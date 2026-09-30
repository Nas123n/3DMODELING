--!strict
-- Lists the concrete things an NPC could do right now: places to visit, sectors to explore,
-- somewhere to wander toward, people to follow or watch, groups to join, spots to stand on, and
-- always the option of doing nothing. Each activity contributes a few candidates; global rules
-- drop targets in no-go areas, full places, blocked people and recent stuck spots; an interrupt
-- adds the reactions it suggests with a bonus.

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Memory = require(script.Parent.Memory)
local Session = require(script.Parent.Session)
local Mood = require(script.Parent.Mood)
local Utility = require(script.Parent.Utility)

type Rng = Rng.Rng
type Candidate = Utility.Candidate

local Goals = {}

export type Entity = {
	id: string,
	kind: string,
	position: Vector3,
	velocity: Vector3,
	yaw: number,
	displayName: string,
}

export type Group = { id: number, members: { string }, center: Vector3, radius: number, age: number }

export type Poi = {
	id: string,
	kind: string,
	position: Vector3,
	weight: number,
	radius: number,
	dwellMedian: number?,
	capacity: number?,
	standOn: boolean?,
}

export type World = {
	pois: { Poi },
	poiOccupants: (poiId: string) -> number, -- entities inside the radius
	entities: { Entity }, -- near me, excluding me, sorted by distance
	visible: { [string]: boolean }, -- entity ids in sight
	groups: { Group },
	myGroup: Group?,
	spawnPoint: Vector3,
	-- Navigation queries
	reachable: (position: Vector3) -> boolean, -- a walkable node within a few studs
	randomReachable: (from: Vector3, minDistance: number, maxDistance: number, toward: Vector3?) -> Vector3?,
	sectorCenter: (sectorId: string) -> Vector3?, -- nearest reachable point in the sector
	nearbySectors: (from: Vector3, count: number) -> { string }, -- unexplored sector ids nearest me
	totalSectors: number,
	isAvoided: (position: Vector3) -> boolean,
	failedRecently: (target: string) -> boolean, -- a path to this target failed < 5 min ago
	props: { { id: string, position: Vector3, top: number, footprint: number } }?,
}

export type Context = {
	me: { id: string, position: Vector3, heading: Vector3 },
	persona: any,
	memory: Memory.Memory,
	phase: string,
	mood: string,
	now: number,
	rng: Rng,
	world: World,
	relations: { [string]: { affinity: number, annoyance: number, blocked: boolean } },
	canFollow: (id: string) -> boolean,
	attachment: string?,
	favoritePoiKind: string?,
	fatigue: number,
}

local function affinityFor(ctx: Context, id: string): number
	local r = ctx.relations[id]
	if not r then
		return 1
	end
	return math.clamp(0.3 + r.affinity - r.annoyance, 0, 1.3)
end

local function blocked(ctx: Context, id: string): boolean
	local r = ctx.relations[id]
	return r ~= nil and r.blocked
end

local function distanceTo(ctx: Context, position: Vector3): number
	return NavMath.flatDistance(ctx.me.position, position)
end

local function feasibility(ctx: Context, position: Vector3?, target: string?): number
	if position and not ctx.world.reachable(position) then
		return 0
	end
	if target and ctx.world.failedRecently(target) then
		return 0.5
	end
	return 1
end

local function add(out: { Candidate }, ctx: Context, c: Candidate)
	if c.position and ctx.world.isAvoided(c.position) then
		return
	end
	if c.position and Memory.nearRecentStuck(ctx.memory, c.position, ctx.now) then
		c.bonus = (c.bonus or 0) - 0.9
	end
	table.insert(out, c)
end

local function visitPoiCandidates(out: { Candidate }, ctx: Context)
	local world = ctx.world
	local favorite = {}
	local rest = {}
	for _, poi in world.pois do
		if poi.capacity and world.poiOccupants(poi.id) >= (poi.capacity :: number) then
			continue
		end
		local last = Memory.lastVisit(ctx.memory, poi.id)
		local isObjective = poi.kind == "objective" or poi.kind == "shop"
		if last and ctx.now - last < 240 and not isObjective then
			continue
		end
		local d = distanceTo(ctx, poi.position)
		local entry = { poi = poi, distance = d, rank = poi.weight / (1 + d / 60) }
		if ctx.favoritePoiKind and poi.kind == ctx.favoritePoiKind then
			table.insert(favorite, entry)
		else
			table.insert(rest, entry)
		end
	end
	table.sort(favorite, function(a, b)
		return a.distance < b.distance
	end)
	table.sort(rest, function(a, b)
		return a.rank > b.rank
	end)
	local picked = {}
	for i = 1, math.min(3, #favorite) do
		table.insert(picked, favorite[i])
	end
	for i = 1, math.min(5, #rest) do
		table.insert(picked, rest[i])
	end
	for _, entry in picked do
		local poi = entry.poi
		local occupants = world.poiOccupants(poi.id)
		local crowd
		if poi.kind == "hangout" or poi.kind == "shop" then
			crowd = 1 + 0.15 * math.min(occupants, 4)
		else
			crowd = 1 / (1 + 0.5 * occupants)
		end
		local factor = poi.weight * (if ctx.favoritePoiKind == poi.kind then 1.6 else 1) * crowd
		if ctx.phase == "orienting" and (poi.kind == "shop" or poi.kind == "spawn") then
			factor *= 1.5
		end
		add(out, ctx, {
			activity = "VisitPoi",
			target = poi.id,
			position = poi.position,
			distance = entry.distance,
			data = poi,
			ctx = factor,
			feasibility = feasibility(ctx, poi.position, poi.id),
		})
	end
end

local function exploreCandidates(out: { Candidate }, ctx: Context)
	local world = ctx.world
	if world.totalSectors > 0 and Memory.exploredCount(ctx.memory) >= 0.9 * world.totalSectors then
		return
	end
	for _, sectorId in world.nearbySectors(ctx.me.position, 4) do
		if Memory.isExplored(ctx.memory, sectorId) then
			continue
		end
		local center = world.sectorCenter(sectorId)
		if center then
			add(out, ctx, {
				activity = "Explore",
				target = sectorId,
				position = center,
				distance = distanceTo(ctx, center),
				data = { sectorId = sectorId, center = center },
				ctx = 1 + 1.5 * (1 - ctx.persona.accountAge),
				feasibility = feasibility(ctx, center, sectorId),
			})
		end
	end
end

local function wanderCandidates(out: { Candidate }, ctx: Context)
	local world = ctx.world
	local toward: Vector3? = nil
	for _, e in world.entities do
		if world.visible[e.id] then
			toward = e.position
			break
		end
	end
	if not toward and #world.pois > 0 then
		toward = world.pois[ctx.rng:int(1, #world.pois)].position
	end
	local biased = world.randomReachable(ctx.me.position, 15, 40, toward)
	if biased then
		add(out, ctx, {
			activity = "Wander",
			position = biased,
			distance = distanceTo(ctx, biased),
			data = { point = biased },
			ctx = 1.5,
		})
	end
	local uniform = world.randomReachable(ctx.me.position, 15, 40, nil)
	if uniform then
		add(out, ctx, {
			activity = "Wander",
			position = uniform,
			distance = distanceTo(ctx, uniform),
			data = { point = uniform },
			ctx = 1,
		})
	end
end

local function entityCandidates(out: { Candidate }, ctx: Context)
	local world = ctx.world
	local follows, watches, faceoffs = 0, 0, 0
	for _, e in world.entities do
		if blocked(ctx, e.id) then
			continue
		end
		local d = distanceTo(ctx, e.position)
		local visible = world.visible[e.id]
		local isAttachment = ctx.attachment == e.id
		local moving = NavMath.flat(e.velocity).Magnitude > 1
		if visible and ctx.canFollow(e.id) and (d <= 30 or isAttachment) and follows < 3 then
			follows += 1
			add(out, ctx, {
				activity = "Follow",
				target = e.id,
				position = e.position,
				distance = d,
				data = { entityId = e.id },
				ctx = (if moving then 1.2 else 0.8) * (if isAttachment then 1.8 else 1),
				affinity = affinityFor(ctx, e.id),
				feasibility = feasibility(ctx, e.position, e.id),
			})
		end
		if visible and d <= 25 and watches < 2 then
			watches += 1
			add(out, ctx, {
				activity = "Watch",
				target = e.id,
				position = e.position,
				distance = d,
				data = { entityId = e.id },
				ctx = if e.kind == "player" then 1.2 else 1,
				affinity = affinityFor(ctx, e.id),
				feasibility = feasibility(ctx, e.position, e.id),
			})
		end
		if d <= 12 and faceoffs < 2 then
			local facingMe = NavMath.dirFromYaw(e.yaw):Dot(NavMath.flatDirection(e.position, ctx.me.position)) > 0.7
			local r = ctx.relations[e.id]
			if (not moving and facingMe) or (r and r.affinity > 0.5) then
				faceoffs += 1
				add(out, ctx, {
					activity = "FaceOff",
					target = e.id,
					position = e.position,
					distance = d,
					data = { entityId = e.id },
					affinity = affinityFor(ctx, e.id),
					feasibility = feasibility(ctx, e.position, e.id),
				})
			end
		end
	end
end

local function groupCandidates(out: { Candidate }, ctx: Context)
	local world = ctx.world
	local ranked = {}
	for _, g in world.groups do
		if world.myGroup and world.myGroup.id == g.id then
			continue
		end
		local d = distanceTo(ctx, g.center)
		if d > 80 then
			continue
		end
		local hasBlocked, hasAttachment = false, false
		for _, id in g.members do
			if blocked(ctx, id) then
				hasBlocked = true
			end
			if ctx.attachment == id then
				hasAttachment = true
			end
		end
		table.insert(ranked, {
			group = g,
			distance = d,
			rank = ((#g.members) ^ 1.3) / (1 + d / 40),
			hasBlocked = hasBlocked,
			hasAttachment = hasAttachment,
		})
	end
	table.sort(ranked, function(a, b)
		return a.rank > b.rank
	end)
	for i = 1, math.min(3, #ranked) do
		local entry = ranked[i]
		add(out, ctx, {
			activity = "JoinGroup",
			target = tostring(entry.group.id),
			position = entry.group.center,
			distance = entry.distance,
			data = { group = entry.group },
			ctx = (1 + 0.25 * #entry.group.members) * (if entry.hasAttachment then 1.5 else 1) * (if entry.hasBlocked
				then 0.2
				else 1),
			feasibility = feasibility(ctx, entry.group.center, nil),
		})
	end
end

local function propCandidates(out: { Candidate }, ctx: Context)
	local props = ctx.world.props
	if not props then
		return
	end
	local n = 0
	for _, prop in props do
		local d = distanceTo(ctx, prop.position)
		if d <= 30 and n < 3 then
			n += 1
			add(out, ctx, {
				activity = "StandOnProp",
				target = prop.id,
				position = prop.position,
				distance = d,
				data = prop,
				ctx = 1 + (if ctx.mood == "playful" then 1 else 0),
				feasibility = feasibility(ctx, prop.position, prop.id),
			})
		end
	end
end

-- The full candidate list for this think step.
function Goals.candidates(ctx: Context, interrupt: any?): { Candidate }
	local out: { Candidate } = {}
	local function allowed(activity: string): boolean
		return Session.phaseWeight(ctx.phase, activity) > 0 and Mood.multiplier(ctx.mood, "activity." .. activity) > 0
	end

	add(out, ctx, { activity = "IdleStand", distance = 0 })
	if allowed("Afk") and (ctx.phase == "settled" or ctx.fatigue > 0.85) then
		add(out, ctx, { activity = "Afk", distance = 0, ctx = if ctx.phase == "settled" then 1.5 else 0.3 })
	end
	if allowed("VisitPoi") then
		visitPoiCandidates(out, ctx)
	end
	if allowed("Explore") then
		exploreCandidates(out, ctx)
	end
	if allowed("Wander") then
		wanderCandidates(out, ctx)
	end
	if allowed("Follow") or allowed("Watch") or allowed("FaceOff") then
		entityCandidates(out, ctx)
	end
	if allowed("JoinGroup") then
		groupCandidates(out, ctx)
	end
	if allowed("Pace") then
		local someoneClose = #ctx.world.entities > 0 and distanceTo(ctx, ctx.world.entities[1].position) <= 8
		add(out, ctx, { activity = "Pace", distance = 0, ctx = 1 + (if someoneClose then 0.5 else 0) })
	end
	if allowed("StandOnProp") then
		propCandidates(out, ctx)
	end
	if allowed("ReturnToSpawn") then
		add(out, ctx, {
			activity = "ReturnToSpawn",
			position = ctx.world.spawnPoint,
			distance = distanceTo(ctx, ctx.world.spawnPoint),
			ctx = 1 + 2 * (if ctx.phase == "leaving" then 1 else 0),
		})
	end
	if ctx.phase == "leaving" then
		add(out, ctx, { activity = "Leave", distance = 0 })
	end

	-- Drop candidates the phase or mood forbids (IdleStand is always allowed).
	for i = #out, 1, -1 do
		local c = out[i]
		if c.activity ~= "IdleStand" and c.activity ~= "Leave" and not allowed(c.activity) then
			table.remove(out, i)
		end
	end

	if interrupt then
		Goals.addReactions(out, ctx, interrupt)
	end
	return out
end

-- Reaction candidates an interrupt suggests.
function Goals.addReactions(out: { Candidate }, ctx: Context, ev: any)
	local kind = ev.kind
	local subject = ev.subject
	if kind == "followed" or kind == "stared" or kind == "onHead" or kind == "blocked" or kind == "botProbe" then
		if subject and not blocked(ctx, subject) then
			add(out, ctx, {
				activity = "ReactProbe",
				target = subject,
				distance = 0,
				data = { kind = kind, subject = subject, followers = ev.data and ev.data.followers or 1 },
				bonus = 2.0,
			})
		end
	elseif kind == "groupNearby" then
		for _, c in out do
			if c.activity == "JoinGroup" and ev.data and c.target == tostring(ev.data.groupId) then
				c.bonus = (c.bonus or 0) + 2.0
			end
		end
	elseif kind == "entityEmoted" or kind == "entityJumped" then
		if ctx.world.myGroup == nil then
			for _, c in out do
				if c.activity == "JoinGroup" then
					local g = c.data and c.data.group
					if g then
						for _, id in g.members do
							if id == subject then
								c.bonus = (c.bonus or 0) + 1.5
							end
						end
					end
				end
			end
		end
	elseif kind == "chatAddressed" then
		for _, c in out do
			if c.activity == "Watch" and c.target == subject then
				c.bonus = (c.bonus or 0) + 1.3
			end
		end
	elseif kind == "entityAppeared" and subject and subject == ctx.attachment then
		for _, c in out do
			if c.activity == "Follow" and c.target == subject then
				c.bonus = (c.bonus or 0) + 1.5
			end
		end
	end
end

return Goals

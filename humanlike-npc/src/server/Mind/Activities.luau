--!strict
-- The things an NPC does, each a small state machine: stand around, go AFK, visit a place,
-- explore, wander, follow someone, join a group, watch, pace, climb on a prop, stand face to
-- face, return to spawn, react to a probe, leave. Activities never touch the world: they emit
-- intents (goto, hold, step, face, jump, follow, freeze) that the locomotion runtime satisfies
-- and actions (say, emote, leave) that presentation carries out, and they read back a
-- locomotion report to learn whether they arrived. Timings come from the research's
-- heavy-tailed distributions, drawn on entry so each run differs. Seats are reached through
-- optional world closures (seatsNear / occupySeat / releaseSeat): a world without them has no
-- seats and the NPC never sits. This is not the chooser (Goals, Utility, Brain) and not the body.
-- requires: NavMath, Rng, Timing, Memory, Utility

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Timing = require(script.Parent.Parent.Timing)
local Memory = require(script.Parent.Memory)
local Utility = require(script.Parent.Utility)

type Rng = Rng.Rng
type Candidate = Utility.Candidate

local Activities = {}

export type Intent = {
	kind: string, -- "goto" | "hold" | "step" | "face" | "jump" | "follow" | "freeze"
	position: Vector3?,
	stopDistance: number?,
	tolerance: number?,
	urgency: number?,
	dir: Vector3?,
	duration: number?,
	yaw: number?,
	targetId: string?,
	keep: number?,
	variant: string?,
}

export type Action = {
	kind: string, -- "say" | "emote" | "leave" | "look" | "forceLine" | "leaveServer" | "sit" | "typing"
	text: string?,
	lineId: string?,
	target: string?, -- entity id; for "sit" the seat id (nil = stand up)
	name: string?,
	cutAfter: number?,
	category: string?,
	point: Vector3?, -- "sit": the seat's floor point
	on: boolean?, -- "typing": indicator on / off
}

export type Locomotion = {
	status: string, -- "idle" | "planning" | "walking" | "arrived" | "failed"
	goal: Vector3?,
	moving: boolean,
	onGround: boolean,
	blockedBy: string?,
	remaining: number?, -- studs still to walk along the path; nil when the caller does not know
}

-- A structural view of Types.SeatRecord (the id, the floor point in front of the seat, its POI).
export type Seat = { id: string, position: Vector3, poiId: string? }

export type Context = {
	now: number,
	dt: number,
	rng: Rng,
	persona: any,
	me: { id: string, position: Vector3, heading: Vector3 },
	locomotion: Locomotion,
	world: any, -- Goals.World (seatsNear / occupySeat / releaseSeat are optional closures on it)
	entity: (id: string) -> any?, -- live entity view or nil
	memory: Memory.Memory,
	emit: (Intent) -> (),
	act: (Action) -> (),
	relieve: (event: string, context: any?) -> (),
	-- Overlay suppression this step (fidget, emote, mirror, talk) and, from a full AFK, attention:
	-- the senses then report nothing but system events and lines that name the NPC.
	suppress: { [string]: boolean },
	canFollow: (id: string) -> boolean,
	beginFollow: (id: string) -> (),
	affinity: (id: string) -> number,
	shiftLock: boolean,
	groupOf: (id: string) -> any?,
	inGroup: boolean,
	wakeBurst: boolean?, -- set by Afk on exit; read by Fidget
	seats: { Seat }?, -- world.seats; nil when the world knows no seats
	familiarity: number?, -- persona.familiarity (0 newcomer .. 1 veteran)
	afkStyle: string?, -- persona.afkStyle: "full" (attention off) | "semi" (reaction delays x3)
}

export type Status = string -- "running" | "success" | "failed"

export type Activity = {
	name: string,
	start: (ctx: Context, candidate: Candidate) -> any,
	tick: (ctx: Context, state: any) -> Status,
	stop: (ctx: Context, state: any, outcome: string) -> (),
	hasTrip: boolean, -- subject to random abandonment
}

local function u(rng: Rng, lo: number, hi: number): number
	return rng:range(lo, hi)
end

export type GotoOptions = { stopDistance: number?, tolerance: number?, urgency: number? }

-- Emits a goto every tick and reports arrival/failure from the locomotion report.
local function gotoStep(ctx: Context, position: Vector3, opts: GotoOptions?): string
	local o: GotoOptions = opts or {}
	local loc = ctx.locomotion
	local tolerance = o.tolerance or 1.5
	if loc.goal and NavMath.flatDistance(loc.goal, position) < 0.5 then
		if loc.status == "arrived" then
			return "arrived"
		elseif loc.status == "failed" then
			return "failed"
		end
	end
	if NavMath.flatDistance(ctx.me.position, position) <= tolerance and loc.status ~= "walking" then
		return "arrived"
	end
	ctx.emit({
		kind = "goto",
		position = position,
		stopDistance = o.stopDistance,
		tolerance = tolerance,
		urgency = o.urgency,
	})
	return "running"
end

local function hold(ctx: Context)
	ctx.emit({ kind = "hold" })
end

local function face(ctx: Context, target: Vector3, jitterDeg: number)
	if not ctx.shiftLock then
		return
	end
	local dir = NavMath.flatDirection(ctx.me.position, target)
	if dir.Magnitude == 0 then
		return
	end
	local yaw = NavMath.yawOf(dir) + math.rad(u(ctx.rng, -jitterDeg, jitterDeg))
	ctx.emit({ kind = "face", yaw = yaw })
end

local registry: { [string]: Activity } = {}

-- IdleStand: stand still for a heavy-tailed while, maybe first stepping out of the walkway.
registry.IdleStand = {
	name = "IdleStand",
	hasTrip = false,
	start = function(ctx, _)
		local p = ctx.persona
		local rng = ctx.rng
		local duration = rng:logNormalClamped(4 * (0.6 + 0.8 * p.patience), 1.1, 0.5, 300)
		local state: { until_: number, stepUntil: number?, stepDir: Vector3? } =
			{ until_ = ctx.now + duration, stepUntil = nil, stepDir = nil }
		if rng:chance(0.25) then
			local side = NavMath.perp(ctx.me.heading) * rng:sign()
			state.stepUntil = ctx.now + u(rng, 0.3, 0.6)
			state.stepDir = side
		end
		return state
	end,
	tick = function(ctx, state)
		if state.stepUntil and ctx.now < state.stepUntil then
			ctx.emit({ kind = "step", dir = state.stepDir, duration = state.stepUntil - ctx.now })
			return "running"
		end
		hold(ctx)
		ctx.relieve("idleTick", { dt = ctx.dt })
		return if ctx.now >= state.until_ then "success" else "running"
	end,
	stop = function() end,
}

-- Afk: perfectly still for minutes, an optional wiggle near the idle-kick, then an abrupt wake.
-- Neither AFK style ever turns: "full" also switches attention off (the senses skip everything
-- but system events and lines naming the NPC); "semi" keeps noticing, three times slower (the
-- brain stretches the reaction delays).
registry.Afk = {
	name = "Afk",
	hasTrip = false,
	start = function(ctx, _)
		local p = ctx.persona
		local rng = ctx.rng
		local duration = rng:logNormalClamped(180, 1.0, 30, 1200) * (0.5 + p.afkProneness)
		local wiggleAt = nil
		if duration > 1020 and rng:chance(0.5) then
			wiggleAt = ctx.now + u(rng, 1080, 1140)
		end
		return { startedAt = ctx.now, until_ = ctx.now + duration, wiggleAt = wiggleAt }
	end,
	tick = function(ctx, state)
		ctx.suppress.fidget = true
		ctx.suppress.emote = true
		ctx.suppress.mirror = true
		ctx.suppress.talk = true
		if ctx.afkStyle == "full" then
			ctx.suppress.attention = true
		end
		ctx.relieve("afkTick", { dt = ctx.dt })
		if state.wiggleAt and ctx.now >= state.wiggleAt then
			state.wiggleAt = nil
			if ctx.rng:chance(0.6) then
				ctx.emit({ kind = "jump" })
			else
				ctx.emit({ kind = "step", dir = ctx.me.heading, duration = 0.15 })
			end
			return "running"
		end
		hold(ctx)
		if ctx.now >= state.until_ then
			ctx.wakeBurst = true
			return "success"
		end
		return "running"
	end,
	stop = function(ctx, _, outcome)
		if outcome == "success" then
			ctx.relieve("afkDone")
		end
	end,
}

local DWELL_DEFAULT: { [string]: number } = { shop = 8, hangout = 25, viewpoint = 12, objective = 6, spawn = 5 }
local HOVER_CHANCE: { [string]: number } = { shop = 0.4, hangout = 0.2, viewpoint = 0.3, objective = 0.15 }
local SIT_CHANCE = 0.35 -- times persona.sitHabit, per dwell at a place with a free seat
local MOBILE_STOP_SCALE = 1.15 -- thumb players stop a little further out
local OCCUPANT_RADIUS, OCCUPANT_PUSH = 2, 1.5 -- studs: nobody stops on top of someone
local SIDE_STEP_EVERY, SIDE_STEP_CHANCE = 5, 0.5 -- dwelling: a small shuffle now and then

-- Facing a point roughly (within ±jitterDeg): shift-lock profiles turn the body, everyone else
-- taps a short step toward it, which is the only way a third-person body turns.
local function faceOrTap(ctx: Context, target: Vector3, jitterDeg: number)
	if ctx.shiftLock then
		face(ctx, target, jitterDeg)
		return
	end
	local toward = NavMath.flatDirection(ctx.me.position, target)
	if toward.Magnitude > 0 then
		ctx.emit({ kind = "step", dir = toward, duration = 0.2 })
	end
end

-- A free seat within the place's radius, taken with p = SIT_CHANCE * sitHabit; nil when the world
-- has no seat query, no free seat is near, or the roll says stand. Draws only when a seat exists,
-- so worlds without seats see the same draw sequence as before seats existed.
local function pickSeat(ctx: Context, poi: any): Seat?
	local world = ctx.world
	if type(world.seatsNear) ~= "function" or type(world.occupySeat) ~= "function" then
		return nil
	end
	local free: { Seat } = world.seatsNear(poi.position, poi.radius or 6)
	if #free == 0 then
		return nil
	end
	local sitHabit = ctx.persona.sitHabit or 0
	if not ctx.rng:chance(SIT_CHANCE * sitHabit) then
		return nil
	end
	return free[1]
end

local function standUp(ctx: Context, state: any)
	if not state.seated then
		return
	end
	state.seated = false
	ctx.act({ kind = "sit", target = nil })
	local seat = state.seat
	if seat and type(ctx.world.releaseSeat) == "function" then
		ctx.world.releaseSeat(seat.id, ctx.me.id)
	end
end

-- VisitPoi: approach off-axis, stop short (further on a phone, never on top of someone), face
-- the place roughly, maybe hover, then interact or dwell, sitting down when a seat is free.
registry.VisitPoi = {
	name = "VisitPoi",
	hasTrip = true,
	start = function(ctx, candidate)
		local poi = candidate.data
		local rng = ctx.rng
		local approach = NavMath.flatDirection(poi.position, ctx.me.position)
		if approach.Magnitude == 0 then
			approach = NavMath.dirFromYaw(rng:range(0, math.pi * 2))
		end
		if rng:chance(0.4) then
			local angle = math.rad(u(rng, 45, 120)) * rng:sign()
			approach = NavMath.dirFromYaw(NavMath.yawOf(approach) + angle)
		end
		local kind = poi.kind
		local stopDist
		if kind == "shop" or kind == "objective" then
			stopDist = u(rng, 2, 4)
		elseif kind == "viewpoint" then
			stopDist = u(rng, 1, 3)
		else
			stopDist = u(rng, 0.3, 0.8) * (poi.radius or 6)
		end
		local profile = ctx.persona.profile
		if profile and profile.kind == "mobile" then
			stopDist *= MOBILE_STOP_SCALE
		end
		local target = poi.position + approach * stopDist
		-- Pushed off anyone already standing on the stop point.
		for _, e in ctx.world.entities do
			if NavMath.flatDistance(e.position, target) < OCCUPANT_RADIUS then
				local away = NavMath.flatDirection(e.position, target)
				if away.Magnitude == 0 then
					away = approach
				end
				target = target + away * OCCUPANT_PUSH
				break
			end
		end
		return {
			poi = poi,
			approach = approach,
			target = target,
			phase = "approach",
			hovers = if rng:chance(HOVER_CHANCE[kind] or 0.2) then rng:int(1, 3) else 0,
			hoverTarget = nil,
			phaseUntil = 0,
			interactions = 0,
			interactionsLeft = 0,
			seat = nil,
			seated = false,
			nextSideStepAt = 0,
		}
	end,
	tick = function(ctx, state)
		local rng = ctx.rng
		local poi = state.poi
		local kind = poi.kind
		if state.phase == "approach" then
			local r = gotoStep(ctx, state.target, { stopDistance = 0.5, tolerance = 1.5, urgency = 0.5 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				if rng:chance(0.6) then
					faceOrTap(ctx, poi.position, 30)
				end
				state.phase = if state.hovers > 0 then "hover" else "decide"
			end
			return "running"
		elseif state.phase == "hover" then
			if not state.hoverTarget then
				local angle = math.rad(u(rng, 30, 90)) * rng:sign()
				local dir = NavMath.dirFromYaw(NavMath.yawOf(state.approach) + angle)
				state.hoverTarget = poi.position + dir * u(rng, 4, 10)
			end
			local r = gotoStep(ctx, state.hoverTarget, { tolerance = 2 })
			if r == "failed" then
				state.hovers = 0
				state.phase = "decide"
			elseif r == "arrived" then
				state.hovers -= 1
				state.hoverTarget = nil
				state.phase = "hoverWait"
				state.phaseUntil = ctx.now + rng:logNormalClamped(1.5, 0.5, 0.5, 4)
			end
			return "running"
		elseif state.phase == "hoverWait" then
			hold(ctx)
			if ctx.now >= state.phaseUntil then
				state.phase = if state.hovers > 0 then "hover" else "decide"
			end
			return "running"
		elseif state.phase == "decide" then
			if kind == "shop" and rng:chance(0.4) then
				state.phase = "lookAndLeave"
				state.phaseUntil = ctx.now + rng:logNormalClamped(3, 0.6, 1, 8)
			elseif kind == "shop" or kind == "objective" then
				state.phase = "interact"
				state.interactionsLeft = Timing.geometric(rng, 0.4, 1, 10)
				-- A beat before the first interaction: nobody presses the prompt on arrival.
				state.sub = "pause"
				state.phaseUntil = ctx.now + rng:logNormalClamped(0.7, 0.5, 0.3, 1.5)
			else
				state.phase = "dwell"
				local median = poi.dwellMedian or DWELL_DEFAULT[kind] or 10
				state.phaseUntil = ctx.now + rng:logNormalClamped(median, 0.8, 1, 300)
				state.nextSideStepAt = ctx.now + SIDE_STEP_EVERY
				local seat = pickSeat(ctx, poi)
				if seat then
					state.seat = seat
					state.phase = "toSeat"
				end
			end
			return "running"
		elseif state.phase == "toSeat" then
			-- Walk to the seat; taken on arrival (someone was quicker) means dwelling on foot.
			local seat: Seat = state.seat
			local r = gotoStep(ctx, seat.position, { stopDistance = 0.3, tolerance = 1.2, urgency = 0.4 })
			if r == "arrived" then
				if ctx.world.occupySeat(seat.id, ctx.me.id) == true then
					state.seated = true
					ctx.act({ kind = "sit", target = seat.id, point = seat.position })
				else
					state.seat = nil
				end
				state.phase = "dwell"
			elseif r == "failed" then
				state.seat = nil
				state.phase = "dwell"
			end
			return "running"
		elseif state.phase == "lookAndLeave" then
			hold(ctx)
			face(ctx, poi.position, 30)
			return if ctx.now >= state.phaseUntil then "success" else "running"
		elseif state.phase == "interact" then
			-- pause -> read the prompt -> hold the key -> watch the result -> shuffle -> maybe check inventory
			if state.sub == "pause" then
				hold(ctx)
				if ctx.now >= state.phaseUntil then
					state.sub = "read"
					state.phaseUntil = ctx.now + u(rng, 0.3, 1.5)
				end
			elseif state.sub == "read" then
				hold(ctx)
				face(ctx, poi.position, 30)
				if ctx.now >= state.phaseUntil then
					state.sub = "prompt"
					state.phaseUntil = ctx.now + u(rng, 0.3, 0.6)
				end
			elseif state.sub == "prompt" then
				hold(ctx)
				ctx.suppress.fidget = true
				ctx.suppress.mirror = true
				if ctx.now >= state.phaseUntil then
					state.sub = "watch"
					state.phaseUntil = ctx.now + rng:logNormalClamped(4, 0.4, 3, 6)
				end
			elseif state.sub == "watch" then
				hold(ctx)
				ctx.suppress.fidget = true
				if ctx.now >= state.phaseUntil then
					state.interactions += 1
					state.interactionsLeft -= 1
					if rng:chance(0.7) then
						ctx.emit({ kind = "step", dir = NavMath.perp(ctx.me.heading) * rng:sign(), duration = 0.15 })
					end
					if rng:chance(0.3) then
						state.sub = "inventory"
						state.phaseUntil = ctx.now + rng:logNormalClamped(2, 0.5, 1, 6)
					elseif state.interactionsLeft > 0 then
						state.sub = "read"
						state.phaseUntil = ctx.now + u(rng, 0.3, 1.5)
					else
						return "success"
					end
				end
			elseif state.sub == "inventory" then
				hold(ctx)
				if ctx.now >= state.phaseUntil then
					if state.interactionsLeft > 0 then
						state.sub = "read"
						state.phaseUntil = ctx.now + u(rng, 0.3, 1.5)
					else
						return "success"
					end
				end
			end
			return "running"
		elseif state.phase == "dwell" then
			hold(ctx)
			if state.seated then
				ctx.suppress.fidget = true
			elseif ctx.now >= state.nextSideStepAt then
				-- Standing around: a small shuffle sideways now and then.
				state.nextSideStepAt = ctx.now + SIDE_STEP_EVERY
				if rng:chance(SIDE_STEP_CHANCE) then
					local studs = u(rng, 0.3, 0.8)
					ctx.emit({
						kind = "step",
						dir = NavMath.perp(ctx.me.heading) * rng:sign(),
						duration = studs / (ctx.persona.walkSpeed or 16),
					})
				end
			end
			return if ctx.now >= state.phaseUntil then "success" else "running"
		end
		return "failed"
	end,
	stop = function(ctx, state, outcome)
		-- The next trip starts on foot: stand up and free the seat whatever the outcome.
		standUp(ctx, state)
		if outcome == "success" then
			Memory.recordVisit(ctx.memory, state.poi.id, ctx.now)
			local kind = state.poi.kind
			if kind == "shop" or kind == "objective" then
				ctx.relieve("visitObjective")
			else
				local others = false
				for _, e in ctx.world.entities do
					if NavMath.flatDistance(e.position, state.poi.position) <= (state.poi.radius or 6) then
						others = true
						break
					end
				end
				ctx.relieve("visitHangout", { others = others })
			end
		end
	end,
}

-- Explore: walk to an unexplored sector, mark it, look around.
registry.Explore = {
	name = "Explore",
	hasTrip = true,
	start = function(ctx, candidate)
		return {
			sectorId = candidate.data.sectorId,
			center = candidate.data.center,
			phase = "go",
			phaseUntil = 0,
			yawTarget = nil,
		}
	end,
	tick = function(ctx, state)
		if state.phase == "go" then
			local r = gotoStep(ctx, state.center, { stopDistance = 3, tolerance = 6, urgency = 0.4 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				Memory.markExplored(ctx.memory, state.sectorId)
				ctx.relieve("explore")
				if ctx.rng:chance(0.6) then
					state.phase = "look"
					state.phaseUntil = ctx.now + ctx.rng:logNormalClamped(2, 0.6, 1, 6)
					if ctx.shiftLock then
						state.yawTarget = NavMath.yawOf(ctx.me.heading) + math.rad(u(ctx.rng, 30, 90)) * ctx.rng:sign()
					end
				else
					return "success"
				end
			end
			return "running"
		end
		hold(ctx)
		if state.yawTarget then
			ctx.emit({ kind = "face", yaw = state.yawTarget })
		end
		return if ctx.now >= state.phaseUntil then "success" else "running"
	end,
	stop = function() end,
}

-- Wander: walk toward something, maybe pause.
registry.Wander = {
	name = "Wander",
	hasTrip = true,
	start = function(ctx, candidate)
		return { point = candidate.data.point, phase = "go", phaseUntil = 0 }
	end,
	tick = function(ctx, state)
		if state.phase == "go" then
			local r = gotoStep(ctx, state.point, { stopDistance = 1.5, tolerance = 3, urgency = 0.3 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				ctx.relieve("wander")
				if ctx.rng:chance(0.5) then
					state.phase = "pause"
					state.phaseUntil = ctx.now + ctx.rng:logNormalClamped(2, 0.7, 0.5, 8)
				else
					return "success"
				end
			end
			return "running"
		end
		hold(ctx)
		return if ctx.now >= state.phaseUntil then "success" else "running"
	end,
	stop = function() end,
}

-- Follow: tail someone for a while at a distance that depends on how well we know them.
registry.Follow = {
	name = "Follow",
	hasTrip = true,
	start = function(ctx, candidate)
		local id = candidate.data.entityId
		local rng = ctx.rng
		ctx.beginFollow(id)
		local keep = if ctx.affinity(id) > 0.5 then u(rng, 1, 3) else u(rng, 3, 6)
		return {
			entityId = id,
			until_ = ctx.now + rng:logNormalClamped(25, 0.6, 10, 60),
			keep = keep,
			lastSeenAt = ctx.now,
			stationarySince = nil,
			targetStationary = false,
		}
	end,
	tick = function(ctx, state)
		if not ctx.canFollow(state.entityId) and ctx.now - state.lastSeenAt > 0 then
			-- Guard withdrew permission (a stop keyword): end at once.
			local r = ctx.affinity(state.entityId)
			if r == 0 or not ctx.canFollow(state.entityId) then
				return "failed"
			end
		end
		local target = ctx.entity(state.entityId)
		if not target then
			return if ctx.now - state.lastSeenAt > 6 then "success" else "running"
		end
		state.lastSeenAt = ctx.now
		local moving = NavMath.flat(target.velocity).Magnitude > 1
		if moving then
			state.stationarySince = nil
			state.targetStationary = false
		else
			state.stationarySince = state.stationarySince or ctx.now
			state.targetStationary = ctx.now - state.stationarySince > 8
		end
		if state.targetStationary then
			return "success"
		end
		ctx.emit({ kind = "follow", targetId = state.entityId, keep = state.keep })
		return if ctx.now >= state.until_ then "success" else "running"
	end,
	stop = function() end,
}

-- JoinGroup: take a ring spot, maybe wave, hang around until bored or the group dissolves.
registry.JoinGroup = {
	name = "JoinGroup",
	hasTrip = true,
	start = function(ctx, candidate)
		local g = candidate.data.group
		local rng = ctx.rng
		local ring = math.clamp(g.radius + 2, 3, 6)
		local dir = NavMath.flatDirection(g.center, ctx.me.position)
		if dir.Magnitude == 0 then
			dir = NavMath.dirFromYaw(rng:range(0, math.pi * 2))
		end
		dir = NavMath.dirFromYaw(NavMath.yawOf(dir) + math.rad(u(rng, -60, 60)))
		return {
			groupId = g.id,
			center = g.center,
			spot = g.center + dir * ring,
			phase = "go",
			until_ = 0,
			crowdedSince = nil,
		}
	end,
	tick = function(ctx, state)
		local rng = ctx.rng
		if state.phase == "go" then
			local r = gotoStep(ctx, state.spot, { stopDistance = 0.5, tolerance = 1.5 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				state.phase = "stay"
				state.until_ = ctx.now + rng:logNormalClamped(60, 0.9, 15, 300)
				if rng:chance(0.3 * (0.5 + ctx.persona.emoteHabit)) then
					ctx.act({ kind = "emote", name = "wave", cutAfter = rng:logNormalClamped(2.5, 0.4, 1.5, 4) })
				end
			end
			return "running"
		end
		local group = ctx.groupOf(ctx.me.id)
		local dissolved = group == nil or #group.members < 2
		-- Personal space: someone standing on my spot for 2 s makes me shuffle.
		local crowded = false
		for _, e in ctx.world.entities do
			if NavMath.flatDistance(e.position, ctx.me.position) < 1.5 then
				crowded = true
				break
			end
		end
		if crowded then
			state.crowdedSince = state.crowdedSince or ctx.now
			if ctx.now - state.crowdedSince > 2 then
				state.crowdedSince = nil
				ctx.emit({ kind = "step", dir = NavMath.perp(ctx.me.heading) * rng:sign(), duration = u(rng, 0.3, 0.5) })
				return "running"
			end
		else
			state.crowdedSince = nil
		end
		face(ctx, state.center, 25)
		hold(ctx)
		if rng:chance(ctx.dt * 0.02) then
			ctx.emit({ kind = "step", dir = NavMath.perp(ctx.me.heading) * rng:sign(), duration = u(rng, 0.2, 0.4) })
		end
		if ctx.now >= state.until_ or dissolved then
			return "success"
		end
		return "running"
	end,
	stop = function() end,
}

-- Watch: stand a few studs from someone (data.entityId) or from a spot (data.position, a game
-- event) and look.
registry.Watch = {
	name = "Watch",
	hasTrip = true,
	start = function(ctx, candidate)
		local id: string? = candidate.data.entityId
		local target = if id then ctx.entity(id) else nil
		local at: Vector3 = if target then target.position else (candidate.data.position or ctx.me.position)
		local dir = NavMath.flatDirection(at, ctx.me.position)
		if dir.Magnitude == 0 then
			dir = NavMath.dirFromYaw(ctx.rng:range(0, math.pi * 2))
		end
		return { entityId = id, at = at, spot = at + dir * u(ctx.rng, 4, 8), phase = "go", until_ = 0 }
	end,
	tick = function(ctx, state)
		if state.phase == "go" then
			local r = gotoStep(ctx, state.spot, { tolerance = 2 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				state.phase = "watch"
				state.until_ = ctx.now + ctx.rng:logNormalClamped(8, 0.7, 3, 30)
			end
			return "running"
		end
		local target = if state.entityId then ctx.entity(state.entityId) else nil
		if target then
			face(ctx, target.position, 20)
		elseif state.entityId == nil then
			face(ctx, state.at, 20)
		end
		hold(ctx)
		return if ctx.now >= state.until_ then "success" else "running"
	end,
	stop = function() end,
}

-- Pace: strafe taps or a small loop while waiting.
registry.Pace = {
	name = "Pace",
	hasTrip = false,
	start = function(ctx, _)
		local rng = ctx.rng
		local strafe = not ctx.persona.profile.analog and rng:chance(0.5)
		return {
			pattern = if strafe then "strafe" else "loop",
			until_ = ctx.now + rng:logNormalClamped(12, 0.7, 4, 40),
			origin = ctx.me.position,
			stepDir = 1,
			stepUntil = 0,
			point = nil,
			pauseUntil = 0,
		}
	end,
	tick = function(ctx, state)
		local rng = ctx.rng
		if ctx.now >= state.until_ then
			return "success"
		end
		if state.pattern == "strafe" then
			if ctx.now >= state.stepUntil then
				state.stepDir = -state.stepDir
				state.stepUntil = ctx.now + u(rng, 0.4, 1.0)
			end
			ctx.emit({
				kind = "step",
				dir = NavMath.perp(ctx.me.heading) * state.stepDir,
				duration = state.stepUntil - ctx.now,
			})
			return "running"
		end
		if ctx.now < state.pauseUntil then
			hold(ctx)
			return "running"
		end
		if not state.point then
			local offset = NavMath.dirFromYaw(rng:range(0, math.pi * 2)) * u(rng, 3, 8)
			local candidate = state.origin + offset
			state.point = if ctx.world.reachable(candidate) then candidate else state.origin
		end
		local r = gotoStep(ctx, state.point, { tolerance = 1.5 })
		if r == "arrived" or r == "failed" then
			state.point = nil
			if rng:chance(0.3) then
				state.pauseUntil = ctx.now + u(rng, 0.3, 1.5)
			end
		end
		return "running"
	end,
	stop = function(ctx, _, outcome)
		if outcome == "success" then
			ctx.relieve("pace")
		end
	end,
}

-- StandOnProp: walk to the edge, jump on (a few tries), stand there, step off.
registry.StandOnProp = {
	name = "StandOnProp",
	hasTrip = true,
	start = function(ctx, candidate)
		local prop = candidate.data
		local dir = NavMath.flatDirection(prop.position, ctx.me.position)
		if dir.Magnitude == 0 then
			dir = NavMath.dirFromYaw(0)
		end
		return {
			prop = prop,
			edge = prop.position + dir * (prop.footprint / 2 + 1.5),
			phase = "go",
			attempts = 0,
			phaseUntil = 0,
		}
	end,
	tick = function(ctx, state)
		local rng = ctx.rng
		local prop = state.prop
		if state.phase == "go" then
			local r = gotoStep(ctx, state.edge, { tolerance = 1 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				state.phase = "mount"
				state.phaseUntil = ctx.now + u(rng, 0.5, 0.9)
				state.attempts += 1
				ctx.emit({ kind = "jump" })
			end
			return "running"
		elseif state.phase == "mount" then
			ctx.emit({ kind = "step", dir = NavMath.flatDirection(ctx.me.position, prop.position), duration = 0.1 })
			if ctx.now >= state.phaseUntil then
				state.phase = "check"
				state.phaseUntil = ctx.now + 0.8
			end
			return "running"
		elseif state.phase == "check" then
			hold(ctx)
			if ctx.now >= state.phaseUntil then
				local onTop = math.abs(ctx.me.position.Y - prop.top) < 1.2
					and NavMath.flatDistance(ctx.me.position, prop.position) < prop.footprint / 2 + 0.5
				if onTop then
					state.phase = "stand"
					state.phaseUntil = ctx.now + rng:logNormalClamped(15, 0.9, 5, 60)
					ctx.relieve("standOnProp")
				elseif state.attempts >= 3 then
					return "failed"
				else
					state.phase = "retry"
					state.phaseUntil = ctx.now + u(rng, 0.3, 0.8)
					ctx.emit({
						kind = "step",
						dir = NavMath.flatDirection(prop.position, ctx.me.position),
						duration = 0.2,
					})
				end
			end
			return "running"
		elseif state.phase == "retry" then
			hold(ctx)
			if ctx.now >= state.phaseUntil then
				state.phase = "mount"
				state.phaseUntil = ctx.now + u(rng, 0.5, 0.9)
				state.attempts += 1
				ctx.emit({ kind = "jump" })
			end
			return "running"
		elseif state.phase == "stand" then
			hold(ctx)
			if ctx.now >= state.phaseUntil then
				ctx.emit({ kind = "step", dir = NavMath.dirFromYaw(rng:range(0, math.pi * 2)), duration = 0.5 })
				return "success"
			end
			return "running"
		end
		return "failed"
	end,
	stop = function() end,
}

-- FaceOff: stand close, face each other, chat: the "trade window" posture.
registry.FaceOff = {
	name = "FaceOff",
	hasTrip = true,
	start = function(ctx, candidate)
		local id = candidate.data.entityId
		local target = ctx.entity(id)
		local at = if target then target.position else ctx.me.position
		local dir = NavMath.flatDirection(at, ctx.me.position)
		if dir.Magnitude == 0 then
			dir = NavMath.dirFromYaw(0)
		end
		return { entityId = id, spot = at + dir * u(ctx.rng, 2, 4), phase = "go", until_ = 0, lastSeenAt = ctx.now }
	end,
	tick = function(ctx, state)
		local target = ctx.entity(state.entityId)
		if state.phase == "go" then
			local r = gotoStep(ctx, state.spot, { tolerance = 1 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				state.phase = "talk"
				state.until_ = ctx.now + ctx.rng:logNormalClamped(40, 0.7, 20, 120)
				if ctx.rng:chance(0.6) then
					ctx.act({ kind = "forceLine", category = "social", target = state.entityId })
				end
			end
			return "running"
		end
		if target then
			state.lastSeenAt = ctx.now
			face(ctx, target.position, 15)
			if NavMath.flatDistance(target.position, ctx.me.position) > 6 then
				return "success"
			end
		elseif ctx.now - state.lastSeenAt > 5 then
			return "success"
		end
		hold(ctx)
		return if ctx.now >= state.until_ then "success" else "running"
	end,
	stop = function(ctx, _, outcome)
		if outcome == "success" then
			ctx.relieve("faceOff")
		end
	end,
}

registry.ReturnToSpawn = {
	name = "ReturnToSpawn",
	hasTrip = true,
	start = function(ctx, _)
		return { phase = "go", until_ = 0 }
	end,
	tick = function(ctx, state)
		if state.phase == "go" then
			local r = gotoStep(ctx, ctx.world.spawnPoint, { tolerance = 4 })
			if r == "failed" then
				return "failed"
			elseif r == "arrived" then
				if ctx.rng:chance(0.5) then
					state.phase = "pause"
					state.until_ = ctx.now + ctx.rng:logNormalClamped(3, 0.6, 1, 10)
				else
					return "success"
				end
			end
			return "running"
		end
		hold(ctx)
		return if ctx.now >= state.until_ then "success" else "running"
	end,
	stop = function() end,
}

-- ReactProbe: one reaction to being followed, blocked, stared at, sat on, or asked if I am a bot.
local function pickReaction(ctx: Context, kind: string, followers: number): string
	local p = ctx.persona
	local rng = ctx.rng
	local options: { string }, weights: { number }
	if kind == "followed" then
		options = { "ignore", "stopFace", "jumpSpin", "chat", "escape" }
		weights = {
			45 * (if ctx.world.mood == "annoyed" then 0.5 else 1),
			20,
			15 * (1 + p.trolliness),
			10 * (0.5 + p.friendliness + 0.5 * p.chattiness),
			10 * (2 - p.patience) * (if followers >= 2 then 2 else 1),
		}
	elseif kind == "blocked" then
		options = { "jumpOver", "around", "chat" }
		weights = { 70, 20, 10 }
	elseif kind == "stared" then
		options = { "ignore", "faceBack", "jumpEmote", "chat" }
		weights = { 50, 25, 15, 10 }
	elseif kind == "onHead" then
		options = { "ignore", "jumpDislodge", "chat" }
		weights = { 60, 30, 10 }
	else -- botProbe
		options = { "ignore", "chat" }
		weights = { 30, 70 }
	end
	return options[rng:weightedIndex(weights)]
end

registry.ReactProbe = {
	name = "ReactProbe",
	hasTrip = false,
	start = function(ctx, candidate)
		local kind = candidate.data.kind
		local subject = candidate.data.subject
		local reaction = pickReaction(ctx, kind, candidate.data.followers or 1)
		local state =
			{ kind = kind, subject = subject, reaction = reaction, until_ = ctx.now, phase = "run", resume = false }
		local rng = ctx.rng
		if reaction == "chat" then
			local category = if kind == "followed"
				then "followed"
				elseif kind == "blocked" then "blocked"
				elseif kind == "botProbe" then "probe"
				else "reaction"
			ctx.act({ kind = "forceLine", category = category, target = subject })
		elseif reaction == "stopFace" then
			state.until_ = ctx.now + u(rng, 2, 6)
		elseif reaction == "faceBack" then
			state.until_ = ctx.now + u(rng, 2, 5)
		elseif
			reaction == "jumpSpin"
			or reaction == "jumpEmote"
			or reaction == "jumpDislodge"
			or reaction == "jumpOver"
		then
			ctx.emit({ kind = "jump" })
			state.until_ = ctx.now + 0.4
			state.resume = reaction == "jumpOver"
			if reaction == "jumpEmote" and rng:chance(0.5) then
				ctx.act({ kind = "emote", name = "wave", cutAfter = 2 })
			end
		elseif reaction == "escape" then
			if rng:chance(0.2 * (1 - ctx.persona.patience)) then
				ctx.act({ kind = "leaveServer" })
				state.until_ = ctx.now
			else
				local far, farD = nil, 0
				for _, poi in ctx.world.pois do
					local d = NavMath.flatDistance(poi.position, ctx.me.position)
					if d >= 80 and d > farD then
						far, farD = poi, d
					end
				end
				if far then
					state.phase = "flee"
					state.target = far.position
				end
			end
		elseif reaction == "around" then
			state.resume = true
		end
		return state
	end,
	tick = function(ctx, state)
		if state.phase == "flee" then
			local r = gotoStep(ctx, state.target, { urgency = 0.8, tolerance = 4 })
			return if r == "running" then "running" else "success"
		end
		if state.reaction == "stopFace" or state.reaction == "faceBack" then
			local target = ctx.entity(state.subject)
			if target then
				face(ctx, target.position, 10)
			end
			hold(ctx)
		elseif state.reaction == "jumpSpin" and ctx.shiftLock then
			ctx.emit({ kind = "face", yaw = NavMath.yawOf(ctx.me.heading) + math.pi })
		end
		return if ctx.now >= state.until_ then "success" else "running"
	end,
	stop = function() end,
}

-- Leave: maybe say bye, then vanish.
registry.Leave = {
	name = "Leave",
	hasTrip = false,
	start = function(ctx, _)
		local p = ctx.persona
		local rng = ctx.rng
		local state = { until_ = ctx.now }
		if rng:chance(0.15 * (0.5 + p.chattiness * 2)) then
			ctx.act({ kind = "forceLine", category = "leaving" })
			state.until_ = ctx.now + rng:logNormalClamped(10, 0.6, 5, 30)
		end
		return state
	end,
	tick = function(ctx, state)
		hold(ctx)
		if ctx.now >= state.until_ then
			ctx.act({ kind = "leave" })
			return "success"
		end
		return "running"
	end,
	stop = function() end,
}

Activities.registry = registry

function Activities.get(name: string): Activity?
	return registry[name]
end

function Activities.list(): { string }
	local names = {}
	for name in registry do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return Activities

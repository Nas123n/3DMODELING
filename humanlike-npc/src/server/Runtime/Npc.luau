--!strict
-- One NPC end to end, as the wiring between the pure pieces: the perception adapter feeds the
-- senses, the senses feed the brain, the brain's intent goes to Nav/Locomotion (path requests,
-- the follower, stuck detection, recovery, steering, timed steps and freezes), the humanizer and
-- the optional mimic sampler shape the command, and the body adapter applies it. Chat, emotes,
-- typing, seats and the leave and reset stories go out through the presenter. It owns the
-- per-NPC policies the pieces cannot: the far-tier conversion of a walk into `moveTo`, camera
-- glances, the reset budget (three per session, the fourth leaves), the short ritual after a body
-- swap, the forced-goal test seam, and the event strings a Report carries. It is not the
-- locomotion state machine (Locomotion), not the mind (Brain) and not the service that schedules
-- and contains it (NpcService): nothing here catches errors, they propagate to the owner. Pure:
-- time is injected, every draw comes from forks of the seed it is given in a fixed order, and
-- every adapter is a table, so the whole loop runs under Lune with fake bodies.
-- requires: Activities, Brain, Humanizer, Locomotion, Memory, MimicSampler, NavMath, PathPlanner, Ports, Rng,
-- Senses, TraceBank, Types

local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)
local Ports = require(script.Parent.Parent.Ports)
local NavMath = require(script.Parent.Parent.Nav.NavMath)
local PathPlanner = require(script.Parent.Parent.Nav.PathPlanner)
local Locomotion = require(script.Parent.Parent.Nav.Locomotion)
local Humanizer = require(script.Parent.Parent.Human.Humanizer)
local Brain = require(script.Parent.Parent.Mind.Brain)
local Senses = require(script.Parent.Parent.Mind.Senses)
local Activities = require(script.Parent.Parent.Mind.Activities)
local Memory = require(script.Parent.Parent.Mind.Memory)
local MimicSampler = require(script.Parent.Parent.Mimic.MimicSampler)
local TraceBank = require(script.Parent.Parent.Mimic.TraceBank)

type Rng = Rng.Rng
type BodyState = Types.BodyState
type MoveCommand = Types.MoveCommand
type Intent = Activities.Intent
type Action = Activities.Action

local Npc = {}
Npc.__index = Npc

export type Identity = Types.Identity

-- The body: read its state, apply a command, place it (spawn and reset only), probe walls.
export type Mover = Ports.Mover

-- Presentation: chat, emotes, typing, seats, and what the game does when an NPC leaves or resets.
export type Presenter = Ports.Presenter

-- What the world looks like from here: entities near me, chats heard, groups, POIs, navigation queries.
export type Perception = Ports.Perception

-- The shared chat plumbing (Overlays.ChatShared, typed structurally so this module does not require
-- Overlays): the recency tracker, the safety gate, the server-wide allow closure and, when the
-- service has one, the ChatGuard.
export type ChatShared = {
	recency: any,
	safety: any,
	allow: (npcId: string, now: number) -> boolean,
	guard: any?,
}

export type Deps = {
	mover: Mover,
	presenter: Presenter,
	perception: Perception,
	planner: PathPlanner.Planner,
	chat: ChatShared,
	agentParams: { canJump: boolean }?,
	killY: number?, -- below this height the body has left the world; default -500
	mimic: MimicSampler.Sampler?, -- when set, near-tier move commands are shaped toward the crowd's speeds
	traces: TraceBank.Bank?, -- when set, an idle near-tier NPC now and then replays a learned fragment
	customWaypoint: ((label: string?, position: Vector3) -> number?)?, -- seconds to hold at a Custom waypoint
	poiWord: string?, -- a fixed {poi} word for the talk overlay; else the nearest POI's word or kind
}

export type Report = {
	command: MoveCommand,
	position: Vector3,
	remaining: number,
	humanizerBusy: boolean,
	intent: string,
	activity: string?,
	target: string?,
	mood: string,
	phase: string,
	locomotion: string, -- "idle" | "planning" | "walking" | "arrived" | "failed" | "dead"
	recoveryLevel: number,
	events: { string },
	-- additive
	tier: Types.Tier?,
	typing: boolean?,
	sitting: string?, -- the seat id while seated
	resetsUsed: number?,
	brainRan: boolean?,
}

export type NpcT = typeof(setmetatable(
	{} :: {
		id: string,
		entityId: string, -- "n:<id>", how the spatial index knows this NPC
		identity: Identity,
		persona: any,
		rng: Rng,
		deps: Deps,
		brain: Brain.BrainT,
		senses: any, -- Senses.Senses; a test may swap in a scripted one
		humanizer: Humanizer.HumanizerT,
		loco: Locomotion.LocomotionT,
		mimicRng: Rng,
		glanceRng: Rng,
		brainCounter: number,
		lastBody: BodyState?,
		lastCommand: MoveCommand?,
		emoteUntil: number,
		leaving: boolean,
		lastTickAt: number,
		tier: string,
		distanceWalked: number,
		lastVelocity: Vector3?,
		velocityJump: number?,
		lastThinkAt: number?,
		lastRemaining: number?,
		lastLocomotion: string,
		resetsUsed: number,
		dead: boolean, -- the body is gone until the adapter's rebind
		typing: boolean,
		sitting: string?,
		poiWordOverride: string?,
		ritualUntil: number, -- the short hold after a body swap
		forcedGoal: Vector3?, -- test seam: a goto that bypasses the brain until arrival
		humanizedTrip: number, -- the last tripId handed to the humanizer
		farPoint: Vector3?, -- the moveTo point issued in a far tier
		farIssuedAt: number,
		pendingEvents: { string }, -- events raised between ticks (onSystemEvent), reported by the next tick
		fragment: TraceBank.Fragment?, -- a learned fragment being replayed while idle
		fragmentIndex: number,
		fragmentStepAt: number,
		fragmentYaw: number,
	},
	Npc
))

local STOP: MoveCommand = { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }

local KILL_Y_DEFAULT = -500
local FAR_MOVE_TO_MAX = 16 -- studs: the moveTo point lies at most this far along the walk
local FAR_REISSUE = 6 -- seconds: a far moveTo is re-issued at least this often (the engine's timeout is 8)
local GLANCE_RANGE = 20 -- studs: a seen or jumping entity closer than this may draw a camera glance
local GLANCE_CHANCE = 0.5
local GLANCE_CHANCE_SOCIAL = 0.7 -- sociability > 0.6
local GLANCE_SOCIABILITY = 0.6
local MAX_RESETS = 3 -- per session; the next reset makes the NPC leave instead
local RITUAL_MEDIAN, RITUAL_SPREAD, RITUAL_LO, RITUAL_HI = 1, 0.4, 0.5, 2 -- the hold after a body swap
local LOOKAHEAD_NEWCOMER = 2 -- studs less follower lookahead when familiarity < 0.3
local FAMILIARITY_NEWCOMER = 0.3
local FRAGMENT_CHANCE = 0.05 -- per brain step while idle in the near tier, with a trace bank

local function stop(): MoveCommand
	return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
end

local function isQuiet(tier: string): boolean
	return tier == "far" or tier == "dormant"
end

local function isKeyboard(persona: any): boolean
	local profile = persona.profile
	local kind = if profile then profile.kind else nil
	return kind == "pc" or kind == "pcShiftLock"
end

function Npc.new(identity: Identity, persona: any, seed: Rng, deps: Deps, now: number, favoritePoiKind: string?): NpcT
	local rng = seed:fork("npc:" .. identity.id)
	-- Fixed fork order (Appendix A): brain, senses, human, recovery, steer, loco, mimic, glance.
	local brain = Brain.new(rng:fork("brain"), persona, now, favoritePoiKind)
	local senses = Senses.new(rng:fork("senses"), persona)
	local humanizer =
		Humanizer.new(rng:fork("human"), persona.profile, persona, { walkableCheck = deps.perception.walkableCheck })
	local recoveryRng = rng:fork("recovery")
	local steerRng = rng:fork("steer")
	local familiarity: number = persona.familiarity or 1
	local lookahead: number = persona.profile.lookahead
	if familiarity < FAMILIARITY_NEWCOMER then
		lookahead = math.max(2, lookahead - LOOKAHEAD_NEWCOMER)
	end
	-- The closures read `deps` at call time, so a rebind (which swaps deps.mover) reaches them.
	local locoDeps: Locomotion.Deps = {
		planner = deps.planner,
		losCheck = deps.perception.losCheck,
		probe = function(position: Vector3, forward: Vector3): (number?, number?)
			local mover = deps.mover
			local probe = mover.probe
			if probe then
				return probe(mover, position, forward)
			end
			return nil, nil
		end,
		entity = function(id: string): Types.AgentView?
			return deps.perception:entity(id)
		end,
		agentId = identity.id,
		canJump = if deps.agentParams then deps.agentParams.canJump else true,
		lookahead = lookahead,
		killY = deps.killY or KILL_Y_DEFAULT,
		customWaypoint = deps.customWaypoint,
	}
	local loco = Locomotion.new(rng:fork("loco"), locoDeps, {
		stuckAfter = 0.8 + 0.7 * persona.patience,
		personalSpace = 0.5 + 1.5 * (1 - persona.trolliness),
		ignoreChance = 0.5 + 0.3 * persona.trolliness,
		jumpShare = 0.7 + 0.15 * persona.impulsivity,
		pushOnlyBlocking = true,
		recoveryRng = recoveryRng,
		steerRng = steerRng,
	}, now)
	local mimicRng = rng:fork("mimic")
	local glanceRng = rng:fork("glance")
	local self = setmetatable({
		id = identity.id,
		entityId = "n:" .. identity.id,
		identity = identity,
		persona = persona,
		rng = rng,
		deps = deps,
		brain = brain,
		senses = senses,
		humanizer = humanizer,
		loco = loco,
		mimicRng = mimicRng,
		glanceRng = glanceRng,
		brainCounter = 0,
		lastBody = nil,
		lastCommand = nil,
		emoteUntil = -math.huge,
		leaving = false,
		lastTickAt = now,
		tier = "near",
		distanceWalked = 0,
		lastVelocity = nil,
		velocityJump = nil,
		lastThinkAt = nil,
		lastRemaining = nil,
		lastLocomotion = "idle",
		resetsUsed = 0,
		dead = false,
		typing = false,
		sitting = nil,
		poiWordOverride = nil,
		ritualUntil = -math.huge,
		forcedGoal = nil,
		humanizedTrip = 0,
		farPoint = nil,
		farIssuedAt = -math.huge,
		pendingEvents = {},
		fragment = nil,
		fragmentIndex = 1,
		fragmentStepAt = -math.huge,
		fragmentYaw = 0,
	}, Npc)
	return self
end

function Npc.setTier(self: NpcT, tier: string)
	if tier ~= self.tier then
		self.farPoint = nil
	end
	self.tier = tier
	self.humanizer:setTier(tier)
end

-- A fixed {poi} word for the talk overlay (nil: back to the nearest POI's word or kind).
function Npc.setPoiWord(self: NpcT, word: string?)
	self.poiWordOverride = word
end

-- Hands a freshly started trip to the humanizer (once per tripId).
local function humanizeNewTrip(self: NpcT, now: number)
	local loco = self.loco
	local follower = loco.follower
	if follower and loco.tripId ~= self.humanizedTrip then
		self.humanizedTrip = loco.tripId
		self.humanizer:beginTrip(follower, now, loco.tripId)
	end
end

-- A completion from the planner (the service routes them by agent id).
function Npc.onPathResult(self: NpcT, completion: PathPlanner.Completion, now: number)
	if self.dead then
		return
	end
	self.loco:onPathResult(completion, now)
	humanizeNewTrip(self, now)
end

-- The engine reported the path blocked at a waypoint (Path.Blocked): true when locomotion re-requested.
function Npc.onBlocked(self: NpcT, blockedIndex: number, now: number): boolean
	if self.dead then
		return false
	end
	return self.loco:onBlocked(blockedIndex, now)
end

-- Something happened to the body or the session that the brain must know (stuck, fell, flung,
-- goalInvalid, avoidExit, nameCollision, serverClosing, kicked, gameEvent). A goal that turned
-- invalid also ends the trip toward it at once.
function Npc.onSystemEvent(self: NpcT, kind: string, now: number, position: Vector3?, data: any?)
	self.brain:onSystemEvent(kind, now, position, data)
	if kind == "goalInvalid" then
		local loco = self.loco
		if loco.follower ~= nil or loco.requestId ~= nil then
			loco:cancel("goalInvalid", now)
		end
		self.forcedGoal = nil
	elseif kind == "avoidExit" then
		table.insert(self.pendingEvents, "avoidExit")
	end
end

-- Test seam: walk to `position` regardless of what the brain wants, until the trip ends.
function Npc.forceGoal(self: NpcT, position: Vector3, now: number)
	self.forcedGoal = position
	local body = self.lastBody
	if body and not self.dead and now >= self.ritualUntil then
		self.loco:setIntent({ kind = "goto", position = position, urgency = 0.9, tolerance = 2 }, body, now)
		humanizeNewTrip(self, now)
	end
end

-- The adapter's fresh body after a reset or a respawn: locomotion starts over and the NPC stands
-- still for a short ritual before its next trip.
function Npc.rebind(self: NpcT, mover: Mover, now: number)
	self.deps.mover = mover
	self.dead = false
	self.lastBody = nil
	self.lastVelocity = nil
	self.velocityJump = nil
	self.lastCommand = nil
	self.lastRemaining = nil
	self.farPoint = nil
	self.fragment = nil
	self.emoteUntil = -math.huge
	self.loco:reset(now)
	self.lastLocomotion = "idle"
	self.ritualUntil = now + self.rng:logNormalClamped(RITUAL_MEDIAN, RITUAL_SPREAD, RITUAL_LO, RITUAL_HI)
end

-- The word for {poi} lines: the override, the fixed dep, else the nearest POI the NPC stands at.
local function poiWordFor(self: NpcT, position: Vector3): string?
	if self.poiWordOverride then
		return self.poiWordOverride
	end
	if self.deps.poiWord then
		return self.deps.poiWord
	end
	local world: any = self.deps.perception.world
	local pois = if world then world.pois else nil
	if type(pois) ~= "table" then
		return nil
	end
	local best: any = nil
	local bestDistance = math.huge
	for _, poi in pois do
		local d = NavMath.flatDistance(poi.position, position)
		if d <= (poi.radius or 6) and d < bestDistance then
			best, bestDistance = poi, d
		end
	end
	if best then
		return best.word or best.kind
	end
	return nil
end

-- Camera glances (keyboard profiles only): a seen or jumping entity within range draws a short
-- look toward it, which the camera model turns into a small route wobble.
local function glances(self: NpcT, events: { any }, body: BodyState, now: number)
	if not isKeyboard(self.persona) then
		return
	end
	local p = if (self.persona.sociability or 0) > GLANCE_SOCIABILITY then GLANCE_CHANCE_SOCIAL else GLANCE_CHANCE
	for _, e in events do
		local kind = e.kind
		if kind ~= "entityAppeared" and kind ~= "seen" and kind ~= "entityJumped" and kind ~= "jumpSeen" then
			continue
		end
		local data = e.data
		local at: Vector3? = if type(data) == "table" then data.position else nil
		if not at then
			continue
		end
		local distance: number = if type(data) == "table" and type(data.distance) == "number"
			then data.distance
			else NavMath.flatDistance(at :: Vector3, body.position)
		if distance > GLANCE_RANGE then
			continue
		end
		if self.glanceRng:chance(p) then
			self.humanizer:lookAt(at :: Vector3, body.position, now + self.glanceRng:range(0.3, 1))
		end
	end
end

-- Builds the brain's world view from the perception adapter and the senses, and steps the brain.
-- Far and dormant NPCs skip the snapshot and the senses: nobody is close enough to be noticed.
local function think(
	self: NpcT,
	body: BodyState,
	now: number,
	dt: number,
	moving: boolean,
	quiet: boolean
): Brain.Output
	local perception = self.deps.perception
	local heading = NavMath.dirFromYaw(body.yaw)
	local events: { any } = {}
	local entities: { any } = {}
	local visible: { [string]: boolean } = {}
	local groups: { any } = {}
	local playersWithin30, playersWithin100 = 0, 0
	if not quiet then
		local snap = perception:snapshot(self.id, body.position, 100)
		groups = perception:groups()
		events = self.senses:step({
			me = {
				id = self.entityId,
				position = body.position,
				heading = heading,
				moving = moving,
				velocity = body.velocity,
			},
			entities = snap.entities,
			chats = snap.chats,
			groups = groups,
			now = now,
			dt = dt,
			occlusion = perception.occlusion,
			raycastBudget = 8,
			locomotion = { blockedBy = self.loco.lastSteerBlockedBy, velocityJump = self.velocityJump },
		}, self.brain.memory, self.brain.guard.attachment)
		glances(self, events, body, now)
		for _, e in snap.entities do
			local record = self.brain.memory.entities[e.id]
			if record and record.lastSeenVisibleAt and now - record.lastSeenVisibleAt < 1 then
				visible[e.id] = true
			end
		end
		entities = table.clone(snap.entities)
		table.sort(entities, function(a, b)
			return NavMath.flatDistance(a.position, body.position) < NavMath.flatDistance(b.position, body.position)
		end)
		playersWithin30 = perception:playersWithin(body.position, 30)
		playersWithin100 = perception:playersWithin(body.position, 100)
	end
	local world: any = table.clone(perception.world :: any)
	world.entities = entities
	world.visible = visible
	world.groups = groups
	return self.brain:step({
		now = now,
		dt = dt,
		me = {
			id = self.id,
			position = body.position,
			heading = heading,
			displayName = self.identity.displayName,
			username = self.identity.username,
		},
		locomotion = self.loco:brainView(body),
		world = world,
		entity = function(id)
			return perception:entity(id)
		end,
		groupOf = function(id)
			return perception:groupOf(id)
		end,
		events = events,
		playersWithin30 = playersWithin30,
		playersWithin100 = playersWithin100,
		chat = self.deps.chat,
		fellNearby = false,
		tier = self.tier,
		poiWord = poiWordFor(self, body.position),
	})
end

-- Carries out the brain's actions through the presenter.
local function runActions(self: NpcT, actions: { Action }, now: number, events: { string })
	local presenter = self.deps.presenter
	for _, a in actions do
		local kind = a.kind
		if kind == "say" and a.text then
			presenter:say(self.id, a.text, a.target)
		elseif kind == "emote" then
			presenter:emote(self.id, a.name, a.cutAfter)
			self.emoteUntil = now + (a.cutAfter or 3)
		elseif kind == "leave" then
			self.leaving = true
			presenter:leave(self.id, "session")
		elseif kind == "leaveServer" then
			self.brain:leaveNow()
		elseif kind == "typing" then
			local on = a.on == true
			self.typing = on
			local setTyping = presenter.setTyping
			if setTyping then
				setTyping(presenter, self.id, on)
			end
		elseif kind == "sit" then
			self.sitting = a.target
			local seat = presenter.seat
			if seat then
				seat(presenter, self.id, a.target)
			end
		elseif kind == "look" and a.name then
			table.insert(events, a.name)
		end
	end
end

-- The reset story: the adapter destroys the body and rebinds a fresh one later; after the third
-- reset of a session the NPC leaves instead (a player who keeps dying logs off).
local function onReset(self: NpcT, body: BodyState, now: number)
	self.resetsUsed += 1
	self.forcedGoal = nil
	self.farPoint = nil
	self.fragment = nil
	self.brain:onSystemEvent("stuck", now, body.position)
	if self.resetsUsed > MAX_RESETS then
		self.brain:leaveNow()
		self.leaving = true
		self.deps.presenter:leave(self.id, "reset")
		return
	end
	local presenter = self.deps.presenter
	local reset = presenter.reset
	if reset then
		self.dead = true
		reset(presenter, self.id)
	else
		-- No adapter to respawn the body: it stays what it is and locomotion simply starts over.
		self.loco:reset(now)
		self.ritualUntil = now + self.rng:logNormalClamped(RITUAL_MEDIAN, RITUAL_SPREAD, RITUAL_LO, RITUAL_HI)
	end
end

-- Locomotion events become report strings; some also reach the brain, the humanizer or the reset story.
local function handleLocomotionEvents(
	self: NpcT,
	out: Locomotion.Output,
	body: BodyState,
	now: number,
	events: { string }
)
	for _, e in out.events do
		local kind = e.kind
		if kind == "stuck" then
			table.insert(events, `stuck:{e.level or 0}`)
		elseif kind == "jumpFailed" then
			table.insert(events, `jumpFailed:{e.label or "?"}`)
		else
			table.insert(events, kind)
		end
		if kind == "tripStarted" then
			humanizeNewTrip(self, now)
		elseif kind == "abandon" then
			self.forcedGoal = nil
			self.brain:onSystemEvent("stuck", now, body.position)
		elseif kind == "fell" then
			self.brain:onSystemEvent("fell", now, body.position)
		elseif kind == "flung" then
			self.forcedGoal = nil
			self.brain:onSystemEvent("flung", now, body.position)
		elseif kind == "arrived" or kind == "pathFailed" or kind == "goalInvalid" or kind == "changedMind" then
			self.forcedGoal = nil
		elseif kind == "reset" then
			onReset(self, body, now)
		end
	end
end

-- The stuck verdict in the humanizer's vocabulary.
local function humanizerVerdict(verdict: string): any
	if verdict == "ok" then
		return "ok"
	elseif verdict == "pushing" or verdict == "wallCapped" then
		return "pushing"
	end
	return "stuck"
end

-- Replays a learned movement fragment while the NPC idles in the near tier (Mimic/TraceBank):
-- the fragment's per-tick directions replace the (stopped) command for its duration.
local function playFragment(self: NpcT, command: MoveCommand, body: BodyState, now: number, idle: boolean): MoveCommand
	local bank = self.deps.traces
	if not bank or self.tier ~= "near" then
		self.fragment = nil
		return command
	end
	if command.mode ~= "stop" or not idle or not body.onGround then
		self.fragment = nil
		return command
	end
	local fragment = self.fragment
	if fragment then
		local step = fragment.steps[self.fragmentIndex]
		if step and now - self.fragmentStepAt >= step.dt then
			self.fragmentIndex += 1
			self.fragmentStepAt = now
			step = fragment.steps[self.fragmentIndex]
		end
		if not step then
			self.fragment = nil
			return command
		end
		local played = TraceBank.play(fragment, self.fragmentYaw, self.fragmentIndex)
		played.facingYaw = command.facingYaw
		return played
	end
	return command
end

-- Maybe starts a fragment on a brain step (one draw per idle near-tier step with a bank).
local function maybeStartFragment(self: NpcT, out: Brain.Output, body: BodyState, now: number)
	local bank = self.deps.traces
	if not bank or self.tier ~= "near" or self.fragment ~= nil then
		return
	end
	if out.intent.kind ~= "hold" or out.activity ~= "IdleStand" or self.loco:status() ~= "idle" then
		return
	end
	if not self.mimicRng:chance(FRAGMENT_CHANCE) then
		return
	end
	local fragment = bank:pick(self.mimicRng)
	if fragment then
		self.fragment = fragment
		self.fragmentIndex = 1
		self.fragmentStepAt = now
		self.fragmentYaw = body.yaw
	end
end

-- The point a far NPC walks to by moveTo: the farthest waypoint of the current path within
-- FAR_MOVE_TO_MAX studs that the body has a line of walk to (the follower's own lookahead rule
-- with a longer reach), the final target on the last leg; without a path (a recovery step, a
-- timed step) a short way along the command's direction.
local function farTarget(self: NpcT, command: MoveCommand, body: BodyState): Vector3
	local follower = self.loco.follower
	local los = self.deps.perception.losCheck
	if follower and not follower.finished then
		local waypoints = follower.waypoints
		local n = #waypoints
		local index = math.min(follower.nextIndex, n)
		local best = waypoints[index].position
		for k = index + 1, n do
			local previous = waypoints[k - 1]
			local w = waypoints[k]
			if previous.action ~= "Walk" or math.abs(w.position.Y - previous.position.Y) > follower.stepHeight then
				break
			end
			if NavMath.flatDistance(body.position, w.position) > FAR_MOVE_TO_MAX then
				break
			end
			if los and not los(body.position, w.position) then
				break
			end
			index, best = k, w.position
		end
		if index == n then
			best = follower.finalTarget
		end
		return best
	end
	local lookahead: number = self.persona.profile.lookahead or 6
	return body.position + command.dir * math.clamp(lookahead, 1, FAR_MOVE_TO_MAX)
end

-- Far and dormant tiers: a walk becomes a `moveTo` toward a point along it, re-issued when the
-- body reports it finished or every few seconds; the engine walks the body between ticks.
local function toMoveTo(self: NpcT, command: MoveCommand, body: BodyState, now: number): MoveCommand
	if command.mode ~= "move" then
		self.farPoint = nil
		return command
	end
	local point = self.farPoint
	if point == nil or body.moveToFinished == true or now - self.farIssuedAt >= FAR_REISSUE then
		point = farTarget(self, command, body)
		self.farPoint = point
		self.farIssuedAt = now
	end
	return {
		mode = "moveTo",
		dir = command.dir,
		magnitude = command.magnitude,
		moveToPoint = point,
		jump = command.jump,
		facingYaw = command.facingYaw,
	}
end

-- One scheduler tick. `runBrain` is true every Nth tick (the scheduler's brain divisor).
function Npc.tick(self: NpcT, now: number, runBrain: boolean): Report
	local dt = math.max(0, now - self.lastTickAt)
	self.lastTickAt = now
	local eventsOut = self.pendingEvents
	self.pendingEvents = {}
	if self.dead then
		-- The body is gone until the adapter rebinds a fresh one: nothing to read, nothing to drive.
		self.lastLocomotion = "dead"
		return self:report(stop(), "-", eventsOut, false)
	end
	local body = self.deps.mover:read()
	self.lastBody = body
	local moving = NavMath.flat(body.velocity).Magnitude > 1
	local quiet = isQuiet(self.tier)

	-- Velocity jumps (bumps) for the senses.
	if self.lastVelocity then
		local change = (NavMath.flat(body.velocity) - NavMath.flat(self.lastVelocity :: Vector3)).Magnitude
		self.velocityJump = if change > 6 and body.onGround then change else nil
	end
	self.lastVelocity = body.velocity

	-- 1. Senses and brain, then the intent to locomotion and the actions to the presenter.
	local brainOut: Brain.Output? = nil
	if runBrain then
		self.brainCounter += 1
		local thinkDt = if self.lastThinkAt then now - self.lastThinkAt else dt
		self.lastThinkAt = now
		local out = think(self, body, now, thinkDt, moving, quiet)
		brainOut = out
		local intent: Intent = out.intent
		local forced = self.forcedGoal
		if out.changedMind and not forced then
			self.loco:cancel("changedMind", now)
		end
		if forced then
			intent = { kind = "goto", position = forced, urgency = 0.9, tolerance = 2 }
		end
		if now < self.ritualUntil then
			intent = { kind = "hold" }
		end
		self.loco:setIntent(intent, body, now)
		humanizeNewTrip(self, now)
		runActions(self, out.actions, now, eventsOut)
		maybeStartFragment(self, out, body, now)
	end
	if self.leaving then
		self.deps.mover:apply(stop())
		self.lastCommand = stop()
		return self:report(stop(), "leave", eventsOut, brainOut ~= nil)
	end

	-- 2. Locomotion: the follower, stuck detection, recovery, steering, timed intents. Steering
	-- wants the neighbours within 8 studs whenever a move command is possible (not while idle).
	local neighbors: { Types.AgentView } = {}
	if not quiet and (self.loco:status() ~= "idle" or now < self.loco.stepUntil) then
		neighbors = self.deps.perception:snapshot(self.id, body.position, 8).entities
	end
	local out = self.loco:tick(body, neighbors, now, dt, self.humanizer:suppressUntil())
	local command = out.command
	self.lastRemaining = out.remaining
	handleLocomotionEvents(self, out, body, now, eventsOut)
	if self.dead then
		self.lastLocomotion = "dead"
		return self:report(stop(), if brainOut then brainOut.intent.kind else "-", eventsOut, brainOut ~= nil)
	end
	if self.leaving then
		self.deps.mover:apply(stop())
		self.lastCommand = stop()
		return self:report(stop(), "leave", eventsOut, brainOut ~= nil)
	end

	-- 3. Humanization of the trip command (input-profile noise and trip decoration).
	if out.humanize then
		local humanized = self.humanizer:apply({
			command = command,
			body = body,
			now = now,
			dt = dt,
			followerEvents = out.followerEvents,
			stuckVerdict = humanizerVerdict(out.verdict),
		})
		command = humanized.command
		for _, e in humanized.events do
			table.insert(eventsOut, e.kind)
		end
		if humanized.abandonTrip then
			self.loco:cancel("goalInvalid", now)
			self.forcedGoal = nil
			self.brain:onSystemEvent("goalInvalid", now, nil)
		end
	end

	-- 4. Mimic shaping toward the crowd's speeds (near tier only), or an idle fragment replay.
	local mimic = self.deps.mimic
	if mimic and self.tier == "near" and command.mode == "move" then
		command = mimic:shape(command, { rng = self.mimicRng, moving = moving, profileMagnitude = command.magnitude })
	end
	if self.deps.traces then
		local idle = self.loco:status() == "idle" and now >= self.loco.stepUntil
		command = playFragment(self, command, body, now, idle)
	end

	-- 5. Jump and facing requests survive whatever replaced the command.
	local base = out.command
	if base.jump and not command.jump then
		command = table.clone(command)
		command.jump = true
	end
	if base.facingYaw and command.mode ~= "move" and command.facingYaw == nil then
		command = table.clone(command)
		command.facingYaw = base.facingYaw
	end

	-- 6. Far tiers walk by moveTo.
	if quiet then
		command = toMoveTo(self, command, body, now)
	end

	-- 7. Emotes are cancelled by movement.
	if command.mode ~= "stop" and now < self.emoteUntil then
		self.deps.presenter:emote(self.id, nil, nil)
		self.emoteUntil = -math.huge
	end

	self.deps.mover:apply(command)
	self.lastCommand = command
	if command.mode == "move" then
		self.distanceWalked += body.walkSpeed * command.magnitude * dt
	end
	self.lastLocomotion = self.loco:brainView(body).status
	return self:report(command, if brainOut then brainOut.intent.kind else "-", eventsOut, brainOut ~= nil)
end

function Npc.report(self: NpcT, command: MoveCommand, intent: string, events: { string }, brainRan: boolean?): Report
	local d = self.brain:describe()
	local body = self.lastBody
	return {
		command = command,
		position = if body then body.position else Vector3.zero,
		remaining = self.lastRemaining or 0,
		humanizerBusy = self.humanizer:isBusy(),
		intent = intent,
		activity = d.activity,
		target = d.target,
		mood = d.mood,
		phase = d.phase,
		locomotion = self.lastLocomotion,
		recoveryLevel = self.loco:describe().level,
		events = events,
		tier = self.tier,
		typing = self.typing,
		sitting = self.sitting,
		resetsUsed = self.resetsUsed,
		brainRan = brainRan == true,
	}
end

function Npc.isLeaving(self: NpcT): boolean
	return self.leaving
end

function Npc.forceLeave(self: NpcT)
	self.brain:leaveNow()
end

function Npc.memory(self: NpcT): Memory.Memory
	return self.brain.memory
end

Npc.STOP = STOP

return Npc

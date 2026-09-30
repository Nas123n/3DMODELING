--!strict
-- One NPC end to end: senses feed the brain, the brain's intent becomes a path request or a
-- direct move, the follower walks the path while the stuck detector, the recovery ladder, local
-- steering and the humanizer shape every command, and the body adapter applies it. Chat and
-- emotes go out through the presenter. Everything here is pure; the adapters (mover, presenter,
-- perception) are injected, so the whole loop runs under Lune with fake bodies.

local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)
local NavMath = require(script.Parent.Parent.Nav.NavMath)
local WaypointFollower = require(script.Parent.Parent.Nav.WaypointFollower)
local StuckDetector = require(script.Parent.Parent.Nav.StuckDetector)
local Recovery = require(script.Parent.Parent.Nav.Recovery)
local Steering = require(script.Parent.Parent.Nav.Steering)
local PathPlanner = require(script.Parent.Parent.Nav.PathPlanner)
local Humanizer = require(script.Parent.Parent.Human.Humanizer)
local Brain = require(script.Parent.Parent.Mind.Brain)
local Senses = require(script.Parent.Parent.Mind.Senses)
local Activities = require(script.Parent.Parent.Mind.Activities)
local Memory = require(script.Parent.Parent.Mind.Memory)

type Rng = Rng.Rng
type BodyState = Types.BodyState
type MoveCommand = Types.MoveCommand
type Intent = Activities.Intent
type Action = Activities.Action

local Npc = {}
Npc.__index = Npc

export type Identity = { id: string, username: string, displayName: string }

-- The body: read its state, apply a command, teleport it (reset story), probe walls.
export type Mover = {
	read: (self: any) -> BodyState,
	apply: (self: any, command: MoveCommand) -> (),
	teleport: (self: any, position: Vector3) -> (),
	probe: ((self: any, position: Vector3, forward: Vector3) -> (number?, number?))?,
}

-- Presentation: chat, emotes, and what the game does when an NPC leaves.
export type Presenter = {
	say: (self: any, npcId: string, text: string, target: string?) -> (),
	emote: (self: any, npcId: string, name: string?, cutAfter: number?) -> (),
	leave: (self: any, npcId: string, reason: string) -> (),
	reset: ((self: any, npcId: string) -> ())?,
}

-- What the world looks like from here: entities near me, chats heard, groups, POIs, navigation queries.
export type Perception = {
	snapshot: (self: any, npcId: string, position: Vector3, radius: number) -> { entities: { any }, chats: { any } },
	occlusion: ((from: Vector3, to: Vector3) -> boolean)?,
	groups: (self: any) -> { any },
	groupOf: (self: any, id: string) -> any?,
	entity: (self: any, id: string) -> any?,
	world: any, -- Goals.World minus the per-NPC bits
	playersWithin: (self: any, position: Vector3, radius: number) -> number,
	walkableCheck: ((point: Vector3) -> string)?,
	losCheck: ((from: Vector3, to: Vector3) -> boolean)?,
}

export type Deps = {
	mover: Mover,
	presenter: Presenter,
	perception: Perception,
	planner: PathPlanner.Planner,
	chat: any, -- Overlays.ChatShared
	agentParams: { canJump: boolean }?,
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
	locomotion: string,
	recoveryLevel: number,
	events: { string },
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
		senses: any,
		humanizer: Humanizer.HumanizerT,
		stuck: StuckDetector.Detector,
		recovery: Recovery.Ladder,
		steering: Steering.Steerer,
		follower: WaypointFollower.Follower?,
		locomotionStatus: string, -- idle | planning | walking | arrived | failed
		goal: Vector3?,
		goalTolerance: number,
		requestId: number?,
		nextRequestId: number,
		lastPlanAt: number,
		followTarget: string?,
		followKeep: number,
		lastFollowGoal: Vector3?,
		stepUntil: number,
		stepDir: Vector3?,
		freezeUntil: number,
		freezeVariant: string,
		freezeDir: Vector3?,
		facingYaw: number?,
		jumpRequested: boolean,
		brainCounter: number,
		lastBody: BodyState?,
		lastCommand: MoveCommand?,
		tripId: number,
		emoteUntil: number,
		leaving: boolean,
		lastTickAt: number,
		tier: string,
		distanceWalked: number,
		lastVelocity: Vector3?,
		velocityJump: number?,
		lastSteerBlockedBy: string?,
		lastThinkAt: number?,
		jumpFailures: number,
		lastRemaining: number?,
	},
	Npc
))

local STOP: MoveCommand = { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }

local function stop(): MoveCommand
	return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
end

function Npc.new(identity: Identity, persona: any, seed: Rng, deps: Deps, now: number, favoritePoiKind: string?): NpcT
	local rng = seed:fork("npc:" .. identity.id)
	local self = setmetatable({
		id = identity.id,
		entityId = "n:" .. identity.id,
		identity = identity,
		persona = persona,
		rng = rng,
		deps = deps,
		brain = Brain.new(rng:fork("brain"), persona, now, favoritePoiKind),
		senses = Senses.new(rng:fork("senses"), persona),
		humanizer = Humanizer.new(
			rng:fork("human"),
			persona.profile,
			persona,
			{ walkableCheck = deps.perception.walkableCheck }
		),
		stuck = StuckDetector.new({ stuckAfter = 0.8 + 0.7 * persona.patience }),
		recovery = Recovery.new(rng:fork("recovery")),
		steering = Steering.new(rng:fork("steer"), {
			personalSpace = 0.5 + 1.5 * (1 - persona.trolliness),
			ignoreChance = 0.1 + 0.4 * persona.trolliness,
			jumpShare = 0.7 + 0.15 * persona.impulsivity,
		}),
		follower = nil,
		locomotionStatus = "idle",
		goal = nil,
		goalTolerance = 1.5,
		requestId = nil,
		nextRequestId = 1,
		lastPlanAt = -math.huge,
		followTarget = nil,
		followKeep = 3,
		lastFollowGoal = nil,
		stepUntil = -math.huge,
		stepDir = nil,
		freezeUntil = -math.huge,
		freezeVariant = "still",
		freezeDir = nil,
		facingYaw = nil,
		jumpRequested = false,
		brainCounter = 0,
		lastBody = nil,
		lastCommand = nil,
		tripId = 0,
		emoteUntil = -math.huge,
		leaving = false,
		lastTickAt = now,
		tier = "near",
		distanceWalked = 0,
		lastVelocity = nil,
		velocityJump = nil,
		lastSteerBlockedBy = nil,
		lastThinkAt = nil,
		jumpFailures = 0,
		lastRemaining = nil,
	}, Npc)
	return self
end

function Npc.setTier(self: NpcT, tier: string)
	self.tier = tier
	self.humanizer:setTier(tier)
end

-- Plans a trip to a goal (or re-plans the current one).
local function requestPath(self: NpcT, body: BodyState, goal: Vector3, now: number, priority: number)
	local id = self.nextRequestId
	self.nextRequestId += 1
	self.requestId = id
	self.goal = goal
	self.locomotionStatus = "planning"
	self.lastPlanAt = now
	local canJump = if self.deps.agentParams then self.deps.agentParams.canJump else true
	self.deps.planner:request({
		id = id,
		agentId = self.id,
		start = body.position,
		goal = goal,
		priority = priority,
		allowPartial = true,
		canJump = canJump,
		issuedAt = now,
	}, now)
end

-- A completion from the planner (the service routes them by agent id).
function Npc.onPathResult(self: NpcT, completion: PathPlanner.Completion, now: number)
	if completion.id ~= self.requestId then
		return
	end
	self.requestId = nil
	local result = completion.result
	local body = self.lastBody or self.deps.mover:read()
	if (result.status == "Success" or result.status == "Partial") and #result.waypoints > 0 then
		self.tripId += 1
		self.follower = WaypointFollower.new(result.waypoints, body.position, now, {
			lookahead = self.persona.profile.lookahead,
			losCheck = self.deps.perception.losCheck,
		})
		self.humanizer:beginTrip(self.follower :: WaypointFollower.Follower, now, self.tripId)
		self.locomotionStatus = "walking"
		self.recovery:onNewGoal(now)
		self.stuck:reset(now)
		self.recovery:onPathArrived()
	else
		self.follower = nil
		self.locomotionStatus = "failed"
		self.recovery:onPathArrived()
	end
end

local function clearTrip(self: NpcT)
	self.follower = nil
	self.requestId = nil
	self.followTarget = nil
end

-- Applies the brain's intent to the locomotion state.
local function applyIntent(self: NpcT, intent: Intent, body: BodyState, now: number)
	local kind = intent.kind
	if kind == "goto" then
		local position = intent.position :: Vector3
		self.goalTolerance = intent.tolerance or 1.5
		local same = self.goal ~= nil and NavMath.flatDistance(self.goal :: Vector3, position) < 0.5
		if not same then
			clearTrip(self)
			requestPath(self, body, position, now, if (intent.urgency or 0) >= 0.8 then 0 else 1)
		elseif self.locomotionStatus == "failed" and now - self.lastPlanAt > 3 then
			requestPath(self, body, position, now, 2)
		end
		self.followTarget = nil
	elseif kind == "follow" then
		local targetId = intent.targetId :: string
		local target = self.deps.perception:entity(targetId)
		self.followKeep = intent.keep or 3
		if not target then
			return
		end
		local behind = NavMath.flatDirection(target.position, body.position)
		if behind.Magnitude == 0 then
			behind = NavMath.dirFromYaw(target.yaw or 0) * -1
		end
		local goal = target.position + behind * self.followKeep
		local moved = self.lastFollowGoal == nil or NavMath.flatDistance(self.lastFollowGoal :: Vector3, goal) > 4
		if self.followTarget ~= targetId or (moved and now - self.lastPlanAt >= 1.5) then
			self.followTarget = targetId
			self.lastFollowGoal = goal
			local los = self.deps.perception.losCheck
			if los and los(body.position, goal) and NavMath.flatDistance(body.position, goal) < 30 then
				-- Direct line: no planner needed.
				self.follower = WaypointFollower.new({
					{ position = body.position, action = "Walk" },
					{ position = goal, action = "Walk" },
				}, body.position, now, { lookahead = 8 })
				self.goal = goal
				self.locomotionStatus = "walking"
				self.lastPlanAt = now
			else
				clearTrip(self)
				self.followTarget = targetId
				requestPath(self, body, goal, now, 1)
			end
		end
	elseif kind == "hold" then
		if self.locomotionStatus == "walking" or self.locomotionStatus == "planning" then
			clearTrip(self)
			self.locomotionStatus = "idle"
		end
	elseif kind == "step" then
		self.stepDir = intent.dir
		self.stepUntil = now + (intent.duration or 0.3)
	elseif kind == "jump" then
		self.jumpRequested = true
	elseif kind == "face" then
		self.facingYaw = intent.yaw
	elseif kind == "freeze" then
		self.freezeUntil = now + (intent.duration or 1)
		self.freezeVariant = intent.variant or "still"
		if self.freezeVariant == "walkStraight" then
			local last = self.lastCommand
			self.freezeDir = if last and last.mode == "move" then last.dir else nil
		end
		-- Typing is a deliberate stop (or a deliberate straight walk): never a stuck verdict.
		self.stuck:suppress(now, self.freezeUntil)
	end
	if (intent :: any).jump then
		self.jumpRequested = true
	end
end

-- Builds the brain's world view from the perception adapter and the senses.
local function think(self: NpcT, body: BodyState, now: number, dt: number, moving: boolean): Brain.Output
	local perception = self.deps.perception
	local snap = perception:snapshot(self.id, body.position, 100)
	local heading = NavMath.dirFromYaw(body.yaw)
	local visible: { [string]: boolean } = {}
	local events = self.senses:step({
		me = {
			id = self.entityId,
			position = body.position,
			heading = heading,
			moving = moving,
			velocity = body.velocity,
		},
		entities = snap.entities,
		chats = snap.chats,
		groups = perception:groups(),
		now = now,
		dt = dt,
		occlusion = perception.occlusion,
		raycastBudget = 8,
		locomotion = { blockedBy = self.lastSteerBlockedBy, velocityJump = self.velocityJump },
	}, self.brain.memory, self.brain.guard.attachment)
	for _, e in snap.entities do
		local record = self.brain.memory.entities[e.id]
		if record and record.lastSeenVisibleAt and now - record.lastSeenVisibleAt < 1 then
			visible[e.id] = true
		end
	end
	local sorted = table.clone(snap.entities)
	table.sort(sorted, function(a, b)
		return NavMath.flatDistance(a.position, body.position) < NavMath.flatDistance(b.position, body.position)
	end)
	local world = table.clone(perception.world)
	world.entities = sorted
	world.visible = visible
	world.groups = perception:groups()
	local groupOf = function(id)
		return perception:groupOf(id)
	end
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
		locomotion = {
			status = self.locomotionStatus,
			goal = self.goal,
			moving = moving,
			onGround = body.onGround,
			blockedBy = self.lastSteerBlockedBy,
		},
		world = world,
		entity = function(id)
			return perception:entity(id)
		end,
		groupOf = groupOf,
		events = events,
		playersWithin30 = perception:playersWithin(body.position, 30),
		playersWithin100 = perception:playersWithin(body.position, 100),
		chat = self.deps.chat,
		fellNearby = false,
	})
end

local function runActions(self: NpcT, actions: { Action }, now: number)
	local presenter = self.deps.presenter
	for _, a in actions do
		if a.kind == "say" and a.text then
			presenter:say(self.id, a.text, a.target)
		elseif a.kind == "emote" then
			presenter:emote(self.id, a.name, a.cutAfter)
			self.emoteUntil = now + (a.cutAfter or 3)
		elseif a.kind == "leave" then
			self.leaving = true
			presenter:leave(self.id, "session")
		elseif a.kind == "leaveServer" then
			self.brain:leaveNow()
		end
	end
end

-- One scheduler tick. `runBrain` is true every Nth tick (the scheduler's brain divisor).
function Npc.tick(self: NpcT, now: number, runBrain: boolean): Report
	local dt = math.max(0, now - self.lastTickAt)
	self.lastTickAt = now
	local body = self.deps.mover:read()
	self.lastBody = body
	local moving = NavMath.flat(body.velocity).Magnitude > 1
	local eventsOut: { string } = {}

	-- Velocity jumps (bumps) for the senses.
	if self.lastVelocity then
		local change = (NavMath.flat(body.velocity) - NavMath.flat(self.lastVelocity :: Vector3)).Magnitude
		self.velocityJump = if change > 6 and body.onGround then change else nil
	end
	self.lastVelocity = body.velocity

	local brainOut: Brain.Output? = nil
	if runBrain then
		self.brainCounter += 1
		local thinkDt = if self.lastThinkAt then now - self.lastThinkAt else dt
		self.lastThinkAt = now
		brainOut = think(self, body, now, thinkDt, moving)
		applyIntent(self, (brainOut :: Brain.Output).intent, body, now)
		runActions(self, (brainOut :: Brain.Output).actions, now)
	end
	if self.leaving then
		self.deps.mover:apply(stop())
		return self:report(stop(), "leave", eventsOut)
	end

	-- Base command from the trip.
	local command: MoveCommand = stop()
	local followerEvents: { WaypointFollower.Event } = {}
	local intendedSpeed = 0
	local remaining = 0
	local forward = NavMath.dirFromYaw(body.yaw)
	if self.follower and self.locomotionStatus == "walking" then
		local follower = self.follower :: WaypointFollower.Follower
		local out = follower:tick(body, now)
		followerEvents = out.events
		command = out.command
		remaining = out.remaining
		self.lastRemaining = remaining
		for _, e in out.events do
			if e.kind == "finished" then
				self.locomotionStatus = "arrived"
				self.recovery:onNewGoal(now)
				table.insert(eventsOut, "arrived")
			elseif e.kind == "waypoint" then
				self.recovery:onProgress(now, 4)
			elseif e.kind == "jumpFailed" then
				table.insert(eventsOut, "jumpFailed:" .. (e.label or "?"))
				-- First failure: simply try the jump again. Second in a row: let recovery handle it
				-- (back up and jump, then re-path with the jump penalized).
				self.jumpFailures += 1
				if self.jumpFailures <= 1 then
					follower:resume()
				else
					local level = self.recovery:onStuck(now, body, forward, "stuck")
					follower:resume()
					if level >= 2 then
						requestPath(self, body, self.goal :: Vector3, now, 0)
					end
				end
			elseif e.kind == "jumpLanded" then
				self.jumpFailures = 0
			elseif e.kind == "custom" then
				follower:resume()
			end
		end
		if command.mode == "move" then
			forward = command.dir
			intendedSpeed = body.walkSpeed * command.magnitude
		end
	end

	-- Stuck detection and recovery on trips.
	local verdict: string = "ok"
	local humanizerQuietUntil = self.humanizer:suppressUntil()
	if humanizerQuietUntil > now then
		self.stuck:suppress(now, humanizerQuietUntil)
	end
	if self.locomotionStatus == "walking" then
		verdict = self.stuck:update(body, intendedSpeed, remaining, now)
	end
	if self.recovery:isActive() then
		local action = self.recovery:tick(now)
		if action.kind == "repath" then
			if self.goal then
				requestPath(self, body, self.goal :: Vector3, now, 0)
			end
			command = stop()
		elseif action.kind == "abandon" then
			table.insert(eventsOut, "abandon")
			self.locomotionStatus = "failed"
			clearTrip(self)
			self.brain:onSystemEvent("stuck", now, body.position)
			command = stop()
		elseif action.kind == "reset" then
			table.insert(eventsOut, "reset")
			self.locomotionStatus = "failed"
			clearTrip(self)
			if self.deps.presenter.reset then
				(self.deps.presenter.reset :: any)(self.deps.presenter, self.id)
			end
			self.brain:onSystemEvent("fell", now, body.position)
			command = stop()
		elseif action.kind ~= "done" then
			command = Recovery.toCommand(action, forward)
			self.stuck:suppress(now, action.until_)
		end
	elseif verdict ~= "ok" then
		local left, right = nil, nil
		if self.deps.mover.probe then
			left, right = (self.deps.mover.probe :: any)(self.deps.mover, body.position, forward)
		end
		local level = self.recovery:onStuck(now, body, forward, verdict :: any, left, right)
		table.insert(eventsOut, `stuck:{level}`)
		self.stuck:reset(now)
		command = Recovery.toCommand(self.recovery:tick(now), forward)
	end

	-- Direct intents: timed steps, freezes.
	if now < self.stepUntil and self.stepDir then
		command = { mode = "move", dir = self.stepDir :: Vector3, magnitude = 1, jump = false }
	end
	if now < self.freezeUntil then
		if self.freezeVariant == "walkStraight" and self.freezeDir then
			command = { mode = "move", dir = self.freezeDir :: Vector3, magnitude = 1, jump = false }
		else
			command = stop()
		end
	end

	-- Local avoidance of other characters (not while frozen: a typist does not dodge).
	if command.mode == "move" and now >= self.freezeUntil then
		local snap = self.deps.perception:snapshot(self.id, body.position, 8)
		local steered = self.steering:adjust({
			dir = command.dir,
			magnitude = command.magnitude,
			position = body.position,
			velocity = body.velocity,
			neighbors = snap.entities,
			now = now,
		})
		command.dir = steered.dir
		command.magnitude = steered.magnitude
		self.lastSteerBlockedBy = steered.blockedBy
		if steered.wantsJump then
			self.jumpRequested = true
		end
	else
		self.lastSteerBlockedBy = nil
	end

	-- Humanization of the trip command (freezes and recovery pass through mostly untouched).
	if self.locomotionStatus == "walking" and not self.recovery:isActive() and now >= self.freezeUntil then
		local humanized = self.humanizer:apply({
			command = command,
			body = body,
			now = now,
			dt = dt,
			followerEvents = followerEvents,
			stuckVerdict = verdict :: any,
		})
		command = humanized.command
		for _, e in humanized.events do
			table.insert(eventsOut, e.kind)
		end
		if humanized.abandonTrip then
			clearTrip(self)
			self.locomotionStatus = "failed"
			self.brain:onSystemEvent("goalInvalid", now, nil)
		end
	end

	if self.jumpRequested and body.onGround then
		command = table.clone(command)
		command.jump = true
	end
	self.jumpRequested = false
	if self.facingYaw and command.mode ~= "move" then
		command = table.clone(command)
		command.facingYaw = self.facingYaw
		self.facingYaw = nil
	elseif self.facingYaw then
		self.facingYaw = nil
	end

	-- Emotes are cancelled by movement.
	if command.mode == "move" and now < self.emoteUntil then
		self.deps.presenter:emote(self.id, nil, nil)
		self.emoteUntil = -math.huge
	end

	self.deps.mover:apply(command)
	self.lastCommand = command
	if command.mode == "move" then
		self.distanceWalked += body.walkSpeed * command.magnitude * dt
	end
	return self:report(command, if brainOut then brainOut.intent.kind else "-", eventsOut)
end

function Npc.report(self: NpcT, command: MoveCommand, intent: string, events: { string }): Report
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
		locomotion = self.locomotionStatus,
		recoveryLevel = self.recovery:currentLevel(),
		events = events,
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

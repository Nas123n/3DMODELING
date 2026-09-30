--!strict
-- The per-NPC locomotion state machine: one intent from the brain (goto, follow, hold, step, face,
-- jump, freeze) plus one body state in, one MoveCommand out per tick. It owns the waypoint
-- follower, the stuck detector, the recovery ladder, local steering, the timed direct intents,
-- the path requests to the planner, the fall and flung rules and the kill plane, and reports what
-- happened as events (arrived, abandon, changedMind, ...) for its owner to forward. It is not the
-- brain, not the humanizer and not the mover: it knows nothing about chat, tiers or personas, and
-- the owner (Runtime/Npc) wires senses -> brain -> setIntent -> tick -> humanizer -> mover. Pure:
-- time is injected, every draw comes from the Rng it is given, the body is a table.

local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)
local Activities = require(script.Parent.Parent.Mind.Activities)
local NavMath = require(script.Parent.NavMath)
local WaypointFollower = require(script.Parent.WaypointFollower)
local StuckDetector = require(script.Parent.StuckDetector)
local Recovery = require(script.Parent.Recovery)
local Steering = require(script.Parent.Steering)
local PathPlanner = require(script.Parent.PathPlanner)

type Rng = Rng.Rng
type BodyState = Types.BodyState
type MoveCommand = Types.MoveCommand
type AgentView = Types.AgentView
type Waypoint = Types.Waypoint
type Intent = Activities.Intent
type Follower = WaypointFollower.Follower

local Locomotion = {}
Locomotion.__index = Locomotion

export type Status = "idle" | "waitingPath" | "following" | "recovering" | "holding" | "airborne" | "dead"
export type HoldVariant = "still" | "walkOn"

export type EventKind =
	"arrived"
	| "abandon"
	| "changedMind"
	| "goalInvalid"
	| "reset"
	| "stuck"
	| "jumpFailed"
	| "repath"
	| "pathFailed"
	| "tripStarted"
	| "fell"
	| "flung"
	| "blocked"

export type Event = {
	kind: EventKind,
	level: number?, -- kind "stuck": the recovery level entered
	label: string?, -- kind "jumpFailed": the follower's label
	at: number,
}

export type Deps = {
	planner: PathPlanner.Planner,
	losCheck: ((a: Vector3, b: Vector3) -> boolean)?, -- flat line of walk; follower lookahead and direct beelines
	probe: ((position: Vector3, forward: Vector3) -> (number?, number?))?, -- free studs left/right for recovery
	entity: (id: string) -> AgentView?, -- live view of a follow target
	agentId: string,
	canJump: boolean,
	lookahead: number, -- follower lookahead in studs (from the input profile)
	killY: number, -- below this height the body has left the world
	customWaypoint: ((label: string?, position: Vector3) -> number?)?, -- seconds to hold at a Custom waypoint
}

export type Options = {
	stuckAfter: number?, -- StuckDetector.stuckAfter (persona patience)
	personalSpace: number?, -- Steering.personalSpace
	ignoreChance: number?, -- Steering.ignoreChance
	jumpShare: number?, -- Steering.jumpShare
	pushOnlyBlocking: boolean?, -- Steering.pushOnlyBlocking (Npc passes true, §2.12)
	steering: Steering.Options?, -- further steering options; the named fields above win
	recoveryRng: Rng?, -- pre-forked streams (the owner's "recovery" and "steer" forks); default forked here
	steerRng: Rng?,
}

export type Output = {
	command: MoveCommand,
	status: Status,
	events: { Event },
	followerEvents: { WaypointFollower.Event },
	remaining: number, -- studs left along the path, measured from the lookahead target
	blockedBy: string?, -- steering: the agent right in front, for the senses
	tripId: number?, -- the current trip while a follower exists
	intendedSpeed: number, -- walkSpeed * magnitude of the follower's command, what the stuck detector saw
	verdict: string, -- the stuck detector's verdict this tick ("ok" when it did not run)
	humanize: boolean, -- true when the owner should pass the command through the humanizer
}

export type BrainView = {
	status: string, -- "idle" | "planning" | "walking" | "arrived" | "failed"
	goal: Vector3?,
	moving: boolean,
	onGround: boolean,
	blockedBy: string?,
	remaining: number,
}

export type LocomotionT = typeof(setmetatable(
	{} :: {
		currentStatus: Status, -- the pinned `status` field, named so the `status()` method is reachable
		goal: Vector3?,
		goalTolerance: number,
		tripId: number,
		follower: Follower?,
		stuck: StuckDetector.Detector,
		recovery: Recovery.Ladder,
		steering: Steering.Steerer,
		requestId: number?,
		nextRequestId: number,
		lastPlanAt: number,
		followTarget: string?,
		followKeep: number,
		lastFollowGoal: Vector3?,
		stepUntil: number,
		stepDir: Vector3?,
		holdUntil: number,
		holdVariant: HoldVariant,
		holdDir: Vector3?,
		facingYaw: number?,
		jumpRequested: boolean,
		jumpFailures: number,
		lastCommand: MoveCommand?,
		lastSteerBlockedBy: string?,
		tripStartedAt: number,
		deps: Deps,
		rng: Rng,
		-- bookkeeping behind the state table
		holdKind: string?, -- nil | "hold" | "freeze" | "flung"
		followerKind: string, -- "path" (from the planner) | "follow" (direct two-waypoint tail)
		outcome: string?, -- nil | "arrived" | "failed", what the brain sees after a trip ended
		failedAt: number,
		dead: boolean,
		falling: boolean,
		airborneSince: number?,
		leftGroundY: number,
		jumpIssuedAt: number,
		recoveryStepping: boolean, -- the ladder is issuing actions (not in its success window)
		customResumeAt: number?,
		blockedTimes: { number },
		lastBlockedAt: number,
		followJitter: number,
		followJitterAt: number,
		followAnnounced: boolean, -- this follow episode already started its trip
		lastBody: BodyState?,
		requestStart: Vector3?,
		lastRemaining: number,
		pending: { Event },
		lastRequest: PathPlanner.Request?,
		lastResult: Types.PathResult?,
	},
	Locomotion
))

local FALL_AIRBORNE = 1.2 -- seconds off the ground that make any descent a fall
local FALL_VY = -10 -- studs/s downward that count as descending
local FALL_DROP = 8 -- studs below the last ground contact without a jump: a real fall
local FLUNG_SPEED = 60 -- studs/s (downward speed excluded: that is a fall)
local JUMP_GRACE = 1.0 -- seconds after a jump command during which a descent is the jump
local DIRECT_MAX = 24 -- goals this close with line of walk are requested as a direct beeline
local FOLLOW_DIRECT_MAX = 30 -- a follow goal this close with line of walk skips the planner
local FOLLOW_LOOKAHEAD = 8
local FOLLOW_REGOAL_MOVED = 4 -- studs the target moved before a planned follow re-goals
local FOLLOW_REGOAL_GAP = 1.5 -- seconds between planned follow re-goals (and jitter redraws)
local FOLLOW_JITTER = math.rad(15)
local RETRY_AFTER = 3 -- seconds a failed goal stays failed before the same goto re-requests
local BLOCKED_DEBOUNCE = 0.5
local BLOCKED_WINDOW = 20
local BLOCKED_LIMIT = 3

local function stop(): MoveCommand
	return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
end

local function move(dir: Vector3): MoveCommand
	return { mode = "move", dir = dir, magnitude = 1, jump = false }
end

function Locomotion.new(rng: Rng, deps: Deps, options: Options?, now: number): LocomotionT
	local o: Options = options or {}
	-- Fixed fork order; the owner may hand in its own "recovery" and "steer" forks instead.
	local recoveryRng = rng:fork("recovery")
	local steerRng = rng:fork("steer")
	local followRng = rng:fork("follow")
	local steerOptions: Steering.Options = if o.steering then table.clone(o.steering) else {}
	if o.personalSpace then
		steerOptions.personalSpace = o.personalSpace
	end
	if o.ignoreChance then
		steerOptions.ignoreChance = o.ignoreChance
	end
	if o.jumpShare then
		steerOptions.jumpShare = o.jumpShare
	end
	if o.pushOnlyBlocking ~= nil then
		steerOptions.pushOnlyBlocking = o.pushOnlyBlocking
	end
	local self = setmetatable({
		currentStatus = "idle" :: Status,
		goal = nil,
		goalTolerance = 1.5,
		tripId = 0,
		follower = nil,
		stuck = StuckDetector.new({ stuckAfter = o.stuckAfter }),
		recovery = Recovery.new(o.recoveryRng or recoveryRng, { killY = deps.killY }),
		steering = Steering.new(o.steerRng or steerRng, steerOptions),
		requestId = nil,
		nextRequestId = 1,
		lastPlanAt = -math.huge,
		followTarget = nil,
		followKeep = 3,
		lastFollowGoal = nil,
		stepUntil = -math.huge,
		stepDir = nil,
		holdUntil = -math.huge,
		holdVariant = "still" :: HoldVariant,
		holdDir = nil,
		facingYaw = nil,
		jumpRequested = false,
		jumpFailures = 0,
		lastCommand = nil,
		lastSteerBlockedBy = nil,
		tripStartedAt = now,
		deps = deps,
		rng = followRng,
		holdKind = nil,
		followerKind = "path",
		outcome = nil,
		failedAt = -math.huge,
		dead = false,
		falling = false,
		airborneSince = nil,
		leftGroundY = 0,
		jumpIssuedAt = -math.huge,
		recoveryStepping = false,
		customResumeAt = nil,
		blockedTimes = {},
		lastBlockedAt = -math.huge,
		followJitter = 0,
		followJitterAt = -math.huge,
		followAnnounced = false,
		lastBody = nil,
		requestStart = nil,
		lastRemaining = 0,
		pending = {},
		lastRequest = nil,
		lastResult = nil,
	}, Locomotion)
	return self
end

local function push(self: LocomotionT, kind: EventKind, now: number, level: number?, label: string?)
	table.insert(self.pending, { kind = kind, level = level, label = label, at = now })
end

local function holdActive(self: LocomotionT, now: number): boolean
	return self.holdKind ~= nil and now < self.holdUntil
end

-- A freeze or a flung hold overrides the command; a plain hold only drops the trip.
local function overriding(self: LocomotionT, now: number): boolean
	return holdActive(self, now) and (self.holdKind == "freeze" or self.holdKind == "flung")
end

local function flungActive(self: LocomotionT, now: number): boolean
	return self.holdKind == "flung" and now < self.holdUntil
end

-- Recomputes the status from the state. Called at the end of every public method.
local function refresh(self: LocomotionT, now: number)
	local status: Status
	if self.dead then
		status = "dead"
	elseif self.falling then
		status = "airborne"
	elseif holdActive(self, now) then
		status = "holding"
	elseif self.recovery:isActive() and self.recoveryStepping then
		status = "recovering"
	elseif self.follower then
		local body = self.lastBody
		local follower = self.follower :: Follower
		status = if body and not body.onGround and follower.jumpState ~= "none" then "airborne" else "following"
	elseif self.requestId then
		status = "waitingPath"
	else
		status = "idle"
	end
	self.currentStatus = status
end

-- Drops the follower and any outstanding request (the goal and the outcome are the caller's call).
local function dropTrip(self: LocomotionT)
	self.follower = nil
	self.customResumeAt = nil
	if self.requestId then
		self.requestId = nil
		self.deps.planner:cancel(self.deps.agentId)
	end
end

-- Ends a recovery episode in progress (the goal it was about is gone).
local function endEpisode(self: LocomotionT, now: number)
	if self.recovery:isActive() then
		self.recovery:onNewGoal(now)
	end
	self.recoveryStepping = false
end

-- Asks the planner for a path; `blocked` re-requests through notifyBlocked (priority 0).
local function requestPath(
	self: LocomotionT,
	start: Vector3,
	goal: Vector3,
	now: number,
	priority: number,
	blocked: boolean
)
	local id = self.nextRequestId
	self.nextRequestId += 1
	self.follower = nil
	self.customResumeAt = nil
	self.requestId = id
	self.goal = goal
	self.lastPlanAt = now
	self.requestStart = start
	self.outcome = nil
	-- A short goal with a clear line of walk is a beeline: the planner answers it on its next step.
	local los = self.deps.losCheck
	local direct = NavMath.flatDistance(start, goal) <= DIRECT_MAX and los ~= nil and los(start, goal)
	local request: PathPlanner.Request = {
		id = id,
		agentId = self.deps.agentId,
		start = start,
		goal = goal,
		priority = priority,
		allowPartial = true,
		canJump = self.deps.canJump,
		forceProvider = if direct then "direct" else nil,
		issuedAt = now,
	}
	self.lastRequest = request
	if blocked then
		self.deps.planner:notifyBlocked(request, now)
	else
		self.deps.planner:request(request, now)
	end
end

-- Installs a follower. `announce` starts a trip (tripId, tripStarted) for the owner's humanizer.
local function startFollower(
	self: LocomotionT,
	waypoints: { Waypoint },
	start: Vector3,
	now: number,
	options: WaypointFollower.Options,
	kind: string,
	announce: boolean
)
	self.follower = WaypointFollower.new(waypoints, start, now, options)
	self.followerKind = kind
	self.customResumeAt = nil
	self.jumpFailures = 0
	self.outcome = nil
	self.stuck:reset(now)
	if announce then
		self.tripId += 1
		self.tripStartedAt = now
		self.followAnnounced = true
		push(self, "tripStarted", now)
	end
end

-- A new goal: fresh ladder timeline, fresh blocked count, then a request.
local function startTrip(self: LocomotionT, body: BodyState, goal: Vector3, now: number, priority: number)
	dropTrip(self)
	endEpisode(self, now)
	self.goal = goal
	self.outcome = nil
	self.blockedTimes = {}
	self.recovery:onNewGoal(now)
	requestPath(self, body.position, goal, now, priority, false)
end

local function applyGoto(self: LocomotionT, intent: Intent, body: BodyState, now: number)
	local position = intent.position
	if not position then
		return
	end
	self.followTarget = nil
	self.goalTolerance = intent.tolerance or 1.5
	local priority = if (intent.urgency or 0) >= 0.8 then 0 else 1
	local same = self.goal ~= nil and NavMath.flatDistance(self.goal :: Vector3, position) < 0.5
	if not same then
		startTrip(self, body, position, now, priority)
	elseif self.follower ~= nil or self.requestId ~= nil then
		-- The trip toward it is in progress: nothing to do.
		return
	elseif self.outcome == "failed" then
		-- The goal stays failed for a while; a repeated goto then tries again at the lowest priority.
		if now - self.failedAt > RETRY_AFTER then
			requestPath(self, body.position, position, now, 2, false)
		end
	elseif self.outcome == "arrived" then
		-- Standing at the goal already.
		return
	else
		-- A hold or a cancel dropped the trip and the brain still wants the goal: walk again.
		requestPath(self, body.position, position, now, priority, false)
	end
end

local function applyFollow(self: LocomotionT, intent: Intent, body: BodyState, now: number)
	local targetId = intent.targetId
	if not targetId then
		return
	end
	self.followKeep = intent.keep or 3
	self.goalTolerance = intent.tolerance or 1.5
	local target = self.deps.entity(targetId)
	if not target then
		return
	end
	local newEpisode = self.followTarget ~= targetId
	if newEpisode then
		self.followTarget = targetId
		self.lastFollowGoal = nil
		self.followJitterAt = -math.huge
		self.followAnnounced = false
	end
	if now - self.followJitterAt >= FOLLOW_REGOAL_GAP then
		self.followJitter = self.rng:range(-FOLLOW_JITTER, FOLLOW_JITTER)
		self.followJitterAt = now
	end
	local behind = NavMath.flatDirection(target.position, body.position)
	if behind.Magnitude == 0 then
		behind = NavMath.dirFromYaw(target.yaw or 0) * -1
	end
	behind = NavMath.dirFromYaw(NavMath.yawOf(behind) + self.followJitter)
	local goal = target.position + behind * self.followKeep
	local distance = NavMath.flatDistance(body.position, goal)
	local los = self.deps.losCheck
	local direct = los ~= nil and distance < FOLLOW_DIRECT_MAX and los(body.position, goal)
	if direct then
		-- Direct line: a two-waypoint follower, re-aimed whenever the target moves.
		local switching = newEpisode
			or self.requestId ~= nil
			or (self.follower ~= nil and self.followerKind ~= "follow")
		local moved = self.lastFollowGoal == nil or NavMath.flatDistance(self.lastFollowGoal :: Vector3, goal) > 1
		if not switching and not moved then
			return
		end
		if switching then
			dropTrip(self)
			endEpisode(self, now)
			self.recovery:onNewGoal(now)
			self.blockedTimes = {}
		end
		self.goal = goal
		self.lastFollowGoal = goal
		self.outcome = nil
		if distance > self.goalTolerance then
			-- One trip per follow episode: the first follower announces it, re-aims stay quiet.
			startFollower(self, {
				{ position = body.position, action = "Walk" },
				{ position = goal, action = "Walk" },
			}, body.position, now, { lookahead = FOLLOW_LOOKAHEAD, losCheck = los }, "follow", not self.followAnnounced)
			self.followAnnounced = true
		else
			self.follower = nil -- close enough: stand
		end
	else
		local moved = self.lastFollowGoal == nil
			or NavMath.flatDistance(self.lastFollowGoal :: Vector3, goal) > FOLLOW_REGOAL_MOVED
		local onDirect = self.follower ~= nil and self.followerKind == "follow"
		if newEpisode or onDirect or (moved and now - self.lastPlanAt >= FOLLOW_REGOAL_GAP) then
			dropTrip(self)
			endEpisode(self, now)
			self.recovery:onNewGoal(now)
			self.blockedTimes = {}
			self.lastFollowGoal = goal
			requestPath(self, body.position, goal, now, 1, false)
		end
	end
end

-- Drops the trip for a hold; a trip that was being walked is a change of mind.
local function holdTrip(self: LocomotionT, now: number)
	local walking = self.follower ~= nil
	dropTrip(self)
	endEpisode(self, now)
	self.followTarget = nil
	if walking then
		push(self, "changedMind", now)
	end
end

-- After a body swap (which is also how the owner's reset story ends): everything idle.
local function revive(self: LocomotionT, now: number)
	dropTrip(self)
	self.dead = false
	self.falling = false
	self.airborneSince = nil
	self.holdKind = nil
	self.holdUntil = -math.huge
	self.holdDir = nil
	self.goal = nil
	self.outcome = nil
	self.followTarget = nil
	self.lastFollowGoal = nil
	self.jumpFailures = 0
	self.jumpRequested = false
	self.facingYaw = nil
	self.stepUntil = -math.huge
	self.stepDir = nil
	self.recovery:onNewGoal(now)
	self.recovery.level = 0
	self.recovery.lastFailureAt = -math.huge
	self.recoveryStepping = false
	self.stuck:reset(now)
	self.lastSteerBlockedBy = nil
	self.blockedTimes = {}
	self.lastCommand = nil
	self.lastRemaining = 0
end

-- Applies the brain's intent. Idempotent: the same intent every brain step changes nothing.
function Locomotion.setIntent(self: LocomotionT, intent: Intent, body: BodyState, now: number)
	self.lastBody = body
	local kind = intent.kind
	if self.dead then
		-- Nothing to move until the owner's reset story ends with reset() (a fresh body).
		return
	end
	if kind == "goto" or kind == "follow" then
		-- A flung body and a falling body are not steerable; the brain repeats itself anyway.
		if not flungActive(self, now) and not self.falling then
			self.holdKind = nil
			if kind == "goto" then
				applyGoto(self, intent, body, now)
			else
				applyFollow(self, intent, body, now)
			end
		end
	elseif kind == "hold" then
		if not flungActive(self, now) then
			holdTrip(self, now)
			self.holdKind = "hold"
			self.holdUntil = now + (intent.duration or math.huge)
			self.holdVariant = "still"
			self.holdDir = nil
		end
	elseif kind == "step" then
		self.stepDir = intent.dir
		self.stepUntil = now + (intent.duration or 0.3)
	elseif kind == "jump" then
		self.jumpRequested = true
	elseif kind == "face" then
		self.facingYaw = intent.yaw
	elseif kind == "freeze" then
		if not flungActive(self, now) then
			-- The trip is kept: typing pauses a walk, it does not end it.
			self.holdKind = "freeze"
			self.holdUntil = now + (intent.duration or 1)
			if intent.variant == "walkStraight" then
				self.holdVariant = "walkOn"
				local last = self.lastCommand
				self.holdDir = if last and last.mode == "move" then last.dir else nil
			else
				self.holdVariant = "still"
				self.holdDir = nil
			end
			-- A deliberate stop (or a deliberate straight walk) is never a stuck verdict.
			self.stuck:suppress(now, self.holdUntil)
		end
	end
	local extra: any = intent
	if extra.jump == true then
		self.jumpRequested = true
	end
	refresh(self, now)
end

-- A completion from the planner (the owner routes them by agent id and request id).
function Locomotion.onPathResult(self: LocomotionT, completion: PathPlanner.Completion, now: number)
	if completion.id ~= self.requestId then
		return
	end
	self.requestId = nil
	local result = completion.result
	self.lastResult = result
	local body = self.lastBody
	local start = if body then body.position else (self.requestStart or completion.goal)
	self.recovery:onPathArrived()
	if (result.status == "Success" or result.status == "Partial") and #result.waypoints > 0 then
		startFollower(
			self,
			result.waypoints,
			start,
			now,
			{ lookahead = self.deps.lookahead, losCheck = self.deps.losCheck },
			"path",
			true
		)
	else
		self.follower = nil
		self.outcome = "failed"
		self.failedAt = now
		push(self, "pathFailed", now)
	end
	refresh(self, now)
end

-- Something scripted or the brain ended the trip: "changedMind" (reselection, random abandonment),
-- "goalInvalid" (the goal turned out to be no goal) or "leave".
function Locomotion.cancel(self: LocomotionT, reason: string, now: number)
	local hadTrip = self.follower ~= nil or self.requestId ~= nil
	dropTrip(self)
	endEpisode(self, now)
	self.stuck:reset(now)
	self.followTarget = nil
	if reason == "goalInvalid" then
		self.outcome = "failed"
		self.failedAt = now
		push(self, "goalInvalid", now)
	else
		self.goal = nil
		self.outcome = nil
		if reason == "changedMind" and hadTrip then
			push(self, "changedMind", now)
		end
	end
	refresh(self, now)
end

-- After a body swap: status idle, follower dropped, ladder and detector reset, no event.
function Locomotion.reset(self: LocomotionT, now: number)
	revive(self, now)
	self.pending = {}
	refresh(self, now)
end

function Locomotion.status(self: LocomotionT): Status
	return self.currentStatus
end

function Locomotion.describe(self: LocomotionT): { status: Status, goal: Vector3?, remaining: number, level: number }
	return {
		status = self.currentStatus,
		goal = self.goal,
		remaining = self.lastRemaining,
		level = self.recovery:currentLevel(),
	}
end

-- What the brain and the activities read back.
function Locomotion.brainView(self: LocomotionT, body: BodyState): BrainView
	local status = "idle"
	if self.requestId then
		status = "planning"
	elseif self.follower then
		status = "walking"
	elseif self.outcome == "arrived" then
		status = "arrived"
	elseif self.outcome == "failed" then
		status = "failed"
	end
	return {
		status = status,
		goal = self.goal,
		moving = NavMath.flat(body.velocity).Magnitude > 1,
		onGround = body.onGround,
		blockedBy = self.lastSteerBlockedBy,
		remaining = self.lastRemaining,
	}
end

-- The waypoint currently steered toward while a planned path is being followed (Path.Blocked rule).
function Locomotion.followerIndex(self: LocomotionT): number?
	local follower = self.follower
	if follower and self.followerKind == "path" and not self.dead then
		return follower:index()
	end
	return nil
end

-- The engine reported the path blocked at a waypoint: re-request urgently when it is still ahead.
-- Debounced; a goal blocked three times in twenty seconds is given up.
function Locomotion.onBlocked(self: LocomotionT, blockedIndex: number, now: number): boolean
	local index = self:followerIndex()
	local goal = self.goal
	local body = self.lastBody
	if index == nil or goal == nil or body == nil or blockedIndex < index then
		return false
	end
	if now - self.lastBlockedAt < BLOCKED_DEBOUNCE then
		return false
	end
	self.lastBlockedAt = now
	local kept: { number } = {}
	for _, t in self.blockedTimes do
		if now - t < BLOCKED_WINDOW then
			table.insert(kept, t)
		end
	end
	table.insert(kept, now)
	self.blockedTimes = kept
	if #kept >= BLOCKED_LIMIT then
		dropTrip(self)
		endEpisode(self, now)
		self.outcome = "failed"
		self.failedAt = now
		push(self, "abandon", now)
	else
		push(self, "blocked", now)
		requestPath(self, body.position, goal, now, 0, true)
	end
	refresh(self, now)
	return true
end

-- Flung: a big velocity that is not a plain fall (downward speed is the fall rule's business).
local function flungSpeed(body: BodyState): number
	local v = body.velocity
	return Vector3.new(v.X, math.max(v.Y, 0), v.Z).Magnitude
end

local function jumpPending(self: LocomotionT, now: number): boolean
	local follower = self.follower
	if follower and follower.jumpState ~= "none" then
		return true
	end
	return now - self.jumpIssuedAt < JUMP_GRACE
end

-- The body left the world: the ladder goes straight to its reset level.
local function killPlane(self: LocomotionT, body: BodyState, forward: Vector3, now: number)
	if self.recovery:isActive() then
		self.recovery:onNewGoal(now)
	end
	local level = self.recovery:onStuck(now, body, forward, "stuck")
	push(self, "stuck", now, level)
	local action = self.recovery:tick(now)
	if action.kind == "reset" then
		dropTrip(self)
		self.recoveryStepping = false
		self.outcome = "failed"
		self.failedAt = now
		self.holdKind = nil
		self.falling = false
		self.dead = true
		push(self, "reset", now)
	end
end

local function output(
	self: LocomotionT,
	command: MoveCommand,
	followerEvents: { WaypointFollower.Event },
	extra: {
		remaining: number,
		intendedSpeed: number,
		verdict: string,
		humanize: boolean,
	}
): Output
	local events = self.pending
	self.pending = {}
	self.lastCommand = command
	return {
		command = command,
		status = self.currentStatus,
		events = events,
		followerEvents = followerEvents,
		remaining = extra.remaining,
		blockedBy = self.lastSteerBlockedBy,
		tripId = if self.follower then self.tripId else nil,
		intendedSpeed = extra.intendedSpeed,
		verdict = extra.verdict,
		humanize = extra.humanize,
	}
end

-- Handles what the follower reported this tick. Returns true when a jump failure re-requested.
local function handleFollowerEvents(
	self: LocomotionT,
	follower: Follower,
	events: { WaypointFollower.Event },
	body: BodyState,
	forward: Vector3,
	now: number,
	humanizerBusyUntil: number
)
	for _, e in events do
		if e.kind == "finished" then
			if self.followerKind == "path" then
				self.outcome = "arrived"
				push(self, "arrived", now)
			end
			self.follower = nil
			self.customResumeAt = nil
			endEpisode(self, now)
			self.recovery:onNewGoal(now)
		elseif e.kind == "waypoint" then
			self.recovery:onProgress(now, 4)
		elseif e.kind == "jumpFailed" then
			push(self, "jumpFailed", now, nil, e.label or "?")
			-- First failure: simply try the jump again. Second in a row: let recovery handle it
			-- (back up and jump, then re-path with the jump penalized).
			self.jumpFailures += 1
			if self.jumpFailures <= 1 then
				follower:resume()
			else
				local level = self.recovery:onStuck(now, body, forward, "stuck")
				follower:resume()
				push(self, "stuck", now, level)
				if level >= 2 and self.goal then
					requestPath(self, body.position, self.goal :: Vector3, now, 0, false)
				end
			end
		elseif e.kind == "jumpLanded" then
			self.jumpFailures = 0
		elseif e.kind == "custom" then
			-- A PathfindingLink: hold a moment (or what the game's handler asks), then walk on.
			local waypoint = follower.waypoints[e.index]
			local duration: number? = nil
			if self.deps.customWaypoint and waypoint then
				duration = self.deps.customWaypoint(e.label, waypoint.position)
			end
			self.customResumeAt = now + (duration or self.rng:range(0.2, 0.5))
		elseif e.kind == "timeout" then
			-- A leg that took far too long is a snag the detector could not see (a slow body, a
			-- door): enter the ladder at its back-up level unless something scripted explains it.
			if
				not self.recovery:isActive()
				and humanizerBusyUntil <= now
				and not holdActive(self, now)
				and self.followerKind == "path"
			then
				local left, right = nil, nil
				if self.deps.probe then
					left, right = self.deps.probe(body.position, forward)
				end
				local level = self.recovery:onStuck(now, body, forward, "pushing", left, right)
				push(self, "stuck", now, level)
				self.stuck:reset(now)
			end
		end
	end
end

-- One tick. `neighbors` are the agents within steering range (empty in far tiers);
-- `humanizerBusyUntil` is the end of the owner's scripted no-progress moment (or -inf).
function Locomotion.tick(
	self: LocomotionT,
	body: BodyState,
	neighbors: { AgentView },
	now: number,
	dt: number,
	humanizerBusyUntil: number
): Output
	self.lastBody = body
	local followerEvents: { WaypointFollower.Event } = {}
	local none = { remaining = 0, intendedSpeed = 0, verdict = "ok", humanize = false }
	if self.dead then
		refresh(self, now)
		return output(self, stop(), followerEvents, none)
	end
	local forward = NavMath.dirFromYaw(body.yaw)

	-- Ground contact bookkeeping for the fall rule.
	if body.onGround then
		self.airborneSince = nil
		self.leftGroundY = body.position.Y
	elseif self.airborneSince == nil then
		self.airborneSince = now
	end

	-- Kill plane.
	if body.position.Y < self.deps.killY then
		killPlane(self, body, forward, now)
		refresh(self, now)
		return output(self, stop(), followerEvents, none)
	end

	-- Flung by physics: nothing to do but wait it out; the brain reselects afterwards.
	if flungSpeed(body) > FLUNG_SPEED and not flungActive(self, now) then
		dropTrip(self)
		endEpisode(self, now)
		self.goal = nil
		self.outcome = nil
		self.followTarget = nil
		self.stuck:reset(now)
		self.holdKind = "flung"
		self.holdUntil = now + self.rng:logNormalClamped(2, 0.5, 1, 5)
		self.holdVariant = "still"
		self.holdDir = nil
		push(self, "flung", now)
	end

	-- A real fall (not a jump): steering and the detector are off until the landing, which
	-- re-plans from where the body ended up.
	if not self.falling and not body.onGround and body.velocity.Y < FALL_VY then
		local airborneFor = now - (self.airborneSince :: number)
		local dropped = self.leftGroundY - body.position.Y
		if airborneFor > FALL_AIRBORNE or (dropped > FALL_DROP and not jumpPending(self, now)) then
			self.falling = true
			dropTrip(self)
			endEpisode(self, now)
			self.stuck:reset(now)
		end
	end
	if self.falling then
		if body.onGround then
			self.falling = false
			push(self, "fell", now)
			local goal = self.goal
			if goal and not flungActive(self, now) then
				requestPath(self, body.position, goal, now, 1, false)
			end
		else
			self.lastSteerBlockedBy = nil
			refresh(self, now)
			return output(self, stop(), followerEvents, none)
		end
	end

	-- Timed holds end on their own.
	if self.holdKind ~= nil and now >= self.holdUntil then
		self.holdKind = nil
	end

	-- Base command from the trip.
	local command: MoveCommand = stop()
	local intendedSpeed = 0
	local remaining = 0
	local verdict = "ok"
	local follower = self.follower
	if follower then
		if follower:isPaused() and self.customResumeAt and now >= self.customResumeAt then
			follower:resume()
			self.customResumeAt = nil
		end
		local out = follower:tick(body, now)
		followerEvents = out.events
		command = out.command
		remaining = out.remaining
		self.lastRemaining = remaining
		handleFollowerEvents(self, follower, out.events, body, forward, now, humanizerBusyUntil)
		-- Tailing someone: keep their pace once close, stand when they stand.
		if self.followerKind == "follow" and self.follower ~= nil and command.mode == "move" then
			local target = if self.followTarget then self.deps.entity(self.followTarget :: string) else nil
			if target then
				local gap = NavMath.flatDistance(body.position, target.position)
				local targetSpeed = NavMath.flat(target.velocity).Magnitude
				if gap <= self.followKeep + 1 then
					if targetSpeed < 1 then
						self.follower = nil
						command = stop()
					elseif body.walkSpeed > 0 then
						command.magnitude = math.clamp(targetSpeed / body.walkSpeed, 0.2, 1)
					end
				end
			end
		end
		if command.mode == "move" then
			forward = command.dir
			intendedSpeed = body.walkSpeed * command.magnitude
		end
	end

	-- Stuck detection on trips (the detector ignores jump arcs itself).
	if humanizerBusyUntil > now then
		self.stuck:suppress(now, humanizerBusyUntil)
	end
	if overriding(self, now) then
		self.stuck:suppress(now, self.holdUntil)
	end
	if self.follower then
		verdict = self.stuck:update(body, intendedSpeed, remaining, now, forward)
	end
	local airborneJump = self.follower ~= nil and not body.onGround and (self.follower :: Follower).jumpState ~= "none"

	-- Recovery ladder.
	if self.recovery:isActive() then
		local action = self.recovery:tick(now)
		if action.kind == "repath" then
			self.recoveryStepping = true
			push(self, "repath", now)
			if self.goal then
				requestPath(self, body.position, self.goal :: Vector3, now, 0, true)
			end
			command = stop()
		elseif action.kind == "abandon" then
			self.recoveryStepping = false
			push(self, "abandon", now)
			dropTrip(self)
			self.outcome = "failed"
			self.failedAt = now
			command = stop()
		elseif action.kind == "reset" then
			self.recoveryStepping = false
			push(self, "reset", now)
			dropTrip(self)
			self.outcome = "failed"
			self.failedAt = now
			self.holdKind = nil
			self.dead = true
			command = stop()
		elseif action.kind ~= "done" then
			self.recoveryStepping = true
			command = Recovery.toCommand(action, forward)
			self.stuck:suppress(now, action.until_)
		else
			if self.recoveryStepping then
				-- The episode's steps are over: the follower drives again while the ladder watches.
				self.recoveryStepping = false
				self.stuck:reset(now)
				local f = self.follower
				if f and f:isPaused() and self.customResumeAt == nil then
					f:resume()
				end
			end
		end
	elseif verdict ~= "ok" and self.follower and not airborneJump then
		local left, right = nil, nil
		if self.deps.probe then
			left, right = self.deps.probe(body.position, forward)
		end
		-- Newer detectors add verdicts: anything that is not a push is handled as stuck.
		local mapped: "stuck" | "pushing" = if verdict == "pushing" or verdict == "wallCapped"
			then "pushing"
			else "stuck"
		local level = self.recovery:onStuck(now, body, forward, mapped, left, right)
		push(self, "stuck", now, level)
		self.stuck:reset(now)
		local action = self.recovery:tick(now)
		self.recoveryStepping = action.kind ~= "done"
		command = Recovery.toCommand(action, forward)
	end

	-- Direct intents: timed steps, then freezes (a typist does not step).
	if now < self.stepUntil and self.stepDir then
		command = move(self.stepDir :: Vector3)
	end
	if overriding(self, now) then
		local dir = self.holdDir
		command = if self.holdVariant == "walkOn" and dir then move(dir) else stop()
	end

	-- Local avoidance of other characters (not while frozen, not in the air).
	if command.mode == "move" and not holdActive(self, now) and not airborneJump then
		local friends: { [string]: boolean }? = nil
		if self.followTarget then
			friends = { [self.followTarget :: string] = true }
		end
		local steered = self.steering:adjust({
			dir = command.dir,
			magnitude = command.magnitude,
			position = body.position,
			velocity = body.velocity,
			neighbors = neighbors,
			now = now,
			friends = friends,
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

	-- Jump and facing requests ride on whatever the command is.
	if self.jumpRequested and body.onGround then
		command = table.clone(command)
		command.jump = true
	end
	self.jumpRequested = false
	if self.facingYaw and command.mode ~= "move" then
		command = table.clone(command)
		command.facingYaw = self.facingYaw
	end
	self.facingYaw = nil
	if command.jump then
		self.jumpIssuedAt = now
	end

	refresh(self, now)
	local humanize = self.follower ~= nil
		and not self.recovery:isActive()
		and not holdActive(self, now)
		and not self.falling
	return output(self, command, followerEvents, {
		remaining = remaining,
		intendedSpeed = intendedSpeed,
		verdict = verdict,
		humanize = humanize,
	})
end

Locomotion.STOP = stop()

return Locomotion

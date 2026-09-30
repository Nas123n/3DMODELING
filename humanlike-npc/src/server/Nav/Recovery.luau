--!strict
-- What an NPC does when it is stuck, scripted the way people actually get unstuck: a short
-- pause, a sidestep, a step back and a hop, a look around and a different route, and finally
-- giving up on the goal. Levels escalate only when the previous one failed recently, the side
-- chosen once is kept for the episode, and a hopeless goal is abandoned rather than oscillated
-- at. The ladder never touches the world: it emits small actions and requests, and is told
-- about progress by whoever runs it.
--
-- The verdict that starts an episode decides how high it enters: "stuck" (poor progress) starts
-- with the nudge, "pushing" (walked into something) skips it, "oscillating" (dithering between
-- two ways round) is a stuck that also skips it and enters at the back-and-jump level, and
-- "wallCapped" (pushed a wall for seconds) is a pushing that goes straight to the repath level.
-- Anything else is treated as "stuck".
-- requires: NavMath, Rng, Types

local NavMath = require(script.Parent.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)

type Rng = Rng.Rng
type BodyState = Types.BodyState
type MoveCommand = Types.MoveCommand

local Recovery = {}
Recovery.__index = Recovery

export type ActionKind =
	"pause"
	| "sidestep"
	| "backup"
	| "forward"
	| "face"
	| "jump"
	| "repath"
	| "abandon"
	| "reset"
	| "done"

export type Action = {
	kind: ActionKind,
	dir: Vector3?, -- for sidestep / backup / forward
	yaw: number?, -- for face
	until_: number, -- when this step ends
}

export type Level = number -- 0 nudge, 1 backAndJump, 2 repath, 3 abandon, 4 reset

export type Options = {
	killY: number?, -- below this height the body is considered fallen out of the world; default -50
	hopelessAfter: number?, -- seconds stuck on one goal before a reset; default 25
	escalateWindow: number?, -- seconds after a failure during which the next stuck escalates; default 15
	progressResetAfter: number?, -- seconds of clean progress that reset the level; default 20
}

type Step = { kind: ActionKind, duration: number, dir: Vector3?, yaw: number? }

export type Ladder = typeof(setmetatable(
	{} :: {
		rng: Rng,
		killY: number,
		hopelessAfter: number,
		escalateWindow: number,
		progressResetAfter: number,
		level: number,
		lastFailureAt: number,
		firstStuckOnGoalAt: number?,
		lastProgressAt: number,
		repathEpisodes: { number }, -- times of L2 episodes on the current goal
		side: number?, -- sidestep side kept for the episode (-1 left, 1 right)
		steps: { Step },
		stepIndex: number,
		stepEndsAt: number,
		active: boolean,
		episodeLevel: number,
		successDeadline: number?,
		successNeeded: number,
		progressSinceEpisode: number,
		waitingForPath: boolean,
		waitingSince: number,
	},
	Recovery
))

function Recovery.new(rng: Rng, options: Options?): Ladder
	local o: Options = options or {}
	return setmetatable({
		rng = rng,
		killY = o.killY or -50,
		hopelessAfter = o.hopelessAfter or 25,
		escalateWindow = o.escalateWindow or 15,
		progressResetAfter = o.progressResetAfter or 20,
		level = 0,
		lastFailureAt = -math.huge,
		firstStuckOnGoalAt = nil,
		lastProgressAt = 0,
		repathEpisodes = {},
		side = nil,
		steps = {},
		stepIndex = 0,
		stepEndsAt = 0,
		active = false,
		episodeLevel = 0,
		successDeadline = nil,
		successNeeded = 0,
		progressSinceEpisode = 0,
		waitingForPath = false,
		waitingSince = 0,
	}, Recovery)
end

function Recovery.isActive(self: Ladder): boolean
	return self.active
end

function Recovery.currentLevel(self: Ladder): number
	return self.level
end

-- Call when the goal changes: a new goal gets a fresh timeline.
function Recovery.onNewGoal(self: Ladder, now: number)
	self.firstStuckOnGoalAt = nil
	self.repathEpisodes = {}
	self.side = nil
	self.active = false
	self.steps = {}
	self.successDeadline = nil
	self.waitingForPath = false
	self.lastProgressAt = now
end

-- Call whenever the follower reports real progress (a waypoint reached) with studs advanced.
function Recovery.onProgress(self: Ladder, now: number, studs: number)
	self.lastProgressAt = now
	if self.successDeadline then
		self.progressSinceEpisode += studs
	end
	if not self.active and now - self.lastFailureAt > self.progressResetAfter then
		self.level = 0
		self.firstStuckOnGoalAt = nil -- twenty seconds of clean walking: the goal is not hopeless
		self.repathEpisodes = {}
	end
end

-- Call when a new path arrived after a repath request.
function Recovery.onPathArrived(self: Ladder)
	self.waitingForPath = false
end

local function chooseSide(self: Ladder, probeLeft: number?, probeRight: number?): number
	if self.side then
		-- Keep the side unless it turned out to be a wall.
		local free = if self.side < 0 then probeLeft else probeRight
		if free == nil or free >= 1 then
			return self.side
		end
	end
	local left, right = probeLeft or 3, probeRight or 3
	local side = if left > right then -1 elseif right > left then 1 else self.rng:sign()
	self.side = side
	return side
end

local function u(self: Ladder, lo: number, hi: number): number
	return self.rng:range(lo, hi)
end

-- The lowest level an episode may start at for a verdict: pushing and oscillating skip the nudge
-- (a person who walked into a wall backs up, one dithering stops and hops), a capped wall goes
-- straight to a new route. Unknown verdicts are plain "stuck".
local function entryLevel(verdict: string): number
	if verdict == "wallCapped" then
		return 2
	elseif verdict == "pushing" or verdict == "oscillating" then
		return 1
	end
	return 0
end

-- Starts an episode. `forward` is the direction the NPC was trying to walk; probes are the free
-- distances of two short raycasts at +-60 degrees (nil when unknown). `verdict` is the detector's
-- word: "stuck" | "pushing" | "oscillating" | "wallCapped" (any other string counts as "stuck").
function Recovery.onStuck(
	self: Ladder,
	now: number,
	body: BodyState,
	forward: Vector3,
	verdict: string,
	probeLeft: number?,
	probeRight: number?
): number
	if self.active then
		return self.episodeLevel
	end
	if now - self.lastFailureAt < self.escalateWindow then
		self.level = math.min(self.level + 1, 3)
	else
		self.level = 0
	end
	self.level = math.max(self.level, entryLevel(verdict))
	self.lastFailureAt = now
	if not self.firstStuckOnGoalAt then
		self.firstStuckOnGoalAt = now
	end
	if body.position.Y < self.killY or now - (self.firstStuckOnGoalAt :: number) > self.hopelessAfter then
		self.level = 4
	end
	if self.level == 2 then
		-- Two repath episodes within 60 s on the same goal: give up instead.
		local recent = 0
		for _, t in self.repathEpisodes do
			if now - t < 60 then
				recent += 1
			end
		end
		if recent >= 1 then
			self.level = 3
		else
			table.insert(self.repathEpisodes, now)
		end
	end

	local fwd = if forward.Magnitude > 1e-6 then NavMath.flat(forward).Unit else NavMath.dirFromYaw(body.yaw)
	local perp = NavMath.perp(fwd)
	local steps: { Step } = {}
	local level = self.level
	if level == 0 then
		local side = chooseSide(self, probeLeft, probeRight)
		table.insert(steps, { kind = "pause", duration = math.clamp(self.rng:gaussian(0.3, 0.1), 0.2, 0.5) })
		table.insert(steps, { kind = "sidestep", duration = u(self, 0.4, 0.8), dir = perp * side })
		table.insert(steps, { kind = "forward", duration = 0.4, dir = fwd })
	elseif level == 1 then
		table.insert(steps, { kind = "pause", duration = u(self, 0.15, 0.4) })
		table.insert(steps, { kind = "backup", duration = u(self, 0.3, 0.6), dir = -fwd })
		table.insert(steps, { kind = "face", duration = 0.1, yaw = NavMath.yawOf(fwd) })
		table.insert(steps, { kind = "jump", duration = 0.6, dir = fwd })
	elseif level == 2 then
		local side = chooseSide(self, probeLeft, probeRight)
		table.insert(steps, { kind = "pause", duration = u(self, 0.3, 0.8) })
		table.insert(steps, { kind = "repath", duration = 0 })
		table.insert(steps, { kind = "sidestep", duration = 0.3, dir = perp * side })
	elseif level == 3 then
		table.insert(steps, { kind = "pause", duration = self.rng:logNormalClamped(0.8, 0.5, 0.4, 2) })
		if self.rng:chance(0.3) then
			table.insert(steps, { kind = "jump", duration = 0.3, dir = Vector3.zero }) -- frustration hop
		end
		table.insert(steps, { kind = "abandon", duration = 0 })
	else
		table.insert(steps, { kind = "reset", duration = 0 })
	end

	self.steps = steps
	self.stepIndex = 0
	self.stepEndsAt = now
	self.active = true
	self.episodeLevel = level
	self.successDeadline = nil
	self.progressSinceEpisode = 0
	self.waitingForPath = false
	return level
end

-- Advances the episode. Returns the action to perform now; "done" once the episode is over and
-- the success test has resolved (it is the caller's job to route repath/abandon/reset requests).
function Recovery.tick(self: Ladder, now: number): Action
	if not self.active then
		return { kind = "done", until_ = now }
	end
	-- Success test after the script ends.
	if self.stepIndex > #self.steps then
		if self.waitingForPath then
			if now - self.waitingSince > 5 then
				self.waitingForPath = false -- the planner never answered: count it as a failed episode
				self.active = false
				return { kind = "done", until_ = now }
			end
			return { kind = "pause", until_ = now + 0.2 }
		end
		if self.successDeadline == nil then
			local needed = if self.episodeLevel == 2 then 3 else 1.5
			local window = if self.episodeLevel == 2 then 3 else 1.5
			self.successNeeded = needed
			self.successDeadline = now + window
			return { kind = "done", until_ = now }
		end
		if self.progressSinceEpisode >= self.successNeeded then
			self.active = false
			self.successDeadline = nil
			self.side = nil
			return { kind = "done", until_ = now }
		end
		if now >= (self.successDeadline :: number) then
			-- Failed: the next onStuck escalates (lastFailureAt is recent).
			self.active = false
			self.successDeadline = nil
			return { kind = "done", until_ = now }
		end
		return { kind = "done", until_ = now }
	end

	if now >= self.stepEndsAt then
		self.stepIndex += 1
		local step = self.steps[self.stepIndex]
		if not step then
			return self:tick(now)
		end
		self.stepEndsAt = now + step.duration
		if step.kind == "repath" then
			self.waitingForPath = true
			self.waitingSince = now
		end
		if step.kind == "abandon" or step.kind == "reset" then
			self.active = false
			return { kind = step.kind, until_ = now }
		end
		return { kind = step.kind, dir = step.dir, yaw = step.yaw, until_ = self.stepEndsAt }
	end
	local step = self.steps[self.stepIndex]
	if not step then
		return { kind = "pause", until_ = self.stepEndsAt }
	end
	return { kind = step.kind, dir = step.dir, yaw = step.yaw, until_ = self.stepEndsAt }
end

-- Converts an action into a move command (the humanizer may still add wobble on top).
function Recovery.toCommand(action: Action, forward: Vector3): MoveCommand
	if action.kind == "sidestep" or action.kind == "backup" or action.kind == "forward" then
		local dir = action.dir or forward
		return { mode = "move", dir = dir, magnitude = 1, jump = false }
	elseif action.kind == "jump" then
		local dir = action.dir or forward
		if dir.Magnitude < 1e-6 then
			return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = true }
		end
		return { mode = "move", dir = dir, magnitude = 1, jump = true }
	elseif action.kind == "face" then
		return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false, facingYaw = action.yaw }
	end
	return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
end

return Recovery

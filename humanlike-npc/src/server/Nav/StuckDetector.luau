--!strict
-- Notices when a walking body is not getting anywhere. Two base signals, both about progress
-- rather than raw velocity, because a humanoid sliding along a wall has velocity but no progress
-- and a humanoid pushing a wall has intent but no velocity:
--   "stuck"   progress along the path has fallen well below what the intended speed predicts
--             for about a second (a brief snag decays away twice as fast as it accrues)
--   "pushing" on the ground, trying to move, and barely moving for 0.6 s (face-first wall contact)
-- and two sharper ones that replace them when they apply, so recovery can start higher up:
--   "oscillating"  the intended direction flipped back and forth (three reversals, each a turn of
--                  more than 120 degrees back to the heading before the last turn) inside a short
--                  window while progress stayed under half of what was expected: a body dithering
--                  between two ways round something
--   "wallCapped"   the pushing conditions held without a break for several seconds: a wall, not a
--                  crowd that will move on
-- Scripted no-progress moments (a deliberate wall bump, a pause, an about-face) suppress it for a
-- bounded time and clear the direction history, so a humanizer's own reversal never counts.
-- It only ever sees plain numbers and vectors; the caller decides what to do with a verdict.

local NavMath = require(script.Parent.NavMath)
local Types = require(script.Parent.Parent.Types)

type BodyState = Types.BodyState

local StuckDetector = {}
StuckDetector.__index = StuckDetector

export type Verdict = "ok" | "stuck" | "pushing" | "oscillating" | "wallCapped"

export type Options = {
	stuckAfter: number?, -- seconds of poor progress before "stuck"; persona patience, default 1.1
	pushAfter: number?, -- default 0.6
	sampleInterval: number?, -- default 0.25
	progressRatio: number?, -- progress below this share of ideal counts as poor; default 0.3
	pushRatio: number?, -- speed below this share of intended counts as pushing; default 0.25
	wallCappedAfter: number?, -- seconds of uninterrupted pushing before "wallCapped"; default 3
	oscillationWindow: number?, -- seconds the reversals must fall within; default 2
	oscillationReversals: number?, -- reversals inside the window that count as oscillating; default 3
	oscillationRatio: number?, -- progress over the window below this share of expected; default 0.5
}

-- One progress sample, kept for the oscillation window.
type Sample = { at: number, progress: number, expected: number }

export type Detector = typeof(setmetatable(
	{} :: {
		stuckAfter: number,
		pushAfter: number,
		sampleInterval: number,
		progressRatio: number,
		pushRatio: number,
		wallCappedAfter: number,
		oscillationWindow: number,
		oscillationReversals: number,
		oscillationRatio: number,
		lastSampleAt: number,
		lastRemaining: number?,
		lastPosition: Vector3?,
		stuckTime: number,
		pushTime: number,
		lastTickAt: number?,
		suppressedUntil: number,
		samples: { Sample }, -- progress samples inside the oscillation window
		lastDir: Vector3?, -- the intended heading as of the last update
		previousDir: Vector3?, -- the heading held before the last turn of more than 120 degrees
		reversals: { number }, -- times of reversals inside the oscillation window
	},
	StuckDetector
))

local REVERSAL_TURN = math.rad(120) -- a turn sharper than this is a change of heading
local REVERSAL_BACK = math.rad(60) -- ... and one landing this close to the heading before it is a reversal

function StuckDetector.new(options: Options?): Detector
	local o: Options = options or {}
	return setmetatable({
		stuckAfter = o.stuckAfter or 1.1,
		pushAfter = o.pushAfter or 0.6,
		sampleInterval = o.sampleInterval or 0.25,
		progressRatio = o.progressRatio or 0.3,
		pushRatio = o.pushRatio or 0.25,
		wallCappedAfter = o.wallCappedAfter or 3,
		oscillationWindow = o.oscillationWindow or 2,
		oscillationReversals = o.oscillationReversals or 3,
		oscillationRatio = o.oscillationRatio or 0.5,
		lastSampleAt = -math.huge,
		lastRemaining = nil,
		lastPosition = nil,
		stuckTime = 0,
		pushTime = 0,
		lastTickAt = nil,
		suppressedUntil = -math.huge,
		samples = {},
		lastDir = nil,
		previousDir = nil,
		reversals = {},
	}, StuckDetector)
end

local function clearHeading(self: Detector)
	self.lastDir = nil
	self.previousDir = nil
	self.reversals = {}
end

function StuckDetector.reset(self: Detector, now: number)
	self.lastSampleAt = now
	self.lastRemaining = nil
	self.lastPosition = nil
	self.stuckTime = 0
	self.pushTime = 0
	self.lastTickAt = now
	self.samples = {}
	clearHeading(self)
end

-- Ignore lack of progress until `untilTime` (capped at 3 s from now: nothing scripted lasts longer).
function StuckDetector.suppress(self: Detector, now: number, untilTime: number)
	self.suppressedUntil = math.min(untilTime, now + 3)
end

function StuckDetector.isSuppressed(self: Detector, now: number): boolean
	return now < self.suppressedUntil
end

-- Drops window entries older than the oscillation window.
local function pruneWindow(self: Detector, now: number)
	local window = self.oscillationWindow
	while #self.samples > 0 and now - self.samples[1].at > window do
		table.remove(self.samples, 1)
	end
	while #self.reversals > 0 and now - self.reversals[1] > window do
		table.remove(self.reversals, 1)
	end
end

-- Records the intended heading and counts a reversal when it turns sharply back to the heading
-- held before the previous sharp turn. Gentle drift just follows along and never counts.
local function trackHeading(self: Detector, dir: Vector3, now: number)
	local flat = NavMath.flat(dir)
	if flat.Magnitude < 1e-6 then
		return
	end
	local heading = flat.Unit
	local lastDir = self.lastDir
	if lastDir and math.abs(NavMath.turnAngle(lastDir, heading)) > REVERSAL_TURN then
		local previousDir = self.previousDir
		if previousDir and math.abs(NavMath.turnAngle(previousDir, heading)) < REVERSAL_BACK then
			table.insert(self.reversals, now)
		end
		self.previousDir = lastDir
	end
	self.lastDir = heading
end

-- Progress over the window as a share of what the intended speed predicted (1 when nothing sampled).
local function windowRatio(self: Detector): number
	local progress, expected = 0, 0
	for _, sample in self.samples do
		progress += sample.progress
		expected += sample.expected
	end
	if expected <= 0 then
		return 1
	end
	return progress / expected
end

-- `intendedSpeed` is what the command asks for (walkSpeed * magnitude), `remaining` the studs
-- left along the path as the follower reports them, `dir` the direction the command points
-- (optional: without it progress is the drop in `remaining` alone and oscillation is never seen).
function StuckDetector.update(
	self: Detector,
	body: BodyState,
	intendedSpeed: number,
	remaining: number,
	now: number,
	dir: Vector3?
): Verdict
	-- A long gap since the last update (the NPC was not walking) must not count as pushing.
	local dt = if self.lastTickAt then math.clamp(now - self.lastTickAt, 0, 0.5) else 0
	self.lastTickAt = now

	if now < self.suppressedUntil then
		self.lastSampleAt = now
		self.lastRemaining = remaining
		self.lastPosition = body.position
		self.pushTime = 0
		self.samples = {}
		clearHeading(self)
		return "ok"
	end
	if intendedSpeed <= 0.05 then
		self:reset(now)
		return "ok"
	end
	if not body.onGround then
		-- Jump arcs never count either way.
		self.lastSampleAt = now
		self.lastRemaining = remaining
		self.lastPosition = body.position
		return "ok"
	end

	if self.lastRemaining == nil then
		self.lastSampleAt = now
		self.lastRemaining = remaining
		self.lastPosition = body.position
	elseif now - self.lastSampleAt >= self.sampleInterval then
		local elapsed = now - self.lastSampleAt
		local expected = intendedSpeed * elapsed * self.progressRatio
		local progress = (self.lastRemaining :: number) - remaining
		local lastPosition = self.lastPosition
		if dir and lastPosition then
			local along = NavMath.flat(dir)
			if along.Magnitude > 1e-6 then
				progress += NavMath.flat(body.position - lastPosition):Dot(along.Unit)
			end
		end
		if progress < expected then
			self.stuckTime += elapsed
		else
			self.stuckTime = math.max(0, self.stuckTime - elapsed * 2)
		end
		table.insert(self.samples, { at = now, progress = progress, expected = intendedSpeed * elapsed })
		self.lastSampleAt = now
		self.lastRemaining = remaining
		self.lastPosition = body.position
	end
	if dir then
		trackHeading(self, dir, now)
	end
	pruneWindow(self, now)

	local horizontalSpeed = NavMath.flat(body.velocity).Magnitude
	if horizontalSpeed < self.pushRatio * intendedSpeed then
		self.pushTime += dt
	else
		self.pushTime = 0
	end

	if #self.reversals >= self.oscillationReversals and windowRatio(self) < self.oscillationRatio then
		return "oscillating"
	end
	if self.pushTime >= self.wallCappedAfter then
		return "wallCapped"
	end
	if self.stuckTime >= self.stuckAfter then
		return "stuck"
	end
	if self.pushTime >= self.pushAfter then
		return "pushing"
	end
	return "ok"
end

return StuckDetector

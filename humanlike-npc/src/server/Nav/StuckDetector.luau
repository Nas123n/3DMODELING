--!strict
-- Notices when a walking body is not getting anywhere. Two signals, both about progress rather
-- than raw velocity, because a humanoid sliding along a wall has velocity but no progress and a
-- humanoid pushing a wall has intent but no velocity:
--   "stuck"   progress along the path has fallen well below what the intended speed predicts
--             for about a second (a brief snag decays away twice as fast as it accrues)
--   "pushing" on the ground, trying to move, and barely moving for 0.6 s (face-first wall contact)
-- Scripted no-progress moments (a deliberate wall bump, a pause) suppress it for a bounded time.

local NavMath = require(script.Parent.NavMath)
local Types = require(script.Parent.Parent.Types)

type BodyState = Types.BodyState

local StuckDetector = {}
StuckDetector.__index = StuckDetector

export type Verdict = "ok" | "stuck" | "pushing"

export type Options = {
	stuckAfter: number?, -- seconds of poor progress before "stuck"; persona patience, default 1.1
	pushAfter: number?, -- default 0.6
	sampleInterval: number?, -- default 0.25
	progressRatio: number?, -- progress below this share of ideal counts as poor; default 0.3
	pushRatio: number?, -- speed below this share of intended counts as pushing; default 0.25
}

export type Detector = typeof(setmetatable(
	{} :: {
		stuckAfter: number,
		pushAfter: number,
		sampleInterval: number,
		progressRatio: number,
		pushRatio: number,
		lastSampleAt: number,
		lastRemaining: number?,
		stuckTime: number,
		pushTime: number,
		lastTickAt: number?,
		suppressedUntil: number,
	},
	StuckDetector
))

function StuckDetector.new(options: Options?): Detector
	local o: Options = options or {}
	return setmetatable({
		stuckAfter = o.stuckAfter or 1.1,
		pushAfter = o.pushAfter or 0.6,
		sampleInterval = o.sampleInterval or 0.25,
		progressRatio = o.progressRatio or 0.3,
		pushRatio = o.pushRatio or 0.25,
		lastSampleAt = -math.huge,
		lastRemaining = nil,
		stuckTime = 0,
		pushTime = 0,
		lastTickAt = nil,
		suppressedUntil = -math.huge,
	}, StuckDetector)
end

function StuckDetector.reset(self: Detector, now: number)
	self.lastSampleAt = now
	self.lastRemaining = nil
	self.stuckTime = 0
	self.pushTime = 0
end

-- Ignore lack of progress until `untilTime` (capped at 3 s from now: nothing scripted lasts longer).
function StuckDetector.suppress(self: Detector, now: number, untilTime: number)
	self.suppressedUntil = math.min(untilTime, now + 3)
end

function StuckDetector.isSuppressed(self: Detector, now: number): boolean
	return now < self.suppressedUntil
end

-- `intendedSpeed` is what the command asks for (walkSpeed * magnitude), `remaining` the studs
-- left along the path as the follower reports them.
function StuckDetector.update(
	self: Detector,
	body: BodyState,
	intendedSpeed: number,
	remaining: number,
	now: number
): Verdict
	local dt = if self.lastTickAt then math.max(0, now - self.lastTickAt) else 0
	self.lastTickAt = now

	if now < self.suppressedUntil then
		self.lastSampleAt = now
		self.lastRemaining = remaining
		self.pushTime = 0
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
		return "ok"
	end

	if self.lastRemaining == nil then
		self.lastSampleAt = now
		self.lastRemaining = remaining
	elseif now - self.lastSampleAt >= self.sampleInterval then
		local elapsed = now - self.lastSampleAt
		local expected = intendedSpeed * elapsed * self.progressRatio
		local progress = (self.lastRemaining :: number) - remaining
		if progress < expected then
			self.stuckTime += elapsed
		else
			self.stuckTime = math.max(0, self.stuckTime - elapsed * 2)
		end
		self.lastSampleAt = now
		self.lastRemaining = remaining
	end

	local horizontalSpeed = NavMath.flat(body.velocity).Magnitude
	if horizontalSpeed < self.pushRatio * intendedSpeed then
		self.pushTime += dt
	else
		self.pushTime = 0
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

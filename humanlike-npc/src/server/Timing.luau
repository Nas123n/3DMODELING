--!strict
-- Timing primitives that make NPC events look human rather than scheduled. People react with a
-- delay that has a long tail, act in bursts separated by heavy-tailed gaps, and drift rather
-- than jitter. Everything here draws from a seeded Rng and an injected `now`, so it is exact in
-- tests and deterministic per NPC.
-- requires: Rng

local Rng = require(script.Parent.Rng)

type Rng = Rng.Rng

local Timing = {}

-- Reaction delay to an expected stimulus (someone walks up) or an unexpected one (someone
-- speaks to you). Ex-Gaussian shapes from the research, scaled by the persona.
function Timing.reaction(rng: Rng, expected: boolean, scale: number?): number
	local s = scale or 1
	if expected then
		return math.clamp(rng:exGaussian(0.6, 0.15, 0.8), 0.25, 6) * s
	end
	return math.clamp(rng:exGaussian(1.4, 0.4, 2.0), 0.5, 8) * s
end

-- Geometric count in [min, max]: number of jumps in a burst, messages in a row.
function Timing.geometric(rng: Rng, p: number, min: number, max: number?): number
	local u = rng:next()
	local n = min + math.floor(math.log(1 - u) / math.log(1 - math.clamp(p, 1e-6, 1 - 1e-6)))
	return math.min(n, max or math.huge)
end

-- Ornstein-Uhlenbeck step: mean-reverting noise (heading tremor, analog stick magnitude).
function Timing.stepOu(rng: Rng, x: number, theta: number, sigma: number, dt: number): number
	return x - theta * x * dt + sigma * math.sqrt(math.max(dt, 0)) * rng:normal()
end

-- A process that fires in bursts: a burst has a physics- or typing-pinned rhythm, bursts are
-- separated by log-normal gaps, and successive gaps are correlated (which memoryless rates
-- never are). Used for jump spam, chat spurts and emote contagion.
local Burst = {}
Burst.__index = Burst

export type BurstOptions = {
	interMedian: number, -- median seconds between bursts
	interSpread: number, -- log-normal sigma of that gap
	withinMean: number, -- seconds between events inside a burst
	withinDev: number,
	withinLo: number,
	withinHi: number,
	lengthP: number, -- geometric parameter for burst length (0.35 -> mean about 3)
	maxLength: number?, -- cap on events per burst
	interLo: number?, -- default 1
	interHi: number?, -- default 3600
}

export type Burst = typeof(setmetatable(
	{} :: {
		rng: Rng,
		options: BurstOptions,
		nextAt: number,
		remaining: number,
		fired: number,
	},
	Burst
))

local function scheduleGap(self: Burst, now: number)
	local o = self.options
	self.nextAt = now + self.rng:logNormalClamped(o.interMedian, o.interSpread, o.interLo or 1, o.interHi or 3600)
	self.remaining = 0
end

function Timing.newBurst(rng: Rng, options: BurstOptions, now: number): Burst
	local self = setmetatable({ rng = rng, options = options, nextAt = 0, remaining = 0, fired = 0 }, Burst)
	scheduleGap(self, now)
	return self
end

-- Returns true when an event fires now. Call at any rate; it never fires more than once per call.
function Burst.poll(self: Burst, now: number): boolean
	if now < self.nextAt then
		return false
	end
	local o = self.options
	if self.remaining == 0 then
		-- Start a burst: fire immediately, queue the rest.
		self.remaining = Timing.geometric(self.rng, o.lengthP, 1, o.maxLength) - 1
	else
		self.remaining -= 1
	end
	self.fired += 1
	if self.remaining > 0 then
		self.nextAt = now + math.clamp(self.rng:gaussian(o.withinMean, o.withinDev), o.withinLo, o.withinHi)
	else
		scheduleGap(self, now)
	end
	return true
end

-- Multiplies the gap between bursts (mood: bored NPCs fidget more, i.e. scale < 1).
function Burst.scaleGap(self: Burst, now: number, factor: number)
	if self.remaining == 0 and self.nextAt > now then
		self.nextAt = now + (self.nextAt - now) * factor
	end
end

-- Forces the next burst to start no later than `at`.
function Burst.nudge(self: Burst, at: number)
	if self.remaining == 0 then
		self.nextAt = math.min(self.nextAt, at)
	end
end

-- Poisson-like single events with a log-normal gap: the "every so often" timer.
local Every = {}
Every.__index = Every

export type Every = typeof(setmetatable(
	{} :: { rng: Rng, median: number, spread: number, lo: number, hi: number, nextAt: number },
	Every
))

function Timing.newEvery(rng: Rng, median: number, spread: number, lo: number, hi: number, now: number): Every
	local self = setmetatable({ rng = rng, median = median, spread = spread, lo = lo, hi = hi, nextAt = 0 }, Every)
	self.nextAt = now + rng:logNormalClamped(median, spread, lo, hi)
	return self
end

function Every.poll(self: Every, now: number): boolean
	if now < self.nextAt then
		return false
	end
	self.nextAt = now + self.rng:logNormalClamped(self.median, self.spread, self.lo, self.hi)
	return true
end

function Every.delay(self: Every, seconds: number)
	self.nextAt = math.max(self.nextAt, seconds)
end

return Timing

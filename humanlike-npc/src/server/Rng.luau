--!strict
-- Deterministic xorshift32 generator. The same seed always reproduces the same NPC, which is
-- what makes behavior testable, and unlike Roblox's Random it also runs in plain Luau under Lune.
-- Beyond the uniform basics it offers the shapes human timing actually has: normal (jitter),
-- log-normal (reaction times, dwell times: right-skewed with a long tail) and exponential
-- (waiting times between bursts).

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

local UINT32 = 4294967296

local function hashString(text: string): number
	-- djb2 (xor variant); h * 33 stays far below 2^53, and bit32 reduces it mod 2^32.
	local h = 5381
	for i = 1, #text do
		h = bit32.bxor(h * 33, string.byte(text, i))
	end
	return h
end

function Rng.new(seed: number | string): Rng
	local state = if type(seed) == "string" then hashString(seed) else bit32.band(math.floor(seed), 0xFFFFFFFF)
	if state == 0 then
		state = 0x9E3779B9 -- xorshift gets stuck on zero
	end
	local self = setmetatable({ state = state }, Rng)
	-- Nearby seeds start out correlated; a few rounds spreads them apart.
	for _ = 1, 8 do
		self:nextUInt()
	end
	return self
end

function Rng.nextUInt(self: Rng): number
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x
end

-- Uniform float in [0, 1).
function Rng.next(self: Rng): number
	return self:nextUInt() / UINT32
end

-- Uniform float in [lo, hi).
function Rng.range(self: Rng, lo: number, hi: number): number
	return lo + (hi - lo) * self:next()
end

-- Uniform integer in [lo, hi], inclusive.
function Rng.int(self: Rng, lo: number, hi: number): number
	return lo + math.floor(self:next() * (hi - lo + 1))
end

function Rng.chance(self: Rng, probability: number): boolean
	return self:next() < probability
end

function Rng.sign(self: Rng): number
	return if self:next() < 0.5 then -1 else 1
end

function Rng.pick<T>(self: Rng, list: { T }): T
	assert(#list > 0, "Rng:pick called with an empty list")
	return list[self:int(1, #list)]
end

-- Picks an index with probability proportional to its weight. Weights <= 0 are never picked.
function Rng.weightedIndex(self: Rng, weights: { number }): number
	local total = 0
	for _, w in weights do
		if w > 0 then
			total += w
		end
	end
	assert(total > 0, "Rng:weightedIndex needs at least one positive weight")
	local roll = self:next() * total
	for i, w in weights do
		if w > 0 then
			roll -= w
			if roll < 0 then
				return i
			end
		end
	end
	-- Floating point can leave a hair of roll; return the last positive weight.
	for i = #weights, 1, -1 do
		if weights[i] > 0 then
			return i
		end
	end
	return 1
end

-- In-place Fisher-Yates shuffle.
function Rng.shuffle<T>(self: Rng, list: { T })
	for i = #list, 2, -1 do
		local j = self:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

-- Standard normal via Box-Muller (mean 0, deviation 1).
function Rng.normal(self: Rng): number
	local u1 = 1 - self:next() -- (0, 1], keeps log() finite
	local u2 = self:next()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Normal with the given mean and standard deviation.
function Rng.gaussian(self: Rng, mean: number, deviation: number): number
	return mean + deviation * self:normal()
end

-- Log-normal sample whose median is `median`; `spread` is the sigma of the underlying normal
-- (0.3 is a mild skew, 0.8 a long tail). Human reaction and dwell times look like this.
function Rng.logNormal(self: Rng, median: number, spread: number): number
	return median * math.exp(spread * self:normal())
end

-- Exponential waiting time with the given mean (memoryless gaps between events).
function Rng.exponential(self: Rng, mean: number): number
	return -mean * math.log(1 - self:next())
end

-- Independent child generator, so adding a consumer doesn't reshuffle every other one.
function Rng.fork(self: Rng, salt: string): Rng
	return Rng.new(bit32.bxor(self:nextUInt(), hashString(salt)))
end

-- Stable hash for turning names into seeds (exposed so spawners can derive per-NPC seeds).
Rng.hash = hashString

return Rng

--!strict
-- Small deterministic xorshift32 generator. The same seed always rebuilds the same
-- decorations, and unlike Roblox's Random it also runs in plain Luau (tests, Lune preview).

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

-- Independent child generator, so adding a prop type doesn't reshuffle every other prop.
function Rng.fork(self: Rng, salt: string): Rng
	return Rng.new(bit32.bxor(self:nextUInt(), hashString(salt)))
end

return Rng

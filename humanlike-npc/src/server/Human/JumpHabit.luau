--!strict
-- Jumping for no reason is the most visible fidget in Roblox, and it is bimodal: some players
-- never touch space outside navigation, some mash it in bursts. Each NPC is frozen into one
-- tier; bursts come from a bursty process whose rhythm is pinned by airtime; the rate follows
-- mood; keyboard players cannot jump while typing; and a jump seen nearby is sometimes copied a
-- second or two later (the mirroring that made BotPrize bots read as human).
-- requires: InputProfile, Rng, Timing

local Rng = require(script.Parent.Parent.Rng)
local Timing = require(script.Parent.Parent.Timing)
local InputProfile = require(script.Parent.InputProfile)

type Rng = Rng.Rng
type Profile = InputProfile.Profile

local JumpHabit = {}
JumpHabit.__index = JumpHabit

-- "never" | "occasional" | "spammer"
export type Tier = string

-- "bored" | "engaged" | "social" | "afk" | "neutral" | any other mood name (treated as neutral)
export type Mood = string

export type Habit = typeof(setmetatable(
	{} :: {
		rng: Rng,
		tier: Tier,
		profile: Profile,
		walking: Timing.Burst?,
		idle: Timing.Burst?,
		mirrorAt: number?,
		lastMirrorAt: number,
		moodScale: number,
	},
	JumpHabit
))

JumpHabit.TIER_WEIGHTS = { never = 40, occasional = 35, spammer = 25 }

local MOOD_SCALE: { [Mood]: number } = { bored = 1.6, engaged = 0.7, social = 1.3, afk = 0, neutral = 1 }

function JumpHabit.pickTier(rng: Rng): Tier
	local index = rng:weightedIndex({
		JumpHabit.TIER_WEIGHTS.never,
		JumpHabit.TIER_WEIGHTS.occasional,
		JumpHabit.TIER_WEIGHTS.spammer,
	})
	local tiers = { "never", "occasional", "spammer" }
	return tiers[index]
end

local function burstFor(rng: Rng, tier: Tier, walking: boolean, profile: Profile, now: number): Timing.Burst?
	if tier == "never" then
		return nil
	end
	local scale = 1 / math.max(profile.jumpRateScale, 0.05)
	local interMedian, lengthP, maxLength
	if tier == "occasional" then
		interMedian = (if walking then 45 else 90) * scale
		lengthP, maxLength = 0.6, 3
	else
		interMedian = (if walking then 12 else 25) * scale
		lengthP, maxLength = 0.35, 12
	end
	if profile.analog then
		maxLength = math.min(maxLength, 2)
	end
	return Timing.newBurst(rng, {
		interMedian = interMedian,
		interSpread = if walking then 0.8 else 0.9,
		withinMean = 0.68,
		withinDev = 0.04,
		withinLo = 0.6,
		withinHi = 0.78,
		lengthP = lengthP,
		maxLength = maxLength,
	}, now)
end

function JumpHabit.new(rng: Rng, profile: Profile, now: number, tier: Tier?): Habit
	local t = tier or JumpHabit.pickTier(rng)
	return setmetatable({
		rng = rng,
		tier = t,
		profile = profile,
		walking = burstFor(rng:fork("jump:walk"), t, true, profile, now),
		idle = burstFor(rng:fork("jump:idle"), t, false, profile, now),
		mirrorAt = nil,
		lastMirrorAt = -math.huge,
		moodScale = 1,
	}, JumpHabit)
end

-- Mood changes the gap between bursts (bored people fidget more).
function JumpHabit.setMood(self: Habit, mood: Mood, now: number)
	local scale = MOOD_SCALE[mood] or 1
	if scale == self.moodScale then
		return
	end
	local factor = if scale <= 0 then math.huge else self.moodScale / scale
	self.moodScale = scale
	for _, burst in { self.walking, self.idle } do
		if burst and factor ~= math.huge then
			burst:scaleGap(now, factor)
		end
	end
end

-- Someone within a few studs jumped: maybe copy it, once per 8 s.
function JumpHabit.mirror(self: Habit, now: number)
	if self.tier == "never" or now - self.lastMirrorAt < 8 or self.mirrorAt then
		return
	end
	if self.rng:chance(0.7) then
		self.mirrorAt = now + self.rng:range(1, 3)
		self.lastMirrorAt = now
	end
end

-- True when the NPC wants to jump right now for no navigational reason.
function JumpHabit.poll(self: Habit, now: number, moving: boolean, onGround: boolean, typing: boolean): boolean
	if not onGround or self.moodScale <= 0 then
		return false
	end
	if typing and not self.profile.analog then
		return false -- space goes into the chat box
	end
	if self.mirrorAt and now >= self.mirrorAt then
		self.mirrorAt = nil
		return true
	end
	local burst = if moving then self.walking else self.idle
	if not burst then
		return false
	end
	return burst:poll(now)
end

return JumpHabit

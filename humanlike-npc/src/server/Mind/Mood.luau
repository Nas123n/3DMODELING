--!strict
-- A labelled mood with a minimum dwell, so the NPC's colour persists for minutes instead of
-- flickering with every need tick (design-mind §4.4). Moods are reviewed every ~20 s (or at once
-- on a salient event, via `force`); entry conditions are checked in a fixed priority order and a
-- higher-priority mood may cut a dwell short while a lower one waits for minUntil. The mood also
-- carries an annoyance level that probes raise and a 180 s time constant drains. The multiplier
-- table is the single place that says how each mood skews fidgeting, chat, emotes, mirroring,
-- reaction delay, interrupt sensitivity, need drift and activity utilities.

local Needs = require(script.Parent.Needs)
local Personality = require(script.Parent.Personality)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng
type Persona = Personality.Persona
type Needs = Needs.Needs

local Mood = {}

-- "neutral" | "engaged" | "bored" | "social" | "playful" | "annoyed" | "zoned"
export type MoodName = string

export type Mood = {
	name: MoodName,
	since: number,
	minUntil: number,
	annoyance: number, -- mood-level annoyance 0..1, tau 180 s
	nextReviewAt: number,
	lastAnnoyanceAt: number, -- when annoyance was last decayed
}

export type MoodContext = {
	nearbyCount: number,
	inGroup: boolean,
	recentJumpsAndEmotes: number, -- by others within 15 studs in the last 20 s
	probeCount2min: number,
	activity: string?,
	maxRelationAnnoyance: number, -- SocialGuard.maxAnnoyance()
}

local ANNOYANCE_TAU = 180

-- Lower number wins; the order of the entry conditions in §4.4.
local PRIORITY: { [string]: number } = {
	annoyed = 1,
	zoned = 2,
	playful = 3,
	social = 4,
	bored = 5,
	engaged = 6,
	neutral = 7,
}

local ENGAGING_ACTIVITIES: { [string]: boolean } = { VisitPoi = true, Explore = true, StandOnProp = true }

-- Multiplier table (§4.4), rows are keys, columns moods; 1 wherever a cell is omitted.
local TABLE: { [string]: { [string]: number } } = {
	fidget = { engaged = 0.6, bored = 2.2, social = 1.3, playful = 2.5, annoyed = 0.8, zoned = 0.15 },
	chat = { engaged = 0.7, bored = 1.4, social = 2.0, playful = 1.5, annoyed = 0.9, zoned = 0.1 },
	emote = { engaged = 0.5, bored = 1.6, social = 1.8, playful = 2.5, annoyed = 0.3, zoned = 0 },
	mirror = { engaged = 0.6, bored = 1.1, social = 1.3, playful = 1.6, annoyed = 0.2, zoned = 0 },
	reaction = { engaged = 1.3, bored = 0.9, social = 0.9, playful = 0.8, annoyed = 0.9, zoned = 2.5 },
	interrupt = { engaged = 0.7, bored = 1.3, social = 1.2, playful = 1.3, annoyed = 1.1, zoned = 0.4 },
	["drift.boredom"] = { engaged = 0.8, bored = 1.5, social = 0.9, playful = 0.9, annoyed = 1.1, zoned = 0.3 },
	["drift.social"] = { engaged = 0.9, bored = 1.2, social = 1.5, playful = 1.2, annoyed = 0.5, zoned = 0.3 },
	["drift.fatigue"] = { engaged = 0.8, bored = 1.3, social = 0.9, playful = 0.8, annoyed = 1.2, zoned = 1.5 },
	["activity.Afk"] = { engaged = 0.4, bored = 1.2, social = 0.5, playful = 0.4, annoyed = 1.3, zoned = 4.0 },
	["activity.JoinGroup"] = { engaged = 0.7, bored = 1.2, social = 2.0, playful = 1.6, annoyed = 0.3, zoned = 0.2 },
	["activity.Follow"] = { engaged = 0.6, bored = 1.3, social = 1.6, playful = 1.5, annoyed = 0.2, zoned = 0.1 },
	["activity.VisitPoi"] = { engaged = 1.5, bored = 0.8, social = 0.8, playful = 0.8, annoyed = 1.0, zoned = 0.5 },
	["activity.Explore"] = { engaged = 1.2, bored = 1.3, social = 0.7, playful = 0.9, annoyed = 1.1, zoned = 0.3 },
	["activity.Pace"] = { engaged = 0.5, bored = 1.8, social = 0.8, playful = 1.2, annoyed = 1.4, zoned = 0.6 },
	["activity.StandOnProp"] = { engaged = 0.6, bored = 1.8, social = 1.0, playful = 2.0, annoyed = 0.5, zoned = 0.2 },
	["activity.Watch"] = { engaged = 0.7, bored = 1.3, social = 1.4, playful = 1.0, annoyed = 0.5, zoned = 0.5 },
	["activity.Leave"] = { engaged = 0.8, bored = 1.2, social = 0.8, playful = 0.8, annoyed = 2.0, zoned = 1.2 },
}

local function reviewDelay(rng: Rng): number
	return rng:logNormalClamped(20, 0.5, 8, 60)
end

function Mood.new(now: number, rng: Rng): Mood
	return {
		name = "neutral",
		since = now,
		minUntil = now,
		annoyance = 0,
		nextReviewAt = now + reviewDelay(rng),
		lastAnnoyanceAt = now,
	}
end

local function decayAnnoyance(mood: Mood, now: number)
	local dt = now - mood.lastAnnoyanceAt
	if dt > 0 then
		mood.annoyance *= math.exp(-dt / ANNOYANCE_TAU)
		mood.lastAnnoyanceAt = now
	end
end

-- Which mood the conditions call for right now, first true wins (§4.4).
local function evaluate(mood: Mood, needs: Needs, ctx: MoodContext, persona: Persona): MoodName
	local annoyance = math.max(mood.annoyance, ctx.maxRelationAnnoyance)
	if annoyance > 0.5 or ctx.probeCount2min >= 3 then
		return "annoyed"
	end
	if needs.fatigue > 0.70 then
		return "zoned"
	end
	if (ctx.recentJumpsAndEmotes >= 2 and persona.jumpiness > 0.4) or (ctx.inGroup and persona.jumpiness > 0.6) then
		return "playful"
	end
	if needs.social > 0.55 and ctx.nearbyCount >= 1 then
		return "social"
	end
	if needs.boredom > 0.65 then
		return "bored"
	end
	if needs.purpose > 0.5 and ctx.activity ~= nil and ENGAGING_ACTIVITIES[ctx.activity] then
		return "engaged"
	end
	return "neutral"
end

-- Reviews the mood when due (or when `force`); returns true when the name changed. The current
-- mood is kept while now < minUntil unless a higher-priority condition holds.
function Mood.update(
	mood: Mood,
	now: number,
	needs: Needs,
	ctx: MoodContext,
	persona: Persona,
	rng: Rng,
	force: boolean?
): boolean
	decayAnnoyance(mood, now)
	if not force and now < mood.nextReviewAt then
		return false
	end
	mood.nextReviewAt = now + reviewDelay(rng)

	local candidate = evaluate(mood, needs, ctx, persona)
	if candidate == mood.name then
		return false
	end
	local dwelling = now < mood.minUntil
	local higher = (PRIORITY[candidate] or 99) < (PRIORITY[mood.name] or 99)
	if dwelling and not higher then
		return false
	end
	mood.name = candidate
	mood.since = now
	mood.minUntil = now + rng:logNormalClamped(90, 0.6, 20, 600)
	return true
end

-- Probes raise it (+0.2 followed/stared/onHead, +0.35 blocked, +0.3 bot probe, +0.5 stop keyword,
-- +0.15 per repeated unanswered direct chat); it decays with tau 180 s.
function Mood.raiseAnnoyance(mood: Mood, amount: number, now: number)
	decayAnnoyance(mood, now)
	mood.annoyance = math.clamp(mood.annoyance + amount, 0, 1)
end

function Mood.multiplier(name: MoodName, key: string): number
	local row = TABLE[key]
	if not row then
		return 1
	end
	local value = row[name]
	return if value == nil then 1 else value
end

-- Lower is more urgent; unknown names sort last.
function Mood.priority(name: MoodName): number
	return PRIORITY[name] or 99
end

return Mood

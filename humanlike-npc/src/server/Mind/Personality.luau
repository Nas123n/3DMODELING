--!strict
-- Who this NPC is, sampled once and never changed: a person is consistent with themselves and
-- different from everyone else. Trait distributions encode the real population's skew (most
-- players are mildly social, most never chat, jumping is bimodal), and everything downstream
-- (the humanizer, the jump habit, the chat voice, the brain's utilities) reads its numbers from
-- here instead of rolling its own.
--
-- The draw order in `sample` is pinned: the 14 traits and the derived values come from the
-- "persona" stream, the input profile and chat voice from its "profile" and "voice" forks, and
-- the later additions (rig, AFK style, spaces, animation pack, presentation, ...) from a
-- "persona2" fork taken after the last draw of the first stream, so adding them changed no
-- earlier value. Anything added later goes at the end of the "persona2" list, never before.
--
-- This module is pure: it reads no clock, no world and no Config (tunables such as the R6 share
-- arrive through Options), and it decides nothing about behaviour; it only describes a person.
-- requires: ChatStyle, InputProfile, Rng

local Rng = require(script.Parent.Parent.Rng)
local InputProfile = require(script.Parent.Parent.Human.InputProfile)
local ChatStyle = require(script.Parent.Parent.Chat.ChatStyle)

type Rng = Rng.Rng

local Personality = {}

-- "kid" | "teen" | "older"
export type Dialect = string

-- Animation pack names, in a fixed order so the weighted pick never depends on table iteration.
-- The shared AnimSets module (the per-pack asset ids the client animator plays) must use exactly
-- these names as its pack keys; "default" is the standard R15 set every install has.
local PACKS: { string } = {
	"default",
	"rthro",
	"cartoony",
	"levitation",
	"ninja",
	"toy",
	"zombie",
	"elder",
	"bubbly",
	"astronaut",
}
Personality.PACKS = PACKS

-- Base share of each pack among the population (sums to 100; "default" is about 60%). The per
-- persona biases live in `packWeights`.
local PACK_WEIGHTS: { [string]: number } = {
	default = 60,
	rthro = 10,
	cartoony = 8,
	levitation = 2,
	ninja = 4,
	toy = 3,
	zombie = 3,
	elder = 3,
	bubbly = 4,
	astronaut = 3,
}
Personality.PACK_WEIGHTS = PACK_WEIGHTS

-- Account age (days) below which a player still runs the default animations (they have not
-- bought a pack yet).
local NEWCOMER_DAYS = 30

-- "sweeper" | "locked" | "twitchy" at 40 / 40 / 20.
local CAMERA_STYLES: { string } = { "sweeper", "locked", "twitchy" }
local CAMERA_STYLE_WEIGHTS: { number } = { 40, 40, 20 }

-- "m" | "f" | "any" at 45 / 45 / 10.
local PRESENTATIONS: { string } = { "m", "f", "any" }
local PRESENTATION_WEIGHTS: { number } = { 45, 45, 10 }

export type Persona = {
	-- Traits in [0, 1]
	sociability: number,
	curiosity: number,
	patience: number,
	jumpiness: number,
	chattiness: number,
	afkProneness: number,
	trolliness: number,
	skill: number,
	impulsivity: number,
	friendliness: number,
	helpfulness: number,
	mirroring: number,
	attention: number,
	emoteHabit: number,
	-- Derived
	accountAge: number, -- 0 new .. 1 veteran
	dialect: Dialect,
	profile: InputProfile.Profile,
	voice: ChatStyle.Voice,
	jumpTier: string, -- "never" | "occasional" | "spammer"
	reactionScale: number, -- multiplies reaction delays
	missChance: number, -- chance a stimulus is not noticed at all
	walkSpeed: number,
	sessionLength: number, -- seconds
	-- Humanizer knobs
	caution: number,
	stopBiasStuds: number,
	aboutFaceRate: number,
	wallBumpRate: number,
	-- Additions drawn from the "persona2" fork, in this order (enum-like fields are plain strings)
	sloppiness: number, -- [0, 1]: deliberate edge falls, chat typo scaling
	restlessness: number, -- [0, 1]: pacing and wander weights
	attachmentProneness: number, -- [0, 1]: how easily someone becomes "the friend"
	rig: string, -- "R15" | "R6"
	afkStyle: string, -- "full" (attention off, no fidgets) | "semi" (attention delays x3, no turning)
	personalSpace: number, -- studs: standing ring distance from strangers
	friendSpace: number, -- studs: standing ring distance from friends and the attachment
	animPack: string, -- one of PACKS
	slangSeed: number, -- integer in [1, 1e6]: chat tag/typo phrase choices
	favoritePoiKind: string?, -- nil here; the service fills it once it knows the place's POI kinds
	pointlessTarget: number, -- share of Wander goals that go nowhere in particular (already scaled)
	rudenessCap: number, -- 0 (rude corpus lines never) | 1 (rude lines allowed at all)
	sitHabit: number, -- [0, 1]: probability weight for seats at hangouts
	cameraStyle: string, -- "sweeper" | "locked" | "twitchy": idle yaw sweep rate, shift-lock profiles only
	presentation: string, -- "m" | "f" | "any": filters gendered hair and hats
	-- Derived from accountAge (no draw)
	accountAgeDays: number, -- 3 .. 3000
	familiarity: number, -- 1 - exp(-accountAgeDays / 90): how well this person knows the platform
}

export type Options = {
	walkSpeedMedian: number?, -- default 16
	walkSpeedSpread: number?, -- log-normal sigma of the boosted share; 0 = everyone at the median
	walkSpeedMax: number?, -- default 32
	sessionMedianMinutes: number?, -- default 15
	sessionMaxMinutes: number?, -- default 240
	profileKind: string?, -- force an input profile
	r6Share: number?, -- probability of an R6 rig, default 0.05 (the service passes its R6Share)
}

local function mixture(rng: Rng, parts: { { number } }): number
	-- parts: { weight, a, b }
	local weights = {}
	for i, part in parts do
		weights[i] = part[1]
	end
	local pick = parts[rng:weightedIndex(weights)]
	return rng:kumaraswamy(pick[2], pick[3])
end

-- Pack weights for one persona, indexed like PACKS: newcomers run the default animations three
-- times as often (nobody buys a pack in their first month) and trolls lean to zombie and ninja.
function Personality.packWeights(accountAgeDays: number, trolliness: number): { number }
	local weights: { number } = {}
	for i, name in PACKS do
		local weight = PACK_WEIGHTS[name]
		if name == "default" and accountAgeDays < NEWCOMER_DAYS then
			weight *= 3
		end
		if trolliness > 0.7 and (name == "zombie" or name == "ninja") then
			weight *= 2
		end
		weights[i] = weight
	end
	return weights
end

function Personality.sample(seed: Rng, options: Options?): Persona
	local o: Options = options or {}
	local rng = seed:fork("persona")
	local accountAge = rng:kumaraswamy(1.2, 1.8)

	local sociability = rng:kumaraswamy(1.6, 1.8)
	local curiosity = rng:kumaraswamy(1.8, 1.4)
	local patience = rng:kumaraswamy(1.5, 1.5)
	local jumpiness = mixture(rng, { { 40, 1, 6 }, { 35, 2, 2 }, { 25, 6, 1 } })
	local chattiness = mixture(rng, { { 60, 1, 12 }, { 30, 2, 3 }, { 10, 4, 1.3 } })
	local afkProneness = rng:kumaraswamy(1.3, 2.5)
	local trolliness = rng:kumaraswamy(1, 4)
	local skill = math.clamp(0.35 + 0.6 * rng:kumaraswamy(2, 1.6) + 0.15 * accountAge, 0, 1)
	local impulsivity = rng:kumaraswamy(1.7, 1.7)
	local friendliness = rng:kumaraswamy(2, 1.6)
	local helpfulness = rng:kumaraswamy(1.4, 2.2)
	local mirroring = rng:kumaraswamy(1.5, 2)
	local attention = rng:kumaraswamy(2.2, 1.6)
	local emoteHabit = mixture(rng, { { 55, 1, 7 }, { 45, 2, 2 } })

	local dialect: Dialect
	local roll = rng:next()
	if accountAge < 0.35 then
		dialect = if roll < 0.7 then "kid" else "teen"
	elseif accountAge < 0.7 then
		dialect = if roll < 0.65 then "teen" elseif roll < 0.85 then "kid" else "older"
	else
		dialect = if roll < 0.6 then "older" else "teen"
	end

	local profile = InputProfile.sample(rng:fork("profile"), o.profileKind)
	local typingSkill = if dialect == "kid" then 0.15 elseif dialect == "teen" then 0.55 else 0.85
	local voiceSloppiness = if dialect == "kid" then 0.8 elseif dialect == "teen" then 0.45 else 0.2
	local voice = ChatStyle.voice(rng:fork("voice"), profile.kind, typingSkill, voiceSloppiness)

	local jumpTier = if jumpiness < 0.25 then "never" elseif jumpiness < 0.7 then "occasional" else "spammer"
	local reactionScale = (if dialect == "kid" then 1.3 else 1) * (0.85 + 0.3 * (1 - attention))
	local missChance = 0.1 + 0.2 * (1 - attention)

	local median = o.walkSpeedMedian or 16
	local spread = o.walkSpeedSpread or 0
	local walkSpeed = median
	if spread > 0 and rng:chance(0.3) then
		walkSpeed = rng:logNormalClamped(median * 1.25, spread, median, o.walkSpeedMax or 32)
	end

	local sessionLength =
		rng:logNormalClamped((o.sessionMedianMinutes or 15) * 60, 0.9, 60, (o.sessionMaxMinutes or 240) * 60)
	local stopBiasStuds = math.clamp(rng:gaussian(0.8, 0.5), -0.5, 2)

	-- Everything below comes from its own stream, forked after the last draw above: the values
	-- above are byte-for-byte what they were before these fields existed. Derived values first,
	-- since they consume no draw and the pack pick needs them.
	local rng2 = rng:fork("persona2")
	local accountAgeDays = math.floor(3 * 1000 ^ accountAge)
	local familiarity = 1 - math.exp(-accountAgeDays / 90)

	local sloppiness = rng2:kumaraswamy(1.5, 2)
	local restlessness = rng2:kumaraswamy(2, 2)
	local attachmentProneness = rng2:kumaraswamy(1.2, 3)
	local rig = if rng2:chance(o.r6Share or 0.05) then "R6" else "R15"
	local afkStyle = if rng2:chance(0.3) then "semi" else "full"
	local personalSpace = rng2:range(4, 8)
	local friendSpace = rng2:range(1, 3)
	local animPack = PACKS[rng2:weightedIndex(Personality.packWeights(accountAgeDays, trolliness))]
	local slangSeed = rng2:int(1, 1000000)
	local pointlessTarget = rng2:range(0.2, 0.4) * (1.5 - 0.5 * familiarity)
	local rudenessCap = if trolliness < 0.6 then 0 else 1
	local sitHabit = rng2:kumaraswamy(1.5, 3)
	local cameraStyle = CAMERA_STYLES[rng2:weightedIndex(CAMERA_STYLE_WEIGHTS)]
	local presentation = PRESENTATIONS[rng2:weightedIndex(PRESENTATION_WEIGHTS)]

	return {
		sociability = sociability,
		curiosity = curiosity,
		patience = patience,
		jumpiness = jumpiness,
		chattiness = chattiness,
		afkProneness = afkProneness,
		trolliness = trolliness,
		skill = skill,
		impulsivity = impulsivity,
		friendliness = friendliness,
		helpfulness = helpfulness,
		mirroring = mirroring,
		attention = attention,
		emoteHabit = emoteHabit,
		accountAge = accountAge,
		dialect = dialect,
		profile = profile,
		voice = voice,
		jumpTier = jumpTier,
		reactionScale = reactionScale,
		missChance = missChance,
		walkSpeed = walkSpeed,
		sessionLength = sessionLength,
		caution = patience,
		stopBiasStuds = stopBiasStuds,
		aboutFaceRate = math.clamp(0.07 * (0.5 + impulsivity), 0.03, 0.12),
		wallBumpRate = math.clamp(0.02 * (1.5 - skill), 0.01, 0.03),
		sloppiness = sloppiness,
		restlessness = restlessness,
		attachmentProneness = attachmentProneness,
		rig = rig,
		afkStyle = afkStyle,
		personalSpace = personalSpace,
		friendSpace = friendSpace,
		animPack = animPack,
		slangSeed = slangSeed,
		favoritePoiKind = nil,
		pointlessTarget = pointlessTarget,
		rudenessCap = rudenessCap,
		sitHabit = sitHabit,
		cameraStyle = cameraStyle,
		presentation = presentation,
		accountAgeDays = accountAgeDays,
		familiarity = familiarity,
	}
end

-- Whether this persona ever chats on its own (the silent majority never does).
function Personality.isChatter(persona: Persona): boolean
	return persona.chattiness >= 0.2
end

return Personality

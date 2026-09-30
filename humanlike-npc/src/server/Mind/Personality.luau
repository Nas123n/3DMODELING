--!strict
-- Who this NPC is, sampled once and never changed: a person is consistent with themselves and
-- different from everyone else. Trait distributions encode the real population's skew (most
-- players are mildly social, most never chat, jumping is bimodal), and everything downstream
-- (the humanizer, the jump habit, the chat voice, the brain's utilities) reads its numbers from
-- here instead of rolling its own.

local Rng = require(script.Parent.Parent.Rng)
local InputProfile = require(script.Parent.Parent.Human.InputProfile)
local ChatStyle = require(script.Parent.Parent.Chat.ChatStyle)

type Rng = Rng.Rng

local Personality = {}

-- "kid" | "teen" | "older"
export type Dialect = string

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
}

export type Options = {
	walkSpeedMedian: number?, -- default 16
	walkSpeedSpread: number?, -- log-normal sigma of the boosted share; 0 = everyone at the median
	walkSpeedMax: number?, -- default 32
	sessionMedianMinutes: number?, -- default 15
	sessionMaxMinutes: number?, -- default 240
	profileKind: string?, -- force an input profile
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
	local sloppiness = if dialect == "kid" then 0.8 elseif dialect == "teen" then 0.45 else 0.2
	local voice = ChatStyle.voice(rng:fork("voice"), profile.kind, typingSkill, sloppiness)

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
		stopBiasStuds = math.clamp(rng:gaussian(0.8, 0.5), -0.5, 2),
		aboutFaceRate = math.clamp(0.07 * (0.5 + impulsivity), 0.03, 0.12),
		wallBumpRate = math.clamp(0.02 * (1.5 - skill), 0.01, 0.03),
	}
end

-- Whether this persona ever chats on its own (the silent majority never does).
function Personality.isChatter(persona: Persona): boolean
	return persona.chattiness >= 0.2
end

return Personality

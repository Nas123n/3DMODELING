--!strict
-- The five slow-moving pressures that make an NPC alternate between kinds of activity instead
-- of cycling through a list: boredom, social hunger, sense of purpose, fatigue and hunger for
-- novelty, each in [0, 1]. A need only rises on its own and only falls through the specific
-- activities that address it, which is what produces the grind -> bored -> pointless thing ->
-- social -> grind rhythm real players show (design-mind §4.3). Rates are per second and put a
-- full cycle in the 3-10 minute range; the running activity's engagement slows boredom, company
-- drains social, and the mood table (Mood.multiplier "drift.<need>") skews each rate.
-- requires: Personality, Rng

local Personality = require(script.Parent.Personality)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng
type Persona = Personality.Persona

local Needs = {}

export type Needs = {
	boredom: number,
	social: number,
	purpose: number,
	fatigue: number,
	novelty: number,
}

export type ReliefContext = {
	others: boolean?, -- someone else within radius / in my group (hangout visits, emotes)
	dt: number?, -- seconds, for the per-tick events (afkTick, idleTick)
}

-- Engagement E of each activity: how much of the NPC's attention it takes (1 freezes boredom).
Needs.ENGAGEMENT = {
	IdleStand = 0.1,
	Afk = 1.0,
	VisitPoi = 0.7,
	Explore = 0.9,
	Wander = 0.5,
	Follow = 0.6,
	JoinGroup = 0.6,
	Watch = 0.4,
	Pace = 0.3,
	StandOnProp = 0.8,
	FaceOff = 0.8,
	ReturnToSpawn = 0.4,
	ReactProbe = 0.7,
	Leave = 1.0,
} :: { [string]: number }

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

local function clampAll(needs: Needs)
	needs.boredom = clamp01(needs.boredom)
	needs.social = clamp01(needs.social)
	needs.purpose = clamp01(needs.purpose)
	needs.fatigue = clamp01(needs.fatigue)
	needs.novelty = clamp01(needs.novelty)
end

-- Initial values at join (§4.3): fresh, mildly social, and returning players know what they came for.
function Needs.new(rng: Rng, persona: Persona): Needs
	local needs: Needs = {
		boredom = 0.1,
		social = rng:kumaraswamy(1.5, 3) * 0.5,
		purpose = 0.5 + 0.3 * persona.accountAge,
		fatigue = rng:kumaraswamy(1.2, 4) * 0.4,
		novelty = 0.6 * (1 - persona.accountAge) + 0.2,
	}
	clampAll(needs)
	return needs
end

-- Per-second drift (§4.3). `engagement` is E of the running activity (Needs.ENGAGEMENT[name]),
-- `companionship` is 1 while in company (JoinGroup, FaceOff, reciprocated Follow, standing in a
-- detected group) else 0, and `moodMultiplier(key)` returns Mood.multiplier(mood, key).
function Needs.drift(
	needs: Needs,
	dt: number,
	persona: Persona,
	engagement: number,
	companionship: number,
	moodMultiplier: ((string) -> number)?
)
	if dt <= 0 then
		return
	end
	local function m(need: string): number
		return if moodMultiplier then moodMultiplier("drift." .. need) else 1
	end
	local e = math.clamp(engagement, 0, 1)
	local c = math.clamp(companionship, 0, 1)

	needs.boredom += dt * (1 / 240) * (0.5 + persona.curiosity) * (1 - e) * m("boredom")
	needs.social += dt * (1 / 300) * (0.3 + 1.4 * persona.sociability) * (1 - c) * m("social")
	needs.social -= dt * (1 / 60) * c
	needs.purpose += dt * (1 / 200) * (0.4 + persona.accountAge) * m("purpose")
	needs.fatigue += dt * (1 / 600) * (0.2 + 1.6 * persona.afkProneness) * m("fatigue")
	needs.novelty += dt * (1 / 180) * (0.3 + persona.curiosity) * m("novelty")
	clampAll(needs)
end

-- Relief events, applied by activities and the brain (table in §4.3):
--   visitObjective  VisitPoi dwell done at an objective/shop        purpose -0.30, boredom -0.15
--   visitHangout    VisitPoi dwell done at hangout/viewpoint/other  purpose -0.10, boredom -0.20, social -0.05 if others
--   explore         reached an unexplored sector                    novelty -0.25, boredom -0.10, purpose -0.05
--   wander          Wander arrival                                  boredom -0.05
--   newEntity       first sighting this session                     novelty -0.05
--   chat            an exchange (said + heard within 20 s)          social -0.15
--   afkTick         Afk running, context.dt seconds                 fatigue -dt/150
--   idleTick        IdleStand running, context.dt seconds           fatigue -dt/600
--   standOnProp     got on top                                      boredom -0.30
--   pace            Pace complete                                   boredom -0.10
--   fidgetBurst     one jump burst                                  boredom -0.02
--   emote           emote played                                    boredom -0.04, social -0.03 if others (in group)
function Needs.relieve(needs: Needs, event: string, context: ReliefContext?)
	local ctx: ReliefContext = context or {}
	local others = ctx.others == true
	local dt = ctx.dt or 0
	if event == "visitObjective" then
		needs.purpose -= 0.30
		needs.boredom -= 0.15
	elseif event == "visitHangout" then
		needs.purpose -= 0.10
		needs.boredom -= 0.20
		if others then
			needs.social -= 0.05
		end
	elseif event == "explore" then
		needs.novelty -= 0.25
		needs.boredom -= 0.10
		needs.purpose -= 0.05
	elseif event == "wander" then
		needs.boredom -= 0.05
	elseif event == "newEntity" then
		needs.novelty -= 0.05
	elseif event == "chat" then
		needs.social -= 0.15
	elseif event == "afkTick" then
		needs.fatigue -= dt / 150
	elseif event == "idleTick" then
		needs.fatigue -= dt / 600
	elseif event == "standOnProp" then
		needs.boredom -= 0.30
	elseif event == "pace" then
		needs.boredom -= 0.10
	elseif event == "fidgetBurst" then
		needs.boredom -= 0.02
	elseif event == "emote" then
		needs.boredom -= 0.04
		if others then
			needs.social -= 0.03
		end
	end
	clampAll(needs)
end

return Needs

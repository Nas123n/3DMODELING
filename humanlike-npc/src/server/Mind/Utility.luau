--!strict
-- Scores what an NPC could do next and picks one the way a person does: the best option is the
-- most likely, not the certain, choice. Each candidate's score multiplies the activity's base
-- appetite, how much it would relieve current needs, the session phase, the mood, a context
-- factor, distance, how recently the same thing was done, affinity toward the target and
-- feasibility. Selection is soft (a temperature set by impulsivity) with hysteresis so a running
-- activity is only dropped for something clearly better. Going AFK is need-driven only through
-- fatigue (0.5 + 0.5 fatigue) so it is reachable inside an ordinary session. Candidate lists
-- come from Goals, not from here.
-- requires: Rng, Session, Mood

local Rng = require(script.Parent.Parent.Rng)
local Session = require(script.Parent.Session)
local Mood = require(script.Parent.Mood)

type Rng = Rng.Rng

local Utility = {}

export type Candidate = {
	activity: string,
	target: string?, -- entity id, poi id, group id, sector id
	position: Vector3?, -- where it takes place (for the distance term)
	distance: number, -- studs from me
	data: any?, -- activity-specific payload
	bonus: number?, -- interrupt / ritual bonus
	ctx: number?, -- activity-specific context factor (default 1)
	feasibility: number?, -- 0 unreachable, 0.5 failed recently, 1 fine
	affinity: number?, -- for entity targets (default 1)
}

export type Scored = { candidate: Candidate, score: number }

export type NeedsTable = { boredom: number, social: number, purpose: number, fatigue: number, novelty: number }

export type Context = {
	persona: any,
	needs: NeedsTable,
	mood: string,
	phase: string,
	now: number,
	-- Seconds since this activity last ended with this target (nil = never).
	lastEnd: (activity: string, target: string?) -> number?,
}

-- Base appetite per activity.
function Utility.base(activity: string, p: any): number
	if activity == "IdleStand" then
		return 1.0
	elseif activity == "Afk" then
		return 0.15 + 0.6 * p.afkProneness
	elseif activity == "VisitPoi" then
		return 1.2
	elseif activity == "Explore" then
		return 0.3 + 0.9 * p.curiosity
	elseif activity == "Wander" then
		return 0.5
	elseif activity == "Follow" then
		return 0.1 + 0.5 * p.sociability + 0.3 * p.trolliness
	elseif activity == "JoinGroup" then
		return 0.2 + 1.0 * p.sociability
	elseif activity == "Watch" then
		return 0.15 + 0.4 * p.curiosity
	elseif activity == "Pace" then
		return 0.2 + 0.3 * p.jumpiness
	elseif activity == "StandOnProp" then
		return 0.1 + 0.5 * p.jumpiness * (1 - p.patience)
	elseif activity == "FaceOff" then
		return 0.05 + 0.4 * p.sociability
	elseif activity == "ReturnToSpawn" then
		return 0.05
	elseif activity == "ReactProbe" then
		return 1.0
	elseif activity == "Leave" then
		return 50
	end
	return 0.5
end

-- How much each activity satisfies each need (rows sum to about 1).
local SATISFIES: { [string]: { boredom: number?, social: number?, purpose: number?, fatigue: number?, novelty: number? } } =
	{
		IdleStand = { fatigue = 0.6, boredom = -0.2 },
		VisitPoi = { purpose = 1.0, boredom = 0.4 },
		Explore = { novelty = 1.0, boredom = 0.5, purpose = 0.2 },
		Wander = { boredom = 0.5, novelty = 0.3 },
		Follow = { social = 0.8, boredom = 0.4 },
		JoinGroup = { social = 1.2, boredom = 0.3 },
		Watch = { boredom = 0.4, social = 0.4, novelty = 0.2 },
		Pace = { boredom = 0.6 },
		StandOnProp = { boredom = 0.9, novelty = 0.2 },
		FaceOff = { social = 1.0 },
		ReturnToSpawn = { purpose = 0.2 },
		ReactProbe = {},
		Leave = {},
	}

function Utility.need(activity: string, needs: NeedsTable): number
	if activity == "ReactProbe" or activity == "Leave" then
		return 1 -- reactions and leaving are not need-driven
	elseif activity == "Afk" then
		-- Half the appetite is always there; fatigue adds the rest (D-41).
		return 0.5 + 0.5 * needs.fatigue
	end
	local row: { [string]: number } = SATISFIES[activity] or {}
	-- People stand around regardless of needs; idling never competes from the floor.
	local total = if activity == "IdleStand" then 0.45 else 0.15
	for key, weight in row do
		local value = (needs :: any)[key] or 0
		total += value * weight
	end
	return math.max(0.15, total)
end

-- Recency: 1 - 0.85 * exp(-(now - lastEnd) / tau).
local function recency(ctx: Context, c: Candidate): number
	local last = ctx.lastEnd(c.activity, c.target)
	if not last then
		return 1
	end
	local tau = if c.activity == "Afk" then 600 elseif c.target then 240 else 120
	return 1 - 0.85 * math.exp(-(ctx.now - last) / tau)
end

function Utility.scoreOne(ctx: Context, c: Candidate): number
	local p = ctx.persona
	local base = Utility.base(c.activity, p)
	local need = Utility.need(c.activity, ctx.needs)
	local phase = Session.phaseWeight(ctx.phase, c.activity)
	local mood = Mood.multiplier(ctx.mood, "activity." .. c.activity)
	local d0 = 60 * (0.5 + p.patience)
	local dist = 1 / (1 + (c.distance / d0) ^ 1.5)
	local rec = recency(ctx, c)
	local affinity = c.affinity or 1
	local feasibility = if c.feasibility == nil then 1 else c.feasibility :: number
	local context = c.ctx or 1
	local bonus = 1 + (c.bonus or 0)
	return base * need * phase * mood * context * dist * rec * affinity * feasibility * bonus + 0.001
end

function Utility.score(ctx: Context, candidates: { Candidate }): { Scored }
	local out: { Scored } = {}
	for _, c in candidates do
		table.insert(out, { candidate = c, score = Utility.scoreOne(ctx, c) })
	end
	return out
end

-- Soft selection with hysteresis. `current` is the running activity's scored entry (rescored
-- this step) or nil; `forced` skips the hysteresis (an interrupt, a finished activity).
function Utility.select(scored: { Scored }, current: Scored?, persona: any, rng: Rng, forced: boolean): Scored?
	if #scored == 0 then
		return current
	end
	local best = scored[1]
	for _, s in scored do
		if s.score > best.score then
			best = s
		end
	end
	if current and not forced then
		local h = 0.35 + 0.4 * persona.patience
		if best.score <= current.score * (1 + h) then
			return current
		end
	end
	local beta = 1 / (0.3 + 0.5 * persona.impulsivity)
	local weights = {}
	for i, s in scored do
		weights[i] = s.score ^ beta
	end
	return scored[rng:weightedIndex(weights)]
end

-- Interrupt resistance of a running activity (what an event must beat to be noticed).
function Utility.resistance(activity: string, state: any): number
	if activity == "IdleStand" then
		return 0.2
	elseif activity == "Afk" then
		return 0.95
	elseif activity == "VisitPoi" then
		local phase = state and state.phase
		return if phase == "interact" then 0.75 elseif phase == "dwell" then 0.55 else 0.4
	elseif activity == "Explore" then
		return 0.35
	elseif activity == "Wander" then
		return 0.3
	elseif activity == "Follow" then
		return if state and state.targetStationary then 0.2 else 0.45
	elseif activity == "JoinGroup" then
		return 0.5
	elseif activity == "Watch" then
		return 0.3
	elseif activity == "Pace" then
		return 0.25
	elseif activity == "StandOnProp" then
		return if state and state.phase == "mount" then 0.7 else 0.4
	elseif activity == "FaceOff" then
		return 0.5
	elseif activity == "ReturnToSpawn" then
		return 0.35
	elseif activity == "ReactProbe" then
		return 0.6
	elseif activity == "Leave" then
		return 1.0
	end
	return 0.3
end

-- How loudly an event kind speaks to this persona.
function Utility.sensitivity(kind: string, persona: any): number
	if
		kind == "chatAddressed"
		or kind == "followed"
		or kind == "stared"
		or kind == "onHead"
		or kind == "botProbe"
		or kind == "groupNearby"
		or kind == "entityEmoted"
	then
		return 0.6 + 0.8 * persona.sociability
	elseif kind == "entityAppeared" or kind == "entityJumped" or kind == "chatHeard" then
		return 0.5 + 0.8 * persona.curiosity
	elseif
		kind == "stuck"
		or kind == "fell"
		or kind == "pathFailed"
		or kind == "goalInvalid"
		or kind == "stopKeyword"
		or kind == "flung"
		or kind == "blocked"
		or kind == "gameEvent"
	then
		return 2.0
	end
	return 0.5
end

return Utility

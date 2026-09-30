--!strict
-- The arc of one visit (design-mind §4.12): joining (the spawn ritual, while assets load and the
-- first inputs happen), orienting (a look around, short for veterans who know the map), settled
-- (the long middle) and leaving (walk back, say bye, go), then gone. Which phase the NPC is in
-- reshapes what it is willing to do: nobody goes AFK ten seconds after spawning and nobody starts
-- exploring on the way out, which the phase weight table expresses as multipliers on activity
-- utility. leaveAt comes from the persona's session length and can be pulled in by the
-- population manager when the server needs the slot, or by the brain when someone with the same
-- name joins. This module keeps no clock and chooses no activity.
-- requires: Personality, Rng

local Personality = require(script.Parent.Personality)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng
type Persona = Personality.Persona

local Session = {}

-- "joining" | "orienting" | "settled" | "leaving" | "gone"
export type Phase = string

export type Session = {
	phase: Phase,
	joinedAt: number,
	orientUntil: number,
	leaveAt: number,
	ritualDone: boolean,
}

-- Phase weights (§4.12), rows are activities: joining, orienting, settled, leaving. VisitPoi at
-- shop/spawn kinds gets a further x1.5 while orienting, applied by the caller who knows the kind.
local WEIGHTS: { [string]: { number } } = {
	IdleStand = { 1, 0.8, 1, 0.5 },
	Afk = { 0, 0.1, 1, 0 },
	VisitPoi = { 0.5, 1.5, 1, 0.3 },
	Explore = { 0.3, 2.0, 0.6, 0 },
	Wander = { 1, 1, 1, 0.5 },
	Follow = { 0, 0.5, 1, 0 },
	JoinGroup = { 1, 1, 1, 0.2 },
	Watch = { 0.5, 1, 1, 0.2 },
	Pace = { 0, 0.3, 1, 0.5 },
	StandOnProp = { 0, 0.5, 1, 0 },
	FaceOff = { 0, 0.5, 1, 0 },
	ReturnToSpawn = { 0, 0.2, 0.3, 2 },
	Leave = { 0, 0, 0, 50 },
}

local COLUMN: { [string]: number } = { joining = 1, orienting = 2, settled = 3, leaving = 4 }

function Session.new(now: number, persona: Persona, rng: Rng): Session
	local orientMedian = if persona.accountAge >= 0.7 then 45 else 120
	return {
		phase = "joining",
		joinedAt = now,
		orientUntil = now + rng:logNormalClamped(orientMedian, 0.6, 20, 300),
		leaveAt = now + persona.sessionLength,
		ritualDone = false,
	}
end

-- Advances phases: joining -> orienting once the ritual is done, orienting -> settled at
-- orientUntil, orienting/settled -> leaving at leaveAt. Chains through several steps in one call
-- when time has moved past them. Returns true when the phase changed.
function Session.update(session: Session, now: number): boolean
	local before = session.phase
	local moved = true
	while moved do
		moved = false
		local phase = session.phase
		if phase == "joining" and session.ritualDone then
			session.phase = "orienting"
			moved = true
		elseif phase == "orienting" then
			if now >= session.leaveAt then
				session.phase = "leaving"
			elseif now >= session.orientUntil then
				session.phase = "settled"
				moved = true
			end
		elseif phase == "settled" and now >= session.leaveAt then
			session.phase = "leaving"
		end
	end
	return session.phase ~= before
end

function Session.finishRitual(session: Session)
	session.ritualDone = true
end

-- Population overflow: the NPC leaves within a few minutes (LNc(60, 0.5, 20, 180) s by default).
-- The optional parameters reshape the draw for other exits, such as a name collision's
-- LNc(20, 0.4, 5, 45); the defaults are the landed values.
function Session.shorten(
	session: Session,
	now: number,
	rng: Rng,
	median: number?,
	spread: number?,
	lo: number?,
	hi: number?
)
	session.leaveAt = now + rng:logNormalClamped(median or 60, spread or 0.5, lo or 20, hi or 180)
end

-- Escape (ReactProbe) or an explicit despawn request: straight to leaving.
function Session.leaveNow(session: Session)
	if session.phase ~= "gone" then
		session.phase = "leaving"
	end
end

function Session.markGone(session: Session)
	session.phase = "gone"
end

-- Multiplier on an activity's utility for the phase; 1 for activities not in the table, 0 once gone.
function Session.phaseWeight(phase: Phase, activity: string): number
	local column = COLUMN[phase]
	if not column then
		return 0
	end
	local row = WEIGHTS[activity]
	if not row then
		return 1
	end
	return row[column]
end

return Session

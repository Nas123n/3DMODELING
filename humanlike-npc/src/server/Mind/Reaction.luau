--!strict
-- The gap between something happening and the NPC acting on it (design-mind §4.6.4). A person
-- does not respond to a stimulus in the same frame: they may not notice it at all (more likely
-- when inattentive, when the event was unexpected, and much more when zoned out), and when they
-- do, the delay has the ex-Gaussian shape of human reaction times, with a 0.15 s physiological
-- floor and 2.5x longer for surprises. System events (stuck, fell, path failed, stop keyword)
-- carry salience >= 0.95, are never missed and fire at once. Events wait in a queue sorted by
-- their due time so the brain pops them in order.

local Mood = require(script.Parent.Mood)
local Personality = require(script.Parent.Personality)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng
type Persona = Personality.Persona

local Reaction = {}

export type Event = {
	kind: string,
	salience: number,
	expected: boolean?,
	subject: string?,
	at: number,
	data: any?,
}

export type Pending = { at: number, event: Event }

export type Queue = { pending: { Pending } }

local IMMEDIATE_SALIENCE = 0.95
local MU = 0.6
local SIGMA = 0.15
local TAU = 0.8
local FLOOR = 0.15
local UNEXPECTED_SCALE = 2.5
local MAX_MISS = 0.9

function Reaction.new(): Queue
	return { pending = {} }
end

-- Reaction delay in seconds for a noticed event (exposed for tests and for callers that schedule
-- their own follow-ups with the same shape).
function Reaction.delay(persona: Persona, expected: boolean, moodName: string, rng: Rng): number
	local base = rng:exGaussian(MU * persona.reactionScale, SIGMA, TAU, FLOOR)
	return base * (if expected then 1 else UNEXPECTED_SCALE) * Mood.multiplier(moodName, "reaction")
end

-- Chance the event goes unnoticed; §4.6.4.
function Reaction.missChance(persona: Persona, expected: boolean, moodName: string): number
	local p = (0.10 + 0.20 * (1 - persona.attention))
		* (if expected then 1 else 1.5)
		* (if moodName == "zoned" then 3 else 1)
	return math.min(p, MAX_MISS)
end

-- Queues the event with a human delay, or drops it (returns false) when it goes unnoticed.
function Reaction.push(queue: Queue, event: Event, now: number, persona: Persona, moodName: string, rng: Rng): boolean
	local delay = 0
	if event.salience < IMMEDIATE_SALIENCE then
		local expected = event.expected == true
		if rng:chance(Reaction.missChance(persona, expected, moodName)) then
			return false
		end
		delay = Reaction.delay(persona, expected, moodName, rng)
	end
	local at = now + delay
	local pending = queue.pending
	local index = #pending + 1
	-- Insert after every entry due at the same time so equal delays keep arrival order.
	while index > 1 and pending[index - 1].at > at do
		index -= 1
	end
	table.insert(pending, index, { at = at, event = event })
	return true
end

-- Pops every event due by `now`, earliest first.
function Reaction.due(queue: Queue, now: number): { Event }
	local out: { Event } = {}
	local pending = queue.pending
	local count = 0
	for _, entry in pending do
		if entry.at <= now then
			count += 1
			table.insert(out, entry.event)
		else
			break
		end
	end
	if count > 0 then
		table.move(pending, count + 1, #pending, 1)
		for i = #pending, #pending - count + 1, -1 do
			pending[i] = nil
		end
	end
	return out
end

function Reaction.pendingCount(queue: Queue): number
	return #queue.pending
end

return Reaction

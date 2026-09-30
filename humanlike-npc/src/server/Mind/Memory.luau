--!strict
-- What one NPC remembers about this session, kept small on purpose (design-mind §4.5): who it
-- has seen and where, what it heard and said (fixed-size rings, raw chat text kept only 60 s for
-- the reply-latency and echo decisions), which places it visited and when, which activities it
-- finished, which map sectors it has explored, and where it recently got stuck so goals and
-- the path provider steer clear. forget() prunes on a 10 s cadence so memory per NPC stays
-- under a few kilobytes. Nothing here is ever replayed verbatim as speech.
-- requires: (none)

local Memory = {}

export type Entity = {
	lastPosition: Vector3,
	lastAt: number,
	firstAt: number,
	timesSeen: number,
	kind: string,
	lastSeenVisibleAt: number?,
}

export type Heard = { fromId: string, text: string?, kind: string, at: number }
export type Said = { lineId: string, at: number, target: string? }
export type Visit = { lastAt: number, count: number }
export type Activity = { name: string, target: string?, startedAt: number, endedAt: number, outcome: string }
export type StuckSpot = { position: Vector3, at: number }

export type Memory = {
	entities: { [string]: Entity },
	heard: { Heard },
	said: { Said },
	visited: { [string]: Visit },
	activities: { Activity },
	explored: { [string]: boolean },
	stuckSpots: { StuckSpot },
	lastForgetAt: number,
}

Memory.CAPS = { heard = 16, said = 16, activities = 24, stuckSpots = 8 }

local FORGET_INTERVAL = 10
local ENTITY_TTL = 600 -- unseen for 10 min
local RING_TTL = 900 -- ring entries older than 15 min
local VISIT_TTL = 1800 -- visits older than 30 min
local RAW_TEXT_TTL = 60
local SECTOR_SIZE = 16
local STUCK_RADIUS = 6
local STUCK_MAX_AGE = 300

function Memory.new(now: number): Memory
	return {
		entities = {},
		heard = {},
		said = {},
		visited = {},
		activities = {},
		explored = {},
		stuckSpots = {},
		lastForgetAt = now,
	}
end

-- Appends to a ring, dropping the oldest entry past the cap.
local function push(ring: { any }, entry: any, cap: number)
	table.insert(ring, entry)
	while #ring > cap do
		table.remove(ring, 1)
	end
end

-- Drops ring entries older than ttl (rings are in insertion order, oldest first).
local function pruneRing(ring: { any }, now: number, ttl: number)
	while #ring > 0 and now - ring[1].at > ttl do
		table.remove(ring, 1)
	end
end

-- Records an entity in range. Returns true on the first sighting ever: the first observation with
-- `visible`, which the brain turns into novelty relief and an entityAppeared event. An entity
-- noticed only out of sight (behind, occluded) is tracked but does not count as sighted yet.
function Memory.observe(
	memory: Memory,
	now: number,
	id: string,
	kind: string,
	position: Vector3,
	visible: boolean
): boolean
	local entity = memory.entities[id]
	if not entity then
		entity = {
			lastPosition = position,
			lastAt = now,
			firstAt = now,
			timesSeen = 0,
			kind = kind,
			lastSeenVisibleAt = nil,
		}
		memory.entities[id] = entity
	end
	entity.lastPosition = position
	entity.lastAt = now
	entity.kind = kind
	entity.timesSeen += 1
	if visible then
		local first = entity.lastSeenVisibleAt == nil
		entity.lastSeenVisibleAt = now
		return first
	end
	return false
end

function Memory.recordHeard(memory: Memory, fromId: string, text: string?, kind: string, now: number)
	push(memory.heard, { fromId = fromId, text = text, kind = kind, at = now }, Memory.CAPS.heard)
end

function Memory.recordSaid(memory: Memory, lineId: string, now: number, target: string?)
	push(memory.said, { lineId = lineId, at = now, target = target }, Memory.CAPS.said)
end

function Memory.recordVisit(memory: Memory, poiId: string, now: number)
	local visit = memory.visited[poiId]
	if visit then
		visit.lastAt = now
		visit.count += 1
	else
		memory.visited[poiId] = { lastAt = now, count = 1 }
	end
end

function Memory.lastVisit(memory: Memory, poiId: string): number?
	local visit = memory.visited[poiId]
	return if visit then visit.lastAt else nil
end

function Memory.recordActivity(
	memory: Memory,
	name: string,
	target: string?,
	startedAt: number,
	endedAt: number,
	outcome: string
)
	push(
		memory.activities,
		{ name = name, target = target, startedAt = startedAt, endedAt = endedAt, outcome = outcome },
		Memory.CAPS.activities
	)
end

-- End time of the most recent finished activity with that name (and target when given), or nil.
function Memory.lastActivityEnd(memory: Memory, name: string, target: string?): number?
	for i = #memory.activities, 1, -1 do
		local entry = memory.activities[i]
		if entry.name == name and (target == nil or entry.target == target) then
			return entry.endedAt
		end
	end
	return nil
end

function Memory.markExplored(memory: Memory, sectorId: string)
	memory.explored[sectorId] = true
end

function Memory.isExplored(memory: Memory, sectorId: string): boolean
	return memory.explored[sectorId] == true
end

function Memory.exploredCount(memory: Memory): number
	local count = 0
	for _ in memory.explored do
		count += 1
	end
	return count
end

function Memory.recordStuck(memory: Memory, position: Vector3, now: number)
	push(memory.stuckSpots, { position = position, at = now }, Memory.CAPS.stuckSpots)
end

-- Whether a stuck spot recorded within maxAge (default 300 s) lies within radius (default 6 studs).
function Memory.nearRecentStuck(
	memory: Memory,
	position: Vector3,
	now: number,
	radius: number?,
	maxAge: number?
): boolean
	local r = radius or STUCK_RADIUS
	local age = maxAge or STUCK_MAX_AGE
	for _, spot in memory.stuckSpots do
		if now - spot.at <= age and (spot.position - position).Magnitude <= r then
			return true
		end
	end
	return false
end

-- Prunes on a 10 s cadence: entities unseen 10 min, ring entries older than 15 min, visits older
-- than 30 min, and the raw text of anything heard more than 60 s ago.
function Memory.forget(memory: Memory, now: number)
	if now - memory.lastForgetAt < FORGET_INTERVAL then
		return
	end
	memory.lastForgetAt = now
	for id, entity in memory.entities do
		if now - entity.lastAt > ENTITY_TTL then
			memory.entities[id] = nil
		end
	end
	pruneRing(memory.heard, now, RING_TTL)
	pruneRing(memory.said, now, RING_TTL)
	pruneRing(memory.stuckSpots, now, RING_TTL)
	for _, entry in memory.heard do
		if entry.text ~= nil and now - entry.at > RAW_TEXT_TTL then
			entry.text = nil
		end
	end
	-- Activities are keyed by end time, and the ring is ordered by insertion (which is end order).
	while #memory.activities > 0 and now - memory.activities[1].endedAt > RING_TTL do
		table.remove(memory.activities, 1)
	end
	for poiId, visit in memory.visited do
		if now - visit.lastAt > VISIT_TTL then
			memory.visited[poiId] = nil
		end
	end
end

-- 16 x 16 stud sectors keyed "{floor(x/16)}:{floor(z/16)}".
function Memory.sectorId(position: Vector3, size: number?): string
	local s = size or SECTOR_SIZE
	return `{math.floor(position.X / s)}:{math.floor(position.Z / s)}`
end

return Memory

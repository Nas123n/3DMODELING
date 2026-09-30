--!strict
-- Decides which NPCs think this frame. NPCs near a player tick often, far ones rarely, and the
-- ones nobody could possibly see barely at all; each NPC has its own phase so a whole tier never
-- ticks in the same frame, and a hard cap per frame turns a spike into a slightly lower rate
-- instead of a hitch. Tiers change with hysteresis so an NPC hovering at a boundary does not
-- flap between rates; `setTier` skips that hysteresis for a caller that already knows better
-- (Lod's promotions), and `wake` pulls one NPC forward to the next frame with a guaranteed brain
-- tick (a player spoke to or bumped it while it was in a slow tier). It is not the LOD filter
-- (Lod decides the distances it is fed), it never measures distances, and it reads no clock:
-- `now` is injected everywhere.
-- requires: (none)

local Scheduler = {}
Scheduler.__index = Scheduler

-- "near" | "mid" | "far" | "dormant"
export type Tier = string

-- Every field is optional in the constructor; a missing one takes its DEFAULTS value.
export type Params = {
	near: number?, -- studs; default 60
	mid: number?, -- default 200
	far: number?, -- default 500
	hysteresis: number?, -- default 1.25: demote only beyond threshold * hysteresis
	rates: { [Tier]: number }?, -- ticks per second per tier
	brainDivisor: { [Tier]: number }?, -- think every N ticks
	maxTicksPerFrame: number?, -- default 8
}

-- What the scheduler runs on: Params with every default filled in.
export type Resolved = {
	near: number,
	mid: number,
	far: number,
	hysteresis: number,
	rates: { [Tier]: number },
	brainDivisor: { [Tier]: number },
	maxTicksPerFrame: number,
}

type Entry = {
	id: string,
	phase: number, -- 0..1
	tier: Tier,
	lastTick: number,
	dueAt: number,
	ticks: number,
	woken: boolean, -- set by wake: due now, ticks first, next markTicked runs the brain
}

export type SchedulerT = typeof(setmetatable(
	{} :: {
		params: Resolved,
		entries: { [string]: Entry },
		order: { string },
	},
	Scheduler
))

local DEFAULTS: Resolved = {
	near = 60,
	mid = 200,
	far = 500,
	hysteresis = 1.25,
	rates = { near = 10, mid = 5, far = 2, dormant = 0.5 },
	brainDivisor = { near = 5, mid = 5, far = 2, dormant = 1 },
	maxTicksPerFrame = 8,
}
Scheduler.DEFAULTS = DEFAULTS

local function mergeTiers(given: { [Tier]: number }?, defaults: { [Tier]: number }): { [Tier]: number }
	local merged = table.clone(defaults)
	if given then
		for tier, value in given do
			merged[tier] = value
		end
	end
	return merged
end

local function resolve(params: Params?): Resolved
	local p: Params = params or {}
	local d = DEFAULTS
	return {
		near = p.near or d.near,
		mid = p.mid or d.mid,
		far = p.far or d.far,
		hysteresis = p.hysteresis or d.hysteresis,
		rates = mergeTiers(p.rates, d.rates),
		brainDivisor = mergeTiers(p.brainDivisor, d.brainDivisor),
		maxTicksPerFrame = p.maxTicksPerFrame or d.maxTicksPerFrame,
	}
end

function Scheduler.new(params: Params?): SchedulerT
	return setmetatable({ params = resolve(params), entries = {}, order = {} }, Scheduler)
end

local function period(self: SchedulerT, entry: Entry): number
	local rate = self.params.rates[entry.tier] or 1
	-- Phase spreads the tier's NPCs across frames.
	return (1 / rate) * (1 + 0.05 * (entry.phase - 0.5))
end

function Scheduler.add(self: SchedulerT, id: string, phase: number, now: number?)
	if self.entries[id] then
		return
	end
	local entry: Entry = {
		id = id,
		phase = phase % 1,
		tier = "near",
		lastTick = now or 0,
		dueAt = 0,
		ticks = 0,
		woken = false,
	}
	entry.dueAt = (now or 0) + period(self, entry) * entry.phase
	self.entries[id] = entry
	table.insert(self.order, id)
end

function Scheduler.remove(self: SchedulerT, id: string)
	if not self.entries[id] then
		return
	end
	self.entries[id] = nil
	for i, other in self.order do
		if other == id then
			table.remove(self.order, i)
			break
		end
	end
end

function Scheduler.tierOf(self: SchedulerT, id: string): Tier
	local entry = self.entries[id]
	return if entry then entry.tier else "dormant"
end

-- Distance to the nearest player per NPC; call every half second or so. Returns the ids whose
-- tier changed, with old and new tiers.
function Scheduler.assignTiers(
	self: SchedulerT,
	distances: { [string]: number }
): { { id: string, from: Tier, to: Tier } }
	local changes = {}
	local p = self.params
	for id, entry in self.entries do
		local d = distances[id]
		if d == nil then
			continue
		end
		local tier = entry.tier
		local h = p.hysteresis
		local new = tier
		-- Promote strictly, demote only past the hysteresis band.
		if d < p.near then
			new = "near"
		elseif d < p.mid then
			new = if tier == "near" and d <= p.near * h then "near" else "mid"
		elseif d < p.far then
			if tier == "near" and d <= p.near * h then
				new = "near"
			elseif tier == "mid" and d <= p.mid * h then
				new = "mid"
			else
				new = "far"
			end
		else
			if tier == "far" and d <= p.far * h then
				new = "far"
			elseif tier == "mid" and d <= p.mid * h then
				new = "mid"
			else
				new = "dormant"
			end
		end
		if new ~= tier then
			entry.tier = new
			entry.dueAt = math.min(entry.dueAt, entry.lastTick + period(self, entry))
			table.insert(changes, { id = id, from = tier, to = new })
		end
	end
	return changes
end

-- Puts an NPC in a tier directly, with no hysteresis: for a caller that already applied its own
-- (Lod's visibility promotions). Returns true when the tier changed; an unknown id or a tier
-- with no rate is ignored.
function Scheduler.setTier(self: SchedulerT, id: string, tier: Tier): boolean
	local entry = self.entries[id]
	if not entry or self.params.rates[tier] == nil or entry.tier == tier then
		return false
	end
	entry.tier = tier
	entry.dueAt = math.min(entry.dueAt, entry.lastTick + period(self, entry))
	return true
end

-- Makes an NPC due now: it comes first in the next `due` and its next `markTicked` runs the
-- brain whatever the divisor says. For a player speaking to or bumping an NPC in a slow tier.
function Scheduler.wake(self: SchedulerT, id: string, now: number)
	local entry = self.entries[id]
	if not entry then
		return
	end
	entry.dueAt = math.min(entry.dueAt, now)
	entry.woken = true
end

-- Ids due now, woken ones first, then oldest due first, at most maxTicksPerFrame.
function Scheduler.due(self: SchedulerT, now: number, out: { string }?): { string }
	local result = out or {}
	table.clear(result)
	local candidates: { Entry } = {}
	for _, id in self.order do
		local entry = self.entries[id]
		if entry and now >= entry.dueAt then
			table.insert(candidates, entry)
		end
	end
	table.sort(candidates, function(a, b)
		if a.woken ~= b.woken then
			return a.woken
		end
		if a.dueAt == b.dueAt then
			return a.id < b.id
		end
		return a.dueAt < b.dueAt
	end)
	for i = 1, math.min(#candidates, self.params.maxTicksPerFrame) do
		table.insert(result, candidates[i].id)
	end
	return result
end

-- Records a tick and schedules the next. Returns true when this tick should also run the brain.
function Scheduler.markTicked(self: SchedulerT, id: string, now: number): boolean
	local entry = self.entries[id]
	if not entry then
		return false
	end
	entry.lastTick = now
	entry.ticks += 1
	entry.dueAt = now + period(self, entry)
	if entry.woken then
		entry.woken = false
		return true
	end
	local divisor = self.params.brainDivisor[entry.tier] or 1
	return entry.ticks % divisor == 0
end

function Scheduler.count(self: SchedulerT): number
	return #self.order
end

return Scheduler

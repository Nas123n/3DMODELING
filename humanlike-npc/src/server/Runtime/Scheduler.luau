--!strict
-- Decides which NPCs think this frame. NPCs near a player tick often, far ones rarely, and the
-- ones nobody could possibly see barely at all; each NPC has its own phase so a whole tier never
-- ticks in the same frame, and a hard cap per frame turns a spike into a slightly lower rate
-- instead of a hitch. Tiers change with hysteresis so an NPC hovering at a boundary does not
-- flap between rates.

local Scheduler = {}
Scheduler.__index = Scheduler

-- "near" | "mid" | "far" | "dormant"
export type Tier = string

export type Params = {
	near: number, -- studs; default 60
	mid: number, -- default 200
	far: number, -- default 500
	hysteresis: number, -- default 1.25: demote only beyond threshold * hysteresis
	rates: { [Tier]: number }, -- ticks per second per tier
	brainDivisor: { [Tier]: number }, -- think every N ticks
	maxTicksPerFrame: number, -- default 8
}

type Entry = {
	id: string,
	phase: number, -- 0..1
	tier: Tier,
	lastTick: number,
	dueAt: number,
	ticks: number,
}

export type SchedulerT = typeof(setmetatable(
	{} :: {
		params: Params,
		entries: { [string]: Entry },
		order: { string },
	},
	Scheduler
))

Scheduler.DEFAULTS = {
	near = 60,
	mid = 200,
	far = 500,
	hysteresis = 1.25,
	rates = { near = 10, mid = 5, far = 2, dormant = 0.5 },
	brainDivisor = { near = 5, mid = 5, far = 2, dormant = 1 },
	maxTicksPerFrame = 8,
}

function Scheduler.new(params: Params?): SchedulerT
	local p = params or Scheduler.DEFAULTS
	return setmetatable({ params = p, entries = {}, order = {} }, Scheduler)
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
	local entry: Entry = { id = id, phase = phase % 1, tier = "near", lastTick = now or 0, dueAt = 0, ticks = 0 }
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

-- Ids due now, oldest due first, at most maxTicksPerFrame.
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
	local divisor = self.params.brainDivisor[entry.tier] or 1
	return entry.ticks % divisor == 0
end

function Scheduler.count(self: SchedulerT): number
	return #self.order
end

return Scheduler

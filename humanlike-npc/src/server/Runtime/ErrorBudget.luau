--!strict
-- Error containment as data: counts the failures each NPC's tick raised and says when one has
-- failed so often, so recently, that it should leave the server (a real player would have
-- crashed out by then) rather than throw every frame. It keeps a short ring of the last errors
-- for the debug view. It does not catch anything itself (NpcService wraps the tick in pcall),
-- it does not despawn anyone (it only answers true), and it reads no clock: `now` is injected.
-- requires: (none)

local ErrorBudget = {}
ErrorBudget.__index = ErrorBudget

export type Options = {
	maxErrors: number?, -- errors within `window` that trip the budget; default 5
	window: number?, -- seconds; default 10
}

export type LogEntry = { id: string, at: number, message: string }

export type Budget = typeof(setmetatable(
	{} :: {
		maxErrors: number,
		window: number,
		-- Error times per NPC, oldest first; pruned to the window on every touch.
		times: { [string]: { number } },
		-- Ring of the last LOG_CAPACITY errors across all NPCs.
		ring: { LogEntry },
		ringNext: number, -- slot the next entry is written to, 1..LOG_CAPACITY
		ringCount: number,
	},
	ErrorBudget
))

local LOG_CAPACITY = 200
ErrorBudget.LOG_CAPACITY = LOG_CAPACITY

function ErrorBudget.new(opts: Options?): Budget
	local o: Options = opts or {}
	return setmetatable({
		maxErrors = o.maxErrors or 5,
		window = o.window or 10,
		times = {},
		ring = {},
		ringNext = 1,
		ringCount = 0,
	}, ErrorBudget)
end

-- Drops the times older than the window; returns the list (nil when nothing is left).
local function prune(self: Budget, id: string, now: number): { number }?
	local list = self.times[id]
	if not list then
		return nil
	end
	local firstKept = 1
	while firstKept <= #list and now - list[firstKept] > self.window do
		firstKept += 1
	end
	if firstKept > #list then
		self.times[id] = nil
		return nil
	end
	if firstKept > 1 then
		local kept = table.move(list, firstKept, #list, 1, {})
		self.times[id] = kept
		return kept
	end
	return list
end

-- Records one failure. Returns true when the NPC has now failed `maxErrors` or more times within
-- the window and must be despawned.
function ErrorBudget.record(self: Budget, id: string, now: number, message: string): boolean
	local list: { number } = prune(self, id, now) or {}
	self.times[id] = list
	table.insert(list, now)

	self.ring[self.ringNext] = { id = id, at = now, message = message }
	self.ringNext = self.ringNext % LOG_CAPACITY + 1
	self.ringCount = math.min(self.ringCount + 1, LOG_CAPACITY)

	return #list >= self.maxErrors
end

-- How many failures the NPC has within the window ending at `now`.
function ErrorBudget.recent(self: Budget, id: string, now: number): number
	local list = prune(self, id, now)
	return if list then #list else 0
end

-- Clears the NPC's count (on despawn). The log keeps its entries: it is the audit trail.
function ErrorBudget.forget(self: Budget, id: string)
	self.times[id] = nil
end

-- The most recent errors across all NPCs, oldest first, at most `limit` (default: the whole
-- ring of 200).
function ErrorBudget.log(self: Budget, limit: number?): { LogEntry }
	local count = math.min(limit or LOG_CAPACITY, self.ringCount)
	local out: { LogEntry } = {}
	-- Walk back `count` slots from the write cursor to find the oldest wanted entry.
	local slot = (self.ringNext - 1 - count) % LOG_CAPACITY + 1
	for _ = 1, count do
		table.insert(out, self.ring[slot])
		slot = slot % LOG_CAPACITY + 1
	end
	return out
end

return ErrorBudget

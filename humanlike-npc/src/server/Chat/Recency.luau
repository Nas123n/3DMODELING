--!strict
-- Remembers which corpus lines were said recently, so the same line is not heard twice across
-- the server within a quarter of an hour, and an NPC never repeats itself within the hour.
-- Template feel ("that guy said exactly that a minute ago") is one of the loudest chat tells.

local Recency = {}
Recency.__index = Recency

export type Tracker = typeof(setmetatable(
	{} :: {
		serverWindow: number,
		selfWindow: number,
		serverUse: { [string]: number },
		selfUse: { [string]: { [string]: number } },
		lastPruneAt: number,
	},
	Recency
))

function Recency.new(serverWindow: number?, selfWindow: number?): Tracker
	return setmetatable({
		serverWindow = serverWindow or 900,
		selfWindow = selfWindow or 3600,
		serverUse = {},
		selfUse = {},
		lastPruneAt = 0,
	}, Recency)
end

-- Selection weight for a line: 1 normally, 0.05 if anyone said it recently, 0 if I did.
function Recency.weight(self: Tracker, lineId: string, npcId: string, now: number): number
	local mine = self.selfUse[npcId]
	if mine and mine[lineId] and now - mine[lineId] < self.selfWindow then
		return 0
	end
	local server = self.serverUse[lineId]
	if server and now - server < self.serverWindow then
		return 0.05
	end
	return 1
end

function Recency.record(self: Tracker, lineId: string, npcId: string, now: number)
	self.serverUse[lineId] = now
	local mine = self.selfUse[npcId]
	if not mine then
		mine = {}
		self.selfUse[npcId] = mine
	end
	mine[lineId] = now
	if now - self.lastPruneAt > 300 then
		self:prune(now)
	end
end

function Recency.prune(self: Tracker, now: number)
	self.lastPruneAt = now
	for lineId, at in self.serverUse do
		if now - at >= self.serverWindow then
			self.serverUse[lineId] = nil
		end
	end
	for npcId, mine in self.selfUse do
		local any = false
		for lineId, at in mine do
			if now - at >= self.selfWindow then
				mine[lineId] = nil
			else
				any = true
			end
		end
		if not any then
			self.selfUse[npcId] = nil
		end
	end
end

function Recency.forget(self: Tracker, npcId: string)
	self.selfUse[npcId] = nil
end

return Recency

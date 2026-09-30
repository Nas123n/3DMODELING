--!strict
-- Every rate rule for NPC chat in one pure object: a minimum gap between two lines of the same
-- NPC, per-NPC caps per minute and per ten minutes, a server-wide cap per minute, a share rule
-- that keeps NPC lines a minority of what real players say, and a quarter rate on a server
-- where nobody has spoken for a while (a dead server does not host a lively NPC chat). A reply
-- may run a little over the per-minute cap and skips the share rules, but never the server cap.
-- It replaces the inline chatAllowed in NpcService. It is not a content filter (Safety) and
-- not a reply decision (Reply); it never reads a clock, `now` is injected, so the same sequence
-- of calls always gives the same answers.

local ChatGuard = {}
ChatGuard.__index = ChatGuard

export type Options = {
	npcMinGap: number?, -- seconds between two lines of the same NPC; 4
	npcPerMinute: number?, -- lines per NPC in any 60 s window; 4
	npcPer10Min: number?, -- lines per NPC in any 600 s window; 12
	serverPerMinute: number?, -- NPC lines server-wide in any 60 s window; 8
	serverShare: number?, -- NPC share of all lines while players are talking; 0.4
	quietAfterSilence: number?, -- seconds without a player line before the quarter rate applies; 600
	replyBoost: number?, -- extra lines per minute a reply may use over npcPerMinute; 2
}

export type Stats = { server1m: number, players1m: number }

-- `droppedCount` is the counter behind `dropped()`; a field of the same name as the method would
-- shadow it through the metatable.
export type Guard = typeof(setmetatable(
	{} :: {
		o: Options,
		npcTimes: { [string]: { number } },
		serverTimes: { number },
		playerTimes: { number },
		lastPlayerAt: number,
		droppedCount: number,
	},
	ChatGuard
))

local DEFAULTS = {
	npcMinGap = 4,
	npcPerMinute = 4,
	npcPer10Min = 12,
	serverPerMinute = 8,
	serverShare = 0.4,
	quietAfterSilence = 600,
	replyBoost = 2,
}
ChatGuard.DEFAULTS = DEFAULTS

local MINUTE = 60
local TEN_MINUTES = 600

-- Drops entries that fell out of the window. Times are appended in call order (now is monotonic).
local function prune(times: { number }, now: number, window: number)
	while #times > 0 and now - times[1] >= window do
		table.remove(times, 1)
	end
end

local function countWithin(times: { number }, now: number, window: number): number
	local n = 0
	for _, at in times do
		if now - at < window then
			n += 1
		end
	end
	return n
end

-- `now` is when the guard starts counting silence; without it the silence timer starts at 0.
function ChatGuard.new(o: Options?, now: number?): Guard
	local opts: Options = o or {}
	return setmetatable({
		o = {
			npcMinGap = opts.npcMinGap or DEFAULTS.npcMinGap,
			npcPerMinute = opts.npcPerMinute or DEFAULTS.npcPerMinute,
			npcPer10Min = opts.npcPer10Min or DEFAULTS.npcPer10Min,
			serverPerMinute = opts.serverPerMinute or DEFAULTS.serverPerMinute,
			serverShare = opts.serverShare or DEFAULTS.serverShare,
			quietAfterSilence = opts.quietAfterSilence or DEFAULTS.quietAfterSilence,
			replyBoost = opts.replyBoost or DEFAULTS.replyBoost,
		},
		npcTimes = {},
		serverTimes = {},
		playerTimes = {},
		lastPlayerAt = now or 0,
		droppedCount = 0,
	}, ChatGuard)
end

local function deny(self: Guard): boolean
	self.droppedCount += 1
	return false
end

-- True when this NPC may send a line now; the line is recorded as sent when true. Rules, all of
-- which must hold: (1) npcMinGap since this NPC's last line; (2) fewer than npcPerMinute lines by
-- this NPC in the last minute (+ replyBoost for a reply); (3) fewer than npcPer10Min in the last
-- ten minutes; (4) fewer than serverPerMinute NPC lines server-wide in the last minute; (5) while
-- players spoke in the last minute, NPC lines stay within serverShare of all lines; (5b) after
-- quietAfterSilence without a player line, NPC lines run at a quarter of serverPerMinute;
-- (6) a reply skips 5 and 5b but not 1 to 4.
function ChatGuard.allow(self: Guard, npcId: string, now: number, isReply: boolean?): boolean
	local o = self.o
	local minGap = o.npcMinGap or DEFAULTS.npcMinGap
	local perMinute = o.npcPerMinute or DEFAULTS.npcPerMinute
	local per10Min = o.npcPer10Min or DEFAULTS.npcPer10Min
	local serverPerMinute = o.serverPerMinute or DEFAULTS.serverPerMinute
	local share = o.serverShare or DEFAULTS.serverShare
	local quietAfter = o.quietAfterSilence or DEFAULTS.quietAfterSilence
	local boost = o.replyBoost or DEFAULTS.replyBoost

	prune(self.serverTimes, now, MINUTE)
	prune(self.playerTimes, now, MINUTE)
	local mine = self.npcTimes[npcId]
	if mine then
		prune(mine, now, TEN_MINUTES)
	end

	if mine and #mine > 0 then
		if now - mine[#mine] < minGap then
			return deny(self)
		end
		local cap = perMinute + (if isReply then boost else 0)
		if countWithin(mine, now, MINUTE) >= cap then
			return deny(self)
		end
		if #mine >= per10Min then
			return deny(self)
		end
	end

	local npcLines = #self.serverTimes
	if npcLines >= serverPerMinute then
		return deny(self)
	end

	if not isReply then
		local playerLines = #self.playerTimes
		if playerLines > 0 then
			-- The epsilon keeps 0.4 * 5 from ceiling to 3 through floating point.
			local allowed = math.ceil(share * (playerLines + npcLines + 1) - 1e-9)
			if npcLines + 1 > allowed then
				return deny(self)
			end
		end
		if now - self.lastPlayerAt >= quietAfter and npcLines >= serverPerMinute / 4 then
			return deny(self)
		end
	end

	if not mine then
		mine = {}
		self.npcTimes[npcId] = mine
	end
	table.insert(mine, now)
	table.insert(self.serverTimes, now)
	return true
end

-- A real player spoke, at any distance.
function ChatGuard.onPlayerLine(self: Guard, now: number)
	prune(self.playerTimes, now, MINUTE)
	table.insert(self.playerTimes, now)
	self.lastPlayerAt = now
end

-- Lines refused so far.
function ChatGuard.dropped(self: Guard): number
	return self.droppedCount
end

-- Drops an NPC's history (it left); server-wide counts keep what it already said.
function ChatGuard.forget(self: Guard, npcId: string)
	self.npcTimes[npcId] = nil
end

-- Lines in the last minute; pass `now` to prune before counting.
function ChatGuard.stats(self: Guard, now: number?): Stats
	if now then
		prune(self.serverTimes, now, MINUTE)
		prune(self.playerTimes, now, MINUTE)
	end
	return { server1m = #self.serverTimes, players1m = #self.playerTimes }
end

return ChatGuard

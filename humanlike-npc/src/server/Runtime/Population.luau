--!strict
-- How many NPCs there should be and when they arrive and leave. The target follows the real
-- player count and an hourly curve; arrivals come in clustered bursts ("friends joining"),
-- never two in the same second; when there are too many, the one due to leave soonest is asked
-- to go; a few who left come back later as the same person. With no players and SpawnWhenEmpty
-- off, the target is zero: an empty server has no witnesses, except that `min` NPCs linger for
-- the empty-server grace after the last player leaves, so the next joiner finds people already
-- there, and the burst that follows a join into an empty server trickles in one by one on
-- jittered gaps. It also keeps the list of usernames retired for a while after their owner
-- left. It never spawns anything itself: every decision is a plain table for NpcService, and
-- the time and the randomness are injected.
-- requires: Rng

local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng

local Population = {}
Population.__index = Population

-- Two joins are never closer than this, whatever the gap draw says.
local MIN_JOIN_GAP = 1.5

-- A clamped log-normal draw: Rng.logNormalClamped(median, spread, lo, hi).
export type Range = { median: number, spread: number, lo: number, hi: number }

export type Config = {
	base: number?, -- default 6
	perPlayer: number?, -- default 0.5
	min: number?, -- default 0
	max: number?, -- default 30
	curve: { number }?, -- 24 hourly multipliers, default all 1
	spawnWhenEmpty: boolean?, -- default false
	initialBurst: number?, -- default 4
	-- Layer 2 additions; Config.population passes every one of them, the defaults are the landed behaviour.
	rejoinChance: number?, -- default 0.1
	rejoinDelay: Range?, -- default { 720, 0.6, 300, 1800 }
	pairChance: number?, -- default 0.3: the next join is a "friend" of this one, u(5, 20) s later
	emptyGrace: number?, -- default 0: seconds after the last player leaves during which `min` NPCs linger
	shortenGap: Range?, -- default: a fixed 30 s between two shortenings
	burstGap: Range?, -- default u(1.5, 4) after the first-tick burst; spaces the burst after a join into an empty server
	joinGap: Range?, -- default { 25, 0.8, 5, 120 }
	nameRetire: number?, -- default 7200: seconds a username stays retired after its owner left
}

export type Decision = {
	spawn: number,
	shorten: boolean,
	rejoinSeed: (number | string)?,
	pairWith: string?, -- the previous joiner's id when this join is their "friend" (known through onJoined)
	retire: { string }, -- usernames whose retirement ended this tick, once each (release them to the name pool)
}

type Retired = { username: string, at: number }

export type Model = typeof(setmetatable(
	{} :: {
		rng: Rng,
		config: Config,
		nextJoinAt: number,
		lastJoinAt: number,
		nextShortenAt: number,
		initialDone: boolean,
		rejoinQueue: { { at: number, seed: number | string } },
		joinIndex: number,
		-- Layer 2 state.
		playersKnown: number, -- players according to onPlayerJoined / onPlayerLeft
		lastPlayerLeftAt: number?, -- when the server last became empty; nil while someone is here or before anyone came
		burstRemaining: number, -- joins still owed to the burst that follows a join into an empty server
		pendingPair: boolean, -- the last gap drawn was a "friend" gap: the next join pairs with the last joiner
		lastJoinedId: string?, -- the id NpcService gave the last joiner (onJoined)
		retired: { Retired },
	},
	Population
))

function Population.new(rng: Rng, config: Config?): Model
	return setmetatable({
		rng = rng,
		config = config or {},
		nextJoinAt = 0,
		lastJoinAt = -math.huge,
		nextShortenAt = 0,
		initialDone = false,
		rejoinQueue = {},
		joinIndex = 0,
		playersKnown = 0,
		lastPlayerLeftAt = nil,
		burstRemaining = 0,
		pendingPair = false,
		lastJoinedId = nil,
		retired = {},
	}, Population)
end

local function draw(rng: Rng, range: Range): number
	return rng:logNormalClamped(range.median, range.spread, range.lo, range.hi)
end

-- With `now`, an empty server keeps `min` NPCs for `emptyGrace` seconds after the last player
-- left; without it (the landed two-argument call) an empty server is empty.
function Population.target(self: Model, playerCount: number, hour: number, now: number?): number
	local c = self.config
	if playerCount == 0 and not c.spawnWhenEmpty then
		local leftAt = self.lastPlayerLeftAt
		if now ~= nil and leftAt ~= nil and now < leftAt + (c.emptyGrace or 0) then
			return c.min or 0
		end
		return 0
	end
	local curve = c.curve
	local multiplier = if curve and #curve == 24 then curve[math.clamp(math.floor(hour) + 1, 1, 24)] else 1
	local raw = ((c.base or 6) + (c.perPlayer or 0.5) * playerCount) * multiplier
	return math.clamp(math.round(raw), c.min or 0, c.max or 30)
end

-- Someone left; with a small chance they come back later as the same persona.
function Population.onLeft(self: Model, seed: number | string, now: number)
	local c = self.config
	if self.rng:chance(c.rejoinChance or 0.1) then
		local delay = if c.rejoinDelay
			then draw(self.rng, c.rejoinDelay)
			else self.rng:logNormalClamped(720, 0.6, 300, 1800)
		table.insert(self.rejoinQueue, { at = now + delay, seed = seed })
	end
end

-- NpcService spawned the NPC a decision asked for: remember its id so a "friend" join that
-- follows can name it in Decision.pairWith.
function Population.onJoined(self: Model, npcId: string)
	self.lastJoinedId = npcId
end

-- A username its owner left behind: out of the pool for `nameRetire` seconds, then listed once in
-- Decision.retire so NpcService releases it.
function Population.retireName(self: Model, username: string, now: number)
	table.insert(self.retired, { username = username, at = now + (self.config.nameRetire or 7200) })
end

-- A player is loading in (PlayerAdded, before the character exists). Into an empty server this
-- starts the join burst: `initialBurst` NPCs one by one, spaced by the burst gap, the first at
-- the next tick, so the joiner finds people arriving rather than a pair popping in together.
function Population.onPlayerJoined(self: Model, now: number)
	if self.playersKnown <= 0 then
		self.burstRemaining = self.config.initialBurst or 4
		self.nextJoinAt = math.max(now, self.lastJoinAt + MIN_JOIN_GAP)
	end
	self.playersKnown += 1
	self.lastPlayerLeftAt = nil
end

-- A player left; `playerCount` is how many remain. When the server is empty the grace starts
-- and any burst still owed is dropped.
function Population.onPlayerLeft(self: Model, playerCount: number, now: number)
	self.playersKnown = playerCount
	if playerCount <= 0 then
		self.lastPlayerLeftAt = now
		self.burstRemaining = 0
	end
end

-- Moves every retirement that ended into `out` (in the order they were retired) and drops it.
local function collectRetired(self: Model, now: number, out: { string })
	local kept: { Retired } = {}
	for _, entry in self.retired do
		if now >= entry.at then
			table.insert(out, entry.username)
		else
			table.insert(kept, entry)
		end
	end
	self.retired = kept
end

-- Called every second or so. Returns how many to spawn now (0 or 1, or a burst at start),
-- whether to shorten someone's session, a seed to reuse when a rejoin is due, the id to pair a
-- "friend" join with, and the usernames whose retirement ended.
function Population.tick(self: Model, now: number, playerCount: number, npcCount: number, hour: number): Decision
	local c = self.config
	local target = self:target(playerCount, hour, now)
	local decision: Decision = { spawn = 0, shorten = false, rejoinSeed = nil, pairWith = nil, retire = {} }
	collectRetired(self, now, decision.retire)
	if not self.initialDone then
		self.initialDone = true
		-- A player already joined the empty server: the spread burst below serves them instead.
		local burst = math.min(target - npcCount, c.initialBurst or 4)
		if burst > 0 and self.burstRemaining <= 0 then
			decision.spawn = burst
			self.lastJoinAt = now
			self.nextJoinAt = now + (if c.burstGap then draw(self.rng, c.burstGap) else self.rng:range(1.5, 4))
			return decision
		end
	end
	if npcCount < target and now >= self.nextJoinAt then
		decision.spawn = 1
		-- A due rejoin is served first.
		for i, entry in self.rejoinQueue do
			if now >= entry.at then
				decision.rejoinSeed = entry.seed
				table.remove(self.rejoinQueue, i)
				break
			end
		end
		self.joinIndex += 1
		if self.pendingPair then
			decision.pairWith = self.lastJoinedId
		end
		self.pendingPair = false
		if self.burstRemaining > 0 then
			self.burstRemaining -= 1
		end
		local gap: number
		if self.burstRemaining > 0 then
			gap = if c.burstGap then draw(self.rng, c.burstGap) else self.rng:range(1.5, 4)
		else
			gap = if c.joinGap then draw(self.rng, c.joinGap) else self.rng:logNormalClamped(25, 0.8, 5, 120)
			if self.rng:chance(c.pairChance or 0.3) then
				gap = self.rng:range(5, 20)
				self.pendingPair = true
			end
		end
		self.nextJoinAt = math.max(now + gap, self.lastJoinAt + MIN_JOIN_GAP)
		self.lastJoinAt = now
	end
	if npcCount > target + 2 and now >= self.nextShortenAt then
		decision.shorten = true
		self.nextShortenAt = now + (if c.shortenGap then draw(self.rng, c.shortenGap) else 30)
	end
	return decision
end

return Population

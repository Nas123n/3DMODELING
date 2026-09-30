--!strict
-- How many NPCs there should be and when they arrive and leave. The target follows the real
-- player count and an hourly curve; arrivals come in clustered bursts ("friends joining"),
-- never two in the same second; when there are too many, the one due to leave soonest is asked
-- to go; a few who left come back later as the same person. With no players and SpawnWhenEmpty
-- off, the target is zero: an empty server has no witnesses.

local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng

local Population = {}
Population.__index = Population

export type Config = {
	base: number?, -- default 6
	perPlayer: number?, -- default 0.5
	min: number?, -- default 0
	max: number?, -- default 30
	curve: { number }?, -- 24 hourly multipliers, default all 1
	spawnWhenEmpty: boolean?, -- default false
	initialBurst: number?, -- default 4
}

export type Decision = { spawn: number, shorten: boolean, rejoinSeed: (number | string)? }

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
	}, Population)
end

function Population.target(self: Model, playerCount: number, hour: number): number
	local c = self.config
	if playerCount == 0 and not c.spawnWhenEmpty then
		return 0
	end
	local curve = c.curve
	local multiplier = if curve and #curve == 24 then curve[math.clamp(math.floor(hour) + 1, 1, 24)] else 1
	local raw = ((c.base or 6) + (c.perPlayer or 0.5) * playerCount) * multiplier
	return math.clamp(math.round(raw), c.min or 0, c.max or 30)
end

-- Someone left; with a small chance they come back later as the same persona.
function Population.onLeft(self: Model, seed: number | string, now: number)
	if self.rng:chance(0.1) then
		table.insert(self.rejoinQueue, { at = now + self.rng:logNormalClamped(720, 0.6, 300, 1800), seed = seed })
	end
end

-- Called every second or so. Returns how many to spawn now (0 or 1, or a burst at start),
-- whether to shorten someone's session, and a seed to reuse when a rejoin is due.
function Population.tick(self: Model, now: number, playerCount: number, npcCount: number, hour: number): Decision
	local target = self:target(playerCount, hour)
	local decision: Decision = { spawn = 0, shorten = false, rejoinSeed = nil }
	if not self.initialDone then
		self.initialDone = true
		if target > 0 then
			decision.spawn = math.min(target, self.config.initialBurst or 4)
			self.lastJoinAt = now
			self.nextJoinAt = now + self.rng:range(1.5, 4)
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
		local gap = self.rng:logNormalClamped(25, 0.8, 5, 120)
		if self.rng:chance(0.3) then
			gap = self.rng:range(5, 20)
		end
		self.nextJoinAt = math.max(now + gap, self.lastJoinAt + 1.5)
		self.lastJoinAt = now
	end
	if npcCount > target + 2 and now >= self.nextShortenAt then
		decision.shorten = true
		self.nextShortenAt = now + 30
	end
	return decision
end

return Population

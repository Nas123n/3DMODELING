return function(T, Loader)
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local Config = session.require(S.Config)
	local Population = session.require(S.Runtime.Population)

	local HOUR = 12
	local WIRED = Config.population(Config.DEFAULTS)

	-- The running system's model: Config.population(c) on the "population" fork of the service root.
	local function wired(seed)
		return Population.new(Rng.new(seed or "population-spec"):fork("population"), WIRED)
	end

	-- Ticks `model` from `from` to `to` every `dt` with a constant player count. `npcCount` is a
	-- function of the spawns so far; every spawn is reported back through onJoined, as NpcService
	-- does. Returns the times of the ticks that spawned, the decisions and the shorten times.
	local function run(model, from, to, dt, players, npcCount)
		local joinTimes, shortenTimes, decisions = {}, {}, {}
		local spawned = 0
		local now = from
		while now <= to do
			local decision = model:tick(now, players, npcCount(spawned), HOUR)
			if decision.spawn > 0 then
				table.insert(joinTimes, now)
				table.insert(decisions, decision)
				for _ = 1, decision.spawn do
					spawned += 1
					model:onJoined(`npc{spawned}`)
				end
			end
			if decision.shorten then
				table.insert(shortenTimes, now)
			end
			now += dt
		end
		return joinTimes, decisions, shortenTimes
	end

	local function gapsOf(times)
		local gaps = {}
		for i = 2, #times do
			table.insert(gaps, times[i] - times[i - 1])
		end
		return gaps
	end

	local function never(_)
		return 0
	end

	T.describe("Population", function()
		T.it("target min during the grace, 0 after", function()
			local model = wired()
			T.equal(model:target(0, HOUR, 0), 0, "a fresh server has nobody to linger for")
			T.equal(model:target(1, HOUR, 0), 7, "6 + 0.5 per player")
			T.equal(model:target(3, HOUR, 0), 8)
			T.equal(model:target(60, HOUR, 0), 30, "PopulationMax")
			T.equal(model:tick(0, 0, 0, HOUR).spawn, 0, "the first tick of an empty server")
			model:onPlayerJoined(0)
			model:onPlayerLeft(0, 100)
			T.equal(model:target(0, HOUR, 100), 2, "PopulationMin lingers")
			T.equal(model:target(0, HOUR, 699.9), 2)
			T.equal(model:target(0, HOUR, 700), 0, "grace over")
			T.equal(model:target(0, HOUR), 0, "the landed two-argument call knows no grace")
			-- The grace feeds tick's target: two are kept, a third is shortened away.
			T.equal(model:tick(101, 0, 5, HOUR).shorten, true, "5 > 2 + 2")
			T.equal(model:tick(200, 0, 4, HOUR).shorten, false, "4 is within 2 + 2")
			-- Someone comes back: the grace is forgotten.
			model:onPlayerJoined(300)
			model:onPlayerLeft(1, 310)
			T.equal(model:target(0, HOUR, 320), 0, "onPlayerLeft with players remaining is not the empty case")
			model:onPlayerLeft(0, 330)
			T.equal(model:target(0, HOUR, 900), 2)
			T.equal(model:target(0, HOUR, 930), 0)
		end)

		T.it("initial burst 2", function()
			local model = wired()
			local first = model:tick(0, 3, 0, HOUR)
			T.equal(first.spawn, 2)
			T.equal(first.shorten, false)
			T.equal(first.rejoinSeed, nil)
			T.equal(first.pairWith, nil)
			T.equal(#first.retire, 0)
			T.equal(model:tick(0.5, 3, 2, HOUR).spawn, 0, "the next join waits for its gap")
			-- No players on the first tick: no burst, and none later either (min only lingers after a leave).
			local empty = wired("empty")
			T.equal(empty:tick(0, 0, 0, HOUR).spawn, 0)
			T.equal(empty:tick(1, 0, 0, HOUR).spawn, 0)
			-- The landed call without a config still works: the landed defaults (min 0, burst 4).
			local landed = Population.new(Rng.new("landed"))
			T.equal(landed:target(3, HOUR), 8)
			T.equal(landed:target(0, HOUR), 0)
			T.equal(landed:tick(0, 3, 0, HOUR).spawn, 4)
			T.equal(#landed:tick(1, 3, 4, HOUR).retire, 0)
		end)

		T.it("joins never closer than 1.5 s", function()
			local model = wired("gaps")
			local joinTimes = run(model, 0, 10000, 0.25, 3, never)
			T.check(#joinTimes >= 150, `{#joinTimes} joins in 10 000 s`)
			local minGap, maxGap = math.huge, 0
			for _, gap in gapsOf(joinTimes) do
				minGap = math.min(minGap, gap)
				maxGap = math.max(maxGap, gap)
			end
			T.check(minGap >= 1.5, `closest joins {minGap} s apart`)
			T.check(minGap >= 5, `a plain join gap is never under 5 s ({minGap})`)
			T.check(maxGap <= 120.25, `widest gap {maxGap}`)
		end)

		T.it("burst joins are spread", function()
			local dt = 0.1
			for seed = 1, 30 do
				local model = wired(`burst{seed}`)
				T.equal(model:tick(0, 0, 0, HOUR).spawn, 0, "empty server, nothing to do")
				-- PlayerAdded during the loading screen: the burst starts at the next tick.
				model:onPlayerJoined(5)
				local joinTimes, decisions = run(model, 5, 400, dt, 1, function(spawned)
					return spawned
				end)
				T.check(#joinTimes >= 3, `seed {seed}: {#joinTimes} joins`)
				T.near(joinTimes[1], 5, 1e-9, `seed {seed}: the first arrives at once`)
				T.equal(decisions[1].spawn, 1, "one at a time, never a pair in the same second")
				T.equal(decisions[2].spawn, 1)
				local burstGap = joinTimes[2] - joinTimes[1]
				T.between(burstGap, 2, 30 + dt, `seed {seed}: burst gap {burstGap}`)
				local afterBurst = joinTimes[3] - joinTimes[2]
				T.check(afterBurst >= 5, `seed {seed}: the join after the burst uses the join gap ({afterBurst})`)
			end
			-- A player who joins before the first tick gets the same spread burst, not an instant pair.
			local early = wired("early")
			early:onPlayerJoined(0)
			T.equal(early:tick(0, 1, 0, HOUR).spawn, 1)
			T.equal(early:tick(0.5, 1, 1, HOUR).spawn, 0)
			-- A second player joining a live server starts no burst.
			local busy = wired("busy")
			busy:onPlayerJoined(0)
			local times = run(busy, 0, 100, 0.5, 1, function(spawned)
				return spawned
			end)
			busy:onPlayerJoined(100.25)
			T.equal(busy:tick(100.5, 2, #times, HOUR).spawn, 0, "no immediate join for the second player")
		end)

		T.it("friend pairs 30% ± 5", function()
			local model = wired("pairs")
			local joinTimes, decisions = run(model, 0, 200000, 1, 3, never)
			-- Stop counting at 2000 joins (the run yields a few more).
			T.check(#joinTimes >= 2000, `{#joinTimes} joins`)
			local pairs, checked = 0, 0
			for i = 2, 2001 do
				checked += 1
				local decision = decisions[i]
				if decision.pairWith ~= nil then
					pairs += 1
					-- A friend joins 5..20 s after the one it pairs with, and pairs with exactly that one.
					local gap = joinTimes[i] - joinTimes[i - 1]
					T.between(gap, 5, 21, `friend gap {gap}`)
					local previous = 0
					for j = 1, i - 1 do
						previous += decisions[j].spawn
					end
					T.equal(decision.pairWith, `npc{previous}`, "pairs with the previous joiner")
				end
			end
			T.equal(checked, 2000)
			T.between(pairs / checked, 0.25, 0.35, `pair share {pairs / checked}`)
		end)

		T.it("rejoin rate 15% ± 4", function()
			local model = wired("rejoin")
			for i = 1, 2000 do
				model:onLeft(`seed{i}`, 0)
			end
			local queued = #model.rejoinQueue
			T.between(queued / 2000, 0.11, 0.19, `rejoin share {queued / 2000}`)
			for _, entry in model.rejoinQueue do
				T.between(entry.at, 300, 3600, `rejoin delay {entry.at}`)
			end
			-- A due rejoin is served by the next join, seed and all.
			local one = wired("rejoin-one")
			one:tick(0, 3, 0, HOUR)
			local tries = 0
			while #one.rejoinQueue == 0 do
				tries += 1
				one:onLeft(`left{tries}`, 10)
			end
			local due = one.rejoinQueue[1]
			local served = nil
			local now = 10
			while served == nil and now < 10000 do
				now += 1
				local decision = one:tick(now, 3, 0, HOUR)
				if decision.spawn > 0 and now >= due.at then
					served = decision.rejoinSeed
				end
			end
			T.equal(served, due.seed)
			T.equal(#one.rejoinQueue, 0)
		end)

		T.it("shorten only when 3 over target", function()
			local model = wired("shorten")
			model:tick(0, 2, 0, HOUR) -- burst
			T.equal(model:target(2, HOUR, 0), 7)
			T.equal(model:tick(1, 2, 8, HOUR).shorten, false, "1 over")
			T.equal(model:tick(2, 2, 9, HOUR).shorten, false, "2 over")
			T.equal(model:tick(3, 2, 10, HOUR).shorten, true, "3 over")
			T.equal(model:tick(4, 2, 10, HOUR).shorten, false, "one per gap")
			T.equal(model:tick(12, 2, 10, HOUR).shorten, false, "the gap is at least 10 s")
			local again = false
			for now = 13, 100 do
				if model:tick(now, 2, 10, HOUR).shorten then
					again = true
					break
				end
			end
			T.check(again, "shortens again within 90 s")
		end)

		T.it("shorten gaps have CV >= 0.3", function()
			local model = wired("cadence")
			local _, _, shortenTimes = run(model, 0, 20000, 1, 2, function()
				return 10
			end)
			T.check(#shortenTimes >= 200, `{#shortenTimes} shortens`)
			local gaps = gapsOf(shortenTimes)
			local sum = 0
			for _, gap in gaps do
				T.between(gap, 10, 91, `shorten gap {gap}`)
				sum += gap
			end
			local mean = sum / #gaps
			local variance = 0
			for _, gap in gaps do
				variance += (gap - mean) ^ 2
			end
			local cv = math.sqrt(variance / #gaps) / mean
			T.check(cv >= 0.3, `shorten cadence CV {cv} (mean {mean})`)
		end)

		T.it("retired names come back once after the retirement", function()
			local model = wired("retire")
			model:retireName("Alice", 0)
			model:retireName("Bob", 100)
			T.equal(#model:tick(1, 3, 0, HOUR).retire, 0)
			T.equal(#model:tick(7199, 3, 0, HOUR).retire, 0)
			local due = model:tick(7200, 3, 0, HOUR).retire
			T.equal(#due, 1)
			T.equal(due[1], "Alice")
			T.equal(#model:tick(7201, 3, 0, HOUR).retire, 0, "listed once")
			local later = model:tick(7300, 3, 0, HOUR).retire
			T.equal(#later, 1)
			T.equal(later[1], "Bob")
			T.equal(#model.retired, 0)
		end)
	end)
end

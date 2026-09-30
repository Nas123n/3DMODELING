return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Timing = session.require(session.game.ServerStorage.HumanlikeNpc.Timing)

	T.describe("Timing", function()
		T.it("reaction times are heavy-tailed and never instant", function()
			local rng = Rng.new(1)
			local sumE, sumU, n = 0, 0, 5000
			for _ = 1, n do
				local e = Timing.reaction(rng, true)
				local u = Timing.reaction(rng, false)
				T.between(e, 0.25, 6)
				T.between(u, 0.5, 8)
				sumE += e
				sumU += u
			end
			T.between(sumE / n, 1.1, 1.6, "expected-stimulus mean")
			T.check(sumU / n > sumE / n + 1, "unexpected stimuli take longer")
			T.check(Timing.reaction(Rng.new(2), true, 2) >= 0.5, "scale multiplies")
		end)

		T.it("geometric counts start at min and have the right mean", function()
			local rng = Rng.new(3)
			local sum, n = 0, 5000
			for _ = 1, n do
				local k = Timing.geometric(rng, 0.35, 1, 12)
				T.between(k, 1, 12)
				sum += k
			end
			T.between(sum / n, 2.4, 3.2, "mean of geometric(0.35) from 1")
		end)

		T.it("OU noise stays bounded and mean-reverting", function()
			local rng = Rng.new(4)
			local x, maxAbs, sum = 0, 0, 0
			for _ = 1, 20000 do
				x = Timing.stepOu(rng, x, 4, 3, 1 / 30)
				maxAbs = math.max(maxAbs, math.abs(x))
				sum += x
			end
			T.check(maxAbs < 8, `OU escaped: {maxAbs}`)
			T.near(sum / 20000, 0, 0.15, "mean reverts to zero")
		end)

		T.it("bursts cluster events: short gaps inside bursts, long gaps between, high burstiness", function()
			local rng = Rng.new(5)
			local burst = Timing.newBurst(rng, {
				interMedian = 40,
				interSpread = 0.9,
				withinMean = 0.68,
				withinDev = 0.05,
				withinLo = 0.55,
				withinHi = 0.85,
				lengthP = 0.35,
				maxLength = 8,
			}, 0)
			local times = {}
			local now = 0
			while now < 20000 do
				if burst:poll(now) then
					table.insert(times, now)
				end
				now += 0.1
			end
			T.check(#times > 500, `only {#times} events`)
			local gaps = {}
			for i = 2, #times do
				gaps[i - 1] = times[i] - times[i - 1]
			end
			local short, long = 0, 0
			for _, g in gaps do
				if g < 1 then
					short += 1
				elseif g > 5 then
					long += 1
				end
			end
			T.check(short > 0.4 * #gaps, "most gaps are within-burst rhythm")
			T.check(long > 0.1 * #gaps, "and a good share are long silences")
			-- Burstiness B = (sigma - mu) / (sigma + mu): 0 for a memoryless process, -1 for a
			-- metronome, positive for bursts (Goh & Barabasi).
			local mean = 0
			for _, g in gaps do
				mean += g
			end
			mean /= #gaps
			local variance = 0
			for _, g in gaps do
				variance += (g - mean) ^ 2
			end
			local sigma = math.sqrt(variance / #gaps)
			local burstiness = (sigma - mean) / (sigma + mean)
			T.check(burstiness > 0.3, `burstiness should be clearly positive, got {burstiness}`)
		end)

		T.it("every-timers space events by a heavy-tailed gap", function()
			local rng = Rng.new(6)
			local every = Timing.newEvery(rng, 4, 1.1, 0.5, 300, 0)
			local fired, now = 0, 0
			while now < 100000 do
				if every:poll(now) then
					fired += 1
				end
				now += 0.5
			end
			-- Mean of lognormal(ln 4, 1.1) is about 7.3 s, so roughly 13k events in 100k s.
			T.between(fired, 9000, 18000, `fired {fired} times`)
		end)
	end)
end

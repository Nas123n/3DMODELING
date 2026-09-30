return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)

	T.describe("Rng", function()
		T.it("repeats the same sequence for the same seed", function()
			local a, b = Rng.new(1234), Rng.new(1234)
			for _ = 1, 100 do
				T.equal(a:nextUInt(), b:nextUInt())
			end
		end)

		T.it("accepts string seeds and separates different ones", function()
			T.equal(Rng.new("alpha"):next(), Rng.new("alpha"):next())
			T.check(Rng.new("alpha"):next() ~= Rng.new("beta"):next(), "different names should differ")
		end)

		T.it("does not get stuck on a zero seed", function()
			local rng = Rng.new(0)
			local seen = {}
			for _ = 1, 20 do
				seen[rng:nextUInt()] = true
			end
			local distinct = 0
			for _ in seen do
				distinct += 1
			end
			T.check(distinct > 15, `only {distinct} distinct values`)
		end)

		T.it("keeps next() in [0, 1) and range()/int() inside their bounds", function()
			local rng = Rng.new(7)
			for _ = 1, 5000 do
				local x = rng:next()
				T.check(x >= 0 and x < 1, `next() out of range: {x}`)
				local y = rng:range(-3, 5)
				T.check(y >= -3 and y < 5, `range() out of range: {y}`)
				local n = rng:int(2, 6)
				T.check(n >= 2 and n <= 6 and n == math.floor(n), `bad int {n}`)
			end
		end)

		T.it("weightedIndex follows the weights and skips zero weights", function()
			local rng = Rng.new(11)
			local hits = { 0, 0, 0 }
			for _ = 1, 6000 do
				local i = rng:weightedIndex({ 1, 0, 3 })
				hits[i] += 1
			end
			T.equal(hits[2], 0, "zero weight must never be picked")
			T.between(hits[3] / hits[1], 2.5, 3.5, "ratio of weights")
		end)

		T.it("normal() has mean ~0 and deviation ~1", function()
			local rng = Rng.new(5)
			local n, sum, sumSq = 20000, 0, 0
			for _ = 1, n do
				local x = rng:normal()
				sum += x
				sumSq += x * x
			end
			local mean = sum / n
			local variance = sumSq / n - mean * mean
			T.near(mean, 0, 0.03, "mean")
			T.near(variance, 1, 0.05, "variance")
		end)

		T.it("logNormal() is positive, right-skewed and centered on its median", function()
			local rng = Rng.new(9)
			local n, below, sum = 20000, 0, 0
			for _ = 1, n do
				local x = rng:logNormal(0.4, 0.5)
				T.check(x > 0, "log-normal must be positive")
				if x < 0.4 then
					below += 1
				end
				sum += x
			end
			T.near(below / n, 0.5, 0.02, "half the samples fall below the median")
			T.check(sum / n > 0.4, "mean sits above the median (right skew)")
		end)

		T.it("exponential() has the requested mean", function()
			local rng = Rng.new(3)
			local n, sum = 20000, 0
			for _ = 1, n do
				local x = rng:exponential(2)
				T.check(x >= 0, "exponential must be non-negative")
				sum += x
			end
			T.near(sum / n, 2, 0.06, "mean")
		end)

		T.it("shuffle keeps every element exactly once", function()
			local rng = Rng.new(21)
			local list = { 1, 2, 3, 4, 5, 6, 7, 8 }
			rng:shuffle(list)
			table.sort(list)
			for i = 1, 8 do
				T.equal(list[i], i)
			end
		end)

		T.it("forks independent, repeatable streams", function()
			local a, b = Rng.new(5), Rng.new(5)
			T.equal(a:fork("walk"):nextUInt(), b:fork("walk"):nextUInt())
			T.check(Rng.new(5):fork("walk"):next() ~= Rng.new(5):fork("chat"):next(), "salts should differ")
		end)
	end)
end

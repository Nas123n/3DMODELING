return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.Builders.Rng)

	T.describe("Rng", function()
		T.it("repeats the same sequence for the same seed", function()
			local a, b = Rng.new(1234), Rng.new(1234)
			for _ = 1, 100 do
				T.equal(a:nextUInt(), b:nextUInt())
			end
		end)

		T.it("accepts string seeds and separates different ones", function()
			local a, b = Rng.new("Volcano"), Rng.new("Volcano")
			T.equal(a:next(), b:next())
			T.check(Rng.new("Volcano"):next() ~= Rng.new("Meadow"):next(), "different names should differ")
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

		T.it("keeps next() in [0, 1) and range() inside its bounds", function()
			local rng = Rng.new(7)
			for _ = 1, 5000 do
				local x = rng:next()
				T.check(x >= 0 and x < 1, `next() out of range: {x}`)
				local y = rng:range(-3, 5)
				T.check(y >= -3 and y < 5, `range() out of range: {y}`)
			end
		end)

		T.it("returns every integer in int(lo, hi), inclusive, and nothing else", function()
			local rng = Rng.new(99)
			local hits = {}
			for _ = 1, 3000 do
				local n = rng:int(2, 6)
				T.check(n >= 2 and n <= 6 and n == math.floor(n), `bad int {n}`)
				hits[n] = (hits[n] or 0) + 1
			end
			for n = 2, 6 do
				T.check((hits[n] or 0) > 450, `value {n} is underrepresented: {hits[n]}`)
			end
		end)

		T.it("forks independent, repeatable streams", function()
			local a, b = Rng.new(5), Rng.new(5)
			local fa, fb = a:fork("Tree"), b:fork("Tree")
			T.equal(fa:nextUInt(), fb:nextUInt())
			T.check(Rng.new(5):fork("Tree"):next() ~= Rng.new(5):fork("Rocks"):next(), "salts should differ")
		end)
	end)
end

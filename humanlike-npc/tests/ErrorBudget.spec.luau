return function(T, Loader)
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local ErrorBudget = session.require(S.Runtime.ErrorBudget)

	T.describe("ErrorBudget", function()
		T.it("fifth error in 10 s trips", function()
			local budget = ErrorBudget.new()
			for i = 1, 4 do
				T.equal(budget:record("npc1", i * 2, `boom {i}`), false, `error {i} does not trip`)
			end
			T.equal(budget:recent("npc1", 8), 4)
			T.equal(budget:record("npc1", 9.5, "boom 5"), true, "fifth within 10 s trips")
			T.equal(budget:recent("npc1", 9.5), 5)
			T.equal(budget:recent("npc2", 9.5), 0, "another npc is separate")
			T.equal(budget:record("npc2", 9.5, "other"), false)
			budget:forget("npc1")
			T.equal(budget:recent("npc1", 9.5), 0, "forget clears the count")
			T.equal(budget:record("npc1", 9.6, "again"), false)
			T.equal(#budget:log(), 7, "the log keeps forgotten entries")
			local strict = ErrorBudget.new({ maxErrors = 2, window = 1 })
			T.equal(strict:record("x", 0, "a"), false)
			T.equal(strict:record("x", 0.5, "b"), true, "two within 1 s trips a budget of 2")
			T.equal(strict:record("x", 2, "c"), false, "the old two fell out of the 1-s window")
		end)

		T.it("errors 11 s apart never trip", function()
			local budget = ErrorBudget.new()
			for i = 0, 40 do
				T.equal(budget:record("npc1", i * 11, "slow leak"), false, `error at {i * 11}`)
				T.equal(budget:recent("npc1", i * 11), 1)
			end
			T.equal(budget:recent("npc1", 40 * 11 + 10), 1, "the last one is still inside the window")
			T.equal(budget:recent("npc1", 40 * 11 + 11), 0, "and out of it a second later")
			-- Exactly at the window edge counts as within.
			local edge = ErrorBudget.new()
			for i = 0, 3 do
				edge:record("e", i, "e")
			end
			T.equal(edge:record("e", 10, "e"), true, "10 s after the first is still within 10 s")
			local past = ErrorBudget.new()
			for i = 0, 3 do
				past:record("p", i, "p")
			end
			T.equal(past:record("p", 10.01, "p"), false, "the first one just fell out")
			T.equal(past:recent("p", 10.01), 4)
		end)

		T.it("log keeps the last 200", function()
			local budget = ErrorBudget.new()
			T.equal(#budget:log(), 0)
			for i = 1, 250 do
				budget:record(`npc{i % 7}`, i, `err {i}`)
			end
			local all = budget:log()
			T.equal(#all, 200)
			T.equal(all[1].message, "err 51", "oldest kept is the 51st")
			T.equal(all[1].at, 51)
			T.equal(all[1].id, "npc2")
			T.equal(all[200].message, "err 250", "newest last")
			for i = 2, 200 do
				T.check(all[i].at == all[i - 1].at + 1, "chronological, no gaps")
			end
			local last = budget:log(3)
			T.equal(#last, 3)
			T.equal(last[1].message, "err 248")
			T.equal(last[3].message, "err 250")
			T.equal(#budget:log(0), 0)
			T.equal(#budget:log(1000), 200, "a limit beyond the ring gives the whole ring")
			local small = ErrorBudget.new()
			small:record("a", 1, "one")
			small:record("b", 2, "two")
			local two = small:log()
			T.equal(#two, 2)
			T.equal(two[1].message, "one")
			T.equal(two[2].message, "two")
			T.equal(#small:log(1), 1)
			T.equal(small:log(1)[1].message, "two")
			T.equal(ErrorBudget.LOG_CAPACITY, 200)
		end)
	end)
end

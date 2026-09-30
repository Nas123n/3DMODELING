return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local TypingFreeze = session.require(S.Chat.TypingFreeze)

	local KINDS = { "pc", "pcShiftLock", "mobile", "console" }
	local VARIANTS = { "still", "heldKey", "free" }
	local forward = Vector3.new(0, 0, -1)

	local function tally(kind, moving, typingSeconds, n)
		local rng = Rng.new(kind .. tostring(n))
		local counts = { still = 0, heldKey = 0, free = 0 }
		local plans = {}
		for _ = 1, n do
			local plan = TypingFreeze.plan(rng, kind, moving, typingSeconds, forward)
			counts[plan.variant] = (counts[plan.variant] or 0) + 1
			table.insert(plans, plan)
		end
		return counts, plans
	end

	T.describe("TypingFreeze", function()
		T.it("weights per platform over 4000 draws within ±3 points", function()
			for _, kind in KINDS do
				local counts = tally(kind, true, 5, 4000)
				local expected = TypingFreeze.WEIGHTS[kind]
				for _, variant in VARIANTS do
					T.near(counts[variant] / 40, expected[variant], 3, `{kind} {variant} share`)
				end
			end
		end)

		T.it("mobile never holds a key", function()
			local counts, plans = tally("mobile", true, 4, 4000)
			T.equal(counts.heldKey, 0)
			T.check(counts.still > 0 and counts.free > 0, "still and free both appear")
			for _, plan in plans do
				T.check(plan.variant ~= "heldKey", "no held key on a thumbstick")
				T.check(plan.dir == nil, "no direction to keep")
			end
		end)

		T.it("heldKey caps at 3 s", function()
			local _, long = tally("pc", true, 10, 2000)
			local held = 0
			for _, plan in long do
				if plan.variant == "heldKey" then
					held += 1
					T.equal(plan.duration, 3, "the held walk")
					T.between(plan.total, 10.2, 10.6, "typing plus the release delay")
					T.check(plan.dir == forward, "keeps the last move direction")
				elseif plan.variant == "still" then
					T.between(plan.duration, 10.2, 10.6)
					T.equal(plan.total, plan.duration)
				else
					T.equal(plan.duration, 0)
					T.equal(plan.total, 0)
				end
			end
			T.check(held > 200, `expected about 300 held keys, got {held}`)
			local _, short = tally("pc", true, 2, 1000)
			for _, plan in short do
				if plan.variant == "heldKey" then
					T.equal(plan.duration, 2, "a short line is held for the whole typing time")
				end
			end
		end)

		T.it("not moving is always still", function()
			for _, kind in KINDS do
				local counts, plans = tally(kind, false, 4, 500)
				T.equal(counts.still, 500, kind)
				for _, plan in plans do
					T.between(plan.duration, 4.2, 4.6)
					T.equal(plan.total, plan.duration)
					T.check(plan.dir == nil)
				end
			end
		end)

		T.it("intent follows the plan's timeline and is nil for free plans", function()
			local rng = Rng.new(11)
			local plan
			repeat
				plan = TypingFreeze.plan(rng, "pc", true, 6, forward)
			until plan.variant == "heldKey"
			plan.startedAt = 100
			local a = TypingFreeze.intent(plan, 100)
			T.equal(a.kind, "freeze")
			T.equal(a.variant, "walkStraight")
			T.near(a.duration, 3, 1e-9)
			T.check(a.dir == forward)
			local b = TypingFreeze.intent(plan, 103.5)
			T.equal(b.variant, "still")
			T.near(b.duration, plan.total - 3.5, 1e-9)
			T.equal(TypingFreeze.intent(plan, 100 + plan.total + 0.01), nil, "over")
			T.equal(TypingFreeze.intent({ variant = "free", duration = 0, total = 0 }, 0), nil, "free never freezes")
			-- A plan without startedAt starts now.
			local still = TypingFreeze.plan(rng, "mobile", false, 2)
			local c = TypingFreeze.intent(still, 50)
			T.equal(c.variant, "still")
			T.near(c.duration, still.total, 1e-9)
		end)

		T.it("is deterministic per seed", function()
			local a, b = tally("console", true, 3, 300), tally("console", true, 3, 300)
			for _, variant in VARIANTS do
				T.equal(a[variant], b[variant])
			end
		end)
	end)
end

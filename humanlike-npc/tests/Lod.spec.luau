return function(T, Loader)
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Lod = session.require(S.Runtime.Lod)
	local Scheduler = session.require(S.Runtime.Scheduler)

	local function one(lod, id, distance, visible, now)
		return lod:effectiveDistances({ { id = id, distance = distance, visible = visible } }, now)[id]
	end

	T.describe("Lod", function()
		T.it("visible far npc is promoted to near", function()
			local lod = Lod.new()
			T.check(one(lod, "a", 240, true, 0) < 60, "visible at 240 reads as near")
			T.equal(one(lod, "a", 240, true, 0), 59, "promoted to just inside the near band")
			T.equal(one(lod, "b", 240, false, 0), 240, "not visible: the raw distance")
			T.equal(one(lod, "c", 260, true, 0), 260, "visible beyond visibleRange: not promoted")
			T.equal(one(lod, "d", 30, true, 0), 30, "already near: the raw distance, never raised")
			T.equal(
				Lod.new({ visibleRange = 300 })
					:effectiveDistances({ { id = "c", distance = 260, visible = true } }, 0).c,
				59
			)
			local scheduler = Scheduler.new()
			scheduler:add("a", 0, 0)
			scheduler:assignTiers(lod:effectiveDistances({ { id = "a", distance = 240, visible = true } }, 0))
			T.equal(scheduler:tierOf("a"), "near")
		end)

		T.it("demotion waits 2 s", function()
			local lod = Lod.new()
			T.equal(one(lod, "a", 50, false, 0), 50)
			local t = 1
			T.check(one(lod, "a", 300, false, t) < 60 * 1.25, "held right after the jump")
			T.check(one(lod, "a", 300, false, t + 1.9) < 60 * 1.25, "still held at t+1.9")
			T.equal(one(lod, "a", 300, false, t + 2.1), 300, "released at t+2.1")
			T.equal(lod:tierOf("a"), "far")
			-- Dipping back inside the band resets the delay.
			T.equal(one(lod, "b", 50, false, 0), 50)
			T.check(one(lod, "b", 300, false, 1) < 60, "held")
			T.equal(one(lod, "b", 40, false, 2), 40, "back inside: immediate")
			T.check(one(lod, "b", 300, false, 2.5) < 60, "held again from a fresh start")
			T.check(one(lod, "b", 300, false, 4.4) < 60, "1.9 s after the second departure")
			T.equal(one(lod, "b", 300, false, 4.6), 300)
			-- Promotion is immediate and a lost line of sight is a demotion like any other.
			T.equal(one(lod, "c", 450, false, 0), 450)
			T.equal(one(lod, "c", 150, false, 0.5), 150, "far to mid at once")
			T.equal(one(lod, "c", 240, true, 1), 59, "seen: near at once")
			T.check(one(lod, "c", 240, false, 1.5) < 60, "occluded again: held near")
			T.check(one(lod, "c", 240, false, 3.4) < 60, "1.9 s after losing sight: still held")
			T.equal(one(lod, "c", 240, false, 3.6), 240, "2.1 s after losing sight: released")
			-- Mid holds at its own edge and the delay is configurable.
			local quick = Lod.new({ downgradeDelay = 0.5 })
			T.equal(one(quick, "d", 150, false, 0), 150)
			T.equal(one(quick, "d", 700, false, 1), 199, "held just inside mid")
			T.equal(one(quick, "d", 700, false, 1.6), 700)
			T.equal(quick:tierOf("d"), "dormant")
			-- The whole thing drives the scheduler without a flap.
			local scheduler = Scheduler.new()
			scheduler:add("e", 0, 0)
			scheduler:assignTiers(lod:effectiveDistances({ { id = "e", distance = 50, visible = false } }, 0))
			for _, now in { 0.5, 1, 1.5, 2 } do
				scheduler:assignTiers(lod:effectiveDistances({ { id = "e", distance = 300, visible = false } }, now))
				T.equal(scheduler:tierOf("e"), "near", `still near at {now}`)
			end
			local changes =
				scheduler:assignTiers(lod:effectiveDistances({ { id = "e", distance = 300, visible = false } }, 2.5))
			T.equal(#changes, 1)
			T.equal(changes[1].to, "far")
		end)

		T.it("pressure 1 doubles distances", function()
			local lod = Lod.new()
			lod:setPressure(1)
			local out = lod:effectiveDistances({
				{ id = "a", distance = 100, visible = false },
				{ id = "b", distance = 30, visible = false },
				{ id = "c", distance = 240, visible = true },
			}, 0)
			T.equal(out.a, 200)
			T.equal(out.b, 60)
			T.equal(out.c, 118, "the promoted 59 is scaled too")
			lod:setPressure(0.5)
			T.near(one(lod, "a", 100, false, 1), 100 / 0.75, 1e-9, "p 0.5 scales by 1/(1-0.25)")
			lod:setPressure(0)
			T.equal(one(lod, "a", 100, false, 2), 100)
			lod:setPressure(2)
			T.equal(lod.pressure, 1, "clamped to 1")
			lod:setPressure(-1)
			T.equal(lod.pressure, 0, "clamped to 0")
			-- Pressure is applied after the hold, so a held npc gets cheaper immediately under load.
			local held = Lod.new()
			T.equal(one(held, "h", 50, false, 0), 50)
			T.equal(one(held, "h", 300, false, 1), 59, "held")
			held:setPressure(1)
			T.equal(one(held, "h", 300, false, 1.5), 118, "held value doubled: mid under pressure")
			T.equal(held:tierOf("h"), "near", "the hold itself is judged on unscaled distances")
		end)

		T.it("no players: distance 0 stays 0 and forget clears the hold", function()
			local lod = Lod.new()
			local out = lod:effectiveDistances({
				{ id = "a", distance = 0, visible = false },
				{ id = "b", distance = 0, visible = true },
			}, 0)
			T.equal(out.a, 0)
			T.equal(out.b, 0)
			lod:setPressure(1)
			T.equal(one(lod, "a", 0, false, 1), 0, "0 scaled is still 0: everyone near with no players")
			lod:setPressure(0)
			T.equal(one(lod, "a", 300, false, 2), 59, "leaving 0 is a demotion and is held")
			lod:forget("a")
			T.equal(lod:tierOf("a"), nil)
			T.equal(one(lod, "a", 300, false, 2.5), 300, "forgotten: first sighting takes the raw distance")
			lod:forget("never-seen") -- no error
			T.equal(one(lod, "b", 0, false, 3), 0, "another id is untouched by forget")
		end)
	end)
end

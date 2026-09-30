return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local NavMath = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.NavMath)
	local InputProfile = session.require(session.game.ServerStorage.HumanlikeNpc.Human.InputProfile)
	local CameraModel = session.require(session.game.ServerStorage.HumanlikeNpc.Human.CameraModel)
	local JumpHabit = session.require(session.game.ServerStorage.HumanlikeNpc.Human.JumpHabit)

	T.describe("NavMath", function()
		T.it("yaw and direction round-trip with Roblox's look-vector convention", function()
			for _, yaw in { 0, 0.5, -1.2, 2.9, -3.1 } do
				local dir = NavMath.dirFromYaw(yaw)
				T.near(NavMath.wrap(NavMath.yawOf(dir) - yaw), 0, 1e-6)
			end
			T.near(NavMath.dirFromYaw(0).Z, -1, 1e-9, "yaw 0 faces -Z")
			T.near(math.abs(NavMath.wrap(math.pi * 3)), math.pi, 1e-9)
			T.near(NavMath.wrap(math.rad(370)), math.rad(10), 1e-9)
			T.near(NavMath.turnAngle(Vector3.new(0, 0, -1), Vector3.new(1, 0, 0)), -math.pi / 2, 1e-6)
		end)
	end)

	T.describe("InputProfile", function()
		T.it("samples the mix and jitters numbers without touching booleans", function()
			local rng = Rng.new(1)
			local counts = {}
			for _ = 1, 2000 do
				local p = InputProfile.sample(rng)
				counts[p.kind] = (counts[p.kind] or 0) + 1
				local base = InputProfile.BASE[p.kind]
				T.equal(p.quantize8, base.quantize8)
				T.equal(p.analog, base.analog)
				if base.wobbleAmpDeg > 0 then
					T.between(p.wobbleAmpDeg, base.wobbleAmpDeg * 0.6, base.wobbleAmpDeg * 1.4)
				else
					T.equal(p.wobbleAmpDeg, 0)
				end
			end
			T.between(counts.mobile / 2000, 0.45, 0.65)
			T.between(counts.pc / 2000, 0.22, 0.38)
			T.check(counts.console > 40)
		end)

		T.it("keyboard profiles snap and analog profiles wobble", function()
			local pc = InputProfile.sample(Rng.new(2), "pc")
			local mobile = InputProfile.sample(Rng.new(3), "mobile")
			T.check(pc.quantize8 and not pc.analog and pc.wobbleAmpDeg == 0 and pc.microStopMean == 0)
			T.check(mobile.analog and not mobile.quantize8 and mobile.wobbleAmpDeg > 0 and mobile.microStopMean > 0)
			T.check(not mobile.walksBack and pc.walksBack)
		end)
	end)

	T.describe("CameraModel", function()
		T.it("lags a big turn, then catches up at its rate, and snaps moves to 45 degrees", function()
			local cam = CameraModel.new(0, 90, 0.25, true)
			local desired = math.pi / 2 -- a 90 degree corner
			local now, dt = 0, 1 / 60
			local yawAt = {}
			while now < 2 do
				local y = cam:update(desired, dt, now)
				yawAt[math.floor(now * 10)] = y -- last sample in each tenth of a second
				now += dt
			end
			T.near(yawAt[1], 0, 0.05, "nothing happens during the lag")
			T.check(
				yawAt[6] > math.rad(25) and yawAt[6] < math.rad(50),
				`turning at about 90 deg/s, got {math.deg(yawAt[6])}`
			)
			T.near(yawAt[19], desired, 0.06, "caught up")

			local fresh = CameraModel.new(0, 90, 0.25, true)
			local snapped = fresh:snapMove(NavMath.dirFromYaw(math.rad(20)))
			T.near(NavMath.yawOf(snapped), 0, 1e-6, "20 degrees snaps to straight ahead")
			local diag = fresh:snapMove(NavMath.dirFromYaw(math.rad(30)))
			T.near(NavMath.yawOf(diag), math.rad(45), 1e-6, "30 degrees snaps to the diagonal")
		end)

		T.it("small heading changes drift without lag and lookAt overrides temporarily", function()
			local cam = CameraModel.new(0, 45, 0.25, true)
			cam:update(math.rad(20), 0.5, 0)
			T.check(math.abs(cam.yaw - math.rad(20)) < 0.05, "drifted to the small change")
			cam:lookAt(math.pi, 1)
			for i = 1, 60 do
				cam:update(math.rad(20), 1 / 60, i / 60)
			end
			T.check(cam.yaw > math.rad(40), "turned toward the look target")
			for i = 61, 300 do
				cam:update(math.rad(20), 1 / 60, i / 60)
			end
			T.near(cam.yaw, math.rad(20), 0.06, "returned to steering after the look expired")
		end)
	end)

	T.describe("JumpHabit", function()
		T.it("tiers follow their weights and never-jumpers never jump", function()
			local rng = Rng.new(4)
			local counts = { never = 0, occasional = 0, spammer = 0 }
			for _ = 1, 3000 do
				counts[JumpHabit.pickTier(rng)] += 1
			end
			T.between(counts.never / 3000, 0.34, 0.46)
			T.between(counts.spammer / 3000, 0.19, 0.31)
			local profile = InputProfile.sample(Rng.new(5), "pc")
			local never = JumpHabit.new(Rng.new(6), profile, 0, "never")
			for t = 0, 600, 0.1 do
				T.check(not never:poll(t, true, true, false), "never means never")
			end
		end)

		T.it("spammers jump far more than occasional jumpers, in airtime-pinned bursts", function()
			local profile = InputProfile.sample(Rng.new(7), "pc")
			local function countJumps(tier, seconds, moving)
				local habit = JumpHabit.new(Rng.new(8), profile, 0, tier)
				local n, times = 0, {}
				for t = 0, seconds, 0.05 do
					if habit:poll(t, moving, true, false) then
						n += 1
						table.insert(times, t)
					end
				end
				return n, times
			end
			local spam, times = countJumps("spammer", 600, true)
			local occ = countJumps("occasional", 600, true)
			T.check(spam > occ * 2, `spammer {spam} vs occasional {occ}`)
			T.between(spam / 10, 4, 20, "spammer jumps per minute while walking")
			local shortGaps = 0
			for i = 2, #times do
				local gap = times[i] - times[i - 1]
				if gap < 0.9 then
					shortGaps += 1
					T.between(gap, 0.55, 0.85, "within-burst rhythm is airtime")
				end
			end
			T.check(shortGaps > 0, "bursts exist")
		end)

		T.it("typing blocks keyboard jumps, airborne blocks all, afk mood silences, mirroring copies", function()
			local pc = InputProfile.sample(Rng.new(9), "pc")
			local habit = JumpHabit.new(Rng.new(10), pc, 0, "spammer")
			local jumpsTyping, jumpsAir = 0, 0
			for t = 0, 600, 0.05 do
				if habit:poll(t, false, true, true) then
					jumpsTyping += 1
				end
				if habit:poll(t, false, false, false) then
					jumpsAir += 1
				end
			end
			T.equal(jumpsTyping, 0)
			T.equal(jumpsAir, 0)
			habit:setMood("afk", 600)
			local afk = 0
			for t = 600, 1200, 0.05 do
				if habit:poll(t, false, true, false) then
					afk += 1
				end
			end
			T.equal(afk, 0)

			local mirror = JumpHabit.new(Rng.new(11), pc, 0, "occasional")
			local copied = 0
			for trial = 1, 100 do
				local base = trial * 100
				mirror:mirror(base)
				for t = base, base + 4, 0.05 do
					if mirror:poll(t, false, true, false) and t - base < 3.5 and t - base >= 1 then
						copied += 1
						break
					end
				end
			end
			T.between(copied / 100, 0.55, 0.85, "about 70% of seen jumps are copied 1-3 s later")
		end)
	end)
end

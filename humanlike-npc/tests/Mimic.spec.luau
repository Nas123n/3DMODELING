return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local NavMath = session.require(S.Nav.NavMath)
	local MotionStats = session.require(S.Mimic.MotionStats)
	local MimicSampler = session.require(S.Mimic.MimicSampler)
	local TraceBank = session.require(S.Mimic.TraceBank)

	local HZ = 10
	local DT = 1 / HZ

	-- Feeds `count` log-normal values of one feature into a fresh Stats; returns the Stats.
	local function lognormalStats(feature, count, sourceSeed, reservoirSeed, median, spread)
		local stats = MotionStats.new()
		local source, rng = Rng.new(sourceSeed), Rng.new(reservoirSeed)
		for _ = 1, count do
			stats:observe(feature, source:logNormal(median, spread), rng)
		end
		return stats
	end

	-- Builds a 10 Hz kinematic track from segments { dir = Vector3, speed = studs/s, seconds = n, yawStep? =
	-- radians per sample while stopped, jumpAt? = { seconds offsets } }. Positions integrate the velocity.
	local function buildTrack(segments)
		local track = {}
		local position = Vector3.zero
		local at = 0
		local yaw = 0
		for _, seg in segments do
			local dir = seg.dir or Vector3.zero
			local velocity = dir * (seg.speed or 0)
			if velocity.Magnitude > 0 then
				yaw = NavMath.yawOf(velocity)
			end
			local samples = math.floor(seg.seconds * HZ + 0.5)
			local jumps = {}
			for _, offset in seg.jumpAt or {} do
				jumps[math.floor(offset * HZ + 0.5)] = true
			end
			for k = 0, samples - 1 do
				if velocity.Magnitude == 0 and seg.yawStep then
					yaw += seg.yawStep
				end
				table.insert(track, {
					position = position,
					velocity = velocity,
					yaw = yaw,
					at = at,
					jumped = jumps[k] == true,
				})
				position += velocity * DT
				at += DT
			end
		end
		return track
	end

	local function mean(list)
		local sum = 0
		for _, v in list do
			sum += v
		end
		return sum / #list
	end

	local function maxOf(list)
		local best = -math.huge
		for _, v in list do
			best = math.max(best, v)
		end
		return best
	end

	T.describe("Mimic", function()
		T.describe("MotionStats", function()
			T.it("reservoir keeps 256 and quantiles track the source", function()
				local stats = lognormalStats("stopDuration", 10000, "mimic-source", "mimic-reservoir", 2.4, 0.9)
				T.equal(stats:count("stopDuration"), 10000, "count is everything observed")
				T.equal(#stats:values("stopDuration"), 256, "reservoir size")
				local q50 = stats:quantile("stopDuration", 0.5)
				T.check(q50 ~= nil, "quantile available")
				T.near(q50, 2.4, 0.24, "q50 within 10% of the source median")
				local q10, q90 = stats:quantile("stopDuration", 0.1), stats:quantile("stopDuration", 0.9)
				T.check(q10 < q50 and q50 < q90, "quantiles are ordered")
				T.check(q90 / q50 > 2 and q50 / q10 > 2, "the tail spread of a spread-0.9 log-normal survives")
				local hist = stats:histogram("stopDuration")
				T.equal(#hist, 24, "24 bins")
				local total = 0
				for _, c in hist do
					total += c
				end
				T.equal(total, 10000, "histogram counts every observation")
				T.equal(stats:quantile("goDuration", 0.5), nil, "empty feature has no quantile")
				T.equal(stats:sample("goDuration", Rng.new(1)), nil, "empty feature has no sample")
				for _ = 1, 7 do
					stats:observe("goDuration", 1, Rng.new(2))
				end
				T.equal(stats:sample("goDuration", Rng.new(1)), nil, "below 8 samples there is no sample")
				stats:observe("goDuration", 1, Rng.new(2))
				T.equal(stats:sample("goDuration", Rng.new(1)), 1, "8 samples is enough")
			end)

			T.it("is deterministic for a seed and ignores non-finite values", function()
				local a = lognormalStats("turnRate", 3000, "s", "r", 48, 1)
				local b = lognormalStats("turnRate", 3000, "s", "r", 48, 1)
				local va, vb = a:values("turnRate"), b:values("turnRate")
				T.equal(#va, #vb)
				for i = 1, #va do
					T.equal(va[i], vb[i], `reservoir slot {i}`)
				end
				a:observe("turnRate", 0 / 0, Rng.new(1))
				a:observe("turnRate", math.huge, Rng.new(1))
				T.equal(a:count("turnRate"), 3000, "NaN and inf are dropped")
			end)

			T.it("KS of identical reservoirs is < 0.1", function()
				local a = lognormalStats("speedRatio", 10000, "same-source", "reservoir-a", 0.86, 0.2)
				local b = lognormalStats("speedRatio", 10000, "same-source", "reservoir-b", 0.86, 0.2)
				local ks = a:ks("speedRatio", b)
				T.check(ks < 0.1, `KS of two reservoirs over the same values: {ks}`)
				T.equal(a:ks("speedRatio", a), 0, "a reservoir against itself")
				local c = lognormalStats("speedRatio", 10000, "same-source", "reservoir-a", 0.86, 0.2)
				T.equal(a:ks("speedRatio", c), 0, "same seeds give the same reservoir")
				local shifted = lognormalStats("speedRatio", 10000, "other-source", "reservoir-c", 1.72, 0.2)
				T.check(a:ks("speedRatio", shifted) > 0.3, "a distribution shifted x2 is far away")
				T.equal(a:ks("goDuration", b), 0, "nothing observed on either side is no evidence")
			end)

			T.it("fills a reservoir from a histogram on the same bin grid", function()
				local a = lognormalStats("jumpGap", 10000, "hist-source", "hist-reservoir", 21, 0.8)
				local b = MotionStats.new()
				b:fillFromHistogram("jumpGap", a:histogram("jumpGap"))
				T.equal(#b:values("jumpGap"), 256)
				T.check(b:count("jumpGap") >= 8, "counts as observed")
				T.near(b:quantile("jumpGap", 0.5), 21, 5, "median from bin centres")
				T.check(a:ks("jumpGap", b) < 0.2, `KS reservoir vs histogram {a:ks("jumpGap", b)}`)
				local centers = MotionStats.binCenters()
				local edges = MotionStats.binEdges()
				T.equal(#centers, 24)
				T.equal(#edges, 25)
				T.near(edges[1], 0.01, 1e-9)
				T.near(edges[25], 1000, 1e-6)
				T.equal(MotionStats.binOf(0.001), 1)
				T.equal(MotionStats.binOf(5000), 24)
				T.check(centers[3] > edges[3] and centers[3] < edges[4], "centre sits inside its bin")
			end)

			T.it("featuresFrom: steady walking gives ratio 1, no stops, jump gaps and one micro-stop rate", function()
				local east = Vector3.new(1, 0, 0)
				local track = buildTrack({ { dir = east, speed = 16, seconds = 30, jumpAt = { 2, 7, 15, 15.2 } } })
				local f = MotionStats.featuresFrom(track, 16)
				for _, name in MotionStats.FEATURES do
					T.check(f[name] ~= nil, `{name} present`)
				end
				T.equal(#f.speedRatio, 30, "one value per 1-s window")
				for _, r in f.speedRatio do
					T.near(r, 1, 1e-9)
				end
				T.equal(#f.stopDuration, 0)
				T.equal(#f.camSweep, 0)
				T.equal(#f.goDuration, 1)
				T.near(f.goDuration[1], 29.9, 1e-6, "one run, measured to its last sample")
				T.equal(#f.turnRate, 299)
				T.near(maxOf(f.turnRate), 0, 1e-9)
				T.equal(#f.jumpGap, 2, "the jump 0.2 s after another is the same jump")
				T.near(f.jumpGap[1], 5, 1e-6)
				T.near(f.jumpGap[2], 8, 1e-6)
				T.equal(#f.microStopRate, 1)
				T.near(f.microStopRate[1], 0, 1e-9)
				T.equal(#f.cornerCut, 0)
				local empty = MotionStats.featuresFrom({}, 16)
				T.equal(#empty.speedRatio, 0)
			end)

			T.it("featuresFrom: stop/go runs, micro-stops per walking minute and camera sweeps per stop", function()
				local east = Vector3.new(1, 0, 0)
				local track = buildTrack({
					{ dir = east, speed = 12, seconds = 8 },
					{ seconds = 3, yawStep = math.rad(0.5) },
					{ dir = east, speed = 12, seconds = 8 },
					{ seconds = 0.3 },
					{ dir = east, speed = 12, seconds = 8 },
					{ seconds = 2 },
				})
				local f = MotionStats.featuresFrom(track, 16)
				T.equal(#f.goDuration, 3)
				for _, g in f.goDuration do
					T.near(g, 8, 1e-6)
				end
				T.equal(#f.stopDuration, 3)
				T.near(f.stopDuration[1], 3, 1e-6)
				T.near(f.stopDuration[2], 0.3, 1e-6)
				T.near(f.stopDuration[3], 1.9, 1e-6, "the last stop is measured to its last sample")
				T.equal(#f.camSweep, 3, "one sweep per stop, aligned with stopDuration")
				T.near(f.camSweep[1], 29 * 0.5, 1e-6, "0.5 deg per sample over 30 stopped samples")
				T.near(f.camSweep[2], 0, 1e-9)
				T.near(f.camSweep[3], 0, 1e-9)
				T.equal(#f.microStopRate, 1)
				T.near(f.microStopRate[1], 60 / 24, 1e-6, "one micro-stop in 24 s of walking")
				for _, r in f.speedRatio do
					T.near(r, 0.75, 1e-9)
				end
			end)

			T.it("featuresFrom: a corner walked through its apex cuts nothing, a rounded one cuts studs", function()
				local east, north = Vector3.new(1, 0, 0), Vector3.new(0, 0, 1)
				local sharp =
					buildTrack({ { dir = east, speed = 10, seconds = 5 }, { dir = north, speed = 10, seconds = 5 } })
				local f = MotionStats.featuresFrom(sharp, 16)
				T.equal(#f.cornerCut, 1)
				T.near(f.cornerCut[1], 0, 1e-6)
				T.near(maxOf(f.turnRate), 900, 1e-6, "90 degrees in one 0.1-s sample")

				local rounded = buildTrack({
					{ dir = east, speed = 10, seconds = 4.9 },
					{ dir = Vector3.new(1, 0, 1).Unit, speed = 10 * math.sqrt(2), seconds = 0.1 },
					{ dir = north, speed = 10, seconds = 5 },
				})
				local g = MotionStats.featuresFrom(rounded, 16)
				T.equal(#g.cornerCut, 1)
				T.near(g.cornerCut[1], math.sqrt(0.5), 1e-6, "the diagonal step passes sqrt(0.5) studs from the apex")
				T.check(maxOf(g.turnRate) < 900, "the turn is split over two samples")

				local uturn =
					buildTrack({ { dir = east, speed = 10, seconds = 3 }, { dir = -east, speed = 10, seconds = 3 } })
				T.equal(#MotionStats.featuresFrom(uturn, 16).cornerCut, 0, "an about-face is not a corner")
			end)
		end)

		T.describe("MimicSampler", function()
			T.it("weight n/(n+k)", function()
				local stats = MotionStats.new()
				local sampler = MimicSampler.new(stats)
				T.equal(sampler:weight("speedRatio"), 0, "nothing learned")
				local rng = Rng.new("w")
				for _ = 1, 200 do
					stats:observe("speedRatio", 0.8, rng)
				end
				T.near(sampler:weight("speedRatio"), 0.5, 1e-9, "n 200 with k 200")
				for _ = 1, 600 do
					stats:observe("speedRatio", 0.8, rng)
				end
				T.near(sampler:weight("speedRatio"), 0.8, 1e-9, "n 800")
				T.near(MimicSampler.new(stats, { k = 100 }):weight("speedRatio"), 800 / 900, 1e-9, "custom k")
				T.equal(sampler:weight("turnRate"), 0, "other features untouched")
			end)

			T.it("draw returns the fallback below 8 samples and jitters learned values by about 5%", function()
				local stats = MotionStats.new()
				local sampler = MimicSampler.new(stats)
				local rng = Rng.new("draw")
				T.equal(sampler:draw("stopDuration", 3, rng), 3, "nothing learned")
				for _ = 1, 5 do
					stats:observe("stopDuration", 2, rng)
				end
				T.equal(sampler:draw("stopDuration", 3, rng), 3, "too few samples")
				for _ = 1, 795 do
					stats:observe("stopDuration", 2, rng)
				end
				local learned, fallback, spread = 0, 0, 0
				for _ = 1, 2000 do
					local v = sampler:draw("stopDuration", 3, rng)
					if v == 3 then
						fallback += 1
					else
						learned += 1
						spread += (v - 2) * (v - 2)
					end
				end
				T.between(learned / 2000, 0.75, 0.85, "learned with p weight = 0.8")
				T.near(math.sqrt(spread / learned) / 2, 0.05, 0.01, "relative jitter")
				T.check(fallback > 0)
			end)

			T.it("shape blends toward learned speed", function()
				local stats = MotionStats.new()
				local feed = Rng.new("feed")
				for _ = 1, 800 do
					stats:observe("speedRatio", 0.7, feed)
				end
				local sampler = MimicSampler.new(stats)
				local rng = Rng.new("shape")
				local cmd = { mode = "move", dir = Vector3.new(1, 0, 0), magnitude = 1, jump = false }
				local sum = 0
				for _ = 1, 500 do
					local shaped = sampler:shape(cmd, { rng = rng, moving = true, profileMagnitude = 1 })
					T.check(shaped ~= cmd, "a new command, not the input")
					T.between(shaped.magnitude, 0.55, 1)
					T.equal(shaped.mode, "move")
					T.equal(shaped.dir, cmd.dir)
					T.equal(shaped.jump, false)
					sum += shaped.magnitude
				end
				T.near(sum / 500, 0.76, 0.05, "0.2 * 1.0 + 0.8 * 0.7")
				T.equal(cmd.magnitude, 1, "input untouched")
				T.equal(sampler:shape(cmd, { rng = rng, moving = false, profileMagnitude = 1 }), cmd, "standing start")
				local stop = { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
				T.equal(sampler:shape(stop, { rng = rng, moving = true, profileMagnitude = 1 }), stop, "stops pass")
				local fresh = MimicSampler.new(MotionStats.new())
				T.equal(fresh:shape(cmd, { rng = rng, moving = true, profileMagnitude = 1 }), cmd, "nothing learned")
			end)

			T.it("shape clamps to [0.55, 1] and keeps facingYaw", function()
				local stats = MotionStats.new()
				local feed = Rng.new("feed2")
				for _ = 1, 5000 do
					stats:observe("speedRatio", 0.1, feed)
				end
				local sampler = MimicSampler.new(stats, { jitter = 0 })
				local rng = Rng.new("clamp")
				local cmd = { mode = "move", dir = Vector3.new(0, 0, 1), magnitude = 0.9, jump = true, facingYaw = 1.2 }
				local shaped = sampler:shape(cmd, { rng = rng, moving = true, profileMagnitude = 0.9 })
				T.near(shaped.magnitude, 0.55, 1e-9, "floor")
				T.equal(shaped.facingYaw, 1.2)
				T.equal(shaped.jump, true)
			end)
		end)

		T.describe("TraceBank", function()
			-- Feeds a scripted player at 10 Hz: segments { dir, magnitude, seconds, jumpAt? }.
			local function feed(bank, rng, key, segments, startAt)
				local at = startAt or 0
				for _, seg in segments do
					local samples = math.floor(seg.seconds * HZ + 0.5)
					local jumps = {}
					for _, offset in seg.jumpAt or {} do
						jumps[math.floor(offset * HZ + 0.5)] = true
					end
					for k = 0, samples - 1 do
						bank:observe({
							dir = seg.dir or Vector3.zero,
							magnitude = seg.magnitude or 0,
							jump = jumps[k] == true,
							at = at,
						}, key, rng)
						at += DT
					end
				end
				return at
			end

			local function checkIdentityFree(fragment)
				for key in fragment do
					T.check(key == "steps" or key == "seconds", `unexpected fragment field {key}`)
				end
				for _, step in fragment.steps do
					for key in step do
						T.check(
							key == "dir" or key == "magnitude" or key == "jump" or key == "dt",
							`unexpected step field {key}`
						)
					end
					T.check(typeof(step.dir) == "Vector3", "dir is a vector")
					T.check(step.dir.Magnitude <= 1 + 1e-6, "dir is unit or zero, never a position")
					T.near(step.dir.Y, 0, 1e-9, "flat")
					T.between(step.magnitude, 0, 1)
					T.check(step.dt > 0 and step.dt <= 1, "dt is a sample interval")
				end
			end

			T.it("fragments are cut at stops and hold no positions", function()
				local bank = TraceBank.new()
				local rng = Rng.new("bank")
				local at = 0
				local dirs = {
					Vector3.new(1, 0, 0),
					Vector3.new(0, 0, -1),
					Vector3.new(-1, 0, 1).Unit,
					Vector3.new(0.3, 0, 1).Unit,
				}
				T.equal(bank:pick(rng), nil, "empty bank")
				for cycle = 1, 10 do
					local d = dirs[(cycle - 1) % #dirs + 1]
					at = feed(bank, rng, 7, {
						{ dir = d, magnitude = 1, seconds = 2, jumpAt = { 0.5 } },
						{ seconds = 0.3 }, -- a pause shorter than a stop stays inside the fragment
						{ dir = d, magnitude = 0.8, seconds = 2 },
						{ seconds = 1.5 }, -- a real stop: cut
					}, at)
					if cycle < 8 then
						T.equal(bank:pick(rng), nil, `no pick with {bank:count()} fragments`)
					end
				end
				T.equal(bank:count(), 10, "one fragment per walk")
				local fragment = bank:pick(rng)
				T.check(fragment ~= nil, "pick after 8 fragments")
				for _, frag in bank.fragments do
					checkIdentityFree(frag)
					T.between(frag.seconds, 3, 10)
					T.near(frag.seconds, 4.3, 0.11, "2 + 0.3 pause + 2 s")
					T.near(frag.steps[1].dir.Z, 1, 1e-6, "first dir is +Z")
					T.near(frag.steps[1].dir.X, 0, 1e-6)
					local pauses, jumps = 0, 0
					for _, step in frag.steps do
						if step.magnitude == 0 then
							pauses += 1
						end
						if step.jump then
							jumps += 1
						end
						if step.magnitude > 0 then
							T.near(step.dir.Z, 1, 1e-6, "a straight walk stays +Z after rotation")
						end
					end
					T.equal(pauses, 3, "the 0.3-s pause is three zero steps")
					T.equal(jumps, 1)
				end
				bank:forget(7)
				T.equal(bank:count(), 10, "forgetting an open trace keeps complete fragments")
			end)

			T.it(
				"drops walks shorter than minSeconds, splits at maxSeconds, and samples uniformly past capacity",
				function()
					local rng = Rng.new("cuts")
					local short = TraceBank.new()
					feed(
						short,
						rng,
						1,
						{ { dir = Vector3.new(1, 0, 0), magnitude = 1, seconds = 2.5 }, { seconds = 2 } }
					)
					T.equal(short:count(), 0, "2.5 s is below the 3-s minimum")

					local long = TraceBank.new()
					feed(long, rng, 1, { { dir = Vector3.new(1, 0, 0), magnitude = 1, seconds = 15 }, { seconds = 2 } })
					T.equal(long:count(), 2, "a 15-s walk is a 10-s and a 5-s fragment")
					T.near(long.fragments[1].seconds, 10, 1e-6)
					T.near(long.fragments[2].seconds, 15 - 0.1 - 10, 1e-6)

					local gap = TraceBank.new()
					local at = feed(gap, rng, 1, { { dir = Vector3.new(1, 0, 0), magnitude = 1, seconds = 4 } })
					feed(
						gap,
						rng,
						1,
						{ { dir = Vector3.new(1, 0, 0), magnitude = 1, seconds = 4 }, { seconds = 2 } },
						at + 5
					)
					T.equal(gap:count(), 2, "a hole in the samples cuts too")

					local small = TraceBank.new({ capacity = 4 })
					local seen = {}
					at = 0
					for cycle = 1, 40 do
						local d = Vector3.new(math.cos(cycle), 0, math.sin(cycle))
						local magnitude = 0.1 + 0.9 * cycle / 40
						at = feed(
							small,
							rng,
							3,
							{ { dir = d, magnitude = magnitude, seconds = 3.5 }, { seconds = 1.2 } },
							at
						)
					end
					T.equal(small:count(), 4)
					T.equal(small.completed, 40)
					for _, frag in small.fragments do
						seen[frag.steps[1].magnitude] = true
					end
					local late = 0
					for m in seen do
						if m > 0.2 then
							late += 1
						end
					end
					T.check(late > 0, "later fragments can replace earlier ones")
				end
			)

			T.it("play rotates a fragment back into the world and keeps its turns", function()
				local bank = TraceBank.new()
				local rng = Rng.new("play")
				local east, north = Vector3.new(1, 0, 0), Vector3.new(0, 0, 1)
				feed(bank, rng, 9, {
					{ dir = east, magnitude = 1, seconds = 2 },
					{ dir = north, magnitude = 0.6, seconds = 2, jumpAt = { 0.4 } },
					{ seconds = 1.5 },
				})
				T.equal(bank:count(), 1)
				local frag = bank.fragments[1]
				T.near(frag.steps[1].dir.Z, 1, 1e-6, "first dir is +Z")
				local turned = frag.steps[#frag.steps].dir
				T.near(
					NavMath.turnAngle(frag.steps[1].dir, turned),
					NavMath.turnAngle(east, north),
					1e-6,
					"turn preserved"
				)
				for _, baseYaw in { 0, 0.7, -2.1, math.pi } do
					local first = TraceBank.play(frag, baseYaw, 1)
					T.equal(first.mode, "move")
					local want = NavMath.dirFromYaw(baseYaw)
					T.near(first.dir.X, want.X, 1e-6)
					T.near(first.dir.Z, want.Z, 1e-6)
					T.near(first.dir.Magnitude, 1, 1e-6)
					local last = TraceBank.play(frag, baseYaw, #frag.steps)
					T.near(NavMath.turnAngle(first.dir, last.dir), NavMath.turnAngle(east, north), 1e-6)
					T.near(last.magnitude, 0.6, 1e-9)
				end
				local jumps = 0
				for i = 1, #frag.steps do
					if TraceBank.play(frag, 0, i).jump then
						jumps += 1
					end
				end
				T.equal(jumps, 1)
				local past = TraceBank.play(frag, 0, #frag.steps + 1)
				T.equal(past.mode, "stop")
				T.equal(past.jump, false)
			end)

			T.it("prune drops silent open traces only", function()
				local bank = TraceBank.new()
				local rng = Rng.new("prune")
				feed(bank, rng, 1, { { dir = Vector3.new(1, 0, 0), magnitude = 1, seconds = 1 } }, 0)
				feed(bank, rng, 2, { { dir = Vector3.new(1, 0, 0), magnitude = 1, seconds = 1 } }, 100)
				bank:prune(101)
				T.check(bank.open[1] == nil, "silent for 100 s")
				T.check(bank.open[2] ~= nil, "still fresh")
			end)
		end)
	end)
end

-- Eval/Trace, Eval/TellScore and tools/lune/Harness. Every trace here is synthetic: a scripted "human-like"
-- population driven by Rng with heavy-tailed timings that should score 0, and one variant per tell that
-- injects exactly that tell. The FakeWorld-based scenarios of §9.6 (a 600-s arena run) live with the
-- integrator once FakeWorld exposes `trace`.
return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3, CFrame = roblox.Vector3, roblox.CFrame
	local Harness = require("../tools/lune/Harness")

	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local MotionStats = session.require(S.Mimic.MotionStats)
	local Trace = session.require(S.Eval.Trace)
	local TellScore = session.require(S.Eval.TellScore)

	local HZ = 10
	local DT = 1 / HZ
	local DEG = math.pi / 180
	local Z_75 = 0.6744897501960817

	local function yawOf(dir)
		return math.atan2(-dir.X, -dir.Z)
	end

	local function dirFromYaw(yaw)
		return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	end

	-- Agent writer -------------------------------------------------------------------------------------------
	-- Emits samples for one agent, integrating its position; `hook(sample, writer)` may edit a sample before
	-- it is pushed (and the writer's state, e.g. its yaw) so a scenario can inject one violation.

	local Writer = {}
	Writer.__index = Writer

	local function newWriter(trace, id, o)
		return setmetatable({
			trace = trace,
			id = id,
			kind = o.kind or "npc",
			profile = o.profile,
			walkSpeed = o.walkSpeed or 16,
			jumpTier = o.jumpTier,
			position = o.position or Vector3.zero,
			yaw = o.yaw or 0,
			at = o.startAt or 0,
			endAt = nil, -- samples at or past this time are not recorded (the agent has left)
			intent = o.intent or "idle",
			analogInput = o.analogInput,
			hook = o.hook,
			pending = {}, -- fields for the next sample only (said, text, replyTo, jumped, events)
			movingIndex = 0,
		}, Writer)
	end

	function Writer:queue(fields)
		for k, v in fields do
			self.pending[k] = v
		end
	end

	function Writer:emit(velocity, fields)
		if velocity.Magnitude >= 0.5 then
			self.movingIndex += 1
		end
		local s = {
			id = self.id,
			kind = self.kind,
			at = self.at,
			position = self.position,
			velocity = velocity,
			yaw = self.yaw,
			onGround = true,
			jumped = false,
			said = false,
			typing = false,
			emote = false,
			intent = self.intent,
			profile = self.profile,
			walkSpeed = self.walkSpeed,
			jumpTier = self.jumpTier,
			pushing = false,
			afkFull = false,
		}
		for k, v in self.pending do
			s[k] = v
		end
		self.pending = {}
		for k, v in fields or {} do
			s[k] = v
		end
		if self.hook then
			self.hook(s, self)
		end
		if not self.endAt or self.at < self.endAt - 1e-9 then
			self.trace:push(s)
		end
		self.position += velocity * DT
		self.at += DT
		return s
	end

	-- Walks `seconds` along `heading` (radians) at `speed`; `wobble(k, samples)` adds a heading offset per
	-- sample and `speedAt(k)` overrides the speed.
	function Writer:walk(heading, speed, seconds, o)
		o = o or {}
		local samples = math.floor(seconds * HZ + 0.5)
		for k = 0, samples - 1 do
			local h = heading + (if o.wobble then o.wobble(k, samples) else 0)
			local sp = if o.speedAt then o.speedAt(k) else speed
			self.yaw = h
			self:emit(dirFromYaw(h) * sp, if o.fields then o.fields(k) else nil)
		end
	end

	-- Turns by `delta` radians along an arc of the given radius at `speed`.
	function Writer:arc(from, delta, speed, radius)
		local rate = speed / radius -- rad/s
		local samples = math.max(1, math.floor(math.abs(delta) / rate * HZ + 0.5))
		for k = 1, samples do
			local h = from + delta * k / samples
			self.yaw = h
			self:emit(dirFromYaw(h) * speed)
		end
	end

	function Writer:stop(seconds, o)
		o = o or {}
		local samples = math.floor(seconds * HZ + 0.5)
		for k = 0, samples - 1 do
			if o.each then
				o.each(k, samples)
			end
			self:emit(Vector3.zero, if o.fields then o.fields(k) else nil)
		end
	end

	-- Scenario generator ------------------------------------------------------------------------------------
	-- A population of `npcs` agents walking between stops. Everything is drawn from `seed`: stop lengths with
	-- the human reference shape (its short tail is the micro-stops), log-normal go lengths, an arc at every
	-- corner, sinusoidal heading wobble whose peak rate is log-normal (thumb tremor) or a slow camera drift
	-- (shift-lock), analog speed ratios drawn from the human reference below 1 every second, jumps, camera
	-- sweeps and chat lines with log-normal gaps, a typing freeze before every line, and one changed mind
	-- every seventh trip. Options let a scenario bend exactly one thing.

	local POIS = { Vector3.new(20, 0, 20), Vector3.new(-25, 0, 10), Vector3.new(5, 0, -30), Vector3.new(-15, 0, -20) }
	local DEFAULT_PROFILES = { "pcShiftLock", "mobile", "mobile", "console" }
	local FAMILIES = { "digits", "camel", "lower", "prefixed", "handle", "leet", "xx", "underscore" }
	local SPEED_SIGMA = math.log(0.97 / 0.72) / (2 * Z_75)
	local STOP_SIGMA = math.log(9 / 0.6) / (2 * Z_75)

	local function human(o)
		o = o or {}
		local trace = Trace.new({ hz = HZ })
		local rng = Rng.new(o.seed or "human")
		local count = o.npcs or 4
		local seconds = o.seconds or 120
		local profiles = o.profiles or DEFAULT_PROFILES
		local lineGap = o.lineGapMedian or 70 * count / 4 -- about 3.5 NPC lines a minute server-wide
		local lineCounter = 0

		if o.marks ~= false then
			for i, p in POIS do
				trace:mark({ kind = "poi", at = 0, subject = `poi{i}`, source = p })
			end
			-- an avoid volume far from everything, so the box path runs on a clean trace
			trace:mark({ kind = "avoidBox", at = 0, cframe = CFrame.new(200, 5, 200), size = Vector3.new(10, 10, 10) })
		end
		if o.avoidBox then
			trace:mark({ kind = "avoidBox", at = 0, cframe = o.avoidBox.cframe, size = o.avoidBox.size })
		end
		for _, m in o.extraMarks or {} do
			trace:mark(m)
		end

		local writers = {}
		for i = 1, count do
			local id = `n:npc{i}`
			local profile = profiles[(i - 1) % #profiles + 1]
			local arrival = if o.arrivals then o.arrivals(i, rng) else 0
			local w = newWriter(trace, id, {
				profile = profile,
				walkSpeed = 16,
				jumpTier = o.jumpTier or "occasional",
				position = Vector3.new(rng:range(-30, 30), 0, rng:range(-30, 30)),
				yaw = rng:range(-math.pi, math.pi),
				startAt = arrival,
				intent = o.intent,
				hook = if o.hook
					then function(s, writer)
						o.hook(s, writer, i)
					end
					else nil,
			})
			writers[i] = w
			if o.marks ~= false then
				trace:mark({
					kind = "identity",
					at = arrival,
					subject = id,
					text = if o.names then o.names[i] else `Person{i}`,
					family = if o.names then nil else FAMILIES[(i - 1) % #FAMILIES + 1],
					avatar = if o.cloneAvatars then "R15|hair1|shirt1|pants1" else `R15|hair{i}|shirt{i}|pants{i}`,
				})
			end
		end
		for i = 1, o.players or 0 do
			-- players carry no profile in the trace, but their input has the same keyboard share
			local input = DEFAULT_PROFILES[(i - 1) % #DEFAULT_PROFILES + 1]
			writers[count + i] = newWriter(trace, `p:{i}`, {
				kind = "player",
				walkSpeed = 16,
				analogInput = input == "mobile" or input == "console",
				position = Vector3.new(rng:range(-30, 30), 0, rng:range(-30, 30)),
				yaw = rng:range(-math.pi, math.pi),
			})
		end

		local function simulate(i, w)
			local own = rng:fork(`agent{i}`)
			-- one timer stream per agent; a shared rhythm gives every agent the same stream from the start
			local timer = if o.sharedRhythm then Rng.new("shared") else own:fork("timer")
			local analog = if w.kind == "player"
				then w.analogInput == true
				else w.profile == "mobile" or w.profile == "console"
			local shiftLock = w.profile == "pcShiftLock"
			local sessionSeconds = if type(o.sessionSeconds) == "function"
				then o.sessionSeconds(i, own)
				elseif o.sessionSeconds then o.sessionSeconds
				else seconds
			local endAt = w.at + sessionSeconds
			if o.sessionSeconds then
				w.endAt = endAt -- a session that ends: nothing is recorded past it
			end
			local lineSigma = o.lineSigma or 0.8
			local nextJump = w.at + own:logNormalClamped(8, 0.9, 1, 60)
			local nextLine = w.at + own:logNormalClamped(lineGap, lineSigma, 5, 600)
			local nextSweep = w.at + own:logNormalClamped(15, 0.9, 3, 90)
			local trips, stops = 0, 0
			local goMedian = o.goMedian or 5.1
			local function setIntent(intent)
				if not o.intent then
					w.intent = intent
				end
			end
			while w.at < endAt do
				-- a stop
				stops += 1
				local stopSeconds = timer:logNormalClamped(o.stopMedian or 2.4, STOP_SIGMA, 0.1, 80)
				if o.stopSeconds then
					stopSeconds = o.stopSeconds
				end
				if o.longStops and shiftLock and stops % o.longStops.every == 0 then
					stopSeconds = o.longStops.seconds
				end
				if o.idleTurnEvery then
					-- 5k + 1 samples so exactly one interval in `idleTurnEvery` turns
					stopSeconds = (math.floor(stopSeconds * HZ / o.idleTurnEvery) * o.idleTurnEvery + 1) / HZ
				end
				setIntent("idle")
				local sweepUntil = -1
				local sweepRate = 0
				-- a long wait always gets one look around
				local forcedSweep = if shiftLock
						and not o.noSweep
						and stopSeconds > 20
					then own:range(2, stopSeconds - 3)
					else nil
				w:stop(stopSeconds, {
					each = function(k, samples)
						if shiftLock and not o.noSweep and k < samples - 11 then
							local due = w.at >= nextSweep or (forcedSweep and k * DT >= forcedSweep)
							if due and k * DT >= sweepUntil then
								sweepUntil = k * DT + 1
								sweepRate = own:range(20, 60) * DEG * own:sign()
								nextSweep = w.at + own:logNormalClamped(15, 0.9, 3, 90)
								forcedSweep = nil
							end
						end
						if k * DT < sweepUntil then
							w.yaw += sweepRate * DT
						end
						if o.idleTurnEvery and not shiftLock and k > 0 and k % o.idleTurnEvery == 0 then
							w.yaw += 30 * DEG * DT
						end
					end,
					fields = function(k)
						if o.lines ~= false and w.kind == "npc" and w.at >= nextLine and k * DT >= 1.6 then
							nextLine = w.at + own:logNormalClamped(lineGap, lineSigma, 5, 600)
							lineCounter += 1
							return { said = true, text = `line {lineCounter}` }
						end
						return nil
					end,
				})
				-- a trip: leg, corner, leg
				trips += 1
				setIntent("goto")
				local goSeconds = timer:logNormalClamped(goMedian, 0.8, goMedian * 0.3, goMedian * 2.75)
				local heading = own:range(-math.pi, math.pi)
				if w.position.Magnitude > 45 then
					heading = yawOf(-w.position) + own:range(-0.5, 0.5)
				end
				local function drawRatio()
					local r = own:logNormal(0.86, SPEED_SIGMA)
					while r >= 1 do
						r = own:logNormal(0.86, SPEED_SIGMA)
					end
					return math.max(r, 0.55)
				end
				local ratio = if analog then drawRatio() else 1
				local speed = w.walkSpeed * ratio * (o.speedScale or 1)
				local peak, hz, amp
				if analog then
					peak = own:logNormalClamped(100, 0.8, 15, 300) * DEG * (o.turnScale or 1)
					hz = own:range(1, 3)
					amp = peak / (2 * math.pi * hz)
				else
					peak = own:logNormalClamped(30, 0.6, 5, 60) * DEG * (o.turnScale or 1)
					hz = own:range(0.1, 0.3)
					amp = math.min(peak / (2 * math.pi * hz), 20 * DEG)
				end
				local phase = own:range(0, 2 * math.pi)
				local function wobble(k, samples)
					if o.noWobble then
						return 0
					end
					if o.sharpCorners and (k == 0 or k == samples - 1) then
						return 0 -- the samples either side of the corner sit on the legs' lines
					end
					return amp * math.sin(2 * math.pi * hz * k * DT + phase)
				end
				local second, secondRatio = -1, ratio
				local function speedAt(k)
					if o.constantSpeedFor == i then
						return w.walkSpeed
					end
					if analog then
						-- thumb pressure changes every second
						local s = math.floor(k / HZ)
						if s ~= second then
							second = s
							secondRatio = drawRatio()
						end
						return w.walkSpeed * math.clamp(secondRatio * (o.speedScale or 1), 0.2, 0.999)
					end
					return speed
				end
				local function fields(k)
					local out = nil
					if not o.noJumps and o.noJumpsFor ~= i and w.at >= nextJump then
						nextJump = w.at + own:logNormalClamped(8, 0.9, 1, 60)
						out = { jumped = true }
					end
					if o.talkWhileWalking == i and w.at >= nextLine then
						nextLine = w.at + own:logNormalClamped(lineGap, lineSigma, 5, 600)
						lineCounter += 1
						out = out or {}
						out.said = true
						out.text = `line {lineCounter}`
					end
					return out
				end
				local legOptions = { wobble = wobble, speedAt = speedAt, fields = fields }
				if o.straightTrips then
					w:walk(heading, speed, goSeconds, legOptions)
				elseif o.zigzag then
					local first = goSeconds * 0.4
					w:walk(heading, speed, first, legOptions)
					local legs = math.max(2, math.floor((goSeconds - first) / 0.5))
					for leg = 1, legs do
						heading += if leg % 2 == 1 then o.zigzag * DEG else -o.zigzag * DEG
						w:walk(heading, speed, 0.5, legOptions)
					end
				else
					local first = goSeconds * timer:range(0.3, 0.7)
					w:walk(heading, speed, first, legOptions)
					local turn = timer:range(65, 115) * DEG * timer:sign()
					if o.sharpCorners then
						-- no arc: the heading flips within one sample
					elseif o.sharedRhythm then
						w:arc(heading, turn, speed, speed / 4) -- the same sample count for every speed
					else
						w:arc(heading, turn, speed, own:range(2.5, 4))
					end
					w:walk(heading + turn, speed, goSeconds - first, legOptions)
				end
				if o.events ~= false and w.kind == "npc" then
					local every = if o.changedMindEvery ~= nil then o.changedMindEvery else 7
					local changed = every > 0 and trips % every == 3
					w:queue({ events = { if changed then "changedMind" else "arrived" } })
				end
			end
			if o.sessionSeconds and w.kind == "npc" then
				trace:mark({ kind = "leave", at = endAt, subject = w.id, text = "session" })
			end
		end

		for i, w in writers do
			simulate(i, w)
		end
		return trace, writers
	end

	-- Assertions ---------------------------------------------------------------------------------------------

	local function firedNames(result)
		local names = {}
		for _, tell in result.tells do
			if tell.fired then
				table.insert(names, tell.name)
			end
		end
		return names
	end

	local function describeFired(result)
		local parts = {}
		for _, name in firedNames(result) do
			table.insert(parts, `{name}={result.byName[name].value}`)
		end
		return table.concat(parts, " ")
	end

	local function onlyFired(result, name)
		local tell = result.byName[name]
		T.check(tell ~= nil, `{name} exists`)
		T.check(tell.evaluated, `{name} evaluated`)
		T.check(tell.fired, `{name} fired (value {tostring(tell.value)})`)
		local others = {}
		for _, fired in firedNames(result) do
			if fired ~= name then
				table.insert(others, `{fired}={result.byName[fired].value}`)
			end
		end
		T.check(#others == 0, `only {name} fires, also: {table.concat(others, " ")}`)
		T.near(result.score, tell.score, 1e-9, "score is the fired tell's score")
		T.equal(tell.severity, TellScore.SEVERITY[tell.class])
		return tell
	end

	T.describe("Trace", function()
		T.it("keeps samples in order, groups by agent and drops the oldest past maxSamples", function()
			local trace = Trace.new({ maxSamples = 5 })
			T.equal(trace.hz, 10, "10 Hz default")
			T.equal(Trace.new().maxSamples, 200000)
			for i = 1, 7 do
				trace:push({
					id = if i % 2 == 0 then "p:1" else "n:npc1",
					kind = if i % 2 == 0 then "player" else "npc",
					at = i * 0.1,
					position = Vector3.new(i, 0, 0),
					velocity = Vector3.zero,
					yaw = 0,
					onGround = true,
					jumped = false,
					said = false,
					typing = false,
					emote = false,
				})
			end
			T.equal(trace:size(), 5)
			T.equal(trace.dropped, 2)
			local list = trace:list()
			T.equal(#list, 5)
			T.near(list[1].at, 0.3, 1e-9, "the two oldest are gone")
			T.near(list[5].at, 0.7, 1e-9)
			local byAgent = trace:byAgent()
			T.equal(#byAgent["n:npc1"], 3)
			T.equal(#byAgent["p:1"], 2)
			T.near(byAgent["n:npc1"][1].at, 0.3, 1e-9)
			local kinds = trace:kinds()
			T.equal(kinds["n:npc1"], "npc")
			T.equal(kinds["p:1"], "player")
			T.equal(table.concat(trace:agentIds(), ","), "n:npc1,p:1")
			local first, last = trace:span()
			T.near(first, 0.3, 1e-9)
			T.near(last, 0.7, 1e-9)
			trace:mark({ kind = "reset", at = 1, subject = "n:npc1" })
			T.equal(#trace:marks(), 1)
			T.equal(Trace.new():size(), 0)
			local none, none2 = Trace.new():span()
			T.equal(none, nil)
			T.equal(none2, nil)
		end)

		T.it("round-trips through toData / fromData and JSON", function()
			local trace = Trace.new({ hz = 20, maxSamples = 100 })
			trace:push({
				id = "n:npc1",
				kind = "npc",
				at = 0.5,
				position = Vector3.new(1.5, 2, -3),
				velocity = Vector3.new(0, 0, 4),
				yaw = 0.7,
				onGround = false,
				jumped = true,
				said = true,
				typing = false,
				emote = true,
				intent = "goto",
				tier = "near",
				profile = "mobile",
				pushing = true,
				afkFull = false,
				replyTo = "p:9",
				walkSpeed = 18,
				jumpTier = "spammer",
				text = "hi",
				events = { "arrived" },
			})
			local cf = CFrame.new(3, 4, 5) * CFrame.Angles(0, 0.6, 0)
			trace:mark({ kind = "avoidBox", at = 0, cframe = cf, size = Vector3.new(10, 4, 6) })
			trace:mark({
				kind = "identity",
				at = 0,
				subject = "n:npc1",
				text = "coolgamer2013",
				family = "digits",
				avatar = "a",
			})
			local back = Trace.fromData(trace:toData())
			T.equal(back.hz, 20)
			T.equal(back:size(), 1)
			local s = back:list()[1]
			T.equal(s.id, "n:npc1")
			T.near(s.position.X, 1.5, 1e-9)
			T.near(s.velocity.Z, 4, 1e-9)
			T.equal(s.onGround, false)
			T.equal(s.jumped, true)
			T.equal(s.pushing, true)
			T.equal(s.afkFull, false)
			T.equal(s.replyTo, "p:9")
			T.equal(s.walkSpeed, 18)
			T.equal(s.events[1], "arrived")
			local marks = back:marks()
			T.equal(#marks, 2)
			T.near((marks[1].cframe.Position - cf.Position).Magnitude, 0, 1e-6)
			T.near((marks[1].cframe.LookVector - cf.LookVector).Magnitude, 0, 1e-6)
			T.equal(marks[1].size.Z, 6)
			T.equal(marks[2].family, "digits")

			local viaJson = Harness.decode(session, Harness.encode(trace))
			T.equal(viaJson:size(), 1)
			T.equal(viaJson:list()[1].text, "hi")
			T.equal(viaJson:list()[1].intent, "goto")
			T.equal(viaJson:list()[1].tier, "near")
			T.near(viaJson:marks()[1].cframe.Position.X, 3, 1e-6)
			T.equal(Trace.fromData({ version = 1 }):size(), 0, "a bare table is an empty trace")
		end)
	end)

	T.describe("TellScore", function()
		T.it("score of an empty trace", function()
			local result = TellScore.score(Trace.new())
			T.equal(result.score, 0)
			T.equal(#result.tells, #TellScore.TELLS)
			T.equal(#result.tells, 29, "every tell of §9.4")
			for _, tell in result.tells do
				T.equal(tell.evaluated, false, `{tell.name} not evaluated`)
				T.equal(tell.fired, false)
				T.equal(tell.score, 0)
				T.equal(#tell.agents, 0)
			end
			T.equal(result.npcCount, 0)
			T.equal(result.seconds, 0)
			T.equal(result.reference, "builtin")
			T.check(string.find(Harness.format(result), "tell score 0") ~= nil, "formats")
		end)

		T.it("reference loading", function()
			for _, name in MotionStats.FEATURES do
				local hist = TellScore.REFERENCE[name]
				T.equal(#hist, MotionStats.BINS, `{name} has 24 bins`)
				local total = 0
				for _, c in hist do
					total += c
				end
				T.equal(total, TellScore.REFERENCE_TOTAL, `{name} histogram holds the whole mass`)
			end
			T.equal(TellScore.REFERENCE.sayRate, nil, "a row with q25 = 0 has no fit")
			-- a Stats filled from the histogram lands near the human median
			local fromHist = MotionStats.new()
			fromHist:fillFromHistogram("stopDuration", TellScore.REFERENCE.stopDuration)
			T.near(fromHist:quantile("stopDuration", 0.5), 2.4, 1.2, "median from bin centres")
			T.equal(#fromHist:values("stopDuration"), 256)
			-- the fitted quantiles reproduce the table (the median exactly; the quartiles as well as one
			-- log-normal can hold both sides of an asymmetric IQR)
			T.near(TellScore.referenceQuantile("speedRatio", 0.5), 0.86, 1e-6)
			T.near(TellScore.referenceQuantile("speedRatio", 0.25), 0.72, 0.03)
			T.near(TellScore.referenceQuantile("speedRatio", 0.75), 0.97, 0.03)
			T.equal(TellScore.referenceQuantile("speedRatio", 0.9), 1, "capped at full speed")
			T.near(TellScore.referenceQuantile("stopDuration", 0.5), 2.4, 1e-6)
			T.near(TellScore.referenceQuantile("stopDuration", 0.75), 9, 0.5)
			T.near(TellScore.referenceQuantile("turnRate", 0.25), 12, 3)
			T.near(TellScore.referenceQuantile("turnRate", 0.5), 48, 1e-6)
			T.equal(TellScore.referenceQuantile("sayRate", 0.5), nil)
			T.near(TellScore.normalQuantile(0.5), 0, 1e-9)
			T.near(TellScore.normalQuantile(0.75), 0.6744897, 1e-6)
			T.near(TellScore.normalQuantile(0.975), 1.959964, 1e-6)
			T.near(TellScore.normalQuantile(0.01), -2.326348, 1e-6)
			T.near(TellScore.normalCdf(1.959964), 0.975, 1e-6)
			T.near(TellScore.normalCdf(-0.6744897), 0.25, 1e-6)
			local stats = TellScore.referenceStats()
			T.equal(#stats:values("speedRatio"), TellScore.REFERENCE_SAMPLES)
			T.near(stats:quantile("speedRatio", 0.5), 0.86, 0.01)
			T.near(stats:quantile("turnRate", 0.5), 48, 0.5)
			T.check(TellScore.referenceStats() == stats, "cached")
			T.equal(#TellScore.TELLS, 29)
			for _, def in TellScore.TELLS do
				T.check(TellScore.SEVERITY[def.class] ~= nil, `{def.name} has a class`)
			end
		end)

		T.it("KS of a sample against itself < 0.1", function()
			local values = TellScore.referenceStats():values("speedRatio")
			T.equal(TellScore.ksAgainstReference("speedRatio", values), 0, "the reference against itself")
			local rng = Rng.new("ks-self")
			local drawn = {}
			for _ = 1, 3000 do
				table.insert(drawn, math.min(1, rng:logNormal(0.86, SPEED_SIGMA)))
			end
			local ks = TellScore.ksAgainstReference("speedRatio", drawn)
			T.check(ks < 0.1, `a sample of the fitted distribution: {ks}`)
			local stops = {}
			for _ = 1, 3000 do
				table.insert(stops, rng:logNormal(2.4, STOP_SIGMA))
			end
			T.check(TellScore.ksAgainstReference("stopDuration", stops) < 0.1, "stop durations too")
			local shifted = {}
			for _, v in drawn do
				table.insert(shifted, v * 0.5)
			end
			T.check(TellScore.ksAgainstReference("speedRatio", shifted) > 0.5, "a x0.5 shift is far")
			T.equal(TellScore.ksAgainstReference("speedRatio", {}), 0, "no values is no evidence")
		end)

		T.it("insideBox is an oriented test and familyOf groups template names", function()
			local box = {
				cframe = CFrame.new(10, 0, 10) * CFrame.Angles(0, math.rad(45), 0),
				size = Vector3.new(4, 4, 20),
			}
			T.check(TellScore.insideBox(Vector3.new(10, 0, 10), box), "centre")
			local along = box.cframe.LookVector * 9
			T.check(TellScore.insideBox(Vector3.new(10, 0, 10) + along, box), "along the long axis")
			local across = box.cframe.RightVector * 3
			T.check(not TellScore.insideBox(Vector3.new(10, 0, 10) + across, box), "past the short axis")
			T.check(not TellScore.insideBox(Vector3.new(10, 3, 10), box), "above")
			T.check(
				not TellScore.insideBox(Vector3.new(19, 0, 10), box),
				"an axis-aligned corner the rotation excludes"
			)
			T.equal(TellScore.familyOf("Bot1"), TellScore.familyOf("Bot8"))
			T.equal(TellScore.familyOf("Player_02"), TellScore.familyOf("Player_07"))
			T.equal(TellScore.familyOf("coolgamer2013"), "digits")
			T.equal(TellScore.familyOf("ShadowFoxKing"), "camel")
			T.equal(TellScore.familyOf("notmilo"), "prefixed")
			T.equal(TellScore.familyOf("bananacat"), "lower")
			T.equal(TellScore.familyOf("xXDragonSlayerXx"), "xx")
			T.equal(TellScore.familyOf("sh4dow_kid"), "leet")
		end)

		T.it("a human-like synthetic population fires no tell", function()
			local trace = human({ seed = "clean" })
			local result = TellScore.score(trace)
			T.equal(describeFired(result), "", "no tell fired")
			T.equal(result.score, 0)
			T.equal(result.npcCount, 4)
			T.equal(result.playerCount, 0)
			-- the statistics a 2-minute trace can evaluate are there and human
			local p = result.population
			T.equal(p.teleportCount, 0)
			T.equal(p.avoidEntry, 0)
			T.equal(p.wallContact, 0)
			T.check(p.speedRatioIqr ~= nil and p.speedRatioIqr > 0.04, `speed IQR {p.speedRatioIqr}`)
			T.check(p.pathStraightness ~= nil and p.pathStraightness > 1.03, `straightness {p.pathStraightness}`)
			T.check(p.cornerCut ~= nil and p.cornerCut > 0.15, `corner cut {p.cornerCut}`)
			T.check(p.turnRateQ90 ~= nil and p.turnRateQ90 < 400, `turn q90 {p.turnRateQ90}`)
			T.check(p.idleShare ~= nil and p.idleShare > 0.15, `idle share {p.idleShare}`)
			T.check(p.abandonShare ~= nil and p.abandonShare > 0.02, `abandon share {p.abandonShare}`)
			T.check(p.syncIndex ~= nil and p.syncIndex <= 0.05, `sync {p.syncIndex}`)
			T.check(p.ksSpeed ~= nil and p.ksSpeed <= 0.25, `ks speed {p.ksSpeed}`)
			T.equal(p.ksStops, nil, "two minutes hold fewer than 100 stops: no KS verdict on them")
			T.check(p.ksTurn ~= nil and p.ksTurn <= 0.3, `ks turn {p.ksTurn}`)
			T.equal(p.idleTurnShare, 0, "nobody fidgets")
			T.equal(p.noJumps, nil, "no NPC spans 10 minutes")
			T.equal(p.reactionLatencyQ10, nil, "no probes")
			T.equal(p.replyLatencyQ10, nil, "no player lines")
			T.equal(p.nameFamilyEntropy, nil, "fewer than 6 identities")
			T.equal(p.sessionCv, nil, "nobody left")
			T.equal(p.avatarDistinct, 1)
			T.equal(p.chatRepeat, 0)
			T.equal(p.silentServerRate, nil, "the quiet window needs 10 minutes")
			T.equal(result.reference, "builtin")
			T.equal(result.referenceByFeature.speedRatio, "builtin")
			local f = result.features["n:npc2"]
			T.check(f.speedRatio > 0.5 and f.speedRatio < 1, "mobile speed ratio")
			T.check(f.idleShare > 0, "per-agent idle share")
			T.check(f.microStopRate ~= nil, "thumb lifts are measured")
			T.equal(f.teleportCount, 0)
			T.equal(f.avoidEntry, 0)
			T.check(f.jumps > 0)
			T.equal(result.features["n:npc1"].camSweep ~= nil, true, "shift-lock sweeps are measured")
			T.equal(result.features["n:npc2"].camSweep, nil, "not for thumbsticks")
			T.equal(result.agents["n:npc1"].profile, "pcShiftLock")
			T.equal(#result.agents["n:npc1"].fired, 0)
			T.check(result.agents["n:npc1"].jumps > 0)
			local text = Harness.format(result)
			T.check(string.find(text, "T%-teleport") ~= nil, "table lists every tell")
			T.check(string.find(text, "n:npc4") ~= nil, "table lists the agents")
			T.check(
				string.find(Harness.format(result, { all = false, agents = false }), "T%-teleport") == nil,
				"filtered"
			)
		end)

		T.it("a long human-like run keeps heavy-tailed timers and is deterministic", function()
			local trace = human({ seed = "long", seconds = 450 })
			local result = TellScore.score(trace)
			T.equal(describeFired(result), "")
			local p = result.population
			T.check(p.timerCv ~= nil and p.timerCv > 0.3, `timer cv {p.timerCv}`)
			T.check(p.ksStops ~= nil and p.ksStops <= 0.25, `ks stops {p.ksStops}`)
			T.check(p.noJumps == nil or p.noJumps == 0, "jumpers jumped")
			T.equal(p.silentServerRate, nil, "the quiet window opens at 600 s")
			local again = TellScore.score(human({ seed = "long", seconds = 450 }))
			T.equal(again.score, result.score)
			for id, f in result.features do
				for k, v in f do
					T.equal(again.features[id][k], v, `{id}.{k}`)
				end
			end
			for k, v in p do
				T.equal(again.population[k], v, k)
			end
			local viaJson = TellScore.score(Harness.decode(session, Harness.encode(trace)))
			T.near(viaJson.score, result.score, 1e-9, "scored the same after a JSON round trip")
			T.equal(viaJson.population.ksStops, p.ksStops)
		end)

		T.it("players in the trace become the reference when they hold enough values", function()
			local trace = human({ seed = "players", seconds = 150, players = 3 })
			local result = TellScore.score(trace)
			T.equal(result.playerCount, 3)
			T.equal(result.reference, "players")
			T.equal(result.referenceByFeature.speedRatio, "players")
			T.equal(result.referenceByFeature.turnRate, "players")
			T.equal(describeFired(result), "", "NPCs shaped like the players score clean")
			local builtin = TellScore.score(trace, { reference = "builtin" })
			T.equal(builtin.reference, "builtin")
			T.check(builtin.population.ksSpeed ~= result.population.ksSpeed, "a different comparison")
			T.equal(result.agents["p:1"].kind, "player")
			T.equal(result.features["p:1"].teleportCount, 0)
		end)

		T.describe("each tell fires on its synthetic trace", function()
			T.it("T-teleport", function()
				local trace = human({
					seed = "teleport",
					hook = function(s, _, i)
						if i == 1 and s.at >= 30 then
							s.position += Vector3.new(50, 0, 0)
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-teleport")
				T.equal(tell.value, 1)
				T.equal(tell.score, 8)
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				T.equal(result.agents["n:npc1"].teleports, 1)
				T.equal(result.agents["n:npc1"].fired[1], "T-teleport")
			end)

			T.it("a reset mark exempts the jump after it", function()
				local trace = human({
					seed = "teleport",
					extraMarks = { { kind = "reset", at = 29.95, subject = "n:npc1" } },
					hook = function(s, _, i)
						if i == 1 and s.at >= 30 then
							s.position += Vector3.new(50, 0, 0)
						end
					end,
				})
				local result = TellScore.score(trace)
				T.equal(result.byName["T-teleport"].fired, false)
				T.equal(result.population.teleportCount, 0)
			end)

			T.it("T-avoidEntry", function()
				local probe = human({ seed = "avoid" })
				local anchor = nil
				for _, s in probe:byAgent()["n:npc1"] do
					if s.at >= 25 then
						anchor = s.position
						break
					end
				end
				local box = { cframe = CFrame.new(anchor.X, 5, anchor.Z), size = Vector3.new(10, 10, 10) }
				local trace = human({ seed = "avoid", avoidBox = box })
				local expected = 0
				for _, s in trace:list() do
					if math.abs(s.position.X - anchor.X) <= 5 and math.abs(s.position.Z - anchor.Z) <= 5 then
						expected += 1
					end
				end
				T.check(expected > 0, "some samples fall inside the box")
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-avoidEntry")
				T.equal(tell.value, expected)
				T.equal(tell.score, 8)
				T.check(table.find(tell.agents, "n:npc1") ~= nil)
				-- Options.avoidBoxes overrides the marks
				local none = TellScore.score(trace, { avoidBoxes = {} })
				T.equal(none.byName["T-avoidEntry"].evaluated, false)
				local explicit = TellScore.score(human({ seed = "avoid", marks = false }), { avoidBoxes = { box } })
				T.equal(explicit.population.avoidEntry, expected)
			end)

			T.it("T-wallContact", function()
				local trace = human({
					seed = "wall",
					hook = function(s, writer, i)
						if i == 1 and s.velocity.Magnitude >= 0.5 and writer.movingIndex % 10 == 0 then
							s.pushing = true
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-wallContact")
				T.between(tell.value, 0.099, 0.101)
				T.near(tell.score, 8, 0.1, "10% is a full critical")
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				T.near(result.features["n:npc1"].wallContact, tell.value, 1e-12)
				T.equal(result.features["n:npc2"].wallContact, 0)
			end)

			T.it("T-constantSpeed", function()
				local analog = { "mobile", "mobile", "console", "mobile" }
				local trace = human({ seed = "constant", profiles = analog, constantSpeedFor = 2 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-constantSpeed")
				T.near(tell.value, 0, 1e-6, "IQR 0")
				T.near(tell.score, 3, 1e-6)
				T.equal(table.concat(tell.agents, ","), "n:npc2")
				T.near(result.features["n:npc2"].speedRatio, 1, 1e-6)
				-- a pc profile at constant speed is exempt: Roblox keyboard input is binary
				local pc =
					TellScore.score(human({ seed = "constant", profiles = { "pc", "mobile", "mobile", "mobile" } }))
				T.equal(pc.byName["T-constantSpeed"].fired, false)
				T.near(pc.features["n:npc1"].speedRatioIqr, 0, 1e-6)
			end)

			T.it("T-perfectStop", function()
				local probe = human({ seed = "stops" })
				local marks = {}
				for _, samples in probe:byAgent() do
					local wasMoving = true
					for k, s in samples do
						local moving = s.velocity.Magnitude >= 0.5
						if wasMoving and not moving then
							table.insert(marks, { kind = "poi", at = 0, subject = `stop{k}`, source = s.position })
						end
						wasMoving = moving
					end
				end
				local trace = human({ seed = "stops", extraMarks = marks })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-perfectStop")
				T.near(tell.value, 0, 1e-9)
				T.equal(tell.score, 3)
				T.check(#tell.agents >= 3, "the agents with three measured stops")
				-- Options.pois overrides the marks
				local far = TellScore.score(trace, { pois = { Vector3.new(500, 0, 500) } })
				T.equal(far.byName["T-perfectStop"].evaluated, false)
			end)

			T.it("T-noJumps", function()
				local spoke = { { kind = "playerLine", at = 300, subject = "p:1", text = "anyone trading" } }
				local trace =
					human({ seed = "nojump", seconds = 620, jumpTier = "spammer", noJumps = true, extraMarks = spoke })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-noJumps")
				T.equal(tell.value, 4)
				T.equal(tell.score, 1)
				T.equal(table.concat(tell.agents, ","), "n:npc1,n:npc2,n:npc3,n:npc4")
				local never = TellScore.score(human({
					seed = "nojump",
					npcs = 1,
					seconds = 620,
					jumpTier = "never",
					noJumps = true,
					extraMarks = spoke,
				}))
				T.equal(never.byName["T-noJumps"].fired, false, "a never-jumper is allowed not to jump")
				T.equal(never.population.noJumps, 0)
			end)

			T.it("T-instantReaction", function()
				local marks = {}
				for k = 1, 10 do
					table.insert(marks, {
						kind = "probe",
						at = 5 + k * 7,
						subject = "n:npc1",
						source = Vector3.new(100, 0, 0),
						text = "follow",
					})
				end
				local trace = human({
					seed = "react",
					intent = "wander",
					extraMarks = marks,
					hook = function(s, _, i)
						if i == 1 then
							for _, m in marks do
								if s.at > m.at + 0.05 and s.at < m.at + 0.15 then
									s.intent = "react"
								end
							end
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-instantReaction")
				T.near(tell.value, 0.1, 1e-6, "q10 0.1")
				T.equal(tell.score, 3)
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				T.equal(result.population.noReactionShare, 0)
				T.near(result.features["n:npc1"].reactionLatency, 0.1, 1e-6)
			end)

			T.it("T-noReaction", function()
				local marks = {}
				for k = 1, 10 do
					table.insert(marks, { kind = "probe", at = 5 + k * 7, subject = "n:npc1" })
				end
				local trace = human({
					seed = "ignore",
					intent = "wander",
					extraMarks = marks,
					hook = function(s, _, i)
						if i == 1 then
							for k, m in marks do
								if k <= 6 and s.at > m.at + 0.95 and s.at < m.at + 1.05 then
									s.intent = "react"
								end
							end
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-noReaction")
				T.near(tell.value, 0.4, 1e-9, "4 of 10 unanswered")
				T.equal(tell.score, 3)
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				T.near(result.population.reactionLatencyQ10, 1, 1e-6, "the answered ones took 1 s")
			end)

			T.it("a body turn that ends up facing the source is a reaction", function()
				local source = Vector3.new(0, 0, 0)
				local marks = {}
				for k = 0, 3 do
					table.insert(marks, { kind = "probe", at = 40 + k * 0.01, subject = "n:npc1", source = source })
				end
				local trace = human({
					seed = "turn",
					intent = "wander",
					extraMarks = marks,
					hook = function(s, writer, i)
						if i ~= 1 then
							return
						end
						local toSource = yawOf(source - s.position)
						if s.at > 39.55 and s.at < 40.55 then
							writer.yaw = toSource + math.pi -- looking away when probed
							s.yaw = writer.yaw
						elseif s.at > 40.55 and s.at < 40.65 then
							writer.yaw = toSource
							s.yaw = toSource
						end
					end,
				})
				local result = TellScore.score(trace)
				T.near(result.features["n:npc1"].reactionLatency, 0.6, 0.11)
				T.equal(result.population.noReactionShare, 0)
			end)

			T.it("T-fastReply", function()
				local marks = {}
				local texts = { "hey", "hi", "yo", "sup", "hello" }
				for k = 1, 5 do
					table.insert(marks, { kind = "playerLine", at = 4 + k * 15, subject = "p:1", text = "trade?" })
				end
				local trace = human({
					seed = "reply",
					extraMarks = marks,
					hook = function(s, _, i)
						if i == 2 then
							for k, m in marks do
								if s.at > m.at + 0.75 and s.at < m.at + 0.85 then
									s.said = true
									s.text = texts[k]
									s.replyTo = "p:1"
								end
							end
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-fastReply")
				T.near(tell.value, 0.8, 1e-6)
				T.equal(tell.score, 3)
				T.equal(table.concat(tell.agents, ","), "n:npc2")
				T.near(result.features["n:npc2"].replyLatency, 0.8, 1e-6)
			end)

			T.it("T-metronome", function()
				local trace = human({
					seed = "metronome",
					seconds = 150,
					noJumpsFor = 1,
					hook = function(s, _, i)
						if i == 1 then
							local phase = s.at % 12
							if phase < 0.05 or phase > 11.95 then
								s.jumped = true
							end
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-metronome")
				T.near(tell.value, 0, 1e-6, "CV 0")
				T.near(tell.score, 3, 1e-6)
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				T.near(result.features["n:npc1"].jumpGap, 12, 1e-6)
				T.check(result.agents["n:npc1"].jumps >= 12)
			end)

			T.it("T-statueIdle", function()
				local long = { every = 3, seconds = 30 }
				local trace = human({ seed = "statue", seconds = 240, noSweep = true, longStops = long })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-statueIdle")
				T.equal(tell.value, 1, "every long stop of the shift-lock agent is a statue")
				T.equal(tell.score, 1)
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				local sweeping = TellScore.score(human({ seed = "statue", seconds = 240, longStops = long }))
				T.equal(sweeping.byName["T-statueIdle"].fired, false, "a camera sweep during the stop is human")
				T.equal(sweeping.population.statueShare, 0)
			end)

			T.it("T-fidgetIdle", function()
				local profiles = { "pc", "mobile", "mobile", "console" }
				local trace = human({ seed = "fidget", profiles = profiles, idleTurnEvery = 5 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-fidgetIdle")
				T.near(tell.value, 0.2, 1e-6, "one interval in five turns")
				T.near(tell.score, 1, 1e-6)
				T.equal(#tell.agents, 4)
			end)

			T.it("T-straightLines", function()
				local trace = human({ seed = "straight", straightTrips = true })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-straightLines")
				T.between(tell.value, 1, 1.03)
				T.near(tell.score, (1.03 - tell.value) / 0.03, 1e-9)
				T.equal(#tell.agents, 4)
			end)

			T.it("T-noCornerCut", function()
				local trace = human({ seed = "sharp", sharpCorners = true })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-noCornerCut")
				T.near(tell.value, 0, 1e-6)
				T.near(tell.score, 1, 1e-6)
				T.equal(#tell.agents, 4)
			end)

			T.it("T-robotTurns", function()
				local trace = human({ seed = "zigzag", zigzag = 50 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-robotTurns")
				T.check(tell.value > 400 and tell.value < 700, `about 500 deg/s ({tell.value})`)
				T.near(tell.score, math.min(1, (tell.value - 400) / 400), 1e-9)
				T.check(#tell.agents >= 2, "the agents whose own q90 crosses")
			end)

			T.it("T-sync", function()
				local trace = human({ seed = "sync", sharedRhythm = true })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-sync")
				T.equal(tell.value, 1)
				T.equal(tell.score, 3)
				T.equal(#tell.agents, 4)
			end)

			T.it("T-uniformSessions", function()
				local bursts = { 0, 0.5, 1, 40, 41, 80, 81, 95 }
				local trace = human({
					seed = "sessions",
					npcs = 8,
					arrivals = function(i)
						return bursts[i]
					end,
					sessionSeconds = 300,
					extraMarks = { { kind = "playerLine", at = 200, subject = "p:1", text = "anyone trading" } },
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-uniformSessions")
				T.near(tell.value, 0, 1e-9)
				T.equal(tell.score, 1)
				T.check(result.population.arrivalClustering > 0.6, "bursty arrivals are human")
				T.equal(result.npcCount, 8)
			end)

			T.it("T-uniformArrivals", function()
				local trace = human({
					seed = "arrivals",
					npcs = 8,
					arrivals = function(i)
						return (i - 1) * 30
					end,
					sessionSeconds = function(_, rng)
						return rng:logNormalClamped(90, 0.9, 30, 300)
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-uniformArrivals")
				T.near(tell.value, 0, 1e-9)
				T.equal(tell.score, 1)
				T.check(result.population.sessionCv > 0.5, `varied sessions are human ({result.population.sessionCv})`)
			end)

			T.it("T-nameTemplate", function()
				local names = {}
				for i = 1, 8 do
					names[i] = `Bot{i}`
				end
				local trace = human({ seed = "names", npcs = 8, names = names })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-nameTemplate")
				T.equal(tell.value, 0)
				T.equal(tell.score, 3)
				local varied = TellScore.score(human({ seed = "names", npcs = 8 }))
				T.near(varied.population.nameFamilyEntropy, 3, 1e-9, "eight families")
			end)

			T.it("T-cloneAvatars", function()
				local trace = human({ seed = "clones", npcs = 8, cloneAvatars = true })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-cloneAvatars")
				T.near(tell.value, 0.125, 1e-9)
				T.equal(tell.score, 1)
			end)

			T.it("T-chatFlood", function()
				local gaps = Rng.new("flood")
				local times, at = {}, 10
				for k = 1, 12 do
					at += gaps:logNormalClamped(3, 0.9, 0.5, 8)
					times[k] = at
				end
				local trace = human({
					seed = "flood",
					lines = false,
					hook = function(s, _, i)
						if i == 2 then
							for k, t in times do
								if s.at >= t and s.at < t + DT then
									s.said = true
									s.text = `flood {k}`
								end
							end
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-chatFlood")
				T.equal(tell.value, 12)
				T.equal(tell.score, 3)
				T.equal(table.concat(tell.agents, ","), "n:npc2")
			end)

			T.it("T-chatRepeat", function()
				local trace = human({
					seed = "repeat",
					hook = function(s, _, i)
						if i == 2 and ((s.at >= 20 and s.at < 20 + DT) or (s.at >= 50 and s.at < 50 + DT)) then
							s.said = true
							s.text = "lol"
						end
					end,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-chatRepeat")
				T.equal(tell.value, 1)
				T.equal(tell.score, 3)
				T.equal(table.concat(tell.agents, ","), "n:npc2")
			end)

			T.it("T-walkTalk", function()
				local profiles = { "pc", "mobile", "mobile", "mobile" }
				local trace = human({
					seed = "walktalk",
					profiles = profiles,
					lines = false,
					talkWhileWalking = 1,
					lineGapMedian = 12,
				})
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-walkTalk")
				T.equal(tell.value, 0)
				T.equal(tell.score, 1)
				T.equal(table.concat(tell.agents, ","), "n:npc1")
				T.check(result.agents["n:npc1"].lines >= 3)
			end)

			T.it("T-silentServerChat", function()
				local trace = human({ seed = "silent", npcs = 2, seconds = 900, lineGapMedian = 21, lineSigma = 0.45 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-silentServerChat")
				T.check(tell.value > 2 and tell.value < 6, `about three lines a minute ({tell.value})`)
				T.near(tell.score, math.min(1, (tell.value - 2) / 2), 1e-9)
				T.equal(#tell.agents, 2)
				-- one player line inside the window resets the silence
				local spoken = TellScore.score(human({
					seed = "silent",
					npcs = 2,
					seconds = 900,
					lineGapMedian = 21,
					lineSigma = 0.45,
					extraMarks = { { kind = "playerLine", at = 590, subject = "p:1", text = "hi" } },
				}))
				T.equal(spoken.population.silentServerRate, nil, "10 minutes of silence never completes")
			end)

			T.it("T-alwaysComplete", function()
				local trace = human({ seed = "complete", changedMindEvery = 0 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-alwaysComplete")
				T.equal(tell.value, 0)
				T.equal(tell.score, 0.25)
			end)

			T.it("T-neverIdle", function()
				local trace = human({ seed = "restless", seconds = 200, goMedian = 150 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-neverIdle")
				T.check(tell.value < 0.15, `idle share {tell.value}`)
				T.near(tell.score, math.min(1, (0.15 - tell.value) / 0.1), 1e-9)
				T.check(#tell.agents >= 3, "the agents whose own share crosses")
			end)

			T.it("T-ksSpeed", function()
				local trace = human({ seed = "slow", speedScale = 0.5 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-ksSpeed")
				T.check(tell.value > 0.25)
				T.near(tell.score, math.min(1, (tell.value - 0.25) / 0.25), 1e-9)
			end)

			T.it("T-ksStops", function()
				local trace = human({ seed = "shortstops", seconds = 300, stopMedian = 0.3 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-ksStops")
				T.check(tell.value > 0.25)
				T.near(tell.score, math.min(1, (tell.value - 0.25) / 0.25), 1e-9)
			end)

			T.it("T-ksTurn", function()
				local trace = human({ seed = "stiff", turnScale = 1 / 8 })
				local result = TellScore.score(trace)
				local tell = onlyFired(result, "T-ksTurn")
				T.check(tell.value > 0.3)
				T.near(tell.score, 0.25 * math.min(1, (tell.value - 0.3) / 0.3), 1e-9)
			end)
		end)
	end)

	T.describe("Harness", function()
		T.it("prints usage without a trace and formats a result", function()
			T.equal(Harness.main({}), 2)
			T.equal(Harness.main({ "--budget", "1" }), 2)
			local result = Harness.score(session, human({ seed = "harness", seconds = 30 }))
			local text = Harness.format(result)
			T.check(string.find(text, "tell score") ~= nil)
			T.check(string.find(text, "threshold") ~= nil)
			T.check(string.find(text, "n:npc1") ~= nil)
			T.check(#string.split(text, "\n") > 29 + 4, "one row per tell and per agent")
		end)
	end)
end

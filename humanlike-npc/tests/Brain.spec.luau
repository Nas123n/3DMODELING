-- Brain: random abandonment (rare, once per trip, never early or near the goal), the changedMind
-- flag, the about-face variant, the far tier (no talk, no emotes, trip-shaped activities only)
-- and the session-level system events. Everything runs on a scripted locomotion: the NPC never
-- moves; a trip is "walking" for a fixed number of seconds and then reports arrival.

return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local Personality = session.require(S.Mind.Personality)
	local Brain = session.require(S.Mind.Brain)
	local Activities = session.require(S.Mind.Activities)
	local Recency = session.require(S.Chat.Recency)
	local Safety = session.require(S.Chat.Safety)

	local ORIGIN = Vector3.new(0, 0, 0)
	local HEADING = Vector3.new(0, 0, -1)
	local DT = 0.5 -- 2 Hz brain rate

	local function flatDistance(a, b)
		local dx, dz = a.X - b.X, a.Z - b.Z
		return math.sqrt(dx * dx + dz * dz)
	end

	-- A ring of places around the origin, all reachable, none ever visited before.
	local function ringOfPois(count, radius, kind, weight)
		local pois = {}
		for i = 1, count do
			local a = (i - 1) / count * 2 * math.pi
			pois[i] = {
				id = "poi" .. i,
				kind = kind,
				position = Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius),
				weight = weight,
				radius = 6,
				dwellMedian = 2,
			}
		end
		return pois
	end

	local function makeWorld(opts)
		local o = opts or {}
		return {
			pois = o.pois or {},
			poiOccupants = function()
				return 0
			end,
			entities = o.entities or {},
			visible = o.visible or {},
			groups = o.groups or {},
			spawnPoint = o.spawnPoint or ORIGIN,
			reachable = function()
				return true
			end,
			randomReachable = o.randomReachable or function()
				return nil
			end,
			sectorCenter = function()
				return nil
			end,
			nearbySectors = function()
				return {}
			end,
			totalSectors = 0,
			isAvoided = function()
				return false
			end,
			failedRecently = function()
				return false
			end,
			props = nil,
		}
	end

	local function makeChat()
		return {
			recency = Recency.new(),
			safety = Safety.new(),
			allow = function()
				return true
			end,
		}
	end

	local function makePersona(seed, overrides)
		local persona = Personality.sample(Rng.new(seed))
		persona.sessionLength = 1e7 -- never reaches "leaving" on its own during a test
		for k, v in overrides or {} do
			persona[k] = v
		end
		return persona
	end

	local function makeInput(now, world, chat, locomotion, extra)
		local e = extra or {}
		return {
			now = now,
			dt = e.dt or DT,
			me = {
				id = "npc1",
				position = e.position or ORIGIN,
				heading = HEADING,
				displayName = "Zed",
				username = "zed_walks",
			},
			locomotion = locomotion,
			world = world,
			entity = function(id)
				for _, entity in world.entities do
					if entity.id == id then
						return entity
					end
				end
				return nil
			end,
			groupOf = function()
				return nil
			end,
			events = e.events or {},
			playersWithin30 = e.playersWithin30 or 0,
			playersWithin100 = e.playersWithin100 or 0,
			chat = chat,
			fellNearby = false,
			tier = e.tier,
		}
	end

	-- Scripted locomotion: the first goto of an activity is a leg that walks for `legSeconds`
	-- and then arrives; later gotos of the same activity (hovers) arrive at once. Anything that
	-- is not a goto idles. `remaining` is what the brain is told about the trip.
	local function newLocomotion(legSeconds, remaining)
		local loco = { status = "idle", goal = nil, moving = false, onGround = true, remaining = remaining }
		local legStart, legIndex = 0, 0
		local function input()
			return {
				status = loco.status,
				goal = loco.goal,
				moving = loco.moving,
				onGround = true,
				blockedBy = nil,
				remaining = loco.remaining,
			}
		end
		local function newActivity()
			legIndex = 0
		end
		local function apply(intent, now)
			if intent.kind == "goto" then
				local p = intent.position
				if loco.goal == nil or flatDistance(loco.goal, p) >= 0.5 then
					legIndex += 1
					loco.goal = p
					legStart = now
					loco.status = "walking"
					loco.moving = legIndex == 1
				elseif loco.status == "walking" and (legIndex > 1 or now - legStart >= legSeconds) then
					loco.status = "arrived"
					loco.moving = false
				end
			else
				loco.status = "idle"
				loco.goal = nil
				loco.moving = false
			end
		end
		return { input = input, newActivity = newActivity, apply = apply }
	end

	-- Runs `tripCount` VisitPoi trips and returns per-trip changedMind counts plus what the
	-- abandonment steps looked like. Every place is heavy enough to dwarf idling, and a place
	-- that has been the target of a trip is retired under a fresh id, so no candidate ever
	-- carries a recency penalty and a periodic review can never out-score the running trip:
	-- the only way a trip is dropped is the random abandonment under test.
	local function runTrips(seed, impulsivity, tripCount, legSeconds, remaining)
		local persona = makePersona(seed, { impulsivity = impulsivity, patience = 1, afkProneness = 0, chattiness = 0 })
		local brain = Brain.new(Rng.new(seed + 1000), persona, 0)
		local world = makeWorld({ pois = ringOfPois(8, 30, "hangout", 10) })
		local chat = makeChat()
		local loco = newLocomotion(legSeconds, remaining)
		local perTrip = {}
		local aboutFaces, plain = 0, 0
		local currentKey = nil
		local now, steps = 0, 0
		local retired = 0
		local function retire(key)
			local target = if key then string.match(key, "^VisitPoi|(.+)$") else nil
			if not target then
				return
			end
			for _, poi in world.pois do
				if poi.id == target then
					retired += 1
					poi.id = "fresh" .. retired
				end
			end
		end
		while #perTrip < tripCount or currentKey ~= nil do
			if steps > 400000 then
				error("scripted trips did not finish")
			end
			now += DT
			steps += 1
			local out = brain:step(makeInput(now, world, chat, loco.input()))
			if out.changedMind then
				T.check(currentKey ~= nil and #perTrip > 0, "changedMind only while a trip is running")
				perTrip[#perTrip] += 1
				retire(currentKey)
				currentKey = nil
				if out.activity == nil then
					-- An about-face: a step straight back (a fidget jump may ride over it this step).
					aboutFaces += 1
					local intent = out.intent
					T.check(intent.kind == "step" or intent.kind == "jump", `about-face intent {intent.kind}`)
					if intent.kind == "step" then
						T.between(intent.duration, 0.4, 0.9, "about-face duration")
						T.check(intent.dir:Dot(HEADING) < -0.99, "about-face walks back")
					end
				else
					plain += 1
				end
			end
			local key = if out.activity then out.activity .. "|" .. tostring(out.target) else nil
			if key ~= currentKey then
				retire(currentKey)
				currentKey = key
				loco.newActivity()
				if out.activity == "VisitPoi" and #perTrip < tripCount then
					table.insert(perTrip, 0)
				elseif out.activity == "VisitPoi" then
					currentKey = nil -- past the quota: stop tracking
				end
			end
			loco.apply(out.intent, now)
			if #perTrip >= tripCount and currentKey == nil then
				break
			end
		end
		return { perTrip = perTrip, aboutFaces = aboutFaces, plain = plain, steps = steps, seconds = now }
	end

	local function total(list)
		local sum, most = 0, 0
		for _, n in list do
			sum += n
			most = math.max(most, n)
		end
		return sum, most
	end

	T.describe("Brain", function()
		T.it("abandonment is rare", function()
			-- 200 scripted 20-s trips at 2 Hz, remaining always >= 8 studs: 17 eligible seconds per
			-- trip, so the expected count is 200 * 17 * (0.002 + 0.006 * impulsivity).
			local impulsive = runTrips(11, 1, 200, 20, 100)
			local sum, most = total(impulsive.perTrip)
			T.equal(#impulsive.perTrip, 200, "trip count")
			T.between(sum, 14, 44, "impulsivity 1 (27.2 expected)")
			T.equal(most, 1, "no trip changes its mind twice")

			local calm = runTrips(12, 0, 200, 20, 100)
			local calmSum, calmMost = total(calm.perTrip)
			T.equal(#calm.perTrip, 200, "trip count")
			T.between(calmSum, 1, 16, "impulsivity 0 (6.8 expected)")
			T.check(calmMost <= 1, "no trip changes its mind twice")
			T.check(calmSum < sum, "impulsive people give up more often")
		end)

		T.it("half of the abandonments are an about-face step, the rest a plain reselection", function()
			local a = runTrips(21, 1, 200, 20, 100)
			local b = runTrips(22, 1, 200, 20, 100)
			local aboutFaces = a.aboutFaces + b.aboutFaces
			local plain = a.plain + b.plain
			T.check(aboutFaces + plain >= 20, "enough abandonments to judge the split")
			local share = aboutFaces / (aboutFaces + plain)
			T.between(share, 0.25, 0.75, "about-face share")
		end)

		T.it("never abandons in the first 3 s of a trip or with less than 8 studs remaining", function()
			-- Trips that arrive after 2.5 s never reach the eligible window.
			local short = runTrips(31, 1, 120, 2.5, 100)
			local shortSum = total(short.perTrip)
			T.equal(#short.perTrip, 120, "trip count")
			T.equal(shortSum, 0, "no abandonment inside the first 3 s")
			-- Long trips whose goal is always reported within 8 studs are never dropped either.
			local close = runTrips(32, 1, 100, 20, 7.9)
			local closeSum = total(close.perTrip)
			T.equal(#close.perTrip, 100, "trip count")
			T.equal(closeSum, 0, "no abandonment near the goal")
			-- With remaining unknown (nil) the rule does not block: the rate is the normal one.
			local unknown = runTrips(33, 1, 100, 20, nil)
			local unknownSum = total(unknown.perTrip)
			T.between(unknownSum, 4, 26, "impulsivity 1 over 100 trips (13.6 expected)")
		end)

		T.it("changedMind is set when a running trip is swapped out by a forced reselection", function()
			local persona = makePersona(41, { impulsivity = 0, patience = 1, afkProneness = 0, chattiness = 0 })
			local brain = Brain.new(Rng.new(1041), persona, 0)
			local world = makeWorld({ pois = ringOfPois(8, 30, "objective", 10) })
			local chat = makeChat()
			local loco = newLocomotion(1e6, 100)
			local now = 0
			local walkingSince = nil
			local flagged = false
			local changedMindSteps = 0
			for _ = 1, 400 do
				now += DT
				local out = brain:step(makeInput(now, world, chat, loco.input()))
				if out.changedMind then
					changedMindSteps += 1
					T.equal(out.phase, "leaving", "the swap happens on the step the session turns to leaving")
					T.check(walkingSince ~= nil and now - walkingSince >= 5, "the trip had been under way")
					T.check(out.activity ~= "VisitPoi", "the trip is gone")
					flagged = true
				end
				if out.activity == "VisitPoi" and loco.input().moving then
					walkingSince = walkingSince or now
					if now - walkingSince >= 5 and not flagged then
						brain:onSystemEvent("serverClosing", now)
					end
				end
				loco.apply(out.intent, now)
			end
			T.check(flagged, "a running trip was dropped")
			T.equal(changedMindSteps, 1, "flagged exactly once")
			T.equal(brain.session.phase, "leaving", "serverClosing leaves now")
		end)

		T.it("nameCollision shortens the session to 5..45 s without failing the activity", function()
			local lows, highs = 0, 0
			for seed = 1, 100 do
				local persona = makePersona(seed, { chattiness = 0 })
				local brain = Brain.new(Rng.new(seed + 500), persona, 100)
				local world = makeWorld({ pois = ringOfPois(4, 30, "objective", 10) })
				local chat = makeChat()
				local loco = newLocomotion(1e6, 100)
				local now = 100
				for _ = 1, 40 do
					now += DT
					local out = brain:step(makeInput(now, world, chat, loco.input()))
					loco.apply(out.intent, now)
				end
				local before = brain.session.leaveAt
				local activity = brain:describe().activity
				brain:onSystemEvent("nameCollision", now)
				local left = brain.session.leaveAt - now
				T.between(left, 5, 45, "leave within LNc(20, 0.4, 5, 45)")
				T.check(brain.session.leaveAt <= before, "only ever shortens")
				T.equal(brain:describe().activity, activity, "the running activity is untouched")
				T.check(brain.session.phase ~= "leaving", "not leaving yet")
				if left < 15 then
					lows += 1
				elseif left > 25 then
					highs += 1
				end
			end
			T.check(lows >= 5 and highs >= 5, `spread around the 20 s median (lows {lows}, highs {highs})`)
		end)

		-- A chatty, emotive persona with a player standing in front of it and a crowd around.
		local function socialRun(seed, tier, seconds)
			local persona = makePersona(seed, {
				chattiness = 1,
				emoteHabit = 1,
				mirroring = 1,
				sociability = 1,
				afkProneness = 0,
				impulsivity = 0.3,
			})
			local brain = Brain.new(Rng.new(seed + 2000), persona, 0)
			local player = {
				id = "p:1",
				kind = "player",
				position = Vector3.new(0, 0, -5),
				velocity = Vector3.zero,
				yaw = math.pi, -- facing the NPC
				displayName = "Zoe",
			}
			local world = makeWorld({
				pois = ringOfPois(6, 30, "hangout", 3),
				entities = { player },
				visible = { ["p:1"] = true },
				randomReachable = function(from, minDistance)
					return Vector3.new(from.X + minDistance + 5, 0, from.Z)
				end,
			})
			local chat = makeChat()
			local loco = newLocomotion(6, 100)
			local says, emotes, typing, forceLines = 0, 0, 0, 0
			local activities = {}
			local now = 0
			local steps = math.floor(seconds / DT)
			for i = 1, steps do
				now += DT
				local events = {}
				if i % 40 == 0 then
					table.insert(events, {
						kind = "chatHeard",
						salience = 0.25,
						subject = "p:1",
						at = now,
						data = { text = "hi Zed", position = player.position, distance = 5 },
					})
					table.insert(events, { kind = "entityEmoted", salience = 0.3, subject = "p:1", at = now })
				end
				local out = brain:step(makeInput(now, world, chat, loco.input(), {
					events = events,
					playersWithin30 = 2,
					playersWithin100 = 6,
					tier = tier,
				}))
				for _, a in out.actions do
					if a.kind == "say" then
						says += 1
					elseif a.kind == "emote" then
						emotes += 1
					elseif a.kind == "forceLine" then
						forceLines += 1
					end
				end
				if out.typing then
					typing += 1
				end
				if out.activity then
					activities[out.activity] = (activities[out.activity] or 0) + 1
				end
				loco.apply(out.intent, now)
			end
			return { says = says, emotes = emotes, typing = typing, forceLines = forceLines, activities = activities }
		end

		T.it("far tier never talks or emotes", function()
			local allowed = { VisitPoi = true, Wander = true, Explore = true, IdleStand = true, Leave = true }
			for _, tier in { "far", "dormant" } do
				for seed = 1, 3 do
					local r = socialRun(seed, tier, 600)
					T.equal(r.says, 0, `{tier}: say actions (seed {seed})`)
					T.equal(r.emotes, 0, `{tier}: emote actions (seed {seed})`)
					T.equal(r.forceLines, 0, `{tier}: forceLine actions leak (seed {seed})`)
					T.equal(r.typing, 0, `{tier}: typing (seed {seed})`)
					for name in r.activities do
						T.check(allowed[name], `{tier}: activity {name} is not allowed`)
					end
				end
			end
			-- The same set-up in the near tier does talk and emote, so the assertion above bites.
			local near = 0
			for seed = 1, 3 do
				local r = socialRun(seed, nil, 600)
				near += r.says + r.emotes
			end
			T.check(near > 0, "near tier talks or emotes with the same set-up")
		end)

		-- The plaza's places as the brain sees them from the south-west spawn area: one shop 28
		-- studs away, everything else 80 studs or more.
		local PLAZA_SPAWN = Vector3.new(-80, 0, -80)
		local function plazaPois()
			local list = {}
			local function poi(x, z, kind, weight, radius)
				table.insert(list, {
					id = `{kind}{#list + 1}`,
					kind = kind,
					position = Vector3.new(x, 0, z),
					weight = weight or 1,
					radius = radius or 6,
					dwellMedian = 2,
				})
			end
			poi(-60, -60, "shop", 2, 7)
			poi(60, -60, "shop", 2, 7)
			poi(0, -80, "shop", 2, 7)
			for _, p in { { -30, 0 }, { 30, 0 }, { 0, 30 }, { -60, 60 }, { 60, 60 } } do
				poi(p[1], p[2], "hangout", 1, 8)
			end
			poi(-85, 0, "viewpoint", 0.7, 5)
			poi(85, 0, "viewpoint", 0.7, 5)
			poi(0, 85, "objective")
			poi(0, -35, "objective")
			return list
		end

		T.it("first trip is short", function()
			local short, trips, n = 0, 0, 200
			for seed = 1, n do
				local persona = makePersona(seed + 100, { chattiness = 0 })
				local brain = Brain.new(Rng.new(seed + 1100), persona, 0)
				local world = makeWorld({
					pois = plazaPois(),
					spawnPoint = PLAZA_SPAWN,
					randomReachable = function(from, minDistance, maxDistance)
						return from + Vector3.new(0, 0, -(minDistance + maxDistance) / 2)
					end,
				})
				local chat = makeChat()
				local loco = newLocomotion(1e6, 100)
				local now = 0
				for _ = 1, 400 do -- up to 200 s: idling first is allowed, beelining far is not
					now += DT
					local out = brain:step(makeInput(now, world, chat, loco.input(), { position = PLAZA_SPAWN }))
					if out.intent.kind == "goto" then
						trips += 1
						if flatDistance(out.intent.position, PLAZA_SPAWN) <= 60 then
							short += 1
						end
						break
					end
					loco.apply(out.intent, now)
				end
			end
			T.check(trips >= 0.9 * n, `most seeds set off within 200 s ({trips})`)
			T.check(short / trips >= 0.95, `short first trips {short} of {trips}`)
		end)

		T.it("ritual first input by profile", function()
			local function ritual(profileKind, n)
				local faces, jumps = 0, 0
				for seed = 1, n do
					local persona = Personality.sample(Rng.new(seed), { profileKind = profileKind })
					persona.chattiness = 0
					local brain = Brain.new(Rng.new(seed + 4000), persona, 0)
					local world = makeWorld({ pois = ringOfPois(4, 30, "hangout", 1) })
					local chat = makeChat()
					local loco = newLocomotion(1e6, 100)
					local sawFace, sawJump = false, false
					local now = 0
					while not brain.ritual.done and now < 10 do
						now += DT
						local out = brain:step(makeInput(now, world, chat, loco.input()))
						T.equal(out.phase, "joining", "the ritual runs in the joining phase")
						if out.intent.kind == "face" then
							sawFace = true
						elseif out.intent.kind == "jump" then
							sawJump = true
						end
						loco.apply(out.intent, now)
					end
					T.check(brain.ritual.done, "the ritual ends within 10 s")
					if sawFace then
						faces += 1
					end
					if sawJump then
						jumps += 1
					end
				end
				return faces / n, jumps / n
			end
			local pcFace = ritual("pc", 400)
			local mobileFace = ritual("mobile", 400)
			T.equal(pcFace, 0, "a keyboard player never spins in place")
			T.equal(mobileFace, 0, "a phone player never spins in place")
			local lockFace, lockJump = ritual("pcShiftLock", 400)
			T.between(lockFace, 0.18, 0.30, `shift-lock spin share {lockFace}`)
			T.between(lockJump, 0.54, 0.66, `jump share {lockJump}`)
		end)

		T.it("game event pulls toward an objective", function()
			local hits, fired, n = 0, 0, 100
			for seed = 1, n do
				local persona = makePersona(seed + 200, { chattiness = 0 })
				local objective = {
					id = "goal",
					kind = "objective",
					position = Vector3.new(0, 0, -40),
					weight = 2,
					radius = 6,
					dwellMedian = 2,
				}
				local hangout = {
					id = "bench",
					kind = "hangout",
					position = Vector3.new(25, 0, 0),
					weight = 1,
					radius = 6,
					dwellMedian = 2,
				}
				local brain = Brain.new(Rng.new(seed + 5000), persona, 0)
				local world = makeWorld({ pois = { hangout, objective } })
				local chat = makeChat()
				local loco = newLocomotion(30, 100) -- a long leg: the walk to the bench takes 30 s
				local now = 0
				local firedAt = nil
				local hit = false
				for _ = 1, 400 do
					now += DT
					local out = brain:step(makeInput(now, world, chat, loco.input()))
					if firedAt then
						if
							(out.activity == "VisitPoi" and out.target == "goal")
							or (out.activity == "Watch" and out.target == "event")
						then
							hit = true
							break
						end
						if now - firedAt > 8 then
							break
						end
					elseif out.activity == "VisitPoi" and out.target == "bench" and loco.input().moving and now > 8 then
						-- Committed to the bench and walking: something happens at the objective.
						brain:onSystemEvent("gameEvent", now, objective.position, { name = "drop", magnitude = 1 })
						firedAt = now
						fired += 1
					end
					loco.apply(out.intent, now)
				end
				if hit then
					hits += 1
				end
			end
			T.check(fired >= 0.8 * n, `the bench trip started in most seeds ({fired})`)
			T.check(hits / fired >= 0.7, `pulled toward the objective in {hits} of {fired}`)
		end)

		T.it("afk share over twenty hours", function()
			local afkSeconds, totalSeconds = 0, 0
			for seed = 1, 20 do
				local persona = makePersona(seed + 300, { afkProneness = 0.6 })
				local brain = Brain.new(Rng.new(seed + 6000), persona, 0)
				local world = makeWorld({
					pois = ringOfPois(6, 30, "hangout", 1),
					randomReachable = function(from, minDistance)
						return from + Vector3.new(minDistance + 5, 0, 0)
					end,
				})
				local chat = makeChat()
				local loco = newLocomotion(4, 100)
				local now = 0
				for _ = 1, 3600 do
					now += 1
					local out = brain:step(makeInput(now, world, chat, loco.input(), { dt = 1 }))
					if out.activity == "Afk" then
						afkSeconds += 1
					end
					totalSeconds += 1
					loco.apply(out.intent, now)
				end
			end
			T.between(afkSeconds / totalSeconds, 0.15, 0.40, `afk share {afkSeconds / totalSeconds}`)
		end)

		-- A brain past its ritual with a VisitPoi trip under way, for the system-event cases.
		local function walkingBrain(seed, legSeconds)
			local persona = makePersona(seed, { chattiness = 0, impulsivity = 0, patience = 1, afkProneness = 0 })
			local brain = Brain.new(Rng.new(seed + 7000), persona, 0)
			local world = makeWorld({ pois = ringOfPois(4, 30, "objective", 10) })
			local chat = makeChat()
			local loco = newLocomotion(legSeconds or 1e6, 100)
			local now = 0
			local out
			for _ = 1, 200 do
				now += DT
				out = brain:step(makeInput(now, world, chat, loco.input()))
				loco.apply(out.intent, now)
				if out.activity == "VisitPoi" and loco.input().moving and now - brain.startedAt >= 2 then
					break
				end
			end
			T.equal(out.activity, "VisitPoi", "a trip is under way")
			return brain, world, chat, loco, now
		end

		T.it("avoidExit walks to the exit point before anything else, then chooses again", function()
			local brain, world, chat, loco, now = walkingBrain(61)
			local target = brain:describe().target
			local exit = Vector3.new(12, 0, -3)
			brain:onSystemEvent("avoidExit", now, exit)
			now += DT
			local out = brain:step(makeInput(now, world, chat, loco.input()))
			T.equal(out.intent.kind, "goto")
			T.equal(out.intent.position, exit)
			T.equal(out.intent.urgency, 0.9)
			T.equal(out.activity, nil, "the trip is dropped while walking out")
			T.equal(out.changedMind, false, "the runtime pushed it, the mind did not change")
			T.equal(brain.excluded[target], nil, "the place is not blamed")
			loco.apply(out.intent, now)
			for _ = 1, 4 do
				now += DT
				out = brain:step(makeInput(now, world, chat, loco.input()))
				T.equal(out.intent.kind, "goto", "still heading out")
				T.equal(out.intent.position, exit)
				loco.apply(out.intent, now)
			end
			-- Standing at the exit: the override ends and an activity is chosen again this step.
			now += DT
			out = brain:step(makeInput(now, world, chat, loco.input(), { position = exit }))
			T.check(out.activity ~= nil, "chose again")
			T.equal(brain.override, nil)
		end)

		T.it("flung defers the reselection until the hold is over, without failing the trip", function()
			local brain, world, chat, loco, now = walkingBrain(62)
			local target = brain:describe().target
			local startedAt = brain.startedAt
			brain:onSystemEvent("flung", now, nil, { hold = 3 })
			local flungAt = now
			while now < flungAt + 2.5 do
				now += DT
				local out = brain:step(makeInput(now, world, chat, loco.input()))
				T.equal(out.activity, "VisitPoi", "the trip keeps its slot during the hold")
				T.equal(brain.startedAt, startedAt, "no reselection yet")
				loco.apply(out.intent, now)
			end
			now = flungAt + 3.5
			local out = brain:step(makeInput(now, world, chat, loco.input()))
			T.check(brain.startedAt > startedAt, "chose again after the hold")
			T.check(out.activity ~= nil)
			T.equal(brain.excluded[target], nil, "the place is not blamed")
		end)

		T.it("fell chooses again, keeps the place, and sometimes says something", function()
			local spoke, n = 0, 100
			for seed = 1, n do
				local brain, world, chat, loco, now = walkingBrain(seed + 80)
				brain.persona.chattiness = 1
				local target = brain:describe().target
				local startedAt = brain.startedAt
				brain:onSystemEvent("fell", now, ORIGIN)
				now += DT
				local out = brain:step(makeInput(now, world, chat, loco.input()))
				T.check(brain.startedAt > startedAt, "chose again")
				T.equal(out.changedMind, false, "a fall is not a change of mind")
				T.equal(brain.excluded[target], nil, "the place is not blamed")
				if brain.overlays:hasPendingLine() then
					spoke += 1
				end
			end
			T.between(spoke / n, 0.18, 0.42, `spoke after falling {spoke / n} (0.3 x chattiness 1)`)
		end)

		T.it("goalInvalid fails the trip, blames the place and forgets the visit", function()
			local brain, world, chat, loco, now = walkingBrain(63)
			local target = brain:describe().target
			brain.memory.visited[target] = { lastAt = now - 10, count = 1 }
			brain:onSystemEvent("goalInvalid", now, nil)
			now += DT
			local out = brain:step(makeInput(now, world, chat, loco.input()))
			T.check(out.activity == nil or brain:describe().target ~= target, "the target is dropped")
			T.check(brain.excluded[target] ~= nil and brain.excluded[target] > now, "excluded for a while")
			T.equal(brain.memory.visited[target], nil, "the visit is forgotten")
		end)

		T.it("a semi AFK notices things three times later", function()
			local function queuedDelay(afkStyle, seed)
				local persona = makePersona(seed, { chattiness = 0, attention = 1, afkStyle = afkStyle })
				local brain = Brain.new(Rng.new(seed + 8000), persona, 0)
				-- Put the brain straight into Afk (past the ritual) so the style applies.
				brain.ritual.done = true
				brain.session.ritualDone = true
				brain.session.phase = "settled"
				brain.activity = Activities.get("Afk")
				brain.state = { startedAt = 0, until_ = 1e6, wiggleAt = nil }
				brain.activityStatus = "running"
				brain.nextReviewAt = 1e6
				local world = makeWorld({})
				local chat = makeChat()
				local loco = newLocomotion(1e6, 100)
				local now = DT
				local ev = { kind = "followed", salience = 0.7, expected = false, subject = "p:1", at = now, data = {} }
				brain:step(makeInput(now, world, chat, loco.input(), { events = { ev } }))
				for _, entry in brain.reactions.pending do
					if entry.event == ev then
						return entry.at - now
					end
				end
				return nil
			end
			local compared, seed = 0, 0
			while compared < 10 do
				seed += 1
				T.check(seed < 200, "enough seeds where the event was noticed")
				local semi, full = queuedDelay("semi", seed), queuedDelay("full", seed)
				T.equal(semi == nil, full == nil, "same draws: both noticed or both missed")
				if semi and full then
					compared += 1
					T.near(semi / full, 3, 1e-9, `semi {semi} vs full {full}`)
					T.check(full >= 0.15, "a real reaction delay")
				end
			end
		end)

		T.it("attention off lets only system events and lines naming the NPC through", function()
			local brain, world, chat, loco, now = walkingBrain(64)
			brain.attentionOff = true
			now += DT
			local before = #brain.reactions.pending
			local events = {
				{ kind = "followed", salience = 0.7, expected = false, subject = "p:1", at = now, data = {} },
				{ kind = "stared", salience = 0.4, expected = false, subject = "p:1", at = now, data = {} },
				{
					kind = "chatHeard",
					salience = 0.25,
					subject = "p:1",
					at = now,
					data = { text = "hi everyone", distance = 5, named = false },
				},
				{
					kind = "chatHeard",
					salience = 0.25,
					subject = "p:1",
					at = now,
					data = { text = "zed come here", distance = 5, named = true },
				},
				{ kind = "stuck", salience = 1, expected = true, at = now },
			}
			-- Attention 1 so nothing is missed by chance; the queue then shows what got in.
			brain.persona.attention = 1
			brain.persona.missChance = 0
			local out = brain:step(makeInput(now, world, chat, loco.input(), { events = events }))
			T.equal(out.attentionOff, false, "walking, not AFK: the flag follows the activity")
			local kinds = {}
			for _, entry in brain.reactions.pending do
				kinds[entry.event.kind] = (kinds[entry.event.kind] or 0) + 1
			end
			T.equal(kinds.followed, nil, "a follower goes unnoticed")
			T.equal(kinds.stared, nil)
			T.equal(kinds.chatHeard, 1, "only the line naming the NPC")
			T.check(#brain.reactions.pending >= before, "system events are queued (or already due)")
			T.equal(#brain.memory.heard, 1, "the named line was absorbed")
			T.equal(brain.memory.heard[1].text, "zed come here")
		end)
	end)
end

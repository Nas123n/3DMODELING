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
			groups = {},
			spawnPoint = ORIGIN,
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
			dt = DT,
			me = { id = "npc1", position = ORIGIN, heading = HEADING, displayName = "Zed", username = "zed_walks" },
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
	end)
end

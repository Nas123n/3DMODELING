return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Personality = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Personality)
	local SocialGuard = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.SocialGuard)
	local Memory = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Memory)
	local Utility = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Utility)
	local Goals = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Goals)
	local Activities = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Activities)
	local Safety = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Safety)
	local Recency = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Recency)
	local Reply = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Reply)
	local Composer = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Composer)
	local ChatCorpus = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.ChatCorpus)
	local ChatStyle = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.ChatStyle)

	T.describe("Personality", function()
		T.it("is deterministic per seed and every trait sits in [0, 1]", function()
			local a, b = Personality.sample(Rng.new(1)), Personality.sample(Rng.new(1))
			T.equal(a.sociability, b.sociability)
			T.equal(a.profile.kind, b.profile.kind)
			T.equal(a.voice.charsPerSecond, b.voice.charsPerSecond)
			for _, key in
				{
					"sociability",
					"curiosity",
					"patience",
					"jumpiness",
					"chattiness",
					"afkProneness",
					"trolliness",
					"skill",
					"impulsivity",
					"friendliness",
					"helpfulness",
					"mirroring",
					"attention",
					"emoteHabit",
					"accountAge",
				}
			do
				T.between(a[key], 0, 1, key)
			end
		end)

		T.it("reproduces the population skews: silent majority, bimodal jumping, mostly mobile", function()
			local silent, spammers, never, mobile, kids, n = 0, 0, 0, 0, 0, 3000
			for i = 1, n do
				local p = Personality.sample(Rng.new(i))
				if not Personality.isChatter(p) then
					silent += 1
				end
				if p.jumpTier == "spammer" then
					spammers += 1
				elseif p.jumpTier == "never" then
					never += 1
				end
				if p.profile.kind == "mobile" then
					mobile += 1
				end
				if p.dialect == "kid" then
					kids += 1
				end
				T.between(p.walkSpeed, 16, 16, "default: everyone walks at 16")
				T.between(p.sessionLength, 60, 240 * 60)
				T.between(p.aboutFaceRate, 0.03, 0.12)
				T.between(p.wallBumpRate, 0.01, 0.03)
			end
			T.between(silent / n, 0.5, 0.75, `silent share {silent / n}`)
			T.between(spammers / n, 0.15, 0.35, `spammer share {spammers / n}`)
			T.between(never / n, 0.3, 0.5, `never share {never / n}`)
			T.between(mobile / n, 0.45, 0.65)
			T.between(kids / n, 0.3, 0.6, `kid share {kids / n}`)
		end)

		T.it("kids type slower and sloppier than older players; speed spread creates boosted walkers", function()
			local kidCps, olderCps, kids, olders = 0, 0, 0, 0
			for i = 1, 2000 do
				local p = Personality.sample(Rng.new(i))
				if p.dialect == "kid" then
					kidCps += p.voice.charsPerSecond
					kids += 1
				elseif p.dialect == "older" then
					olderCps += p.voice.charsPerSecond
					olders += 1
				end
			end
			T.check(kids > 0 and olders > 0)
			T.check(kidCps / kids < olderCps / olders, "kids are slower typists")
			local boosted = 0
			for i = 1, 500 do
				local p = Personality.sample(Rng.new(i), { walkSpeedSpread = 0.3 })
				if p.walkSpeed > 16.5 then
					boosted += 1
					T.between(p.walkSpeed, 16, 32)
				end
			end
			T.between(boosted / 500, 0.15, 0.32, "about 30% roll a boost, some clamp back to the median")
		end)
	end)

	T.describe("Safety", function()
		T.it("blocks personal information, off-platform, money, dating and lures", function()
			local gate = Safety.new()
			for _, bad in
				{
					"add me on discord",
					"whats ur age",
					"how old are u",
					"free robux",
					"visit www.site.com",
					"kys",
					"do u have a gf",
					"join my group",
					"meet me at the park",
					"email me @ home",
				}
			do
				T.check(not gate:check(bad), `should reject: {bad}`)
			end
			for _, ok in { "hi", "can i have a pet pls", "how do u get to the next area", "lol", "### ##", "gg :)" } do
				T.check(gate:check(ok), `should accept: {ok}`)
			end
			T.check(not gate:check(string.rep("a", 121)), "too long")
			T.check(not gate:check("hola señor"), "charset")
			T.check(not gate:check(""), "empty")
			gate:setEnabled(false)
			T.check(not gate:check("hi"), "kill switch")
		end)

		T.it("keeps an audit ring, most recent first", function()
			local gate = Safety.new(nil, 3)
			gate:record("n1", "greeting:hi", "hi", 1)
			gate:record("n1", "greeting:hey", "hey", 2)
			gate:record("n2", "reaction:lol", "lol", 3)
			gate:record("n2", "reaction:bruh", "bruh", 4)
			local log = gate:log()
			T.equal(#log, 3)
			T.equal(log[1].text, "bruh")
			T.equal(log[3].text, "hey")
		end)
	end)

	T.describe("Recency", function()
		T.it("weights recently used lines down server-wide and out for the speaker", function()
			local tracker = Recency.new(900, 3600)
			T.equal(tracker:weight("x", "a", 0), 1)
			tracker:record("x", "a", 0)
			T.equal(tracker:weight("x", "a", 10), 0, "I said it")
			T.equal(tracker:weight("x", "b", 10), 0.05, "someone said it")
			T.equal(tracker:weight("x", "b", 1000), 1, "server window passed")
			T.equal(tracker:weight("x", "a", 1000), 0, "still mine within the hour")
			T.equal(tracker:weight("x", "a", 4000), 1)
		end)
	end)

	T.describe("Reply", function()
		T.it("classifies heard lines", function()
			local me, user = "Milo", "coolgamer2013"
			T.equal(Reply.classify("stop following me", me, user, 5).kind, "stopKeyword")
			T.equal(Reply.classify("stop", me, user, 40).kind, "broadcast", "far away 'stop' is not aimed at me")
			T.equal(Reply.classify("milo stop", me, user, 40).kind, "stopKeyword", "unless named")
			T.equal(Reply.classify("r u a bot", me, user, 5).kind, "botProbe")
			T.equal(Reply.classify("hi milo", me, user).kind, "named")
			T.equal(Reply.classify("coolgamer how", me, user).kind, "named", "username prefix counts")
			T.equal(Reply.classify("how do u get there", me, user).kind, "question")
			T.equal(Reply.classify("is this good?", me, user).kind, "question")
			T.equal(Reply.classify("u want a free pet", me, user).kind, "offer")
			T.equal(Reply.classify("hii", me, user).kind, "greeting")
			T.equal(Reply.classify("hi everyone", me, user).kind, "greeting")
			T.equal(Reply.classify("nice avatar", me, user).kind, "compliment")
			T.equal(Reply.classify("im bored", me, user).kind, "broadcast")
		end)

		T.it("reply probabilities follow the research table and the guard", function()
			local traits = { chattiness = 0.5, helpfulness = 0.5, dialect = "teen" }
			local pGreet = Reply.decide("greeting", traits)
			local pNamed = Reply.decide("named", traits)
			local pBroadcast = Reply.decide("broadcast", traits)
			local pProbe, catProbe = Reply.decide("botProbe", traits)
			T.check(pNamed > pGreet and pGreet > pBroadcast, "named > greeting > broadcast")
			T.near(pProbe, 0.7, 1e-6)
			T.equal(catProbe, "probe")
			T.equal(Reply.decide("botProbe", traits, true), 0, "only once per asker")
			T.equal(Reply.decide("stopKeyword", traits), 0)
			T.equal(Reply.decide("named", { chattiness = 1, helpfulness = 1, dialect = "kid", blocked = true }), 0)
			local silent = Reply.decide("named", { chattiness = 0, helpfulness = 0, dialect = "kid" })
			T.check(silent < pNamed and silent > 0, "silent personas rarely but sometimes answer when named")
			local offer, offerCat = Reply.decide("offer", traits)
			T.check(offer > 0.3)
			T.equal(offerCat, "disagree", "offers are never accepted")
		end)

		T.it("latency grows with reply length", function()
			local voice = ChatStyle.voice(Rng.new(1), "pc", 0.5, 0.3)
			local rng = Rng.new(2)
			local short, long = 0, 0
			for _ = 1, 200 do
				short += Reply.latency("hi", voice, rng, true)
				long += Reply.latency("i think its in the next area past the shop", voice, rng, true)
			end
			T.check(long > short * 2, "long replies take much longer")
			T.check(short / 200 >= 1.5)
		end)
	end)

	T.describe("Composer", function()
		local function ctx(overrides)
			local c = {
				npcId = "n1",
				voice = ChatStyle.voice(Rng.new(5), "pc", 0.6, 0.2),
				rng = Rng.new(6),
				now = 0,
				accountAge = 0.3,
			}
			for k, v in overrides or {} do
				c[k] = v
			end
			return c
		end

		T.it("composes safe lines from the requested category and never repeats itself soon", function()
			local recency, safety = Recency.new(), Safety.new()
			local seen = {}
			for i = 1, 25 do
				local out =
					Composer.compose(ctx({ category = "greeting", now = i, nearbyName = "Zoe" }), recency, safety)
				T.check(out ~= nil, "a greeting is available while unused lines remain")
				T.equal(out.category, "greeting")
				T.check(safety:check(out.text) or out.tagged, `unsafe {out.text}`)
				T.check(not seen[out.lineId], `repeated {out.lineId}`)
				seen[out.lineId] = true
			end
			-- Once every greeting has been used within the hour, the NPC simply says nothing.
			local exhausted = 0
			for i = 26, 80 do
				if
					Composer.compose(ctx({ category = "greeting", now = i, nearbyName = "Zoe" }), recency, safety)
					== nil
				then
					exhausted += 1
				end
			end
			T.check(exhausted > 0, "silence beats repetition")
		end)

		T.it("fills names, skips name lines without a neighbour, and hides rude lines unless allowed", function()
			local recency, safety = Recency.new(), Safety.new()
			local rude, named = 0, 0
			for i = 1, 300 do
				local out =
					Composer.compose(ctx({ category = "reaction", now = i * 10, rng = Rng.new(i) }), recency, safety)
				if out and (out.text == "noob" or out.text == "skill issue" or out.text == "L bozo") then
					rude += 1
				end
				local g = Composer.compose(
					ctx({ category = "social", now = i * 10 + 5, rng = Rng.new(i + 1000) }),
					recency,
					safety
				)
				if g and string.find(g.text, "{", 1, true) then
					T.check(false, `unfilled slot in {g.text}`)
				end
				if g and string.find(g.text, "Zoe", 1, true) then
					named += 1
				end
			end
			T.equal(rude, 0, "rude lines hidden by default")
			T.equal(named, 0, "no neighbour, no name")
			local withName = 0
			for i = 1, 200 do
				local out = Composer.compose(
					ctx({ category = "social", nearbyName = "Zoe", now = i * 100, rng = Rng.new(i) }),
					Recency.new(),
					safety
				)
				if out and string.find(out.text, "Zoe", 1, true) then
					withName += 1
				end
			end
			T.check(withName > 5, "name lines appear with a neighbour")
		end)

		T.it("echoes with a mutation, never verbatim", function()
			local recency, safety = Recency.new(), Safety.new()
			local rng = Rng.new(9)
			local verbatim = 0
			for i = 1, 100 do
				local out = Composer.compose(
					ctx({
						category = "echo",
						echoSource = "anyone wanna trade",
						now = i * 100,
						rng = rng,
						voice = {
							profile = "pc",
							typoRate = 0,
							stretchChance = 0,
							capsChance = 0,
							truncateChance = 0,
							charsPerSecond = 2,
							hesitation = 0,
							tagChance = 0,
						},
					}),
					Recency.new(),
					safety
				)
				T.check(out ~= nil)
				if out.text == "anyone wanna trade" then
					verbatim += 1
				end
			end
			T.equal(verbatim, 0)
		end)

		T.it("spontaneous category mix leans on mood and phase", function()
			local safety = Safety.new()
			local counts = {}
			for i = 1, 400 do
				local out = Composer.compose(
					ctx({ mood = "bored", phase = "settled", rng = Rng.new(i), now = i * 100 }),
					Recency.new(),
					safety
				)
				if out then
					counts[out.category] = (counts[out.category] or 0) + 1
				end
			end
			T.check(
				(counts.bored or 0) + (counts.nonsense or 0) > (counts.greeting or 0),
				"bored settled NPCs mutter more than they greet"
			)
			T.equal(counts.game, nil, "no game lines unless the developer adds some")
			ChatCorpus.extend("game", { "the volcano area is so cool" })
			local game = 0
			for i = 1, 200 do
				local out = Composer.compose(ctx({ rng = Rng.new(i), now = i * 100 }), Recency.new(), safety)
				if out and out.category == "game" then
					game += 1
				end
			end
			T.check(game > 5, "game lines join the mix once added")
		end)
	end)

	T.describe("SocialGuard", function()
		T.it("allows one follow episode and two unanswered direct messages per target", function()
			local guard = SocialGuard.new()
			T.check(guard:canFollow("p1", 0))
			guard:beginFollow("p1", 0)
			T.check(not guard:canFollow("p1", 10))
			T.check(guard:canDirectMessage("p1", 10))
			guard:saidTo("p1", 10, true)
			T.check(not guard:canDirectMessage("p1", 11), "never two spontaneous lines in a row at the same target")
			guard:saidTo("p2", 12, true)
			T.check(guard:canDirectMessage("p1", 13))
			guard:saidTo("p1", 13, true)
			T.check(not guard:canDirectMessage("p1", 14), "two unanswered")
			guard:heardFrom("p1", "lol", 20, false)
			T.check(
				guard:canDirectMessage("p1", 21) or guard.lastSpontaneousTarget == "p1",
				"an answer resets the count"
			)
			guard:saidTo("p2", 22, true)
			T.check(guard:canDirectMessage("p1", 23))
		end)

		T.it("backs off permanently on a stop keyword aimed at it", function()
			local guard = SocialGuard.new()
			guard:warm("p1", 0.6, 0)
			T.equal(guard.attachment, "p1")
			guard:heardFrom("p1", "STOP following me!!", 5, true)
			T.check(guard:isBlocked("p1"))
			T.equal(guard.avoidance, "p1")
			T.equal(guard.attachment, nil)
			T.check(not guard:canFollow("p1", 6))
			T.check(not guard:canDirectMessage("p1", 6))
			guard:warm("p1", 1, 7)
			T.check(guard:isBlocked("p1"), "blocked stays blocked")
			-- Not aimed at me: no block.
			local g2 = SocialGuard.new()
			g2:heardFrom("p3", "stop", 1, false)
			T.check(not g2:isBlocked("p3"))
		end)

		T.it("limits verbal probe reactions and raises annoyance", function()
			local guard = SocialGuard.new()
			T.check(guard:onProbe("p1", "followed", 0))
			T.check(not guard:onProbe("p1", "followed", 30), "once per kind per minute")
			T.check(guard:onProbe("p1", "botProbe", 31))
			T.check(guard:onProbe("p1", "stared", 32))
			T.check(not guard:onProbe("p1", "blocked", 200), "three per subject per session")
			T.check(guard:relation("p1", 200).annoyance > 0.5)
			guard:decay(1200)
			T.check(guard:relation("p1", 1200).annoyance < 0.2, "annoyance fades")
		end)

		T.it("rude lines go to a player at most once", function()
			local guard = SocialGuard.new()
			T.check(not guard:wasRudeTo("p1"), "nothing said yet")
			guard:saidTo("p1", 10, true)
			T.check(not guard:wasRudeTo("p1"), "an ordinary line is not rude")
			T.equal(guard:relation("p1", 10).rudeAt, nil)
			guard:saidTo("p1", 20, true, true)
			T.check(guard:wasRudeTo("p1"), "a rude line is remembered")
			T.equal(guard:relation("p1", 20).rudeAt, 20)
			T.check(not guard:wasRudeTo("p2"), "per person")
			guard:decay(5000)
			T.check(guard:wasRudeTo("p1"), "never fades within the session")
			guard:saidTo("p1", 6000, false, false)
			T.check(guard:wasRudeTo("p1"), "a later ordinary line does not clear it")
			guard:forget("p1")
			T.check(not guard:wasRudeTo("p1"), "forgotten with the relation")
		end)
	end)

	-- A flat world view for Goals and Utility: places on a ring, no entities, everything reachable.
	local function flatWorld(pois, overrides)
		local world = {
			pois = pois or {},
			poiOccupants = function()
				return 0
			end,
			entities = {},
			visible = {},
			groups = {},
			myGroup = nil,
			spawnPoint = Vector3.zero,
			reachable = function()
				return true
			end,
			randomReachable = function(from, minDistance)
				return from + Vector3.new(minDistance + 5, 0, 0)
			end,
			sectorCenter = function()
				return Vector3.new(20, 0, 20)
			end,
			nearbySectors = function()
				return { "1:1" }
			end,
			totalSectors = 100,
			isAvoided = function()
				return false
			end,
			failedRecently = function()
				return false
			end,
			props = nil,
		}
		for k, v in overrides or {} do
			world[k] = v
		end
		return world
	end

	local function goalsContext(persona, world, overrides)
		local ctx = {
			me = { id = "npc1", position = Vector3.zero, heading = Vector3.new(0, 0, -1) },
			persona = persona,
			memory = Memory.new(0),
			phase = "settled",
			mood = "neutral",
			now = 1000,
			rng = Rng.new(77),
			world = world,
			relations = {},
			canFollow = function()
				return true
			end,
			attachment = nil,
			favoritePoiKind = nil,
			fatigue = 0.2,
		}
		for k, v in overrides or {} do
			ctx[k] = v
		end
		return ctx
	end

	local function utilityContext(persona, needs)
		return {
			persona = persona,
			needs = needs,
			mood = "neutral",
			phase = "settled",
			now = 1000,
			lastEnd = function()
				return nil
			end,
		}
	end

	local function find(candidates, activity, target)
		for _, c in candidates do
			if c.activity == activity and (target == nil or c.target == target) then
				return c
			end
		end
		return nil
	end

	T.describe("Utility", function()
		T.it("need(Afk) is 0.5 + 0.5 fatigue so AFK is reachable in an ordinary session", function()
			local function needs(fatigue)
				return { boredom = 0, social = 0, purpose = 0, fatigue = fatigue, novelty = 0 }
			end
			T.near(Utility.need("Afk", needs(0)), 0.5, 1e-9)
			T.near(Utility.need("Afk", needs(0.5)), 0.75, 1e-9)
			T.near(Utility.need("Afk", needs(1)), 1.0, 1e-9)
			T.equal(Utility.need("Leave", needs(1)), 1)
			T.near(Utility.need("IdleStand", needs(0)), 0.45, 1e-9, "the idle floor is untouched")
			T.equal(Utility.sensitivity("gameEvent", { sociability = 0, curiosity = 0 }), 2.0, "a system event")
		end)
	end)

	T.describe("Goals", function()
		T.it("newcomers explore more", function()
			local persona = Personality.sample(Rng.new(3))
			local needs = { boredom = 0.5, social = 0.2, purpose = 0.5, fatigue = 0.1, novelty = 0.6 }
			local function exploreScore(familiarity)
				local ctx = goalsContext(persona, flatWorld({}), { familiarity = familiarity })
				local c = find(Goals.candidates(ctx), "Explore")
				T.check(c ~= nil, "an Explore candidate exists")
				return Utility.scoreOne(utilityContext(persona, needs), c)
			end
			local newcomer, veteran = exploreScore(0.05), exploreScore(0.95)
			T.check(newcomer / veteran >= 1.6, `ratio {newcomer / veteran}`)
			local unscaled = exploreScore(nil)
			T.near(unscaled, exploreScore(1), 1e-9, "no familiarity given behaves like a veteran")
		end)

		T.it("restlessness and the pointless share shape Wander and Pace", function()
			local persona = Personality.sample(Rng.new(4))
			persona.restlessness = 1
			persona.pointlessTarget = 0.5
			local ctx = goalsContext(persona, flatWorld({}))
			local candidates = Goals.candidates(ctx)
			local wanders = {}
			for _, c in candidates do
				if c.activity == "Wander" then
					table.insert(wanders, c.ctx)
				end
			end
			T.equal(#wanders, 2)
			T.near(wanders[1], 1.25 * 1.4, 1e-9, "biased half of 2.5, restless x1.4")
			T.near(wanders[2], 1.25 * 1.4, 1e-9, "pointless half of 2.5, restless x1.4")
			T.near(find(candidates, "Pace").ctx, 1.4, 1e-9)
			-- A calm persona without the traits keeps the landed 1.5 / 1 split and factor 1.
			local plain = Personality.sample(Rng.new(4))
			plain.restlessness = nil
			plain.pointlessTarget = nil
			local plainCandidates = Goals.candidates(goalsContext(plain, flatWorld({})))
			local plainWanders = {}
			for _, c in plainCandidates do
				if c.activity == "Wander" then
					table.insert(plainWanders, c.ctx)
				end
			end
			T.near(plainWanders[1], 1.5, 1e-9)
			T.near(plainWanders[2], 1, 1e-9)
			T.near(find(plainCandidates, "Pace").ctx, 1, 1e-9)
		end)

		T.it("a hangout with a free seat pulls harder on someone who likes to sit", function()
			local persona = Personality.sample(Rng.new(5))
			persona.sitHabit = 1
			local hangout = { id = "h", kind = "hangout", position = Vector3.new(20, 0, 0), weight = 1, radius = 6 }
			local plain = find(Goals.candidates(goalsContext(persona, flatWorld({ hangout }))), "VisitPoi", "h")
			local seated = find(
				Goals.candidates(goalsContext(
					persona,
					flatWorld({ hangout }, {
						seatsNear = function()
							return { { id = "bench", position = Vector3.new(22, 0, 0), poiId = "h" } }
						end,
					})
				)),
				"VisitPoi",
				"h"
			)
			T.near(seated.ctx / plain.ctx, 1.3, 1e-9)
		end)

		T.it("a game event adds the nearest objective (bonus 2) and a watch of the spot (bonus 1)", function()
			local persona = Personality.sample(Rng.new(6))
			local pois = {
				{ id = "far", kind = "objective", position = Vector3.new(200, 0, 0), weight = 1, radius = 6 },
				{ id = "near", kind = "objective", position = Vector3.new(40, 0, 0), weight = 1, radius = 6 },
				{ id = "h", kind = "hangout", position = Vector3.new(10, 0, 0), weight = 1, radius = 6 },
			}
			local at = Vector3.new(45, 0, 5)
			local ctx = goalsContext(persona, flatWorld(pois))
			local ev = { kind = "gameEvent", salience = 1, at = 1000, data = { position = at, magnitude = 1 } }
			local candidates = Goals.candidates(ctx, ev)
			local objective = find(candidates, "VisitPoi", "near")
			T.check(objective ~= nil, "the nearest objective is a candidate")
			T.equal(objective.bonus, 2.0)
			T.equal(find(candidates, "VisitPoi", "far").bonus, nil, "only the nearest gets the bonus")
			local watch = find(candidates, "Watch", "event")
			T.check(watch ~= nil, "a watch toward the spot")
			T.equal(watch.bonus, 1.0)
			T.equal(watch.data.position, at)
			-- Without a position there is no watch, and the objective bonus goes by my position.
			local noSpot = Goals.candidates(ctx, { kind = "gameEvent", salience = 1, at = 1000, data = {} })
			T.equal(find(noSpot, "Watch", "event"), nil)
			T.equal(find(noSpot, "VisitPoi", "near").bonus, 2.0)
		end)
	end)

	T.describe("Activities", function()
		local HEADING = Vector3.new(0, 0, -1)

		local function flatDistance(a, b)
			local dx, dz = a.X - b.X, a.Z - b.Z
			return math.sqrt(dx * dx + dz * dz)
		end

		-- One activity under a scripted body: a goto walks for one tick and arrives on the next,
		-- teleporting the body to the goal; everything else idles. Returns the outcome plus every
		-- intent and action seen.
		local function runActivity(seed, name, candidate, opts)
			local o = opts or {}
			local persona = Personality.sample(Rng.new(seed), { profileKind = o.profileKind })
			for k, v in o.persona or {} do
				persona[k] = v
			end
			local loco = { status = "idle", goal = nil, moving = false, onGround = true, blockedBy = nil }
			local me = { id = "npc1", position = Vector3.zero, heading = HEADING }
			local world = flatWorld(o.pois or {}, o.world)
			local step = {}
			local intents, actions = {}, {}
			local ctx = {
				now = 0,
				dt = 0.5,
				rng = Rng.new(seed + 5000),
				persona = persona,
				me = me,
				locomotion = loco,
				world = world,
				entity = function()
					return nil
				end,
				memory = Memory.new(0),
				emit = function(i)
					table.insert(step, i)
					table.insert(intents, i)
				end,
				act = function(a)
					table.insert(actions, a)
				end,
				relieve = function() end,
				suppress = {},
				canFollow = function()
					return true
				end,
				beginFollow = function() end,
				affinity = function()
					return 0
				end,
				shiftLock = persona.profile.strafes,
				groupOf = function()
					return nil
				end,
				inGroup = false,
				familiarity = persona.familiarity,
				afkStyle = persona.afkStyle,
			}
			local activity = Activities.get(name)
			local state = activity.start(ctx, candidate)
			local status = "running"
			local steps = 0
			while status == "running" do
				steps += 1
				if steps > 4000 then
					error(`{name} did not finish`)
				end
				ctx.now += ctx.dt
				ctx.suppress = {}
				table.clear(step)
				status = activity.tick(ctx, state)
				local travel = nil
				for _, i in step do
					if i.kind == "goto" then
						travel = i
					end
				end
				if travel then
					if loco.goal and flatDistance(loco.goal, travel.position) < 0.5 then
						loco.status = "arrived"
						loco.moving = false
						me.position = travel.position
					else
						loco.goal = travel.position
						loco.status = "walking"
						loco.moving = true
					end
				else
					loco.status = "idle"
					loco.goal = nil
					loco.moving = false
				end
			end
			activity.stop(ctx, state, status)
			return { status = status, intents = intents, actions = actions, state = state, seconds = ctx.now }
		end

		local function hangout(extra)
			local poi = { id = "h1", kind = "hangout", position = Vector3.new(0, 0, -20), weight = 1, radius = 6 }
			for k, v in extra or {} do
				poi[k] = v
			end
			return poi
		end

		T.it("visit stops short and faces", function()
			local stopSum, faced, n = 0, 0, 200
			for seed = 1, n do
				local poi = hangout({ dwellMedian = 2 })
				local r = runActivity(seed, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
					profileKind = "pcShiftLock",
					pois = { poi },
				})
				T.equal(r.status, "success", `seed {seed}`)
				local firstGoto, sawFace = nil, false
				for _, i in r.intents do
					if i.kind == "goto" and not firstGoto then
						firstGoto = i
					elseif i.kind == "face" then
						sawFace = true
					end
				end
				T.check(firstGoto ~= nil, "a trip was made")
				stopSum += flatDistance(firstGoto.position, poi.position)
				if sawFace then
					faced += 1
				end
			end
			T.check(stopSum / n >= 1.5, `mean stop distance {stopSum / n}`)
			T.between(faced / n, 0.5, 0.7, `face share {faced / n}`)
		end)

		T.it("mobile players stop further out and nobody stops on top of someone", function()
			local poi = hangout()
			local function firstStop(seed, profileKind, entities)
				local r = runActivity(seed, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
					profileKind = profileKind,
					pois = { poi },
					world = { entities = entities or {} },
				})
				for _, i in r.intents do
					if i.kind == "goto" then
						return flatDistance(i.position, poi.position)
					end
				end
				return nil
			end
			-- Same seed, same draws: the phone stops 15 % further out.
			local pc, mobile = firstStop(11, "pc"), firstStop(11, "mobile")
			T.near(mobile / pc, 1.15, 1e-6)
			T.between(pc, 1.8, 4.8, "hangout stop distance u(0.3, 0.8) x radius 6")
			-- Someone standing on the stop point pushes it 1.5 studs away from them.
			local plain = runActivity(12, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
				profileKind = "pc",
				pois = { poi },
			})
			local plainStop = nil
			for _, i in plain.intents do
				if i.kind == "goto" then
					plainStop = i.position
					break
				end
			end
			local occupant = {
				id = "p:1",
				kind = "player",
				position = plainStop + Vector3.new(0.5, 0, 0),
				velocity = Vector3.zero,
				yaw = 0,
				displayName = "Zoe",
			}
			local pushed = runActivity(12, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
				profileKind = "pc",
				pois = { poi },
				world = { entities = { occupant } },
			})
			local pushedStop = nil
			for _, i in pushed.intents do
				if i.kind == "goto" then
					pushedStop = i.position
					break
				end
			end
			T.near(flatDistance(pushedStop, plainStop), 1.5, 1e-6, "moved 1.5 studs")
			T.check(flatDistance(pushedStop, occupant.position) > flatDistance(plainStop, occupant.position), "away")
		end)

		T.it("sits when a free seat is near", function()
			local seat = { id = "bench", position = Vector3.new(3, 0, -20), poiId = "h1" }
			local function seatedWorld(startOccupied, listWhenOccupied)
				local occupied = startOccupied
				return {
					seatsNear = function(position, radius)
						T.check(radius == 6, "the POI radius")
						T.check(position == Vector3.new(0, 0, -20), "the POI position")
						if occupied and not listWhenOccupied then
							return {}
						end
						return { seat }
					end,
					occupySeat = function(id, who)
						T.equal(id, "bench")
						T.equal(who, "npc1")
						if occupied then
							return false
						end
						occupied = true
						return true
					end,
					releaseSeat = function(id, who)
						T.equal(id, "bench")
						T.equal(who, "npc1")
						occupied = false
					end,
				}
			end
			local sits, n = 0, 400
			for seed = 1, n do
				local poi = hangout({ dwellMedian = 2 })
				local r = runActivity(seed, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
					persona = { sitHabit = 1 },
					pois = { poi },
					world = seatedWorld(false, false),
				})
				local sat, stood = false, false
				for _, a in r.actions do
					if a.kind == "sit" and a.target == "bench" then
						sat = true
						T.equal(a.point, seat.position)
					elseif a.kind == "sit" and a.target == nil then
						stood = true
					end
				end
				if sat then
					sits += 1
					T.check(stood, "stands up again when the visit ends")
					T.check(not r.state.seated, "released")
				else
					T.check(not stood, "no stand without a sit")
				end
			end
			T.between(sits / n, 0.28, 0.42, `sit share {sits / n}`)
			-- The seat is taken: never, whether the registry hides it or occupySeat says no.
			for _, listed in { false, true } do
				local taken = 0
				for seed = 1, 100 do
					local poi = hangout({ dwellMedian = 2 })
					local r = runActivity(seed, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
						persona = { sitHabit = 1 },
						pois = { poi },
						world = seatedWorld(true, listed),
					})
					for _, a in r.actions do
						if a.kind == "sit" then
							taken += 1
						end
					end
				end
				T.equal(taken, 0, `occupied seat listed={listed}`)
			end
			-- A world without a seat query never sits and draws nothing extra.
			local none = 0
			for seed = 1, 50 do
				local poi = hangout({ dwellMedian = 2 })
				local r = runActivity(seed, "VisitPoi", { activity = "VisitPoi", target = poi.id, data = poi }, {
					persona = { sitHabit = 1 },
					pois = { poi },
				})
				for _, a in r.actions do
					if a.kind == "sit" then
						none += 1
					end
				end
			end
			T.equal(none, 0)
		end)

		T.it("a full AFK switches attention off, a semi AFK does not, and neither ever turns", function()
			for _, style in { "full", "semi" } do
				local persona = Personality.sample(Rng.new(21), { profileKind = "pcShiftLock" })
				persona.afkStyle = style
				local sawAttention, faces = false, 0
				local r = runActivity(21, "Afk", { activity = "Afk", distance = 0 }, {
					profileKind = "pcShiftLock",
					persona = { afkStyle = style, afkProneness = 0.5 },
				})
				for _, i in r.intents do
					if i.kind == "face" then
						faces += 1
					end
				end
				T.equal(faces, 0, `{style}: no turning`)
				T.equal(r.status, "success")
				-- The suppression flag is set every tick: check one tick directly.
				local ctx = {
					now = 0,
					dt = 0.5,
					rng = Rng.new(1),
					persona = persona,
					me = { id = "npc1", position = Vector3.zero, heading = HEADING },
					locomotion = { status = "idle", goal = nil, moving = false, onGround = true },
					world = flatWorld({}),
					entity = function()
						return nil
					end,
					memory = Memory.new(0),
					emit = function() end,
					act = function() end,
					relieve = function() end,
					suppress = {},
					canFollow = function()
						return true
					end,
					beginFollow = function() end,
					affinity = function()
						return 0
					end,
					shiftLock = true,
					groupOf = function()
						return nil
					end,
					inGroup = false,
					afkStyle = style,
				}
				local afk = Activities.get("Afk")
				local state = afk.start(ctx, { activity = "Afk", distance = 0 })
				ctx.now = 1
				afk.tick(ctx, state)
				sawAttention = ctx.suppress.attention == true
				T.equal(sawAttention, style == "full", `{style}: attention flag`)
				T.check(ctx.suppress.fidget and ctx.suppress.talk, "still and silent")
			end
		end)
	end)
end

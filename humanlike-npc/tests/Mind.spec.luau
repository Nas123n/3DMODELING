return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Personality = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Personality)
	local SocialGuard = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.SocialGuard)
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
	end)
end

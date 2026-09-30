return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Personality = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Personality)
	local Needs = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Needs)
	local Mood = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Mood)
	local Memory = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Memory)
	local Reaction = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Reaction)
	local Session = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Session)

	local function persona(seed, overrides)
		local p = Personality.sample(Rng.new(seed))
		for key, value in overrides or {} do
			p[key] = value
		end
		return p
	end

	local function needsAt(values)
		return {
			boredom = values.boredom or 0,
			social = values.social or 0,
			purpose = values.purpose or 0,
			fatigue = values.fatigue or 0,
			novelty = values.novelty or 0,
		}
	end

	T.describe("Needs", function()
		T.it("starts inside the §4.3 ranges and matches the persona", function()
			for seed = 1, 40 do
				local p = persona(seed)
				local needs = Needs.new(Rng.new(seed + 100), p)
				T.equal(needs.boredom, 0.1, "boredom")
				T.between(needs.social, 0, 0.5, "social")
				T.near(needs.purpose, 0.5 + 0.3 * p.accountAge, 1e-9, "purpose")
				T.between(needs.fatigue, 0, 0.4, "fatigue")
				T.near(needs.novelty, 0.6 * (1 - p.accountAge) + 0.2, 1e-9, "novelty")
				for _, key in { "boredom", "social", "purpose", "fatigue", "novelty" } do
					T.between(needs[key], 0, 1, key)
				end
			end
		end)

		T.it("boredom saturates in about four minutes idle with curiosity 0.5", function()
			local p = persona(1, { curiosity = 0.5 })
			local needs = needsAt({ boredom = 0.1 })
			local now = 0
			local saturatedAt = nil
			while now < 400 do
				Needs.drift(needs, 1, p, 0, 0)
				now += 1
				if needs.boredom >= 1 and not saturatedAt then
					saturatedAt = now
				end
			end
			T.check(saturatedAt ~= nil, "saturates")
			T.between(saturatedAt, 200, 240, `saturated at {saturatedAt}`)
			-- Engagement slows it: standing idle (E 0.1) takes longer than doing nothing at all.
			local idle = needsAt({ boredom = 0.1 })
			Needs.drift(idle, 200, p, Needs.ENGAGEMENT.IdleStand, 0)
			T.near(idle.boredom, 0.1 + 200 / 240 * 0.9, 1e-6, "E 0.1 slows the climb by 10 %")
		end)

		T.it("companionship relieves social in about a minute", function()
			local p = persona(2, { sociability = 0.9 })
			local needs = needsAt({ social = 1 })
			local now = 0
			local emptyAt = nil
			while now < 120 do
				Needs.drift(needs, 0.5, p, 0.6, 1)
				now += 0.5
				if needs.social <= 0 and not emptyAt then
					emptyAt = now
				end
			end
			T.check(emptyAt ~= nil, "company empties social hunger")
			T.between(emptyAt, 55, 65, `emptied at {emptyAt}`)
			-- Alone it only rises.
			local alone = needsAt({ social = 0.2 })
			Needs.drift(alone, 60, p, 0.6, 0)
			T.near(alone.social, 0.2 + 60 / 300 * (0.3 + 1.4 * 0.9), 1e-6, "rises alone")
		end)

		T.it("Afk freezes boredom while the other needs keep drifting", function()
			local p = persona(3, { curiosity = 0.7, afkProneness = 0.5 })
			local needs = needsAt({ boredom = 0.3, fatigue = 0.2 })
			Needs.drift(needs, 120, p, Needs.ENGAGEMENT.Afk, 0)
			T.near(needs.boredom, 0.3, 1e-9, "boredom frozen")
			T.near(needs.fatigue, 0.2 + 120 / 600 * (0.2 + 1.6 * 0.5), 1e-6, "fatigue still climbs")
			T.near(needs.novelty, 120 / 180 * (0.3 + 0.7), 1e-6, "novelty still climbs")
			T.near(needs.purpose, 120 / 200 * (0.4 + p.accountAge), 1e-6, "purpose still climbs")
		end)

		T.it("applies the mood multiplier per need and clamps to [0, 1]", function()
			local p = persona(4, { curiosity = 0.5 })
			local calls = {}
			local needs = needsAt({ boredom = 0.5 })
			Needs.drift(needs, 60, p, 0, 0, function(key)
				calls[key] = true
				return if key == "drift.boredom" then 0.3 else 1
			end)
			T.check(calls["drift.boredom"] and calls["drift.social"] and calls["drift.fatigue"], "asks per need")
			T.near(needs.boredom, 0.5 + 60 / 240 * 0.3, 1e-6, "zoned boredom drift is 0.3x")
			local full = needsAt({ boredom = 0.99, social = 0.99, purpose = 0.99, fatigue = 0.99, novelty = 0.99 })
			Needs.drift(full, 1000, p, 0, 0)
			for _, key in { "boredom", "social", "purpose", "fatigue", "novelty" } do
				T.equal(full[key], 1, key)
			end
		end)

		T.it("has every engagement value of the table", function()
			local expected = {
				IdleStand = 0.1,
				Afk = 1.0,
				VisitPoi = 0.7,
				Explore = 0.9,
				Wander = 0.5,
				Follow = 0.6,
				JoinGroup = 0.6,
				Watch = 0.4,
				Pace = 0.3,
				StandOnProp = 0.8,
				FaceOff = 0.8,
				ReturnToSpawn = 0.4,
				ReactProbe = 0.7,
				Leave = 1.0,
			}
			for name, value in expected do
				T.equal(Needs.ENGAGEMENT[name], value, name)
			end
		end)

		T.it("applies every relief event with the amounts of the table", function()
			local cases = {
				{ "visitObjective", nil, { purpose = -0.30, boredom = -0.15 } },
				{ "visitHangout", nil, { purpose = -0.10, boredom = -0.20 } },
				{ "visitHangout", { others = true }, { purpose = -0.10, boredom = -0.20, social = -0.05 } },
				{ "explore", nil, { novelty = -0.25, boredom = -0.10, purpose = -0.05 } },
				{ "wander", nil, { boredom = -0.05 } },
				{ "newEntity", nil, { novelty = -0.05 } },
				{ "chat", nil, { social = -0.15 } },
				{ "afkTick", { dt = 30 }, { fatigue = -30 / 150 } },
				{ "idleTick", { dt = 60 }, { fatigue = -60 / 600 } },
				{ "standOnProp", nil, { boredom = -0.30 } },
				{ "pace", nil, { boredom = -0.10 } },
				{ "fidgetBurst", nil, { boredom = -0.02 } },
				{ "emote", nil, { boredom = -0.04 } },
				{ "emote", { others = true }, { boredom = -0.04, social = -0.03 } },
				{ "nothingLikeThis", nil, {} },
			}
			for _, case in cases do
				local event, context, deltas = case[1], case[2], case[3]
				local needs = needsAt({ boredom = 0.8, social = 0.8, purpose = 0.8, fatigue = 0.8, novelty = 0.8 })
				Needs.relieve(needs, event, context)
				for _, key in { "boredom", "social", "purpose", "fatigue", "novelty" } do
					T.near(needs[key], 0.8 + (deltas[key] or 0), 1e-9, `{event} {key}`)
				end
			end
			local empty = needsAt({ purpose = 0.1 })
			Needs.relieve(empty, "visitObjective")
			T.equal(empty.purpose, 0, "clamped at zero")
			T.equal(empty.boredom, 0, "clamped at zero")
		end)
	end)

	T.describe("Mood", function()
		local function ctx(overrides)
			local c = {
				nearbyCount = 0,
				inGroup = false,
				recentJumpsAndEmotes = 0,
				probeCount2min = 0,
				activity = "IdleStand",
				maxRelationAnnoyance = 0,
			}
			for key, value in overrides or {} do
				c[key] = value
			end
			return c
		end

		T.it("starts neutral with a review 8..60 s out", function()
			local mood = Mood.new(100, Rng.new(1))
			T.equal(mood.name, "neutral")
			T.equal(mood.since, 100)
			T.between(mood.nextReviewAt - 100, 8, 60)
			T.equal(mood.annoyance, 0)
			for seed = 1, 50 do
				local m = Mood.new(0, Rng.new(seed))
				T.between(m.nextReviewAt, 8, 60, "review cadence")
			end
		end)

		T.it("evaluates entry conditions in priority order", function()
			local p = persona(5, { jumpiness = 0.8 })
			local all = ctx({
				nearbyCount = 2,
				inGroup = true,
				recentJumpsAndEmotes = 3,
				probeCount2min = 3,
				activity = "VisitPoi",
				maxRelationAnnoyance = 0.9,
			})
			local needs = needsAt({ boredom = 0.9, social = 0.9, purpose = 0.9, fatigue = 0.9 })
			local expectedOrder = { "annoyed", "zoned", "playful", "social", "bored", "engaged", "neutral" }
			local function moodFor(c, n)
				local mood = Mood.new(0, Rng.new(7))
				Mood.update(mood, 0, n, c, p, Rng.new(8), true)
				return mood.name
			end
			T.equal(moodFor(all, needs), expectedOrder[1])
			all.probeCount2min = 0
			all.maxRelationAnnoyance = 0.5
			T.equal(moodFor(all, needs), expectedOrder[2], "annoyance must exceed 0.5")
			needs.fatigue = 0.7
			T.equal(moodFor(all, needs), expectedOrder[3], "fatigue must exceed 0.7")
			all.inGroup = false
			all.recentJumpsAndEmotes = 1
			T.equal(moodFor(all, needs), expectedOrder[4])
			needs.social = 0.55
			T.equal(moodFor(all, needs), expectedOrder[5])
			needs.boredom = 0.65
			T.equal(moodFor(all, needs), expectedOrder[6])
			all.activity = "Wander"
			T.equal(moodFor(all, needs), expectedOrder[7], "engaged needs an engaging activity")
			all.activity = "Explore"
			needs.purpose = 0.5
			T.equal(moodFor(all, needs), "neutral", "purpose must exceed 0.5")

			-- The alternative playful path: in a group with jumpiness > 0.6.
			T.equal(moodFor(ctx({ inGroup = true }), needsAt({})), "playful", "group + jumpy")
			T.equal(moodFor(ctx({ inGroup = true }), needsAt({})), "playful")
			local calm = persona(5, { jumpiness = 0.5 })
			local mood = Mood.new(0, Rng.new(7))
			Mood.update(mood, 0, needsAt({}), ctx({ inGroup = true }), calm, Rng.new(8), true)
			T.equal(mood.name, "neutral", "jumpiness 0.5 in a group is not playful")
			Mood.update(mood, 0, needsAt({}), ctx({ recentJumpsAndEmotes = 2 }), calm, Rng.new(8), true)
			T.equal(mood.name, "playful", "two jumps nearby with jumpiness > 0.4 is")
			-- Social needs someone nearby.
			T.equal(moodFor(ctx({ nearbyCount = 0 }), needsAt({ social = 0.9 })), "neutral")
			T.equal(moodFor(ctx({ nearbyCount = 1 }), needsAt({ social = 0.9 })), "social")
			-- Mood-level annoyance counts too.
			local irritated = Mood.new(0, Rng.new(7))
			Mood.raiseAnnoyance(irritated, 0.6, 0)
			Mood.update(irritated, 0, needsAt({}), ctx({}), p, Rng.new(8), true)
			T.equal(irritated.name, "annoyed")
		end)

		T.it("keeps a mood for its minimum dwell unless a higher priority mood wins", function()
			local p = persona(6, { jumpiness = 0.2 })
			local rng = Rng.new(9)
			local mood = Mood.new(0, Rng.new(1))
			T.check(Mood.update(mood, 0, needsAt({ boredom = 0.9 }), ctx({}), p, rng, true), "enters bored")
			T.equal(mood.name, "bored")
			T.between(mood.minUntil, 20, 600, "dwell 20..600 s")
			local dwell = mood.minUntil
			-- Boredom is gone, but the dwell holds.
			T.check(not Mood.update(mood, 1, needsAt({}), ctx({}), p, rng, true), "no change during dwell")
			T.equal(mood.name, "bored")
			-- A lower-priority mood (engaged) cannot interrupt either.
			T.check(
				not Mood.update(mood, 2, needsAt({ purpose = 0.9 }), ctx({ activity = "Explore" }), p, rng, true),
				"engaged waits"
			)
			-- A higher-priority one can.
			T.check(Mood.update(mood, 3, needsAt({ fatigue = 0.9 }), ctx({}), p, rng, true), "zoned interrupts")
			T.equal(mood.name, "zoned")
			T.equal(mood.since, 3)
			-- After the dwell the review follows the conditions again.
			local later = mood.minUntil + 1
			T.check(Mood.update(mood, later, needsAt({}), ctx({}), p, rng, true), "leaves after dwell")
			T.equal(mood.name, "neutral")
			T.check(dwell > 0)
		end)

		T.it("reviews only when due unless forced", function()
			local p = persona(7)
			local rng = Rng.new(3)
			local mood = Mood.new(0, Rng.new(2))
			local boredNeeds = needsAt({ boredom = 0.9 })
			T.check(not Mood.update(mood, mood.nextReviewAt - 1, boredNeeds, ctx({}), p, rng), "not due yet")
			T.equal(mood.name, "neutral")
			local reviewAt = mood.nextReviewAt
			T.check(Mood.update(mood, reviewAt, boredNeeds, ctx({}), p, rng), "due")
			T.equal(mood.name, "bored")
			T.between(mood.nextReviewAt - reviewAt, 8, 60, "next review rescheduled")
		end)

		T.it("decays annoyance with tau 180 s", function()
			local mood = Mood.new(0, Rng.new(1))
			Mood.raiseAnnoyance(mood, 1, 0)
			T.equal(mood.annoyance, 1)
			Mood.update(mood, 180, needsAt({}), ctx({}), persona(8), Rng.new(2))
			T.near(mood.annoyance, math.exp(-1), 1e-6, "one tau")
			Mood.update(mood, 360, needsAt({}), ctx({}), persona(8), Rng.new(2))
			T.near(mood.annoyance, math.exp(-2), 1e-6, "two tau")
			Mood.raiseAnnoyance(mood, 0.9, 360)
			T.equal(mood.annoyance, 1, "clamped")
			Mood.raiseAnnoyance(mood, 0.2, 540)
			T.near(mood.annoyance, math.exp(-1) + 0.2, 1e-6, "decays before adding")
		end)

		T.it("multiplier table spot checks", function()
			T.equal(Mood.multiplier("bored", "fidget"), 2.2)
			T.equal(Mood.multiplier("zoned", "chat"), 0.1)
			T.equal(Mood.multiplier("annoyed", "emote"), 0.3)
			T.equal(Mood.multiplier("zoned", "emote"), 0)
			T.equal(Mood.multiplier("zoned", "reaction"), 2.5)
			T.equal(Mood.multiplier("engaged", "reaction"), 1.3)
			T.equal(Mood.multiplier("playful", "interrupt"), 1.3)
			T.equal(Mood.multiplier("zoned", "drift.boredom"), 0.3)
			T.equal(Mood.multiplier("annoyed", "drift.social"), 0.5)
			T.equal(Mood.multiplier("zoned", "drift.fatigue"), 1.5)
			T.equal(Mood.multiplier("zoned", "activity.Afk"), 4.0)
			T.equal(Mood.multiplier("social", "activity.JoinGroup"), 2.0)
			T.equal(Mood.multiplier("annoyed", "activity.Follow"), 0.2)
			T.equal(Mood.multiplier("engaged", "activity.VisitPoi"), 1.5)
			T.equal(Mood.multiplier("bored", "activity.Pace"), 1.8)
			T.equal(Mood.multiplier("playful", "activity.StandOnProp"), 2.0)
			T.equal(Mood.multiplier("annoyed", "activity.Leave"), 2.0)
			T.equal(Mood.multiplier("neutral", "fidget"), 1)
			T.equal(Mood.multiplier("neutral", "activity.Watch"), 1)
			T.equal(Mood.multiplier("bored", "drift.purpose"), 1, "unknown key is 1")
			T.equal(Mood.multiplier("weird", "fidget"), 1, "unknown mood is 1")
		end)
	end)

	T.describe("Memory", function()
		T.it("caps its rings and drops the oldest entry", function()
			local memory = Memory.new(0)
			for i = 1, 20 do
				Memory.recordHeard(memory, `p{i}`, "hi", "greeting", i)
				Memory.recordSaid(memory, `line{i}`, i, nil)
			end
			T.equal(#memory.heard, 16)
			T.equal(#memory.said, 16)
			T.equal(memory.heard[1].fromId, "p5")
			T.equal(memory.heard[16].fromId, "p20")
			T.equal(memory.said[1].lineId, "line5")
			for i = 1, 30 do
				Memory.recordActivity(memory, "Wander", nil, i, i + 1, "done")
			end
			T.equal(#memory.activities, 24)
			T.equal(memory.activities[1].startedAt, 7)
			for i = 1, 12 do
				Memory.recordStuck(memory, Vector3.new(i * 100, 0, 0), i)
			end
			T.equal(#memory.stuckSpots, 8)
			T.equal(memory.stuckSpots[1].position.X, 500)
		end)

		T.it("detects the first sighting only once, and only when visible", function()
			local memory = Memory.new(0)
			T.check(Memory.observe(memory, 1, "a", "player", Vector3.new(1, 0, 0), true), "first")
			T.check(not Memory.observe(memory, 2, "a", "player", Vector3.new(2, 0, 0), true), "second")
			T.check(not Memory.observe(memory, 3, "a", "player", Vector3.new(3, 0, 0), false), "unseen")
			local a = memory.entities.a
			T.equal(a.firstAt, 1)
			T.equal(a.lastAt, 3)
			T.equal(a.timesSeen, 3)
			T.equal(a.lastSeenVisibleAt, 2)
			T.equal(a.lastPosition.X, 3)
			T.equal(a.kind, "player")
			-- Someone noticed behind me first, then seen: the sighting is the visible one.
			T.check(not Memory.observe(memory, 4, "b", "npc", Vector3.new(0, 0, 0), false), "behind")
			T.equal(memory.entities.b.firstAt, 4)
			T.check(Memory.observe(memory, 5, "b", "npc", Vector3.new(0, 0, 0), true), "now sighted")
			T.check(not Memory.observe(memory, 6, "b", "npc", Vector3.new(0, 0, 0), true))
		end)

		T.it("forget() applies the entity, ring, text and visit windows on a 10 s cadence", function()
			local memory = Memory.new(0)
			Memory.observe(memory, 0, "old", "player", Vector3.zero, true)
			Memory.observe(memory, 500, "recent", "player", Vector3.zero, true)
			Memory.recordHeard(memory, "old", "old words", "greeting", 0)
			Memory.recordHeard(memory, "recent", "fresh words", "question", 590)
			Memory.recordSaid(memory, "l1", 0, nil)
			Memory.recordSaid(memory, "l2", 500, "recent")
			Memory.recordActivity(memory, "Wander", nil, 0, 10, "done")
			Memory.recordActivity(memory, "Pace", nil, 500, 520, "done")
			Memory.recordStuck(memory, Vector3.zero, 0)
			Memory.recordStuck(memory, Vector3.zero, 500)
			Memory.recordVisit(memory, "shop", 0)
			Memory.recordVisit(memory, "bench", 500)

			-- Too soon after creation: nothing happens.
			Memory.forget(memory, 5)
			T.equal(#memory.heard, 2)
			T.equal(memory.lastForgetAt, 0)

			-- At 601 s: entity unseen 10 min gone, old raw text gone, rings (15 min) and visits intact.
			Memory.forget(memory, 601)
			T.equal(memory.lastForgetAt, 601)
			T.check(memory.entities.old == nil, "unseen 10 min dropped")
			T.check(memory.entities.recent ~= nil, "recent kept")
			T.equal(#memory.heard, 2, "heard ring kept")
			T.equal(memory.heard[1].text, nil, "raw text dropped after 60 s")
			T.equal(memory.heard[1].kind, "greeting", "classification kept")
			T.equal(memory.heard[2].text, "fresh words", "fresh text kept")
			T.equal(#memory.said, 2)
			T.equal(#memory.activities, 2)
			T.equal(#memory.stuckSpots, 2)
			T.equal(Memory.lastVisit(memory, "shop"), 0)

			-- At 1000 s: entries older than 15 min are gone.
			Memory.forget(memory, 1000)
			T.equal(#memory.heard, 1)
			T.equal(memory.heard[1].fromId, "recent")
			T.equal(#memory.said, 1)
			T.equal(memory.said[1].lineId, "l2")
			T.equal(#memory.activities, 1)
			T.equal(memory.activities[1].name, "Pace")
			T.equal(#memory.stuckSpots, 1)
			T.equal(Memory.lastVisit(memory, "shop"), 0, "visits live 30 min")

			-- At 1900 s: the old visit is gone, the 500 s one stays until 2300.
			Memory.forget(memory, 1900)
			T.equal(Memory.lastVisit(memory, "shop"), nil)
			T.equal(Memory.lastVisit(memory, "bench"), 500)
			T.check(memory.entities.recent == nil, "recent now unseen too long")
		end)

		T.it("records visits, activities and explored sectors", function()
			local memory = Memory.new(0)
			T.equal(Memory.lastVisit(memory, "x"), nil)
			Memory.recordVisit(memory, "x", 10)
			Memory.recordVisit(memory, "x", 40)
			T.equal(Memory.lastVisit(memory, "x"), 40)
			T.equal(memory.visited.x.count, 2)

			Memory.recordActivity(memory, "Follow", "bob", 0, 30, "done")
			Memory.recordActivity(memory, "Follow", "amy", 40, 70, "abandoned")
			Memory.recordActivity(memory, "Wander", nil, 80, 90, "done")
			T.equal(Memory.lastActivityEnd(memory, "Follow"), 70, "latest of that name")
			T.equal(Memory.lastActivityEnd(memory, "Follow", "bob"), 30, "by target")
			T.equal(Memory.lastActivityEnd(memory, "Follow", "zed"), nil)
			T.equal(Memory.lastActivityEnd(memory, "Afk"), nil)

			T.equal(Memory.exploredCount(memory), 0)
			T.check(not Memory.isExplored(memory, "1:1"))
			Memory.markExplored(memory, "1:1")
			Memory.markExplored(memory, "1:1")
			Memory.markExplored(memory, "2:1")
			T.check(Memory.isExplored(memory, "1:1"))
			T.equal(Memory.exploredCount(memory), 2)
		end)

		T.it("sectorId floors into 16 stud cells", function()
			T.equal(Memory.sectorId(Vector3.new(0, 0, 0)), "0:0")
			T.equal(Memory.sectorId(Vector3.new(15.9, 50, 15.9)), "0:0")
			T.equal(Memory.sectorId(Vector3.new(16, 0, -1)), "1:-1")
			T.equal(Memory.sectorId(Vector3.new(-0.5, 0, 33)), "-1:2")
			T.equal(Memory.sectorId(Vector3.new(17, 0, 9), 8), "2:1")
			T.equal(Memory.sectorId(Vector3.new(17, 0, 9), 16), Memory.sectorId(Vector3.new(17, 0, 9)))
		end)

		T.it("knows when a target sits near a recent stuck spot", function()
			local memory = Memory.new(0)
			T.check(not Memory.nearRecentStuck(memory, Vector3.zero, 0), "empty")
			Memory.recordStuck(memory, Vector3.new(10, 0, 10), 100)
			T.check(Memory.nearRecentStuck(memory, Vector3.new(14, 0, 10), 100), "4 studs away")
			T.check(Memory.nearRecentStuck(memory, Vector3.new(16, 0, 10), 100), "6 studs is inclusive")
			T.check(not Memory.nearRecentStuck(memory, Vector3.new(17, 0, 10), 100), "7 studs away")
			T.check(Memory.nearRecentStuck(memory, Vector3.new(14, 0, 10), 400), "300 s later still")
			T.check(not Memory.nearRecentStuck(memory, Vector3.new(14, 0, 10), 401), "then forgotten")
			T.check(Memory.nearRecentStuck(memory, Vector3.new(17, 0, 10), 100, 8), "custom radius")
			T.check(Memory.nearRecentStuck(memory, Vector3.new(14, 0, 10), 700, nil, 900), "custom max age")
			T.check(not Memory.nearRecentStuck(memory, Vector3.new(14, 0, 10), 200, nil, 50), "short max age")
		end)
	end)

	T.describe("Reaction", function()
		local function event(kind, salience, expected, at)
			return { kind = kind, salience = salience, expected = expected, at = at or 0 }
		end

		T.it("never misses salience >= 0.95 and fires it immediately", function()
			local p = persona(10, { attention = 0 })
			local rng = Rng.new(11)
			local queue = Reaction.new()
			for i = 1, 200 do
				T.check(Reaction.push(queue, event("stuck", 0.95, false, i), i, p, "zoned", rng), "never missed")
			end
			T.equal(Reaction.pendingCount(queue), 200)
			for _, entry in queue.pending do
				T.equal(entry.at, entry.event.at, "delay 0")
			end
			T.equal(#Reaction.due(queue, 0), 0)
			T.equal(#Reaction.due(queue, 100), 100)
			T.equal(Reaction.pendingCount(queue), 100)
		end)

		T.it("misses a share of ordinary events that grows when inattentive, surprised or zoned", function()
			local p = persona(12, { attention = 0.5 })
			local function missShare(moodName, expected, attention, salt)
				local q = Reaction.new()
				local rng = Rng.new(salt)
				local pers = persona(12, { attention = attention })
				local missed = 0
				for _ = 1, 2000 do
					if not Reaction.push(q, event("entityJumped", 0.2, expected), 0, pers, moodName, rng) then
						missed += 1
					end
				end
				return missed / 2000
			end
			T.between(missShare("neutral", true, 0.5, 1), 0.1, 0.3, "attention 0.5 expected: 0.2")
			T.between(missShare("neutral", false, 0.5, 2), 0.25, 0.35, "unexpected: 0.3")
			T.between(missShare("zoned", true, 0.5, 3), 0.55, 0.65, "zoned: 0.6")
			T.between(missShare("zoned", false, 0, 4), 0.87, 0.93, "clamped at 0.9")
			T.between(missShare("neutral", true, 1, 5), 0.07, 0.13, "full attention: 0.1")
			T.near(Reaction.missChance(p, true, "neutral"), 0.2, 1e-9)
			T.near(Reaction.missChance(p, false, "neutral"), 0.3, 1e-9)
			T.near(Reaction.missChance(p, false, "zoned"), 0.9, 1e-9)
		end)

		T.it("delays unexpected events about 2.5x the expected ones and scales by mood", function()
			local p = persona(13, { reactionScale = 1 })
			local function meanDelay(expected, moodName, salt)
				local rng = Rng.new(salt)
				local total, n = 0, 3000
				local min = math.huge
				for _ = 1, n do
					local d = Reaction.delay(p, expected, moodName, rng)
					total += d
					min = math.min(min, d)
				end
				return total / n, min
			end
			local expectedMean, expectedMin = meanDelay(true, "neutral", 1)
			local unexpectedMean = meanDelay(false, "neutral", 2)
			T.between(expectedMean, 1.25, 1.55, `expected mean ~1.4 (0.6 + 0.8), got {expectedMean}`)
			T.between(unexpectedMean / expectedMean, 2.3, 2.7, "unexpected is 2.5x")
			T.check(expectedMin >= 0.15, "physiological floor")
			local zonedMean = meanDelay(true, "zoned", 3)
			T.between(zonedMean / expectedMean, 2.3, 2.7, "zoned reaction multiplier 2.5")
			local slow = persona(13, { reactionScale = 2 })
			local slowMean = 0
			local rng = Rng.new(4)
			for _ = 1, 3000 do
				slowMean += Reaction.delay(slow, true, "neutral", rng)
			end
			T.between(slowMean / 3000, 1.85, 2.15, "mu scales with reactionScale (1.2 + 0.8)")
			-- Through push: the queued time carries the delay.
			local q = Reaction.new()
			local pushRng = Rng.new(5)
			local pers = persona(13, { attention = 1 })
			local sum, count = 0, 0
			for _ = 1, 500 do
				if Reaction.push(q, event("chatHeard", 0.25, true), 10, pers, "neutral", pushRng) then
					count += 1
				end
			end
			for _, entry in q.pending do
				sum += entry.at - 10
			end
			T.between(sum / count, 1.0, 1.8, "pushed delays around 1.4 x reactionScale")
		end)

		T.it("keeps the queue ordered by time and pops in order", function()
			local p = persona(14, { attention = 1 })
			local rng = Rng.new(15)
			local queue = Reaction.new()
			-- Immediate events pushed at descending times land in ascending order.
			for _, t in { 30, 10, 20, 10, 5 } do
				Reaction.push(queue, event("stuck", 1, true, t), t, p, "neutral", rng)
			end
			local ats = {}
			for _, entry in queue.pending do
				table.insert(ats, entry.at)
			end
			T.equal(table.concat(ats, ","), "5,10,10,20,30")
			-- Interleave delayed events; whatever the delay, the list stays sorted.
			for i = 1, 40 do
				Reaction.push(queue, event("entityJumped", 0.3, i % 2 == 0, i), i, p, "neutral", rng)
			end
			for i = 2, #queue.pending do
				T.check(queue.pending[i - 1].at <= queue.pending[i].at, "sorted")
			end
			local total = Reaction.pendingCount(queue)
			local expectedEvents = {}
			for _, entry in queue.pending do
				if entry.at <= 12 then
					table.insert(expectedEvents, entry.event)
				end
			end
			local early = Reaction.due(queue, 12)
			T.equal(#early, #expectedEvents, "everything due by 12 is popped")
			for i, ev in early do
				T.check(ev == expectedEvents[i], "popped in due-time order")
			end
			T.check(#early >= 3, "the immediate ones at 5, 10, 10 are due")
			T.equal(Reaction.pendingCount(queue), total - #early)
			for _, entry in queue.pending do
				T.check(entry.at > 12, "only the later ones remain")
			end
			local rest = Reaction.due(queue, 1000)
			T.equal(#rest, total - #early)
			T.equal(Reaction.pendingCount(queue), 0)
			T.equal(#Reaction.due(queue, 2000), 0)
		end)
	end)

	T.describe("Session", function()
		T.it("moves through the phases in order, gated by the spawn ritual", function()
			local p = persona(20, { accountAge = 0.2, sessionLength = 900 })
			local s = Session.new(1000, p, Rng.new(21))
			T.equal(s.phase, "joining")
			T.equal(s.joinedAt, 1000)
			T.equal(s.leaveAt, 1900)
			T.between(s.orientUntil - 1000, 20, 300)
			T.check(not s.ritualDone)
			-- Time alone never ends joining.
			T.check(not Session.update(s, s.orientUntil + 5), "ritual gate")
			T.equal(s.phase, "joining")
			Session.finishRitual(s)
			T.check(Session.update(s, 1003), "ritual done")
			T.equal(s.phase, "orienting")
			T.check(not Session.update(s, s.orientUntil - 0.01))
			T.check(Session.update(s, s.orientUntil), "orientUntil reached")
			T.equal(s.phase, "settled")
			T.check(not Session.update(s, 1899))
			T.check(Session.update(s, 1900), "leaveAt reached")
			T.equal(s.phase, "leaving")
			T.check(not Session.update(s, 5000), "leaving waits for the Leave activity")
			Session.markGone(s)
			T.equal(s.phase, "gone")
			T.check(not Session.update(s, 6000))

			-- A late update chains joining -> orienting -> settled in one call.
			local late = Session.new(0, p, Rng.new(22))
			Session.finishRitual(late)
			T.check(Session.update(late, late.orientUntil + 1))
			T.equal(late.phase, "settled")
			-- Orienting can go straight to leaving once leaveAt has passed.
			local brief = Session.new(0, persona(20, { sessionLength = 60 }), Rng.new(23))
			Session.finishRitual(brief)
			Session.update(brief, 1)
			T.equal(brief.phase, "orienting")
			Session.update(brief, 60)
			T.equal(brief.phase, "leaving")
		end)

		T.it("veterans orient faster", function()
			local function meanOrient(age)
				local total = 0
				for seed = 1, 200 do
					local s = Session.new(0, persona(seed, { accountAge = age }), Rng.new(seed))
					T.between(s.orientUntil, 20, 300)
					total += s.orientUntil
				end
				return total / 200
			end
			local veteran, newcomer = meanOrient(0.9), meanOrient(0.1)
			T.between(veteran, 35, 75, `veteran median 45, mean {veteran}`)
			T.between(newcomer, 100, 170, `newcomer median 120, mean {newcomer}`)
			T.check(veteran < newcomer)
		end)

		T.it("shorten pulls leaveAt to 20..180 s out and leaveNow goes straight to leaving", function()
			local p = persona(24, { sessionLength = 3600 })
			for seed = 1, 100 do
				local s = Session.new(0, p, Rng.new(seed))
				Session.shorten(s, 500, Rng.new(seed + 1000))
				T.between(s.leaveAt - 500, 20, 180, "shortened")
			end
			local s = Session.new(0, p, Rng.new(1))
			Session.leaveNow(s)
			T.equal(s.phase, "leaving")
			Session.markGone(s)
			Session.leaveNow(s)
			T.equal(s.phase, "gone", "gone stays gone")
		end)

		T.it("phaseWeight table spot checks", function()
			T.equal(Session.phaseWeight("leaving", "Leave"), 50)
			T.equal(Session.phaseWeight("joining", "Afk"), 0)
			T.equal(Session.phaseWeight("settled", "Leave"), 0)
			T.equal(Session.phaseWeight("orienting", "VisitPoi"), 1.5)
			T.equal(Session.phaseWeight("orienting", "Explore"), 2.0)
			T.equal(Session.phaseWeight("settled", "Explore"), 0.6)
			T.equal(Session.phaseWeight("leaving", "ReturnToSpawn"), 2)
			T.equal(Session.phaseWeight("joining", "Wander"), 1)
			T.equal(Session.phaseWeight("orienting", "Afk"), 0.1)
			T.equal(Session.phaseWeight("leaving", "IdleStand"), 0.5)
			T.equal(Session.phaseWeight("joining", "Follow"), 0)
			T.equal(Session.phaseWeight("leaving", "JoinGroup"), 0.2)
			T.equal(Session.phaseWeight("settled", "Pace"), 1)
			T.equal(Session.phaseWeight("orienting", "FaceOff"), 0.5)
			T.equal(Session.phaseWeight("settled", "ReactProbe"), 1, "unlisted activity is neutral")
			T.equal(Session.phaseWeight("gone", "Wander"), 0, "gone does nothing")
		end)
	end)
end

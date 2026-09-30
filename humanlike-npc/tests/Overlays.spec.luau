return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local Personality = session.require(S.Mind.Personality)
	local SocialGuard = session.require(S.Mind.SocialGuard)
	local Overlays = session.require(S.Mind.Overlays)
	local Recency = session.require(S.Chat.Recency)
	local Safety = session.require(S.Chat.Safety)
	local ChatCorpus = session.require(S.Chat.ChatCorpus)

	local DT = 0.25

	-- One NPC's overlays with a player ("Zoe") and another NPC ("Kai") standing next to it. The
	-- persona is sampled, then its chat traits are pinned so the run is talkative on purpose.
	local function harness(seed, profileKind, overrides)
		local persona = Personality.sample(Rng.new(seed), { profileKind = profileKind or "pc" })
		persona.chattiness = 0.9
		persona.mirroring = 0.9
		persona.trolliness = 0
		for key, value in overrides or {} do
			persona[key] = value
		end
		local rng = Rng.new(seed + 1000)
		local h = {}
		h.persona = persona
		h.overlays = Overlays.new(rng:fork("overlays"), persona, 0)
		h.guard = SocialGuard.new()
		h.chat = {
			recency = Recency.new(),
			safety = Safety.new(),
			allow = function()
				return true
			end,
		}
		h.entities = {
			["p:1"] = {
				id = "p:1",
				kind = "player",
				position = Vector3.new(3, 0, 0),
				velocity = Vector3.new(0, 0, 0),
				displayName = "Zoe",
				username = "zoe_zoe",
			},
			["n:npc2"] = {
				id = "n:npc2",
				kind = "npc",
				position = Vector3.new(-3, 0, 0),
				velocity = Vector3.new(0, 0, 0),
				displayName = "Kai",
				username = "kai_kai",
			},
		}
		function h.ctx(now, events, moving, extra)
			local ctx = {
				now = now,
				dt = DT,
				rng = rng,
				persona = persona,
				me = {
					id = "n:npc1",
					position = Vector3.new(0, 0, 0),
					heading = Vector3.new(0, 0, -1),
					displayName = "Milo",
					username = "milo_plays",
				},
				moving = moving == true,
				onGround = true,
				mood = "social",
				phase = "settled",
				activity = "IdleStand",
				suppress = {},
				inGroup = false,
				groupMembers = {},
				playersWithin30 = 1,
				playersWithin100 = 2,
				nearbyName = "Zoe",
				entity = function(id)
					return h.entities[id]
				end,
				guard = h.guard,
				attachment = nil,
				chat = h.chat,
				events = events or {},
				wakeBurst = false,
				fellNearby = false,
			}
			for k, v in extra or {} do
				ctx[k] = v
			end
			return ctx
		end
		return h
	end

	-- The tags of the corpus line behind a said line's id ("category:text").
	local function tagsOf(lineId)
		local category, text = string.match(lineId, "^([^:]+):(.*)$")
		if not category then
			return {}
		end
		for _, line in ChatCorpus.byCategory(category) do
			if line.text == text then
				return line.tags or {}
			end
		end
		return {}
	end

	local function hasTag(tags, tag)
		for _, t in tags do
			if t == tag then
				return true
			end
		end
		return false
	end

	local function heard(now, subject, text, lineId)
		return {
			kind = "chatHeard",
			salience = 0.25,
			subject = subject,
			at = now,
			data = { text = text, lineId = lineId, position = Vector3.new(3, 0, 0), distance = 3 },
		}
	end

	T.describe("Overlays", function()
		T.it("player text is never echoed", function()
			local h = harness(7)
			local said, corpusEchoes = 0, 0
			local now = 0
			for tick = 1, 28800 do -- two hours at 4 Hz
				now = tick * DT
				local events = {}
				if tick % 80 == 0 then
					-- The player says the marker every 20 s, half the time naming the NPC.
					local text = if tick % 160 == 0 then "zzqx13" else "milo zzqx13"
					table.insert(events, heard(now, "p:1", text, nil))
				elseif tick % 80 == 40 then
					-- Another NPC's corpus line arrives with its lineId: the only echo source.
					table.insert(events, heard(now, "n:npc2", "lol", "reaction:lol"))
				elseif tick % 80 == 60 then
					-- Player bytes behind an id that names no corpus line, and behind a real one.
					table.insert(events, heard(now, "p:1", "zzqx13", "reaction:zzqx13"))
					table.insert(events, heard(now, "p:1", "zzqx13 lol", "reaction:bruh"))
				end
				local out = h.overlays:tick(h.ctx(now, events, false))
				for _, a in out.actions do
					if a.kind == "say" then
						said += 1
						T.check(not string.find(string.lower(a.text), "zzqx", 1, true), `player bytes echoed: {a.text}`)
						T.check(not string.find(a.text, "{", 1, true), `unfilled slot: {a.text}`)
						if string.sub(a.lineId, 1, 5) == "echo:" then
							corpusEchoes += 1
						end
					end
				end
			end
			T.check(said > 20, `expected a talkative run, got {said} lines`)
			T.check(corpusEchoes >= 1, "corpus lines heard from an NPC are echoed")
		end)

		T.it("typing action brackets a line", function()
			local h = harness(3, "pc", { chattiness = 0.1 }) -- no spontaneous lines
			local ctx0 = h.ctx(0, {}, false)
			h.overlays:forceLine(ctx0, "greeting", nil)
			T.check(h.overlays:hasPendingLine(), "a line is queued")
			local first = h.overlays:tick(ctx0)
			T.equal(#first.actions, 1)
			T.equal(first.actions[1].kind, "typing")
			T.equal(first.actions[1].on, true)
			T.equal(first.typing, true)
			T.check(h.overlays:isTyping(0))
			T.check(first.intent ~= nil and first.intent.kind == "freeze", "a keyboard NPC freezes while typing")
			T.equal(first.intent.variant, "still", "a standing NPC stands still")

			local ons, offs, says, offTick = 0, 0, 0, nil
			local now = 0
			for tick = 1, 480 do
				now = tick * DT
				local out = h.overlays:tick(h.ctx(now, {}, false))
				local sayIndex = nil
				for i, a in out.actions do
					if a.kind == "say" then
						says += 1
						sayIndex = i
					elseif a.kind == "typing" and a.on == true then
						ons += 1
					elseif a.kind == "typing" and a.on == false then
						offs += 1
						offTick = tick
						T.check(sayIndex ~= nil and i > sayIndex, "typing goes off right after the line is said")
						T.equal(out.typing, true, "the release delay keeps the body frozen a moment longer")
					end
				end
				if offs > 0 then
					break
				end
			end
			T.equal(ons, 0, "the indicator switched on once only")
			T.equal(offs, 1, "and off once")
			T.check(says >= 1 and says <= 4, `{says} lines for one forced line and its follow-ups`)
			T.check(not h.overlays:hasPendingLine())
			T.check(offTick ~= nil and offTick * DT >= 1.5, "nothing is said before the typing floor")
			-- The freeze lifts within the pinned resume window after the last line.
			local released = false
			for tick = offTick + 1, offTick + 12 do
				local out = h.overlays:tick(h.ctx(tick * DT, {}, false))
				T.equal(#out.actions, 0, "no more typing actions while idle")
				if not out.typing then
					released = true
					T.check(out.intent == nil or out.intent.kind ~= "freeze", "no freeze once released")
					break
				end
			end
			T.check(released, "released within 3 s of the line")
		end)

		T.it("a dropped line switches typing off without a say, and the guard is preferred over allow", function()
			local h = harness(5, "pc", { chattiness = 0.1 })
			local allowCalls, guardCalls = 0, 0
			h.chat.allow = function()
				allowCalls += 1
				return true
			end
			h.chat.guard = {
				allow = function(_, npcId, now, isReply)
					guardCalls += 1
					T.equal(npcId, "n:npc1")
					T.check(type(now) == "number")
					T.equal(isReply, true, "a probe answer counts as a reply")
					return false
				end,
			}
			local ctx0 = h.ctx(0, {}, false)
			h.overlays:forceLine(ctx0, "probe", "p:1")
			T.check(h.overlays:hasPendingLine())
			local first = h.overlays:tick(ctx0)
			T.equal(first.actions[1].kind, "typing")
			T.equal(first.actions[1].on, true)
			local offs, says = 0, 0
			for tick = 1, 240 do
				local out = h.overlays:tick(h.ctx(tick * DT, {}, false))
				for _, a in out.actions do
					if a.kind == "say" then
						says += 1
					elseif a.kind == "typing" and a.on == false then
						offs += 1
					end
				end
			end
			T.equal(says, 0, "the guard refused the line")
			T.equal(offs, 1, "typing still switched off")
			T.equal(guardCalls, 1)
			T.equal(allowCalls, 0, "allow is ignored when a guard is present")
		end)

		T.it("the typing plan drives the freeze intent while moving", function()
			local seen = { still = false, walkStraight = false, free = false }
			for seed = 20, 80 do
				local h = harness(seed, "pc", { chattiness = 0.1 })
				local ctx0 = h.ctx(0, {}, true)
				h.overlays:forceLine(ctx0, "greeting", nil)
				if not h.overlays:hasPendingLine() then
					continue
				end
				local plan = h.overlays.typingPlan
				local first = h.overlays:tick(ctx0)
				T.equal(first.typing, true)
				if plan.variant == "free" then
					seen.free = true
					T.check(first.intent == nil, "a free typist keeps walking")
				elseif plan.variant == "heldKey" then
					seen.walkStraight = true
					T.equal(first.intent.variant, "walkStraight", "the held key walks the body straight")
					T.near(first.intent.duration, h.overlays.freezeUntil, 1e-9)
					local later = h.overlays:tick(h.ctx(plan.duration + DT, {}, true))
					if later.typing then
						T.equal(later.intent.variant, "still", "then the body stands")
					end
				else
					seen.still = true
					T.equal(first.intent.variant, "still")
				end
				if seen.still and seen.walkStraight and seen.free then
					break
				end
			end
			T.check(seen.still and seen.walkStraight and seen.free, "all three variants appear across seeds")
		end)

		T.it("platformFreezes false keeps the body free while the line is typed", function()
			local h = harness(3, "pc", { chattiness = 0.1 })
			local ctx0 = h.ctx(0, {}, false, { platformFreezes = false })
			h.overlays:forceLine(ctx0, "greeting", nil)
			local first = h.overlays:tick(ctx0)
			T.equal(first.typing, true, "still typing")
			T.equal(first.intent, nil, "but no freeze intent")
			T.equal(first.actions[1].kind, "typing")
		end)

		T.it("a half-typed line is dropped half the time when a reaction interrupts", function()
			local dropped, n = 0, 200
			for seed = 1, n do
				local h = harness(seed + 300, "pc", { chattiness = 0.1 })
				h.overlays:forceLine(h.ctx(0, {}, false), "greeting", nil)
				T.check(h.overlays:hasPendingLine())
				local first = h.overlays:tick(h.ctx(DT, {}, false))
				T.equal(first.actions[1].kind, "typing")
				local out = h.overlays:tick(h.ctx(2 * DT, {}, false, { interrupted = true }))
				if not h.overlays:hasPendingLine() then
					dropped += 1
					T.check(not out.typing, "the freeze is lifted with the line")
					T.equal(out.actions[#out.actions].kind, "typing", "the indicator goes off")
					T.equal(out.actions[#out.actions].on, false)
				else
					T.equal(#out.actions, 0, "kept: nothing to report")
				end
			end
			T.between(dropped / n, 0.38, 0.62, `dropped share {dropped / n}`)
			-- Starting a ReactProbe counts as an interrupt too; an unrelated activity change does not.
			local viaProbe, viaOther = 0, 0
			for seed = 1, n do
				local h = harness(seed + 600, "pc", { chattiness = 0.1 })
				h.overlays:forceLine(h.ctx(0, {}, false), "greeting", nil)
				h.overlays:tick(h.ctx(DT, {}, false, { activity = "Wander" }))
				h.overlays:tick(h.ctx(2 * DT, {}, false, { activity = "ReactProbe" }))
				if not h.overlays:hasPendingLine() then
					viaProbe += 1
				end
				local g = harness(seed + 900, "pc", { chattiness = 0.1 })
				g.overlays:forceLine(g.ctx(0, {}, false), "greeting", nil)
				g.overlays:tick(g.ctx(DT, {}, false, { activity = "Wander" }))
				g.overlays:tick(g.ctx(2 * DT, {}, false, { activity = "VisitPoi" }))
				if not g.overlays:hasPendingLine() then
					viaOther += 1
				end
			end
			T.between(viaProbe / n, 0.38, 0.62, `dropped on ReactProbe {viaProbe / n}`)
			T.equal(viaOther, 0, "an ordinary activity change keeps the line")
		end)

		T.it("pc and mobile NPCs never emit face while idle", function()
			local function faces(profileKind, seed)
				local h = harness(seed, profileKind, { chattiness = 0.1, jumpiness = 0.5, emoteHabit = 0 })
				local count = 0
				for tick = 1, 2400 do -- 600 s idle, social mood (sweeps allowed)
					local out = h.overlays:tick(h.ctx(tick * DT, {}, false))
					if out.intent and out.intent.kind == "face" then
						count += 1
					end
				end
				return count
			end
			for _, kind in { "pc", "mobile", "console" } do
				for seed = 1, 3 do
					T.equal(faces(kind, seed), 0, `{kind} seed {seed} turned in place`)
				end
			end
			T.check(faces("pcShiftLock", 1) >= 5, "a shift-lock player sweeps")
		end)

		T.it("cameraStyle stretches the sweep gap for shift-lock profiles only", function()
			local function sweeps(style, profileKind)
				local h =
					harness(31, profileKind, { chattiness = 0.1, jumpiness = 0, emoteHabit = 0, cameraStyle = style })
				local starts = 0
				local wasFacing = false
				for tick = 1, 9600 do -- 40 min idle
					local out = h.overlays:tick(h.ctx(tick * DT, {}, false))
					local facing = out.intent ~= nil and out.intent.kind == "face"
					if facing and not wasFacing then
						starts += 1
					end
					wasFacing = facing
				end
				return starts
			end
			local sweeper, locked, twitchy =
				sweeps("sweeper", "pcShiftLock"), sweeps("locked", "pcShiftLock"), sweeps("twitchy", "pcShiftLock")
			T.check(twitchy > sweeper and sweeper > locked, `twitchy {twitchy} > sweeper {sweeper} > locked {locked}`)
			T.between(sweeper / locked, 2.4, 5, `sweeper / locked {sweeper / locked} (gap x0.7 vs x2.5)`)
			T.equal(sweeps("twitchy", "pc"), 0, "no style ever makes a third-person body turn")
		end)

		T.it("reading pauses a keyboard walker", function()
			local function windows(profileKind, seed)
				local h = harness(seed, profileKind, { chattiness = 0.1, jumpiness = 0, emoteHabit = 0 })
				local pauses, freezes = 0, 0
				local now = 0
				for _ = 1, 200 do
					-- A reading window of 2 s while walking, then 3 s of plain walking.
					for i = 1, 20 do
						now += DT
						local out = h.overlays:tick(h.ctx(now, {}, true, { reading = i <= 8 }))
						for _, a in out.actions do
							if a.kind == "look" and a.name == "readingPause" then
								pauses += 1
							end
						end
						if out.intent and out.intent.kind == "freeze" and out.intent.variant == "still" then
							freezes += 1
						end
					end
				end
				return pauses, freezes
			end
			local pcPauses, pcFreezes = windows("pc", 41)
			T.between(pcPauses / 200, 0.22, 0.38, `pc pause share {pcPauses / 200}`)
			T.check(pcFreezes >= pcPauses * 4, "each pause holds the body for a second or more")
			local mobilePauses = windows("mobile", 42)
			T.check(mobilePauses / 200 <= 0.10, `mobile pause share {mobilePauses / 200}`)
			-- Reading while standing still is not a pause.
			local h = harness(43, "pc", { chattiness = 0.1, jumpiness = 0, emoteHabit = 0 })
			local standing = 0
			for tick = 1, 800 do
				local out = h.overlays:tick(h.ctx(tick * DT, {}, false, { reading = tick % 20 < 8 }))
				for _, a in out.actions do
					if a.kind == "look" then
						standing += 1
					end
				end
			end
			T.equal(standing, 0)
		end)

		T.it("step-away from a close stranger", function()
			local function run(friend, distance, seconds)
				local h = harness(51, "pc", { chattiness = 0.1, jumpiness = 0, emoteHabit = 0, personalSpace = 5 })
				local nearest = { id = "p:1", distance = distance, dir = Vector3.new(1, 0, 0), friend = friend }
				local steps = {}
				for tick = 1, math.floor(seconds / DT) do
					local out = h.overlays:tick(h.ctx(tick * DT, {}, false, { nearest = nearest }))
					if out.intent and out.intent.kind == "step" then
						table.insert(steps, { at = tick * DT, intent = out.intent })
					end
				end
				return steps
			end
			local stranger = run(false, 2, 4)
			T.equal(#stranger, 1, "one step")
			T.check(stranger[1].at >= 3, `after 3 s (at {stranger[1].at})`)
			T.check(stranger[1].intent.dir:Dot(Vector3.new(1, 0, 0)) < -0.9, "directly away")
			T.between(stranger[1].intent.duration * 16, 1, 2, "one to two studs at walking speed")
			T.equal(#run(true, 2, 4), 0, "a friend may stand close")
			T.equal(#run(false, 6, 4), 0, "outside the personal space")
			local long = run(false, 2, 20)
			T.check(#long >= 2 and #long <= 3, `at most once per 8 s over 20 s ({#long})`)
			for i = 2, #long do
				T.check(long[i].at - long[i - 1].at >= 8, "8 s apart")
			end
		end)

		T.it("rude lines go to a player at most once, and never in a social mood", function()
			local rudeTotal, seedsWithTwo = 0, 0
			for seed = 1, 120 do
				local h = harness(seed + 1200, "pc", { chattiness = 0.1, trolliness = 1, rudenessCap = 1 })
				local rudeToZoe = 0
				local now = 0
				for _ = 1, 6 do
					-- Reset the direct-message guard so a new forced line to Zoe is allowed.
					h.guard:saidTo("n:npc2", now, true)
					h.guard:heardFrom("p:1", "ok", now, false)
					h.overlays:forceLine(h.ctx(now, {}, false, { mood = "bored" }), "reaction", "p:1")
					for _ = 1, 200 do
						now += DT
						local out = h.overlays:tick(h.ctx(now, {}, false, { mood = "bored" }))
						for _, a in out.actions do
							if a.kind == "say" and a.target == "p:1" and hasTag(tagsOf(a.lineId), "rude") then
								rudeToZoe += 1
							end
						end
						if not h.overlays:hasPendingLine() then
							break
						end
					end
				end
				rudeTotal += rudeToZoe
				if rudeToZoe > 1 then
					seedsWithTwo += 1
				end
				if rudeToZoe > 0 then
					T.check(h.guard:wasRudeTo("p:1"), "the guard recorded it")
				end
			end
			T.check(rudeTotal >= 10, `rude lines do appear for a troll ({rudeTotal})`)
			T.equal(seedsWithTwo, 0, "never twice at the same person")
		end)

		T.it("dialect-tagged lines stay with their dialect and right lines come once per 10 min", function()
			local h = harness(8)
			local lastRightAt = nil
			local said = 0
			for tick = 1, 28800 do -- two hours at 4 Hz, talkative
				local now = tick * DT
				local out = h.overlays:tick(h.ctx(now, {}, false))
				for _, a in out.actions do
					if a.kind == "say" then
						said += 1
						local tags = tagsOf(a.lineId)
						for _, d in { "kid", "teen", "older" } do
							if hasTag(tags, d) then
								T.equal(d, h.persona.dialect, `a {d} line from a {h.persona.dialect}`)
							end
						end
						if hasTag(tags, "right") then
							if lastRightAt then
								T.check(now - lastRightAt >= 600, `right lines {now - lastRightAt} s apart`)
							end
							lastRightAt = now
						end
					end
				end
			end
			T.check(said > 20, `talkative run ({said})`)
		end)
	end)
end

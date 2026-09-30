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
		function h.ctx(now, events, moving)
			return {
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
		end
		return h
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
	end)
end

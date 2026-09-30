return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Personality = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Personality)
	local Memory = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Memory)
	local Senses = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Senses)
	local Spatial = session.require(session.game.ServerStorage.HumanlikeNpc.World.Spatial)

	local function entity(id, x, y, z, opts)
		local o = opts or {}
		return {
			id = id,
			kind = o.kind or "player",
			position = Vector3.new(x, y, z),
			velocity = o.velocity or Vector3.zero,
			yaw = o.yaw or 0,
			displayName = id,
			jumpedAt = o.jumpedAt,
			emoteAt = o.emoteAt,
			emoteName = o.emoteName,
		}
	end

	local function ids(list)
		local out = {}
		for i, e in list do
			out[i] = e.id
		end
		return table.concat(out, ",")
	end

	T.describe("Spatial", function()
		T.it("groups form by union-find at 8 studs among slow entities and dissolve", function()
			local spatial = Spatial.new()
			local fast = Vector3.new(10, 0, 0)
			spatial:update({
				entity("a", 0, 0, 0),
				entity("b", 7, 0, 0),
				entity("c", 14, 0, 0), -- 14 from a, chained through b
				entity("d", 30, 0, 0), -- alone
				entity("e", 100, 0, 0, { velocity = fast }), -- running: not a candidate
				entity("f", 107, 0, 0),
				entity("g", 200, 0, 0, { velocity = fast }), -- running but hugging h: candidate
				entity("h", 205, 0, 0),
			}, 0)
			local groups = spatial:groups()
			T.equal(#groups, 2, "two groups")
			T.equal(table.concat(groups[1].members, ","), "a,b,c")
			T.equal(table.concat(groups[2].members, ","), "g,h")
			T.near(groups[1].center.X, 7, 1e-6)
			T.near(groups[1].radius, 7, 1e-6)
			T.equal(groups[1].age, 0)
			T.equal(spatial:groupOf("b").id, groups[1].id)
			T.equal(spatial:groupOf("d"), nil)
			T.equal(spatial:groupOf("e"), nil)

			-- Within 2 s the entities are stored but the groups are not recomputed.
			spatial:update({ entity("a", 0, 0, 0), entity("c", 14, 0, 0) }, 1)
			T.equal(#spatial:groups(), 2, "not recomputed yet")
			T.equal(spatial:get("b"), nil, "but entities are current")
			T.equal(spatial:groups()[1].age, 1, "age still advances")

			-- b walked off: a and c are 14 apart, the group dissolves.
			spatial:update({ entity("a", 0, 0, 0), entity("c", 14, 0, 0) }, 2)
			T.equal(#spatial:groups(), 0, "dissolved")
			T.equal(spatial:groupOf("a"), nil)
		end)

		T.it("group identity persists while at least half the members remain, and age grows", function()
			local spatial = Spatial.new()
			local function ring(names, offset)
				local list = {}
				for i, name in names do
					table.insert(list, entity(name, (offset or 0) + i * 5, 0, 0))
				end
				return list
			end
			spatial:update(ring({ "a", "b", "c", "d" }), 0)
			local first = spatial:groups()[1]
			T.equal(first.id, 1)
			-- d leaves: 3 of 4 remain.
			spatial:update(ring({ "a", "b", "c" }), 2)
			local g = spatial:groups()[1]
			T.equal(g.id, 1, "same group")
			T.equal(g.age, 2)
			T.equal(g.createdAt, 0)
			-- a and b leave, e joins: c is 1 of 2 = 50%, still the same group.
			spatial:update(ring({ "c", "e" }), 4)
			g = spatial:groups()[1]
			T.equal(g.id, 1, "half the members still count")
			T.equal(g.age, 4)
			-- c leaves, f g h join e: 1 of 4, a new group.
			spatial:update(ring({ "e", "f", "g", "h" }), 6)
			g = spatial:groups()[1]
			T.check(g.id ~= 1, "new identity")
			T.equal(g.age, 0)
			T.equal(g.createdAt, 6)

			-- A split: the remnant listed first keeps the identity, the other is new.
			local s2 = Spatial.new()
			s2:update(ring({ "a", "b", "c", "d" }), 0)
			s2:update({ entity("a", 0, 0, 0), entity("b", 5, 0, 0), entity("c", 50, 0, 0), entity("d", 55, 0, 0) }, 2)
			local groups = s2:groups()
			T.equal(#groups, 2)
			T.equal(groups[1].id, 1)
			T.equal(table.concat(groups[1].members, ","), "a,b")
			T.equal(groups[2].id, 2)
			T.equal(groups[2].age, 0)
		end)

		T.it("near() sorts by distance and honours the exclusion", function()
			local spatial = Spatial.new()
			spatial:update({
				entity("far", 50, 0, 0),
				entity("mid", 0, 0, 10),
				entity("close", 3, 0, 0),
				entity("me", 0, 0, 0),
				entity("out", 200, 0, 0),
			}, 0)
			T.equal(ids(spatial:near(Vector3.zero, 100, "me")), "close,mid,far")
			T.equal(ids(spatial:near(Vector3.zero, 100)), "me,close,mid,far")
			T.equal(ids(spatial:near(Vector3.zero, 5, "me")), "close")
			T.equal(#spatial:near(Vector3.new(1000, 0, 0), 10), 0)
			T.equal(spatial:get("mid").position.Z, 10)
			T.equal(spatial:get("nobody"), nil)
		end)
	end)

	T.describe("Senses", function()
		local function make(seed, profileKind)
			local persona = Personality.sample(Rng.new(seed), { profileKind = profileKind or "pc" })
			return Senses.new(Rng.new(seed + 1000), persona), Memory.new(0)
		end

		local function me(x, z, hx, hz, moving)
			return {
				id = "me",
				position = Vector3.new(x, 0, z),
				heading = Vector3.new(hx or 0, 0, hz or -1),
				moving = moving or false,
				velocity = Vector3.zero,
			}
		end

		local function input(who, entities, now, dt, extra)
			local inp = { me = who, entities = entities or {}, chats = {}, groups = {}, now = now or 0, dt = dt or 0.1 }
			for k, v in extra or {} do
				inp[k] = v
			end
			return inp
		end

		local function only(events, kind)
			local found = {}
			for _, ev in events do
				if ev.kind == kind then
					table.insert(found, ev)
				end
			end
			return found
		end

		T.it("sees inside the 120 degree cone and, about 15% of the time, what is behind", function()
			local senses, memory = make(1)
			local front = senses:step(input(me(0, 0), { entity("front", 0, 0, -10) }), memory)
			T.equal(#only(front, "entityAppeared"), 1, "straight ahead")
			T.equal(only(front, "entityAppeared")[1].expected, true)
			T.near(only(front, "entityAppeared")[1].salience, 0.3, 1e-6)
			T.equal(only(front, "entityAppeared")[1].subject, "front")
			-- 55 degrees off is still inside a 120 degree cone.
			local edge = senses:step(
				input(me(0, 0), { entity("edge", 10 * math.sin(math.rad(55)), 0, -10 * math.cos(math.rad(55))) }),
				memory
			)
			T.equal(#only(edge, "entityAppeared"), 1, "55 degrees off")

			local seenSteps, n = 0, 4000
			for i = 1, n do
				senses:step(input(me(0, 0), { entity("side", 10, 0, 0) }, i * 2, 2), memory)
				if senses.visible.side then
					seenSteps += 1
				end
			end
			T.between(seenSteps / n, 0.11, 0.19, `behind awareness share {seenSteps / n}`)
		end)

		T.it("respects the occlusion callback within the raycast budget, keeping the last verdict", function()
			local senses, memory = make(2)
			local calls, blocked = 0, true
			local function occlusion(from, to)
				calls += 1
				T.near(from.Y, 1.5, 1e-6, "eye height")
				T.near(to.Y, 1.5, 1e-6, "their eye height")
				return blocked
			end
			local a = entity("a", 0, 0, -10)
			local out =
				senses:step(input(me(0, 0), { a }, 0, 0.1, { occlusion = occlusion, raycastBudget = 4 }), memory)
			T.equal(calls, 1)
			T.equal(#out, 0, "behind a wall: nothing")
			T.equal(senses.visible.a, false)
			blocked = false
			out = senses:step(input(me(0, 0), { a }, 0.1, 0.1, { occlusion = occlusion, raycastBudget = 0 }), memory)
			T.equal(calls, 1, "no budget, no ray")
			T.equal(senses.visible.a, false, "previous verdict kept")
			T.equal(#out, 0)
			out = senses:step(input(me(0, 0), { a }, 0.2, 0.1, { occlusion = occlusion, raycastBudget = 1 }), memory)
			T.equal(calls, 2)
			T.equal(#only(out, "entityAppeared"), 1, "now seen")
			blocked = true
			senses:step(input(me(0, 0), { a }, 0.3, 0.1, { occlusion = occlusion, raycastBudget = 0 }), memory)
			T.equal(senses.visible.a, true, "still seen until a ray says otherwise")
			-- Two entities, budget one: exactly one ray per step, the other keeps its verdict.
			local before = calls
			local b = entity("b", 2, 0, -10)
			senses:step(input(me(0, 0), { a, b }, 0.4, 0.1, { occlusion = occlusion, raycastBudget = 1 }), memory)
			T.equal(calls - before, 1)
			T.equal(senses.visible.a, false, "a got the ray")
			T.equal(senses.visible.b, false, "b was never checked: not seen yet")
		end)

		T.it("entityAppeared once, again after 30 s unseen, entityLeft after 3 s, attachment bonus", function()
			local senses, memory = make(3)
			local blocked = false
			local function occlusion()
				return blocked
			end
			local a = entity("a", 0, 0, -10)
			local appeared, left = 0, 0
			for t = 0, 60 do
				-- hidden 2..9 (short gap) and 11..41 (long gap)
				blocked = (t >= 2 and t <= 9) or (t >= 11 and t <= 41)
				local out = senses:step(input(me(0, 0), { a }, t, 1, { occlusion = occlusion }), memory)
				local app, lft = #only(out, "entityAppeared"), #only(out, "entityLeft")
				appeared += app
				left += lft
				if app > 0 then
					T.check(t == 0 or t == 42, `appeared at {t}`)
				end
				if lft > 0 then
					T.check(t == 5 or t == 14, `left at {t}`)
					T.near(only(out, "entityLeft")[1].salience, 0.1, 1e-6)
				end
			end
			T.equal(appeared, 2)
			T.equal(left, 2)

			-- Walking out of the near list entirely also counts as leaving, once.
			local s2, m2 = make(4)
			s2:step(input(me(0, 0), { entity("b", 0, 0, -5) }, 0, 1), m2)
			local gone = 0
			for t = 1, 10 do
				gone += #only(s2:step(input(me(0, 0), {}, t, 1), m2), "entityLeft")
			end
			T.equal(gone, 1)

			local s3, m3 = make(5)
			local out = s3:step(input(me(0, 0), { entity("buddy", 0, 0, -5) }), m3, "buddy")
			T.near(only(out, "entityAppeared")[1].salience, 0.6, 1e-6, "attachment bonus")
		end)

		T.it("entityJumped only within 20 studs and 0.5 s, once per jump; emotes within 25", function()
			local senses, memory = make(6)
			local jumper = entity("j", 0, 0, -10, { jumpedAt = 0 })
			local out = senses:step(input(me(0, 0), { jumper }, 0.2, 0.1), memory)
			T.equal(#only(out, "entityJumped"), 1)
			T.near(only(out, "entityJumped")[1].salience, 0.2, 1e-6)
			out = senses:step(input(me(0, 0), { jumper }, 0.3, 0.1), memory)
			T.equal(#only(out, "entityJumped"), 0, "same jump, not twice")
			jumper.jumpedAt = 0.4
			out = senses:step(input(me(0, 0), { jumper }, 1.0, 0.1), memory)
			T.equal(#only(out, "entityJumped"), 0, "stale jump")
			local farJumper = entity("f", 0, 0, -25, { jumpedAt = 1.0 })
			out = senses:step(input(me(0, 0), { farJumper }, 1.1, 0.1), memory)
			T.equal(#only(out, "entityJumped"), 0, "too far")
			local dancer = entity("d", 0, 0, -22, { emoteAt = 1.2, emoteName = "dance" })
			local farDancer = entity("e", 0, 0, -30, { emoteAt = 1.2, emoteName = "dance" })
			out = senses:step(input(me(0, 0), { dancer, farDancer }, 1.3, 0.1), memory)
			T.equal(#only(out, "entityEmoted"), 1)
			T.equal(only(out, "entityEmoted")[1].subject, "d")
			T.equal(only(out, "entityEmoted")[1].data.emote, "dance")
		end)

		T.it("hears chat within 100 studs, or anything while reading", function()
			local senses, memory = make(7)
			local chats = {
				{ fromId = "p1", text = "hi", position = Vector3.new(50, 0, 0), at = 0 },
				{ fromId = "p2", text = "yo", position = Vector3.new(150, 0, 0), at = 0 },
				{ fromId = "me", text = "mine", position = Vector3.new(0, 0, 0), at = 0 },
			}
			local out = senses:step(input(me(0, 0), {}, 0, 0.1, { chats = chats }), memory)
			local heard = only(out, "chatHeard")
			T.equal(#heard, 1)
			T.equal(heard[1].subject, "p1")
			T.equal(heard[1].data.text, "hi")
			T.near(heard[1].data.distance, 50, 1e-6)
			T.near(heard[1].salience, 0.25, 1e-6)
			T.check(not senses:isReading(0))
			senses.readingUntil = 10
			T.check(senses:isReading(5))
			out = senses:step(input(me(0, 0), {}, 5, 0.1, { chats = chats }), memory)
			T.equal(#only(out, "chatHeard"), 2, "reading the window catches the far one too")
			T.check(not senses:isReading(10))
		end)

		T.it("reading windows open at about 0.12/min on pc with 6 chats/min, rarely on mobile", function()
			local function windows(seed, profileKind)
				local senses, memory = make(seed, profileKind)
				local count, wasReading = 0, false
				local hours = 20
				for t = 0, hours * 3600 do
					local chats = if t % 10 == 0
						then { { fromId = "p", text = "lol", position = Vector3.new(10, 0, 0), at = t } }
						else {}
					senses:step(input(me(0, 0), {}, t, 1, { chats = chats }), memory)
					local reading = senses:isReading(t + 1)
					if reading and not wasReading then
						count += 1
					end
					wasReading = reading
				end
				return count / (hours * 60)
			end
			local pc = windows(8, "pc")
			local mobile = windows(9, "mobile")
			T.between(pc, 0.08, 0.17, `pc rate/min {pc}`)
			T.between(mobile, 0.02, 0.065, `mobile rate/min {mobile}`)
			T.check(mobile < pc / 2, "mobile reads far less")
		end)

		T.it("followed fires after 5 s behind me and 15 studs walked, not before, with a 30 s cooldown", function()
			local senses, memory = make(10)
			local first, second = nil, nil
			local dt = 0.1
			for i = 0, 450 do
				local t = i * dt
				local x = 4 * t
				local follower = entity("f", x - 5, 0, 0, { velocity = Vector3.new(4, 0, 0) })
				local out = senses:step(input(me(x, 0, 1, 0, true), { follower }, t, dt), memory)
				local ev = only(out, "followed")
				if #ev > 0 then
					T.equal(ev[1].subject, "f")
					T.equal(ev[1].expected, false)
					T.near(ev[1].salience, 0.5, 1e-6)
					if not first then
						first = t
					elseif not second then
						second = t
					else
						T.check(false, `third event at {t}`)
					end
				end
			end
			T.check(first ~= nil, "followed fired")
			T.between(first, 5, 5.2, `first at {first}`)
			T.check(second ~= nil, "fired again after the cooldown")
			T.between(second, 35, 35.3, `second at {second}`)

			-- Behind me for ages while I stand still: never.
			local s2, m2 = make(11)
			for i = 0, 200 do
				local out = s2:step(input(me(0, 0, 1, 0), { entity("f", -5, 0, 0) }, i * dt, dt), m2)
				T.equal(#only(out, "followed"), 0, "no walking, no following")
			end
			-- Someone ahead of me is not following.
			local s3, m3 = make(12)
			for i = 0, 100 do
				local t = i * dt
				local out = s3:step(input(me(4 * t, 0, 1, 0, true), { entity("g", 4 * t + 5, 0, 0) }, t, dt), m3)
				T.equal(#only(out, "followed"), 0, "ahead is not behind")
			end
		end)

		T.it("two followers raise the salience to 0.7", function()
			local senses, memory = make(13)
			local dt = 0.1
			local events = {}
			for i = 0, 60 do
				local t = i * dt
				local x = 4 * t
				local out = senses:step(
					input(me(x, 0, 1, 0, true), {
						entity("f1", x - 5, 0, 1),
						entity("f2", x - 6, 0, -1),
					}, t, dt),
					memory
				)
				for _, ev in only(out, "followed") do
					table.insert(events, ev)
				end
			end
			T.equal(#events, 2)
			T.near(events[1].salience, 0.7, 1e-6)
			T.near(events[2].salience, 0.7, 1e-6)
			T.check(events[1].subject ~= events[2].subject)
		end)

		T.it("stared needs 3 s of a still entity facing me at 3..6 studs, with a 45 s cooldown", function()
			local senses, memory = make(14)
			local starer = entity("s", 0, 0, -4, { yaw = math.pi }) -- looks toward +Z, at me
			local times = {}
			local dt = 0.5
			for i = 0, 100 do
				local t = i * dt
				local out = senses:step(input(me(0, 0), { starer }, t, dt), memory)
				for _, ev in only(out, "stared") do
					T.equal(ev.expected, false)
					T.near(ev.salience, 0.4, 1e-6)
					T.equal(ev.subject, "s")
					table.insert(times, t)
				end
			end
			T.equal(#times, 2, `stared at {table.concat(times, ",")}`)
			T.equal(times[1], 3)
			T.equal(times[2], 48)

			local function never(e, why)
				local s, m = make(15)
				for i = 0, 20 do
					T.equal(#only(s:step(input(me(0, 0), { e }, i * dt, dt), m), "stared"), 0, why)
				end
			end
			never(entity("away", 0, 0, -4, { yaw = 0 }), "facing away")
			never(entity("far", 0, 0, -8, { yaw = math.pi }), "too far")
			never(entity("close", 0, 0, -2, { yaw = math.pi }), "too close")
			never(entity("moving", 0, 0, -4, { yaw = math.pi, velocity = Vector3.new(2, 0, 0) }), "moving")
		end)

		T.it("onHead needs 1 s within 2 studs horizontally and 3.5..6.5 above", function()
			local senses, memory = make(16)
			local dt = 0.25
			local times = {}
			for i = 0, 8 do
				local out = senses:step(input(me(0, 0), { entity("h", 0.5, 5, 0) }, i * dt, dt), memory)
				for _, ev in only(out, "onHead") do
					T.near(ev.salience, 0.5, 1e-6)
					table.insert(times, i * dt)
				end
			end
			T.equal(#times, 1)
			T.equal(times[1], 1)
			local function never(e, why)
				local s, m = make(17)
				for i = 0, 8 do
					T.equal(#only(s:step(input(me(0, 0), { e }, i * dt, dt), m), "onHead"), 0, why)
				end
			end
			never(entity("beside", 3, 5, 0), "too far sideways")
			never(entity("high", 0, 8, 0), "too high")
			never(entity("low", 0, 2, 0), "too low")
		end)

		T.it("bumped escalates on the third bump in 30 s and rests 5 s between bumps", function()
			local senses, memory = make(18)
			local near = { entity("n", 2, 0, 0) }
			local function bump(t, jump, entities)
				local out = senses:step(
					input(me(0, 0), entities or near, t, 0.1, { locomotion = { velocityJump = jump } }),
					memory
				)
				return only(out, "bumped")
			end
			local first = bump(0, 8)
			T.near(first[1].salience, 0.2, 1e-6)
			T.equal(first[1].subject, "n", "the nearest entity is the subject")
			T.equal(#bump(1, 8), 0, "cooldown")
			T.near(bump(6, 8)[1].salience, 0.2, 1e-6)
			local third = bump(12, 8)
			T.near(third[1].salience, 0.5, 1e-6, "third in 30 s")
			T.equal(third[1].data.count, 3)
			T.equal(#bump(13, 8), 0, "cooldown after the third too")
			T.near(bump(40, 8)[1].salience, 0.2, 1e-6, "window passed")
			T.equal(#bump(50, 5), 0, "small change")
			T.equal(#bump(60, 8, { entity("far", 6, 0, 0) }), 0, "nobody close")
			T.equal(#bump(70, 8, {}), 0, "nobody at all")
		end)

		T.it("blocked comes from locomotion.blockedBy with an 8 s cooldown per blocker", function()
			local senses, memory = make(19)
			local function blocked(t, who)
				return only(
					senses:step(input(me(0, 0), {}, t, 0.1, { locomotion = { blockedBy = who } }), memory),
					"blocked"
				)
			end
			local first = blocked(0, "p1")
			T.equal(#first, 1)
			T.equal(first[1].subject, "p1")
			T.near(first[1].salience, 0.6, 1e-6)
			T.equal(#blocked(4, "p1"), 0)
			T.equal(#blocked(4.5, "p2"), 1, "another blocker")
			T.equal(#blocked(8, "p1"), 1)
			T.equal(#blocked(9, nil), 0)
		end)

		T.it("groupNearby fires once per group id for fresh groups of 3+ within 40 studs", function()
			local senses, memory = make(20)
			local function group(id, size, x, createdAt)
				local members = {}
				for i = 1, size do
					members[i] = `m{i}`
				end
				return {
					id = id,
					members = members,
					center = Vector3.new(x, 0, 0),
					radius = 4,
					age = 0,
					createdAt = createdAt,
				}
			end
			local function step(t, groups)
				return only(senses:step(input(me(0, 0), {}, t, 0.1, { groups = groups }), memory), "groupNearby")
			end
			local out = step(5, { group(1, 3, 20, 4), group(2, 2, 10, 4), group(3, 3, 60, 4), group(4, 4, 10, -10) })
			T.equal(#out, 1)
			T.equal(out[1].data.groupId, 1)
			T.near(out[1].salience, 0.3, 1e-6)
			T.equal(#step(6, { group(1, 3, 20, 4) }), 0, "once per id")
			T.equal(#step(7, { group(5, 3, 30, 6), group(1, 3, 20, 4) }), 1, "a new id")
		end)

		T.it("chatHeard carries the line id of a corpus line and marks lines naming me", function()
			local senses, memory = make(21)
			local who = me(0, 0)
			who.displayName = "Milo"
			who.username = "milo_plays"
			local chats = {
				{ fromId = "n:npc2", text = "lol", position = Vector3.new(5, 0, 0), at = 0, lineId = "reaction:lol" },
				{ fromId = "p1", text = "milo come here", position = Vector3.new(5, 0, 0), at = 0 },
			}
			local heard = only(senses:step(input(who, {}, 0, 0.1, { chats = chats }), memory), "chatHeard")
			T.equal(#heard, 2)
			T.equal(heard[1].data.lineId, "reaction:lol")
			T.equal(heard[1].data.named, false)
			T.equal(heard[2].data.lineId, nil, "a player's line has no corpus id")
			T.equal(heard[2].data.named, true)
			T.equal(heard[2].data.text, "milo come here")
		end)

		T.it("attentionOff drops everything but named lines", function()
			local function scene(attentionOff)
				local senses, memory = make(22)
				local who = me(0, 0)
				who.displayName = "Milo"
				who.username = "milo_plays"
				local starer = entity("s", 0, 0, -4, { yaw = math.pi }) -- still, facing me, 4 studs
				local jumper = entity("j", 3, 0, -6, { jumpedAt = 0 })
				local rider = entity("r", 0.5, 5, 0)
				local kinds = {}
				local dt = 0.5
				for i = 0, 12 do
					local t = i * dt
					jumper.jumpedAt = t
					local chats = if i == 4
						then {
							{ fromId = "p1", text = "hi everyone", position = Vector3.new(5, 0, 0), at = t },
							{ fromId = "p1", text = "hey milo u there", position = Vector3.new(5, 0, 0), at = t },
						}
						else {}
					local groups = {
						{
							id = 9,
							members = { "a", "b", "c" },
							center = Vector3.new(10, 0, 0),
							radius = 4,
							age = 0,
							createdAt = t,
						},
					}
					local out = senses:step(
						input(who, { starer, jumper, rider }, t, dt, {
							chats = chats,
							groups = groups,
							attentionOff = attentionOff,
							locomotion = { blockedBy = "s", velocityJump = 8 },
						}),
						memory
					)
					for _, ev in out do
						kinds[ev.kind] = (kinds[ev.kind] or 0) + 1
						if attentionOff then
							T.equal(ev.kind, "chatHeard", `leaked {ev.kind}`)
							T.equal(ev.data.text, "hey milo u there", "only the line naming me")
							T.equal(ev.data.named, true)
						end
					end
				end
				return kinds, senses, memory
			end
			local attentive = scene(false)
			T.check((attentive.entityAppeared or 0) >= 3, "the scene is noisy when attentive")
			T.check((attentive.stared or 0) >= 1, "stared fires when attentive")
			T.check((attentive.onHead or 0) >= 1, "onHead fires when attentive")
			T.check((attentive.entityJumped or 0) >= 1, "jumps are seen when attentive")
			T.check((attentive.blocked or 0) >= 1 and (attentive.bumped or 0) >= 1, "locomotion events when attentive")
			T.check((attentive.groupNearby or 0) >= 1, "groups when attentive")
			T.equal(attentive.chatHeard, 2, "both lines heard when attentive")

			local off, senses, memory = scene(true)
			T.equal(off.chatHeard, 1, "only the named line")
			T.equal(off.entityAppeared, nil)
			T.equal(off.stared, nil)
			T.equal(off.onHead, nil)
			T.equal(off.entityJumped, nil)
			T.equal(off.groupNearby, nil)
			T.equal(off.blocked, nil)
			-- Sightings are still recorded: memory and the visibility bookkeeping keep up.
			T.check(memory.entities.s ~= nil and memory.entities.s.timesSeen >= 13, "memory records the starer")
			T.check(memory.entities.s.lastSeenVisibleAt ~= nil, "seen, not just tracked")
			T.equal(senses.visible.s, true)
			T.check(not senses:isReading(6), "no reading windows open while attention is off")
		end)
	end)
end

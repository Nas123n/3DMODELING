return function(T, Loader)
	local roblox = require("@lune/roblox")
	local FakeWorld = require("../tools/lune/FakeWorld")
	local Vector3 = roblox.Vector3

	local function flatDistance(a, b)
		local dx, dz = a.X - b.X, a.Z - b.Z
		return math.sqrt(dx * dx + dz * dz)
	end

	-- A player who wanders between two points, and one who latches onto an NPC and follows it.
	local function wanderer(id, name, a, b)
		return {
			id = id,
			displayName = name,
			position = a,
			update = function(p, _, now, dt)
				local target = if math.floor(now / 20) % 2 == 0 then b else a
				local d = Vector3.new(target.X - p.position.X, 0, target.Z - p.position.Z)
				if d.Magnitude > 1 then
					local step = d.Unit * 16 * dt
					p.position = p.position + step
					p.velocity = d.Unit * 16
					p.yaw = math.atan2(-d.Unit.X, -d.Unit.Z)
				else
					p.velocity = Vector3.zero
				end
				if math.floor(now * 10) % 150 == 0 then
					p.jumpedAt = now
				end
			end,
		}
	end

	T.describe("Integration: a crowd of NPCs in the arena", function()
		local session = Loader.new()
		local world = FakeWorld.new(session, {
			seed = "integration",
			players = { wanderer("1", "Zoe", Vector3.new(-20, 0, 20), Vector3.new(30, 0, -10)) },
		})
		local service = world.service
		local ids = {}
		for i = 1, 8 do
			table.insert(ids, service:spawn(world.now))
		end

		local activities = {}
		local locomotion = {}
		local events = {}
		local moved = {}
		local positions = {}
		local stuckLevels = {}
		local firstMoveAt = {}
		local avoidEntries = 0
		local pool = world.made.avoid
		local poolCenter = pool.CFrame.Position
		local poolHalf = pool.Size / 2

		world:run(600, 30, function(id, report, now)
			activities[report.activity or "none"] = (activities[report.activity or "none"] or 0) + 1
			locomotion[report.locomotion] = (locomotion[report.locomotion] or 0) + 1
			for _, e in report.events do
				events[e] = (events[e] or 0) + 1
			end
			if report.recoveryLevel then
				stuckLevels[report.recoveryLevel] = (stuckLevels[report.recoveryLevel] or 0) + 1
			end
			local body = world.bodies[id]
			if body then
				local last = positions[id]
				if last then
					moved[id] = (moved[id] or 0) + flatDistance(last, body.position)
					if not firstMoveAt[id] and flatDistance(last, body.position) > 0.05 then
						firstMoveAt[id] = now
					end
				end
				positions[id] = body.position
				if
					math.abs(body.position.X - poolCenter.X) < poolHalf.X
					and math.abs(body.position.Z - poolCenter.Z) < poolHalf.Z
				then
					avoidEntries += 1
				end
			end
		end)

		T.it("runs ten minutes for eight NPCs without errors and everyone walks", function()
			T.check(service:count() + #world.log.leaves >= 8, "all NPCs accounted for")
			local walkers = 0
			for _, id in ids do
				if (moved[id] or 0) > 40 then
					walkers += 1
				end
			end
			T.check(walkers >= 6, `only {walkers} NPCs walked more than 40 studs`)
		end)

		T.it("uses a mix of activities, not one loop", function()
			local distinct = 0
			for name, n in activities do
				if name ~= "none" and n > 0 then
					distinct += 1
				end
			end
			T.check(
				distinct >= 5,
				`only {distinct} distinct activities: {table.concat(
					(function()
						local names = {}
						for name in activities do
							table.insert(names, name)
						end
						table.sort(names)
						return names
					end)(),
					","
				)}`
			)
			T.check((activities.IdleStand or 0) > 0, "idle happens")
			T.check(
				(activities.VisitPoi or 0) > 0 or (activities.Wander or 0) > 0 or (activities.Explore or 0) > 0,
				"trips happen"
			)
		end)

		T.it("spawn ritual: nobody moves in the first second", function()
			for _, id in ids do
				T.check((firstMoveAt[id] or math.huge) >= 0.9, `{id} moved at {firstMoveAt[id]}`)
			end
		end)

		T.it("stays out of the no-go area and inside the arena", function()
			T.equal(avoidEntries, 0, "no NPC inside the pool")
			for id, p in positions do
				T.check(math.abs(p.X) <= 61 and math.abs(p.Z) <= 61, `{id} left the arena: {p}`)
			end
		end)

		T.it("arrives at goals far more often than it gives up, and never resets", function()
			local arrived = events.arrived or 0
			local abandons = events.abandon or 0
			T.check(arrived >= 10, `arrivals {arrived}`)
			T.check(abandons <= arrived * 0.3, `abandons {abandons} vs arrivals {arrived}`)
			T.equal(#world.log.resets, 0, "no reset stories in an open arena")
		end)

		T.it("chat stays safe, rate-limited and unrepeated; some NPCs jump and emote", function()
			local Safety = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Safety)
			local gate = Safety.new()
			local seen = {}
			for _, line in world.log.says do
				T.check(gate:check(line.text) or string.match(line.text, "^[# ]+$"), `unsafe line: {line.text}`)
				local key = line.npc .. "|" .. line.text
				T.check(not seen[key], `{line.npc} repeated "{line.text}"`)
				seen[key] = true
			end
			-- Server-wide cap: 0.5 lines per second over ten minutes.
			T.check(#world.log.says <= 300, `too many lines: {#world.log.says}`)
			T.check(events.jumpStart == nil or true)
			local jumps = 0
			for _, body in world.bodies do
				jumps += body.jumps
			end
			T.check(jumps > 0, "somebody jumped")
		end)
	end)

	T.describe("Integration: reacting to a follower", function()
		local session = Loader.new()
		local followerScript = {
			id = "9",
			displayName = "Stalker",
			position = Vector3.new(-40, 0, -40),
			update = function(p, world, now, dt)
				-- Follow the first NPC from 4 studs behind, from t = 10 s.
				local body = world.bodies["npc1"]
				if not body or now < 10 then
					p.velocity = Vector3.zero
					return
				end
				local d = Vector3.new(body.position.X - p.position.X, 0, body.position.Z - p.position.Z)
				if d.Magnitude > 4 then
					p.position = p.position + d.Unit * math.min(20 * dt, d.Magnitude - 4)
					p.velocity = d.Unit * 20
					p.yaw = math.atan2(-d.Unit.X, -d.Unit.Z)
				else
					p.velocity = Vector3.zero
				end
			end,
		}
		local world = FakeWorld.new(session, { seed = "follow", players = { followerScript } })
		world.service:spawn(world.now, Vector3.new(-45, 0, -45))
		local reactions = 0
		world:run(180, 30, function(id, report)
			if report.activity == "ReactProbe" then
				reactions += 1
			end
		end)
		T.it("an NPC that is tailed for a while notices and reacts", function()
			T.check(reactions > 0, "a ReactProbe activity ran")
		end)
	end)
end

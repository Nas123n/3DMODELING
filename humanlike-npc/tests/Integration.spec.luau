-- The fake-world scenarios of spec §10.2: a crowd in the arena, a follower, the gauntlet, the
-- engine's pathfinder present (and timing out), chat probes in the plaza, the population model,
-- and the far tier. Every T.describe is one FakeWorld at 30 Hz, seeded. The grids are sampled once
-- per process (FakeWorld's cache), so a world costs its simulation and nothing else.
return function(T, Loader)
	local roblox = require("@lune/roblox")
	local FakeWorld = require("../tools/lune/FakeWorld")
	local Scenes = require("../tools/lune/Scenes")
	local ScriptedPlayer = require("../tools/lune/Fakes/ScriptedPlayer")
	local FakePathProvider = require("../tools/lune/Fakes/FakePathProvider")
	local Vector3 = roblox.Vector3

	local function flatDistance(a, b)
		local dx, dz = a.X - b.X, a.Z - b.Z
		return math.sqrt(dx * dx + dz * dz)
	end

	local function flat(v)
		return Vector3.new(v.X, 0, v.Z)
	end

	-- NavMath.dirFromYaw: yaw = atan2(-dir.X, -dir.Z).
	local function dirFromYaw(yaw)
		return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	end

	-- A tally of what the reports said: events (server-wide and per NPC), activities, locomotion.
	local function newTally()
		return { events = {}, activities = {}, locomotion = {}, byNpc = {} }
	end

	local function fold(tally, id, report)
		local activity = report.activity or "none"
		tally.activities[activity] = (tally.activities[activity] or 0) + 1
		tally.locomotion[report.locomotion] = (tally.locomotion[report.locomotion] or 0) + 1
		local mine = tally.byNpc[id]
		if not mine then
			mine = {}
			tally.byNpc[id] = mine
		end
		for _, e in report.events do
			tally.events[e] = (tally.events[e] or 0) + 1
			mine[e] = (mine[e] or 0) + 1
		end
	end

	local function count(tally, event, id)
		if id then
			local mine = tally.byNpc[id]
			return if mine then mine[event] or 0 else 0
		end
		return tally.events[event] or 0
	end

	-- The measured trip ratios, printed for the record.
	local function describeTrips(name, tally, says)
		print(
			string.format(
				"[integration] %s: arrived %d, abandon %d, changedMind %d, goalInvalid %d, tripStarted %d, pathFailed %d, resets %d, says %d",
				name,
				count(tally, "arrived"),
				count(tally, "abandon"),
				count(tally, "changedMind"),
				count(tally, "goalInvalid"),
				count(tally, "tripStarted"),
				count(tally, "pathFailed"),
				count(tally, "reset"),
				says or 0
			)
		)
	end

	-- Snaps a point to the nearest walkable cell of the world's grid (spawn(at) places exactly).
	local function walkable(world, point)
		local ix, iz = world.grid:nearestWalkable(point, 8)
		T.check(ix ~= nil, `no walkable cell near {point}`)
		return world.grid:centerOf(ix, iz)
	end

	T.describe("Integration: a crowd of NPCs in the arena", function()
		local session = Loader.new()
		local world = FakeWorld.new(session, {
			seed = "integration",
			players = { ScriptedPlayer.wanderer("1", "Zoe", Vector3.new(-20, 0, 20), Vector3.new(30, 0, -10)) },
		})
		local service = world.service
		local ids = {}
		for _ = 1, 8 do
			table.insert(ids, service:spawn(world.now))
		end

		local tally = newTally()
		local moved = {}
		local positions = {}
		local firstMoveAt = {}
		local avoidEntries = 0
		local pool = world.made.avoid
		local poolCenter = pool.CFrame.Position
		local poolHalf = pool.Size / 2

		world:run(600, 30, function(id, report, now)
			fold(tally, id, report)
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
		describeTrips("arena crowd", tally, #world.log.says)

		T.it("runs ten minutes for eight NPCs without errors and everyone walks", function()
			T.check(service:count() + #world.log.leaves >= 8, "all NPCs accounted for")
			T.equal(service:stats().errors, 0, "no tick errors")
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
			local names = {}
			for name, n in tally.activities do
				if name ~= "none" and n > 0 then
					distinct += 1
					table.insert(names, name)
				end
			end
			table.sort(names)
			T.check(distinct >= 5, `only {distinct} distinct activities: {table.concat(names, ",")}`)
			T.check((tally.activities.IdleStand or 0) > 0, "idle happens")
			T.check(
				(tally.activities.VisitPoi or 0) > 0
					or (tally.activities.Wander or 0) > 0
					or (tally.activities.Explore or 0) > 0,
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
			local arrived = count(tally, "arrived")
			local abandon = count(tally, "abandon")
			local changedMind = count(tally, "changedMind")
			local tripStarted = count(tally, "tripStarted")
			local pathFailed = count(tally, "pathFailed")
			T.check(arrived >= 10, `arrivals {arrived}`)
			T.check(abandon <= arrived * 0.15, `abandon {abandon} vs arrived {arrived}`)
			T.check(changedMind <= arrived * 0.6, `changedMind {changedMind} vs arrived {arrived}`)
			T.check(pathFailed <= tripStarted * 0.1, `pathFailed {pathFailed} vs tripStarted {tripStarted}`)
			T.equal(count(tally, "reset"), 0, "no reset events in an open arena")
			T.equal(#world.log.resets, 0, "no reset stories in an open arena")
		end)

		T.it("chat stays safe, rate-limited and unrepeated; some NPCs jump", function()
			local Safety = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Safety)
			local gate = Safety.new()
			local seen = {}
			for _, line in world.log.says do
				T.check(gate:check(line.text) or string.match(line.text, "^[# ]+$"), `unsafe line: {line.text}`)
				local key = line.npc .. "|" .. line.text
				T.check(not seen[key], `{line.npc} repeated "{line.text}"`)
				seen[key] = true
			end
			-- Server-wide cap: 8 lines per minute over ten minutes.
			T.check(#world.log.says <= 80, `too many lines: {#world.log.says}`)
			local jumps = 0
			for _, body in world.bodies do
				jumps += body.jumps
			end
			T.check(jumps > 0, "somebody jumped")
		end)
	end)

	T.describe("Integration: reacting to a follower", function()
		local session = Loader.new()
		local world = FakeWorld.new(session, {
			seed = "follow-2",
			players = { ScriptedPlayer.follower("9", "Stalker", "npc1", 4, 10, Vector3.new(-40, 0, -40)) },
		})
		local service = world.service
		local id = service:spawn(world.now, Vector3.new(-45, 0, -45))
		local npc = service:get(id)
		-- The senses are watched so the test sees the followed episodes the NPC sees.
		local followedAt = {}
		local senses = npc.senses
		local sensesStep = senses.step
		senses.step = function(self, input, ...)
			local events = sensesStep(self, input, ...)
			for _, e in events do
				if e.kind == "followed" and e.subject == "p:9" then
					table.insert(followedAt, input.now)
				end
			end
			return events
		end
		local reactions = 0
		local turnedToFollower = false
		world:run(180, 30, function(reportId, report, now)
			if report.activity == "ReactProbe" then
				reactions += 1
			end
			local first = followedAt[1]
			local body = world.bodies[reportId]
			if first and now - first <= 8 and body then
				local toward = flat(world.players[1].position - body.position)
				if toward.Magnitude > 0.1 and dirFromYaw(body.yaw):Dot(toward.Unit) > 0.7 then
					turnedToFollower = true
				end
			end
		end)
		print(`[integration] follower: {#followedAt} followed episodes, {reactions} ReactProbe ticks`)

		T.it("an NPC that is tailed for a while notices and reacts", function()
			T.check(#followedAt > 0, "a followed episode was sensed")
			T.check(reactions > 0, "a ReactProbe activity ran")
		end)

		T.it("turns toward the follower within 8 s of the first episode", function()
			T.check(turnedToFollower, "the NPC's yaw pointed at the follower")
		end)

		T.it("blocks the follower after three episodes", function()
			T.check(#followedAt >= 3, `only {#followedAt} followed episodes in three minutes`)
			T.check(npc.brain.guard:isBlocked("p:9"), "the follower is blocked")
		end)
	end)

	T.describe("Integration: the gauntlet", function()
		local session = Loader.new()
		local world = FakeWorld.new(session, { scene = "gauntlet", seed = "gauntlet" })
		local service = world.service
		local objective = service.world.pois:all()[1].position
		local ids = {}
		for _ = 1, 3 do
			local id = service:spawn(world.now)
			table.insert(ids, id)
			service:get(id):forceGoal(objective, world.now)
		end
		-- Timeouts out of the sliced grid provider, counted at the source.
		local provider = service.gridProvider
		local timeouts = 0
		local providerStep = provider.step
		provider.step = function(self, now, spent)
			local completions = providerStep(self, now, spent)
			for _, c in completions do
				if c.result.status == "Timeout" then
					timeouts += 1
				end
			end
			return completions
		end
		local tally = newTally()
		local reachedAt = {}
		local farthestZ = {}
		local stripEntries = 0
		local strip = world.made.strip
		world:run(90, 30, function(id, report, now)
			fold(tally, id, report)
			local body = world.bodies[id]
			if body then
				if not reachedAt[id] and flatDistance(body.position, objective) <= 6 then
					reachedAt[id] = now
				end
				farthestZ[id] = math.max(farthestZ[id] or -math.huge, body.position.Z)
				if Scenes.inside(strip, body.position + Vector3.new(0, 1, 0)) then
					stripEntries += 1
				end
			end
		end)
		describeTrips("gauntlet", tally, #world.log.says)

		T.it("all three reach the objective within 90 s, each jumping the gap", function()
			for _, id in ids do
				T.check(reachedAt[id] ~= nil, `{id} never reached the objective`)
				local body = world.bodies[id]
				T.check(body ~= nil and body.jumps >= 1, `{id} never jumped`)
				T.check((farthestZ[id] or 0) > 89, `{id} never got past the gap`)
			end
		end)

		T.it("nobody enters the no-go strip", function()
			T.equal(stripEntries, 0)
		end)

		T.it("the pocket is survived without a reset and with few repaths", function()
			T.equal(count(tally, "reset"), 0, "no reset")
			T.equal(#world.log.resets, 0, "no reset story")
			for _, id in ids do
				T.check(
					count(tally, "stuck:2", id) <= 2,
					`{id} entered the repath level {count(tally, "stuck:2", id)} times`
				)
			end
		end)

		T.it("the sliced grid provider never times out at 1.5 ms", function()
			T.equal(timeouts, 0)
			T.equal(service:stats().errors, 0)
		end)
	end)

	T.describe("Integration: the engine's pathfinder is present", function()
		local session = Loader.new()
		local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
		local world = FakeWorld.new(session, {
			seed = "primary",
			players = { ScriptedPlayer.wanderer("1", "Zoe", Vector3.new(-20, 0, 20), Vector3.new(30, 0, -10)) },
			primary = function(grid)
				return FakePathProvider.new(grid, { rng = Rng.new("primary"), failEvery = 4 })
			end,
		})
		local service = world.service
		local ids = {}
		for _ = 1, 8 do
			table.insert(ids, service:spawn(world.now))
		end
		local tally = newTally()
		local leftAt = {}
		world:run(600, 30, function(id, report)
			fold(tally, id, report)
		end)
		for _, leave in world.log.leaves do
			leftAt[leave.npc] = leave.at
		end
		describeTrips("primary present", tally, #world.log.says)

		T.it("the planner falls back to the grid and completes plenty", function()
			local stats = service.planner:getStats()
			T.check(stats.fallbacks >= 1, `fallbacks {stats.fallbacks}`)
			T.check(stats.completed >= 20, `completed {stats.completed}`)
			T.check(world.primary.stats.completed >= 10, `primary completions {world.primary.stats.completed}`)
		end)

		T.it("every NPC that stayed keeps arriving", function()
			for _, id in ids do
				local stayed = leftAt[id] == nil or leftAt[id] >= 300
				if stayed then
					T.check(count(tally, "arrived", id) >= 3, `{id} arrived {count(tally, "arrived", id)} times`)
				end
			end
		end)
	end)

	T.describe("Integration: the engine's pathfinder times out", function()
		local session = Loader.new()
		local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
		local world = FakeWorld.new(session, {
			seed = "primary-timeout",
			players = { ScriptedPlayer.wanderer("1", "Zoe", Vector3.new(-20, 0, 20), Vector3.new(30, 0, -10)) },
			primary = function(grid)
				return FakePathProvider.new(grid, { rng = Rng.new("timeout"), mode = "timeout" })
			end,
		})
		local service = world.service
		for _ = 1, 8 do
			service:spawn(world.now)
		end
		local backoffAt = nil
		local arrivedAfterBackoff = 0
		world:run(150, 30, function(_, report, now)
			if backoffAt == nil and service.planner.backoffUntil > 0 then
				backoffAt = now
			end
			if backoffAt then
				for _, e in report.events do
					if e == "arrived" then
						arrivedAfterBackoff += 1
					end
				end
			end
		end)

		T.it("backs the engine off within 60 s and keeps arriving through the grid", function()
			T.check(backoffAt ~= nil and backoffAt <= 60, `backoff at {backoffAt}`)
			T.check(arrivedAfterBackoff >= 3, `arrivals after the backoff {arrivedAfterBackoff}`)
		end)
	end)

	T.describe("Integration: chat probes in the plaza", function()
		local session = Loader.new()
		local S = session.game.ServerStorage.HumanlikeNpc
		local Personality = session.require(S.Mind.Personality)
		local world = FakeWorld.new(session, { scene = "plaza", seed = "chat-7" })
		local service = world.service
		-- Six NPCs on a ring 13 studs around where the talker will stand (within earshot, outside the
		-- 12-stud "aimed" range, so the last line has to name its target).
		local talkerAt = Vector3.new(0, 0, -40)
		local ids = {}
		for k = 0, 5 do
			local angle = k * math.pi / 3
			local offset = Vector3.new(math.cos(angle) * 13, 0, math.sin(angle) * 13)
			table.insert(ids, service:spawn(world.now, walkable(world, talkerAt + offset)))
		end
		local chatters = {}
		for _, id in ids do
			if Personality.isChatter(service.records[id].persona) then
				table.insert(chatters, id)
			end
		end
		-- The NPC the third line names and the last line is aimed at.
		local namedId = chatters[1] or ids[1]
		local namedName = service:identity(namedId).displayName
		local lines = {
			{ t = 20, text = "hi" },
			{ t = 60, text = "are you a bot" },
			{ t = 120, text = `{namedName} come here` },
			{ t = 180, text = `{namedName} stop` }, -- aimed at the NPC (Reply: named, or within 12 studs)
		}
		world:setPlayers({ ScriptedPlayer.talker("7", "Mia", talkerAt, lines) })
		-- What the speaker's body did in the 1.5 s before each line, and the typing plan it followed.
		local recent = {}
		local presenter = world.adapter.presenter
		local say = presenter.say
		presenter.say = function(p, npcId, text, target)
			local npc = service:get(npcId)
			local plan = if npc then npc.brain.overlays.typingPlan else nil
			say(p, npcId, text, target)
			local entry = world.log.says[#world.log.says]
			entry.variant = if plan then plan.variant else nil
			local travelled = 0
			local history = recent[npcId] or {}
			for i = 2, #history do
				if history[i].t >= world.now - 1.5 then
					travelled += flatDistance(history[i - 1].p, history[i].p)
				end
			end
			entry.travelled = travelled
		end
		world:run(200, 30, function(id, _, now)
			local body = world.bodies[id]
			if body then
				local history = recent[id]
				if not history then
					history = {}
					recent[id] = history
				end
				table.insert(history, { t = now, p = body.position })
				while #history > 0 and history[1].t < now - 3 do
					table.remove(history, 1)
				end
			end
		end)
		local replies = {}
		for _, entry in world.log.says do
			if entry.target == "p:7" then
				table.insert(replies, entry)
			end
		end
		print(
			`[integration] chat probes: {#chatters} chatters, {#world.log.says} lines, {#replies} replies to the talker`
		)

		T.it("at least three of the six are chatters", function()
			T.check(#chatters >= 3, `only {#chatters} chatters with seed chat-7`)
		end)

		T.it("someone greets back within 12 s", function()
			local greeted = false
			for _, r in replies do
				if r.at > 20 and r.at <= 32 and (r.category == "greeting" or r.category == "social") then
					greeted = true
				end
			end
			T.check(greeted, "a greeting or social reply to hi")
		end)

		T.it("answers a bot probe at most once per NPC", function()
			local probes = {}
			for _, r in replies do
				if r.category == "probe" then
					probes[r.npc] = (probes[r.npc] or 0) + 1
					T.check(probes[r.npc] <= 1, `{r.npc} answered probes {probes[r.npc]} times`)
				end
			end
		end)

		T.it("stop is final", function()
			T.check(service:get(namedId) ~= nil, "the named NPC is still here")
			T.check(service:get(namedId).brain.guard:isBlocked("p:7"), "the talker is blocked")
			for _, r in replies do
				T.check(not (r.npc == namedId and r.at > 180), `{namedId} replied after stop at {r.at}`)
			end
		end)

		T.it("replies come after a typing freeze and never sooner than 1.5 s", function()
			for _, r in replies do
				if r.variant ~= "free" then
					T.check(r.travelled <= 0.5, `{r.npc} moved {r.travelled} studs while typing "{r.text}"`)
				end
				local heard = nil
				for _, line in lines do
					if line.t <= r.at then
						heard = line
					end
				end
				T.check(
					heard ~= nil and r.at - heard.t >= 1.5,
					`{r.npc} replied {r.at - (heard and heard.t or 0)} s after the line`
				)
			end
		end)
	end)

	T.describe("Integration: the population model in the plaza", function()
		local session = Loader.new()
		local Config = session.require(session.game.ServerStorage.HumanlikeNpc.Config)
		local config = Config.resolve(nil)
		config.EmptyServerGraceSeconds = 30
		local world = FakeWorld.new(session, {
			scene = "plaza",
			seed = "population",
			config = config,
			population = true,
			players = {
				ScriptedPlayer.wanderer("1", "Ana", Vector3.new(-25, 0, -25), Vector3.new(25, 0, 25)),
				ScriptedPlayer.wanderer("2", "Ben", Vector3.new(25, 0, -25), Vector3.new(-25, 0, 25)),
			},
		})
		local service = world.service
		local function spawnTimes()
			local times = {}
			for _, event in world.log.telemetry do
				if event.kind == "spawn" then
					table.insert(times, event.at)
				end
			end
			return times
		end
		world:run(600, 30)
		local countAt600 = service:count()
		local timesAt600 = spawnTimes()
		world:run(300, 30)
		world:setPlayers({})
		world:run(15, 30)
		local targetInGrace = service.population:target(0, 12, world.now)
		world:run(45, 30)
		local targetAfterGrace = service.population:target(0, 12, world.now)
		local remaining = {}
		for _, id in service:list() do
			table.insert(remaining, { id = id, left = service:get(id).brain.session.leaveAt - world.now })
		end
		world:run(240, 30)
		print(`[integration] population: {countAt600} NPCs at 600 s, {#timesAt600} joins, {#remaining} left at 960 s`)

		T.it("fills toward the target for two players", function()
			T.between(countAt600, 5, 9, "count at 600 s")
			T.check(#timesAt600 >= 5, `only {#timesAt600} joins`)
		end)

		T.it("joins never closer than 1.5 s, at least one pair", function()
			local pair = false
			for i = 2, #timesAt600 do
				local gap = timesAt600[i] - timesAt600[i - 1]
				T.check(gap >= 1.5 - 1e-6, `join gap {gap}`)
				if gap <= 20 then
					pair = true
				end
			end
			T.check(pair, "two joins within 20 s")
		end)

		T.it("keeps two during the grace, then everyone leaves", function()
			T.equal(targetInGrace, 2, "target during the grace")
			T.equal(targetAfterGrace, 0, "target after the grace")
			for _, entry in remaining do
				T.check(entry.left <= 180, `{entry.id} still had {entry.left} s at 960 s`)
			end
			T.equal(service:count(), 0, "count at 1200 s")
		end)
	end)

	T.describe("Integration: the far tier", function()
		local session = Loader.new()
		local approachFrom = 300
		local player = {
			id = "5",
			displayName = "Far",
			position = Vector3.new(0, 0, 340),
			update = function(p, world, now, dt)
				local body = world.bodies["npc1"]
				if now < approachFrom or not body then
					p.velocity = Vector3.zero
					return
				end
				local d = flat(body.position - p.position)
				if d.Magnitude > 40 then
					p.position = p.position + d.Unit * math.min(20 * dt, d.Magnitude - 40)
					p.velocity = d.Unit * 20
					p.yaw = math.atan2(-d.Unit.X, -d.Unit.Z)
				else
					p.velocity = Vector3.zero
				end
			end,
		}
		local world = FakeWorld.new(session, { scene = "plaza", seed = "far", players = { player } })
		local service = world.service
		local ids = {}
		for _, at in
			{ Vector3.new(-20, 0, -60), Vector3.new(20, 0, -60), Vector3.new(-20, 0, -80), Vector3.new(20, 0, -80) }
		do
			table.insert(ids, service:spawn(world.now, walkable(world, at)))
		end
		local tiers = {}
		local modes = {}
		local moved = {}
		local last = {}
		local teleports = 0
		local dt = 1 / 30
		local arrivedAt = {}
		for _ = 1, 300 * 30 do
			local reports = world:step(dt)
			for id, report in reports do
				tiers[report.tier or "?"] = (tiers[report.tier or "?"] or 0) + 1
				modes[report.command.mode] = (modes[report.command.mode] or 0) + 1
				for _, e in report.events do
					if e == "arrived" then
						arrivedAt[id] = world.now
					end
				end
			end
			for _, id in ids do
				local body = world.bodies[id]
				if body then
					local previous = last[id]
					if previous then
						local step = flatDistance(previous, body.position)
						moved[id] = (moved[id] or 0) + step
						if step > 3 * body.walkSpeed * dt then
							teleports += 1
						end
					end
					last[id] = body.position
				end
			end
		end
		local saysBefore, emotesBefore = #world.log.says, #world.log.emotes
		-- The player walks in: within a second of being 50 studs away the NPC is near, mid-trip.
		local promotedAt = nil
		local closeAt = nil
		local notFrozen = false
		while world.now < approachFrom + 60 do
			local reports = world:step(dt)
			local body = world.bodies["npc1"]
			if body and closeAt == nil and flatDistance(body.position, world.players[1].position) <= 50 then
				closeAt = world.now
			end
			if closeAt and promotedAt == nil and service.scheduler:tierOf("npc1") == "near" then
				promotedAt = world.now
			end
			local report = reports["npc1"]
			if promotedAt and report and world.now - promotedAt <= 30 then
				if
					report.locomotion == "walking"
					or report.locomotion == "planning"
					or report.locomotion == "arrived"
				then
					notFrozen = true
				end
			end
			if promotedAt and world.now - promotedAt > 30 then
				break
			end
		end
		local recentArrival = arrivedAt["npc1"] ~= nil and promotedAt ~= nil and promotedAt - arrivedAt["npc1"] <= 30
		print(
			`[integration] far tier: tiers {tiers.far or 0} far / {tiers.near or 0} near ticks, promoted {promotedAt}`
		)

		T.it("far NPCs keep travelling by moveTo without a word, an emote or a teleport", function()
			T.equal(tiers.near or 0, 0, "no near ticks with the player 400 studs away")
			T.check((tiers.far or 0) > 0, "far ticks")
			T.equal(modes.move or 0, 0, "never a plain move")
			T.check((modes.moveTo or 0) > 0, "moveTo commands")
			for _, id in ids do
				T.check((moved[id] or 0) >= 60, `{id} travelled {moved[id]}`)
			end
			T.equal(saysBefore, 0, "no lines")
			T.equal(emotesBefore, 0, "no emotes")
			T.equal(teleports, 0, "no position jumps")
		end)

		T.it("a player walking in promotes the NPC to near within a second, mid-trip", function()
			T.check(closeAt ~= nil, "the player got within 50 studs")
			T.check(promotedAt ~= nil and promotedAt - closeAt <= 1, `promoted {promotedAt} after close at {closeAt}`)
			T.check(notFrozen or recentArrival, "the NPC is mid-trip or just arrived, not idle-frozen")
		end)
	end)
end

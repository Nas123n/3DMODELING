return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local Sim = require("../tools/lune/Sim")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local NavGrid = session.require(S.Nav.NavGrid)
	local GridPathProvider = session.require(S.Nav.GridPathProvider)
	local GoalResolver = session.require(S.Nav.GoalResolver)
	local PathPlanner = session.require(S.Nav.PathPlanner)
	local PoiRegistry = session.require(S.World.PoiRegistry)
	local Personality = session.require(S.Mind.Personality)
	local Recency = session.require(S.Chat.Recency)
	local Safety = session.require(S.Chat.Safety)
	local Npc = session.require(S.Runtime.Npc)
	local Report = session.require(S.Runtime.Report)

	-- One arena grid for every case.
	local _, made = Scenes.arena(session)
	local grid = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
	grid:sample(session.world, { avoid = { made.avoid } })
	local pois = PoiRegistry.new()
	local spawnPart = made.spawn.CFrame.Position
	local spawn = Vector3.new(spawnPart.X, 0, spawnPart.Z)

	local function los(a, b)
		return grid:hasLineOfWalk(a, b)
	end

	local function flatDistance(a, b)
		local dx, dz = a.X - b.X, a.Z - b.Z
		return math.sqrt(dx * dx + dz * dz)
	end

	local function gridPlanner()
		local provider = GridPathProvider.new(grid)
		return PathPlanner.new(nil, provider, GoalResolver.new(grid, pois), { losCheck = los })
	end

	-- A world view with nothing to do in it: no places, no sectors, no reachable wander points, so
	-- the real brain only ever stands around and every trip in a case comes from the test.
	local function barrenWorld(at)
		return {
			pois = {},
			poiOccupants = function()
				return 0
			end,
			entities = {},
			visible = {},
			groups = {},
			myGroup = nil,
			spawnPoint = at,
			reachable = function()
				return false
			end,
			randomReachable = function()
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

	-- A scripted perception: `entities` (a list, or a function of now) is what a snapshot returns.
	local function scriptedPerception(world, options)
		local o = options or {}
		local perception = {
			world = world,
			losCheck = los,
			walkableCheck = function(point)
				local ix, iz = grid:cellOf(point)
				if grid:isWalkable(ix, iz) then
					return "walkable"
				elseif grid:isBlocked(ix, iz) then
					return "wall"
				end
				return "void"
			end,
		}
		function perception.snapshot(_, _, position, radius)
			if o.snapshot then
				return o.snapshot(position, radius)
			end
			return { entities = {}, chats = {} }
		end
		function perception.groups()
			return {}
		end
		function perception.groupOf()
			return nil
		end
		function perception.entity()
			return nil
		end
		function perception.playersWithin()
			return 0
		end
		return perception
	end

	local function recordingPresenter()
		local log = { says = {}, emotes = {}, leaves = {}, resets = {}, typing = {} }
		local presenter = { log = log }
		function presenter.say(_, npcId, text, target)
			table.insert(log.says, { npc = npcId, text = text, target = target })
		end
		function presenter.emote(_, npcId, name, cutAfter)
			table.insert(log.emotes, { npc = npcId, name = name, cutAfter = cutAfter })
		end
		function presenter.leave(_, npcId, reason)
			table.insert(log.leaves, { npc = npcId, reason = reason })
		end
		function presenter.reset(_, npcId)
			table.insert(log.resets, { npc = npcId })
		end
		function presenter.setTyping(_, npcId, on)
			table.insert(log.typing, { npc = npcId, on = on })
		end
		return presenter
	end

	local function moverFor(body)
		local mover = {}
		function mover.read()
			return body:state()
		end
		function mover.apply(_, command)
			body:step(command, 1 / 30)
		end
		function mover.teleport(_, at)
			body.position = at
		end
		return mover
	end

	local function chatShared()
		return {
			recency = Recency.new(),
			safety = Safety.new(),
			allow = function()
				return true
			end,
		}
	end

	-- Builds an NPC on a Sim body at `at`. Options: seed, profileKind, world, perception, presenter,
	-- killY, planner. The mover integrates the body inside apply (30 Hz), so a tick moves the body.
	local function makeNpc(at, options)
		local o = options or {}
		local seed = Rng.new(o.seed or 11)
		local persona = Personality.sample(seed, { profileKind = o.profileKind })
		local body = Sim.fromGrid(grid, at, { walkSpeed = persona.walkSpeed })
		local mover = moverFor(body)
		local presenter = o.presenter or recordingPresenter()
		local world = o.world or barrenWorld(at)
		local perception = o.perception or scriptedPerception(world)
		local planner = o.planner or gridPlanner()
		local identity = { id = o.id or "npc1", username = "test_user", displayName = "Tester" }
		local npc = Npc.new(identity, persona, seed, {
			mover = mover,
			presenter = presenter,
			perception = perception,
			planner = planner,
			chat = chatShared(),
			killY = o.killY,
		}, 0)
		return {
			npc = npc,
			body = body,
			mover = mover,
			presenter = presenter,
			persona = persona,
			planner = planner,
			perception = perception,
			now = 0,
			dt = 1 / 30,
			brainEvery = 3, -- 10 Hz brain at a 30 Hz tick
			ticks = 0,
			events = {},
			reports = {},
		}
	end

	-- Runs the NPC for `seconds`: planner step, tick (brain every third tick), event log.
	local function run(h, seconds, onReport)
		local endAt = h.now + seconds - 1e-9
		while h.now < endAt do
			local now = h.now
			for _, c in h.planner:step(now) do
				h.npc:onPathResult(c, now)
			end
			h.ticks += 1
			local report = h.npc:tick(now, (h.ticks - 1) % h.brainEvery == 0)
			table.insert(h.reports, { id = h.npc.id, report = report, now = now })
			for _, e in report.events do
				table.insert(h.events, { kind = e, at = now })
			end
			if onReport then
				onReport(now, report)
			end
			h.now = now + h.dt
		end
	end

	local function count(h, kind)
		local n = 0
		for _, e in h.events do
			if e.kind == kind then
				n += 1
			end
		end
		return n
	end

	local function first(h, kind)
		for _, e in h.events do
			if e.kind == kind then
				return e
			end
		end
		return nil
	end

	-- A brain stub: `intentAt(now)` returns the intent (and optionally changedMind) each step.
	local function scriptBrain(npc, intentAt)
		npc.brain.step = function(_, input)
			local intent, changedMind = intentAt(input.now)
			return {
				intent = intent,
				actions = {},
				activity = "Scripted",
				target = nil,
				interrupted = false,
				typing = false,
				phase = "settled",
				mood = "neutral",
				changedMind = changedMind == true,
			}
		end
	end

	local function goto_(position, extra)
		local intent = { kind = "goto", position = position }
		for k, v in extra or {} do
			intent[k] = v
		end
		return intent
	end

	T.describe("Npc", function()
		T.it("emits tripStarted/arrived once per trip", function()
			local h = makeNpc(spawn)
			-- The real brain, in a world with nothing to do: it stands; the test walks it.
			local goal = spawn + Vector3.new(30, 0, 0)
			run(h, 0.5)
			h.npc:forceGoal(goal, h.now)
			run(h, 12)
			T.equal(count(h, "tripStarted"), 1, "one tripStarted")
			T.equal(count(h, "arrived"), 1, "one arrived")
			T.equal(count(h, "abandon"), 0, "no abandon")
			T.equal(count(h, "changedMind"), 0, "no changedMind")
			T.equal(count(h, "goalInvalid"), 0, "no goalInvalid")
			T.check(first(h, "tripStarted").at < first(h, "arrived").at, "tripStarted precedes arrived")
			T.check(
				flatDistance(h.body.position, goal) <= 8,
				`ends {flatDistance(h.body.position, goal)} from the goal`
			)
			local last = h.reports[#h.reports].report
			T.equal(last.tier, "near")
			T.equal(last.resetsUsed, 0)
			T.equal(last.typing, false)
			-- A second forced goal is a second trip, and nothing else.
			h.npc:forceGoal(spawn + Vector3.new(30, 0, 20), h.now)
			run(h, 12)
			T.equal(count(h, "tripStarted"), 2, "two tripStarted")
			T.equal(count(h, "arrived"), 2, "two arrived")
		end)

		T.it("changedMind when the brain reselects mid-trip", function()
			local h = makeNpc(spawn, { seed = 12 })
			local a = spawn + Vector3.new(40, 0, 0)
			local b = spawn + Vector3.new(0, 0, 40)
			-- Two seconds toward A, then the brain swaps to B and flags the change of mind once.
			local swappedAt = nil
			scriptBrain(h.npc, function(now)
				if now < 2 then
					return goto_(a, { urgency = 0.5 })
				end
				local fresh = swappedAt == nil
				swappedAt = swappedAt or now
				return goto_(b, { urgency = 0.5 }), fresh
			end)
			run(h, 14)
			T.equal(count(h, "changedMind"), 1, "one changedMind")
			T.equal(count(h, "abandon"), 0, "no abandon")
			T.equal(count(h, "goalInvalid"), 0, "no goalInvalid")
			T.equal(count(h, "tripStarted"), 2, "the second goal is a new trip")
			T.equal(count(h, "arrived"), 1, "only the second trip arrives")
			local changed = first(h, "changedMind")
			T.check(changed.at >= 2 and changed.at < 2.2, `changedMind reported at {changed.at}`)
			T.check(flatDistance(h.body.position, b) <= 8, `ends {flatDistance(h.body.position, b)} from B`)
		end)

		T.it("far tier issues moveTo and no say/emote", function()
			local h = makeNpc(spawn, { seed = 13, profileKind = "pc" })
			-- A chatterbox on a keyboard, far from everyone: the ritual's greeting and every emote
			-- is dropped, the walk goes out as moveTo and the body still arrives.
			h.persona.chattiness = 1
			h.persona.emoteHabit = 1
			h.npc:setTier("far")
			local goal = spawn + Vector3.new(40, 0, 0)
			h.npc:forceGoal(goal, 0)
			local modes = {}
			run(h, 15, function(_, report)
				modes[report.command.mode] = (modes[report.command.mode] or 0) + 1
				T.equal(report.tier, "far")
			end)
			T.check((modes.moveTo or 0) > 0, "moveTo commands were issued")
			T.equal(modes.move, nil, "never a plain move in the far tier")
			T.equal(count(h, "tripStarted"), 1)
			T.equal(count(h, "arrived"), 1, "arrives by moveTo")
			T.check(
				flatDistance(h.body.position, goal) <= 8,
				`ends {flatDistance(h.body.position, goal)} from the goal`
			)
			T.equal(#h.presenter.log.says, 0, "no lines")
			T.equal(#h.presenter.log.emotes, 0, "no emotes")
			-- Back in the near tier the same walk is a plain move.
			h.npc:setTier("near")
			h.npc:forceGoal(spawn, h.now)
			local moves = 0
			run(h, 6, function(_, report)
				if report.command.mode == "move" then
					moves += 1
				end
			end)
			T.check(moves > 0, "move commands in the near tier")
		end)

		T.it("reset calls presenter.reset and rebind restarts a short ritual", function()
			local h = makeNpc(spawn, { seed = 14, killY = -50 })
			local goal = spawn + Vector3.new(20, 0, 0)
			local function fallOut()
				-- Below the kill plane: locomotion resets within a tick, and the adapter is asked.
				h.body.position = Vector3.new(h.body.position.X, -51, h.body.position.Z)
				run(h, h.dt * 2)
			end
			local function rebindAndWalk()
				h.body.position = spawn
				h.body.onGround = true
				h.body.velocity = Vector3.zero
				local rebindAt = h.now
				h.npc:rebind(h.mover, rebindAt)
				h.npc:forceGoal(goal, rebindAt)
				local firstMoveAt = nil
				run(h, 6, function(now)
					if not firstMoveAt and flatDistance(h.body.position, spawn) > 0.05 then
						firstMoveAt = now
					end
				end)
				T.check(firstMoveAt ~= nil, "walks again after the rebind")
				return firstMoveAt - rebindAt
			end
			for i = 1, 3 do
				h.npc:forceGoal(goal, h.now)
				run(h, 1)
				fallOut()
				T.equal(#h.presenter.log.resets, i, `reset {i} reached the presenter`)
				T.equal(count(h, "reset"), i, `reset {i} reported`)
				T.equal(h.npc:isLeaving(), false, `still here after reset {i}`)
				T.equal(h.reports[#h.reports].report.locomotion, "dead", "dead until the rebind")
				T.equal(h.reports[#h.reports].report.resetsUsed, i)
				local held = rebindAndWalk()
				T.between(held, 0.5, 2.1, `held still {held} s after rebind {i}`)
			end
			-- The fourth reset is one too many: the NPC leaves instead of respawning.
			fallOut()
			T.equal(count(h, "reset"), 4, "fourth reset reported")
			T.equal(#h.presenter.log.resets, 3, "the presenter is not asked a fourth time")
			T.equal(h.npc:isLeaving(), true, "the fourth reset makes the NPC leave")
			T.equal(#h.presenter.log.leaves, 1, "the presenter saw the leave")
			T.equal(h.reports[#h.reports].report.resetsUsed, 4)
		end)

		T.it("a throwing perception propagates", function()
			local world = barrenWorld(spawn)
			local perception = scriptedPerception(world, {
				snapshot = function()
					error("perception exploded")
				end,
			})
			local h = makeNpc(spawn, { seed = 15, perception = perception })
			T.throws(function()
				h.npc:tick(0, true)
			end, "perception exploded")
			-- Nothing is latched: the next brain tick asks again and throws again.
			T.throws(function()
				h.npc:tick(0.1, true)
			end, "perception exploded")
			-- A tick without a brain step, standing idle, needs no snapshot and runs through.
			local report = h.npc:tick(0.2, false)
			T.equal(report.command.mode, "stop")
		end)

		T.it("camera glance on a seen event", function()
			local function glancesFor(profileKind, seed)
				local h = makeNpc(spawn, { seed = seed, profileKind = profileKind })
				h.persona.sociability = 0.3
				local looks = 0
				h.npc.humanizer.lookAt = function()
					looks += 1
				end
				-- A scripted sense: one seen event per brain step, 12 studs to the east.
				local seen = 0
				h.npc.senses = {
					step = function(_, input)
						seen += 1
						return {
							{
								kind = "entityAppeared",
								salience = 0.5,
								subject = "p:1",
								expected = true,
								at = input.now,
								data = {
									position = input.me.position + Vector3.new(12, 0, 0),
									distance = 12,
									kind = "player",
								},
							},
						}
					end,
					isReading = function()
						return false
					end,
				}
				h.brainEvery = 1
				run(h, 200 * h.dt)
				return looks, seen
			end
			local looks, seen = glancesFor("pc", 16)
			T.equal(seen, 200, "two hundred seen events")
			T.between(looks / seen, 0.4, 0.6, `pc glance rate {looks / seen}`)
			local shiftLooks, shiftSeen = glancesFor("pcShiftLock", 17)
			T.between(shiftLooks / shiftSeen, 0.4, 0.6, `shift-lock glance rate {shiftLooks / shiftSeen}`)
			local mobileLooks = glancesFor("mobile", 18)
			T.equal(mobileLooks, 0, "mobile never glances")
			local consoleLooks = glancesFor("console", 19)
			T.equal(consoleLooks, 0, "console never glances")
		end)

		T.it("typing actions reach the presenter and the report", function()
			local h = makeNpc(spawn, { seed = 20 })
			scriptBrain(h.npc, function()
				return { kind = "hold" }
			end)
			local step = h.npc.brain.step
			local phase = 0
			h.npc.brain.step = function(brain, input)
				local out = step(brain, input)
				phase += 1
				if phase == 1 then
					out.actions = { { kind = "typing", on = true } }
				elseif phase == 4 then
					out.actions = { { kind = "typing", on = false } }
				end
				return out
			end
			local typingTicks = 0
			run(h, 1, function(_, report)
				if report.typing then
					typingTicks += 1
				end
			end)
			T.equal(#h.presenter.log.typing, 2, "on and off reached the presenter")
			T.equal(h.presenter.log.typing[1].on, true)
			T.equal(h.presenter.log.typing[2].on, false)
			T.check(typingTicks >= 3 and typingTicks <= 12, `typing reported on {typingTicks} ticks`)
		end)
	end)

	T.describe("Report", function()
		T.it("summarize counts the three abandon kinds separately", function()
			local function report(activity, locomotion, events)
				return {
					command = Npc.STOP,
					position = Vector3.zero,
					remaining = 0,
					humanizerBusy = false,
					intent = "goto",
					activity = activity,
					target = nil,
					mood = "neutral",
					phase = "settled",
					locomotion = locomotion,
					recoveryLevel = 0,
					events = events,
				}
			end
			local reports = {
				{ id = "npc1", report = report("Wander", "walking", { "tripStarted" }), now = 0 },
				{ id = "npc1", report = report("Wander", "arrived", { "arrived" }), now = 1 },
				{ id = "npc2", report = report("VisitPoi", "walking", { "stuck:3", "abandon" }), now = 1 },
				{ id = "npc1", report = report("Explore", "walking", { "changedMind", "tripStarted" }), now = 2 },
				{ id = "npc3", report = report(nil, "failed", { "goalInvalid" }), now = 2 },
				{ id = "npc3", report = report("Wander", "walking", { "changedMind" }), now = 3 },
				{ id = "npc2", report = report("VisitPoi", "failed", { "reset" }), now = 4 },
			}
			local s = Report.summarize(reports)
			T.equal(s.arrived, 1, "arrived")
			T.equal(s.abandon, 1, "abandon")
			T.equal(s.changedMind, 2, "changedMind")
			T.equal(s.goalInvalid, 1, "goalInvalid")
			T.equal(s.resets, 1, "resets")
			T.equal(s.ticks, 7)
			T.equal(s.events["stuck:3"], 1)
			T.equal(s.events.tripStarted, 2)
			T.equal(s.activities.Wander, 3)
			T.equal(s.activities.none, 1)
			T.equal(s.locomotion.walking, 4)
			T.equal(s.locomotion.failed, 2)
		end)

		T.it("emptyFrame and fold count ticks, brains and events", function()
			local frame = Report.emptyFrame()
			T.equal(frame.ticks, 0)
			T.equal(frame.brains, 0)
			T.equal(frame.pressure, 0)
			local events = {}
			local base = {
				command = Npc.STOP,
				position = Vector3.zero,
				remaining = 0,
				humanizerBusy = false,
				intent = "-",
				mood = "neutral",
				phase = "settled",
				locomotion = "idle",
				recoveryLevel = 0,
				events = { "arrived" },
				brainRan = false,
			}
			Report.fold(frame, base, events)
			local withBrain = table.clone(base)
			withBrain.brainRan = true
			withBrain.intent = "hold"
			withBrain.events = { "arrived", "hesitation" }
			Report.fold(frame, withBrain, events)
			T.equal(frame.ticks, 2)
			T.equal(frame.brains, 1)
			T.equal(events.arrived, 2)
			T.equal(events.hesitation, 1)
		end)
	end)
end

return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local FakeWorld = require("../tools/lune/FakeWorld")
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
	local Locomotion = session.require(S.Nav.Locomotion)

	local model, made = Scenes.arena(session)
	local grid = FakeWorld.sampledGrid(session, "arena", model) -- sampled once per process, shared
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

	-- A fake provider that answers every request on its next step: "nopath" always fails,
	-- "straight" returns the two-point line from start to goal. Logs what it was asked.
	local function fakeProvider(mode)
		local p = { name = mode, queue = {}, log = {} }
		function p:submit(request)
			table.insert(self.log, request)
			table.insert(self.queue, request)
		end
		function p:cancel(id)
			for i, r in self.queue do
				if r.id == id then
					table.remove(self.queue, i)
					return
				end
			end
		end
		function p:cancelAgent(agentId)
			for i = #self.queue, 1, -1 do
				if self.queue[i].agentId == agentId then
					table.remove(self.queue, i)
				end
			end
		end
		function p:inFlight()
			return #self.queue
		end
		function p:step()
			local out = {}
			for _, r in self.queue do
				local result
				if mode == "nopath" then
					result = {
						status = "NoPath",
						waypoints = {},
						provider = "grid",
						cost = 0,
						goalDistance = flatDistance(r.start, r.goal),
					}
				else
					result = {
						status = "Success",
						waypoints = {
							{ position = r.start, action = "Walk" },
							{ position = r.goal, action = "Walk" },
						},
						provider = "grid",
						cost = flatDistance(r.start, r.goal),
						goalDistance = 0,
					}
				end
				table.insert(out, { id = r.id, agentId = r.agentId, result = result })
			end
			self.queue = {}
			return out
		end
		return p
	end

	local function gridPlanner()
		local provider = GridPathProvider.new(grid)
		return PathPlanner.new(nil, provider, GoalResolver.new(grid, pois), { losCheck = los }), provider
	end

	local function makeLoco(planner, depsOverrides, options, seed)
		local deps = {
			planner = planner,
			losCheck = los,
			entity = function()
				return nil
			end,
			agentId = "npc1",
			canJump = true,
			lookahead = 6,
			killY = -50,
		}
		for k, v in depsOverrides or {} do
			deps[k] = v
		end
		return Locomotion.new(Rng.new(seed or 7), deps, options, 0)
	end

	-- Drives planner, locomotion and body together; `onTick(now, out)` runs after the body moved.
	local function harness(planner, loco, body, hz)
		local h = {
			planner = planner,
			loco = loco,
			body = body,
			now = 0,
			dt = 1 / (hz or 10),
			events = {},
			statuses = {},
			commands = {},
		}
		function h:note()
			local status = self.loco:status()
			if self.statuses[#self.statuses] ~= status then
				table.insert(self.statuses, status)
			end
		end
		function h:run(seconds, onTick)
			local endAt = self.now + seconds - 1e-9
			while self.now < endAt do
				local now = self.now
				if self.planner then
					for _, c in self.planner:step(now) do
						self.loco:onPathResult(c, now)
					end
				end
				local out = self.loco:tick(self.body:state(), {}, now, self.dt, -math.huge)
				for _, e in out.events do
					table.insert(self.events, e)
				end
				self:note()
				table.insert(self.commands, out.command)
				self.body:step(out.command, self.dt)
				if onTick then
					onTick(now, out)
				end
				self.now = now + self.dt
			end
		end
		function h:count(kind)
			local n = 0
			for _, e in self.events do
				if e.kind == kind then
					n += 1
				end
			end
			return n
		end
		function h:first(kind)
			for _, e in self.events do
				if e.kind == kind then
					return e
				end
			end
			return nil
		end
		function h:levels()
			local out = {}
			for _, e in self.events do
				if e.kind == "stuck" then
					table.insert(out, e.level)
				end
			end
			return out
		end
		return h
	end

	local function goto_(position, extra)
		local intent = { kind = "goto", position = position }
		for k, v in extra or {} do
			intent[k] = v
		end
		return intent
	end

	T.describe("Locomotion", function()
		T.it("goto plans, follows and arrives", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:note()
			h:run(6)
			T.equal(table.concat(h.statuses, ","), "waitingPath,following,idle", "status sequence")
			T.equal(h:count("tripStarted"), 1, "one tripStarted")
			T.equal(h:count("arrived"), 1, "one arrived")
			T.equal(h:count("abandon"), 0)
			T.check(flatDistance(body.position, goal) <= 4.5, `ends {flatDistance(body.position, goal)} from the goal`)
			T.equal(loco:brainView(body:state()).status, "arrived", "the brain sees arrived until the next intent")
			T.equal(loco:describe().level, 0)
		end)

		T.it("same goal does not re-request", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(0.5)
			T.equal(loco:status(), "following")
			loco:setIntent(goto_(goal + Vector3.new(0.2, 0, 0.2)), body:state(), h.now)
			T.equal(loco:status(), "following", "still following, no new request")
			h:run(0.5)
			loco:setIntent(goto_(goal), body:state(), h.now)
			h:run(4)
			T.equal(planner:getStats().completed, 1, "one completion")
			T.equal(planner:getStats().queued, 1, "one request")
			T.equal(h:count("tripStarted"), 1)
			-- Standing at the goal, the same goto still does nothing.
			loco:setIntent(goto_(goal), body:state(), h.now)
			h:run(0.5)
			T.equal(planner:getStats().queued, 1, "arrived: no re-request")
		end)

		T.it("pathFailed then retry after 3 s", function()
			local fake = fakeProvider("nopath")
			local planner = PathPlanner.new(fake, fake, GoalResolver.new(grid, pois), { losCheck = los })
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(60, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			T.equal(loco:status(), "waitingPath")
			h:run(1.5)
			T.equal(h:count("pathFailed"), 1, "the ladder ran out")
			T.equal(h:count("tripStarted"), 0)
			T.equal(loco:status(), "idle")
			T.equal(loco:brainView(body:state()).status, "failed")
			local failedAt = h:first("pathFailed").at
			local queuedBefore = planner:getStats().queued
			local logBefore = #fake.log
			-- Too soon: nothing.
			loco:setIntent(goto_(goal), body:state(), failedAt + 1)
			T.equal(planner:getStats().queued, queuedBefore, "no retry within 3 s")
			-- Later: the same goto re-requests at the lowest priority.
			local retryAt = failedAt + 3.1
			h.now = retryAt
			loco:setIntent(goto_(goal), body:state(), retryAt)
			T.equal(planner:getStats().queued, queuedBefore + 1, "retry queued")
			T.equal(loco:status(), "waitingPath")
			h:run(0.2)
			T.check(#fake.log > logBefore, "the provider saw the retry")
			T.equal(fake.log[logBefore + 1].priority, 2, "retry priority")
		end)

		T.it("leg timeout enters recovery and resumes the follower", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			body.walkSpeed = 0
			h:run(6)
			local levels = h:levels()
			T.check(#levels >= 1, "a stuck episode ran")
			T.equal(levels[1], 1, "the timeout enters at level 1")
			T.equal(h:count("abandon"), 0)
			body.walkSpeed = 16
			local pausedTicks = 0
			h:run(8, function()
				local follower = loco.follower
				if follower and follower:isPaused() then
					pausedTicks += 1
				end
			end)
			T.equal(pausedTicks, 0, "the follower is never left paused")
			T.equal(h:count("arrived"), 1, "the trip completes once the body walks")
		end)

		T.it("custom waypoint resumes after a short pause", function()
			local function trip(customWaypoint)
				local seen = {}
				local loco = makeLoco(gridPlanner(), {
					customWaypoint = if customWaypoint
						then function(label, position)
							table.insert(seen, { label = label, position = position })
							return customWaypoint(label, position)
						end
						else nil,
				})
				local body = Sim.fromGrid(grid, spawn)
				local goal = spawn + Vector3.new(16, 0, 0)
				loco:setIntent(goto_(goal), body:state(), 0)
				local waypoints = {}
				for i, dx in { 0, 4, 8, 12, 16 } do
					table.insert(waypoints, {
						position = spawn + Vector3.new(dx, 0, 0),
						action = if i == 3 then "Custom" else "Walk",
						label = if i == 3 then "door" else nil,
					})
				end
				loco:onPathResult({
					id = loco.requestId,
					agentId = "npc1",
					result = {
						status = "Success",
						waypoints = waypoints,
						provider = "grid",
						cost = 16,
						goalDistance = 0,
					},
					reason = "original",
					goal = goal,
				}, 0)
				T.equal(loco:status(), "following")
				local h = harness(nil, loco, body, 20)
				local firstPaused, lastPaused = nil, nil
				h:run(5, function(now)
					local follower = loco.follower
					if follower and follower:isPaused() then
						firstPaused = firstPaused or now
						lastPaused = now
					end
				end)
				T.check(firstPaused ~= nil, "the follower paused at the custom waypoint")
				T.equal(h:count("arrived"), 1, "and finished the trip")
				return lastPaused - firstPaused + h.dt, seen
			end
			local pause = trip(nil)
			T.between(pause, 0.2, 0.55, `short pause {pause}`)
			local long, seen = trip(function()
				return 2
			end)
			T.between(long, 1.95, 2.1, `handler pause {long}`)
			T.equal(#seen, 1)
			T.equal(seen[1].label, "door")
			T.near(seen[1].position.X, spawn.X + 8, 1e-6)
		end)

		T.it("a fall repaths and reports fell", function()
			local fake = fakeProvider("straight")
			local planner = PathPlanner.new(nil, fake, GoalResolver.new(grid, pois), {
				losCheck = function()
					return true
				end,
			})
			local loco = makeLoco(planner, {
				losCheck = function()
					return true
				end,
			})
			-- A 12-stud ledge with a strip of nothing at its foot: the body walks off and drops.
			local body = Sim.new(Vector3.new(-10, 12, 0), {
				floorAt = function(x)
					if x < 0 then
						return 12
					elseif x < 3 then
						return nil
					end
					return 0
				end,
			})
			local goal = Vector3.new(20, 0, 0)
			local h = harness(planner, loco, body, 20)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(4)
			T.equal(h:count("fell"), 1, "one fall")
			T.equal(h:count("flung"), 0, "a fall is not a fling")
			-- The landing re-planned (the planner may answer a short clear goal itself, so the
			-- request is observed on the locomotion, not on the provider).
			T.equal(planner:getStats().queued, 2, "two requests")
			T.equal(loco.lastRequest.id, 2)
			T.equal(loco.lastRequest.priority, 1, "at priority 1")
			T.check(loco.lastRequest.start.Y < 1, "from the landing point")
			T.equal(body.position.Y, 0)
			T.equal(h:count("tripStarted"), 2, "a new trip from the landing point")
			local sawAirborne = false
			for _, s in h.statuses do
				if s == "airborne" then
					sawAirborne = true
				end
			end
			T.check(sawAirborne, "status airborne while falling")
			T.equal(h:count("arrived"), 1, "then arrives")
		end)

		T.it("flung holds then reselects", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(1)
			T.equal(loco:status(), "following")
			body.velocity = Vector3.new(80, 0, 0)
			h:run(h.dt)
			T.equal(h:count("flung"), 1)
			T.equal(loco:status(), "holding")
			local holdingUntil = h.now
			local lastBrain = -1
			h:run(7, function(now, out)
				if out.status == "holding" then
					holdingUntil = now + h.dt
				end
				if now - lastBrain >= 0.2 then
					lastBrain = now
					loco:setIntent(goto_(goal), body:state(), now)
				end
			end)
			local held = holdingUntil - 1
			T.between(held, 1, 5, `held for {held}`)
			T.equal(h:count("flung"), 1, "one fling")
			T.equal(h:count("tripStarted"), 2, "the goto after the hold starts a new trip")
		end)

		T.it("stuck escalates and repaths", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner, nil, { stuckAfter = 0.3 })
			local wallX = spawn.X + 6
			local body = Sim.new(spawn, {
				blockedAt = function(x)
					return x > wallX
				end,
			})
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(12)
			local levels = h:levels()
			T.check(#levels >= 3, `three episodes, got {#levels}`)
			T.equal(levels[1], 0, "nudge first")
			T.equal(levels[2], 1, "then back up and jump")
			T.equal(levels[3], 2, "then a re-path")
			local repath = h:first("repath")
			T.check(repath ~= nil and repath.at < 12, "repath within 12 s")
			T.equal(h:count("reset"), 0, "no reset")
			local sawRecovering = false
			for _, s in h.statuses do
				if s == "recovering" then
					sawRecovering = true
				end
			end
			T.check(sawRecovering, "status recovering during episodes")
		end)

		T.it("hold cancels a trip with changedMind", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(1)
			loco:setIntent({ kind = "hold" }, body:state(), h.now)
			T.equal(loco:status(), "holding")
			h:run(1)
			T.equal(h:count("changedMind"), 1, "one changedMind")
			T.equal(h:count("abandon"), 0, "no abandon")
			T.equal(h:count("arrived"), 0)
			T.equal(loco.follower, nil)
			T.equal(h.commands[#h.commands].mode, "stop")
			-- A second hold is idempotent.
			loco:setIntent({ kind = "hold" }, body:state(), h.now)
			h:run(0.5)
			T.equal(h:count("changedMind"), 1)
			-- The brain wants the same goal again: the trip restarts.
			loco:setIntent(goto_(goal), body:state(), h.now)
			h:run(3)
			T.equal(h:count("tripStarted"), 2)
			T.equal(h:count("arrived"), 1)
		end)

		T.it("freeze walkStraight keeps walking", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(40, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(0.5)
			local dir = h.commands[#h.commands].dir
			T.equal(h.commands[#h.commands].mode, "move")
			loco:setIntent({ kind = "freeze", variant = "walkStraight", duration = 2 }, body:state(), h.now)
			local start = body.position
			local constant, suppressed = true, true
			h:run(2, function(now, out)
				if out.status ~= "holding" then
					constant = false
				end
				if out.command.mode ~= "move" or (out.command.dir - dir).Magnitude > 1e-6 then
					constant = false
				end
				if not loco.stuck:isSuppressed(now) then
					suppressed = false
				end
			end)
			T.check(constant, "the command direction stays constant for 2 s")
			T.check(suppressed, "the stuck detector is suppressed")
			T.near(flatDistance(body.position, start), 32, 0.5, "walked straight at full speed")
			h:run(0.2)
			T.check(loco:status() ~= "holding", "the freeze ended")
		end)

		T.it("follow keeps 3 studs behind", function()
			local planner = gridPlanner()
			-- A target walking a rectangle in the clear south strip at 12 studs/s.
			local corners = {
				Vector3.new(-45, 0, -50),
				Vector3.new(45, 0, -50),
				Vector3.new(45, 0, -30),
				Vector3.new(-45, 0, -30),
			}
			local target = {
				id = "p:1",
				kind = "player",
				position = corners[1],
				velocity = Vector3.new(12, 0, 0),
				yaw = 0,
				displayName = "Zed",
				radius = 2,
				isMoving = true,
			}
			local leg = 1
			local function advanceTarget(dt)
				local to = corners[leg % 4 + 1]
				local d = Vector3.new(to.X - target.position.X, 0, to.Z - target.position.Z)
				if d.Magnitude < 12 * dt then
					target.position = to
					leg += 1
					to = corners[leg % 4 + 1]
					d = Vector3.new(to.X - target.position.X, 0, to.Z - target.position.Z)
				end
				local dir = d.Unit
				target.position = target.position + dir * 12 * dt
				target.velocity = dir * 12
				target.yaw = math.atan2(-dir.X, -dir.Z)
			end
			local loco = makeLoco(planner, {
				entity = function(id)
					return if id == "p:1" then target else nil
				end,
			})
			local body = Sim.fromGrid(grid, corners[1] + Vector3.new(-4, 0, 0))
			local h = harness(planner, loco, body)
			local follow = { kind = "follow", targetId = "p:1", keep = 3 }
			loco:setIntent(follow, body:state(), 0)
			local lastBrain = 0
			local gaps, sum = 0, 0
			local farthest = 0
			h:run(20, function(now)
				advanceTarget(h.dt)
				if now - lastBrain >= 0.2 - 1e-9 then
					lastBrain = now
					loco:setIntent(follow, body:state(), now + h.dt)
				end
				if now >= 5 then
					local gap = flatDistance(body.position, target.position)
					gaps += 1
					sum += gap
					farthest = math.max(farthest, gap)
				end
			end)
			local mean = sum / gaps
			T.between(mean, 2, 6, `mean gap {mean}`)
			T.check(farthest < 10, `never lost: farthest {farthest}`)
			T.equal(h:count("tripStarted"), 1, "one trip per follow episode")
			T.equal(h:count("abandon"), 0)
			T.equal(h:count("stuck"), 0)
		end)

		T.it("kill plane resets", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(1)
			body.position = Vector3.new(body.position.X, -51, body.position.Z)
			h:run(h.dt)
			T.equal(h:count("reset"), 1, "reset within one tick")
			T.equal(loco:status(), "dead")
			T.equal(h.commands[#h.commands].mode, "stop")
			T.equal(loco:brainView(body:state()).status, "failed")
			-- Dead until the owner's reset story ends with a fresh body: intents change nothing.
			loco:setIntent(goto_(goal), body:state(), h.now)
			h:run(0.5)
			T.equal(loco:status(), "dead")
			T.equal(h.commands[#h.commands].mode, "stop")
			T.equal(planner:getStats().queued, 1, "no request while dead")
			-- The body swap: reset() brings it back to idle without an event.
			body.position = spawn
			loco:reset(h.now)
			T.equal(loco:status(), "idle")
			T.equal(loco.follower, nil)
			T.equal(loco:describe().level, 0)
			T.equal(loco:brainView(body:state()).status, "idle")
			h:run(0.5)
			T.equal(h:count("reset"), 1, "no event from reset()")
			loco:setIntent(goto_(goal), body:state(), h.now)
			h:run(3)
			T.equal(h:count("tripStarted"), 2, "walks again after the swap")
			T.equal(h:count("arrived"), 1)
		end)

		T.it("cancel reports changedMind or goalInvalid and leaves the goal readable", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(1)
			loco:cancel("changedMind", h.now)
			T.equal(loco:status(), "idle")
			h:run(0.5)
			T.equal(h:count("changedMind"), 1)
			T.equal(loco:brainView(body:state()).status, "idle")
			T.equal(loco:brainView(body:state()).goal, nil, "a changed mind forgets the goal")
			-- Nothing to cancel: no event.
			loco:cancel("changedMind", h.now)
			h:run(0.2)
			T.equal(h:count("changedMind"), 1, "no changedMind without a trip")
			-- goalInvalid keeps the goal so the activity reads the failure back.
			loco:setIntent(goto_(goal), body:state(), h.now)
			h:run(0.5)
			loco:cancel("goalInvalid", h.now)
			h:run(0.2)
			T.equal(h:count("goalInvalid"), 1)
			local view = loco:brainView(body:state())
			T.equal(view.status, "failed")
			T.check(view.goal ~= nil and flatDistance(view.goal, goal) < 1e-6, "goal kept")
			T.equal(h:count("abandon"), 0)
			T.equal(h:count("arrived"), 0)
		end)

		T.it("onBlocked re-requests ahead of the follower and gives up on the third", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn, { walkSpeed = 8 })
			local goal = spawn + Vector3.new(30, 0, 0)
			local h = harness(planner, loco, body)
			T.equal(loco:onBlocked(3, 0), false, "nothing to block yet")
			loco:setIntent(goto_(goal), body:state(), 0)
			h:run(0.3)
			local index = loco:followerIndex()
			T.check(index ~= nil and index >= 1, "following a planned path")
			T.equal(loco:onBlocked(index - 1, h.now), false, "behind the follower: ignored")
			T.equal(loco:onBlocked(index, h.now), true, "ahead: re-request")
			T.equal(loco:status(), "waitingPath")
			T.equal(loco.lastRequest.priority, 0, "urgent")
			T.equal(h:count("blocked"), 0, "event flows out on the next tick")
			h:run(0.2)
			T.equal(h:count("blocked"), 1)
			T.equal(loco:onBlocked(1, h.now), false, "no follower while waiting")
			h:run(1)
			T.equal(loco:status(), "following", "the new path arrived")
			T.equal(loco:onBlocked(loco:followerIndex(), h.now), true, "second")
			h:run(0.2)
			T.equal(loco:status(), "following", "an urgent request is answered on the next step")
			T.equal(loco:onBlocked(loco:followerIndex(), h.now), false, "debounced within 0.5 s of the last")
			h:run(0.5)
			T.equal(loco:status(), "following")
			T.equal(loco:onBlocked(loco:followerIndex(), h.now), true, "third in twenty seconds")
			h:run(0.2)
			T.equal(h:count("abandon"), 1, "gave the goal up")
			T.equal(h:count("blocked"), 2)
			T.equal(loco:status(), "idle")
			T.equal(loco:brainView(body:state()).status, "failed")
		end)

		T.it("direct beeline for short goals", function()
			local planner = gridPlanner()
			local loco = makeLoco(planner)
			local body = Sim.fromGrid(grid, spawn)
			local goal = spawn + Vector3.new(10, 0, 0)
			loco:setIntent(goto_(goal), body:state(), 0)
			T.equal(loco:status(), "waitingPath")
			T.equal(loco.lastRequest.forceProvider, "direct", "asked for a beeline")
			for _, c in planner:step(0) do
				loco:onPathResult(c, 0)
			end
			T.equal(loco:status(), "following", "a follower on the very next planner step")
			local out = loco:tick(body:state(), {}, 0, 0.1, -math.huge)
			T.equal(#out.events, 1)
			T.equal(out.events[1].kind, "tripStarted")
			T.equal(out.tripId, 1)
			local result = loco.lastResult
			T.check(#result.waypoints >= 2, `waypoints {#result.waypoints}`)
			-- A planner that honours the "direct" hint answers with the straight line (its own
			-- spacing); an older one answers a short clear goal from the grid.
			T.check(result.provider == "direct" or result.provider == "grid", result.provider)
			if result.provider == "direct" then
				local last = result.waypoints[#result.waypoints].position
				T.near(flatDistance(last, goal), 0, 1e-6, "the line ends at the goal")
			end
			T.equal(out.command.mode, "move")
			T.check(out.command.dir.X > 0.99, "walks straight at it")
		end)
	end)
end

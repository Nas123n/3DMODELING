-- NpcService under Lune (spec §2.32): synchronous fake movers, no requestSpawn unless a case
-- installs one. Every case is a small arena FakeWorld (the grid is sampled once per process).
return function(T, Loader)
	local roblox = require("@lune/roblox")
	local FakeWorld = require("../tools/lune/FakeWorld")
	local ScriptedPlayer = require("../tools/lune/Fakes/ScriptedPlayer")
	local Sim = require("../tools/lune/Sim")
	local Vector3 = roblox.Vector3

	local function flatDistance(a, b)
		local dx, dz = a.X - b.X, a.Z - b.Z
		return math.sqrt(dx * dx + dz * dz)
	end

	local function hasEvent(report, name)
		for _, e in report.events do
			if e == name then
				return true
			end
		end
		return false
	end

	local function insidePart(part, point)
		local local_ = part.CFrame:PointToObjectSpace(point)
		local half = part.Size / 2
		return math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z
	end

	T.describe("NpcService", function()
		T.it("spawn snaps to walkable and outside avoid", function()
			local world = FakeWorld.new(Loader.new(), { seed = "spawn" })
			local service = world.service
			local grid = world.grid
			for _ = 1, 20 do
				local id = service:spawn(world.now)
				local body = world.bodies[id]
				T.check(body ~= nil, `{id} has a body`)
				local ix, iz = grid:cellOf(body.position)
				T.check(grid:isWalkable(ix, iz), `{id} spawned on a walkable cell`)
				T.check(not service.world.pois:isAvoided(body.position), `{id} spawned outside the pool`)
				local spawn = world.made.spawn
				T.check(
					math.abs(body.position.X - spawn.CFrame.Position.X) <= spawn.Size.X / 2 + 8
						and math.abs(body.position.Z - spawn.CFrame.Position.Z) <= spawn.Size.Z / 2 + 8,
					`{id} spawned near the NpcSpawn area`
				)
			end
			T.equal(service:count(), 20)
			local frame = service:stepFrame(world.now + 0.1, 0.1)
			T.equal(frame.npcCount, 20)
			T.check(frame.ticks > 0, "ticks ran")
		end)

		T.it("despawn cancels planner and frees the scheduler slot", function()
			local world = FakeWorld.new(Loader.new(), { seed = "despawn" })
			local service = world.service
			local a = service:spawn(world.now)
			local b = service:spawn(world.now)
			world:run(8, 30)
			T.equal(service:count(), 2)
			service:despawn(a, "test", world.now)
			T.equal(service:count(), 1)
			T.equal(service.scheduler:count(), 1, "one scheduler slot left")
			T.equal(service:get(a), nil)
			T.check(service:get(b) ~= nil, "the other stays")
			T.equal(service.planner.pending[a], nil, "no pending request")
			for _, active in service.planner.active do
				T.check(active.request.agentId ~= a, "no active request for the despawned NPC")
			end
			for _, request in service.gridProvider.queue do
				T.check(request.agentId ~= a, "nothing queued at the grid provider")
			end
			T.equal(world.bodies[a], nil, "the body is gone")
			T.equal(world.connections:count(), 1, "the connections bag holds the survivor only")
			T.check(
				#world.log.leaves >= 1 and world.log.leaves[#world.log.leaves].npc == a,
				"the presenter saw the leave"
			)
			world:run(2, 30)
			T.equal(service:count(), 1)
		end)

		T.it("a throwing npc gets STOP and an error event", function()
			local world = FakeWorld.new(Loader.new(), { seed = "throw" })
			local service = world.service
			local Npc = world.session.require(world.session.game.ServerStorage.HumanlikeNpc.Runtime.Npc)
			local id = service:spawn(world.now)
			world:run(2, 30)
			local record = service.records[id]
			local mover = record.mover
			local read = mover.read
			local applied = {}
			local apply = mover.apply
			mover.apply = function(m, command)
				table.insert(applied, command)
				return apply(m, command)
			end
			-- Reads throw for exactly one frame (the frame the NPC is due in).
			local throwing = false
			mover.read = function(...)
				if throwing then
					error("body unreadable")
				end
				return read(...)
			end
			local errored = nil
			for _ = 1, 30 do
				throwing = true
				local reports = service:step(world.now + 0.1)
				world.now += 0.1
				throwing = false
				if reports[id] then
					errored = reports[id]
					break
				end
			end
			T.check(errored ~= nil, "the NPC ticked")
			T.check(hasEvent(errored, "error"), "the report carries the error event")
			T.equal(errored.command.mode, "stop", "a STOP report")
			T.check(applied[#applied] == Npc.STOP, "the mover received Npc.STOP")
			T.equal(service:stats().errors, 1)
			T.check(service:get(id) ~= nil, "one error does not despawn")
			-- The next frames tick normally.
			local normal = nil
			for _ = 1, 10 do
				local reports = service:step(world.now + 0.1)
				world.now += 0.1
				if reports[id] then
					normal = reports[id]
					break
				end
			end
			T.check(normal ~= nil and not hasEvent(normal, "error"), "the next tick is clean")
			T.equal(service:stats().errors, 1)
		end)

		T.it("error budget despawns a throwing npc", function()
			local world = FakeWorld.new(Loader.new(), { seed = "budget" })
			local service = world.service
			local id = service:spawn(world.now)
			world:run(1, 30)
			local record = service.records[id]
			record.mover.read = function()
				error("always broken")
			end
			local frames = 0
			while service:get(id) ~= nil and frames < 12 do
				service:step(world.now + 0.11)
				world.now += 0.11
				frames += 1
			end
			T.equal(service:get(id), nil, "the NPC is gone")
			T.equal(service:stats().errors, 5, "five errors tripped the budget")
			T.check(frames <= 6, `took {frames} frames`)
			T.equal(service:count(), 0)
			T.equal(world.log.leaves[#world.log.leaves].reason, "errors")
		end)

		T.it("shutdown makes everyone leave within 8 s", function()
			local world = FakeWorld.new(Loader.new(), { seed = "shutdown" })
			local service = world.service
			for _ = 1, 4 do
				service:spawn(world.now)
			end
			world:run(5, 30)
			T.equal(service:count(), 4)
			service:shutdown(world.now)
			world:run(8.1, 30)
			T.equal(service:count(), 0, "everyone left")
			T.equal(#world.log.leaves, 4, "the presenter saw four leaves")
		end)

		T.it("name collision shortens the session", function()
			local world = FakeWorld.new(Loader.new(), { seed = "collision" })
			local service = world.service
			local id = service:spawn(world.now)
			local other = service:spawn(world.now)
			world:run(1, 30)
			service:identity(id).displayName = "Zoe"
			local session = service:get(id).brain.session
			local otherSession = service:get(other).brain.session
			local before = session.leaveAt
			local otherBefore = otherSession.leaveAt
			T.check(before - world.now > 45, "a fresh session is longer than a collision leaves")
			service:onPlayerJoined(5, "Zoe", world.now)
			T.check(session.leaveAt - world.now <= 45, `leaveAt - now = {session.leaveAt - world.now}`)
			T.check(session.leaveAt - world.now >= 5, "not immediately")
			T.equal(otherSession.leaveAt, otherBefore, "the other NPC is untouched")
			-- The newcomer's name is never handed out while they are here.
			for _ = 1, 10 do
				local extra = service:spawn(world.now)
				local identity = service:identity(extra)
				T.check(string.lower(identity.displayName) ~= "zoe" and string.lower(identity.username) ~= "zoe")
			end
		end)

		T.it("requestSpawn defers body building", function()
			local world = FakeWorld.new(Loader.new(), {
				seed = "request",
				population = true,
				players = { ScriptedPlayer.wanderer("1", "Zoe", Vector3.new(-20, 0, 20), Vector3.new(30, 0, -10)) },
			})
			local service = world.service
			local requests = {}
			world.adapter.requestSpawn = function(n, pairWith)
				table.insert(requests, { n = n, pairWith = pairWith })
			end
			local created = 0
			local createMover = world.adapter.createMover
			world.adapter.createMover = function(...)
				created += 1
				return createMover(...)
			end
			local wanted = 0
			for _ = 1, 30 * 60 do
				world:step(1 / 30)
				wanted += world.lastFrame.wantSpawn
			end
			T.check(#requests >= 1, "the adapter was asked to build bodies")
			T.check(wanted >= 1, "FrameStats.wantSpawn reported the wish")
			T.equal(created, 0, "stepFrame never built a body itself")
			T.equal(service:count(), 0)
			-- The adapter comes back with a body it built: the NPC is registered on it.
			local body = Sim.fromGrid(world.grid, Vector3.zero, { walkSpeed = 16 })
			local teleported = nil
			local mover = {
				read = function()
					return body:state()
				end,
				apply = function() end,
				teleport = function(_, at)
					teleported = at
					body.position = at
				end,
			}
			local id = service:spawn(world.now, nil, nil, mover)
			T.equal(service:count(), 1)
			T.check(service.records[id].mover == mover, "the NPC drives the given body")
			T.check(teleported ~= nil, "the body was placed at the spawn")
			T.check(service.world.grid:isWalkable(service.world.grid:cellOf(teleported)), "on walkable ground")
			T.equal(created, 0)
			local frame = service:stepFrame(world.now + 0.1, 0.1)
			T.equal(frame.npcCount, 1)
		end)

		T.it("avoid exit", function()
			local world = FakeWorld.new(Loader.new(), { seed = "avoid" })
			local service = world.service
			local id = service:spawn(world.now)
			world:run(3, 30)
			local pool = world.made.avoid
			local center = pool.CFrame.Position
			world:teleportNpc(id, Vector3.new(center.X, 0, center.Z))
			local exitEvent = false
			local goal = nil
			world:run(1, 30, function(reportId, report)
				if reportId == id and hasEvent(report, "avoidExit") then
					exitEvent = true
				end
			end)
			local npc = service:get(id)
			goal = if npc.brain.override then npc.brain.override.position else nil
			T.check(exitEvent, "an avoidExit event was reported")
			T.check(service:stats().avoidExits >= 1, "counted")
			T.check(goal ~= nil, "the brain has an exit goal")
			T.check(not insidePart(pool, Vector3.new(goal.X, center.Y, goal.Z)), `the exit {goal} is outside the pool`)
			T.check(not service.world.pois:isAvoided(goal), "the exit is not avoided")
		end)

		T.it("died respawns or despawns", function()
			local world = FakeWorld.new(Loader.new(), { seed = "died" })
			local service = world.service
			local respawns, despawns = 0, 0
			local usernames = {}
			for _ = 1, 100 do
				local id = service:spawn(world.now)
				table.insert(usernames, service:identity(id).username)
				world:run(0.2, 30)
				service:onDied(id, world.now)
				if service:get(id) ~= nil then
					respawns += 1
					T.check(world.bodies[id] ~= nil, "a fresh body was bound")
					service:despawn(id, "died", world.now)
				else
					despawns += 1
				end
			end
			T.equal(respawns + despawns, 100)
			T.between(respawns, 60, 80, `respawns {respawns}`)
			T.equal(service:stats().respawns, respawns)
			T.equal(#world.log.resets, respawns, "each respawn went through the presenter's reset")
			for _, username in usernames do
				T.check(service.names.taken[string.lower(username)] == true, `{username} stayed taken`)
			end
			T.equal(next(service.reservedNames), nil, "nothing was quarantined")
			T.equal(service:count(), 0)
		end)

		T.it("discovery refresh invalidates a goal", function()
			local world = FakeWorld.new(Loader.new(), { seed = "discovery" })
			local service = world.service
			local pois = service.world.pois
			for _ = 1, 6 do
				service:spawn(world.now)
			end
			-- Find an NPC walking to a place.
			local walker, target = nil, nil
			local deadline = 240
			while walker == nil and world.now < deadline do
				local reports = world:step(1 / 30)
				for id, report in reports do
					if
						report.activity == "VisitPoi"
						and report.locomotion == "walking"
						and report.target
						and pois:get(report.target)
					then
						walker, target = id, report.target
						break
					end
				end
			end
			T.check(walker ~= nil, "an NPC was walking to a place")
			pois:removePoi(target)
			service:onDiscoveryRefresh(world.now)
			local invalidated = false
			for _ = 1, 10 do
				local reports = world:step(1 / 30)
				local report = reports[walker]
				if report and hasEvent(report, "goalInvalid") then
					invalidated = true
					break
				end
			end
			T.check(invalidated, "goalInvalid was reported on the next tick")
			T.check(service:get(walker).brain:describe().target ~= target, "the place is no longer the target")
			-- The shared view no longer lists the place.
			for _, poi in service.perceptionWorld.pois do
				T.check(poi.id ~= target, "the view was rebuilt")
			end
		end)

		T.it("chat lines carry their corpus id to the ears of other NPCs", function()
			local world = FakeWorld.new(Loader.new(), { seed = "lines" })
			local service = world.service
			local id = service:spawn(world.now)
			world:run(1, 30)
			-- A line the safety audit recorded (the overlay does this before the presenter speaks).
			service.safety:record(id, "greeting:hello there", "hello there", world.now, nil)
			service:notifySaid(id, "hello there", world.now)
			local heard = service.recentChats[#service.recentChats]
			T.equal(heard.fromId, "n:" .. id)
			T.equal(heard.lineId, "greeting:hello there")
			T.equal(service:stats().linesSaid, 1)
			-- A player's line names the NPC: it is due at once with a brain tick.
			local displayName = service:identity(id).displayName
			local body = world.bodies[id]
			service:onPlayerChat("42", `{displayName} hello`, body.position + Vector3.new(5, 0, 0), world.now)
			local entry = service.scheduler.entries[id]
			T.check(entry.woken, "the NPC was woken")
			T.equal(service.guard:stats(world.now).players1m, 1, "the guard counted the player's line")
			local frame = service:stepFrame(world.now + 0.01, 0.01)
			T.equal(frame.ticks, 1, "woken NPCs tick at once")
			T.equal(frame.brains, 1, "with a brain tick")
		end)
	end)
end

return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local Vector3, CFrame = roblox.Vector3, roblox.CFrame

	local session = Loader.new()
	local NavGrid = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.NavGrid)
	local GridPathProvider = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.GridPathProvider)
	local GoalResolver = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.GoalResolver)
	local PathPlanner = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.PathPlanner)
	local PoiRegistry = session.require(session.game.ServerStorage.HumanlikeNpc.World.PoiRegistry)
	local Scheduler = session.require(session.game.ServerStorage.HumanlikeNpc.Runtime.Scheduler)

	local world = Loader.new()
	local _, made = Scenes.arena(world)
	local grid = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
	grid:sample(world.world, { avoid = { made.avoid } })

	local pois = PoiRegistry.new()
	for _, name in { "shop", "hangoutA", "hangoutB", "viewpoint" } do
		local part = made[name]
		pois:addPoi({
			id = name,
			kind = part:GetAttribute("PoiKind"),
			position = Vector3.new(part.CFrame.Position.X, 0, part.CFrame.Position.Z),
			weight = part:GetAttribute("PoiWeight"),
			radius = part:GetAttribute("PoiRadius"),
		})
	end
	pois:addAvoid({ id = "pool", cframe = made.avoid.CFrame, size = made.avoid.Size })
	pois:addSpawn({ id = "spawn", cframe = made.spawn.CFrame, size = made.spawn.Size })

	local start = made.spawn.CFrame.Position
	local shop = made.shop.CFrame.Position

	-- A fake engine provider: answers after `delay` seconds with a canned result, or never.
	local function fakePrimary(delay, status)
		local p = { name = "roblox", queue = {}, cancelled = {} }
		function p:submit(request)
			table.insert(self.queue, { request = request, at = nil })
		end
		function p:cancel(id)
			for i, entry in self.queue do
				if entry.request.id == id then
					table.remove(self.queue, i)
					self.cancelled[id] = true
					return
				end
			end
		end
		function p:cancelAgent(agentId)
			for i = #self.queue, 1, -1 do
				if self.queue[i].request.agentId == agentId then
					table.remove(self.queue, i)
				end
			end
		end
		function p:inFlight()
			return #self.queue
		end
		function p:step(now)
			local out = {}
			for i = #self.queue, 1, -1 do
				local entry = self.queue[i]
				entry.at = entry.at or now
				if delay ~= nil and now - entry.at >= delay then
					table.remove(self.queue, i)
					local result
					if status == "Success" then
						local r = entry.request
						result = {
							status = "Success",
							waypoints = {
								{ position = r.start, action = "Walk" },
								{ position = r.goal, action = "Walk" },
							},
							provider = "roblox",
							cost = 1,
							goalDistance = 0,
						}
					else
						result = { status = "NoPath", waypoints = {}, provider = "roblox", cost = 0, goalDistance = 0 }
					end
					table.insert(out, { id = entry.request.id, agentId = entry.request.agentId, result = result })
				end
			end
			return out
		end
		return p
	end

	local nextId = 0
	local function req(agentId, from, to, priority, extra)
		nextId += 1
		local r = { id = nextId, agentId = agentId, start = from, goal = to, priority = priority or 1, issuedAt = 0 }
		for k, v in extra or {} do
			r[k] = v
		end
		return r
	end

	local function runUntil(planner, seconds, dt)
		local all = {}
		local now = 0
		while now <= seconds do
			for _, c in planner:step(now) do
				table.insert(all, c)
			end
			now += dt or 1 / 30
		end
		return all
	end

	T.describe("GridPathProvider", function()
		T.it("answers queued requests most urgent first, a few per step", function()
			local provider = GridPathProvider.new(grid, { maxPerStep = 2 })
			provider:submit({ id = 1, agentId = "a", start = start, goal = shop, priority = 3, issuedAt = 0 })
			provider:submit({ id = 2, agentId = "b", start = start, goal = shop, priority = 0, issuedAt = 0 })
			provider:submit({ id = 3, agentId = "c", start = start, goal = shop, priority = 1, issuedAt = 0 })
			local first = provider:step(0)
			T.equal(#first, 2)
			T.equal(first[1].id, 2, "priority 0 first")
			T.equal(first[2].id, 3)
			T.equal(first[1].result.status, "Success")
			T.equal(first[1].result.provider, "grid")
			T.equal(#provider:step(0), 1)
			T.equal(#provider:step(0), 0)
		end)

		T.it("replaces an agent's older request and honours penalties for a while", function()
			local provider = GridPathProvider.new(grid)
			provider:submit({ id = 1, agentId = "a", start = start, goal = shop, priority = 1, issuedAt = 0 })
			provider:submit({
				id = 2,
				agentId = "a",
				start = start,
				goal = made.hangoutB.CFrame.Position,
				priority = 1,
				issuedAt = 0,
			})
			local out = provider:step(0)
			T.equal(#out, 1)
			T.equal(out[1].id, 2, "newest wins")
			local cx, cz = grid:cellOf(Vector3.new(0, 0, 0))
			provider:addPenalty("a", { { cx, cz } }, 8, 5)
			T.equal(grid.cost[cz * grid.cols + cx + 1], 8)
			provider:step(6)
			T.equal(grid.cost[cz * grid.cols + cx + 1], nil, "penalty expired")
		end)
	end)

	T.describe("GoalResolver", function()
		T.it("offers points along the line and the nearest other POI", function()
			local resolver = GoalResolver.new(grid, pois)
			local candidates = resolver:candidates(start, shop, 3)
			T.check(#candidates >= 2, `candidates {#candidates}`)
			T.equal(candidates[1].reason, "lineFraction")
			T.near(candidates[1].fraction, 0.75, 1e-9)
			for _, c in candidates do
				local ix, iz = grid:cellOf(c.goal)
				T.check(grid:isWalkable(ix, iz), "candidates stand on walkable ground")
			end
			-- Cap respected.
			T.equal(#resolver:candidates(start, shop, 1), 1)
		end)
	end)

	T.describe("PathPlanner", function()
		T.it("plans through the grid when there is no engine provider and caches near-identical requests", function()
			local provider = GridPathProvider.new(grid)
			local planner = PathPlanner.new(nil, provider, GoalResolver.new(grid, pois), { cooldown = 1 })
			planner:request(req("a", start, shop), 0)
			local done = runUntil(planner, 0.2)
			T.equal(#done, 1)
			T.equal(done[1].result.status, "Success")
			T.equal(done[1].reason, "original")
			-- Same start/goal within the quantum, another agent: served from cache.
			planner:request(req("b", start + Vector3.new(0.5, 0, 0.5), shop, 1), 0.3)
			local hit = runUntil(planner, 0.5)
			T.equal(#hit, 1)
			T.check(planner:getStats().cacheHits == 1, "one cache hit")
		end)

		T.it("spaces one agent's requests by the cooldown and lets the newest replace the pending one", function()
			local provider = GridPathProvider.new(grid)
			local planner = PathPlanner.new(nil, provider, GoalResolver.new(grid, pois), { cooldown = 1, cacheTtl = 0 })
			planner:request(req("a", start, shop), 0)
			planner:request(req("a", start, made.hangoutA.CFrame.Position), 0.1) -- inside cooldown: pending
			planner:request(req("a", start, made.hangoutB.CFrame.Position), 0.2) -- replaces the pending one
			local done = runUntil(planner, 1.5)
			T.equal(#done, 2, "first and the replacement")
			T.check(done[2].goal.Z == made.hangoutB.CFrame.Position.Z, "the newest pending request was the one planned")
			T.check(done[2].id > done[1].id)
		end)

		T.it("falls back from the engine to the grid on NoPath and on timeout", function()
			local noPath = fakePrimary(0.05, "NoPath")
			local planner = PathPlanner.new(
				noPath,
				GridPathProvider.new(grid),
				GoalResolver.new(grid, pois),
				{ robloxTimeout = 0.5 }
			)
			planner:request(req("a", start, shop), 0)
			local done = runUntil(planner, 1)
			T.equal(#done, 1)
			T.equal(done[1].result.provider, "grid")
			T.equal(done[1].result.status, "Success")
			T.equal(planner:getStats().fallbacks, 1)

			local never = fakePrimary(nil, "Success")
			local p2 = PathPlanner.new(
				never,
				GridPathProvider.new(grid),
				GoalResolver.new(grid, pois),
				{ robloxTimeout = 0.5 }
			)
			p2:request(req("a", start, shop), 0)
			local d2 = runUntil(p2, 1.5)
			T.equal(#d2, 1)
			T.equal(d2[1].result.provider, "grid", "timed out engine request answered by the grid")
			T.check(never.cancelled[d2[1].id] or #never.queue == 0, "engine request cancelled")
		end)

		T.it("limits engine requests in flight and admits the rest as slots free", function()
			local slow = fakePrimary(0.2, "Success")
			local planner = PathPlanner.new(
				slow,
				GridPathProvider.new(grid),
				GoalResolver.new(grid, pois),
				{ maxInFlightRoblox = 2 }
			)
			for i = 1, 5 do
				planner:request(req(`n{i}`, start, shop), 0)
			end
			planner:step(0)
			T.check(slow:inFlight() <= 2, `in flight {slow:inFlight()}`)
			local done = runUntil(planner, 2)
			T.equal(#done, 5, "everyone gets a path")
			for _, c in done do
				T.equal(c.result.provider, "roblox")
			end
		end)

		T.it("resolves an unreachable goal to a stand-in and reports the reason", function()
			-- Far outside the arena walls: nothing walkable near it, so the grid says NoPath.
			local outside = Vector3.new(-75, 0, 0)
			local planner = PathPlanner.new(nil, GridPathProvider.new(grid), GoalResolver.new(grid, pois), {})
			planner:request(req("a", start, outside, 1), 0)
			local done = runUntil(planner, 1)
			T.equal(#done, 1)
			T.equal(done[1].result.status, "Success")
			T.equal(done[1].reason, "lineFraction")
			T.check(planner:getStats().fallbacks >= 1)
		end)

		T.it("accepts a partial path when it gets most of the way there", function()
			-- A pillar top without being allowed to jump: the path ends at the pillar's foot.
			local top = made.pillars[1].CFrame.Position
			local planner = PathPlanner.new(nil, GridPathProvider.new(grid), GoalResolver.new(grid, pois), {})
			planner:request(req("a", start, Vector3.new(top.X, 6, top.Z), 1, { canJump = false }), 0)
			local done = runUntil(planner, 1)
			T.equal(#done, 1)
			T.equal(done[1].result.status, "Partial")
			T.check(done[1].result.goalDistance < 8, `ends at the pillar, {done[1].result.goalDistance}`)
			T.equal(done[1].reason, "original")
		end)

		T.it("falls back to a straight line for a short clear hop with no grid coverage", function()
			local empty = NavGrid.new({ minX = 0, minZ = 0, maxX = 4, maxZ = 4, cellSize = 2 })
			local planner = PathPlanner.new(nil, GridPathProvider.new(empty), GoalResolver.new(empty, nil), {
				losCheck = function()
					return true
				end,
			})
			planner:request(req("a", Vector3.new(100, 0, 100), Vector3.new(110, 0, 100)), 0)
			local done = runUntil(planner, 1)
			T.equal(#done, 1)
			T.equal(done[1].result.provider, "direct")
			T.check(#done[1].result.waypoints >= 2)
			planner:request(req("a", Vector3.new(100, 0, 100), Vector3.new(200, 0, 100)), 5)
			local far = runUntil(planner, 6)
			T.equal(far[#far].result.status, "NoPath", "too far for a straight line")
		end)
	end)

	T.describe("Scheduler", function()
		T.it("ticks near NPCs often, far ones rarely, spreads phases and caps per frame", function()
			local scheduler = Scheduler.new()
			for i = 1, 20 do
				scheduler:add(`n{i}`, (i * 0.37) % 1, 0)
			end
			local distances = {}
			for i = 1, 20 do
				distances[`n{i}`] = if i <= 10 then 10 else 400
			end
			scheduler:assignTiers(distances)
			T.equal(scheduler:tierOf("n1"), "near")
			T.equal(scheduler:tierOf("n20"), "far")
			local counts = {}
			local maxPerFrame = 0
			local now, dt = 0, 1 / 60
			while now < 10 do
				local due = scheduler:due(now)
				maxPerFrame = math.max(maxPerFrame, #due)
				for _, id in due do
					counts[id] = (counts[id] or 0) + 1
					scheduler:markTicked(id, now)
				end
				now += dt
			end
			T.check(maxPerFrame <= 8, `per-frame cap {maxPerFrame}`)
			T.between(counts.n1, 80, 105, `near ticks in 10 s: {counts.n1}`)
			T.between(counts.n20, 15, 22, `far ticks in 10 s: {counts.n20}`)
		end)

		T.it("uses hysteresis so a boundary hover does not flap, and brain divisors", function()
			local scheduler = Scheduler.new()
			scheduler:add("a", 0.5, 0)
			scheduler:assignTiers({ a = 50 })
			T.equal(scheduler:tierOf("a"), "near")
			scheduler:assignTiers({ a = 70 }) -- past 60 but within 60 * 1.25
			T.equal(scheduler:tierOf("a"), "near", "stays near inside the band")
			local changes = scheduler:assignTiers({ a = 80 })
			T.equal(scheduler:tierOf("a"), "mid")
			T.equal(#changes, 1)
			T.equal(changes[1].to, "mid")
			scheduler:assignTiers({ a = 65 })
			T.equal(scheduler:tierOf("a"), "mid", "promotion needs to drop below the threshold")
			scheduler:assignTiers({ a = 59 })
			T.equal(scheduler:tierOf("a"), "near")
			local brainTicks = 0
			for i = 1, 10 do
				if scheduler:markTicked("a", i * 0.1) then
					brainTicks += 1
				end
			end
			T.equal(brainTicks, 2, "near tier thinks every 5th tick")
		end)
	end)
end

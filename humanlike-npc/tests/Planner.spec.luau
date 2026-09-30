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

	-- A fake engine provider: answers after `delay` seconds with a canned result (Success, or any
	-- failure status), or never.
	local function fakePrimary(delay, status)
		local p = { name = "roblox", queue = {}, cancelled = {}, submitted = 0 }
		function p:submit(request)
			self.submitted += 1
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
						result = { status = status, waypoints = {}, provider = "roblox", cost = 0, goalDistance = 0 }
					end
					table.insert(out, { id = entry.request.id, agentId = entry.request.agentId, result = result })
				end
			end
			return out
		end
		return p
	end

	-- A fake grid provider that only records what it is asked and never answers.
	local function fakeGrid()
		local p = { name = "grid", submitted = {} }
		function p:submit(request)
			table.insert(self.submitted, request)
		end
		function p:cancel() end
		function p:cancelAgent() end
		function p:inFlight()
			return 0
		end
		function p:step()
			return {}
		end
		return p
	end

	-- A budgeted-mode `spent` stand-in: every call after the first reports one more 64-node resume.
	local function fakeSpent()
		local calls = 0
		return function()
			local ms = calls * 0.02 * 64
			calls += 1
			return ms
		end
	end

	local function sameWaypoints(a, b, message)
		T.equal(#a, #b, message)
		for i, w in a do
			T.equal(w.position, b[i].position, message)
			T.equal(w.action, b[i].action, message)
		end
	end

	local pillarTop = made.pillars[1].CFrame.Position

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

		T.it("sliced provider completes the same path over several steps", function()
			-- The pillar top without jumping is unreachable: an exhaustive search of the arena.
			local request = { id = 1, agentId = "a", start = start, goal = pillarTop, priority = 1, issuedAt = 0 }
			request.canJump = false
			local whole = GridPathProvider.new(grid)
			whole:submit(request)
			local sync = whole:step(0)[1].result
			T.equal(sync.status, "Partial")
			local exhaustive = grid:findPath(start, pillarTop, { jumpHeight = 0, maxNodes = 6000 })
			T.check(exhaustive.expanded >= 1500, `an exhaustive search, expanded {exhaustive.expanded}`)

			local provider = GridPathProvider.new(grid, { budgetMs = 1.5 })
			provider:submit(table.clone(request))
			local steps, done = 0, nil
			while steps < 100 and not done do
				steps += 1
				local out = provider:step(steps * 0.01, fakeSpent())
				if #out > 0 then
					done = out[1].result
				end
			end
			T.check(done ~= nil, "the sliced search completed")
			T.between(steps, 2, 60, `steps {steps}`)
			T.equal(done.status, sync.status)
			T.equal(done.cost, sync.cost)
			sameWaypoints(done.waypoints, sync.waypoints, "sliced and synchronous results agree")
			T.equal(provider:inFlight(), 0)
			-- Without a `spent` callback the provider estimates 20 us per node and behaves the same.
			local estimated = GridPathProvider.new(grid, { budgetMs = 1.5 })
			estimated:submit(table.clone(request))
			local steps2, done2 = 0, nil
			while steps2 < 100 and not done2 do
				steps2 += 1
				local out = estimated:step(steps2 * 0.01)
				if #out > 0 then
					done2 = out[1].result
				end
			end
			T.equal(steps2, steps, "same slicing without a spent callback")
			sameWaypoints(done2.waypoints, sync.waypoints)
		end)

		T.it("one active search; others wait", function()
			local provider = GridPathProvider.new(grid, { budgetMs = 1.5 })
			provider:submit({
				id = 1,
				agentId = "a",
				start = start,
				goal = pillarTop,
				priority = 1,
				canJump = false,
				issuedAt = 0,
			})
			provider:submit({
				id = 2,
				agentId = "b",
				start = start,
				goal = made.viewpoint.CFrame.Position,
				priority = 1,
				issuedAt = 0,
			})
			T.equal(#provider:step(0), 0, "nothing finishes in one slice")
			T.equal(provider:inFlight(), 2, "one active, one queued")
			T.check(provider.active ~= nil and provider.active.request.id == 1, "the first request is the live one")
			T.equal(#provider.queue, 1, "the other waits in the queue")
			local finishedAt = {}
			for i = 1, 200 do
				for _, c in provider:step(i * 0.01) do
					finishedAt[c.id] = i
					T.equal(c.result.status, if c.id == 1 then "Partial" else "Success")
				end
				if finishedAt[1] and finishedAt[2] then
					break
				end
			end
			T.check(finishedAt[1] ~= nil and finishedAt[2] ~= nil, "both complete")
			T.check(finishedAt[1] < finishedAt[2], "completions arrive on different steps, in order")
			T.equal(provider:inFlight(), 0)
		end)

		T.it("cancelling the live search drops it mid-way", function()
			local provider = GridPathProvider.new(grid, { budgetMs = 1.5 })
			provider:submit({
				id = 1,
				agentId = "a",
				start = start,
				goal = pillarTop,
				priority = 1,
				canJump = false,
				issuedAt = 0,
			})
			provider:step(0)
			T.equal(provider:inFlight(), 1)
			provider:cancelAgent("a")
			T.equal(provider:inFlight(), 0)
			for i = 1, 100 do
				T.equal(#provider:step(i * 0.01), 0, "a cancelled search never completes")
			end
		end)

		T.it("queue timeout", function()
			-- A tiny budget: 8 nodes per step, so the urgent search starves everything behind it.
			local provider = GridPathProvider.new(grid, { budgetMs = 0.1, yieldEvery = 8 })
			provider:submit({
				id = 1,
				agentId = "a",
				start = start,
				goal = pillarTop,
				priority = 0,
				canJump = false,
				issuedAt = 0,
			})
			provider:submit({ id = 2, agentId = "b", start = start, goal = shop, priority = 1, issuedAt = 0 })
			local timedOut = nil
			for i = 0, 62 do
				local now = i * 0.1
				for _, c in provider:step(now) do
					T.equal(c.id, 2, "only the waiting request completes")
					timedOut = { at = now, result = c.result }
				end
			end
			T.check(timedOut ~= nil, "the waiting request completed")
			T.equal(timedOut.result.status, "Timeout")
			T.equal(timedOut.result.provider, "grid")
			T.between(timedOut.at, 6, 6.15, `timed out at {timedOut.at}`)
			T.equal(provider:inFlight(), 1, "the starved search is still live")
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

		T.it("starved request completes direct", function()
			local never = fakePrimary(nil, "Success")
			local planner = PathPlanner.new(never, GridPathProvider.new(grid), GoalResolver.new(grid, pois), {
				robloxTimeout = 100,
				losCheck = function()
					return true
				end,
			})
			planner:request(req("a", start, start + Vector3.new(20, 0, 0)), 0)
			local when, completion = nil, nil
			local now = 0
			while now <= 8 do
				local out = planner:step(now)
				if #out > 0 and not completion then
					when, completion = now, out[1]
				end
				now += 1 / 30
			end
			T.check(completion ~= nil, "completed")
			T.between(when, 6, 6.05, `starved at {when}`)
			T.equal(completion.result.provider, "direct")
			T.equal(completion.result.status, "Success")
			T.equal(completion.reason, "starved")
			T.equal(never:inFlight(), 0, "engine request cancelled")
			T.equal(planner:getStats().inFlight, 0)
		end)

		T.it("five timeouts back the primary off", function()
			local flaky = fakePrimary(0, "Timeout")
			local planner = PathPlanner.new(
				flaky,
				GridPathProvider.new(grid, { maxPerStep = 5 }),
				GoalResolver.new(grid, pois),
				{ maxInFlightRoblox = 5, cacheTtl = 0 }
			)
			for i = 1, 5 do
				planner:request(req(`n{i}`, start, shop), 0)
			end
			local done = planner:step(0)
			T.equal(#done, 5, "each timed-out request fell to the grid on the same step")
			for _, c in done do
				T.equal(c.result.provider, "grid")
				T.equal(c.reason, "original")
			end
			T.equal(flaky.submitted, 5)
			T.near(planner:getStats().backoffUntil, 30, 1e-9, "backed off for 30 s")
			planner:request(req("n6", start, shop), 0.1)
			local sixth = planner:step(0.1)
			T.equal(#sixth, 1)
			T.equal(sixth[1].reason, "backoff")
			T.equal(sixth[1].result.provider, "grid")
			T.equal(flaky.submitted, 5, "the primary was skipped")
			planner:request(req("n7", start, shop), 31)
			planner:step(31)
			T.equal(flaky.submitted, 6, "after 30 s the primary is tried again")
		end)

		T.it("short trips get a small node budget", function()
			local fake = fakeGrid()
			local planner = PathPlanner.new(nil, fake, GoalResolver.new(grid, pois), {})
			planner:request(req("a", start, start + Vector3.new(10, 0, 0)), 0)
			planner:request(req("b", start, start + Vector3.new(0, 0, 200)), 0)
			planner:step(0)
			T.equal(#fake.submitted, 2)
			T.equal(fake.submitted[1].maxNodes, 400, "10 studs")
			T.equal(fake.submitted[2].maxNodes, 4000, "200 studs")
			-- The real provider honours it: a 20-node budget makes the exhaustive search partial and short.
			local tight = GridPathProvider.new(grid)
			tight:submit({
				id = 1,
				agentId = "a",
				start = start,
				goal = pillarTop,
				priority = 1,
				issuedAt = 0,
				maxNodes = 20,
			})
			T.equal(tight:step(0)[1].result.status, "Partial")
		end)

		T.it("off-grid start skips the grid", function()
			local high = Vector3.new(start.X, 30, start.Z)
			local fake = fakeGrid()
			local planner = PathPlanner.new(nil, fake, GoalResolver.new(grid, pois), {
				floorAt = function()
					return 0
				end,
				losCheck = function()
					return true
				end,
			})
			planner:request(req("a", high, high + Vector3.new(10, 0, 0)), 0)
			local done = planner:step(0)
			T.equal(#fake.submitted, 0, "the grid receives nothing")
			T.equal(#done, 1)
			T.equal(done[1].reason, "offGrid")
			T.equal(done[1].result.provider, "direct")
			T.equal(done[1].result.status, "Success")
			-- Without line of sight there is nothing left: NoPath.
			local blind = PathPlanner.new(nil, fake, GoalResolver.new(grid, pois), {
				floorAt = function()
					return 0
				end,
			})
			blind:request(req("a", high, high + Vector3.new(10, 0, 0)), 0)
			local d2 = blind:step(0)
			T.equal(#fake.submitted, 0)
			T.equal(d2[1].reason, "offGrid")
			T.equal(d2[1].result.status, "NoPath")
			-- On the floor the same trip goes to the grid as usual.
			blind:request(req("b", start, start + Vector3.new(10, 0, 0)), 0)
			T.equal(#fake.submitted, 1)
		end)

		T.it("shedding keeps near-tier latency under 2 s", function()
			local flaky = fakePrimary(0, "Timeout")
			local sliced = GridPathProvider.new(grid, { budgetMs = 1.5 })
			local planner = PathPlanner.new(flaky, sliced, GoalResolver.new(grid, pois), {
				maxInFlightRoblox = 5,
				cacheTtl = 0,
				losCheck = function()
					return true
				end,
			})
			for i = 1, 5 do
				planner:request(req(`t{i}`, start, shop), 0)
			end
			planner:step(0)
			T.check(planner:getStats().backoffUntil > 0, "primary backed off")
			for i = 1, 5 do
				planner:cancel(`t{i}`)
			end
			T.equal(sliced:inFlight(), 0)
			-- Two near requests, then twenty far ones, all in the same frame.
			for i = 1, 2 do
				planner:request(req(`near{i}`, start, shop, 0), 1)
			end
			for i = 1, 20 do
				planner:request(req(`far{i}`, start, made.hangoutA.CFrame.Position, 2), 1)
			end
			local nearDone, shed = {}, 0
			local now = 1
			while now <= 3 do
				for _, c in planner:step(now) do
					if string.sub(c.agentId, 1, 4) == "near" then
						nearDone[c.agentId] = now
						T.equal(c.result.status, "Success")
						T.equal(c.reason, "backoff")
					end
					if c.reason == "shed" then
						shed += 1
						T.equal(c.result.status, "NoPath", "too far for a straight line")
					end
				end
				now += 1 / 30
			end
			T.check(nearDone.near1 ~= nil and nearDone.near2 ~= nil, "near requests completed")
			T.check(nearDone.near1 - 1 <= 2 and nearDone.near2 - 1 <= 2, "within 2 s")
			T.check(shed >= 12, `shed {shed}`)
			T.equal(flaky.submitted, 5, "nothing reached the primary while backed off")
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

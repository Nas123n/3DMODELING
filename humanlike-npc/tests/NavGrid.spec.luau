return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local NavGrid = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.NavGrid)

	-- A flat 40x40 grid at cell size 2, all walkable at y = 0.
	local function openGrid()
		local grid = NavGrid.new({ minX = 0, minZ = 0, maxX = 40, maxZ = 40, cellSize = 2 })
		grid:fill(0, 0, 19, 19, 0)
		return grid
	end

	local function hasJump(waypoints)
		for _, w in waypoints do
			if w.action == "Jump" then
				return true
			end
		end
		return false
	end

	T.describe("NavGrid", function()
		T.it("walks a straight line across open ground as two waypoints", function()
			local grid = openGrid()
			local result = grid:findPath(Vector3.new(3, 0, 3), Vector3.new(37, 0, 33))
			T.equal(result.status, "Success")
			T.equal(#result.waypoints, 2, "smoothing should leave start and goal only")
			T.near(result.waypoints[2].position.X, 37, 1e-6)
			T.near(result.waypoints[2].position.Z, 33, 1e-6)
			T.check(result.expanded > 0, "expanded nodes")
		end)

		T.it("routes around a wall and never cuts a corner", function()
			local grid = openGrid()
			-- Wall across the middle (z cells 10) from x cell 0..16, leaving a door at 17..19.
			grid:fillBlocked(0, 10, 16, 10)
			local result = grid:findPath(Vector3.new(5, 0, 5), Vector3.new(5, 0, 35))
			T.equal(result.status, "Success")
			T.check(#result.waypoints >= 3, "must bend around the wall")
			-- Every consecutive pair must be a walkable straight line.
			for i = 2, #result.waypoints do
				T.check(
					grid:hasLineOfWalk(result.waypoints[i - 1].position, result.waypoints[i].position),
					`segment {i} crosses the wall`
				)
			end
			-- The path must pass through the door (x >= 34).
			local throughDoor = false
			for _, w in result.waypoints do
				if w.position.X >= 34 and math.abs(w.position.Z - 21) <= 4 then
					throughDoor = true
				end
			end
			T.check(throughDoor, "path should use the door")
		end)

		T.it("blocks diagonal moves that squeeze between two blocked cells", function()
			local grid = NavGrid.new({ minX = 0, minZ = 0, maxX = 6, maxZ = 6, cellSize = 2 })
			grid:fill(0, 0, 2, 2, 0)
			grid:block(1, 0)
			grid:block(0, 1)
			-- From (0,0) to (1,1) only diagonally, which is forbidden; other cells give a way around.
			grid:block(2, 0)
			grid:block(0, 2)
			local result = grid:findPath(Vector3.new(1, 0, 1), Vector3.new(3, 0, 3))
			T.check(result.status ~= "Success", "no legal route: diagonal squeeze must be refused")
		end)

		T.it("returns a partial path toward an unreachable goal", function()
			local grid = openGrid()
			grid:fillBlocked(10, 0, 10, 19) -- a wall: never jumped, no way around
			local result = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21))
			T.equal(result.status, "Partial")
			local last = result.waypoints[#result.waypoints].position
			T.check(last.X > 15 and last.X < 21, `partial path should end at the wall, got x={last.X}`)
		end)

		T.it("reports NoPath when the start has no walkable cell nearby", function()
			local grid = openGrid()
			grid:fill(0, 0, 19, 19)
			local result = grid:findPath(Vector3.new(3, 0, 3), Vector3.new(30, 0, 30))
			T.equal(result.status, "NoPath")
			T.equal(#result.waypoints, 0)
		end)

		T.it("uses a jump link to climb a ledge and none when jumping is disabled", function()
			local grid = openGrid()
			grid:fill(10, 0, 19, 19, 5) -- east half is a 5-stud ledge
			local withJump = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 5, 21))
			T.equal(withJump.status, "Success")
			T.check(hasJump(withJump.waypoints), "ledge needs a jump waypoint")
			local noJump = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 5, 21), { jumpHeight = 0 })
			T.check(noJump.status ~= "Success", "unreachable without jumping")
			local tooHigh = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 5, 21), { jumpHeight = 4 })
			T.check(tooHigh.status ~= "Success", "ledge taller than jump height")
		end)

		T.it("jumps a gap of missing cells but not one wider than maxJumpGap", function()
			local grid = openGrid()
			grid:fill(9, 0, 10, 19) -- 4-stud chasm
			local result = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21))
			T.equal(result.status, "Success")
			T.check(hasJump(result.waypoints), "gap needs a jump")
			local narrow = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21), { maxJumpGap = 2 })
			T.check(narrow.status ~= "Success", "gap wider than allowed")
			grid:fill(8, 0, 12, 19) -- 10-stud chasm
			local wide = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21))
			T.check(wide.status ~= "Success", "10-stud chasm is too wide")
		end)

		T.it("never smooths across a jump and never leaps over a wall", function()
			local grid = openGrid()
			grid:fill(9, 0, 10, 19)
			local result = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21))
			local jumpIndex = nil
			for i, w in result.waypoints do
				if w.action == "Jump" then
					jumpIndex = i
				end
			end
			T.check(jumpIndex ~= nil, "jump present")
			local before = result.waypoints[jumpIndex :: number].position
			local after = result.waypoints[jumpIndex :: number + 1].position
			T.check(math.abs(after.X - before.X) <= 8.01, "jump waypoints must be adjacent across the gap")
			local walled = openGrid()
			walled:fillBlocked(9, 0, 9, 19)
			T.check(
				walled:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21)).status ~= "Success",
				"no leaping walls"
			)
		end)

		T.it("prefers cheaper cells when costs are set", function()
			local grid = openGrid()
			for iz = 0, 19 do
				for ix = 0, 19 do
					if iz < 10 then
						grid:setCost(ix, iz, 5)
					end
				end
			end
			local result = grid:findPath(Vector3.new(3, 0, 15), Vector3.new(37, 0, 15))
			T.equal(result.status, "Success")
			-- The direct line at z = 15 is expensive; the path should dip into the cheap half.
			local dipped = false
			for _, w in result.waypoints do
				if w.position.Z >= 20 then
					dipped = true
				end
			end
			T.check(dipped, "path should detour through cheap cells")
		end)

		T.it("stays within the node budget and reports a partial result", function()
			local grid = openGrid()
			grid:fillBlocked(10, 0, 10, 19)
			local result = grid:findPath(Vector3.new(3, 0, 21), Vector3.new(37, 0, 21), { maxNodes = 20 })
			T.check(result.expanded <= 20, "budget respected")
			T.equal(result.status, "Partial")
		end)

		T.it("is deterministic", function()
			local grid = openGrid()
			grid:fillBlocked(0, 10, 16, 10)
			local a = grid:findPath(Vector3.new(5, 0, 5), Vector3.new(5, 0, 35))
			local b = grid:findPath(Vector3.new(5, 0, 5), Vector3.new(5, 0, 35))
			T.equal(#a.waypoints, #b.waypoints)
			for i, w in a.waypoints do
				T.equal(w.position, b.waypoints[i].position)
				T.equal(w.action, b.waypoints[i].action)
			end
		end)
	end)

	T.describe("NavGrid sampling from a world", function()
		local world = Loader.new()
		local _, made = Scenes.arena(world)
		local grid = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
		local walkable = grid:sample(world.world, { avoid = { made.avoid } })

		T.it("finds the floor, sees pillar tops as jump-up surfaces, keeps the platform and ramp", function()
			T.check(walkable > 2000, `only {walkable} walkable cells`)
			local px, pz = grid:cellOf(made.pillars[1].CFrame.Position)
			T.near(grid:floorAt(px, pz) :: number, 6, 0.01, "pillar top is a surface 6 studs up")
			-- Standing on a pillar takes a jump; without one the top is unreachable.
			local onto = grid:findPath(Vector3.new(0, 0, 0), made.pillars[1].CFrame.Position)
			T.equal(onto.status, "Success")
			T.check(hasJump(onto.waypoints), "getting onto the pillar needs a jump")
			local noJump = grid:findPath(Vector3.new(0, 0, 0), made.pillars[1].CFrame.Position, { jumpHeight = 0 })
			T.check(noJump.status ~= "Success", "no jump, no pillar")
			local plat = made.platform.CFrame.Position
			local cx, cz = grid:cellOf(plat)
			T.near(grid:floorAt(cx, cz) :: number, 6, 0.01, "platform top height")
			local mid = made.ramp.CFrame.Position
			local rx, rz = grid:cellOf(mid)
			local rampY = grid:floorAt(rx, rz)
			T.check(rampY ~= nil and rampY > 1 and rampY < 6, `ramp middle should be walkable mid-height, got {rampY}`)
			-- The west wall enters the footprint of the outermost cells: blocked, not void, so it is
			-- never leapt, and a goal inside it has no path when snapping is off.
			T.check(grid:isBlocked(0, 30), "cell against the west wall is blocked")
			T.equal(grid:findPath(Vector3.new(0, 0, 0), Vector3.new(-59, 0, 0), { snapRadius = 0 }).status, "NoPath")
		end)

		T.it("blocks the no-go area", function()
			local ax, az = grid:cellOf(made.avoid.CFrame.Position)
			T.check(not grid:isWalkable(ax, az), "avoid area center blocked")
			T.check(grid:isWalkable(ax + 6, az), "just outside the avoid area is fine")
		end)

		T.it("paths from spawn to the viewpoint via the ramp without jumping", function()
			local start = made.spawn.CFrame.Position
			local goal = made.viewpoint.CFrame.Position
			local result = grid:findPath(start, goal, { jumpHeight = 0 })
			T.equal(result.status, "Success")
			T.check(not hasJump(result.waypoints), "ramp route needs no jump")
			local last = result.waypoints[#result.waypoints].position
			T.near(last.Y, 6, 0.01, "arrives on the platform top")
			T.check(NavGrid.pathLength(result.waypoints) > 60, "spawn to platform is a long walk")
		end)

		T.it("paths from spawn to the viewpoint with jumps allowed too", function()
			local result = grid:findPath(made.spawn.CFrame.Position, made.viewpoint.CFrame.Position)
			T.equal(result.status, "Success")
		end)

		T.it("paths to the shop around the pillars", function()
			local result = grid:findPath(made.spawn.CFrame.Position, made.shop.CFrame.Position)
			T.equal(result.status, "Success")
			for i = 2, #result.waypoints do
				T.check(
					grid:hasLineOfWalk(result.waypoints[i - 1].position, result.waypoints[i].position),
					`segment {i} is not walkable`
				)
			end
		end)

		local corner, opposite = Vector3.new(-50, 0, -50), Vector3.new(50, 0, 50)

		T.it("yieldEvery slices and the result is identical", function()
			local plain = grid:findPath(corner, opposite)
			T.equal(plain.status, "Success")
			T.check(plain.expanded > 64, `a long search, expanded {plain.expanded}`)
			local thread = coroutine.create(function()
				return grid:findPath(corner, opposite, { yieldEvery = 64 })
			end)
			local resumes = 0
			local sliced = nil
			while true do
				local ok, result = coroutine.resume(thread)
				T.check(ok, `search failed: {tostring(result)}`)
				if coroutine.status(thread) == "dead" then
					sliced = result
					break
				end
				resumes += 1
			end
			T.equal(sliced.expanded, plain.expanded, "same expansions")
			T.equal(sliced.status, plain.status)
			T.equal(sliced.cost, plain.cost)
			T.equal(#sliced.waypoints, #plain.waypoints, "same waypoints")
			for i, w in plain.waypoints do
				T.equal(sliced.waypoints[i].position, w.position)
				T.equal(sliced.waypoints[i].action, w.action)
			end
			local expected = math.ceil(plain.expanded / 64) - 1
			T.between(resumes, expected - 1, expected + 1, `yields for {plain.expanded} nodes`)
		end)

		T.it("yieldEvery outside a coroutine is synchronous", function()
			local plain = grid:findPath(corner, opposite)
			local result = grid:findPath(corner, opposite, { yieldEvery = 64 })
			T.equal(result.expanded, plain.expanded)
			T.equal(#result.waypoints, #plain.waypoints)
		end)
	end)
end

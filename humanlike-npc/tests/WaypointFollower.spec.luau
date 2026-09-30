return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local FakeWorld = require("../tools/lune/FakeWorld")
	local Sim = require("../tools/lune/Sim")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local NavGrid = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.NavGrid)
	local WaypointFollower = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.WaypointFollower)

	local function wp(x, y, z, action)
		return { position = Vector3.new(x, y, z), action = action or "Walk" }
	end

	-- Runs the follower on a body until finished or the time limit; returns events seen.
	local function drive(follower, body, seconds, dt)
		local events = {}
		local now = 0
		local step = dt or 1 / 10
		while now < seconds do
			local out = follower:tick(body:state(), now)
			for _, e in out.events do
				table.insert(events, e)
			end
			if follower:isFinished() then
				break
			end
			body:step(out.command, step)
			now += step
		end
		return events, now
	end

	local function count(events, kind)
		local n = 0
		for _, e in events do
			if e.kind == kind then
				n += 1
			end
		end
		return n
	end

	T.describe("WaypointFollower", function()
		T.it("walks a straight path to the end and reports each waypoint once", function()
			local follower = WaypointFollower.new({ wp(0, 0, 0), wp(20, 0, 0), wp(40, 0, 0) }, Vector3.new(0, 0, 0), 0)
			local body = Sim.new(Vector3.new(0, 0, 0))
			local events, elapsed = drive(follower, body, 10)
			T.check(follower:isFinished(), "should finish")
			T.equal(count(events, "finished"), 1)
			T.check(count(events, "waypoint") >= 2, "intermediate waypoints reported")
			T.near(body.position.X, 40, 1.2, "arrives at the end")
			T.between(elapsed, 2.3, 3.2, "40 studs at 16 studs/s")
		end)

		T.it("cuts corners with lookahead but never looks past a climb", function()
			-- A small zig-zag: lookahead should aim past the middle point when it is within reach.
			local path = { wp(0, 0, 0), wp(4, 0, 2), wp(8, 0, 0), wp(30, 0, 0) }
			local follower = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0, { lookahead = 10 })
			local out = follower:tick(Sim.new(Vector3.new(0, 0, 0)):state(), 0)
			T.check(out.target and out.target.X == 8, `aims past the zig within lookahead, got {out.target}`)
			local short = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0, { lookahead = 5 })
			local o = short:tick(Sim.new(Vector3.new(0, 0, 0)):state(), 0)
			T.check(o.target and o.target.X == 4, "a short lookahead aims at the next waypoint")

			local climb = { wp(0, 0, 0), wp(4, 0, 0), wp(8, 5, 0), wp(12, 5, 0) }
			local f2 = WaypointFollower.new(climb, Vector3.new(0, 0, 0), 0, { lookahead = 20 })
			local o2 = f2:tick(Sim.new(Vector3.new(0, 0, 0)):state(), 0)
			T.check(o2.target and o2.target.X <= 4.01, "must not look past a 5-stud rise")
		end)

		T.it("respects a line-of-sight callback", function()
			local path = { wp(0, 0, 0), wp(4, 0, 0), wp(8, 0, 0), wp(12, 0, 0) }
			local follower = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0, {
				lookahead = 50,
				losCheck = function(_, to)
					return to.X <= 8
				end,
			})
			local out = follower:tick(Sim.new(Vector3.new(0, 0, 0)):state(), 0)
			T.check(out.target and out.target.X == 8, `lookahead stops where LOS ends, got {out.target}`)
		end)

		T.it("jumps at a Jump waypoint and lands on the far side", function()
			local grid = NavGrid.new({ minX = 0, minZ = 0, maxX = 40, maxZ = 10, cellSize = 2 })
			grid:fill(0, 0, 19, 4, 0)
			grid:fill(9, 0, 10, 4) -- 4-stud chasm at x 18..22
			local result = grid:findPath(Vector3.new(3, 0, 5), Vector3.new(37, 0, 5))
			T.equal(result.status, "Success")
			local follower = WaypointFollower.new(result.waypoints, Vector3.new(3, 0, 5), 0)
			local body = Sim.fromGrid(grid, Vector3.new(3, 0, 5))
			local events = drive(follower, body, 15)
			T.equal(count(events, "jumpStart"), 1, "one jump")
			T.equal(count(events, "jumpLanded"), 1, "landed")
			T.equal(count(events, "jumpFailed"), 0)
			T.check(follower:isFinished(), "reaches the far side")
			T.check(body.jumps == 1, "the body jumped once")
			T.near(body.position.X, 37, 1.2)
		end)

		T.it("reports a failed jump when the body never leaves the ground", function()
			local path = { wp(0, 0, 0), wp(6, 0, 0, "Jump"), wp(12, 0, 0) }
			local follower = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0)
			local body = Sim.new(Vector3.new(0, 0, 0))
			-- A body that ignores jump requests.
			local original = body.step
			body.step = function(self, command, dt)
				local c = table.clone(command)
				c.jump = false
				return original(self, c, dt)
			end
			local events = drive(follower, body, 6)
			T.check(count(events, "jumpStart") >= 1)
			T.equal(count(events, "jumpFailed"), 1, "gives up after retries")
			T.check(follower:isPaused(), "holds for recovery")
			follower:resume()
			T.check(not follower:isPaused())
		end)

		T.it("reports a timeout when no progress is made on a leg", function()
			local path = { wp(0, 0, 0), wp(40, 0, 0) }
			local follower = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0)
			local body = Sim.new(Vector3.new(0, 0, 0), {
				blockedAt = function(x)
					return x > 5
				end,
			})
			local events = drive(follower, body, 12)
			T.check(count(events, "timeout") >= 1, "timeout reported")
			T.check(not follower:isFinished())
		end)

		T.it("holds at a Custom waypoint until resumed", function()
			local path = { wp(0, 0, 0), wp(6, 0, 0, "Custom"), wp(12, 0, 0) }
			path[2].label = "UseBoat"
			local follower = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0)
			local body = Sim.new(Vector3.new(0, 0, 0))
			local events = drive(follower, body, 3)
			T.equal(count(events, "custom"), 1)
			T.check(not follower:isFinished(), "paused at the link")
			T.near(body.position.X, 6, 1.5)
			follower:resume()
			drive(follower, body, 3)
			T.check(follower:isFinished(), "continues after resume")
		end)

		T.it("offsets corners, moves the final target and rewinds the walked path", function()
			local path = { wp(0, 0, 0), wp(10, 0, 0), wp(10, 0, 10), wp(20, 0, 10) }
			local follower = WaypointFollower.new(path, Vector3.new(0, 0, 0), 0, { lookahead = 0 })
			T.check(follower:offsetCorner(2, Vector3.new(-1, 0, 1)), "corner 2 can be clipped")
			T.check(not follower:offsetCorner(4, Vector3.new(1, 0, 0)), "the last waypoint is not a corner")
			T.near(follower.waypoints[2].position.X, 9, 1e-6)
			follower:setFinalTarget(Vector3.new(22, 0, 11))
			local body = Sim.new(Vector3.new(0, 0, 0))
			drive(follower, body, 10)
			T.check(follower:isFinished())
			T.near(body.position.X, 22, 1.2, "walks to the moved final target")
			local back = follower:rewind(8, body.position)
			T.check(#back >= 2, "rewind returns a polyline")
			local total = 0
			for i = 2, #back do
				total += (back[i] - back[i - 1]).Magnitude
			end
			T.near(total, 8, 0.5, "rewind covers the requested studs")
		end)

		T.it("follows a real grid path across the arena, ramp included", function()
			local world = Loader.new()
			local model, made = Scenes.arena(world)
			local grid = FakeWorld.sampledGrid(world, "arena", model) -- sampled once per process, shared
			local start = made.spawn.CFrame.Position
			local goal = made.viewpoint.CFrame.Position
			local result = grid:findPath(start, goal, { jumpHeight = 0 })
			T.equal(result.status, "Success")
			local follower = WaypointFollower.new(result.waypoints, start, 0, {
				losCheck = function(a, b)
					return grid:hasLineOfWalk(a, b)
				end,
			})
			local body = Sim.fromGrid(grid, Vector3.new(start.X, 0, start.Z))
			local events = drive(follower, body, 30)
			T.check(follower:isFinished(), "reaches the viewpoint")
			T.equal(count(events, "jumpFailed"), 0)
			T.near(body.position.Y, 6, 0.5, "ends on the platform")
			T.check(body.distance > 60, "walked a real distance")
		end)
	end)
end

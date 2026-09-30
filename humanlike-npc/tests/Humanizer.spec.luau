return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local Sim = require("../tools/lune/Sim")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local NavGrid = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.NavGrid)
	local NavMath = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.NavMath)
	local WaypointFollower = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.WaypointFollower)
	local InputProfile = session.require(session.game.ServerStorage.HumanlikeNpc.Human.InputProfile)
	local Humanizer = session.require(session.game.ServerStorage.HumanlikeNpc.Human.Humanizer)

	local world = Loader.new()
	local _, made = Scenes.arena(world)
	local grid = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
	grid:sample(world.world, { avoid = { made.avoid } })

	local function walkableCheck(point)
		local ix, iz = grid:cellOf(point)
		if grid:isWalkable(ix, iz) then
			return "walkable"
		elseif grid:isBlocked(ix, iz) then
			return "wall"
		end
		return "void"
	end

	local persona = {
		skill = 0.5,
		caution = 0.5,
		impulsivity = 0.5,
		stopBiasStuds = 0.8,
		aboutFaceRate = 0.07,
		wallBumpRate = 0.02,
	}

	-- An L-shaped corridor with walls: one sharp corner at (34, 6).
	local corridor = NavGrid.new({ minX = 0, minZ = 0, maxX = 40, maxZ = 40, cellSize = 2 })
	corridor:fillBlocked(0, 0, 19, 19)
	corridor:fill(0, 2, 18, 4, 0) -- along x, z in 4..10
	corridor:fill(16, 2, 18, 19, 0) -- along z, x in 32..38

	local function checkerFor(g)
		return function(point)
			local ix, iz = g:cellOf(point)
			if g:isWalkable(ix, iz) then
				return "walkable"
			elseif g:isBlocked(ix, iz) then
				return "wall"
			end
			return "void"
		end
	end

	-- Runs one humanized trip; returns stats.
	local function trip(seed, profileKind, from, to, overrides, seconds, gridOverride)
		local g = gridOverride or grid
		local rng = Rng.new(seed)
		local profile = InputProfile.sample(rng:fork("profile"), profileKind)
		local p = table.clone(persona)
		for k, v in overrides or {} do
			p[k] = v
		end
		local humanizer = Humanizer.new(rng:fork("human"), profile, p, { walkableCheck = checkerFor(g) })
		local result = g:findPath(from, to)
		local follower = WaypointFollower.new(result.waypoints, from, 0, {
			losCheck = function(a, b)
				return g:hasLineOfWalk(a, b)
			end,
		})
		humanizer:beginTrip(follower, 0, seed)
		local body = Sim.fromGrid(g, Vector3.new(from.X, 0, from.Z))
		local now, dt = 0, 0.1
		local stats =
			{ events = {}, magnitudes = {}, headings = {}, abandoned = false, finished = false, arrival = nil }
		while now < (seconds or 40) do
			local out = follower:tick(body:state(), now)
			for _, e in out.events do
				if e.kind == "jumpFailed" then
					follower:resume() -- recovery's job in the real runtime: retry the jump
				end
			end
			local h = humanizer:apply({
				command = out.command,
				body = body:state(),
				now = now,
				dt = dt,
				followerEvents = out.events,
			})
			for _, e in h.events do
				table.insert(stats.events, e.kind)
			end
			if h.abandonTrip then
				stats.abandoned = true
				break
			end
			if follower:isFinished() and not humanizer:isBusy() then
				stats.finished = true
				break
			end
			if h.command.mode == "move" then
				table.insert(stats.magnitudes, h.command.magnitude)
				table.insert(stats.headings, NavMath.yawOf(h.command.dir))
			end
			body:step(h.command, dt)
			now += dt
		end
		stats.arrival = body.position
		stats.elapsed = now
		return stats, result
	end

	local function count(list, kind)
		local n = 0
		for _, k in list do
			if k == kind then
				n += 1
			end
		end
		return n
	end

	local start = made.spawn.CFrame.Position
	local shop = made.shop.CFrame.Position

	T.describe("Humanizer", function()
		T.it("mobile trips still arrive, with varying speed and a wobbling heading", function()
			local stats = trip(1, "mobile", start, shop)
			T.check(stats.finished, "trip finishes")
			T.check(NavMath.flatDistance(stats.arrival, shop) < 5, `arrives near the shop, {stats.arrival}`)
			local minM, maxM = 1, 0
			for _, m in stats.magnitudes do
				minM, maxM = math.min(minM, m), math.max(maxM, m)
			end
			T.check(minM < 0.85 and maxM > 0.9, `analog magnitude varies: {minM}..{maxM}`)
			-- Heading changes between consecutive ticks are small but non-zero (wobble, no snapping).
			local tiny = 0
			for i = 2, #stats.headings do
				local d = math.abs(NavMath.wrap(stats.headings[i] - stats.headings[i - 1]))
				if d > 1e-4 and d < math.rad(10) then
					tiny += 1
				end
			end
			T.check(tiny > #stats.headings * 0.3, "most ticks carry a small heading wobble")
		end)

		T.it("pc trips snap to 45-degree headings relative to the camera and run at full speed", function()
			local stats = trip(2, "pc", start, shop)
			T.check(stats.finished, "trip finishes")
			for _, m in stats.magnitudes do
				T.equal(m, 1, "keyboard is binary")
			end
			-- Consecutive headings differ by 0 or multiples of 45 degrees (camera drift aside).
			local snapped = 0
			for i = 2, #stats.headings do
				local d = math.abs(NavMath.wrap(stats.headings[i] - stats.headings[i - 1]))
				local rem = d % (math.pi / 4)
				if d < 1e-4 or rem < 0.05 or rem > math.pi / 4 - 0.05 then
					snapped += 1
				end
			end
			T.check(snapped > #stats.headings * 0.6, `headings mostly snap ({snapped}/{#stats.headings})`)
		end)

		T.it("stop points spread around the goal instead of landing on one spot", function()
			local xs, zs = {}, {}
			for seed = 10, 39 do
				local stats = trip(seed, "pc", start, shop, { aboutFaceRate = 0, wallBumpRate = 0 }, 40)
				T.check(stats.finished, `seed {seed} finishes`)
				table.insert(xs, stats.arrival.X)
				table.insert(zs, stats.arrival.Z)
			end
			local function spread(list)
				local mean = 0
				for _, v in list do
					mean += v
				end
				mean /= #list
				local var = 0
				for _, v in list do
					var += (v - mean) ^ 2
				end
				return math.sqrt(var / #list)
			end
			T.check(spread(xs) + spread(zs) > 0.8, `arrival spread {spread(xs)} {spread(zs)}`)
		end)

		T.it("forced about-faces turn back and sometimes abandon the trip", function()
			local turned, abandoned = 0, 0
			for seed = 100, 139 do
				local stats = trip(seed, "pc", start, shop, { aboutFaceRate = 1 }, 40)
				if count(stats.events, "aboutFace") > 0 then
					turned += 1
				end
				if stats.abandoned then
					abandoned += 1
					T.check(count(stats.events, "aboutFaceAbandon") == 1)
				end
			end
			T.equal(turned, 40, "every trip turned around")
			T.between(abandoned / 40, 0.12, 0.5, "about 30% change their mind")
		end)

		T.it("hesitations, distractions and wall bumps fire when forced and the trip still completes", function()
			local hesitated, distracted, bumped = 0, 0, 0
			for seed = 200, 219 do
				local stats = trip(seed, "pc", start, made.viewpoint.CFrame.Position, {
					caution = 4, -- pushes the hesitation chance to 1
					impulsivity = 7, -- distraction chance to 1
					wallBumpRate = 1,
					aboutFaceRate = 0,
				}, 60)
				T.check(stats.finished, `seed {seed} finishes`)
				hesitated += count(stats.events, "hesitation")
				distracted += count(stats.events, "distraction")
				bumped += count(stats.events, "wallBump")
			end
			T.check(distracted >= 10, `distractions {distracted}`)
			-- Sharp corners live in the corridor: hesitations and wall bumps fire there.
			for seed = 240, 259 do
				local stats = trip(seed, "pc", Vector3.new(3, 0, 7), Vector3.new(35, 0, 37), {
					caution = 4,
					impulsivity = 0,
					wallBumpRate = 1,
					aboutFaceRate = 0,
				}, 60, corridor)
				T.check(stats.finished, `corridor seed {seed} finishes`)
				hesitated += count(stats.events, "hesitation")
				bumped += count(stats.events, "wallBump")
			end
			T.check(hesitated >= 10, `hesitations {hesitated}`)
			T.check(bumped >= 10, `wall bumps {bumped}`)
			-- A straight two-waypoint route still gets a mid-walk stop.
			local straight = 0
			for seed = 220, 229 do
				local stats = trip(
					seed,
					"pc",
					start,
					made.hangoutB.CFrame.Position,
					{ impulsivity = 7, aboutFaceRate = 0, wallBumpRate = 0 },
					30
				)
				T.check(stats.finished)
				straight += count(stats.events, "distraction")
			end
			T.check(straight >= 8, `straight-leg distractions {straight}`)
		end)

		T.it("far tier passes commands through untouched and default rates stay low", function()
			local rng = Rng.new(7)
			local profile = InputProfile.sample(rng, "mobile")
			local h = Humanizer.new(rng, profile, persona, { tier = "far" })
			local cmd = { mode = "move", dir = Vector3.new(0, 0, -1), magnitude = 1, jump = false }
			local out = h:apply({
				command = cmd,
				body = {
					position = Vector3.zero,
					velocity = Vector3.zero,
					onGround = true,
					state = "Running",
					walkSpeed = 16,
					yaw = 0,
				},
				now = 1,
				dt = 0.1,
				followerEvents = {},
			})
			T.equal(out.command.magnitude, 1)
			T.equal(out.command.dir, cmd.dir)

			local bumps, faces = 0, 0
			for seed = 300, 399 do
				local stats = trip(seed, "mobile", start, shop, nil, 40)
				bumps += count(stats.events, "wallBump")
				faces += count(stats.events, "aboutFace")
			end
			T.check(bumps <= 8, `wall bumps per 100 trips: {bumps}`)
			T.between(faces, 1, 20, `about-faces per 100 trips: {faces}`)
		end)
	end)
end

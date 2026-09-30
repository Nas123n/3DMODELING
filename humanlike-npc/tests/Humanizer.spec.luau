return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local FakeWorld = require("../tools/lune/FakeWorld")
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
	local model, made = Scenes.arena(world)
	local grid = FakeWorld.sampledGrid(world, "arena", model) -- sampled once per process, shared

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

	-- A hand-built path: each entry is { position, action? } (Walk unless given).
	local function path(points)
		local waypoints = {}
		for _, p in points do
			table.insert(waypoints, { position = p[1], action = p[2] or "Walk" })
		end
		return waypoints
	end

	-- Drives a humanizer over a ready follower and body until the trip ends or `seconds` pass.
	-- `onEvent(kind, now)` runs for every humanizer event so a case can poke the follower
	-- mid-event. Records event kinds, the windows in which the humanizer was busy and the body's
	-- position each tick, so a case can look at what the body did while an event ran.
	local function drive(humanizer, follower, body, seconds, onEvent)
		local now, dt = 0, 0.1
		local stats = { events = {}, busy = {}, trace = {}, finished = false, abandoned = false }
		local busySince = nil
		while now < seconds do
			local out = follower:tick(body:state(), now)
			for _, e in out.events do
				if e.kind == "jumpFailed" then
					follower:resume()
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
				if onEvent then
					onEvent(e.kind, now)
				end
			end
			if humanizer:isBusy() then
				busySince = busySince or now
			elseif busySince then
				table.insert(stats.busy, { from = busySince, to = now })
				busySince = nil
			end
			table.insert(stats.trace, { at = now, position = body.position })
			if h.abandonTrip then
				stats.abandoned = true
				break
			end
			if follower:isFinished() and not humanizer:isBusy() then
				stats.finished = true
				break
			end
			body:step(h.command, dt)
			now += dt
		end
		if busySince then
			table.insert(stats.busy, { from = busySince, to = now })
		end
		stats.elapsed = now
		return stats
	end

	-- The largest value of `measure(position)` over the ticks inside a busy window.
	local function peakDuring(stats, window, measure)
		local peak = -math.huge
		for _, entry in stats.trace do
			if entry.at >= window.from and entry.at <= window.to then
				peak = math.max(peak, measure(entry.position))
			end
		end
		return peak
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

		-- Bounded events: the fixes of the spec's "Humanizer EXTEND" item. Each case forces one
		-- event, makes it go wrong the way it did in the field, and checks the trip still ends
		-- with the follower running.
		local quiet =
			{ skill = 0.5, caution = -0.5, impulsivity = 0, stopBiasStuds = 0.8, aboutFaceRate = 0, wallBumpRate = 0 }

		T.it("an about-face that cannot walk back gives up after 4 s and hands the trip back", function()
			local from, to = Vector3.new(0, 0, 0), Vector3.new(120, 0, 0)
			local finished, abandoned = 0, 0
			for seed = 400, 409 do
				local rng = Rng.new(seed)
				local profile = InputProfile.sample(rng:fork("profile"), "mobile")
				local p = table.clone(quiet)
				p.aboutFaceRate = 1
				local humanizer = Humanizer.new(rng:fork("human"), profile, p)
				local follower = WaypointFollower.new(path({ { from }, { to } }), from, 0)
				humanizer:beginTrip(follower, 0, seed)
				-- A one-way floor: while the humanizer has the wheel the body cannot move back
				-- toward the start, which is what a wall across the rewound line looks like.
				local body
				body = Sim.new(from, {
					blockedAt = function(x, _z)
						return humanizer:isBusy() and x < body.position.X - 0.05
					end,
				})
				local stats = drive(humanizer, follower, body, 30)
				T.equal(count(stats.events, "aboutFace"), 1, `seed {seed} turned around`)
				T.check(stats.finished or stats.abandoned, `seed {seed} ends the trip`)
				T.check(not follower:isPaused(), `seed {seed} leaves the follower running`)
				local window = stats.busy[1]
				T.check(window ~= nil, `seed {seed} was busy with the about-face`)
				-- The brief stop of phase 1, then the 4 s walk-back limit, then straight back to the follower.
				T.between(window.to - window.from, 4, 4.6, `seed {seed} gave up after the limit`)
				if stats.finished then
					finished += 1
					T.check(NavMath.flatDistance(body.position, to) < 5, `seed {seed} arrives, {body.position}`)
				else
					abandoned += 1
					T.equal(count(stats.events, "aboutFaceAbandon"), 1, `seed {seed} reported the change of mind`)
				end
			end
			T.check(finished >= 5, `most trips finish ({finished})`)
			T.check(abandoned >= 1, `a planned change of mind still happens ({abandoned})`)
		end)

		T.it("an about-face that starts next to the follower's target is skipped", function()
			local from, to = Vector3.new(0, 0, 0), Vector3.new(0, 0, 40)
			local skipped, abandonedTrips = 0, 0
			for seed = 410, 419 do
				local rng = Rng.new(seed)
				local profile = InputProfile.sample(rng:fork("profile"), "pc")
				local p = table.clone(quiet)
				p.aboutFaceRate = 1
				local humanizer = Humanizer.new(rng:fork("human"), profile, p)
				local follower = WaypointFollower.new(path({ { from }, { to } }), from, 0)
				humanizer:beginTrip(follower, 0, seed)
				local body = Sim.new(from)
				local function tick(now)
					local out = follower:tick(body:state(), now)
					return humanizer:apply({
						command = out.command,
						body = body:state(),
						now = now,
						dt = 0.1,
						followerEvents = out.events,
					})
				end
				tick(0)
				-- Stand 1.5 studs short of the stop point when the about-face (due by 5 s) fires.
				body.position = follower.finalTarget - Vector3.new(0, 0, 1.5)
				local first = tick(5.5)
				T.equal(#first.events, 1, `seed {seed} fires the about-face`)
				T.equal(first.events[1].kind, "aboutFace")
				T.equal(first.command.mode, "stop", "phase 1 stops")
				-- Phase 1 lasts at most 0.3 s, so the tick at 6 s moves to phase 2; its first walking
				-- tick sees the target within 2 studs and gives up at once.
				tick(6)
				local second = tick(6.1)
				T.check(not humanizer:isBusy(), `seed {seed} handed the wheel back`)
				T.check(not follower:isPaused(), `seed {seed} leaves the follower running`)
				if second.abandonTrip then
					abandonedTrips += 1
					T.equal(#second.events, 1)
					T.equal(second.events[1].kind, "aboutFaceAbandon")
				else
					skipped += 1
					T.equal(second.command.mode, "move", `seed {seed} walks on the same tick`)
					T.check(second.command.dir.Z > 0.9, "toward the stop point")
				end
			end
			T.check(skipped >= 4, `most trips carry on ({skipped})`)
			T.check(abandonedTrips >= 1, `a planned change of mind still happens ({abandonedTrips})`)
		end)

		T.it("an event that ends on a paused follower resumes it", function()
			-- A link hold (Custom waypoint) at a sharp corner where a hesitation fires in the same
			-- tick: the follower pauses for a decision, the humanizer stops for its hesitation,
			-- and nobody else answers. The end of the hesitation must release the hold.
			for seed = 420, 424 do
				local rng = Rng.new(seed)
				local profile = InputProfile.sample(rng:fork("profile"), "pc")
				local p = table.clone(quiet)
				p.caution = 10 -- hesitation chance past 1 whatever the profile's jitter
				local humanizer = Humanizer.new(rng:fork("human"), profile, p)
				local waypoints = path({
					{ Vector3.new(0, 0, 0) },
					{ Vector3.new(20, 0, 0), "Custom" },
					{ Vector3.new(20, 0, 20) },
				})
				local follower = WaypointFollower.new(waypoints, Vector3.zero, 0)
				humanizer:beginTrip(follower, 0, seed)
				local body = Sim.new(Vector3.zero)
				local holdingDuringEvent = false
				local stats = drive(humanizer, follower, body, 20, function(kind)
					if kind == "hesitation" then
						holdingDuringEvent = follower:isPaused()
					end
				end)
				T.equal(count(stats.events, "hesitation"), 1, `seed {seed} hesitated at the link`)
				T.check(holdingDuringEvent, `seed {seed} follower was holding when the hesitation started`)
				T.check(stats.finished, `seed {seed} finishes`)
				T.check(not follower:isPaused(), `seed {seed} leaves the follower running`)
				T.check(NavMath.flatDistance(body.position, Vector3.new(20, 0, 20)) < 5, `seed {seed} arrives`)
			end
		end)

		T.it("a wall bump leans on the wall instead of sliding away along the old heading", function()
			-- The path turns sharply at a wall it meets at an angle, so a body holding the old
			-- heading slides along the wall (+Z) for the whole extra time. Steering at the wall
			-- probe point every tick keeps it by the corner. (The turn is 73 degrees so it stays
			-- past the 60-degree wall-bump threshold after any corner clip.)
			local corner = Vector3.new(10, 0, 3)
			local points = { { Vector3.zero }, { corner }, { Vector3.new(10, 0, 15) } }
			local function wallAt(x)
				return x >= 11
			end
			local longest = 0
			for seed = 430, 439 do
				local rng = Rng.new(seed)
				local profile = InputProfile.sample(rng:fork("profile"), "pc")
				local p = table.clone(quiet)
				p.wallBumpRate = 1
				local humanizer = Humanizer.new(rng:fork("human"), profile, p, {
					walkableCheck = function(point)
						return if wallAt(point.X) then "wall" else "walkable"
					end,
				})
				local follower = WaypointFollower.new(path(points), Vector3.zero, 0)
				humanizer:beginTrip(follower, 0, seed)
				local body = Sim.new(Vector3.zero, {
					blockedAt = function(x, _z)
						return wallAt(x)
					end,
				})
				local stats = drive(humanizer, follower, body, 30)
				T.equal(count(stats.events, "wallBump"), 1, `seed {seed} bumped`)
				T.check(stats.finished, `seed {seed} finishes`)
				T.check(not follower:isPaused(), `seed {seed} leaves the follower running`)
				local window = stats.busy[1]
				local peakZ = peakDuring(stats, window, function(position)
					return position.Z
				end)
				-- The probe sits at most ~5.5 studs along Z; holding the old heading would have slid
				-- 4.6 studs per second of extra time.
				T.check(peakZ < 8, `seed {seed} stayed by the corner while pushing (z {peakZ})`)
				longest = math.max(longest, window.to - window.from)
			end
			T.check(longest >= 1.5, `some bump pushed long enough to have slid away ({longest} s)`)

			-- With nothing to push against the bump is a short overshoot of the corner, not a
			-- walk into the distance for the extra time.
			for seed = 440, 449 do
				local rng = Rng.new(seed)
				local profile = InputProfile.sample(rng:fork("profile"), "pc")
				local p = table.clone(quiet)
				p.wallBumpRate = 1
				local humanizer = Humanizer.new(rng:fork("human"), profile, p)
				local follower = WaypointFollower.new(path(points), Vector3.zero, 0)
				humanizer:beginTrip(follower, 0, seed)
				local turn = follower.waypoints[2].position -- possibly clipped
				local body = Sim.new(Vector3.zero)
				local stats = drive(humanizer, follower, body, 30)
				T.equal(count(stats.events, "wallBump"), 1, `seed {seed} bumped`)
				T.check(stats.finished, `seed {seed} finishes`)
				T.check(not follower:isPaused(), `seed {seed} leaves the follower running`)
				local peak = peakDuring(stats, stats.busy[1], function(position)
					return NavMath.flatDistance(position, turn)
				end)
				T.check(peak <= 4.5, `seed {seed} overshoots the corner by little ({peak})`)
			end
		end)
	end)
end

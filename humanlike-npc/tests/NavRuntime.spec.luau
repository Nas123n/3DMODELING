return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Sim = require("../tools/lune/Sim")
	local Vector3 = roblox.Vector3

	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local StuckDetector = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.StuckDetector)
	local Steering = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.Steering)
	local Recovery = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.Recovery)
	local WaypointFollower = session.require(session.game.ServerStorage.HumanlikeNpc.Nav.WaypointFollower)

	local function wp(x, y, z, action)
		return { position = Vector3.new(x, y, z), action = action or "Walk" }
	end

	T.describe("StuckDetector", function()
		T.it("stays quiet on a clean walk and flags pushing against a wall", function()
			local detector = StuckDetector.new()
			local body = Sim.new(Vector3.new(0, 0, 0), {
				blockedAt = function(x)
					return x > 10
				end,
			})
			local follower = WaypointFollower.new({ wp(0, 0, 0), wp(40, 0, 0) }, body.position, 0)
			local now, dt = 0, 0.1
			local firstPush, firstStuck = nil, nil
			while now < 6 do
				local out = follower:tick(body:state(), now)
				body:step(out.command, dt)
				local verdict = detector:update(body:state(), 16 * out.command.magnitude, out.remaining, now)
				if verdict == "pushing" and not firstPush then
					firstPush = now
				elseif verdict == "stuck" and not firstStuck then
					firstStuck = now
				end
				if now < 0.5 then
					T.equal(verdict, "ok", "clean walking is ok")
				end
				now += dt
			end
			T.check(firstPush ~= nil, "pushing detected")
			-- Reaches the wall at ~0.6 s; pushing fires 0.6 s later.
			T.between(firstPush, 1.0, 1.6, `pushing at {firstPush}`)
		end)

		T.it("flags stuck when sliding without progress, and suppression delays it", function()
			local detector = StuckDetector.new({ stuckAfter = 1.0 })
			local body = {
				position = Vector3.new(0, 0, 0),
				velocity = Vector3.new(0, 0, 16),
				onGround = true,
				state = "Running",
				walkSpeed = 16,
				yaw = 0,
			}
			-- Velocity sideways, remaining never shrinks: sliding along a wall.
			local now, verdict = 0, "ok"
			local firstStuck = nil
			while now < 3 do
				verdict = detector:update(body, 16, 30, now)
				if verdict == "stuck" and not firstStuck then
					firstStuck = now
				end
				now += 0.05
			end
			T.check(firstStuck and firstStuck > 0.9 and firstStuck < 1.4, `stuck at {firstStuck}`)

			local d2 = StuckDetector.new({ stuckAfter = 1.0 })
			d2:suppress(0, 2)
			local firstStuck2 = nil
			now = 0
			while now < 4 do
				if d2:update(body, 16, 30, now) == "stuck" and not firstStuck2 then
					firstStuck2 = now
				end
				now += 0.05
			end
			T.check(firstStuck2 and firstStuck2 > 2.9, `suppressed until 2 then stuck at {firstStuck2}`)
		end)

		T.it("a brief snag decays away and airborne time never counts", function()
			local detector = StuckDetector.new()
			local moving = {
				position = Vector3.new(0, 0, 0),
				velocity = Vector3.new(16, 0, 0),
				onGround = true,
				state = "Running",
				walkSpeed = 16,
				yaw = 0,
			}
			local now, remaining = 0, 100
			for _ = 1, 20 do
				remaining -= 1.6
				T.equal(detector:update(moving, 16, remaining, now), "ok")
				now += 0.1
			end
			-- A 0.5 s snag: no progress.
			for _ = 1, 5 do
				T.equal(detector:update(moving, 16, remaining, now), "ok", "half a second is not stuck")
				now += 0.1
			end
			for _ = 1, 20 do
				remaining -= 1.6
				T.equal(detector:update(moving, 16, remaining, now), "ok")
				now += 0.1
			end
			local airborne = {
				position = Vector3.new(0, 3, 0),
				velocity = Vector3.zero,
				onGround = false,
				state = "Freefall",
				walkSpeed = 16,
				yaw = 0,
			}
			for _ = 1, 30 do
				T.equal(detector:update(airborne, 16, remaining, now), "ok", "airborne never counts")
				now += 0.1
			end
		end)
	end)

	T.describe("Steering", function()
		local function agent(id, x, z, vx, vz)
			return {
				id = id,
				kind = "player",
				position = Vector3.new(x, 0, z),
				velocity = Vector3.new(vx or 0, 0, vz or 0),
				yaw = 0,
				displayName = id,
				radius = 2,
				isMoving = (vx or 0) ~= 0 or (vz or 0) ~= 0,
			}
		end

		T.it("drifts sideways away from someone on a collision course, within the lateral cap", function()
			local steer = Steering.new(Rng.new(1), { ignoreChance = 0 })
			local out = steer:adjust({
				dir = Vector3.new(0, 0, -1),
				magnitude = 1,
				position = Vector3.new(0, 0, 0),
				velocity = Vector3.new(0, 0, -16),
				neighbors = { agent("a", 0.5, -6, 0, 16) },
				now = 0,
			})
			T.check(math.abs(out.dir.X) > 0.2, `should deviate sideways, got {out.dir}`)
			T.check(out.dir.Z < -0.7, "but keep mostly heading forward")
			T.check(not out.wantsJump)
		end)

		T.it("ignores neighbours far away or moving apart", function()
			local steer = Steering.new(Rng.new(2), { ignoreChance = 0 })
			local far = steer:adjust({
				dir = Vector3.new(0, 0, -1),
				magnitude = 1,
				position = Vector3.new(0, 0, 0),
				velocity = Vector3.new(0, 0, -16),
				neighbors = { agent("a", 0, -20, 0, 0), agent("b", 0, 6, 0, 16) },
				now = 0,
			})
			T.near(far.dir.X, 0, 1e-6, "no deviation")
		end)

		T.it("slows when blocked and after 0.7 s mostly hops over", function()
			local steer = Steering.new(Rng.new(3), { ignoreChance = 0 })
			local blocker = agent("b", 0, -3.5, 0, 0)
			local jumps, sidesteps, waits = 0, 0, 0
			for trial = 1, 200 do
				steer.blockedSince = {}
				local now = trial * 100
				local first = steer:adjust({
					dir = Vector3.new(0, 0, -1),
					magnitude = 1,
					position = Vector3.new(0, 0, 0),
					velocity = Vector3.zero,
					neighbors = { blocker },
					now = now,
				})
				T.equal(first.blockedBy, "b")
				T.near(first.magnitude, 0.6, 1e-6, "slowed by the shove")
				T.check(not first.wantsJump, "no instant reaction")
				local later = steer:adjust({
					dir = Vector3.new(0, 0, -1),
					magnitude = 1,
					position = Vector3.new(0, 0, 0),
					velocity = Vector3.zero,
					neighbors = { blocker },
					now = now + 0.8,
				})
				if later.wantsJump then
					jumps += 1
				elseif math.abs(later.dir.X) > 0.9 then
					sidesteps += 1
				else
					waits += 1
				end
			end
			T.between(jumps / 200, 0.55, 0.85, "hop share")
			T.between(sidesteps / 200, 0.1, 0.32, "walk-around share")
			T.check(waits > 0, "sometimes just waits")
		end)

		T.it("a share of neighbours is simply bumped into", function()
			local steer = Steering.new(Rng.new(4), { ignoreChance = 0.5 })
			local ignored = 0
			for i = 1, 200 do
				local out = steer:adjust({
					dir = Vector3.new(0, 0, -1),
					magnitude = 1,
					position = Vector3.new(0, 0, 0),
					velocity = Vector3.new(0, 0, -16),
					neighbors = { agent(`n{i}`, 0.5, -6, 0, 16) },
					now = i,
				})
				if math.abs(out.dir.X) < 1e-6 then
					ignored += 1
				end
			end
			T.between(ignored / 200, 0.35, 0.65)
		end)
	end)

	T.describe("Recovery", function()
		local body = {
			position = Vector3.new(0, 0, 0),
			velocity = Vector3.zero,
			onGround = true,
			state = "Running",
			walkSpeed = 16,
			yaw = 0,
		}
		local forward = Vector3.new(0, 0, -1)

		local function runEpisode(ladder, start)
			local kinds = {}
			local now = start
			for _ = 1, 400 do
				local action = ladder:tick(now)
				if #kinds == 0 or kinds[#kinds] ~= action.kind then
					table.insert(kinds, action.kind)
				end
				if action.kind == "abandon" or action.kind == "reset" then
					break
				end
				if not ladder:isActive() then
					break
				end
				now += 0.05
			end
			return kinds, now
		end

		T.it("starts at a nudge, then escalates through back-and-jump, repath and abandon", function()
			local ladder = Recovery.new(Rng.new(1))
			T.equal(ladder:onStuck(0, body, forward, "stuck", 3, 1), 0)
			local kinds = runEpisode(ladder, 0)
			T.equal(kinds[1], "pause")
			T.equal(kinds[2], "sidestep")
			T.equal(kinds[3], "forward")
			-- Sidestep went to the freer left side (probeLeft 3 > probeRight 1).
			local action = (function()
				local l = Recovery.new(Rng.new(1))
				l:onStuck(0, body, forward, "stuck", 3, 1)
				l:tick(0)
				return l:tick(0.6)
			end)()
			T.equal(action.kind, "sidestep")
			T.check(action.dir.X > 0.9 or action.dir.X < -0.9, "sidestep is perpendicular")

			-- No progress, stuck again soon: level 1.
			T.equal(ladder:onStuck(5, body, forward, "stuck"), 1)
			local k1 = runEpisode(ladder, 5)
			T.equal(k1[2], "backup")
			T.equal(k1[3], "face")
			T.equal(k1[4], "jump")
			T.equal(ladder:onStuck(10, body, forward, "stuck"), 2)
			local k2, t2 = runEpisode(ladder, 10)
			T.equal(k2[2], "repath")
			T.check(t2 - 10 > 5 and t2 - 10 < 8, `waits for the path then gives up after 5 s (took {t2 - 10})`)
			-- With a path that arrives but leads nowhere, the success test fails and the next stuck abandons.
			ladder:onPathArrived()
			T.equal(ladder:onStuck(20, body, forward, "stuck"), 3)
			local k3 = runEpisode(ladder, 15)
			T.equal(k3[#k3], "abandon")
		end)

		T.it("pushing skips the nudge, and progress resets the level", function()
			local ladder = Recovery.new(Rng.new(2))
			T.equal(ladder:onStuck(0, body, forward, "pushing"), 1)
			runEpisode(ladder, 0)
			ladder:onProgress(30, 40)
			T.equal(ladder:currentLevel(), 0, "clean progress for 20 s resets")
			T.equal(ladder:onStuck(31, body, forward, "stuck"), 0)
		end)

		T.it("a hopeless goal or a fall out of the world resets", function()
			local ladder = Recovery.new(Rng.new(3))
			local fallen = table.clone(body)
			fallen.position = Vector3.new(0, -100, 0)
			T.equal(ladder:onStuck(0, fallen, forward, "stuck"), 4)
			local kinds = runEpisode(ladder, 0)
			T.equal(kinds[#kinds], "reset")

			local slow = Recovery.new(Rng.new(4))
			slow:onStuck(0, body, forward, "stuck")
			runEpisode(slow, 0)
			slow:onStuck(30, body, forward, "stuck") -- 30 s on the same goal
			T.equal(slow:currentLevel(), 4)
		end)

		T.it("converts actions to move commands", function()
			local cmd = Recovery.toCommand({ kind = "backup", dir = Vector3.new(0, 0, 1), until_ = 1 }, forward)
			T.equal(cmd.mode, "move")
			T.equal(cmd.dir.Z, 1)
			local jump = Recovery.toCommand({ kind = "jump", dir = forward, until_ = 1 }, forward)
			T.check(jump.jump)
			local pause = Recovery.toCommand({ kind = "pause", until_ = 1 }, forward)
			T.equal(pause.mode, "stop")
		end)
	end)
end

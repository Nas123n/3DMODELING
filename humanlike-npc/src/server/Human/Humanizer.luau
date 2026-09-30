--!strict
-- The layer between "the shortest path" and "how a person walks it". At the start of every trip
-- it decides the trip's small imperfections (which corners get clipped, where the walk stops a
-- stud short or past, whether there is a hesitation, a distracted stop, an about-face, a wall
-- bump, an early or late jump) and edits the follower's waypoints accordingly. Every tick it
-- adds the continuous noise of the input device: thumbstick wobble, tremor, partial speed and
-- thumb lifts for analog profiles; camera lag and eight-way snapping for keyboard profiles.
--
-- Rates are deliberately low: a person who stumbles constantly reads as broken, not human. At
-- the defaults an NPC bumps a wall about once per fifty trips and turns around once in fourteen.

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Timing = require(script.Parent.Parent.Timing)
local Types = require(script.Parent.Parent.Types)
local CameraModel = require(script.Parent.CameraModel)
local InputProfile = require(script.Parent.InputProfile)
local WaypointFollower = require(script.Parent.Parent.Nav.WaypointFollower)

type Rng = Rng.Rng
type Profile = InputProfile.Profile
type MoveCommand = Types.MoveCommand
type BodyState = Types.BodyState
type Waypoint = Types.Waypoint
type Follower = WaypointFollower.Follower
type FollowerEvent = WaypointFollower.Event

local Humanizer = {}
Humanizer.__index = Humanizer

-- The persona knobs the humanizer reads (all 0..1 unless noted). Personality fills these.
export type Persona = {
	skill: number, -- practiced players clip fewer corners and bump fewer walls
	caution: number, -- hesitates at corners
	impulsivity: number, -- distraction stops, about-faces
	stopBiasStuds: number, -- mean of the final stop offset along the approach (positive = past)
	aboutFaceRate: number, -- per trip
	wallBumpRate: number, -- per trip
}

-- "near" | "mid" | "far" | "dormant"
export type Tier = string

-- Answers whether a point is standable ("walkable"), a wall to graze ("wall") or nothing ("void").
export type WalkableCheck = (point: Vector3) -> "walkable" | "wall" | "void"

export type Options = {
	walkableCheck: WalkableCheck?,
	tier: Tier?,
}

export type EventKind =
	"hesitation"
	| "distraction"
	| "aboutFace"
	| "aboutFaceAbandon"
	| "wallBump"
	| "correction"
	| "strafeLeg"

export type Event = { kind: EventKind, at: number }

type Planned = {
	kind: "hesitation" | "distraction" | "aboutFace" | "wallBump" | "correction",
	index: number?, -- waypoint index that triggers it
	at: number?, -- time that triggers it
	duration: number,
	magnitude: number?, -- mobile hesitation: slow instead of stop
	heading: Vector3?, -- wall bump: pre-corner heading
	extra: number?, -- wall bump: seconds to keep going
	abandon: boolean?, -- about-face: change of mind
	rewindStuds: number?,
	idealPoint: Vector3?, -- correction tap target
	pending: boolean?, -- triggered, waiting for the active event to end
}

type Active = {
	kind: string,
	phase: number,
	phaseEndsAt: number,
	plan: Planned,
	points: { Vector3 }?, -- about-face polyline
	pointIndex: number?,
	dir: Vector3?,
	magnitude: number?,
	pushingSince: number?,
}

export type Input = {
	command: MoveCommand,
	body: BodyState,
	now: number,
	dt: number,
	followerEvents: { FollowerEvent },
	stuckVerdict: ("ok" | "stuck" | "pushing")?,
}

export type Output = {
	command: MoveCommand,
	events: { Event },
	abandonTrip: boolean, -- the NPC changed its mind
}

export type HumanizerT = typeof(setmetatable(
	{} :: {
		rng: Rng,
		profile: Profile,
		persona: Persona,
		walkableCheck: WalkableCheck?,
		tier: Tier,
		camera: CameraModel.Camera?,
		follower: Follower?,
		waypoints: { Waypoint },
		tripStartedAt: number,
		tripRng: Rng,
		planned: { Planned },
		active: Active?,
		suppressedUntil: number,
		-- analog noise state
		phase1: number,
		phase2: number,
		tremor: number,
		ouMag: number,
		dipUntil: number,
		dipAmount: number,
		nextDipAt: number,
		microStopUntil: number,
		nextMicroStopAt: number,
		strafeLeg: boolean,
		arrived: boolean,
	},
	Humanizer
))

function Humanizer.new(rng: Rng, profile: Profile, persona: Persona, options: Options?): HumanizerT
	local o: Options = options or {}
	local camera = if profile.quantize8 or profile.camRateDegPerS > 0
		then CameraModel.new(0, math.max(profile.camRateDegPerS, 20), profile.camLag, profile.quantize8)
		else nil
	return setmetatable({
		rng = rng,
		profile = profile,
		persona = persona,
		walkableCheck = o.walkableCheck,
		tier = o.tier or "near",
		camera = camera,
		follower = nil,
		waypoints = {},
		tripStartedAt = 0,
		tripRng = rng:fork("trip:0"),
		planned = {},
		active = nil,
		suppressedUntil = -math.huge,
		phase1 = rng:range(0, math.pi * 2),
		phase2 = rng:range(0, math.pi * 2),
		tremor = 0,
		ouMag = 0,
		dipUntil = 0,
		dipAmount = 0,
		nextDipAt = 0,
		microStopUntil = 0,
		nextMicroStopAt = 0,
		strafeLeg = false,
		arrived = false,
	}, Humanizer)
end

function Humanizer.setTier(self: HumanizerT, tier: Tier)
	self.tier = tier
end

-- The end of any scripted no-progress moment, so the stuck detector can stay quiet.
function Humanizer.suppressUntil(self: HumanizerT): number
	return self.suppressedUntil
end

function Humanizer.isBusy(self: HumanizerT): boolean
	return self.active ~= nil
end

local function u(rng: Rng, lo: number, hi: number): number
	return rng:range(lo, hi)
end

local function turnAt(waypoints: { Waypoint }, i: number): (number, Vector3, Vector3)
	local a, b, c = waypoints[i - 1], waypoints[i], waypoints[i + 1]
	if not a or not b or not c then
		return 0, Vector3.zero, Vector3.zero
	end
	local din = NavMath.flatDirection(a.position, b.position)
	local dout = NavMath.flatDirection(b.position, c.position)
	if din.Magnitude == 0 or dout.Magnitude == 0 then
		return 0, din, dout
	end
	return math.abs(NavMath.turnAngle(din, dout)), din, dout
end

-- Plans this trip's imperfections and edits the follower's waypoints.
function Humanizer.beginTrip(self: HumanizerT, follower: Follower, now: number, tripId: number)
	self.follower = follower
	self.waypoints = follower.waypoints
	self.tripStartedAt = now
	self.tripRng = self.rng:fork(`trip:{tripId}`)
	self.planned = {}
	self.active = nil
	self.arrived = false
	self.strafeLeg = false
	local rng = self.tripRng
	local persona = self.persona
	local profile = self.profile
	local waypoints = self.waypoints
	local n = #waypoints
	follower.lookahead = profile.lookahead
	if n < 2 then
		return
	end

	-- 1. Corner clipping.
	local clipChance = 0.6 * (1.3 - 0.6 * persona.skill)
	for i = 2, n - 1 do
		local angle, din, dout = turnAt(waypoints, i)
		if angle > math.rad(25) and waypoints[i].action == "Walk" and rng:chance(clipChance) then
			local inside = (dout - din)
			if inside.Magnitude > 1e-6 then
				inside = inside.Unit
				local clip = rng:logNormalClamped(0.8, 0.4, 0.3, 1.5)
				local point = waypoints[i].position + inside * clip
				local verdict = if self.walkableCheck then self.walkableCheck(point) else "walkable"
				if verdict ~= "void" then
					follower:offsetCorner(i, inside * clip)
				end
			end
		end
	end

	-- 2. Final stop point and a possible correction tap.
	local last, secondLast = waypoints[n].position, waypoints[n - 1].position
	local approach = NavMath.flatDirection(secondLast, last)
	if approach.Magnitude > 0 then
		local perp = NavMath.perp(approach)
		local along = math.clamp(rng:gaussian(persona.stopBiasStuds, 1.2), -1.5, 3)
		local side = rng:gaussian(0, 0.8)
		local target = last + approach * along + perp * side
		local verdict = if self.walkableCheck then self.walkableCheck(target) else "walkable"
		if verdict == "walkable" then
			follower:setFinalTarget(target)
			if rng:chance(0.3) then
				table.insert(self.planned, {
					kind = "correction",
					index = n,
					duration = rng:logNormalClamped(0.5, 0.5, 0.3, 1.5),
					idealPoint = last,
				})
			end
		end
	end

	-- 3. Hesitations at sharp corners.
	local hesitationChance = 0.12 * (0.5 + persona.caution) * profile.hesitationScale
	for i = 2, n - 1 do
		local angle = turnAt(waypoints, i)
		if angle > math.rad(60) and rng:chance(hesitationChance) then
			if profile.analog then
				table.insert(
					self.planned,
					{ kind = "hesitation", index = i, duration = u(rng, 0.3, 0.6), magnitude = 0.6 }
				)
			else
				table.insert(self.planned, { kind = "hesitation", index = i, duration = u(rng, 0.15, 0.5) })
			end
		end
	end

	-- 4. One distracted mid-path stop: at an intermediate waypoint, or on a straight walk simply
	-- some seconds in (stopping to read chat).
	if rng:chance(0.15 * persona.impulsivity) then
		local duration = rng:logNormalClamped(1.2, 0.7, 0.4, 6)
		local candidates = {}
		for i = 2, n - 1 do
			if waypoints[i].action == "Walk" and waypoints[i - 1].action == "Walk" then
				table.insert(candidates, i)
			end
		end
		if #candidates > 0 then
			table.insert(
				self.planned,
				{ kind = "distraction", index = candidates[rng:int(1, #candidates)], duration = duration }
			)
		else
			local legSeconds = NavMath.flatDistance(waypoints[1].position, waypoints[n].position) / 16
			if legSeconds > 2 then
				table.insert(
					self.planned,
					{ kind = "distraction", at = now + u(rng, 1, legSeconds - 0.5), duration = duration }
				)
			end
		end
	end

	-- 5. About-face: forgot something, or changed my mind.
	if rng:chance(persona.aboutFaceRate) then
		table.insert(self.planned, {
			kind = "aboutFace",
			at = now + u(rng, 1, 5),
			duration = 0,
			rewindStuds = u(rng, 2, 6),
			abandon = rng:chance(0.3),
		})
	end

	-- 6. Wall bump at a sharp corner: keep walking straight, notice, back off, turn.
	if rng:chance(persona.wallBumpRate) then
		local corners = {}
		for i = 2, n - 1 do
			local angle, din = turnAt(waypoints, i)
			if angle > math.rad(60) then
				table.insert(corners, { index = i, heading = din })
			end
		end
		if #corners > 0 then
			local pick = corners[rng:int(1, #corners)]
			table.insert(self.planned, {
				kind = "wallBump",
				index = pick.index,
				heading = pick.heading,
				extra = rng:logNormalClamped(1.0, 0.6, 0.4, 3.0),
				duration = u(rng, 0.2, 0.6),
			})
		end
	end

	-- 7. Jump timing: early (most), on time, or late. Late only makes sense where the ground
	-- runs out past the take-off (a gap); at a ledge the body simply cannot get past it.
	for i = 1, n - 1 do
		if waypoints[i].action == "Jump" then
			local roll = rng:next()
			local leg = NavMath.flatDirection(waypoints[math.max(1, i - 1)].position, waypoints[i].position)
			local beyond = waypoints[i].position + leg * 1.5
			local gap = self.walkableCheck ~= nil and self.walkableCheck(beyond) == "void"
			if roll < 0.7 then
				follower:setJumpTrigger(i, rng:logNormalClamped(1.0, 0.5, 0.2, 2.5))
			elseif roll < 0.9 or not gap then
				follower:setJumpTrigger(i, u(rng, 0, 0.3))
			else
				follower:setJumpTrigger(i, -u(rng, 0.3, 0.8))
			end
		end
	end
end

local function stop(): MoveCommand
	return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
end

local function move(dir: Vector3, magnitude: number): MoveCommand
	return { mode = "move", dir = dir, magnitude = magnitude, jump = false }
end

-- Starts a planned event.
local function activate(self: HumanizerT, plan: Planned, now: number, body: BodyState)
	local active: Active = { kind = plan.kind, phase = 1, phaseEndsAt = now + plan.duration, plan = plan }
	if plan.kind == "aboutFace" then
		active.phaseEndsAt = now + u(self.tripRng, 0.1, 0.3)
		local follower = self.follower :: Follower
		active.points = follower:rewind(plan.rewindStuds or 4, body.position)
		active.pointIndex = 2
	elseif plan.kind == "wallBump" then
		active.phaseEndsAt = now + (plan.extra or 1)
		self.suppressedUntil = math.min(now + (plan.extra or 1) + 0.6, now + 3)
	elseif plan.kind == "correction" then
		active.phaseEndsAt = now + plan.duration
	end
	self.active = active
end

-- Runs the active event; returns the command it dictates, or nil when it just ended.
local function runActive(self: HumanizerT, input: Input, events: { Event }): (MoveCommand?, boolean)
	local active = self.active :: Active
	local now = input.now
	local plan = active.plan
	local rng = self.tripRng
	if active.kind == "hesitation" then
		if now >= active.phaseEndsAt then
			self.active = nil
			return nil, false
		end
		if plan.magnitude then
			local c = table.clone(input.command)
			c.magnitude = plan.magnitude
			return c, false
		end
		return stop(), false
	elseif active.kind == "distraction" then
		if now >= active.phaseEndsAt then
			self.active = nil
			return nil, false
		end
		return stop(), false
	elseif active.kind == "correction" then
		if active.phase == 1 then
			if now >= active.phaseEndsAt then
				active.phase = 2
				active.phaseEndsAt = now + u(rng, 0.2, 0.4)
			end
			return stop(), false
		end
		if now >= active.phaseEndsAt then
			self.active = nil
			return stop(), false
		end
		local dir = NavMath.flatDirection(input.body.position, plan.idealPoint or input.body.position)
		if dir.Magnitude == 0 then
			self.active = nil
			return stop(), false
		end
		return move(dir, 1), false
	elseif active.kind == "aboutFace" then
		-- phase 1: stop; phase 2: walk the rewound polyline; phase 3: stop; then resume or abandon.
		if active.phase == 1 then
			if now >= active.phaseEndsAt then
				active.phase = 2
			end
			return stop(), false
		elseif active.phase == 2 then
			local points = active.points :: { Vector3 }
			local index = active.pointIndex :: number
			while index <= #points and NavMath.flatDistance(input.body.position, points[index]) < 1 do
				index += 1
			end
			active.pointIndex = index
			if index > #points then
				active.phase = 3
				active.phaseEndsAt = now + u(rng, 0.3, 1.0)
				return stop(), false
			end
			local dir = NavMath.flatDirection(input.body.position, points[index])
			return move(dir, 1), false
		else
			if now >= active.phaseEndsAt then
				self.active = nil
				if plan.abandon then
					table.insert(events, { kind = "aboutFaceAbandon", at = now })
					return stop(), true
				end
				return nil, false
			end
			return stop(), false
		end
	elseif active.kind == "wallBump" then
		if active.phase == 1 then
			-- Keep the pre-corner heading until the extra time passes or the wall is felt.
			if input.stuckVerdict == "pushing" then
				active.pushingSince = active.pushingSince or now
			else
				active.pushingSince = nil
			end
			local felt = active.pushingSince ~= nil and now - (active.pushingSince :: number) >= 0.4
			if now >= active.phaseEndsAt or felt then
				active.phase = 2
				active.phaseEndsAt = now + plan.duration
				return stop(), false
			end
			return move(plan.heading or input.command.dir, 1), false
		end
		if now >= active.phaseEndsAt then
			self.active = nil
			self.suppressedUntil = -math.huge
			return nil, false
		end
		return stop(), false
	end
	self.active = nil
	return nil, false
end

-- Checks follower events and the clock for planned events to start. A trigger that arrives
-- while another event is running is remembered and fires as soon as that one ends.
local function triggerPlanned(self: HumanizerT, input: Input, events: { Event })
	local now = input.now
	for _, plan in self.planned do
		if plan.pending then
			continue
		end
		if plan.at and now >= plan.at then
			plan.pending = true
		elseif plan.index then
			for _, e in input.followerEvents do
				if plan.kind == "correction" then
					if e.kind == "finished" then
						plan.pending = true
					end
				elseif e.index == plan.index and (e.kind == "waypoint" or e.kind == "corner") then
					plan.pending = true
				end
			end
		end
	end
	if self.active then
		return
	end
	for i, plan in self.planned do
		if plan.pending then
			table.remove(self.planned, i)
			activate(self, plan, now, input.body)
			table.insert(events, { kind = plan.kind, at = now })
			return
		end
	end
end

function Humanizer.apply(self: HumanizerT, input: Input): Output
	local events: { Event } = {}
	local profile = self.profile
	local rng = self.rng
	local now, dt = input.now, input.dt

	-- Strafe legs: on shift-lock, a fifth of legs are walked sideways facing the camera.
	for _, e in input.followerEvents do
		if e.kind == "waypoint" and profile.strafes then
			self.strafeLeg = rng:chance(0.2)
			if self.strafeLeg then
				table.insert(events, { kind = "strafeLeg", at = now })
			end
		end
	end

	-- Never interfere with a jump: a stop issued at take-off swallows it and the follower times out.
	local midJump = input.command.jump or (self.follower ~= nil and (self.follower :: Follower).jumpState ~= "none")
	if not midJump then
		triggerPlanned(self, input, events)
		if self.active then
			local overridden, abandon = runActive(self, input, events)
			if overridden then
				return { command = overridden, events = events, abandonTrip = abandon }
			end
		end
	end

	local cmd = table.clone(input.command)
	if cmd.mode ~= "move" or self.tier == "far" or self.tier == "dormant" then
		return { command = cmd, events = events, abandonTrip = false }
	end
	if cmd.dir.Magnitude < 1e-6 then
		return { command = cmd, events = events, abandonTrip = false }
	end

	if profile.analog then
		if self.tier == "near" then
			local t = now
			local a1 = profile.wobbleAmpDeg
			local a2 = 0.4 * a1
			local f1 = profile.wobbleHz
			local f2 = 1.7 * f1
			self.tremor = Timing.stepOu(rng, self.tremor, 4, profile.tremorSigma, dt)
			local wobble = a1 * math.sin(2 * math.pi * f1 * t + self.phase1)
				+ a2 * math.sin(2 * math.pi * f2 * t + self.phase2)
				+ self.tremor
			cmd.dir = NavMath.dirFromYaw(NavMath.yawOf(cmd.dir) + math.rad(wobble))
		end
		-- Partial stick deflection with occasional dips and thumb lifts.
		self.ouMag = Timing.stepOu(rng, self.ouMag, 2, 0.5, dt)
		if now >= self.nextDipAt then
			self.dipUntil = now + u(rng, 0.2, 1)
			self.dipAmount = u(rng, 0.2, 0.4)
			self.nextDipAt = now + rng:exponential(8)
		end
		local dip = if now < self.dipUntil then self.dipAmount else 0
		cmd.magnitude = math.clamp(0.78 + 0.22 * (1 - math.min(1, math.abs(self.ouMag))) - dip, 0.55, 1) * cmd.magnitude
		if profile.microStopMean > 0 and self.tier == "near" then
			if now >= self.nextMicroStopAt then
				self.microStopUntil = now + rng:logNormalClamped(profile.microStopMedianDur, 0.5, 0.1, 0.45)
				self.nextMicroStopAt = now + rng:exponential(profile.microStopMean)
			end
			if now < self.microStopUntil then
				cmd.magnitude = 0
			end
		end
	else
		local camera = self.camera :: CameraModel.Camera
		local camYaw = camera:update(NavMath.yawOf(cmd.dir), dt, now)
		cmd.dir = camera:snapMove(cmd.dir)
		cmd.magnitude = 1
		if profile.strafes and self.strafeLeg then
			cmd.facingYaw = camYaw
		end
	end

	return { command = cmd, events = events, abandonTrip = false }
end

-- Something caught the eye: keyboard profiles briefly drag the camera toward it, which shows
-- as a small route wobble (all a third party can see of "looking around").
function Humanizer.lookAt(self: HumanizerT, point: Vector3, from: Vector3, untilTime: number)
	if self.camera then
		local dir = NavMath.flatDirection(from, point)
		if dir.Magnitude > 0 then
			self.camera:lookAt(NavMath.yawOf(dir), untilTime)
		end
	end
end

return Humanizer

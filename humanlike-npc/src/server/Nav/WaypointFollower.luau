--!strict
-- Turns a list of waypoints into per-tick move commands. This is the shape of Roblox's own
-- current pathfinding sample (Humanoid:Move every tick with a destination-plane test), kept pure:
-- feed it the body's state and the clock, get back a MoveCommand and the events that happened.
--
-- It looks ahead along the path (runtime string pulling) so corners are cut the way a person
-- walks toward what they can see, handles Jump waypoints as a small state machine with retries,
-- notices timeouts, and exposes the hooks the humanizer needs: offset a corner, move the final
-- stop point, rewind the walked polyline for an about-face.

local NavMath = require(script.Parent.NavMath)
local Types = require(script.Parent.Parent.Types)

type Waypoint = Types.Waypoint
type BodyState = Types.BodyState
type MoveCommand = Types.MoveCommand

local WaypointFollower = {}
WaypointFollower.__index = WaypointFollower

export type EventKind =
	"waypoint"
	| "corner"
	| "finished"
	| "jumpStart"
	| "jumpLanded"
	| "jumpFailed"
	| "timeout"
	| "custom"

export type Event = {
	kind: EventKind,
	index: number,
	angle: number?, -- corner angle in radians (kind "corner")
	label: string?, -- kind "custom"
}

export type Options = {
	lookahead: number?, -- studs; default 6
	stepHeight: number?, -- default 2
	jumpTrigger: number?, -- studs before a Jump waypoint at which to jump; default 1
	jumpTimeout: number?, -- seconds airborne before the jump counts as failed; default 2
	finalRadius: number?, -- default 1
	-- True when a straight walk between two points is clear (grid line-of-walk or a raycast).
	losCheck: ((from: Vector3, to: Vector3) -> boolean)?,
}

export type Output = {
	command: MoveCommand,
	events: { Event },
	target: Vector3?, -- the point currently steered toward
	remaining: number, -- studs left along the path
	cornerAngle: number?, -- angle of the next corner, when within lookahead
}

export type Follower = typeof(setmetatable(
	{} :: {
		waypoints: { Waypoint },
		nextIndex: number,
		segmentStart: Vector3,
		waypointStartedAt: number,
		jumpState: "none" | "requested" | "airborne" | "landed",
		jumpRequestedAt: number,
		jumpRetries: number,
		finalTarget: Vector3,
		jumpTrigger: { [number]: number }, -- per-waypoint override of the jump trigger distance
		lookahead: number,
		stepHeight: number,
		defaultJumpTrigger: number,
		jumpTimeout: number,
		finalRadius: number,
		losCheck: ((Vector3, Vector3) -> boolean)?,
		paused: boolean, -- holding at a Custom waypoint or after a failed jump, until resume()
		failedJump: number?, -- index of the Jump waypoint that failed, until resume()
		stallSince: number?, -- standing at a late-trigger take-off without getting past it
		walked: { Vector3 }, -- positions at each waypoint arrival, for rewind
		finished: boolean,
		walkSpeedHint: number,
	},
	WaypointFollower
))

local STOP: MoveCommand = { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }

local function stopCommand(): MoveCommand
	return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
end

function WaypointFollower.new(waypoints: { Waypoint }, start: Vector3, now: number, options: Options?): Follower
	local o: Options = options or {}
	local last = if #waypoints > 0 then waypoints[#waypoints].position else start
	local self = setmetatable({
		waypoints = waypoints,
		nextIndex = 1,
		segmentStart = start,
		waypointStartedAt = now,
		jumpState = "none" :: "none" | "requested" | "airborne" | "landed",
		jumpRequestedAt = 0,
		jumpRetries = 0,
		finalTarget = last,
		jumpTrigger = {},
		lookahead = o.lookahead or 6,
		stepHeight = o.stepHeight or 2,
		defaultJumpTrigger = o.jumpTrigger or 1,
		jumpTimeout = o.jumpTimeout or 2,
		finalRadius = o.finalRadius or 1,
		losCheck = o.losCheck,
		paused = false,
		failedJump = nil,
		stallSince = nil,
		walked = { start },
		finished = #waypoints == 0,
		walkSpeedHint = 16,
	}, WaypointFollower)
	-- The first waypoint usually sits under the agent's feet: skip anything within 2 studs.
	while self.nextIndex < #waypoints and NavMath.flatDistance(start, waypoints[self.nextIndex].position) < 2 do
		if waypoints[self.nextIndex].action ~= "Walk" then
			break
		end
		self.nextIndex += 1
	end
	return self
end

function WaypointFollower.index(self: Follower): number
	return self.nextIndex
end

function WaypointFollower.isFinished(self: Follower): boolean
	return self.finished
end

-- Replaces the arrival point without touching the last waypoint (remaining-distance math stays honest).
function WaypointFollower.setFinalTarget(self: Follower, point: Vector3)
	self.finalTarget = point
end

-- Moves a Walk waypoint that sits between two walk legs (corner clipping).
function WaypointFollower.offsetCorner(self: Follower, index: number, offset: Vector3): boolean
	local w = self.waypoints[index]
	if not w or w.action ~= "Walk" or index < self.nextIndex or index >= #self.waypoints then
		return false
	end
	local previous = self.waypoints[index - 1]
	if previous and previous.action ~= "Walk" then
		return false
	end
	self.waypoints[index] = { position = w.position + offset, action = w.action, label = w.label }
	return true
end

function WaypointFollower.setJumpTrigger(self: Follower, index: number, distance: number)
	self.jumpTrigger[index] = distance
end

-- Continues after a Custom waypoint hold or a failed jump (recovery decides when).
function WaypointFollower.resume(self: Follower)
	self.paused = false
	self.failedJump = nil
	self.jumpState = "none"
	self.jumpRetries = 0
end

-- The follower is holding still and needs a decision (link handler or recovery).
function WaypointFollower.isPaused(self: Follower): boolean
	return self.paused
end

-- The already-walked polyline, reversed from `position` back `studs` along it.
function WaypointFollower.rewind(self: Follower, studs: number, position: Vector3): { Vector3 }
	local points = { position }
	local budget = studs
	local cursor = position
	for i = #self.walked, 1, -1 do
		local p = self.walked[i]
		local d = NavMath.flatDistance(cursor, p)
		if d >= budget then
			if d > 1e-6 then
				table.insert(points, cursor + (p - cursor) * (budget / d))
			end
			break
		end
		budget -= d
		table.insert(points, p)
		cursor = p
	end
	return points
end

-- Straight-line studs left from `position` through the remaining waypoints, measured from the
-- waypoint currently steered toward (`fromIndex`, default the next one) so cutting a corner
-- toward a farther waypoint still counts as progress.
function WaypointFollower.remainingDistance(self: Follower, position: Vector3, fromIndex: number?): number
	if self.finished or self.nextIndex > #self.waypoints then
		return 0
	end
	local start = math.clamp(fromIndex or self.nextIndex, self.nextIndex, #self.waypoints)
	local total = NavMath.flatDistance(position, self.waypoints[start].position)
	for i = start + 1, #self.waypoints do
		total += NavMath.flatDistance(self.waypoints[i - 1].position, self.waypoints[i].position)
	end
	return total
end

local function turnAngleAt(self: Follower, index: number): number
	local a, b, c = self.waypoints[index - 1], self.waypoints[index], self.waypoints[index + 1]
	if not a or not b or not c then
		return 0
	end
	local din = NavMath.flatDirection(a.position, b.position)
	local dout = NavMath.flatDirection(b.position, c.position)
	if din.Magnitude == 0 or dout.Magnitude == 0 then
		return 0
	end
	return math.abs(NavMath.turnAngle(din, dout))
end

local function reached(self: Follower, index: number, body: BodyState): boolean
	local w = self.waypoints[index]
	local isLast = index == #self.waypoints
	if isLast then
		return NavMath.flatDistance(body.position, self.finalTarget) < self.finalRadius
	end
	local previous = if index == 1 then self.segmentStart else self.waypoints[index - 1].position
	local leg = NavMath.flatDirection(previous, w.position)
	local speedToward = if leg.Magnitude > 0 then math.max(0, NavMath.flat(body.velocity):Dot(leg)) else 0
	local arriveRadius = math.max(1, 0.0625 * speedToward)
	local distance = NavMath.flatDistance(body.position, w.position)
	if distance < arriveRadius then
		return true
	end
	-- Destination-plane test: passed the plane through w whose normal points back along the leg.
	if leg.Magnitude > 0 and NavMath.flat(body.position - w.position):Dot(leg) >= 0 then
		-- Only counts when we are roughly on the leg, not somewhere far off to the side.
		local lateral = (NavMath.flat(body.position - w.position) - leg * NavMath.flat(body.position - w.position)
			:Dot(leg)).Magnitude
		return lateral < 4
	end
	return false
end

-- Furthest waypoint within lookahead that a straight walk can reach, never past a jump, a custom
-- waypoint, or a leg that climbs more than a step.
local function lookaheadTarget(self: Follower, position: Vector3): (Vector3, number)
	local bestIndex = self.nextIndex
	local best = self.waypoints[bestIndex].position
	for k = self.nextIndex + 1, math.min(#self.waypoints, self.nextIndex + 6) do
		local previous = self.waypoints[k - 1]
		if previous.action ~= "Walk" then
			break
		end
		local w = self.waypoints[k]
		if math.abs(w.position.Y - previous.position.Y) > self.stepHeight then
			break
		end
		if NavMath.flatDistance(position, w.position) > self.lookahead then
			break
		end
		if self.losCheck and not self.losCheck(position, w.position) then
			break
		end
		bestIndex, best = k, w.position
	end
	if bestIndex == #self.waypoints then
		best = self.finalTarget
	end
	return best, bestIndex
end

local function moveToward(position: Vector3, target: Vector3, jump: boolean): MoveCommand
	local dir = NavMath.flatDirection(position, target)
	if dir.Magnitude == 0 then
		return { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = jump }
	end
	return { mode = "move", dir = dir, magnitude = 1, jump = jump }
end

function WaypointFollower.tick(self: Follower, body: BodyState, now: number): Output
	local events: { Event } = {}
	if self.finished then
		return { command = stopCommand(), events = events, remaining = 0 }
	end
	if self.paused then
		return { command = stopCommand(), events = events, remaining = self:remainingDistance(body.position) }
	end
	self.walkSpeedHint = body.walkSpeed

	-- Advance past every waypoint we have reached (a lookahead can pass several at once). A Jump
	-- waypoint is never advanced here: reaching it is the take-off cue handled below.
	while self.nextIndex <= #self.waypoints and self.jumpState == "none" and reached(self, self.nextIndex, body) do
		local w = self.waypoints[self.nextIndex]
		if w.action == "Jump" and self.waypoints[self.nextIndex + 1] then
			break
		end
		table.insert(events, { kind = "waypoint", index = self.nextIndex })
		local angle = turnAngleAt(self, self.nextIndex)
		if angle > math.rad(25) then
			table.insert(events, { kind = "corner", index = self.nextIndex, angle = angle })
		end
		table.insert(self.walked, body.position)
		if w.action == "Custom" then
			table.insert(events, { kind = "custom", index = self.nextIndex, label = w.label })
			self.paused = true
		end
		self.nextIndex += 1
		self.waypointStartedAt = now
		self.segmentStart = body.position
		if self.paused then
			break
		end
	end
	if self.nextIndex > #self.waypoints then
		self.finished = true
		table.insert(events, { kind = "finished", index = #self.waypoints })
		return { command = stopCommand(), events = events, remaining = 0 }
	end
	if self.paused then
		return { command = stopCommand(), events = events, remaining = self:remainingDistance(body.position) }
	end

	local w = self.waypoints[self.nextIndex]
	local landing = self.waypoints[self.nextIndex + 1]
	local command: MoveCommand
	local target: Vector3? = nil
	local targetIndex = self.nextIndex

	if w.action == "Jump" and landing then
		if self.jumpState == "none" then
			local trigger = self.jumpTrigger[self.nextIndex] or self.defaultJumpTrigger
			local toTakeoff = NavMath.flatDistance(body.position, w.position)
			-- Trigger when within `trigger` studs of the take-off point, or once past it. A negative
			-- trigger means "late": only once past the take-off point by that many studs.
			local leg = NavMath.flatDirection(self.segmentStart, w.position)
			local along = if leg.Magnitude > 0 then NavMath.flat(body.position - w.position):Dot(leg) else 0
			local atTakeoff = reached(self, self.nextIndex, body)
			local ready
			if trigger >= 0 then
				ready = toTakeoff <= trigger or along >= 0 or atTakeoff
			else
				-- Late: only once past the take-off point; if something stops us there, go anyway.
				ready = along >= -trigger
				if not ready and atTakeoff then
					self.stallSince = self.stallSince or now
					ready = now - (self.stallSince :: number) >= 0.5
				end
			end
			if body.onGround and ready then
				self.stallSince = nil
				table.insert(events, { kind = "waypoint", index = self.nextIndex })
				self.jumpState = "requested"
				self.jumpRequestedAt = now
				self.jumpRetries = 0
				table.insert(events, { kind = "jumpStart", index = self.nextIndex })
				command = moveToward(body.position, landing.position, true)
				target = landing.position
			else
				command = moveToward(body.position, w.position, false)
				target = w.position
			end
		elseif self.jumpState == "requested" then
			if not body.onGround then
				self.jumpState = "airborne"
				command = moveToward(body.position, landing.position, false)
			elseif now - self.jumpRequestedAt > 0.4 then
				self.jumpRetries += 1
				if self.jumpRetries > 2 then
					self.jumpState = "none"
					self.paused = true
					self.failedJump = self.nextIndex
					table.insert(events, { kind = "jumpFailed", index = self.nextIndex, label = "noTakeoff" })
					command = stopCommand()
				else
					self.jumpRequestedAt = now
					command = moveToward(body.position, landing.position, true)
				end
			else
				command = moveToward(body.position, landing.position, false)
			end
			target = landing.position
		elseif self.jumpState == "airborne" then
			if body.onGround then
				self.jumpState = "landed"
				table.insert(events, { kind = "jumpLanded", index = self.nextIndex })
			elseif now - self.jumpRequestedAt > self.jumpTimeout then
				self.jumpState = "none"
				self.paused = true
				self.failedJump = self.nextIndex
				table.insert(events, { kind = "jumpFailed", index = self.nextIndex, label = "airborneTimeout" })
			end
			command = if self.paused then stopCommand() else moveToward(body.position, landing.position, false)
			target = landing.position
		else -- landed
			if body.position.Y < landing.position.Y - self.stepHeight - 0.5 then
				self.jumpState = "none"
				self.paused = true
				self.failedJump = self.nextIndex
				table.insert(events, { kind = "jumpFailed", index = self.nextIndex, label = "short" })
				command = stopCommand()
			else
				self.jumpState = "none"
				table.insert(self.walked, body.position)
				self.nextIndex += 1 -- past the Jump waypoint; the landing is the next target
				self.waypointStartedAt = now
				self.segmentStart = body.position
				if self.nextIndex > #self.waypoints then
					self.finished = true
					table.insert(events, { kind = "finished", index = #self.waypoints })
					return { command = stopCommand(), events = events, remaining = 0 }
				end
				local nextTarget = lookaheadTarget(self, body.position)
				command = moveToward(body.position, nextTarget, false)
				target = nextTarget
			end
		end
	else
		local point, index = lookaheadTarget(self, body.position)
		command = moveToward(body.position, point, false)
		target = point
		targetIndex = index
	end

	-- Timeouts: base 1.5 s plus the leg length at half speed.
	local legLength = NavMath.flatDistance(self.segmentStart, w.position)
	local allowed = 1.5 + legLength / math.max(1, 0.5 * (body.walkSpeed > 0 and body.walkSpeed or 16))
	if now - self.waypointStartedAt > allowed then
		table.insert(events, { kind = "timeout", index = self.nextIndex })
		self.waypointStartedAt = now -- report once per allowance
	end

	local cornerAngle: number? = nil
	if self.nextIndex < #self.waypoints then
		local angle = turnAngleAt(self, self.nextIndex)
		if angle > math.rad(25) and NavMath.flatDistance(body.position, w.position) <= self.lookahead then
			cornerAngle = angle
		end
	end

	return {
		command = command,
		events = events,
		target = target,
		remaining = self:remainingDistance(body.position, targetIndex),
		cornerAngle = cornerAngle,
	}
end

WaypointFollower.STOP = STOP

return WaypointFollower

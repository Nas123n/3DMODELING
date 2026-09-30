-- A kinematic stand-in for a Humanoid so the locomotion runtime can be driven under Lune.
-- The body walks at WalkSpeed along the commanded direction, jumps on a fixed arc, lands on
-- whatever the nav grid says the floor is, and refuses to enter blocked cells (which is what
-- pushing a wall looks like: intent but no motion). It is deliberately crude: it exists to
-- exercise state machines, not to imitate physics.

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local Sim = {}
Sim.__index = Sim

local GRAVITY = 196.2
local JUMP_SPEED = 50 -- JumpPower 50: about 0.51 s of airtime, 6.4 studs high

export type Options = {
	walkSpeed: number?,
	stepHeight: number?,
	-- Returns the floor height at a horizontal position, or nil when there is none (void).
	floorAt: ((x: number, z: number) -> number?)?,
	-- True when a horizontal position may not be entered (a wall). Default: never.
	blockedAt: ((x: number, z: number) -> boolean)?,
}

function Sim.new(position: any, options: Options?)
	local o = options or {}
	return setmetatable({
		position = position,
		velocity = Vector3.zero,
		onGround = true,
		walkSpeed = o.walkSpeed or 16,
		stepHeight = o.stepHeight or 2,
		floorAt = o.floorAt or function()
			return 0
		end,
		blockedAt = o.blockedAt or function()
			return false
		end,
		yaw = 0,
		verticalSpeed = 0,
		lastCommand = nil,
		jumps = 0,
		distance = 0,
	}, Sim)
end

-- Body state in the shape the follower expects.
function Sim.state(self)
	return {
		position = self.position,
		velocity = self.velocity,
		onGround = self.onGround,
		state = if self.onGround then "Running" else "Freefall",
		walkSpeed = self.walkSpeed,
		yaw = self.yaw,
	}
end

-- Applies a MoveCommand for dt seconds.
function Sim.step(self, command, dt: number)
	self.lastCommand = command
	local dir = Vector3.zero
	local magnitude = 0
	if command.mode == "move" then
		dir = command.dir
		magnitude = command.magnitude
	elseif command.mode == "moveTo" and command.moveToPoint then
		local d = Vector3.new(command.moveToPoint.X - self.position.X, 0, command.moveToPoint.Z - self.position.Z)
		if d.Magnitude > 1 then
			dir = d.Unit
			magnitude = 1
		end
	end
	if command.jump and self.onGround then
		self.onGround = false
		self.verticalSpeed = JUMP_SPEED
		self.jumps += 1
	end
	if dir.Magnitude > 0 then
		self.yaw = math.atan2(-dir.X, -dir.Z)
	end

	local horizontal = dir * (self.walkSpeed * magnitude)
	local nextX = self.position.X + horizontal.X * dt
	local nextZ = self.position.Z + horizontal.Z * dt
	local moved = true
	if self.blockedAt(nextX, nextZ) then
		moved = false
		nextX, nextZ = self.position.X, self.position.Z
		horizontal = Vector3.zero
	end

	local y = self.position.Y
	if not self.onGround then
		self.verticalSpeed -= GRAVITY * dt
		y += self.verticalSpeed * dt
		local floor = self.floorAt(nextX, nextZ)
		if floor and y <= floor and self.verticalSpeed <= 0 then
			y = floor
			self.onGround = true
			self.verticalSpeed = 0
		end
	else
		local floor = self.floorAt(nextX, nextZ)
		if floor == nil then
			-- Walked off an edge.
			self.onGround = false
			self.verticalSpeed = 0
		elseif floor > y + self.stepHeight then
			-- A step too tall to climb: stay put (pushing).
			moved = false
			nextX, nextZ = self.position.X, self.position.Z
			horizontal = Vector3.zero
		else
			y = floor
		end
	end

	local previous = self.position
	self.position = Vector3.new(nextX, y, nextZ)
	self.velocity = Vector3.new(horizontal.X, self.verticalSpeed, horizontal.Z)
	self.distance += (Vector3.new(nextX, 0, nextZ) - Vector3.new(previous.X, 0, previous.Z)).Magnitude
	return moved
end

-- Convenience: floorAt / blockedAt derived from a NavGrid.
function Sim.fromGrid(grid: any, position: any, options: Options?)
	local o = options or {}
	o.floorAt = function(x: number, z: number)
		local ix, iz = grid:cellOf(Vector3.new(x, 0, z))
		return grid:floorAt(ix, iz)
	end
	o.blockedAt = function(x: number, z: number)
		local ix, iz = grid:cellOf(Vector3.new(x, 0, z))
		return grid:isBlocked(ix, iz)
	end
	return Sim.new(position, o)
end

return Sim

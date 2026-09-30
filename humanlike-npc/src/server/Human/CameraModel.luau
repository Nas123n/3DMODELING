--!strict
-- A virtual camera for keyboard profiles. PC movement is relative to the camera, and the camera
-- lags behind where the player wants to go: on a straight leg nothing shows, but at a corner the
-- player first walks at 45 degrees while the mouse catches up, which is the "zig" everyone has
-- seen. Nobody can see an NPC's camera, so this only has to reproduce that visible effect.
-- requires: NavMath

local NavMath = require(script.Parent.Parent.Nav.NavMath)

local CameraModel = {}
CameraModel.__index = CameraModel

export type Camera = typeof(setmetatable(
	{} :: {
		yaw: number,
		rate: number, -- radians per second
		lag: number, -- seconds
		quantize8: boolean,
		turnStartsAt: number?,
		lookUntil: number?, -- explicit look-at override (something caught the eye)
		lookYaw: number?,
	},
	CameraModel
))

function CameraModel.new(initialYaw: number, rateDegPerS: number, lag: number, quantize8: boolean): Camera
	return setmetatable({
		yaw = initialYaw,
		rate = math.rad(math.max(rateDegPerS, 1)),
		lag = lag,
		quantize8 = quantize8,
		turnStartsAt = nil,
		lookUntil = nil,
		lookYaw = nil,
	}, CameraModel)
end

-- Something interesting: the camera turns toward it until `untilTime`, then returns to steering.
function CameraModel.lookAt(self: Camera, yaw: number, untilTime: number)
	self.lookYaw = yaw
	self.lookUntil = untilTime
	self.turnStartsAt = nil
end

-- Advances the camera toward the desired heading and returns its yaw.
function CameraModel.update(self: Camera, desiredYaw: number, dt: number, now: number): number
	local target = desiredYaw
	if self.lookUntil then
		if now < self.lookUntil then
			target = self.lookYaw :: number
		else
			self.lookUntil = nil
			self.lookYaw = nil
		end
	end
	local delta = NavMath.wrap(target - self.yaw)
	if math.abs(delta) > math.rad(30) then
		if self.turnStartsAt == nil then
			self.turnStartsAt = now + self.lag
		end
		if now >= (self.turnStartsAt :: number) then
			local step = math.clamp(delta, -self.rate * dt, self.rate * dt)
			self.yaw = NavMath.wrap(self.yaw + step)
			if math.abs(NavMath.wrap(target - self.yaw)) < math.rad(3) then
				self.turnStartsAt = nil
			end
		end
	else
		-- Small drift: no explicit drag, the camera just floats after the heading.
		self.yaw = NavMath.wrap(self.yaw + delta * math.min(1, 2 * dt))
		self.turnStartsAt = nil
	end
	return self.yaw
end

-- Snaps a desired move direction to the eight camera-relative directions.
function CameraModel.snapMove(self: Camera, desired: Vector3): Vector3
	if not self.quantize8 or desired.Magnitude < 1e-6 then
		return desired
	end
	local rel = NavMath.wrap(NavMath.yawOf(desired) - self.yaw)
	local snapped = math.round(rel / (math.pi / 4)) * (math.pi / 4)
	return NavMath.dirFromYaw(self.yaw + snapped)
end

return CameraModel

--!strict
-- Small vector helpers the navigation modules share: flattening to the XZ plane, yaw <-> direction,
-- angle wrapping. Kept out of the modules so their logic reads as the algorithm, not as geometry.

local NavMath = {}

local TAU = math.pi * 2

function NavMath.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function NavMath.flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Unit vector in the XZ plane from a to b, or zero when they coincide.
function NavMath.flatDirection(from: Vector3, to: Vector3): Vector3
	local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if d.Magnitude < 1e-6 then
		return Vector3.zero
	end
	return d.Unit
end

-- Yaw of a direction: 0 faces -Z (Roblox's LookVector convention), increasing counter-clockwise
-- seen from above, so that CFrame.Angles(0, yaw, 0).LookVector == dirFromYaw(yaw).
function NavMath.yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

function NavMath.dirFromYaw(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

-- Wraps an angle to (-pi, pi].
function NavMath.wrap(angle: number): number
	local a = (angle + math.pi) % TAU
	if a < 0 then
		a += TAU
	end
	return a - math.pi
end

-- Signed angle from direction a to direction b about the Y axis.
function NavMath.turnAngle(a: Vector3, b: Vector3): number
	return NavMath.wrap(NavMath.yawOf(b) - NavMath.yawOf(a))
end

-- Perpendicular to a flat direction (rotated 90 degrees counter-clockwise from above).
function NavMath.perp(direction: Vector3): Vector3
	return Vector3.new(-direction.Z, 0, direction.X)
end

return NavMath

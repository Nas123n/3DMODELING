-- Stand-in for the spatial queries the NPC system makes on `workspace`, evaluated against the
-- BaseParts under a Lune Workspace. Lune has no physics engine, so this answers Raycast,
-- GetPartBoundsInBox and GetPartBoundsInRadius itself, treating parts as oriented boxes
-- (balls as spheres). That is enough to find floors, walls, gaps and nearby characters.

local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local Enum = roblox.Enum

local World = {}
World.__index = World

local function newParams()
	return {
		FilterType = Enum.RaycastFilterType.Exclude,
		FilterDescendantsInstances = {},
		IgnoreWater = false,
		RespectCanCollide = false,
		MaxParts = 0,
		-- Lune has no RaycastParams instance, so the helpers mirror its methods on a plain table.
		AddToFilter = function(self: any, instances: any)
			if typeof(instances) == "Instance" then
				table.insert(self.FilterDescendantsInstances, instances)
			else
				for _, instance in instances do
					table.insert(self.FilterDescendantsInstances, instance)
				end
			end
		end,
	}
end

World.RaycastParams = { new = newParams }
World.OverlapParams = { new = newParams }

function World.new(workspace: any)
	return setmetatable({ root = workspace, CurrentCamera = workspace.CurrentCamera }, World)
end

local function matchesFilter(part: any, params: any): boolean
	local listed = false
	for _, item in params.FilterDescendantsInstances do
		if part == item or part:IsDescendantOf(item) then
			listed = true
			break
		end
	end
	if params.FilterType == Enum.RaycastFilterType.Include then
		return listed
	end
	return not listed
end

local function queryableParts(self: any, params: any): { any }
	local parts = {}
	for _, descendant in self.root:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanQuery and matchesFilter(descendant, params) then
			if params.RespectCanCollide and not descendant.CanCollide then
				continue
			end
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function isBall(part: any): boolean
	return part:IsA("Part") and part.Shape == Enum.PartType.Ball
end

-- Slab test in the part's local space. Returns distance along the unit ray and the world normal.
local function intersect(part: any, origin: any, direction: any, maxDistance: number): (number?, any)
	local cf = part.CFrame
	if isBall(part) then
		local radius = math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2
		local offset = origin - cf.Position
		local b = offset:Dot(direction)
		local c = offset:Dot(offset) - radius * radius
		local discriminant = b * b - c
		if discriminant < 0 then
			return nil, nil
		end
		local t = -b - math.sqrt(discriminant)
		if t < 0 or t > maxDistance then
			return nil, nil
		end
		return t, (origin + direction * t - cf.Position).Unit
	end
	local localOrigin = cf:PointToObjectSpace(origin)
	local localDirection = cf:VectorToObjectSpace(direction)
	local half = part.Size / 2
	local tNear, tFar = -math.huge, math.huge
	local nearAxis, nearSign = 0, 0
	local o = { localOrigin.X, localOrigin.Y, localOrigin.Z }
	local d = { localDirection.X, localDirection.Y, localDirection.Z }
	local h = { half.X, half.Y, half.Z }
	for axis = 1, 3 do
		if math.abs(d[axis]) < 1e-9 then
			if o[axis] < -h[axis] or o[axis] > h[axis] then
				return nil, nil
			end
		else
			local t1 = (-h[axis] - o[axis]) / d[axis]
			local t2 = (h[axis] - o[axis]) / d[axis]
			local sign = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				sign = 1
			end
			if t1 > tNear then
				tNear, nearAxis, nearSign = t1, axis, sign
			end
			tFar = math.min(tFar, t2)
			if tNear > tFar then
				return nil, nil
			end
		end
	end
	if tNear < 0 or tNear > maxDistance or nearAxis == 0 then
		return nil, nil
	end
	local localNormal = Vector3.new(
		if nearAxis == 1 then nearSign else 0,
		if nearAxis == 2 then nearSign else 0,
		if nearAxis == 3 then nearSign else 0
	)
	return tNear, cf:VectorToWorldSpace(localNormal)
end

function World.Raycast(self: any, origin: any, direction: any, params: any?)
	local p = params or newParams()
	local distance = direction.Magnitude
	if distance <= 0 then
		return nil
	end
	local unit = direction.Unit
	local best, bestT, bestNormal = nil, math.huge, nil
	for _, part in queryableParts(self, p) do
		local t, normal = intersect(part, origin, unit, distance)
		if t and t < bestT then
			best, bestT, bestNormal = part, t, normal
		end
	end
	if not best then
		return nil
	end
	return {
		Instance = best,
		Position = origin + unit * bestT,
		Normal = bestNormal,
		Distance = bestT,
		Material = best.Material,
	}
end

local function worldBox(cf: any, size: any): (any, any)
	local half = size / 2
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local extent = Vector3.new(
		math.abs(r.X) * half.X + math.abs(u.X) * half.Y + math.abs(l.X) * half.Z,
		math.abs(r.Y) * half.X + math.abs(u.Y) * half.Y + math.abs(l.Y) * half.Z,
		math.abs(r.Z) * half.X + math.abs(u.Z) * half.Y + math.abs(l.Z) * half.Z
	)
	return cf.Position - extent, cf.Position + extent
end

function World.GetPartBoundsInBox(self: any, cframe: any, size: any, params: any?): { any }
	local p = params or newParams()
	local low, high = worldBox(cframe, size)
	local hits = {}
	for _, part in queryableParts(self, p) do
		local partLow, partHigh = worldBox(part.CFrame, part.Size)
		if
			partLow.X < high.X
			and partHigh.X > low.X
			and partLow.Y < high.Y
			and partHigh.Y > low.Y
			and partLow.Z < high.Z
			and partHigh.Z > low.Z
		then
			table.insert(hits, part)
			if p.MaxParts > 0 and #hits >= p.MaxParts then
				break
			end
		end
	end
	return hits
end

function World.GetPartBoundsInRadius(self: any, position: any, radius: number, params: any?): { any }
	local p = params or newParams()
	local hits = {}
	for _, part in queryableParts(self, p) do
		-- Closest point on the part's world-aligned bounds to the query center.
		local low, high = worldBox(part.CFrame, part.Size)
		local cx = math.clamp(position.X, low.X, high.X)
		local cy = math.clamp(position.Y, low.Y, high.Y)
		local cz = math.clamp(position.Z, low.Z, high.Z)
		local dx, dy, dz = position.X - cx, position.Y - cy, position.Z - cz
		if dx * dx + dy * dy + dz * dz <= radius * radius then
			table.insert(hits, part)
			if p.MaxParts > 0 and #hits >= p.MaxParts then
				break
			end
		end
	end
	return hits
end

return World

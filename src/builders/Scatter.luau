--!strict
-- Pure 2D placement math for decorating a rectangular zone footprint (X/Z plane).
-- No Roblox types here so it can be unit tested outside the engine.

local Scatter = {}

export type Bounds = { minX: number, minZ: number, maxX: number, maxZ: number }
export type Circle = { x: number, z: number, r: number }
export type Point = { x: number, z: number }

-- 0 on the zone's outer edge, rising to 1 at the centerline of the shorter axis.
function Scatter.edgeFactor(bounds: Bounds, x: number, z: number): number
	local halfSpan = math.min(bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ) / 2
	if halfSpan <= 0 then
		return 0
	end
	local distance = math.min(x - bounds.minX, bounds.maxX - x, z - bounds.minZ, bounds.maxZ - z)
	return math.clamp(distance / halfSpan, 0, 1)
end

function Scatter.area(bounds: Bounds): number
	return math.max(0, bounds.maxX - bounds.minX) * math.max(0, bounds.maxZ - bounds.minZ)
end

-- Spatial hash of placed footprints, used to keep props from overlapping each other.
local Grid = {}
Grid.__index = Grid

export type Grid = typeof(setmetatable(
	{} :: {
		cellSize: number,
		cells: { [number]: { Circle } },
		maxRadius: number,
		count: number,
	},
	Grid
))

local function cellKey(ix: number, iz: number): number
	-- Zones are far smaller than 2^20 cells across, so this packs both indices without collisions.
	return (ix + 524288) * 1048576 + (iz + 524288)
end

function Scatter.newGrid(cellSize: number): Grid
	assert(cellSize > 0, "cellSize must be positive")
	return setmetatable({ cellSize = cellSize, cells = {}, maxRadius = 0, count = 0 }, Grid)
end

-- True when a circle at (x, z) with radius r (plus padding) touches nothing already added.
function Grid.fits(self: Grid, x: number, z: number, r: number, padding: number?): boolean
	local pad = padding or 0
	local reach = r + self.maxRadius + pad
	local size = self.cellSize
	local ix0, ix1 = math.floor((x - reach) / size), math.floor((x + reach) / size)
	local iz0, iz1 = math.floor((z - reach) / size), math.floor((z + reach) / size)
	for ix = ix0, ix1 do
		for iz = iz0, iz1 do
			local bucket = self.cells[cellKey(ix, iz)]
			if bucket then
				for _, other in bucket do
					local minDistance = r + other.r + pad
					local dx, dz = x - other.x, z - other.z
					if dx * dx + dz * dz < minDistance * minDistance then
						return false
					end
				end
			end
		end
	end
	return true
end

function Grid.add(self: Grid, x: number, z: number, r: number)
	local key = cellKey(math.floor(x / self.cellSize), math.floor(z / self.cellSize))
	local bucket = self.cells[key]
	if not bucket then
		bucket = {}
		self.cells[key] = bucket
	end
	table.insert(bucket, { x = x, z = z, r = r })
	self.maxRadius = math.max(self.maxRadius, r)
	self.count += 1
end

function Scatter.insideAny(circles: { Circle }, x: number, z: number, radius: number): boolean
	for _, c in circles do
		local reach = c.r + radius
		local dx, dz = x - c.x, z - c.z
		if dx * dx + dz * dz < reach * reach then
			return true
		end
	end
	return false
end

-- Evenly spaced points around the rectangle, inset from its edge, always including the corners.
function Scatter.perimeter(bounds: Bounds, inset: number, spacing: number): { Point }
	local minX, maxX = bounds.minX + inset, bounds.maxX - inset
	local minZ, maxZ = bounds.minZ + inset, bounds.maxZ - inset
	local points: { Point } = {}
	if maxX <= minX or maxZ <= minZ or spacing <= 0 then
		return points
	end
	-- Walk the four sides clockwise; each side contributes its start corner plus interior points.
	local corners = {
		{ x = minX, z = minZ },
		{ x = maxX, z = minZ },
		{ x = maxX, z = maxZ },
		{ x = minX, z = maxZ },
	}
	for i = 1, 4 do
		local a = corners[i]
		local b = corners[i % 4 + 1]
		local length = math.abs(b.x - a.x) + math.abs(b.z - a.z)
		local segments = math.max(1, math.round(length / spacing))
		for s = 0, segments - 1 do
			local t = s / segments
			table.insert(points, { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t })
		end
	end
	return points
end

function Scatter.perimeterLength(bounds: Bounds, inset: number): number
	local width = bounds.maxX - bounds.minX - inset * 2
	local depth = bounds.maxZ - bounds.minZ - inset * 2
	if width <= 0 or depth <= 0 then
		return 0
	end
	return (width + depth) * 2
end

-- The point `distance` studs along the rectangle inset by `inset`, walking from its min corner.
function Scatter.perimeterPoint(bounds: Bounds, inset: number, distance: number): Point
	local minX, maxX = bounds.minX + inset, bounds.maxX - inset
	local minZ, maxZ = bounds.minZ + inset, bounds.maxZ - inset
	local width, depth = maxX - minX, maxZ - minZ
	local d = distance % ((width + depth) * 2)
	if d < width then
		return { x = minX + d, z = minZ }
	end
	d -= width
	if d < depth then
		return { x = maxX, z = minZ + d }
	end
	d -= depth
	if d < width then
		return { x = maxX - d, z = maxZ }
	end
	d -= width
	return { x = minX, z = maxZ - d }
end

return Scatter

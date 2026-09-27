--!strict
-- Decorates a zone (a Model or Folder holding its floor and gameplay objects) with themed
-- props. Everything goes into one "Decorations" folder inside the zone, which is replaced
-- on every run, so rebuilding is safe and the same seed gives the same result.
--
-- What it avoids:
--   * anything already standing on the floor (egg stands, paths, walls, the boss, spawns),
--     with `padding` studs of breathing room around it
--   * parts tagged "KeepClear" (use invisible parts to reserve walkways or arenas)
--   * the middle of the zone for big props, which only go near the edges
-- Invisible, non-colliding parts (zone triggers, region volumes) are ignored.

local Props = require(script.Parent.Props)
local Rng = require(script.Parent.Rng)
local Scatter = require(script.Parent.Scatter)
local ZoneThemes = require(script.Parent.ZoneThemes)

type Theme = ZoneThemes.Theme
type Bounds = Scatter.Bounds

local ZoneDecorator = {}

ZoneDecorator.FOLDER_NAME = "Decorations"
ZoneDecorator.GROUND_TAG = "ZoneGround"
ZoneDecorator.KEEP_CLEAR_TAG = "KeepClear"
ZoneDecorator.DECORATION_TAG = "Decoration"
ZoneDecorator.THEME_ATTRIBUTE = "ZoneTheme"

export type Options = {
	theme: (string | Theme)?, -- defaults to the zone's ZoneTheme attribute
	seed: (number | string)?, -- defaults to the zone's name
	density: number?, -- multiplies every scatter count; default 1
	ground: { Instance }?, -- floor parts; defaults to parts tagged ZoneGround, else the widest flat part
	bounds: { center: Vector3, size: Vector3 }?, -- footprint override; required for Terrain floors
	keepClear: { { position: Vector3, radius: number } }?,
	padding: number?, -- studs kept free around existing objects; default 2
	perimeter: boolean?, -- lanterns/torches around the edge; default true
	ambient: boolean?, -- floating particles; default true
}

export type Report = {
	zone: string,
	theme: string,
	props: number,
	parts: number,
	counts: { [string]: number },
	-- Props the theme asked for but that found no free spot (a crowded zone, or a small one).
	shortfall: { [string]: number },
}

local EDGE_BAND = 0.32 -- "edge" props stay in the outer third of the zone
local BORDER_DEPTH = 4 -- "border" props sit within this many studs of touching the edge
local TAU = math.pi * 2

-- Frame first, then fill inward; flat ground cover last.
local PLACEMENT_ORDER = { border = 1, edge = 2, any = 3, uniform = 4 }

local function isGhost(part: BasePart): boolean
	-- Invisible and non-colliding: trigger volumes, zone regions, hitboxes.
	return part.Transparency >= 0.95 and not part.CanCollide
end

local function worldExtents(part: BasePart): (Vector3, Vector3)
	local cf, half = part.CFrame, part.Size / 2
	local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
	local extent = Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
	)
	local center = cf.Position
	return center - extent, center + extent
end

local function isFloorLike(part: BasePart): boolean
	local low, high = worldExtents(part)
	local span = high - low
	return span.X >= 8 and span.Z >= 8 and span.Y < 0.5 * math.min(span.X, span.Z)
end

local function collectGround(zone: Instance, explicit: { Instance }?): { Instance }
	if explicit and #explicit > 0 then
		return explicit
	end
	local tagged: { Instance } = {}
	local candidates: { BasePart } = {}
	local previous = zone:FindFirstChild(ZoneDecorator.FOLDER_NAME)
	for _, descendant in zone:GetDescendants() do
		if descendant:IsA("BasePart") and not (previous and descendant:IsDescendantOf(previous)) then
			if descendant:HasTag(ZoneDecorator.GROUND_TAG) then
				table.insert(tagged, descendant)
			elseif isFloorLike(descendant) and not isGhost(descendant) then
				table.insert(candidates, descendant)
			end
		end
	end
	if #tagged > 0 then
		return tagged
	end

	-- The widest flat part is the floor. Tiles that share its level, color and material
	-- count too; a path or rug in a different color stays an obstacle.
	local widest: BasePart? = nil
	local widestArea = 0
	for _, part in candidates do
		local low, high = worldExtents(part)
		local area = (high.X - low.X) * (high.Z - low.Z)
		if area > widestArea then
			widest, widestArea = part, area
		end
	end
	if not widest then
		return {}
	end
	local _, widestTop = worldExtents(widest)
	local ground: { Instance } = {}
	for _, part in candidates do
		local _, top = worldExtents(part)
		if
			part == widest
			or (
				part.Material == widest.Material
				and part.Color == widest.Color
				and math.abs(top.Y - widestTop.Y) < 0.25
			)
		then
			table.insert(ground, part)
		end
	end
	return ground
end

local function resolveTheme(zone: Instance, theme: (string | Theme)?): Theme
	if type(theme) == "table" then
		return theme
	end
	local name = theme or zone:GetAttribute(ZoneDecorator.THEME_ATTRIBUTE)
	if type(name) ~= "string" then
		error(`zone "{zone:GetFullName()}" has no theme: pass options.theme or set its ZoneTheme attribute`, 3)
	end
	return ZoneThemes.get(name)
end

local function makeAmbient(parent: Instance, bounds: Bounds, floorY: number, ambient: ZoneThemes.Ambient)
	local width, depth = bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ
	local volume = Instance.new("Part")
	volume.Name = "AmbientParticles"
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.CanTouch = false
	volume.CastShadow = false
	volume.Transparency = 1
	volume.Size = Vector3.new(width, ambient.height, depth)
	volume.CFrame = CFrame.new(
		(bounds.minX + bounds.maxX) / 2,
		floorY + ambient.lift + ambient.height / 2,
		(bounds.minZ + bounds.maxZ) / 2
	)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = ambient.texture
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = ambient.direction
	local keypoints = {}
	for i, color in ambient.colors do
		local t = if #ambient.colors == 1 then 0 else (i - 1) / (#ambient.colors - 1)
		table.insert(keypoints, ColorSequenceKeypoint.new(t, color))
	end
	if #keypoints == 1 then
		table.insert(keypoints, ColorSequenceKeypoint.new(1, ambient.colors[1]))
	end
	emitter.Color = ColorSequence.new(keypoints)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.2, ambient.size),
		NumberSequenceKeypoint.new(0.8, ambient.size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new(ambient.transparency)
	emitter.Lifetime = NumberRange.new(ambient.lifetime[1], ambient.lifetime[2])
	emitter.Speed = NumberRange.new(ambient.speed[1], ambient.speed[2])
	emitter.SpreadAngle = Vector2.new(ambient.spread, ambient.spread)
	emitter.Acceleration = ambient.acceleration
	emitter.LightEmission = ambient.lightEmission
	emitter.Rate = math.clamp(ambient.per1000 * width * depth / 1000, 2, 60)
	emitter.Parent = volume
	volume.Parent = parent
end

function ZoneDecorator.clear(zone: Instance)
	local existing = zone:FindFirstChild(ZoneDecorator.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
end

function ZoneDecorator.decorate(zone: Instance, options: Options?): (Folder, Report)
	local opts: Options = options or {}
	local theme = resolveTheme(zone, opts.theme)

	-- Floor and footprint --------------------------------------------------------------
	local ground = collectGround(zone, opts.ground)
	local groundParts: { Instance } = {}
	local allowTerrain = false
	for _, item in ground do
		if item:IsA("Terrain") then
			allowTerrain = true
		elseif item:IsA("BasePart") then
			table.insert(groundParts, item)
		end
	end

	if #groundParts == 0 and not allowTerrain then
		error(
			`no floor found in "{zone:GetFullName()}": tag its floor parts "{ZoneDecorator.GROUND_TAG}" or pass options.ground`,
			2
		)
	end

	local bounds: Bounds
	local floorY: number
	local bottomY: number
	if opts.bounds then
		local center, half = opts.bounds.center, opts.bounds.size / 2
		bounds =
			{ minX = center.X - half.X, maxX = center.X + half.X, minZ = center.Z - half.Z, maxZ = center.Z + half.Z }
		floorY, bottomY = center.Y + half.Y, center.Y - half.Y
	else
		if #groundParts == 0 then
			error(`a Terrain floor has no size: pass options.bounds for "{zone:GetFullName()}"`, 2)
		end
		bounds = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
		floorY, bottomY = -math.huge, math.huge
		for _, item in groundParts do
			local low, high = worldExtents(item :: BasePart)
			bounds.minX, bounds.maxX = math.min(bounds.minX, low.X), math.max(bounds.maxX, high.X)
			bounds.minZ, bounds.maxZ = math.min(bounds.minZ, low.Z), math.max(bounds.maxZ, high.Z)
			floorY, bottomY = math.max(floorY, high.Y), math.min(bottomY, low.Y)
		end
	end
	-- Only now that the zone checks out: the previous decorations must not block the new ones.
	ZoneDecorator.clear(zone)
	local centerX, centerZ = (bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2

	-- Queries ---------------------------------------------------------------------------
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local seeThrough: { Instance } = {}
	rayParams.FilterDescendantsInstances = seeThrough
	local rayOriginY = floorY + 80
	local rayLength = floorY - bottomY + 160

	-- Finds the floor under (x, z). Fails if something other than the floor is hit first,
	-- which is how paths, platforms and props already sitting on the floor are avoided.
	local function floorAt(x: number, z: number): Vector3?
		for _ = 1, 8 do
			local hit = workspace:Raycast(Vector3.new(x, rayOriginY, z), Vector3.new(0, -rayLength, 0), rayParams)
			if not hit then
				return nil
			end
			local instance = hit.Instance
			if (allowTerrain and instance:IsA("Terrain")) or table.find(groundParts, instance) then
				return hit.Position
			end
			if instance:IsA("BasePart") and instance.Transparency >= 0.95 then
				-- Invisible ceilings and trigger volumes: look through them from now on.
				table.insert(seeThrough, instance)
				rayParams.FilterDescendantsInstances = seeThrough
			else
				return nil
			end
		end
		return nil
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = groundParts
	local padding = opts.padding or 2

	-- True when an existing object (not the floor) intrudes on the space a prop needs. Only the
	-- prop's core is checked, so canopies may overhang a wall; `padding` adds breathing room.
	local function obstructed(position: Vector3, radius: number, height: number): boolean
		local reach = (radius * 0.5 + padding) * 2
		local size = Vector3.new(reach, height, reach)
		local box = CFrame.new(position + Vector3.new(0, height / 2 + 0.05, 0))
		for _, part in workspace:GetPartBoundsInBox(box, size, overlapParams) do
			if not isGhost(part) or part:HasTag(ZoneDecorator.KEEP_CLEAR_TAG) then
				return true
			end
		end
		return false
	end

	-- Placement -------------------------------------------------------------------------
	local rng = Rng.new(opts.seed or zone.Name)
	local density = opts.density or 1
	local grid = Scatter.newGrid(4)
	local flatGrid = Scatter.newGrid(4) -- ground cover only has to avoid other ground cover
	local keepClear: { Scatter.Circle } = {}
	if opts.keepClear then
		for _, area in opts.keepClear do
			table.insert(keepClear, { x = area.position.X, z = area.position.Z, r = area.radius })
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = ZoneDecorator.FOLDER_NAME
	local counts: { [string]: number } = {}
	local shortfall: { [string]: number } = {}
	local total = 0

	local function place(propName: string, x: number, z: number, yaw: number, scale: number): boolean
		local spec = Props.specs[propName]
		local radius = spec.radius * scale
		local occupied = if spec.flat then flatGrid else grid
		if not occupied:fits(x, z, radius) or Scatter.insideAny(keepClear, x, z, radius) then
			return false
		end
		local floor = floorAt(x, z)
		if not floor or obstructed(floor, radius, spec.height * scale) then
			return false
		end
		local model =
			spec.build(folder, CFrame.new(floor) * CFrame.Angles(0, yaw, 0), rng:fork(propName), theme.palette, scale)
		model:AddTag(ZoneDecorator.DECORATION_TAG)
		occupied:add(x, z, radius)
		counts[propName] = (counts[propName] or 0) + 1
		total += 1
		return true
	end

	-- Edge lights go first so they get evenly spaced spots before anything else competes.
	if theme.perimeter and opts.perimeter ~= false then
		for _, point in Scatter.perimeter(bounds, theme.perimeter.inset, theme.perimeter.spacing) do
			local dx, dz = centerX - point.x, centerZ - point.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance > 0 then
				-- Face the zone's middle (lantern arms reach over the play area). If a wall or
				-- fence lines the edge, step inward a little before giving up on this spot.
				local yaw = math.atan2(-dx, -dz)
				for step = 0, 2 do
					local shift = math.min(step * 3, distance)
					local x, z = point.x + dx / distance * shift, point.z + dz / distance * shift
					if place(theme.perimeter.prop, x, z, yaw, 1) then
						break
					end
				end
			end
		end
	end

	-- The border frame first, then largest props first so small clutter fills the gaps.
	local entries = table.clone(theme.scatter)
	table.sort(entries, function(a, b)
		local orderA, orderB = PLACEMENT_ORDER[a.placement], PLACEMENT_ORDER[b.placement]
		if orderA ~= orderB then
			return orderA < orderB
		end
		local sizeA = Props.specs[a.prop].radius * (a.scale[1] + a.scale[2])
		local sizeB = Props.specs[b.prop].radius * (b.scale[1] + b.scale[2])
		if sizeA ~= sizeB then
			return sizeA > sizeB
		end
		return a.prop < b.prop
	end)

	local area = Scatter.area(bounds)
	for _, entry in entries do
		local spec = Props.specs[entry.prop]
		local amount = if entry.placement == "border"
			then entry.density * Scatter.perimeterLength(bounds, 0) / 100
			else entry.density * area / 1000
		local target = math.floor(amount * density + 0.5)
		if entry.max then
			target = math.min(target, entry.max)
		end
		local picker = rng:fork(entry.prop .. entry.placement)
		local placed, attempts = 0, 0
		local maxAttempts = target * 30 + 20
		while placed < target and attempts < maxAttempts do
			attempts += 1
			local scale = picker:range(entry.scale[1], entry.scale[2])
			local radius = spec.radius * scale
			if bounds.maxX - bounds.minX <= radius * 2 or bounds.maxZ - bounds.minZ <= radius * 2 then
				break
			end
			local x, z
			if entry.placement == "border" then
				-- A random spot along the rim, just far enough in to keep the prop on the floor.
				local inset = radius + picker:range(0, BORDER_DEPTH)
				local length = Scatter.perimeterLength(bounds, inset)
				if length <= 0 then
					break
				end
				local point = Scatter.perimeterPoint(bounds, inset, picker:range(0, length))
				x, z = point.x, point.z
			else
				x = picker:range(bounds.minX + radius, bounds.maxX - radius)
				z = picker:range(bounds.minZ + radius, bounds.maxZ - radius)
			end
			local accepted = true
			if entry.placement == "edge" then
				accepted = Scatter.edgeFactor(bounds, x, z) <= EDGE_BAND
			elseif entry.placement == "any" then
				-- Thin out toward the middle so the play area stays walkable.
				accepted = picker:next() < 1 - 0.65 * Scatter.edgeFactor(bounds, x, z)
			end
			if accepted and place(entry.prop, x, z, picker:range(0, TAU), scale) then
				placed += 1
			end
		end
		if placed < target then
			shortfall[entry.prop] = (shortfall[entry.prop] or 0) + target - placed
		end
	end

	if theme.ambient and opts.ambient ~= false then
		makeAmbient(folder, bounds, floorY, theme.ambient)
	end

	local parts = 0
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			parts += 1
		end
	end
	-- Parent last: one replication/render update instead of hundreds.
	folder.Parent = zone

	return folder,
		{
			zone = zone.Name,
			theme = theme.name,
			props = total,
			parts = parts,
			counts = counts,
			shortfall = shortfall,
		}
end

-- Decorates every child of `container` that has a ZoneTheme attribute.
function ZoneDecorator.decorateAll(container: Instance, options: Options?): { Report }
	local reports: { Report } = {}
	for _, zone in container:GetChildren() do
		if type(zone:GetAttribute(ZoneDecorator.THEME_ATTRIBUTE)) == "string" then
			local zoneOptions = table.clone(options or {}) :: Options
			zoneOptions.theme = nil
			local _, report = ZoneDecorator.decorate(zone, zoneOptions)
			table.insert(reports, report)
		end
	end
	return reports
end

-- One line per zone, for the command bar output.
function ZoneDecorator.describe(report: Report): string
	local names = {}
	for name in report.counts do
		table.insert(names, name)
	end
	table.sort(names)
	local parts = {}
	for _, name in names do
		table.insert(parts, `{name} {report.counts[name]}`)
	end
	local line =
		`{report.zone} ({report.theme}): {report.props} props, {report.parts} parts - {table.concat(parts, ", ")}`
	local missing = {}
	for name, count in report.shortfall do
		table.insert(missing, `{name} {count}`)
	end
	if #missing > 0 then
		table.sort(missing)
		line ..= ` | no room for: {table.concat(missing, ", ")}`
	end
	return line
end

return ZoneDecorator

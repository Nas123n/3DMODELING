--!strict
-- Reads the developer's vocabulary out of the world: parts or models tagged NpcPoi (with
-- PoiKind, PoiWeight, PoiRadius, PoiDwell, NpcCapacity, PoiId, PoiWord attributes), NpcSpawn
-- areas and NpcAvoid volumes, into a PoiRegistry; plus the seats (Seat/VehicleSeat parts and
-- NpcSeat-tagged parts, attached to the POI whose radius covers them), NpcSlow volumes with their
-- NavCost, NpcNoSpawn volumes and standable props. Anything under an NpcIgnore-tagged instance
-- is left out of props and seats. Only GetDescendants, tags, attributes and part geometry are
-- used, so the same scan runs in Studio and under Lune. It never touches the nav grid: callers
-- turn slow parts into `grid:setCost` calls and no-spawn parts into spawn-point rejections.
-- requires: PoiRegistry

local PoiRegistry = require(script.Parent.PoiRegistry)

local Scan = {}

export type Prop = { id: string, position: Vector3, top: number, footprint: number }
export type SeatRecord = { id: string, position: Vector3, poiId: string?, source: any? }
export type SlowPart = { part: BasePart, cost: number }

Scan.SEAT_TAG = "NpcSeat"
Scan.SLOW_TAG = "NpcSlow"
Scan.NO_SPAWN_TAG = "NpcNoSpawn"
Scan.IGNORE_TAG = "NpcIgnore"
Scan.PROP_TAG = "NpcProp"
Scan.DEFAULT_SLOW_COST = 4

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function stringAttribute(instance: Instance, name: string, default: string): string
	local value = instance:GetAttribute(name)
	return if type(value) == "string" then value else default
end

local function pivotOf(instance: Instance): (CFrame?, Vector3?)
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	elseif instance:IsA("Model") then
		return instance.WorldPivot, nil
	end
	return nil, nil
end

-- True when the instance or any ancestor below `root` carries the NpcIgnore tag.
local function isIgnored(instance: Instance, root: Instance): boolean
	local current: Instance? = instance
	while current and current ~= root do
		if current:HasTag(Scan.IGNORE_TAG) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Fills (or refills) a registry from everything under `root`. Returns the registry.
function Scan.into(registry: PoiRegistry.Registry, root: Instance): PoiRegistry.Registry
	local counter = 0
	for _, instance in root:GetDescendants() do
		local isPoi = instance:HasTag(PoiRegistry.POI_TAG)
		local isSpawn = instance:HasTag(PoiRegistry.SPAWN_TAG)
		local isAvoid = instance:HasTag(PoiRegistry.AVOID_TAG)
		if not (isPoi or isSpawn or isAvoid) then
			continue -- untagged: never read its pivot (an unplaced Model has none under Lune)
		end
		local cf, size = pivotOf(instance)
		if not cf then
			continue
		end
		if isPoi then
			counter += 1
			local position = cf.Position
			-- Floor-projected: the point of interest is where you stand, not the marker's center.
			if size then
				position = Vector3.new(position.X, position.Y - size.Y / 2, position.Z)
			end
			local capacity = instance:GetAttribute("NpcCapacity")
			local dwell = instance:GetAttribute("PoiDwell")
			local word = instance:GetAttribute("PoiWord")
			registry:addPoi({
				id = stringAttribute(instance, "PoiId", `{instance.Name}#{counter}`),
				kind = stringAttribute(instance, "PoiKind", "hangout"),
				position = position,
				weight = numberAttribute(instance, "PoiWeight", 1),
				radius = numberAttribute(instance, "PoiRadius", 6),
				dwellMedian = if type(dwell) == "number" then dwell else nil,
				capacity = if type(capacity) == "number" then capacity else nil,
				word = if type(word) == "string" and word ~= "" then word else nil,
				source = instance,
			})
		end
		if isSpawn and size then
			counter += 1
			registry:addSpawn({ id = `{instance.Name}#{counter}`, cframe = cf, size = size })
		end
		if isAvoid and size then
			counter += 1
			registry:addAvoid({ id = `{instance.Name}#{counter}`, cframe = cf, size = size })
		end
	end
	return registry
end

function Scan.registry(root: Instance): PoiRegistry.Registry
	return Scan.into(PoiRegistry.new(), root)
end

-- Things NPCs might climb onto: parts tagged NpcProp, or any collidable part whose top is
-- between 2 and 7 studs up and whose footprint is 3 to 12 studs (a crate, a pillar, a sign).
-- Parts under an NpcIgnore-tagged instance are never props.
function Scan.props(root: Instance, autoDetect: boolean?): { Prop }
	local props: { Prop } = {}
	local counter = 0
	for _, instance in root:GetDescendants() do
		if not instance:IsA("BasePart") then
			continue
		end
		local tagged = instance:HasTag(Scan.PROP_TAG)
		if not tagged and not autoDetect then
			continue
		end
		if isIgnored(instance, root) then
			continue
		end
		local size = instance.Size
		local footprint = math.min(size.X, size.Z)
		local top = instance.CFrame.Position.Y + size.Y / 2
		local height = size.Y
		if not tagged then
			if not instance.CanCollide or instance.Transparency >= 0.95 then
				continue
			end
			if height < 2 or height > 7 or footprint < 3 or footprint > 12 or math.max(size.X, size.Z) > 16 then
				continue
			end
		end
		counter += 1
		table.insert(props, {
			id = `{instance.Name}#{counter}`,
			position = Vector3.new(
				instance.CFrame.Position.X,
				instance.CFrame.Position.Y - size.Y / 2,
				instance.CFrame.Position.Z
			),
			top = top,
			footprint = footprint,
		})
	end
	return props
end

-- Avoid volumes as BaseParts for NavGrid.sample.
function Scan.avoidParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and instance:HasTag(PoiRegistry.AVOID_TAG) then
			table.insert(parts, instance)
		end
	end
	return parts
end

-- Every Seat and VehicleSeat under root, plus any BasePart tagged NpcSeat, recorded through
-- `registry:addSeat`. A seat's position is the floor point one stud in front of it (where an NPC
-- walks to before sitting); its poiId is the nearest POI whose PoiRadius covers that point, else
-- nil. Seats under an NpcIgnore-tagged instance (the developer's own vehicles) are skipped.
function Scan.seats(root: Instance, registry: PoiRegistry.Registry): { SeatRecord }
	local seats: { SeatRecord } = {}
	local counter = 0
	for _, instance in root:GetDescendants() do
		if not instance:IsA("BasePart") then
			continue
		end
		if not (instance:IsA("Seat") or instance:IsA("VehicleSeat") or instance:HasTag(Scan.SEAT_TAG)) then
			continue
		end
		if isIgnored(instance, root) then
			continue
		end
		counter += 1
		local cf, size = instance.CFrame, instance.Size
		local front = cf.Position + cf.LookVector * (size.Z / 2 + 1)
		local position = Vector3.new(front.X, cf.Position.Y - size.Y / 2, front.Z)
		local poiId: string? = nil
		local bestDistance = math.huge
		for _, poi in registry:all() do
			local d = flatDistance(poi.position, position)
			if d <= poi.radius and (d < bestDistance or (d == bestDistance and poi.id < (poiId :: string))) then
				poiId, bestDistance = poi.id, d
			end
		end
		local record: SeatRecord = {
			id = `{instance.Name}#{counter}`,
			position = position,
			poiId = poiId,
			source = instance,
		}
		registry:addSeat(record)
		table.insert(seats, record)
	end
	return seats
end

-- NpcSlow volumes with their NavCost (default 4): the caller applies `grid:setCost(cost)` to
-- every cell whose center lies inside the part.
function Scan.slowParts(root: Instance): { SlowPart }
	local parts: { SlowPart } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and instance:HasTag(Scan.SLOW_TAG) then
			table.insert(parts, {
				part = instance,
				cost = math.max(1, numberAttribute(instance, "NavCost", Scan.DEFAULT_SLOW_COST)),
			})
		end
	end
	return parts
end

-- NpcNoSpawn volumes: spawn points inside them are rejected (NPCs may still walk through).
function Scan.noSpawnParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and instance:HasTag(Scan.NO_SPAWN_TAG) then
			table.insert(parts, instance)
		end
	end
	return parts
end

return Scan

--!strict
-- Reads the developer's vocabulary out of the world: parts or models tagged NpcPoi (with
-- PoiKind, PoiWeight, PoiRadius, PoiDwell, NpcCapacity, PoiStandOn attributes), NpcSpawn areas
-- and NpcAvoid volumes, into a PoiRegistry. Only GetDescendants, tags, attributes and part
-- geometry are used, so the same scan runs in Studio and under Lune.

local PoiRegistry = require(script.Parent.PoiRegistry)

local Scan = {}

export type Prop = { id: string, position: Vector3, top: number, footprint: number }

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

-- Fills (or refills) a registry from everything under `root`. Returns the registry.
function Scan.into(registry: PoiRegistry.Registry, root: Instance): PoiRegistry.Registry
	local counter = 0
	for _, instance in root:GetDescendants() do
		local cf, size = pivotOf(instance)
		if not cf then
			continue
		end
		if instance:HasTag(PoiRegistry.POI_TAG) then
			counter += 1
			local position = cf.Position
			-- Floor-projected: the point of interest is where you stand, not the marker's center.
			if size then
				position = Vector3.new(position.X, position.Y - size.Y / 2, position.Z)
			end
			local capacity = instance:GetAttribute("NpcCapacity")
			local dwell = instance:GetAttribute("PoiDwell")
			registry:addPoi({
				id = stringAttribute(instance, "PoiId", `{instance.Name}#{counter}`),
				kind = stringAttribute(instance, "PoiKind", "hangout"),
				position = position,
				weight = numberAttribute(instance, "PoiWeight", 1),
				radius = numberAttribute(instance, "PoiRadius", 6),
				dwellMedian = if type(dwell) == "number" then dwell else nil,
				capacity = if type(capacity) == "number" then capacity else nil,
				source = instance,
			})
		end
		if instance:HasTag(PoiRegistry.SPAWN_TAG) and size then
			counter += 1
			registry:addSpawn({ id = `{instance.Name}#{counter}`, cframe = cf, size = size })
		end
		if instance:HasTag(PoiRegistry.AVOID_TAG) and size then
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
function Scan.props(root: Instance, autoDetect: boolean?): { Prop }
	local props: { Prop } = {}
	local counter = 0
	for _, instance in root:GetDescendants() do
		if not instance:IsA("BasePart") then
			continue
		end
		local tagged = instance:HasTag("NpcProp")
		if not tagged and not autoDetect then
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

return Scan

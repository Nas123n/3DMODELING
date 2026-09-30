-- Test worlds for the Lune suite: floors, walls, pillars, ramps, raised platforms with a gap, and
-- tagged points of interest, spawn areas and no-go areas. Every helper returns the instances it
-- made so a test can move or delete them mid-run (dynamic obstacles). Positions are plain
-- Vector3 studs; the floor's top surface is at y = 0 unless an origin says otherwise.

local roblox = require("@lune/roblox")

local Instance, Vector3, CFrame, Color3, Enum =
	roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Color3, roblox.Enum

local Scenes = {}

Scenes.POI_TAG = "NpcPoi"
Scenes.SPAWN_TAG = "NpcSpawn"
Scenes.AVOID_TAG = "NpcAvoid"

local function block(parent: any, name: string, cframe: any, size: any, props: { [string]: any }?): any
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = Color3.fromRGB(163, 162, 165)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props or {} do
		part[key] = value
	end
	part.Parent = parent
	return part
end

Scenes.block = block

-- A flat floor whose top surface is at origin.Y, centered on origin.X/Z.
function Scenes.floor(parent: any, origin: any, width: number, depth: number, name: string?): any
	return block(
		parent,
		name or "Floor",
		CFrame.new(origin - Vector3.new(0, 1, 0)),
		Vector3.new(width, 2, depth),
		{ Material = Enum.Material.Grass }
	)
end

-- A wall standing on the floor between two floor points.
function Scenes.wall(parent: any, from: any, to: any, height: number?, thickness: number?): any
	local h = height or 8
	local t = thickness or 1
	local mid = (from + to) / 2 + Vector3.new(0, h / 2, 0)
	local length = (to - from).Magnitude
	local cf = CFrame.lookAt(mid, mid + (to - from).Unit)
	return block(parent, "Wall", cf, Vector3.new(t, h, length))
end

-- A box obstacle standing on the floor at a point.
function Scenes.pillar(parent: any, at: any, size: number?, height: number?): any
	local s = size or 4
	local h = height or 6
	return block(parent, "Pillar", CFrame.new(at + Vector3.new(0, h / 2, 0)), Vector3.new(s, h, s))
end

-- A ramp rising from `from` (on the floor) to `to` (top of the platform it leads to).
function Scenes.ramp(parent: any, from: any, to: any, width: number?): any
	local w = width or 8
	local mid = (from + to) / 2
	local delta = to - from
	local run = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
	-- Explicit yaw then pitch: Lune's CFrame.lookAt ignores the vertical part of the direction.
	local yaw = math.atan2(-delta.X, -delta.Z)
	local pitch = math.atan2(delta.Y, run)
	local cf = CFrame.new(mid) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, -0.5, 0)
	return block(parent, "Ramp", cf, Vector3.new(w, 1, delta.Magnitude))
end

-- A raised platform whose top surface is at `top`.
function Scenes.platform(parent: any, center: any, width: number, depth: number, top: number): any
	local thickness = 1
	return block(
		parent,
		"Platform",
		CFrame.new(center.X, top - thickness / 2, center.Z),
		Vector3.new(width, thickness, depth)
	)
end

-- A point of interest: an invisible marker part tagged NpcPoi with the standard attributes.
function Scenes.poi(
	parent: any,
	at: any,
	kind: string,
	options: { weight: number?, radius: number?, dwell: number?, name: string? }?
): any
	local o = options or {}
	local marker = block(parent, o.name or `Poi_{kind}`, CFrame.new(at + Vector3.new(0, 1, 0)), Vector3.new(2, 2, 2), {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	marker:AddTag(Scenes.POI_TAG)
	marker:SetAttribute("PoiKind", kind)
	marker:SetAttribute("PoiWeight", o.weight or 1)
	marker:SetAttribute("PoiRadius", o.radius or 6)
	if o.dwell then
		marker:SetAttribute("PoiDwell", o.dwell)
	end
	return marker
end

-- A spawn area: an invisible flat part tagged NpcSpawn whose top surface is at origin.Y.
function Scenes.spawnArea(parent: any, origin: any, width: number, depth: number): any
	local part =
		block(parent, "SpawnArea", CFrame.new(origin - Vector3.new(0, 0.05, 0)), Vector3.new(width, 0.1, depth), {
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
		})
	part:AddTag(Scenes.SPAWN_TAG)
	return part
end

-- A no-go area: an invisible volume tagged NpcAvoid.
function Scenes.avoidArea(parent: any, center: any, size: any): any
	local part = block(parent, "AvoidArea", CFrame.new(center), size, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	part:AddTag(Scenes.AVOID_TAG)
	return part
end

export type ArenaOptions = {
	name: string?,
	origin: any?, -- floor top center; default (0, 0, 0)
	size: number?, -- square floor side; default 120
	walls: boolean?, -- perimeter walls; default true
	pillars: number?, -- scattered box obstacles; default 6
	platform: boolean?, -- raised platform with a ramp on one side and a jump-gap on the other; default true
	pois: boolean?, -- a shop, two hangouts, a viewpoint on the platform; default true
	avoid: boolean?, -- a no-go pool in one corner; default true
}

-- A complete arena: floor, perimeter walls, a grid of pillars in the middle, a raised platform
-- reachable by a ramp (and by a 4-stud jump gap from a stepping block), POIs and a no-go area.
-- Returns the Model plus a table of the notable instances for tests to reference.
function Scenes.arena(session: any, options: ArenaOptions?): (any, { [string]: any })
	local o = options or {}
	local origin = o.origin or Vector3.zero
	local size = o.size or 120
	local half = size / 2
	local model = Instance.new("Model")
	model.Name = o.name or "Arena"
	local made: { [string]: any } = {}

	made.floor = Scenes.floor(model, origin, size, size)
	made.spawn = Scenes.spawnArea(model, origin + Vector3.new(-half + 14, 0, -half + 14), 20, 20)

	if o.walls ~= false then
		local corners = {
			origin + Vector3.new(-half, 0, -half),
			origin + Vector3.new(half, 0, -half),
			origin + Vector3.new(half, 0, half),
			origin + Vector3.new(-half, 0, half),
		}
		made.walls = {}
		for i = 1, 4 do
			table.insert(made.walls, Scenes.wall(model, corners[i], corners[i % 4 + 1]))
		end
	end

	local pillars = if o.pillars == nil then 6 else o.pillars
	made.pillars = {}
	for i = 1, pillars do
		-- Deterministic spread across the middle third so a path always exists around them.
		local angle = (i - 1) / pillars * math.pi * 2
		local radius = size * 0.18
		local at = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		table.insert(made.pillars, Scenes.pillar(model, at, 4, 6))
	end

	if o.platform ~= false then
		local top = 6
		local center = origin + Vector3.new(half - 22, 0, half - 22)
		made.platform = Scenes.platform(model, center, 24, 24, top)
		-- Ramp from the west edge of the platform down toward the floor.
		local rampTop = center + Vector3.new(-12, top, 0)
		local rampFoot = center + Vector3.new(-12 - 18, 0, 0)
		made.ramp = Scenes.ramp(model, rampFoot, rampTop, 8)
		-- Stepping block north of the platform, separated by a 4-stud gap: reachable only by jumping.
		local stepCenter = center + Vector3.new(0, 0, -12 - 4 - 3)
		made.step = block(model, "Step", CFrame.new(stepCenter + Vector3.new(0, top / 2, 0)), Vector3.new(6, top, 6))
	end

	if o.pois ~= false then
		made.shop =
			Scenes.poi(model, origin + Vector3.new(half - 12, 0, -half + 12), "shop", { weight = 2, radius = 7 })
		made.hangoutA = Scenes.poi(model, origin + Vector3.new(-half + 40, 0, half - 40), "hangout", { radius = 8 })
		made.hangoutB = Scenes.poi(model, origin + Vector3.new(0, 0, -half + 20), "hangout", { radius = 8 })
		if made.platform then
			local p = made.platform.CFrame.Position
			made.viewpoint = Scenes.poi(model, Vector3.new(p.X, 6, p.Z), "viewpoint", { weight = 0.7, radius = 5 })
		end
	end

	if o.avoid ~= false then
		-- A pool in the south-west corner; hangoutA sits 20 studs diagonally away from it.
		made.avoid = Scenes.avoidArea(model, origin + Vector3.new(-half + 20, 2, half - 20), Vector3.new(16, 4, 16))
	end

	model.Parent = session.workspace
	return model, made
end

return Scenes

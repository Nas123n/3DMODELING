-- Test worlds for the Lune suite: floors, walls, pillars, ramps, raised platforms with a gap, and
-- tagged points of interest, spawn areas and no-go areas. Every helper returns the instances it
-- made so a test can move or delete them mid-run (dynamic obstacles). Positions are plain
-- Vector3 studs; the floor's top surface is at y = 0 unless an origin says otherwise.
--
-- Three complete worlds: `arena` (the landed 120x120 crowd world, plus two seats and an NpcSlow
-- strip), `gauntlet` (a 40x160 obstacle course for navigation scenarios) and `plaza` (a 200x200
-- open square with twelve POIs for population and tell-score runs).

local roblox = require("@lune/roblox")

local Instance, Vector3, CFrame, Color3, Enum =
	roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Color3, roblox.Enum

local Scenes = {}

Scenes.POI_TAG = "NpcPoi"
Scenes.SPAWN_TAG = "NpcSpawn"
Scenes.AVOID_TAG = "NpcAvoid"
Scenes.SLOW_TAG = "NpcSlow"
Scenes.NO_SPAWN_TAG = "NpcNoSpawn"
Scenes.SEAT_TAG = "NpcSeat"

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
	options: {
		weight: number?,
		radius: number?,
		dwell: number?,
		name: string?,
		capacity: number?,
		word: string?,
	}?
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
	if o.capacity then
		marker:SetAttribute("NpcCapacity", o.capacity)
	end
	if o.word then
		marker:SetAttribute("PoiWord", o.word)
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

-- A slow area (mud, stairs): an invisible volume tagged NpcSlow with a NavCost attribute. It is
-- not collidable and not queryable, so it never changes what the grid samples; only its cost does.
function Scenes.slowArea(parent: any, center: any, size: any, cost: number?): any
	local part = block(parent, "SlowArea", CFrame.new(center), size, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	part:AddTag(Scenes.SLOW_TAG)
	part:SetAttribute("NavCost", cost or 4)
	return part
end

-- A no-spawn area: an invisible volume tagged NpcNoSpawn.
function Scenes.noSpawnArea(parent: any, center: any, size: any): any
	local part = block(parent, "NoSpawnArea", CFrame.new(center), size, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	part:AddTag(Scenes.NO_SPAWN_TAG)
	return part
end

-- A Seat resting on the floor at `at`, 2x1x2, facing the horizontal direction `facing`.
function Scenes.seat(parent: any, at: any, facing: any?, name: string?): any
	local seat = Instance.new("Seat")
	seat.Name = name or "Seat"
	seat.Anchored = true
	seat.Size = Vector3.new(2, 1, 2)
	local dir = facing or Vector3.new(0, 0, -1)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 1e-6 then
		flat = Vector3.new(0, 0, -1)
	end
	local center = at + Vector3.new(0, 0.5, 0)
	-- Explicit yaw (NavMath.yawOf convention): Lune's CFrame.lookAt mirrors the Z component.
	seat.CFrame = CFrame.new(center) * CFrame.Angles(0, math.atan2(-flat.X, -flat.Z), 0)
	seat.Color = Color3.fromRGB(120, 80, 50)
	seat.Material = Enum.Material.Wood
	seat.Parent = parent
	return seat
end

-- An invisible, non-colliding, non-queryable box: a region tests can refer to (a door opening, a
-- gap, a pocket) without changing what the grid sees.
function Scenes.marker(parent: any, name: string, center: any, size: any): any
	return block(parent, name, CFrame.new(center), size, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
end

-- True when a world point lies inside a part's oriented box.
function Scenes.inside(part: any, point: any): boolean
	local local_ = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	return math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z
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
	seats: boolean?, -- a Seat by hangoutA and a Seat far from every POI; default true
	slow: boolean?, -- an NpcSlow strip along the east wall; default true
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

	if o.seats ~= false then
		-- A seat 3 studs east of hangoutA, facing it: its record attaches to hangoutA.
		local hangoutA = origin + Vector3.new(-half + 40, 0, half - 40)
		made.seatA = Scenes.seat(model, hangoutA + Vector3.new(3, 0, 0), Vector3.new(-1, 0, 0), "SeatA")
		-- A seat more than 40 studs from every POI (shop 43.6, viewpoint 43.1, hangoutB 53.9,
		-- hangoutA 65.9): attaches to nothing.
		made.seatFar = Scenes.seat(model, origin + Vector3.new(half - 19, 0, -5), Vector3.new(0, 0, 1), "SeatFar")
	end

	if o.slow ~= false then
		-- A slow strip along the east wall between the shop and the platform (x 52..56, z -20..4 for
		-- the default size). No landed test path crosses it: the spawn, the POIs, the pillars and
		-- the ramp foot all lie west of it or far north/south along the wall.
		made.slow = Scenes.slowArea(model, origin + Vector3.new(half - 6, 1, -8), Vector3.new(4, 2, 24), 4)
	end

	model.Parent = session.workspace
	return model, made
end

export type GauntletOptions = {
	name: string?,
	origin: any?, -- floor top at the corridor's start edge, centered in x; default (0, 0, 0)
}

-- A 40x160 corridor along +Z (x in [-20, 20], z in [0, 160] from the origin) with, in order: two
-- rows of 8-stud obstacle blocks offset so the straight line is blocked (passage east, then
-- west), a ramp up 4 studs onto a raised floor, a 5-stud jump gap over a 14-stud drop, a narrow
-- 3-stud door, a dead-end pocket 6 studs deep on the east side, a no-go strip across the corridor
-- with a 4-stud walkable bypass by the west wall, and the objective POI at the end; the spawn area
-- is at the start. Returns the Model plus the notable instances: start (the spawn part), door,
-- gap and pocket (invisible marker boxes), strip (the NpcAvoid part), bypass (a walkable point in
-- the bypass), objective (the POI marker), and the geometry (rows, ramp, platforms, jambs, ...).
-- Grid note: cell centers must not lie inside the door jambs' plane, so the jambs are 0.9 studs
-- thick and centered on z = 100.5; any 2-stud grid with integer bounds straddles them.
function Scenes.gauntlet(session: any, options: GauntletOptions?): (any, { [string]: any })
	local o = options or {}
	local origin = o.origin or Vector3.zero
	local model = Instance.new("Model")
	model.Name = o.name or "Gauntlet"
	local made: { [string]: any } = {}
	local halfWidth = 20
	local length = 160
	local raised = 4

	-- Floors: the lower start floor (z 0..66), a deep floor under the raised section (top -10, so
	-- the gap is a real chasm: too far to drop into, too far to jump out of), and two raised
	-- platforms with the 5-stud gap between them (z 84..89).
	made.floor = Scenes.floor(model, origin + Vector3.new(0, 0, 33), halfWidth * 2, 66, "FloorStart")
	made.pit = Scenes.floor(model, origin + Vector3.new(0, -10, 113), halfWidth * 2, 94, "FloorPit")
	made.platformA = Scenes.platform(model, origin + Vector3.new(0, 0, 75), halfWidth * 2, 18, raised)
	made.platformB = Scenes.platform(model, origin + Vector3.new(0, 0, 124.5), halfWidth * 2, 71, raised)
	made.gap = Scenes.marker(model, "Gap", origin + Vector3.new(0, raised + 2, 86.5), Vector3.new(halfWidth * 2, 4, 5))

	-- Perimeter walls, tall enough to stand 8 studs above the raised floor.
	local corners = {
		origin + Vector3.new(-halfWidth, 0, 0),
		origin + Vector3.new(halfWidth, 0, 0),
		origin + Vector3.new(halfWidth, 0, length),
		origin + Vector3.new(-halfWidth, 0, length),
	}
	made.walls = {}
	for i = 1, 4 do
		table.insert(made.walls, Scenes.wall(model, corners[i], corners[i % 4 + 1], 12))
	end

	-- Spawn at the start.
	made.start = Scenes.spawnArea(model, origin + Vector3.new(0, 0, 8), 24, 12)
	made.spawn = made.start

	-- Two obstacle rows: 4x8x4 blocks two studs apart (too tight to pass, too tall to jump), the
	-- first leaving the east side open, the second the west side.
	made.rows = {}
	local rows = {
		{ z = 26, xs = { -18, -12, -6, 0, 6 } },
		{ z = 40, xs = { -6, 0, 6, 12, 18 } },
	}
	for _, row in rows do
		local blocks = {}
		for _, x in row.xs do
			table.insert(
				blocks,
				block(model, "Obstacle", CFrame.new(origin + Vector3.new(x, 4, row.z)), Vector3.new(4, 8, 4))
			)
		end
		table.insert(made.rows, blocks)
	end

	-- Ramp up 4 studs across the whole corridor (z 54..66), onto platform A.
	made.ramp = Scenes.ramp(model, origin + Vector3.new(0, 0, 54), origin + Vector3.new(0, raised, 66), halfWidth * 2)

	-- Narrow door: two jambs leaving a 3-stud opening at x in [-1.5, 1.5].
	local doorZ = 100.5
	local jambLength = halfWidth - 1.5
	made.doorJambs = {
		block(
			model,
			"DoorJamb",
			CFrame.new(origin + Vector3.new(-1.5 - jambLength / 2, raised + 4, doorZ)),
			Vector3.new(jambLength, 8, 0.9)
		),
		block(
			model,
			"DoorJamb",
			CFrame.new(origin + Vector3.new(1.5 + jambLength / 2, raised + 4, doorZ)),
			Vector3.new(jambLength, 8, 0.9)
		),
	}
	made.door = Scenes.marker(model, "Door", origin + Vector3.new(0, raised + 4, doorZ), Vector3.new(3, 8, 0.9))

	-- Dead-end pocket: two walls jutting 6.5 studs from the east wall (z 108 and 116) form a bay
	-- 6 studs deep and 7 wide, open to the corridor.
	made.pocketWalls = {
		block(model, "PocketWall", CFrame.new(origin + Vector3.new(16.75, raised + 4, 108)), Vector3.new(6.5, 8, 1)),
		block(model, "PocketWall", CFrame.new(origin + Vector3.new(16.75, raised + 4, 116)), Vector3.new(6.5, 8, 1)),
	}
	made.pocket = Scenes.marker(model, "Pocket", origin + Vector3.new(16.75, raised + 4, 112), Vector3.new(6, 8, 7))

	-- No-go strip across the corridor (x -14..20, z 126..130) leaving 6 studs to the west wall, of
	-- which 4 are walkable for a radius-2 agent.
	made.strip = Scenes.avoidArea(model, origin + Vector3.new(3, raised + 2, 128), Vector3.new(34, 4, 4))
	made.bypass = origin + Vector3.new(-17, raised, 128)

	-- The objective at the end.
	made.objective =
		Scenes.poi(model, origin + Vector3.new(0, raised, 150), "objective", { radius = 6, name = "Objective" })

	model.Parent = session.workspace
	return model, made
end

export type PlazaOptions = {
	name: string?,
	origin: any?, -- floor top center; default (0, 0, 0)
	size: number?, -- square floor side; default 200
}

-- A 200x200 open square with perimeter walls, 12 POIs (3 shops, 5 hangouts with NpcCapacity 4,
-- 2 viewpoints, 2 objectives), 3 spawn areas, 2 no-go pools and 20 crates that Scan.props
-- auto-detects (4x4x4, in two rings). Positions below are for the default size and scale with it.
-- Returns the Model plus: pois (all 12), shops, hangouts, viewpoints, objectives, spawns, avoids,
-- props, floor, walls.
function Scenes.plaza(session: any, options: PlazaOptions?): (any, { [string]: any })
	local o = options or {}
	local origin = o.origin or Vector3.zero
	local size = o.size or 200
	local half = size / 2
	local scale = size / 200
	local model = Instance.new("Model")
	model.Name = o.name or "Plaza"
	local made: { [string]: any } = {}

	local function at(x: number, z: number): any
		return origin + Vector3.new(x * scale, 0, z * scale)
	end

	made.floor = Scenes.floor(model, origin, size, size)

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

	made.pois = {}
	made.shops = {}
	made.hangouts = {}
	made.viewpoints = {}
	made.objectives = {}
	local function poi(list: { any }, x: number, z: number, kind: string, options_: any): any
		local marker = Scenes.poi(model, at(x, z), kind, options_)
		table.insert(list, marker)
		table.insert(made.pois, marker)
		return marker
	end
	poi(made.shops, -60, -60, "shop", { weight = 2, radius = 7 })
	poi(made.shops, 60, -60, "shop", { weight = 2, radius = 7 })
	poi(made.shops, 0, -80, "shop", { weight = 2, radius = 7 })
	for _, p in { { -30, 0 }, { 30, 0 }, { 0, 30 }, { -60, 60 }, { 60, 60 } } do
		poi(made.hangouts, p[1], p[2], "hangout", { radius = 8, capacity = 4 })
	end
	poi(made.viewpoints, -85, 0, "viewpoint", { weight = 0.7, radius = 5 })
	poi(made.viewpoints, 85, 0, "viewpoint", { weight = 0.7, radius = 5 })
	poi(made.objectives, 0, 85, "objective", { radius = 6 })
	poi(made.objectives, 0, -35, "objective", { radius = 6 })

	made.spawns = {}
	for _, p in { { -80, -80 }, { 80, -80 }, { -80, 80 } } do
		table.insert(made.spawns, Scenes.spawnArea(model, at(p[1], p[2]), 20 * scale, 20 * scale))
	end

	made.avoids = {
		Scenes.avoidArea(model, at(40, 40) + Vector3.new(0, 2, 0), Vector3.new(20 * scale, 4, 20 * scale)),
		Scenes.avoidArea(model, at(-40, -40) + Vector3.new(0, 2, 0), Vector3.new(16 * scale, 4, 16 * scale)),
	}

	-- Crates: twelve on a ring of radius 70 and eight on a ring of radius 45, every one at least
	-- 10 studs from any POI marker and outside the pools and spawn areas.
	made.props = {}
	local function crate(x: number, z: number)
		local p = at(x, z)
		table.insert(
			made.props,
			block(model, "Crate", CFrame.new(Vector3.new(p.X, origin.Y + 2, p.Z)), Vector3.new(4, 4, 4), {
				Material = Enum.Material.WoodPlanks,
			})
		)
	end
	for i = 0, 11 do
		local angle = i * math.pi / 6
		crate(70 * math.cos(angle), 70 * math.sin(angle))
	end
	for i = 0, 7 do
		local angle = math.pi / 8 + i * math.pi / 4
		crate(45 * math.cos(angle), 45 * math.sin(angle))
	end

	model.Parent = session.workspace
	return model, made
end

return Scenes

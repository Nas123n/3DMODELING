-- Test zones shaped like a typical simulator area: a floor, a raised path through the
-- middle, an egg stand, an invisible zone-trigger volume and optional edge walls.
-- Shared by the tests and the preview renderer.

local roblox = require("@lune/roblox")

local Instance, Vector3, CFrame, Color3, Enum =
	roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Color3, roblox.Enum

local Scenes = {}

-- Floor colors roughly matching each theme, for previews only.
Scenes.FLOORS = {
	Meadow = "#79C75A",
	Forest = "#4E9A4A",
	Desert = "#EBCB8B",
	Snow = "#EEF5FB",
	Volcano = "#4A403C",
	Crystal = "#4E4670",
	Den = "#5E5048",
}

Scenes.PATHS = {
	Meadow = "#D9C08C",
	Forest = "#A58A62",
	Desert = "#D8B06E",
	Snow = "#C9D7E3",
	Volcano = "#2F2927",
	Crystal = "#3A3356",
	Den = "#3F3530",
}

export type ZoneOptions = {
	name: string,
	theme: string,
	origin: any?, -- Vector3 at the floor's top center
	size: number?,
	path: boolean?,
	trigger: boolean?,
	walls: boolean?,
	stand: string?, -- egg tier to put on a stand near the middle
	boss: boolean?,
}

local function block(parent: any, name: string, cframe: any, size: any, color: any, props: { [string]: any }?)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props or {} do
		part[key] = value
	end
	part.Parent = parent
	return part
end

function Scenes.zone(session: any, options: ZoneOptions): any
	local origin = options.origin or Vector3.zero
	local size = options.size or 140
	local zone = Instance.new("Model")
	zone.Name = options.name
	zone:SetAttribute("ZoneTheme", options.theme)

	block(
		zone,
		"Floor",
		CFrame.new(origin - Vector3.new(0, 1, 0)),
		Vector3.new(size, 2, size),
		Color3.fromHex(Scenes.FLOORS[options.theme] or "#7A7A7A")
	)
	if options.path ~= false then
		block(
			zone,
			"Path",
			CFrame.new(origin + Vector3.new(0, 0.05, 0)),
			Vector3.new(size, 0.2, 10),
			Color3.fromHex(Scenes.PATHS[options.theme] or "#999999"),
			{
				Material = Enum.Material.Cobblestone,
			}
		)
	end
	if options.trigger ~= false then
		block(
			zone,
			"ZoneTrigger",
			CFrame.new(origin + Vector3.new(0, 15, 0)),
			Vector3.new(size, 30, size),
			Color3.new(1, 1, 1),
			{
				Transparency = 1,
				CanCollide = false,
			}
		)
	end
	if options.walls then
		local half = size / 2
		for _, wall in
			{
				{ Vector3.new(0, 4, -half + 0.5), Vector3.new(size, 8, 1) },
				{ Vector3.new(0, 4, half - 0.5), Vector3.new(size, 8, 1) },
				{ Vector3.new(-half + 0.5, 4, 0), Vector3.new(1, 8, size) },
				{ Vector3.new(half - 0.5, 4, 0), Vector3.new(1, 8, size) },
			}
		do
			block(zone, "Wall", CFrame.new(origin + wall[1]), wall[2], Color3.fromHex("#8A7F76"))
		end
	end
	if options.stand then
		local EggBuilder = session.require(session.game.ServerStorage.Builders.EggBuilder)
		-- Faces -Z, toward the path.
		EggBuilder.buildStand(options.stand, CFrame.new(origin + Vector3.new(0, 0, 18)), zone)
	end
	if options.boss then
		-- Stand-in for the sleeping boss: a curled-up lump the decorator has to leave room for.
		local boss = Instance.new("Model")
		boss.Name = "SleepingBoss"
		local body = CFrame.new(origin + Vector3.new(0, 4, -24))
		block(boss, "Body", body, Vector3.new(16, 8, 11), Color3.fromHex("#8E2F3A"), { CanCollide = true })
		block(boss, "Head", body * CFrame.new(-9, -1, -4), Vector3.new(6, 5, 6), Color3.fromHex("#A2394A"))
		block(boss, "Tail", body * CFrame.new(8, -2.5, 6), Vector3.new(10, 3, 3), Color3.fromHex("#7C2833"))
		boss.Parent = zone
	end
	zone.Parent = session.workspace
	return zone
end

return Scenes

-- Builds preview scenes with the real builders under Lune and exports them as JSON for
-- viewer.html: `lune run tools/preview/build` (from the repo root), then `node tools/preview/render.mjs`.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Loader = require("../lune/Loader")
local Scenes = require("../lune/Scenes")

local Vector3, CFrame = roblox.Vector3, roblox.CFrame

local OUT = "tools/preview/out"

local function components(cf: any): { number }
	return { cf:GetComponents() }
end

local function rgb(color: any): { number }
	return { color.R, color.G, color.B }
end

local function textOf(gui: any): string?
	for _, d in gui:GetDescendants() do
		if d.ClassName == "TextLabel" then
			return d.Text
		end
	end
	return nil
end

-- Flattens every visible part (plus lights, fires and sign text) under `root`.
local function export(root: any): { [string]: any }
	local parts, lights, fires, texts = {}, {}, {}, {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.99 then
			local shape = if d:IsA("Part") then d.Shape.Name else d.ClassName
			local mesh = d:FindFirstChildOfClass("SpecialMesh")
			if mesh and mesh.MeshType == roblox.Enum.MeshType.Sphere then
				shape = "Ellipsoid"
			end
			table.insert(parts, {
				shape = shape,
				size = { d.Size.X, d.Size.Y, d.Size.Z },
				cf = components(d.CFrame),
				color = rgb(d.Color),
				material = d.Material.Name,
				transparency = d.Transparency,
			})
			for _, gui in d:GetChildren() do
				if gui.ClassName == "SurfaceGui" then
					table.insert(texts, {
						part = #parts,
						face = gui.Face.Name,
						text = textOf(gui) or "",
					})
				end
			end
		elseif d.ClassName == "PointLight" and d.Parent:IsA("BasePart") then
			local p = d.Parent.CFrame.Position
			table.insert(
				lights,
				{ position = { p.X, p.Y, p.Z }, color = rgb(d.Color), range = d.Range, brightness = d.Brightness }
			)
		elseif d.ClassName == "Fire" and d.Parent:IsA("BasePart") then
			local p = d.Parent.CFrame.Position
			table.insert(
				fires,
				{ position = { p.X, p.Y, p.Z }, size = d.Size, color = rgb(d.Color), core = rgb(d.SecondaryColor) }
			)
		end
	end
	return { parts = parts, lights = lights, fires = fires, texts = texts }
end

local function write(name: string, scene: { [string]: any }, extra: { [string]: any }?)
	for key, value in extra or {} do
		scene[key] = value
	end
	fs.writeFile(`{OUT}/{name}.json`, serde.encode("json", scene))
	print(`wrote {OUT}/{name}.json ({#scene.parts} parts, {#scene.lights} lights)`)
end

if not fs.isDir(OUT) then
	fs.writeDir(OUT)
end

local session = Loader.new()
local builders = session.game.ServerStorage.Builders
local ZoneDecorator = session.require(builders.ZoneDecorator)
local ZoneThemes = session.require(builders.ZoneThemes)
local EggBuilder = session.require(builders.EggBuilder)

local themeNames = {}
for name in ZoneThemes.Themes do
	table.insert(themeNames, name)
end
table.sort(themeNames)

for index, themeName in themeNames do
	local zone = Scenes.zone(session, {
		name = themeName,
		theme = themeName,
		origin = Vector3.new(index * 400, 0, 0),
		stand = if themeName == "Den" then nil else "Rare",
		boss = themeName == "Den",
	})
	local _, report = ZoneDecorator.decorate(zone)
	print(ZoneDecorator.describe(report))
	write(`zone-{themeName}`, export(zone), { center = { index * 400, 0, 0 }, span = 140 })
end

-- All five tiers' stands side by side on a plain floor.
local galleryRoot = roblox.Instance.new("Model")
galleryRoot.Name = "Gallery"
local floor = roblox.Instance.new("Part")
floor.Anchored = true
floor.Size = Vector3.new(96, 1, 30)
floor.CFrame = CFrame.new(0, -500.5, 0)
floor.Color = roblox.Color3.fromHex("#9FD68A")
floor.Parent = galleryRoot
local gallery = EggBuilder.buildGallery(CFrame.new(0, -500, 0), galleryRoot)
galleryRoot.Parent = session.workspace
write("eggs", export(galleryRoot), { center = { 0, -500, 0 }, span = 80 })

-- One close-up per tier, to check each variation's pattern.
for _, stand in gallery:GetChildren() do
	local pivot = stand.WorldPivot.Position
	write(
		`stand-{stand:GetAttribute("Tier")}`,
		export(stand),
		{ center = { pivot.X, pivot.Y + 3, pivot.Z }, span = 15 }
	)
end

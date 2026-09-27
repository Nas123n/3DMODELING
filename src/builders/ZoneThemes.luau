--!strict
-- Zone themes: a palette plus which props to scatter, how densely, and where.
--
-- Scatter entries:
--   prop       name from Props.specs
--   placement  "border"  - a ring hugging the zone's outer edge (tree lines, cliff walls)
--              "edge"    - the outer third of the zone, keeping the middle open for play
--              "any"     - anywhere, thinning out toward the middle
--              "uniform" - anywhere, evenly (flat ground cover)
--   density    "border": props per 100 studs of edge; otherwise props per 1000 square studs
--   scale      { min, max } size multiplier
--   max        optional hard cap per zone

local Props = require(script.Parent.Props)

type Palette = Props.Palette

export type Placement = "border" | "edge" | "any" | "uniform"

export type ScatterEntry = {
	prop: string,
	density: number,
	placement: Placement,
	scale: { number },
	max: number?,
}

export type Ambient = {
	colors: { Color3 },
	size: number,
	per1000: number, -- particles per second per 1000 square studs
	lifetime: { number },
	speed: { number },
	height: number, -- emitter volume height above the floor
	lift: number, -- emitter volume starts this far above the floor
	direction: Enum.NormalId,
	acceleration: Vector3,
	spread: number,
	lightEmission: number,
	transparency: number,
	texture: string,
}

export type Theme = {
	name: string,
	palette: Palette,
	scatter: { ScatterEntry },
	perimeter: { prop: string, spacing: number, inset: number }?,
	ambient: Ambient?,
}

local function hex(value: string): Color3
	return Color3.fromHex(value)
end

local function hexes(values: { string }): { Color3 }
	local colors = table.create(#values)
	for i, value in values do
		colors[i] = hex(value)
	end
	return colors
end

local BASE_PALETTE: Palette = {
	leaves = hexes({ "#6CC24A", "#4FAE3B", "#86D65A" }),
	trunk = hex("#7A5230"),
	grass = hexes({ "#6FCB4E", "#58B83F", "#8BDB62" }),
	flowers = hexes({ "#FF6B8B", "#FFD447", "#FFFFFF", "#B98BFF", "#FF9F45" }),
	fruit = {},
	berries = {},
	rock = hexes({ "#9A9A9A", "#B3AFA6", "#85827D" }),
	rockMaterial = Enum.Material.Slate,
	snowCaps = false,
	crystal = hexes({ "#B57CFF", "#7CC8FF" }),
	crystalMaterial = Enum.Material.Glass,
	crystalTransparency = 0.15,
	crystalNeonTips = false,
	crystalGlow = hex("#C79BFF"),
	mushroomCap = hexes({ "#E8453C" }),
	mushroomGlow = false,
	cactus = hex("#5DA35A"),
	bone = hex("#EFE6D2"),
	metal = hex("#3B3B45"),
	flame = hex("#FF8A2B"),
	flameCore = hex("#FFD36B"),
	lamp = hex("#FFE3A1"),
	mound = hex("#8BD66A"),
	lava = hex("#FF5A1F"),
	lavaCore = hex("#FFB23F"),
	gold = hex("#FFC93C"),
	goldBright = hex("#FFE27A"),
	patch = hexes({ "#8FD46C", "#6BBF4E" }),
}

local function palette(overrides: { [string]: any }): Palette
	local result = table.clone(BASE_PALETTE) :: { [string]: any }
	for key, value in overrides do
		assert(BASE_PALETTE[key] ~= nil, `unknown palette key "{key}"`)
		result[key] = value
	end
	return (result :: any) :: Palette
end

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

local AMBIENT: { [string]: Ambient } = {
	Pollen = {
		colors = hexes({ "#FFF6B0", "#FFFFFF" }),
		size = 0.18,
		per1000 = 1.2,
		lifetime = { 5, 8 },
		speed = { 0.2, 0.6 },
		height = 12,
		lift = 1,
		direction = Enum.NormalId.Top,
		acceleration = Vector3.new(0.3, 0.05, 0.1),
		spread = 180,
		lightEmission = 0.6,
		transparency = 0.1,
		texture = SPARKLE,
	},
	Fireflies = {
		colors = hexes({ "#D6FF6B", "#FFF27A" }),
		size = 0.24,
		per1000 = 0.9,
		lifetime = { 4, 7 },
		speed = { 0.3, 0.8 },
		height = 9,
		lift = 1,
		direction = Enum.NormalId.Top,
		acceleration = Vector3.zero,
		spread = 180,
		lightEmission = 1,
		transparency = 0,
		texture = SPARKLE,
	},
	Snowfall = {
		colors = hexes({ "#FFFFFF" }),
		size = 0.3,
		per1000 = 3,
		lifetime = { 7, 9 },
		speed = { 1.5, 2.5 },
		height = 12,
		lift = 16,
		direction = Enum.NormalId.Bottom,
		acceleration = Vector3.new(0.4, -0.3, 0.2),
		spread = 20,
		lightEmission = 0.3,
		transparency = 0,
		texture = SPARKLE,
	},
	Embers = {
		colors = hexes({ "#FFB23F", "#FF5A1F" }),
		size = 0.22,
		per1000 = 1.6,
		lifetime = { 3, 5 },
		speed = { 1, 2.5 },
		height = 4,
		lift = 0.5,
		direction = Enum.NormalId.Top,
		acceleration = Vector3.new(0.2, 0.6, 0),
		spread = 35,
		lightEmission = 1,
		transparency = 0,
		texture = SPARKLE,
	},
	Dust = {
		colors = hexes({ "#E8CFA0" }),
		size = 0.9,
		per1000 = 0.5,
		lifetime = { 6, 9 },
		speed = { 0.5, 1.2 },
		height = 6,
		lift = 0.5,
		direction = Enum.NormalId.Right,
		acceleration = Vector3.new(0.4, 0.05, 0.1),
		spread = 40,
		lightEmission = 0,
		transparency = 0.75,
		texture = SMOKE,
	},
	Sparkles = {
		colors = hexes({ "#C79BFF", "#7CC8FF" }),
		size = 0.3,
		per1000 = 1.2,
		lifetime = { 2, 4 },
		speed = { 0.2, 0.5 },
		height = 10,
		lift = 1,
		direction = Enum.NormalId.Top,
		acceleration = Vector3.zero,
		spread = 180,
		lightEmission = 1,
		transparency = 0,
		texture = SPARKLE,
	},
}

local ZoneThemes = {}

ZoneThemes.Ambient = AMBIENT

ZoneThemes.Themes = {
	Meadow = {
		name = "Meadow",
		palette = palette({
			fruit = hexes({ "#E8403A", "#FF8C2E" }),
			berries = hexes({ "#D93A5E", "#7D5BD9" }),
		}),
		scatter = {
			{ prop = "Tree", placement = "border", density = 5, scale = { 1.1, 1.6 } },
			{ prop = "Bush", placement = "border", density = 3, scale = { 1.0, 1.4 } },
			{ prop = "Tree", placement = "edge", density = 0.25, scale = { 0.9, 1.2 } },
			{ prop = "Rocks", placement = "edge", density = 0.3, scale = { 0.8, 1.2 } },
			{ prop = "Mushrooms", placement = "edge", density = 0.2, scale = { 0.9, 1.2 } },
			{ prop = "Bush", placement = "any", density = 0.5, scale = { 0.8, 1.2 } },
			{ prop = "Flowers", placement = "any", density = 1.3, scale = { 1.0, 1.3 } },
			{ prop = "Grass", placement = "any", density = 2.5, scale = { 0.9, 1.3 } },
			{ prop = "Pebbles", placement = "any", density = 0.3, scale = { 0.8, 1.2 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.5, scale = { 0.9, 1.5 } },
		},
		perimeter = { prop = "Lantern", spacing = 34, inset = 3 },
		ambient = AMBIENT.Pollen,
	},
	Forest = {
		name = "Forest",
		palette = palette({
			patch = hexes({ "#5AA653", "#3F8A45" }),
			leaves = hexes({ "#2F8F46", "#3E9E4F", "#267A3C" }),
			trunk = hex("#5E3B22"),
			grass = hexes({ "#3E9E4F", "#4DAF52", "#338A43" }),
			flowers = hexes({ "#FFFFFF", "#FFD447", "#9FD4FF" }),
			berries = hexes({ "#D93A5E" }),
			rock = hexes({ "#7D8A80", "#6B766E", "#8C968E" }),
			mushroomCap = hexes({ "#E8453C", "#D9822B" }),
		}),
		scatter = {
			{ prop = "PineTree", placement = "border", density = 5, scale = { 1.1, 1.8 } },
			{ prop = "Tree", placement = "border", density = 2, scale = { 1.1, 1.5 } },
			{ prop = "PineTree", placement = "edge", density = 0.35, scale = { 0.8, 1.2 } },
			{ prop = "Rocks", placement = "edge", density = 0.4, scale = { 0.8, 1.3 } },
			{ prop = "Bush", placement = "any", density = 0.8, scale = { 0.8, 1.2 } },
			{ prop = "Mushrooms", placement = "any", density = 0.5, scale = { 0.9, 1.3 } },
			{ prop = "Flowers", placement = "any", density = 0.5, scale = { 0.9, 1.2 } },
			{ prop = "Grass", placement = "any", density = 2.5, scale = { 1.0, 1.4 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.5, scale = { 0.9, 1.5 } },
		},
		perimeter = { prop = "Lantern", spacing = 38, inset = 3 },
		ambient = AMBIENT.Fireflies,
	},
	Desert = {
		name = "Desert",
		palette = palette({
			patch = hexes({ "#F3D89C", "#DDBA78" }),
			trunk = hex("#6B4E36"),
			grass = hexes({ "#C9B26B", "#B59A55", "#D6C27E" }),
			rock = hexes({ "#D9A066", "#C98B55", "#E3B27A" }),
			rockMaterial = Enum.Material.Sandstone,
			mound = hex("#F0D08A"),
		}),
		scatter = {
			{ prop = "RockSpire", placement = "border", density = 2.5, scale = { 1.0, 1.6 } },
			{ prop = "Cactus", placement = "border", density = 3, scale = { 1.0, 1.5 } },
			{ prop = "Rocks", placement = "border", density = 2, scale = { 1.0, 1.5 } },
			{ prop = "Cactus", placement = "edge", density = 0.3, scale = { 0.8, 1.2 } },
			{ prop = "Rocks", placement = "edge", density = 0.4, scale = { 0.8, 1.3 } },
			{ prop = "DeadTree", placement = "edge", density = 0.15, scale = { 0.9, 1.3 } },
			{ prop = "Mound", placement = "any", density = 0.5, scale = { 1.0, 1.6 } },
			{ prop = "Bones", placement = "any", density = 0.15, scale = { 1.0, 1.3 } },
			{ prop = "Grass", placement = "any", density = 0.8, scale = { 0.8, 1.1 } },
			{ prop = "Pebbles", placement = "any", density = 0.6, scale = { 0.9, 1.4 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.4, scale = { 1.0, 1.6 } },
		},
		perimeter = { prop = "Torch", spacing = 32, inset = 3 },
		ambient = AMBIENT.Dust,
	},
	Snow = {
		name = "Snow",
		palette = palette({
			patch = hexes({ "#DCEBF7", "#FFFFFF" }),
			leaves = hexes({ "#2E7D5B", "#25694C", "#357F60" }),
			trunk = hex("#5A3F2B"),
			rock = hexes({ "#8E9AA6", "#A3AEB8", "#7D8994" }),
			snowCaps = true,
			crystal = hexes({ "#A8E6FF", "#CFF4FF" }),
			crystalMaterial = Enum.Material.Ice,
			crystalTransparency = 0.1,
			crystalGlow = hex("#9BE3FF"),
			mound = hex("#F4FAFF"),
		}),
		scatter = {
			{ prop = "PineTree", placement = "border", density = 5.5, scale = { 1.1, 1.8 } },
			{ prop = "RockSpire", placement = "border", density = 1, scale = { 1.0, 1.4 } },
			{ prop = "PineTree", placement = "edge", density = 0.35, scale = { 0.8, 1.2 } },
			{ prop = "Crystals", placement = "edge", density = 0.3, scale = { 0.9, 1.4 } },
			{ prop = "Rocks", placement = "edge", density = 0.35, scale = { 0.8, 1.2 } },
			{ prop = "Snowman", placement = "any", density = 0.05, scale = { 0.9, 1.1 }, max = 2 },
			{ prop = "Mound", placement = "any", density = 0.7, scale = { 1.0, 1.6 } },
			{ prop = "Pebbles", placement = "any", density = 0.2, scale = { 0.8, 1.2 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.4, scale = { 1.0, 1.6 } },
		},
		perimeter = { prop = "Lantern", spacing = 34, inset = 3 },
		ambient = AMBIENT.Snowfall,
	},
	Volcano = {
		name = "Volcano",
		palette = palette({
			patch = hexes({ "#352E2C", "#57493F" }),
			trunk = hex("#2B2522"),
			rock = hexes({ "#3A3535", "#4A4242", "#2E2A2A" }),
			rockMaterial = Enum.Material.Basalt,
			crystal = hexes({ "#FF6A2A", "#FF8F3A" }),
			crystalMaterial = Enum.Material.SmoothPlastic,
			crystalTransparency = 0,
			crystalNeonTips = true,
			crystalGlow = hex("#FF6A2A"),
			bone = hex("#D9CFBC"),
			metal = hex("#2A2626"),
			flame = hex("#FF7A2B"),
		}),
		scatter = {
			{ prop = "BasaltColumns", placement = "border", density = 3, scale = { 1.0, 1.6 } },
			{ prop = "RockSpire", placement = "border", density = 1.5, scale = { 1.0, 1.5 } },
			{ prop = "Rocks", placement = "border", density = 2, scale = { 1.0, 1.5 } },
			{ prop = "Rocks", placement = "edge", density = 0.5, scale = { 0.9, 1.4 } },
			{ prop = "DeadTree", placement = "edge", density = 0.3, scale = { 1.0, 1.4 } },
			{ prop = "Crystals", placement = "edge", density = 0.25, scale = { 0.9, 1.4 } },
			{ prop = "LavaVent", placement = "any", density = 0.2, scale = { 1.0, 1.4 } },
			{ prop = "Bones", placement = "any", density = 0.08, scale = { 0.9, 1.2 } },
			{ prop = "LavaCrack", placement = "any", density = 0.8, scale = { 0.9, 1.4 } },
			{ prop = "Pebbles", placement = "any", density = 0.6, scale = { 0.9, 1.4 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.5, scale = { 1.0, 1.6 } },
		},
		perimeter = { prop = "Brazier", spacing = 30, inset = 3 },
		ambient = AMBIENT.Embers,
	},
	Crystal = {
		name = "Crystal",
		palette = palette({
			patch = hexes({ "#5B5282", "#433B63" }),
			rock = hexes({ "#4B4466", "#3D3754", "#5A5277" }),
			crystal = hexes({ "#B57CFF", "#7CC8FF", "#FF8AE2" }),
			mushroomCap = hexes({ "#62F2FF", "#C57CFF" }),
			mushroomGlow = true,
		}),
		scatter = {
			{ prop = "Crystals", placement = "border", density = 5, scale = { 1.4, 2.2 } },
			{ prop = "Stalagmite", placement = "border", density = 2.5, scale = { 1.2, 1.8 } },
			{ prop = "Crystals", placement = "edge", density = 0.3, scale = { 0.9, 1.3 } },
			{ prop = "Rocks", placement = "edge", density = 0.4, scale = { 0.8, 1.2 } },
			{ prop = "Mushrooms", placement = "any", density = 0.6, scale = { 0.9, 1.3 } },
			{ prop = "Crystals", placement = "any", density = 0.2, scale = { 0.5, 0.7 } },
			{ prop = "Pebbles", placement = "any", density = 0.5, scale = { 0.8, 1.2 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.4, scale = { 1.0, 1.6 } },
		},
		ambient = AMBIENT.Sparkles,
	},
	Den = {
		name = "Den",
		palette = palette({
			patch = hexes({ "#4E423B", "#6B5A4E" }),
			trunk = hex("#3A2E28"),
			rock = hexes({ "#4A3F3A", "#5A4D45", "#3C3330" }),
			crystal = hexes({ "#C0303A", "#8E1F2B" }),
			crystalMaterial = Enum.Material.SmoothPlastic,
			crystalTransparency = 0,
			crystalNeonTips = true,
			crystalGlow = hex("#FF4040"),
			bone = hex("#E9DFC8"),
			metal = hex("#2E2A28"),
			flame = hex("#FF7A2B"),
		}),
		scatter = {
			{ prop = "RockSpire", placement = "border", density = 3.5, scale = { 1.1, 1.8 } },
			{ prop = "Stalagmite", placement = "border", density = 2.5, scale = { 1.2, 1.8 } },
			{ prop = "Stalagmite", placement = "edge", density = 0.3, scale = { 0.9, 1.3 } },
			{ prop = "Rocks", placement = "edge", density = 0.5, scale = { 0.9, 1.4 } },
			{ prop = "Crystals", placement = "edge", density = 0.2, scale = { 0.9, 1.3 } },
			{ prop = "Treasure", placement = "any", density = 0.12, scale = { 1.3, 1.7 }, max = 4 },
			{ prop = "Bones", placement = "any", density = 0.35, scale = { 1.0, 1.4 } },
			{ prop = "Pebbles", placement = "any", density = 0.7, scale = { 0.9, 1.4 } },
			{ prop = "GroundPatch", placement = "uniform", density = 0.5, scale = { 1.0, 1.6 } },
		},
		perimeter = { prop = "Brazier", spacing = 26, inset = 3 },
		ambient = AMBIENT.Embers,
	},
} :: { [string]: Theme }

function ZoneThemes.get(name: string): Theme
	local theme = ZoneThemes.Themes[name]
	if not theme then
		local names = {}
		for key in ZoneThemes.Themes do
			table.insert(names, key)
		end
		table.sort(names)
		error(`unknown zone theme "{name}" (available: {table.concat(names, ", ")})`, 2)
	end
	return theme
end

-- Catch typos in prop names when the module loads rather than halfway through a build.
for themeName, theme in ZoneThemes.Themes do
	for _, entry in theme.scatter do
		assert(Props.specs[entry.prop], `theme "{themeName}" scatters unknown prop "{entry.prop}"`)
	end
	if theme.perimeter then
		assert(
			Props.specs[theme.perimeter.prop],
			`theme "{themeName}" uses unknown perimeter prop "{theme.perimeter.prop}"`
		)
	end
end

return ZoneThemes

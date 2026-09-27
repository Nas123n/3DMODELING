--!strict
-- Procedural decoration props. Each builder takes the ground CFrame to stand on (already
-- yawed), a random generator, the zone palette and a scale, and returns a Model whose
-- pivot is that ground point.

local Geometry = require(script.Parent.Geometry)
local Rng = require(script.Parent.Rng)

type Rng = Rng.Rng

export type Palette = {
	leaves: { Color3 },
	trunk: Color3,
	grass: { Color3 },
	flowers: { Color3 },
	fruit: { Color3 }, -- empty = trees never carry fruit
	berries: { Color3 }, -- empty = bushes never carry berries
	rock: { Color3 },
	rockMaterial: Enum.Material,
	snowCaps: boolean, -- snow on pine tiers and rock tops
	crystal: { Color3 },
	crystalMaterial: Enum.Material,
	crystalTransparency: number,
	crystalNeonTips: boolean,
	crystalGlow: Color3,
	mushroomCap: { Color3 },
	mushroomGlow: boolean,
	cactus: Color3,
	bone: Color3,
	metal: Color3,
	flame: Color3,
	flameCore: Color3,
	lamp: Color3,
	mound: Color3,
	lava: Color3,
	lavaCore: Color3,
	gold: Color3,
	goldBright: Color3,
	patch: { Color3 }, -- ground patches that break up a flat floor
}

export type Builder = (parent: Instance, base: CFrame, rng: Rng, pal: Palette, scale: number) -> Model

export type Spec = {
	radius: number, -- footprint radius at scale 1, used for spacing
	height: number, -- rough height at scale 1, used for the clearance check
	build: Builder,
	-- Lies flat on the floor: other props may stand on it, so it doesn't reserve space.
	flat: boolean?,
}

local WHITE = Color3.fromRGB(255, 255, 255)
local SNOW = Color3.fromRGB(246, 251, 255)
local COAL = Color3.fromRGB(30, 28, 32)
local STEM = Color3.fromRGB(243, 233, 210)
local CARROT = Color3.fromRGB(255, 140, 45)
local SCARF = Color3.fromRGB(214, 48, 64)
local CHEST_WOOD = Color3.fromRGB(138, 90, 43)
local GEMS = { Color3.fromRGB(255, 77, 109), Color3.fromRGB(77, 217, 255), Color3.fromRGB(108, 255, 122) }
local CACTUS_FLOWER = Color3.fromRGB(255, 120, 180)

local TAU = math.pi * 2
local WOOD = Enum.Material.Wood
local NEON = Enum.Material.Neon
local METAL = Enum.Material.Metal
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local part = Geometry.part
local column = Geometry.column
local shade = Geometry.shade

local function jitter(rng: Rng, colors: { Color3 }, amount: number): Color3
	return shade(rng:pick(colors), rng:range(-amount, amount))
end

local function flicker(light: PointLight, amount: number?)
	light:AddTag("Flicker")
	if amount then
		light:SetAttribute("FlickerAmount", amount)
	end
end

local function sparkles(parent: BasePart, color: Color3, rate: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(0.4, 1.2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = rate
	emitter.Parent = parent
end

-- Leafy tree: short root flare, leaning trunk, clustered ball canopy, sometimes fruit.
local function tree(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Tree", parent, base)
	local bark = shade(pal.trunk, rng:range(-0.05, 0.05))
	column(m, base, 0.8 * s, 2.1 * s, shade(bark, -0.06), { material = WOOD, collide = true, name = "Roots" })
	local lean = base * CFrame.Angles(rng:range(-0.07, 0.07), 0, rng:range(-0.07, 0.07))
	local trunkHeight = rng:range(5.2, 6.6) * s
	column(m, lean, trunkHeight, 1.3 * s, bark, { material = WOOD, collide = true, name = "Trunk" })

	local crown = lean * CFrame.new(0, trunkHeight + 1.2 * s, 0)
	part(m, "Ball", crown, Vector3.one * 6.6 * s, jitter(rng, pal.leaves, 0.06), { name = "Leaves" })
	local spin = rng:range(0, TAU)
	for i = 1, 3 do
		local angle = spin + i * TAU / 3 + rng:range(-0.3, 0.3)
		local offset = Vector3.new(math.cos(angle) * 2.6 * s, rng:range(-1.0, 0.4) * s, math.sin(angle) * 2.6 * s)
		part(m, "Ball", crown + offset, Vector3.one * rng:range(4.2, 5.2) * s, jitter(rng, pal.leaves, 0.06), {
			name = "Leaves",
		})
	end
	part(m, "Ball", crown * CFrame.new(0, 2.3 * s, 0), Vector3.one * 4.2 * s, jitter(rng, pal.leaves, 0.06), {
		name = "Leaves",
	})

	if #pal.fruit > 0 and rng:chance(0.35) then
		local color = rng:pick(pal.fruit)
		for _ = 1, rng:int(3, 5) do
			local theta, phi = rng:range(1.0, 1.9), rng:range(0, TAU)
			local direction =
				Vector3.new(math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi))
			part(
				m,
				"Ball",
				crown + direction * 3.25 * s,
				Vector3.one * 0.6 * s,
				color,
				{ name = "Fruit", shadow = false }
			)
		end
	end
	return m
end

-- Stylized pine: stacked, narrowing needle tiers topped with a faceted point.
local function pineTree(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("PineTree", parent, base)
	column(m, base, 2.4 * s, 1.0 * s, shade(pal.trunk, rng:range(-0.05, 0.05)), {
		material = WOOD,
		collide = true,
		name = "Trunk",
	})
	local needles = rng:pick(pal.leaves)
	local width = rng:range(6.0, 6.8) * s
	local tierHeight = 1.7 * s
	local y = 1.8 * s
	for i = 1, rng:int(4, 5) do
		local tierBase = base * CFrame.new(0, y, 0) * CFrame.Angles(0, rng:range(0, math.pi), 0)
		column(m, tierBase, tierHeight, width, shade(needles, (i - 1) * 0.035 + rng:range(-0.02, 0.02)), {
			name = "Needles",
		})
		if pal.snowCaps then
			column(m, tierBase * CFrame.new(0, tierHeight, 0), 0.3 * s, width * 0.9, SNOW, { name = "Snow" })
		end
		y += tierHeight * 0.78
		width *= 0.74
	end
	local tipSize = math.max(width * 0.9, 0.8 * s)
	part(
		m,
		"Block",
		base * CFrame.new(0, y + tierHeight * 0.3, 0) * Geometry.CORNER_UP,
		Vector3.one * tipSize,
		if pal.snowCaps then SNOW else shade(needles, 0.14),
		{ name = "Tip" }
	)
	return m
end

local function bush(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Bush", parent, base)
	local leaf = rng:pick(pal.leaves)
	local mainCenter, mainRadius = base.Position, 0
	for i = 1, rng:int(2, 4) do
		local diameter = rng:range(2.2, 3.4) * s * (if i == 1 then 1.15 else 1)
		local angle = rng:range(0, TAU)
		local reach = if i == 1 then 0 else rng:range(0.9, 1.5) * s
		local cf = base * CFrame.new(math.cos(angle) * reach, diameter * 0.32, math.sin(angle) * reach)
		part(m, "Ball", cf, Vector3.one * diameter, shade(leaf, rng:range(-0.07, 0.07)), { name = "Leaves" })
		if i == 1 then
			mainCenter, mainRadius = cf.Position, diameter / 2
		end
	end
	if #pal.berries > 0 and rng:chance(0.4) then
		local color = rng:pick(pal.berries)
		for _ = 1, rng:int(3, 6) do
			local theta, phi = rng:range(0.3, 1.3), rng:range(0, TAU)
			local direction =
				Vector3.new(math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi))
			part(m, "Ball", CFrame.new(mainCenter + direction * mainRadius), Vector3.one * 0.42 * s, color, {
				name = "Berry",
				shadow = false,
			})
		end
	end
	return m
end

local function flowers(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Flowers", parent, base)
	-- One or two colors per patch reads as a planted bed rather than confetti.
	local colors = { rng:pick(pal.flowers), rng:pick(pal.flowers) }
	for _ = 1, rng:int(5, 8) do
		local angle, reach = rng:range(0, TAU), math.sqrt(rng:next()) * 1.9 * s
		local height = rng:range(0.8, 1.5) * s
		local stem = base
			* CFrame.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
			* CFrame.Angles(rng:range(-0.15, 0.15), 0, rng:range(-0.15, 0.15))
		part(
			m,
			"Block",
			stem * CFrame.new(0, height / 2, 0),
			Vector3.new(0.14 * s, height, 0.14 * s),
			jitter(rng, pal.grass, 0.04),
			{ name = "Stem", shadow = false }
		)
		part(m, "Ball", stem * CFrame.new(0, height, 0), Vector3.one * rng:range(0.65, 0.85) * s, rng:pick(colors), {
			name = "Bloom",
			shadow = false,
		})
	end
	return m
end

local function grass(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Grass", parent, base)
	for _ = 1, rng:int(4, 7) do
		local height = rng:range(1.0, 2.0) * s
		local blade = base
			* CFrame.new(rng:range(-0.5, 0.5) * s, 0, rng:range(-0.5, 0.5) * s)
			* CFrame.Angles(0, rng:range(0, math.pi), 0)
			* CFrame.Angles(rng:range(-0.35, 0.35), 0, rng:range(-0.35, 0.35))
			* CFrame.new(0, height / 2 - 0.1 * s, 0)
		part(m, "Block", blade, Vector3.new(0.14 * s, height, 0.38 * s), jitter(rng, pal.grass, 0.06), {
			name = "Blade",
			shadow = false,
		})
	end
	return m
end

local function rocks(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Rocks", parent, base)
	local size = rng:range(2.4, 4.2) * s
	local mainSize = Vector3.new(size * rng:range(0.9, 1.3), size * rng:range(0.55, 0.85), size * rng:range(0.8, 1.1))
	local main = base
		* CFrame.new(0, mainSize.Y * 0.25, 0)
		* CFrame.Angles(rng:range(-0.2, 0.2), rng:range(0, math.pi), rng:range(-0.2, 0.2))
	part(m, "Block", main, mainSize, jitter(rng, pal.rock, 0.05), {
		material = pal.rockMaterial,
		collide = true,
		name = "Boulder",
	})
	if pal.snowCaps then
		part(
			m,
			"Ellipsoid",
			main * CFrame.new(0, mainSize.Y / 2, 0),
			Vector3.new(mainSize.X * 0.95, 0.7 * s, mainSize.Z * 0.95),
			SNOW,
			{ name = "Snow" }
		)
	end
	for _ = 1, rng:int(1, 3) do
		local angle = rng:range(0, TAU)
		local reach = size * rng:range(0.6, 0.9)
		local stone = rng:range(0.8, 1.6) * s
		local cf = base
			* CFrame.new(math.cos(angle) * reach, stone * 0.25, math.sin(angle) * reach)
			* CFrame.Angles(rng:range(-0.4, 0.4), rng:range(0, math.pi), rng:range(-0.4, 0.4))
		part(
			m,
			"Block",
			cf,
			Vector3.new(stone, stone * rng:range(0.6, 0.9), stone * rng:range(0.8, 1.1)),
			jitter(rng, pal.rock, 0.06),
			{ material = pal.rockMaterial, name = "Stone" }
		)
	end
	return m
end

local function pebbles(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Pebbles", parent, base)
	for _ = 1, rng:int(3, 6) do
		local size = rng:range(0.35, 0.8) * s
		local cf = base
			* CFrame.new(rng:range(-0.9, 0.9) * s, size * 0.2, rng:range(-0.9, 0.9) * s)
			* CFrame.Angles(rng:range(-0.5, 0.5), rng:range(0, math.pi), rng:range(-0.5, 0.5))
		part(m, "Block", cf, Vector3.new(size, size * 0.6, size * 0.85), jitter(rng, pal.rock, 0.07), {
			material = pal.rockMaterial,
			name = "Pebble",
			shadow = false,
		})
	end
	return m
end

local function mushrooms(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Mushrooms", parent, base)
	local capMaterial = if pal.mushroomGlow then NEON else Enum.Material.SmoothPlastic
	for i = 1, rng:int(1, 3) do
		local k = s * rng:range(0.9, 1.2) * (if i == 1 then 1 else rng:range(0.55, 0.8))
		local angle = rng:range(0, TAU)
		local reach = if i == 1 then 0 else rng:range(0.9, 1.3) * s
		local stemBase = base * CFrame.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
		local stemHeight = 1.3 * k
		column(m, stemBase, stemHeight, 0.55 * k, STEM, { name = "Stem" })
		local capCenter = stemBase * CFrame.new(0, stemHeight + 0.05 * k, 0)
		local capColor = rng:pick(pal.mushroomCap)
		local cap = part(m, "Ellipsoid", capCenter, Vector3.new(2.1 * k, 1.0 * k, 2.1 * k), capColor, {
			material = capMaterial,
			name = "Cap",
		})
		for _ = 1, rng:int(3, 5) do
			local point, normal = Geometry.ellipsoidPoint(1.05 * k, 0.5 * k, rng:range(0.3, 1.0), rng:range(0, TAU))
			part(
				m,
				"Ellipsoid",
				Geometry.withUp(capCenter.Position + point, normal),
				Vector3.new(0.42 * k, 0.14 * k, 0.42 * k),
				if pal.mushroomGlow then shade(capColor, 0.25) else WHITE,
				{ name = "Spot", shadow = false }
			)
		end
		if pal.mushroomGlow and i == 1 then
			Geometry.light(cap, capColor, 10, 1)
		end
	end
	return m
end

local function cactus(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Cactus", parent, base)
	local color = shade(pal.cactus, rng:range(-0.05, 0.05))
	local height = rng:range(4.0, 6.2) * s
	local width = 1.4 * s
	column(m, base, height, width, color, { collide = true, name = "Body" })
	part(m, "Ball", base * CFrame.new(0, height, 0), Vector3.one * width, color, { name = "Top" })
	local armWidth = 0.9 * s
	local reach = 1.25 * s
	for arm = 1, rng:int(1, 2) do
		local side = if arm == 1 then 1 else -1
		local armY = height * rng:range(0.38, 0.6)
		local frame = base * CFrame.Angles(0, rng:range(-0.3, 0.3), 0)
		part(
			m,
			"Cylinder",
			frame * CFrame.new(side * (width / 2 + reach / 2), armY, 0),
			Vector3.new(reach + 0.2 * s, armWidth, armWidth),
			color,
			{ name = "Arm" }
		)
		local elbow = frame * CFrame.new(side * (width / 2 + reach - 0.1 * s), armY - 0.1 * s, 0)
		local upHeight = rng:range(1.4, 2.2) * s
		column(m, elbow, upHeight, armWidth, color, { name = "Arm" })
		part(m, "Ball", elbow * CFrame.new(0, upHeight, 0), Vector3.one * armWidth, color, { name = "ArmTop" })
	end
	if rng:chance(0.3) then
		part(m, "Ball", base * CFrame.new(0, height + width * 0.45, 0), Vector3.one * 0.6 * s, CACTUS_FLOWER, {
			name = "Flower",
		})
	end
	return m
end

-- Cluster of faceted crystals leaning away from a tall central one.
local function crystals(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Crystals", parent, base)
	local mainBody: Part? = nil
	for i = 1, rng:int(3, 5) do
		local isMain = i == 1
		local height = (if isMain then rng:range(4.5, 6.5) else rng:range(2.2, 4.0)) * s
		local width = (if isMain then rng:range(1.2, 1.5) else rng:range(0.7, 1.1)) * s
		local angle = rng:range(0, TAU)
		local reach = if isMain then 0 else rng:range(0.8, 1.4) * s
		local tilt = if isMain then rng:range(0, 0.12) else rng:range(0.25, 0.55)
		-- Local +X points away from the cluster center, so tipping around Z leans the crystal outward.
		local root = base
			* CFrame.new(math.cos(angle) * reach, -0.3 * s, math.sin(angle) * reach)
			* CFrame.Angles(0, -angle, 0)
			* CFrame.Angles(0, 0, -tilt)
		local color = jitter(rng, pal.crystal, 0.05)
		local body = part(
			m,
			"Block",
			root * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, math.pi / 4, 0),
			Vector3.new(width, height, width),
			color,
			{
				material = pal.crystalMaterial,
				transparency = pal.crystalTransparency,
				collide = isMain,
				name = "Crystal",
			}
		)
		local tipSize = width * 0.72
		part(
			m,
			"Block",
			root * CFrame.new(0, height - tipSize * 0.12, 0) * Geometry.CORNER_UP,
			Vector3.one * tipSize,
			if pal.crystalNeonTips then shade(color, 0.15) else color,
			{
				material = if pal.crystalNeonTips then NEON else pal.crystalMaterial,
				transparency = if pal.crystalNeonTips then 0 else pal.crystalTransparency,
				name = "Tip",
			}
		)
		if isMain then
			mainBody = body
		end
	end
	if mainBody then
		Geometry.light(mainBody, pal.crystalGlow, 12, 1.2)
	end
	return m
end

local function torch(parent: Instance, base: CFrame, _rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Torch", parent, base)
	column(m, base, 4.2 * s, 0.45 * s, pal.trunk, { material = WOOD, name = "Post" })
	local bowl = base * CFrame.new(0, 4.2 * s, 0)
	column(m, bowl, 0.5 * s, 1.25 * s, pal.metal, { material = METAL, name = "Bowl" })
	local flame = part(m, "Ball", bowl * CFrame.new(0, 0.55 * s, 0), Vector3.one * 0.7 * s, pal.flame, {
		material = NEON,
		shadow = false,
		name = "Flame",
	})
	local fire = Instance.new("Fire")
	fire.Size = 3.2 * s
	fire.Heat = 7
	fire.Color = pal.flame
	fire.SecondaryColor = pal.flameCore
	fire.Parent = flame
	flicker(Geometry.light(flame, pal.flame, 16, 1.4))
	return m
end

local function brazier(parent: Instance, base: CFrame, _rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Brazier", parent, base)
	local stone = pal.rock[1]
	column(m, base, 1.0 * s, 2.6 * s, stone, { material = pal.rockMaterial, collide = true, name = "Base" })
	column(m, base * CFrame.new(0, 1.0 * s, 0), 2.2 * s, 1.3 * s, shade(stone, 0.05), {
		material = pal.rockMaterial,
		collide = true,
		name = "Column",
	})
	local bowl = base * CFrame.new(0, 3.2 * s, 0)
	column(m, bowl, 0.9 * s, 3.2 * s, pal.metal, { material = METAL, collide = true, name = "Bowl" })
	local coals =
		part(m, "Ellipsoid", bowl * CFrame.new(0, 0.9 * s, 0), Vector3.new(2.6 * s, 0.8 * s, 2.6 * s), pal.flame, {
			material = NEON,
			shadow = false,
			name = "Coals",
		})
	local fire = Instance.new("Fire")
	fire.Size = 6 * s
	fire.Heat = 9
	fire.Color = pal.flame
	fire.SecondaryColor = pal.flameCore
	fire.Parent = coals
	flicker(Geometry.light(coals, pal.flame, 22, 1.8))
	return m
end

-- Street lamp; the arm reaches toward the post's front (-Z), i.e. into the zone.
local function lantern(parent: Instance, base: CFrame, _rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Lantern", parent, base)
	column(m, base, 0.35 * s, 1.1 * s, pal.metal, { material = METAL, name = "Foot" })
	column(m, base, 7.2 * s, 0.42 * s, pal.metal, { material = METAL, collide = true, name = "Post" })
	part(
		m,
		"Ball",
		base * CFrame.new(0, 7.3 * s, 0),
		Vector3.one * 0.7 * s,
		pal.metal,
		{ material = METAL, name = "Finial" }
	)
	part(m, "Block", base * CFrame.new(0, 6.9 * s, -0.8 * s), Vector3.new(0.22, 0.22, 1.6) * s, pal.metal, {
		material = METAL,
		name = "Arm",
	})
	part(m, "Block", base * CFrame.new(0, 6.6 * s, -1.5 * s), Vector3.new(0.12, 0.5, 0.12) * s, pal.metal, {
		material = METAL,
		name = "Hook",
	})
	part(m, "Block", base * CFrame.new(0, 6.3 * s, -1.5 * s), Vector3.new(1.0, 0.22, 1.0) * s, pal.metal, {
		material = METAL,
		name = "Cap",
	})
	local glass =
		part(m, "Block", base * CFrame.new(0, 5.75 * s, -1.5 * s), Vector3.new(0.72, 0.9, 0.72) * s, pal.lamp, {
			material = NEON,
			shadow = false,
			name = "Glass",
		})
	part(m, "Block", base * CFrame.new(0, 5.22 * s, -1.5 * s), Vector3.new(0.9, 0.16, 0.9) * s, pal.metal, {
		material = METAL,
		name = "Base",
	})
	flicker(Geometry.light(glass, pal.lamp, 18, 1.1), 0.06)
	return m
end

local function stalagmite(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Stalagmite", parent, base)
	local lean = base * CFrame.Angles(rng:range(-0.08, 0.08), rng:range(0, math.pi), rng:range(-0.08, 0.08))
	local color = jitter(rng, pal.rock, 0.05)
	local width = rng:range(2.4, 3.2) * s
	local y = 0
	for i, step in { { 0.8, 1.0 }, { 0.75, 0.66 }, { 0.6, 0.4 } } do
		local height = rng:range(2.0, 2.6) * s * step[1]
		column(m, lean * CFrame.new(0, y, 0), height, width * step[2], shade(color, -0.03 * (i - 1)), {
			material = pal.rockMaterial,
			collide = i == 1,
			name = "Rock",
		})
		y += height
	end
	part(m, "Block", lean * CFrame.new(0, y, 0) * Geometry.CORNER_UP, Vector3.one * width * 0.3, shade(color, -0.06), {
		material = pal.rockMaterial,
		name = "Tip",
	})
	return m
end

local function deadTree(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("DeadTree", parent, base)
	local bark = shade(pal.trunk, rng:range(-0.04, 0.04))
	local lean = base * CFrame.Angles(rng:range(-0.08, 0.08), 0, rng:range(-0.08, 0.08))
	local height = rng:range(4.5, 6.0) * s
	column(m, lean, height, 0.9 * s, bark, { material = WOOD, collide = true, name = "Trunk" })
	local branches = rng:int(2, 3)
	local spin = rng:range(0, TAU)
	for i = 1, branches do
		local length = rng:range(1.8, 3.0) * s
		local branch = lean
			* CFrame.new(0, height * rng:range(0.45, 0.92), 0)
			* CFrame.Angles(0, spin + i * TAU / branches + rng:range(-0.4, 0.4), 0)
			* CFrame.Angles(0, 0, rng:range(0.5, 0.9)) -- tip the branch's +X axis upward
		part(m, "Cylinder", branch * CFrame.new(length / 2, 0, 0), Vector3.new(length, 0.45 * s, 0.45 * s), bark, {
			material = WOOD,
			name = "Branch",
		})
		local twig = branch * CFrame.new(length, 0, 0) * CFrame.Angles(0, 0, rng:sign() * 0.6)
		part(m, "Cylinder", twig * CFrame.new(0.5 * s, 0, 0), Vector3.new(1.0 * s, 0.25 * s, 0.25 * s), bark, {
			material = WOOD,
			name = "Twig",
		})
	end
	return m
end

local function bones(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Bones", parent, base)
	local skull = base
		* CFrame.Angles(0, rng:range(0, TAU), 0)
		* CFrame.new(0, 0.62 * s, 0)
		* CFrame.Angles(rng:range(-0.2, 0.1), 0, rng:range(-0.15, 0.15))
	part(m, "Ball", skull, Vector3.one * 1.3 * s, pal.bone, { name = "Skull" })
	part(m, "Block", skull * CFrame.new(0, -0.42 * s, -0.18 * s), Vector3.new(0.85, 0.35, 0.7) * s, pal.bone, {
		name = "Jaw",
	})
	for _, x in { -0.26, 0.26 } do
		part(m, "Ball", skull * CFrame.new(x * s, 0.08 * s, -0.5 * s), Vector3.one * 0.34 * s, COAL, {
			name = "Eye",
			shadow = false,
		})
	end
	for _ = 1, rng:int(2, 3) do
		local angle, reach = rng:range(0, TAU), rng:range(1.0, 1.8) * s
		local bone = base
			* CFrame.new(math.cos(angle) * reach, 0.22 * s, math.sin(angle) * reach)
			* CFrame.Angles(0, rng:range(0, TAU), 0)
			* CFrame.Angles(0, 0, rng:range(-0.12, 0.12))
		part(m, "Cylinder", bone, Vector3.new(2.2, 0.34, 0.34) * s, pal.bone, { name = "Bone" })
		for _, x in { -1.1, 1.1 } do
			for _, z in { -0.17, 0.17 } do
				part(m, "Ball", bone * CFrame.new(x * s, 0, z * s), Vector3.one * 0.5 * s, pal.bone, {
					name = "Knob",
					shadow = false,
				})
			end
		end
	end
	return m
end

-- Gold hoard for the boss den: coin mound, loose coins, gems and sometimes a chest.
local function treasure(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Treasure", parent, base)
	local a, b = 2.6 * s, 0.9 * s
	local center = base * CFrame.new(0, 0.1 * s, 0)
	local mound = part(m, "Ellipsoid", center, Vector3.new(a * 2, b * 2, a * 2), pal.gold, { name = "Hoard" })

	local function surface(reach: number, angle: number): (Vector3, Vector3)
		local x, z = math.cos(angle) * reach, math.sin(angle) * reach
		local y = b * math.sqrt(math.max(0, 1 - (reach / a) ^ 2))
		local localPoint = Vector3.new(x, y, z)
		local localNormal = Vector3.new(x / (a * a), y / (b * b), z / (a * a)).Unit
		return center:PointToWorldSpace(localPoint), center:VectorToWorldSpace(localNormal)
	end

	for _ = 1, rng:int(8, 12) do
		local point, normal = surface(math.sqrt(rng:next()) * a * 0.85, rng:range(0, TAU))
		local coin = Geometry.withUp(point, normal)
			* CFrame.Angles(rng:range(-0.4, 0.4), 0, rng:range(-0.4, 0.4))
			* CFrame.Angles(0, 0, math.pi / 2)
		part(m, "Cylinder", coin, Vector3.new(0.14, 0.85, 0.85) * s, pal.goldBright, {
			material = METAL,
			name = "Coin",
			shadow = false,
		})
	end
	for i = 1, 3 do
		local point = surface(rng:range(0.3, 0.7) * a, rng:range(0, TAU))
		part(m, "Block", CFrame.new(point) * Geometry.CORNER_UP, Vector3.one * 0.55 * s, GEMS[i], {
			material = NEON,
			name = "Gem",
			shadow = false,
		})
	end

	if rng:chance(0.6) then
		local chest = base
			* CFrame.Angles(0, rng:range(0, TAU), 0)
			* CFrame.new(a + 0.5 * s, 0, 0)
			* CFrame.Angles(0, math.pi / 2 + rng:range(-0.4, 0.4), 0)
		part(m, "Block", chest * CFrame.new(0, 0.65 * s, 0), Vector3.new(2.4, 1.3, 1.6) * s, CHEST_WOOD, {
			material = WOOD,
			collide = true,
			name = "Chest",
		})
		-- Lid: a cylinder half sunk into the box reads as a rounded lid.
		part(
			m,
			"Cylinder",
			chest * CFrame.new(0, 1.3 * s, 0),
			Vector3.new(2.4, 1.6, 1.6) * s,
			shade(CHEST_WOOD, -0.06),
			{
				material = WOOD,
				name = "Lid",
			}
		)
		for _, x in { -0.8, 0.8 } do
			part(m, "Block", chest * CFrame.new(x * s, 0.66 * s, 0), Vector3.new(0.18, 1.34, 1.64) * s, pal.gold, {
				material = METAL,
				name = "Band",
			})
			part(m, "Cylinder", chest * CFrame.new(x * s, 1.3 * s, 0), Vector3.new(0.18, 1.64, 1.64) * s, pal.gold, {
				material = METAL,
				name = "Band",
			})
		end
		part(
			m,
			"Block",
			chest * CFrame.new(0, 1.15 * s, -0.83 * s),
			Vector3.new(0.35, 0.45, 0.12) * s,
			pal.goldBright,
			{
				material = METAL,
				name = "Lock",
			}
		)
	end
	Geometry.light(mound, pal.goldBright, 12, 0.9)
	sparkles(mound, pal.goldBright, 3)
	return m
end

local function lavaVent(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("LavaVent", parent, base)
	local ring = rng:int(5, 7)
	for i = 1, ring do
		local angle = i * TAU / ring + rng:range(-0.25, 0.25)
		local size = rng:range(1.2, 2.0) * s
		local height = size * rng:range(0.6, 0.9)
		local cf = base
			* CFrame.new(math.cos(angle) * 2.3 * s, height * 0.3, math.sin(angle) * 2.3 * s)
			* CFrame.Angles(rng:range(-0.3, 0.3), rng:range(0, math.pi), rng:range(-0.3, 0.3))
		part(m, "Block", cf, Vector3.new(size, height, size * rng:range(0.8, 1.1)), jitter(rng, pal.rock, 0.05), {
			material = pal.rockMaterial,
			name = "Rim",
		})
	end
	part(m, "Ellipsoid", base * CFrame.new(0, 0.05, 0), Vector3.new(4.0 * s, 0.5, 4.0 * s), pal.lava, {
		material = NEON,
		shadow = false,
		name = "Lava",
	})
	local core = part(m, "Ellipsoid", base * CFrame.new(0, 0.1, 0), Vector3.new(2.2 * s, 0.55, 2.2 * s), pal.lavaCore, {
		material = NEON,
		shadow = false,
		name = "Core",
	})
	local embers = Instance.new("ParticleEmitter")
	embers.Texture = SPARKLE_TEXTURE
	embers.Color = ColorSequence.new(pal.lavaCore, pal.lava)
	embers.LightEmission = 1
	embers.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
	embers.Lifetime = NumberRange.new(1.5, 2.5)
	embers.Speed = NumberRange.new(2, 4)
	embers.SpreadAngle = Vector2.new(25, 25)
	embers.Acceleration = Vector3.new(0, 1, 0)
	embers.Rate = 6
	embers.Parent = core
	flicker(Geometry.light(core, pal.lava, 16, 1.5))
	return m
end

-- Glowing fissure: a short zigzag of neon slabs set into the floor.
local function lavaCrack(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("LavaCrack", parent, base)
	local x, z = 0, 0
	local heading = rng:range(0, TAU)
	for _ = 1, rng:int(3, 5) do
		local length = rng:range(1.8, 3.2) * s
		heading += rng:range(-0.7, 0.7)
		local dx, dz = math.cos(heading), math.sin(heading)
		local mid = base * CFrame.new(x + dx * length / 2, 0.03, z + dz * length / 2) * CFrame.Angles(0, -heading, 0)
		part(m, "Block", mid, Vector3.new(length + 0.3 * s, 0.12, rng:range(0.3, 0.5) * s), pal.lava, {
			material = NEON,
			shadow = false,
			name = "Crack",
		})
		x += dx * length
		z += dz * length
	end
	return m
end

-- Half-buried lump: a snow drift, sand dune or moss hump depending on the palette.
local function mound(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("Mound", parent, base)
	local length, depth = rng:range(4, 7) * s, rng:range(3, 5) * s
	part(
		m,
		"Ellipsoid",
		base,
		Vector3.new(length, rng:range(1.2, 2.0) * s, depth),
		shade(pal.mound, rng:range(-0.03, 0.03)),
		{
			name = "Mound",
		}
	)
	if rng:chance(0.6) then
		part(
			m,
			"Ellipsoid",
			base * CFrame.new(length * 0.35, 0, depth * rng:range(-0.2, 0.2)),
			Vector3.new(length * 0.6, rng:range(0.9, 1.4) * s, depth * 0.7),
			shade(pal.mound, rng:range(-0.03, 0.03)),
			{ name = "Mound" }
		)
	end
	return m
end

local function snowman(parent: Instance, base: CFrame, rng: Rng, _pal: Palette, s: number): Model
	local m = Geometry.model("Snowman", parent, base)
	local body = base * CFrame.Angles(0, rng:range(-0.4, 0.4), 0)
	part(m, "Ball", body * CFrame.new(0, 1.25 * s, 0), Vector3.one * 3.0 * s, SNOW, { collide = true, name = "Bottom" })
	local middle = body * CFrame.new(0, 3.1 * s, 0)
	part(m, "Ball", middle, Vector3.one * 2.2 * s, SNOW, { name = "Middle" })
	local head = body * CFrame.new(0, 4.6 * s, 0)
	part(m, "Ball", head, Vector3.one * 1.6 * s, SNOW, { name = "Head" })
	for _, x in { -0.28, 0.28 } do
		part(m, "Ball", head * CFrame.new(x * s, 0.15 * s, -0.72 * s), Vector3.one * 0.25 * s, COAL, {
			name = "Eye",
			shadow = false,
		})
	end
	part(
		m,
		"Cylinder",
		head * CFrame.new(0, 0, -0.95 * s) * CFrame.Angles(0, math.pi / 2, 0),
		Vector3.new(0.7, 0.22, 0.22) * s,
		CARROT,
		{
			name = "Nose",
		}
	)
	for _, y in { 0.35, -0.2 } do
		part(m, "Ball", middle * CFrame.new(0, y * s, -1.07 * s), Vector3.one * 0.28 * s, COAL, {
			name = "Button",
			shadow = false,
		})
	end
	column(m, body * CFrame.new(0, 3.8 * s, 0), 0.38 * s, 1.5 * s, SCARF, { name = "Scarf" })
	part(
		m,
		"Block",
		body * CFrame.new(0.45 * s, 3.5 * s, -0.98 * s) * CFrame.Angles(0, 0, 0.15),
		Vector3.new(0.35, 0.9, 0.12) * s,
		SCARF,
		{
			name = "Scarf",
		}
	)
	for _, side in { -1, 1 } do
		part(
			m,
			"Cylinder",
			middle * CFrame.new(side * 1.6 * s, 0.35 * s, 0) * CFrame.Angles(0, 0, side * 0.5),
			Vector3.new(1.8, 0.18, 0.18) * s,
			CHEST_WOOD,
			{ material = WOOD, name = "Arm" }
		)
	end
	if rng:chance(0.5) then
		local hat = head * CFrame.new(0, 0.62 * s, 0)
		column(m, hat, 0.15 * s, 1.7 * s, COAL, { name = "Brim" })
		column(m, hat, 1.1 * s, 1.1 * s, COAL, { name = "Hat" })
	end
	return m
end

-- Flat blotch of a slightly different ground color; several overlapping discs make an organic shape.
local function groundPatch(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("GroundPatch", parent, base)
	-- One color per patch: overlapping discs share a top height, so they must match to avoid flicker.
	local color = jitter(rng, pal.patch, 0.02)
	local lift = rng:range(0, 0.03) -- separates patches that overlap each other
	for i = 1, rng:int(3, 5) do
		local angle = rng:range(0, TAU)
		local reach = if i == 1 then 0 else rng:range(1.5, 3.2) * s
		column(
			m,
			base * CFrame.new(math.cos(angle) * reach, -0.06 + lift, math.sin(angle) * reach),
			0.14,
			rng:range(3.5, 6) * s,
			color,
			{
				name = "Patch",
				shadow = false,
			}
		)
	end
	return m
end

-- Tall stack of weathered slabs with boulders at its foot: cave walls, mesas, cliffs.
local function rockSpire(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("RockSpire", parent, base)
	local color = jitter(rng, pal.rock, 0.04)
	local footWidth = rng:range(5, 6.5) * s
	local width = footWidth
	local y = 0
	local tiers = rng:int(3, 4)
	for i = 1, tiers do
		local height = rng:range(2.6, 3.8) * s
		local size = Vector3.new(width * rng:range(0.85, 1.1), height, width * rng:range(0.8, 1.05))
		local slab = base
			* CFrame.new(rng:range(-0.4, 0.4) * s, y + height / 2, rng:range(-0.4, 0.4) * s)
			* CFrame.Angles(rng:range(-0.1, 0.1), rng:range(0, math.pi), rng:range(-0.1, 0.1))
		part(m, "Block", slab, size, shade(color, rng:range(-0.05, 0.05)), {
			material = pal.rockMaterial,
			collide = i <= 2,
			name = "Slab",
		})
		if pal.snowCaps and i == tiers then
			part(
				m,
				"Ellipsoid",
				slab * CFrame.new(0, height / 2, 0),
				Vector3.new(size.X * 0.95, 0.8 * s, size.Z * 0.95),
				SNOW,
				{
					name = "Snow",
				}
			)
		end
		y += height * 0.85
		width *= rng:range(0.62, 0.75)
	end
	for _ = 1, rng:int(2, 3) do
		local angle = rng:range(0, TAU)
		local stone = rng:range(1.5, 2.6) * s
		local cf = base
			* CFrame.new(math.cos(angle) * footWidth * 0.65, stone * 0.3, math.sin(angle) * footWidth * 0.65)
			* CFrame.Angles(rng:range(-0.3, 0.3), rng:range(0, math.pi), rng:range(-0.3, 0.3))
		part(m, "Block", cf, Vector3.new(stone, stone * 0.75, stone * 0.9), jitter(rng, pal.rock, 0.05), {
			material = pal.rockMaterial,
			name = "Boulder",
		})
	end
	return m
end

-- Packed volcanic columns, tallest in the middle, with lava glowing between them.
local function basaltColumns(parent: Instance, base: CFrame, rng: Rng, pal: Palette, s: number): Model
	local m = Geometry.model("BasaltColumns", parent, base)
	local count = rng:int(6, 9)
	local tallest = rng:range(8, 12) * s
	local golden = math.pi * (3 - math.sqrt(5))
	local spin = rng:range(0, TAU)
	for i = 1, count do
		-- Sunflower packing keeps the columns tight without overlapping much.
		local reach = math.sqrt((i - 1) / count) * 2.8 * s
		local angle = spin + i * golden
		local height = math.max(tallest * (1 - reach / (3.6 * s)) * rng:range(0.75, 1.0), 1.5 * s)
		column(
			m,
			base * CFrame.new(math.cos(angle) * reach, -0.2, math.sin(angle) * reach),
			height,
			rng:range(1.8, 2.3) * s,
			jitter(rng, pal.rock, 0.05),
			{
				material = pal.rockMaterial,
				collide = i <= 3,
				name = "Column",
			}
		)
	end
	local glow = part(m, "Ellipsoid", base * CFrame.new(0, 0.02, 0), Vector3.new(7.2 * s, 0.4, 7.2 * s), pal.lava, {
		material = NEON,
		shadow = false,
		name = "Lava",
	})
	if rng:chance(0.5) then
		flicker(Geometry.light(glow, pal.lava, 14, 1))
	end
	return m
end

local Props = {}

Props.specs = {
	Tree = { radius = 3.6, height = 12, build = tree },
	PineTree = { radius = 3.2, height = 11, build = pineTree },
	Bush = { radius = 1.9, height = 3, build = bush },
	Flowers = { radius = 1.9, height = 1.5, build = flowers },
	Grass = { radius = 0.8, height = 1.6, build = grass },
	Rocks = { radius = 2.8, height = 3.5, build = rocks },
	Pebbles = { radius = 1.0, height = 0.6, build = pebbles },
	Mushrooms = { radius = 1.8, height = 2.5, build = mushrooms },
	Cactus = { radius = 2.2, height = 7, build = cactus },
	Crystals = { radius = 2.4, height = 7, build = crystals },
	Torch = { radius = 0.9, height = 6, build = torch },
	Brazier = { radius = 1.8, height = 5, build = brazier },
	Lantern = { radius = 1.2, height = 8, build = lantern },
	Stalagmite = { radius = 1.7, height = 7, build = stalagmite },
	DeadTree = { radius = 2.6, height = 8, build = deadTree },
	Bones = { radius = 2.2, height = 1.5, build = bones },
	Treasure = { radius = 3.6, height = 3, build = treasure },
	LavaVent = { radius = 3.2, height = 2, build = lavaVent },
	LavaCrack = { radius = 3.0, height = 0.3, build = lavaCrack },
	Mound = { radius = 3.2, height = 2, build = mound },
	Snowman = { radius = 1.8, height = 6, build = snowman },
	GroundPatch = { radius = 4.5, height = 0.3, build = groundPatch, flat = true },
	RockSpire = { radius = 4.2, height = 12, build = rockSpire },
	BasaltColumns = { radius = 3.8, height = 11, build = basaltColumns },
} :: { [string]: Spec }

return Props

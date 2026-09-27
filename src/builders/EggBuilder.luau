--!strict
-- Builds egg models from EggConfig: one egg per variation, a display stand per tier
-- (all 3 variations side by side under a sign), and template folders for game code to clone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EggConfig = require(ReplicatedStorage.Shared.EggConfig)
local Geometry = require(script.Parent.Geometry)

type Tier = EggConfig.Tier
type Variation = EggConfig.Variation

local EggBuilder = {}

EggBuilder.EGG_HEIGHT = 3.2
EggBuilder.EGG_TAG = "Egg"

local TAU = math.pi * 2
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local STAND_STONE = Color3.fromRGB(242, 238, 230)
local SIGN_TEXT = Color3.fromRGB(255, 255, 255)
local SIGN_STROKE = Color3.fromRGB(35, 30, 45)
local PLAQUE = Color3.fromRGB(43, 43, 51)

local function tierOf(tierId: string): Tier
	local tier = EggConfig.getTier(tierId)
	if not tier then
		error(`unknown egg tier "{tierId}"`, 3)
	end
	return tier
end

-- Surface point of the egg's ellipsoid (semi-axes a, b, a) at height fraction t (-1 bottom .. 1 top).
local function shellPoint(a: number, b: number, t: number, phi: number): Vector3
	local ring = a * math.sqrt(math.max(0, 1 - t * t))
	return Vector3.new(ring * math.cos(phi), b * t, ring * math.sin(phi))
end

-- Three bands: a wide one round the middle and two thin ones above and below.
local function stripes(model: Model, center: CFrame, a: number, b: number, color: Color3, material: Enum.Material)
	for _, band in { { t = 0, half = 0.1 }, { t = 0.42, half = 0.055 }, { t = -0.42, half = 0.055 } } do
		-- Size the ring for the widest part of the shell it covers, so it never sinks in.
		local widestT = math.max(0, math.abs(band.t) - band.half)
		local radius = a * math.sqrt(1 - widestT * widestT) + 0.02 * a
		Geometry.column(
			model,
			center * CFrame.new(0, (band.t - band.half) * b, 0),
			band.half * 2 * b,
			radius * 2,
			color,
			{
				material = material,
				name = "Stripe",
			}
		)
	end
end

-- Round spots spread evenly over the shell (Fibonacci lattice), kept off the very top and bottom.
local function spots(model: Model, center: CFrame, a: number, b: number, color: Color3, material: Enum.Material)
	local count = 11
	local golden = math.pi * (3 - math.sqrt(5))
	for i = 0, count - 1 do
		local y = (1 - (i + 0.5) / count * 2) * 0.82
		local point, normal = Geometry.ellipsoidPoint(a, b, math.acos(y), i * golden)
		local diameter = a * (0.36 + 0.06 * (i % 3))
		Geometry.part(
			model,
			"Ellipsoid",
			Geometry.withUp(center:PointToWorldSpace(point), center:VectorToWorldSpace(normal)),
			Vector3.new(diameter, diameter * 0.3, diameter),
			color,
			{ material = material, name = "Spot", shadow = false }
		)
	end
end

-- A zigzag band around the middle, like a cracked-open shell line.
local function zigzag(model: Model, center: CFrame, a: number, b: number, color: Color3, material: Enum.Material)
	local segments = 16
	local amplitude = 0.2
	local width = 0.075 * b * 2
	for i = 0, segments - 1 do
		local phi0, phi1 = i / segments * TAU, (i + 1) / segments * TAU
		local t0 = if i % 2 == 0 then amplitude else -amplitude
		local p0, p1 = shellPoint(a, b, t0, phi0), shellPoint(a, b, -t0, phi1)
		local along = (p1 - p0).Unit
		-- The chord's midpoint sits inside the shell; center the slab on the surface instead.
		local midPhi = (phi0 + phi1) / 2
		local radial = Vector3.new(math.cos(midPhi), 0, math.sin(midPhi))
		local position = radial * a
		local outward = (radial - along * along:Dot(radial)).Unit
		Geometry.part(
			model,
			"Block",
			center * CFrame.fromMatrix(position, along, outward),
			Vector3.new((p1 - p0).Magnitude + width * 0.9, 0.1 * a, width),
			color,
			{ material = material, name = "Zigzag" }
		)
	end
end

local PATTERNS = {
	Stripes = stripes,
	Spots = spots,
	Zigzag = zigzag,
}

-- Builds one egg standing with its bottom at `bottom`. Tagged "Egg", with Tier and
-- Variation attributes so game code can tell eggs apart.
function EggBuilder.buildEgg(
	tierId: string,
	variationId: string,
	bottom: CFrame,
	parent: Instance?,
	height: number?
): Model
	local tier = tierOf(tierId)
	local variation = EggConfig.getVariation(tierId, variationId)
	if not variation then
		error(`tier "{tierId}" has no variation "{variationId}"`, 2)
	end
	local h = height or EggBuilder.EGG_HEIGHT
	local a, b = h / 1.3 / 2, h / 2
	local center = bottom * CFrame.new(0, b, 0)
	local base, accent = Color3.fromHex(variation.base), Color3.fromHex(variation.accent)

	local model = Instance.new("Model")
	model.Name = variation.name
	model:SetAttribute("Tier", tier.id)
	model:SetAttribute("Variation", variation.id)
	model:AddTag(EggBuilder.EGG_TAG)
	-- Stream the egg in whole, so the client animator never captures a half-loaded pivot.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local shell = Geometry.part(model, "Ellipsoid", center, Vector3.new(a * 2, h, a * 2), base, { name = "Shell" })
	-- Clickable and hit by raycasts (ClickDetector, Mouse.Target) even though nothing collides.
	shell.CanQuery = true
	-- With a PrimaryPart the model pivots on it, so move that pivot down to the egg's base.
	shell.PivotOffset = CFrame.new(0, -b, 0)
	model.PrimaryPart = shell
	model.WorldPivot = bottom

	local accentMaterial = if tier.effects.neonAccent then Enum.Material.Neon else Enum.Material.SmoothPlastic
	PATTERNS[variation.pattern](model, center, a, b, accent, accentMaterial)

	if tier.effects.light then
		Geometry.light(shell, accent, 10, 1.2)
	end
	if tier.effects.sparkles then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = SPARKLE_TEXTURE
		emitter.Color = ColorSequence.new(accent)
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
		emitter.Lifetime = NumberRange.new(0.8, 1.4)
		emitter.Speed = NumberRange.new(0.6, 1.2)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rate = 4
		emitter.Parent = shell
	end
	if tier.effects.halo then
		local halo = Instance.new("Model")
		halo.Name = "Halo"
		local ring = bottom * CFrame.new(0, h + 0.55, 0)
		for i = 1, 10 do
			local angle = i / 10 * TAU
			Geometry.part(
				halo,
				"Ball",
				ring * CFrame.new(math.cos(angle) * a * 1.35, 0, math.sin(angle) * a * 1.35),
				Vector3.one * 0.3,
				accent,
				{
					material = Enum.Material.Neon,
					shadow = false,
					name = "Orb",
				}
			)
		end
		halo.WorldPivot = ring
		halo:AddTag("Spin")
		halo:SetAttribute("SpinSpeed", 1.4)
		halo.Parent = model
	end

	model.Parent = parent
	return model
end

local function signText(part: BasePart, text: string, pixelsPerStud: number)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = SIGN_TEXT
	local stroke = Instance.new("UIStroke")
	stroke.Color = SIGN_STROKE
	stroke.Thickness = 3
	stroke.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.04, 0)
	padding.PaddingRight = UDim.new(0.04, 0)
	padding.PaddingTop = UDim.new(0.1, 0)
	padding.PaddingBottom = UDim.new(0.1, 0)
	padding.Parent = label
	label.Parent = gui
	gui.Parent = part
end

-- Display stand for one tier: a plinth with the tier's 3 eggs on pedestals, a name plaque
-- under each, and a sign behind. `cframe` is the ground point; the front faces its LookVector.
-- The eggs are tagged Bob and Spin so the client animator makes them float and turn.
function EggBuilder.buildStand(tierId: string, cframe: CFrame, parent: Instance?): Model
	local tier = tierOf(tierId)
	local trim = Color3.fromHex(tier.color)
	local stand = Instance.new("Model")
	stand.Name = `{tier.name}EggStand`
	stand:SetAttribute("Tier", tier.id)
	stand.WorldPivot = cframe

	Geometry.part(stand, "Block", cframe * CFrame.new(0, 0.25, 0), Vector3.new(13.4, 0.5, 5.4), trim, {
		collide = true,
		name = "Plinth",
	})
	Geometry.part(stand, "Block", cframe * CFrame.new(0, 0.75, 0), Vector3.new(12.8, 0.5, 4.8), STAND_STONE, {
		collide = true,
		name = "Plinth",
	})

	local eggs = Instance.new("Folder")
	eggs.Name = "Eggs"
	eggs.Parent = stand
	local count = #tier.variations
	for index, variation in tier.variations do
		-- First variation on the left as seen from the front (the viewer's left is the stand's +X).
		local x = ((count + 1) / 2 - index) * 4.2
		local pedestal = cframe * CFrame.new(x, 1.0, -0.2)
		Geometry.column(stand, pedestal, 1.4, 2.6, STAND_STONE, { collide = true, name = "Pedestal" })
		Geometry.column(
			stand,
			pedestal * CFrame.new(0, 1.4, 0),
			0.25,
			2.9,
			trim,
			{ collide = true, name = "PedestalCap" }
		)
		-- Name plaque leaning back on the plinth in front of the pedestal, museum-label style.
		local plaqueCFrame = cframe * CFrame.new(x, 1.3, -1.95) * CFrame.Angles(math.rad(20), 0, 0)
		local plaque = Geometry.part(stand, "Block", plaqueCFrame, Vector3.new(2.5, 0.55, 0.12), PLAQUE, {
			name = "Plaque",
		})
		signText(plaque, string.gsub(variation.name, " Egg$", ""), 60)

		local egg = EggBuilder.buildEgg(tier.id, variation.id, pedestal * CFrame.new(0, 2.0, 0), eggs)
		egg:AddTag("Bob")
		egg:AddTag("Spin")
		egg:SetAttribute("SpinSpeed", 0.6)
	end

	-- The board ends inside the posts and the posts rise past it: no coplanar faces to flicker.
	for _, x in { -5.6, 5.6 } do
		Geometry.part(stand, "Block", cframe * CFrame.new(x, 5.25, 1.9), Vector3.new(0.4, 8.5, 0.4), SIGN_STROKE, {
			collide = true,
			name = "SignPost",
		})
	end
	local board = Geometry.part(stand, "Block", cframe * CFrame.new(0, 8.2, 1.9), Vector3.new(11.2, 2.2, 0.35), trim, {
		collide = true,
		name = "Sign",
	})
	signText(board, `{tier.name} Eggs`, 40)

	stand.Parent = parent
	return stand
end

local function replaceChild(parent: Instance?, name: string)
	local existing = parent and parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end

-- Every tier's eggs at the origin, grouped as EggTemplates/<Tier>/<Egg name>, for game code
-- to clone (e.g. into ReplicatedStorage for hatch animations). Replaces an earlier build.
function EggBuilder.buildTemplates(parent: Instance?): Folder
	replaceChild(parent, "EggTemplates")
	local root = Instance.new("Folder")
	root.Name = "EggTemplates"
	for _, tier in EggConfig.Tiers do
		local folder = Instance.new("Folder")
		folder.Name = tier.id
		for _, variation in tier.variations do
			EggBuilder.buildEgg(tier.id, variation.id, CFrame.identity, folder)
		end
		folder.Parent = root
	end
	root.Parent = parent
	return root
end

-- One stand per tier in a row centered on `origin`, for previewing every egg at once.
-- Replaces an earlier gallery in the same parent.
function EggBuilder.buildGallery(origin: CFrame, parent: Instance?): Folder
	replaceChild(parent, "EggGallery")
	local gallery = Instance.new("Folder")
	gallery.Name = "EggGallery"
	local count = #EggConfig.Tiers
	for index, tier in EggConfig.Tiers do
		EggBuilder.buildStand(tier.id, origin * CFrame.new((index - (count + 1) / 2) * 16, 0, 0), gallery)
	end
	gallery.Parent = parent
	return gallery
end

return EggBuilder

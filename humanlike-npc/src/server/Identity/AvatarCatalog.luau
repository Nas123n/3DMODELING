--!strict
-- The closed lists the avatar generator draws from: skin tones, body-colour presets, hair,
-- clothing, faces and hats with their population weights, and the colour palettes the block
-- placeholder rig wears. It is data: nothing here is fetched, nothing here yields, and no draw
-- happens here (Avatars does the drawing).
--
-- Every catalog id ships as 0 ("none" / the default piece). With ids at 0 the rig adapter builds
-- proper default R15 avatars from an id-less HumanoidDescription (body colours and scales only),
-- which is the look a real new account has. To add clothing variety, replace the 0s below with
-- catalog ids of classic shirts, pants, faces and accessories that the place's group owns or that
-- are public. The `label` on each entry only says what kind of piece belongs there. Never put an
-- id here that you have not verified: a bad id set is blacklisted for the server run and that
-- NPC is rebuilt with ids 0 (§3.6). `withPlaceholderIds` numbers the entries with plainly fake
-- ids (1000001, 1000002, ...) so tests and dry runs can tell entries apart; those ids are not
-- real assets and must never reach a HumanoidDescription.
-- requires: (none)

local AvatarCatalog = {}

-- gender: "any" | "m" | "f" (filtered by persona.presentation)
export type HairEntry = { id: number, weight: number, gender: string, label: string? }
-- style: "default" | "casual" | "aesthetic" | "meme" | "sport"
export type ClothingEntry = { id: number, weight: number, style: string, label: string? }
export type FaceEntry = { id: number, weight: number, label: string? }
-- style is the hat's group (an NPC never wears two hats of one group); gender as for hair.
export type HatEntry = { id: number, weight: number, style: string, gender: string, label: string? }
-- colors: the six HumanoidDescription body-colour slots (BODY_COLOR_SLOTS); skinSlots: the slots the
-- generator recolours to the persona's skin tone (empty for fixed sets such as the "noob" colours).
export type BodyColorPreset = { weight: number, colors: { [string]: Color3 }, skinSlots: { string }, label: string? }
export type PrimitivePalette = { shirt: Color3, pants: Color3, hair: Color3? }

export type Catalog = {
	SKIN_TONES: { Color3 },
	SKIN_WEIGHTS: { number },
	HAIR: { HairEntry },
	SHIRTS: { ClothingEntry },
	PANTS: { ClothingEntry },
	FACES: { FaceEntry },
	HATS: { HatEntry },
	STYLES: { [string]: number },
	BODY_COLOR_PRESETS: { BodyColorPreset },
	PRIMITIVE_PALETTES: { PrimitivePalette },
}

-- The six HumanoidDescription body-colour properties, in a fixed order (never iterate the colour
-- table itself when the order matters).
AvatarCatalog.BODY_COLOR_SLOTS = {
	"HeadColor",
	"TorsoColor",
	"LeftArmColor",
	"RightArmColor",
	"LeftLegColor",
	"RightLegColor",
}

-- Clothing styles in a fixed order; STYLES holds the weights (sum 100).
AvatarCatalog.STYLE_ORDER = { "default", "casual", "aesthetic", "meme", "sport" }

-- Twelve tones, fair to deep. Weights sum to 100 and no single tone is above 20.
local SKIN_TONES: { Color3 } = {
	Color3.fromRGB(255, 224, 196),
	Color3.fromRGB(246, 210, 180),
	Color3.fromRGB(238, 195, 160),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(215, 165, 125),
	Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(180, 120, 85),
	Color3.fromRGB(160, 95, 53),
	Color3.fromRGB(135, 82, 55),
	Color3.fromRGB(124, 92, 70),
	Color3.fromRGB(105, 64, 40),
	Color3.fromRGB(86, 66, 54),
}
local SKIN_WEIGHTS: { number } = { 6, 9, 12, 14, 12, 10, 8, 7, 6, 6, 5, 5 }

local HAIR: { HairEntry } = {
	{ id = 0, weight = 12, gender = "any", label = "short messy" },
	{ id = 0, weight = 8, gender = "any", label = "side swept" },
	{ id = 0, weight = 6, gender = "any", label = "short curly" },
	{ id = 0, weight = 6, gender = "any", label = "wavy" },
	{ id = 0, weight = 4, gender = "any", label = "afro" },
	{ id = 0, weight = 4, gender = "any", label = "beanie hair" },
	{ id = 0, weight = 6, gender = "m", label = "buzz cut" },
	{ id = 0, weight = 5, gender = "m", label = "spiky" },
	{ id = 0, weight = 4, gender = "m", label = "slicked back" },
	{ id = 0, weight = 10, gender = "f", label = "long straight" },
	{ id = 0, weight = 8, gender = "f", label = "ponytail" },
	{ id = 0, weight = 6, gender = "f", label = "bob" },
	{ id = 0, weight = 5, gender = "f", label = "braids" },
	{ id = 0, weight = 4, gender = "f", label = "bun" },
}

local SHIRTS: { ClothingEntry } = {
	{ id = 0, weight = 10, style = "default", label = "plain blue tee" },
	{ id = 0, weight = 8, style = "default", label = "plain red tee" },
	{ id = 0, weight = 8, style = "default", label = "white tee" },
	{ id = 0, weight = 6, style = "default", label = "grey hoodie" },
	{ id = 0, weight = 8, style = "casual", label = "graphic tee" },
	{ id = 0, weight = 7, style = "casual", label = "flannel" },
	{ id = 0, weight = 6, style = "casual", label = "striped hoodie" },
	{ id = 0, weight = 5, style = "casual", label = "denim jacket" },
	{ id = 0, weight = 6, style = "aesthetic", label = "pastel cardigan" },
	{ id = 0, weight = 5, style = "aesthetic", label = "oversized sweater" },
	{ id = 0, weight = 4, style = "aesthetic", label = "crop top" },
	{ id = 0, weight = 6, style = "meme", label = "bacon shirt" },
	{ id = 0, weight = 4, style = "meme", label = "pixel abs" },
	{ id = 0, weight = 3, style = "meme", label = "costume top" },
	{ id = 0, weight = 5, style = "sport", label = "soccer jersey" },
	{ id = 0, weight = 4, style = "sport", label = "basketball jersey" },
}

local PANTS: { ClothingEntry } = {
	{ id = 0, weight = 10, style = "default", label = "blue jeans" },
	{ id = 0, weight = 8, style = "default", label = "black jeans" },
	{ id = 0, weight = 6, style = "default", label = "grey sweatpants" },
	{ id = 0, weight = 6, style = "default", label = "khaki shorts" },
	{ id = 0, weight = 8, style = "casual", label = "ripped jeans" },
	{ id = 0, weight = 6, style = "casual", label = "cargo pants" },
	{ id = 0, weight = 6, style = "casual", label = "denim shorts" },
	{ id = 0, weight = 5, style = "casual", label = "joggers" },
	{ id = 0, weight = 6, style = "aesthetic", label = "pastel skirt" },
	{ id = 0, weight = 5, style = "aesthetic", label = "pleated skirt" },
	{ id = 0, weight = 4, style = "aesthetic", label = "wide leg pants" },
	{ id = 0, weight = 5, style = "meme", label = "bacon pants" },
	{ id = 0, weight = 4, style = "meme", label = "pixel legs" },
	{ id = 0, weight = 3, style = "meme", label = "costume bottoms" },
	{ id = 0, weight = 5, style = "sport", label = "soccer shorts" },
	{ id = 0, weight = 4, style = "sport", label = "track pants" },
}

-- id 0 is the default smile.
local FACES: { FaceEntry } = {
	{ id = 0, weight = 30, label = "default smile" },
	{ id = 0, weight = 12, label = "chill" },
	{ id = 0, weight = 10, label = "awkward" },
	{ id = 0, weight = 8, label = "err" },
	{ id = 0, weight = 8, label = "silly" },
	{ id = 0, weight = 8, label = "stern" },
	{ id = 0, weight = 8, label = "sleepy" },
	{ id = 0, weight = 8, label = "friendly grin" },
	{ id = 0, weight = 8, label = "skeptic" },
}

local HATS: { HatEntry } = {
	{ id = 0, weight = 10, style = "casual", gender = "any", label = "beanie" },
	{ id = 0, weight = 10, style = "casual", gender = "any", label = "cap" },
	{ id = 0, weight = 6, style = "casual", gender = "m", label = "backwards cap" },
	{ id = 0, weight = 5, style = "casual", gender = "any", label = "hood" },
	{ id = 0, weight = 8, style = "default", gender = "any", label = "headphones" },
	{ id = 0, weight = 8, style = "default", gender = "any", label = "glasses" },
	{ id = 0, weight = 6, style = "aesthetic", gender = "any", label = "bucket hat" },
	{ id = 0, weight = 6, style = "aesthetic", gender = "f", label = "bow" },
	{ id = 0, weight = 5, style = "aesthetic", gender = "f", label = "flower crown" },
	{ id = 0, weight = 5, style = "aesthetic", gender = "f", label = "cat ears" },
	{ id = 0, weight = 6, style = "sport", gender = "any", label = "bandana" },
	{ id = 0, weight = 5, style = "sport", gender = "any", label = "headband" },
	{ id = 0, weight = 6, style = "meme", gender = "any", label = "traffic cone" },
	{ id = 0, weight = 5, style = "meme", gender = "any", label = "banana" },
	{ id = 0, weight = 4, style = "meme", gender = "m", label = "fedora" },
}

local STYLES: { [string]: number } = { default = 30, casual = 35, aesthetic = 15, meme = 12, sport = 8 }

local function slots(head: Color3, torso: Color3, arms: Color3, legs: Color3): { [string]: Color3 }
	return {
		HeadColor = head,
		TorsoColor = torso,
		LeftArmColor = arms,
		RightArmColor = arms,
		LeftLegColor = legs,
		RightLegColor = legs,
	}
end

local ALL_SLOTS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
local SKIN_ONLY = { "HeadColor", "LeftArmColor", "RightArmColor" }
local SKIN_AND_TORSO = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor" }
local SKIN_AND_LEGS = { "HeadColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }

local NOOB_YELLOW = Color3.fromRGB(245, 205, 48)
local NOOB_BLUE = Color3.fromRGB(13, 105, 172)
local NOOB_GREEN = Color3.fromRGB(75, 151, 75)
local MID_TONE = SKIN_TONES[6]
local BLACK = Color3.fromRGB(27, 42, 53)
local WHITE = Color3.fromRGB(248, 248, 248)
local DARK_GREY = Color3.fromRGB(99, 95, 98)
local PASTEL_PINK = Color3.fromRGB(255, 182, 193)
local PASTEL_BLUE = Color3.fromRGB(173, 216, 230)
local PASTEL_MINT = Color3.fromRGB(152, 251, 152)

-- Eight presets; weights sum to 100. The classic yellow/blue/green "noob" set is p 0.08; the rest
-- are skin-toned (recoloured to the persona's tone at the listed slots) or pastel.
local BODY_COLOR_PRESETS: { BodyColorPreset } = {
	{ weight = 8, colors = slots(NOOB_YELLOW, NOOB_BLUE, NOOB_YELLOW, NOOB_GREEN), skinSlots = {}, label = "noob" },
	{
		weight = 42,
		colors = slots(MID_TONE, MID_TONE, MID_TONE, MID_TONE),
		skinSlots = ALL_SLOTS,
		label = "plain skin",
	},
	{
		weight = 12,
		colors = slots(MID_TONE, MID_TONE, MID_TONE, BLACK),
		skinSlots = SKIN_AND_TORSO,
		label = "skin, dark legs",
	},
	{
		weight = 8,
		colors = slots(MID_TONE, WHITE, MID_TONE, MID_TONE),
		skinSlots = SKIN_AND_LEGS,
		label = "skin, white torso",
	},
	{
		weight = 10,
		colors = slots(MID_TONE, DARK_GREY, MID_TONE, DARK_GREY),
		skinSlots = SKIN_ONLY,
		label = "skin, grey body",
	},
	{
		weight = 8,
		colors = slots(PASTEL_PINK, PASTEL_PINK, PASTEL_PINK, PASTEL_PINK),
		skinSlots = {},
		label = "pastel pink",
	},
	{
		weight = 7,
		colors = slots(PASTEL_BLUE, PASTEL_BLUE, PASTEL_BLUE, PASTEL_BLUE),
		skinSlots = {},
		label = "pastel blue",
	},
	{
		weight = 5,
		colors = slots(PASTEL_MINT, PASTEL_MINT, PASTEL_MINT, PASTEL_MINT),
		skinSlots = {},
		label = "pastel mint",
	},
}

local function palette(shirt: { number }, pants: { number }, hair: { number }?): PrimitivePalette
	return {
		shirt = Color3.fromRGB(shirt[1], shirt[2], shirt[3]),
		pants = Color3.fromRGB(pants[1], pants[2], pants[3]),
		hair = if hair then Color3.fromRGB(hair[1], hair[2], hair[3]) else nil,
	}
end

-- Twenty-four shirt/pants/hair colour triples for the block placeholder rig (hair nil = none).
local PRIMITIVE_PALETTES: { PrimitivePalette } = {
	palette({ 13, 105, 172 }, { 27, 42, 53 }, { 60, 40, 30 }),
	palette({ 196, 40, 28 }, { 13, 105, 172 }, { 30, 30, 30 }),
	palette({ 248, 248, 248 }, { 27, 42, 53 }, { 220, 190, 120 }),
	palette({ 27, 42, 53 }, { 27, 42, 53 }, { 30, 30, 30 }),
	palette({ 99, 95, 98 }, { 40, 40, 60 }, { 90, 60, 40 }),
	palette({ 75, 151, 75 }, { 99, 95, 98 }, { 220, 190, 120 }),
	palette({ 255, 182, 193 }, { 248, 248, 248 }, { 255, 200, 220 }),
	palette({ 173, 216, 230 }, { 40, 40, 60 }, { 60, 40, 30 }),
	palette({ 152, 251, 152 }, { 27, 42, 53 }, { 30, 30, 30 }),
	palette({ 245, 205, 48 }, { 13, 105, 172 }, nil),
	palette({ 120, 60, 160 }, { 27, 42, 53 }, { 120, 60, 160 }),
	palette({ 255, 140, 0 }, { 40, 40, 60 }, { 90, 60, 40 }),
	palette({ 30, 30, 30 }, { 99, 95, 98 }, { 220, 190, 120 }),
	palette({ 200, 200, 200 }, { 30, 30, 30 }, { 60, 40, 30 }),
	palette({ 0, 128, 128 }, { 27, 42, 53 }, { 30, 30, 30 }),
	palette({ 220, 20, 60 }, { 248, 248, 248 }, { 90, 60, 40 }),
	palette({ 70, 130, 180 }, { 27, 42, 53 }, { 220, 190, 120 }),
	palette({ 255, 255, 255 }, { 13, 105, 172 }, { 30, 30, 30 }),
	palette({ 128, 0, 32 }, { 40, 40, 60 }, { 60, 40, 30 }),
	palette({ 46, 139, 87 }, { 99, 95, 98 }, nil),
	palette({ 255, 105, 180 }, { 27, 42, 53 }, { 255, 200, 220 }),
	palette({ 105, 105, 105 }, { 27, 42, 53 }, { 30, 30, 30 }),
	palette({ 210, 180, 140 }, { 40, 40, 60 }, { 90, 60, 40 }),
	palette({ 0, 0, 139 }, { 248, 248, 248 }, { 220, 190, 120 }),
}

local DEFAULT: Catalog = {
	SKIN_TONES = SKIN_TONES,
	SKIN_WEIGHTS = SKIN_WEIGHTS,
	HAIR = HAIR,
	SHIRTS = SHIRTS,
	PANTS = PANTS,
	FACES = FACES,
	HATS = HATS,
	STYLES = STYLES,
	BODY_COLOR_PRESETS = BODY_COLOR_PRESETS,
	PRIMITIVE_PALETTES = PRIMITIVE_PALETTES,
}

-- The shipped catalog as one value (what Avatars.sample uses when no catalog is passed).
AvatarCatalog.DEFAULT = DEFAULT
AvatarCatalog.SKIN_TONES = SKIN_TONES
AvatarCatalog.SKIN_WEIGHTS = SKIN_WEIGHTS
AvatarCatalog.HAIR = HAIR
AvatarCatalog.SHIRTS = SHIRTS
AvatarCatalog.PANTS = PANTS
AvatarCatalog.FACES = FACES
AvatarCatalog.HATS = HATS
AvatarCatalog.STYLES = STYLES
AvatarCatalog.BODY_COLOR_PRESETS = BODY_COLOR_PRESETS
AvatarCatalog.PRIMITIVE_PALETTES = PRIMITIVE_PALETTES

-- Which palette a spec wears when it is built as a block rig: derived from `catalogSeed`, no draw,
-- so Avatars (forcePrimitive) and PrimitiveRig (fallback after a failed build) agree.
function AvatarCatalog.paletteIndex(catalogSeed: number, count: number?): number
	local n = count or #PRIMITIVE_PALETTES
	return math.floor(math.abs(catalogSeed)) % n + 1
end

-- A catalog with no hair, clothing, faces or hats at all (tones, presets and palettes stay): the
-- output is then body colours and scales only, every id 0.
function AvatarCatalog.empty(): Catalog
	return {
		SKIN_TONES = SKIN_TONES,
		SKIN_WEIGHTS = SKIN_WEIGHTS,
		HAIR = {},
		SHIRTS = {},
		PANTS = {},
		FACES = {},
		HATS = {},
		STYLES = STYLES,
		BODY_COLOR_PRESETS = BODY_COLOR_PRESETS,
		PRIMITIVE_PALETTES = PRIMITIVE_PALETTES,
	}
end

-- A copy of the shipped catalog whose entries carry distinct fake ids (base + 1, base + 2, ...;
-- base defaults to 1000000). For tests and dry runs only: the ids are not assets.
function AvatarCatalog.withPlaceholderIds(base: number?): Catalog
	local nextId = base or 1000000
	local function number(): number
		nextId += 1
		return nextId
	end
	local hair: { HairEntry } = {}
	for i, entry in HAIR do
		hair[i] = { id = number(), weight = entry.weight, gender = entry.gender, label = entry.label }
	end
	local shirts: { ClothingEntry } = {}
	for i, entry in SHIRTS do
		shirts[i] = { id = number(), weight = entry.weight, style = entry.style, label = entry.label }
	end
	local pants: { ClothingEntry } = {}
	for i, entry in PANTS do
		pants[i] = { id = number(), weight = entry.weight, style = entry.style, label = entry.label }
	end
	local faces: { FaceEntry } = {}
	for i, entry in FACES do
		-- The first face stays the default (id 0) like the shipped list.
		faces[i] = { id = if i == 1 then 0 else number(), weight = entry.weight, label = entry.label }
	end
	local hats: { HatEntry } = {}
	for i, entry in HATS do
		hats[i] =
			{ id = number(), weight = entry.weight, style = entry.style, gender = entry.gender, label = entry.label }
	end
	return {
		SKIN_TONES = SKIN_TONES,
		SKIN_WEIGHTS = SKIN_WEIGHTS,
		HAIR = hair,
		SHIRTS = shirts,
		PANTS = pants,
		FACES = faces,
		HATS = hats,
		STYLES = STYLES,
		BODY_COLOR_PRESETS = BODY_COLOR_PRESETS,
		PRIMITIVE_PALETTES = PRIMITIVE_PALETTES,
	}
end

return AvatarCatalog

--!strict
-- One deterministic AvatarSpec per persona: a clothing style biased by who the person is, a skin
-- tone and a body-colour preset, hair, shirt, pants, face and hats drawn from the catalog, body
-- scales in the narrow ranges real avatars sit in, and the seed a rig can be rebuilt from. The
-- same rng and persona always give the same spec, so a departed persona rejoins looking the same.
--
-- It only describes a look. It never builds a HumanoidDescription or a Model (RobloxRig and
-- PrimitiveRig do), never fetches anything, and decides nothing about behaviour. With the shipped
-- catalog (every id 0) the spec is body colours and scales only, which the rig adapter turns into
-- a proper default R15 avatar; `primitive` is true only when the caller forces the block rig.
--
-- Draw order is pinned (style, skin tone, body-colour preset, hair, shirt, pants, face, hat count
-- and hats, scales, catalogSeed); anything added later draws after catalogSeed.
-- requires: AvatarCatalog, Rng, Types

local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)
local AvatarCatalog = require(script.Parent.AvatarCatalog)

type Rng = Rng.Rng
type AvatarSpec = Types.AvatarSpec
type Catalog = AvatarCatalog.Catalog

local Avatars = {}

-- The persona fields the generator reads (a Personality.Persona has them all).
export type PersonaLike = {
	trolliness: number,
	accountAgeDays: number,
	presentation: string, -- "m" | "f" | "any"
	rig: string, -- "R15" | "R6"
	animPack: string,
}

export type Options = {
	forcePrimitive: boolean?, -- true: the spec is for the block placeholder rig (palette colours added)
	rig: string?, -- "R15" | "R6"; overrides persona.rig
	catalog: Catalog?, -- defaults to AvatarCatalog.DEFAULT
}

export type Scale = {
	height: number,
	width: number,
	head: number,
	depth: number,
	proportion: number,
	bodyType: number,
}

local NO_HAIR_CHANCE = 0.15
local DEFAULT_FACE_CHANCE = 0.6
local HAT_COUNT_WEIGHTS = { 35, 45, 20 } -- 0, 1, 2 hats
local NEWCOMER_DAYS = 30
local VETERAN_DAYS = 800
local TROLL_THRESHOLD = 0.7

-- Style weights for one persona, indexed like AvatarCatalog.STYLE_ORDER: trolls lean to meme
-- clothing, newcomers to the defaults, long-time accounts to the aesthetic look.
function Avatars.styleWeights(persona: PersonaLike, catalog: Catalog?): { number }
	local styles = (catalog or AvatarCatalog.DEFAULT).STYLES
	local weights: { number } = {}
	for i, name in AvatarCatalog.STYLE_ORDER do
		local weight = styles[name] or 0
		if name == "meme" and persona.trolliness > TROLL_THRESHOLD then
			weight *= 3
		end
		if name == "default" and persona.accountAgeDays < NEWCOMER_DAYS then
			weight *= 3
		end
		if name == "aesthetic" and persona.accountAgeDays > VETERAN_DAYS then
			weight *= 2
		end
		weights[i] = weight
	end
	return weights
end

local function fitsPresentation(gender: string, presentation: string): boolean
	return gender == "any" or gender == presentation
end

local function pickHair(rng: Rng, hair: { AvatarCatalog.HairEntry }, presentation: string): number
	local candidates: { AvatarCatalog.HairEntry } = {}
	for _, entry in hair do
		if fitsPresentation(entry.gender, presentation) then
			table.insert(candidates, entry)
		end
	end
	if #candidates == 0 then
		return 0
	end
	local weights: { number } = {}
	for i, entry in candidates do
		weights[i] = entry.weight
	end
	return candidates[rng:weightedIndex(weights)].id
end

local function pickClothing(rng: Rng, list: { AvatarCatalog.ClothingEntry }, style: string): number
	local candidates: { AvatarCatalog.ClothingEntry } = {}
	for _, entry in list do
		if entry.style == style then
			table.insert(candidates, entry)
		end
	end
	if #candidates == 0 then
		candidates = list
	end
	if #candidates == 0 then
		return 0
	end
	local weights: { number } = {}
	for i, entry in candidates do
		weights[i] = entry.weight
	end
	return candidates[rng:weightedIndex(weights)].id
end

local function pickFace(rng: Rng, faces: { AvatarCatalog.FaceEntry }): number
	if #faces == 0 then
		return 0
	end
	local weights: { number } = {}
	for i, entry in faces do
		weights[i] = entry.weight
	end
	return faces[rng:weightedIndex(weights)].id
end

-- Up to `count` hats that fit the presentation, never two of one style group. Entries with id 0
-- are "no hat" placeholders and are skipped, so the shipped catalog yields no hats.
local function pickHats(rng: Rng, hats: { AvatarCatalog.HatEntry }, presentation: string, count: number): { number }
	local ids: { number } = {}
	local usedStyles: { [string]: boolean } = {}
	for _ = 1, count do
		local candidates: { AvatarCatalog.HatEntry } = {}
		for _, entry in hats do
			if entry.id ~= 0 and fitsPresentation(entry.gender, presentation) and not usedStyles[entry.style] then
				table.insert(candidates, entry)
			end
		end
		if #candidates == 0 then
			break
		end
		local weights: { number } = {}
		for i, entry in candidates do
			weights[i] = entry.weight
		end
		local chosen = candidates[rng:weightedIndex(weights)]
		table.insert(ids, chosen.id)
		usedStyles[chosen.style] = true
	end
	return ids
end

function Avatars.sample(rng: Rng, persona: PersonaLike, options: Options?): AvatarSpec
	local o: Options = options or {}
	local catalog: Catalog = o.catalog or AvatarCatalog.DEFAULT
	local rig = o.rig or persona.rig
	local presentation = persona.presentation

	local style = AvatarCatalog.STYLE_ORDER[rng:weightedIndex(Avatars.styleWeights(persona, catalog))]
	local skinToneIndex = rng:weightedIndex(catalog.SKIN_WEIGHTS)
	local skin = catalog.SKIN_TONES[skinToneIndex]

	local presetWeights: { number } = {}
	for i, preset in catalog.BODY_COLOR_PRESETS do
		presetWeights[i] = preset.weight
	end
	local preset = catalog.BODY_COLOR_PRESETS[rng:weightedIndex(presetWeights)]
	local bodyColors: { [string]: Color3 } = {}
	for _, slot in AvatarCatalog.BODY_COLOR_SLOTS do
		bodyColors[slot] = preset.colors[slot]
	end
	for _, slot in preset.skinSlots do
		bodyColors[slot] = skin
	end

	local hairId = if rng:chance(NO_HAIR_CHANCE) then 0 else pickHair(rng, catalog.HAIR, presentation)
	local shirtId = pickClothing(rng, catalog.SHIRTS, style)
	local pantsId = pickClothing(rng, catalog.PANTS, style)
	local faceId = if rng:chance(DEFAULT_FACE_CHANCE) then 0 else pickFace(rng, catalog.FACES)
	local hatCount = rng:weightedIndex(HAT_COUNT_WEIGHTS) - 1
	local hatIds = pickHats(rng, catalog.HATS, presentation, hatCount)

	-- Narrow ranges: real avatars are never at the slider ends. R6 has no scales.
	local scale: Scale = { height = 1, width = 1, head = 1, depth = 1, proportion = 0, bodyType = 0 }
	if rig == "R15" then
		scale.height = rng:range(0.9, 1.05)
		scale.width = rng:range(0.7, 1.0)
		scale.depth = rng:range(0.9, 1.0)
		scale.proportion = rng:range(0, 0.3)
		scale.bodyType = rng:range(0, 0.3)
	end

	local catalogSeed = rng:nextUInt()

	local primitive = o.forcePrimitive == true
	if primitive then
		local paletteEntry =
			catalog.PRIMITIVE_PALETTES[AvatarCatalog.paletteIndex(catalogSeed, #catalog.PRIMITIVE_PALETTES)]
		bodyColors.shirt = paletteEntry.shirt
		bodyColors.pants = paletteEntry.pants
		if paletteEntry.hair then
			bodyColors.hair = paletteEntry.hair
		end
		bodyColors.skin = skin
	end

	return {
		rig = rig,
		bodyColors = bodyColors,
		skinToneIndex = skinToneIndex,
		shirtId = shirtId,
		pantsId = pantsId,
		faceId = faceId,
		hairId = hairId,
		hatIds = hatIds,
		scale = scale,
		catalogSeed = catalogSeed,
		animPack = persona.animPack,
		primitive = primitive,
		presentation = presentation,
	}
end

-- The same look with every catalog id at 0: what the rig adapter retries with after a build
-- failed on a bad id set (a default avatar, never a block rig). Returns a fresh table.
function Avatars.withoutIds(spec: AvatarSpec): AvatarSpec
	local bodyColors: { [string]: Color3 } = {}
	for slot, color in spec.bodyColors do
		bodyColors[slot] = color
	end
	return {
		rig = spec.rig,
		bodyColors = bodyColors,
		skinToneIndex = spec.skinToneIndex,
		shirtId = 0,
		pantsId = 0,
		faceId = 0,
		hairId = 0,
		hatIds = {},
		scale = {
			height = spec.scale.height,
			width = spec.scale.width,
			head = spec.scale.head,
			depth = spec.scale.depth,
			proportion = spec.scale.proportion,
			bodyType = spec.scale.bodyType,
		},
		catalogSeed = spec.catalogSeed,
		animPack = spec.animPack,
		primitive = spec.primitive,
		presentation = spec.presentation,
	}
end

-- True when the spec carries no catalog asset at all (the default install's output).
function Avatars.isIdless(spec: AvatarSpec): boolean
	return (spec.shirtId or 0) == 0
		and (spec.pantsId or 0) == 0
		and (spec.faceId or 0) == 0
		and (spec.hairId or 0) == 0
		and #spec.hatIds == 0
end

return Avatars

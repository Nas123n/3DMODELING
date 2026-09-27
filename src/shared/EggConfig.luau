--!strict
-- Egg tiers and their variations. Every tier has exactly VARIATIONS_PER_TIER variations;
-- validate() enforces that when this module loads, so a bad edit fails loudly instead of
-- shipping a tier with a missing or extra egg.
--
-- Colors are hex strings (not Color3) so this module stays plain Luau and can be
-- required by tests outside Roblox. EggBuilder converts them with Color3.fromHex.

local EggConfig = {}

EggConfig.VARIATIONS_PER_TIER = 3

export type Pattern = "Stripes" | "Spots" | "Zigzag"

export type Variation = {
	id: string,
	name: string,
	pattern: Pattern,
	base: string, -- shell color
	accent: string, -- pattern color
}

export type Effects = {
	light: boolean, -- PointLight in the accent color
	neonAccent: boolean, -- pattern pieces glow
	sparkles: boolean, -- sparkle particles around the egg
	halo: boolean, -- ring of orbs floating above the egg
}

export type Tier = {
	id: string,
	name: string,
	order: number,
	color: string, -- stand trim and sign color
	effects: Effects,
	variations: { Variation },
}

EggConfig.Tiers = {
	{
		id = "Common",
		name = "Common",
		order = 1,
		color = "#8FD16A",
		effects = { light = false, neonAccent = false, sparkles = false, halo = false },
		variations = {
			{ id = "Meadow", name = "Meadow Egg", pattern = "Stripes", base = "#A6E27A", accent = "#F4FFE8" },
			{ id = "Pebble", name = "Pebble Egg", pattern = "Spots", base = "#DDD6C8", accent = "#8C8173" },
			{ id = "Acorn", name = "Acorn Egg", pattern = "Zigzag", base = "#D9A45E", accent = "#6E4220" },
		},
	},
	{
		id = "Uncommon",
		name = "Uncommon",
		order = 2,
		color = "#4FB9F0",
		effects = { light = false, neonAccent = false, sparkles = false, halo = false },
		variations = {
			{ id = "Tide", name = "Tide Egg", pattern = "Stripes", base = "#5CC8F0", accent = "#E6FAFF" },
			{ id = "Frost", name = "Frost Egg", pattern = "Spots", base = "#D6F1FF", accent = "#5FA9E0" },
			{ id = "Lagoon", name = "Lagoon Egg", pattern = "Zigzag", base = "#3BB7A8", accent = "#D2FFF5" },
		},
	},
	{
		id = "Rare",
		name = "Rare",
		order = 3,
		color = "#A070F0",
		effects = { light = true, neonAccent = false, sparkles = false, halo = false },
		variations = {
			{ id = "Blossom", name = "Blossom Egg", pattern = "Stripes", base = "#F59AC8", accent = "#FFF0F7" },
			{ id = "Amethyst", name = "Amethyst Egg", pattern = "Spots", base = "#9A6BE0", accent = "#E8DAFF" },
			{ id = "Dusk", name = "Dusk Egg", pattern = "Zigzag", base = "#5B4BB5", accent = "#F7B2E4" },
		},
	},
	{
		id = "Epic",
		name = "Epic",
		order = 4,
		color = "#FF7A3D",
		effects = { light = true, neonAccent = true, sparkles = true, halo = false },
		variations = {
			{ id = "Ember", name = "Ember Egg", pattern = "Stripes", base = "#FF7A3D", accent = "#FFE08A" },
			{ id = "Magma", name = "Magma Egg", pattern = "Spots", base = "#3A2A2A", accent = "#FF6A1F" },
			{ id = "Solar", name = "Solar Egg", pattern = "Zigzag", base = "#FFC53D", accent = "#FF5E3A" },
		},
	},
	{
		id = "Legendary",
		name = "Legendary",
		order = 5,
		color = "#FFD447",
		effects = { light = true, neonAccent = true, sparkles = true, halo = true },
		variations = {
			{ id = "Aurum", name = "Aurum Egg", pattern = "Stripes", base = "#FFD447", accent = "#FFF6C9" },
			{ id = "Void", name = "Void Egg", pattern = "Spots", base = "#1C1633", accent = "#B77CFF" },
			{ id = "Prism", name = "Prism Egg", pattern = "Zigzag", base = "#F4FBFF", accent = "#5CF2FF" },
		},
	},
} :: { Tier }

local PATTERNS: { [string]: boolean } = { Stripes = true, Spots = true, Zigzag = true }

local function isHex(value: unknown): boolean
	return type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil
end

-- Returns (true, nil) when the config is well formed, otherwise (false, reason).
function EggConfig.validate(tiers: { Tier }?): (boolean, string?)
	local list = tiers or EggConfig.Tiers
	local tierIds: { [string]: boolean } = {}
	for index, tier in list do
		if type(tier.id) ~= "string" or tier.id == "" then
			return false, `tier #{index} has no id`
		end
		if tierIds[tier.id] then
			return false, `duplicate tier id "{tier.id}"`
		end
		tierIds[tier.id] = true
		if not isHex(tier.color) then
			return false, `tier "{tier.id}" color must be a #RRGGBB hex string`
		end
		if #tier.variations ~= EggConfig.VARIATIONS_PER_TIER then
			return false,
				`tier "{tier.id}" has {#tier.variations} variations, expected exactly {EggConfig.VARIATIONS_PER_TIER}`
		end
		local variationIds: { [string]: boolean } = {}
		for _, variation in tier.variations do
			if type(variation.id) ~= "string" or variation.id == "" then
				return false, `tier "{tier.id}" has a variation without an id`
			end
			if variationIds[variation.id] then
				return false, `tier "{tier.id}" has duplicate variation id "{variation.id}"`
			end
			variationIds[variation.id] = true
			if not PATTERNS[variation.pattern] then
				return false, `variation "{tier.id}/{variation.id}" has unknown pattern "{tostring(variation.pattern)}"`
			end
			if not isHex(variation.base) or not isHex(variation.accent) then
				return false, `variation "{tier.id}/{variation.id}" colors must be #RRGGBB hex strings`
			end
		end
	end
	return true, nil
end

function EggConfig.getTier(tierId: string): Tier?
	for _, tier in EggConfig.Tiers do
		if tier.id == tierId then
			return tier
		end
	end
	return nil
end

function EggConfig.getVariation(tierId: string, variationId: string): Variation?
	local tier = EggConfig.getTier(tierId)
	if not tier then
		return nil
	end
	for _, variation in tier.variations do
		if variation.id == variationId then
			return variation
		end
	end
	return nil
end

-- Maps a roll in [0, 1) to one of the tier's variations with equal odds,
-- e.g. EggConfig.pickVariation("Rare", Random.new():NextNumber()).
function EggConfig.pickVariation(tierId: string, roll: number): Variation
	local tier = EggConfig.getTier(tierId)
	assert(tier, `unknown egg tier "{tierId}"`)
	local count = #tier.variations
	local index = math.clamp(math.floor(roll * count) + 1, 1, count)
	return tier.variations[index]
end

do
	local ok, reason = EggConfig.validate()
	assert(ok, `EggConfig is invalid: {reason}`)
end

return EggConfig

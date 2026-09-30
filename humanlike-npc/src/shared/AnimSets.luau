--!strict
-- Animation asset ids the client animator plays on characters that carry no Animate script: the pack weights,
-- one clip set per pack, the emote catalogue, and the pure helpers that pick among them. The `default` pack is
-- pinned to the R15 Animate script's own ids (verified from the engine source); the other packs ship with 0 ids,
-- which fall back to the default clip, and are meant to be filled by the developer with the ids of the packs the
-- place owns. It is not an animator (no Animation instances, no tracks) and it holds no per-character state.
-- requires: nothing

export type Pack = {
	idle1: number,
	idle2: number,
	idle3: number,
	idleWeights: { number }, -- three weights, in the order idle1, idle2, idle3
	walk: number,
	run: number,
	jump: number,
	fall: number,
	climb: number,
	sit: number,
}

export type EmoteClip = { id: number, weight: number }

export type Emote = {
	id: number, -- the (first) clip
	weightedIds: { EmoteClip }?, -- present for the multi-clip emotes
	duration: number, -- seconds; math.huge loops until moving
	loops: boolean,
}

local AnimSets = {}

AnimSets.DEFAULT = "default"

-- Relative weights for the pack a character uses (see packFor).
local PACKS: { [string]: number } = {
	rthro = 25,
	cartoony = 15,
	robot = 5,
	ninja = 8,
	knight = 5,
	zombie = 5,
	elder = 5,
	levitation = 3,
	stylish = 8,
	toy = 3,
	superhero = 3,
	default = 15,
}
AnimSets.PACKS = PACKS

-- Sorted pack names so every iteration over PACKS is deterministic.
local PACK_NAMES: { string } = {}
for name in PACKS do
	table.insert(PACK_NAMES, name)
end
table.sort(PACK_NAMES)
AnimSets.PACK_NAMES = PACK_NAMES

local function emptyPack(): Pack
	return {
		idle1 = 0,
		idle2 = 0,
		idle3 = 0,
		idleWeights = { 1, 1, 9 },
		walk = 0,
		run = 0,
		jump = 0,
		fall = 0,
		climb = 0,
		sit = 0,
	}
end

-- The R15 Animate script's default ids [animate-src].
local DEFAULT_PACK: Pack = {
	idle1 = 507766666,
	idle2 = 507766951,
	idle3 = 507766388,
	idleWeights = { 1, 1, 9 },
	walk = 507777826,
	run = 507767714,
	jump = 507765000,
	fall = 507767968,
	climb = 507765644,
	sit = 2506281703,
}

-- Developer-editable: an id of 0 means "use the default pack's clip".
local SETS: { [string]: Pack } = {
	default = DEFAULT_PACK,
	rthro = emptyPack(),
	cartoony = emptyPack(),
	robot = emptyPack(),
	ninja = emptyPack(),
	knight = emptyPack(),
	zombie = emptyPack(),
	elder = emptyPack(),
	levitation = emptyPack(),
	stylish = emptyPack(),
	toy = emptyPack(),
	superhero = emptyPack(),
}
AnimSets.SETS = SETS

-- The R6 Animate script's ids, from memory rather than the engine source ([unverified]; Studio checklist C-8).
-- Used only for characters whose Humanoid.RigType is R6; R15 clips do not map onto an R6 rig.
local R6: Pack = {
	idle1 = 180435571,
	idle2 = 180435792,
	idle3 = 180435571,
	idleWeights = { 9, 1, 0 },
	walk = 180426354,
	run = 180426354,
	jump = 125750702,
	fall = 180436148,
	climb = 180436334,
	sit = 178130996,
}
AnimSets.R6 = R6

local function clips(ids: { number }): { EmoteClip }
	local list: { EmoteClip } = {}
	for _, id in ids do
		table.insert(list, { id = id, weight = 1 })
	end
	return list
end

-- The seven default emotes [animate-src]. `loops` mirrors the Animate script's emoteNames table.
local EMOTES: { [string]: Emote } = {
	wave = { id = 507770239, duration = 3, loops = false },
	point = { id = 507770453, duration = 2, loops = false },
	dance = {
		id = 507771019,
		weightedIds = clips({ 507771019, 507771955, 507772104 }),
		duration = math.huge,
		loops = true,
	},
	dance2 = {
		id = 507776043,
		weightedIds = clips({ 507776043, 507776720, 507776879 }),
		duration = math.huge,
		loops = true,
	},
	dance3 = {
		id = 507777268,
		weightedIds = clips({ 507777268, 507777451, 507777623 }),
		duration = math.huge,
		loops = true,
	},
	laugh = { id = 507770818, duration = 3, loops = false },
	cheer = { id = 507770677, duration = 3, loops = false },
}
AnimSets.EMOTES = EMOTES

local EMOTE_NAMES: { string } = {}
for name in EMOTES do
	table.insert(EMOTE_NAMES, name)
end
table.sort(EMOTE_NAMES)
AnimSets.EMOTE_NAMES = EMOTE_NAMES

local function orDefault(id: number, fallback: number): number
	return if id > 0 then id else fallback
end

-- The clip set for a pack name with every 0 id replaced by the default pack's clip; unknown names give the default.
function AnimSets.resolve(packName: string?): Pack
	local chosen: Pack? = if packName then SETS[packName] else nil
	local pack: Pack = chosen or DEFAULT_PACK
	local d = DEFAULT_PACK
	local weights = pack.idleWeights
	if #weights ~= 3 or (weights[1] + weights[2] + weights[3]) <= 0 then
		weights = d.idleWeights
	end
	return {
		idle1 = orDefault(pack.idle1, d.idle1),
		idle2 = orDefault(pack.idle2, d.idle2),
		idle3 = orDefault(pack.idle3, d.idle3),
		idleWeights = { weights[1], weights[2], weights[3] },
		walk = orDefault(pack.walk, d.walk),
		run = orDefault(pack.run, d.run),
		jump = orDefault(pack.jump, d.jump),
		fall = orDefault(pack.fall, d.fall),
		climb = orDefault(pack.climb, d.climb),
		sit = orDefault(pack.sit, d.sit),
	}
end

-- The idle clip id for index 1..3 (no dynamic key indexing, so the shape stays checkable).
function AnimSets.idleId(pack: Pack, index: number): number
	if index == 1 then
		return pack.idle1
	elseif index == 2 then
		return pack.idle2
	end
	return pack.idle3
end

-- djb2 over the bytes, kept below 2^32 so the arithmetic is exact everywhere.
function AnimSets.hash(text: string): number
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 4294967296
	end
	return h
end

-- Deterministic weighted pack choice from a character's name: every client (and the server, if it wants to agree)
-- derives the same pack without any replicated marker. Weights come from PACKS over the sorted names.
function AnimSets.packFor(name: string): string
	local total = 0
	for _, packName in PACK_NAMES do
		total += PACKS[packName]
	end
	if total <= 0 then
		return AnimSets.DEFAULT
	end
	local u = (AnimSets.hash(name) % 1000003) / 1000003
	local target = u * total
	local acc = 0
	for _, packName in PACK_NAMES do
		acc += PACKS[packName]
		if target < acc then
			return packName
		end
	end
	return PACK_NAMES[#PACK_NAMES]
end

-- Picks one clip id of an emote by a uniform draw u ∈ [0, 1); single-clip emotes ignore u.
function AnimSets.emoteId(emote: Emote, u: number): number
	local list = emote.weightedIds
	if list == nil or #list == 0 then
		return emote.id
	end
	local total = 0
	for _, clip in list do
		total += clip.weight
	end
	if total <= 0 then
		return list[1].id
	end
	local target = math.clamp(u, 0, 0.999999) * total
	local acc = 0
	for _, clip in list do
		acc += clip.weight
		if target < acc then
			return clip.id
		end
	end
	return list[#list].id
end

return AnimSets

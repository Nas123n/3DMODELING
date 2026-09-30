--!strict
-- Usernames and display names that look like real Roblox accounts. A name is the first thing
-- a player reads, and "Bot_07" ends the illusion instantly, so the generator samples the same
-- family mix real servers show (word + digits, CamelCase compounds, lowercase aesthetic names,
-- prefixed identities, creator-style handles, leetspeak, the old xX_Xx style, auto-suggested
-- word-word-digits, number-heavy names and joke phrases), obeys Roblox's username rules
-- (3 to 20 characters, letters, digits, at most one underscore that is neither first nor last)
-- and refuses anything that reads as staff, bot, test or a well-known creator.
--
-- Names are never real people: the word lists are generic, and callers should still run the
-- optional online check (Players:GetUserIdFromNameAsync) in the Roblox adapter to drop any
-- collision with an existing account. A Pool hands out unique names per server.

local Rng = require(script.Parent.Rng)

type Rng = Rng.Rng

local Names = {}

export type Name = {
	username: string,
	displayName: string,
	family: string,
}

export type Family = {
	key: string,
	weight: number,
}

-- Share of each family among a typical server (see the research notes).
local FAMILIES: { Family } = {
	{ key = "wordDigits", weight = 30 },
	{ key = "camelCompound", weight = 15 },
	{ key = "lowercaseAesthetic", weight = 12 },
	{ key = "prefixed", weight = 10 },
	{ key = "creatorHandle", weight = 8 },
	{ key = "leet", weight = 8 },
	{ key = "xXxX", weight = 5 },
	{ key = "suggested", weight = 5 },
	{ key = "numeric", weight = 4 },
	{ key = "phrase", weight = 3 },
}
Names.FAMILIES = FAMILIES

local ADJECTIVES = {
	"cool",
	"epic",
	"shadow",
	"dark",
	"blue",
	"red",
	"pink",
	"golden",
	"silver",
	"happy",
	"quiet",
	"crazy",
	"tiny",
	"mega",
	"super",
	"ultra",
	"sneaky",
	"lucky",
	"frosty",
	"fire",
	"ice",
	"neon",
	"cosmic",
	"lunar",
	"solar",
	"toxic",
	"turbo",
	"hyper",
	"sleepy",
	"wild",
	"swift",
	"brave",
	"cute",
	"fluffy",
	"spooky",
	"glitchy",
	"pixel",
	"retro",
	"royal",
	"savage",
}

local NOUNS = {
	"gamer",
	"fox",
	"wolf",
	"panda",
	"cat",
	"kitty",
	"puppy",
	"dragon",
	"tiger",
	"bunny",
	"otter",
	"axolotl",
	"shark",
	"duck",
	"frog",
	"bear",
	"lion",
	"ninja",
	"knight",
	"king",
	"queen",
	"storm",
	"blade",
	"nova",
	"star",
	"moon",
	"sky",
	"cloud",
	"ghost",
	"phantom",
	"slayer",
	"hunter",
	"master",
	"lord",
	"boss",
	"pro",
	"noob",
	"bacon",
	"banana",
	"mango",
	"cookie",
	"donut",
	"pizza",
	"taco",
	"waffle",
	"blueberry",
	"cherry",
	"salad",
	"potato",
	"toast",
}

local FIRST_NAMES = {
	"milo",
	"zoe",
	"jaden",
	"ryan",
	"lily",
	"ava",
	"noah",
	"leo",
	"mia",
	"ethan",
	"emma",
	"liam",
	"aiden",
	"chloe",
	"lucas",
	"ella",
	"mason",
	"sofia",
	"jack",
	"nora",
	"kai",
	"ivy",
	"max",
	"ruby",
	"eli",
	"luna",
	"sam",
	"lexi",
	"theo",
	"maya",
	"jay",
	"skye",
	"evan",
	"zara",
	"owen",
	"nina",
	"tyler",
	"jade",
	"caleb",
	"hazel",
}

local MEME_WORDS = {
	"bruh",
	"skibidi",
	"sigma",
	"rizz",
	"sus",
	"goofy",
	"gyatt",
	"bacon",
	"noob",
	"chill",
	"vibes",
	"yeet",
	"bonk",
	"oof",
	"cap",
	"slay",
	"lowkey",
	"sheesh",
}

local PREFIXES = { "not", "its", "iam", "the", "real", "x", "mr", "lil", "im", "just", "only" }
local HANDLE_SUFFIXES = { "YT", "TTV", "_Official", "Gaming", "Plays", "Vlogs", "Live" }
local PHRASES = {
	"iforgotmypassword",
	"just_a_noob",
	"dontlookatme",
	"whyamihere",
	"idontknow",
	"stopreadingmyname",
	"imnotabot",
	"whereismypet",
	"nolookingplz",
	"okayandthen",
	"totallyreal",
	"averageplayer",
	"helpimstuck",
	"iamverycool",
	"youfoundme",
	"nothingtoseehere",
}

-- Substrings that expose scripted characters or impersonate staff and known creators.
-- Every banned entry is checked case-insensitively against the username with underscores
-- and digits removed, so "N_P_C_1" is rejected too.
Names.BANNED = {
	"npc",
	"bot",
	"dummy",
	"test",
	"guest",
	"admin",
	"moderator",
	"roblox",
	"staff",
	"builderman",
	"shedletsky",
	"telamon",
	"dantdm",
	"flamingo",
	"albertsstuff",
	"kreekcraft",
	"denis",
	"sketch",
	"itsfunneh",
	"leah",
	"ashley",
	"pghlego",
	"thinknoodles",
	"preston",
	"bandites",
	"ant",
	"tanqr",
	"ryguy",
	"chopper",
	"official",
	"developer",
	"owner",
	"system",
	"server",
	"helper",
}

-- "player" followed by digits is a classic placeholder; "player" inside another word is fine.
local PLAYER_PATTERN = "^[Pp]layer_?%d+$"

local LEET_MAP = { a = "4", e = "3", i = "1", o = "0", s = "5", t = "7" }

local function capitalize(word: string): string
	return string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
end

local function digits(rng: Rng): string
	local roll = rng:next()
	if roll < 0.45 then
		return tostring(rng:int(2009, 2016)) -- birth-year style
	elseif roll < 0.75 then
		return tostring(rng:int(1, 99))
	elseif roll < 0.9 then
		return tostring(rng:int(100, 999))
	end
	return tostring(rng:int(1000, 9999))
end

local function leet(word: string, rng: Rng): string
	local out = {}
	local swapped = 0
	for i = 1, #word do
		local c = string.sub(word, i, i)
		local sub = LEET_MAP[c]
		if sub and swapped < 2 and rng:chance(0.6) then
			table.insert(out, sub)
			swapped += 1
		else
			table.insert(out, c)
		end
	end
	return table.concat(out)
end

local function underscoreJoin(rng: Rng, a: string, b: string): string
	return if rng:chance(0.5) then a .. "_" .. b else a .. b
end

local GENERATORS: { [string]: (Rng) -> string } = {
	wordDigits = function(rng)
		local roll = rng:next()
		local base
		if roll < 0.4 then
			base = rng:pick(ADJECTIVES) .. rng:pick(NOUNS)
		elseif roll < 0.7 then
			base = rng:pick(FIRST_NAMES)
		else
			base = rng:pick(NOUNS) .. rng:pick({ "lover", "fan", "kid", "girl", "boy", "man", "gal", "guy" })
		end
		if rng:chance(0.3) then
			base = capitalize(base)
		end
		return underscoreJoin(rng, base, digits(rng))
	end,
	camelCompound = function(rng)
		local parts = { capitalize(rng:pick(ADJECTIVES)), capitalize(rng:pick(NOUNS)) }
		if rng:chance(0.35) then
			table.insert(parts, capitalize(rng:pick({ "King", "Queen", "Pro", "Boss", "Master", "Lord", "Star" })))
		end
		return table.concat(parts)
	end,
	lowercaseAesthetic = function(rng)
		local roll = rng:next()
		if roll < 0.4 then
			return rng:pick(NOUNS) .. rng:pick(NOUNS)
		elseif roll < 0.7 then
			return rng:pick(MEME_WORDS) .. rng:pick(NOUNS)
		end
		return rng:pick(ADJECTIVES) .. rng:pick(FIRST_NAMES)
	end,
	prefixed = function(rng)
		local core = if rng:chance(0.6) then rng:pick(FIRST_NAMES) else rng:pick(NOUNS)
		local name = rng:pick(PREFIXES) .. core
		if rng:chance(0.3) then
			name = name .. "_"
			name = string.sub(name, 1, #name - 1) .. digits(rng) -- never end with an underscore
		end
		if rng:chance(0.25) then
			name = capitalize(name)
		end
		return name
	end,
	creatorHandle = function(rng)
		local core = if rng:chance(0.5) then capitalize(rng:pick(FIRST_NAMES)) else capitalize(rng:pick(NOUNS))
		if rng:chance(0.5) then
			core = core .. capitalize(rng:pick({ "Gaming", "Plays", "Games" }))
			return core .. rng:pick({ "YT", "TTV", "" })
		end
		return core .. rng:pick(HANDLE_SUFFIXES)
	end,
	leet = function(rng)
		local base = rng:pick(ADJECTIVES) .. (if rng:chance(0.5) then "_" else "") .. rng:pick(NOUNS)
		return leet(base, rng)
	end,
	xXxX = function(rng)
		local core = capitalize(rng:pick(ADJECTIVES)) .. capitalize(rng:pick(NOUNS))
		return if rng:chance(0.7) then "xX" .. core .. "Xx" else core .. "_" .. rng:pick({ "pro", "epic", "gamer" })
	end,
	suggested = function(rng)
		-- Roblox's own suggestion when a name is taken: Word + Word + digits.
		return capitalize(rng:pick(ADJECTIVES)) .. capitalize(rng:pick(NOUNS)) .. tostring(rng:int(1000, 9999))
	end,
	numeric = function(rng)
		if rng:chance(0.5) then
			return tostring(rng:int(1000000, 9999999))
		end
		return tostring(rng:int(2009, 2016)) .. "_" .. capitalize(rng:pick(FIRST_NAMES))
	end,
	phrase = function(rng)
		return rng:pick(PHRASES)
	end,
}

-- Roblox username rules.
function Names.isValidUsername(name: string): boolean
	if #name < 3 or #name > 20 then
		return false
	end
	if not string.match(name, "^[%w_]+$") then
		return false
	end
	local _, underscores = string.gsub(name, "_", "")
	if underscores > 1 then
		return false
	end
	if string.sub(name, 1, 1) == "_" or string.sub(name, -1) == "_" then
		return false
	end
	return true
end

-- Display names: 3 to 20 characters, letters, digits and single spaces, no leading or trailing space.
function Names.isValidDisplayName(name: string): boolean
	if #name < 3 or #name > 20 then
		return false
	end
	if not string.match(name, "^[%w ]+$") then
		return false
	end
	if string.sub(name, 1, 1) == " " or string.sub(name, -1) == " " or string.find(name, "  ", 1, true) then
		return false
	end
	return true
end

function Names.isBanned(name: string): boolean
	if string.match(name, PLAYER_PATTERN) then
		return true
	end
	local stripped = string.gsub(name, "[_%d]", "")
	local flat = string.lower(stripped)
	for _, banned in Names.BANNED do
		if string.find(flat, banned, 1, true) then
			return true
		end
	end
	return false
end

local function pickFamily(rng: Rng): string
	local weights = {}
	for i, family in FAMILIES do
		weights[i] = family.weight
	end
	return FAMILIES[rng:weightedIndex(weights)].key
end

-- The name above the head. About a fifth of players leave it equal to the username; the rest
-- use a first name, a pet word, a shorter form or a spaced version of the username.
local function displayNameFor(rng: Rng, username: string): string
	local roll = rng:next()
	if roll < 0.2 then
		return username
	elseif roll < 0.45 then
		local first = rng:pick(FIRST_NAMES)
		return if rng:chance(0.6) then capitalize(first) else first
	elseif roll < 0.6 then
		local word = rng:pick(NOUNS)
		return if rng:chance(0.5) then capitalize(word) else word
	elseif roll < 0.75 then
		-- Strip digits, underscores and creator suffixes, keep what a friend would call them.
		local core = string.gsub(username, "[%d_]", "")
		core = string.gsub(core, "^[xX][xX]", "")
		core = string.gsub(core, "[xX][xX]$", "")
		core = string.gsub(core, "YT$", "")
		core = string.gsub(core, "TTV$", "")
		if #core >= 3 then
			return string.sub(core, 1, 20)
		end
		return capitalize(rng:pick(FIRST_NAMES))
	elseif roll < 0.9 then
		return capitalize(rng:pick(ADJECTIVES)) .. " " .. capitalize(rng:pick(NOUNS))
	end
	return rng:pick(MEME_WORDS) .. " " .. rng:pick(NOUNS)
end

-- One plausible name. Retries until the username passes the rules and the ban list.
function Names.generate(rng: Rng, family: string?): Name
	for _ = 1, 50 do
		local key = family or pickFamily(rng)
		local generator = GENERATORS[key]
		assert(generator, `unknown name family {key}`)
		local username = generator(rng)
		if Names.isValidUsername(username) and not Names.isBanned(username) then
			local displayName = displayNameFor(rng, username)
			if not Names.isValidDisplayName(displayName) then
				displayName = capitalize(rng:pick(FIRST_NAMES))
			end
			return { username = username, displayName = displayName, family = key }
		end
	end
	-- Statistically unreachable; keep the caller safe anyway.
	local fallback = capitalize(rng:pick(ADJECTIVES)) .. capitalize(rng:pick(NOUNS)) .. tostring(rng:int(1000, 9999))
	return { username = fallback, displayName = capitalize(rng:pick(FIRST_NAMES)), family = "suggested" }
end

-- Unique names for one server. Comparison is case-insensitive like Roblox's.
local Pool = {}
Pool.__index = Pool

export type Pool = typeof(setmetatable(
	{} :: { rng: Rng, taken: { [string]: boolean }, reserved: { [string]: boolean } },
	Pool
))

function Names.newPool(rng: Rng, reserved: { string }?): Pool
	local taken = {}
	local initial: { string } = reserved or {}
	for _, name in initial do
		taken[string.lower(name)] = true
	end
	return setmetatable({ rng = rng, taken = taken, reserved = {} }, Pool)
end

-- Marks a name as in use (a real player's username, so no NPC ever shares it).
function Pool.reserve(self: Pool, name: string)
	self.taken[string.lower(name)] = true
end

function Pool.release(self: Pool, name: string)
	self.taken[string.lower(name)] = nil
end

function Pool.take(self: Pool, family: string?): Name
	for _ = 1, 200 do
		local name = Names.generate(self.rng, family)
		local key = string.lower(name.username)
		if not self.taken[key] then
			self.taken[key] = true
			return name
		end
	end
	error("Names.Pool: could not find a free name after 200 attempts")
end

return Names

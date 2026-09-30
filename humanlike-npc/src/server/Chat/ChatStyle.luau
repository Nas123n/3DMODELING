--!strict
-- Turns a corpus line into what a particular person would actually type. Real messages carry
-- the fingerprints of their author and their device: adjacent-key typos, dropped letters,
-- stretched vowels ("hiiii"), a phone's auto-capitalised first letter, the new chat's habit of
-- cutting the last letters off a fast message, and the occasional line the filter turned into
-- "###". Every function is pure and seeded, so the same persona always types the same way.
--
-- The typing-time model (notice + open the box + characters / speed + hesitation) is here too,
-- because a reply that arrives faster than it could have been typed is the loudest chat tell.

local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng

local ChatStyle = {}

-- "pc" | "pcShiftLock" | "mobile" | "console"
export type InputProfile = string

export type Voice = {
	profile: InputProfile,
	typoRate: number, -- typos per character, 0.02 to 0.07 for kids
	stretchChance: number, -- chance a message gets a stretched letter, about 0.12
	capsChance: number, -- chance of an ALL CAPS message, about 0.05
	truncateChance: number, -- chance the tail is cut, about 0.04
	charsPerSecond: number, -- 0.7 (young, thumbs) to 4 (teen keyboard)
	hesitation: number, -- chance of a pause and backspace while typing, about 0.3
	tagChance: number, -- chance an eligible line shows as ###, 0.03 to 0.06
}

-- QWERTY neighbours for adjacent-key substitutions.
local NEIGHBOURS: { [string]: string } = {
	q = "wa",
	w = "qes",
	e = "wrd",
	r = "etf",
	t = "ryg",
	y = "tuh",
	u = "yij",
	i = "uok",
	o = "ipl",
	p = "ol",
	a = "qsz",
	s = "awdz",
	d = "sefx",
	f = "drgc",
	g = "fthv",
	h = "gyjb",
	j = "hukn",
	k = "jilm",
	l = "kop",
	z = "asx",
	x = "zsdc",
	c = "xdfv",
	v = "cfgb",
	b = "vghn",
	n = "bhjm",
	m = "njk",
}

local VOWELS = { a = true, e = true, i = true, o = true, u = true, y = true }

-- Words whose first letter a phone keyboard would capitalise (and i -> I).
local function mobileCapitalize(text: string): string
	local first = string.sub(text, 1, 1)
	if string.match(first, "%l") then
		text = string.upper(first) .. string.sub(text, 2)
	end
	-- iOS-style: a lone "i" becomes "I".
	text = string.gsub(text, "(%s)i(%s)", "%1I%2")
	text = string.gsub(text, "(%s)i$", "%1I")
	return text
end

-- One typo somewhere in the word: an adjacent key, a dropped letter or a swapped pair.
local function typoWord(word: string, rng: Rng): string
	if #word < 3 then
		return word
	end
	local roll = rng:next()
	local i = rng:int(2, #word) -- first letters survive typing better
	if roll < 0.5 then
		local c = string.sub(word, i, i)
		local options = NEIGHBOURS[string.lower(c)]
		if options then
			local at = rng:int(1, #options)
			local replacement = string.sub(options, at, at)
			return string.sub(word, 1, i - 1) .. replacement .. string.sub(word, i + 1)
		end
		return word
	elseif roll < 0.8 then
		return string.sub(word, 1, i - 1) .. string.sub(word, i + 1) -- dropped letter
	end
	if i < #word then
		return string.sub(word, 1, i - 1)
			.. string.sub(word, i + 1, i + 1)
			.. string.sub(word, i, i)
			.. string.sub(word, i + 2)
	end
	return word
end

-- Applies typos across a message at `rate` per character (at most 2 per message: humans notice).
function ChatStyle.typos(text: string, rng: Rng, rate: number): string
	if rate <= 0 then
		return text
	end
	local words = string.split(text, " ")
	local applied = 0
	for i, word in words do
		if applied >= 2 then
			break
		end
		if string.match(word, "^%a+$") and rng:chance(rate * #word) then
			words[i] = typoWord(word, rng)
			applied += 1
		end
	end
	return table.concat(words, " ")
end

-- Stretches a vowel or the last letter: "hi" -> "hiii", "no" -> "nooo", "lol" -> "lolll".
function ChatStyle.stretch(text: string, rng: Rng): string
	local words = string.split(text, " ")
	-- Prefer the last word; that is where the enthusiasm goes.
	local index = if rng:chance(0.7) then #words else rng:int(1, #words)
	local word = words[index]
	if not string.match(word, "^%a+$") then
		return text
	end
	local lastVowel = nil
	for i = #word, 1, -1 do
		if VOWELS[string.lower(string.sub(word, i, i))] then
			lastVowel = i
			break
		end
	end
	local at = if lastVowel and rng:chance(0.7) then lastVowel else #word
	local extra = rng:int(1, 4)
	local c = string.sub(word, at, at)
	words[index] = string.sub(word, 1, at) .. string.rep(c, extra) .. string.sub(word, at + 1)
	return table.concat(words, " ")
end

-- The new chat cuts trailing characters when the sender hits enter while still typing.
function ChatStyle.truncate(text: string, rng: Rng): string
	if #text < 6 then
		return text
	end
	local cut = rng:int(1, math.min(5, #text - 4))
	return string.sub(text, 1, #text - cut)
end

-- What a filtered message looks like: every non-space character becomes '#'.
function ChatStyle.tagged(text: string): string
	return (string.gsub(text, "%S", "#"))
end

-- Lines the filter plausibly catches: digits, or a word longer than 8 letters (names, places).
function ChatStyle.isTagEligible(text: string): boolean
	if string.find(text, "%d") then
		return true
	end
	for word in string.gmatch(text, "%a+") do
		if #word >= 9 then
			return true
		end
	end
	return false
end

-- Full pipeline for one message. `slots` fills {name}-style placeholders first.
function ChatStyle.render(text: string, voice: Voice, rng: Rng, slots: { [string]: string }?): string
	local out = text
	if slots then
		for key, value in slots do
			out = string.gsub(out, "{" .. key .. "}", value)
		end
	end
	-- Anything left in braces has no value: drop the message's slot rather than showing braces.
	out = string.gsub(out, "%s*{%w+}%s*", " ")
	out = string.gsub(out, "^%s+", "")
	out = string.gsub(out, "%s+$", "")
	out = string.gsub(out, "%s%s+", " ")
	if #out == 0 then
		return out
	end

	if rng:chance(voice.tagChance) and ChatStyle.isTagEligible(out) then
		return ChatStyle.tagged(out)
	end
	out = ChatStyle.typos(out, rng, voice.typoRate)
	if rng:chance(voice.stretchChance) then
		out = ChatStyle.stretch(out, rng)
	end
	if rng:chance(voice.capsChance) then
		out = string.upper(out)
	elseif voice.profile == "mobile" and rng:chance(0.55) then
		out = mobileCapitalize(out)
	end
	if rng:chance(voice.truncateChance) then
		out = ChatStyle.truncate(out, rng)
	end
	return string.sub(out, 1, 200)
end

-- Seconds from deciding to say something until the message appears: notice the situation,
-- open the chat box, type it, maybe hesitate. `addressed` is true when replying to something
-- just said (people are quicker to open the box for that).
function ChatStyle.typingSeconds(text: string, voice: Voice, rng: Rng, addressed: boolean?): number
	local notice = if addressed then rng:logNormal(1.5, 0.6) else rng:logNormal(0.8, 0.5)
	local open = rng:range(0.3, 0.8)
	local typing = #text / math.max(0.3, voice.charsPerSecond) * rng:range(0.85, 1.25)
	local hesitation = if rng:chance(voice.hesitation) then rng:range(0.5, 3) else 0
	local total = notice + open + typing + hesitation
	-- Below 1.5 s is impossible for anything longer than one character.
	if #text > 1 then
		total = math.max(1.5, total)
	end
	return total
end

-- A Voice sampled for a persona from three knobs: age-like skill (0 young .. 1 teen), the input
-- profile, and a sloppiness factor (0 tidy .. 1 chaotic).
function ChatStyle.voice(rng: Rng, profile: InputProfile, skill: number, sloppiness: number): Voice
	local keyboard = profile == "pc" or profile == "pcShiftLock"
	local cps = if keyboard then 1.2 + 2.8 * skill else 0.7 + 1.8 * skill
	return {
		profile = profile,
		typoRate = 0.015 + 0.05 * sloppiness * (1 - 0.5 * skill),
		stretchChance = 0.06 + 0.14 * sloppiness,
		capsChance = 0.02 + 0.06 * sloppiness,
		truncateChance = if keyboard then 0.02 + 0.05 * sloppiness else 0.01,
		charsPerSecond = cps * rng:range(0.85, 1.15),
		hesitation = 0.2 + 0.3 * (1 - skill),
		tagChance = 0.03 + 0.03 * sloppiness,
	}
end

return ChatStyle

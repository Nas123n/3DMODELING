--!strict
-- Picks what an NPC says and renders it in that NPC's voice. Spontaneous lines come from
-- category weights shaped by mood, session phase and persona; replies come from the category
-- the reply model chose. Every candidate is weighted down if it was heard recently anywhere on
-- the server and out entirely if this NPC said it in the last hour; the result passes the
-- safety gate. Echoes copy a nearby message with a mutation and never verbatim. Tags narrow the
-- candidates: a dialect-tagged line is only for that dialect, rude / poi / needsName / right /
-- help.right lines need the matching context, and the help sub-tags share 60 / 25 / 15. This is
-- not the reply decision (Reply), the rate limit (ChatGuard) or the corpus itself (ChatCorpus).
-- requires: ChatCorpus, ChatStyle, Recency, Rng, Safety

local ChatCorpus = require(script.Parent.ChatCorpus)
local ChatStyle = require(script.Parent.ChatStyle)
local Recency = require(script.Parent.Recency)
local Safety = require(script.Parent.Safety)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng
type Line = ChatCorpus.Line
type Voice = ChatStyle.Voice

local Composer = {}

export type Context = {
	npcId: string,
	voice: Voice,
	rng: Rng,
	now: number,
	category: string?, -- forced category (replies); nil = spontaneous
	mood: string?, -- "bored" | "social" | "playful" | "annoyed" | ...
	phase: string?, -- "joining" | "orienting" | "settled" | "leaving"
	accountAge: number?,
	trolliness: number?,
	nearbyName: string?, -- a display name for {name} slots
	echoSource: string?, -- a heard message for {echo}
	allowRude: boolean?,
	poiWord: string?, -- fills {poi}; poi-tagged lines (and any line with the slot) need it
	allowRight: boolean?, -- right-tagged lines need it (the caller allows one per NPC per 10 min)
	dialect: string?, -- "kid" | "teen" | "older": a line tagged with a dialect is only for that dialect
	knowsPoi: boolean?, -- help.right lines need it (familiarity > 0.5 and the POI kind was visited)
}

export type Composed = {
	text: string,
	lineId: string,
	category: string,
	tagged: boolean, -- rendered as a tag-only message ("# #")
	rude: boolean, -- the chosen line carries the rude tag
	right: boolean, -- the chosen line carries the right tag (the caller starts its 10 min timer)
}

-- Base shares of spontaneous categories, in a fixed order so draws are reproducible.
local SPONTANEOUS: { { category: string, weight: number } } = {
	{ category = "greeting", weight = 10 },
	{ category = "question", weight = 12 },
	{ category = "social", weight = 12 },
	{ category = "reaction", weight = 10 },
	{ category = "complaint", weight = 5 },
	{ category = "nonsense", weight = 5 },
	{ category = "bored", weight = 6 },
	{ category = "compliment", weight = 3 },
	{ category = "game", weight = 14 },
}

-- The same shares by category name, for readers; the ordered list above drives the draw.
local spontaneousByName: { [string]: number } = {}
for _, entry in SPONTANEOUS do
	spontaneousByName[entry.category] = entry.weight
end
Composer.SPONTANEOUS = spontaneousByName

local DIALECTS = { "kid", "teen", "older" }

-- Shares of the help sub-tags (a real player who does not know the place answers vaguely or
-- wrongly far more often than correctly); an untagged help line counts as vague.
local HELP_SHARES: { [string]: number } = { vague = 60, wrong = 25, right = 15 }

local function categoryWeights(ctx: Context): ({ string }, { number })
	local names, weights = {}, {}
	local age = ctx.accountAge or 0.3
	for _, entry in SPONTANEOUS do
		local w = entry.weight
		local c = entry.category
		if c == "greeting" then
			w *= if ctx.phase == "joining" or ctx.phase == "orienting"
				then 2
				elseif ctx.phase == "settled" then 0.3
				else 1
		elseif c == "question" then
			w *= 2 - age
		elseif c == "reaction" then
			w *= if ctx.mood == "playful" then 2 elseif ctx.mood == "social" then 1.5 else 1
		elseif c == "complaint" then
			w *= (1 + (ctx.trolliness or 0)) * (if ctx.mood == "annoyed" then 2 else 1)
		elseif c == "nonsense" then
			w *= if ctx.mood == "bored" then 3 else 1
		elseif c == "bored" then
			w *= if ctx.mood == "bored" then 2.5 else 0.5
		elseif c == "game" then
			if #ChatCorpus.byCategory("game") == 0 then
				w = 0
			end
		elseif c == "social" then
			w *= if ctx.mood == "social" then 1.8 else 1
		end
		if w > 0 then
			table.insert(names, c)
			table.insert(weights, w)
		end
	end
	return names, weights
end

local function lineId(line: Line): string
	return line.category .. ":" .. line.text
end

local function hasDialectTag(line: Line): boolean
	for _, dialect in DIALECTS do
		if ChatCorpus.hasTag(line, dialect) then
			return true
		end
	end
	return false
end

-- "right" | "wrong" | "vague" (the default for a line without a help sub-tag).
local function helpGroup(line: Line): string
	if ChatCorpus.hasTag(line, "help.right") then
		return "right"
	elseif ChatCorpus.hasTag(line, "help.wrong") then
		return "wrong"
	end
	return "vague"
end

-- Whether a line may be said in this context; every rule is a no-op for a line without the tag.
local function fits(line: Line, ctx: Context): boolean
	if ChatCorpus.hasTag(line, "needsName") and not ctx.nearbyName then
		return false
	end
	if ChatCorpus.hasTag(line, "rude") and not ctx.allowRude then
		return false
	end
	if string.find(line.text, "{echo}", 1, true) and not ctx.echoSource then
		return false
	end
	if (ChatCorpus.hasTag(line, "poi") or string.find(line.text, "{poi}", 1, true)) and not ctx.poiWord then
		return false
	end
	if ChatCorpus.hasTag(line, "right") and not ctx.allowRight then
		return false
	end
	if ChatCorpus.hasTag(line, "help.right") and not ctx.knowsPoi then
		return false
	end
	if ctx.dialect and hasDialectTag(line) and not ChatCorpus.hasTag(line, ctx.dialect :: string) then
		return false
	end
	return true
end

-- Scales candidate weights so the help sub-tag groups present share 60 / 25 / 15 whatever their
-- line counts. Untouched when no candidate carries a wrong or right sub-tag.
local function applyHelpShares(candidates: { Line }, weights: { number })
	local counts: { [string]: number } = { vague = 0, wrong = 0, right = 0 }
	local groups: { string } = {}
	for i, line in candidates do
		local group = helpGroup(line)
		groups[i] = group
		counts[group] += 1
	end
	if counts.wrong == 0 and counts.right == 0 then
		return
	end
	for i, group in groups do
		weights[i] *= HELP_SHARES[group] / counts[group]
	end
end

-- Mutates a copied message the way kids copy each other: an extra letter, a neighbour key, a
-- dropped last letter.
function Composer.mutateEcho(text: string, rng: Rng): string
	local roll = rng:next()
	if #text == 0 then
		return text
	end
	if roll < 0.5 then
		local last = string.sub(text, -1)
		if string.match(last, "%a") then
			return text .. string.rep(last, rng:int(1, 3))
		end
		return text .. "!"
	elseif roll < 0.8 then
		return ChatStyle.typos(text, rng, 0.5)
	end
	if #text > 3 then
		return string.sub(text, 1, #text - 1)
	end
	return text
end

-- Chooses and renders a line, or returns nil when nothing fits (a silent NPC is normal).
function Composer.compose(ctx: Context, recency: Recency.Tracker, safety: Safety.Gate): Composed?
	local rng = ctx.rng
	local category = ctx.category
	if not category then
		local names, weights = categoryWeights(ctx)
		if #names == 0 then
			return nil
		end
		category = names[rng:weightedIndex(weights)]
	end
	local pool = ChatCorpus.byCategory(category :: string)
	if #pool == 0 then
		return nil
	end
	local candidates: { Line } = {}
	local weights: { number } = {}
	local mobileVoice = ctx.voice.profile == "mobile"
	for _, line in pool do
		if not fits(line, ctx) then
			continue
		end
		local w = recency:weight(lineId(line), ctx.npcId, ctx.now)
		if w > 0 then
			if mobileVoice and ChatCorpus.hasTag(line, "mobile") then
				w *= 2
			end
			table.insert(candidates, line)
			table.insert(weights, w)
		end
	end
	if #candidates == 0 then
		return nil
	end
	applyHelpShares(candidates, weights)
	local line = candidates[rng:weightedIndex(weights)]
	local slots: { [string]: string } = {}
	if ctx.nearbyName then
		slots.name = ctx.nearbyName
	end
	if ctx.echoSource then
		slots.echo = Composer.mutateEcho(ctx.echoSource, rng)
	end
	if ctx.poiWord then
		slots.poi = ctx.poiWord
	end
	local text = ChatStyle.render(line.text, ctx.voice, rng, slots)
	if #text == 0 or not safety:check(text) then
		return nil
	end
	local id = lineId(line)
	recency:record(id, ctx.npcId, ctx.now)
	local tagged = string.match(text, "^[# ]+$") ~= nil
	return {
		text = text,
		lineId = id,
		category = category :: string,
		tagged = tagged,
		rude = ChatCorpus.hasTag(line, "rude"),
		right = ChatCorpus.hasTag(line, "right"),
	}
end

return Composer

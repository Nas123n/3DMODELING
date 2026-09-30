--!strict
-- Whether and how an NPC answers something it heard. Most messages get no reply from anyone;
-- a greeting from a stranger is answered by roughly one player in six, a message with your
-- name in it by a third, a question by those who feel helpful, an offer by many (with
-- suspicion, never acceptance), and "are you a bot" by most, once. A reply arrives no sooner
-- than it could have been noticed, the chat box opened, and the words typed.

local ChatStyle = require(script.Parent.ChatStyle)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng
type Voice = ChatStyle.Voice

local Reply = {}

-- "stopKeyword" | "botProbe" | "named" | "question" | "offer" | "greeting" | "compliment" | "broadcast"
export type Kind = string

Reply.STOP_KEYWORDS = {
	"stop",
	"leave me alone",
	"go away",
	"stop following",
	"get away",
	"stop copying",
	"stop it",
	"back off",
	"leave me",
}

Reply.BOT_PROBES = {
	"bot",
	"r u real",
	"are u real",
	"are you real",
	"npc",
	"is he real",
	"u real",
	"ur a bot",
	"are u a bot",
	"beep boop",
}

local QUESTION_STARTS =
	{ "how", "where", "what", "can", "does", "is", "anyone", "any1", "who", "why", "wheres", "whats" }
local OFFERS = { "free", "giveaway", "u want", "want a", "ill give", "i can give", "i'll give" }
local GREETINGS = {
	hi = true,
	hii = true,
	hiii = true,
	hello = true,
	hey = true,
	heyy = true,
	yo = true,
	sup = true,
	hru = true,
	wsp = true,
	wsg = true,
}
local COMPLIMENTS = { "nice", "cool", "cute", "love ur", "love your", "good avatar", "ur pro", "so good" }

-- Lowercase, punctuation stripped, single spaces.
function Reply.normalize(text: string): string
	local lower = string.lower(text)
	lower = string.gsub(lower, "[^%w%s']", " ")
	lower = string.gsub(lower, "%s+", " ")
	lower = string.gsub(lower, "^%s", "")
	lower = string.gsub(lower, "%s$", "")
	return lower
end

local function containsAny(text: string, needles: { string }): boolean
	for _, needle in needles do
		if string.find(text, needle, 1, true) then
			return true
		end
	end
	return false
end

-- Does the text address me: my display name (3+ chars) or the start of my username (4+ chars).
function Reply.isNamed(normalized: string, displayName: string, username: string): boolean
	local padded = " " .. normalized .. " "
	local display = string.lower(displayName)
	if #display >= 3 and string.find(padded, " " .. display .. " ", 1, true) then
		return true
	end
	local head = string.lower(string.sub(username, 1, math.max(4, math.min(#username, 6))))
	if #head >= 4 and string.find(padded, " " .. head, 1, true) then
		return true
	end
	return false
end

export type Classified = {
	kind: Kind,
	named: boolean,
	raw: string,
	normalized: string,
}

-- `distance` is studs from the speaker; nil when unknown (chat window).
function Reply.classify(text: string, displayName: string, username: string, distance: number?): Classified
	local n = Reply.normalize(text)
	local named = Reply.isNamed(n, displayName, username)
	local near = distance == nil or distance <= 15
	local kind: Kind = "broadcast"
	if containsAny(n, Reply.STOP_KEYWORDS) and (named or (distance ~= nil and distance <= 12)) then
		kind = "stopKeyword"
	elseif containsAny(n, Reply.BOT_PROBES) and (named or near) then
		kind = "botProbe"
	elseif named then
		kind = "named"
	elseif string.sub(text, -1) == "?" or containsAny(" " .. n, QUESTION_STARTS_PREFIXED()) then
		kind = "question"
	elseif containsAny(n, OFFERS) then
		kind = "offer"
	elseif GREETINGS[n] or string.sub(n, 1, 3) == "hi " then
		kind = "greeting"
	elseif containsAny(n, COMPLIMENTS) then
		kind = "compliment"
	end
	return { kind = kind, named = named, raw = text, normalized = n }
end

function QUESTION_STARTS_PREFIXED(): { string }
	local out = {}
	for i, w in QUESTION_STARTS do
		out[i] = " " .. w .. " "
	end
	return out
end

export type ReplyTraits = {
	chattiness: number,
	helpfulness: number,
	dialect: string,
	annoyance: number?, -- 0..1 toward this speaker
	moodChat: number?, -- mood multiplier for chat
	blocked: boolean?, -- guard says never talk to them
}

-- Probability of answering, and the category the answer should come from.
function Reply.decide(kind: Kind, traits: ReplyTraits, probedBefore: boolean?): (number, string)
	local base, category
	if kind == "greeting" then
		base = if traits.dialect == "kid" then 0.22 elseif traits.dialect == "older" then 0.08 else 0.15
		category = "greeting"
	elseif kind == "named" then
		base, category = 0.40, "greeting"
	elseif kind == "question" then
		base, category = 0.32 * (0.5 + traits.helpfulness), "help"
	elseif kind == "offer" then
		base, category = 0.55, "disagree"
	elseif kind == "compliment" then
		base, category = 0.30, "thanks"
	elseif kind == "botProbe" then
		base, category = if probedBefore then 0 else 0.70, "probe"
	elseif kind == "stopKeyword" then
		return 0, "none"
	else
		base, category = 0.05, "reaction"
	end
	if traits.blocked then
		return 0, category
	end
	local p = base * (0.3 + 1.4 * traits.chattiness) * (traits.moodChat or 1) * (1 - (traits.annoyance or 0))
	return math.clamp(p, 0, 0.9), category
end

-- Seconds until the reply appears.
function Reply.latency(replyText: string, voice: Voice, rng: Rng, expected: boolean): number
	return ChatStyle.typingSeconds(replyText, voice, rng, expected)
end

return Reply

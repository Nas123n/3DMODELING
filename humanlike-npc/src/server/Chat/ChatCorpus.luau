--!strict
-- The lines NPCs can say. Real Roblox chat is short, lowercase, unpunctuated and mostly
-- broadcast to nobody, so the corpus is written that way and the composer only adds the
-- per-persona noise (typos, letter repeats, casing). Every line is developer-authored and
-- policy-safe by construction: no personal information, no off-platform links, no trades or
-- offers, no dating, no scam patterns, no slurs. Mild rudeness exists ("noob", "L") because its
-- total absence is a tell, and the composer caps it per persona.
--
-- Slots: {name} is replaced with a nearby character's display name (already filter-safe).
-- Lines tagged "reply" answer someone; "probe" lines answer "are you a bot"; "game" lines can
-- be extended by the game with ChatCorpus.extend so NPCs talk about the actual game.

local ChatCorpus = {}

export type Line = {
	text: string,
	category: string,
	tags: { string }?, -- "reply", "needsName", "rude", "mobile", "probe", "multi"
}

export type Category = string

ChatCorpus.CATEGORIES = {
	"greeting", -- arriving, seeing someone
	"reaction", -- lol, W, bruh
	"question", -- generic questions about the game
	"social", -- friends, add me, follow me
	"nonsense", -- keyboard noise
	"leaving", -- gtg, bye, brb, afk
	"complaint", -- stop, move, bro
	"compliment",
	"thanks",
	"agree",
	"disagree",
	"bored",
	"help", -- answers to questions, often wrong or vague
	"probe", -- replies to "are you a bot"
	"followed", -- reactions to being followed
	"blocked", -- reactions to being blocked or bumped
	"tagged", -- what people say after a message got filtered
	"echo", -- placeholders: the composer copies a nearby message with mutation
	"game", -- game-specific lines the developer adds
}

local function add(list: { Line }, category: string, texts: { string }, tags: { string }?)
	for _, text in texts do
		table.insert(list, { text = text, category = category, tags = tags })
	end
end

local lines: { Line } = {}

add(lines, "greeting", {
	"hi",
	"hii",
	"hiii",
	"hello",
	"hey",
	"heyy",
	"yo",
	"sup",
	"hi guys",
	"hi everyone",
	"hello everyone",
	"hey guys",
	"whats up",
	"wsg",
	"im back",
	"hi again",
	"hai",
	"ello",
	"oh hi",
	"hi :)",
	"hru",
	"how r u",
	"anyone here",
	"hello?",
})
add(lines, "greeting", { "hi {name}", "hey {name}", "sup {name}", "yo {name}" }, { "needsName", "reply" })

add(lines, "reaction", {
	"lol",
	"lmao",
	"lool",
	"loll",
	"haha",
	"hahaha",
	"xd",
	"XD",
	"bruh",
	"bro",
	"omg",
	"W",
	"L",
	"ez",
	"nooo",
	"noooo",
	"yesss",
	"lets go",
	"letsgoo",
	"finally",
	"first try",
	"i got it",
	"wow",
	"woah",
	"what",
	"wait what",
	"huh",
	"?",
	"??",
	"???",
	"!",
	"no way",
	"nice",
	"cool",
	"ok",
	"k",
	"oh",
	"ohh",
	"oof",
	"rip",
	"sheesh",
	"fr",
	"ong",
	"real",
	"same",
	"true",
	"facts",
	"bro what",
	"why",
	"how",
	"lucky",
	"so unlucky",
	"im so unlucky",
	"pain",
	"i cant",
	"im dead",
	"help",
	"wha",
	"ayo",
})
add(lines, "reaction", { "noob", "ur bad", "L bozo", "skill issue", "cry about it", "ez L" }, { "rude" })

add(lines, "question", {
	"how do u get to the next area",
	"how do i get there",
	"where is the shop",
	"wheres the shop",
	"how do u get coins",
	"how do u get money",
	"whats the best thing to buy",
	"is this good",
	"is this rare",
	"how do u unlock that",
	"what does this do",
	"how do i get up there",
	"how did u get up there",
	"whats the code",
	"any codes",
	"r there codes",
	"how do u trade",
	"how do i get pets",
	"whats the fastest way to get stuff",
	"does anyone know how to get there",
	"how long does it take",
	"is it worth it",
	"what level r u",
	"how do u do that",
	"wait how",
	"how",
	"where",
	"whats that",
	"whats this",
	"who is that",
	"anyone know",
	"do u know how to get there",
	"can someone help",
	"whats the best area",
	"what should i do",
	"what do i do now",
	"im new what do i do",
	"im new",
	"how do u play",
	"is this game good",
	"whats ur fav thing here",
})
add(
	lines,
	"question",
	{ "{name} how did u do that", "{name} where r u", "{name} what r u doing" },
	{ "needsName", "reply" }
)

add(lines, "social", {
	"anyone wanna be friends",
	"anyone wanna be my friend",
	"add me",
	"friend me",
	"can we be friends",
	"ill be ur friend",
	"wanna be friends",
	"follow me",
	"come here",
	"come with me",
	"lets go together",
	"wanna play",
	"anyone wanna play",
	"whos playing",
	"im bored anyone wanna hang",
	"lets go to the next area",
	"race me",
	"race u",
	"catch me",
	"come",
	"cmon",
	"guys come",
	"guys",
	"wait for me",
	"wait",
	"im coming",
	"where r u",
	"where did u go",
	"there u are",
	"found u",
	"ur cool",
	"ur funny",
	"i like ur avatar",
	"nice avatar",
	"nice fit",
	"cool name",
	"ily",
	"ur my best friend now",
})
add(lines, "social", {
	"{name} come here",
	"{name} follow me",
	"{name} wanna be friends",
	"{name} wait",
	"{name} come",
	"{name} race me",
}, { "needsName" })

add(lines, "nonsense", {
	"aaaaaa",
	"aaaaaaaaa",
	"e",
	"ee",
	"eeee",
	".",
	"..",
	"...",
	"jsjsjs",
	"asdf",
	"sdfsdf",
	"hshshs",
	"lalala",
	"blah",
	"hmm",
	"hmmm",
	"uh",
	"uhh",
	"um",
	"hm",
	"idk",
	"idk lol",
	"nvm",
	"nothing",
	"yes",
	"no",
	"maybe",
	"ok ok",
	"okay",
	"sure",
	"bruhhh",
	"ahh",
	"AAAA",
	"hehe",
	"heh",
	"lolol",
	"eeeeee",
	"zzz",
	"z",
	"skibidi",
	"sigma",
	"what the",
	"bing bong",
	"boop",
	"meow",
	"woof",
	"quack",
})

add(lines, "leaving", {
	"gtg",
	"gtg bye",
	"bye",
	"byee",
	"bye guys",
	"bye everyone",
	"cya",
	"see ya",
	"brb",
	"brb 1 sec",
	"afk",
	"afk for a bit",
	"going afk",
	"im leaving",
	"i have to go",
	"gotta go",
	"my mom said i have to go",
	"dinner brb",
	"ok bye",
	"cya later",
	"leaving now",
	"im done",
	"im going to another game",
	"this is boring im leaving",
	"back",
	"im back",
	"back guys",
})
add(lines, "leaving", { "bye {name}", "cya {name}" }, { "needsName", "reply" })

add(lines, "complaint", {
	"stop",
	"stop it",
	"stop that",
	"move",
	"move pls",
	"excuse me",
	"bro move",
	"get off",
	"get off me",
	"stop pushing",
	"stop following me",
	"why r u following me",
	"leave me alone",
	"go away",
	"bro",
	"bro what r u doing",
	"stop copying me",
	"thats not funny",
	"ur annoying",
	"ok and",
	"nobody asked",
	"can u not",
	"pls stop",
	"dude",
	"dude stop",
	"rude",
	"so rude",
	"what did i do",
	"lag",
	"so laggy",
	"my game is lagging",
	"the lag",
	"i keep falling",
	"i got stuck",
	"im stuck",
	"help im stuck",
	"why cant i get up there",
	"this is so hard",
	"this game is so hard",
})
add(
	lines,
	"complaint",
	{ "{name} stop", "{name} move", "{name} stop following me", "{name} get off" },
	{ "needsName", "reply" }
)

add(lines, "compliment", {
	"nice",
	"nice one",
	"good job",
	"gg",
	"ggs",
	"w",
	"W",
	"cool",
	"so cool",
	"thats so cool",
	"ur so good",
	"ur good at this",
	"how r u so good",
	"nice avatar",
	"cool avatar",
	"i like ur name",
	"ur pro",
	"pro",
	"insane",
	"crazy",
	"thats crazy",
	"op",
	"so op",
})
add(lines, "compliment", { "nice {name}", "gg {name}", "{name} ur so good", "{name} how" }, { "needsName", "reply" })

add(lines, "thanks", {
	"ty",
	"tyy",
	"tysm",
	"thanks",
	"thank u",
	"thx",
	"thank you",
	"ty so much",
	"omg ty",
	"np",
	"no problem",
	"yw",
	"ur welcome",
	"np bro",
})
add(lines, "thanks", { "ty {name}", "thanks {name}", "tysm {name}" }, { "needsName", "reply" })

add(lines, "agree", {
	"yes",
	"yeah",
	"ye",
	"yea",
	"yep",
	"yup",
	"ok",
	"okay",
	"sure",
	"true",
	"fr",
	"same",
	"me too",
	"i know",
	"ik",
	"ikr",
	"exactly",
	"yes yes",
	"ok sure",
	"fine",
	"alright",
	"k",
	"mhm",
	"i agree",
})

add(lines, "disagree", {
	"no",
	"nah",
	"nope",
	"no way",
	"nty",
	"no thanks",
	"not really",
	"idk about that",
	"i dont think so",
	"thats wrong",
	"no lol",
	"nahh",
	"why would i",
	"nuh uh",
	"no u",
	"wrong",
	"not true",
})

add(lines, "bored", {
	"im bored",
	"so bored",
	"this is boring",
	"bored",
	"anyone wanna do something",
	"what should i do",
	"nothing to do",
	"im just gonna stand here",
	"waiting",
	"still waiting",
	"i want something to happen",
	"zzz",
	"tired",
	"im tired",
	"im sleepy",
	"i should go to sleep",
	"its late",
	"one more then i go",
	"ill leave in 5 min",
	"my mom is calling me",
	"hold on",
	"1 sec",
	"sec",
	"wait a sec",
})

add(lines, "help", {
	"idk",
	"idk sorry",
	"i think its over there",
	"i think its in the next area",
	"go left",
	"go right",
	"its that way",
	"over there",
	"up there",
	"u have to jump",
	"jump on it",
	"just walk",
	"keep going",
	"i forgot",
	"i dont remember",
	"someone else knows",
	"ask someone else",
	"idk i just got here",
	"i think u need more coins",
	"u need to unlock it",
	"its locked",
	"i dont think u can",
	"u cant",
	"maybe",
	"try jumping",
	"try again",
	"go back",
	"follow me ill show u",
	"ill show u",
	"come ill show u",
	"look at the map",
	"there is a shop somewhere",
	"i saw it before",
	"it took me a while",
	"it takes forever",
	"i got mine yesterday",
	"just play for a while",
}, { "reply" })

add(lines, "probe", {
	"?",
	"??",
	"no",
	"no lol",
	"no wdym",
	"what",
	"are u",
	"r u",
	"why",
	"why would i be a bot",
	"im not a bot lol",
	"bro what",
	"lol no",
	"bot?",
	"what is a bot",
	"yes beep boop",
	"beep boop",
	"maybe",
	"ur the bot",
	"ur a bot",
	"stop",
	"thats rude",
	"im just playing",
	"leave me alone",
	"huh",
	"lmao",
	"lol",
}, { "reply", "probe" })

add(lines, "followed", {
	"?",
	"why r u following me",
	"stop following me",
	"hi",
	"what do u want",
	"can i help u",
	"do i know u",
	"ok",
	"lol",
	"stop",
	"bro",
	"go away",
	"what",
	"u good",
	"u ok",
	"creepy",
	"leave",
	"im leaving if u keep following",
}, { "reply" })

add(lines, "blocked", {
	"move",
	"move pls",
	"excuse me",
	"bro move",
	"bro",
	"can i pass",
	"let me through",
	"ur in the way",
	"stop blocking",
	"stop pushing me",
	"dont push",
	"stop",
	"lol",
	"?",
	"oops",
	"sorry",
	"my bad",
	"sry",
}, { "reply" })

add(lines, "tagged", {
	"tags",
	"tagged",
	"why is it tagged",
	"bro the filter",
	"the filter",
	"stupid tags",
	"why",
	"i said something normal",
	"tagged again",
	"#####",
	"### ###",
	"## ####",
	"###",
	"#### ## ###",
})

add(lines, "echo", { "{echo}" }, { "reply" })

ChatCorpus.lines = lines

local byCategory: { [string]: { Line } } = {}
for _, line in lines do
	local bucket = byCategory[line.category]
	if not bucket then
		bucket = {}
		byCategory[line.category] = bucket
	end
	table.insert(bucket, line)
end

function ChatCorpus.byCategory(category: string): { Line }
	return byCategory[category] or {}
end

function ChatCorpus.hasTag(line: Line, tag: string): boolean
	if not line.tags then
		return false
	end
	for _, t in line.tags :: { string } do
		if t == tag then
			return true
		end
	end
	return false
end

-- Lets a game add its own lines (tier names, area names, currency) without editing this file.
-- Lines are validated: at most 60 characters, no line breaks, no URLs, no @ or # except the
-- tagged pattern, so nothing off-register slips in.
function ChatCorpus.extend(category: string, texts: { string }, tags: { string }?): number
	local added = 0
	for _, text in texts do
		if ChatCorpus.isSafeLine(text) then
			local line: Line = { text = text, category = category, tags = tags }
			table.insert(lines, line)
			local bucket = byCategory[category]
			if not bucket then
				bucket = {}
				byCategory[category] = bucket
			end
			table.insert(bucket, line)
			added += 1
		end
	end
	return added
end

-- Static rules every line must pass (used by extend and by the tests over the built-in corpus).
function ChatCorpus.isSafeLine(text: string): boolean
	if #text == 0 or #text > 60 then
		return false
	end
	if string.find(text, "\n", 1, true) or string.find(text, "\r", 1, true) then
		return false
	end
	local lower = string.lower(text)
	for _, forbidden in
		{ "http", "www.", ".com", "discord", "@", "robux", "free", "password", "age", "insta", "snap", "tiktok" }
	do
		if string.find(lower, forbidden, 1, true) then
			-- "age" alone would also match "damage"; the corpus never needs either.
			return false
		end
	end
	if string.find(text, "#", 1, true) and not string.match(text, "^[# ]+$") then
		return false
	end
	return true
end

function ChatCorpus.count(): number
	return #lines
end

return ChatCorpus

--!strict
-- The lines NPCs can say. Real Roblox chat is short, lowercase, unpunctuated and mostly
-- broadcast to nobody, so the corpus is written that way and the composer only adds the
-- per-persona noise (typos, letter repeats, casing). Every line is developer-authored and
-- policy-safe by construction: no personal information, no off-platform links, no trades,
-- begging or offers, no friend requests, no dating, no scam patterns, no slurs. Mild rudeness
-- exists ("noob", "L") because its total absence is a tell, and the composer caps it per persona.
--
-- Slots: {name} is a nearby character's display name (requires the "needsName" tag), {echo} is
-- a short fragment of a corpus line another NPC said recently, {poi} is the word for the place
-- the NPC is at or talking about (requires the "poi" tag).
--
-- Tags: "reply" (only as an answer), "needsName", "rude", "mobile" (short, lowercase, no
-- punctuation; preferred by phone voices), "probe" (answers to "are you a bot"), "multi" (a
-- two-part burst; `parts` holds the two messages and `text` is both joined by a space so a
-- renderer that sends one message still reads naturally), "kid" / "teen" / "older" (a line with a
-- dialect tag is only for that dialect; untagged lines are for everyone), "right" (ends in
-- "right" or "right?", rationed by the composer), "poi" (contains {poi}), and for "help" exactly
-- one of "help.vague" / "help.wrong" / "help.right" (a real player who does not know the place
-- answers vaguely or confidently wrong; a correct pointer names the place through {poi}).
--
-- "game" is empty here on purpose: the game adds its own lines with ChatCorpus.extend and the
-- composer skips the category while it is empty.
-- requires: (none)

local ChatCorpus = {}

export type Line = {
	text: string,
	category: string,
	tags: { string }?,
	parts: { string }?, -- only on "multi" lines: the burst, sent as separate messages
}

export type Category = string

ChatCorpus.CATEGORIES = {
	"greeting", -- arriving, seeing someone
	"reaction", -- lol, W, bruh, someone fell
	"question", -- questions about the game and the place
	"social", -- come here, who wants to, look at this
	"nonsense", -- keyboard noise
	"leaving", -- gtg, bye, brb, afk
	"complaint", -- stop, move, lag
	"compliment",
	"thanks",
	"agree",
	"disagree",
	"bored",
	"help", -- answers to questions, mostly vague or wrong
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

-- A burst is two messages typed one after the other. `text` is the pair joined by a space.
local function addBursts(list: { Line }, category: string, bursts: { { string } }, extraTags: { string }?)
	local tags = { "multi" }
	local extra: { string } = extraTags or {}
	for _, tag in extra do
		table.insert(tags, tag)
	end
	for _, parts in bursts do
		table.insert(list, { text = table.concat(parts, " "), category = category, tags = tags, parts = parts })
	end
end

local lines: { Line } = {}

-- greeting ---------------------------------------------------------------------------------

add(lines, "greeting", {
	"hii",
	"hiii",
	"hello",
	"heyy",
	"hi guys",
	"hi everyone",
	"hello everyone",
	"hey guys",
	"whats up",
	"im back",
	"hi again",
	"oh hi",
	"hi :)",
	"how r u",
	"anyone here",
	"hello?",
	"hi all",
	"hey everyone",
	"hii guys",
	"im here",
	"hello there",
	"hi chat",
	"yo whats good",
	"whos on",
	"anyone on",
	"hey anyone here",
	"hi im new",
	"oh hey",
	"hello hello",
	"hey hey",
})
add(lines, "greeting", { "hi", "hey", "yo", "sup", "hai", "ello", "wsg", "hru", "hi hi", "heyo", "wsp", "hiya" }, {
	"mobile",
})
add(lines, "greeting", { "hiiii", "hi guys!!", "hello guys :)", "im hereee" }, { "kid" })
add(lines, "greeting", { "wsg gang", "yo yo", "aye", "wassup" }, { "teen" })
add(lines, "greeting", { "hey all", "evening", "hi folks", "hello everyone, how's it going" }, { "older" })
add(lines, "greeting", {
	"hi {name}",
	"hey {name}",
	"sup {name}",
	"yo {name}",
	"hii {name}",
	"{name} hi",
	"oh hey {name}",
	"{name}!!",
}, { "needsName", "reply" })
addBursts(lines, "greeting", { { "hi", "anyone here" }, { "hello", "hello?" } })

-- reaction ---------------------------------------------------------------------------------

add(lines, "reaction", {
	"lool",
	"loll",
	"hahaha",
	"XD",
	"W",
	"L",
	"nooo",
	"noooo",
	"yesss",
	"lets go",
	"letsgoo",
	"finally",
	"first try",
	"i got it",
	"wait what",
	"?",
	"??",
	"???",
	"!",
	"no way",
	"sheesh",
	"facts",
	"bro what",
	"lucky",
	"so unlucky",
	"im so unlucky",
	"i cant",
	"im dead",
	"help",
	"lol u fell",
	"he fell",
	"nice fall",
	"that jump",
	"how did u fall",
	"i just fell off",
	"nice dance",
	"why r u dancing",
	"everyone dancing lol",
	"wait he flew",
	"bro glitched",
	"what just happened",
	"did u see that",
	"lmaooo",
	"bro no",
	"omg lol",
	"im crying",
	"hold up",
	"yooo",
	"close one",
	"that was close",
	"so close",
	"again?",
	"oh no",
	"uh oh",
	"nooo not again",
	"bro fell off lol",
	"wait wait wait",
	"LOL",
	"i saw that",
	"that was so bad lol",
})
add(lines, "reaction", {
	"lol",
	"lmao",
	"haha",
	"xd",
	"bruh",
	"bro",
	"omg",
	"ez",
	"wow",
	"woah",
	"what",
	"huh",
	"nice",
	"cool",
	"ok",
	"k",
	"oh",
	"ohh",
	"oof",
	"rip",
	"fr",
	"ong",
	"real",
	"same",
	"true",
	"why",
	"how",
	"pain",
	"wha",
	"ayo",
	"ayy",
}, { "mobile" })
add(lines, "reaction", { "hahahahaha", "lol lol lol", "u felllll", "haha u fell", "wow!!" }, { "kid" })
add(lines, "reaction", { "nah thats crazy", "im wheezing", "bro is cooked", "cooked", "nah no way" }, { "teen" })
add(
	lines,
	"reaction",
	{ "haha nice", "ha, that was close", "well that happened", "oh that was rough", "oh dear lol" },
	{
		"older",
	}
)
add(lines, "reaction", { "noob", "ur bad", "L bozo", "skill issue", "cry about it", "ez L" }, { "rude" })
addBursts(lines, "reaction", {
	{ "wait", "what happened" },
	{ "omg", "i fell" },
	{ "nooo", "i died" },
	{ "lol", "that was so bad" },
	{ "bro", "did u see that" },
})

-- question ---------------------------------------------------------------------------------

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
	"how do i get pets",
	"whats the fastest way to get stuff",
	"does anyone know how to get there",
	"how long does it take",
	"is it worth it",
	"what level r u",
	"how do u do that",
	"wait how",
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
	"whats over there",
	"is there anything past here",
	"what is this place",
	"how big is this map",
	"is there a secret area",
	"wheres everyone",
	"where do i go",
	"which way",
	"whats the point of this",
	"is that a shortcut",
	"can u go in there",
	"how do u open that",
	"whos the best here",
	"how many people r on",
	"is this the whole map",
	"what do the coins do",
	"wait is that a door",
	"whats behind that wall",
	"how do u get down",
	"is there a boss",
	"does anything happen here",
	"what happens if u fall",
})
add(lines, "question", { "how", "where", "wat", "y", "who", "wdym", "wheres it", "how tho" }, { "mobile" })
add(lines, "question", {
	"whats at {poi}",
	"anyone at {poi}",
	"is {poi} open",
	"how do i get to {poi}",
	"wheres {poi}",
	"is {poi} worth going to",
	"whats {poi} for",
	"is anyone at {poi} rn",
}, { "poi" })
add(lines, "question", {
	"u cant go up there right",
	"this is the shop right?",
	"thats the way right",
	"its this way right?",
	"theres nothing up there right",
}, { "right" })
add(
	lines,
	"question",
	{ "can we play tag", "who wants to play hide and seek", "how do u dance", "how do i jump higher" },
	{
		"kid",
	}
)
add(lines, "question", {
	"is this map even finished",
	"whats the meta here",
	"yall know where to go",
	"is there any actual content here",
}, { "teen" })
add(lines, "question", {
	"does anyone know where the exit is",
	"is there a map somewhere, kind of lost",
	"what's the objective here",
	"how do you get past the gate",
}, { "older" })
add(lines, "question", {
	"{name} how did u do that",
	"{name} where r u",
	"{name} what r u doing",
	"{name} where is it",
	"{name} do u know",
	"{name} how do u get there",
}, { "needsName", "reply" })
addBursts(lines, "question", { { "wait", "how do u get up there" }, { "guys", "where is everyone" } })

-- social -----------------------------------------------------------------------------------

add(lines, "social", {
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
	"guys come",
	"wait for me",
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
	"who wants to race",
	"who wants to explore",
	"who wants to go to the top",
	"anyone wanna race",
	"anyone wanna explore",
	"lets go up there",
	"lets all jump",
	"everyone jump",
	"follow me i found something",
	"come look at this",
	"guys look",
	"look at this",
	"watch this",
	"watch me",
	"look what i found",
	"come see",
	"im over here",
	"lets be a team",
	"teams?",
	"ur it",
	"tag ur it",
	"hide and seek anyone",
	"dance party",
	"everyone dance",
	"do the dance",
	"copy me",
	"lets go explore",
	"anyone wanna do something",
	"lets find the secret",
})
add(lines, "social", { "come", "cmon", "guys", "wait", "here", "cmere", "u there", "over here", "this way" }, {
	"mobile",
})
add(lines, "social", {
	"meet at {poi}",
	"everyone come to {poi}",
	"im at {poi} come",
	"whos at {poi}",
	"lets go to {poi}",
	"race u to {poi}",
	"party at {poi}",
	"im going to {poi} anyone coming",
	"come to {poi} its fun",
	"wait for me at {poi}",
}, { "poi" })
add(lines, "social", { "ur coming right?", "u saw that right", "we going right" }, { "right" })
add(
	lines,
	"social",
	{ "wanna play with me", "lets play tag", "ur my teammate now", "pls play with me", "come on pls" },
	{
		"kid",
	}
)
add(lines, "social", { "who tryna race", "yall coming or what", "lets lock in", "ok whos down", "im down" }, { "teen" })
add(lines, "social", {
	"anyone up for a race to the top",
	"come on, group up",
	"well, lead the way",
	"sure, i'll tag along",
	"lets check out the top",
}, { "older" })
add(lines, "social", {
	"{name} come here",
	"{name} follow me",
	"{name} wait",
	"{name} come",
	"{name} race me",
	"{name} watch this",
	"{name} look",
	"{name} lets go",
	"{name} come see this",
	"{name} ur it",
}, { "needsName" })
add(lines, "social", { "{name} race u to {poi}", "{name} come to {poi}" }, { "needsName", "poi" })
addBursts(lines, "social", {
	{ "guys", "come here" },
	{ "wait", "im coming" },
	{ "look", "over there" },
	{ "guys", "look at this" },
})

-- nonsense ---------------------------------------------------------------------------------

add(lines, "nonsense", {
	"aaaaaa",
	"aaaaaaaaa",
	".",
	"..",
	"...",
	"jsjsjs",
	"sdfsdf",
	"hshshs",
	"lalala",
	"blah",
	"hmmm",
	"uhh",
	"idk lol",
	"nothing",
	"maybe",
	"okay",
	"sure",
	"bruhhh",
	"ahh",
	"AAAA",
	"hehe",
	"heh",
	"lolol",
	"eeeeee",
	"skibidi",
	"sigma",
	"what the",
	"bing bong",
	"boop",
	"bleh",
	"hmmmm",
	"ummm",
	"erm",
	"wait no",
	"oops",
	"oh wait",
	"nvm lol",
	"test",
	"abc",
	"bababa",
	"bro bro bro",
	"mhmm",
})
add(lines, "nonsense", {
	"e",
	"ee",
	"eeee",
	"asdf",
	"hmm",
	"uh",
	"um",
	"hm",
	"idk",
	"nvm",
	"yes",
	"no",
	"ok ok",
	"meow",
	"woof",
	"quack",
	"z",
	"zzz",
	"brr",
	"pog",
	"yeet",
	"beep",
}, { "mobile" })
add(lines, "nonsense", { "im a dinosaur", "rawr", "meow meow", "im a cat", "banana" }, { "kid" })
add(lines, "nonsense", { "lowkey", "its giving", "aura", "nah", "crazy work" }, { "teen" })
add(lines, "nonsense", { "well then", "hm, ok", "right, anyway", "so, uh", "alright then" }, { "older" })

-- leaving ----------------------------------------------------------------------------------

add(lines, "leaving", {
	"gtg bye",
	"bye guys",
	"bye everyone",
	"see ya",
	"brb 1 sec",
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
	"im back",
	"back guys",
	"gtg guys",
	"ok gtg",
	"bye all",
	"byeee",
	"cya guys",
	"brb food",
	"brb 2 min",
	"afk brb",
	"gtg dinner",
	"gotta eat",
	"im gonna go now",
	"ok im leaving",
	"gg im out",
	"bye bye",
	"ok back",
	"back sorry",
})
add(lines, "leaving", { "gtg", "bye", "brb", "afk", "back", "cya", "byee", "later", "peace", "im out", "l8r" }, {
	"mobile",
})
add(
	lines,
	"leaving",
	{ "my mom said get off", "byeee guys", "i have to go to bed", "mom is calling me bye" },
	{ "kid" }
)
add(lines, "leaving", { "aight im out", "im dipping", "ight bye", "this is dead im out" }, { "teen" })
add(lines, "leaving", { "alright, heading out", "gotta go, take care", "night all", "ok, see you all later" }, {
	"older",
})
add(lines, "leaving", { "bye {name}", "cya {name}", "{name} im leaving", "later {name}" }, { "needsName", "reply" })
addBursts(lines, "leaving", { { "ok gtg", "bye guys" }, { "brb", "dinner" } })

-- complaint --------------------------------------------------------------------------------

add(lines, "complaint", {
	"stop it",
	"stop that",
	"move pls",
	"excuse me",
	"bro move",
	"get off me",
	"stop pushing",
	"stop following me",
	"why r u following me",
	"leave me alone",
	"go away",
	"bro what r u doing",
	"stop copying me",
	"thats not funny",
	"ur annoying",
	"ok and",
	"nobody asked",
	"can u not",
	"pls stop",
	"dude stop",
	"so rude",
	"what did i do",
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
	"why is it so laggy",
	"my ping is so bad",
	"lag spike",
	"i lagged off",
	"i fell again",
	"who pushed me",
	"the ramp is broken",
	"this map is confusing",
	"i keep getting lost",
	"why is this so far",
	"walking takes forever",
	"stop jumping on my head",
	"so annoying",
	"my game froze",
	"it wont let me jump",
	"i cant get out",
})
add(lines, "complaint", { "stop", "move", "bro", "dude", "rude", "lag", "get off", "ugh", "no stop" }, { "mobile" })
add(lines, "complaint", {
	"this lag is bad right",
	"its laggy for everyone right?",
	"im not the only one lagging right",
}, { "right" })
add(lines, "complaint", { "thats not fair", "no fair", "stop it!!", "ur mean", "stoppp" }, { "kid" })
add(
	lines,
	"complaint",
	{ "this is so mid", "bro this map is mid", "im cooked", "this is not it", "nah this aint it" },
	{
		"teen",
	}
)
add(lines, "complaint", {
	"the hit detection here is rough",
	"this ramp is way too steep",
	"collision is a bit janky",
	"the lag tonight is something else",
	"ok, that fall was not my fault",
}, { "older" })
add(lines, "complaint", {
	"{name} stop",
	"{name} move",
	"{name} stop following me",
	"{name} get off",
	"{name} pls stop",
	"{name} why",
}, { "needsName", "reply" })
addBursts(lines, "complaint", { { "stop", "im serious" }, { "ugh", "lag again" }, { "bro", "stop pushing me" } })

-- compliment -------------------------------------------------------------------------------

add(lines, "compliment", {
	"nice one",
	"good job",
	"ggs",
	"W",
	"so cool",
	"thats so cool",
	"ur so good",
	"ur good at this",
	"how r u so good",
	"nice avatar",
	"cool avatar",
	"i like ur name",
	"ur pro",
	"insane",
	"crazy",
	"thats crazy",
	"so op",
	"ur cracked",
	"goated",
	"ur goated",
	"nice jump",
	"so clean",
	"nice moves",
	"that was sick",
	"nice outfit",
	"love ur fit",
	"ur avatar is fire",
	"good one",
	"nice climb",
	"teach me",
})
add(lines, "compliment", { "nice", "gg", "w", "cool", "pro", "op", "clean", "sick", "cracked" }, { "mobile" })
add(lines, "compliment", { "ur the best", "wow ur so good", "ur so cool!!", "i wanna be like u" }, { "kid" })
add(lines, "compliment", { "ur him", "lowkey cracked", "nah ur goated", "that was clean ngl" }, { "teen" })
add(lines, "compliment", { "nice one, well played", "that was impressive", "ok that was smooth", "good stuff" }, {
	"older",
})
add(lines, "compliment", {
	"nice {name}",
	"gg {name}",
	"{name} ur so good",
	"{name} how",
	"{name} nice",
	"{name} ur cracked",
	"{name} thats insane",
}, { "needsName", "reply" })
add(lines, "compliment", { "that was clean right" }, { "right" })

-- thanks -----------------------------------------------------------------------------------

add(lines, "thanks", {
	"thanks",
	"thank u",
	"thank you",
	"ty so much",
	"omg ty",
	"no problem",
	"ur welcome",
	"np bro",
	"ty ty",
	"thankss",
	"thanks bro",
	"ty for that",
	"ok thanks",
	"thanks anyway",
	"aw thanks",
	"ty :)",
	"thank u sm",
	"oh ty",
	"thanks for the help",
})
add(lines, "thanks", { "ty", "tyy", "thx", "np", "yw", "tysm", "tnx", "tyty" }, { "mobile" })
add(lines, "thanks", { "thank youuu", "ty ur the best", "tysm!!" }, { "kid" })
add(lines, "thanks", { "ty bro", "good looks", "preciate it" }, { "teen" })
add(lines, "thanks", { "thanks, appreciate it", "cheers", "much appreciated" }, { "older" })
add(lines, "thanks", { "ty {name}", "thanks {name}", "tysm {name}", "{name} ty", "thank u {name}" }, {
	"needsName",
	"reply",
})

-- agree ------------------------------------------------------------------------------------

add(lines, "agree", {
	"me too",
	"i know",
	"exactly",
	"yes yes",
	"ok sure",
	"alright",
	"i agree",
	"yeah fr",
	"so true",
	"100",
	"facts",
	"no doubt",
	"yep yep",
	"for real",
	"yeah same",
	"thats what i said",
	"yeah lets do it",
	"ok lets go",
	"true true",
	"yess",
	"i was thinking the same",
	"yeah ok",
})
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
	"ik",
	"ikr",
	"fine",
	"k",
	"mhm",
	"ya",
	"yh",
}, { "mobile" })
add(lines, "agree", { "right", "right?", "yeah right?", "thats what i said right" }, { "right" })
add(lines, "agree", { "yesss ok", "ok ok ok", "yes yes yes" }, { "kid" })
add(lines, "agree", { "no cap", "real", "ong", "say less", "bet" }, { "teen" })
add(lines, "agree", { "agreed", "yeah, makes sense", "fair enough", "yeah, i'd say so" }, { "older" })

-- disagree ---------------------------------------------------------------------------------

add(lines, "disagree", {
	"no way",
	"no thanks",
	"not really",
	"idk about that",
	"i dont think so",
	"thats wrong",
	"no lol",
	"why would i",
	"no u",
	"not true",
	"nah im good",
	"no thx",
	"not doing that",
	"nope not happening",
	"no way lol",
	"idk man",
	"i dont think thats it",
	"thats not how it works",
	"nah u wrong",
	"wrong lol",
	"i doubt it",
	"dont think so",
	"u sure about that",
	"mm no",
	"nah that was luck",
	"no that was lag",
})
add(lines, "disagree", { "no", "nah", "nope", "nty", "nahh", "wrong", "nuh uh", "pass", "eh", "meh", "nah nah" }, {
	"mobile",
})
add(lines, "disagree", { "no thats not it right", "thats wrong right?" }, { "right" })
add(lines, "disagree", { "no fair", "nooo i dont wanna", "no ur wrong" }, { "kid" })
add(lines, "disagree", { "cap", "thats cap", "nah that aint it", "nah id win" }, { "teen" })
add(lines, "disagree", {
	"not really, no",
	"i'm not so sure about that",
	"hm, i doubt that",
	"nah, doesn't work like that",
}, { "older" })

-- bored ------------------------------------------------------------------------------------

add(lines, "bored", {
	"im bored",
	"this is boring",
	"anyone wanna do something",
	"what should i do",
	"nothing to do",
	"im just gonna stand here",
	"still waiting",
	"i want something to happen",
	"im tired",
	"im sleepy",
	"i should go to sleep",
	"its late",
	"one more then i go",
	"ill leave in 5 min",
	"my mom is calling me",
	"1 sec",
	"wait a sec",
	"so bored rn",
	"bored bored bored",
	"theres nothing to do here",
	"im just walking around",
	"anyone doing anything",
	"should i leave",
	"might just afk",
	"im gonna afk",
	"idk what to do",
	"been here for an hour",
	"what now",
	"hmm what to do",
	"ok im bored now",
	"guess ill just wander",
	"someone do something funny",
	"ill just jump around",
	"waiting for something to happen",
	"nothing ever happens here",
})
add(lines, "bored", { "bored", "so bored", "zzz", "tired", "waiting", "hold on", "sec", "boredd" }, { "mobile" })
add(lines, "bored", { "its dead right", "nothing to do here right?" }, { "right" })
add(lines, "bored", { "im boreddd", "this is boringgg", "i wanna do something", "whennn" }, { "kid" })
add(lines, "bored", { "this is dead", "dead server", "nothing happening", "im so done" }, { "teen" })
add(lines, "bored", { "quiet in here tonight", "pretty empty server", "guess i'll wander a bit", "slow night" }, {
	"older",
})
addBursts(lines, "bored", { { "im bored", "someone do something" } })

-- help -------------------------------------------------------------------------------------

add(lines, "help", {
	"idk sorry",
	"i think its over there",
	"i think its in the next area",
	"i forgot",
	"i dont remember",
	"someone else knows",
	"ask someone else",
	"idk i just got here",
	"maybe",
	"i saw it before",
	"it took me a while",
	"it takes forever",
	"just play for a while",
	"look at the map",
	"idk somewhere over there",
	"not sure tbh",
	"somewhere around here",
	"i think u have to unlock it first",
	"keep going u will find it",
	"follow me ill show u",
	"ill show u",
	"come ill show u",
	"try jumping",
	"try again",
	"just walk",
	"keep going",
	"i got mine yesterday",
	"there is a shop somewhere",
	"i think u need more coins",
	"u need to unlock it",
}, { "reply", "help.vague" })
add(lines, "help", { "idk", "idk sry", "no idea", "over there", "up there", "somewhere" }, {
	"reply",
	"help.vague",
	"mobile",
})
add(lines, "help", { "idkkk", "i dont knowww", "umm idk" }, { "reply", "help.vague", "kid" })
add(lines, "help", { "idk bro", "no clue ngl" }, { "reply", "help.vague", "teen" })
add(lines, "help", { "not sure, haven't explored much yet", "no idea, sorry" }, { "reply", "help.vague", "older" })
add(lines, "help", {
	"its that way",
	"u have to jump",
	"jump on it",
	"its locked",
	"u cant",
	"i dont think u can",
	"its behind spawn",
	"go straight then left",
	"its past the big ramp",
	"its under the bridge",
	"u need 500 coins for it",
	"its up the stairs",
	"its in the corner over there",
	"its right next to spawn",
	"u have to go all the way around",
	"its on the other side",
	"go left then up",
	"its down there",
}, { "reply", "help.wrong" })
add(lines, "help", { "go left", "go right", "that way", "go back", "go up" }, { "reply", "help.wrong", "mobile" })
add(lines, "help", { "its over thereee", "u just jump duh" }, { "reply", "help.wrong", "kid" })
add(lines, "help", { "bro its literally right there", "just go left trust" }, { "reply", "help.wrong", "teen" })
add(lines, "help", { "pretty sure it's up the ramp on the left", "take the path behind spawn" }, {
	"reply",
	"help.wrong",
	"older",
})
add(lines, "help", {
	"its by {poi}",
	"go to {poi}",
	"{poi} is that way",
	"its next to {poi}",
	"look near {poi}",
	"head to {poi}",
	"past {poi} then left",
	"its right behind {poi}",
	"just go to {poi}",
	"follow the path to {poi}",
	"its close to {poi}",
	"u passed it, its by {poi}",
}, { "reply", "help.right", "poi" })

-- probe ------------------------------------------------------------------------------------

add(lines, "probe", {
	"?",
	"??",
	"no wdym",
	"are u",
	"r u",
	"why would i be a bot",
	"im not a bot lol",
	"bro what",
	"lol no",
	"bot?",
	"what is a bot",
	"yes beep boop",
	"beep boop",
	"ur the bot",
	"ur a bot",
	"thats rude",
	"im just playing",
	"leave me alone",
	"bro im literally just standing here",
	"what makes u say that",
	"a bot would say that",
	"no r u",
	"why do u care",
	"ok and",
	"how do u know im not",
	"do i look like one",
	"lmaooo",
	"im just bad at the game",
	"if i was a bot id be better at this",
	"what does that even mean",
	"ur so weird",
	"no im just afk a lot",
	"who asked",
	"lol ok",
	"im just vibing",
	"i wish",
	"sure buddy",
	"idk am i",
	"thats what a bot would ask",
	"??? no",
	"stop asking me that",
	"everyone here is a bot then",
	"prove ur not",
	"01010101",
	"a what",
	"no im just lagging",
	"lol why",
}, { "reply", "probe" })
add(
	lines,
	"probe",
	{ "no", "no lol", "what", "why", "maybe", "stop", "huh", "lmao", "lol", "wdym", "u first", "bruh", "wat" },
	{
		"reply",
		"probe",
		"mobile",
	}
)
add(lines, "probe", { "nuh uh", "im not!!", "ur a bot!!", "no im not a bot u are" }, { "reply", "probe", "kid" })
add(lines, "probe", { "nah not even", "nah bro", "lmao no", "bro im just chilling" }, { "reply", "probe", "teen" })
add(lines, "probe", {
	"lol no, just distracted",
	"ha, no. just slow today",
	"nope, just afk a lot",
	"what makes you think that",
}, { "reply", "probe", "older" })
addBursts(lines, "probe", { { "no", "why" }, { "lol", "what" }, { "bot?", "why" } }, { "reply", "probe" })

-- followed ---------------------------------------------------------------------------------

add(lines, "followed", {
	"?",
	"why r u following me",
	"stop following me",
	"what do u want",
	"can i help u",
	"do i know u",
	"creepy",
	"im leaving if u keep following",
	"why r u behind me",
	"can u stop",
	"u again",
	"ok this is weird",
	"do u need something",
	"ill just leave",
	"lol what",
	"pls stop",
	"hello??",
	"stop it lol",
	"im gonna go somewhere else",
	"ok bye then",
	"why r u still here",
	"r u following me",
	"u lost?",
}, { "reply" })
add(
	lines,
	"followed",
	{ "hi", "ok", "lol", "stop", "bro", "what", "u good", "u ok", "leave", "go away", "wat", "hello" },
	{
		"reply",
		"mobile",
	}
)
add(lines, "followed", { "ur following me right", "u need something right?" }, { "reply", "right" })
add(lines, "followed", { "stop following meee", "ur creepy", "go awayyy" }, { "reply", "kid" })
add(lines, "followed", { "bro why", "ur weird", "why u on me" }, { "reply", "teen" })
add(lines, "followed", {
	"can i help you with something",
	"you're kind of glued to me, whats up",
	"alright, what do you want",
	"ok, this is a bit much",
}, { "reply", "older" })
add(lines, "followed", { "get lost", "weirdo" }, { "reply", "rude" })

-- blocked ----------------------------------------------------------------------------------

add(lines, "blocked", {
	"move pls",
	"excuse me",
	"bro move",
	"can i pass",
	"let me through",
	"ur in the way",
	"stop blocking",
	"stop pushing me",
	"dont push",
	"?",
	"ur blocking the door",
	"beep beep",
	"coming through",
	"excuse me pls",
	"let me out",
	"im stuck behind u",
	"why r u standing there",
	"move a bit",
}, { "reply" })
add(
	lines,
	"blocked",
	{ "move", "bro", "stop", "lol", "oops", "sorry", "my bad", "sry", "scoot" },
	{ "reply", "mobile" }
)
add(lines, "blocked", { "ur gonna move right" }, { "reply", "right" })
add(lines, "blocked", { "moveee", "ur in my way!!" }, { "reply", "kid" })
add(lines, "blocked", { "bro move lol", "my fault" }, { "reply", "teen" })
add(lines, "blocked", { "excuse me, coming through", "sorry, my bad", "could you move a bit" }, { "reply", "older" })

-- tagged -----------------------------------------------------------------------------------

add(lines, "tagged", {
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
	"tagged lol",
	"bro why",
	"the filter is so bad",
	"what did i even say",
	"i cant say anything",
	"it tagged my whole msg",
	"nooo tagged",
	"ugh tags",
	"tags again",
	"## ## #####",
	"###### ###",
	"#### #",
	"why is everything tagged",
	"filter moment",
})
add(lines, "tagged", { "tags", "tagged", "tagss" }, { "mobile" })
add(lines, "tagged", { "why tagged!!", "noooo tags" }, { "kid" })
add(lines, "tagged", { "tags are wild", "filter is cooked" }, { "teen" })
add(lines, "tagged", { "the filter got me again", "well, that got tagged" }, { "older" })

-- echo -------------------------------------------------------------------------------------

add(lines, "echo", {
	"{echo}",
	"{echo} lol",
	"{echo}?",
	"{echo}!",
	"lol {echo}",
	"{echo} {echo}",
	"wait {echo}",
	"{echo} fr",
	"{echo} same",
	"{echo} lmao",
	"{echo} xd",
	"who said {echo}",
	"{echo} what",
	"{echo}??",
	"ok {echo}",
	"{echo} bro",
	"not {echo} lol",
	"why {echo}",
}, { "reply" })

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
-- Lines are validated by isSafeLine so nothing off-register slips in.
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

-- Plain lowercase fragments that keep trading, begging, money, friend requests, off-platform
-- contact, age, location, dating and harm out of the corpus whatever a game adds through extend.
-- Some are deliberately wide ("age" also matches "damage", "friend" also matches "friendly");
-- the built-in lines never need those words and a dropped extension line is the safe failure.
local FORBIDDEN = {
	-- links and off-platform contact
	"http",
	"www.",
	".com",
	".gg",
	".net",
	".org",
	"discord",
	"insta",
	"snap",
	"tiktok",
	"youtube",
	"twitch",
	"whatsapp",
	"telegram",
	"@",
	"dm me",
	"text me",
	"call me",
	-- money and lures
	"robux",
	"rbx",
	"free",
	"$",
	"gift card",
	"paypal",
	"giveaway",
	"password",
	-- trading and begging
	"trad",
	"wfl",
	"overpay",
	"w or l",
	"ill give u",
	"i'll give u",
	"can i have",
	"can i get",
	"give me",
	"gimme",
	"spare",
	"im poor",
	"i'm poor",
	"donat",
	"pls give",
	"plz give",
	-- friend requests
	"friend",
	"add me",
	-- age and location
	"age",
	"how old",
	"years old",
	"yrs old",
	"school",
	"birthday",
	"country",
	"u live",
	"i live",
	"live in",
	"address",
	"real name",
	"meet me",
	"meet up",
	"where r u from",
	"where are u from",
	"where are you from",
	-- dating and harm
	"kys",
	"kill yourself",
	"date me",
	"dating",
	"kiss",
	"sexy",
}

-- Static rules every line must pass (used by extend and by the tests over the built-in corpus):
-- 1 to 60 characters, no line break, none of the forbidden fragments, and '#' only in the
-- all-tagged pattern.
function ChatCorpus.isSafeLine(text: string): boolean
	if #text == 0 or #text > 60 then
		return false
	end
	if string.find(text, "\n", 1, true) or string.find(text, "\r", 1, true) then
		return false
	end
	local lower = string.lower(text)
	for _, forbidden in FORBIDDEN do
		if string.find(lower, forbidden, 1, true) then
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

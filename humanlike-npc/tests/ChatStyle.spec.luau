return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local ChatStyle = session.require(session.game.ServerStorage.HumanlikeNpc.ChatStyle)

	local function tidyVoice(profile)
		return {
			profile = profile or "pc",
			typoRate = 0,
			stretchChance = 0,
			capsChance = 0,
			truncateChance = 0,
			charsPerSecond = 2,
			hesitation = 0,
			tagChance = 0,
		}
	end

	T.describe("ChatStyle", function()
		T.it("fills slots and drops placeholders it cannot fill", function()
			local rng = Rng.new(1)
			T.equal(ChatStyle.render("hi {name}", tidyVoice(), rng, { name = "Milo" }), "hi Milo")
			T.equal(ChatStyle.render("hi {name}", tidyVoice(), rng), "hi")
			T.equal(ChatStyle.render("{name} come here", tidyVoice(), rng), "come here")
		end)

		T.it("typos are adjacent keys, drops or swaps, at most two per message", function()
			local rng = Rng.new(2)
			local changed = 0
			for _ = 1, 500 do
				local out = ChatStyle.typos("anyone wanna be friends", rng, 0.05)
				if out ~= "anyone wanna be friends" then
					changed += 1
					local words = string.split(out, " ")
					T.check(#words == 4, `word count changed: {out}`)
					T.check(#out >= 20 and #out <= 23, `length drifted: {out}`)
				end
			end
			T.between(changed / 500, 0.4, 0.95, "typo frequency at 5% per character")
			T.equal(ChatStyle.typos("hi", rng, 0.5), "hi", "short words are left alone")
		end)

		T.it("stretches a vowel or the last letter", function()
			local rng = Rng.new(3)
			local seen = {}
			for _ = 1, 200 do
				local out = ChatStyle.stretch("hi", rng)
				seen[out] = true
				T.check(string.match(out, "^hi+$") ~= nil, `bad stretch {out}`)
				T.check(#out > 2 and #out <= 6)
			end
			T.check(seen["hiii"] or seen["hii"], "common forms appear")
			local no = ChatStyle.stretch("no", rng)
			T.check(string.match(no, "^no+$") ~= nil, `bad stretch {no}`)
		end)

		T.it("truncates a few trailing characters only on longer messages", function()
			local rng = Rng.new(4)
			T.equal(ChatStyle.truncate("hi", rng), "hi")
			for _ = 1, 100 do
				local out = ChatStyle.truncate("anyone wanna trade", rng)
				T.check(#out >= 13 and #out <= 17, `truncate length {#out}`)
				T.check(string.sub("anyone wanna trade", 1, #out) == out, "must be a prefix")
			end
		end)

		T.it("tags every non-space character and knows what is eligible", function()
			T.equal(ChatStyle.tagged("hi 2013"), "## ####")
			T.check(ChatStyle.isTagEligible("my number is 2013"))
			T.check(ChatStyle.isTagEligible("anyone tradingggggg"))
			T.check(not ChatStyle.isTagEligible("hi"))
		end)

		T.it("mobile profiles capitalise the first letter about half the time, pc never", function()
			local rng = Rng.new(5)
			local mobile, pc = tidyVoice("mobile"), tidyVoice("pc")
			local caps = 0
			for _ = 1, 400 do
				local out = ChatStyle.render("can i have a pet", mobile, rng)
				if string.sub(out, 1, 1) == "C" then
					caps += 1
					T.check(string.find(out, " I ", 1, true) ~= nil, `mobile caps should also fix i: {out}`)
				end
				T.equal(ChatStyle.render("can i have a pet", pc, rng), "can i have a pet")
			end
			T.between(caps / 400, 0.4, 0.7, "mobile capitalisation share")
		end)

		T.it("all caps and tagging follow their chances", function()
			local rng = Rng.new(6)
			local voice = tidyVoice("pc")
			voice.capsChance = 0.5
			voice.tagChance = 0.5
			local caps, tags = 0, 0
			for _ = 1, 400 do
				local out = ChatStyle.render("lets go 2013", voice, rng)
				if out == "LETS GO 2013" then
					caps += 1
				elseif out == "#### ## ####" then
					tags += 1
				end
			end
			T.between(caps / 400, 0.15, 0.35)
			T.between(tags / 400, 0.4, 0.6)
		end)

		T.it("typing time grows with length and never beats 1.5 seconds for real words", function()
			local rng = Rng.new(7)
			local voice = tidyVoice("pc")
			local short, long = 0, 0
			for _ = 1, 300 do
				local a = ChatStyle.typingSeconds("hi", voice, rng, true)
				local b = ChatStyle.typingSeconds("can i have a pet pls im poor", voice, rng, true)
				T.check(a >= 1.5, "minimum latency")
				short += a
				long += b
			end
			T.check(long / 300 > short / 300 + 8, "28 characters at 2 cps take much longer than 2")
			T.check(ChatStyle.typingSeconds("k", voice, rng) > 0.5, "one character still needs a moment")
		end)

		T.it("voices are stable per seed and vary with skill and device", function()
			local a = ChatStyle.voice(Rng.new(9), "pc", 0.8, 0.3)
			local b = ChatStyle.voice(Rng.new(9), "pc", 0.8, 0.3)
			T.equal(a.charsPerSecond, b.charsPerSecond)
			local young = ChatStyle.voice(Rng.new(9), "mobile", 0.1, 0.8)
			T.check(young.charsPerSecond < a.charsPerSecond, "thumbs and youth type slower")
			T.check(young.typoRate > a.typoRate, "and make more typos")
		end)
	end)
end

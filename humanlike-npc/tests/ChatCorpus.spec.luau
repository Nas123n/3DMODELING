return function(T, Loader)
	local session = Loader.new()
	local ChatCorpus = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.ChatCorpus)
	local Safety = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Safety)

	-- The three slots as the composer fills them, so the static text can be judged by the gate.
	local function filled(text: string): string
		local out = string.gsub(text, "{name}", "Zoe")
		out = string.gsub(out, "{echo}", "hiii")
		out = string.gsub(out, "{poi}", "the shop")
		return out
	end

	T.describe("ChatCorpus", function()
		T.it("has a few hundred lines spread over every category", function()
			T.check(ChatCorpus.count() >= 400, `only {ChatCorpus.count()} lines`)
			for _, category in ChatCorpus.CATEGORIES do
				if category ~= "game" then
					T.check(#ChatCorpus.byCategory(category) >= 1, `category {category} is empty`)
				end
			end
		end)

		T.it("keeps every built-in line short, lowercase-leaning and policy-safe", function()
			local uppercaseStarts = 0
			for _, line in ChatCorpus.lines do
				T.check(ChatCorpus.isSafeLine(line.text), `unsafe line: {line.text}`)
				T.check(#line.text <= 60, `too long: {line.text}`)
				local first = string.sub(line.text, 1, 1)
				if first ~= string.lower(first) then
					uppercaseStarts += 1
				end
				T.check(not string.find(line.text, "%.$") or #line.text <= 3, `terminal period: {line.text}`)
			end
			-- A handful of shouted lines is normal; most start lowercase.
			T.check(uppercaseStarts / ChatCorpus.count() < 0.05, "too many capitalised lines")
		end)

		T.it("marks lines that need a name and lines that are replies", function()
			local needsName, replies = 0, 0
			for _, line in ChatCorpus.lines do
				if string.find(line.text, "{name}", 1, true) then
					T.check(ChatCorpus.hasTag(line, "needsName"), `{line.text} uses a name without the needsName tag`)
				end
				if ChatCorpus.hasTag(line, "needsName") then
					needsName += 1
					T.check(
						string.find(line.text, "{name}", 1, true) ~= nil,
						`{line.text} tagged needsName without a slot`
					)
				end
				if ChatCorpus.hasTag(line, "reply") then
					replies += 1
				end
			end
			T.check(needsName >= 10 and replies >= 50, "tags present")
		end)

		T.it("rejects unsafe extensions and accepts safe ones", function()
			local before = #ChatCorpus.byCategory("game")
			T.equal(
				ChatCorpus.extend(
					"game",
					{ "go to the volcano area", "join my discord", "free robux here", string.rep("a", 61) }
				),
				1
			)
			T.equal(#ChatCorpus.byCategory("game"), before + 1)
			T.check(not ChatCorpus.isSafeLine("visit www.example.com"))
			T.check(not ChatCorpus.isSafeLine("#hashtag"))
			T.check(ChatCorpus.isSafeLine("### ##"), "tagged-looking lines are allowed")
		end)

		T.it("rejects trading, begging, friend requests, off-platform contact, age and location", function()
			for _, bad in
				{
					"anyone trading",
					"trade me ur pet",
					"wfl?",
					"can i have a pet pls",
					"give me ur coins",
					"im poor pls",
					"free pets here",
					"1000 robux for it",
					"anyone wanna be friends",
					"add me",
					"friend me pls",
					"add me on snap",
					"whats ur insta",
					"my discord is open",
					"text me",
					"how old r u",
					"im 9 years old",
					"whats ur age",
					"where do u live",
					"i live in a big city",
					"what country r u from",
					"i have school tmrw",
					"meet me at the park",
					"date me",
				}
			do
				T.check(not ChatCorpus.isSafeLine(bad), `accepted: {bad}`)
			end
			for _, good in { "anyone wanna race", "come to the shop", "follow me ill show u", "meet at the top" } do
				T.check(ChatCorpus.isSafeLine(good), `rejected: {good}`)
			end
		end)

		T.it("corpus size and tags", function()
			T.check(ChatCorpus.count() >= 600, `only {ChatCorpus.count()} lines`)
			local gate = Safety.new()
			local helpSub = { ["help.vague"] = 0, ["help.wrong"] = 0, ["help.right"] = 0 }
			local tagCounts = {}
			for _, category in ChatCorpus.CATEGORIES do
				local bucket = ChatCorpus.byCategory(category)
				-- "game" belongs to the developer: the composer skips it while empty and Mind.spec pins that.
				if category ~= "game" then
					T.check(#bucket >= 12, `category {category} has only {#bucket} lines`)
				end
				local seen = {}
				for _, line in bucket do
					local text = line.text
					T.check(not seen[text], `duplicate in {category}: {text}`)
					seen[text] = true
					T.check(ChatCorpus.isSafeLine(text), `unsafe: {text}`)
					local rendered = filled(text)
					T.check(string.match(rendered, Safety.CHARSET) ~= nil, `charset: {text}`)
					T.check(gate:reason(rendered) == nil, `gate rejects {text}: {gate:reason(rendered)}`)
					T.check(not string.find(rendered, "{", 1, true), `unknown slot in {text}`)
					for _, tag in line.tags or {} do
						tagCounts[tag] = (tagCounts[tag] or 0) + 1
					end
					local hasPoi = string.find(text, "{poi}", 1, true) ~= nil
					T.equal(ChatCorpus.hasTag(line, "poi"), hasPoi, `poi tag and slot disagree: {text}`)
					local hasName = string.find(text, "{name}", 1, true) ~= nil
					T.equal(ChatCorpus.hasTag(line, "needsName"), hasName, `name tag and slot disagree: {text}`)
					if ChatCorpus.hasTag(line, "right") then
						T.check(
							string.match(text, "%f[%w]right%??$") ~= nil,
							`right line does not end in right: {text}`
						)
					end
					if ChatCorpus.hasTag(line, "mobile") then
						T.check(#text <= 16, `mobile line too long: {text}`)
						T.equal(text, string.lower(text), `mobile line not lowercase: {text}`)
						T.check(not string.find(text, "%p"), `mobile line has punctuation: {text}`)
					end
					local dialects = 0
					for _, dialect in { "kid", "teen", "older" } do
						if ChatCorpus.hasTag(line, dialect) then
							dialects += 1
						end
					end
					T.check(dialects <= 1, `more than one dialect: {text}`)
					if ChatCorpus.hasTag(line, "multi") then
						local parts = line.parts
						T.check(parts ~= nil and #parts == 2, `multi without two parts: {text}`)
						T.equal(table.concat(parts, " "), text, `multi text is not its parts joined: {text}`)
					else
						T.check(line.parts == nil, `parts on a line without multi: {text}`)
					end
					if category == "help" then
						local subs = 0
						for sub in helpSub do
							if ChatCorpus.hasTag(line, sub) then
								subs += 1
								helpSub[sub] += 1
							end
						end
						T.equal(subs, 1, `help line needs exactly one sub-tag: {text}`)
						if ChatCorpus.hasTag(line, "help.right") then
							T.check(hasPoi, `help.right without a poi slot: {text}`)
						end
					end
					if category == "probe" then
						T.check(
							ChatCorpus.hasTag(line, "probe") and ChatCorpus.hasTag(line, "reply"),
							`probe tags: {text}`
						)
					end
				end
			end
			for sub, n in helpSub do
				T.check(n >= 6, `{sub} has only {n} lines`)
			end
			for _, tag in
				{ "reply", "needsName", "rude", "mobile", "probe", "multi", "kid", "teen", "older", "right", "poi" }
			do
				T.check((tagCounts[tag] or 0) >= 6, `tag {tag} is used {tagCounts[tag] or 0} times`)
			end
		end)
	end)
end

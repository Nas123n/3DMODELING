return function(T, Loader)
	local session = Loader.new()
	local ChatCorpus = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.ChatCorpus)

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
			T.equal(
				ChatCorpus.extend(
					"game",
					{ "go to the volcano area", "join my discord", "free robux here", string.rep("a", 61) }
				),
				1
			)
			T.equal(#ChatCorpus.byCategory("game"), 1)
			T.check(not ChatCorpus.isSafeLine("visit www.example.com"))
			T.check(not ChatCorpus.isSafeLine("#hashtag"))
			T.check(ChatCorpus.isSafeLine("### ##"), "tagged-looking lines are allowed")
		end)
	end)
end

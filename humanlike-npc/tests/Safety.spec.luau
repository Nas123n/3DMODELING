return function(T, Loader)
	local session = Loader.new()
	local Safety = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Safety)

	T.describe("Safety", function()
		T.it("accepts plain chat and rejects empty, long and off-charset text", function()
			local gate = Safety.new()
			for _, ok in { "hi", "can i have a pet pls", "how do u get to the next area", "lol", "### ##", "gg :)" } do
				T.check(gate:check(ok), `should accept: {ok}`)
				T.equal(gate:reason(ok), nil, `no reason for: {ok}`)
			end
			T.check(gate:check(string.rep("a", 120)), "120 chars is the cap")
			T.equal(gate:reason(string.rep("a", 121)), "too long")
			T.equal(gate:reason(""), "empty")
			T.equal(gate:reason("hola señor"), "charset")
			T.equal(gate:reason("hi\0there"), "charset")
			T.equal(gate:reason("<b>hi</b>"), "charset")
			T.equal(gate:reason("wow, that's (really) cool-ish: yes! #1?"), nil, "every charset punctuation")
			T.equal(gate.rejected, 0, "reason alone does not count")
			T.check(not gate:check(""))
			T.check(not gate:check("hola señor"))
			T.equal(gate.rejected, 2)
		end)

		T.it("blocks personal information, off-platform, money, dating and lures", function()
			local gate = Safety.new()
			for _, bad in
				{
					"add me on discord",
					"whats ur age",
					"how old are u",
					"free robux",
					"visit www.site.com",
					"kys",
					"do u have a gf",
					"join my group",
					"meet me at the park",
					"whats ur phone number",
					"ill give u 2 back",
					"FREE ROBUX",
					"add my snapchat",
				}
			do
				local reason = gate:reason(bad)
				T.check(reason ~= nil and string.sub(reason, 1, 8) == "pattern ", `should reject with a pattern: {bad}`)
				T.check(not gate:check(bad), `should reject: {bad}`)
			end
			T.equal(gate:reason("free robux"), "pattern robux")
			T.equal(gate:reason("email me @ home"), "charset", "the charset stops @ before the pattern list")
			T.check(gate:check("a hotdog stand"), "boundary: hotdog is fine")
			T.check(not gate:check("ur hot"), "boundary: hot alone is not")
			T.check(not gate:check("hot dog"), "boundary: hot before a space is not")
			T.check(gate:check("instant win"), "insta needs a boundary")
			T.check(gate:check("a diesel truck"), "die needs a boundary")
			T.check(gate:check("the average is 5"), "age inside a word")
		end)

		T.it("every default pattern is valid and none matches the empty string", function()
			local accepted, rejected = Safety.validatePatterns(Safety.DEFAULT_PATTERNS)
			T.equal(#rejected, 0, table.concat(rejected, ", "))
			T.equal(#accepted, #Safety.DEFAULT_PATTERNS)
			for _, pattern in Safety.DEFAULT_PATTERNS do
				T.equal(string.find("", pattern), nil, `{pattern} matches nothing`)
			end
		end)

		T.it("extra patterns extend the blocklist", function()
			local defaults = #Safety.DEFAULT_PATTERNS
			local gate = Safety.new({ "banana", "^psst" })
			T.equal(gate:reason("i like BANANA bread"), "pattern banana")
			T.check(not gate:check("psst over here"))
			T.check(gate:check("no psst here"))
			T.check(gate:check("hello"))
			T.equal(#gate:rejectedPatterns(), 0)
			T.equal(#gate.patterns, defaults + 2)
			T.equal(#Safety.DEFAULT_PATTERNS, defaults, "the shared default list is not mutated")
		end)

		T.it("invalid patterns are dropped", function()
			local gate = Safety.new({ "%", "ok" })
			local rejected = gate:rejectedPatterns()
			T.equal(#rejected, 1)
			T.equal(rejected[1], "%")
			T.check(gate:check("hello"))
			T.check(not gate:check("ok then"))
			-- The report is a copy; the gate keeps its own list.
			table.insert(rejected, "x")
			T.equal(#gate:rejectedPatterns(), 1)
			local many = Safety.new({ "[a", "%b", "%f", "%1", "(", "a%", "", "a*", ".-", "good" })
			local dropped = many:rejectedPatterns()
			T.equal(#dropped, 9, table.concat(dropped, " | "))
			T.equal(dropped[1], "[a")
			T.equal(dropped[9], ".-")
			T.check(many:check("hello"), "a match-everything pattern must not silence chat")
			T.check(not many:check("good day"))
		end)

		T.it("validatePatterns keeps order and splits accepted from rejected", function()
			local accepted, rejected = Safety.validatePatterns({ "one", "%", "two", "", "three", "x*" })
			T.equal(table.concat(accepted, ","), "one,two,three")
			T.equal(table.concat(rejected, ","), "%,,x*")
			local none, bad = Safety.validatePatterns({})
			T.equal(#none, 0)
			T.equal(#bad, 0)
		end)

		T.it("a pattern that only fails on real text never raises inside check", function()
			-- Passes the construction probe (anchored, never reaches the trailing %) but errors once
			-- the text starts with zzz.
			local gate = Safety.new({ "^zzz%", "^zz%" })
			T.equal(#gate:rejectedPatterns(), 0)
			T.check(gate:check("hi there"), "unrelated text is fine")
			local ok, result = pcall(function()
				return gate:check("zzz hi")
			end)
			T.check(ok, `check raised: {tostring(result)}`)
			T.equal(result, true, "the broken pattern is dropped, not treated as a hit")
			local rejected = gate:rejectedPatterns()
			T.equal(#rejected, 2, table.concat(rejected, " | "))
			T.equal(rejected[1], "^zzz%")
			T.equal(rejected[2], "^zz%")
			T.equal(#gate.patterns, #Safety.DEFAULT_PATTERNS, "dropped for good")
			T.check(gate:check("zzz again"))
			T.equal(#gate:rejectedPatterns(), 2, "reported once")
			-- Ordinary rejections still work after a drop.
			T.check(not gate:check("zzz free robux"))
		end)

		T.it("keeps an audit ring, most recent first", function()
			local gate = Safety.new(nil, 3)
			T.equal(#gate:log(), 0)
			gate:record("n1", "greeting:hi", "hi", 1)
			gate:record("n1", "greeting:hey", "hey", 2, "p:100")
			local two = gate:log()
			T.equal(#two, 2)
			T.equal(two[1].text, "hey")
			T.equal(two[1].npcId, "n1")
			T.equal(two[1].lineId, "greeting:hey")
			T.equal(two[1].at, 2)
			T.equal(two[1].target, "p:100")
			T.equal(two[2].target, nil)
			gate:record("n2", "reaction:lol", "lol", 3)
			gate:record("n2", "reaction:bruh", "bruh", 4)
			local log = gate:log()
			T.equal(#log, 3, "capacity 3 overwrites the oldest")
			T.equal(log[1].text, "bruh")
			T.equal(log[2].text, "lol")
			T.equal(log[3].text, "hey")
			local limited = gate:log(2)
			T.equal(#limited, 2)
			T.equal(limited[2].text, "lol")
			gate:record("n3", nil, "wrap", 5)
			gate:record("n3", nil, "wrap2", 6)
			local wrapped = gate:log()
			T.equal(#wrapped, 3)
			T.equal(wrapped[1].text, "wrap2")
			T.equal(wrapped[3].text, "bruh")
			T.equal(wrapped[2].lineId, nil)
			local big = Safety.new()
			for i = 1, 520 do
				big:record("n1", nil, `line {i}`, i)
			end
			local full = big:log()
			T.equal(#full, 500, "default capacity")
			T.equal(full[1].text, "line 520")
			T.equal(full[500].text, "line 21")
		end)

		T.it("kill switch drops everything and counts rejections", function()
			local gate = Safety.new()
			T.check(gate:check("hi"))
			T.equal(gate.rejected, 0)
			gate:setEnabled(false)
			T.equal(gate:reason("hi"), "disabled")
			T.check(not gate:check("hi"))
			T.check(not gate:check("free robux"))
			T.equal(gate.rejected, 2)
			gate:setEnabled(true)
			T.check(gate:check("hi"))
			T.check(not gate:check("free robux"))
			T.equal(gate.rejected, 3)
		end)
	end)
end

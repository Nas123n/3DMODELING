return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Safety = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Safety)
	local Recency = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Recency)
	local Composer = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.Composer)
	local ChatCorpus = session.require(session.game.ServerStorage.HumanlikeNpc.Chat.ChatCorpus)

	-- Tagged lines in categories of their own: the spontaneous mix never picks them and no other
	-- suite composes from them (each session loads its own corpus anyway).
	local CAT = "composerspec"
	local HELP = "composerspechelp"
	local ALL = CAT .. ":composer spec line for everyone"
	local KID = CAT .. ":composer spec kid line"
	local TEEN = CAT .. ":composer spec teen line"
	local OLDER = CAT .. ":composer spec older line"
	local POI = CAT .. ":composer spec its near the {poi}"
	local POI_SLOT = CAT .. ":composer spec look for the {poi} over there"
	local RIGHT = CAT .. ":composer spec thats the way right"
	local RUDE = CAT .. ":composer spec rude line"

	T.equal(ChatCorpus.extend(CAT, { "composer spec line for everyone" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec kid line" }, { "kid" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec teen line" }, { "teen" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec older line" }, { "older" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec its near the {poi}" }, { "poi" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec look for the {poi} over there" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec thats the way right" }, { "right" }), 1)
	T.equal(ChatCorpus.extend(CAT, { "composer spec rude line" }, { "rude" }), 1)
	T.equal(
		ChatCorpus.extend(
			HELP,
			{ "composer help idk somewhere over there", "composer help no clue sorry" },
			{ "help.vague" }
		),
		2
	)
	T.equal(
		ChatCorpus.extend(
			HELP,
			{ "composer help its behind spawn", "composer help go left at the start" },
			{ "help.wrong" }
		),
		2
	)
	T.equal(
		ChatCorpus.extend(
			HELP,
			{ "composer help its at the {poi}", "composer help go to the {poi}" },
			{ "help.right", "poi" }
		),
		2
	)

	-- A voice that renders text verbatim, so lines can be matched by id and text.
	local VOICE = {
		profile = "pc",
		typoRate = 0,
		stretchChance = 0,
		capsChance = 0,
		truncateChance = 0,
		charsPerSecond = 2,
		hesitation = 0,
		tagChance = 0,
	}

	local function ctx(overrides)
		local c = { npcId = "n1", voice = VOICE, rng = Rng.new(6), now = 0, accountAge = 0.3, category = CAT }
		for k, v in overrides or {} do
			c[k] = v
		end
		return c
	end

	-- Composes n times (fresh recency and a seeded rng each time) and counts picks by line id.
	local function tally(overrides, n)
		local counts, last = {}, {}
		local safety = Safety.new()
		for i = 1, n do
			local o = { rng = Rng.new(i), now = i * 100 }
			for k, v in overrides do
				o[k] = v
			end
			local out = Composer.compose(ctx(o), Recency.new(), safety)
			if out then
				T.check(not string.find(out.text, "{", 1, true), `unfilled slot in {out.text}`)
				counts[out.lineId] = (counts[out.lineId] or 0) + 1
				last[out.lineId] = out
			end
		end
		return counts, last
	end

	T.describe("Composer", function()
		T.it("dialect-tagged line only for that dialect", function()
			local kid = tally({ dialect = "kid" }, 200)
			T.check((kid[KID] or 0) > 0, "kid line for kids")
			T.equal(kid[TEEN], nil, "no teen line for kids")
			T.equal(kid[OLDER], nil, "no older line for kids")

			local teen = tally({ dialect = "teen" }, 200)
			T.check((teen[TEEN] or 0) > 0, "teen line for teens")
			T.equal(teen[KID], nil)
			T.equal(teen[OLDER], nil)

			local older = tally({ dialect = "older" }, 200)
			T.check((older[OLDER] or 0) > 0, "older line for older players")
			T.equal(older[KID], nil)
			T.equal(older[TEEN], nil)

			-- Without a dialect nothing is narrowed: the landed callers passed none and keep working.
			local any = tally({}, 200)
			T.check((any[KID] or 0) > 0 and (any[TEEN] or 0) > 0 and (any[OLDER] or 0) > 0, "no dialect, no filter")
		end)

		T.it("poi line needs poiWord and gets it substituted", function()
			local without = tally({}, 200)
			T.equal(without[POI], nil, "poi-tagged line without a poi word")
			T.equal(without[POI_SLOT], nil, "a {poi} slot without the tag still needs the word")

			local with, last = tally({ poiWord = "fountain" }, 200)
			T.check((with[POI] or 0) > 0, "poi line with a poi word")
			T.check((with[POI_SLOT] or 0) > 0, "slot-only line with a poi word")
			T.equal(last[POI].text, "composer spec its near the fountain")
			T.equal(last[POI_SLOT].text, "composer spec look for the fountain over there")
			T.equal(last[POI].category, CAT)
		end)

		T.it("right-tagged line needs allowRight", function()
			local without, lastWithout = tally({}, 200)
			T.equal(without[RIGHT], nil, "no right line unless allowed")
			for _, out in lastWithout do
				T.check(not out.right, `right flag on {out.lineId}`)
			end

			local with, last = tally({ allowRight = true }, 200)
			T.check((with[RIGHT] or 0) > 0, "right line when allowed")
			T.check(last[RIGHT].right, "the composed line reports the right tag")
			T.check(not last[ALL].right, "an untagged line does not")
		end)

		T.it("untagged lines for everyone", function()
			for _, dialect in { "kid", "teen", "older", false } do
				local counts = tally({ dialect = dialect or nil }, 200)
				T.check((counts[ALL] or 0) > 0, `untagged line for {tostring(dialect)}`)
			end
			-- Rude stays hidden unless allowed, and is flagged when it shows.
			local hidden = tally({ dialect = "teen" }, 200)
			T.equal(hidden[RUDE], nil, "rude hidden by default")
			local shown, last = tally({ dialect = "teen", allowRude = true }, 200)
			T.check((shown[RUDE] or 0) > 0, "rude shown when allowed")
			T.check(last[RUDE].rude, "the composed line reports the rude tag")
			T.check(not last[ALL].rude)
		end)

		T.it("help sub-tags share 60 25 15 and help.right needs knowsPoi", function()
			local n = 2000
			local function shares(overrides)
				local counts = tally(overrides, n)
				local vague, wrong, right, total = 0, 0, 0, 0
				for id, c in counts do
					total += c
					if string.find(id, "idk", 1, true) or string.find(id, "no clue", 1, true) then
						vague += c
					elseif string.find(id, "{poi}", 1, true) then
						right += c
					else
						wrong += c
					end
				end
				T.equal(total, n, "every compose produced a line")
				return vague / n, wrong / n, right / n
			end

			local vague, wrong, right = shares({ category = HELP, poiWord = "fountain", knowsPoi = true })
			T.near(vague, 0.6, 0.03, "vague share")
			T.near(wrong, 0.25, 0.03, "wrong share")
			T.near(right, 0.15, 0.03, "right share")

			vague, wrong, right = shares({ category = HELP, poiWord = "fountain" })
			T.equal(right, 0, "help.right needs knowsPoi")
			T.near(vague, 60 / 85, 0.03, "vague share without right lines")
			T.near(wrong, 25 / 85, 0.03, "wrong share without right lines")

			vague, wrong, right = shares({ category = HELP, knowsPoi = true })
			T.equal(right, 0, "help.right lines carry {poi} and need the word too")
		end)

		T.it("same seed, same words", function()
			local safety = Safety.new()
			local a = Composer.compose(
				ctx({ rng = Rng.new(3), poiWord = "fountain", allowRight = true }),
				Recency.new(),
				safety
			)
			local b = Composer.compose(
				ctx({ rng = Rng.new(3), poiWord = "fountain", allowRight = true }),
				Recency.new(),
				safety
			)
			T.check(a ~= nil and b ~= nil)
			T.equal(a.text, b.text)
			T.equal(a.lineId, b.lineId)
			T.equal(Composer.SPONTANEOUS.game, 14)
		end)
	end)
end

return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Names = session.require(session.game.ServerStorage.HumanlikeNpc.Identity.Names)

	T.describe("Names", function()
		T.it("validates usernames like Roblox does", function()
			T.check(Names.isValidUsername("coolgamer2013"))
			T.check(Names.isValidUsername("Milo_2014"))
			T.check(not Names.isValidUsername("ab"), "too short")
			T.check(not Names.isValidUsername(string.rep("a", 21)), "too long")
			T.check(not Names.isValidUsername("_milo"), "leading underscore")
			T.check(not Names.isValidUsername("milo_"), "trailing underscore")
			T.check(not Names.isValidUsername("mi_lo_x"), "two underscores")
			T.check(not Names.isValidUsername("milo zoe"), "space")
			T.check(not Names.isValidUsername("milo-zoe"), "hyphen")
		end)

		T.it("bans names that expose scripted characters or impersonate known people", function()
			for _, bad in
				{
					"NPC_7",
					"botman",
					"Player12",
					"player_3",
					"TestUser",
					"Guest1337",
					"RobloxFan",
					"Admin99",
					"xXDanTDMXx",
					"n_p_c_1",
				}
			do
				T.check(Names.isBanned(bad), `{bad} should be banned`)
			end
			T.check(not Names.isBanned("coolgamer2013"))
			T.check(not Names.isBanned("multiplayerfan"), "'player' inside a word is fine")
		end)

		T.it("generates valid, unbanned names deterministically per seed", function()
			local a, b = Names.generate(Rng.new(42)), Names.generate(Rng.new(42))
			T.equal(a.username, b.username)
			T.equal(a.displayName, b.displayName)
			local rng = Rng.new(7)
			for _ = 1, 2000 do
				local name = Names.generate(rng)
				T.check(Names.isValidUsername(name.username), `invalid username {name.username}`)
				T.check(not Names.isBanned(name.username), `banned username {name.username}`)
				T.check(Names.isValidDisplayName(name.displayName), `invalid display name "{name.displayName}"`)
			end
		end)

		T.it("follows the family mix and every family produces valid names", function()
			local rng = Rng.new(99)
			local counts = {}
			local n = 4000
			for _ = 1, n do
				local name = Names.generate(rng)
				counts[name.family] = (counts[name.family] or 0) + 1
			end
			local total = 0
			for _, family in Names.FAMILIES do
				total += family.weight
			end
			for _, family in Names.FAMILIES do
				local expected = family.weight / total
				local got = (counts[family.key] or 0) / n
				T.between(got, expected * 0.7, expected * 1.3, `family {family.key} share`)
				for _ = 1, 50 do
					local name = Names.generate(rng, family.key)
					T.equal(name.family, family.key)
					T.check(Names.isValidUsername(name.username), `invalid {family.key} name {name.username}`)
				end
			end
		end)

		T.it("keeps display names short and mostly different from usernames", function()
			local rng = Rng.new(3)
			local same, n = 0, 1000
			for _ = 1, n do
				local name = Names.generate(rng)
				if name.displayName == name.username then
					same += 1
				end
				T.check(#name.displayName <= 20)
			end
			T.between(same / n, 0.12, 0.3, "share of display names equal to the username")
		end)

		T.it("pools hand out unique names and honour reservations", function()
			local pool = Names.newPool(Rng.new(5), { "TakenName" })
			local seen = {}
			for _ = 1, 500 do
				local name = pool:take()
				local key = string.lower(name.username)
				T.check(not seen[key], `duplicate {name.username}`)
				seen[key] = true
				T.check(key ~= "takenname")
			end
			pool:reserve("coolgamer2013")
			for _ = 1, 200 do
				T.check(string.lower(pool:take().username) ~= "coolgamer2013")
			end
		end)

		-- Seeded suites elsewhere rely on this sequence; extensions must draw after it or on new paths only.
		T.it("keeps the landed draw order per seed", function()
			local pinned = {
				[1] = {
					"yeetninja|yeetninja",
					"braveotter2016|Tiny Pizza",
					"Cosmicpanda2|Cosmicpanda2",
					"jack_2013|jack",
				},
				[42] = { "LexiPlays|Jack", "cutehunter56|cat", "susdragon|Tyler", "iamghost|Nina" },
				[1234] = { "FrogGamingTTV|Evan", "MiaYT|MiaYT", "sup3rpro|bruh nova", "2013_Evan|Evan" },
			}
			for seed, expected in pinned do
				local rng = Rng.new(seed)
				for i, want in expected do
					local name = Names.generate(rng)
					T.equal(`{name.username}|{name.displayName}`, want, `seed {seed} name {i}`)
				end
			end
			local pool = Names.newPool(Rng.new(5), { "TakenName" })
			local got = {}
			for _ = 1, 5 do
				table.insert(got, pool:take().username)
			end
			T.equal(table.concat(got, " "), "turbopizza_2012 FluffyGamer SwiftKnightKing 5uper_t4co turbosky_2010")
		end)

		T.it("bans well-known creator and streamer handle stems", function()
			for _, bad in
				{
					"mrflimflam",
					"FunnehFan",
					"KreekFan_2013",
					"MrBeast6000",
					"LankyBox1",
					"SharkBloxYT",
					"IShowSpeed",
					"jelly_2011",
					"xXTechnobladeXx",
					"aphmau_lover",
					"rblx_kai",
					"Sanna_fan",
				}
			do
				T.check(Names.isBanned(bad), `{bad} should be banned`)
			end
			for _, ok in { "coolgamer2013", "lunarsalad2013", "HyperStar4578", "jadeplays", "KaiBuilds" } do
				T.check(not Names.isBanned(ok), `{ok} should be allowed`)
			end
		end)

		T.it("preferred names come first", function()
			local preferred = { " Studio_AltOne ", "studioalttwo", "bad name!", "STUDIO_ALTONE", "ab" }
			local pool = Names.newPool(Rng.new(5), { "TakenName" }, preferred)
			local first = pool:take()
			T.equal(first.username, "Studio_AltOne")
			T.equal(first.displayName, "Studio AltOne")
			T.equal(first.family, Names.PREFERRED_FAMILY)
			T.check(Names.isValidDisplayName(first.displayName))
			local second = pool:take()
			T.equal(second.username, "studioalttwo")
			T.equal(second.displayName, "studioalttwo")
			-- The invalid and duplicate entries were ignored; generated names follow and consume the same
			-- draws as a pool without preferred names.
			local plain = Names.newPool(Rng.new(5), { "TakenName" })
			for i = 1, 20 do
				local a, b = pool:take(), plain:take()
				T.check(a.family ~= Names.PREFERRED_FAMILY, `take {i} should be generated`)
				T.equal(a.username, b.username, `take {i} draws as without preferred`)
			end
			-- A released preferred name is preferred again.
			pool:release("studio_altone")
			T.equal(pool:take().username, "Studio_AltOne")
			-- A reservation wins over a preference.
			local reserved = Names.newPool(Rng.new(5), { "StudioAltTwo" }, { "StudioAltTwo", "StudioAltThree" })
			T.equal(reserved:take().username, "StudioAltThree")
			T.check(reserved:take().family ~= Names.PREFERRED_FAMILY)
		end)

		T.it("reject never returns that name again", function()
			local probe = Names.newPool(Rng.new(11))
			local doomed = probe:take().username
			local pool = Names.newPool(Rng.new(11), nil, { "Studio_Alt" })
			pool:reject("studio_alt")
			pool:reject(string.upper(doomed))
			T.check(pool:isRejected("STUDIO_ALT"))
			T.check(pool:isRejected(doomed))
			T.check(not pool:isRejected("someoneelse"))
			for _ = 1, 300 do
				local name = pool:take()
				T.check(string.lower(name.username) ~= "studio_alt", "rejected preferred name came back")
				T.check(string.lower(name.username) ~= string.lower(doomed), "rejected generated name came back")
			end
			-- Release does not undo a rejection, even for a name that was taken before it was rejected.
			local late = Names.newPool(Rng.new(11), nil, { "Studio_Alt" })
			T.equal(late:take().username, "Studio_Alt")
			late:reject("Studio_Alt")
			late:release("Studio_Alt")
			T.check(late:isRejected("Studio_Alt"))
			for _ = 1, 50 do
				T.check(late:take().username ~= "Studio_Alt")
			end
		end)

		T.it("account age biases the family mix without changing the draw count", function()
			local base = Names.familyWeights(nil)
			local young = Names.familyWeights(10)
			local veteran = Names.familyWeights(1000)
			local middle = Names.familyWeights(300)
			for i, family in Names.FAMILIES do
				T.equal(base[i], family.weight, `base weight {family.key}`)
				T.equal(middle[i], family.weight, `middle-aged weight {family.key}`)
			end
			local index = {}
			for i, family in Names.FAMILIES do
				index[family.key] = i
			end
			T.equal(young[index.wordDigits], 60)
			T.equal(young[index.numeric], 12)
			T.equal(young[index.suggested], 15)
			T.equal(young[index.phrase], 3)
			T.equal(veteran[index.lowercaseAesthetic], 24)
			T.equal(veteran[index.phrase], 6)
			T.equal(veteran[index.creatorHandle], 12)
			T.equal(veteran[index.wordDigits], 30)
			-- Observed shares follow the biased weights.
			local rng = Rng.new(2024)
			local counts, n = {}, 4000
			local total = 0
			for _, w in young do
				total += w
			end
			for _ = 1, n do
				local name = Names.generate(rng, nil, 10)
				T.check(Names.isValidUsername(name.username), `invalid username {name.username}`)
				counts[name.family] = (counts[name.family] or 0) + 1
			end
			for i, family in Names.FAMILIES do
				local expected = young[i] / total
				T.between((counts[family.key] or 0) / n, expected * 0.7, expected * 1.3, `young share {family.key}`)
			end
			-- Without an account age the pool and generate draw the landed sequence.
			local a, b = Names.generate(Rng.new(42)), Names.generate(Rng.new(42), nil, nil)
			T.equal(a.username, b.username)
		end)

		T.it("draws birth-year suffixes only for accounts older than 1500 days", function()
			-- Suffix years for the digit families, a leading "2013_" for the numeric family.
			local function yearShare(accountAgeDays: number?, family: string, pattern: string): number
				local rng = Rng.new(77)
				local hits, n = 0, 1500
				for _ = 1, n do
					local name = Names.generate(rng, family, accountAgeDays)
					T.check(Names.isValidUsername(name.username), `invalid username {name.username}`)
					if string.match(name.username, pattern) then
						hits += 1
					end
				end
				return hits / n
			end
			local suffix, prefix = "20[01]%d$", "^20[01]%d_"
			T.between(yearShare(nil, "wordDigits", suffix), 0.3, 0.6, "landed mix keeps the years")
			T.between(yearShare(3000, "wordDigits", suffix), 0.3, 0.6, "veterans keep the years")
			T.between(yearShare(100, "wordDigits", suffix), 0, 0.02, "young accounts get no birth years")
			T.between(yearShare(100, "prefixed", suffix), 0, 0.02, "young prefixed names get no birth years")
			T.between(yearShare(nil, "numeric", prefix), 0.3, 0.7, "landed numeric keeps the years")
			T.equal(yearShare(100, "numeric", prefix), 0, "young numeric names are plain numbers")
		end)
	end)
end

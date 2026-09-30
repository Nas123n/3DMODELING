return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Names = session.require(session.game.ServerStorage.HumanlikeNpc.Names)

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
	end)
end

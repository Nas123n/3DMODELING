return function(T, Loader)
	local session = Loader.new()
	local Rng = session.require(session.game.ServerStorage.HumanlikeNpc.Rng)
	local Personality = session.require(session.game.ServerStorage.HumanlikeNpc.Mind.Personality)

	-- Every field of the landed persona for four seeds, printed with %.17g from the module as it
	-- was before the "persona2" additions. The additions are drawn from a fork taken after the
	-- last of these draws, so none of them may move by a bit.
	local PINNED = {
		{
			seed = 1,
			aboutFaceRate = 0.059742580815388684,
			accountAge = 0.84178697501033817,
			afkProneness = 0.93844096608181538,
			attention = 0.77933150969131171,
			caution = 0.60503980686515169,
			chattiness = 0.10852258766138001,
			curiosity = 0.34531767072910963,
			dialect = "older",
			emoteHabit = 0.10259147708045324,
			friendliness = 0.29691936323080009,
			helpfulness = 0.25587765925695966,
			impulsivity = 0.35346544021983822,
			jumpTier = "occasional",
			jumpiness = 0.5063633736176183,
			mirroring = 0.4223204803551544,
			missChance = 0.14413369806173768,
			patience = 0.60503980686515169,
			profile = {
				analog = false,
				camLag = 0.15910247162253299,
				camRateDegPerS = 66.87518696533516,
				hesitationScale = 1,
				jumpRateScale = 1,
				kind = "pc",
				lookahead = 4,
				microStopMean = 0,
				microStopMedianDur = 0,
				quantize8 = true,
				strafes = false,
				tremorSigma = 0,
				typingFreezes = true,
				walksBack = true,
				wobbleAmpDeg = 0,
				wobbleHz = 0,
			},
			reactionScale = 0.91620054709260645,
			sessionLength = 685.10150622578578,
			skill = 0.86144977253830879,
			sociability = 0.17162822711415621,
			stopBiasStuds = 0.65205423492698034,
			trolliness = 0.18758612794524587,
			voice = {
				capsChance = 0.032000000000000001,
				charsPerSecond = 3.535273549577687,
				hesitation = 0.24500000000000002,
				profile = "pc",
				stretchChance = 0.087999999999999995,
				tagChance = 0.035999999999999997,
				truncateChance = 0.030000000000000002,
				typoRate = 0.020750000000000001,
			},
			walkSpeed = 16,
			wallBumpRate = 0.012771004549233824,
		},
		{
			seed = 2,
			aboutFaceRate = 0.054585428940386566,
			accountAge = 0.31359675211323845,
			afkProneness = 0.64668217479797108,
			attention = 0.76554715144733032,
			caution = 0.78692574661245684,
			chattiness = 0.1206859524556112,
			curiosity = 0.9712639187721499,
			dialect = "kid",
			emoteHabit = 0.19513853721920904,
			friendliness = 0.56054785875183488,
			helpfulness = 0.50250966104834927,
			impulsivity = 0.27979184200552237,
			jumpTier = "never",
			jumpiness = 0.19138759481795387,
			mirroring = 0.18078495870339978,
			missChance = 0.14689056971053394,
			patience = 0.78692574661245684,
			profile = {
				analog = true,
				camLag = 0,
				camRateDegPerS = 0,
				hesitationScale = 0.59999999999999998,
				jumpRateScale = 0.29999999999999999,
				kind = "mobile",
				lookahead = 8,
				microStopMean = 15.606689753908533,
				microStopMedianDur = 0.15222551079830524,
				quantize8 = false,
				strafes = false,
				tremorSigma = 3.3644949048340278,
				typingFreezes = true,
				walksBack = false,
				wobbleAmpDeg = 6.97665549556163,
				wobbleHz = 3.2663828279966416,
			},
			reactionScale = 1.1964366109355413,
			sessionLength = 969.93869790968961,
			skill = 0.55039940602482007,
			sociability = 0.14046989033260285,
			stopBiasStuds = 0.34775827805529047,
			trolliness = 0.0068420935692964369,
			voice = {
				capsChance = 0.068000000000000005,
				charsPerSecond = 0.8472619911441579,
				hesitation = 0.45500000000000002,
				profile = "mobile",
				stretchChance = 0.17200000000000001,
				tagChance = 0.053999999999999999,
				truncateChance = 0.01,
				typoRate = 0.052000000000000011,
			},
			walkSpeed = 16,
			wallBumpRate = 0.018992011879503598,
		},
		{
			seed = 3,
			aboutFaceRate = 0.046095841234136653,
			accountAge = 0.48845037811965647,
			afkProneness = 0.50967124796053509,
			attention = 0.76349972711119152,
			caution = 0.40275955287394688,
			chattiness = 0.91667677944517856,
			curiosity = 0.074426731368481686,
			dialect = "teen",
			emoteHabit = 0.61820429299062052,
			friendliness = 0.82504167588485966,
			helpfulness = 0.49489537476045886,
			impulsivity = 0.15851201763052356,
			jumpTier = "spammer",
			jumpiness = 0.98549957829549539,
			mirroring = 0.81843305531707444,
			missChance = 0.14730005457776171,
			patience = 0.40275955287394688,
			profile = {
				analog = false,
				camLag = 0.25667334472549619,
				camRateDegPerS = 21.972007604781538,
				hesitationScale = 1,
				jumpRateScale = 1,
				kind = "pc",
				lookahead = 4,
				microStopMean = 0,
				microStopMedianDur = 0,
				quantize8 = true,
				strafes = false,
				tremorSigma = 0,
				typingFreezes = true,
				walksBack = true,
				wobbleAmpDeg = 0,
				wobbleHz = 0,
			},
			reactionScale = 0.92095008186664251,
			sessionLength = 802.29352296216609,
			skill = 0.51663802862015151,
			sociability = 0.017443335262677852,
			stopBiasStuds = 0.83474058910657845,
			trolliness = 0.20086874886843387,
			voice = {
				capsChance = 0.047,
				charsPerSecond = 3.0259377378909846,
				hesitation = 0.33499999999999996,
				profile = "pc",
				stretchChance = 0.12300000000000001,
				tagChance = 0.043499999999999997,
				truncateChance = 0.042500000000000003,
				typoRate = 0.0313125,
			},
			walkSpeed = 16,
			wallBumpRate = 0.019667239427596971,
		},
		{
			seed = "p-1",
			aboutFaceRate = 0.095090149708390428,
			accountAge = 0.11953490508289592,
			afkProneness = 0.3089364876793958,
			attention = 0.70568298968665288,
			caution = 0.38461442723523637,
			chattiness = 0.059678599038757496,
			curiosity = 0.40371403683156992,
			dialect = "kid",
			emoteHabit = 0.26900177903400879,
			friendliness = 0.47630100207528031,
			helpfulness = 0.28256324921845283,
			impulsivity = 0.85843071011986305,
			jumpTier = "occasional",
			jumpiness = 0.62921185515792655,
			mirroring = 0.88017282691525323,
			missChance = 0.15886340206266944,
			patience = 0.38461442723523637,
			profile = {
				analog = false,
				camLag = 0.26656686791435935,
				camRateDegPerS = 34.597901897504926,
				hesitationScale = 1,
				jumpRateScale = 1,
				kind = "pc",
				lookahead = 4,
				microStopMean = 0,
				microStopMedianDur = 0,
				quantize8 = true,
				strafes = false,
				tremorSigma = 0,
				typingFreezes = true,
				walksBack = true,
				wobbleAmpDeg = 0,
				wobbleHz = 0,
			},
			reactionScale = 1.2197836340222055,
			sessionLength = 400.63085804394126,
			skill = 0.55759344061982852,
			sociability = 0.19444748000643372,
			stopBiasStuds = 1.6145842001591195,
			trolliness = 0.43992148771950401,
			voice = {
				capsChance = 0.068000000000000005,
				charsPerSecond = 1.8237992925150319,
				hesitation = 0.45500000000000002,
				profile = "pc",
				stretchChance = 0.17200000000000001,
				tagChance = 0.053999999999999999,
				truncateChance = 0.060000000000000012,
				typoRate = 0.052000000000000011,
			},
			walkSpeed = 16,
			wallBumpRate = 0.01884813118760343,
		},
	}

	-- The optional draws (walk speed boost, session median) sit before the new fork as well.
	local PINNED_SPREAD = {
		{
			seed = 1,
			walkSpeed = 30.601827575815811,
			stopBiasStuds = 0.79471520736971735,
			sessionLength = 2068.5004840339898,
		},
		{ seed = 2, walkSpeed = 16, stopBiasStuds = 0.26530491426140257, sessionLength = 757.28827284265276 },
		{ seed = 6, walkSpeed = 16, stopBiasStuds = -0.15450021840685058, sessionLength = 263.26234224414196 },
		{
			seed = 11,
			walkSpeed = 28.116497702757783,
			stopBiasStuds = 0.98161502867988581,
			sessionLength = 344.99124593497424,
		},
	}

	local ADDED = {
		"sloppiness",
		"restlessness",
		"attachmentProneness",
		"rig",
		"afkStyle",
		"personalSpace",
		"friendSpace",
		"animPack",
		"slangSeed",
		"pointlessTarget",
		"rudenessCap",
		"sitHabit",
		"cameraStyle",
		"presentation",
		"accountAgeDays",
		"familiarity",
	}

	local function sortedKeys(t)
		local keys = {}
		for k in t do
			table.insert(keys, k)
		end
		table.sort(keys)
		return keys
	end

	T.describe("Persona", function()
		T.it("persona additions are deterministic and in range", function()
			local a, b = Personality.sample(Rng.new(7)), Personality.sample(Rng.new(7))
			for _, key in ADDED do
				T.equal(a[key], b[key], key)
			end
			T.equal(a.favoritePoiKind, nil, "the service fills favoritePoiKind, not the persona")

			local packSet = {}
			for _, name in Personality.PACKS do
				packSet[name] = true
			end
			T.equal(#Personality.PACKS, 10)
			T.equal(Personality.PACKS[1], "default")

			local n = 4000
			local r6, semi, defaults = 0, 0, 0
			local cameras, presentations = {}, {}
			local byAge = {}
			for i = 1, n do
				local p = Personality.sample(Rng.new(i))
				if p.rig == "R6" then
					r6 += 1
				else
					T.equal(p.rig, "R15")
				end
				if p.afkStyle == "semi" then
					semi += 1
				else
					T.equal(p.afkStyle, "full")
				end
				T.between(p.sloppiness, 0, 1, "sloppiness")
				T.between(p.restlessness, 0, 1, "restlessness")
				T.between(p.attachmentProneness, 0, 1, "attachmentProneness")
				T.between(p.personalSpace, 4, 8, "personalSpace")
				T.between(p.friendSpace, 1, 3, "friendSpace")
				T.check(packSet[p.animPack], `unknown pack {p.animPack}`)
				if p.animPack == "default" then
					defaults += 1
				end
				T.equal(p.slangSeed, math.floor(p.slangSeed), "slangSeed is an integer")
				T.between(p.slangSeed, 1, 1e6, "slangSeed")
				T.between(p.pointlessTarget, 0.2, 0.6, "pointlessTarget")
				T.equal(p.rudenessCap, if p.trolliness < 0.6 then 0 else 1, "rudenessCap follows trolliness")
				T.between(p.sitHabit, 0, 1, "sitHabit")
				cameras[p.cameraStyle] = (cameras[p.cameraStyle] or 0) + 1
				presentations[p.presentation] = (presentations[p.presentation] or 0) + 1
				T.between(p.accountAgeDays, 3, 3000, "accountAgeDays")
				T.equal(p.accountAgeDays, math.floor(p.accountAgeDays), "accountAgeDays is whole days")
				T.between(p.familiarity, 0, 1, "familiarity")
				T.near(p.familiarity, 1 - math.exp(-p.accountAgeDays / 90), 1e-12, "familiarity formula")
				table.insert(byAge, { p.accountAge, p.familiarity })
			end
			T.between(r6 / n, 0.03, 0.07, `R6 share {r6 / n}`)
			T.between(semi / n, 0.26, 0.34, `semi AFK share {semi / n}`)
			T.between(defaults / n, 0.6, 0.85, `default pack share {defaults / n} (60% base, newcomers x3)`)
			T.between((cameras.sweeper or 0) / n, 0.34, 0.46, "sweeper 40%")
			T.between((cameras.locked or 0) / n, 0.34, 0.46, "locked 40%")
			T.between((cameras.twitchy or 0) / n, 0.15, 0.25, "twitchy 20%")
			T.equal(#sortedKeys(cameras), 3, "exactly three camera styles")
			T.between((presentations.m or 0) / n, 0.39, 0.51, "m 45%")
			T.between((presentations.f or 0) / n, 0.39, 0.51, "f 45%")
			T.between((presentations.any or 0) / n, 0.06, 0.14, "any 10%")
			T.equal(#sortedKeys(presentations), 3, "exactly three presentations")

			table.sort(byAge, function(x, y)
				return x[1] < y[1]
			end)
			for i = 2, #byAge do
				T.check(byAge[i][2] >= byAge[i - 1][2], "familiarity is monotone in accountAge")
			end
		end)

		T.it("rig share follows the r6Share option and pack weights follow the persona", function()
			for i = 1, 300 do
				T.equal(Personality.sample(Rng.new(i), { r6Share = 0 }).rig, "R15", "r6Share 0 never yields R6")
				T.equal(Personality.sample(Rng.new(i), { r6Share = 1 }).rig, "R6", "r6Share 1 always yields R6")
			end

			local base = Personality.packWeights(400, 0.2)
			local newcomer = Personality.packWeights(10, 0.2)
			local troll = Personality.packWeights(400, 0.9)
			T.equal(#base, #Personality.PACKS)
			local total = 0
			for i, name in Personality.PACKS do
				T.equal(base[i], Personality.PACK_WEIGHTS[name], name)
				total += base[i]
				if name == "default" then
					T.equal(newcomer[i], base[i] * 3, "newcomers run the default pack x3")
				else
					T.equal(newcomer[i], base[i], name)
				end
				if name == "zombie" or name == "ninja" then
					T.equal(troll[i], base[i] * 2, `trolls lean to {name}`)
				else
					T.equal(troll[i], base[i], name)
				end
			end
			T.equal(total, 100, "base weights sum to 100")
			T.near(base[1] / total, 0.6, 1e-9, "default is 60% of the base mix")

			-- The bias is visible in the population: newcomers (< 30 days) run "default" far more often.
			local newDefault, newCount, oldDefault, oldCount = 0, 0, 0, 0
			for i = 1, 3000 do
				local p = Personality.sample(Rng.new(i))
				if p.accountAgeDays < 30 then
					newCount += 1
					if p.animPack == "default" then
						newDefault += 1
					end
				else
					oldCount += 1
					if p.animPack == "default" then
						oldDefault += 1
					end
				end
			end
			T.check(newCount > 300 and oldCount > 300, "both groups are well represented")
			T.between(newDefault / newCount, 0.75, 0.9, `newcomer default share {newDefault / newCount}`)
			T.between(oldDefault / oldCount, 0.52, 0.68, `veteran default share {oldDefault / oldCount}`)
		end)

		T.it("existing draws are unchanged by the additions", function()
			for _, pinned in PINNED do
				local p = Personality.sample(Rng.new(pinned.seed))
				for _, key in sortedKeys(pinned) do
					if key == "seed" then
						continue
					end
					local expected = pinned[key]
					if type(expected) == "table" then
						for _, sub in sortedKeys(expected) do
							T.equal(p[key][sub], expected[sub], `seed {pinned.seed} {key}.{sub}`)
						end
					else
						T.equal(p[key], expected, `seed {pinned.seed} {key}`)
					end
				end
			end
			for _, pinned in PINNED_SPREAD do
				local p = Personality.sample(Rng.new(pinned.seed), { walkSpeedSpread = 0.3, sessionMedianMinutes = 20 })
				T.equal(p.walkSpeed, pinned.walkSpeed, `seed {pinned.seed} walkSpeed`)
				T.equal(p.stopBiasStuds, pinned.stopBiasStuds, `seed {pinned.seed} stopBiasStuds`)
				T.equal(p.sessionLength, pinned.sessionLength, `seed {pinned.seed} sessionLength`)
			end
		end)
	end)
end

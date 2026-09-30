return function(T, Loader)
	local fs = require("@lune/fs")
	local roblox = require("@lune/roblox")
	local Instance = roblox.Instance

	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Config = session.require(S.Config)

	local function keysOf(t)
		local keys = {}
		for key in t do
			table.insert(keys, key)
		end
		table.sort(keys)
		return keys
	end

	-- A stand-in for the Bootstrap script carrying attributes.
	local function sourceWith(attributes)
		local source = Instance.new("Script")
		source.Name = "HumanlikeNpcBootstrap"
		for name, value in attributes do
			source:SetAttribute(name, value)
		end
		return source
	end

	T.describe("Config", function()
		T.it("defaults validate", function()
			local problems = Config.validate(Config.DEFAULTS)
			T.equal(#problems, 0, table.concat(problems, "; "))
			local resolved = Config.resolve(nil)
			T.check(resolved ~= Config.DEFAULTS, "resolve returns a copy")
			T.equal(#keysOf(resolved), #keysOf(Config.DEFAULTS), "same keys")
			for _, key in keysOf(Config.DEFAULTS) do
				T.equal(resolved[key], Config.DEFAULTS[key], key)
			end
			T.equal(#Config.lastWarnings, 0)
			T.equal(#Config.validate(resolved), 0)
			-- A few of the checks bite.
			resolved.PopulationMin = 40
			resolved.TierMid = 10
			resolved.ChatServerShare = 1.5
			resolved.PathBudgetMs = 0
			resolved.ChatHook = "legacy"
			local bad = Config.validate(resolved)
			T.check(#bad >= 5, `{#bad} problems: {table.concat(bad, "; ")}`)
			local text = table.concat(bad, "\n")
			T.check(string.find(text, "PopulationMin", 1, true), "min > max reported")
			T.check(string.find(text, "TierNear", 1, true), "tier order reported")
			T.check(string.find(text, "ChatServerShare", 1, true), "share reported")
			T.check(string.find(text, "PathBudgetMs", 1, true), "budget reported")
			T.check(string.find(text, "ChatHook", 1, true), "enum reported")
		end)

		T.it("attribute overlay keeps types", function()
			local source = sourceWith({
				PopulationBase = 9,
				PopulationMax = "lots", -- a string for a number key: ignored and reported
				Debug = true,
				Seed = 42, -- Seed takes a number or a string
				ChatHook = "shared",
				NotAKey = 1, -- unknown: ignored and reported
			})
			local resolved = Config.resolve(source)
			T.equal(resolved.PopulationBase, 9)
			T.equal(resolved.PopulationMax, 30, "wrong type keeps the default")
			T.equal(resolved.Debug, true)
			T.equal(resolved.Seed, 42)
			T.equal(resolved.ChatHook, "shared")
			T.equal(resolved.NotAKey, nil)
			T.equal(Config.DEFAULTS.PopulationBase, 6, "DEFAULTS untouched")
			T.equal(#Config.lastWarnings, 2, table.concat(Config.lastWarnings, "; "))
			T.check(string.find(Config.lastWarnings[1], "NotAKey", 1, true), "unknown name reported first (sorted)")
			T.check(string.find(Config.lastWarnings[2], "PopulationMax", 1, true), "wrong type reported")
			T.check(string.find(Config.lastWarnings[2], "string", 1, true), "the offending type is named")
			-- A later resolve without a source clears the warnings.
			Config.resolve(nil)
			T.equal(#Config.lastWarnings, 0)
		end)

		T.it("HourCurve parses 24 values", function()
			T.equal(Config.hourCurve(""), nil, "flat by default")
			T.equal(Config.population(Config.DEFAULTS).curve, nil)
			local values = {}
			for hour = 0, 23 do
				table.insert(values, tostring(0.5 + hour * 0.1))
			end
			local resolved = Config.resolve(sourceWith({ HourCurve = table.concat(values, ", ") }))
			T.equal(#Config.validate(resolved), 0)
			local curve = Config.population(resolved).curve
			T.check(curve ~= nil, "curve parsed")
			T.equal(#curve, 24)
			T.near(curve[1], 0.5, 1e-9)
			T.near(curve[13], 1.7, 1e-9)
			T.near(curve[24], 2.8, 1e-9)
			-- Wrong count or a non-number: flat, and validate says so.
			T.equal(Config.hourCurve("1,2,3"), nil)
			T.equal(Config.hourCurve(string.rep("1,", 23) .. "x"), nil)
			resolved.HourCurve = "1,2,3"
			T.equal(Config.population(resolved).curve, nil)
			local problems = Config.validate(resolved)
			T.equal(#problems, 1)
			T.check(string.find(problems[1], "HourCurve", 1, true))
		end)

		T.it("sub-configs carry the numbers", function()
			local scheduler = Config.scheduler(Config.DEFAULTS)
			T.equal(scheduler.rates.near, 10)
			T.equal(scheduler.rates.dormant, 0.5)
			T.equal(scheduler.brainDivisor.near, 2)
			T.equal(scheduler.brainDivisor.dormant, 1)
			T.equal(scheduler.near, 60)
			T.equal(scheduler.far, 500)
			T.equal(scheduler.hysteresis, 1.25)
			T.equal(scheduler.maxTicksPerFrame, 12)

			local population = Config.population(Config.DEFAULTS)
			T.equal(population.min, 2)
			T.equal(population.max, 30)
			T.equal(population.base, 6)
			T.equal(population.perPlayer, 0.5)
			T.equal(population.spawnWhenEmpty, false)
			T.equal(population.initialBurst, 2)
			T.equal(population.rejoinChance, 0.15)
			T.equal(population.rejoinDelay.median, 900)
			T.equal(population.rejoinDelay.hi, 3600)
			T.equal(population.pairChance, 0.3)
			T.equal(population.emptyGrace, 600)
			T.equal(population.shortenGap.median, 30)
			T.equal(population.shortenGap.lo, 10)
			T.equal(population.burstGap.median, 8)
			T.equal(population.burstGap.hi, 30)
			T.equal(population.joinGap.median, 25)
			T.equal(population.nameRetire, 7200)

			local planner = Config.planner(Config.DEFAULTS)
			T.equal(planner.shedAbove, 8)
			T.equal(planner.maxInFlightRoblox, 2)
			T.equal(planner.robloxTimeout, 1.5)
			T.equal(planner.cooldown, 1)
			T.equal(planner.cacheTtl, 2)
			T.equal(planner.directMax, 24)
			T.equal(planner.starvationAfter, 6)
			T.equal(planner.backoffSeconds, 30)
			T.equal(planner.gridMaxNodes, 4000)
			T.equal(planner.cellSize, 2)

			local guard = Config.chatGuard(Config.DEFAULTS)
			T.equal(guard.npcMinGap, 4)
			T.equal(guard.npcPerMinute, 4)
			T.equal(guard.npcPer10Min, 12)
			T.equal(guard.serverPerMinute, 8)
			T.equal(guard.serverShare, 0.4)
			T.equal(guard.quietAfterSilence, 600)
			T.equal(guard.replyBoost, 2)

			local lod = Config.lod(Config.DEFAULTS)
			T.equal(lod.visibleRange, 250)
			T.equal(lod.downgradeDelay, 2)
			T.equal(lod.near, 60)
			T.equal(lod.mid, 200)
			T.equal(lod.far, 500)

			-- The builders read the resolved table, not DEFAULTS.
			local resolved = Config.resolve(sourceWith({ PopulationMin = 4, RateNear = 20, ShedAbove = 3 }))
			T.equal(Config.population(resolved).min, 4)
			T.equal(Config.scheduler(resolved).rates.near, 20)
			T.equal(Config.planner(resolved).shedAbove, 3)
		end)

		T.it("KillY auto is math.huge", function()
			T.equal(Config.DEFAULTS.KillY, math.huge)
			T.equal(Config.resolve(nil).KillY, math.huge)
			local resolved = Config.resolve(sourceWith({ KillY = -40 }))
			T.equal(resolved.KillY, -40)
			T.equal(#Config.lastWarnings, 0)
			T.equal(resolved.KillYOffset, 60)
		end)

		T.it("Config requires only Types", function()
			local source = fs.readFile("src/server/Config.luau")
			local requires = {}
			for line in string.gmatch(source, "[^\n]+") do
				if string.find(line, "require(", 1, true) then
					table.insert(requires, line)
				end
			end
			T.equal(#requires, 1, table.concat(requires, "\n"))
			T.check(string.find(requires[1], "require(script.Parent.Types)", 1, true), requires[1])
			T.check(string.find(source, "^%-%-!strict\n"), "strict")
			T.check(string.find(source, "\n%-%- requires: Types\n"), "requires line in the doc comment")
		end)
	end)
end

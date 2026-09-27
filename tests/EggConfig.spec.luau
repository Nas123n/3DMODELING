return function(T, Loader)
	local session = Loader.new()
	local EggConfig = session.require(session.game.ReplicatedStorage.Shared.EggConfig)

	local function tier(variationCount: number)
		local variations = {}
		for i = 1, variationCount do
			table.insert(
				variations,
				{ id = `V{i}`, name = `V{i}`, pattern = "Spots", base = "#FFFFFF", accent = "#000000" }
			)
		end
		return {
			id = "Test",
			name = "Test",
			order = 1,
			color = "#123456",
			effects = { light = false, neonAccent = false, sparkles = false, halo = false },
			variations = variations,
		}
	end

	T.describe("EggConfig", function()
		T.it("ships a valid config", function()
			local ok, reason = EggConfig.validate()
			T.check(ok, reason)
		end)

		T.it("gives every tier exactly 3 variations", function()
			T.equal(EggConfig.VARIATIONS_PER_TIER, 3)
			T.check(#EggConfig.Tiers > 0, "no tiers")
			for _, t in EggConfig.Tiers do
				T.equal(#t.variations, 3, `tier {t.id}`)
			end
		end)

		T.it("uses all three patterns in every tier", function()
			for _, t in EggConfig.Tiers do
				local patterns = {}
				for _, v in t.variations do
					patterns[v.pattern] = true
				end
				T.check(patterns.Stripes and patterns.Spots and patterns.Zigzag, `tier {t.id} repeats a pattern`)
			end
		end)

		T.it("rejects tiers with fewer or more than 3 variations", function()
			T.check(EggConfig.validate({ tier(3) }), "3 should pass")
			local ok2, reason2 = EggConfig.validate({ tier(2) })
			T.check(not ok2 and string.find(reason2, "expected exactly 3"), reason2)
			local ok4 = EggConfig.validate({ tier(4) })
			T.check(not ok4, "4 variations should fail")
		end)

		T.it("rejects duplicate ids, unknown patterns and bad colors", function()
			local dup = tier(3)
			dup.variations[2].id = "V1"
			T.check(not EggConfig.validate({ dup }), "duplicate variation id")
			local badPattern = tier(3)
			badPattern.variations[1].pattern = "Plaid"
			T.check(not EggConfig.validate({ badPattern }), "unknown pattern")
			local badColor = tier(3)
			badColor.variations[1].base = "red"
			T.check(not EggConfig.validate({ badColor }), "bad hex")
			T.check(not EggConfig.validate({ tier(3), tier(3) }), "duplicate tier id")
		end)

		T.it("looks tiers and variations up by id", function()
			local first = EggConfig.Tiers[1]
			T.equal(EggConfig.getTier(first.id), first)
			T.equal(EggConfig.getVariation(first.id, first.variations[2].id), first.variations[2])
			T.equal(EggConfig.getTier("Nope"), nil)
			T.equal(EggConfig.getVariation(first.id, "Nope"), nil)
		end)

		T.it("pickVariation splits rolls evenly across the three", function()
			local t = EggConfig.Tiers[1]
			T.equal(EggConfig.pickVariation(t.id, 0), t.variations[1])
			T.equal(EggConfig.pickVariation(t.id, 0.34), t.variations[2])
			T.equal(EggConfig.pickVariation(t.id, 0.9999), t.variations[3])
			T.equal(EggConfig.pickVariation(t.id, 1), t.variations[3])
			T.throws(function()
				EggConfig.pickVariation("Nope", 0.5)
			end, "unknown egg tier")
		end)
	end)
end

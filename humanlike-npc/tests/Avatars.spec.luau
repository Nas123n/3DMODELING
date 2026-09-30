return function(T, Loader)
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local Personality = session.require(S.Mind.Personality)
	local AvatarCatalog = session.require(S.Identity.AvatarCatalog)
	local Avatars = session.require(S.Identity.Avatars)

	local function deepEqual(a, b): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in a do
			if not deepEqual(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end

	-- A persona with the fields the generator reads pinned, so a test's expectation does not
	-- depend on what Personality happened to draw.
	local function persona(overrides)
		local base = Personality.sample(Rng.new(1))
		local copy = {}
		for k, v in base do
			copy[k] = v
		end
		copy.trolliness = 0.3
		copy.accountAgeDays = 200
		copy.presentation = "any"
		copy.rig = "R15"
		for k, v in overrides or {} do
			copy[k] = v
		end
		return copy
	end

	local function shares(n, p, catalog)
		local rng = Rng.new(77)
		local counts = { default = 0, casual = 0, aesthetic = 0, meme = 0, sport = 0 }
		local placeholder = catalog or AvatarCatalog.withPlaceholderIds()
		local styleOf = {}
		for _, entry in placeholder.SHIRTS do
			styleOf[entry.id] = entry.style
		end
		for _ = 1, n do
			local spec = Avatars.sample(rng, p, { catalog = placeholder })
			counts[styleOf[spec.shirtId]] += 1
		end
		return counts
	end

	T.describe("AvatarCatalog", function()
		T.it("ships the pinned list sizes and weights", function()
			T.equal(#AvatarCatalog.SKIN_TONES, 12)
			T.equal(#AvatarCatalog.SKIN_WEIGHTS, 12)
			local total = 0
			for _, w in AvatarCatalog.SKIN_WEIGHTS do
				total += w
				T.check(w <= 20, "no skin tone above 20")
			end
			T.equal(total, 100, "skin weights sum")
			T.check(#AvatarCatalog.HAIR >= 12, "hair entries")
			T.check(#AvatarCatalog.SHIRTS >= 16, "shirt entries")
			T.check(#AvatarCatalog.PANTS >= 16, "pants entries")
			T.check(#AvatarCatalog.FACES >= 8, "face entries")
			T.check(#AvatarCatalog.HATS >= 12, "hat entries")
			T.equal(#AvatarCatalog.BODY_COLOR_PRESETS, 8)
			T.equal(#AvatarCatalog.PRIMITIVE_PALETTES, 24)
			local styleTotal = 0
			for _, name in AvatarCatalog.STYLE_ORDER do
				styleTotal += AvatarCatalog.STYLES[name]
			end
			T.equal(styleTotal, 100, "style weights sum")
			local presetTotal = 0
			for _, preset in AvatarCatalog.BODY_COLOR_PRESETS do
				presetTotal += preset.weight
				for _, slot in AvatarCatalog.BODY_COLOR_SLOTS do
					T.check(preset.colors[slot] ~= nil, `preset {preset.label} slot {slot}`)
				end
			end
			T.equal(presetTotal, 100, "preset weights sum")
			T.equal(AvatarCatalog.BODY_COLOR_PRESETS[1].weight, 8, "noob set at p 0.08")
		end)

		T.it("ships every id at 0 and numbers placeholders distinctly", function()
			for _, list in
				{
					AvatarCatalog.HAIR,
					AvatarCatalog.SHIRTS,
					AvatarCatalog.PANTS,
					AvatarCatalog.FACES,
					AvatarCatalog.HATS,
				}
			do
				for _, entry in list do
					T.equal(entry.id, 0, `shipped id {entry.label}`)
				end
			end
			local numbered = AvatarCatalog.withPlaceholderIds()
			local seen = {}
			for _, list in { numbered.HAIR, numbered.SHIRTS, numbered.PANTS, numbered.HATS } do
				for _, entry in list do
					T.check(entry.id > 1000000, "placeholder ids are plainly fake")
					T.check(not seen[entry.id], "placeholder ids are distinct")
					seen[entry.id] = true
				end
			end
			T.equal(numbered.FACES[1].id, 0, "the first face stays the default")
			T.equal(#AvatarCatalog.empty().HAIR, 0)
			T.equal(#AvatarCatalog.empty().BODY_COLOR_PRESETS, 8)
		end)
	end)

	T.describe("Avatars", function()
		T.it("deterministic per seed", function()
			local p = Personality.sample(Rng.new(11))
			local a = Avatars.sample(Rng.new(5):fork("avatar"), p)
			local b = Avatars.sample(Rng.new(5):fork("avatar"), p)
			T.check(deepEqual(a, b), "same seed, same spec")
			local c = Avatars.sample(Rng.new(6):fork("avatar"), p)
			T.check(a.catalogSeed ~= c.catalogSeed, "different seed, different catalogSeed")
			T.equal(a.animPack, p.animPack)
			T.equal(a.presentation, p.presentation)
			T.equal(a.rig, p.rig)
		end)

		T.it("style distribution over 4000 within ±3 points", function()
			local n = 4000
			local counts = shares(n, persona())
			for _, name in AvatarCatalog.STYLE_ORDER do
				local expected = AvatarCatalog.STYLES[name] / 100
				T.between(counts[name] / n, expected - 0.03, expected + 0.03, `style {name} share`)
			end
		end)

		T.it("troll bias", function()
			local counts = shares(4000, persona({ trolliness = 0.9 }))
			T.check(counts.meme / 4000 >= 0.25, `meme share {counts.meme / 4000}`)
			local newbie = shares(4000, persona({ accountAgeDays = 10 }))
			T.check(newbie.default / 4000 >= 0.5, `newcomer default share {newbie.default / 4000}`)
			local veteran = shares(4000, persona({ accountAgeDays = 1000 }))
			T.check(veteran.aesthetic / 4000 >= 0.22, `veteran aesthetic share {veteran.aesthetic / 4000}`)
		end)

		T.it("scales in range", function()
			local rng = Rng.new(3)
			local p = persona()
			for _ = 1, 500 do
				local spec = Avatars.sample(rng, p)
				T.between(spec.scale.height, 0.9, 1.05, "height")
				T.between(spec.scale.width, 0.7, 1.0, "width")
				T.equal(spec.scale.head, 1, "head")
				T.between(spec.scale.depth, 0.9, 1.0, "depth")
				T.between(spec.scale.proportion, 0, 0.3, "proportion")
				T.between(spec.scale.bodyType, 0, 0.3, "bodyType")
				T.between(spec.skinToneIndex, 1, 12, "skin tone index")
			end
			local r6 = Avatars.sample(Rng.new(9), p, { rig = "R6" })
			T.equal(r6.rig, "R6")
			T.equal(r6.scale.height, 1, "R6 has no scales")
			T.equal(r6.scale.proportion, 0)
		end)

		T.it("no duplicate hat style", function()
			local catalog = AvatarCatalog.withPlaceholderIds()
			local styleOf = {}
			for _, entry in catalog.HATS do
				styleOf[entry.id] = entry.style
			end
			local rng = Rng.new(21)
			local p = persona()
			local counts = { 0, 0, 0 }
			local n = 3000
			for _ = 1, n do
				local spec = Avatars.sample(rng, p, { catalog = catalog })
				T.check(#spec.hatIds <= 2, "at most two hats")
				counts[#spec.hatIds + 1] += 1
				local seen = {}
				for _, id in spec.hatIds do
					local style = styleOf[id]
					T.check(style ~= nil, `unknown hat id {id}`)
					T.check(not seen[style], `two hats of style {style}`)
					seen[style] = true
				end
			end
			T.between(counts[1] / n, 0.31, 0.39, "no hat share")
			T.between(counts[2] / n, 0.41, 0.49, "one hat share")
			T.between(counts[3] / n, 0.16, 0.24, "two hats share")
		end)

		T.it("presentation filters hair", function()
			local catalog = AvatarCatalog.withPlaceholderIds()
			local hairGender, hatGender = {}, {}
			for _, entry in catalog.HAIR do
				hairGender[entry.id] = entry.gender
			end
			for _, entry in catalog.HATS do
				hatGender[entry.id] = entry.gender
			end
			local rng = Rng.new(31)
			local bald = 0
			local n = 2000
			for _ = 1, n do
				local spec = Avatars.sample(rng, persona({ presentation = "m" }), { catalog = catalog })
				if spec.hairId == 0 then
					bald += 1
				else
					T.check(hairGender[spec.hairId] ~= "f", "presentation m never picks f hair")
				end
				for _, id in spec.hatIds do
					T.check(hatGender[id] ~= "f", "presentation m never picks f hats")
				end
			end
			T.between(bald / n, 0.11, 0.19, "no hair share")
			for _ = 1, 500 do
				local spec = Avatars.sample(rng, persona({ presentation = "f" }), { catalog = catalog })
				if spec.hairId ~= 0 then
					T.check(hairGender[spec.hairId] ~= "m", "presentation f never picks m hair")
				end
			end
		end)

		T.it("empty catalog still yields body colours and scales", function()
			local rng = Rng.new(41)
			local p = persona()
			local noobs = 0
			local n = 2000
			for _ = 1, n do
				local spec = Avatars.sample(rng, p, { catalog = AvatarCatalog.empty() })
				for _, slot in AvatarCatalog.BODY_COLOR_SLOTS do
					T.check(spec.bodyColors[slot] ~= nil, `body colour {slot}`)
				end
				T.between(spec.skinToneIndex, 1, 12)
				T.equal(spec.shirtId, 0)
				T.equal(spec.pantsId, 0)
				T.equal(spec.faceId, 0)
				T.equal(spec.hairId, 0)
				T.equal(#spec.hatIds, 0)
				T.equal(spec.primitive, false)
				T.check(Avatars.isIdless(spec))
				if spec.bodyColors.TorsoColor == AvatarCatalog.BODY_COLOR_PRESETS[1].colors.TorsoColor then
					noobs += 1
				end
			end
			T.between(noobs / n, 0.05, 0.11, "noob set share")
			-- The shipped catalog is id-less too: the default install's output.
			local shipped = Avatars.sample(Rng.new(2), p)
			T.check(Avatars.isIdless(shipped), "shipped catalog yields no ids")
			T.equal(shipped.primitive, false)
		end)

		T.it("skin-toned presets follow the skin tone index", function()
			local rng = Rng.new(51)
			local p = persona()
			local recoloured = 0
			for _ = 1, 500 do
				local spec = Avatars.sample(rng, p)
				local tone = AvatarCatalog.SKIN_TONES[spec.skinToneIndex]
				if spec.bodyColors.HeadColor == tone then
					recoloured += 1
				end
			end
			T.between(recoloured / 500, 0.6, 0.85, "share of skin-toned heads")
		end)

		T.it("forcePrimitive adds the palette and withoutIds strips ids", function()
			local catalog = AvatarCatalog.withPlaceholderIds()
			local p = persona()
			local spec = Avatars.sample(Rng.new(61), p, { forcePrimitive = true, catalog = catalog })
			T.equal(spec.primitive, true)
			local paletteEntry = AvatarCatalog.PRIMITIVE_PALETTES[AvatarCatalog.paletteIndex(spec.catalogSeed)]
			T.equal(spec.bodyColors.shirt, paletteEntry.shirt)
			T.equal(spec.bodyColors.pants, paletteEntry.pants)
			T.equal(spec.bodyColors.skin, AvatarCatalog.SKIN_TONES[spec.skinToneIndex])
			local plain = Avatars.sample(Rng.new(61), p, { catalog = catalog })
			T.equal(plain.catalogSeed, spec.catalogSeed, "forcePrimitive changes no draw")
			T.equal(plain.shirtId, spec.shirtId)
			T.check(plain.bodyColors.shirt == nil, "no palette without forcePrimitive")
			local dressed
			local rng = Rng.new(62)
			for _ = 1, 50 do
				local candidate = Avatars.sample(rng, p, { catalog = catalog })
				if not Avatars.isIdless(candidate) then
					dressed = candidate
					break
				end
			end
			T.check(dressed ~= nil, "placeholder catalog dresses someone")
			local stripped = Avatars.withoutIds(dressed)
			T.check(Avatars.isIdless(stripped))
			T.equal(stripped.catalogSeed, dressed.catalogSeed)
			T.equal(stripped.skinToneIndex, dressed.skinToneIndex)
			T.check(deepEqual(stripped.bodyColors, dressed.bodyColors))
			T.check(stripped.bodyColors ~= dressed.bodyColors, "fresh tables")
			T.check(not Avatars.isIdless(dressed), "the original is untouched")
		end)
	end)
end

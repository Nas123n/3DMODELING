return function(T, Loader)
	local session = Loader.new()
	local EggBuilder = session.require(session.game.ServerStorage.Builders.EggBuilder)
	local EggConfig = session.require(session.game.ReplicatedStorage.Shared.EggConfig)
	local roblox = require("@lune/roblox")
	local CFrame = roblox.CFrame

	local PATTERN_PARTS = { Stripes = "Stripe", Spots = "Spot", Zigzag = "Zigzag" }

	local function countNamed(root: any, name: string): number
		local n = 0
		for _, d in root:GetDescendants() do
			if d.Name == name then
				n += 1
			end
		end
		return n
	end

	local function findClass(root: any, className: string): any
		for _, d in root:GetDescendants() do
			if d.ClassName == className then
				return d
			end
		end
		return nil
	end

	T.describe("EggBuilder", function()
		T.it("builds every variation with its pattern and identifying attributes", function()
			for _, tier in EggConfig.Tiers do
				for _, variation in tier.variations do
					local egg = EggBuilder.buildEgg(tier.id, variation.id, CFrame.new(0, 5, 0))
					T.equal(egg.Name, variation.name)
					T.equal(egg:GetAttribute("Tier"), tier.id)
					T.equal(egg:GetAttribute("Variation"), variation.id)
					T.check(egg:HasTag("Egg"), "egg tag")
					T.equal(egg.PrimaryPart and egg.PrimaryPart.Name, "Shell")
					T.check(
						countNamed(egg, PATTERN_PARTS[variation.pattern]) >= 3,
						`{variation.id} has no {variation.pattern}`
					)
					for _, d in egg:GetDescendants() do
						if d:IsA("BasePart") then
							T.check(d.Anchored and not d.CanCollide and not d.CanTouch, `{variation.id}/{d.Name} flags`)
						end
					end
				end
			end
		end)

		T.it("adds lights, sparkles and halos only where the tier asks for them", function()
			for _, tier in EggConfig.Tiers do
				local egg = EggBuilder.buildEgg(tier.id, tier.variations[1].id, CFrame.identity)
				T.equal(findClass(egg, "PointLight") ~= nil, tier.effects.light, `{tier.id} light`)
				T.equal(findClass(egg, "ParticleEmitter") ~= nil, tier.effects.sparkles, `{tier.id} sparkles`)
				local halo = egg:FindFirstChild("Halo")
				T.equal(halo ~= nil, tier.effects.halo, `{tier.id} halo`)
				if halo then
					T.equal(#halo:GetChildren(), 10)
					T.check(halo:HasTag("Spin"), "halo spins")
				end
			end
		end)

		T.it("puts exactly the tier's 3 eggs on each stand, animated and signed", function()
			for _, tier in EggConfig.Tiers do
				local stand = EggBuilder.buildStand(tier.id, CFrame.identity)
				local eggs = stand:FindFirstChild("Eggs"):GetChildren()
				T.equal(#eggs, 3, tier.id)
				local names = {}
				for _, egg in eggs do
					names[egg:GetAttribute("Variation")] = true
					T.check(egg:HasTag("Bob") and egg:HasTag("Spin"), "stand eggs bob and spin")
				end
				for _, variation in tier.variations do
					T.check(names[variation.id], `stand is missing {variation.id}`)
				end
				-- Seen from the front, config order runs left to right (stand-local +X to -X).
				local previousX = math.huge
				for _, variation in tier.variations do
					for _, egg in eggs do
						if egg:GetAttribute("Variation") == variation.id then
							local x = egg.WorldPivot.Position.X
							T.check(x < previousX, `{tier.id}: {variation.id} is out of order`)
							previousX = x
						end
					end
				end
				local sign = stand:FindFirstChild("Sign")
				local label = findClass(sign, "TextLabel")
				T.equal(label and label.Text, `{tier.name} Eggs`)
				T.equal(countNamed(stand, "Plaque"), 3)
			end
		end)

		T.it("builds templates grouped by tier", function()
			local templates = EggBuilder.buildTemplates()
			T.equal(#templates:GetChildren(), #EggConfig.Tiers)
			for _, tier in EggConfig.Tiers do
				T.equal(#templates:FindFirstChild(tier.id):GetChildren(), 3)
			end
		end)

		T.it("names the bad id when a tier or variation doesn't exist", function()
			T.throws(function()
				EggBuilder.buildEgg("Mythic", "Nope", CFrame.identity)
			end, "Mythic")
			T.throws(function()
				EggBuilder.buildEgg("Common", "Nope", CFrame.identity)
			end, "Nope")
		end)
	end)
end

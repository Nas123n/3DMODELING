return function(T, Loader)
	local session = Loader.new()
	local builders = session.game.ServerStorage.Builders
	local Props = session.require(builders.Props)
	local Rng = session.require(builders.Rng)
	local ZoneThemes = session.require(builders.ZoneThemes)
	local roblox = require("@lune/roblox")

	local function sortedKeys(map: { [string]: any }): { string }
		local keys = {}
		for key in map do
			table.insert(keys, key)
		end
		table.sort(keys)
		return keys
	end

	T.describe("Props", function()
		T.it("builds every prop with every theme palette at small and large scale", function()
			for _, themeName in sortedKeys(ZoneThemes.Themes) do
				local theme = ZoneThemes.Themes[themeName]
				for _, propName in sortedKeys(Props.specs) do
					for _, scale in { 0.7, 1.4 } do
						local folder = roblox.Instance.new("Folder")
						local rng = Rng.new(`{themeName}/{propName}/{scale}`)
						local ok, result = pcall(
							Props.specs[propName].build,
							folder,
							roblox.CFrame.new(3, 0, -2),
							rng,
							theme.palette,
							scale
						)
						T.check(ok, `{themeName}/{propName}: {result}`)
						T.equal(result.ClassName, "Model", propName)
						T.equal(result.Parent, folder, `{propName} parent`)
						local parts = 0
						for _, d in result:GetDescendants() do
							if d:IsA("BasePart") then
								parts += 1
								T.check(d.Anchored, `{propName}/{d.Name} must be anchored`)
								T.check(not d.CanTouch, `{propName}/{d.Name} must not fire touches`)
								T.check(
									d.CanCollide or not d.CanQuery,
									`{propName}/{d.Name}: non-colliding parts skip queries`
								)
								if d:FindFirstChildOfClass("SpecialMesh") then
									T.check(not d.CanCollide, `{propName}/{d.Name}: mesh parts collide as boxes`)
								end
								local size = d.Size
								T.check(size.X > 0 and size.Y > 0 and size.Z > 0, `{propName}/{d.Name} has zero size`)
							end
						end
						T.check(parts > 0 and parts <= 40, `{propName} has {parts} parts`)
					end
				end
			end
		end)

		T.it("gives fires and lamps flickering lights", function()
			local palette = ZoneThemes.Themes.Volcano.palette
			for _, propName in { "Torch", "Brazier", "Lantern", "LavaVent" } do
				local model = Props.specs[propName].build(
					roblox.Instance.new("Folder"),
					roblox.CFrame.identity,
					Rng.new(1),
					palette,
					1
				)
				local flickering = 0
				for _, d in model:GetDescendants() do
					if d.ClassName == "PointLight" and d:HasTag("Flicker") then
						flickering += 1
					end
				end
				T.equal(flickering, 1, propName)
			end
		end)

		T.it("stands props on the ground: nothing sinks far below or floats off the base", function()
			local palette = ZoneThemes.Themes.Meadow.palette
			for _, propName in sortedKeys(Props.specs) do
				local model = Props.specs[propName].build(
					roblox.Instance.new("Folder"),
					roblox.CFrame.new(0, 10, 0),
					Rng.new(3),
					palette,
					1
				)
				local lowest = math.huge
				for _, d in model:GetDescendants() do
					if d:IsA("BasePart") then
						lowest = math.min(lowest, d.CFrame.Position.Y - d.Size.Magnitude / 2)
					end
				end
				T.check(lowest < 10.5, `{propName} floats: lowest point {lowest}`)
			end
		end)
	end)
end

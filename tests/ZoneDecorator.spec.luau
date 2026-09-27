return function(T, Loader)
	local Scenes = require("../tools/lune/Scenes")
	local roblox = require("@lune/roblox")
	local Vector3, CFrame, Instance, Color3 = roblox.Vector3, roblox.CFrame, roblox.Instance, roblox.Color3

	local function fresh()
		local session = Loader.new()
		local builders = session.game.ServerStorage.Builders
		return session, session.require(builders.ZoneDecorator), session.require(builders.ZoneThemes)
	end

	local function propModels(folder: any): { any }
		local models = {}
		for _, child in folder:GetChildren() do
			if child.ClassName == "Model" then
				table.insert(models, child)
			end
		end
		return models
	end

	local function snapshot(folder: any): string
		local lines = {}
		for _, model in propModels(folder) do
			local p = model.WorldPivot.Position
			table.insert(lines, string.format("%s %.3f %.3f %.3f", model.Name, p.X, p.Y, p.Z))
		end
		table.sort(lines)
		return table.concat(lines, "\n")
	end

	T.describe("ZoneDecorator", function()
		T.it("decorates every theme without errors and reports what it placed", function()
			local session, ZoneDecorator, ZoneThemes = fresh()
			local index = 0
			for themeName in ZoneThemes.Themes do
				index += 1
				local zone = Scenes.zone(session, {
					name = `Zone{themeName}`,
					theme = themeName,
					origin = Vector3.new(index * 400, 0, 0),
					stand = "Common",
				})
				local folder, report = ZoneDecorator.decorate(zone)
				T.equal(folder.Parent, zone)
				T.equal(report.theme, themeName)
				T.check(report.props >= 40, `{themeName}: only {report.props} props`)
				T.check(report.parts > report.props, `{themeName}: part count`)
				T.equal(#propModels(folder), report.props)
				local ambient = folder:FindFirstChild("AmbientParticles")
				T.check(
					ambient ~= nil and ambient:FindFirstChildOfClass("ParticleEmitter") ~= nil,
					`{themeName}: ambient`
				)
				T.check(
					string.find(ZoneDecorator.describe(report), themeName, 1, true) ~= nil,
					"describe names the theme"
				)
			end
		end)

		T.it("keeps props on the floor, off the path and clear of the egg stand", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Meadow", theme = "Meadow", stand = "Rare" })
			local folder = ZoneDecorator.decorate(zone)
			for _, model in propModels(folder) do
				local p = model.WorldPivot.Position
				T.check(math.abs(p.X) <= 70 and math.abs(p.Z) <= 70, `{model.Name} off the floor at {p}`)
				T.near(p.Y, 0, 0.01, `{model.Name} not on the floor top`)
				T.check(math.abs(p.Z) > 5, `{model.Name} on the path at {p}`)
				-- Stand plinth is 13.4 x 5.4 centered at (0, 18); nothing within its footprint + padding.
				T.check(
					not (math.abs(p.X) < 6.7 + 2 and math.abs(p.Z - 18) < 2.7 + 2),
					`{model.Name} inside the stand at {p}`
				)
				model:AddTag("__checked")
			end
		end)

		T.it("keeps big props near the edge so the middle stays walkable", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Forest", theme = "Forest" })
			local folder = ZoneDecorator.decorate(zone)
			for _, model in propModels(folder) do
				if model.Name == "PineTree" or model.Name == "Tree" then
					local p = model.WorldPivot.Position
					local fromEdge = 70 - math.max(math.abs(p.X), math.abs(p.Z))
					T.check(fromEdge <= 70 * 0.32 + 0.01, `{model.Name} too central at {p}`)
				end
			end
		end)

		T.it("is deterministic per seed and replaces its own folder on rebuild", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Volcano", theme = "Volcano" })
			local first = snapshot(ZoneDecorator.decorate(zone, { seed = 42 }))
			local second = snapshot(ZoneDecorator.decorate(zone, { seed = 42 }))
			T.equal(first, second, "same seed, same layout")
			local count = 0
			for _, child in zone:GetChildren() do
				if child.Name == "Decorations" then
					count += 1
				end
			end
			T.equal(count, 1, "old Decorations folder should be replaced")
			T.check(snapshot(ZoneDecorator.decorate(zone, { seed = 43 })) ~= first, "a new seed moves things")
		end)

		T.it("respects density, KeepClear parts and the keepClear option", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Desert", theme = "Desert" })
			local _, normal = ZoneDecorator.decorate(zone)
			local _, dense = ZoneDecorator.decorate(zone, { density = 2 })
			local _, bare = ZoneDecorator.decorate(zone, { density = 0, perimeter = false })
			T.check(dense.props > normal.props, "density 2 adds props")
			T.equal(bare.props, 0, "density 0 without perimeter places nothing")

			local marker = Instance.new("Part")
			marker.Name = "Arena"
			marker.Anchored = true
			marker.Transparency = 1
			marker.CanCollide = false
			marker.Size = Vector3.new(40, 10, 40)
			marker.CFrame = CFrame.new(-40, 5, -40)
			marker:AddTag("KeepClear")
			marker.Parent = zone
			local folder =
				ZoneDecorator.decorate(zone, { keepClear = { { position = Vector3.new(40, 0, 40), radius = 15 } } })
			for _, model in propModels(folder) do
				local p = model.WorldPivot.Position
				T.check(
					not (math.abs(p.X + 40) < 20 and math.abs(p.Z + 40) < 20),
					`{model.Name} inside KeepClear part at {p}`
				)
				T.check(
					(Vector3.new(p.X, 0, p.Z) - Vector3.new(40, 0, 40)).Magnitude > 15,
					`{model.Name} inside keepClear circle at {p}`
				)
			end
		end)

		T.it("still lines walled zones with edge lights by stepping inward", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Walled", theme = "Meadow", walls = true })
			local _, report = ZoneDecorator.decorate(zone)
			T.check((report.counts.Lantern or 0) >= 12, `only {report.counts.Lantern} lanterns`)
		end)

		T.it("uses ZoneGround-tagged parts as the floor when present", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Split", theme = "Snow", path = false })
			local floor = zone:FindFirstChild("Floor")
			floor.Size = Vector3.new(70, 2, 140)
			floor.CFrame = CFrame.new(-35, -1, 0)
			local other = floor:Clone()
			other.Name = "Floor2"
			other.CFrame = CFrame.new(35, -1, 0)
			other.Color = Color3.new(0.2, 0.2, 0.2)
			other.Parent = zone
			other:AddTag("ZoneGround")
			local folder = ZoneDecorator.decorate(zone)
			T.check(#propModels(folder) > 0, "something placed")
			for _, model in propModels(folder) do
				T.check(model.WorldPivot.Position.X > 0, `{model.Name} outside the tagged floor`)
			end
		end)

		T.it("decorateAll themes each zone from its attribute and skips untagged ones", function()
			local session, ZoneDecorator = fresh()
			local container = Instance.new("Folder")
			container.Name = "Zones"
			container.Parent = session.workspace
			Scenes.zone(session, { name = "A", theme = "Crystal" }).Parent = container
			Scenes.zone(session, { name = "B", theme = "Den", origin = Vector3.new(400, 0, 0), boss = true }).Parent =
				container
			local plain = Instance.new("Model")
			plain.Name = "Lobby"
			plain.Parent = container
			local reports = ZoneDecorator.decorateAll(container)
			T.equal(#reports, 2)
			local themes = {}
			for _, report in reports do
				themes[report.zone] = report.theme
			end
			T.equal(themes.A, "Crystal")
			T.equal(themes.B, "Den")
			T.equal(plain:FindFirstChild("Decorations"), nil)
		end)

		T.it("leaves the sleeping boss room to breathe", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Den", theme = "Den", boss = true })
			local folder = ZoneDecorator.decorate(zone)
			for _, model in propModels(folder) do
				local p = model.WorldPivot.Position
				-- Boss body spans x -8..8, z -29.5..-18.5 (plus head and tail); keep 2 studs clear.
				T.check(not (math.abs(p.X) < 10 and p.Z > -31.5 and p.Z < -16.5), `{model.Name} on the boss at {p}`)
			end
		end)

		T.it("keeps the previous decorations when a rebuild fails", function()
			local session, ZoneDecorator = fresh()
			local zone = Scenes.zone(session, { name = "Keep", theme = "Meadow" })
			ZoneDecorator.decorate(zone)
			zone:FindFirstChild("Floor"):Destroy()
			zone:FindFirstChild("Path"):Destroy()
			T.throws(function()
				ZoneDecorator.decorate(zone)
			end, "no floor")
			local folder = zone:FindFirstChild("Decorations")
			T.check(folder ~= nil and #folder:GetChildren() > 0, "old decorations were deleted")
		end)

		T.it("explains how to fix a zone with no floor or no theme", function()
			local session, ZoneDecorator = fresh()
			local empty = Instance.new("Model")
			empty.Name = "Empty"
			empty:SetAttribute("ZoneTheme", "Meadow")
			empty.Parent = session.workspace
			T.throws(function()
				ZoneDecorator.decorate(empty)
			end, "ZoneGround")
			local untitled = Scenes.zone(session, { name = "NoTheme", theme = "Meadow" })
			untitled:SetAttribute("ZoneTheme", nil)
			T.throws(function()
				ZoneDecorator.decorate(untitled)
			end, "ZoneTheme")
			T.throws(function()
				ZoneDecorator.decorate(untitled, { theme = "Swamp" })
			end, "available")
		end)
	end)
end

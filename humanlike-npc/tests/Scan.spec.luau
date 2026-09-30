return function(T, Loader)
	local roblox = require("@lune/roblox")
	local Scenes = require("../tools/lune/Scenes")
	local FakeWorld = require("../tools/lune/FakeWorld")
	local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Scan = session.require(S.World.Scan)
	local PoiRegistry = session.require(S.World.PoiRegistry)
	local model, made = Scenes.arena(session)

	-- The POI record whose source is this marker part.
	local function recordFor(registry, marker)
		for _, poi in registry:all() do
			if poi.source == marker then
				return poi
			end
		end
		return nil
	end

	-- The floor point under a marker part: its centre dropped by half its height.
	local function floorPointOf(part)
		local p = part.CFrame.Position
		return Vector3.new(p.X, p.Y - part.Size.Y / 2, p.Z)
	end

	local function nearVector(actual, expected, tolerance, message)
		T.near(actual.X, expected.X, tolerance, `{message} (X)`)
		T.near(actual.Y, expected.Y, tolerance, `{message} (Y)`)
		T.near(actual.Z, expected.Z, tolerance, `{message} (Z)`)
	end

	-- A throwaway world for the vocabulary tests, built the way Scenes builds its arenas.
	local function scratchWorld(name)
		local root = Instance.new("Model")
		root.Name = name
		root.Parent = session.workspace
		return root
	end

	T.describe("Scan of the arena", function()
		local registry = Scan.registry(model)

		T.it("finds the four POIs with the kinds, weights, radii and dwell Scenes declares", function()
			T.equal(#registry:all(), 4, "POI count")
			local declared = {
				{ marker = made.shop, kind = "shop", weight = 2, radius = 7 },
				{ marker = made.hangoutA, kind = "hangout", weight = 1, radius = 8 },
				{ marker = made.hangoutB, kind = "hangout", weight = 1, radius = 8 },
				{ marker = made.viewpoint, kind = "viewpoint", weight = 0.7, radius = 5 },
			}
			for _, expected in declared do
				local poi = recordFor(registry, expected.marker)
				T.check(poi ~= nil, `no record for {expected.marker.Name}`)
				T.equal(poi.kind, expected.kind, `{expected.marker.Name} kind`)
				T.near(poi.weight, expected.weight, 1e-6, `{expected.marker.Name} weight`)
				T.near(poi.radius, expected.radius, 1e-6, `{expected.marker.Name} radius`)
				-- Scenes.arena never passes a dwell, so no marker carries PoiDwell or NpcCapacity.
				T.equal(poi.dwellMedian, nil, `{expected.marker.Name} dwell`)
				T.equal(poi.capacity, nil, `{expected.marker.Name} capacity`)
			end
			T.equal(#registry:byKind("hangout"), 2, "two hangouts")
			T.equal(#registry:byKind("shop"), 1, "one shop")
			T.equal(#registry:byKind("viewpoint"), 1, "one viewpoint")
		end)

		T.it("gives every POI a unique id built from its marker name and keeps the marker as source", function()
			local seen = {}
			for _, poi in registry:all() do
				T.check(not seen[poi.id], `duplicate id {poi.id}`)
				seen[poi.id] = true
				T.check(poi.source ~= nil and poi.source:HasTag("NpcPoi"), `{poi.id} source is the tagged marker`)
				local prefix = `{poi.source.Name}#`
				T.equal(string.sub(poi.id, 1, #prefix), prefix, `{poi.id} starts with the marker name`)
				T.check(registry:get(poi.id) == poi, `{poi.id} is retrievable by id`)
			end
			-- The two hangouts share a marker name and must still be told apart.
			T.check(recordFor(registry, made.hangoutA) ~= recordFor(registry, made.hangoutB), "hangouts differ")
		end)

		T.it("projects each marker to the floor point under it", function()
			local shop = recordFor(registry, made.shop)
			T.near(shop.position.Y, 0, 1e-3, "a marker resting on the floor projects to y = 0")
			for _, marker in { made.shop, made.hangoutA, made.hangoutB, made.viewpoint } do
				local poi = recordFor(registry, marker)
				nearVector(poi.position, floorPointOf(marker), 1e-3, `{marker.Name} floor point`)
			end
			-- The viewpoint stands on the platform, so its floor point is the platform top.
			local viewpoint = recordFor(registry, made.viewpoint)
			local platformTop = made.platform.CFrame.Position.Y + made.platform.Size.Y / 2
			T.near(viewpoint.position.Y, platformTop, 1e-3, "viewpoint sits on the platform top")
			T.near(viewpoint.position.Y, 6, 1e-3, "platform top is 6 studs up")
		end)

		T.it("records the one spawn area and its points land on the floor top", function()
			T.equal(#registry.spawns, 1, "spawn count")
			local spawn = registry.spawns[1]
			T.equal(string.sub(spawn.id, 1, #"SpawnArea#"), "SpawnArea#", "spawn id from the part name")
			nearVector(spawn.cframe.Position, made.spawn.CFrame.Position, 1e-3, "spawn cframe")
			nearVector(spawn.size, made.spawn.Size, 1e-3, "spawn size")
			local half = made.spawn.Size / 2
			local centre = made.spawn.CFrame.Position
			for _, uv in { { 0.5, 0.5 }, { 0, 0 }, { 1, 1 }, { 0.25, 0.9 } } do
				local point = registry:spawnPoint(uv[1], uv[2])
				T.check(point ~= nil, "spawn point exists")
				T.near(point.Y, 0, 1e-3, `spawn point ({uv[1]}, {uv[2]}) is on the floor top`)
				T.check(
					math.abs(point.X - centre.X) <= half.X - 2 + 1e-3
						and math.abs(point.Z - centre.Z) <= half.Z - 2 + 1e-3,
					`spawn point ({uv[1]}, {uv[2]}) stays inside the inset rectangle: {point}`
				)
			end
		end)

		T.it("records the one avoid volume and answers isAvoided from it", function()
			T.equal(#registry.avoids, 1, "avoid count")
			local avoid = registry.avoids[1]
			T.equal(string.sub(avoid.id, 1, #"AvoidArea#"), "AvoidArea#", "avoid id from the part name")
			nearVector(avoid.cframe.Position, made.avoid.CFrame.Position, 1e-3, "avoid cframe")
			nearVector(avoid.size, made.avoid.Size, 1e-3, "avoid size")
			local centre = made.avoid.CFrame.Position
			local half = made.avoid.Size / 2
			T.check(registry:isAvoided(Vector3.new(centre.X, 0.5, centre.Z)), "pool centre at floor level is avoided")
			T.check(registry:isAvoided(centre + Vector3.new(half.X - 0.5, 0, half.Z - 0.5)), "inside the corner")
			T.check(not registry:isAvoided(centre + Vector3.new(half.X + 1, 0, 0)), "just outside is fine")
			T.check(not registry:isAvoided(recordFor(registry, made.hangoutA).position), "hangoutA is outside the pool")
		end)

		T.it("returns the avoid part for the grid sampler", function()
			local parts = Scan.avoidParts(model)
			T.equal(#parts, 1, "avoid part count")
			T.check(parts[1] == made.avoid, "the avoid part is the arena's pool")
			T.check(parts[1]:IsA("BasePart") and parts[1]:HasTag("NpcAvoid"), "a tagged BasePart")
		end)

		T.it("auto-detects the crates: the six pillars and the step block, nothing else", function()
			local props = Scan.props(model, true)
			-- By the crate rule (collidable, opaque, 2..7 high, 3..12 footprint, longest side <= 16) the
			-- arena's 4x6x4 pillars and 6x6x6 step qualify; the floor, walls, platform, ramp, the
			-- invisible marker parts, the 1-stud-high seats and the non-collidable slow strip do not.
			-- (The design note "props auto-detected: the step block only" predates the landed rule,
			-- under which the pillars are crates too; the landed rule is the one pinned here.)
			local expected = { made.step }
			for _, pillar in made.pillars do
				table.insert(expected, pillar)
			end
			T.equal(#props, #expected, "prop count")
			for _, part in expected do
				local top = part.CFrame.Position.Y + part.Size.Y / 2
				local found = nil
				for _, prop in props do
					local dx, dz = prop.position.X - part.CFrame.Position.X, prop.position.Z - part.CFrame.Position.Z
					if math.abs(dx) < 1e-3 and math.abs(dz) < 1e-3 then
						found = prop
					end
				end
				T.check(found ~= nil, `{part.Name} at {part.CFrame.Position} should be a prop`)
				T.equal(string.sub(found.id, 1, #part.Name + 1), `{part.Name}#`, "prop id from the part name")
				T.near(found.position.Y, 0, 1e-3, `{part.Name} prop position is its floor point`)
				T.near(found.top, top, 1e-3, `{part.Name} top`)
				T.near(found.top, 6, 1e-3, `{part.Name} top is 6 studs up`)
				T.near(found.footprint, math.min(part.Size.X, part.Size.Z), 1e-3, `{part.Name} footprint`)
			end
			local ids = {}
			for _, prop in props do
				T.check(not ids[prop.id], `duplicate prop id {prop.id}`)
				ids[prop.id] = true
			end
		end)

		T.it("finds no props without auto-detection because the arena tags none", function()
			T.equal(#Scan.props(model), 0, "no NpcProp tags in the arena")
			T.equal(#Scan.props(model, false), 0, "explicit false")
		end)

		T.it("into fills the registry it is given and returns it", function()
			local own = PoiRegistry.new()
			T.check(Scan.into(own, model) == own, "returns the same registry")
			T.equal(#own:all(), 4, "POIs")
			T.equal(#own.spawns, 1, "spawns")
			T.equal(#own.avoids, 1, "avoids")
		end)
	end)

	T.describe("Scan vocabulary defaults", function()
		T.it("fills PoiId, PoiKind hangout, weight 1 and radius 6 for a bare NpcPoi part", function()
			local root = scratchWorld("BarePoi")
			local bench = Scenes.block(root, "Bench", CFrame.new(10, 1, 10), Vector3.new(2, 2, 2))
			bench:AddTag("NpcPoi")
			local registry = Scan.registry(root)
			T.equal(#registry:all(), 1, "one POI")
			local poi = registry:all()[1]
			T.equal(poi.id, "Bench#1", "id defaults to name and counter")
			T.equal(poi.kind, "hangout", "kind default")
			T.equal(poi.weight, 1, "weight default")
			T.equal(poi.radius, 6, "radius default")
			T.equal(poi.dwellMedian, nil, "no dwell")
			T.equal(poi.capacity, nil, "no capacity")
			nearVector(poi.position, Vector3.new(10, 0, 10), 1e-3, "floor point under the marker")
			T.check(poi.source == bench, "source is the part")
			T.check(registry:get("Bench#1") == poi, "retrievable by the default id")
			T.equal(#registry.spawns, 0, "no spawns")
			T.equal(#registry.avoids, 0, "no avoids")
		end)

		T.it("reads every POI attribute when it is set", function()
			local root = scratchWorld("FullPoi")
			local counter = Scenes.block(root, "Counter", CFrame.new(-4, 2.5, 8), Vector3.new(4, 5, 4))
			counter:AddTag("NpcPoi")
			counter:SetAttribute("PoiId", "tillA")
			counter:SetAttribute("PoiKind", "shop")
			counter:SetAttribute("PoiWeight", 3)
			counter:SetAttribute("PoiRadius", 9)
			counter:SetAttribute("PoiDwell", 45)
			counter:SetAttribute("NpcCapacity", 2)
			local registry = Scan.registry(root)
			local poi = registry:get("tillA")
			T.check(poi ~= nil, "found by PoiId")
			T.equal(poi.kind, "shop")
			T.equal(poi.weight, 3)
			T.equal(poi.radius, 9)
			T.equal(poi.dwellMedian, 45)
			T.equal(poi.capacity, 2)
			nearVector(poi.position, Vector3.new(-4, 0, 8), 1e-3, "a 5-stud marker still projects to its base")
			T.check(registry:isFull("tillA") == false, "empty shop is not full")
			registry:enter("tillA", "a")
			registry:enter("tillA", "b")
			T.check(registry:isFull("tillA"), "capacity 2 fills with two")
		end)

		T.it("falls back to the defaults when an attribute has the wrong type", function()
			local root = scratchWorld("OddPoi")
			local odd = Scenes.block(root, "Odd", CFrame.new(0, 1, 0), Vector3.new(2, 2, 2))
			odd:AddTag("NpcPoi")
			odd:SetAttribute("PoiId", 12)
			odd:SetAttribute("PoiKind", 7)
			odd:SetAttribute("PoiWeight", "heavy")
			odd:SetAttribute("PoiRadius", true)
			odd:SetAttribute("PoiDwell", "long")
			odd:SetAttribute("NpcCapacity", "many")
			local poi = Scan.registry(root):all()[1]
			T.equal(poi.id, "Odd#1")
			T.equal(poi.kind, "hangout")
			T.equal(poi.weight, 1)
			T.equal(poi.radius, 6)
			T.equal(poi.dwellMedian, nil)
			T.equal(poi.capacity, nil)
		end)

		T.it("takes a tagged Model at its pivot and skips tagged instances with no geometry", function()
			local root = scratchWorld("ModelPoi")
			local kiosk = Instance.new("Model")
			kiosk.Name = "Kiosk"
			kiosk.WorldPivot = CFrame.new(1, 2, 3)
			kiosk:AddTag("NpcPoi")
			kiosk:AddTag("NpcSpawn")
			kiosk:AddTag("NpcAvoid")
			kiosk.Parent = root
			local folder = Instance.new("Folder")
			folder.Name = "Notes"
			folder:AddTag("NpcPoi")
			folder.Parent = root
			local registry = Scan.registry(root)
			T.equal(#registry:all(), 1, "the Model counts, the Folder does not")
			local poi = registry:all()[1]
			T.equal(poi.id, "Kiosk#1")
			T.equal(poi.kind, "hangout")
			nearVector(poi.position, Vector3.new(1, 2, 3), 1e-3, "a Model has no size: its pivot is the point")
			T.equal(#registry.spawns, 0, "a Model is not a spawn area")
			T.equal(#registry.avoids, 0, "a Model is not an avoid volume")
			T.equal(#Scan.avoidParts(root), 0, "avoidParts returns BaseParts only")
		end)

		T.it("keeps a tagged NpcProp even when the crate rule would reject it", function()
			local root = scratchWorld("TaggedProp")
			local sign = Scenes.block(root, "Sign", CFrame.new(5, 0.5, 5), Vector3.new(1, 1, 1), {
				CanCollide = false,
				Transparency = 1,
			})
			sign:AddTag("NpcProp")
			for _, autoDetect in { nil, false, true } do
				local props = Scan.props(root, autoDetect)
				T.equal(#props, 1, `tagged prop found with autoDetect = {tostring(autoDetect)}`)
				T.equal(props[1].id, "Sign#1")
				nearVector(props[1].position, Vector3.new(5, 0, 5), 1e-3, "prop position is the base point")
				T.near(props[1].top, 1, 1e-3, "prop top")
				T.near(props[1].footprint, 1, 1e-3, "prop footprint")
			end
		end)

		T.it("auto-detects only collidable, opaque parts within the crate limits", function()
			local root = scratchWorld("CrateRule")
			-- Each candidate rests on the floor at its own X so nothing overlaps.
			local x = 0
			local function crate(name, size, props)
				x += 30
				return Scenes.block(root, name, CFrame.new(x, size.Y / 2, 0), size, props)
			end
			crate("Cube", Vector3.new(4, 4, 4))
			crate("Lowest", Vector3.new(4, 2, 4))
			crate("Tallest", Vector3.new(4, 7, 4))
			crate("Narrowest", Vector3.new(3, 4, 10))
			crate("Widest", Vector3.new(12, 4, 16))
			crate("Tinted", Vector3.new(4, 4, 4), { Transparency = 0.5 })
			crate("TooLow", Vector3.new(4, 1.5, 4))
			crate("TooTall", Vector3.new(4, 7.5, 4))
			crate("TooNarrow", Vector3.new(2.5, 4, 8))
			crate("TooWide", Vector3.new(12.5, 4, 12.5))
			crate("TooLong", Vector3.new(4, 4, 17))
			crate("Ghost", Vector3.new(4, 4, 4), { CanCollide = false })
			crate("Invisible", Vector3.new(4, 4, 4), { Transparency = 1 })
			local names = {}
			for _, prop in Scan.props(root, true) do
				names[string.match(prop.id, "^(.-)#%d+$")] = true
			end
			for _, name in { "Cube", "Lowest", "Tallest", "Narrowest", "Widest", "Tinted" } do
				T.check(names[name], `{name} qualifies as a crate`)
			end
			for _, name in { "TooLow", "TooTall", "TooNarrow", "TooWide", "TooLong", "Ghost", "Invisible" } do
				T.check(not names[name], `{name} must not qualify as a crate`)
			end
			T.equal(#Scan.props(root, true), 6, "six crates")
			T.equal(#Scan.props(root), 0, "none without auto-detection")
		end)

		T.it("reads PoiWord into PoiRecord.word and leaves it nil otherwise", function()
			local root = scratchWorld("PoiWord")
			local till = Scenes.poi(root, Vector3.new(0, 0, 0), "shop", { word = "till", name = "Till" })
			local plain = Scenes.poi(root, Vector3.new(20, 0, 0), "shop", { name = "Plain" })
			local blank = Scenes.poi(root, Vector3.new(40, 0, 0), "shop", { name = "Blank" })
			blank:SetAttribute("PoiWord", "")
			local odd = Scenes.poi(root, Vector3.new(60, 0, 0), "shop", { name = "Odd" })
			odd:SetAttribute("PoiWord", 7)
			local registry = Scan.registry(root)
			T.equal(recordFor(registry, till).word, "till", "PoiWord read")
			T.equal(recordFor(registry, plain).word, nil, "no attribute, no word")
			T.equal(recordFor(registry, blank).word, nil, "an empty PoiWord is no word")
			T.equal(recordFor(registry, odd).word, nil, "a non-string PoiWord is ignored")
		end)
	end)

	-- Cell index formula from NavGrid: iz * cols + ix + 1.
	local function costAt(grid, point)
		local ix, iz = grid:cellOf(point)
		return grid.cost[iz * grid.cols + ix + 1]
	end

	-- What FakeWorld / RobloxDiscovery do with Scan.slowParts: every walkable cell whose center
	-- (one stud above its floor, as NavGrid.sample tests avoid volumes) lies inside a slow part
	-- gets that part's cost.
	local function applySlow(grid, slowParts)
		for iz = 0, grid.rows - 1 do
			for ix = 0, grid.cols - 1 do
				local y = grid:floorAt(ix, iz)
				if y then
					local c = grid:centerOf(ix, iz)
					for _, entry in slowParts do
						if Scenes.inside(entry.part, Vector3.new(c.X, y + 1, c.Z)) then
							grid:setCost(ix, iz, entry.cost)
						end
					end
				end
			end
		end
	end

	-- Points every 0.25 studs along a path's segments.
	local function walkPath(waypoints, visit)
		for i = 2, #waypoints do
			local from, to = waypoints[i - 1].position, waypoints[i].position
			local n = math.max(1, math.ceil((to - from).Magnitude / 0.25))
			for s = 0, n do
				visit(from:Lerp(to, s / n))
			end
		end
	end

	T.describe("Scan seats, slow and no-spawn parts", function()
		T.it("seats attach to the nearest POI", function()
			local registry = Scan.registry(model)
			local seats = Scan.seats(model, registry)
			T.equal(#seats, 2, "the arena has two seats")
			T.equal(#registry:seats(), 2, "both recorded in the registry")
			local seatA, seatFar = nil, nil
			for _, seat in seats do
				if seat.source == made.seatA then
					seatA = seat
				elseif seat.source == made.seatFar then
					seatFar = seat
				end
			end
			T.check(seatA ~= nil and seatFar ~= nil, "records keep the Seat instance as source")
			local hangoutA = recordFor(registry, made.hangoutA)
			T.equal(seatA.poiId, hangoutA.id, "a seat 3 studs from hangoutA belongs to hangoutA")
			T.equal(seatFar.poiId, nil, "a seat 40 studs from everything belongs to no POI")
			T.equal(string.sub(seatA.id, 1, #"SeatA#"), "SeatA#", "seat id from the part name")
			T.check(seatA.id ~= seatFar.id, "seat ids differ")
			-- Every POI is more than 40 studs from the far seat's part.
			for _, poi in registry:all() do
				local p = made.seatFar.CFrame.Position
				local d = math.sqrt((p.X - poi.position.X) ^ 2 + (p.Z - poi.position.Z) ^ 2)
				T.check(d > 40, `{poi.id} is {d} from the far seat`)
			end
			-- seatsNear answers with the free seats around hangoutA, nearest first.
			local near = registry:seatsNear(hangoutA.position, hangoutA.radius)
			T.equal(#near, 1, "one seat within hangoutA's radius")
			T.check(near[1] == seatA, "and it is seatA")
			T.equal(#registry:seatsNear(recordFor(registry, made.shop).position, 7), 0, "no seat by the shop")
			-- A rescan replaces records by id instead of duplicating them.
			Scan.seats(model, registry)
			T.equal(#registry:seats(), 2, "rescan is idempotent")
		end)

		T.it("a seat record is the floor point one stud in front of the seat", function()
			local root = scratchWorld("SeatFront")
			local seat = Scenes.seat(root, Vector3.new(10, 0, 10), Vector3.new(1, 0, 0), "Bench")
			local registry = Scan.registry(root)
			local seats = Scan.seats(root, registry)
			T.equal(#seats, 1)
			T.equal(seats[1].id, "Bench#1")
			nearVector(
				seats[1].position,
				Vector3.new(12, 0, 10),
				1e-3,
				"half the depth plus one stud ahead, on the floor"
			)
			T.check(seats[1].source == seat, "source is the Seat")
			-- Raised seats project to their own base, not the world floor.
			local stool = Scenes.seat(root, Vector3.new(30, 3, 10), Vector3.new(0, 0, 1), "Stool")
			local again = Scan.seats(root, Scan.registry(root))
			T.equal(#again, 2)
			nearVector(again[2].position, Vector3.new(30, 3, 12), 1e-3, "stool front point")
			T.check(again[2].source == stool)
		end)

		T.it("VehicleSeats and NpcSeat-tagged parts are seats; NpcIgnore hides seats and props", function()
			local root = scratchWorld("SeatKinds")
			local vehicle = Instance.new("VehicleSeat")
			vehicle.Name = "Kart"
			vehicle.Anchored = true
			vehicle.Size = Vector3.new(2, 1, 2)
			vehicle.CFrame = CFrame.new(0, 0.5, 0)
			vehicle.Parent = root
			local log = Scenes.block(root, "Log", CFrame.new(20, 0.5, 0), Vector3.new(6, 1, 2))
			log:AddTag("NpcSeat")
			local ignored = Instance.new("Model")
			ignored.Name = "OwnCar"
			ignored:AddTag("NpcIgnore")
			ignored.Parent = root
			Scenes.seat(ignored, Vector3.new(40, 0, 0), nil, "CarSeat")
			Scenes.block(ignored, "CarCrate", CFrame.new(50, 2, 0), Vector3.new(4, 4, 4))
			local crate = Scenes.block(root, "Crate", CFrame.new(70, 2, 0), Vector3.new(4, 4, 4))
			local props = Scan.props(root, true)
			T.equal(#props, 1, "the crate inside the ignored model is not a prop")
			T.equal(props[1].id, "Crate#1")
			T.near(props[1].position.X, crate.CFrame.Position.X, 1e-3)
			local seats = Scan.seats(root, Scan.registry(root))
			T.equal(#seats, 2, "the vehicle seat and the tagged log, not the ignored car seat")
			T.equal(seats[1].id, "Kart#1")
			T.equal(seats[2].id, "Log#2")
			T.equal(seats[1].poiId, nil, "no POIs here")
		end)

		T.it("the registry hands out free seats nearest first and tracks who sits where", function()
			local registry = PoiRegistry.new()
			registry:addSeat({ id = "b", position = Vector3.new(4, 0, 0) })
			registry:addSeat({ id = "a", position = Vector3.new(4, 0, 0) })
			registry:addSeat({ id = "c", position = Vector3.new(1, 0, 0) })
			registry:addSeat({ id = "d", position = Vector3.new(30, 0, 0) })
			local ids = {}
			for _, seat in registry:seatsNear(Vector3.zero, 10) do
				table.insert(ids, seat.id)
			end
			T.equal(table.concat(ids, ","), "c,a,b", "nearest first, ties by id, out of range dropped")
			T.check(registry:occupySeat("c", "n:npc1"), "a free seat is taken")
			T.check(not registry:occupySeat("c", "n:npc2"), "a taken seat is refused")
			T.check(registry:occupySeat("c", "n:npc1"), "the holder may ask again")
			T.equal(registry:seatOccupant("c"), "n:npc1")
			T.equal(registry:seatOccupant("a"), nil)
			T.check(not registry:occupySeat("zzz", "n:npc1"), "an unknown seat is refused")
			ids = {}
			for _, seat in registry:seatsNear(Vector3.zero, 10) do
				table.insert(ids, seat.id)
			end
			T.equal(table.concat(ids, ","), "a,b", "occupied seats are not offered")
			registry:releaseSeat("c", "n:npc2")
			T.equal(registry:seatOccupant("c"), "n:npc1", "only the holder can release")
			registry:releaseSeat("c", "n:npc1")
			T.equal(registry:seatOccupant("c"), nil, "released")
			T.equal(#registry:seatsNear(Vector3.zero, 10), 3)
			registry:occupySeat("d", "n:npc3")
			registry:removeSeat("d")
			T.equal(#registry:seats(), 3, "removed")
			T.equal(registry:seatOccupant("d"), nil, "removing a seat clears its occupant")
			registry:addSeat({ id = "a", position = Vector3.new(50, 0, 0), poiId = "x" })
			T.equal(#registry:seats(), 3, "adding an existing id replaces the record")
			T.equal(registry:seats()[2].poiId, "x", "in place")
		end)

		T.it("NpcSlow raises cell cost", function()
			-- A fresh session so the arena is the only thing sampled; the window covers the strip.
			local world = Loader.new()
			local arena, parts = Scenes.arena(world)
			local NavGrid = world.require(world.game.ServerStorage.HumanlikeNpc.Nav.NavGrid)
			local grid = NavGrid.new({ minX = 40, minZ = -30, maxX = 60, maxZ = 10, cellSize = 2 })
			grid:sample(world.world)
			local slow = Scan.slowParts(arena)
			T.equal(#slow, 1, "one slow part in the arena")
			T.check(slow[1].part == parts.slow, "it is the strip")
			T.equal(slow[1].cost, 4, "NavCost 4")
			local centre = parts.slow.CFrame.Position
			T.check(grid:isWalkable(grid:cellOf(centre)), "the strip does not change what is walkable")
			T.equal(costAt(grid, centre), nil, "no cost before it is applied")
			local plain = grid:findPath(Vector3.new(47, 0, -7), Vector3.new(57, 0, -7))
			applySlow(grid, slow)
			T.equal(costAt(grid, centre), 4, "grid cost under the part is 4")
			T.equal(costAt(grid, centre + Vector3.new(-6, 0, 0)), nil, "outside the strip stays at 1")
			local slowed = grid:findPath(Vector3.new(47, 0, -7), Vector3.new(57, 0, -7))
			T.equal(plain.status, "Success")
			T.equal(slowed.status, "Success")
			-- Two cells crossed at x4 instead of x1: 12 studs-equivalent more.
			T.near(slowed.cost, plain.cost + 12, 0.01, "crossing the strip costs more")
		end)

		T.it("slowParts reads NavCost with default 4 and noSpawnParts lists NpcNoSpawn volumes", function()
			local root = scratchWorld("SlowAndNoSpawn")
			local mud = Scenes.slowArea(root, Vector3.new(0, 1, 0), Vector3.new(8, 2, 8), 2.5)
			local stairs = Scenes.block(root, "Stairs", CFrame.new(20, 1, 0), Vector3.new(8, 2, 8))
			stairs:AddTag("NpcSlow")
			local odd = Scenes.block(root, "Odd", CFrame.new(40, 1, 0), Vector3.new(8, 2, 8))
			odd:AddTag("NpcSlow")
			odd:SetAttribute("NavCost", "muddy")
			local tagged = Instance.new("Model")
			tagged.Name = "Swamp"
			tagged:AddTag("NpcSlow")
			tagged:AddTag("NpcNoSpawn")
			tagged.Parent = root
			local slow = Scan.slowParts(root)
			T.equal(#slow, 3, "three slow parts; the Model is not a part")
			T.check(slow[1].part == mud and slow[1].cost == 2.5, "NavCost read")
			T.check(slow[2].part == stairs and slow[2].cost == 4, "default 4")
			T.check(slow[3].part == odd and slow[3].cost == 4, "a non-number NavCost falls back to 4")
			T.equal(#Scan.noSpawnParts(root), 0, "no no-spawn parts yet")
			local nest = Scenes.noSpawnArea(root, Vector3.new(0, 2, 30), Vector3.new(10, 4, 10))
			local parts = Scan.noSpawnParts(root)
			T.equal(#parts, 1)
			T.check(parts[1] == nest and parts[1]:HasTag("NpcNoSpawn"))
			T.equal(#Scan.noSpawnParts(model), 0, "the arena has none")
			T.equal(#Scan.avoidParts(root), 0, "slow and no-spawn parts are not avoid parts")
		end)
	end)

	T.describe("Scenes gauntlet and plaza", function()
		T.it("the gauntlet builds and its route is walkable end to end with one jump across the gap", function()
			local world = Loader.new()
			local gauntlet, g = Scenes.gauntlet(world)
			local NavGrid = world.require(world.game.ServerStorage.HumanlikeNpc.Nav.NavGrid)
			for _, name in { "start", "door", "gap", "pocket", "strip", "objective", "ramp", "bypass" } do
				T.check(g[name] ~= nil, `made.{name} exists`)
			end
			local registry = Scan.registry(gauntlet)
			T.equal(#registry:all(), 1, "one POI")
			T.equal(registry:all()[1].kind, "objective")
			T.near(registry:all()[1].position.Y, 4, 1e-3, "the objective stands on the raised floor")
			T.equal(#registry.spawns, 1, "one spawn area")
			T.equal(#registry.avoids, 1, "one no-go strip")
			T.check(registry.avoids[1].cframe.Position == g.strip.CFrame.Position, "the avoid record is the strip")
			T.equal(#Scan.props(gauntlet, true), 0, "nothing in the gauntlet reads as a crate")
			T.check(not registry:isAvoided(g.bypass + Vector3.new(0, 1, 0)), "the bypass is outside the strip")

			-- The gauntlet grid is sampled once per process and shared with Integration (FakeWorld's cache).
			local grid, walkable = FakeWorld.sampledGrid(world, "gauntlet", gauntlet)
			T.check(walkable > 1000, `only {walkable} walkable cells`)
			local rx, rz = grid:cellOf(Vector3.new(0, 0, 60))
			local rampY = grid:floorAt(rx, rz)
			T.check(rampY ~= nil and rampY > 0.5 and rampY < 3.5, `ramp middle walkable mid-height, got {rampY}`)
			local bx, bz = grid:cellOf(g.bypass)
			T.check(grid:isWalkable(bx, bz), "the bypass cell is walkable")
			local sx, sz = grid:cellOf(g.strip.CFrame.Position)
			T.check(grid:isBlocked(sx, sz), "the strip's cells are blocked")

			local start = g.start.CFrame.Position
			local goal = registry:all()[1].position
			local result = grid:findPath(Vector3.new(start.X, 0, start.Z), goal)
			T.equal(result.status, "Success", "spawn to objective")
			local jumps = 0
			for _, w in result.waypoints do
				if w.action == "Jump" then
					jumps += 1
				end
			end
			T.equal(jumps, 1, "exactly one jump: the gap")
			local inStrip, throughDoor, overGap = false, false, false
			walkPath(result.waypoints, function(q)
				local probe = Vector3.new(q.X, q.Y + 1, q.Z)
				inStrip = inStrip or registry:isAvoided(probe)
				throughDoor = throughDoor or Scenes.inside(g.door, probe)
				overGap = overGap or Scenes.inside(g.gap, probe)
			end)
			T.check(not inStrip, "the path never enters the no-go strip")
			T.check(throughDoor, "the path goes through the door")
			T.check(overGap, "the path crosses the gap")
			T.near(result.waypoints[#result.waypoints].position.Y, 4, 1e-3, "arrives on the raised floor")
			T.check(NavGrid.pathLength(result.waypoints) > 150, "a long walk")
			-- Without jumping the corridor is cut at the gap.
			T.check(grid:findPath(Vector3.new(start.X, 0, start.Z), goal, { jumpHeight = 0 }).status ~= "Success")
		end)

		T.it("the plaza builds with 12 POIs, 3 spawns, 2 avoids and 20 auto-detected props", function()
			local world = Loader.new()
			local plaza, p = Scenes.plaza(world)
			local registry = Scan.registry(plaza)
			T.equal(#registry:all(), 12, "POI count")
			T.equal(#registry:byKind("shop"), 3)
			T.equal(#registry:byKind("hangout"), 5)
			T.equal(#registry:byKind("viewpoint"), 2)
			T.equal(#registry:byKind("objective"), 2)
			for _, hangout in registry:byKind("hangout") do
				T.equal(hangout.capacity, 4, `{hangout.id} capacity`)
			end
			for _, poi in registry:all() do
				T.near(poi.position.Y, 0, 1e-3, `{poi.id} on the floor`)
				T.check(not registry:isAvoided(poi.position + Vector3.new(0, 1, 0)), `{poi.id} outside the pools`)
			end
			T.equal(#registry.spawns, 3, "spawn areas")
			T.equal(#registry.avoids, 2, "no-go pools")
			T.equal(#p.pois, 12)
			T.equal(#p.props, 20)
			local props = Scan.props(plaza, true)
			T.equal(#props, 20, "twenty crates and nothing else")
			for _, prop in props do
				T.near(prop.top, 4, 1e-3, `{prop.id} top`)
				T.check(not registry:isAvoided(prop.position + Vector3.new(0, 1, 0)), `{prop.id} outside the pools`)
				for _, poi in registry:all() do
					local d = math.sqrt((prop.position.X - poi.position.X) ^ 2 + (prop.position.Z - poi.position.Z) ^ 2)
					T.check(d >= 10 - 1e-6, `{prop.id} is {d} from {poi.id}`)
				end
			end
			for i = 1, 3 do
				local point = registry:spawnPoint(0.5, 0.5, i)
				T.check(point ~= nil and not registry:isAvoided(point + Vector3.new(0, 1, 0)), `spawn {i} is usable`)
			end
			T.equal(#Scan.seats(plaza, registry), 0, "no seats in the plaza")
			T.equal(#Scan.slowParts(plaza), 0, "no slow parts in the plaza")
		end)
	end)
end

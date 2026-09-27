return function(T, Loader)
	local session = Loader.new()
	local Scatter = session.require(session.game.ServerStorage.Builders.Scatter)

	local bounds = { minX = 0, minZ = 0, maxX = 100, maxZ = 60 }

	T.describe("Scatter", function()
		T.it("edgeFactor is 0 on the edge and 1 on the short-axis centerline", function()
			T.near(Scatter.edgeFactor(bounds, 0, 30), 0, 1e-9)
			T.near(Scatter.edgeFactor(bounds, 50, 0), 0, 1e-9)
			T.near(Scatter.edgeFactor(bounds, 50, 30), 1, 1e-9)
			T.near(Scatter.edgeFactor(bounds, 50, 15), 0.5, 1e-9)
		end)

		T.it("grid rejects overlapping circles and accepts touching-free ones", function()
			local grid = Scatter.newGrid(4)
			grid:add(10, 10, 3)
			T.check(not grid:fits(14, 10, 2), "overlapping circle should not fit")
			T.check(grid:fits(15.5, 10, 2), "separate circle should fit")
			T.check(not grid:fits(15.5, 10, 2, 1), "padding should push it out")
			grid:add(40, 40, 8)
			T.check(not grid:fits(49, 40, 2), "large radius neighbors must be found across cells")
		end)

		T.it("insideAny finds reserved circles", function()
			local circles = { { x = 0, z = 0, r = 5 } }
			T.check(Scatter.insideAny(circles, 6, 0, 2), "footprint overlaps the reserved circle")
			T.check(not Scatter.insideAny(circles, 8, 0, 2), "footprint is clear")
		end)

		T.it("perimeter includes all four corners, inset, with sensible spacing", function()
			local points = Scatter.perimeter(bounds, 3, 20)
			local corners = { { 3, 3 }, { 97, 3 }, { 97, 57 }, { 3, 57 } }
			for _, corner in corners do
				local found = false
				for _, p in points do
					if math.abs(p.x - corner[1]) < 1e-9 and math.abs(p.z - corner[2]) < 1e-9 then
						found = true
					end
				end
				T.check(found, `missing corner {corner[1]},{corner[2]}`)
			end
			for i, p in points do
				local q = points[i % #points + 1]
				local gap = math.abs(p.x - q.x) + math.abs(p.z - q.z)
				T.check(gap > 10 and gap < 30, `uneven spacing {gap}`)
			end
		end)

		T.it("perimeter is empty when the inset swallows the zone", function()
			T.equal(#Scatter.perimeter({ minX = 0, minZ = 0, maxX = 4, maxZ = 4 }, 3, 10), 0)
		end)
	end)
end

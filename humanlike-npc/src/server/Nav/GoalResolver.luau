--!strict
-- When a goal cannot be reached, a person walks as close as they can, looks at it, and leaves;
-- they do not stand still computing. This turns an unreachable goal into a short list of
-- reachable stand-ins: points along the line toward it, and the nearest other place of
-- interest. The planner tries them in order and tells the brain which one it ended up with.

local NavGrid = require(script.Parent.NavGrid)
local NavMath = require(script.Parent.NavMath)
local PoiRegistry = require(script.Parent.Parent.World.PoiRegistry)

type Grid = NavGrid.Grid
type Registry = PoiRegistry.Registry

local GoalResolver = {}
GoalResolver.__index = GoalResolver

export type Reason = "original" | "lineFraction" | "nearestPoi"

export type Candidate = { goal: Vector3, reason: Reason, fraction: number? }

export type Resolver = typeof(setmetatable(
	{} :: {
		grid: Grid?,
		pois: Registry?,
		floorProbe: ((Vector3) -> Vector3?)?,
	},
	GoalResolver
))

function GoalResolver.new(grid: Grid?, pois: Registry?, floorProbe: ((Vector3) -> Vector3?)?): Resolver
	return setmetatable({ grid = grid, pois = pois, floorProbe = floorProbe }, GoalResolver)
end

-- Projects a point onto walkable ground when a grid is available (nearest walkable cell center).
local function snap(self: Resolver, point: Vector3): Vector3?
	local probed = if self.floorProbe then self.floorProbe(point) else point
	if not probed then
		return nil
	end
	if self.grid then
		local ix, iz = self.grid:nearestWalkable(probed, 8)
		if not ix then
			return nil
		end
		return self.grid:centerOf(ix :: number, iz :: number)
	end
	return probed
end

function GoalResolver.candidates(self: Resolver, start: Vector3, goal: Vector3, maxCount: number?): { Candidate }
	local out: { Candidate } = {}
	local limit = maxCount or 3
	for _, fraction in { 0.75, 0.5, 0.25 } do
		if #out >= limit then
			break
		end
		local point = start:Lerp(goal, fraction)
		local snapped = snap(self, point)
		if snapped and NavMath.flatDistance(snapped, start) > 4 then
			table.insert(out, { goal = snapped, reason = "lineFraction", fraction = fraction })
		end
	end
	if #out < limit and self.pois then
		local excludeId: string? = nil
		local atGoal = self.pois:within(goal, 1)
		if #atGoal > 0 then
			excludeId = atGoal[1].id
		end
		local poi = self.pois:nearest(goal, excludeId)
		if poi and NavMath.flatDistance(poi.position, start) > 4 then
			table.insert(out, { goal = poi.position, reason = "nearestPoi" })
		end
	end
	return out
end

return GoalResolver

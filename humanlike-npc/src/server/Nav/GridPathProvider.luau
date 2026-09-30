--!strict
-- PathProvider over a NavGrid: the provider the tests use and the in-game fallback when the
-- engine's pathfinder says NoPath. Requests are queued and a bounded number is answered per
-- step, in priority order (a blocked NPC first, a dormant one last), so many NPCs re-planning at
-- once cost a few searches per frame rather than all of them.

local NavGrid = require(script.Parent.NavGrid)
local NavMath = require(script.Parent.NavMath)
local Types = require(script.Parent.Parent.Types)

type Grid = NavGrid.Grid
type PathResult = Types.PathResult
type Waypoint = Types.Waypoint

local GridPathProvider = {}
GridPathProvider.__index = GridPathProvider

export type PathRequest = {
	id: number,
	agentId: string,
	start: Vector3,
	goal: Vector3,
	priority: number, -- 0 urgent .. 4 dormant
	allowPartial: boolean?,
	canJump: boolean?,
	issuedAt: number,
}

export type Completion = { id: number, agentId: string, result: PathResult }

export type Options = {
	maxPerStep: number?, -- searches answered per step; default 2
	maxNodes: number?, -- A* expansions per search; default 6000
	jumpHeight: number?,
	maxJumpGap: number?,
	stepHeight: number?,
}

export type Provider = typeof(setmetatable(
	{} :: {
		name: string,
		grid: Grid,
		queue: { PathRequest },
		maxPerStep: number,
		maxNodes: number,
		jumpHeight: number,
		maxJumpGap: number,
		stepHeight: number,
		penalties: { [string]: { cells: { { number } }, until_: number } },
		searches: number,
	},
	GridPathProvider
))

function GridPathProvider.new(grid: Grid, options: Options?): Provider
	local o: Options = options or {}
	return setmetatable({
		name = "grid",
		grid = grid,
		queue = {},
		maxPerStep = o.maxPerStep or 2,
		maxNodes = o.maxNodes or 6000,
		jumpHeight = o.jumpHeight or 7,
		maxJumpGap = o.maxJumpGap or 6,
		stepHeight = o.stepHeight or 2,
		penalties = {},
		searches = 0,
	}, GridPathProvider)
end

function GridPathProvider.submit(self: Provider, request: PathRequest)
	-- Newest request per agent wins.
	self:cancelAgent(request.agentId)
	table.insert(self.queue, request)
end

function GridPathProvider.cancel(self: Provider, id: number)
	for i, request in self.queue do
		if request.id == id then
			table.remove(self.queue, i)
			return
		end
	end
end

function GridPathProvider.cancelAgent(self: Provider, agentId: string)
	for i = #self.queue, 1, -1 do
		if self.queue[i].agentId == agentId then
			table.remove(self.queue, i)
		end
	end
end

function GridPathProvider.inFlight(self: Provider): number
	return #self.queue
end

-- Makes a few cells expensive for a while (recovery: "I can't get through there").
function GridPathProvider.addPenalty(
	self: Provider,
	agentId: string,
	cells: { { number } },
	multiplier: number,
	untilTime: number
)
	self.penalties[agentId] = { cells = cells, until_ = untilTime }
	for _, cell in cells do
		self.grid:setCost(cell[1], cell[2], multiplier)
	end
end

local function clearExpiredPenalties(self: Provider, now: number)
	for agentId, penalty in self.penalties do
		if now >= penalty.until_ then
			for _, cell in penalty.cells do
				self.grid:setCost(cell[1], cell[2], nil)
			end
			self.penalties[agentId] = nil
		end
	end
end

local function toResult(self: Provider, request: PathRequest, found: NavGrid.PathResult): PathResult
	local waypoints: { Waypoint } = {}
	for _, w in found.waypoints do
		table.insert(waypoints, { position = w.position, action = w.action })
	end
	local goalDistance = 0
	if #waypoints > 0 then
		goalDistance = NavMath.flatDistance(waypoints[#waypoints].position, request.goal)
	end
	local status: Types.PathStatus = found.status
	if status == "Partial" and request.allowPartial == false then
		status = "NoPath"
		waypoints = {}
	end
	return { status = status, waypoints = waypoints, provider = "grid", cost = found.cost, goalDistance = goalDistance }
end

-- Answers up to maxPerStep queued requests, most urgent first.
function GridPathProvider.step(self: Provider, now: number): { Completion }
	clearExpiredPenalties(self, now)
	local completions: { Completion } = {}
	if #self.queue == 0 then
		return completions
	end
	table.sort(self.queue, function(a, b)
		if a.priority == b.priority then
			return a.issuedAt < b.issuedAt
		end
		return a.priority < b.priority
	end)
	for _ = 1, self.maxPerStep do
		local request = table.remove(self.queue, 1)
		if not request then
			break
		end
		local found = self.grid:findPath(request.start, request.goal, {
			maxNodes = self.maxNodes,
			jumpHeight = if request.canJump == false then 0 else self.jumpHeight,
			maxJumpGap = self.maxJumpGap,
			stepHeight = self.stepHeight,
		})
		self.searches += 1
		table.insert(
			completions,
			{ id = request.id, agentId = request.agentId, result = toResult(self, request, found) }
		)
	end
	return completions
end

return GridPathProvider

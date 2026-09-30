--!strict
-- PathProvider over a NavGrid: the provider the tests use and the in-game fallback when the
-- engine's pathfinder says NoPath. Requests are queued and answered in priority order (a blocked
-- NPC first, a dormant one last), so many NPCs re-planning at once cost a few searches per frame
-- rather than all of them.
--
-- Two modes. Without `budgetMs` (the default) a step answers up to `maxPerStep` requests with
-- synchronous searches, exactly as it always has. With `budgetMs` a step is a time slice: one
-- search at a time lives in a coroutine that NavGrid yields every `yieldEvery` expanded nodes, and
-- `step` resumes it while `spent()` (milliseconds used so far this step, supplied by the caller;
-- estimated at 20 us per node when absent) stays under the budget. A request cancelled mid-search
-- is dropped and its coroutine abandoned; one that waits longer than `queueTimeout` completes with
-- `Timeout`. Not a scheduler: whoever calls `step` decides when and how much budget to give.
-- requires: NavGrid, NavMath, Types

local NavGrid = require(script.Parent.NavGrid)
local NavMath = require(script.Parent.NavMath)
local Types = require(script.Parent.Parent.Types)

type Grid = NavGrid.Grid
type PathResult = Types.PathResult
type Waypoint = Types.Waypoint

local GridPathProvider = {}
GridPathProvider.__index = GridPathProvider

-- Structurally the same as Ports.PathRequest.
export type PathRequest = {
	id: number,
	agentId: string,
	start: Vector3,
	goal: Vector3,
	priority: number, -- 0 urgent .. 4 dormant
	allowPartial: boolean?,
	canJump: boolean?,
	issuedAt: number,
	maxNodes: number?, -- per-request node budget (the planner sets it); overrides Options.maxNodes
}

export type Completion = { id: number, agentId: string, result: PathResult }

export type Options = {
	maxPerStep: number?, -- searches answered per synchronous step; default 2
	maxNodes: number?, -- A* expansions per search; default 6000
	jumpHeight: number?,
	maxJumpGap: number?,
	stepHeight: number?,
	budgetMs: number?, -- when set, steps are time slices of this many milliseconds; default nil (synchronous)
	yieldEvery: number?, -- nodes expanded between yields in budgeted mode; default 64
	queueTimeout: number?, -- seconds a request may wait in budgeted mode before it completes as Timeout; default 6
}

-- The one search in progress in budgeted mode.
type Active = {
	request: PathRequest,
	thread: thread,
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
		budgetMs: number?,
		yieldEvery: number,
		queueTimeout: number,
		penalties: { [string]: { cells: { { number } }, until_: number } },
		searches: number,
		resumes: number, -- coroutine resumes so far (budgeted mode), for tuning
		active: Active?,
	},
	GridPathProvider
))

-- Milliseconds one resume is assumed to cost when the caller supplies no `spent`: the measured
-- Lune baseline of about 20 us per expanded node.
local MS_PER_NODE = 0.02

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
		budgetMs = o.budgetMs,
		yieldEvery = o.yieldEvery or 64,
		queueTimeout = o.queueTimeout or 6,
		penalties = {},
		searches = 0,
		resumes = 0,
		active = nil,
	}, GridPathProvider)
end

function GridPathProvider.submit(self: Provider, request: PathRequest)
	-- Newest request per agent wins.
	self:cancelAgent(request.agentId)
	table.insert(self.queue, request)
end

function GridPathProvider.cancel(self: Provider, id: number)
	local active = self.active
	if active and active.request.id == id then
		self.active = nil -- the coroutine is simply never resumed again
		return
	end
	for i, request in self.queue do
		if request.id == id then
			table.remove(self.queue, i)
			return
		end
	end
end

function GridPathProvider.cancelAgent(self: Provider, agentId: string)
	local active = self.active
	if active and active.request.agentId == agentId then
		self.active = nil
	end
	for i = #self.queue, 1, -1 do
		if self.queue[i].agentId == agentId then
			table.remove(self.queue, i)
		end
	end
end

-- Queued plus the one being searched.
function GridPathProvider.inFlight(self: Provider): number
	return #self.queue + (if self.active then 1 else 0)
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
	local expired: { string } = {}
	for agentId, penalty in self.penalties do
		if now >= penalty.until_ then
			table.insert(expired, agentId)
		end
	end
	table.sort(expired)
	for _, agentId in expired do
		for _, cell in self.penalties[agentId].cells do
			self.grid:setCost(cell[1], cell[2], nil)
		end
		self.penalties[agentId] = nil
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

local function emptyResult(request: PathRequest, status: Types.PathStatus): PathResult
	return {
		status = status,
		waypoints = {},
		provider = "grid",
		cost = 0,
		goalDistance = NavMath.flatDistance(request.start, request.goal),
	}
end

local function pathOptions(self: Provider, request: PathRequest, yieldEvery: number?): NavGrid.PathOptions
	return {
		maxNodes = request.maxNodes or self.maxNodes,
		jumpHeight = if request.canJump == false then 0 else self.jumpHeight,
		maxJumpGap = self.maxJumpGap,
		stepHeight = self.stepHeight,
		yieldEvery = yieldEvery,
	}
end

local function sortQueue(self: Provider)
	table.sort(self.queue, function(a, b)
		if a.priority == b.priority then
			if a.issuedAt == b.issuedAt then
				return a.id < b.id
			end
			return a.issuedAt < b.issuedAt
		end
		return a.priority < b.priority
	end)
end

-- Synchronous mode: up to maxPerStep searches, most urgent first.
local function stepSynchronous(self: Provider): { Completion }
	local completions: { Completion } = {}
	if #self.queue == 0 then
		return completions
	end
	sortQueue(self)
	for _ = 1, self.maxPerStep do
		local request = table.remove(self.queue, 1)
		if not request then
			break
		end
		local found = self.grid:findPath(request.start, request.goal, pathOptions(self, request, nil))
		self.searches += 1
		table.insert(
			completions,
			{ id = request.id, agentId = request.agentId, result = toResult(self, request, found) }
		)
	end
	return completions
end

-- Starts the most urgent queued request as the live search, or returns nil when nothing waits.
local function startNext(self: Provider): Active?
	local request = table.remove(self.queue, 1)
	if not request then
		return nil
	end
	local grid = self.grid
	local options = pathOptions(self, request, self.yieldEvery)
	local active: Active = {
		request = request,
		thread = coroutine.create(function()
			return grid:findPath(request.start, request.goal, options)
		end),
	}
	self.active = active
	self.searches += 1
	return active
end

-- Budgeted mode: time out stale requests, then resume (or start) the one search while the budget lasts.
local function stepSliced(self: Provider, now: number, spent: (() -> number)?): { Completion }
	local completions: { Completion } = {}
	local budget = self.budgetMs :: number
	sortQueue(self)
	local kept: { PathRequest } = {}
	for _, request in self.queue do
		if now - request.issuedAt > self.queueTimeout then
			table.insert(
				completions,
				{ id = request.id, agentId = request.agentId, result = emptyResult(request, "Timeout") }
			)
		else
			table.insert(kept, request)
		end
	end
	self.queue = kept

	local estimated = 0
	local function used(): number
		if spent then
			return spent()
		end
		return estimated
	end

	while used() < budget do
		local active = self.active or startNext(self)
		if not active then
			break
		end
		local ok, result = coroutine.resume(active.thread)
		self.resumes += 1
		estimated += MS_PER_NODE * self.yieldEvery
		if not ok then
			self.active = nil
			table.insert(completions, {
				id = active.request.id,
				agentId = active.request.agentId,
				result = emptyResult(active.request, "Error"),
			})
		elseif coroutine.status(active.thread) == "dead" then
			self.active = nil
			table.insert(completions, {
				id = active.request.id,
				agentId = active.request.agentId,
				result = toResult(self, active.request, result :: NavGrid.PathResult),
			})
		end
	end
	return completions
end

-- Answers queued requests, most urgent first: a few whole searches per step, or, with `budgetMs`,
-- as much of one search at a time as `spent()` (milliseconds used so far this step) allows.
function GridPathProvider.step(self: Provider, now: number, spent: (() -> number)?): { Completion }
	clearExpiredPenalties(self, now)
	if self.budgetMs == nil then
		return stepSynchronous(self)
	end
	return stepSliced(self, now, spent)
end

return GridPathProvider

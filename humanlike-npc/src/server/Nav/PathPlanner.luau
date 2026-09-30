--!strict
-- One place that owns every path request. It keeps the engine's pathfinder to a couple of
-- computations in flight, spaces one agent's requests apart, caches recent answers, and when a
-- request fails it walks a ladder: engine -> grid -> nearer stand-in goals -> a straight line if
-- short and clear -> NoPath. Whatever runs the NPCs calls `step` once per frame and hands the
-- completions to their owners.
--
-- It also keeps the ladder honest under load: a short request nobody answered for a while is
-- finished with a straight line or NoPath ("starved"); an engine that keeps timing out is left
-- alone for a while and everything goes to the grid ("backoff"); grid searches carry a node budget
-- scaled to the trip so short trips stay cheap; a start or goal far above or below the grid's
-- floor (a bridge, an upper storey) skips the grid ("offGrid"); and while the engine is backed
-- off and the grid backlog is long, far-tier requests are answered at once with a straight line
-- or NoPath ("shed") so near NPCs keep their latency. It never yields and never touches a Roblox
-- service: providers are injected, time is passed in.

local NavMath = require(script.Parent.NavMath)
local GoalResolver = require(script.Parent.GoalResolver)
local Types = require(script.Parent.Parent.Types)

type PathResult = Types.PathResult
type Waypoint = Types.Waypoint
type Resolver = GoalResolver.Resolver
type Candidate = GoalResolver.Candidate

local PathPlanner = {}
PathPlanner.__index = PathPlanner

export type Request = {
	id: number,
	agentId: string,
	start: Vector3,
	goal: Vector3,
	priority: number, -- 0 urgent (blocked ahead, recovery), 1 near, 2 mid, 3 far, 4 dormant
	allowPartial: boolean?,
	canJump: boolean?,
	forceProvider: ("roblox" | "grid" | "direct")?,
	issuedAt: number,
}

export type Completion = {
	id: number,
	agentId: string,
	result: PathResult,
	-- Which goal the path leads to and why: "original" | "lineFraction" | "nearestPoi" (GoalResolver.Reason)
	-- | "direct" (forceProvider) | "starved" | "backoff" | "offGrid" | "shed" (see the module comment)
	reason: string,
	goal: Vector3, -- the goal actually planned to
}

-- Any provider: the Roblox adapter or the grid provider share this shape (Ports.PathProvider).
-- `spent` reports milliseconds used so far this step; a provider may ignore it.
export type Provider = {
	name: string,
	submit: (self: any, request: any) -> (),
	cancel: (self: any, id: number) -> (),
	cancelAgent: (self: any, agentId: string) -> (),
	step: (self: any, now: number, spent: (() -> number)?) -> { { id: number, agentId: string, result: PathResult } },
	inFlight: (self: any) -> number,
}

export type Params = {
	maxInFlightRoblox: number?, -- default 2
	robloxTimeout: number?, -- default 1.5 s
	cooldown: number?, -- default 1.0 s between one agent's requests (0.25 for priority 0)
	cacheTtl: number?, -- default 2.0 s
	cacheQuantum: number?, -- default 4 studs
	directMax: number?, -- default 24 studs for a straight-line fallback
	losCheck: ((Vector3, Vector3) -> boolean)?, -- for the straight-line fallback
	starvationAfter: number?, -- default 6 s: a request with its goal within 30 studs that waited this long is finished direct/NoPath
	backoffAfter: number?, -- default 5: primary Timeout/Error results ...
	backoffWindow: number?, -- default 60 s: ... within this window ...
	backoffSeconds: number?, -- default 30 s: ... skip the primary for this long
	gridMaxNodes: number?, -- default 4000: cap of the per-request grid node budget
	cellSize: number?, -- default 2: the grid's cell size, for the node budget
	floorAt: ((p: Vector3) -> number?)?, -- the grid's floor under a point (nil = no cell); for the off-grid rule
	shedAbove: number?, -- default 8: grid backlog above which far-tier requests are shed while the primary is backed off
}

type Active = {
	request: Request,
	stage: "roblox" | "grid",
	startedAt: number,
	triedResolver: boolean,
	candidates: { Candidate }?,
	reason: string, -- GoalResolver.Reason of the goal being planned to
	goal: Vector3,
	providerId: number, -- id used with the provider (changes per candidate attempt)
	tag: string?, -- "backoff" | "offGrid" | "starved" | "shed": reported as the reason when the goal stayed the original
	offGrid: boolean,
}

export type Planner = typeof(setmetatable(
	{} :: {
		primary: Provider?,
		fallback: Provider,
		resolver: Resolver,
		params: Params,
		pending: { [string]: Request },
		cooldownUntil: { [string]: number },
		cache: { [string]: { result: PathResult, at: number } },
		active: { [number]: Active }, -- by request id
		byProviderId: { [number]: number }, -- provider id -> request id
		nextProviderId: number,
		waitingForPrimary: { Request },
		cachedCompletions: { Completion }?, -- completions decided inside request(), delivered by the next step
		primaryFailures: { number }, -- times of recent primary Timeout/Error results
		backoffUntil: number,
		stats: {
			queued: number,
			inFlight: number,
			cacheHits: number,
			fallbacks: number,
			completed: number,
			latencySum: number,
		},
	},
	PathPlanner
))

local STARVATION_RANGE = 30 -- studs: only a short request is rescued by the starvation guard
local PRIMARY_MAX_RANGE = 2900 -- studs: PathfindingService stops at 3000, keep a margin
local OFF_GRID_TOLERANCE = 2 + 7 -- stepHeight + jumpHeight: farther from the grid's floor is another storey
local SHED_PRIORITY = 2 -- priority at or beyond which a request belongs to a far tier and may be shed

function PathPlanner.new(primary: Provider?, fallback: Provider, resolver: Resolver, params: Params?): Planner
	return setmetatable({
		primary = primary,
		fallback = fallback,
		resolver = resolver,
		params = params or {},
		pending = {},
		cooldownUntil = {},
		cache = {},
		active = {},
		byProviderId = {},
		nextProviderId = 1000000,
		waitingForPrimary = {},
		cachedCompletions = nil,
		primaryFailures = {},
		backoffUntil = -math.huge,
		stats = { queued = 0, inFlight = 0, cacheHits = 0, fallbacks = 0, completed = 0, latencySum = 0 },
	}, PathPlanner)
end

local function quantize(v: Vector3, q: number): string
	return `{math.floor(v.X / q)},{math.floor(v.Y / q)},{math.floor(v.Z / q)}`
end

local function cacheKey(self: Planner, request: Request): string
	local q = self.params.cacheQuantum or 4
	return `{quantize(request.start, q)}|{quantize(request.goal, q)}|{if request.canJump == false then "nj" else "j"}`
end

-- Drops leading waypoints the agent is already standing on (a cached path from a nearby start).
local function trimStart(result: PathResult, start: Vector3): PathResult
	local waypoints = table.clone(result.waypoints)
	while #waypoints > 1 and NavMath.flatDistance(waypoints[1].position, start) < 2 and waypoints[1].action == "Walk" do
		table.remove(waypoints, 1)
	end
	return {
		status = result.status,
		waypoints = waypoints,
		provider = result.provider,
		cost = result.cost,
		goalDistance = result.goalDistance,
	}
end

-- Request ids in flight, in a fixed order (hash order must never reach the completions).
local function activeIds(self: Planner): { number }
	local ids: { number } = {}
	for id in self.active do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- A* expansions a grid search may spend on this trip: four times the squared cell distance, at
-- least 400, at most gridMaxNodes, so a short hop never pays for an exhaustive search.
local function nodeBudget(self: Planner, start: Vector3, goal: Vector3): number
	local cells = NavMath.flatDistance(start, goal) / (self.params.cellSize or 2)
	local cap = self.params.gridMaxNodes or 4000
	return math.min(math.max(400, math.ceil(cells * cells * 4)), cap)
end

-- A start or goal more than a step plus a jump away from the grid's floor is on another level the
-- 2.5-D grid cannot see (a bridge, an upper storey): the grid would plan on the wrong floor.
local function isOffGrid(self: Planner, request: Request): boolean
	local floorAt = self.params.floorAt
	if not floorAt then
		return false
	end
	for _, point in { request.start, request.goal } do
		local y = floorAt(point)
		if y ~= nil and math.abs(point.Y - y) > OFF_GRID_TOLERANCE then
			return true
		end
	end
	return false
end

local function directOrNoPath(self: Planner, request: Request): PathResult
	local distance = NavMath.flatDistance(request.start, request.goal)
	local los = self.params.losCheck
	if distance <= (self.params.directMax or 24) and los and los(request.start, request.goal) then
		local waypoints: { Waypoint } = {}
		local steps = math.max(1, math.ceil(distance / 4))
		for i = 0, steps do
			table.insert(waypoints, { position = request.start:Lerp(request.goal, i / steps), action = "Walk" })
		end
		return { status = "Success", waypoints = waypoints, provider = "direct", cost = distance, goalDistance = 0 }
	end
	return { status = "NoPath", waypoints = {}, provider = "direct", cost = 0, goalDistance = distance }
end

-- A completion decided while the request was made. It is delivered by the next step, never
-- synchronously inside request(), so completions always reach their owners the same way.
local function completeNextStep(self: Planner, request: Request, result: PathResult, reason: string, now: number)
	self.active[request.id] = {
		request = request,
		stage = "grid",
		startedAt = now,
		triedResolver = false,
		candidates = nil,
		reason = reason,
		goal = request.goal,
		providerId = 0,
		tag = nil,
		offGrid = false,
	}
	local list = self.cachedCompletions or {}
	self.cachedCompletions = list
	table.insert(list, {
		id = request.id,
		agentId = request.agentId,
		result = result,
		reason = reason,
		goal = request.goal,
	})
end

local function submitTo(self: Planner, active: Active, stage: "roblox" | "grid", now: number)
	active.stage = stage
	active.startedAt = now
	local providerId = self.nextProviderId
	self.nextProviderId += 1
	active.providerId = providerId
	self.byProviderId[providerId] = active.request.id
	local request = active.request
	local payload = {
		id = providerId,
		agentId = request.agentId,
		start = request.start,
		goal = active.goal,
		priority = request.priority,
		allowPartial = if request.allowPartial == nil then true else request.allowPartial,
		canJump = request.canJump,
		issuedAt = now,
		maxNodes = if stage == "grid" then nodeBudget(self, request.start, active.goal) else nil,
	}
	if stage == "roblox" then
		(self.primary :: Provider):submit(payload)
	else
		self.fallback:submit(payload)
	end
end

local function begin(self: Planner, request: Request, now: number)
	local force = request.forceProvider
	if force == "direct" then
		completeNextStep(self, request, directOrNoPath(self, request), "direct", now)
		return
	end
	local distance = NavMath.flatDistance(request.start, request.goal)
	local backedOff = now < self.backoffUntil
	local offGrid = isOffGrid(self, request)
	local tag: string? = nil
	local usePrimary = self.primary ~= nil and force ~= "grid"
	if usePrimary and force ~= "roblox" then
		if distance > PRIMARY_MAX_RANGE then
			usePrimary = false
		elseif backedOff then
			usePrimary = false
			tag = "backoff"
		end
	end
	if offGrid then
		tag = "offGrid"
		if not usePrimary then
			completeNextStep(self, request, directOrNoPath(self, request), "offGrid", now)
			return
		end
	end
	if
		not usePrimary
		and backedOff
		and request.priority >= SHED_PRIORITY
		and self.fallback:inFlight() > (self.params.shedAbove or 8)
	then
		completeNextStep(self, request, directOrNoPath(self, request), "shed", now)
		return
	end
	local active: Active = {
		request = request,
		stage = "grid",
		startedAt = now,
		triedResolver = false,
		candidates = nil,
		reason = "original",
		goal = request.goal,
		providerId = 0,
		tag = tag,
		offGrid = offGrid,
	}
	self.active[request.id] = active
	if usePrimary then
		local limit = self.params.maxInFlightRoblox or 2
		if (self.primary :: Provider):inFlight() >= limit then
			table.insert(self.waitingForPrimary, request)
			return
		end
		submitTo(self, active, "roblox", now)
	else
		if tag == "backoff" then
			self.stats.fallbacks += 1
		end
		submitTo(self, active, "grid", now)
	end
end

function PathPlanner.cancel(self: Planner, agentId: string)
	self.pending[agentId] = nil
	for i = #self.waitingForPrimary, 1, -1 do
		if self.waitingForPrimary[i].agentId == agentId then
			table.remove(self.waitingForPrimary, i)
		end
	end
	for _, id in activeIds(self) do
		local active = self.active[id]
		if active.request.agentId == agentId then
			self.byProviderId[active.providerId] = nil
			if active.stage == "roblox" and self.primary then
				self.primary:cancel(active.providerId)
			else
				self.fallback:cancel(active.providerId)
			end
			self.active[id] = nil
		end
	end
end

-- Queues a request. Returns its id. A newer request from the same agent replaces older ones.
function PathPlanner.request(self: Planner, request: Request, now: number): number
	self.stats.queued += 1
	local cooldown = self.cooldownUntil[request.agentId] or -math.huge
	if now < cooldown and request.priority > 0 then
		self.pending[request.agentId] = request
		return request.id
	end
	local key = cacheKey(self, request)
	local cached = self.cache[key]
	if cached and now - cached.at < (self.params.cacheTtl or 2) and cached.result.status == "Success" then
		self.stats.cacheHits += 1
		self:cancel(request.agentId)
		self.cache[key] = cached
		self.pending[request.agentId] = nil
		self.cooldownUntil[request.agentId] = now
			+ (if request.priority == 0 then 0.25 else (self.params.cooldown or 1))
		completeNextStep(self, request, trimStart(cached.result, request.start), "original", now)
		return request.id
	end
	self:cancel(request.agentId)
	self.cooldownUntil[request.agentId] = now + (if request.priority == 0 then 0.25 else (self.params.cooldown or 1))
	begin(self, request, now)
	return request.id
end

local function worthWalking(request: Request, goal: Vector3, result: PathResult): boolean
	if #result.waypoints < 2 then
		return false
	end
	local length = 0
	for i = 2, #result.waypoints do
		length += NavMath.flatDistance(result.waypoints[i - 1].position, result.waypoints[i].position)
	end
	return result.goalDistance <= 0.75 * NavMath.flatDistance(request.start, goal) and length >= 6
end

local function finish(self: Planner, active: Active, result: PathResult, now: number, out: { Completion })
	self.active[active.request.id] = nil
	self.byProviderId[active.providerId] = nil
	self.stats.completed += 1
	self.stats.latencySum += now - active.request.issuedAt
	local reason = active.reason
	local tag = active.tag
	if tag and reason == "original" then
		reason = tag
	end
	table.insert(out, {
		id = active.request.id,
		agentId = active.request.agentId,
		result = result,
		reason = reason,
		goal = active.goal,
	})
end

-- Ends the ladder at the original goal with a straight line or NoPath, labelled with `tag`.
local function finishDirect(self: Planner, active: Active, tag: string, now: number, out: { Completion })
	active.goal = active.request.goal
	active.reason = "original"
	active.tag = tag
	finish(self, active, directOrNoPath(self, active.request), now, out)
end

local function tryNextCandidate(self: Planner, active: Active, now: number, out: { Completion })
	local candidates = active.candidates :: { Candidate }
	local candidate = table.remove(candidates, 1)
	if not candidate then
		finish(self, active, directOrNoPath(self, active.request), now, out)
		return
	end
	active.goal = candidate.goal
	active.reason = candidate.reason
	submitTo(self, active, "grid", now)
end

local function demote(self: Planner, active: Active, now: number, out: { Completion })
	self.stats.fallbacks += 1
	if active.stage == "roblox" then
		if active.offGrid then
			finishDirect(self, active, "offGrid", now, out)
		else
			submitTo(self, active, "grid", now)
		end
	elseif not active.triedResolver then
		active.triedResolver = true
		active.candidates = self.resolver:candidates(active.request.start, active.request.goal, 3)
		tryNextCandidate(self, active, now, out)
	elseif active.candidates and #active.candidates > 0 then
		tryNextCandidate(self, active, now, out)
	else
		finish(self, active, directOrNoPath(self, active.request), now, out)
	end
end

-- A primary Timeout or Error. Enough of them inside the window back the primary off for a while.
local function recordPrimaryFailure(self: Planner, now: number)
	local failures = self.primaryFailures
	table.insert(failures, now)
	local window = self.params.backoffWindow or 60
	while #failures > 0 and now - failures[1] > window do
		table.remove(failures, 1)
	end
	if #failures >= (self.params.backoffAfter or 5) then
		self.backoffUntil = now + (self.params.backoffSeconds or 30)
		self.primaryFailures = {}
	end
end

local function handle(
	self: Planner,
	completion: { id: number, agentId: string, result: PathResult },
	now: number,
	out: { Completion }
)
	local requestId = self.byProviderId[completion.id]
	if not requestId then
		return -- cancelled
	end
	local active = self.active[requestId]
	if not active or active.providerId ~= completion.id then
		return
	end
	local result = completion.result
	if result.status == "Success" then
		if active.reason == "original" then
			self.cache[cacheKey(self, active.request)] = { result = result, at = now }
		end
		finish(self, active, result, now, out)
	elseif result.status == "Partial" and worthWalking(active.request, active.goal, result) then
		finish(self, active, result, now, out)
	else
		if active.stage == "roblox" and (result.status == "Timeout" or result.status == "Error") then
			recordPrimaryFailure(self, now)
		end
		demote(self, active, now, out)
	end
end

-- A request nobody answered for starvationAfter seconds, with its goal close by: stop waiting.
local function starve(self: Planner, now: number, out: { Completion })
	local after = self.params.starvationAfter or 6
	for _, id in activeIds(self) do
		local active = self.active[id]
		local request = active.request
		if now - request.issuedAt > after and NavMath.flatDistance(request.start, request.goal) <= STARVATION_RANGE then
			for i = #self.waitingForPrimary, 1, -1 do
				if self.waitingForPrimary[i].id == id then
					table.remove(self.waitingForPrimary, i)
				end
			end
			if active.providerId ~= 0 then
				if active.stage == "roblox" and self.primary then
					self.primary:cancel(active.providerId)
				else
					self.fallback:cancel(active.providerId)
				end
			end
			finishDirect(self, active, "starved", now, out)
		end
	end
end

-- Once per frame. Returns the completions to hand to their agents. `spent` (milliseconds used so
-- far this frame) is passed to the providers, so a budgeted one knows how much it may still do.
function PathPlanner.step(self: Planner, now: number, spent: (() -> number)?): { Completion }
	local out: { Completion } = {}
	local cachedCompletions = self.cachedCompletions
	if cachedCompletions then
		for _, c in cachedCompletions do
			if self.active[c.id] then
				self.active[c.id] = nil
				self.stats.completed += 1
				table.insert(out, c)
			end
		end
		self.cachedCompletions = nil
	end

	local primary = self.primary
	if primary then
		for _, c in primary:step(now, spent) do
			handle(self, c, now, out)
		end
		-- Timeouts on the engine side demote to the grid.
		local timeout = self.params.robloxTimeout or 1.5
		for _, id in activeIds(self) do
			local active = self.active[id]
			if active and active.stage == "roblox" and active.providerId ~= 0 and now - active.startedAt > timeout then
				primary:cancel(active.providerId)
				self.byProviderId[active.providerId] = nil
				recordPrimaryFailure(self, now)
				demote(self, active, now, out)
			end
		end
		-- Admit waiting requests as slots free up; while backed off they all go to the grid.
		local limit = self.params.maxInFlightRoblox or 2
		local backedOff = now < self.backoffUntil
		while #self.waitingForPrimary > 0 and (backedOff or primary:inFlight() < limit) do
			local request = table.remove(self.waitingForPrimary, 1) :: Request
			local active = self.active[request.id]
			if active then
				if backedOff and request.forceProvider ~= "roblox" then
					active.tag = active.tag or "backoff"
					self.stats.fallbacks += 1
					if active.offGrid then
						finishDirect(self, active, "offGrid", now, out)
					else
						submitTo(self, active, "grid", now)
					end
				else
					submitTo(self, active, "roblox", now)
				end
			end
		end
	end
	for _, c in self.fallback:step(now, spent) do
		handle(self, c, now, out)
	end
	starve(self, now, out)
	-- Pending requests whose cooldown ended.
	local agents: { string } = {}
	for agentId in self.pending do
		table.insert(agents, agentId)
	end
	table.sort(agents)
	for _, agentId in agents do
		local request = self.pending[agentId]
		if request and now >= (self.cooldownUntil[agentId] or 0) then
			self.pending[agentId] = nil
			self:request(request, now)
		end
	end
	local inFlight = 0
	for _ in self.active do
		inFlight += 1
	end
	self.stats.inFlight = inFlight
	return out
end

-- The engine reported the path blocked at a waypoint ahead: re-plan urgently.
function PathPlanner.notifyBlocked(self: Planner, request: Request, now: number): number
	request.priority = 0
	return self:request(request, now)
end

function PathPlanner.getStats(self: Planner): {
	queued: number,
	inFlight: number,
	cacheHits: number,
	fallbacks: number,
	completed: number,
	avgLatency: number,
	backoffUntil: number,
}
	local s = self.stats
	return {
		queued = s.queued,
		inFlight = s.inFlight,
		cacheHits = s.cacheHits,
		fallbacks = s.fallbacks,
		completed = s.completed,
		avgLatency = if s.completed > 0 then s.latencySum / s.completed else 0,
		backoffUntil = self.backoffUntil,
	}
end

return PathPlanner

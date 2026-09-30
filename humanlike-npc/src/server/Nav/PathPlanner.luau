--!strict
-- One place that owns every path request. It keeps the engine's pathfinder to a couple of
-- computations in flight, spaces one agent's requests apart, caches recent answers, and when a
-- request fails it walks a ladder: engine -> grid -> nearer stand-in goals -> a straight line if
-- short and clear -> NoPath. Whatever runs the NPCs calls `step` once per frame and hands the
-- completions to their owners.

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
	forceProvider: ("roblox" | "grid")?,
	issuedAt: number,
}

export type Completion = {
	id: number,
	agentId: string,
	result: PathResult,
	reason: GoalResolver.Reason, -- which goal the path actually leads to
	goal: Vector3, -- the goal actually planned to
}

-- Any provider: the Roblox adapter or the grid provider share this shape.
export type Provider = {
	name: string,
	submit: (self: any, request: any) -> (),
	cancel: (self: any, id: number) -> (),
	cancelAgent: (self: any, agentId: string) -> (),
	step: (self: any, now: number) -> { { id: number, agentId: string, result: PathResult } },
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
}

type Active = {
	request: Request,
	stage: "roblox" | "grid",
	startedAt: number,
	triedResolver: boolean,
	candidates: { Candidate }?,
	reason: GoalResolver.Reason,
	goal: Vector3,
	providerId: number, -- id used with the provider (changes per candidate attempt)
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
		cachedCompletions: { Completion }?,
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
	}
	if stage == "roblox" then
		(self.primary :: Provider):submit(payload)
	else
		self.fallback:submit(payload)
	end
end

local function begin(self: Planner, request: Request, now: number)
	local active: Active = {
		request = request,
		stage = "grid",
		startedAt = now,
		triedResolver = false,
		candidates = nil,
		reason = "original",
		goal = request.goal,
		providerId = 0,
	}
	self.active[request.id] = active
	local usePrimary = self.primary ~= nil and request.forceProvider ~= "grid"
	if request.forceProvider == "roblox" and self.primary == nil then
		usePrimary = false
	end
	if usePrimary then
		local limit = self.params.maxInFlightRoblox or 2
		if (self.primary :: Provider):inFlight() >= limit then
			table.insert(self.waitingForPrimary, request)
			return
		end
		submitTo(self, active, "roblox", now)
	else
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
	for id, active in self.active do
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
		local active: Active = {
			request = request,
			stage = "grid",
			startedAt = now,
			triedResolver = false,
			reason = "original",
			goal = request.goal,
			providerId = 0,
		}
		self.active[request.id] = active
		-- Completed on the next step so completions always flow through the same path.
		active.candidates = nil
		self.cache[key] = cached
		self.pending[request.agentId] = nil
		self.cooldownUntil[request.agentId] = now
			+ (if request.priority == 0 then 0.25 else (self.params.cooldown or 1))
		-- Store a synthetic completion to be flushed by step().
		local list = self.cachedCompletions or {}
		self.cachedCompletions = list
		table.insert(list, {
			id = request.id,
			agentId = request.agentId,
			result = trimStart(cached.result, request.start),
			reason = "original",
			goal = request.goal,
		})
		return request.id
	end
	self:cancel(request.agentId)
	self.cooldownUntil[request.agentId] = now + (if request.priority == 0 then 0.25 else (self.params.cooldown or 1))
	begin(self, request, now)
	return request.id
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
	table.insert(out, {
		id = active.request.id,
		agentId = active.request.agentId,
		result = result,
		reason = active.reason,
		goal = active.goal,
	})
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
		submitTo(self, active, "grid", now)
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
		demote(self, active, now, out)
	end
end

-- Once per frame. Returns the completions to hand to their agents.
function PathPlanner.step(self: Planner, now: number): { Completion }
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

	if self.primary then
		for _, c in self.primary:step(now) do
			handle(self, c, now, out)
		end
		-- Timeouts on the engine side demote to the grid.
		for _, active in self.active do
			if active.stage == "roblox" and now - active.startedAt > (self.params.robloxTimeout or 1.5) then
				self.primary:cancel(active.providerId)
				self.byProviderId[active.providerId] = nil
				demote(self, active, now, out)
			end
		end
		-- Admit waiting requests as slots free up.
		local limit = self.params.maxInFlightRoblox or 2
		while #self.waitingForPrimary > 0 and self.primary:inFlight() < limit do
			local request = table.remove(self.waitingForPrimary, 1) :: Request
			local active = self.active[request.id]
			if active then
				submitTo(self, active, "roblox", now)
			end
		end
	end
	for _, c in self.fallback:step(now) do
		handle(self, c, now, out)
	end
	-- Pending requests whose cooldown ended.
	for agentId, request in self.pending do
		if now >= (self.cooldownUntil[agentId] or 0) then
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
}
	local s = self.stats
	return {
		queued = s.queued,
		inFlight = s.inFlight,
		cacheHits = s.cacheHits,
		fallbacks = s.fallbacks,
		completed = s.completed,
		avgLatency = if s.completed > 0 then s.latencySum / s.completed else 0,
	}
end

return PathPlanner

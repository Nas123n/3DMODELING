--!strict
-- The primary PathProvider over PathfindingService: one Path instance per agent, reused across requests; at
-- most `maxInFlight` ComputeAsync calls at once, each in its own thread inside pcall; completions are queued
-- and handed out by the next `step`, never from inside the computing thread; a request with no answer within
-- `timeout` completes as Timeout and its late result is discarded. `Path.Blocked` is connected once per Path
-- (into that Path's bag) and drained by `step` into the `onBlocked` callback Api wires to the service. Status
-- map: Success -> Success, NoPath -> NoPath, anything else (the legacy partial statuses) -> Partial, a pcall
-- error -> Error. It never yields inside `step`, never decides what to do with a failure (PathPlanner walks
-- the ladder) and never plans on a grid (GridPathProvider does).
-- requires: Connections, NavMath, Ports (types), Types (types)

local Connections = require(script.Parent.Connections)
local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Ports = require(script.Parent.Parent.Ports)
local Types = require(script.Parent.Parent.Types)

type Bag = Connections.Bag
type PathRequest = Ports.PathRequest
type PathCompletion = Ports.PathCompletion
type PathResult = Types.PathResult
type Waypoint = Types.Waypoint

local RobloxPathProvider = {}
RobloxPathProvider.__index = RobloxPathProvider

export type AgentOptions = {
	radius: number?, -- AgentRadius, default 2
	height: number?, -- AgentHeight, default 5
	canJump: boolean?, -- AgentCanJump default (a request's canJump overrides); default true
	canClimb: boolean?, -- AgentCanClimb, default false
	waypointSpacing: number?, -- default 4
	costs: { [string]: number }?, -- default { NoGo = math.huge, Slow = 4, Water = 8 }
}

export type Options = {
	bag: Bag, -- parent bag; the provider makes a child bag and one per Path
	maxInFlight: number?, -- Config.MaxInFlightRoblox, default 2
	timeout: number?, -- Config.RobloxTimeout, default 1.5 s
	agent: AgentOptions?,
	onBlocked: ((agentId: string, blockedIndex: number, now: number) -> ())?, -- Api -> service:onBlocked
}

type PathEntry = {
	path: Path,
	bag: Bag,
	canJump: boolean,
}

type Active = {
	request: PathRequest,
	startedAt: number,
	thread: thread?,
}

type Blocked = { agentId: string, index: number }

export type Stats = {
	computed: number,
	success: number,
	noPath: number,
	partial: number,
	errors: number,
	timeouts: number,
	blocked: number,
	paths: number,
}

export type Provider = typeof(setmetatable(
	{} :: {
		name: string,
		bag: Bag,
		maxInFlight: number,
		timeout: number,
		agent: AgentOptions,
		onBlocked: ((agentId: string, blockedIndex: number, now: number) -> ())?,
		paths: { [string]: PathEntry },
		queue: { PathRequest },
		active: { [number]: Active },
		completions: { PathCompletion },
		blockedQueue: { Blocked },
		stats: Stats,
		destroyed: boolean,
	},
	RobloxPathProvider
))

local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

function RobloxPathProvider.new(options: Options): Provider
	local agent: AgentOptions = options.agent or {}
	return setmetatable({
		name = "roblox",
		bag = options.bag:child("pathProvider"),
		maxInFlight = options.maxInFlight or 2,
		timeout = options.timeout or 1.5,
		agent = agent,
		onBlocked = options.onBlocked,
		paths = {},
		queue = {},
		active = {},
		completions = {},
		blockedQueue = {},
		stats = { computed = 0, success = 0, noPath = 0, partial = 0, errors = 0, timeouts = 0, blocked = 0, paths = 0 },
		destroyed = false,
	}, RobloxPathProvider)
end

-- The agent parameter table CreatePath takes, for one jump setting.
function RobloxPathProvider.agentParameters(agent: AgentOptions, canJump: boolean): { [string]: any }
	local costs = agent.costs or { NoGo = math.huge, Slow = 4, Water = 8 }
	return {
		AgentRadius = agent.radius or 2,
		AgentHeight = agent.height or 5,
		AgentCanJump = canJump,
		AgentCanClimb = agent.canClimb == true,
		WaypointSpacing = agent.waypointSpacing or 4,
		Costs = costs,
	}
end

local function destroyEntry(entry: PathEntry)
	entry.bag:disconnectAll()
	pcall(function()
		entry.path:Destroy()
	end)
end

-- The agent's Path, created on first use (and recreated when its jump setting changes).
local function pathFor(self: Provider, agentId: string, canJump: boolean): Path?
	local entry: PathEntry? = self.paths[agentId]
	if entry and entry.canJump ~= canJump then
		destroyEntry(entry)
		self.paths[agentId] = nil
		entry = nil
	end
	if entry then
		return entry.path
	end
	local created: Path? = nil
	local ok = pcall(function()
		local PathfindingService = game:GetService("PathfindingService")
		created = PathfindingService:CreatePath(RobloxPathProvider.agentParameters(self.agent, canJump))
	end)
	local path = created
	if not ok or path == nil then
		return nil
	end
	local bag = self.bag:child(`path:{agentId}`)
	pcall(function()
		bag:add(path.Blocked:Connect(function(index: number)
			table.insert(self.blockedQueue, { agentId = agentId, index = index })
		end))
	end)
	self.paths[agentId] = { path = path, bag = bag, canJump = canJump }
	self.stats.paths += 1
	return path
end

-- Maps the engine's waypoints to the core's (Jump/Custom/Walk with labels).
function RobloxPathProvider.mapWaypoints(waypoints: { PathWaypoint }): { Waypoint }
	local out: { Waypoint } = {}
	for _, w in waypoints do
		local action: string = "Walk"
		if w.Action == Enum.PathWaypointAction.Jump then
			action = "Jump"
		elseif w.Action == Enum.PathWaypointAction.Custom then
			action = "Custom"
		end
		local label: string? = if w.Label ~= "" then w.Label else nil
		table.insert(out, { position = w.Position, action = action :: any, label = label })
	end
	return out
end

-- Total length of a waypoint list in studs (NavGrid.pathLength over the core's waypoint shape).
function RobloxPathProvider.pathLength(waypoints: { Waypoint }): number
	local length = 0
	for i = 2, #waypoints do
		length += (waypoints[i].position - waypoints[i - 1].position).Magnitude
	end
	return length
end

-- The core's status for an engine status: Success and NoPath as they are, every legacy status Partial.
function RobloxPathProvider.mapStatus(status: Enum.PathStatus): string
	if status == Enum.PathStatus.Success then
		return "Success"
	elseif status == Enum.PathStatus.NoPath then
		return "NoPath"
	end
	return "Partial"
end

local function emptyResult(request: PathRequest, status: string): PathResult
	return {
		status = status :: any, -- a PathStatus name
		waypoints = {},
		provider = "roblox",
		cost = 0,
		goalDistance = NavMath.flatDistance(request.start, request.goal),
	}
end

-- Reads a computed Path into a result. Called inside the computing thread after ComputeAsync returned.
local function resultOf(request: PathRequest, path: Path): PathResult
	local status = RobloxPathProvider.mapStatus(path.Status)
	if status == "NoPath" then
		return emptyResult(request, "NoPath")
	end
	local waypoints = RobloxPathProvider.mapWaypoints(path:GetWaypoints())
	if #waypoints == 0 then
		return emptyResult(request, "NoPath")
	end
	if status == "Partial" and request.allowPartial == false then
		return emptyResult(request, "NoPath")
	end
	local last = waypoints[#waypoints].position
	return {
		status = status :: any, -- a PathStatus name
		waypoints = waypoints,
		provider = "roblox",
		cost = RobloxPathProvider.pathLength(waypoints),
		goalDistance = if status == "Success" then 0 else NavMath.flatDistance(last, request.goal),
	}
end

local function finish(self: Provider, request: PathRequest, result: PathResult)
	local active = self.active[request.id]
	if not active or active.request ~= request then
		return -- cancelled, timed out or replaced: the late result is discarded
	end
	self.active[request.id] = nil
	self.stats.computed += 1
	if result.status == "Success" then
		self.stats.success += 1
	elseif result.status == "NoPath" then
		self.stats.noPath += 1
	elseif result.status == "Partial" then
		self.stats.partial += 1
	elseif result.status == "Error" then
		self.stats.errors += 1
	end
	table.insert(self.completions, { id = request.id, agentId = request.agentId, result = result })
end

local function start(self: Provider, request: PathRequest, now: number)
	local canJump = if request.canJump == nil then (self.agent.canJump ~= false) else request.canJump :: boolean
	local path = pathFor(self, request.agentId, canJump)
	local active: Active = { request = request, startedAt = now, thread = nil }
	self.active[request.id] = active
	if not path then
		finish(self, request, emptyResult(request, "Error"))
		return
	end
	local thread = task.spawn(function()
		local ok = try(function()
			path:ComputeAsync(request.start, request.goal)
		end)
		local result: PathResult
		if ok then
			local readOk, read = pcall(resultOf, request, path)
			result = if readOk then read else emptyResult(request, "Error")
		else
			result = emptyResult(request, "Error")
		end
		self.bag:remove(coroutine.running())
		if not self.destroyed then
			finish(self, request, result)
		end
	end)
	if coroutine.status(thread) ~= "dead" then
		active.thread = thread
		self.bag:add(thread)
	end
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

local function activeCount(self: Provider): number
	local n = 0
	for _ in self.active do
		n += 1
	end
	return n
end

-- Ids of the in-flight requests in a fixed order (hash order never reaches a completion).
local function activeIds(self: Provider): { number }
	local ids: { number } = {}
	for id in self.active do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function RobloxPathProvider.submit(self: Provider, request: PathRequest)
	if self.destroyed then
		return
	end
	self:cancelAgent(request.agentId)
	table.insert(self.queue, request)
end

local function dropActive(self: Provider, id: number)
	local active = self.active[id]
	if not active then
		return
	end
	self.active[id] = nil
	local thread = active.thread
	if thread then
		self.bag:remove(thread)
		if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
			pcall(function()
				task.cancel(thread)
			end)
		end
	end
end

function RobloxPathProvider.cancel(self: Provider, id: number)
	for i = #self.queue, 1, -1 do
		if self.queue[i].id == id then
			table.remove(self.queue, i)
		end
	end
	dropActive(self, id)
end

-- Drops the agent's queued and in-flight requests. The Path and its Blocked connection stay (forgetAgent).
function RobloxPathProvider.cancelAgent(self: Provider, agentId: string)
	for i = #self.queue, 1, -1 do
		if self.queue[i].agentId == agentId then
			table.remove(self.queue, i)
		end
	end
	for _, id in activeIds(self) do
		local active = self.active[id]
		if active and active.request.agentId == agentId then
			dropActive(self, id)
		end
	end
end

-- The agent despawned: its Path, bag and pending notifications go too.
function RobloxPathProvider.forgetAgent(self: Provider, agentId: string)
	self:cancelAgent(agentId)
	local entry = self.paths[agentId]
	if entry then
		self.paths[agentId] = nil
		destroyEntry(entry)
	end
	for i = #self.blockedQueue, 1, -1 do
		if self.blockedQueue[i].agentId == agentId then
			table.remove(self.blockedQueue, i)
		end
	end
	for i = #self.completions, 1, -1 do
		if self.completions[i].agentId == agentId then
			table.remove(self.completions, i)
		end
	end
end

-- Once per frame: times out stale computations, hands out finished ones, starts new ones up to
-- maxInFlight, and forwards queued Blocked notifications. `spent` is accepted and ignored (starting a
-- computation costs nothing measurable here).
function RobloxPathProvider.step(self: Provider, now: number, spent: (() -> number)?): { PathCompletion }
	local out: { PathCompletion } = {}
	if self.destroyed then
		return out
	end
	for _, id in activeIds(self) do
		local active = self.active[id]
		if active and now - active.startedAt > self.timeout then
			local request = active.request
			dropActive(self, id)
			self.stats.timeouts += 1
			table.insert(out, { id = request.id, agentId = request.agentId, result = emptyResult(request, "Timeout") })
		end
	end
	if #self.completions > 0 then
		for _, completion in self.completions do
			table.insert(out, completion)
		end
		self.completions = {}
	end
	if #self.queue > 0 then
		sortQueue(self)
		while #self.queue > 0 and activeCount(self) < self.maxInFlight do
			local request = table.remove(self.queue, 1) :: PathRequest
			start(self, request, now)
		end
	end
	if #self.blockedQueue > 0 then
		local queued = self.blockedQueue
		self.blockedQueue = {}
		local onBlocked = self.onBlocked
		for _, blocked in queued do
			self.stats.blocked += 1
			if onBlocked then
				try(function()
					onBlocked(blocked.agentId, blocked.index, now)
				end)
			end
		end
	end
	return out
end

-- Queued plus computing.
function RobloxPathProvider.inFlight(self: Provider): number
	return #self.queue + activeCount(self)
end

function RobloxPathProvider.getStats(self: Provider): Stats
	return table.clone(self.stats)
end

-- Frees every Path, bag and thread. The provider answers nothing afterwards.
function RobloxPathProvider.destroy(self: Provider)
	self.destroyed = true
	for _, id in activeIds(self) do
		dropActive(self, id)
	end
	self.queue = {}
	self.completions = {}
	self.blockedQueue = {}
	local agents: { string } = {}
	for agentId in self.paths do
		table.insert(agents, agentId)
	end
	table.sort(agents)
	for _, agentId in agents do
		destroyEntry(self.paths[agentId])
	end
	self.paths = {}
	self.bag:disconnectAll()
end

-- The same object seen as the port (methods take `self: Provider`; the port takes `self: any`).
function RobloxPathProvider.asPort(self: Provider): Ports.PathProvider
	return (self :: any) :: Ports.PathProvider
end

return RobloxPathProvider

-- A stand-in for the engine's pathfinder under Lune. It has the provider shape the planner drives
-- (`submit`, `cancel`, `cancelAgent`, `step`, `inFlight`, plus `forgetAgent` like the Roblox
-- adapter) and answers from a NavGrid, but asynchronously: a request completes at `issuedAt +
-- latency`, the latency drawn from an injected Rng, so a test meets the same ordering hazards the
-- real engine causes. Every result carries `provider = "roblox"`, so the planner counts it as the
-- primary. Knobs: `failEvery` (every nth submitted request completes as Timeout), `mode`
-- ("success" passes the grid's answer through; "timeout", "partial" and "nopath" force that
-- outcome) and `blockAt`, a seam that queues a Blocked notification the way `Path.Blocked` would;
-- the caller drains the queue with `drainBlocked`, or `step` hands it to an `onBlocked` callback
-- when one was given. Not a scheduler and not the grid provider: it never slices a search and
-- ignores `spent`. Plain data in, plain data out; no Roblox instances, no yields.

local FakePathProvider = {}
FakePathProvider.__index = FakePathProvider

export type Mode = "success" | "timeout" | "partial" | "nopath"

export type Options = {
	rng: any?, -- an Rng for the latency draws; without one a range collapses to its midpoint
	latency: (number | { number })?, -- fixed seconds, or { lo, hi } drawn uniformly; default { 0.05, 0.4 }
	failEvery: number?, -- every nth submitted request completes as Timeout; nil = never
	mode: Mode?, -- default "success"
	maxNodes: number?, -- A* expansions per search when the request carries none; default 6000
	jumpHeight: number?, -- default 7
	maxJumpGap: number?, -- default 6
	stepHeight: number?, -- default 2
	onBlocked: ((agentId: string, idx: number, at: number) -> ())?, -- when set, step drains the Blocked queue into it
}

export type Blocked = { agentId: string, idx: number, at: number }

export type Completion = { id: number, agentId: string, result: any }

type Entry = { request: any, due: number, timeout: boolean }

export type Provider = typeof(setmetatable(
	{} :: {
		name: string,
		grid: any,
		rng: any?,
		latency: number | { number },
		failEvery: number?,
		mode: Mode,
		maxNodes: number,
		jumpHeight: number,
		maxJumpGap: number,
		stepHeight: number,
		onBlocked: ((agentId: string, idx: number, at: number) -> ())?,
		entries: { Entry },
		blocked: { Blocked },
		stats: { submitted: number, completed: number, timeouts: number, cancelled: number },
	},
	FakePathProvider
))

local DEFAULT_LATENCY = { 0.05, 0.4 }

function FakePathProvider.new(grid: any, options: Options?): Provider
	local o: Options = options or {}
	return setmetatable({
		name = "roblox",
		grid = grid,
		rng = o.rng,
		latency = o.latency or DEFAULT_LATENCY,
		failEvery = o.failEvery,
		mode = o.mode or "success",
		maxNodes = o.maxNodes or 6000,
		jumpHeight = o.jumpHeight or 7,
		maxJumpGap = o.maxJumpGap or 6,
		stepHeight = o.stepHeight or 2,
		onBlocked = o.onBlocked,
		entries = {},
		blocked = {},
		stats = { submitted = 0, completed = 0, timeouts = 0, cancelled = 0 },
	}, FakePathProvider)
end

local function flatDistance(a: any, b: any): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function pathLength(waypoints: { any }): number
	local length = 0
	for i = 2, #waypoints do
		length += (waypoints[i].position - waypoints[i - 1].position).Magnitude
	end
	return length
end

-- The first half of a path by length, ending at the cut point: the engine's Partial, a path that
-- stops short. Works for a two-point straight line as well as a long one.
local function firstHalf(waypoints: { any }): { any }
	local half = pathLength(waypoints) / 2
	local out = { waypoints[1] }
	local walked = 0
	for i = 2, #waypoints do
		local from, to = waypoints[i - 1].position, waypoints[i].position
		local segment = (to - from).Magnitude
		if walked + segment >= half then
			local t = if segment > 0 then (half - walked) / segment else 0
			table.insert(out, { position = from:Lerp(to, t), action = "Walk" })
			break
		end
		walked += segment
		table.insert(out, waypoints[i])
	end
	return out
end

local function drawLatency(self: Provider): number
	local latency = self.latency
	if type(latency) == "number" then
		return latency
	end
	local lo, hi = latency[1], latency[2] or latency[1]
	if self.rng then
		return self.rng:range(lo, hi)
	end
	return (lo + hi) / 2
end

-- The newest request per agent wins, as with one Path instance per agent in the engine.
function FakePathProvider.submit(self: Provider, request: any)
	self:cancelAgent(request.agentId)
	self.stats.submitted += 1
	local failEvery = self.failEvery
	local timeout = failEvery ~= nil and failEvery > 0 and self.stats.submitted % failEvery == 0
	table.insert(self.entries, {
		request = request,
		due = (request.issuedAt or 0) + drawLatency(self),
		timeout = timeout,
	})
end

function FakePathProvider.cancel(self: Provider, id: number)
	for i, entry in self.entries do
		if entry.request.id == id then
			table.remove(self.entries, i)
			self.stats.cancelled += 1
			return
		end
	end
end

function FakePathProvider.cancelAgent(self: Provider, agentId: string)
	for i = #self.entries, 1, -1 do
		if self.entries[i].request.agentId == agentId then
			table.remove(self.entries, i)
			self.stats.cancelled += 1
		end
	end
end

-- The adapter's sibling of cancelAgent (it also destroys the agent's Path); here the same thing.
function FakePathProvider.forgetAgent(self: Provider, agentId: string)
	self:cancelAgent(agentId)
end

function FakePathProvider.inFlight(self: Provider): number
	return #self.entries
end

local function emptyResult(request: any, status: string): any
	return {
		status = status,
		waypoints = {},
		provider = "roblox",
		cost = 0,
		goalDistance = flatDistance(request.start, request.goal),
	}
end

local function answer(self: Provider, entry: Entry): any
	local request = entry.request
	self.stats.completed += 1
	if entry.timeout or self.mode == "timeout" then
		self.stats.timeouts += 1
		return emptyResult(request, "Timeout")
	end
	if self.mode == "nopath" then
		return emptyResult(request, "NoPath")
	end
	local found = self.grid:findPath(request.start, request.goal, {
		maxNodes = request.maxNodes or self.maxNodes,
		jumpHeight = if request.canJump == false then 0 else self.jumpHeight,
		maxJumpGap = self.maxJumpGap,
		stepHeight = self.stepHeight,
	})
	local waypoints: { any } = {}
	for _, w in found.waypoints do
		table.insert(waypoints, { position = w.position, action = w.action })
	end
	local status: string = found.status
	if self.mode == "partial" and status == "Success" and #waypoints >= 2 then
		waypoints = firstHalf(waypoints)
		status = "Partial"
	end
	if status == "Partial" and request.allowPartial == false then
		status = "NoPath"
		waypoints = {}
	end
	if status == "NoPath" or #waypoints == 0 then
		return emptyResult(request, "NoPath")
	end
	return {
		status = status,
		waypoints = waypoints,
		provider = "roblox",
		cost = pathLength(waypoints),
		goalDistance = flatDistance(waypoints[#waypoints].position, request.goal),
	}
end

-- Completes every request whose latency has elapsed, earliest first (ties by request id), and
-- drains the Blocked queue into `onBlocked` when that callback was given.
function FakePathProvider.step(self: Provider, now: number, _spent: (() -> number)?): { Completion }
	local ready: { Entry } = {}
	local kept: { Entry } = {}
	for _, entry in self.entries do
		table.insert(if entry.due <= now then ready else kept, entry)
	end
	self.entries = kept
	table.sort(ready, function(a, b)
		if a.due == b.due then
			return a.request.id < b.request.id
		end
		return a.due < b.due
	end)
	local completions: { Completion } = {}
	for _, entry in ready do
		table.insert(completions, {
			id = entry.request.id,
			agentId = entry.request.agentId,
			result = answer(self, entry),
		})
	end
	local onBlocked = self.onBlocked
	if onBlocked then
		for _, blocked in self:drainBlocked() do
			onBlocked(blocked.agentId, blocked.idx, blocked.at)
		end
	end
	return completions
end

-- Test seam: the engine says the agent's path is blocked at waypoint `idx` (Path.Blocked).
function FakePathProvider.blockAt(self: Provider, agentId: string, idx: number, now: number)
	table.insert(self.blocked, { agentId = agentId, idx = idx, at = now })
end

-- Hands over and clears the queued Blocked notifications, in the order they were raised.
function FakePathProvider.drainBlocked(self: Provider): { Blocked }
	local out = self.blocked
	self.blocked = {}
	return out
end

function FakePathProvider.destroy(self: Provider)
	self.entries = {}
	self.blocked = {}
end

return FakePathProvider

--!strict
-- A bank of short movement fragments learned from players: how a person's input actually flows for a few
-- seconds between stops (the curve of a turn, the analog speed, the hop halfway, the half-second pause),
-- stored as directions relative to the fragment's own first heading so a fragment can be replayed anywhere
-- an NPC happens to stand. Identity-free and in-memory only: fragments hold unit directions, magnitudes,
-- jump flags and step durations, never positions, never ids or names (the per-session playerKey is a random
-- integer used only to keep concurrent players' samples apart), and nothing here is ever persisted. It does
-- not decide when an NPC plays a fragment (Npc does) and does not learn distributions (MotionStats does).
-- requires: NavMath, Rng, Types

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)

type Rng = Rng.Rng
type MoveCommand = Types.MoveCommand

local TraceBank = {}
TraceBank.__index = TraceBank

TraceBank.CAPACITY = 64
TraceBank.MIN_SECONDS = 3
TraceBank.MAX_SECONDS = 10
TraceBank.MIN_FRAGMENTS = 8 -- pick() answers nil below this
TraceBank.STOP_SECONDS = 1 -- standing still this long ends a fragment
TraceBank.GAP_SECONDS = 1 -- a hole in the samples this long ends a fragment too
TraceBank.STILL_MAGNITUDE = 0.05 -- below this the player is standing still
TraceBank.IDLE_FORGET = 60 -- prune() drops open traces silent for this long

export type Options = { capacity: number?, minSeconds: number?, maxSeconds: number? }

export type Sample = { dir: Vector3, magnitude: number, jump: boolean, at: number }

export type Step = { dir: Vector3, magnitude: number, jump: boolean, dt: number }

export type Fragment = { steps: { Step }, seconds: number }

-- The fragment being recorded for one player.
export type OpenTrace = {
	lastAt: number?,
	steps: { Step },
	seconds: number,
	firstYaw: number?, -- heading of the fragment's first step; every dir is rotated so it becomes +Z
	stillSince: number?,
	stillSteps: { Step }, -- a short pause's steps, kept if the player moves again inside STOP_SECONDS
}

export type Bank = typeof(setmetatable(
	{} :: {
		capacity: number,
		minSeconds: number,
		maxSeconds: number,
		fragments: { Fragment },
		completed: number, -- every complete fragment ever seen, so the store stays a uniform sample
		open: { [number]: OpenTrace },
	},
	TraceBank
))

-- Rotation about +Y that follows the yaw convention: rotateY(dirFromYaw(y), a) == dirFromYaw(y + a).
local function rotateY(v: Vector3, angle: number): Vector3
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c + v.Z * s, 0, -v.X * s + v.Z * c)
end

local function flatUnit(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-6 then
		return Vector3.zero
	end
	return flat.Unit
end

function TraceBank.new(opts: Options?): Bank
	local o: Options = opts or {}
	local minSeconds = math.max(0, o.minSeconds or TraceBank.MIN_SECONDS)
	return setmetatable({
		capacity = math.max(1, math.floor(o.capacity or TraceBank.CAPACITY)),
		minSeconds = minSeconds,
		maxSeconds = math.max(minSeconds, o.maxSeconds or TraceBank.MAX_SECONDS),
		fragments = {},
		completed = 0,
		open = {},
	}, TraceBank)
end

local function newTrace(): OpenTrace
	return { lastAt = nil, steps = {}, seconds = 0, firstYaw = nil, stillSince = nil, stillSteps = {} }
end

local function isStill(sample: Sample): boolean
	return sample.magnitude < TraceBank.STILL_MAGNITUDE or flatUnit(sample.dir).Magnitude < 0.5
end

-- Reservoir over complete fragments (Vitter's algorithm R), so the bank is a uniform sample of the session.
local function store(self: Bank, fragment: Fragment, rng: Rng)
	self.completed += 1
	if #self.fragments < self.capacity then
		table.insert(self.fragments, fragment)
		return
	end
	local slot = rng:int(1, self.completed)
	if slot <= self.capacity then
		self.fragments[slot] = fragment
	end
end

local function closeFragment(self: Bank, trace: OpenTrace, rng: Rng)
	if #trace.steps > 0 and trace.seconds >= self.minSeconds then
		store(self, { steps = trace.steps, seconds = trace.seconds }, rng)
	end
	trace.steps = {}
	trace.seconds = 0
	trace.firstYaw = nil
end

local function addStep(
	self: Bank,
	trace: OpenTrace,
	dir: Vector3,
	magnitude: number,
	jump: boolean,
	dt: number,
	rng: Rng
)
	if trace.seconds + dt > self.maxSeconds then
		closeFragment(self, trace, rng)
	end
	local firstYaw = trace.firstYaw
	if firstYaw == nil then
		firstYaw = NavMath.yawOf(dir)
		trace.firstYaw = firstYaw
	end
	-- dirFromYaw(pi) is +Z, so the first step's heading maps onto +Z and every later dir keeps its offset.
	local relative = if dir.Magnitude < 1e-6 then Vector3.zero else rotateY(dir, math.pi - firstYaw)
	table.insert(trace.steps, { dir = relative, magnitude = magnitude, jump = jump, dt = dt })
	trace.seconds += dt
end

-- Feeds one player's sample (10 Hz is the intended rate). `playerKey` is a per-session random integer that
-- tells concurrent players apart; it is never a user id. A player's first sample only starts the clock (a
-- step needs the interval since the previous sample). Fragments are cut where the player stood still for
-- STOP_SECONDS, where the samples have a hole of GAP_SECONDS, and at maxSeconds; pauses shorter than a stop
-- stay inside the fragment as zero-magnitude steps. Every stored dir is relative to the fragment's first.
function TraceBank.observe(self: Bank, sample: Sample, playerKey: number, rng: Rng)
	local trace = self.open[playerKey]
	if not trace then
		trace = newTrace()
		self.open[playerKey] = trace
	end
	local at = sample.at
	local still = isStill(sample)
	local lastAt = trace.lastAt
	if lastAt == nil then
		trace.lastAt = at
		trace.stillSince = if still then at else nil
		return
	end
	local dt = at - lastAt
	if dt <= 0 then
		return
	end
	trace.lastAt = at
	if dt > TraceBank.GAP_SECONDS then
		closeFragment(self, trace, rng)
		trace.stillSteps = {}
		trace.stillSince = if still then at else nil
		return
	end
	if still then
		local since = trace.stillSince
		if since == nil then
			since = at
			trace.stillSince = since
		end
		if at - since >= TraceBank.STOP_SECONDS then
			closeFragment(self, trace, rng)
			trace.stillSteps = {}
			return
		end
		if #trace.steps > 0 then
			table.insert(trace.stillSteps, { dir = Vector3.zero, magnitude = 0, jump = sample.jump, dt = dt })
		end
		return
	end
	if trace.stillSince ~= nil then
		for _, step in trace.stillSteps do
			addStep(self, trace, step.dir, step.magnitude, step.jump, step.dt, rng)
		end
		trace.stillSteps = {}
		trace.stillSince = nil
	end
	addStep(self, trace, flatUnit(sample.dir), math.clamp(sample.magnitude, 0, 1), sample.jump, dt, rng)
end

-- Drops the open recording of a player who left. Nothing complete is lost.
function TraceBank.forget(self: Bank, playerKey: number)
	self.open[playerKey] = nil
end

-- Drops open recordings that have been silent for IDLE_FORGET seconds (players who left without forget()).
function TraceBank.prune(self: Bank, now: number)
	local stale = {}
	for key, trace in self.open do
		local lastAt = trace.lastAt
		if lastAt == nil or now - lastAt > TraceBank.IDLE_FORGET then
			table.insert(stale, key)
		end
	end
	table.sort(stale)
	for _, key in stale do
		self.open[key] = nil
	end
end

-- Complete fragments currently held (at most capacity).
function TraceBank.count(self: Bank): number
	return #self.fragments
end

-- Uniformly one of the stored fragments; nil while fewer than MIN_FRAGMENTS are held.
function TraceBank.pick(self: Bank, rng: Rng): Fragment?
	local held = #self.fragments
	if held < TraceBank.MIN_FRAGMENTS then
		return nil
	end
	return self.fragments[rng:int(1, held)]
end

-- The command for step `index` of a fragment, rotated so the fragment's first heading becomes `baseYaw`.
-- A zero-magnitude step (a pause inside the fragment) and any index past the end come back as a stop; the
-- caller advances `index` once the step's `dt` has elapsed and ends playback when index > #fragment.steps.
function TraceBank.play(fragment: Fragment, baseYaw: number, index: number): MoveCommand
	local step = fragment.steps[index]
	if step == nil or step.magnitude <= 0 or step.dir.Magnitude < 1e-6 then
		local stop: MoveCommand = { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = step ~= nil and step.jump }
		return stop
	end
	local move: MoveCommand = {
		mode = "move",
		dir = rotateY(step.dir, baseYaw - math.pi),
		magnitude = step.magnitude,
		jump = step.jump,
	}
	return move
end

return TraceBank

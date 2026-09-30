--!strict
-- A recording of what every agent (NPC or player) did, sampled at a fixed rate, plus marks for the scripted
-- stimuli and world facts the tell score needs (probes, player lines, avoid boxes, resets, POI centres,
-- identities). It is the only input of Eval/TellScore and it is written by FakeWorld under Lune or by
-- NpcService when Config.TraceEnabled. It is not production telemetry: it holds positions and text, it is
-- never persisted by the system itself, and it holds no logic about what a tell is. The sample store is a
-- ring: past `maxSamples` the oldest samples are dropped, marks are never dropped.
-- requires: Types

local Types = require(script.Parent.Parent.Types)

local Trace = {}
Trace.__index = Trace

Trace.DEFAULT_HZ = 10
Trace.DEFAULT_MAX_SAMPLES = 200000
Trace.DATA_VERSION = 1

-- kind: "player" | "npc"
export type Sample = {
	id: string, -- "n:npc<N>" or "p:<UserId>" (Types.AgentView.id)
	kind: string,
	at: number,
	position: Vector3,
	velocity: Vector3,
	yaw: number,
	onGround: boolean,
	jumped: boolean, -- left the ground by jumping since the previous sample
	said: boolean, -- a chat line was sent since the previous sample
	typing: boolean,
	emote: boolean,
	intent: string?, -- the brain intent kind this sample (NPCs)
	tier: Types.Tier?,
	profile: Types.InputProfileKind?, -- the NPC's InputProfile.kind; players: nil
	pushing: boolean?, -- the stuck detector's verdict was "pushing" / "wallCapped" this sample
	afkFull: boolean?, -- the NPC is in a full AFK episode (attention off)
	replyTo: string?, -- the agent id whose line this `said` answers
	-- Additive fields (not in the base shape); every one is optional and the score has a fallback:
	walkSpeed: number?, -- Humanoid.WalkSpeed this sample (fallback: TellScore Options.walkSpeed, then 16)
	jumpTier: string?, -- "never" | "occasional" | "spammer" (fallback: may jump)
	text: string?, -- the line sent when `said` (repeat detection, one-character replies)
	events: { string }?, -- Npc.Report.events since the previous sample (arrived, abandon, changedMind, ...)
}

-- kind: "probe" | "avoidBox" | "reset" | "playerLine" | "poi" | "identity" | "leave"
--   probe:      a scripted stimulus aimed at `subject` (a follower starting, a stare, a line addressed to it)
--               from `source`; `text` may name the stimulus
--   avoidBox:   an NpcAvoid volume (`cframe`, `size`) so avoid entries can be counted
--   reset:      `subject` was reset at `at` (its next position jump is not a teleport)
--   playerLine: a real player's chat line: `subject` is the player's agent id, `text` the line
--   poi:        a POI centre (`source`) with its id in `subject`, for stop precision
--   identity:   `subject`'s username in `text`, its name family in `family` and an avatar key in `avatar`
--   leave:      `subject` left the server at `at` (`text` may hold the reason); closes its session
export type Mark = {
	kind: string,
	at: number,
	subject: string?,
	source: Vector3?,
	cframe: CFrame?,
	size: Vector3?,
	text: string?,
	family: string?,
	avatar: string?,
}

export type Options = { hz: number?, maxSamples: number? }

export type Trace = typeof(setmetatable(
	{} :: {
		hz: number,
		maxSamples: number,
		samples: { Sample }, -- ring storage; chronological only until the ring wraps
		head: number, -- slot the next sample overwrites once the ring is full
		count: number,
		dropped: number, -- samples the ring has thrown away
		markList: { Mark },
	},
	Trace
))

-- Plain-table form of a trace (numbers, strings, booleans and arrays only), for JSON or any other codec.
export type Data = {
	version: number,
	hz: number,
	maxSamples: number,
	samples: { { [string]: any } },
	marks: { { [string]: any } },
}

function Trace.new(opts: Options?): Trace
	local o: Options = opts or {}
	return setmetatable({
		hz = o.hz or Trace.DEFAULT_HZ,
		maxSamples = math.max(1, math.floor(o.maxSamples or Trace.DEFAULT_MAX_SAMPLES)),
		samples = {},
		head = 1,
		count = 0,
		dropped = 0,
		markList = {},
	}, Trace)
end

function Trace.push(self: Trace, s: Sample)
	if self.count < self.maxSamples then
		self.count += 1
		self.samples[self.count] = s
	else
		self.samples[self.head] = s
		self.head = self.head % self.maxSamples + 1
		self.dropped += 1
	end
end

function Trace.mark(self: Trace, m: Mark)
	table.insert(self.markList, m)
end

-- Marks in the order they were recorded (a copy).
function Trace.marks(self: Trace): { Mark }
	return table.clone(self.markList)
end

function Trace.size(self: Trace): number
	return self.count
end

-- Calls `fn` for every kept sample, oldest first.
function Trace.each(self: Trace, fn: (Sample) -> ())
	if self.count < self.maxSamples then
		for i = 1, self.count do
			fn(self.samples[i])
		end
		return
	end
	for i = self.head, self.maxSamples do
		fn(self.samples[i])
	end
	for i = 1, self.head - 1 do
		fn(self.samples[i])
	end
end

-- Every kept sample, oldest first (a new array).
function Trace.list(self: Trace): { Sample }
	local out: { Sample } = table.create(self.count)
	self:each(function(s)
		table.insert(out, s)
	end)
	return out
end

-- Samples grouped by agent id, each list oldest first.
function Trace.byAgent(self: Trace): { [string]: { Sample } }
	local out: { [string]: { Sample } } = {}
	self:each(function(s)
		local list = out[s.id]
		if not list then
			list = {}
			out[s.id] = list
		end
		table.insert(list, s)
	end)
	return out
end

-- The kind of every agent seen ("player" | "npc"); the latest sample of an agent decides.
function Trace.kinds(self: Trace): { [string]: string }
	local out: { [string]: string } = {}
	self:each(function(s)
		out[s.id] = s.kind
	end)
	return out
end

-- Agent ids in sorted order (so callers never depend on hash order).
function Trace.agentIds(self: Trace): { string }
	local ids = {}
	for id in self:kinds() do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- First and last sample time, or nil when the trace is empty.
function Trace.span(self: Trace): (number?, number?)
	local first: number? = nil
	local last: number? = nil
	self:each(function(s)
		if first == nil or s.at < (first :: number) then
			first = s.at
		end
		if last == nil or s.at > (last :: number) then
			last = s.at
		end
	end)
	return first, last
end

-- Serialization ----------------------------------------------------------------------------------------------

local function vectorData(v: Vector3?): { number }?
	if v == nil then
		return nil
	end
	return { v.X, v.Y, v.Z }
end

local function vectorOf(d: any): Vector3?
	if type(d) ~= "table" then
		return nil
	end
	return Vector3.new(d[1] or 0, d[2] or 0, d[3] or 0)
end

local function cframeData(cf: CFrame?): { number }?
	if cf == nil then
		return nil
	end
	return { cf:GetComponents() }
end

local function cframeOf(d: any): CFrame?
	if type(d) ~= "table" or #d ~= 12 then
		return nil
	end
	return CFrame.new(d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12])
end

local function sampleData(s: Sample): { [string]: any }
	return {
		id = s.id,
		kind = s.kind,
		at = s.at,
		position = vectorData(s.position),
		velocity = vectorData(s.velocity),
		yaw = s.yaw,
		onGround = s.onGround,
		jumped = s.jumped,
		said = s.said,
		typing = s.typing,
		emote = s.emote,
		intent = s.intent,
		tier = s.tier,
		profile = s.profile,
		pushing = s.pushing,
		afkFull = s.afkFull,
		replyTo = s.replyTo,
		walkSpeed = s.walkSpeed,
		jumpTier = s.jumpTier,
		text = s.text,
		events = if s.events then table.clone(s.events) else nil,
	}
end

local function sampleOf(d: { [string]: any }): Sample
	return {
		id = tostring(d.id),
		kind = tostring(d.kind or "npc"),
		at = tonumber(d.at) or 0,
		position = vectorOf(d.position) or Vector3.zero,
		velocity = vectorOf(d.velocity) or Vector3.zero,
		yaw = tonumber(d.yaw) or 0,
		onGround = d.onGround ~= false,
		jumped = d.jumped == true,
		said = d.said == true,
		typing = d.typing == true,
		emote = d.emote == true,
		intent = if type(d.intent) == "string" then d.intent else nil,
		tier = if type(d.tier) == "string" then d.tier else nil,
		profile = if type(d.profile) == "string" then d.profile else nil,
		pushing = if type(d.pushing) == "boolean" then d.pushing else nil,
		afkFull = if type(d.afkFull) == "boolean" then d.afkFull else nil,
		replyTo = if type(d.replyTo) == "string" then d.replyTo else nil,
		walkSpeed = tonumber(d.walkSpeed),
		jumpTier = if type(d.jumpTier) == "string" then d.jumpTier else nil,
		text = if type(d.text) == "string" then d.text else nil,
		events = if type(d.events) == "table" then table.clone(d.events) else nil,
	}
end

local function markData(m: Mark): { [string]: any }
	return {
		kind = m.kind,
		at = m.at,
		subject = m.subject,
		source = vectorData(m.source),
		cframe = cframeData(m.cframe),
		size = vectorData(m.size),
		text = m.text,
		family = m.family,
		avatar = m.avatar,
	}
end

local function markOf(d: { [string]: any }): Mark
	return {
		kind = tostring(d.kind),
		at = tonumber(d.at) or 0,
		subject = if type(d.subject) == "string" then d.subject else nil,
		source = vectorOf(d.source),
		cframe = cframeOf(d.cframe),
		size = vectorOf(d.size),
		text = if type(d.text) == "string" then d.text else nil,
		family = if type(d.family) == "string" then d.family else nil,
		avatar = if type(d.avatar) == "string" then d.avatar else nil,
	}
end

-- The whole trace as plain tables (kept samples oldest first), for a JSON encoder outside ring 1.
function Trace.toData(self: Trace): Data
	local samples: { { [string]: any } } = table.create(self.count)
	self:each(function(s)
		table.insert(samples, sampleData(s))
	end)
	local marks: { { [string]: any } } = table.create(#self.markList)
	for _, m in self.markList do
		table.insert(marks, markData(m))
	end
	return {
		version = Trace.DATA_VERSION,
		hz = self.hz,
		maxSamples = self.maxSamples,
		samples = samples,
		marks = marks,
	}
end

-- Rebuilds a trace from `toData` output (or any table of that shape); unknown fields are ignored.
function Trace.fromData(data: Data): Trace
	local samples: { { [string]: any } } = if type(data.samples) == "table" then data.samples else {}
	local marks: { { [string]: any } } = if type(data.marks) == "table" then data.marks else {}
	local trace = Trace.new({
		hz = tonumber(data.hz) or Trace.DEFAULT_HZ,
		maxSamples = math.max(tonumber(data.maxSamples) or Trace.DEFAULT_MAX_SAMPLES, #samples),
	})
	for _, d in samples do
		trace:push(sampleOf(d))
	end
	for _, d in marks do
		trace:mark(markOf(d))
	end
	return trace
end

return Trace

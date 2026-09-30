--!strict
-- The tell score: reads an Eval/Trace and measures how much the recorded agents behave like a script instead
-- of like players, one statistic per tell of §9.4 (teleports, avoid entries, wall contact, constant speed,
-- perfect stops, metronomic timers, instant reactions, chat floods, cloned identities, ...). Every tell has a
-- severity class (Critical 8, High 3, Medium 1, Low 0.25) and the score is the sum of severity × min(1, excess)
-- over the tells that fired. Pure and deterministic: the same trace and options give the same Result and no
-- random draw is made (reservoirs are sized to hold every value, so the one Rng handed to MotionStats never
-- runs). It is not a verdict on a moment: every statistic needs a minimum of evidence before its tell is
-- evaluated, and a tell without evidence reports `evaluated = false` rather than "clean". It never reads
-- the world, only the trace.
-- requires: Trace, MotionStats, Rng, Types

local Trace = require(script.Parent.Trace)
local MotionStats = require(script.Parent.Parent.Mimic.MotionStats)
local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)

type Sample = Trace.Sample
type Mark = Trace.Mark
type Stats = MotionStats.Stats

local TellScore = {}

TellScore.SEVERITY = { critical = 8, high = 3, medium = 1, low = 0.25 }

-- Evidence and geometry constants (§9).
TellScore.MOVING_SPEED = MotionStats.MOVING_SPEED -- studs/s: below this an agent is stopped
TellScore.MICRO_STOP = MotionStats.MICRO_STOP -- s
TellScore.LONG_STOP = 20 -- s: a stop this long is where a statue shows
TellScore.IDLE_TURN_RATE = 20 -- deg/s: yaw motion while stopped counts as a turn past this
TellScore.STATUE_SWEEP = 0.5 -- deg: less yaw travel than this over a long stop is "no sweep"
TellScore.TYPING_STILL = 1.5 -- s of stillness before a line for a typing freeze
TellScore.REACTION_WINDOW = 8 -- s: a probe unanswered this long is a no-reaction
TellScore.REACTION_TURN = 30 -- deg turned toward the source that counts as a reaction
TellScore.REPLY_WINDOW = 120 -- s: a reply later than this is not matched to the line
TellScore.POI_RADIUS = 8 -- studs: stops farther from every POI are not measured for precision
TellScore.TRIP_MIN_STUDS = 8 -- a moving run shorter than this is not a trip for straightness
TellScore.TELEPORT_FACTOR = 3 -- |Δposition| > factor · walkSpeed · dt is a teleport
TellScore.TELEPORT_MAX_DT = 1 -- s: a longer gap between samples is a hole, not a teleport
TellScore.RESET_SLACK = 1 -- s: a reset mark this long before the jump exempts it
TellScore.SYNC_WINDOW = 0.2 -- s: transitions this close coincide
TellScore.QUIET_AFTER = 600 -- s without a player line before the server counts as quiet
TellScore.NO_JUMP_SPAN = 600 -- s: the window of T-noJumps
TellScore.NO_JUMP_WALKING = 60 -- s of walking inside that window
-- §9.2 says 6 intervals; at 6 a human stream (CV about 0.7) falls under the 0.3 threshold about 5% of the
-- time by sampling noise alone, at 10 under 1%, so 10 is the minimum here.
TellScore.MIN_TIMER_INTERVALS = 10
TellScore.MIN_REFERENCE_PLAYER_VALUES = 200
-- KS needs evidence: at 100 values the sampling noise of the distance is about 0.13 (95%), so the 0.25 and
-- 0.3 thresholds are meaningful; below that the KS tells are not evaluated.
TellScore.MIN_KS_VALUES = 100
TellScore.REFERENCE_SAMPLES = 256
TellScore.REFERENCE_TOTAL = 10000 -- counts per reference histogram
TellScore.DEFAULT_WALK_SPEED = 16

local DEG = 180 / math.pi
local TWO_PI = 2 * math.pi
local NO_DRAW = Rng.new("TellScore") -- handed to MotionStats.observe; reservoirs never fill past capacity

-- Shapes ----------------------------------------------------------------------------------------------------

export type Box = { cframe: CFrame, size: Vector3 }

export type Options = {
	avoidBoxes: { Box }?, -- default: the trace's avoidBox marks
	reference: string?, -- "builtin" | "players"; nil: players when they hold >= 200 values, else builtin
	walkSpeed: number?, -- WalkSpeed for samples that carry none (16)
	pois: { Vector3 }?, -- POI centres for stop precision; default: the trace's poi marks
}

-- direction "above": fires when value > threshold; "below": fires when value < threshold. `full` is the value
-- at which the excess reaches 1 (severity counted in full): the spec's "units of the threshold" are the
-- default (full = 2 · threshold above, 0 below, 1 when the threshold is 0); the other values are the ones
-- that make the §9.6 rows score their full severity.
export type TellDef = {
	name: string,
	statistic: string,
	class: string, -- "critical" | "high" | "medium" | "low"
	direction: string, -- "above" | "below"
	threshold: number,
	full: number,
}

export type Tell = {
	name: string,
	statistic: string,
	class: string,
	severity: number,
	direction: string,
	threshold: number,
	value: number?,
	evaluated: boolean,
	fired: boolean,
	excess: number, -- 0 .. 1
	score: number,
	agents: { string }, -- sorted agent ids that cross the threshold on their own
}

export type AgentSummary = {
	id: string,
	kind: string,
	profile: Types.InputProfileKind?,
	samples: number,
	seconds: number,
	movingSeconds: number,
	stoppedSeconds: number,
	lines: number,
	jumps: number,
	teleports: number,
	fired: { string }, -- tells that list this agent
}

export type Result = {
	score: number,
	tells: { Tell }, -- in TELLS order
	byName: { [string]: Tell },
	features: { [string]: { [string]: number } }, -- per agent: medians of list features, shares and rates
	population: { [string]: number }, -- every evaluated statistic
	agents: { [string]: AgentSummary },
	reference: string, -- "builtin" | "players": what the KS tells compared against
	referenceByFeature: { [string]: string },
	npcCount: number,
	playerCount: number,
	seconds: number,
}

TellScore.TELLS = {
	{
		name = "T-teleport",
		statistic = "teleportCount",
		class = "critical",
		direction = "above",
		threshold = 0,
		full = 1,
	},
	{
		name = "T-avoidEntry",
		statistic = "avoidEntry",
		class = "critical",
		direction = "above",
		threshold = 0,
		full = 1,
	},
	{
		name = "T-wallContact",
		statistic = "wallContact",
		class = "critical",
		direction = "above",
		threshold = 0.05,
		full = 0.1,
	},
	{
		name = "T-constantSpeed",
		statistic = "speedRatioIqr",
		class = "high",
		direction = "below",
		threshold = 0.04,
		full = 0,
	},
	{
		name = "T-perfectStop",
		statistic = "stopPrecision",
		class = "high",
		direction = "below",
		threshold = 0.3,
		full = 0,
	},
	{ name = "T-noJumps", statistic = "noJumps", class = "medium", direction = "above", threshold = 0, full = 1 },
	{
		name = "T-instantReaction",
		statistic = "reactionLatencyQ10",
		class = "high",
		direction = "below",
		threshold = 0.25,
		full = 0.15,
	},
	{
		name = "T-noReaction",
		statistic = "noReactionShare",
		class = "high",
		direction = "above",
		threshold = 0.3,
		full = 0.4,
	},
	{
		name = "T-fastReply",
		statistic = "replyLatencyQ10",
		class = "high",
		direction = "below",
		threshold = 1.5,
		full = 1,
	},
	{ name = "T-metronome", statistic = "timerCv", class = "high", direction = "below", threshold = 0.3, full = 0 },
	{
		name = "T-statueIdle",
		statistic = "statueShare",
		class = "medium",
		direction = "above",
		threshold = 0.2,
		full = 0.6,
	},
	{
		name = "T-fidgetIdle",
		statistic = "idleTurnShare",
		class = "medium",
		direction = "above",
		threshold = 0.05,
		full = 0.2,
	},
	{
		name = "T-straightLines",
		statistic = "pathStraightness",
		class = "medium",
		direction = "below",
		threshold = 1.03,
		full = 1,
	},
	{
		name = "T-noCornerCut",
		statistic = "cornerCut",
		class = "medium",
		direction = "below",
		threshold = 0.15,
		full = 0,
	},
	{
		name = "T-robotTurns",
		statistic = "turnRateQ90",
		class = "medium",
		direction = "above",
		threshold = 400,
		full = 800,
	},
	{ name = "T-sync", statistic = "syncIndex", class = "high", direction = "above", threshold = 0.05, full = 0.1 },
	{
		name = "T-uniformSessions",
		statistic = "sessionCv",
		class = "medium",
		direction = "below",
		threshold = 0.5,
		full = 0,
	},
	{
		name = "T-uniformArrivals",
		statistic = "arrivalClustering",
		class = "medium",
		direction = "below",
		threshold = 0.6,
		full = 0,
	},
	{
		name = "T-nameTemplate",
		statistic = "nameFamilyEntropy",
		class = "high",
		direction = "below",
		threshold = 2,
		full = 0,
	},
	{
		name = "T-cloneAvatars",
		statistic = "avatarDistinct",
		class = "medium",
		direction = "below",
		threshold = 0.8,
		full = 0.5,
	},
	{ name = "T-chatFlood", statistic = "chatFloodMax", class = "high", direction = "above", threshold = 8, full = 12 },
	{ name = "T-chatRepeat", statistic = "chatRepeat", class = "high", direction = "above", threshold = 0, full = 1 },
	{
		name = "T-walkTalk",
		statistic = "typingFreezeShare",
		class = "medium",
		direction = "below",
		threshold = 0.6,
		full = 0,
	},
	{
		name = "T-silentServerChat",
		statistic = "silentServerRate",
		class = "medium",
		direction = "above",
		threshold = 2,
		full = 4,
	},
	{
		name = "T-alwaysComplete",
		statistic = "abandonShare",
		class = "low",
		direction = "below",
		threshold = 0.02,
		full = 0,
	},
	{
		name = "T-neverIdle",
		statistic = "idleShare",
		class = "medium",
		direction = "below",
		threshold = 0.15,
		full = 0.05,
	},
	{ name = "T-ksSpeed", statistic = "ksSpeed", class = "medium", direction = "above", threshold = 0.25, full = 0.5 },
	{ name = "T-ksStops", statistic = "ksStops", class = "medium", direction = "above", threshold = 0.25, full = 0.5 },
	{ name = "T-ksTurn", statistic = "ksTurn", class = "low", direction = "above", threshold = 0.3, full = 0.6 },
} :: { TellDef }

-- Human reference per feature: { median, q25, q75 } (§9.2). Rows whose q25 is 0 document the human value but
-- have no log-normal fit and no histogram.
TellScore.REFERENCE_QUANTILES = {
	speedRatio = { 0.86, 0.72, 0.97 },
	stopDuration = { 2.4, 0.6, 9 },
	goDuration = { 5.1, 1.5, 14 },
	turnRate = { 48, 12, 140 },
	jumpGap = { 21, 4, 90 },
	microStopRate = { 1.8, 0.4, 4 },
	cornerCut = { 0.7, 0.2, 1.6 },
	camSweep = { 35, 5, 110 },
	idleTurnShare = { 0, 0, 0.02 },
	reactionLatency = { 0.9, 0.5, 1.8 },
	replyLatency = { 4.5, 2.5, 12 },
	timerCv = { 0.7, 0.45, 1.1 },
	wallContact = { 0.01, 0, 0.03 },
	stopPrecision = { 1.9, 0.6, 3.5 },
	pathStraightness = { 1.18, 1.05, 1.45 },
	idleShare = { 0.42, 0.2, 0.7 },
	sayRate = { 0.35, 0, 1.2 },
	typingFreezeShare = { 0.8, 0.6, 1 },
} :: { [string]: { number } }

-- Math -------------------------------------------------------------------------------------------------------

local function wrap(angle: number): number
	local a = angle % TWO_PI
	return if a > math.pi then a - TWO_PI else a
end

local function yawOf(dir: Vector3): number
	return math.atan2(-dir.X, -dir.Z)
end

local function flatSpeed(v: Vector3): number
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end

local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function isMoving(s: Sample): boolean
	return flatSpeed(s.velocity) >= TellScore.MOVING_SPEED
end

local function sortedCopy(list: { number }): { number }
	local copy = table.clone(list)
	table.sort(copy)
	return copy
end

-- Linear interpolation between order statistics of an ascending list; nil when empty.
local function quantileSorted(list: { number }, q: number): number?
	local n = #list
	if n == 0 then
		return nil
	end
	local position = 1 + math.clamp(q, 0, 1) * (n - 1)
	local lower = math.floor(position)
	local upper = math.min(lower + 1, n)
	return list[lower] + (list[upper] - list[lower]) * (position - lower)
end

local function quantileOf(list: { number }, q: number): number?
	return quantileSorted(sortedCopy(list), q)
end

local function medianOf(list: { number }): number?
	return quantileOf(list, 0.5)
end

-- Coefficient of variation (population standard deviation over the mean); nil below two values or when the
-- mean is not positive.
local function cvOf(list: { number }): number?
	local n = #list
	if n < 2 then
		return nil
	end
	local sum = 0
	for _, v in list do
		sum += v
	end
	local mean = sum / n
	if mean <= 0 then
		return nil
	end
	local variance = 0
	for _, v in list do
		variance += (v - mean) * (v - mean)
	end
	return math.sqrt(variance / n) / mean
end

local function intervalsOf(times: { number }): { number }
	local out = {}
	for i = 2, #times do
		table.insert(out, times[i] - times[i - 1])
	end
	return out
end

local function entropyBits(counts: { [string]: number }): number
	local total = 0
	for _, c in counts do
		total += c
	end
	if total <= 0 then
		return 0
	end
	local bits = 0
	for _, c in counts do
		if c > 0 then
			local p = c / total
			bits -= p * math.log(p, 2)
		end
	end
	return bits
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- Abramowitz-Stegun 7.1.26 (|error| < 1.5e-7).
local function erf(x: number): number
	local sign = if x < 0 then -1 else 1
	local ax = math.abs(x)
	local t = 1 / (1 + 0.3275911 * ax)
	local poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t
	return sign * (1 - poly * math.exp(-ax * ax))
end

function TellScore.normalCdf(z: number): number
	return 0.5 * (1 + erf(z / math.sqrt(2)))
end

-- Acklam's rational approximation of the standard normal quantile (relative error about 1e-9).
function TellScore.normalQuantile(p: number): number
	if p <= 0 then
		return -math.huge
	end
	if p >= 1 then
		return math.huge
	end
	local a1, a2, a3 = -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02
	local a4, a5, a6 = 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00
	local b1, b2, b3 = -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02
	local b4, b5 = 6.680131188771972e+01, -1.328068155288572e+01
	local c1, c2, c3 = -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00
	local c4, c5, c6 = -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00
	local d1, d2, d3, d4 = 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00
	local pLow = 0.02425
	if p < pLow then
		local q = math.sqrt(-2 * math.log(p))
		return (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) / ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
	elseif p <= 1 - pLow then
		local q = p - 0.5
		local r = q * q
		return (((((a1 * r + a2) * r + a3) * r + a4) * r + a5) * r + a6)
			* q
			/ (((((b1 * r + b2) * r + b3) * r + b4) * r + b5) * r + 1)
	end
	local q = math.sqrt(-2 * math.log(1 - p))
	return -(((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) / ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
end

-- Reference ----------------------------------------------------------------------------------------------------

type LogNormal = { mu: number, sigma: number }

local Z_75 = 0.6744897501960817

local function fitOf(feature: string): LogNormal?
	local row = TellScore.REFERENCE_QUANTILES[feature]
	if not row or row[1] <= 0 or row[2] <= 0 or row[3] <= row[2] then
		return nil
	end
	return { mu = math.log(row[1]), sigma = math.log(row[3] / row[2]) / (2 * Z_75) }
end

-- Upper caps on fitted features: a speed ratio is measured against the agent's own WalkSpeed, so it never
-- exceeds 1; the fit's mass above the cap is a point mass at the cap (the share of keyboard players, whose
-- speed is binary), not a tail no agent could produce.
TellScore.REFERENCE_CAPS = { speedRatio = 1 } :: { [string]: number }

-- The reference value at quantile p of a feature's log-normal fit; nil for features without a fit.
function TellScore.referenceQuantile(feature: string, p: number): number?
	local fit = fitOf(feature)
	if not fit then
		return nil
	end
	local value = math.exp(fit.mu + fit.sigma * TellScore.normalQuantile(p))
	local cap = TellScore.REFERENCE_CAPS[feature]
	return if cap then math.min(value, cap) else value
end

-- Counts per bin from the fit's CDF at the bin edges (cumulative floors, so the bins sum to the total); mass
-- above a feature's cap lands in the cap's bin.
local function histogramOf(fit: LogNormal, cap: number?): { number }
	local edges = MotionStats.binEdges()
	local bins = #edges - 1
	local hist = table.create(bins, 0)
	local previousCount = 0
	for i = 1, bins do
		local edge = edges[i + 1]
		local cumulative = if i == bins or (cap and edge >= (cap :: number))
			then 1
			else TellScore.normalCdf((math.log(edge) - fit.mu) / fit.sigma)
		local count = math.floor(cumulative * TellScore.REFERENCE_TOTAL + 1e-9)
		hist[i] = count - previousCount
		previousCount = count
	end
	return hist
end

-- 24-bin log histograms (MotionStats' grid) of every feature with a log-normal fit, in REFERENCE_QUANTILES.
TellScore.REFERENCE = (function(): { [string]: { number } }
	local out: { [string]: { number } } = {}
	for _, feature in sortedKeys(TellScore.REFERENCE_QUANTILES) do
		local fit = fitOf(feature)
		if fit then
			out[feature] = histogramOf(fit, TellScore.REFERENCE_CAPS[feature])
		end
	end
	return out
end)()

-- A Stats whose reservoirs hold `values` in full (no subsampling, no draws).
local function statsOf(feature: string, values: { number }): Stats
	local stats = MotionStats.new({ reservoir = math.max(1, #values) })
	for _, v in values do
		stats:observe(feature, v, NO_DRAW)
	end
	return stats
end

local referenceStatsCache: Stats? = nil

-- The builtin reference as a MotionStats.Stats: per fitted feature, REFERENCE_SAMPLES quantiles of the
-- log-normal fit (deterministic, no draws). The bin grid is too coarse for KS on speed ratios (their whole
-- interquartile range sits in one bin), so the reservoir is built from the fit rather than from REFERENCE.
function TellScore.referenceStats(): Stats
	if referenceStatsCache then
		return referenceStatsCache :: Stats
	end
	local stats = MotionStats.new({ reservoir = TellScore.REFERENCE_SAMPLES })
	for _, feature in sortedKeys(TellScore.REFERENCE_QUANTILES) do
		if fitOf(feature) then
			for i = 1, TellScore.REFERENCE_SAMPLES do
				local p = (i - 0.5) / TellScore.REFERENCE_SAMPLES
				stats:observe(feature, TellScore.referenceQuantile(feature, p) :: number, NO_DRAW)
			end
		end
	end
	referenceStatsCache = stats
	return stats
end

-- Two-sample KS distance between `values` and the reference (builtin unless `reference` is given).
function TellScore.ksAgainstReference(feature: string, values: { number }, reference: Stats?): number
	if #values == 0 then
		return 0
	end
	return statsOf(feature, values):ks(feature, reference or TellScore.referenceStats())
end

-- Geometry ---------------------------------------------------------------------------------------------------

-- Oriented box test (the box's CFrame is its centre and orientation, `size` its full extents).
function TellScore.insideBox(point: Vector3, box: Box): boolean
	local p = box.cframe:PointToObjectSpace(point)
	local half = box.size / 2
	return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
end

-- Crude username family classifier, used when an identity mark carries no `family`. It only has to make
-- template names (Bot1 .. Bot8, Player_01 ..) fall into one family and varied names into several.
function TellScore.familyOf(username: string): string
	local name = username
	if string.match(name, "^[xX][xX]") or string.match(name, "[xX][xX]$") then
		return "xx"
	end
	if string.match(name, "%d%d$") or string.match(name, "%d%d%d+") then
		return "digits"
	end
	if string.match(name, "%d") then
		return "leet"
	end
	local lower = string.lower(name)
	if string.match(lower, "^not") or string.match(lower, "^its") or string.match(lower, "^iam") then
		return "prefixed"
	end
	if string.match(lower, "^the") or string.match(lower, "^real") or string.match(lower, "^mr") then
		return "prefixed"
	end
	if string.match(lower, "yt$") or string.match(lower, "ttv") or string.match(lower, "official") then
		return "handle"
	end
	if string.match(lower, "gaming") then
		return "handle"
	end
	if string.match(name, "_") then
		return "underscore"
	end
	if string.match(string.sub(name, 2), "%u") then
		return "camel"
	end
	if string.match(name, "^%l+$") then
		return "lower"
	end
	return "other"
end

-- Per-agent analysis -----------------------------------------------------------------------------------------

type Run = { moving: boolean, first: number, last: number, seconds: number }
type Line = { at: number, text: string?, replyTo: string?, still: boolean }
type Transition = { at: number, toMoving: boolean }

type Analysis = {
	id: string,
	kind: string,
	profile: string?,
	jumpTier: string?,
	walkSpeed: number,
	samples: { Sample },
	firstAt: number,
	lastAt: number,
	seconds: number,
	movingSeconds: number,
	stoppedSeconds: number,
	lists: { [string]: { number } },
	speedRatioIqr: number?,
	stoppedIntervalSeconds: number,
	turningStoppedSeconds: number,
	longStops: number,
	statueStops: number,
	movingSamples: number,
	pushingSamples: number,
	lines: { Line },
	jumps: { number },
	teleports: number,
	avoidSamples: number,
	events: { [string]: number },
	timerCv: number?,
	transitions: { Transition },
	noJumps: boolean,
	reactionLatencies: { number },
	noResponses: number,
	probes: number,
	replyLatencies: { number },
	quietLines: number,
}

type Context = {
	walkSpeed: number,
	pois: { Vector3 },
	boxes: { Box },
	resets: { [string]: { number } }, -- reset mark times per subject
}

local function runsOf(samples: { Sample }): { Run }
	local runs: { Run } = {}
	local current: Run? = nil
	for i, sample in samples do
		local moving = isMoving(sample)
		if current and (current :: Run).moving == moving then
			(current :: Run).last = i
		else
			if current then
				(current :: Run).seconds = sample.at - samples[(current :: Run).first].at
			end
			local run: Run = { moving = moving, first = i, last = i, seconds = 0 }
			table.insert(runs, run)
			current = run
		end
	end
	if current then
		(current :: Run).seconds = samples[(current :: Run).last].at - samples[(current :: Run).first].at
	end
	return runs
end

-- Index of the last sample with at <= t, or 0.
local function lastIndexAtOrBefore(samples: { Sample }, t: number): number
	local lo, hi = 1, #samples
	local best = 0
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if samples[mid].at <= t then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return best
end

local function isKeyboard(profile: string?): boolean
	return profile == "pc" or profile == "pcShiftLock"
end

local function stillBefore(samples: { Sample }, index: number): boolean
	local at = samples[index].at
	local j = index
	while j >= 1 do
		if at - samples[j].at > TellScore.TYPING_STILL then
			return true -- enough still history behind the line
		end
		if isMoving(samples[j]) then
			return false
		end
		j -= 1
	end
	return false -- the agent has not been observed for long enough
end

local function analyzeAgent(id: string, kind: string, samples: { Sample }, ctx: Context): Analysis
	local n = #samples
	local profile: string? = nil
	local jumpTier: string? = nil
	local walkSpeed: number? = nil
	for _, s in samples do
		profile = s.profile or profile
		jumpTier = s.jumpTier or jumpTier
		walkSpeed = s.walkSpeed or walkSpeed
	end
	local speed = walkSpeed or ctx.walkSpeed
	local a: Analysis = {
		id = id,
		kind = kind,
		profile = profile,
		jumpTier = jumpTier,
		walkSpeed = speed,
		samples = samples,
		firstAt = samples[1].at,
		lastAt = samples[n].at,
		seconds = samples[n].at - samples[1].at,
		movingSeconds = 0,
		stoppedSeconds = 0,
		lists = MotionStats.featuresFrom(samples :: any, speed),
		speedRatioIqr = nil,
		stoppedIntervalSeconds = 0,
		turningStoppedSeconds = 0,
		longStops = 0,
		statueStops = 0,
		movingSamples = 0,
		pushingSamples = 0,
		lines = {},
		jumps = {},
		teleports = 0,
		avoidSamples = 0,
		events = {},
		timerCv = nil,
		transitions = {},
		noJumps = false,
		reactionLatencies = {},
		noResponses = 0,
		probes = 0,
		replyLatencies = {},
		quietLines = 0,
	}
	a.lists.stopPrecision = {}
	a.lists.pathStraightness = {}

	local speedRatios = a.lists.speedRatio
	if #speedRatios >= 8 then
		local sorted = sortedCopy(speedRatios)
		a.speedRatioIqr = (quantileSorted(sorted, 0.75) :: number) - (quantileSorted(sorted, 0.25) :: number)
	end

	local shiftLock = profile == "pcShiftLock"
	local microStops: { number } = {}
	local sweeps: { number } = {}
	local runs = runsOf(samples)
	for k, run in runs do
		if k > 1 then
			table.insert(a.transitions, { at = samples[run.first].at, toMoving = run.moving })
		end
		if run.moving then
			a.movingSeconds += run.seconds
			-- path straightness per trip
			local straight = flatDistance(samples[run.first].position, samples[run.last].position)
			if straight >= TellScore.TRIP_MIN_STUDS then
				local path = 0
				for i = run.first, run.last - 1 do
					path += flatDistance(samples[i].position, samples[i + 1].position)
				end
				table.insert(a.lists.pathStraightness, path / straight)
			end
			continue
		end
		a.stoppedSeconds += run.seconds
		if run.seconds < TellScore.MICRO_STOP then
			table.insert(microStops, samples[run.first].at)
		end
		-- yaw motion while stopped
		local sweepRad = 0
		local turning = false
		local afkSamples = 0
		for i = run.first, run.last do
			if samples[i].afkFull then
				afkSamples += 1
			end
			if i == run.first then
				continue
			end
			local dt = samples[i].at - samples[i - 1].at
			if dt <= 0 then
				continue
			end
			local delta = math.abs(wrap(samples[i].yaw - samples[i - 1].yaw))
			sweepRad += delta
			a.stoppedIntervalSeconds += dt
			local nowTurning = delta * DEG / dt > TellScore.IDLE_TURN_RATE
			if nowTurning then
				a.turningStoppedSeconds += dt
				if not turning then
					table.insert(sweeps, samples[i].at)
				end
			end
			turning = nowTurning
		end
		if run.seconds > TellScore.LONG_STOP and afkSamples * 2 <= run.last - run.first + 1 then
			a.longStops += 1
			if sweepRad * DEG < TellScore.STATUE_SWEEP then
				a.statueStops += 1
			end
		end
		-- stop precision against the nearest POI
		if run.seconds >= 1 and #ctx.pois > 0 then
			local p = samples[run.first].position
			local best = math.huge
			for _, poi in ctx.pois do
				best = math.min(best, flatDistance(p, poi))
			end
			if best <= TellScore.POI_RADIUS then
				table.insert(a.lists.stopPrecision, best)
			end
		end
	end

	local resets = ctx.resets[id]
	local lastJump: number? = nil
	for i, s in samples do
		if isMoving(s) then
			a.movingSamples += 1
			if s.pushing then
				a.pushingSamples += 1
			end
		end
		if s.jumped then
			if lastJump == nil or s.at - (lastJump :: number) >= MotionStats.JUMP_DEBOUNCE then
				table.insert(a.jumps, s.at)
				lastJump = s.at
			end
		end
		if s.said then
			table.insert(a.lines, { at = s.at, text = s.text, replyTo = s.replyTo, still = stillBefore(samples, i) })
		end
		if s.events then
			for _, e in s.events do
				a.events[e] = (a.events[e] or 0) + 1
			end
		end
		for _, box in ctx.boxes do
			if TellScore.insideBox(s.position, box) then
				a.avoidSamples += 1
				break
			end
		end
		if i > 1 then
			local previous = samples[i - 1]
			local dt = s.at - previous.at
			if dt > 0 and dt <= TellScore.TELEPORT_MAX_DT then
				local moved = flatDistance(s.position, previous.position)
				if moved > TellScore.TELEPORT_FACTOR * speed * dt then
					local exempt = false
					for _, resetAt in resets or {} do
						if resetAt >= previous.at - TellScore.RESET_SLACK and resetAt <= s.at then
							exempt = true
							break
						end
					end
					if not exempt then
						a.teleports += 1
					end
				end
			end
		end
	end

	-- timer coefficient of variation: the most regular of the agent's periodic behaviours
	local lineTimes = {}
	for _, line in a.lines do
		table.insert(lineTimes, line.at)
	end
	local streams = { a.jumps, microStops, lineTimes }
	if shiftLock then
		table.insert(streams, sweeps)
	end
	for _, times in streams do
		if #times >= TellScore.MIN_TIMER_INTERVALS + 1 then
			local cv = cvOf(intervalsOf(times))
			if cv and (a.timerCv == nil or cv < (a.timerCv :: number)) then
				a.timerCv = cv
			end
		end
	end

	-- T-noJumps: a jumper that walks over a minute inside a 10-minute stretch without one jump
	if jumpTier ~= "never" and a.seconds >= TellScore.NO_JUMP_SPAN then
		local bounds = { a.firstAt }
		for _, t in a.jumps do
			table.insert(bounds, t)
		end
		table.insert(bounds, a.lastAt)
		for k = 2, #bounds do
			local from, to = bounds[k - 1], bounds[k]
			if to - from >= TellScore.NO_JUMP_SPAN then
				local walking = 0
				for i = lastIndexAtOrBefore(samples, from) + 1, n do
					if samples[i].at > to then
						break
					end
					if i > 1 and isMoving(samples[i - 1]) then
						walking += samples[i].at - samples[i - 1].at
					end
				end
				if walking > TellScore.NO_JUMP_WALKING then
					a.noJumps = true
					break
				end
			end
		end
	end
	return a
end

-- Marks --------------------------------------------------------------------------------------------------------

local function probeLatencies(byId: { [string]: Analysis }, marks: { Mark })
	for _, m in marks do
		if m.kind ~= "probe" or not m.subject then
			continue
		end
		local a = byId[m.subject :: string]
		if not a then
			continue
		end
		local samples = a.samples
		local base = lastIndexAtOrBefore(samples, m.at)
		if base == 0 then
			continue
		end
		a.probes += 1
		local baseline = samples[base]
		local source = m.source
		local facingLimit = TellScore.REACTION_TURN / DEG
		local facedAlready = source ~= nil
			and math.abs(wrap(yawOf((source :: Vector3) - baseline.position) - baseline.yaw)) < facingLimit
		local answered = false
		for i = base + 1, #samples do
			local s = samples[i]
			if s.at - m.at > TellScore.REACTION_WINDOW then
				break
			end
			local responded = s.intent ~= baseline.intent
			if not responded and source and not facedAlready then
				-- a body turn of REACTION_TURN or more that ends up facing the source
				local turned = math.abs(wrap(s.yaw - baseline.yaw)) * DEG
				local toSource = math.abs(wrap(yawOf((source :: Vector3) - s.position) - s.yaw))
				responded = turned >= TellScore.REACTION_TURN and toSource < facingLimit
			end
			if responded then
				table.insert(a.reactionLatencies, s.at - m.at)
				answered = true
				break
			end
		end
		if not answered then
			a.noResponses += 1
		end
	end
end

local function replyLatencies(byId: { [string]: Analysis }, npcIds: { string }, marks: { Mark })
	local linesBySubject: { [string]: { number } } = {}
	local anyLines: { number } = {}
	for _, m in marks do
		if m.kind == "playerLine" then
			if m.subject then
				local list = linesBySubject[m.subject :: string]
				if not list then
					list = {}
					linesBySubject[m.subject :: string] = list
				end
				table.insert(list, m.at)
			end
			table.insert(anyLines, m.at)
		end
	end
	for _, list in linesBySubject do
		table.sort(list)
	end
	table.sort(anyLines)
	for _, id in npcIds do
		local a = byId[id]
		for _, line in a.lines do
			if not line.replyTo or (line.text and #(line.text :: string) <= 1) then
				continue
			end
			local candidates = linesBySubject[line.replyTo :: string] or anyLines
			local latest: number? = nil
			for _, t in candidates do
				if t <= line.at then
					latest = t
				else
					break
				end
			end
			if latest and line.at - (latest :: number) <= TellScore.REPLY_WINDOW then
				table.insert(a.replyLatencies, line.at - (latest :: number))
			end
		end
	end
end

-- Population -------------------------------------------------------------------------------------------------

local function pooled(analyses: { Analysis }, feature: string): { number }
	local out = {}
	for _, a in analyses do
		for _, v in a.lists[feature] or {} do
			table.insert(out, v)
		end
	end
	return out
end

local function syncIndex(npcs: { Analysis }): number?
	local eligible: { Analysis } = {}
	for _, a in npcs do
		if #a.transitions >= 4 then
			table.insert(eligible, a)
		end
	end
	if #eligible < 2 then
		return nil
	end
	local pairs, synced = 0, 0
	local flagged: { [string]: boolean } = {}
	for i = 1, #eligible do
		for j = i + 1, #eligible do
			local a, b = eligible[i], eligible[j]
			local from = math.max(a.firstAt, b.firstAt)
			local to = math.min(a.lastAt, b.lastAt)
			if to - from <= 0 then
				continue
			end
			pairs += 1
			local observed = 0
			local k = 1
			for _, ta in a.transitions do
				while k <= #b.transitions and b.transitions[k].at < ta.at - TellScore.SYNC_WINDOW do
					k += 1
				end
				local m = k
				while m <= #b.transitions and b.transitions[m].at <= ta.at + TellScore.SYNC_WINDOW + 1e-9 do
					if b.transitions[m].toMoving == ta.toMoving then
						observed += 1
						break
					end
					m += 1
				end
			end
			-- same-direction transitions of b fall in a's window at this rate by chance (Poisson); a pair is
			-- synchronized well above that
			local expected = #a.transitions * #b.transitions * (2 * TellScore.SYNC_WINDOW) / (to - from) / 2
			if observed >= math.max(5, 3 * expected + 3) then
				synced += 1
				flagged[a.id] = true
				flagged[b.id] = true
			end
		end
	end
	if pairs == 0 then
		return nil
	end
	for _, a in npcs do
		if flagged[a.id] then
			a.events["_synced"] = 1
		end
	end
	return synced / pairs
end

-- The score ----------------------------------------------------------------------------------------------------

local function set(population: { [string]: number }, key: string, value: number?)
	if value ~= nil then
		population[key] = value :: number
	end
end

local function agentsWhere(list: { Analysis }, predicate: (Analysis) -> boolean): { string }
	local out = {}
	for _, a in list do
		if predicate(a) then
			table.insert(out, a.id)
		end
	end
	table.sort(out)
	return out
end

function TellScore.score(trace: Trace.Trace, opts: Options?): Result
	local o: Options = opts or {}
	local marks = trace:marks()
	table.sort(marks, function(x, y)
		return x.at < y.at
	end)
	local kinds = trace:kinds()
	local byAgent = trace:byAgent()
	local ids = trace:agentIds()

	-- world facts from options or marks
	local boxes: { Box } = {}
	if o.avoidBoxes then
		boxes = o.avoidBoxes :: { Box }
	else
		for _, m in marks do
			if m.kind == "avoidBox" and m.cframe and m.size then
				table.insert(boxes, { cframe = m.cframe :: CFrame, size = m.size :: Vector3 })
			end
		end
	end
	local pois: { Vector3 } = {}
	if o.pois then
		pois = o.pois :: { Vector3 }
	else
		for _, m in marks do
			if m.kind == "poi" and m.source then
				table.insert(pois, m.source :: Vector3)
			end
		end
	end
	local resets: { [string]: { number } } = {}
	for _, m in marks do
		if m.kind == "reset" and m.subject then
			local list = resets[m.subject :: string]
			if not list then
				list = {}
				resets[m.subject :: string] = list
			end
			table.insert(list, m.at)
		end
	end
	local ctx: Context = {
		walkSpeed = o.walkSpeed or TellScore.DEFAULT_WALK_SPEED,
		pois = pois,
		boxes = boxes,
		resets = resets,
	}

	local byId: { [string]: Analysis } = {}
	local npcs: { Analysis } = {}
	local players: { Analysis } = {}
	local npcIds: { string } = {}
	for _, id in ids do
		local a = analyzeAgent(id, kinds[id], byAgent[id], ctx)
		byId[id] = a
		if a.kind == "player" then
			table.insert(players, a)
		else
			table.insert(npcs, a)
			table.insert(npcIds, id)
		end
	end
	probeLatencies(byId, marks)
	replyLatencies(byId, npcIds, marks)

	local t0, t1 = trace:span()
	local population: { [string]: number } = {}
	local agentLists: { [string]: { string } } = {}

	-- teleports and avoid entries
	local teleports = 0
	local avoidEntries = 0
	for _, a in npcs do
		teleports += a.teleports
		avoidEntries += a.avoidSamples
	end
	if #npcs > 0 then
		set(population, "teleportCount", teleports)
		agentLists["T-teleport"] = agentsWhere(npcs, function(a)
			return a.teleports > 0
		end)
		if #boxes > 0 then
			set(population, "avoidEntry", avoidEntries)
			agentLists["T-avoidEntry"] = agentsWhere(npcs, function(a)
				return a.avoidSamples > 0
			end)
		end
	end

	-- wall contact: the worst NPC
	local worstWall: number? = nil
	for _, a in npcs do
		if a.movingSamples >= 20 then
			local share = a.pushingSamples / a.movingSamples
			if worstWall == nil or share > (worstWall :: number) then
				worstWall = share
			end
		end
	end
	set(population, "wallContact", worstWall)
	agentLists["T-wallContact"] = agentsWhere(npcs, function(a)
		return a.movingSamples >= 20 and a.pushingSamples / a.movingSamples > 0.05
	end)

	-- constant speed: the least varied analog agent (PC input is binary, so pc profiles are exempt)
	local minIqr: number? = nil
	for _, a in npcs do
		if a.speedRatioIqr and not isKeyboard(a.profile) then
			if minIqr == nil or (a.speedRatioIqr :: number) < (minIqr :: number) then
				minIqr = a.speedRatioIqr
			end
		end
	end
	set(population, "speedRatioIqr", minIqr)
	agentLists["T-constantSpeed"] = agentsWhere(npcs, function(a)
		return a.speedRatioIqr ~= nil and not isKeyboard(a.profile) and (a.speedRatioIqr :: number) < 0.04
	end)

	-- pooled list features
	local stopPrecision = pooled(npcs, "stopPrecision")
	if #stopPrecision >= 4 then
		set(population, "stopPrecision", medianOf(stopPrecision))
	end
	agentLists["T-perfectStop"] = agentsWhere(npcs, function(a)
		local own = a.lists.stopPrecision
		return #own >= 3 and (medianOf(own) :: number) < 0.3
	end)
	local straightness = pooled(npcs, "pathStraightness")
	if #straightness >= 4 then
		set(population, "pathStraightness", medianOf(straightness))
	end
	agentLists["T-straightLines"] = agentsWhere(npcs, function(a)
		local own = a.lists.pathStraightness
		return #own >= 2 and (medianOf(own) :: number) < 1.03
	end)
	local cornerCut = pooled(npcs, "cornerCut")
	if #cornerCut >= 4 then
		set(population, "cornerCut", medianOf(cornerCut))
	end
	agentLists["T-noCornerCut"] = agentsWhere(npcs, function(a)
		local own = a.lists.cornerCut
		return #own >= 2 and (medianOf(own) :: number) < 0.15
	end)
	local turnRate = pooled(npcs, "turnRate")
	if #turnRate >= 20 then
		set(population, "turnRateQ90", quantileOf(turnRate, 0.9))
	end
	agentLists["T-robotTurns"] = agentsWhere(npcs, function(a)
		local own = a.lists.turnRate
		return #own >= 10 and (quantileOf(own, 0.9) :: number) > 400
	end)

	-- jumps
	local noJumpers = agentsWhere(npcs, function(a)
		return a.noJumps
	end)
	local anyLongSpan = false
	for _, a in npcs do
		if a.seconds >= TellScore.NO_JUMP_SPAN then
			anyLongSpan = true
		end
	end
	if anyLongSpan then
		set(population, "noJumps", #noJumpers)
	end
	agentLists["T-noJumps"] = noJumpers

	-- reactions to probes
	local reactionLatencies: { number } = {}
	local probes, noResponses = 0, 0
	for _, a in npcs do
		for _, v in a.reactionLatencies do
			table.insert(reactionLatencies, v)
		end
		probes += a.probes
		noResponses += a.noResponses
	end
	if #reactionLatencies >= 3 then
		set(population, "reactionLatencyQ10", quantileOf(reactionLatencies, 0.1))
	end
	if probes >= 3 then
		set(population, "noReactionShare", noResponses / probes)
	end
	agentLists["T-instantReaction"] = agentsWhere(npcs, function(a)
		for _, v in a.reactionLatencies do
			if v < 0.25 then
				return true
			end
		end
		return false
	end)
	agentLists["T-noReaction"] = agentsWhere(npcs, function(a)
		return a.noResponses > 0
	end)

	-- replies to player lines
	local replies: { number } = {}
	for _, a in npcs do
		for _, v in a.replyLatencies do
			table.insert(replies, v)
		end
	end
	if #replies >= 3 then
		set(population, "replyLatencyQ10", quantileOf(replies, 0.1))
	end
	agentLists["T-fastReply"] = agentsWhere(npcs, function(a)
		for _, v in a.replyLatencies do
			if v < 1.5 then
				return true
			end
		end
		return false
	end)

	-- metronome: the most regular NPC
	local minCv: number? = nil
	for _, a in npcs do
		if a.timerCv and (minCv == nil or (a.timerCv :: number) < (minCv :: number)) then
			minCv = a.timerCv
		end
	end
	set(population, "timerCv", minCv)
	agentLists["T-metronome"] = agentsWhere(npcs, function(a)
		return a.timerCv ~= nil and (a.timerCv :: number) < 0.3
	end)

	-- idle posture
	local longStops, statues = 0, 0
	local stoppedNonShift, turningNonShift = 0, 0
	for _, a in npcs do
		if a.profile == "pcShiftLock" then
			longStops += a.longStops
			statues += a.statueStops
		else
			stoppedNonShift += a.stoppedIntervalSeconds
			turningNonShift += a.turningStoppedSeconds
		end
	end
	if longStops >= 3 then
		set(population, "statueShare", statues / longStops)
	end
	if stoppedNonShift >= 10 then
		set(population, "idleTurnShare", turningNonShift / stoppedNonShift)
	end
	agentLists["T-statueIdle"] = agentsWhere(npcs, function(a)
		return a.profile == "pcShiftLock" and a.statueStops > 0
	end)
	agentLists["T-fidgetIdle"] = agentsWhere(npcs, function(a)
		return a.profile ~= "pcShiftLock"
			and a.stoppedIntervalSeconds > 0
			and a.turningStoppedSeconds / a.stoppedIntervalSeconds > 0.05
	end)

	-- synchrony
	set(population, "syncIndex", syncIndex(npcs))
	agentLists["T-sync"] = agentsWhere(npcs, function(a)
		return a.events["_synced"] ~= nil
	end)
	for _, a in npcs do
		a.events["_synced"] = nil
	end

	-- arrivals (first sample) and sessions (first sample to the agent's `leave` mark: a session that is
	-- still running when the trace ends has no length, so unmarked agents are not measured)
	local leaveAt: { [string]: number } = {}
	for _, m in marks do
		if m.kind == "leave" and m.subject then
			leaveAt[m.subject :: string] = m.at
		end
	end
	local arrivals: { number } = {}
	local sessions: { number } = {}
	for _, a in npcs do
		table.insert(arrivals, a.firstAt)
		local left = leaveAt[a.id]
		if left and left >= a.firstAt then
			table.insert(sessions, left - a.firstAt)
		end
	end
	table.sort(arrivals)
	if #arrivals >= 4 then
		set(population, "arrivalClustering", cvOf(intervalsOf(arrivals)))
	end
	if #sessions >= 4 then
		set(population, "sessionCv", cvOf(sessions))
	end

	-- identities
	local identities: { [string]: Mark } = {}
	for _, m in marks do
		if m.kind == "identity" and m.subject and kinds[m.subject :: string] ~= "player" then
			identities[m.subject :: string] = m
		end
	end
	local families: { [string]: number } = {}
	local avatars: { [string]: boolean } = {}
	local identityCount, avatarCount, distinctAvatars = 0, 0, 0
	for _, subject in sortedKeys(identities) do
		local m = identities[subject]
		identityCount += 1
		local family = m.family or (if m.text then TellScore.familyOf(m.text :: string) else "unknown")
		families[family] = (families[family] or 0) + 1
		if m.avatar then
			avatarCount += 1
			if not avatars[m.avatar :: string] then
				avatars[m.avatar :: string] = true
				distinctAvatars += 1
			end
		end
	end
	if identityCount >= 6 then
		set(population, "nameFamilyEntropy", entropyBits(families))
	end
	if avatarCount >= 2 then
		set(population, "avatarDistinct", distinctAvatars / avatarCount)
	end

	-- chat
	local npcLineTimes: { number } = {}
	local anyText = false
	local repeats = 0
	for _, a in npcs do
		local lastByText: { [string]: number } = {}
		for _, line in a.lines do
			table.insert(npcLineTimes, line.at)
			if line.text then
				anyText = true
				local text = line.text :: string
				local last = lastByText[text]
				if last and line.at - last <= 600 then
					repeats += 1
					a.events["_repeat"] = (a.events["_repeat"] or 0) + 1
				end
				lastByText[text] = line.at
			end
		end
	end
	table.sort(npcLineTimes)
	if #npcs > 0 then
		local floodMax, j = 0, 1
		for i = 1, #npcLineTimes do
			while j <= #npcLineTimes and npcLineTimes[j] < npcLineTimes[i] + 60 do
				j += 1
			end
			floodMax = math.max(floodMax, j - i)
		end
		set(population, "chatFloodMax", floodMax)
		if floodMax > 8 then
			-- the agents that spoke inside the fullest minute
			local start = 0
			j = 1
			for i = 1, #npcLineTimes do
				while j <= #npcLineTimes and npcLineTimes[j] < npcLineTimes[i] + 60 do
					j += 1
				end
				if j - i == floodMax then
					start = npcLineTimes[i]
					break
				end
			end
			agentLists["T-chatFlood"] = agentsWhere(npcs, function(a)
				for _, line in a.lines do
					if line.at >= start and line.at < start + 60 then
						return true
					end
				end
				return false
			end)
		end
	end
	if anyText then
		set(population, "chatRepeat", repeats)
	end
	agentLists["T-chatRepeat"] = agentsWhere(npcs, function(a)
		return a.events["_repeat"] ~= nil
	end)
	for _, a in npcs do
		a.events["_repeat"] = nil
	end

	-- typing freezes on keyboard profiles
	local keyboardLines, stillLines = 0, 0
	for _, a in npcs do
		if isKeyboard(a.profile) then
			for _, line in a.lines do
				keyboardLines += 1
				if line.still then
					stillLines += 1
				end
			end
		end
	end
	if keyboardLines >= 3 then
		set(population, "typingFreezeShare", stillLines / keyboardLines)
	end
	agentLists["T-walkTalk"] = agentsWhere(npcs, function(a)
		if not isKeyboard(a.profile) or #a.lines == 0 then
			return false
		end
		local still = 0
		for _, line in a.lines do
			if line.still then
				still += 1
			end
		end
		return still / #a.lines < 0.6
	end)

	-- NPC chat while the server has been quiet (mirrors ChatGuard: silence counts from the trace start)
	if t0 and t1 then
		local playerLineTimes: { number } = {}
		for _, m in marks do
			if m.kind == "playerLine" then
				table.insert(playerLineTimes, m.at)
			end
		end
		table.sort(playerLineTimes)
		local bounds = { t0 :: number }
		for _, t in playerLineTimes do
			if t > (t0 :: number) and t < (t1 :: number) then
				table.insert(bounds, t)
			end
		end
		table.insert(bounds, t1 :: number)
		local quietSeconds = 0
		for k = 2, #bounds do
			quietSeconds += math.max(0, bounds[k] - bounds[k - 1] - TellScore.QUIET_AFTER)
		end
		local quietLines = 0
		for _, a in npcs do
			for _, line in a.lines do
				local lastPlayer = t0 :: number
				for _, t in playerLineTimes do
					if t <= line.at then
						lastPlayer = math.max(lastPlayer, t)
					else
						break
					end
				end
				if line.at - lastPlayer >= TellScore.QUIET_AFTER then
					quietLines += 1
					a.quietLines += 1
				end
			end
		end
		if quietSeconds >= 60 then
			set(population, "silentServerRate", quietLines / (quietSeconds / 60))
		end
	end
	agentLists["T-silentServerChat"] = agentsWhere(npcs, function(a)
		return a.quietLines > 0
	end)

	-- trips that ended early
	local trips, early = 0, 0
	for _, a in npcs do
		for _, kind in { "arrived", "abandon", "changedMind", "goalInvalid", "reset" } do
			trips += a.events[kind] or 0
		end
		early += (a.events.abandon or 0) + (a.events.changedMind or 0)
	end
	if trips >= 20 then
		set(population, "abandonShare", early / trips)
	end

	-- idle share
	local npcSeconds, npcStopped = 0, 0
	for _, a in npcs do
		npcSeconds += a.seconds
		npcStopped += a.stoppedSeconds
	end
	if npcSeconds >= 30 then
		set(population, "idleShare", npcStopped / npcSeconds)
	end
	agentLists["T-neverIdle"] = agentsWhere(npcs, function(a)
		return a.seconds >= 30 and a.stoppedSeconds / a.seconds < 0.15
	end)

	-- KS against the reference
	local referenceByFeature: { [string]: string } = {}
	local usedPlayers = false
	for _, pair in { { "ksSpeed", "speedRatio" }, { "ksStops", "stopDuration" }, { "ksTurn", "turnRate" } } do
		local key, feature = pair[1], pair[2]
		local npcValues = pooled(npcs, feature)
		if #npcValues < TellScore.MIN_KS_VALUES then
			continue
		end
		local playerValues = pooled(players, feature)
		local reference: Stats
		if o.reference ~= "builtin" and #playerValues >= TellScore.MIN_REFERENCE_PLAYER_VALUES then
			reference = statsOf(feature, playerValues)
			referenceByFeature[feature] = "players"
			usedPlayers = true
		else
			reference = TellScore.referenceStats()
			referenceByFeature[feature] = "builtin"
		end
		set(population, key, TellScore.ksAgainstReference(feature, npcValues, reference))
	end

	-- tells
	local tells: { Tell } = {}
	local byName: { [string]: Tell } = {}
	local total = 0
	for _, def in TellScore.TELLS do
		local severity = TellScore.SEVERITY[def.class] or 0
		local value = population[def.statistic]
		local fired = false
		local excess = 0
		if value ~= nil then
			local v = value :: number
			if def.direction == "above" then
				fired = v > def.threshold
				if fired then
					local span = def.full - def.threshold
					excess = if span <= 0 then 1 else math.clamp((v - def.threshold) / span, 0, 1)
				end
			else
				fired = v < def.threshold
				if fired then
					local span = def.threshold - def.full
					excess = if span <= 0 then 1 else math.clamp((def.threshold - v) / span, 0, 1)
				end
			end
		end
		local tell: Tell = {
			name = def.name,
			statistic = def.statistic,
			class = def.class,
			severity = severity,
			direction = def.direction,
			threshold = def.threshold,
			value = value,
			evaluated = value ~= nil,
			fired = fired,
			excess = excess,
			score = severity * excess,
			agents = if fired then agentLists[def.name] or {} else {},
		}
		total += tell.score
		table.insert(tells, tell)
		byName[def.name] = tell
	end

	-- per-agent features and summaries
	local features: { [string]: { [string]: number } } = {}
	local agents: { [string]: AgentSummary } = {}
	for _, id in ids do
		local a = byId[id]
		local f: { [string]: number } = {}
		for _, name in
			{ "speedRatio", "stopDuration", "goDuration", "turnRate", "jumpGap", "microStopRate", "cornerCut" }
		do
			local list = a.lists[name]
			if #list > 0 then
				f[name] = medianOf(list) :: number
			end
		end
		for _, name in { "stopPrecision", "pathStraightness" } do
			local list = a.lists[name]
			if #list > 0 then
				f[name] = medianOf(list) :: number
			end
		end
		if a.profile == "pcShiftLock" and #a.lists.camSweep > 0 then
			f.camSweep = medianOf(a.lists.camSweep) :: number
		end
		if a.profile ~= "pcShiftLock" and a.stoppedIntervalSeconds > 0 then
			f.idleTurnShare = a.turningStoppedSeconds / a.stoppedIntervalSeconds
		end
		if #a.lists.turnRate >= 10 then
			f.turnRateQ90 = quantileOf(a.lists.turnRate, 0.9) :: number
		end
		if a.speedRatioIqr then
			f.speedRatioIqr = a.speedRatioIqr :: number
		end
		if #a.reactionLatencies > 0 then
			f.reactionLatency = medianOf(a.reactionLatencies) :: number
		end
		if #a.replyLatencies > 0 then
			f.replyLatency = medianOf(a.replyLatencies) :: number
		end
		if a.timerCv then
			f.timerCv = a.timerCv :: number
		end
		if a.movingSamples > 0 then
			f.wallContact = a.pushingSamples / a.movingSamples
		end
		if a.seconds > 0 then
			f.idleShare = a.stoppedSeconds / a.seconds
			f.sayRate = #a.lines / (a.seconds / 60)
		end
		if #a.lines > 0 then
			local still = 0
			for _, line in a.lines do
				if line.still then
					still += 1
				end
			end
			f.typingFreezeShare = still / #a.lines
		end
		f.teleportCount = a.teleports
		if #boxes > 0 then
			f.avoidEntry = a.avoidSamples
		end
		f.jumps = #a.jumps
		f.lines = #a.lines
		features[id] = f

		local fired: { string } = {}
		for _, tell in tells do
			if tell.fired and table.find(tell.agents, id) then
				table.insert(fired, tell.name)
			end
		end
		agents[id] = {
			id = id,
			kind = a.kind,
			profile = a.profile,
			samples = #a.samples,
			seconds = a.seconds,
			movingSeconds = a.movingSeconds,
			stoppedSeconds = a.stoppedSeconds,
			lines = #a.lines,
			jumps = #a.jumps,
			teleports = a.teleports,
			fired = fired,
		}
	end

	return {
		score = total,
		tells = tells,
		byName = byName,
		features = features,
		population = population,
		agents = agents,
		reference = if usedPlayers then "players" else "builtin",
		referenceByFeature = referenceByFeature,
		npcCount = #npcs,
		playerCount = #players,
		seconds = if t0 and t1 then (t1 :: number) - (t0 :: number) else 0,
	}
end

return TellScore

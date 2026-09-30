--!strict
-- Per-feature distributions of how agents move: a fixed-size reservoir (Vitter's algorithm R, a uniform
-- sample of everything ever observed) plus a 24-bin log-spaced histogram per feature, with quantiles, a
-- two-sample Kolmogorov-Smirnov distance and `featuresFrom`, which turns a kinematic track into the eight
-- per-agent features of the tell score. Identity-free and in-memory only: it holds numbers such as speed
-- ratios and stop lengths, never positions, ids, names or text, and nothing here is ever persisted.
-- requires: NavMath, Rng

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng

local MotionStats = {}
MotionStats.__index = MotionStats

MotionStats.FEATURES = {
	"speedRatio",
	"stopDuration",
	"goDuration",
	"turnRate",
	"jumpGap",
	"microStopRate",
	"cornerCut",
	"camSweep",
}

-- Histogram range shared by every feature: 24 log-spaced bins from 0.01 to 1000 (five decades), which
-- covers speed ratios, seconds, deg/s, studs and degrees alike. Values outside land in the end bins.
MotionStats.BINS = 24
MotionStats.HIST_LO = 0.01
MotionStats.HIST_HI = 1000
MotionStats.RESERVOIR = 256
MotionStats.MIN_SAMPLES = 8 -- below this, sample() and quantile() report nothing

-- An agent is moving when its flat speed reaches this (studs/s); stops are runs below it.
MotionStats.MOVING_SPEED = 0.5
MotionStats.MICRO_STOP = 0.5 -- seconds: a stop shorter than this is a micro-stop
MotionStats.CORNER_DEG = 60 -- a heading change past this is a corner
MotionStats.WINDOW = 1 -- seconds per speedRatio window
MotionStats.JUMP_DEBOUNCE = 0.5 -- seconds: jumped samples closer than this are one jump

export type Options = { reservoir: number?, bins: number? }

export type Feature = {
	n: number, -- everything observed, not just what is kept
	reservoir: { number },
	sorted: { number }?, -- cache of the reservoir in ascending order; dropped on observe
	hist: { number }, -- counts per bin over everything observed
}

export type Stats = typeof(setmetatable(
	{} :: {
		reservoirSize: number,
		bins: number,
		features: { [string]: Feature },
	},
	MotionStats
))

export type TrackSample = { position: Vector3, velocity: Vector3, yaw: number, at: number, jumped: boolean }
export type Track = { TrackSample }

local DEG = 180 / math.pi
local LOG_LO = math.log(MotionStats.HIST_LO)
local LOG_HI = math.log(MotionStats.HIST_HI)

local function binOf(value: number, bins: number): number
	if value <= MotionStats.HIST_LO then
		return 1
	end
	if value >= MotionStats.HIST_HI then
		return bins
	end
	local t = (math.log(value) - LOG_LO) / (LOG_HI - LOG_LO)
	return math.clamp(math.floor(t * bins) + 1, 1, bins)
end

-- Bin edges (bins + 1 numbers) and geometric bin centres, so a reference table can be built on the same grid.
function MotionStats.binEdges(bins: number?): { number }
	local count = bins or MotionStats.BINS
	local edges = table.create(count + 1)
	for i = 0, count do
		edges[i + 1] = math.exp(LOG_LO + (LOG_HI - LOG_LO) * i / count)
	end
	return edges
end

function MotionStats.binCenters(bins: number?): { number }
	local count = bins or MotionStats.BINS
	local centers = table.create(count)
	for i = 1, count do
		centers[i] = math.exp(LOG_LO + (LOG_HI - LOG_LO) * (i - 0.5) / count)
	end
	return centers
end

function MotionStats.binOf(value: number, bins: number?): number
	return binOf(value, bins or MotionStats.BINS)
end

local function newFeature(bins: number): Feature
	return { n = 0, reservoir = {}, sorted = nil, hist = table.create(bins, 0) }
end

function MotionStats.new(opts: Options?): Stats
	local o: Options = opts or {}
	local self = setmetatable({
		reservoirSize = math.max(1, math.floor(o.reservoir or MotionStats.RESERVOIR)),
		bins = math.max(1, math.floor(o.bins or MotionStats.BINS)),
		features = {},
	}, MotionStats)
	for _, name in MotionStats.FEATURES do
		self.features[name] = newFeature(self.bins)
	end
	return self
end

local function featureOf(self: Stats, name: string): Feature
	local f = self.features[name]
	if not f then
		f = newFeature(self.bins)
		self.features[name] = f
	end
	return f
end

local function sortedOf(f: Feature): { number }
	local cached = f.sorted
	if cached then
		return cached
	end
	local sorted: { number } = table.clone(f.reservoir)
	table.sort(sorted)
	f.sorted = sorted
	return sorted
end

-- Vitter's algorithm R: the first `reservoir` values fill it; the n-th value after that replaces a uniformly
-- chosen slot with probability reservoir / n, so the reservoir stays a uniform sample of everything seen.
function MotionStats.observe(self: Stats, feature: string, value: number, rng: Rng)
	if value ~= value or value == math.huge or value == -math.huge then
		return
	end
	local f = featureOf(self, feature)
	f.n += 1
	f.hist[binOf(value, self.bins)] += 1
	if #f.reservoir < self.reservoirSize then
		table.insert(f.reservoir, value)
	else
		local slot = rng:int(1, f.n)
		if slot <= self.reservoirSize then
			f.reservoir[slot] = value
		else
			return
		end
	end
	f.sorted = nil
end

-- Observes every value of a feature table as `featuresFrom` returns it, in the order of FEATURES.
function MotionStats.observeAll(self: Stats, features: { [string]: { number } }, rng: Rng)
	local names = {}
	for name in features do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		for _, value in features[name] do
			self:observe(name, value, rng)
		end
	end
end

-- Fills a reservoir deterministically from a histogram on this module's bin grid: the reservoir slots take
-- bin centres in proportion to the counts (no draws, no rng), so a reference table can be compared with `ks`.
function MotionStats.fillFromHistogram(self: Stats, feature: string, hist: { number })
	local f = featureOf(self, feature)
	local centers = MotionStats.binCenters(#hist)
	local total = 0
	for _, count in hist do
		total += math.max(0, count)
	end
	f.reservoir = {}
	f.sorted = nil
	if total <= 0 then
		return
	end
	local size = self.reservoirSize
	local cumulative, bin = 0, 1
	for i = 1, size do
		local u = (i - 0.5) / size * total
		while bin < #hist and cumulative + math.max(0, hist[bin]) < u do
			cumulative += math.max(0, hist[bin])
			bin += 1
		end
		f.reservoir[i] = centers[bin]
	end
	f.n = math.max(f.n, size)
	for i, count in hist do
		if i <= self.bins then
			f.hist[i] += math.max(0, count)
		end
	end
end

function MotionStats.count(self: Stats, feature: string): number
	local f = self.features[feature]
	return if f then f.n else 0
end

-- A copy of the reservoir (unsorted), for inspection and for reference tables.
function MotionStats.values(self: Stats, feature: string): { number }
	local f = self.features[feature]
	return if f then table.clone(f.reservoir) else {}
end

-- Linear interpolation between order statistics of the reservoir; nil below MIN_SAMPLES.
function MotionStats.quantile(self: Stats, feature: string, q: number): number?
	local f = self.features[feature]
	if not f or #f.reservoir < MotionStats.MIN_SAMPLES then
		return nil
	end
	local sorted = sortedOf(f)
	local n = #sorted
	local position = 1 + math.clamp(q, 0, 1) * (n - 1)
	local lower = math.floor(position)
	local upper = math.min(lower + 1, n)
	local frac = position - lower
	return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
end

-- Counts per bin (a copy), over everything ever observed for the feature.
function MotionStats.histogram(self: Stats, feature: string): { number }
	local f = self.features[feature]
	return if f then table.clone(f.hist) else table.create(self.bins, 0)
end

function MotionStats.sample(self: Stats, feature: string, rng: Rng): number?
	local f = self.features[feature]
	if not f or #f.reservoir < MotionStats.MIN_SAMPLES then
		return nil
	end
	return f.reservoir[rng:int(1, #f.reservoir)]
end

-- Two-sample Kolmogorov-Smirnov distance between the two reservoirs: the largest gap between their empirical
-- CDFs, found by walking both sorted reservoirs together. 0 when either side has nothing (no evidence).
function MotionStats.ks(self: Stats, feature: string, other: Stats): number
	local a = self.features[feature]
	local b = other.features[feature]
	if not a or not b or #a.reservoir == 0 or #b.reservoir == 0 then
		return 0
	end
	local sa, sb = sortedOf(a), sortedOf(b)
	local na, nb = #sa, #sb
	local i, j = 1, 1
	local best = 0
	while i <= na and j <= nb do
		local value = math.min(sa[i], sb[j])
		while i <= na and sa[i] <= value do
			i += 1
		end
		while j <= nb and sb[j] <= value do
			j += 1
		end
		local gap = math.abs((i - 1) / na - (j - 1) / nb)
		if gap > best then
			best = gap
		end
	end
	return best
end

-- Feature extraction ----------------------------------------------------------------------------------------

local function flatSpeed(v: Vector3): number
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end

local function isMoving(sample: TrackSample): boolean
	return flatSpeed(sample.velocity) >= MotionStats.MOVING_SPEED
end

local function headingOf(v: Vector3): number
	return NavMath.yawOf(Vector3.new(v.X, 0, v.Z))
end

-- Distance from point p to the segment ab, in the XZ plane.
local function segmentDistance(p: Vector3, a: Vector3, b: Vector3): number
	local abx, abz = b.X - a.X, b.Z - a.Z
	local apx, apz = p.X - a.X, p.Z - a.Z
	local len2 = abx * abx + abz * abz
	local t = if len2 < 1e-9 then 0 else math.clamp((apx * abx + apz * abz) / len2, 0, 1)
	local cx, cz = a.X + abx * t, a.Z + abz * t
	local dx, dz = p.X - cx, p.Z - cz
	return math.sqrt(dx * dx + dz * dz)
end

-- Intersection of the line through a along da with the line through b along db (XZ plane), or nil when the
-- lines are nearly parallel.
local function lineIntersection(a: Vector3, da: Vector3, b: Vector3, db: Vector3): Vector3?
	local cross = da.X * db.Z - da.Z * db.X
	if math.abs(cross) < 1e-6 then
		return nil
	end
	local rx, rz = b.X - a.X, b.Z - a.Z
	local t = (rx * db.Z - rz * db.X) / cross
	return Vector3.new(a.X + da.X * t, 0, a.Z + da.Z * t)
end

type Run = { moving: boolean, first: number, last: number, seconds: number }

-- Splits the track into alternating stop/go runs. A run lasts from its first sample to the first sample of
-- the next run; the final run lasts to its last sample (it is censored, but dropping it would lose data).
local function runsOf(track: Track): { Run }
	local runs: { Run } = {}
	local current: Run? = nil
	for i, sample in track do
		local moving = isMoving(sample)
		if current and current.moving == moving then
			current.last = i
		else
			if current then
				current.seconds = sample.at - track[current.first].at
			end
			local run: Run = { moving = moving, first = i, last = i, seconds = 0 }
			table.insert(runs, run)
			current = run
		end
	end
	if current then
		current.seconds = track[current.last].at - track[current.first].at
	end
	return runs
end

-- Computes the eight per-agent features (§9.2) from a kinematic track sorted by `at`. Every key of FEATURES
-- is present, possibly empty. Definitions:
--   speedRatio    mean |v_flat| / walkSpeed over the moving samples of each 1-s window (from the first
--                 sample) that has at least one moving sample
--   stopDuration  seconds of each run with |v_flat| < MOVING_SPEED (index-aligned with camSweep)
--   goDuration    seconds of each moving run
--   turnRate      |Δ heading| / dt in deg/s between consecutive moving samples (heading = velocity direction)
--   jumpGap       seconds between consecutive jumps (jumped samples closer than JUMP_DEBOUNCE are one jump)
--   microStopRate stops shorter than MICRO_STOP per minute of walking: one value per completed 60 s of
--                 walking, plus the trailing part scaled to a minute when it holds at least 20 s of walking
--   cornerCut     at each heading change over CORNER_DEG (between 60 and 150 degrees), the distance from the
--                 corner of the two straight legs to the path actually walked, in studs
--   camSweep      degrees of yaw travelled during each stop run (index-aligned with stopDuration)
-- Whether camSweep applies (shift-lock agents only) is the caller's decision; the value is computed for all.
function MotionStats.featuresFrom(track: Track, walkSpeed: number): { [string]: { number } }
	local out: { [string]: { number } } = {}
	for _, name in MotionStats.FEATURES do
		out[name] = {}
	end
	local n = #track
	if n == 0 then
		return out
	end
	local speed = math.max(walkSpeed, 1e-6)
	local t0 = track[1].at

	-- speedRatio per 1-s window
	local windowIndex, windowSum, windowCount = 0, 0, 0
	for _, sample in track do
		local w = math.floor((sample.at - t0) / MotionStats.WINDOW)
		if w ~= windowIndex then
			if windowCount > 0 then
				table.insert(out.speedRatio, windowSum / windowCount / speed)
			end
			windowIndex, windowSum, windowCount = w, 0, 0
		end
		if isMoving(sample) then
			windowSum += flatSpeed(sample.velocity)
			windowCount += 1
		end
	end
	if windowCount > 0 then
		table.insert(out.speedRatio, windowSum / windowCount / speed)
	end

	-- stop/go runs, camSweep per stop, micro-stops per walking minute
	local runs = runsOf(track)
	local chunkWalking, chunkMicro = 0, 0
	for _, run in runs do
		if run.seconds <= 0 then
			continue
		end
		if run.moving then
			table.insert(out.goDuration, run.seconds)
			chunkWalking += run.seconds
			while chunkWalking >= 60 do
				table.insert(out.microStopRate, chunkMicro)
				chunkWalking -= 60
				chunkMicro = 0
			end
		else
			table.insert(out.stopDuration, run.seconds)
			local sweep = 0
			for i = run.first + 1, run.last do
				sweep += math.abs(NavMath.wrap(track[i].yaw - track[i - 1].yaw))
			end
			table.insert(out.camSweep, sweep * DEG)
			if run.seconds < MotionStats.MICRO_STOP then
				chunkMicro += 1
			end
		end
	end
	if chunkWalking >= 20 then
		table.insert(out.microStopRate, chunkMicro * 60 / chunkWalking)
	end

	-- turnRate between consecutive moving samples
	for i = 2, n do
		local a, b = track[i - 1], track[i]
		local dt = b.at - a.at
		if dt > 0 and isMoving(a) and isMoving(b) then
			local delta = NavMath.wrap(headingOf(b.velocity) - headingOf(a.velocity))
			table.insert(out.turnRate, math.abs(delta) * DEG / dt)
		end
	end

	-- jumpGap
	local lastJump: number? = nil
	for _, sample in track do
		if sample.jumped then
			if lastJump == nil then
				lastJump = sample.at
			elseif sample.at - lastJump >= MotionStats.JUMP_DEBOUNCE then
				table.insert(out.jumpGap, sample.at - lastJump)
				lastJump = sample.at
			end
		end
	end

	-- cornerCut: legs are straight while the heading stays within 20 degrees of the leg's heading; when the
	-- heading has swung past CORNER_DEG the corner is where the two legs' lines meet, and the cut is how far
	-- the walked path stays from that point.
	local cornerRad = MotionStats.CORNER_DEG / DEG
	local maxCornerRad = 150 / DEG
	local legHeading: number? = nil
	local legAnchor = 1 -- last sample still on the incoming leg
	for i, sample in track do
		if not isMoving(sample) then
			legHeading = nil
			continue
		end
		local heading = headingOf(sample.velocity)
		if legHeading == nil then
			legHeading = heading
			legAnchor = i
			continue
		end
		local turned = math.abs(NavMath.wrap(heading - legHeading))
		if turned <= 20 / DEG then
			legAnchor = i
		elseif turned > cornerRad then
			if turned < maxCornerRad then
				local a = track[legAnchor].position
				local corner =
					lineIntersection(a, NavMath.dirFromYaw(legHeading), sample.position, NavMath.dirFromYaw(heading))
				if corner then
					local best = math.huge
					for k = legAnchor, i - 1 do
						best = math.min(best, segmentDistance(corner, track[k].position, track[k + 1].position))
					end
					if best < math.huge then
						table.insert(out.cornerCut, best)
					end
				end
			end
			legHeading = heading
			legAnchor = i
		end
	end
	return out
end

return MotionStats

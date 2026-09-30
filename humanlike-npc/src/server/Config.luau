--!strict
-- Every default of the whole system in one table, and the resolver that overlays attributes of the same name from
-- the Bootstrap script (numbers, booleans and strings only: an unknown name or a wrong type is reported in
-- Config.lastWarnings and never applied). The sub-config builders cut the resolved table into the plain tables the
-- runtime modules take, typed structurally right here so this module stays a leaf: it requires nothing but Types,
-- it never reads a Roblox service, and resolve(nil) touches no Instance at all. It is not the client's settings
-- (ClientConfig) and it does not build NpcService.Config: Api does that from the resolved table.
-- requires: Types

local Types = require(script.Parent.Types)

type Tier = Types.Tier

local Config = {}

local DEFAULTS = {
	-- identity / determinism
	Seed = "humanlike-npc" :: string | number, -- the server run seed (Api appends os.time() when SeedPerRun is true)
	SeedPerRun = true,
	DisclosureAck = false, -- true once the game description discloses computer-controlled characters (else one warning)
	-- population
	PopulationBase = 6,
	PopulationPerPlayer = 0.5,
	PopulationMin = 2,
	PopulationMax = 30,
	SpawnOnlyWithPlayers = true, -- target 0 with no players, after the empty-server grace
	EmptyServerGraceSeconds = 600, -- PopulationMin NPCs linger this long after the last player leaves
	InitialBurst = 2,
	BurstGapMedian = 8,
	BurstGapSpread = 0.6,
	BurstGapMin = 2,
	BurstGapMax = 30,
	JoinGapMedian = 25,
	JoinGapSpread = 0.8,
	JoinGapMin = 5,
	JoinGapMax = 120,
	PairChance = 0.3,
	ShortenGapMedian = 30,
	ShortenGapSpread = 0.5,
	ShortenGapMin = 10,
	ShortenGapMax = 90,
	SessionMedianMinutes = 15,
	SessionSpread = 0.9,
	SessionMinMinutes = 1,
	SessionMaxMinutes = 240,
	RejoinChance = 0.15,
	RejoinDelayMedian = 900,
	RejoinDelaySpread = 0.7,
	RejoinDelayMin = 300,
	RejoinDelayMax = 3600,
	NameRetireSeconds = 7200,
	NameQuarantineSeconds = 600,
	HourCurve = "", -- "" = flat; else 24 comma-separated multipliers
	LocalHourOffset = 0,
	NameCheckOnline = true,
	ReservedNames = "", -- ';'-separated studio alt-account usernames, drawn first
	-- movement
	WalkSpeedMedian = 16,
	WalkSpeedSpread = 0,
	WalkSpeedMax = 32,
	AnalogViaWalkSpeed = true,
	AgentRadius = 2,
	AgentHeight = 5,
	WaypointSpacing = 4,
	CanJump = true,
	CanClimb = false,
	DirectMax = 24,
	KillYOffset = 60, -- killY = worldBounds.min.Y - KillYOffset (never absolute)
	KillY = math.huge, -- explicit override; math.huge means "auto" (a nil value would not be a field of DEFAULTS)
	MaxResetsPerSession = 3,
	DiedRespawnChance = 0.7,
	-- navigation / budgets
	GridCellSize = 2,
	GridMaxCells = 40000,
	GridMaxNodes = 4000,
	GridYieldEvery = 64,
	GridMaxSideStuds = 1200,
	PathBudgetMs = 1.5,
	PathBudgetMaxMs = 4.0,
	TickBudgetMs = 2.5,
	FrameBudgetMs = 4.0,
	MaxTicksPerFrame = 12,
	MaxInFlightRoblox = 2,
	RobloxTimeout = 1.5,
	PathCooldown = 1.0,
	PathCacheTtl = 2,
	StarvationAfter = 6,
	ProviderBackoffSeconds = 30,
	ShedAbove = 8,
	RaycastsPerBrainTick = 8,
	LosRaycastsPerPass = 16,
	ResampleEverySeconds = 300,
	-- tiers
	TierNear = 60,
	TierMid = 200,
	TierFar = 500,
	VisibleRange = 250,
	DowngradeDelay = 2,
	RateNear = 10,
	RateMid = 5,
	RateFar = 2,
	RateDormant = 0.5,
	BrainDivisorNear = 2,
	BrainDivisorMid = 2,
	BrainDivisorFar = 2,
	BrainDivisorDormant = 1,
	-- chat
	ChatEnabled = true,
	ChatHook = "own", -- "own" | "shared"
	ChatNpcMinGap = 4,
	ChatNpcPerMinute = 4,
	ChatNpcPer10Min = 12,
	ChatServerPerMinute = 8,
	ChatServerShare = 0.4,
	ChatQuietAfterSilence = 600,
	ChatReplyBoost = 2,
	ChatExtraPatterns = "", -- ';'-separated Lua patterns; invalid ones are dropped with a warning
	FilterNpcChat = false, -- never a bystander's UserId: a studio-owned alt account id when filtering is on
	FilterUserId = 0,
	ShowTypingIndicator = false,
	ChatAuditCapacity = 500,
	-- presentation
	HeadLook = "off", -- "off" | "shared"; there is no NPC-only mode
	-- avatars / rigs
	UsePrimitiveRigs = false, -- debug flag: force block rigs (the default install builds real default avatars)
	RigPoolSize = 2,
	R6Share = 0.05,
	AutoProps = true,
	-- mimic / eval
	MimicEnabled = true,
	MimicK = 200,
	MimicJitter = 0.05,
	TraceEnabled = false,
	TraceHz = 10,
	TraceMaxSamples = 200000,
	-- errors / debug
	ErrorsPerNpc = 5,
	ErrorWindow = 10,
	Debug = false,
	LogLevel = "warn", -- "off" | "warn" | "info"
	StreamingHint = true, -- warn once when StreamingEnabled and StreamingTargetRadius < 1024
}

Config.DEFAULTS = DEFAULTS

export type Resolved = typeof(DEFAULTS)

-- What the last resolve() ignored and why; Api prints them once at startup.
Config.lastWarnings = {} :: { string }

-- A clamped log-normal draw, as `Rng.logNormalClamped(median, spread, lo, hi)` takes it.
export type Range = { median: number, spread: number, lo: number, hi: number }

-- Subtype of Runtime/Population.Config.
export type PopulationConfig = {
	base: number,
	perPlayer: number,
	min: number,
	max: number,
	curve: { number }?, -- nil = flat
	spawnWhenEmpty: boolean,
	initialBurst: number,
	rejoinChance: number,
	rejoinDelay: Range,
	pairChance: number,
	emptyGrace: number,
	shortenGap: Range,
	burstGap: Range,
	joinGap: Range,
	nameRetire: number,
}

-- Subtype of Runtime/Scheduler.Params.
export type SchedulerParams = {
	near: number,
	mid: number,
	far: number,
	hysteresis: number,
	rates: { [Tier]: number },
	brainDivisor: { [Tier]: number },
	maxTicksPerFrame: number,
}

-- Subtype of Nav/PathPlanner.Params.
export type PlannerParams = {
	maxInFlightRoblox: number,
	robloxTimeout: number,
	cooldown: number,
	cacheTtl: number,
	directMax: number,
	starvationAfter: number,
	backoffSeconds: number,
	gridMaxNodes: number,
	cellSize: number,
	shedAbove: number,
}

-- Subtype of Chat/ChatGuard.Options.
export type ChatGuardOptions = {
	npcMinGap: number,
	npcPerMinute: number,
	npcPer10Min: number,
	serverPerMinute: number,
	serverShare: number,
	quietAfterSilence: number,
	replyBoost: number,
}

-- Subtype of Runtime/Lod.Options.
export type LodOptions = {
	visibleRange: number,
	downgradeDelay: number,
	near: number,
	mid: number,
	far: number,
}

local function trim(text: string): string
	local trimmed = string.gsub(text, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	return trimmed
end

-- "" gives nil (flat); otherwise exactly 24 comma-separated non-negative numbers, else nil.
function Config.hourCurve(text: string): { number }?
	if trim(text) == "" then
		return nil
	end
	local curve: { number } = {}
	for piece in string.gmatch(text .. ",", "([^,]*),") do
		local value = tonumber(trim(piece))
		if value == nil or value < 0 then
			return nil
		end
		table.insert(curve, value)
	end
	if #curve ~= 24 then
		return nil
	end
	return curve
end

-- Seed may be a string or a number; every other key keeps the type of its default.
local function acceptable(name: string, default: any, value: any): boolean
	if typeof(value) == typeof(default) then
		return true
	end
	return name == "Seed" and typeof(value) == "number"
end

-- A copy of DEFAULTS with the source's attributes overlaid. Attribute names are visited in sorted order so the
-- warnings come out the same whatever the attribute table's internal order.
function Config.resolve(source: Instance?): Resolved
	local resolved = table.clone(DEFAULTS)
	local warnings: { string } = {}
	if source ~= nil then
		local attributes: { [string]: any } = source:GetAttributes()
		local names: { string } = {}
		for name in attributes do
			table.insert(names, name)
		end
		table.sort(names)
		local defaults: { [string]: any } = DEFAULTS
		local target: { [string]: any } = resolved
		for _, name in names do
			local value = attributes[name]
			local default = defaults[name]
			if default == nil then
				table.insert(warnings, `unknown attribute "{name}" (ignored)`)
			elseif not acceptable(name, default, value) then
				table.insert(
					warnings,
					`attribute "{name}" is a {typeof(value)}, expected a {typeof(default)} (default kept)`
				)
			else
				target[name] = value
			end
		end
	end
	Config.lastWarnings = warnings
	return resolved
end

-- Every value that would make a module misbehave, as a list of problems (empty when all is well).
function Config.validate(c: Resolved): { string }
	local problems: { string } = {}
	local function report(text: string)
		table.insert(problems, text)
	end
	local function positive(name: string, value: number)
		if not (value > 0) then
			report(`{name} must be > 0 (is {value})`)
		end
	end
	local function atLeast(name: string, value: number, floor: number)
		if not (value >= floor) then
			report(`{name} must be >= {floor} (is {value})`)
		end
	end
	local function share(name: string, value: number)
		if not (value >= 0 and value <= 1) then
			report(`{name} must be in [0, 1] (is {value})`)
		end
	end
	local function ordered(loName: string, lo: number, hiName: string, hi: number)
		if not (lo <= hi) then
			report(`{loName} ({lo}) must be <= {hiName} ({hi})`)
		end
	end
	local function oneOf(name: string, value: string, allowed: { string })
		if table.find(allowed, value) == nil then
			report(`{name} must be one of {table.concat(allowed, " | ")} (is "{value}")`)
		end
	end
	-- budgets
	positive("PathBudgetMs", c.PathBudgetMs)
	positive("PathBudgetMaxMs", c.PathBudgetMaxMs)
	positive("TickBudgetMs", c.TickBudgetMs)
	positive("FrameBudgetMs", c.FrameBudgetMs)
	ordered("PathBudgetMs", c.PathBudgetMs, "PathBudgetMaxMs", c.PathBudgetMaxMs)
	atLeast("MaxTicksPerFrame", c.MaxTicksPerFrame, 1)
	atLeast("MaxInFlightRoblox", c.MaxInFlightRoblox, 0)
	positive("RobloxTimeout", c.RobloxTimeout)
	-- tiers and rates
	positive("TierNear", c.TierNear)
	if not (c.TierNear < c.TierMid and c.TierMid < c.TierFar) then
		report(`tiers must increase: TierNear {c.TierNear} < TierMid {c.TierMid} < TierFar {c.TierFar}`)
	end
	positive("VisibleRange", c.VisibleRange)
	atLeast("DowngradeDelay", c.DowngradeDelay, 0)
	positive("RateNear", c.RateNear)
	positive("RateMid", c.RateMid)
	positive("RateFar", c.RateFar)
	positive("RateDormant", c.RateDormant)
	atLeast("BrainDivisorNear", c.BrainDivisorNear, 1)
	atLeast("BrainDivisorMid", c.BrainDivisorMid, 1)
	atLeast("BrainDivisorFar", c.BrainDivisorFar, 1)
	atLeast("BrainDivisorDormant", c.BrainDivisorDormant, 1)
	-- shares
	share("ChatServerShare", c.ChatServerShare)
	share("R6Share", c.R6Share)
	share("PairChance", c.PairChance)
	share("RejoinChance", c.RejoinChance)
	share("DiedRespawnChance", c.DiedRespawnChance)
	share("MimicJitter", c.MimicJitter)
	-- population
	atLeast("PopulationBase", c.PopulationBase, 0)
	atLeast("PopulationPerPlayer", c.PopulationPerPlayer, 0)
	atLeast("PopulationMin", c.PopulationMin, 0)
	ordered("PopulationMin", c.PopulationMin, "PopulationMax", c.PopulationMax)
	if not (c.PopulationMax <= 100) then
		report(`PopulationMax must be <= 100 (is {c.PopulationMax})`)
	end
	atLeast("EmptyServerGraceSeconds", c.EmptyServerGraceSeconds, 0)
	atLeast("InitialBurst", c.InitialBurst, 0)
	positive("BurstGapMin", c.BurstGapMin)
	ordered("BurstGapMin", c.BurstGapMin, "BurstGapMax", c.BurstGapMax)
	positive("JoinGapMin", c.JoinGapMin)
	ordered("JoinGapMin", c.JoinGapMin, "JoinGapMax", c.JoinGapMax)
	positive("ShortenGapMin", c.ShortenGapMin)
	ordered("ShortenGapMin", c.ShortenGapMin, "ShortenGapMax", c.ShortenGapMax)
	positive("RejoinDelayMin", c.RejoinDelayMin)
	ordered("RejoinDelayMin", c.RejoinDelayMin, "RejoinDelayMax", c.RejoinDelayMax)
	positive("SessionMinMinutes", c.SessionMinMinutes)
	ordered("SessionMinMinutes", c.SessionMinMinutes, "SessionMaxMinutes", c.SessionMaxMinutes)
	atLeast("NameRetireSeconds", c.NameRetireSeconds, 0)
	atLeast("NameQuarantineSeconds", c.NameQuarantineSeconds, 0)
	if c.HourCurve ~= "" and Config.hourCurve(c.HourCurve) == nil then
		report(`HourCurve must be empty or 24 comma-separated non-negative numbers (is "{c.HourCurve}")`)
	end
	-- movement and grid
	positive("WalkSpeedMedian", c.WalkSpeedMedian)
	atLeast("WalkSpeedSpread", c.WalkSpeedSpread, 0)
	ordered("WalkSpeedMedian", c.WalkSpeedMedian, "WalkSpeedMax", c.WalkSpeedMax)
	positive("AgentRadius", c.AgentRadius)
	positive("AgentHeight", c.AgentHeight)
	positive("WaypointSpacing", c.WaypointSpacing)
	atLeast("DirectMax", c.DirectMax, 0)
	positive("GridCellSize", c.GridCellSize)
	positive("GridMaxCells", c.GridMaxCells)
	positive("GridMaxNodes", c.GridMaxNodes)
	positive("GridYieldEvery", c.GridYieldEvery)
	positive("GridMaxSideStuds", c.GridMaxSideStuds)
	atLeast("MaxResetsPerSession", c.MaxResetsPerSession, 0)
	-- chat
	atLeast("ChatNpcMinGap", c.ChatNpcMinGap, 0)
	positive("ChatNpcPerMinute", c.ChatNpcPerMinute)
	positive("ChatNpcPer10Min", c.ChatNpcPer10Min)
	positive("ChatServerPerMinute", c.ChatServerPerMinute)
	atLeast("ChatQuietAfterSilence", c.ChatQuietAfterSilence, 0)
	atLeast("ChatReplyBoost", c.ChatReplyBoost, 0)
	positive("ChatAuditCapacity", c.ChatAuditCapacity)
	oneOf("ChatHook", c.ChatHook, { "own", "shared" })
	oneOf("HeadLook", c.HeadLook, { "off", "shared" })
	oneOf("LogLevel", c.LogLevel, { "off", "warn", "info" })
	-- errors / eval
	positive("ErrorsPerNpc", c.ErrorsPerNpc)
	positive("ErrorWindow", c.ErrorWindow)
	positive("RigPoolSize", c.RigPoolSize)
	positive("MimicK", c.MimicK)
	positive("TraceHz", c.TraceHz)
	positive("TraceMaxSamples", c.TraceMaxSamples)
	return problems
end

function Config.population(c: Resolved): PopulationConfig
	return {
		base = c.PopulationBase,
		perPlayer = c.PopulationPerPlayer,
		min = c.PopulationMin,
		max = c.PopulationMax,
		curve = Config.hourCurve(c.HourCurve),
		spawnWhenEmpty = not c.SpawnOnlyWithPlayers,
		initialBurst = c.InitialBurst,
		rejoinChance = c.RejoinChance,
		rejoinDelay = {
			median = c.RejoinDelayMedian,
			spread = c.RejoinDelaySpread,
			lo = c.RejoinDelayMin,
			hi = c.RejoinDelayMax,
		},
		pairChance = c.PairChance,
		emptyGrace = c.EmptyServerGraceSeconds,
		shortenGap = {
			median = c.ShortenGapMedian,
			spread = c.ShortenGapSpread,
			lo = c.ShortenGapMin,
			hi = c.ShortenGapMax,
		},
		burstGap = { median = c.BurstGapMedian, spread = c.BurstGapSpread, lo = c.BurstGapMin, hi = c.BurstGapMax },
		joinGap = { median = c.JoinGapMedian, spread = c.JoinGapSpread, lo = c.JoinGapMin, hi = c.JoinGapMax },
		nameRetire = c.NameRetireSeconds,
	}
end

function Config.scheduler(c: Resolved): SchedulerParams
	return {
		near = c.TierNear,
		mid = c.TierMid,
		far = c.TierFar,
		hysteresis = 1.25,
		rates = { near = c.RateNear, mid = c.RateMid, far = c.RateFar, dormant = c.RateDormant },
		brainDivisor = {
			near = c.BrainDivisorNear,
			mid = c.BrainDivisorMid,
			far = c.BrainDivisorFar,
			dormant = c.BrainDivisorDormant,
		},
		maxTicksPerFrame = c.MaxTicksPerFrame,
	}
end

function Config.planner(c: Resolved): PlannerParams
	return {
		maxInFlightRoblox = c.MaxInFlightRoblox,
		robloxTimeout = c.RobloxTimeout,
		cooldown = c.PathCooldown,
		cacheTtl = c.PathCacheTtl,
		directMax = c.DirectMax,
		starvationAfter = c.StarvationAfter,
		backoffSeconds = c.ProviderBackoffSeconds,
		gridMaxNodes = c.GridMaxNodes,
		cellSize = c.GridCellSize,
		shedAbove = c.ShedAbove,
	}
end

function Config.chatGuard(c: Resolved): ChatGuardOptions
	return {
		npcMinGap = c.ChatNpcMinGap,
		npcPerMinute = c.ChatNpcPerMinute,
		npcPer10Min = c.ChatNpcPer10Min,
		serverPerMinute = c.ChatServerPerMinute,
		serverShare = c.ChatServerShare,
		quietAfterSilence = c.ChatQuietAfterSilence,
		replyBoost = c.ChatReplyBoost,
	}
end

function Config.lod(c: Resolved): LodOptions
	return {
		visibleRange = c.VisibleRange,
		downgradeDelay = c.DowngradeDelay,
		near = c.TierNear,
		mid = c.TierMid,
		far = c.TierFar,
	}
end

return Config

--!strict
-- Owns every NPC on the server: spawns and despawns them (or asks the adapter to build bodies
-- and registers them when they arrive), runs the budgeted server frame in a fixed order
-- (population, spatial index, LOD tiers under a raycast budget, path planning under a time
-- slice, chat memory and player lines, queued Blocked notifications, the due NPC ticks each
-- inside a pcall with an error budget, mimic and trace sampling, pressure), keeps the shared
-- spatial index and the perception every NPC sees, rate-limits NPC chat through ChatGuard,
-- places spawns on walkable ground outside the no-go and no-spawn volumes, walks an NPC out of
-- a no-go volume it was pushed into, retires usernames, and answers the adapter's events (a
-- player joined or left, a name collision, a death, a respawned body, a blocked path, a game
-- event, a discovery refresh, the server closing). The world itself (bodies, players, the
-- presenter, the navigation grid, the points of interest) comes in through an adapter, so the
-- same service runs under Lune with fake bodies and in Studio with humanoids. It never yields:
-- body building goes through `requestSpawn` when the adapter offers it, and every default it
-- needs comes from the plain resolved config table it is handed (it never requires Config).
-- requires: Avatars, ChatGuard, ErrorBudget, GoalResolver, GridPathProvider, Lod, Memory, MimicSampler,
-- MotionStats, Names, NavGrid, NavMath, Npc, PathPlanner, Personality, PoiRegistry, Population, Ports, Recency,
-- Reply, Report, Rng, Safety, Scheduler, Spatial, Trace, TraceBank, Types

local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)
local Ports = require(script.Parent.Parent.Ports)
local NavMath = require(script.Parent.Parent.Nav.NavMath)
local NavGrid = require(script.Parent.Parent.Nav.NavGrid)
local GridPathProvider = require(script.Parent.Parent.Nav.GridPathProvider)
local GoalResolver = require(script.Parent.Parent.Nav.GoalResolver)
local PathPlanner = require(script.Parent.Parent.Nav.PathPlanner)
local PoiRegistry = require(script.Parent.Parent.World.PoiRegistry)
local Spatial = require(script.Parent.Parent.World.Spatial)
local Personality = require(script.Parent.Parent.Mind.Personality)
local Memory = require(script.Parent.Parent.Mind.Memory)
local Names = require(script.Parent.Parent.Identity.Names)
local Avatars = require(script.Parent.Parent.Identity.Avatars)
local Recency = require(script.Parent.Parent.Chat.Recency)
local Safety = require(script.Parent.Parent.Chat.Safety)
local ChatGuard = require(script.Parent.Parent.Chat.ChatGuard)
local Reply = require(script.Parent.Parent.Chat.Reply)
local MotionStats = require(script.Parent.Parent.Mimic.MotionStats)
local MimicSampler = require(script.Parent.Parent.Mimic.MimicSampler)
local TraceBank = require(script.Parent.Parent.Mimic.TraceBank)
local Trace = require(script.Parent.Parent.Eval.Trace)
local Scheduler = require(script.Parent.Scheduler)
local Lod = require(script.Parent.Lod)
local ErrorBudget = require(script.Parent.ErrorBudget)
local Population = require(script.Parent.Population)
local Npc = require(script.Parent.Npc)
local Report = require(script.Parent.Report)

type Rng = Rng.Rng
type Grid = NavGrid.Grid
type Entity = Spatial.Entity
type FrameStats = Types.FrameStats
type Box = { cframe: CFrame, size: Vector3 }

local NpcService = {}
NpcService.__index = NpcService

-- What the game provides. The landed fields stay; everything after `nameTaken` is optional and
-- additive (§2.32): without `requestSpawn` the service builds bodies synchronously through
-- `createMover`; with it, `stepFrame` only asks and the adapter calls `spawn(now, at, seed, body)`
-- on a later frame with the body it built (the service places it with `body:teleport`).
export type WorldAdapter = {
	-- Builds a body for a new NPC at a position; returns the mover the runtime drives.
	createMover: (id: string, identity: Npc.Identity, persona: any, position: Vector3) -> Npc.Mover,
	destroyMover: (id: string) -> (),
	-- Live views of the real players (position, velocity, yaw, displayName, jumpedAt, emoteAt).
	players: () -> { Entity },
	presenter: Npc.Presenter,
	grid: Grid?, -- the sampled nav grid (fallback / tests)
	primaryProvider: PathPlanner.Provider?, -- the engine's pathfinder, when available
	pois: PoiRegistry.Registry, -- POIs, spawns, avoids and seats
	losCheck: ((from: Vector3, to: Vector3) -> boolean)?,
	occlusion: ((from: Vector3, to: Vector3) -> boolean)?,
	props: { { id: string, position: Vector3, top: number, footprint: number } }?,
	-- Optional: reject a generated username (for example one that resolves to a real account).
	nameTaken: ((username: string) -> boolean)?,
	-- Additions.
	clock: Ports.Clock?, -- hour of day for the population curve (else 12)
	playerLos: ((npcPosition: Vector3, playerPosition: Vector3) -> boolean)?, -- one occlusion raycast, budgeted
	bounds: { min: Vector3, max: Vector3 }?, -- world bounds for the kill plane (else the grid's floor)
	spent: (() -> number)?, -- milliseconds used so far this frame (the adapter's os.clock); nil = never over budget
	telemetry: ((event: Types.NpcEvent) -> ())?,
	avatars: ((id: string, spec: Types.AvatarSpec) -> ())?, -- the avatar drawn for a fresh NPC
	avoidBoxes: (() -> { Box })?, -- NpcAvoid volumes (else the registry's avoids)
	noSpawnBoxes: (() -> { Box })?, -- NpcNoSpawn volumes: never a spawn point inside one
	requestSpawn: ((n: number, pairWith: string?) -> ())?, -- when present, stepFrame never builds bodies itself
	floorAt: ((p: Vector3) -> number?)?, -- floor under a point for the planner's off-grid rule (else the grid)
	customWaypoint: ((label: string?, position: Vector3) -> number?)?, -- seconds to hold at a Custom waypoint
}

-- The landed shape stays. `config` is the resolved Config table (typed structurally so this module
-- never requires Config): when present every default below comes from it. The sub-config tables
-- are what Config's builders return; each is derived from `config` when absent. A `population`
-- table (given or derived from a config with PopulationBase) switches the population model on.
export type Config = {
	seed: (number | string)?,
	chatServerRate: number?, -- landed, no config: lines per second server-wide (ChatGuard takes over with one)
	chatPerNpcPerMinute: number?, -- landed, no config
	chatEnabled: boolean?,
	walkSpeedMedian: number?,
	walkSpeedSpread: number?,
	walkSpeedMax: number?,
	sessionMedianMinutes: number?,
	sessionMaxMinutes: number?,
	sectorSize: number?, -- default 16
	extraSafetyPatterns: { string }?,
	scheduler: Scheduler.Params?,
	-- Additions.
	config: { [string]: any }?,
	population: Population.Config?,
	populationEnabled: boolean?, -- false keeps a derived population model from ticking (tests)
	planner: PathPlanner.Params?,
	chatGuard: ChatGuard.Options?,
	lod: Lod.Options?,
	reservedNames: { string }?, -- Config.ReservedNames split on ';' (drawn first)
}

type Record = {
	npc: Npc.NpcT,
	mover: Npc.Mover,
	identity: Npc.Identity,
	persona: any,
	spawnedAt: number,
	spawnIndex: number?,
	jumpedAt: number?,
	emoteAt: number?,
	emoteName: string?,
	lastCommandJump: boolean,
	chatTimes: { number },
	lastReport: Npc.Report?,
	typing: boolean,
	saidAt: number,
	lastSaidText: string?,
	lastSaidTarget: string?,
	lastSaidLineId: string?,
	sampleEvents: { string },
	avoidExitAt: number,
	probeTarget: string?, -- the subject of the ReactProbe episode the last report showed
	probeEpisodes: { [string]: number }, -- ReactProbe episodes per subject this session (H15 escalation)
}

type ChatEntry = { fromId: string, text: string, position: Vector3, at: number, lineId: string?, seq: number }

type PlayerTrack = { samples: { MotionStats.TrackSample }, key: number, jumpedAt: number? }

export type Stats = {
	spawned: number,
	despawned: number,
	linesSaid: number,
	linesDropped: number,
	errors: number,
	pressure: number,
	frame: FrameStats,
	respawns: number,
	avoidExits: number,
}

export type Service = typeof(setmetatable(
	{} :: {
		rng: Rng,
		config: Config,
		world: WorldAdapter,
		records: { [string]: Record },
		order: { string },
		scheduler: Scheduler.SchedulerT,
		spatial: Spatial.Spatial,
		planner: PathPlanner.Planner,
		gridProvider: GridPathProvider.Provider?,
		recency: Recency.Tracker,
		safety: Safety.Gate,
		guard: ChatGuard.Guard,
		errorBudget: ErrorBudget.Budget,
		lod: Lod.LodT,
		population: Population.Model,
		populationEnabled: boolean,
		names: Names.Pool,
		recentChats: { ChatEntry },
		chatSeq: number, -- every heard line gets the next number, so a perception can tell what it delivered
		serverChatTimes: { number },
		nextNpcIndex: number,
		lastTierAssignAt: number,
		sectorSize: number,
		sectors: { string },
		sectorCenters: { [string]: Vector3 },
		reservedNames: { [string]: number },
		counters: {
			spawned: number,
			despawned: number,
			linesSaid: number,
			errors: number,
			respawns: number,
			avoidExits: number,
		},
		perceptionWorld: any,
		-- Frame state.
		frame: FrameStats,
		lastReports: { [string]: Npc.Report },
		lastNow: number?,
		pressure: number,
		lastPopulationAt: number,
		lastSampleAt: number,
		playersNow: { Entity },
		playerNames: { [string]: string }, -- userId -> displayName, from onPlayerJoined/onPlayerLeft
		playerSaidAt: { [string]: number },
		losCursor: number,
		losVisible: { [string]: boolean },
		blockedQueue: { { id: string, index: number, at: number } },
		knownPoiIds: { [string]: boolean },
		pendingPairWith: string?,
		pendingRejoinSeed: (number | string)?,
		shutdownAt: number?,
		overBudgetReportedAt: number,
		killY: number?,
		-- Budgets and rules (from config or the module defaults).
		pathBudgetMs: number,
		pathBudgetMaxMs: number,
		tickBudgetMs: number,
		frameBudgetMs: number,
		losPerPass: number,
		visibleRange: number,
		diedRespawnChance: number,
		nameRetireSeconds: number,
		canJump: boolean,
		-- Mimic and trace.
		mimicRng: Rng,
		motionStats: MotionStats.Stats?,
		mimic: MimicSampler.Sampler?,
		traceBank: TraceBank.Bank?,
		playerTracks: { [string]: PlayerTrack },
		trace: Trace.Trace?,
		traceHz: number,
	},
	NpcService
))

local POPULATION_INTERVAL = 1 -- seconds between population decisions
local TIER_INTERVAL = 0.5 -- seconds between LOD passes
local CHAT_MEMORY = 3 -- seconds a heard line stays in earshot memory
local CHAT_SNAPSHOT_RADIUS = 50 -- studs: a snapshot at least this wide is the brain's and carries the chat heard
local NAME_WAKE_RANGE = 30 -- studs: a line naming an NPC this close wakes it
local GAME_EVENT_RANGE = 100 -- studs: emitEvent reaches NPCs this close
local AVOID_EXIT_GAP = 5 -- seconds between two avoidExit events for one NPC
local SHUTDOWN_GRACE = 8 -- seconds after shutdown before whoever is left is removed
local OVER_BUDGET_GAP = 10 -- seconds between two frameOverBudget events
local PRESSURE_UP, PRESSURE_DOWN = 0.05, 0.01
local PROBE_EPISODES_TO_BLOCK = 3 -- H15: reactions to one person's probing before they are blocked
local MIMIC_WINDOW = 300 -- player samples (30 s at 10 Hz) folded into MotionStats at a time
local MIMIC_HZ = 10
local SPAWN_ATTEMPTS = 12
local SPAWN_SNAP = 8 -- studs: a spawn point snaps to the nearest walkable cell within this
-- A shortened session ends in LNc(60, 0.5, 20, 180) s (Session.shorten's landed defaults).
local SHORTEN_MEDIAN, SHORTEN_SPREAD, SHORTEN_LO, SHORTEN_HI = 60, 0.5, 20, 180

local function entityId(npcId: string): string
	return "n:" .. npcId
end

local function insideBox(box: Box, point: Vector3): boolean
	local local_ = box.cframe:PointToObjectSpace(point)
	local half = box.size / 2
	return math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z
end

local function sectorsOf(grid: Grid?, size: number): ({ string }, { [string]: Vector3 })
	local ids: { string } = {}
	local centers: { [string]: Vector3 } = {}
	if not grid then
		return ids, centers
	end
	local seen: { [string]: boolean } = {}
	for iz = 0, grid.rows - 1 do
		for ix = 0, grid.cols - 1 do
			if grid:isWalkable(ix, iz) then
				local center = grid:centerOf(ix, iz)
				local id = Memory.sectorId(center, size)
				if not seen[id] then
					seen[id] = true
					table.insert(ids, id)
					-- The first walkable cell found in the sector stands in for its center.
					centers[id] = center
				end
			end
		end
	end
	table.sort(ids)
	return ids, centers
end

-- Config helpers ------------------------------------------------------------------------------------------

-- A key of the resolved config table, or `default` when there is no table or no such key.
local function cfg(config: Config, key: string, default: any): any
	local resolved = config.config
	if resolved ~= nil then
		local value = resolved[key]
		if value ~= nil then
			return value
		end
	end
	return default
end

local function range(c: { [string]: any }, prefix: string): { median: number, spread: number, lo: number, hi: number }
	return {
		median = c[prefix .. "Median"],
		spread = c[prefix .. "Spread"],
		lo = c[prefix .. "Min"],
		hi = c[prefix .. "Max"],
	}
end

-- "" gives nil (flat); else 24 comma-separated non-negative numbers, else nil (Config.hourCurve).
local function hourCurve(text: any): { number }?
	if type(text) ~= "string" then
		return nil
	end
	local curve: { number } = {}
	for piece in string.gmatch(text .. ",", "([^,]*),") do
		local value = tonumber((string.gsub(piece, "%s", "")))
		if value == nil or value < 0 then
			return nil
		end
		table.insert(curve, value)
	end
	return if #curve == 24 then curve else nil
end

-- The sub-config tables Config's builders would return, derived from the resolved table.
local function derivePopulation(c: { [string]: any }): Population.Config?
	if type(c.PopulationBase) ~= "number" then
		return nil
	end
	return {
		base = c.PopulationBase,
		perPlayer = c.PopulationPerPlayer,
		min = c.PopulationMin,
		max = c.PopulationMax,
		curve = hourCurve(c.HourCurve),
		spawnWhenEmpty = not c.SpawnOnlyWithPlayers,
		initialBurst = c.InitialBurst,
		rejoinChance = c.RejoinChance,
		rejoinDelay = range(c, "RejoinDelay"),
		pairChance = c.PairChance,
		emptyGrace = c.EmptyServerGraceSeconds,
		shortenGap = range(c, "ShortenGap"),
		burstGap = range(c, "BurstGap"),
		joinGap = range(c, "JoinGap"),
		nameRetire = c.NameRetireSeconds,
	}
end

local function deriveScheduler(c: { [string]: any }): Scheduler.Params
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

local function derivePlanner(c: { [string]: any }): PathPlanner.Params
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

local function deriveChatGuard(c: { [string]: any }): ChatGuard.Options
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

local function deriveLod(c: { [string]: any }): Lod.Options
	return {
		visibleRange = c.VisibleRange,
		downgradeDelay = c.DowngradeDelay,
		near = c.TierNear,
		mid = c.TierMid,
		far = c.TierFar,
	}
end

local function splitList(text: any): { string }
	local out: { string } = {}
	if type(text) ~= "string" then
		return out
	end
	for piece in string.gmatch(text, "[^;]+") do
		local trimmed = string.match(piece, "^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			table.insert(out, trimmed)
		end
	end
	return out
end

-- Every NPC's locomotion numbers its path requests from 1, while the planner keys its in-flight
-- table by request id alone: two NPCs asking at the same moment would overwrite each other and
-- one of them would wait for an answer forever. The planner's `request` and `step` are wrapped on
-- this instance so every id it sees is unique, and completions carry the requester's own id back
-- (Locomotion matches them against its number). `notifyBlocked` goes through `request`, and a
-- request replayed from the cooldown queue keeps the id it was first given.
local function uniqueRequestIds(planner: PathPlanner.Planner)
	local nextId = 1
	local outerIds: { [number]: number } = {} -- planner id -> the requester's own id
	local owners: { [number]: string } = {} -- planner id -> agent, so a cancel can drop its mappings
	local front: any = planner
	front.request = function(self: PathPlanner.Planner, request: PathPlanner.Request, now: number): number
		local tagged: any = request
		if tagged.outerId == nil then
			tagged.outerId = request.id
			request.id = nextId
			nextId += 1
		end
		-- The planner cancels the agent's older requests first (dropping their mappings below), so this
		-- request's mapping is registered after it returns; nothing completes before the next step.
		local id = PathPlanner.request(self, request, now)
		outerIds[request.id] = tagged.outerId
		owners[request.id] = request.agentId
		return id
	end
	front.step = function(self: PathPlanner.Planner, now: number, spent: (() -> number)?): { PathPlanner.Completion }
		local out = PathPlanner.step(self, now, spent)
		for _, completion in out do
			local outer = outerIds[completion.id]
			if outer then
				outerIds[completion.id] = nil
				owners[completion.id] = nil
				completion.id = outer
			end
		end
		return out
	end
	front.cancel = function(self: PathPlanner.Planner, agentId: string)
		PathPlanner.cancel(self, agentId)
		local dropped: { number } = {}
		for inner, owner in owners do
			if owner == agentId then
				table.insert(dropped, inner)
			end
		end
		for _, inner in dropped do
			owners[inner] = nil
			outerIds[inner] = nil
		end
	end
end

-- The kill plane: an explicit KillY, else KillYOffset below the world's lowest floor.
local function killPlane(config: Config, world: WorldAdapter): number?
	if config.config == nil then
		return nil
	end
	local explicit = cfg(config, "KillY", math.huge)
	if type(explicit) == "number" and explicit ~= math.huge then
		return explicit
	end
	local offset = cfg(config, "KillYOffset", 60)
	local bounds = world.bounds
	if bounds then
		return bounds.min.Y - offset
	end
	local grid = world.grid
	if grid then
		local lowest = math.huge
		for _, y in grid.floor do
			if y ~= nil and y < lowest then
				lowest = y
			end
		end
		if lowest ~= math.huge then
			return lowest - offset
		end
	end
	return nil
end

function NpcService.new(config: Config, world: WorldAdapter): Service
	local rng = Rng.new(config.seed or "humanlike-npc")
	local resolved: { [string]: any }? = config.config
	local grid = world.grid
	local gridProvider: GridPathProvider.Provider? = nil
	if grid then
		if resolved then
			gridProvider = GridPathProvider.new(grid, {
				budgetMs = cfg(config, "PathBudgetMs", 1.5),
				yieldEvery = cfg(config, "GridYieldEvery", 64),
				maxNodes = cfg(config, "GridMaxNodes", 4000),
			})
		else
			gridProvider = GridPathProvider.new(grid)
		end
	end
	local fallback: PathPlanner.Provider = (gridProvider :: any)
		or {
			name = "none",
			submit = function() end,
			cancel = function() end,
			cancelAgent = function() end,
			step = function()
				return {}
			end,
			inFlight = function()
				return 0
			end,
		}
	local resolver = GoalResolver.new(grid, world.pois)
	local plannerParams: PathPlanner.Params = if config.planner
		then table.clone(config.planner)
		elseif resolved then derivePlanner(resolved)
		else {}
	plannerParams.losCheck = world.losCheck
	if grid then
		plannerParams.cellSize = plannerParams.cellSize or grid.cellSize
		plannerParams.floorAt = world.floorAt
			or function(p: Vector3): number?
				return grid:floorAt(grid:cellOf(p))
			end
	end
	local planner = PathPlanner.new(world.primaryProvider, fallback, resolver, plannerParams)
	uniqueRequestIds(planner)
	local sectorSize = config.sectorSize or 16
	local sectors, centers = sectorsOf(grid, sectorSize)
	local schedulerParams: Scheduler.Params? = config.scheduler
	if schedulerParams == nil and resolved then
		schedulerParams = deriveScheduler(resolved)
	end
	local guardOptions: ChatGuard.Options? = config.chatGuard
	if guardOptions == nil and resolved then
		guardOptions = deriveChatGuard(resolved)
	end
	local lodOptions: Lod.Options? = config.lod
	if lodOptions == nil and resolved then
		lodOptions = deriveLod(resolved)
	end
	local populationConfig: Population.Config? = config.population
	local populationEnabled = populationConfig ~= nil
	if populationConfig == nil and resolved then
		populationConfig = derivePopulation(resolved)
	end
	if config.populationEnabled == false then
		populationEnabled = false
	end
	local extraPatterns: { string }? = config.extraSafetyPatterns
	if extraPatterns == nil and resolved then
		extraPatterns = splitList(resolved.ChatExtraPatterns)
	end
	local preferred: { string }? = config.reservedNames
	if preferred == nil and resolved then
		preferred = splitList(resolved.ReservedNames)
	end
	-- Root forks in Appendix A's order: names, world (in buildWorldView), population, mimic.
	local names = Names.newPool(rng:fork("names"), nil, preferred)
	local self = setmetatable({
		rng = rng,
		config = config,
		world = world,
		records = {},
		order = {},
		scheduler = Scheduler.new(schedulerParams),
		spatial = Spatial.new(),
		planner = planner,
		gridProvider = gridProvider,
		recency = Recency.new(),
		safety = Safety.new(extraPatterns, cfg(config, "ChatAuditCapacity", nil)),
		guard = ChatGuard.new(guardOptions, 0),
		errorBudget = ErrorBudget.new({
			maxErrors = cfg(config, "ErrorsPerNpc", nil),
			window = cfg(config, "ErrorWindow", nil),
		}),
		lod = Lod.new(lodOptions),
		population = nil :: any,
		populationEnabled = populationEnabled,
		names = names,
		recentChats = {},
		chatSeq = 0,
		serverChatTimes = {},
		nextNpcIndex = 1,
		lastTierAssignAt = -math.huge,
		sectorSize = sectorSize,
		sectors = sectors,
		sectorCenters = centers,
		reservedNames = {},
		counters = { spawned = 0, despawned = 0, linesSaid = 0, errors = 0, respawns = 0, avoidExits = 0 },
		perceptionWorld = nil,
		frame = Report.emptyFrame(),
		lastReports = {},
		lastNow = nil,
		pressure = 0,
		lastPopulationAt = -math.huge,
		lastSampleAt = -math.huge,
		playersNow = {},
		playerNames = {},
		playerSaidAt = {},
		losCursor = 1,
		losVisible = {},
		blockedQueue = {},
		knownPoiIds = {},
		pendingPairWith = nil,
		pendingRejoinSeed = nil,
		shutdownAt = nil,
		overBudgetReportedAt = -math.huge,
		killY = killPlane(config, world),
		pathBudgetMs = cfg(config, "PathBudgetMs", 1.5),
		pathBudgetMaxMs = cfg(config, "PathBudgetMaxMs", 4),
		tickBudgetMs = cfg(config, "TickBudgetMs", 2.5),
		frameBudgetMs = cfg(config, "FrameBudgetMs", 4),
		losPerPass = cfg(config, "LosRaycastsPerPass", 16),
		visibleRange = cfg(config, "VisibleRange", 250),
		diedRespawnChance = cfg(config, "DiedRespawnChance", 0.7),
		nameRetireSeconds = cfg(config, "NameRetireSeconds", 7200),
		canJump = cfg(config, "CanJump", true),
		mimicRng = nil :: any,
		motionStats = nil :: MotionStats.Stats?,
		mimic = nil :: MimicSampler.Sampler?,
		traceBank = nil :: TraceBank.Bank?,
		playerTracks = {},
		trace = nil :: Trace.Trace?,
		traceHz = cfg(config, "TraceHz", 10),
	}, NpcService)
	if config.chatEnabled == false or cfg(config, "ChatEnabled", true) == false then
		self.safety:setEnabled(false)
	end
	self.perceptionWorld = NpcService.buildWorldView(self)
	self.population = Population.new(rng:fork("population"), populationConfig)
	self.mimicRng = rng:fork("mimic")
	if resolved and cfg(config, "MimicEnabled", true) == true then
		local stats = MotionStats.new()
		self.motionStats = stats
		self.mimic =
			MimicSampler.new(stats, { k = cfg(config, "MimicK", nil), jitter = cfg(config, "MimicJitter", nil) })
		self.traceBank = TraceBank.new()
	end
	if resolved and cfg(config, "TraceEnabled", false) == true then
		local trace = Trace.new({ hz = self.traceHz, maxSamples = cfg(config, "TraceMaxSamples", nil) })
		self.trace = trace
		for _, poi in world.pois:all() do
			trace:mark({ kind = "poi", at = 0, subject = poi.id, source = poi.position })
		end
		for _, box in NpcService.avoidBoxes(self) do
			trace:mark({ kind = "avoidBox", at = 0, cframe = box.cframe, size = box.size })
		end
	end
	return self
end

-- The no-go volumes: the adapter's, else the registry's.
function NpcService.avoidBoxes(self: Service): { Box }
	local fn = self.world.avoidBoxes
	if fn then
		return fn()
	end
	local out: { Box } = {}
	for _, avoid in self.world.pois.avoids do
		table.insert(out, { cframe = avoid.cframe, size = avoid.size })
	end
	return out
end

-- The static part of what NPCs perceive (POIs, seats, navigation queries); entities are added per
-- NPC. The table is mutated in place by onDiscoveryRefresh so every NPC's perception stays current.
function NpcService.buildWorldView(self: Service): any
	local grid = self.world.grid
	local pois = self.world.pois
	local spatial = self.spatial
	local rng = self.rng:fork("world")
	local centers = self.sectorCenters
	local sectors = self.sectors
	local function poiList()
		local out = {}
		local known: { [string]: boolean } = {}
		for _, poi in pois:all() do
			table.insert(out, poi)
			known[poi.id] = true
		end
		self.knownPoiIds = known
		return out
	end
	local view = {
		pois = poiList(),
		poiOccupants = function(poiId)
			local poi = pois:get(poiId)
			if not poi then
				return 0
			end
			return #spatial:near(poi.position, poi.radius)
		end,
		entities = {},
		visible = {},
		groups = {},
		myGroup = nil,
		spawnPoint = pois:spawnPoint(0.5, 0.5) or Vector3.zero,
		reachable = function(position)
			if not grid then
				return true
			end
			local ix = grid:nearestWalkable(position, 4)
			return ix ~= nil
		end,
		randomReachable = function(from: Vector3, minDistance: number, maxDistance: number, toward: Vector3?): Vector3?
			if not grid then
				local dir = if toward
					then NavMath.flatDirection(from, toward)
					else NavMath.dirFromYaw(rng:range(0, math.pi * 2))
				return from + dir * rng:range(minDistance, maxDistance)
			end
			for _ = 1, 12 do
				local yaw
				if toward then
					local base = NavMath.yawOf(NavMath.flatDirection(from, toward))
					yaw = base + rng:gaussian(0, 0.5)
				else
					yaw = rng:range(0, math.pi * 2)
				end
				local point = from + NavMath.dirFromYaw(yaw) * rng:range(minDistance, maxDistance)
				local ix, iz = grid:nearestWalkable(point, 4)
				if ix then
					local center = grid:centerOf(ix :: number, iz :: number)
					if not pois:isAvoided(center) then
						return center
					end
				end
			end
			return nil
		end,
		sectorCenter = function(sectorId)
			return centers[sectorId]
		end,
		nearbySectors = function(from: Vector3, count: number): { string }
			local ranked = {}
			for _, id in sectors do
				local c = centers[id]
				table.insert(ranked, { id = id, d = NavMath.flatDistance(from, c) })
			end
			table.sort(ranked, function(a, b)
				return a.d < b.d
			end)
			local out = {}
			for i = 1, math.min(count * 3, #ranked) do
				table.insert(out, ranked[i].id)
			end
			return out
		end,
		totalSectors = #sectors,
		isAvoided = function(position)
			return pois:isAvoided(position)
		end,
		failedRecently = function()
			return false
		end,
		props = self.world.props,
		-- Seats through the registry (Goals.World's optional closures).
		seats = pois:seats(),
		seatsNear = function(position: Vector3, radius: number)
			return pois:seatsNear(position, radius)
		end,
		occupySeat = function(seatId: string, who: string): boolean
			return pois:occupySeat(seatId, who)
		end,
		releaseSeat = function(seatId: string, who: string)
			pois:releaseSeat(seatId, who)
		end,
	}
	return view
end

-- Chat rate limits without a config (landed rules): server-wide lines per second and per-NPC lines
-- per minute. With a config the ChatGuard decides and this is never consulted.
local function chatAllowed(self: Service, npcId: string, now: number): boolean
	local rate = self.config.chatServerRate or 0.5
	local perMinute = self.config.chatPerNpcPerMinute or 3
	local times = self.serverChatTimes
	while #times > 0 and now - times[1] > 10 do
		table.remove(times, 1)
	end
	if #times >= rate * 10 then
		return false
	end
	local record = self.records[npcId]
	if record then
		local mine = record.chatTimes
		while #mine > 0 and now - mine[1] > 60 do
			table.remove(mine, 1)
		end
		if #mine >= perMinute then
			return false
		end
		table.insert(mine, now)
	end
	table.insert(times, now)
	return true
end

-- Perception for one NPC, backed by the shared spatial index.
local function makePerception(self: Service, npcId: string): Npc.Perception
	local spatial = self.spatial
	local world = self.world
	local myEntityId = entityId(npcId)
	local perception: { [string]: any } = {
		world = self.perceptionWorld,
		occlusion = world.occlusion,
		losCheck = world.losCheck,
	}
	local grid = world.grid
	if grid then
		perception.walkableCheck = function(point: Vector3): string
			local ix, iz = grid:cellOf(point)
			if grid:isWalkable(ix, iz) then
				return "walkable"
			elseif grid:isBlocked(ix, iz) then
				return "wall"
			end
			return "void"
		end
	end
	-- Chat is delivered once: a line reaches this NPC in the first hearing-range snapshot after it was
	-- said (Types.Snapshot: "since the last snapshot"); the short steering snapshots carry no chat.
	local lastChatSeq = 0
	function perception.snapshot(_, _, position, radius)
		local entities = spatial:near(position, radius, myEntityId)
		local chats = {}
		if radius >= CHAT_SNAPSHOT_RADIUS then
			local newest = lastChatSeq
			for _, c in self.recentChats do
				if c.seq > lastChatSeq then
					newest = math.max(newest, c.seq)
					if c.fromId ~= myEntityId and NavMath.flatDistance(c.position, position) <= radius then
						table.insert(chats, c)
					end
				end
			end
			lastChatSeq = newest
		end
		return { entities = entities, chats = chats }
	end
	function perception.groups(_)
		return spatial:groups()
	end
	function perception.groupOf(_, id)
		return spatial:groupOf(id)
	end
	function perception.entity(_, id)
		return spatial:get(id)
	end
	function perception.playersWithin(_, position, radius)
		local n = 0
		for _, e in spatial:near(position, radius) do
			if e.kind == "player" then
				n += 1
			end
		end
		return n
	end
	return perception :: any
end

local function telemetry(self: Service, kind: string, npcId: string, now: number, data: { [string]: any }?)
	local fn = self.world.telemetry
	if fn then
		fn({ kind = kind, npcId = npcId, at = now, data = data })
	end
end

-- Names ----------------------------------------------------------------------------------------------------

-- True when a real player present carries this username or display name (F15).
local function playerHasName(self: Service, name: string): boolean
	local wanted = string.lower(name)
	for _, displayName in self.playerNames do
		if string.lower(displayName) == wanted then
			return true
		end
	end
	return false
end

local function takeName(self: Service, accountAgeDays: number?): Names.Name
	local name: Names.Name? = nil
	for _ = 1, 20 do
		local candidate = self.names:take(nil, accountAgeDays)
		name = candidate
		local taken = self.world.nameTaken ~= nil and self.world.nameTaken(candidate.username)
		if
			not taken
			and not playerHasName(self, candidate.username)
			and not playerHasName(self, candidate.displayName)
		then
			return candidate
		end
		self.names:reject(candidate.username)
	end
	return name :: Names.Name
end

-- Spawn placement -------------------------------------------------------------------------------------------

local function insideNoSpawn(self: Service, point: Vector3): boolean
	local fn = self.world.noSpawnBoxes
	if not fn then
		return false
	end
	for _, box in fn() do
		if insideBox(box, point) then
			return true
		end
	end
	return false
end

-- The centre of the walkable ground (mean of the walkable cells, snapped): the stand-in spawn when
-- the place has no NpcSpawn area.
local function walkableCentre(grid: Grid): Vector3?
	local sum = Vector3.zero
	local n = 0
	for iz = 0, grid.rows - 1 do
		for ix = 0, grid.cols - 1 do
			if grid:isWalkable(ix, iz) then
				sum += grid:centerOf(ix, iz)
				n += 1
			end
		end
	end
	if n == 0 then
		return nil
	end
	local ix, iz = grid:nearestWalkable(sum / n, 64)
	if ix then
		return grid:centerOf(ix :: number, iz :: number)
	end
	return nil
end

-- A point on an NpcSpawn area (a pair's area when given), snapped to walkable ground, never inside a
-- no-go or no-spawn volume, never off the grid. Falls back to the last candidate it saw.
local function placeSpawn(self: Service, spawnIndex: number?): (Vector3, number?)
	local pois = self.world.pois
	local grid = self.world.grid
	local rng = self.rng
	local fallback: Vector3? = nil
	local fallbackIndex: number? = nil
	for _ = 1, SPAWN_ATTEMPTS do
		local u1, u2 = rng:next(), rng:next()
		local index: number? = spawnIndex or rng:int(1, math.max(1, #pois.spawns))
		local point = pois:spawnPoint(u1, u2, index)
		if not point then
			index = nil
			point = if grid then walkableCentre(grid) else nil
			if not point then
				point = Vector3.zero
			end
		end
		local candidate: Vector3 = point :: Vector3
		if grid then
			local ix, iz = grid:nearestWalkable(candidate, SPAWN_SNAP)
			if not ix then
				continue -- off the grid: never a spawn point
			end
			candidate = grid:centerOf(ix :: number, iz :: number)
		end
		if fallback == nil then
			fallback, fallbackIndex = candidate, index
		end
		if not pois:isAvoided(candidate) and not insideNoSpawn(self, candidate) then
			return candidate, index
		end
	end
	return fallback or Vector3.zero, fallbackIndex
end

-- Spawning ---------------------------------------------------------------------------------------------------

-- A new NPC. `at` places it exactly; `seed` reuses a departed persona (rejoin); `body` is a mover the
-- adapter built already (the service places it with `teleport`). Returns the NPC id.
function NpcService.spawn(
	self: Service,
	now: number,
	at: Vector3?,
	seed: (number | string)?,
	body: Ports.Mover?
): string
	local index = self.nextNpcIndex
	self.nextNpcIndex += 1
	local id = `npc{index}`
	if seed == nil and self.pendingRejoinSeed ~= nil then
		seed = self.pendingRejoinSeed
	end
	self.pendingRejoinSeed = nil
	local seedValue: number | string = seed or Rng.hash(`{self.config.seed or "humanlike-npc"}:{index}`)
	local npcSeed = Rng.new(seedValue)
	local persona = Personality.sample(npcSeed, {
		walkSpeedMedian = self.config.walkSpeedMedian or cfg(self.config, "WalkSpeedMedian", nil),
		walkSpeedSpread = self.config.walkSpeedSpread or cfg(self.config, "WalkSpeedSpread", nil),
		walkSpeedMax = self.config.walkSpeedMax or cfg(self.config, "WalkSpeedMax", nil),
		sessionMedianMinutes = self.config.sessionMedianMinutes or cfg(self.config, "SessionMedianMinutes", nil),
		sessionMaxMinutes = self.config.sessionMaxMinutes or cfg(self.config, "SessionMaxMinutes", nil),
		r6Share = cfg(self.config, "R6Share", nil),
	})
	local name = takeName(self, persona.accountAgeDays)
	local identity: Npc.Identity = {
		id = id,
		username = name.username,
		displayName = name.displayName,
		accountAgeDays = persona.accountAgeDays,
		familiarity = persona.familiarity,
		seed = seedValue,
	}
	-- Favourite kind of place: weighted by the POIs present and curiosity (kinds sorted so the draw
	-- never depends on hash order).
	local favorite: string? = nil
	local kinds: { string } = {}
	local weights: { number } = {}
	local kindWeight: { [string]: number } = {}
	for _, poi in self.world.pois:all() do
		if kindWeight[poi.kind] == nil then
			table.insert(kinds, poi.kind)
		end
		kindWeight[poi.kind] = (kindWeight[poi.kind] or 0) + poi.weight
	end
	if #kinds > 0 then
		table.sort(kinds)
		for _, kind in kinds do
			table.insert(weights, kindWeight[kind] * (1 + persona.curiosity))
		end
		favorite = kinds[npcSeed:fork("favorite"):weightedIndex(weights)]
	end
	local avatar = Avatars.sample(npcSeed:fork("avatar"), persona, {
		forcePrimitive = cfg(self.config, "UsePrimitiveRigs", false) == true,
	})
	-- Placement: a given point, the pair's spawn area, or any area.
	local pairWith = self.pendingPairWith
	self.pendingPairWith = nil
	local pair = if pairWith then self.records[pairWith] else nil
	local position: Vector3
	local spawnIndex: number? = nil
	if at then
		position = at
	else
		position, spawnIndex = placeSpawn(self, if pair then pair.spawnIndex else nil)
	end
	local mover: Npc.Mover
	if body then
		mover = body
		body:teleport(position)
	else
		mover = self.world.createMover(id, identity, persona, position)
	end
	if self.world.avatars then
		self.world.avatars(id, avatar)
	end
	local guard = self.guard
	local npc = Npc.new(identity, persona, npcSeed, {
		mover = mover,
		presenter = self.world.presenter,
		perception = makePerception(self, id),
		planner = self.planner,
		chat = {
			recency = self.recency,
			safety = self.safety,
			allow = function(npcId, atTime)
				if self.config.config ~= nil then
					return guard:allow(npcId, atTime)
				end
				return chatAllowed(self, npcId, atTime)
			end,
			guard = if self.config.config ~= nil then guard else nil,
		},
		agentParams = { canJump = self.canJump },
		killY = self.killY,
		mimic = self.mimic,
		traces = self.traceBank,
		customWaypoint = self.world.customWaypoint,
	}, now, favorite)
	self.records[id] = {
		npc = npc,
		mover = mover,
		identity = identity,
		persona = persona,
		spawnedAt = now,
		spawnIndex = spawnIndex,
		jumpedAt = nil,
		emoteAt = nil,
		emoteName = nil,
		lastCommandJump = false,
		chatTimes = {},
		lastReport = nil,
		typing = false,
		saidAt = -math.huge,
		lastSaidText = nil,
		lastSaidTarget = nil,
		lastSaidLineId = nil,
		sampleEvents = {},
		avoidExitAt = -math.huge,
		probeTarget = nil,
		probeEpisodes = {},
	}
	table.insert(self.order, id)
	self.scheduler:add(id, Rng.hash(id) / 4294967296, now)
	self.counters.spawned += 1
	self.population:onJoined(id)
	if pair then
		-- Friends who joined together: warmth on both sides from the start.
		npc.brain.guard:warm(entityId(pairWith :: string), 0.6, now)
		pair.npc.brain.guard:warm(entityId(id), 0.6, now)
	end
	local trace = self.trace
	if trace then
		trace:mark({
			kind = "identity",
			at = now,
			subject = entityId(id),
			text = identity.username,
			family = name.family,
			avatar = tostring(avatar.catalogSeed),
		})
	end
	telemetry(self, "spawn", id, now, {
		username = identity.username,
		displayName = identity.displayName,
		accountAgeDays = persona.accountAgeDays,
		familiarity = persona.familiarity,
		walkSpeed = persona.walkSpeed,
		seed = seedValue,
	})
	return id
end

-- Retires a username: released to the pool after NameRetireSeconds (Population's list when it runs).
local function retireName(self: Service, username: string, now: number)
	if self.populationEnabled then
		self.population:retireName(username, now)
	else
		self.reservedNames[username] = now + self.nameRetireSeconds
	end
end

function NpcService.despawn(self: Service, id: string, reason: string, now: number)
	local record = self.records[id]
	if not record then
		return
	end
	self.records[id] = nil
	for i, other in self.order do
		if other == id then
			table.remove(self.order, i)
			break
		end
	end
	self.lastReports[id] = nil
	self.scheduler:remove(id)
	self.planner:cancel(id)
	local primary: any = self.world.primaryProvider
	if primary and type(primary.forgetAgent) == "function" then
		primary:forgetAgent(id)
	end
	self.recency:forget(id)
	self.guard:forget(id)
	self.errorBudget:forget(id)
	self.lod:forget(id)
	self.losVisible[id] = nil
	local sitting = record.npc.sitting
	if sitting then
		self.world.pois:releaseSeat(sitting, id)
	end
	if reason ~= "session" then
		-- The leave story an NPC tells itself ends with presenter:leave; every other exit is ours to announce.
		self.world.presenter:leave(id, reason)
	end
	self.world.destroyMover(id)
	-- A death keeps the name (a real player keeps theirs); every other exit retires it for a while.
	if reason ~= "died" then
		retireName(self, record.identity.username, now)
	end
	if reason == "session" or reason == "shortened" then
		self.population:onLeft(record.identity.seed or id, now)
	end
	self.counters.despawned += 1
	local trace = self.trace
	if trace then
		trace:mark({ kind = "leave", at = now, subject = entityId(id), text = reason })
	end
	telemetry(self, "despawn", id, now, {
		username = record.identity.username,
		displayName = record.identity.displayName,
		reason = reason,
	})
end

-- Players and chat -------------------------------------------------------------------------------------------

-- A real player said something (server-side hook): NPCs within earshot may hear it; those it names
-- wake up at once; the guard counts it for the share rule.
function NpcService.onPlayerChat(self: Service, playerId: string, text: string, position: Vector3, now: number)
	local fromId = "p:" .. playerId
	self.chatSeq += 1
	table.insert(
		self.recentChats,
		{ fromId = fromId, text = text, position = position, at = now, lineId = nil, seq = self.chatSeq }
	)
	self.guard:onPlayerLine(now)
	self.playerSaidAt[fromId] = now
	local normalized = Reply.normalize(text)
	for _, id in self.order do
		local record = self.records[id]
		if not record then
			continue
		end
		local me = self.spatial:get(entityId(id))
		if me and NavMath.flatDistance(me.position, position) <= NAME_WAKE_RANGE then
			if Reply.isNamed(normalized, record.identity.displayName, record.identity.username) then
				self.scheduler:wake(id, now)
			end
		end
	end
	local trace = self.trace
	if trace then
		trace:mark({ kind = "playerLine", at = now, subject = fromId, source = position, text = text })
	end
end

-- An NPC said something: other NPCs hear it too (parity), the counters and the trace see it. The
-- corpus line id comes from the caller or, failing that, from the safety audit the overlay wrote
-- just before the presenter was asked to speak.
function NpcService.notifySaid(self: Service, id: string, text: string, now: number, lineId: string?)
	local record = self.records[id]
	if not record then
		return
	end
	local target: string? = nil
	if lineId == nil then
		local entries = self.safety:log(16)
		for i = #entries, 1, -1 do
			local entry = entries[i]
			if entry.npcId == id and entry.text == text then
				lineId = entry.lineId
				target = entry.target
				break
			end
		end
	end
	local me = self.spatial:get(entityId(id))
	local position = if me then me.position else record.mover:read().position
	self.chatSeq += 1
	table.insert(
		self.recentChats,
		{ fromId = entityId(id), text = text, position = position, at = now, lineId = lineId, seq = self.chatSeq }
	)
	self.counters.linesSaid += 1
	record.saidAt = now
	record.lastSaidText = text
	record.lastSaidTarget = target
	record.lastSaidLineId = lineId
	telemetry(self, "line", id, now, { text = text, lineId = lineId, target = target })
end

function NpcService.notifyEmote(self: Service, id: string, name: string?, now: number)
	local record = self.records[id]
	if record then
		record.emoteAt = if name then now else nil
		record.emoteName = name
	end
end

-- Pulls an NPC forward to the next frame with a brain tick (a player spoke to or bumped it).
function NpcService.wake(self: Service, id: string, now: number)
	self.scheduler:wake(id, now)
end

-- Every NPC whose username or display name is the newcomer's: their session ends soon (F15).
function NpcService.onNameCollision(self: Service, displayName: string, now: number)
	local wanted = string.lower(displayName)
	for _, id in self.order do
		local record = self.records[id]
		if not record then
			continue
		end
		local identity = record.identity
		if string.lower(identity.displayName) == wanted or string.lower(identity.username) == wanted then
			record.npc:onSystemEvent("nameCollision", now)
		end
	end
end

-- PlayerAdded (before the character exists): the population's burst starts, names are checked.
function NpcService.onPlayerJoined(self: Service, userId: number | string, displayName: string, now: number)
	self.playerNames[tostring(userId)] = displayName
	self.population:onPlayerJoined(now)
	self:onNameCollision(displayName, now)
end

function NpcService.onPlayerLeft(self: Service, userId: number | string, now: number)
	local key = tostring(userId)
	self.playerNames[key] = nil
	local count = 0
	for _ in self.playerNames do
		count += 1
	end
	self.population:onPlayerLeft(count, now)
	local playerId = "p:" .. key
	local track = self.playerTracks[playerId]
	if track then
		self.playerTracks[playerId] = nil
		if self.traceBank then
			self.traceBank:forget(track.key)
		end
	end
	self.playerSaidAt[playerId] = nil
	for _, id in self.order do
		local record = self.records[id]
		if record then
			record.npc.brain.guard:forget(playerId)
		end
	end
end

-- Adapter events -------------------------------------------------------------------------------------------

-- Path.Blocked from the engine (through Api): queued, handed to the NPC in the next frame's fixed order.
function NpcService.onBlocked(self: Service, id: string, blockedIndex: number, now: number)
	table.insert(self.blockedQueue, { id = id, index = blockedIndex, at = now })
end

-- Humanoid.Died: usually the same person respawns (a fresh body through the presenter's reset story,
-- then onRebind), sometimes they rage-quit. The username is never quarantined either way.
function NpcService.onDied(self: Service, id: string, now: number)
	local record = self.records[id]
	if not record then
		return
	end
	local presenter = self.world.presenter
	local reset = presenter.reset
	if reset and self.rng:chance(self.diedRespawnChance) then
		record.npc.dead = true
		record.npc.loco:reset(now)
		record.npc.lastLocomotion = "dead"
		self.counters.respawns += 1
		telemetry(self, "died", id, now, { respawn = true })
		local trace = self.trace
		if trace then
			trace:mark({ kind = "reset", at = now, subject = entityId(id), text = "died" })
		end
		reset(presenter, id)
	else
		telemetry(self, "died", id, now, { respawn = false })
		self:despawn(id, "died", now)
	end
end

-- The adapter's fresh body after a reset or a death: the NPC starts over on it.
function NpcService.onRebind(self: Service, id: string, mover: Ports.Mover, now: number)
	local record = self.records[id]
	if not record then
		return
	end
	record.mover = mover
	record.npc:rebind(mover, now)
end

-- A game event NPCs may react to: everyone within range who is close enough to a player to be watched.
function NpcService.emitEvent(self: Service, name: string, position: Vector3, magnitude: number, now: number)
	for _, id in self.order do
		local record = self.records[id]
		if not record then
			continue
		end
		local tier = record.npc.tier
		if tier ~= "near" and tier ~= "mid" then
			continue
		end
		local me = self.spatial:get(entityId(id))
		if me and NavMath.flatDistance(me.position, position) <= GAME_EVENT_RANGE then
			record.npc:onSystemEvent("gameEvent", now, position, { name = name, magnitude = magnitude })
			telemetry(self, "gameEvent", id, now, { name = name, magnitude = magnitude })
		end
	end
end

-- POIs or seats changed: the shared view is rebuilt in place, NPCs heading for a place that is gone
-- learn it, seat occupancy of removed seats is dropped.
function NpcService.onDiscoveryRefresh(self: Service, now: number)
	local before = self.knownPoiIds
	local fresh = NpcService.buildWorldView(self)
	local view: { [string]: any } = self.perceptionWorld
	for key, value in fresh do
		view[key] = value
	end
	local pois = self.world.pois
	local seatIds: { [string]: boolean } = {}
	for _, seat in pois:seats() do
		seatIds[seat.id] = true
	end
	for seatId in pois.seatOccupants do
		if not seatIds[seatId] then
			pois.seatOccupants[seatId] = nil
		end
	end
	for _, id in self.order do
		local record = self.records[id]
		if not record then
			continue
		end
		local target = record.npc.brain:describe().target
		if target and before[target] and not self.knownPoiIds[target] then
			record.npc:onSystemEvent("goalInvalid", now)
		end
		local sitting = record.npc.sitting
		if sitting and not seatIds[sitting] then
			record.npc.sitting = nil
		end
	end
	local trace = self.trace
	if trace then
		for _, poi in pois:all() do
			if not before[poi.id] then
				trace:mark({ kind = "poi", at = now, subject = poi.id, source = poi.position })
			end
		end
	end
end

-- The server is closing: everyone leaves at once (the brain's Leave), and whoever is still here after
-- the grace is removed by the next frame.
function NpcService.shutdown(self: Service, now: number)
	self.shutdownAt = now
	for _, id in self.order do
		local record = self.records[id]
		if record then
			record.npc:onSystemEvent("serverClosing", now)
		end
	end
end

function NpcService.tellTrace(self: Service): Trace.Trace?
	return self.trace
end

function NpcService.stats(self: Service): Stats
	local c = self.counters
	return {
		spawned = c.spawned,
		despawned = c.despawned,
		linesSaid = c.linesSaid,
		linesDropped = self.guard:dropped(),
		errors = c.errors,
		pressure = self.pressure,
		frame = self.frame,
		respawns = c.respawns,
		avoidExits = c.avoidExits,
	}
end

-- The frame --------------------------------------------------------------------------------------------------

local function currentHour(self: Service): number
	local clock = self.world.clock
	if clock and clock.hour then
		return clock.hour(clock)
	end
	return 12
end

-- 1. The population model, once per second: shorten, retire, and ask for spawns (never built here
-- when the adapter offers requestSpawn).
local function stepPopulation(self: Service, now: number, frame: FrameStats)
	if now - self.lastPopulationAt < POPULATION_INTERVAL then
		return
	end
	self.lastPopulationAt = now
	-- Names reserved long enough ago (the no-population path).
	local due: { string } = {}
	for name, until_ in self.reservedNames do
		if now >= until_ then
			table.insert(due, name)
		end
	end
	table.sort(due)
	for _, name in due do
		self.reservedNames[name] = nil
		self.names:release(name)
	end
	-- Housekeeping nobody else does: recency entries out of their windows, path-cache entries past
	-- their TTL (the planner only ever adds), and the cooldowns of NPCs that left.
	self.recency:prune(now)
	local planner = self.planner
	local ttl = planner.params.cacheTtl or 2
	local stale: { string } = {}
	for key, entry in planner.cache do
		if now - entry.at >= ttl then
			table.insert(stale, key)
		end
	end
	for _, key in stale do
		planner.cache[key] = nil
	end
	local gone: { string } = {}
	for agentId in planner.cooldownUntil do
		if self.records[agentId] == nil then
			table.insert(gone, agentId)
		end
	end
	for _, agentId in gone do
		planner.cooldownUntil[agentId] = nil
	end
	if not self.populationEnabled then
		return
	end
	local playerCount = #self.playersNow
	local hour = currentHour(self)
	local npcCount = #self.order
	local decision = self.population:tick(now, playerCount, npcCount, hour)
	for _, username in decision.retire do
		self.names:release(username)
	end
	local target = self.population:target(playerCount, hour, now)
	if target == 0 and playerCount == 0 then
		-- Nobody is here to watch and the grace is over: every session ends within a few minutes.
		for _, id in self.order do
			local record = self.records[id]
			if record and not record.npc:isLeaving() then
				local session = record.npc.brain.session
				if session.leaveAt - now > SHORTEN_HI then
					session.leaveAt = now
						+ self.rng:logNormalClamped(SHORTEN_MEDIAN, SHORTEN_SPREAD, SHORTEN_LO, SHORTEN_HI)
				end
			end
		end
	elseif decision.shorten then
		-- The one due to leave soonest goes first.
		local soonest: Record? = nil
		for _, id in self.order do
			local record = self.records[id]
			if record and not record.npc:isLeaving() then
				if
					soonest == nil
					or record.npc.brain.session.leaveAt < (soonest :: Record).npc.brain.session.leaveAt
				then
					soonest = record
				end
			end
		end
		if soonest then
			local session = (soonest :: Record).npc.brain.session
			local before = session.leaveAt
			session.leaveAt = math.min(
				before,
				now + self.rng:logNormalClamped(SHORTEN_MEDIAN, SHORTEN_SPREAD, SHORTEN_LO, SHORTEN_HI)
			)
		end
	end
	local wanted = decision.spawn
	if wanted > 0 then
		-- Under pressure the target shrinks (fewer joins, nobody kicked).
		local scaled = math.round(target * (1 - 0.5 * self.pressure))
		wanted = math.max(0, math.min(wanted, scaled - npcCount))
	end
	if wanted > 0 then
		frame.wantSpawn = wanted
		frame.pairWith = decision.pairWith
		frame.rejoinSeed = decision.rejoinSeed
		self.pendingPairWith = decision.pairWith
		self.pendingRejoinSeed = decision.rejoinSeed
		local requestSpawn = self.world.requestSpawn
		if requestSpawn then
			requestSpawn(wanted, decision.pairWith)
		else
			for _ = 1, wanted do
				self:spawn(now)
			end
		end
	end
end

-- 2. Everyone's position, once per frame, into the spatial index. A body that cannot be read is
-- left out: its own tick raises the error where the budget sees it.
local function stepSpatial(self: Service, now: number)
	local views: { Entity } = {}
	for _, id in self.order do
		local record = self.records[id]
		if not record or record.npc.dead then
			continue
		end
		local ok, body = pcall(record.mover.read, record.mover)
		if not ok then
			continue
		end
		table.insert(views, {
			id = entityId(id),
			kind = "npc" :: "npc",
			position = body.position,
			velocity = body.velocity,
			yaw = body.yaw,
			displayName = record.identity.displayName,
			jumpedAt = record.jumpedAt,
			emoteAt = record.emoteAt,
			emoteName = record.emoteName,
		})
	end
	self.playersNow = self.world.players()
	for _, p in self.playersNow do
		table.insert(views, p)
	end
	self.spatial:update(views, now)
end

-- The exit point out of a no-go volume: the nearest walkable cell (every cell inside is blocked).
local function exitPoint(self: Service, box: Box, position: Vector3): Vector3
	local grid = self.world.grid
	if grid then
		for _, radius in { 8, 16, 32, 64 } do
			local ix, iz = grid:nearestWalkable(position, radius)
			if ix then
				local centre = grid:centerOf(ix :: number, iz :: number)
				if not insideBox(box, Vector3.new(centre.X, position.Y, centre.Z)) then
					return centre
				end
			end
		end
	end
	local centre = box.cframe.Position
	local dir = NavMath.flatDirection(centre, position)
	if dir.Magnitude < 1e-6 then
		dir = box.cframe.LookVector
	end
	local half = math.max(box.size.X, box.size.Z) / 2
	return Vector3.new(centre.X, position.Y, centre.Z) + NavMath.flat(dir).Unit * (half + 2)
end

-- 3. The LOD pass every half second: distance to the nearest player, an occlusion verdict for the
-- nearest player under the raycast budget (round-robin, previous verdicts kept), Lod, tiers; then
-- the near-tier avoid-box test.
local function stepLod(self: Service, now: number)
	if now - self.lastTierAssignAt < TIER_INTERVAL then
		return
	end
	self.lastTierAssignAt = now
	local players = self.playersNow
	local order = self.order
	local n = #order
	if n == 0 then
		return
	end
	local inputs: { Lod.Input } = {}
	local nearest: { [string]: Entity? } = {}
	local positions: { [string]: Vector3? } = {}
	for _, id in order do
		local record = self.records[id]
		if not record then
			continue
		end
		local me = self.spatial:get(entityId(id))
		if not me then
			continue -- dead, or unreadable this frame
		end
		local position = me.position
		positions[id] = position
		local best, bestPlayer = math.huge, nil :: Entity?
		for _, p in players do
			local d = NavMath.flatDistance(p.position, position)
			if d < best then
				best, bestPlayer = d, p
			end
		end
		if #players == 0 then
			best = 0 -- no players: everyone is near, so behaviour stays observable
		end
		nearest[id] = bestPlayer
		table.insert(inputs, { id = id, distance = best, visible = self.losVisible[id] == true })
	end
	-- Raycasts round-robin from the cursor; NPCs whose turn does not come keep their verdict.
	local playerLos = self.world.playerLos
	if playerLos and #players > 0 then
		local budget = self.losPerPass
		local start = self.losCursor
		local visited = 0
		local k = 0
		while k < #inputs and budget > 0 do
			local slot = ((start - 1 + k) % #inputs) + 1
			local input = inputs[slot]
			local player = nearest[input.id]
			if player and input.distance <= self.visibleRange then
				local visible = playerLos(positions[input.id] :: Vector3, player.position) == true
				self.losVisible[input.id] = visible
				input.visible = visible
				budget -= 1
			else
				self.losVisible[input.id] = false
				input.visible = false
			end
			k += 1
			visited = k
		end
		self.losCursor = ((start - 1 + visited) % #inputs) + 1
	elseif #players == 0 then
		for _, input in inputs do
			self.losVisible[input.id] = false
			input.visible = false
		end
	end
	self.lod:setPressure(self.pressure)
	local distances = self.lod:effectiveDistances(inputs, now)
	for _, change in self.scheduler:assignTiers(distances) do
		local record = self.records[change.id]
		if record then
			record.npc:setTier(change.to)
		end
	end
	-- Avoid exit: a near NPC standing inside a no-go volume walks out.
	local boxes: { Box }? = nil
	for _, id in order do
		local record = self.records[id]
		local position = positions[id]
		if not record or position == nil or record.npc.dead or record.npc.tier ~= "near" then
			continue
		end
		if now - record.avoidExitAt < AVOID_EXIT_GAP then
			continue
		end
		if boxes == nil then
			boxes = NpcService.avoidBoxes(self)
		end
		for _, box in boxes :: { Box } do
			if insideBox(box, position) or insideBox(box, position + Vector3.new(0, 1, 0)) then
				record.avoidExitAt = now
				self.counters.avoidExits += 1
				record.npc:onSystemEvent("avoidExit", now, exitPoint(self, box, position))
				break
			end
		end
	end
end

-- 4. Paths: the grid slice grows while the engine is backed off, completions reach their NPCs.
local function stepPaths(self: Service, now: number, spent: (() -> number)?)
	local provider = self.gridProvider
	if provider and provider.budgetMs ~= nil then
		local backedOff = now < self.planner.backoffUntil
		local budget = self.pathBudgetMs
		if backedOff then
			budget = math.min(self.pathBudgetMaxMs, self.pathBudgetMs + 0.5 * provider:inFlight())
		end
		provider.budgetMs = budget
	end
	for _, completion in self.planner:step(now, spent) do
		local record = self.records[completion.agentId]
		if record then
			record.npc:onPathResult(completion, now)
		end
	end
end

-- 5. Chat memory and the queued Blocked notifications.
local function stepChatAndBlocked(self: Service, now: number)
	while #self.recentChats > 0 and now - self.recentChats[1].at > CHAT_MEMORY do
		table.remove(self.recentChats, 1)
	end
	local queue = self.blockedQueue
	if #queue > 0 then
		self.blockedQueue = {}
		for _, entry in queue do
			local record = self.records[entry.id]
			if record then
				record.npc:onBlocked(entry.index, now)
			end
		end
	end
end

-- A caught tick error: the body stops, the report says "error", the budget may end the session.
local function onTickError(self: Service, record: Record, id: string, now: number, message: string): Npc.Report?
	self.counters.errors += 1
	pcall(function()
		record.mover:apply(Npc.STOP)
	end)
	telemetry(self, "error", id, now, { message = message })
	if self.errorBudget:record(id, now, message) then
		self:despawn(id, "errors", now)
		return nil
	end
	local npc = record.npc
	local ok, report = pcall(npc.report, npc, Npc.STOP, "-", { "error" }, false)
	if ok then
		return report
	end
	local body = record.npc.lastBody
	return {
		command = Npc.STOP,
		position = if body then body.position else Vector3.zero,
		remaining = 0,
		humanizerBusy = false,
		intent = "-",
		activity = nil,
		target = nil,
		mood = "neutral",
		phase = "settled",
		locomotion = "failed",
		recoveryLevel = 0,
		events = { "error" },
		tier = record.npc.tier,
		typing = false,
		sitting = nil,
		resetsUsed = record.npc.resetsUsed,
		brainRan = false,
	}
end

-- 6. The due NPC ticks under the tick budget, each in a pcall.
local function stepTicks(self: Service, now: number, frame: FrameStats, used: () -> number)
	local reports: { [string]: Npc.Report } = {}
	local due = self.scheduler:due(now)
	for i, id in due do
		if used() > self.tickBudgetMs then
			frame.dropped += #due - i + 1
			break
		end
		local record = self.records[id]
		if not record then
			continue
		end
		local runBrain = self.scheduler:markTicked(id, now)
		-- Through the instance, so a test or a bench that shadows `tick` on one NPC is honoured.
		local npc = record.npc
		local ok, result = pcall(npc.tick, npc, now, runBrain)
		local report: Npc.Report? = nil
		if ok then
			report = result
		else
			report = onTickError(self, record, id, now, tostring(result))
		end
		if report == nil then
			continue -- despawned by the error budget
		end
		local r = report :: Npc.Report
		reports[id] = r
		record.lastReport = r
		Report.fold(frame, r)
		if r.command.jump and not record.lastCommandJump then
			record.jumpedAt = now
		end
		record.lastCommandJump = r.command.jump
		record.typing = r.typing == true
		local trace = self.trace
		for _, event in r.events do
			if trace then
				table.insert(record.sampleEvents, event)
			end
			if event == "reset" then
				if trace then
					trace:mark({ kind = "reset", at = now, subject = entityId(id) })
				end
				telemetry(self, "reset", id, now, nil)
			end
		end
		-- H15 escalation: the third reaction to the same person's probing (following, staring, standing
		-- on the NPC, asking if it is a bot) blocks them: no more following, watching or messaging.
		local probeTarget: string? = if r.activity == "ReactProbe" then r.target else nil
		if probeTarget and probeTarget ~= record.probeTarget and string.sub(probeTarget, 1, 2) == "p:" then
			local episodes = (record.probeEpisodes[probeTarget] or 0) + 1
			record.probeEpisodes[probeTarget] = episodes
			if episodes >= PROBE_EPISODES_TO_BLOCK and not record.npc.brain.guard:isBlocked(probeTarget) then
				record.npc.brain.guard:block(probeTarget, now)
			end
		end
		record.probeTarget = probeTarget
		if record.npc:isLeaving() then
			self:despawn(id, "session", now)
		end
	end
	self.lastReports = reports
end

-- 7. Mimic and trace samples at 10 Hz: players' kinematics into MotionStats and the TraceBank, every
-- agent into the trace when one is kept.
local function stepSampling(self: Service, now: number)
	local hz = if self.trace then self.traceHz else MIMIC_HZ
	if now - self.lastSampleAt < 1 / hz - 1e-6 then
		return
	end
	local since = self.lastSampleAt
	self.lastSampleAt = now
	local trace = self.trace
	local stats = self.motionStats
	local bank = self.traceBank
	local present: { [string]: boolean } = {}
	for _, p in self.playersNow do
		present[p.id] = true
		local jumped = p.jumpedAt ~= nil and (p.jumpedAt :: number) > since
		if stats and bank then
			local track = self.playerTracks[p.id]
			if not track then
				track = { samples = {}, key = Rng.hash(p.id), jumpedAt = nil }
				self.playerTracks[p.id] = track
			end
			table.insert(track.samples, {
				position = p.position,
				velocity = p.velocity,
				yaw = p.yaw,
				at = now,
				jumped = jumped,
			})
			if #track.samples >= MIMIC_WINDOW then
				stats:observeAll(MotionStats.featuresFrom(track.samples, 16), self.mimicRng)
				track.samples = {}
			end
			local flat = NavMath.flat(p.velocity)
			bank:observe({
				dir = if flat.Magnitude > 1e-6 then flat.Unit else Vector3.zero,
				magnitude = math.clamp(flat.Magnitude / 16, 0, 1),
				jump = jumped,
				at = now,
			}, track.key, self.mimicRng)
		end
		if trace then
			local saidAt = self.playerSaidAt[p.id]
			trace:push({
				id = p.id,
				kind = "player",
				at = now,
				position = p.position,
				velocity = p.velocity,
				yaw = p.yaw,
				onGround = true,
				jumped = jumped,
				said = saidAt ~= nil and (saidAt :: number) > since,
				typing = (p :: any).isTyping == true,
				emote = p.emoteName ~= nil,
				intent = nil,
				tier = nil,
				profile = nil,
			})
		end
	end
	if bank then
		bank:prune(now)
	end
	if not trace then
		return
	end
	for _, id in self.order do
		local record = self.records[id]
		if not record or record.npc.dead then
			continue
		end
		local readable, body = pcall(record.mover.read, record.mover)
		if not readable then
			continue
		end
		local report = record.lastReport
		local said = record.saidAt > since
		local events: { string }? = nil
		if #record.sampleEvents > 0 then
			events = table.clone(record.sampleEvents)
			table.clear(record.sampleEvents)
		end
		trace:push({
			id = entityId(id),
			kind = "npc",
			at = now,
			position = body.position,
			velocity = body.velocity,
			yaw = body.yaw,
			onGround = body.onGround,
			jumped = record.jumpedAt ~= nil and (record.jumpedAt :: number) > since,
			said = said,
			typing = record.typing,
			emote = record.emoteName ~= nil,
			intent = if report then report.intent else nil,
			tier = record.npc.tier,
			profile = record.persona.profile.kind,
			pushing = if report then report.recoveryLevel > 0 else nil,
			afkFull = record.npc.brain:isAttentionOff(),
			replyTo = if said then record.lastSaidTarget else nil,
			walkSpeed = body.walkSpeed,
			jumpTier = record.persona.jumpTier,
			text = if said then record.lastSaidText else nil,
			events = events,
		})
	end
end

-- 8. Pressure, the over-budget event, the shutdown grace.
local function stepPressure(self: Service, now: number, frame: FrameStats, overTickBudget: boolean, used: () -> number)
	if overTickBudget then
		self.pressure = math.min(1, self.pressure + PRESSURE_UP)
	else
		self.pressure = math.max(0, self.pressure - PRESSURE_DOWN)
	end
	frame.pressure = self.pressure
	frame.spent = used()
	frame.npcCount = #self.order
	if frame.spent > self.frameBudgetMs and now - self.overBudgetReportedAt >= OVER_BUDGET_GAP then
		self.overBudgetReportedAt = now
		telemetry(self, "frameOverBudget", "", now, { spent = frame.spent, ticks = frame.ticks })
	end
	local shutdownAt = self.shutdownAt
	if shutdownAt and now - shutdownAt >= SHUTDOWN_GRACE then
		for _, id in table.clone(self.order) do
			self:despawn(id, "shutdown", now)
		end
	end
end

-- The budgeted server frame (§4.1), in its fixed order. Returns the frame's stats.
function NpcService.stepFrame(self: Service, now: number, dt: number): FrameStats
	local frame = Report.emptyFrame()
	self.frame = frame
	self.lastNow = now
	local spent = self.world.spent
	local function used(): number
		return if spent then spent() else 0
	end
	stepPopulation(self, now, frame)
	stepSpatial(self, now)
	stepLod(self, now)
	local pathStart = used()
	stepPaths(self, now, spent)
	frame.pathMs = used() - pathStart
	stepChatAndBlocked(self, now)
	local tickStart = used()
	stepTicks(self, now, frame, used)
	frame.tickMs = used() - tickStart
	local overTickBudget = used() > self.tickBudgetMs
	stepSampling(self, now)
	stepPressure(self, now, frame, overTickBudget, used)
	return frame
end

-- The landed frame: runs stepFrame and returns the ids ticked with their reports.
function NpcService.step(self: Service, now: number): { [string]: Npc.Report }
	local dt = if self.lastNow then math.max(0, now - self.lastNow :: number) else 0
	self:stepFrame(now, dt)
	return self.lastReports
end

function NpcService.count(self: Service): number
	return #self.order
end

function NpcService.list(self: Service): { string }
	return table.clone(self.order)
end

function NpcService.get(self: Service, id: string): Npc.NpcT?
	local record = self.records[id]
	return if record then record.npc else nil
end

function NpcService.identity(self: Service, id: string): Npc.Identity?
	local record = self.records[id]
	return if record then record.identity else nil
end

function NpcService.chatLog(self: Service, limit: number?): { Safety.Entry }
	return self.safety:log(limit)
end

function NpcService.setChatEnabled(self: Service, enabled: boolean)
	self.safety:setEnabled(enabled)
end

return NpcService

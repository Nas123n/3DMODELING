--!strict
-- Owns every NPC on the server: spawns and despawns them, ticks them through the scheduler,
-- keeps the shared spatial index, routes path completions, hears player chat, rate-limits NPC
-- chat, and hands each NPC a perception of the world. The world itself (bodies, players, the
-- presenter, the navigation grid, the points of interest) comes in through an adapter, so the
-- same service runs under Lune with fake bodies and in Studio with humanoids.

local Rng = require(script.Parent.Parent.Rng)
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
local Recency = require(script.Parent.Parent.Chat.Recency)
local Safety = require(script.Parent.Parent.Chat.Safety)
local Scheduler = require(script.Parent.Scheduler)
local Npc = require(script.Parent.Npc)

type Rng = Rng.Rng
type Grid = NavGrid.Grid
type Entity = Spatial.Entity

local NpcService = {}
NpcService.__index = NpcService

-- What the game provides.
export type WorldAdapter = {
	-- Builds a body for a new NPC at a position; returns the mover the runtime drives.
	createMover: (id: string, identity: Npc.Identity, persona: any, position: Vector3) -> Npc.Mover,
	destroyMover: (id: string) -> (),
	-- Live views of the real players (position, velocity, yaw, displayName, jumpedAt, emoteAt).
	players: () -> { Entity },
	presenter: Npc.Presenter,
	grid: Grid?, -- the sampled nav grid (fallback / tests)
	primaryProvider: PathPlanner.Provider?, -- the engine's pathfinder, when available
	pois: PoiRegistry.Registry,
	losCheck: ((from: Vector3, to: Vector3) -> boolean)?,
	occlusion: ((from: Vector3, to: Vector3) -> boolean)?,
	props: { { id: string, position: Vector3, top: number, footprint: number } }?,
	-- Optional: reject a generated username (for example one that resolves to a real account).
	nameTaken: ((username: string) -> boolean)?,
}

export type Config = {
	seed: (number | string)?,
	chatServerRate: number?, -- lines per second, server-wide; default 0.5
	chatPerNpcPerMinute: number?, -- default 3
	chatEnabled: boolean?,
	walkSpeedMedian: number?,
	walkSpeedSpread: number?,
	walkSpeedMax: number?,
	sessionMedianMinutes: number?,
	sessionMaxMinutes: number?,
	sectorSize: number?, -- default 16
	extraSafetyPatterns: { string }?,
	scheduler: Scheduler.Params?,
}

type Record = {
	npc: Npc.NpcT,
	mover: Npc.Mover,
	identity: Npc.Identity,
	persona: any,
	spawnedAt: number,
	jumpedAt: number?,
	emoteAt: number?,
	emoteName: string?,
	lastCommandJump: boolean,
	chatTimes: { number },
}

type ChatEntry = { fromId: string, text: string, position: Vector3, at: number }

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
		names: Names.Pool,
		recentChats: { ChatEntry },
		serverChatTimes: { number },
		nextNpcIndex: number,
		lastTierAssignAt: number,
		sectorSize: number,
		sectors: { string },
		sectorCenters: { [string]: Vector3 },
		reservedNames: { [string]: number },
		stats: { spawned: number, despawned: number, linesSaid: number, linesDropped: number },
		perceptionWorld: any,
	},
	NpcService
))

local function entityId(npcId: string): string
	return "n:" .. npcId
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

function NpcService.new(config: Config, world: WorldAdapter): Service
	local rng = Rng.new(config.seed or "humanlike-npc")
	local grid = world.grid
	local gridProvider = if grid then GridPathProvider.new(grid) else nil
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
	local planner = PathPlanner.new(world.primaryProvider, fallback, resolver, { losCheck = world.losCheck })
	local sectorSize = config.sectorSize or 16
	local sectors, centers = sectorsOf(grid, sectorSize)
	local self = setmetatable({
		rng = rng,
		config = config,
		world = world,
		records = {},
		order = {},
		scheduler = Scheduler.new(config.scheduler),
		spatial = Spatial.new(),
		planner = planner,
		gridProvider = gridProvider,
		recency = Recency.new(),
		safety = Safety.new(config.extraSafetyPatterns),
		names = Names.newPool(rng:fork("names")),
		recentChats = {},
		serverChatTimes = {},
		nextNpcIndex = 1,
		lastTierAssignAt = -math.huge,
		sectorSize = sectorSize,
		sectors = sectors,
		sectorCenters = centers,
		reservedNames = {},
		stats = { spawned = 0, despawned = 0, linesSaid = 0, linesDropped = 0 },
		perceptionWorld = nil,
	}, NpcService)
	if config.chatEnabled == false then
		self.safety:setEnabled(false)
	end
	self.perceptionWorld = NpcService.buildWorldView(self)
	return self
end

-- The static part of what NPCs perceive (POIs, navigation queries); entities are added per NPC.
function NpcService.buildWorldView(self: Service): any
	local grid = self.world.grid
	local pois = self.world.pois
	local spatial = self.spatial
	local rng = self.rng:fork("world")
	local centers = self.sectorCenters
	local sectors = self.sectors
	local function poiList()
		local out = {}
		for _, poi in pois:all() do
			table.insert(out, poi)
		end
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
	}
	return view
end

-- Chat rate limits: server-wide lines per second and per-NPC lines per minute.
local function chatAllowed(self: Service, npcId: string, now: number): boolean
	local rate = self.config.chatServerRate or 0.5
	local perMinute = self.config.chatPerNpcPerMinute or 3
	local times = self.serverChatTimes
	while #times > 0 and now - times[1] > 10 do
		table.remove(times, 1)
	end
	if #times >= rate * 10 then
		self.stats.linesDropped += 1
		return false
	end
	local record = self.records[npcId]
	if record then
		local mine = record.chatTimes
		while #mine > 0 and now - mine[1] > 60 do
			table.remove(mine, 1)
		end
		if #mine >= perMinute then
			self.stats.linesDropped += 1
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
	function perception.snapshot(_, _, position, radius)
		local entities = spatial:near(position, radius, myEntityId)
		local chats = {}
		for _, c in self.recentChats do
			if c.fromId ~= myEntityId and NavMath.flatDistance(c.position, position) <= radius then
				table.insert(chats, c)
			end
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

-- A new NPC. Returns its id.
function NpcService.spawn(self: Service, now: number, at: Vector3?, seed: (number | string)?): string
	local index = self.nextNpcIndex
	self.nextNpcIndex += 1
	local id = `npc{index}`
	local npcSeed = Rng.new(seed or Rng.hash(`{self.config.seed or "humanlike-npc"}:{index}`))
	local persona = Personality.sample(npcSeed, {
		walkSpeedMedian = self.config.walkSpeedMedian,
		walkSpeedSpread = self.config.walkSpeedSpread,
		walkSpeedMax = self.config.walkSpeedMax,
		sessionMedianMinutes = self.config.sessionMedianMinutes,
		sessionMaxMinutes = self.config.sessionMaxMinutes,
	})
	local name
	for _ = 1, 20 do
		name = self.names:take()
		if not self.world.nameTaken or not self.world.nameTaken(name.username) then
			break
		end
	end
	local identity: Npc.Identity = { id = id, username = name.username, displayName = name.displayName }
	local position: Vector3 = at or Vector3.zero
	if not at then
		local u1, u2 = self.rng:next(), self.rng:next()
		local spawnIndex = self.rng:int(1, math.max(1, #self.world.pois.spawns))
		position = self.world.pois:spawnPoint(u1, u2, spawnIndex) or Vector3.zero
		local grid = self.world.grid
		if grid then
			local ix, iz = grid:nearestWalkable(position, 8)
			if ix then
				position = grid:centerOf(ix :: number, iz :: number)
			end
		end
	end
	local mover = self.world.createMover(id, identity, persona, position)
	-- Favourite kind of place: weighted by the POIs present and curiosity.
	local favorite: string? = nil
	local kinds, weights = {}, {}
	local kindWeight: { [string]: number } = {}
	for _, poi in self.world.pois:all() do
		kindWeight[poi.kind] = (kindWeight[poi.kind] or 0) + poi.weight
	end
	for kind, w in kindWeight do
		table.insert(kinds, kind)
		table.insert(weights, w * (1 + persona.curiosity))
	end
	if #kinds > 0 then
		favorite = kinds[npcSeed:fork("favorite"):weightedIndex(weights)]
	end
	local npc = Npc.new(identity, persona, npcSeed, {
		mover = mover,
		presenter = self.world.presenter,
		perception = makePerception(self, id),
		planner = self.planner,
		chat = {
			recency = self.recency,
			safety = self.safety,
			allow = function(npcId, at)
				return chatAllowed(self, npcId, at)
			end,
		},
	}, now, favorite)
	self.records[id] = {
		npc = npc,
		mover = mover,
		identity = identity,
		persona = persona,
		spawnedAt = now,
		jumpedAt = nil,
		emoteAt = nil,
		emoteName = nil,
		lastCommandJump = false,
		chatTimes = {},
	}
	table.insert(self.order, id)
	self.scheduler:add(id, Rng.hash(id) / 4294967296, now)
	self.stats.spawned += 1
	return id
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
	self.scheduler:remove(id)
	self.planner:cancel(id)
	self.recency:forget(id)
	self.world.destroyMover(id)
	self.reservedNames[record.identity.username] = now + 7200
	self.stats.despawned += 1
end

-- A real player said something (server-side hook): NPCs within earshot may hear it.
function NpcService.onPlayerChat(self: Service, playerId: string, text: string, position: Vector3, now: number)
	table.insert(self.recentChats, { fromId = "p:" .. playerId, text = text, position = position, at = now })
end

-- An NPC said something: other NPCs hear it too (parity), and the presenter shows it.
local function onNpcSaid(self: Service, id: string, text: string, position: Vector3, now: number)
	table.insert(self.recentChats, { fromId = entityId(id), text = text, position = position, at = now })
	self.stats.linesSaid += 1
end

local function entityViews(self: Service, now: number): { Entity }
	local views: { Entity } = {}
	for _, id in self.order do
		local record = self.records[id]
		if not record then
			continue
		end
		local body = record.mover:read()
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
	for _, p in self.world.players() do
		table.insert(views, p)
	end
	-- Release names reserved long enough ago.
	for name, until_ in self.reservedNames do
		if now >= until_ then
			self.reservedNames[name] = nil
			self.names:release(name)
		end
	end
	return views
end

-- One server frame. Returns the ids ticked and their reports.
function NpcService.step(self: Service, now: number): { [string]: Npc.Report }
	-- Spatial index and tiers.
	self.spatial:update(entityViews(self, now), now)
	if now - self.lastTierAssignAt >= 0.5 then
		self.lastTierAssignAt = now
		local players = self.world.players()
		local distances = {}
		for _, id in self.order do
			local record = self.records[id]
			if record then
				local body = record.mover:read()
				local best = math.huge
				for _, p in players do
					best = math.min(best, NavMath.flatDistance(p.position, body.position))
				end
				if #players == 0 then
					best = 0 -- no players: treat everyone as near so behaviour stays observable in tests
				end
				distances[id] = best
			end
		end
		for _, change in self.scheduler:assignTiers(distances) do
			local record = self.records[change.id]
			if record then
				record.npc:setTier(change.to)
			end
		end
	end
	-- Old chat falls out of earshot memory.
	while #self.recentChats > 0 and now - self.recentChats[1].at > 3 do
		table.remove(self.recentChats, 1)
	end

	-- Paths.
	for _, completion in self.planner:step(now) do
		local record = self.records[completion.agentId]
		if record then
			record.npc:onPathResult(completion, now)
		end
	end

	-- NPC ticks.
	local reports: { [string]: Npc.Report } = {}
	for _, id in self.scheduler:due(now) do
		local record = self.records[id]
		if not record then
			continue
		end
		local runBrain = self.scheduler:markTicked(id, now)
		local report = record.npc:tick(now, runBrain)
		reports[id] = report
		if report.command.jump and not record.lastCommandJump then
			record.jumpedAt = now
		end
		record.lastCommandJump = report.command.jump
		if record.npc:isLeaving() then
			self:despawn(id, "session", now)
		end
	end
	return reports
end

-- The presenter calls this so NPC chat reaches other NPCs' ears and the counters.
function NpcService.notifySaid(self: Service, id: string, text: string, now: number)
	local record = self.records[id]
	if record then
		onNpcSaid(self, id, text, record.mover:read().position, now)
	end
end

function NpcService.notifyEmote(self: Service, id: string, name: string?, now: number)
	local record = self.records[id]
	if record then
		record.emoteAt = if name then now else nil
		record.emoteName = name
	end
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

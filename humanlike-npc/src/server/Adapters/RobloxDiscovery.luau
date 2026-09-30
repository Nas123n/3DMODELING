--!strict
-- Reads the developer's world once at start and keeps it fresh: the POI registry, seats, props, NpcSlow costs,
-- NpcNoSpawn volumes and avoid parts through World/Scan; the world bounds (the union of every tagged
-- instance's box and every SpawnLocation, inflated by 40 studs and clamped to Config.GridMaxSideStuds, or the
-- one NpcNavBounds part; never "every part under workspace"); the fallback NavGrid over those bounds with the
-- cell size raised until the cell count fits Config.GridMaxCells, sampled in slices of 2000 cells per frame
-- so a big map never hitches; a PathfindingModifier under every NpcAvoid ("NoGo", PassThrough false) and
-- NpcSlow ("Slow") part, labels that name nothing; and CollectionService tag listeners that rescan within a
-- second of a tag change and tell the service. `refresh` rescans without resampling; `resample` resamples
-- the grid in slices at most once per 30 s. When the tagged world is larger than the clamp the grid is off
-- (one warning) and the planner ladder is engine -> direct -> NoPath. It never chooses goals, never moves
-- anything and never edits CanCollide.
-- requires: Connections, NavGrid, PoiRegistry, Scan

local CollectionService = game:GetService("CollectionService")

local Connections = require(script.Parent.Connections)
local NavGrid = require(script.Parent.Parent.Nav.NavGrid)
local PoiRegistry = require(script.Parent.Parent.World.PoiRegistry)
local Scan = require(script.Parent.Parent.World.Scan)

type Bag = Connections.Bag
type Grid = NavGrid.Grid
type Registry = PoiRegistry.Registry

local RobloxDiscovery = {}

-- The Config keys discovery reads (a structural subset of Config.Resolved, so nothing here requires Config).
export type ConfigLike = {
	GridCellSize: number,
	GridMaxCells: number,
	GridMaxSideStuds: number,
	AutoProps: boolean,
	AgentRadius: number,
	AgentHeight: number,
}

export type Box = { cframe: CFrame, size: Vector3 }
export type Bounds = { min: Vector3, max: Vector3 }

export type Options = {
	bag: Bag, -- the root bag: tag listeners and sampling threads live in a child of it
	clock: (() -> number)?, -- default os.clock
	onRefresh: ((now: number) -> ())?, -- Api -> service:onDiscoveryRefresh
	excludes: (() -> { Instance })?, -- characters (players' and NPCs') ignored while sampling
	sync: boolean?, -- sample without yielding (tests); default false
	sliceCells: number?, -- cells sampled per frame; default 2000
	refreshDelay: number?, -- seconds between a tag change and the rescan; default 1
	resampleFloor: number?, -- minimum seconds between two resamples; default 30
}

export type Stats = {
	gridDisabled: boolean,
	cells: number,
	walkable: number,
	cellSize: number,
	sampledAt: number?,
	sampling: boolean,
	samples: number,
	refreshes: number,
	modifiers: number,
	listeners: boolean,
}

export type Discovered = {
	registry: Registry,
	props: { Scan.Prop },
	seats: { Scan.SeatRecord },
	slowParts: { Scan.SlowPart },
	noSpawnParts: { BasePart },
	avoidParts: { BasePart },
	spawnLocations: { BasePart },
	bounds: Bounds?,
	grid: Grid?,
	gridDisabled: boolean,
	refresh: () -> (),
	resample: (force: boolean?) -> boolean,
	destroy: () -> (),
	isAvoided: (point: Vector3) -> boolean,
	isNoSpawn: (point: Vector3) -> boolean,
	floorAt: (point: Vector3) -> number?,
	spawnPoint: (u1: number, u2: number, index: number?) -> Vector3?,
	respawnPoint: (u1: number, u2: number, u3: number) -> Vector3?,
	avoidBoxes: () -> { Box },
	seatOf: (seatId: string) -> Instance?,
	stats: () -> Stats,
}

RobloxDiscovery.NAV_BOUNDS_TAG = "NpcNavBounds"
RobloxDiscovery.NO_GO_LABEL = "NoGo"
RobloxDiscovery.SLOW_LABEL = "Slow"
RobloxDiscovery.INFLATE = 40
RobloxDiscovery.FLOOR_MARGIN = 4
RobloxDiscovery.SLICE_CELLS = 2000
RobloxDiscovery.RESAMPLE_FLOOR = 30
RobloxDiscovery.REFRESH_DELAY = 1
RobloxDiscovery.SPAWN_INSET = 2

-- Tags whose instances define the bounds.
RobloxDiscovery.BOUNDS_TAGS = {
	PoiRegistry.POI_TAG,
	PoiRegistry.SPAWN_TAG,
	PoiRegistry.AVOID_TAG,
	Scan.PROP_TAG,
	Scan.SLOW_TAG,
}

-- Tags whose changes trigger a rescan.
RobloxDiscovery.WATCHED_TAGS = {
	PoiRegistry.POI_TAG,
	PoiRegistry.SPAWN_TAG,
	PoiRegistry.AVOID_TAG,
	Scan.PROP_TAG,
	Scan.SLOW_TAG,
	Scan.SEAT_TAG,
	Scan.NO_SPAWN_TAG,
	Scan.IGNORE_TAG,
	RobloxDiscovery.NAV_BOUNDS_TAG,
}

-- Pure geometry ------------------------------------------------------------------------------------

-- World-axis extents of an oriented box.
function RobloxDiscovery.aabb(box: Box): (Vector3, Vector3)
	local cf = box.cframe
	local half = box.size / 2
	local right = cf.RightVector * half.X
	local up = cf.UpVector * half.Y
	local look = cf.LookVector * half.Z
	local extent = Vector3.new(
		math.abs(right.X) + math.abs(up.X) + math.abs(look.X),
		math.abs(right.Y) + math.abs(up.Y) + math.abs(look.Y),
		math.abs(right.Z) + math.abs(up.Z) + math.abs(look.Z)
	)
	return cf.Position - extent, cf.Position + extent
end

function RobloxDiscovery.insideBox(box: Box, point: Vector3, tolerance: number?): boolean
	local local_ = box.cframe:PointToObjectSpace(point)
	local half = box.size / 2
	local t = tolerance or 0
	return math.abs(local_.X) <= half.X + t and math.abs(local_.Y) <= half.Y + t and math.abs(local_.Z) <= half.Z + t
end

-- The bounds rule. `boxes` are the tagged instances and SpawnLocations; `override` the NpcNavBounds part.
-- Returns nil bounds with `disabled = true` when the tagged world is wider than `maxSide` on either axis.
function RobloxDiscovery.boundsOf(boxes: { Box }, override: Box?, maxSide: number, inflate: number?): (Bounds?, boolean)
	local pad = inflate or RobloxDiscovery.INFLATE
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	local function include(box: Box)
		local lo, hi = RobloxDiscovery.aabb(box)
		if minV == nil or maxV == nil then
			minV, maxV = lo, hi
		else
			minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
			maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		end
	end
	if override then
		include(override)
		pad = 0
	else
		for _, box in boxes do
			include(box)
		end
	end
	local lo, hi = minV, maxV
	if lo == nil or hi == nil then
		return nil, false
	end
	if hi.X - lo.X > maxSide or hi.Z - lo.Z > maxSide then
		return nil, true
	end
	local minX, maxX = lo.X - pad, hi.X + pad
	local minZ, maxZ = lo.Z - pad, hi.Z + pad
	if maxX - minX > maxSide then
		local cx = (minX + maxX) / 2
		minX, maxX = cx - maxSide / 2, cx + maxSide / 2
	end
	if maxZ - minZ > maxSide then
		local cz = (minZ + maxZ) / 2
		minZ, maxZ = cz - maxSide / 2, cz + maxSide / 2
	end
	return {
		min = Vector3.new(minX, lo.Y - RobloxDiscovery.FLOOR_MARGIN, minZ),
		max = Vector3.new(maxX, hi.Y + pad, maxZ),
	},
		false
end

-- The cell size, raised in half-stud steps until cols * rows fits maxCells.
function RobloxDiscovery.cellSizeFor(bounds: Bounds, base: number, maxCells: number): number
	local width = bounds.max.X - bounds.min.X
	local depth = bounds.max.Z - bounds.min.Z
	local cellSize = math.max(0.5, base)
	while math.ceil(width / cellSize) * math.ceil(depth / cellSize) > math.max(1, maxCells) do
		cellSize += 0.5
	end
	return cellSize
end

-- A uniform point on a part's top surface, inset SPAWN_INSET (the registry's own spawn formula).
function RobloxDiscovery.topSurfacePoint(box: Box, u1: number, u2: number): Vector3
	local half = box.size / 2
	local inset = RobloxDiscovery.SPAWN_INSET
	local x = (u1 * 2 - 1) * math.max(0, half.X - inset)
	local z = (u2 * 2 - 1) * math.max(0, half.Z - inset)
	return box.cframe:PointToWorldSpace(Vector3.new(x, half.Y, z))
end

-- World reading ------------------------------------------------------------------------------------

local function isIgnored(instance: Instance, root: Instance): boolean
	local current: Instance? = instance
	while current and current ~= root do
		if current:HasTag(Scan.IGNORE_TAG) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function boxOf(instance: Instance): Box?
	if instance:IsA("BasePart") then
		return { cframe = instance.CFrame, size = instance.Size }
	elseif instance:IsA("Model") then
		local ok, cf, size = pcall(function()
			return instance:GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			return { cframe = cf, size = size }
		end
	end
	return nil
end

local function hasAnyTag(instance: Instance, tags: { string }): boolean
	for _, tag in tags do
		if instance:HasTag(tag) then
			return true
		end
	end
	return false
end

-- Tagged boxes, SpawnLocations (not under NpcIgnore) and the NpcNavBounds override, in one pass.
local function readWorld(root: Instance): ({ Box }, { BasePart }, Box?)
	local boxes: { Box } = {}
	local spawnLocations: { BasePart } = {}
	local override: Box? = nil
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and instance:HasTag(RobloxDiscovery.NAV_BOUNDS_TAG) then
			override = { cframe = instance.CFrame, size = instance.Size }
		end
		if hasAnyTag(instance, RobloxDiscovery.BOUNDS_TAGS) then
			local box = boxOf(instance)
			if box then
				table.insert(boxes, box)
			end
		end
		if instance:IsA("SpawnLocation") and not isIgnored(instance, root) then
			table.insert(spawnLocations, instance)
			table.insert(boxes, { cframe = instance.CFrame, size = instance.Size })
		end
	end
	return boxes, spawnLocations, override
end

-- Parts that move (platforms): unanchored with a velocity, or driven by an AlignPosition / PrismaticConstraint.
local function isMovingPlatform(part: BasePart): boolean
	if part.Anchored then
		return part:FindFirstChildWhichIsA("AlignPosition") ~= nil
			or part:FindFirstChildWhichIsA("PrismaticConstraint") ~= nil
	end
	local ok, moving = pcall(function()
		return part.AssemblyLinearVelocity.Magnitude > 0.01
	end)
	return (ok and moving == true)
		or part:FindFirstChildWhichIsA("AlignPosition") ~= nil
		or part:FindFirstChildWhichIsA("PrismaticConstraint") ~= nil
end

local function ignoreList(root: Instance, excludes: (() -> { Instance })?): { Instance }
	local list: { Instance } = {}
	for _, instance in root:GetDescendants() do
		if instance:HasTag(Scan.IGNORE_TAG) then
			table.insert(list, instance)
		elseif instance:IsA("BasePart") and isMovingPlatform(instance) then
			table.insert(list, instance)
		end
	end
	if excludes then
		local ok, extra = pcall(excludes)
		if ok then
			for _, instance in extra do
				table.insert(list, instance)
			end
		end
	end
	return list
end

-- The run -------------------------------------------------------------------------------------------

type State = {
	root: Instance,
	config: ConfigLike,
	bag: Bag,
	clock: () -> number,
	onRefresh: ((now: number) -> ())?,
	excludes: (() -> { Instance })?,
	sync: boolean,
	sliceCells: number,
	refreshDelay: number,
	resampleFloor: number,
	registry: Registry,
	result: Discovered?,
	modifiers: { Instance },
	slowCells: { { number } },
	worldSpawn: Vector3?,
	sampling: boolean,
	lastSampleAt: number,
	sampledAt: number?,
	samples: number,
	refreshes: number,
	refreshPending: boolean,
	listeners: boolean,
	destroyed: boolean,
	walkable: number,
}

local function frame(state: State)
	if state.sync then
		return
	end
	task.wait()
end

-- Samples the whole grid band by band through sub-grids that share its columns and cell size, so
-- NavGrid.sample runs unchanged and the caller yields between bands.
local function sampleSliced(state: State, grid: Grid, bounds: Bounds)
	local cols = grid.cols
	local rowsPerSlice = math.max(1, math.floor(state.sliceCells / cols))
	local options: NavGrid.SampleOptions = {
		top = bounds.max.Y + 20,
		bottom = bounds.min.Y,
		agentRadius = state.config.AgentRadius,
		agentHeight = state.config.AgentHeight,
		stepHeight = 2,
		ignore = ignoreList(state.root, state.excludes),
		avoid = Scan.avoidParts(state.root),
	}
	local walkable = 0
	local row = 0
	while row < grid.rows do
		if state.destroyed then
			return
		end
		local count = math.min(rowsPerSlice, grid.rows - row)
		local z0 = grid.minZ + row * grid.cellSize
		local sub = NavGrid.new({
			minX = grid.minX,
			minZ = z0,
			maxX = grid.minX + (cols - 0.5) * grid.cellSize,
			maxZ = z0 + (count - 0.5) * grid.cellSize,
			cellSize = grid.cellSize,
		})
		if sub.cols ~= cols or sub.rows ~= count then
			-- Should never happen; fall back to one synchronous pass over the whole grid.
			walkable = grid:sample(workspace, options)
			break
		end
		walkable += sub:sample(workspace, options)
		for iz = 0, count - 1 do
			for ix = 0, cols - 1 do
				local from = iz * cols + ix + 1
				local to = (row + iz) * cols + ix + 1
				grid.floor[to] = sub.floor[from]
				grid.blocked[to] = sub.blocked[from]
			end
		end
		row += count
		if row < grid.rows then
			frame(state)
		end
	end
	state.walkable = walkable
end

local function cellRange(grid: Grid, box: Box): (number, number, number, number)
	local lo, hi = RobloxDiscovery.aabb(box)
	local ix0, iz0 = grid:cellOf(lo)
	local ix1, iz1 = grid:cellOf(hi)
	return math.max(0, ix0), math.max(0, iz0), math.min(grid.cols - 1, ix1), math.min(grid.rows - 1, iz1)
end

-- Whether a volume covers a cell's floor point (XZ inside, vertical range within two studs of the floor).
local function coversCell(box: Box, floorPoint: Vector3): boolean
	local local_ = box.cframe:PointToObjectSpace(floorPoint)
	local half = box.size / 2
	return math.abs(local_.X) <= half.X and math.abs(local_.Z) <= half.Z and math.abs(local_.Y) <= half.Y + 2
end

local function applySlowCosts(state: State, grid: Grid, slowParts: { Scan.SlowPart })
	for _, cell in state.slowCells do
		grid:setCost(cell[1], cell[2], nil)
	end
	state.slowCells = {}
	for _, slow in slowParts do
		local ok = pcall(function()
			local box: Box = { cframe = slow.part.CFrame, size = slow.part.Size }
			local ix0, iz0, ix1, iz1 = cellRange(grid, box)
			for iz = iz0, iz1 do
				for ix = ix0, ix1 do
					local y = grid:floorAt(ix, iz)
					if y ~= nil and coversCell(box, grid:centerOf(ix, iz)) then
						grid:setCost(ix, iz, slow.cost)
						table.insert(state.slowCells, { ix, iz })
					end
				end
			end
		end)
		if not ok then
			continue
		end
	end
end

local function blockAvoidCells(grid: Grid, avoidParts: { BasePart })
	for _, part in avoidParts do
		pcall(function()
			local box: Box = { cframe = part.CFrame, size = part.Size }
			local ix0, iz0, ix1, iz1 = cellRange(grid, box)
			for iz = iz0, iz1 do
				for ix = ix0, ix1 do
					local y = grid:floorAt(ix, iz)
					if y ~= nil and coversCell(box, grid:centerOf(ix, iz)) then
						grid:block(ix, iz)
					end
				end
			end
		end)
	end
end

-- The centre of the walkable world: the walkable cell nearest the centroid of every walkable cell.
local function worldSpawnOf(grid: Grid?, bounds: Bounds?): Vector3?
	if grid then
		local sx, sz, n = 0, 0, 0
		for iz = 0, grid.rows - 1 do
			for ix = 0, grid.cols - 1 do
				if grid:isWalkable(ix, iz) then
					sx += ix
					sz += iz
					n += 1
				end
			end
		end
		if n > 0 then
			local center = grid:centerOf(math.floor(sx / n), math.floor(sz / n))
			local ix, iz = grid:nearestWalkable(center, 64)
			if ix and iz then
				return grid:centerOf(ix, iz)
			end
		end
	end
	if bounds then
		return (bounds.min + bounds.max) / 2
	end
	return nil
end

local function ensureModifier(state: State, part: BasePart, label: string)
	for _, child in part:GetChildren() do
		if child:IsA("PathfindingModifier") and child.Label == label then
			return
		end
	end
	local ok = pcall(function()
		local modifier = Instance.new("PathfindingModifier")
		modifier.Label = label
		modifier.PassThrough = false
		modifier.Parent = part
		table.insert(state.modifiers, modifier)
	end)
	if not ok then
		return
	end
end

local function applyModifiers(state: State, avoidParts: { BasePart }, slowParts: { Scan.SlowPart })
	for _, part in avoidParts do
		ensureModifier(state, part, RobloxDiscovery.NO_GO_LABEL)
	end
	for _, slow in slowParts do
		ensureModifier(state, slow.part, RobloxDiscovery.SLOW_LABEL)
	end
end

local function addSpawnLocations(registry: Registry, spawnLocations: { BasePart })
	if #registry.spawns > 0 then
		return
	end
	for i, part in spawnLocations do
		registry:addSpawn({ id = `SpawnLocation#{i}`, cframe = part.CFrame, size = part.Size })
	end
end

-- Rescans everything but the grid into the same registry (the service holds a reference to it).
local function rescan(state: State, result: Discovered)
	local registry = state.registry
	registry.pois = {}
	registry.byId = {}
	registry.spawns = {}
	registry.avoids = {}
	registry.occupancy = {}
	Scan.into(registry, state.root)
	local _, spawnLocations = readWorld(state.root)
	addSpawnLocations(registry, spawnLocations)
	local fresh = Scan.seats(state.root, registry)
	local keep: { [string]: boolean } = {}
	for _, seat in fresh do
		keep[seat.id] = true
	end
	for _, seat in table.clone(registry:seats()) do
		if not keep[seat.id] then
			registry:removeSeat(seat.id)
		end
	end
	result.seats = fresh
	result.spawnLocations = spawnLocations
	result.props = Scan.props(state.root, state.config.AutoProps)
	result.slowParts = Scan.slowParts(state.root)
	result.noSpawnParts = Scan.noSpawnParts(state.root)
	result.avoidParts = Scan.avoidParts(state.root)
	applyModifiers(state, result.avoidParts, result.slowParts)
	local grid = result.grid
	if grid then
		applySlowCosts(state, grid, result.slowParts)
		blockAvoidCells(grid, result.avoidParts)
	end
	state.refreshes += 1
end

local function listen(state: State, schedule: () -> ())
	local ok = pcall(function()
		for _, tag in RobloxDiscovery.WATCHED_TAGS do
			state.bag:add(CollectionService:GetInstanceAddedSignal(tag):Connect(function()
				schedule()
			end))
			state.bag:add(CollectionService:GetInstanceRemovedSignal(tag):Connect(function()
				schedule()
			end))
		end
	end)
	state.listeners = ok
end

-- Runs discovery over `root` (normally workspace). Yields while the grid is sampled unless `sync`.
function RobloxDiscovery.run(root: Instance, config: ConfigLike, options: Options): Discovered
	local state: State = {
		root = root,
		config = config,
		bag = options.bag:child("discovery"),
		clock = options.clock or os.clock,
		onRefresh = options.onRefresh,
		excludes = options.excludes,
		sync = options.sync == true,
		sliceCells = options.sliceCells or RobloxDiscovery.SLICE_CELLS,
		refreshDelay = options.refreshDelay or RobloxDiscovery.REFRESH_DELAY,
		resampleFloor = options.resampleFloor or RobloxDiscovery.RESAMPLE_FLOOR,
		registry = Scan.registry(root),
		result = nil,
		modifiers = {},
		slowCells = {},
		worldSpawn = nil,
		sampling = false,
		lastSampleAt = -math.huge,
		sampledAt = nil,
		samples = 0,
		refreshes = 0,
		refreshPending = false,
		listeners = false,
		destroyed = false,
		walkable = 0,
	}
	local registry = state.registry
	local boxes, spawnLocations, override = readWorld(root)
	addSpawnLocations(registry, spawnLocations)
	local seats = Scan.seats(root, registry)
	local props = Scan.props(root, config.AutoProps)
	local slowParts = Scan.slowParts(root)
	local noSpawnParts = Scan.noSpawnParts(root)
	local avoidParts = Scan.avoidParts(root)

	local bounds, disabled = RobloxDiscovery.boundsOf(boxes, override, config.GridMaxSideStuds)
	local grid: Grid? = nil
	if disabled then
		warn(
			`[HumanlikeNpc] the tagged world is wider than GridMaxSideStuds ({config.GridMaxSideStuds}); `
				.. "the fallback grid is off"
		)
	elseif bounds then
		local cellSize = RobloxDiscovery.cellSizeFor(bounds, config.GridCellSize, config.GridMaxCells)
		grid = NavGrid.new({
			minX = bounds.min.X,
			minZ = bounds.min.Z,
			maxX = bounds.max.X,
			maxZ = bounds.max.Z,
			cellSize = cellSize,
		})
	end

	local result: Discovered
	local function isNoSpawn(point: Vector3): boolean
		for _, part in result.noSpawnParts do
			local ok, inside = pcall(function()
				return RobloxDiscovery.insideBox({ cframe = part.CFrame, size = part.Size }, point)
			end)
			if ok and inside == true then
				return true
			end
		end
		return false
	end
	local function acceptable(point: Vector3): boolean
		return not registry:isAvoided(point) and not isNoSpawn(point)
	end
	local function snapped(point: Vector3?): Vector3?
		if point == nil then
			return nil
		end
		local g = result.grid
		if g then
			local ix, iz = g:nearestWalkable(point, 8)
			if ix and iz then
				return g:centerOf(ix, iz)
			end
			return nil -- off-grid: never a spawn
		end
		return point
	end
	local function spawnPoint(u1: number, u2: number, index: number?): Vector3?
		for k = 0, 8 do
			local v1 = (u1 + 0.37 * k) % 1
			local v2 = (u2 + 0.61 * k) % 1
			local point = snapped(registry:spawnPoint(v1, v2, index))
			if point == nil then
				break
			end
			if acceptable(point) then
				return point
			end
		end
		local fallback = state.worldSpawn
		if fallback and acceptable(fallback) then
			return fallback
		end
		return nil
	end
	local function respawnPoint(u1: number, u2: number, u3: number): Vector3?
		local locations = result.spawnLocations
		if #locations > 0 then
			local index = math.clamp(math.floor(u3 * #locations) + 1, 1, #locations)
			local part = locations[index]
			for k = 0, 8 do
				local v1 = (u1 + 0.37 * k) % 1
				local v2 = (u2 + 0.61 * k) % 1
				local okPoint, point = pcall(function()
					return RobloxDiscovery.topSurfacePoint({ cframe = part.CFrame, size = part.Size }, v1, v2)
				end)
				if not okPoint then
					break
				end
				local placed = snapped(point)
				if placed and acceptable(placed) then
					return placed
				end
			end
		end
		local spawns = #registry.spawns
		if spawns > 0 then
			return spawnPoint(u1, u2, math.clamp(math.floor(u3 * spawns) + 1, 1, spawns))
		end
		return spawnPoint(u1, u2, nil)
	end

	local function doSample()
		local g = result.grid
		local b = result.bounds
		if not g or not b then
			return
		end
		state.sampling = true
		state.lastSampleAt = state.clock()
		sampleSliced(state, g, b)
		if not state.destroyed then
			applySlowCosts(state, g, result.slowParts)
			state.worldSpawn = worldSpawnOf(g, b)
			state.samples += 1
			state.sampledAt = state.clock()
		end
		state.sampling = false
	end

	local function resample(force: boolean?): boolean
		if state.destroyed or state.sampling or not result.grid then
			return false
		end
		if not force and state.clock() - state.lastSampleAt < state.resampleFloor then
			return false
		end
		if state.sync then
			doSample()
			return true
		end
		local bag = state.bag
		local thread = task.spawn(function()
			doSample()
			bag:remove(coroutine.running())
		end)
		if coroutine.status(thread) ~= "dead" then
			bag:add(thread)
		end
		return true
	end

	local function refresh()
		if state.destroyed then
			return
		end
		rescan(state, result)
	end

	local function schedule()
		if state.destroyed or state.refreshPending then
			return
		end
		state.refreshPending = true
		local bag = state.bag
		local thread = task.delay(state.refreshDelay, function()
			bag:remove(coroutine.running())
			state.refreshPending = false
			if state.destroyed then
				return
			end
			refresh()
			local onRefresh = state.onRefresh
			if onRefresh then
				pcall(onRefresh, state.clock())
			end
		end)
		bag:add(thread)
	end

	local function destroy()
		state.destroyed = true
		state.bag:disconnectAll()
		for _, modifier in state.modifiers do
			pcall(function()
				modifier:Destroy()
			end)
		end
		state.modifiers = {}
	end

	result = {
		registry = registry,
		props = props,
		seats = seats,
		slowParts = slowParts,
		noSpawnParts = noSpawnParts,
		avoidParts = avoidParts,
		spawnLocations = spawnLocations,
		bounds = bounds,
		grid = grid,
		gridDisabled = disabled,
		refresh = refresh,
		resample = resample,
		destroy = destroy,
		isAvoided = function(point: Vector3): boolean
			return registry:isAvoided(point)
		end,
		isNoSpawn = isNoSpawn,
		floorAt = function(point: Vector3): number?
			local g = result.grid
			if not g then
				return nil
			end
			return g:floorAt(g:cellOf(point))
		end,
		spawnPoint = spawnPoint,
		respawnPoint = respawnPoint,
		avoidBoxes = function(): { Box }
			local out: { Box } = {}
			for _, avoid in registry.avoids do
				table.insert(out, { cframe = avoid.cframe, size = avoid.size })
			end
			return out
		end,
		seatOf = function(seatId: string): Instance?
			for _, seat in registry:seats() do
				if seat.id == seatId then
					local source = seat.source
					return if typeof(source) == "Instance" then source else nil
				end
			end
			return nil
		end,
		stats = function(): Stats
			local g = result.grid
			return {
				gridDisabled = result.gridDisabled,
				cells = if g then g.cols * g.rows else 0,
				walkable = state.walkable,
				cellSize = if g then g.cellSize else 0,
				sampledAt = state.sampledAt,
				sampling = state.sampling,
				samples = state.samples,
				refreshes = state.refreshes,
				modifiers = #state.modifiers,
				listeners = state.listeners,
			}
		end,
	}
	state.result = result
	applyModifiers(state, avoidParts, slowParts)
	if grid then
		doSample()
	else
		state.worldSpawn = worldSpawnOf(nil, bounds)
	end
	listen(state, schedule)
	return result
end

return RobloxDiscovery

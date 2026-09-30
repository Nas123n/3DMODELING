--!strict
-- A 2.5D navigation grid with A*, for two jobs: the path provider the Lune tests run against,
-- and the in-game fallback when PathfindingService returns NoPath (the engine has no partial
-- paths, so "get as close as you can" has to come from here).
--
-- The grid stores one floor height per cell. Cells are sampled from the world by casting a ray
-- down at each cell center, checking the slope of what it hit, and casting short rays at knee
-- and head height to make sure an agent fits there. A cell is walkable (has a floor), blocked
-- (something stands in it: a wall, a pillar, a no-go volume) or void (no floor at all: a pit,
-- the edge of the world). A* moves between neighbouring cells (8 directions, no corner cutting),
-- climbs steps up to `stepHeight`, and takes jump links: a rise of up to `jumpHeight` to a
-- neighbour, or a leap of up to `maxJumpGap` studs across void cells or cells far below (never
-- through blocked ones). The result is string-pulled so walks between corners are straight
-- lines; jumps are never smoothed away.
--
-- A search can be sliced: with `PathOptions.yieldEvery` set, `findPath` yields every that many
-- expanded nodes when it is driven from a coroutine (GridPathProvider's budgeted mode), and the
-- result is byte-identical to the synchronous one. Called from the thread that loaded this module
-- (a test's top level, a Script's main thread) it never yields: that thread reports itself as
-- yieldable under both runtimes, yet nothing would ever resume it.
--
-- Everything here is plain Luau over Vector3, so it runs identically in Studio and under Lune.

local NavGrid = {}
NavGrid.__index = NavGrid

-- The thread this module was loaded from. A search running on it is never sliced.
local hostThread: thread? = coroutine.running()

export type Action = "Walk" | "Jump"

export type Waypoint = {
	position: Vector3,
	action: Action, -- "Jump" means: jump to reach the NEXT waypoint (same as PathWaypointAction)
}

export type Status = "Success" | "Partial" | "NoPath"

export type PathResult = {
	status: Status,
	waypoints: { Waypoint },
	cost: number, -- path cost in studs (jumps weighted), 0 when NoPath
	expanded: number, -- nodes expanded, for budget tuning
}

export type Options = {
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	cellSize: number?, -- default 2 studs
}

export type SampleOptions = {
	top: number?, -- ray start height; default 500
	bottom: number?, -- lowest floor accepted; default -500
	maxSlope: number?, -- degrees; default 50
	agentHeight: number?, -- default 5
	agentRadius: number?, -- default 2
	stepHeight: number?, -- obstacles lower than this are steps, not blockers; default 2
	ignore: { Instance }?, -- instances never hit (characters, markers)
	avoid: { BasePart }?, -- volumes whose interior is blocked (NpcAvoid parts, which may be CanQuery=false)
	walkableOnly: { Instance }?, -- when given, only these instances count as floor
}

export type PathOptions = {
	maxNodes: number?, -- default 20000, like the engine
	stepHeight: number?, -- default 2 (a Humanoid steps up 2 studs without jumping)
	jumpHeight: number?, -- default 7 (JumpPower 50 gives about 7.2); 0 disables jumping
	maxDrop: number?, -- default 12; larger drops are never taken
	maxJumpGap: number?, -- widest chasm (missing floor) jumped, in studs; default 6; 0 disables gap jumps
	jumpCost: number?, -- multiplier on jump link length; default 1.6 (jumping costs time)
	smooth: boolean?, -- string pulling; default true
	snapRadius: number?, -- studs to search for a walkable cell around start/goal; default 8
	-- When > 0 and the search runs inside a coroutine (not the module's host thread), yield after this
	-- many expanded nodes; the resumer passes nothing back. Default nil: synchronous. About 20 us per
	-- node under Lune, so 64 gives slices of roughly 1.3 ms.
	yieldEvery: number?,
}

export type Grid = typeof(setmetatable(
	{} :: {
		minX: number,
		minZ: number,
		cellSize: number,
		cols: number,
		rows: number,
		-- Floor height per walkable cell (nil = not walkable). Index = iz * cols + ix + 1 (ix, iz zero-based).
		floor: { [number]: number? },
		-- Cells something stands in. Not walkable, and unlike void cells never jumped across.
		blocked: { [number]: boolean },
		-- Extra traversal cost multiplier per cell (nil = 1). Lets callers make areas unattractive.
		cost: { [number]: number? },
	},
	NavGrid
))

local SQRT2 = math.sqrt(2)

function NavGrid.new(options: Options): Grid
	local cellSize = options.cellSize or 2
	assert(cellSize > 0, "cellSize must be positive")
	local cols = math.max(1, math.ceil((options.maxX - options.minX) / cellSize))
	local rows = math.max(1, math.ceil((options.maxZ - options.minZ) / cellSize))
	local floor: { [number]: number? } = table.create(cols * rows)
	return setmetatable({
		minX = options.minX,
		minZ = options.minZ,
		cellSize = cellSize,
		cols = cols,
		rows = rows,
		floor = floor,
		blocked = {},
		cost = {},
	}, NavGrid)
end

-- Cell indices (zero-based) for a world position; may fall outside the grid.
function NavGrid.cellOf(self: Grid, position: Vector3): (number, number)
	return math.floor((position.X - self.minX) / self.cellSize), math.floor((position.Z - self.minZ) / self.cellSize)
end

function NavGrid.inBounds(self: Grid, ix: number, iz: number): boolean
	return ix >= 0 and iz >= 0 and ix < self.cols and iz < self.rows
end

local function indexOf(self: Grid, ix: number, iz: number): number
	return iz * self.cols + ix + 1
end

-- World position of a cell's center at its floor height (or y = 0 for blocked cells).
function NavGrid.centerOf(self: Grid, ix: number, iz: number): Vector3
	local y = self.floor[indexOf(self, ix, iz)]
	return Vector3.new(self.minX + (ix + 0.5) * self.cellSize, y or 0, self.minZ + (iz + 0.5) * self.cellSize)
end

function NavGrid.floorAt(self: Grid, ix: number, iz: number): number?
	if not self:inBounds(ix, iz) then
		return nil
	end
	return self.floor[indexOf(self, ix, iz)]
end

function NavGrid.isWalkable(self: Grid, ix: number, iz: number): boolean
	return self:inBounds(ix, iz) and self.floor[indexOf(self, ix, iz)] ~= nil
end

-- Marks a cell walkable at height y, or void (no floor, jumpable across) when y is nil.
function NavGrid.setCell(self: Grid, ix: number, iz: number, y: number?)
	if self:inBounds(ix, iz) then
		local index = indexOf(self, ix, iz)
		self.floor[index] = y
		self.blocked[index] = nil
	end
end

-- Marks a cell as occupied by an obstacle: not walkable and never jumped across.
function NavGrid.block(self: Grid, ix: number, iz: number)
	if self:inBounds(ix, iz) then
		local index = indexOf(self, ix, iz)
		self.floor[index] = nil
		self.blocked[index] = true
	end
end

-- Fills a rectangle of cells (inclusive indices) with one height, or makes it void when y is nil.
function NavGrid.fill(self: Grid, ix0: number, iz0: number, ix1: number, iz1: number, y: number?)
	for iz = math.max(0, iz0), math.min(self.rows - 1, iz1) do
		for ix = math.max(0, ix0), math.min(self.cols - 1, ix1) do
			self:setCell(ix, iz, y)
		end
	end
end

-- Blocks a rectangle of cells (inclusive indices).
function NavGrid.fillBlocked(self: Grid, ix0: number, iz0: number, ix1: number, iz1: number)
	for iz = math.max(0, iz0), math.min(self.rows - 1, iz1) do
		for ix = math.max(0, ix0), math.min(self.cols - 1, ix1) do
			self:block(ix, iz)
		end
	end
end

function NavGrid.isBlocked(self: Grid, ix: number, iz: number): boolean
	return self:inBounds(ix, iz) and self.blocked[indexOf(self, ix, iz)] == true
end

function NavGrid.setCost(self: Grid, ix: number, iz: number, multiplier: number?)
	if self:inBounds(ix, iz) then
		self.cost[indexOf(self, ix, iz)] = multiplier
	end
end

function NavGrid.walkableCount(self: Grid): number
	local n = 0
	for _ in self.floor do
		n += 1
	end
	return n
end

-- True when the point is inside the part's oriented box (works for CanQuery=false volumes).
local function insidePart(part: BasePart, point: Vector3): boolean
	local local_ = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	return math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z
end

-- Samples every cell from the world: floor under the cell center, slope, and clearance rays at
-- knee and head height in the four axis directions plus one straight up. Returns the number of
-- walkable cells.
function NavGrid.sample(self: Grid, world: any, options: SampleOptions?): number
	local o: SampleOptions = options or {}
	local top = o.top or 500
	local bottom = o.bottom or -500
	local minNormalY = math.cos(math.rad(o.maxSlope or 50))
	local agentHeight = o.agentHeight or 5
	local agentRadius = o.agentRadius or 2
	local stepHeight = o.stepHeight or 2
	local avoid: { BasePart } = o.avoid or {}

	local rayParams = RaycastParams.new()
	if o.walkableOnly and #o.walkableOnly > 0 then
		rayParams.FilterType = Enum.RaycastFilterType.Include
		rayParams.FilterDescendantsInstances = o.walkableOnly
	else
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = o.ignore or {}
	end
	local clearParams = RaycastParams.new()
	clearParams.FilterType = Enum.RaycastFilterType.Exclude
	clearParams.FilterDescendantsInstances = o.ignore or {}
	clearParams.RespectCanCollide = true

	local down = Vector3.new(0, bottom - top, 0)
	local kneeHeight = stepHeight + 0.3
	local headHeight = agentHeight - 0.4
	local reach = {
		Vector3.new(agentRadius, 0, 0),
		Vector3.new(-agentRadius, 0, 0),
		Vector3.new(0, 0, agentRadius),
		Vector3.new(0, 0, -agentRadius),
	}
	local up = Vector3.new(0, agentHeight - stepHeight - 0.1, 0)

	local function fits(x: number, floorY: number, z: number): boolean
		if world:Raycast(Vector3.new(x, floorY + stepHeight + 0.05, z), up, clearParams) then
			return false
		end
		for _, height in { kneeHeight, headHeight } do
			local origin = Vector3.new(x, floorY + height, z)
			for _, direction in reach do
				if world:Raycast(origin, direction, clearParams) then
					return false
				end
			end
		end
		return true
	end

	local walkable = 0
	for iz = 0, self.rows - 1 do
		for ix = 0, self.cols - 1 do
			local index = indexOf(self, ix, iz)
			local x = self.minX + (ix + 0.5) * self.cellSize
			local z = self.minZ + (iz + 0.5) * self.cellSize
			local hit = world:Raycast(Vector3.new(x, top, z), down, rayParams)
			self.floor[index] = nil
			self.blocked[index] = nil
			if not hit then
				continue -- void: nothing below
			end
			local floorY = hit.Position.Y
			local ok = hit.Normal.Y >= minNormalY and fits(x, floorY, z)
			if ok then
				local point = Vector3.new(x, floorY + 1, z)
				for _, volume in avoid do
					if insidePart(volume, point) then
						ok = false
						break
					end
				end
			end
			if ok then
				self.floor[index] = floorY
				walkable += 1
			else
				self.blocked[index] = true
			end
		end
	end
	return walkable
end

-- Nearest walkable cell to a position, searched in growing rings up to `radius` studs.
function NavGrid.nearestWalkable(self: Grid, position: Vector3, radius: number?): (number?, number?)
	local ix, iz = self:cellOf(position)
	if self:isWalkable(ix, iz) then
		return ix, iz
	end
	local rings = math.ceil((radius or 8) / self.cellSize)
	for ring = 1, rings do
		local bestDistance = math.huge
		local bx, bz = nil, nil
		for dz = -ring, ring do
			for dx = -ring, ring do
				if math.max(math.abs(dx), math.abs(dz)) == ring then
					local cx, cz = ix + dx, iz + dz
					if self:isWalkable(cx, cz) then
						local center = self:centerOf(cx, cz)
						local d = (Vector3.new(center.X, position.Y, center.Z) - position).Magnitude
						if d < bestDistance then
							bestDistance, bx, bz = d, cx, cz
						end
					end
				end
			end
		end
		if bx then
			return bx, bz
		end
	end
	return nil, nil
end

-- Binary min-heap keyed on f-score, storing cell indices.
type Heap = { keys: { number }, items: { number }, size: number }

local function heapPush(heap: Heap, key: number, item: number)
	heap.size += 1
	local i = heap.size
	heap.keys[i], heap.items[i] = key, item
	while i > 1 do
		local parent = i // 2
		if heap.keys[parent] <= heap.keys[i] then
			break
		end
		heap.keys[parent], heap.keys[i] = heap.keys[i], heap.keys[parent]
		heap.items[parent], heap.items[i] = heap.items[i], heap.items[parent]
		i = parent
	end
end

local function heapPop(heap: Heap): (number, number)
	local key, item = heap.keys[1], heap.items[1]
	local last = heap.size
	heap.keys[1], heap.items[1] = heap.keys[last], heap.items[last]
	heap.keys[last], heap.items[last] = nil, nil
	heap.size = last - 1
	local i = 1
	while true do
		local left, right = i * 2, i * 2 + 1
		local smallest = i
		if left <= heap.size and heap.keys[left] < heap.keys[smallest] then
			smallest = left
		end
		if right <= heap.size and heap.keys[right] < heap.keys[smallest] then
			smallest = right
		end
		if smallest == i then
			break
		end
		heap.keys[smallest], heap.keys[i] = heap.keys[i], heap.keys[smallest]
		heap.items[smallest], heap.items[i] = heap.items[i], heap.items[smallest]
		i = smallest
	end
	return key, item
end

local DIRECTIONS = {
	{ 1, 0 },
	{ -1, 0 },
	{ 0, 1 },
	{ 0, -1 },
	{ 1, 1 },
	{ 1, -1 },
	{ -1, 1 },
	{ -1, -1 },
}
local CARDINALS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Octile distance in studs.
local function heuristic(self: Grid, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = math.abs(ax - bx), math.abs(az - bz)
	return (math.max(dx, dz) + (SQRT2 - 1) * math.min(dx, dz)) * self.cellSize
end

-- Cost in studs of walking a straight line between two cell centers, or nil when the line
-- leaves walkable cells, climbs more than a step, or slips diagonally between two blocked
-- cells. Samples the segment at quarter-cell spacing so no cell it touches is skipped.
local function lineCost(self: Grid, ax: number, az: number, bx: number, bz: number, stepHeight: number): number?
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)
	local previousY = self:floorAt(ax, az)
	if not previousY then
		return nil
	end
	if length == 0 then
		return 0
	end
	local samples = math.ceil(length * 4)
	local stepLength = length * self.cellSize / samples
	local px, pz = ax, az
	local total = 0
	for i = 1, samples do
		local t = i / samples
		local cx, cz = math.floor(ax + dx * t + 0.5), math.floor(az + dz * t + 0.5)
		if cx ~= px or cz ~= pz then
			local y = self:floorAt(cx, cz)
			if not y or math.abs(y - previousY) > stepHeight then
				return nil
			end
			if cx ~= px and cz ~= pz then
				-- Crossed a corner: both cells sharing that corner must be open at a walkable height.
				local y1, y2 = self:floorAt(cx, pz), self:floorAt(px, cz)
				if
					not y1
					or not y2
					or math.abs(y1 - previousY) > stepHeight
					or math.abs(y2 - previousY) > stepHeight
				then
					return nil
				end
			end
			previousY, px, pz = y, cx, cz
		end
		total += stepLength * (self.cost[indexOf(self, px, pz)] or 1)
	end
	return total
end

-- Path between two world positions. Start and goal snap to the nearest walkable cell.
function NavGrid.findPath(self: Grid, from: Vector3, to: Vector3, options: PathOptions?): PathResult
	local o: PathOptions = options or {}
	local maxNodes = o.maxNodes or 20000
	local stepHeight = o.stepHeight or 2
	local jumpHeight = o.jumpHeight or 7
	local maxDrop = o.maxDrop or 12
	local maxJumpGap = o.maxJumpGap or 6
	local jumpCost = o.jumpCost or 1.6
	local snapRadius = o.snapRadius or 8
	local yieldEvery = o.yieldEvery or 0
	local sliced = yieldEvery > 0 and coroutine.isyieldable() and coroutine.running() ~= hostThread
	-- A chasm of k missing cells is crossed by a link k + 1 cells long.
	local gapCells = if jumpHeight > 0 and maxJumpGap > 0 then math.floor(maxJumpGap / self.cellSize + 1e-6) + 1 else 0

	local sx, sz = self:nearestWalkable(from, snapRadius)
	local gx, gz = self:nearestWalkable(to, snapRadius)
	if not sx or not gx then
		return { status = "NoPath", waypoints = {}, cost = 0, expanded = 0 }
	end
	local startIndex, goalIndex = indexOf(self, sx :: number, sz :: number), indexOf(self, gx :: number, gz :: number)

	local gScore: { [number]: number } = { [startIndex] = 0 }
	local cameFrom: { [number]: number } = {}
	local jumpInto: { [number]: boolean } = {} -- true when the move INTO this cell is a jump
	local closed: { [number]: boolean } = {}
	local heap: Heap = { keys = {}, items = {}, size = 0 }
	heapPush(heap, heuristic(self, sx :: number, sz :: number, gx :: number, gz :: number), startIndex)

	local expanded = 0
	local bestIndex, bestH = startIndex, heuristic(self, sx :: number, sz :: number, gx :: number, gz :: number)
	local found = false
	local cols = self.cols

	local function consider(
		current: number,
		cx: number,
		cz: number,
		nx: number,
		nz: number,
		distance: number,
		isJump: boolean
	)
		if not self:inBounds(nx, nz) then
			return
		end
		local neighbor = indexOf(self, nx, nz)
		if closed[neighbor] then
			return
		end
		local ny = self.floor[neighbor]
		if ny == nil then
			return
		end
		local cy = self.floor[current] :: number
		local dy = ny - cy
		if isJump then
			if dy > jumpHeight or dy < -maxDrop then
				return
			end
		else
			if dy > stepHeight then
				if jumpHeight <= 0 or dy > jumpHeight then
					return
				end
				isJump = true
			elseif dy < -maxDrop then
				return
			end
		end
		local multiplier = self.cost[neighbor] or 1
		local stepCost = distance * self.cellSize * multiplier * (if isJump then jumpCost else 1)
		local tentative = gScore[current] + stepCost
		local known = gScore[neighbor]
		if known == nil or tentative < known then
			gScore[neighbor] = tentative
			cameFrom[neighbor] = current
			jumpInto[neighbor] = isJump
			local h = heuristic(self, nx, nz, gx :: number, gz :: number)
			heapPush(heap, tentative + h, neighbor)
		end
	end

	while heap.size > 0 do
		local _, current = heapPop(heap)
		if closed[current] then
			continue
		end
		closed[current] = true
		expanded += 1
		if current == goalIndex then
			found = true
			break
		end
		local cx = (current - 1) % cols
		local cz = (current - 1) // cols
		local h = heuristic(self, cx, cz, gx :: number, gz :: number)
		if h < bestH then
			bestH, bestIndex = h, current
		end
		if expanded >= maxNodes then
			break
		end

		for _, d in DIRECTIONS do
			local nx, nz = cx + d[1], cz + d[2]
			if d[1] ~= 0 and d[2] ~= 0 then
				-- No corner cutting: both orthogonal neighbours must be open at a walkable height.
				local cy = self.floor[current] :: number
				local y1, y2 = self:floorAt(cx + d[1], cz), self:floorAt(cx, cz + d[2])
				if not y1 or not y2 or math.abs(y1 - cy) > stepHeight or math.abs(y2 - cy) > stepHeight then
					continue
				end
				consider(current, cx, cz, nx, nz, SQRT2, false)
			else
				consider(current, cx, cz, nx, nz, 1, false)
			end
		end

		-- Gap jumps: straight over void cells (or cells well below), cardinal directions only.
		-- A single blocked cell may also be crossed when the far side is a different level: that
		-- is climbing onto (or dropping off) the very obstacle standing in that cell.
		local cy = self.floor[current] :: number
		for gap = 2, gapCells do
			for _, d in CARDINALS do
				local leapable = true
				local mount = false
				for k = 1, gap - 1 do
					local mx, mz = cx + d[1] * k, cz + d[2] * k
					if not self:inBounds(mx, mz) then
						leapable = false
						break
					end
					if self:isBlocked(mx, mz) then
						if gap == 2 then
							mount = true
						else
							leapable = false
							break
						end
					else
						local my = self:floorAt(mx, mz)
						if my ~= nil and my > cy - 2.5 then
							leapable = false -- solid ground at walking height: walk it instead
							break
						end
					end
				end
				if leapable then
					local tx, tz = cx + d[1] * gap, cz + d[2] * gap
					if mount then
						local ty = self:floorAt(tx, tz)
						if ty == nil or math.abs(ty - cy) <= stepHeight then
							continue -- same level across an obstacle: that is a wall, not a box
						end
					end
					consider(current, cx, cz, tx, tz, gap, true)
				end
			end
		end

		-- A slice ends here, after the node's edges are in the open set, so the order of expansion
		-- (and therefore the result) is exactly the synchronous one.
		if sliced and expanded % yieldEvery == 0 then
			coroutine.yield()
		end
	end

	local endIndex = if found then goalIndex else bestIndex
	if not found and endIndex == startIndex then
		return { status = "NoPath", waypoints = {}, cost = 0, expanded = expanded }
	end

	-- Walk back through cameFrom to build the cell chain.
	local chain: { number } = {}
	local node = endIndex
	while node do
		table.insert(chain, 1, node)
		node = cameFrom[node]
	end

	local waypoints: { Waypoint } = {}
	local function cellWaypoint(index: number, action: Action): Waypoint
		local ix = (index - 1) % cols
		local iz = (index - 1) // cols
		return { position = self:centerOf(ix, iz), action = action }
	end

	if o.smooth == false then
		for i, index in chain do
			local nextIsJump = chain[i + 1] ~= nil and jumpInto[chain[i + 1]] == true
			table.insert(waypoints, cellWaypoint(index, if nextIsJump then "Jump" else "Walk"))
		end
	else
		-- String pulling between jump segments: from each anchor, jump to the farthest cell that a
		-- straight walk reaches no more expensively than the grid path did (so detours around
		-- costly areas survive, and jumps are never crossed).
		local i = 1
		while i <= #chain do
			local anchor = chain[i]
			local ax = (anchor - 1) % cols
			local az = (anchor - 1) // cols
			local farthest = i
			for j = i + 1, #chain do
				if jumpInto[chain[j]] then
					break
				end
				local jx = (chain[j] - 1) % cols
				local jz = (chain[j] - 1) // cols
				local straight = lineCost(self, ax, az, jx, jz, stepHeight)
				if straight and straight <= gScore[chain[j]] - gScore[anchor] + 1e-6 then
					farthest = j
				else
					break
				end
			end
			if farthest == i then
				-- Either the next move is a jump, or nothing straight is reachable: advance one cell.
				local nextIsJump = chain[i + 1] ~= nil and jumpInto[chain[i + 1]] == true
				table.insert(waypoints, cellWaypoint(anchor, if nextIsJump then "Jump" else "Walk"))
				i += 1
			else
				table.insert(waypoints, cellWaypoint(anchor, "Walk"))
				i = farthest
				if i == #chain then
					table.insert(waypoints, cellWaypoint(chain[i], "Walk"))
					break
				end
			end
		end
	end

	-- End exactly where the caller asked when the goal cell was reached (it snapped to a center).
	if found and #waypoints > 0 then
		local last = waypoints[#waypoints]
		local goalY = self.floor[goalIndex] :: number
		last.position = Vector3.new(to.X, goalY, to.Z)
		-- If the requested goal sits outside the cell, keep the center to avoid walking into a wall.
		local gcx, gcz = self:cellOf(to)
		if gcx ~= gx or gcz ~= gz then
			last.position = self:centerOf(gx :: number, gz :: number)
		end
	end

	return {
		status = if found then "Success" else "Partial",
		waypoints = waypoints,
		cost = gScore[endIndex] or 0,
		expanded = expanded,
	}
end

-- Straight-line walkability between two world points (for corner cutting decisions).
function NavGrid.hasLineOfWalk(self: Grid, from: Vector3, to: Vector3, stepHeight: number?): boolean
	local ax, az = self:cellOf(from)
	local bx, bz = self:cellOf(to)
	if not self:isWalkable(ax, az) or not self:isWalkable(bx, bz) then
		return false
	end
	return lineCost(self, ax, az, bx, bz, stepHeight or 2) ~= nil
end

-- Total length of a waypoint list in studs.
function NavGrid.pathLength(waypoints: { Waypoint }): number
	local length = 0
	for i = 2, #waypoints do
		length += (waypoints[i].position - waypoints[i - 1].position).Magnitude
	end
	return length
end

return NavGrid

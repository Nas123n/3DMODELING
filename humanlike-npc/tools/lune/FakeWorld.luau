-- A complete fake game for the Lune suite: one of the Scenes worlds (arena, gauntlet or plaza),
-- a sampled nav grid (sampled once per process per scene and shared by every world and suite
-- that asks for it), fake kinematic bodies for NPCs, scripted fake players, a recording
-- presenter (chat, emotes, leaves, resets, typing, cameras, seats) and a fake connections bag,
-- wired into the same WorldAdapter shape the Roblox adapters provide. The service always runs on
-- a resolved Config (the defaults unless a test hands one in), optionally with the population
-- model, a primary FakePathProvider whose Blocked queue is drained into the service, and the
-- tell-score trace. A reset is resolved synchronously: the presenter builds a fresh body at the
-- spawn and hands it back through service:onRebind. Tests spawn NPCs through NpcService and
-- advance time with `step` / `run`. The landed `FakeWorld.new(session, { seed, players })` still
-- works: it is the arena with the default config.

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local Scenes = require("./Scenes")
local Sim = require("./Sim")

local FakeWorld = {}
FakeWorld.__index = FakeWorld

export type PlayerScript = {
	id: string,
	displayName: string,
	position: Vector3,
	-- Called every frame with (player, world, now, dt); moves the player by mutating position/velocity.
	update: ((player: any, world: any, now: number, dt: number) -> ())?,
}

export type Options = {
	seed: (number | string)?,
	players: { PlayerScript }?,
	scene: string?, -- "arena" (default) | "gauntlet" | "plaza"
	config: any?, -- Config.Resolved; default Config.resolve(nil)
	primary: any?, -- a FakePathProvider used as the engine's pathfinder, or a function (grid) -> provider
	population: boolean?, -- wire Config.population(config) so the service spawns on its own
	trace: boolean?, -- keep an Eval.Trace (FakeWorld.trace) at TraceHz
	spent: (() -> number)?, -- the frame's millisecond counter (nil: never over budget, deterministic)
}

-- Grid bounds per scene; the plaza samples at 4 studs to keep the suite fast.
local GRID_BOUNDS = {
	arena = { minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 },
	gauntlet = { minX = -20, minZ = 0, maxX = 20, maxZ = 160, cellSize = 2 },
	plaza = { minX = -100, minZ = -100, maxX = 100, maxZ = 100, cellSize = 4 },
}
FakeWorld.GRID_BOUNDS = GRID_BOUNDS

-- Sampled grids, once per process, keyed by scene name (sampling is by far the slowest step).
local gridCache: { [string]: { grid: any, walkable: number } } = {}

-- Every walkable cell whose center (one stud above its floor) lies inside an NpcSlow part gets
-- that part's cost (what RobloxDiscovery does in Studio).
local function applySlow(grid: any, slowParts: { any })
	for _, entry in slowParts do
		-- Instance properties are read once; only the cells under the part's horizontal extent are tested.
		local cf, size = entry.part.CFrame, entry.part.Size
		local half = size / 2
		local reach = math.sqrt(half.X * half.X + half.Z * half.Z) -- the box's horizontal extent whatever its yaw
		local centre = cf.Position
		local ix0, iz0 = grid:cellOf(Vector3.new(centre.X - reach, 0, centre.Z - reach))
		local ix1, iz1 = grid:cellOf(Vector3.new(centre.X + reach, 0, centre.Z + reach))
		for iz = math.max(0, iz0), math.min(grid.rows - 1, iz1) do
			for ix = math.max(0, ix0), math.min(grid.cols - 1, ix1) do
				local y = grid:floorAt(ix, iz)
				if y then
					local c = grid:centerOf(ix, iz)
					local local_ = cf:PointToObjectSpace(Vector3.new(c.X, y + 1, c.Z))
					if
						math.abs(local_.X) <= half.X
						and math.abs(local_.Y) <= half.Y
						and math.abs(local_.Z) <= half.Z
					then
						grid:setCost(ix, iz, entry.cost)
					end
				end
			end
		end
	end
end

-- The nav grid of a scene built in `session` (its model is `model`), sampled with the scene's
-- NpcAvoid parts blocked and its NpcSlow costs applied. Sampled once per process; later calls,
-- from any session, get the same grid. Returns the grid and its walkable cell count.
function FakeWorld.sampledGrid(session: any, scene: string, model: any): (any, number)
	local cached = gridCache[scene]
	if cached then
		return cached.grid, cached.walkable
	end
	local bounds = GRID_BOUNDS[scene]
	assert(bounds, `FakeWorld: unknown scene "{scene}"`)
	local S = session.game.ServerStorage.HumanlikeNpc
	local NavGrid = session.require(S.Nav.NavGrid)
	local Scan = session.require(S.World.Scan)
	local grid = NavGrid.new(bounds)
	local walkable = grid:sample(session.world, { avoid = Scan.avoidParts(model) })
	applySlow(grid, Scan.slowParts(model))
	gridCache[scene] = { grid = grid, walkable = walkable }
	return grid, walkable
end

-- A bag with the shape of Adapters/Connections that the leak test can read: one entry per body.
local function newBag()
	local bag = { entries = {} }
	function bag.add(self, entry)
		table.insert(self.entries, entry)
		return entry
	end
	function bag.remove(self, entry)
		for i = #self.entries, 1, -1 do
			if self.entries[i] == entry then
				table.remove(self.entries, i)
				return true
			end
		end
		return false
	end
	function bag.count(self)
		return #self.entries
	end
	return bag
end

local function wrapPlayer(p: PlayerScript)
	return {
		id = "p:" .. p.id,
		kind = "player",
		position = p.position,
		velocity = Vector3.zero,
		yaw = 0,
		displayName = p.displayName,
		update = p.update,
		jumpedAt = nil,
		emoteAt = nil,
		emoteName = nil,
		isTyping = nil,
		chatQueue = {},
	}
end

-- `session` is a Loader session; modules are required through it.
function FakeWorld.new(session: any, options: Options?)
	local o: Options = options or {}
	local scene = o.scene or "arena"
	local S = session.game.ServerStorage.HumanlikeNpc
	local NavMath = session.require(S.Nav.NavMath)
	local Scan = session.require(S.World.Scan)
	local Config = session.require(S.Config)
	local NpcService = session.require(S.Runtime.NpcService)

	local builder = Scenes[scene]
	assert(type(builder) == "function", `FakeWorld: unknown scene "{scene}"`)
	local model, made = builder(session)
	local grid = FakeWorld.sampledGrid(session, scene, model)
	local pois = Scan.registry(model)
	Scan.seats(model, pois)
	local props = Scan.props(model, true)
	local noSpawnParts = Scan.noSpawnParts(model)
	local resolved = if o.config then table.clone(o.config) else Config.resolve(nil)
	if o.trace then
		resolved.TraceEnabled = true
	end
	local primary = o.primary
	if type(primary) == "function" then
		primary = primary(grid)
	end

	local self = setmetatable({
		session = session,
		scene = scene,
		model = model,
		made = made,
		grid = grid,
		pois = pois,
		props = props,
		config = resolved,
		bodies = {},
		commands = {},
		players = {},
		log = {
			says = {},
			emotes = {},
			leaves = {},
			resets = {},
			typing = {},
			cameras = {},
			seats = {},
			telemetry = {},
			avatars = {},
		},
		connections = newBag(),
		primary = primary,
		service = nil,
		trace = nil,
		now = 0,
		hour = 12,
		frames = 0,
		lastFrame = nil,
	}, FakeWorld)

	for _, p in o.players or {} do
		table.insert(self.players, wrapPlayer(p))
	end

	local function flat(v)
		return Vector3.new(v.X, 0, v.Z)
	end

	local function losCheck(a, b)
		return grid:hasLineOfWalk(a, b)
	end

	-- A body's respawn point: the first spawn area's middle, snapped to walkable ground.
	local function respawnPoint()
		local point = pois:spawnPoint(0.5, 0.5, 1) or Vector3.zero
		local ix, iz = grid:nearestWalkable(point, 8)
		if ix then
			return grid:centerOf(ix, iz)
		end
		return Vector3.new(point.X, 0, point.Z)
	end

	local function makeMover(id, body)
		local entry = { npc = id }
		self.connections:add(entry)
		local mover = { entry = entry }
		function mover.read()
			return body:state()
		end
		function mover.apply(_, command)
			self.commands[id] = command
			if command.facingYaw and command.mode ~= "move" then
				body.yaw = command.facingYaw
			end
		end
		function mover.teleport(_, at)
			body.position = at
			body.onGround = true
			body.velocity = Vector3.zero
		end
		function mover.probe(_, position, forward)
			-- Free distance to the left and right at 60 degrees, up to 3 studs, on the grid.
			local function free(angle)
				local dir = NavMath.dirFromYaw(NavMath.yawOf(forward) + angle)
				for d = 0.5, 3, 0.5 do
					local p = position + dir * d
					local ix, iz = grid:cellOf(p)
					if not grid:isWalkable(ix, iz) then
						return d - 0.5
					end
				end
				return 3
			end
			return free(math.rad(60)), free(math.rad(-60))
		end
		function mover.setWalkSpeed(_, speed)
			body:setWalkSpeed(speed)
		end
		function mover.destroy()
			self.connections:remove(entry)
		end
		return mover
	end

	local adapter = {
		createMover = function(id, _identity, persona, position)
			local body =
				Sim.fromGrid(grid, Vector3.new(position.X, position.Y, position.Z), { walkSpeed = persona.walkSpeed })
			self.bodies[id] = body
			self.commands[id] = nil
			return makeMover(id, body)
		end,
		destroyMover = function(id)
			self.bodies[id] = nil
			self.commands[id] = nil
			local record = self.service and self.service.records[id]
			local mover = if record then record.mover else nil
			if mover and mover.destroy then
				mover.destroy()
			else
				-- The record is gone already (the service clears it before destroyMover): drop the bag entry by id.
				for i = #self.connections.entries, 1, -1 do
					if self.connections.entries[i].npc == id then
						table.remove(self.connections.entries, i)
					end
				end
			end
		end,
		players = function()
			local out = {}
			for _, p in self.players do
				table.insert(out, {
					id = p.id,
					kind = "player",
					position = p.position,
					velocity = p.velocity,
					yaw = p.yaw,
					displayName = p.displayName,
					jumpedAt = p.jumpedAt,
					emoteAt = p.emoteAt,
					emoteName = p.emoteName,
					isTyping = p.isTyping,
				})
			end
			return out
		end,
		presenter = {
			say = function(_, npcId, text, target)
				local entry = { npc = npcId, text = text, target = target, at = self.now, lineId = nil, category = nil }
				table.insert(self.log.says, entry)
				if self.service then
					self.service:notifySaid(npcId, text, self.now)
					local record = self.service.records[npcId]
					local lineId = if record then record.lastSaidLineId else nil
					if lineId then
						entry.lineId = lineId
						entry.category = string.match(lineId, "^([^:]+):")
					end
				end
			end,
			emote = function(_, npcId, name, cutAfter)
				table.insert(self.log.emotes, { npc = npcId, name = name, cutAfter = cutAfter, at = self.now })
				if self.service then
					self.service:notifyEmote(npcId, name, self.now)
				end
			end,
			leave = function(_, npcId, reason)
				table.insert(self.log.leaves, { npc = npcId, reason = reason, at = self.now })
			end,
			reset = function(_, npcId)
				table.insert(self.log.resets, { npc = npcId, at = self.now })
				-- A fresh body at the spawn, handed back at once: the reset story ends this frame.
				local old = self.service and self.service.records[npcId]
				local walkSpeed = if old then old.persona.walkSpeed else 16
				if old and old.mover.destroy then
					old.mover.destroy()
				end
				local body = Sim.fromGrid(grid, respawnPoint(), { walkSpeed = walkSpeed })
				self.bodies[npcId] = body
				self.commands[npcId] = nil
				if self.service then
					self.service:onRebind(npcId, makeMover(npcId, body), self.now)
				end
			end,
			setTyping = function(_, npcId, on)
				table.insert(self.log.typing, { npc = npcId, on = on, at = self.now })
			end,
			setCamera = function(_, npcId, yaw, pitch)
				table.insert(self.log.cameras, { npc = npcId, yaw = yaw, pitch = pitch, at = self.now })
			end,
			seat = function(_, npcId, seatId)
				table.insert(self.log.seats, { npc = npcId, seat = seatId, at = self.now })
			end,
		},
		grid = grid,
		primaryProvider = primary,
		pois = pois,
		losCheck = losCheck,
		occlusion = function(a, b)
			return not grid:hasLineOfWalk(flat(a), flat(b))
		end,
		props = props,
		-- Additions (§2.32).
		clock = {
			now = function()
				return self.now
			end,
			hour = function()
				return self.hour
			end,
		},
		playerLos = function(npcPosition, playerPosition)
			return grid:hasLineOfWalk(flat(npcPosition), flat(playerPosition))
		end,
		spent = o.spent,
		telemetry = function(event)
			table.insert(self.log.telemetry, event)
		end,
		avatars = function(id, spec)
			self.log.avatars[id] = spec
		end,
		avoidBoxes = function()
			local out = {}
			for _, avoid in pois.avoids do
				table.insert(out, { cframe = avoid.cframe, size = avoid.size })
			end
			return out
		end,
		noSpawnBoxes = function()
			local out = {}
			for _, part in noSpawnParts do
				table.insert(out, { cframe = part.CFrame, size = part.Size })
			end
			return out
		end,
		floorAt = function(p)
			return grid:floorAt(grid:cellOf(p))
		end,
	}
	self.adapter = adapter
	self.service = NpcService.new({
		seed = o.seed or "fake",
		config = resolved,
		scheduler = Config.scheduler(resolved),
		planner = Config.planner(resolved),
		chatGuard = Config.chatGuard(resolved),
		lod = Config.lod(resolved),
		population = if o.population then Config.population(resolved) else nil,
	}, adapter)
	self.trace = self.service:tellTrace()
	for _, p in self.players do
		self.service:onPlayerJoined(string.sub(p.id, 3), p.displayName, self.now)
	end
	return self
end

-- A player says something (heard by NPCs in range).
function FakeWorld.playerSays(self, playerIndex: number, text: string)
	local p = self.players[playerIndex]
	self.service:onPlayerChat(string.sub(p.id, 3), text, p.position, self.now)
end

-- Replaces the players: those who are gone leave the server, newcomers join (the population
-- model and the name check hear about both). Scripts keep running from their given position.
function FakeWorld.setPlayers(self, list: { PlayerScript })
	local before = {}
	for _, p in self.players do
		before[p.id] = p
	end
	local after = {}
	local players = {}
	for _, script in list do
		local id = "p:" .. script.id
		local existing = before[id]
		if existing then
			table.insert(players, existing)
		else
			table.insert(players, wrapPlayer(script))
		end
		after[id] = true
	end
	self.players = players
	for id in before do
		if not after[id] then
			self.service:onPlayerLeft(string.sub(id, 3), self.now)
		end
	end
	for _, p in players do
		if not before[p.id] then
			self.service:onPlayerJoined(string.sub(p.id, 3), p.displayName, self.now)
		end
	end
end

-- Moves an NPC's body (the avoid-exit and kill-plane cases): the one teleport a test may do.
function FakeWorld.teleportNpc(self, id: string, position: Vector3)
	local body = self.bodies[id]
	if body then
		body.position = position
		body.velocity = Vector3.zero
		body.onGround = true
	end
end

-- A scripted stimulus aimed at `subject` (an NPC entity id) from `source`, recorded in the trace.
function FakeWorld.probe(self, subject: string, source: Vector3?, text: string?)
	if self.trace then
		self.trace:mark({ kind = "probe", at = self.now, subject = subject, source = source, text = text })
	end
end

-- Advances the whole world by dt: players move, the service steps, bodies integrate, the primary
-- provider's Blocked notifications reach the service.
function FakeWorld.step(self, dt: number)
	self.now += dt
	for _, p in self.players do
		if p.update then
			p.update(p, self, self.now, dt)
		end
	end
	self.lastFrame = self.service:stepFrame(self.now, dt)
	self.frames += 1
	local reports = self.service.lastReports
	local ids = {}
	for id in self.bodies do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local body = self.bodies[id]
		local command = self.commands[id] or { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
		body:step(command, dt)
		-- Only one jump per command application.
		if command.jump then
			self.commands[id] = table.clone(command)
			self.commands[id].jump = false
		end
	end
	local primary = self.primary
	if primary and primary.drainBlocked then
		for _, blocked in primary:drainBlocked() do
			self.service:onBlocked(blocked.agentId, blocked.idx, blocked.at)
		end
	end
	return reports
end

-- Runs for `seconds` at `hz`, collecting per-NPC reports; returns a summary table.
function FakeWorld.run(self, seconds: number, hz: number?, onReport: ((id: string, report: any, now: number) -> ())?)
	local dt = 1 / (hz or 30)
	local frames = math.floor(seconds / dt + 1e-6)
	for _ = 1, frames do
		local reports = self:step(dt)
		if onReport then
			for id, report in reports do
				onReport(id, report, self.now)
			end
		end
	end
end

return FakeWorld

-- A complete fake game for the Lune suite: the arena scene, a sampled nav grid, fake bodies
-- for NPCs, scripted fake players, and a recording presenter, wired into the same WorldAdapter
-- shape the Roblox adapter provides. Tests spawn NPCs through NpcService and advance time.

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

-- `session` is a Loader session; modules are required through it.
function FakeWorld.new(session: any, options: { seed: (number | string)?, players: { PlayerScript }? }?)
	local o = options or {}
	local S = session.game.ServerStorage.HumanlikeNpc
	local NavGrid = session.require(S.Nav.NavGrid)
	local NavMath = session.require(S.Nav.NavMath)
	local Scan = session.require(S.World.Scan)
	local NpcService = session.require(S.Runtime.NpcService)

	local model, made = Scenes.arena(session)
	local grid = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
	grid:sample(session.world, { avoid = Scan.avoidParts(model) })
	-- Bodies collide with geometry, not with the planning margin around it: a narrow-agent grid.
	local physics = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
	physics:sample(session.world, { agentRadius = 0.6 })
	local pois = Scan.registry(model)
	local props = Scan.props(model, true)

	local self = setmetatable({
		session = session,
		model = model,
		made = made,
		grid = grid,
		physics = physics,
		pois = pois,
		bodies = {},
		commands = {},
		players = {},
		log = { says = {}, emotes = {}, leaves = {}, resets = {} },
		service = nil,
		now = 0,
	}, FakeWorld)

	for _, p in o.players or {} do
		table.insert(self.players, {
			id = "p:" .. p.id,
			kind = "player",
			position = p.position,
			velocity = Vector3.zero,
			yaw = 0,
			displayName = p.displayName,
			update = p.update,
			jumpedAt = nil,
			emoteAt = nil,
			chatQueue = {},
		})
	end

	local function losCheck(a, b)
		return grid:hasLineOfWalk(a, b)
	end

	local adapter = {
		createMover = function(id, _identity, persona, position)
			local body =
				Sim.fromGrid(grid, Vector3.new(position.X, position.Y, position.Z), { walkSpeed = persona.walkSpeed })
			self.bodies[id] = body
			self.commands[id] = nil
			local mover = {}
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
			return mover
		end,
		destroyMover = function(id)
			self.bodies[id] = nil
			self.commands[id] = nil
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
				})
			end
			return out
		end,
		presenter = {
			say = function(_, npcId, text, target)
				table.insert(self.log.says, { npc = npcId, text = text, target = target, at = self.now })
				if self.service then
					self.service:notifySaid(npcId, text, self.now)
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
				local body = self.bodies[npcId]
				if body then
					local spawn = made.spawn.CFrame.Position
					body.position = Vector3.new(spawn.X, 0, spawn.Z)
					body.onGround = true
				end
			end,
		},
		grid = grid,
		primaryProvider = nil,
		pois = pois,
		losCheck = losCheck,
		occlusion = function(a, b)
			return not grid:hasLineOfWalk(Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z))
		end,
		props = props,
	}
	self.adapter = adapter
	self.service = NpcService.new({ seed = o.seed or "fake" }, adapter)
	return self
end

-- A player says something (heard by NPCs in range).
function FakeWorld.playerSays(self, playerIndex: number, text: string)
	local p = self.players[playerIndex]
	self.service:onPlayerChat(string.sub(p.id, 3), text, p.position, self.now)
end

-- Advances the whole world by dt: players move, the service steps, bodies integrate.
function FakeWorld.step(self, dt: number)
	self.now += dt
	for _, p in self.players do
		if p.update then
			p.update(p, self, self.now, dt)
		end
	end
	local reports = self.service:step(self.now)
	for id, body in self.bodies do
		local command = self.commands[id] or { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }
		body:step(command, dt)
		-- Only one jump per command application.
		if command.jump then
			self.commands[id] = table.clone(command)
			self.commands[id].jump = false
		end
	end
	return reports
end

-- Runs for `seconds` at `hz`, collecting per-NPC reports; returns a summary table.
function FakeWorld.run(self, seconds: number, hz: number?, onReport: ((id: string, report: any, now: number) -> ())?)
	local dt = 1 / (hz or 30)
	local frames = math.floor(seconds / dt)
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

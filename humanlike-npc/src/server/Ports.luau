--!strict
-- The port contracts that sit between the pure core and the world: the body (Mover), the path
-- planners (PathProvider), the clock, what an NPC can perceive (Perception, WorldView), where its
-- words and gestures go (ChatSink, Presenter) and how the world is queried (WorldQuery). Every
-- Roblox adapter and every Lune fake implements one of these shapes; the core only ever sees the
-- shape. Types only: no functions, no state, no instance API. It requires Types and World/Spatial
-- (for the Group type) and nothing else.
-- requires: Spatial, Types

local Types = require(script.Parent.Types)
local Spatial = require(script.Parent.World.Spatial)

-- A connected component of slow-moving entities, as the spatial index computes it.
export type Group = Spatial.Group

-- The body: read its state, apply a command, place it (spawn and reset only), probe walls.
export type Mover = {
	read: (self: any) -> Types.BodyState,
	apply: (self: any, command: Types.MoveCommand) -> (),
	teleport: (self: any, position: Vector3) -> (), -- spawn/reset only, never mid-session
	-- probe: free studs to the left and to the right of `forward` at +-60 degrees, each capped at 3
	probe: ((self: any, position: Vector3, forward: Vector3) -> (number?, number?))?,
	setWalkSpeed: ((self: any, speed: number) -> ())?,
	destroy: ((self: any) -> ())?,
}

export type PathRequest = {
	id: number,
	agentId: string,
	start: Vector3,
	goal: Vector3,
	priority: number,
	allowPartial: boolean?,
	canJump: boolean?,
	issuedAt: number,
	maxNodes: number?, -- set by the planner
}

export type PathCompletion = {
	id: number,
	agentId: string,
	result: Types.PathResult,
}

-- A path planner the PathPlanner drives: the engine's PathfindingService or the sampled grid.
export type PathProvider = {
	name: string,
	submit: (self: any, request: PathRequest) -> (),
	cancel: (self: any, id: number) -> (),
	cancelAgent: (self: any, agentId: string) -> (),
	step: (self: any, now: number, spent: (() -> number)?) -> { PathCompletion },
	inFlight: (self: any) -> number,
}

export type Clock = {
	now: (self: any) -> number, -- monotonic seconds
	wall: ((self: any) -> number)?, -- wall-clock seconds since the epoch
	hour: ((self: any) -> number)?, -- local hour of day, 0 .. 24
}

-- The shared, per-frame view of the world: Goals.World minus the per-NPC fields `myGroup` and
-- `reachable`, which Npc adds when it builds the brain input.
export type WorldView = {
	pois: { Types.PoiRecord },
	poiOccupants: (poiId: string) -> number,
	seats: { Types.SeatRecord },
	entities: { Types.AgentView },
	visible: { [string]: boolean },
	groups: { Group },
	spawnPoint: Vector3,
	randomReachable: (from: Vector3, min: number, max: number, toward: Vector3?) -> Vector3?,
	sectorCenter: (id: string) -> Vector3?,
	nearbySectors: (from: Vector3, count: number) -> { string },
	totalSectors: number,
	isAvoided: (p: Vector3) -> boolean,
	failedRecently: (target: string) -> boolean,
	props: { Types.Prop }?,
}

-- What one NPC can perceive: entities and chat near it, sight and floor checks, groups, the world.
export type Perception = {
	snapshot: (
		self: any,
		npcId: string,
		position: Vector3,
		radius: number
	) -> { entities: { Types.AgentView }, chats: { Types.ChatEvent } },
	occlusion: ((from: Vector3, to: Vector3) -> boolean)?, -- true when something solid blocks eye to eye
	losCheck: ((from: Vector3, to: Vector3) -> boolean)?, -- true when the floor between is walkable (flat)
	walkableCheck: ((point: Vector3) -> string)?, -- "walkable" | "wall" | "void"
	groups: (self: any) -> { Group },
	groupOf: (self: any, id: string) -> Group?,
	entity: (self: any, id: string) -> Types.AgentView?,
	playersWithin: (self: any, position: Vector3, radius: number) -> number,
	world: WorldView,
}

export type ChatSink = {
	say: (self: any, npcId: string, text: string, target: string?) -> (),
	setTyping: ((self: any, npcId: string, typing: boolean) -> ())?,
}

-- Presentation: chat, emotes, leaving, and the reset story.
export type Presenter = {
	say: (self: any, npcId: string, text: string, target: string?) -> (),
	emote: (self: any, npcId: string, name: string?, cutAfter: number?) -> (),
	leave: (self: any, npcId: string, reason: string) -> (),
	-- reset: the adapter destroys the body and, after Players.RespawnTime, builds a fresh rig with the same
	-- identity, places it at a SpawnLocation (else an NpcSpawn) and calls npc:rebind(newMover). Never a teleport.
	reset: ((self: any, npcId: string) -> ())?,
	setTyping: ((self: any, npcId: string, typing: boolean) -> ())?,
	-- setCamera: only in HeadLook == "shared" mode: the adapter writes the neutral CamYaw/CamPitch attributes
	-- on the NPC character at most 2 Hz; players' characters get the same attributes from their own client.
	setCamera: ((self: any, npcId: string, yaw: number, pitch: number) -> ())?,
	seat: ((self: any, npcId: string, seatId: string?) -> ())?,
}

-- Static world queries the service asks at discovery time and when it places an NPC.
export type WorldQuery = {
	pois: (self: any) -> { Types.PoiRecord },
	seats: (self: any) -> { Types.SeatRecord },
	spawnPoint: (self: any, u1: number, u2: number, index: number?) -> Vector3?,
	isAvoided: (self: any, point: Vector3) -> boolean,
	bounds: (self: any) -> { min: Vector3, max: Vector3 },
	floorAt: (self: any, point: Vector3) -> number?,
	props: (self: any) -> { Types.Prop },
}

return {}

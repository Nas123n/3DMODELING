--!strict
-- Plain-data contracts shared by the pure core and the Roblox adapters. No functions, no
-- instances: every value here can be built in a test from literals, which is what keeps the
-- brain, the navigation runtime and the humanizer testable under Lune.
-- requires: (none)

export type WaypointAction = "Walk" | "Jump" | "Custom"

export type Waypoint = {
	position: Vector3,
	action: WaypointAction, -- "Jump": jump to reach the NEXT waypoint (PathWaypointAction semantics)
	label: string?, -- navigation area or PathfindingLink label
}

export type PathStatus = "Success" | "Partial" | "NoPath" | "Error" | "Cancelled" | "Timeout"

export type PathResult = {
	status: PathStatus,
	waypoints: { Waypoint }, -- empty unless Success or Partial; Partial ends at the closest reachable point
	provider: "roblox" | "grid" | "direct",
	cost: number, -- studs-equivalent
	goalDistance: number, -- horizontal distance from the last waypoint to the requested goal (0 on Success)
}

export type AgentParams = {
	radius: number, -- integer studs for Roblox (2)
	height: number, -- integer studs for Roblox (5)
	canJump: boolean,
	canClimb: boolean,
	waypointSpacing: number, -- 4
	costs: { [string]: number },
}

-- What the locomotion runtime knows about its own body each tick.
export type BodyState = {
	position: Vector3, -- HumanoidRootPart position
	velocity: Vector3, -- assembly velocity
	onGround: boolean, -- FloorMaterial ~= Air
	state: "Running" | "Jumping" | "Freefall" | "Landed" | "Seated" | "Dead" | "Other",
	walkSpeed: number,
	yaw: number, -- facing yaw in radians (atan2 of the look vector, see Nav.yawOf)
	moveToFinished: boolean?, -- set by the adapter when MoveToFinished fired since the last read
}

-- What the locomotion runtime asks the body to do.
export type MoveCommand = {
	mode: "move" | "moveTo" | "stop",
	dir: Vector3, -- world-space unit vector (mode "move")
	magnitude: number, -- 0..1 analog scale (mode "move")
	moveToPoint: Vector3?, -- mode "moveTo"
	jump: boolean,
	facingYaw: number?, -- nil = AutoRotate; a number holds this yaw (shift-lock profile)
}

export type AgentView = {
	id: string, -- "p:<userId>" or "n:<npcId>"
	kind: "player" | "npc",
	position: Vector3,
	velocity: Vector3,
	yaw: number,
	displayName: string,
	radius: number, -- 2
	isMoving: boolean,
	-- Spatial.Entity extras, so one record serves both the spatial index and the brain.
	jumpedAt: number?, -- when this agent last left the ground by jumping
	emoteAt: number?, -- when this agent last started an emote
	emoteName: string?, -- the emote playing since emoteAt, nil once it ended
	isTyping: boolean?, -- typing indicator on
}

-- lineId: the corpus line id when an NPC said it (so an echo re-renders the corpus line, never the bytes heard);
-- nil for a real player's line.
export type ChatEvent = { fromId: string, text: string, at: number, position: Vector3, lineId: string? }

export type Snapshot = {
	now: number,
	me: AgentView,
	nearby: { AgentView }, -- within the perception radius, sorted by distance
	chat: { ChatEvent }, -- since the last snapshot, within hearing range
	losBudget: number, -- how many occlusion raycasts this tick may spend
}

export type PoiRecord = {
	id: string,
	kind: string,
	position: Vector3, -- floor-projected
	weight: number,
	radius: number,
	dwellMedian: number?,
	capacity: number?, -- NpcCapacity attribute; nil = unlimited
	word: string?, -- PoiWord attribute: overrides the {poi} chat word (else the kind is used)
	source: any?, -- the Instance (adapter only; nil in tests)
}

export type SpawnRecord = { id: string, cframe: CFrame, size: Vector3 } -- top-surface rectangle
export type AvoidRecord = { id: string, cframe: CFrame, size: Vector3 }

-- "pc" | "pcShiftLock" | "mobile" | "console"
export type InputProfileKind = string

-- "near" | "mid" | "far" | "dormant" (the scheduler's update-rate bands; Scheduler.Tier and Humanizer.Tier
-- are the same plain string)
export type Tier = string

-- Who an NPC is for the whole session: the name pair players see, the fake account behind it, and
-- the seed everything about it derives from.
export type Identity = {
	id: string, -- "npc<N>"
	username: string,
	displayName: string,
	userIdLike: number?, -- a plausible UserId-shaped number for display; never a real account
	accountAgeDays: number?, -- math.floor(3 * 1000 ^ accountAge), 3 .. 3000
	familiarity: number?, -- 1 - exp(-accountAgeDays / 90), 0 .. 1
	seed: (number | string)?, -- the identity's own Rng seed
}

-- Everything the rig builder needs to dress a body; catalog ids are nil when the piece is absent.
export type AvatarSpec = {
	rig: string, -- "R15" | "R6"
	bodyColors: { [string]: Color3 }, -- keyed by body part name ("Head", "Torso", "LeftArm", ...)
	skinToneIndex: number, -- index into the catalog's skin tone list
	shirtId: number?,
	pantsId: number?,
	faceId: number?,
	hairId: number?,
	hatIds: { number },
	scale: {
		height: number,
		width: number,
		head: number,
		depth: number,
		proportion: number,
		bodyType: number,
	},
	catalogSeed: number, -- the draw that picked the catalog pieces, so a rig can be rebuilt identically
	animPack: string, -- animation pack name
	primitive: boolean, -- true: built from parts (PrimitiveRig), false: from a HumanoidDescription
	presentation: string, -- "m" | "f" | "any"
}

export type SeatRecord = {
	id: string,
	position: Vector3, -- floor point in front of the seat
	poiId: string?, -- the POI this seat belongs to
	source: any?, -- the Seat instance (adapter only; nil in tests)
}

-- A standable prop (crate, ledge, low wall) an NPC may hop onto.
export type Prop = {
	id: string,
	position: Vector3, -- centre of the top surface
	top: number, -- world Y of the top surface
	footprint: number, -- horizontal half-extent in studs
}

-- One line an NPC said, as recorded for the trace and the tell score.
export type Utterance = {
	npcId: string,
	text: string,
	at: number,
	target: string?, -- entity id the line was aimed at; nil = broadcast
	category: string, -- ChatCorpus category
	lineId: string, -- corpus line id, for anti-repetition
}

-- kinds: spawn, despawn, line, error, reset, died, frameOverBudget, gameEvent
export type NpcEvent = {
	kind: string,
	npcId: string,
	at: number,
	data: { [string]: any }?,
}

-- What one service frame cost and what it decided, for the budget and the trace.
export type FrameStats = {
	ticks: number, -- NPC ticks run this frame
	brains: number, -- brain evaluations run this frame
	pathMs: number, -- milliseconds spent in path providers
	tickMs: number, -- milliseconds spent ticking NPCs
	spent: number, -- total milliseconds the service spent this frame
	pressure: number, -- 0 .. 1+, how far over its budget the frame ran
	npcCount: number,
	dropped: number, -- ticks the scheduler cap pushed to a later frame
	wantSpawn: number, -- NPCs the population model would like to add
	pairWith: string?, -- npc id a newly spawned NPC should arrive with, if any
	rejoinSeed: (number | string)?, -- a departed persona's seed when one of the wanted spawns is its rejoin
}

-- Where the brain wants the body to go and why.
export type Goal = {
	position: Vector3,
	tolerance: number, -- studs: arrived when this close
	priority: number,
	reason: string, -- activity or overlay that set the goal
	poiId: string?,
}

return {}

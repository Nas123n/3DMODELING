--!strict
-- Plain-data contracts shared by the pure core and the Roblox adapters. No functions, no
-- instances: every value here can be built in a test from literals, which is what keeps the
-- brain, the navigation runtime and the humanizer testable under Lune.

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
}

export type ChatEvent = { fromId: string, text: string, at: number, position: Vector3 }

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
	source: any?, -- the Instance (adapter only; nil in tests)
}

export type SpawnRecord = { id: string, cframe: CFrame, size: Vector3 } -- top-surface rectangle
export type AvoidRecord = { id: string, cframe: CFrame, size: Vector3 }

-- "pc" | "pcShiftLock" | "mobile" | "console"
export type InputProfileKind = string

return {}

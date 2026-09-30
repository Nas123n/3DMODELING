--!strict
-- The Mover port over one character Model with a Humanoid and a HumanoidRootPart: reads the body state the
-- core ticks on, applies its commands through Humanoid:Move / MoveTo / Jump (analog speed as a throttled
-- WalkSpeed write by default, because sub-unit Move magnitudes on server-owned humanoids are unverified),
-- holds a facing through one AlignOrientation (never a CFrame write on a live body), probes walls with two
-- short raycasts, re-asserts server network ownership every 5 s, and owns the body's connection bag so
-- `destroy` frees everything with the model. Every method tolerates a destroyed or dying body: `read`
-- reports state "Dead" and onGround false, everything else becomes a no-op. It never builds, names, parents
-- or dresses a body (RobloxRig does, in the pinned order) and it never teleports a live body: `teleport`
-- is spawn placement before parenting, and the placement math is exported for the rig.
-- requires: Connections, NavMath, Ports (types), Types (types)

local Connections = require(script.Parent.Connections)
local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Ports = require(script.Parent.Parent.Ports)
local Types = require(script.Parent.Parent.Types)

type BodyState = Types.BodyState
type MoveCommand = Types.MoveCommand
type Bag = Connections.Bag

local RobloxMover = {}
RobloxMover.__index = RobloxMover

export type Options = {
	bag: Bag, -- parent bag; the mover makes its own child bag for the body
	walkSpeed: number?, -- persona walk speed; default the humanoid's current WalkSpeed
	analogViaWalkSpeed: boolean?, -- Config.AnalogViaWalkSpeed; default true
	excludes: (() -> { Instance })?, -- every character the probe raycasts must ignore (this body is always excluded)
	onDied: (() -> ())?, -- Humanoid.Died, or the model leaving the DataModel; called at most once
	clock: (() -> number)?, -- default os.clock; drives the write throttle and the ownership re-assert
}

export type Mover = typeof(setmetatable(
	{} :: {
		model: Model,
		humanoid: Humanoid,
		root: BasePart,
		bag: Bag,
		clock: () -> number,
		walkSpeed: number,
		analog: boolean,
		excludes: (() -> { Instance })?,
		onDied: (() -> ())?,
		dead: boolean,
		diedReported: boolean,
		moveToFinished: boolean,
		stateName: string,
		lastSpeedWrite: number,
		lastOwnerCheck: number,
		facingHeld: boolean,
		attachment: Attachment?,
		align: AlignOrientation?,
		lastPosition: Vector3,
		lastYaw: number,
	},
	RobloxMover
))

RobloxMover.PROBE_LENGTH = 3
RobloxMover.PROBE_ANGLE = math.rad(60)
RobloxMover.SPEED_WRITE_GAP = 0.25 -- at most 4 WalkSpeed writes per second per body
RobloxMover.SPEED_WRITE_THRESHOLD = 0.5
RobloxMover.SPEED_QUANTUM = 16 -- the analog target is quantised to 1/16 of the walk speed
RobloxMover.FACING_DEADBAND = math.rad(3)
RobloxMover.OWNERSHIP_PERIOD = 5

-- Humanoid states the core distinguishes; everything else is "Other".
local STATE_NAMES: { [string]: boolean } = {
	Running = true,
	Jumping = true,
	Freefall = true,
	Landed = true,
	Seated = true,
	Dead = true,
}

local warnedAlign = false

local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

-- Where the root must be for the feet to touch a floor point: R15 stands HipHeight plus half the root
-- above it; an R6 rig adds its leg length (the engine's own height formula).
function RobloxMover.placementCFrame(model: Model, humanoid: Humanoid, root: BasePart, floorPoint: Vector3): CFrame
	local height = humanoid.HipHeight + root.Size.Y / 2
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local leg = model:FindFirstChild("Left Leg")
		if leg and leg:IsA("BasePart") then
			height += leg.Size.Y
		end
	end
	return CFrame.new(floorPoint + Vector3.new(0, height, 0))
end

local function reportDied(self: Mover)
	if self.diedReported then
		return
	end
	self.diedReported = true
	self.dead = true
	local onDied = self.onDied
	if onDied then
		try(onDied)
	end
end

-- The facing constraint: one Attachment in the root and one AlignOrientation in OneAttachment mode, disabled
-- until a facing is held. Absent when the engine refuses (degrades to AutoRotate only, one warning).
local function createAlign(self: Mover)
	local ok = pcall(function()
		local attachment = Instance.new("Attachment")
		attachment.Parent = self.root
		local align = Instance.new("AlignOrientation")
		align.Mode = Enum.OrientationAlignmentMode.OneAttachment
		align.Attachment0 = attachment
		align.RigidityEnabled = false
		align.MaxTorque = 1e5
		align.Responsiveness = 20
		align.MaxAngularVelocity = 1.6
		align.Enabled = false
		align.Parent = self.root
		self.attachment = attachment
		self.align = align
	end)
	if not ok and not warnedAlign then
		warnedAlign = true
		warn("[HumanlikeNpc] AlignOrientation facing unavailable; bodies keep AutoRotate only")
	end
end

local function connect(self: Mover)
	local bag = self.bag
	local humanoid = self.humanoid
	local model = self.model
	-- Reached or timed out: either way the walk ended, which is what the far-tier re-issue rule waits for.
	bag:add(humanoid.MoveToFinished:Connect(function()
		self.moveToFinished = true
	end))
	bag:add(humanoid.StateChanged:Connect(function(_, new: Enum.HumanoidStateType)
		self.stateName = new.Name
		if new == Enum.HumanoidStateType.Dead then
			reportDied(self)
		end
	end))
	bag:add(humanoid.Died:Connect(function()
		reportDied(self)
	end))
	bag:add(model.AncestryChanged:Connect(function()
		if not self.dead and not model:IsDescendantOf(game) then
			reportDied(self)
		end
	end))
end

-- Wraps a parented character. Returns nil when the model has no Humanoid or root part.
function RobloxMover.new(model: Model, options: Options): Mover?
	local humanoidChild = model:FindFirstChildOfClass("Humanoid")
	local rootChild = model:FindFirstChild("HumanoidRootPart")
	if not humanoidChild or not humanoidChild:IsA("Humanoid") or not rootChild or not rootChild:IsA("BasePart") then
		return nil
	end
	local humanoid: Humanoid = humanoidChild
	local root: BasePart = rootChild
	local clock = options.clock or os.clock
	local self = setmetatable({
		model = model,
		humanoid = humanoid,
		root = root,
		bag = options.bag:child(`body:{model.Name}`),
		clock = clock,
		walkSpeed = options.walkSpeed or humanoid.WalkSpeed,
		analog = options.analogViaWalkSpeed ~= false,
		excludes = options.excludes,
		onDied = options.onDied,
		dead = false,
		diedReported = false,
		moveToFinished = false,
		stateName = "Running",
		lastSpeedWrite = -math.huge,
		lastOwnerCheck = clock(),
		facingHeld = false,
		attachment = nil,
		align = nil,
		lastPosition = root.Position,
		lastYaw = NavMath.yawOf(root.CFrame.LookVector),
	}, RobloxMover)
	pcall(function()
		humanoid.WalkSpeed = self.walkSpeed
	end)
	createAlign(self)
	connect(self)
	return self
end

local function deadState(self: Mover): BodyState
	return {
		position = self.lastPosition,
		velocity = Vector3.zero,
		onGround = false,
		state = "Dead",
		walkSpeed = self.walkSpeed,
		yaw = self.lastYaw,
		moveToFinished = false,
	}
end

-- Ownership re-assert (every OWNERSHIP_PERIOD): a body a client owns lags and could be hijacked.
local function reassertOwnership(self: Mover, now: number)
	if now - self.lastOwnerCheck < RobloxMover.OWNERSHIP_PERIOD then
		return
	end
	self.lastOwnerCheck = now
	pcall(function()
		local root = self.root
		if root:GetNetworkOwner() ~= nil then
			root:SetNetworkOwner(nil)
		end
	end)
end

local function readLive(self: Mover): BodyState
	local root = self.root
	local humanoid = self.humanoid
	if self.model.Parent == nil or humanoid.Health <= 0 then
		return deadState(self)
	end
	local position = root.Position
	local yaw = NavMath.yawOf(root.CFrame.LookVector)
	self.lastPosition = position
	self.lastYaw = yaw
	local name = humanoid:GetState().Name
	self.stateName = name
	local state: string = if STATE_NAMES[name] then name else "Other"
	return {
		position = position,
		velocity = root.AssemblyLinearVelocity,
		onGround = humanoid.FloorMaterial ~= Enum.Material.Air,
		state = state :: any, -- a BodyState state name (the union is checked above)
		walkSpeed = humanoid.WalkSpeed,
		yaw = yaw,
		moveToFinished = self.moveToFinished,
	}
end

function RobloxMover.read(self: Mover): BodyState
	if self.dead then
		return deadState(self)
	end
	reassertOwnership(self, self.clock())
	local ok, state = pcall(readLive, self)
	if not ok then
		return deadState(self)
	end
	return state
end

-- Throttled WalkSpeed write toward `target` (quantised to 1/SPEED_QUANTUM of the walk speed).
local function writeSpeed(self: Mover, target: number, now: number)
	local quantum = math.max(self.walkSpeed, 1e-3) / RobloxMover.SPEED_QUANTUM
	local quantised = math.floor(target / quantum + 0.5) * quantum
	if math.abs(quantised - self.humanoid.WalkSpeed) <= RobloxMover.SPEED_WRITE_THRESHOLD then
		return
	end
	if now - self.lastSpeedWrite < RobloxMover.SPEED_WRITE_GAP then
		return
	end
	self.lastSpeedWrite = now
	self.humanoid.WalkSpeed = quantised
end

local function releaseFacing(self: Mover)
	if not self.facingHeld then
		return
	end
	self.facingHeld = false
	local align = self.align
	if align then
		align.Enabled = false
	end
	self.humanoid.AutoRotate = true
end

local function holdFacing(self: Mover, yaw: number)
	local align = self.align
	if not align then
		return
	end
	if not self.facingHeld then
		local current = NavMath.yawOf(self.root.CFrame.LookVector)
		if math.abs(NavMath.wrap(yaw - current)) <= RobloxMover.FACING_DEADBAND then
			return
		end
		self.facingHeld = true
		self.humanoid.AutoRotate = false
		align.Enabled = true
	end
	align.CFrame = CFrame.Angles(0, yaw, 0)
end

local function applyLive(self: Mover, command: MoveCommand)
	local humanoid = self.humanoid
	local now = self.clock()
	self.moveToFinished = false
	if command.mode == "move" then
		local magnitude = math.clamp(command.magnitude, 0, 1)
		local dir = command.dir
		if dir.Magnitude > 1e-6 then
			dir = dir.Unit
		else
			dir = Vector3.zero
			magnitude = 0
		end
		if self.analog then
			humanoid:Move(dir, false)
			writeSpeed(self, self.walkSpeed * magnitude, now)
		else
			humanoid:Move(dir * magnitude, false)
		end
	elseif command.mode == "moveTo" then
		local point = command.moveToPoint
		if point then
			humanoid:MoveTo(point)
		else
			humanoid:Move(Vector3.zero, false)
		end
		if self.analog then
			writeSpeed(self, self.walkSpeed, now)
		end
	else
		humanoid:Move(Vector3.zero, false)
		if self.analog then
			writeSpeed(self, self.walkSpeed, now)
		end
	end
	if command.jump then
		humanoid.Jump = true
	end
	local facing = command.facingYaw
	if facing ~= nil and command.mode ~= "move" then
		holdFacing(self, facing)
	else
		releaseFacing(self)
	end
end

function RobloxMover.apply(self: Mover, command: MoveCommand)
	if self.dead then
		return
	end
	pcall(applyLive, self, command)
end

-- Spawn placement only: places the feet on `position`. Never called on a live, parented body.
function RobloxMover.teleport(self: Mover, position: Vector3)
	if self.dead then
		return
	end
	pcall(function()
		self.model:PivotTo(RobloxMover.placementCFrame(self.model, self.humanoid, self.root, position))
	end)
end

-- Free studs to the left and to the right of `forward` at +-60 degrees, each capped at PROBE_LENGTH.
function RobloxMover.probe(self: Mover, position: Vector3, forward: Vector3): (number?, number?)
	local length = RobloxMover.PROBE_LENGTH
	if self.dead then
		return length, length
	end
	local results = table.pack(pcall(function(): (number, number)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local list: { Instance } = { self.model }
		local excludes = self.excludes
		if excludes then
			for _, instance in excludes() do
				table.insert(list, instance)
			end
		end
		params.FilterDescendantsInstances = list
		local origin = position + Vector3.new(0, 1, 0)
		local yaw = NavMath.yawOf(forward)
		local function cast(angle: number): number
			local direction = NavMath.dirFromYaw(yaw + angle) * length
			local hit = workspace:Raycast(origin, direction, params)
			return if hit then hit.Distance else length
		end
		return cast(RobloxMover.PROBE_ANGLE), cast(-RobloxMover.PROBE_ANGLE)
	end))
	if results[1] ~= true then
		return length, length
	end
	return (results[2] :: any) :: number, (results[3] :: any) :: number
end

function RobloxMover.setWalkSpeed(self: Mover, speed: number)
	self.walkSpeed = math.max(0, speed)
	if self.dead then
		return
	end
	pcall(function()
		self.humanoid.WalkSpeed = self.walkSpeed
		self.lastSpeedWrite = self.clock()
	end)
end

-- Frees the body's connections and removes the model. A body is never reused.
function RobloxMover.destroy(self: Mover)
	self.dead = true
	self.bag:disconnectAll()
	pcall(function()
		self.model:Destroy()
	end)
end

-- Whether the body is still alive and in the world.
function RobloxMover.isAlive(self: Mover): boolean
	if self.dead then
		return false
	end
	local ok, alive = pcall(function()
		return self.model.Parent ~= nil and self.humanoid.Health > 0
	end)
	return ok and alive == true
end

-- The same object seen as the port (methods take `self: Mover`; the port takes `self: any`).
function RobloxMover.asPort(self: Mover): Ports.Mover
	return (self :: any) :: Ports.Mover
end

return RobloxMover

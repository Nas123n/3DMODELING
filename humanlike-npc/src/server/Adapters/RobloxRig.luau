--!strict
-- Builds NPC bodies and hands them out as movers, in the pinned acquire order: build -> name the model after
-- the username (Humanoid.DisplayName = display name) -> PivotTo the spawn -> ModelStreamingMode Atomic ->
-- parent to workspace -> unanchor the root -> SetNetworkOwner(nil) (retried up to 30 frames, else the body is
-- released with a warning) -> disable the humanoid states an NPC never needs -> wrap in RobloxMover (which
-- connects MoveToFinished, StateChanged, Died and AncestryChanged into the body's bag). Bodies come from
-- Players:CreateHumanoidModelFromDescriptionAsync with a HumanoidDescription filled from the AvatarSpec
-- (AssetTypeVerification.Always, inside pcall): an id-less description is the default install and yields a
-- real default R15 avatar; a description whose catalog ids fail is blacklisted for the run and retried with
-- every id at 0; only when the engine call itself fails, or with Config.UsePrimitiveRigs, does PrimitiveRig
-- stand in. The returned Animate and Health scripts are removed and an Animator is ensured on the server.
-- A pool of `poolSize` spare default R15 bodies is built ahead of demand in pool-bag threads and re-dressed on
-- acquire (ApplyDescriptionAsync); when re-dressing fails the spare is discarded and a fresh build is made.
-- A body is never reused under a new name: release destroys it, and a username a body wore is quarantined
-- for 10 minutes against any *other* identity (a respawn after reset or death keeps its name). With
-- Config.NameCheckOnline the username is checked against Players:GetUserIdFromNameAsync (at most 5 lookups/s,
-- 3-s timeout) and a name that resolves is rejected in the Names pool; two consecutive API failures turn the
-- check off for the run with one warning. It never decides who spawns, where, or when (Api and the service do).
-- requires: AvatarCatalog, Avatars, Connections, Names (types), Ports (types), PrimitiveRig, RobloxMover, Types (types)

local Players = game:GetService("Players")

local Connections = require(script.Parent.Connections)
local Ports = require(script.Parent.Parent.Ports)
local Types = require(script.Parent.Parent.Types)
local AvatarCatalog = require(script.Parent.Parent.Identity.AvatarCatalog)
local Avatars = require(script.Parent.Parent.Identity.Avatars)
local Names = require(script.Parent.Parent.Identity.Names)
local PrimitiveRig = require(script.Parent.Parent.Identity.PrimitiveRig)
local RobloxMover = require(script.Parent.RobloxMover)

type Bag = Connections.Bag
type Identity = Types.Identity
type AvatarSpec = Types.AvatarSpec
type Mover = RobloxMover.Mover

local RobloxRig = {}
RobloxRig.__index = RobloxRig

export type Options = {
	bag: Bag, -- the pool bag: build threads, ownership retries and every body bag live under it
	poolSize: number?, -- Config.RigPoolSize, default 2; 0 disables pre-warming
	primitive: boolean?, -- Config.UsePrimitiveRigs: always build block rigs
	nameCheckOnline: boolean?, -- Config.NameCheckOnline, default true
	names: Names.Pool?, -- the service's name pool, for `reject` on a name that resolves to a real account
	canClimb: boolean?, -- Config.CanClimb: keeps the Climbing state enabled
	analogViaWalkSpeed: boolean?, -- Config.AnalogViaWalkSpeed
	quarantineSeconds: number?, -- Config.NameQuarantineSeconds, default 600
	clock: (() -> number)?, -- default os.clock
	excludes: (() -> { Instance })?, -- every character the movers' probe raycasts ignore
	onDied: ((npcId: string) -> ())?, -- Api -> service:onDied(id, now)
}

type Body = {
	npcId: string,
	username: string,
	model: Model,
	mover: Mover,
}

export type Stats = {
	built: number,
	pooled: number,
	primitive: number,
	failedBuilds: number,
	blacklisted: number,
	rejectedNames: number,
	ownershipFailures: number,
	spares: number,
	live: number,
}

export type Rig = typeof(setmetatable(
	{} :: {
		bag: Bag,
		poolSize: number,
		primitive: boolean,
		nameCheckOnline: boolean,
		names: Names.Pool?,
		canClimb: boolean,
		analog: boolean,
		quarantineSeconds: number,
		clock: () -> number,
		excludes: (() -> { Instance })?,
		onDied: ((npcId: string) -> ())?,
		bodies: { [string]: Body },
		order: { string },
		spares: { Model },
		building: number,
		blacklist: { [string]: boolean },
		wornBy: { [string]: string }, -- lowercase username -> npc id that wore it
		quarantine: { [string]: number }, -- lowercase username -> release time
		lookups: { number }, -- times of recent name lookups (rate limit)
		checkFailures: number,
		checkDisabled: boolean,
		warnedStreaming: boolean,
		warnedBuild: boolean,
		stats: Stats,
		destroyed: boolean,
	},
	RobloxRig
))

RobloxRig.OWNERSHIP_FRAMES = 30
RobloxRig.LOOKUPS_PER_SECOND = 5
RobloxRig.LOOKUP_TIMEOUT = 3

-- States an NPC never enters (Climbing stays when the agent may climb).
local DISABLED_STATES: { Enum.HumanoidStateType } = {
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.GettingUp,
	Enum.HumanoidStateType.PlatformStanding,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.StrafingNoPhysics,
	Enum.HumanoidStateType.RunningNoPhysics,
	Enum.HumanoidStateType.Physics,
}

local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

local function lower(name: string): string
	return string.lower(name)
end

function RobloxRig.new(options: Options): Rig
	local self = setmetatable({
		bag = options.bag,
		poolSize = math.max(0, math.floor(options.poolSize or 2)),
		primitive = options.primitive == true,
		nameCheckOnline = options.nameCheckOnline ~= false,
		names = options.names,
		canClimb = options.canClimb == true,
		analog = options.analogViaWalkSpeed ~= false,
		quarantineSeconds = options.quarantineSeconds or 600,
		clock = options.clock or os.clock,
		excludes = options.excludes,
		onDied = options.onDied,
		bodies = {},
		order = {},
		spares = {},
		building = 0,
		blacklist = {},
		wornBy = {},
		quarantine = {},
		lookups = {},
		checkFailures = 0,
		checkDisabled = false,
		warnedStreaming = false,
		warnedBuild = false,
		stats = {
			built = 0,
			pooled = 0,
			primitive = 0,
			failedBuilds = 0,
			blacklisted = 0,
			rejectedNames = 0,
			ownershipFailures = 0,
			spares = 0,
			live = 0,
		},
		destroyed = false,
	}, RobloxRig)
	if self.poolSize > 0 and not self.primitive then
		self:prewarm()
	end
	return self
end

-- The catalog ids of a spec as one key (for the run's blacklist of id sets that fail to load).
function RobloxRig.idKey(spec: AvatarSpec): string
	local hats = table.clone(spec.hatIds)
	table.sort(hats)
	return `{spec.shirtId or 0}|{spec.pantsId or 0}|{spec.faceId or 0}|{spec.hairId or 0}|{table.concat(hats, ",")}`
end

-- A HumanoidDescription for a spec: scales, the six body colours, and only the ids that are not 0.
function RobloxRig.describe(spec: AvatarSpec): HumanoidDescription
	local desc = Instance.new("HumanoidDescription")
	local scale = spec.scale
	desc.HeightScale = scale.height
	desc.WidthScale = scale.width
	desc.DepthScale = scale.depth
	desc.HeadScale = scale.head
	desc.ProportionScale = scale.proportion
	desc.BodyTypeScale = scale.bodyType
	local colors = spec.bodyColors
	for _, slot in AvatarCatalog.BODY_COLOR_SLOTS do
		local color = colors[slot]
		if color then
			(desc :: any)[slot] = color
		end
	end
	if (spec.shirtId or 0) ~= 0 then
		desc.Shirt = spec.shirtId :: number
	end
	if (spec.pantsId or 0) ~= 0 then
		desc.Pants = spec.pantsId :: number
	end
	if (spec.faceId or 0) ~= 0 then
		desc.Face = spec.faceId :: number
	end
	if (spec.hairId or 0) ~= 0 then
		desc.HairAccessory = tostring(spec.hairId)
	end
	local hats: { string } = {}
	for _, id in spec.hatIds do
		if id ~= 0 then
			table.insert(hats, tostring(id))
		end
	end
	if #hats > 0 then
		desc.HatAccessory = table.concat(hats, ",")
	end
	return desc
end

local function rigTypeOf(spec: AvatarSpec): Enum.HumanoidRigType
	return if spec.rig == "R6" then Enum.HumanoidRigType.R6 else Enum.HumanoidRigType.R15
end

-- The engine call, by its Async name first and the older name when the Async one is not a member.
local function createModel(desc: HumanoidDescription, rigType: Enum.HumanoidRigType): (Model?, string?)
	local players: any = Players
	local results = table.pack(pcall(function()
		return players:CreateHumanoidModelFromDescriptionAsync(desc, rigType, Enum.AssetTypeVerification.Always)
	end))
	if results[1] == true and typeof(results[2]) == "Instance" then
		return results[2] :: Model, nil
	end
	local err = tostring(results[2])
	if string.find(err, "valid member", 1, true) then
		local again = table.pack(pcall(function()
			return Players:CreateHumanoidModelFromDescription(desc, rigType, Enum.AssetTypeVerification.Always)
		end))
		if again[1] == true and typeof(again[2]) == "Instance" then
			return again[2] :: Model, nil
		end
		err = tostring(again[2])
	end
	return nil, err
end

-- Re-dresses a spare (ApplyDescriptionAsync, older name as a fallback). False when the engine refused.
local function applyDescription(humanoid: Humanoid, desc: HumanoidDescription): boolean
	local target: any = humanoid
	local ok, err = try(function()
		target:ApplyDescriptionAsync(desc, Enum.AssetTypeVerification.Always)
	end)
	if ok then
		return true
	end
	if string.find(tostring(err), "valid member", 1, true) then
		local again = try(function()
			humanoid:ApplyDescription(desc, Enum.AssetTypeVerification.Always)
		end)
		return again
	end
	return false
end

-- What every engine-built model gets: no Animate (the client animator drives every character without one),
-- no Health script, and an Animator created on the server.
local function tidy(model: Model)
	pcall(function()
		local animate = model:FindFirstChild("Animate")
		if animate then
			animate:Destroy()
		end
		local health = model:FindFirstChild("Health")
		if health then
			health:Destroy()
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid:IsA("Humanoid") and not humanoid:FindFirstChildOfClass("Animator") then
			local animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
	end)
end

local function buildPrimitive(self: Rig, spec: AvatarSpec, name: string): Model?
	local ok, model = pcall(function(): Model
		local built = PrimitiveRig.build(spec, name)
		return built
	end)
	if not ok then
		return nil
	end
	self.stats.primitive += 1
	return model
end

-- A fresh body for a spec through the engine, with the id-set blacklist and the ids-0 retry; nil when the
-- engine call itself failed with an id-less description.
local function buildFromEngine(self: Rig, spec: AvatarSpec): Model?
	local key = RobloxRig.idKey(spec)
	local candidate = spec
	if self.blacklist[key] and not Avatars.isIdless(spec) then
		candidate = Avatars.withoutIds(spec)
	end
	for _ = 1, 2 do
		local model, err = createModel(RobloxRig.describe(candidate), rigTypeOf(candidate))
		if model then
			tidy(model)
			self.stats.built += 1
			return model
		end
		self.stats.failedBuilds += 1
		if Avatars.isIdless(candidate) then
			if not self.warnedBuild then
				self.warnedBuild = true
				warn(
					`[HumanlikeNpc] CreateHumanoidModelFromDescriptionAsync failed ({tostring(err)}); block rigs stand in`
				)
			end
			return nil
		end
		if not self.blacklist[key] then
			self.blacklist[key] = true
			self.stats.blacklisted += 1
			warn(`[HumanlikeNpc] avatar id set {key} failed to load ({tostring(err)}); retrying with default avatar`)
		end
		candidate = Avatars.withoutIds(candidate)
	end
	return nil
end

-- A spare default R15 body for the pool (unparented, undressed, unnamed).
local function buildSpare(self: Rig): Model?
	local desc = Instance.new("HumanoidDescription")
	local model = createModel(desc, Enum.HumanoidRigType.R15)
	if model then
		tidy(model)
		self.stats.built += 1
	end
	return model
end

-- Tops the pool up to poolSize in pool-bag threads.
function RobloxRig.prewarm(self: Rig)
	if self.destroyed or self.primitive then
		return
	end
	local bag = self.bag
	while #self.spares + self.building < self.poolSize do
		self.building += 1
		local thread = task.spawn(function()
			local model = buildSpare(self)
			self.building -= 1
			bag:remove(coroutine.running())
			if self.destroyed then
				if model then
					model:Destroy()
				end
				return
			end
			if model then
				table.insert(self.spares, model)
				self.stats.spares = #self.spares
			end
		end)
		if coroutine.status(thread) ~= "dead" then
			bag:add(thread)
		end
	end
end

-- A pooled R15 body re-dressed for the spec, or nil (the spare is discarded when re-dressing fails).
local function takeSpare(self: Rig, spec: AvatarSpec): Model?
	if spec.rig == "R6" or spec.primitive then
		return nil
	end
	local model = table.remove(self.spares)
	self.stats.spares = #self.spares
	if not model then
		return nil
	end
	local key = RobloxRig.idKey(spec)
	local candidate = if self.blacklist[key] then Avatars.withoutIds(spec) else spec
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid:IsA("Humanoid") then
		for _ = 1, 2 do
			if applyDescription(humanoid, RobloxRig.describe(candidate)) then
				self.stats.pooled += 1
				return model
			end
			if Avatars.isIdless(candidate) then
				break
			end
			if not self.blacklist[key] then
				self.blacklist[key] = true
				self.stats.blacklisted += 1
			end
			candidate = Avatars.withoutIds(candidate)
		end
	end
	pcall(function()
		model:Destroy()
	end)
	return nil
end

local function buildBody(self: Rig, spec: AvatarSpec, name: string): Model?
	if self.primitive or spec.primitive then
		return buildPrimitive(self, spec, name)
	end
	local spare = takeSpare(self, spec)
	if spare then
		self:prewarm()
		return spare
	end
	local built = buildFromEngine(self, spec)
	if built then
		return built
	end
	return buildPrimitive(self, spec, name)
end

-- Online impersonation check. True when the name may be used (or the check is off); a name that resolves is
-- rejected in the pool. Yields for the rate limit and the lookup.
function RobloxRig.nameAvailable(self: Rig, username: string): boolean
	if not self.nameCheckOnline or self.checkDisabled then
		return true
	end
	local now = self.clock()
	local lookups = self.lookups
	while #lookups > 0 and now - lookups[1] > 1 do
		table.remove(lookups, 1)
	end
	if #lookups >= RobloxRig.LOOKUPS_PER_SECOND then
		task.wait(math.max(0.05, 1 - (now - lookups[1])))
		now = self.clock()
		while #lookups > 0 and now - lookups[1] > 1 do
			table.remove(lookups, 1)
		end
	end
	table.insert(lookups, now)
	local done, resolved, failed = false, false, false
	task.spawn(function()
		local results = table.pack(pcall(function()
			return Players:GetUserIdFromNameAsync(username)
		end))
		if results[1] == true then
			resolved = type(results[2]) == "number" and results[2] > 0
		else
			local err = string.lower(tostring(results[2]))
			-- An unknown user is the good outcome, not an API failure.
			if not (string.find(err, "unknown", 1, true) or string.find(err, "not found", 1, true)) then
				failed = true
			end
		end
		done = true
	end)
	local deadline = self.clock() + RobloxRig.LOOKUP_TIMEOUT
	while not done and self.clock() < deadline do
		task.wait()
	end
	if not done or failed then
		self.checkFailures += 1
		if self.checkFailures >= 2 then
			self.checkDisabled = true
			warn("[HumanlikeNpc] GetUserIdFromNameAsync failed twice in a row; usernames are no longer checked online")
		end
		return true
	end
	self.checkFailures = 0
	if resolved then
		self.stats.rejectedNames += 1
		local names = self.names
		if names then
			names:reject(username)
		end
		warn(`[HumanlikeNpc] username "{username}" belongs to a real account; rejected`)
		return false
	end
	return true
end

-- Whether a name may be worn by this identity now: not in quarantine for another identity.
function RobloxRig.nameQuarantined(self: Rig, username: string, npcId: string): boolean
	local key = lower(username)
	local until_ = self.quarantine[key]
	if until_ == nil then
		return false
	end
	if self.clock() >= until_ then
		self.quarantine[key] = nil
		return false
	end
	return self.wornBy[key] ~= npcId
end

-- Waits up to OWNERSHIP_FRAMES frames for the root to accept server ownership. False when it never does.
local function takeOwnership(root: BasePart): boolean
	for _ = 1, RobloxRig.OWNERSHIP_FRAMES do
		local ok, taken = pcall(function()
			if root:CanSetNetworkOwnership() then
				root:SetNetworkOwner(nil)
				return true
			end
			return false
		end)
		if ok and taken == true then
			return true
		end
		task.wait()
	end
	return false
end

local function disableStates(self: Rig, humanoid: Humanoid)
	pcall(function()
		for _, state in DISABLED_STATES do
			humanoid:SetStateEnabled(state, false)
		end
		if not self.canClimb then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
		end
	end)
end

-- Builds and places a body for an identity (yields; called from Api's spawn thread or the presenter's
-- respawn thread, never inside a frame). Returns the mover, or nil and why: "nameTaken" (the name resolves
-- to a real account; Api draws another identity), "quarantined" (another identity wore it recently),
-- "buildFailed", "ownership" (server ownership never took; the body was released) or "destroyed".
function RobloxRig.acquire(
	self: Rig,
	identity: Identity,
	spec: AvatarSpec,
	position: Vector3,
	walkSpeed: number?
): (Ports.Mover?, string?)
	if self.destroyed then
		return nil, "destroyed"
	end
	local existing = self.bodies[identity.id]
	if existing then
		self:release(identity.id) -- a stale body under this id; never two bodies for one identity
	end
	if self:nameQuarantined(identity.username, identity.id) then
		return nil, "quarantined"
	end
	if not self:nameAvailable(identity.username) then
		return nil, "nameTaken"
	end
	local model = buildBody(self, spec, identity.username)
	if not model then
		return nil, "buildFailed"
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
		pcall(function()
			model:Destroy()
		end)
		return nil, "buildFailed"
	end
	local placed = try(function()
		-- The pinned order: name, place, streaming mode, parent, unanchor.
		model.Name = identity.username
		humanoid.DisplayName = identity.displayName
		model:PivotTo(RobloxMover.placementCFrame(model, humanoid, root, position))
		local streamed = pcall(function()
			model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		end)
		if not streamed and not self.warnedStreaming then
			self.warnedStreaming = true
			warn("[HumanlikeNpc] ModelStreamingMode.Atomic could not be set; bodies keep the default streaming mode")
		end
		model.Parent = workspace
		root.Anchored = false
	end)
	if not placed then
		pcall(function()
			model:Destroy()
		end)
		return nil, "buildFailed"
	end
	if not takeOwnership(root) then
		self.stats.ownershipFailures += 1
		warn(`[HumanlikeNpc] body "{identity.username}" never accepted server ownership; released`)
		pcall(function()
			model:Destroy()
		end)
		return nil, "ownership"
	end
	if self.destroyed then
		pcall(function()
			model:Destroy()
		end)
		return nil, "destroyed"
	end
	disableStates(self, humanoid)
	pcall(function()
		humanoid.BreakJointsOnDeath = false
		humanoid.AutoRotate = true
		if walkSpeed then
			humanoid.WalkSpeed = walkSpeed
		end
	end)
	local npcId = identity.id
	local onDied = self.onDied
	local mover = RobloxMover.new(model, {
		bag = self.bag,
		walkSpeed = walkSpeed,
		analogViaWalkSpeed = self.analog,
		excludes = self.excludes,
		clock = self.clock,
		onDied = if onDied
			then function()
				onDied(npcId)
			end
			else nil,
	})
	if not mover then
		pcall(function()
			model:Destroy()
		end)
		return nil, "buildFailed"
	end
	self.bodies[npcId] = { npcId = npcId, username = identity.username, model = model, mover = mover }
	table.insert(self.order, npcId)
	self.wornBy[lower(identity.username)] = npcId
	self.stats.live = #self.order
	return mover:asPort(), nil
end

-- Destroys the body of an NPC (leave, reset, despawn) and quarantines its name for other identities.
function RobloxRig.release(self: Rig, npcId: string)
	local body = self.bodies[npcId]
	if not body then
		return
	end
	self.bodies[npcId] = nil
	for i, id in self.order do
		if id == npcId then
			table.remove(self.order, i)
			break
		end
	end
	self.stats.live = #self.order
	self.quarantine[lower(body.username)] = self.clock() + self.quarantineSeconds
	body.mover:destroy()
end

function RobloxRig.characterOf(self: Rig, npcId: string): Model?
	local body = self.bodies[npcId]
	return if body then body.model else nil
end

function RobloxRig.moverOf(self: Rig, npcId: string): Ports.Mover?
	local body = self.bodies[npcId]
	return if body then body.mover:asPort() else nil
end

-- Server-only truth: whether a model is one of the live bodies (they carry no marker of their own).
function RobloxRig.isNpc(self: Rig, model: Instance): boolean
	for _, id in self.order do
		local body = self.bodies[id]
		if body and body.model == model then
			return true
		end
	end
	return false
end

-- The live bodies, in spawn order (for raycast filters and the debug overlay).
function RobloxRig.characters(self: Rig): { Model }
	local out: { Model } = {}
	for _, id in self.order do
		local body = self.bodies[id]
		if body then
			table.insert(out, body.model)
		end
	end
	return out
end

function RobloxRig.getStats(self: Rig): Stats
	local stats = table.clone(self.stats)
	stats.spares = #self.spares
	stats.live = #self.order
	return stats
end

-- Releases every body, destroys the spares and stops building.
function RobloxRig.destroy(self: Rig)
	self.destroyed = true
	for _, id in table.clone(self.order) do
		self:release(id)
	end
	for _, model in self.spares do
		pcall(function()
			model:Destroy()
		end)
	end
	self.spares = {}
	self.stats.spares = 0
end

return RobloxRig

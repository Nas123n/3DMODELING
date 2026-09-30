--!strict
-- Shared head look: inert unless ClientConfig.HeadLook == "shared" (the default is "off", because default Roblox
-- players' heads do not follow their camera, so a head tracker on some characters only would be a tell). In
-- "shared" mode every character with a Humanoid, players included and this client's own excluded, gets one
-- identical routine: the neck joint's Transform (an AnimationConstraint or a Motor6D; C0/C1 are never written) is
-- rotated toward the CamYaw/CamPitch attributes the server keeps on every character, lerped by HeadLookLerp and
-- clamped to HeadLookMaxDegrees, in PreSimulation and skipping frames the Animator throttled. This client also
-- publishes its own camera yaw/pitch relative to its character on the CharacterCam remote at 5 Hz. It is not an
-- NPC feature (nothing here distinguishes characters) and it idles when the server side is not running.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("HumanlikeNpcShared")
local ClientConfig = require(Shared:WaitForChild("ClientConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local config = ClientConfig.get()

if config.HeadLook ~= "shared" then
	return
end

local PUBLISH_INTERVAL = 0.2 -- 5 Hz
local MIN_DELTA_DEGREES = 0.25
local JOINT_RETRY = 1 -- seconds between joint lookups while a head is missing (streaming)

type Look = {
	model: Model,
	humanoid: Humanoid,
	animator: Animator?,
	joint: Instance?,
	jointCheckedAt: number,
	yaw: number,
	pitch: number,
	targetYaw: number,
	targetPitch: number,
	connections: { RBXScriptConnection },
}

local localPlayer = Players.LocalPlayer
local looks: { [Model]: Look } = {}
local maxAngle = math.rad(config.HeadLookMaxDegrees)
local lerp = config.HeadLookLerp
local camRemote: UnreliableRemoteEvent? = nil
local lastPublishAt = 0
local lastYaw = math.huge
local lastPitch = math.huge
local warned = false

local function warnOnce(message: string)
	if not warned then
		warned = true
		warn("[HumanlikeNpc head look] " .. message)
	end
end

local function onChild(parent: Instance, name: string, callback: (Instance) -> ())
	local existing = parent:FindFirstChild(name)
	if existing then
		callback(existing)
		return
	end
	local connection: RBXScriptConnection? = nil
	connection = parent.ChildAdded:Connect(function(child)
		if child.Name == name then
			if connection then
				connection:Disconnect()
			end
			callback(child)
		end
	end)
end

local function clampRadians(degrees: unknown): number
	if type(degrees) ~= "number" or degrees ~= degrees then
		return 0
	end
	return math.clamp(math.rad(degrees), -maxAngle, maxAngle)
end

local function readTargets(look: Look)
	look.targetYaw = clampRadians(look.model:GetAttribute(Remotes.CAM_ATTR_YAW))
	look.targetPitch = clampRadians(look.model:GetAttribute(Remotes.CAM_ATTR_PITCH))
end

local function findJoint(model: Model): Instance?
	local head = model:FindFirstChild("Head")
	if head ~= nil then
		local joint = head:FindFirstChildWhichIsA("AnimationConstraint") or head:FindFirstChildWhichIsA("Motor6D")
		if joint ~= nil then
			return joint
		end
	end
	local torso = model:FindFirstChild("Torso") -- R6 keeps the Neck in the Torso
	if torso ~= nil then
		local neck = torso:FindFirstChild("Neck")
		if neck ~= nil and neck:IsA("Motor6D") then
			return neck
		end
	end
	return nil
end

local function detach(model: Model)
	local look = looks[model]
	if look == nil then
		return
	end
	looks[model] = nil
	for _, connection in look.connections do
		connection:Disconnect()
	end
end

local function attach(model: Model, humanoid: Humanoid)
	if looks[model] ~= nil then
		return
	end
	local look: Look = {
		model = model,
		humanoid = humanoid,
		animator = humanoid:FindFirstChildOfClass("Animator"),
		joint = findJoint(model),
		jointCheckedAt = os.clock(),
		yaw = 0,
		pitch = 0,
		targetYaw = 0,
		targetPitch = 0,
		connections = {},
	}
	readTargets(look)
	looks[model] = look
	table.insert(
		look.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				detach(model)
			end
		end)
	)
	table.insert(
		look.connections,
		humanoid.AncestryChanged:Connect(function()
			if humanoid.Parent ~= model then
				detach(model)
			end
		end)
	)
	table.insert(
		look.connections,
		model:GetAttributeChangedSignal(Remotes.CAM_ATTR_YAW):Connect(function()
			readTargets(look)
		end)
	)
	table.insert(
		look.connections,
		model:GetAttributeChangedSignal(Remotes.CAM_ATTR_PITCH):Connect(function()
			readTargets(look)
		end)
	)
end

local function consider(instance: Instance)
	if not instance:IsA("Humanoid") then
		return
	end
	local parent = instance.Parent
	if parent ~= nil and parent:IsA("Model") and parent:IsDescendantOf(workspace) then
		attach(parent, instance)
	end
end

local function wrapAngle(angle: number): number
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

-- This client's own camera, relative to its character, published on the CharacterCam remote at 5 Hz.
local function publish(now: number)
	local remote = camRemote
	if remote == nil or now - lastPublishAt < PUBLISH_INTERVAL then
		return
	end
	local character = localPlayer.Character
	local camera = workspace.CurrentCamera
	if character == nil or camera == nil then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local look = camera.CFrame.LookVector
	local forward = root.CFrame.LookVector
	local yaw = math.deg(wrapAngle(math.atan2(-look.X, -look.Z) - math.atan2(-forward.X, -forward.Z)))
	local pitch = math.deg(math.asin(math.clamp(look.Y, -1, 1)))
	yaw = math.clamp(yaw, -config.HeadLookMaxDegrees, config.HeadLookMaxDegrees)
	pitch = math.clamp(pitch, -config.HeadLookMaxDegrees, config.HeadLookMaxDegrees)
	if math.abs(yaw - lastYaw) < MIN_DELTA_DEGREES and math.abs(pitch - lastPitch) < MIN_DELTA_DEGREES then
		return
	end
	lastPublishAt = now
	lastYaw = yaw
	lastPitch = pitch
	local ok = pcall(function()
		remote:FireServer(yaw, pitch)
	end)
	if not ok then
		warnOnce("could not publish the camera direction")
	end
end

-- Wiring

workspace.DescendantAdded:Connect(consider)
for _, instance in workspace:GetDescendants() do
	consider(instance)
end

RunService.Heartbeat:Connect(function()
	publish(os.clock())
end)

RunService.PreSimulation:Connect(function()
	local now = os.clock()
	local own = localPlayer.Character
	for model, look in looks do
		if model == own then
			continue
		end
		local joint = look.joint
		if joint == nil or joint.Parent == nil then
			if now - look.jointCheckedAt < JOINT_RETRY then
				continue
			end
			look.jointCheckedAt = now
			joint = findJoint(model)
			look.joint = joint
			if joint == nil then
				continue
			end
		end
		local animator = look.animator
		if animator ~= nil and animator.EvaluationThrottled then
			continue
		end
		look.yaw += (look.targetYaw - look.yaw) * lerp
		look.pitch += (look.targetPitch - look.pitch) * lerp
		if math.abs(look.yaw) < 1e-4 and math.abs(look.pitch) < 1e-4 then
			continue
		end
		local ok = pcall(function()
			local target = joint :: any
			target.Transform = CFrame.fromEulerAnglesYXZ(look.pitch, look.yaw, 0) * target.Transform
		end)
		if not ok then
			warnOnce("neck Transform is not writable on this rig; head look is off for it")
			look.joint = nil
			look.jointCheckedAt = math.huge
		end
	end
end)

onChild(ReplicatedStorage, Remotes.FOLDER, function(folder)
	onChild(folder, Remotes.CAM, function(remote)
		if remote:IsA("UnreliableRemoteEvent") then
			camRemote = remote
		end
	end)
end)

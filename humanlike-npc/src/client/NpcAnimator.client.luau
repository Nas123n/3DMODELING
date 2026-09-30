--!strict
-- Client-side animator for every character in the workspace that has a Humanoid, carries no `Animate` script and
-- is not tagged NpcIgnore, whichever character that is: it re-implements the R15 Animate script's behaviour
-- (idle variants re-rolled 1/1/9 at the clip end, walk/run cross-fade, jump hold then fall, climb, sit, the seven
-- default emotes) with AnimLogic choosing the state each frame from the polled root velocity and the replicated
-- Humanoid state, and AnimationTracks loaded through the character's Animator from AnimSets. A character that
-- gains an `Animate` script, gets the tag or leaves the workspace is released at once. It never touches a
-- character that has its own Animate script (every player's does), never reads Players to decide, never
-- replicates anything, and it idles when there is nothing to animate.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("HumanlikeNpcShared")
local AnimLogic = require(Shared:WaitForChild("AnimLogic"))
local AnimSets = require(Shared:WaitForChild("AnimSets"))
local ClientConfig = require(Shared:WaitForChild("ClientConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

type Pack = AnimSets.Pack
type Selection = AnimLogic.Selection

local config = ClientConfig.get()

local IGNORE_TAG = "NpcIgnore"
local ANIMATE_NAME = "Animate"
local ANIMATOR_WAIT = 1 -- seconds to wait for the server-created Animator before making a local one
local EMOTE_LOAD_GRACE = 3 -- seconds an emote track may stay at Length 0 before it counts as unloadable
local R6_WARP = 12.8 / 14.5 -- the R6 Animate script warps its walk by speed / 14.5 instead of speed · 1.25 / 16
local IDLE_KEYS = { "idle1", "idle2", "idle3" }
-- States in which the engine stops every animation.
local STOP_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.GettingUp] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
}

type Rig = {
	model: Model,
	humanoid: Humanoid,
	animator: Animator?,
	root: BasePart?,
	pack: Pack,
	isR6: boolean,
	seed: number,
	rollIndex: number,
	idleIndex: number,
	animations: { Animation },
	tracks: { [string]: AnimationTrack },
	current: string?, -- key of the main clip playing ("idle1", "walk", "jump", "emote", ...)
	mainTrack: AnimationTrack?,
	runTrack: AnimationTrack?,
	loopConnection: RBXScriptConnection?,
	lastPlayback: number,
	lastWalkWeight: number,
	state: string,
	changedAt: number,
	jumpedAt: number?,
	lastHumanoidState: Enum.HumanoidStateType?,
	halted: boolean,
	emote: string?,
	emoteTrack: AnimationTrack?,
	emoteUntil: number?,
	emoteStartedAt: number?,
	fallbackPose: string?, -- "wave" | "point" when the emote clip could not load
	connections: { RBXScriptConnection },
}

local rigs: { [Model]: Rig } = {}
local warned = false

local function warnOnce(message: string)
	if not warned then
		warned = true
		warn("[HumanlikeNpc animator] " .. message)
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

local function eligible(model: Model): boolean
	if model:FindFirstChild(ANIMATE_NAME) ~= nil then
		return false
	end
	if CollectionService:HasTag(model, IGNORE_TAG) then
		return false
	end
	return model:IsDescendantOf(workspace)
end

-- Tracks

local function loadTrack(rig: Rig, key: string, id: number): AnimationTrack?
	local existing: AnimationTrack? = rig.tracks[key]
	if existing ~= nil then
		return existing
	end
	local animator = rig.animator
	if animator == nil or id <= 0 then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = key
	animation.AnimationId = "rbxassetid://" .. tostring(id)
	table.insert(rig.animations, animation)
	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		warnOnce(`LoadAnimation failed for {key}: {tostring(result)}`)
		return nil
	end
	local track: AnimationTrack = result
	track.Priority = Enum.AnimationPriority.Core
	rig.tracks[key] = track
	return track
end

local function stopMain(rig: Rig, fade: number)
	local loop = rig.loopConnection
	if loop ~= nil then
		loop:Disconnect()
		rig.loopConnection = nil
	end
	local main = rig.mainTrack
	if main ~= nil then
		main:Stop(fade)
	end
	local run = rig.runTrack
	if run ~= nil then
		run:Stop(fade)
	end
	rig.mainTrack = nil
	rig.runTrack = nil
	rig.current = nil
	rig.lastPlayback = -1
	rig.lastWalkWeight = -1
end

-- Switches the main clip like the engine's switchToAnim: nothing happens when the same clip is already playing.
local function playMain(rig: Rig, key: string, id: number, fade: number): AnimationTrack?
	if rig.current == key then
		return rig.mainTrack
	end
	stopMain(rig, fade)
	rig.current = key
	local track = loadTrack(rig, key, id)
	if track == nil then
		return nil
	end
	rig.mainTrack = track
	track:Play(fade)
	return track
end

local function playIdle(rig: Rig, fade: number)
	local index = rig.idleIndex
	local key = IDLE_KEYS[index]
	local track = playMain(rig, key, AnimSets.idleId(rig.pack, index), fade)
	if track ~= nil and rig.loopConnection == nil then
		-- The idle clips loop; each loop end is the engine's "End" keyframe, where the variant is re-rolled.
		rig.loopConnection = track.DidLoop:Connect(function()
			if rig.current ~= key then
				return
			end
			local pick = AnimLogic.idleRoll(rig.seed, rig.rollIndex, rig.pack.idleWeights)
			rig.rollIndex += 1
			if pick ~= rig.idleIndex then
				rig.idleIndex = pick
				playIdle(rig, config.AnimFadeTime)
			end
		end)
	end
end

local function applyWalk(rig: Rig, selection: Selection)
	local walk = playMain(rig, "walk", rig.pack.walk, selection.fade)
	if walk == nil then
		return
	end
	local run = rig.runTrack
	if run == nil then
		run = loadTrack(rig, "run", rig.pack.run)
		if run ~= nil then
			rig.runTrack = run
			run:Play(selection.fade)
		end
	end
	local playback = if rig.isR6 then selection.playbackSpeed * R6_WARP else selection.playbackSpeed
	if math.abs(playback - rig.lastPlayback) < 1e-4 and math.abs(selection.walkWeight - rig.lastWalkWeight) < 1e-4 then
		return
	end
	rig.lastPlayback = playback
	rig.lastWalkWeight = selection.walkWeight
	walk:AdjustWeight(math.max(selection.walkWeight, 0.0001))
	walk:AdjustSpeed(playback)
	if run ~= nil then
		run:AdjustWeight(math.max(selection.runWeight, 0.0001))
		run:AdjustSpeed(playback)
	end
end

-- Emotes

local function stopEmote(rig: Rig, fade: number)
	local track = rig.emoteTrack
	rig.emoteTrack = nil
	rig.emote = nil
	rig.emoteUntil = nil
	rig.emoteStartedAt = nil
	rig.fallbackPose = nil
	if track ~= nil then
		track:Stop(fade)
	end
	if rig.current == "emote" then
		rig.current = nil
	end
end

local function startEmote(rig: Rig, name: string, cutAfter: number?, now: number)
	local emote = AnimSets.EMOTES[name]
	if emote == nil then
		return
	end
	if rig.state ~= "idle" then
		return -- the engine only plays emotes while standing
	end
	stopEmote(rig, AnimLogic.EMOTE_FADE)
	local id = AnimSets.emoteId(emote, AnimLogic.unit(rig.seed, rig.rollIndex))
	rig.rollIndex += 1
	rig.emote = name
	rig.emoteStartedAt = now
	if cutAfter ~= nil and cutAfter > 0 then
		rig.emoteUntil = now + cutAfter
	elseif not emote.loops then
		rig.emoteUntil = now + emote.duration + 1 -- safety net should Stopped never fire
	end
	local track = loadTrack(rig, "emote:" .. tostring(id), id)
	if track == nil then
		if name == "wave" or name == "point" then
			rig.fallbackPose = name
			if rig.emoteUntil == nil then
				rig.emoteUntil = now + emote.duration
			end
		else
			stopEmote(rig, 0)
		end
		return
	end
	rig.emoteTrack = track
	if not emote.loops then
		track.Stopped:Once(function()
			if rig.emoteTrack == track then
				stopEmote(rig, config.AnimFadeTime)
			end
		end)
	end
end

-- An emote whose asset never loaded: wave and point degrade to a joint pose, everything else ends (C-8).
local function checkEmoteLoaded(rig: Rig, now: number)
	local track = rig.emoteTrack
	local startedAt = rig.emoteStartedAt
	if track == nil or startedAt == nil or now - startedAt < EMOTE_LOAD_GRACE or track.Length > 0 then
		return
	end
	local name = rig.emote
	local emote = if name ~= nil then AnimSets.EMOTES[name] else nil
	rig.emoteTrack = nil
	track:Stop(0)
	if emote ~= nil and (name == "wave" or name == "point") then
		rig.fallbackPose = name
		if rig.emoteUntil == nil then
			rig.emoteUntil = startedAt + emote.duration
		end
	else
		stopEmote(rig, config.AnimFadeTime)
	end
end

local function fallbackJoint(rig: Rig): Instance?
	local arm = rig.model:FindFirstChild("RightUpperArm")
	if arm ~= nil then
		return arm:FindFirstChildWhichIsA("AnimationConstraint") or arm:FindFirstChildWhichIsA("Motor6D")
	end
	local torso = rig.model:FindFirstChild("Torso")
	if torso ~= nil then
		local shoulder = torso:FindFirstChild("Right Shoulder")
		if shoulder ~= nil and shoulder:IsA("Motor6D") then
			return shoulder
		end
	end
	return nil
end

-- Per frame

local function readRoot(rig: Rig): BasePart?
	local root = rig.root
	if root ~= nil and root.Parent == rig.model then
		return root
	end
	local candidate = rig.humanoid.RootPart or rig.model:FindFirstChild("HumanoidRootPart")
	if candidate ~= nil and candidate:IsA("BasePart") then
		rig.root = candidate
		return candidate
	end
	rig.root = nil
	return nil
end

local function stopAll(rig: Rig, fade: number)
	stopEmote(rig, fade)
	stopMain(rig, fade)
end

local function step(rig: Rig, now: number)
	local humanoid = rig.humanoid
	local humanoidState = humanoid:GetState()
	if humanoidState ~= rig.lastHumanoidState then
		if humanoidState == Enum.HumanoidStateType.Jumping then
			rig.jumpedAt = now
		end
		rig.lastHumanoidState = humanoidState
	end
	if STOP_STATES[humanoidState] then
		if not rig.halted then
			rig.halted = true
			stopAll(rig, AnimLogic.JUMP_FADE)
			rig.state = ""
		end
		return
	end
	rig.halted = false
	local root = readRoot(rig)
	if root == nil then
		return -- parts streamed out: keep whatever is playing
	end
	local velocity = root.AssemblyLinearVelocity
	local speed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	local heightScale = if rig.isR6 or not humanoid.AutomaticScalingEnabled then 1 else humanoid.HipHeight / 2
	if heightScale < 0.1 then
		heightScale = 1
	end
	local airborne = humanoidState == Enum.HumanoidStateType.Jumping or humanoidState == Enum.HumanoidStateType.Freefall
	local seated = humanoidState == Enum.HumanoidStateType.Seated or humanoid.Sit
	local climbing = humanoidState == Enum.HumanoidStateType.Climbing

	if rig.emote ~= nil then
		local cutAt = rig.emoteUntil
		local moving = speed > AnimLogic.MOVE_THRESHOLD * heightScale
		if airborne or seated or climbing or moving or (cutAt ~= nil and now >= cutAt) then
			stopEmote(rig, config.AnimFadeTime) -- moving cancels an emote, as it does in the engine
		else
			checkEmoteLoaded(rig, now)
		end
	end

	local selection = AnimLogic.select({
		onGround = not airborne,
		speed = speed,
		verticalSpeed = velocity.Y,
		heightScale = heightScale,
		seated = seated,
		climbing = climbing,
		emote = rig.emote,
		now = now,
		lastState = rig.state,
		lastChangeAt = rig.changedAt,
		jumpedAt = rig.jumpedAt,
	})
	local state = selection.state
	if state ~= rig.state then
		rig.state = state
		rig.changedAt = now
	end

	if state == "idle" then
		playIdle(rig, selection.fade)
	elseif state == "walk" then
		applyWalk(rig, selection)
	elseif state == "jump" then
		playMain(rig, "jump", rig.pack.jump, selection.fade)
	elseif state == "fall" then
		playMain(rig, "fall", rig.pack.fall, selection.fade)
	elseif state == "climb" then
		local track = playMain(rig, "climb", rig.pack.climb, selection.fade)
		if track ~= nil and math.abs(selection.playbackSpeed - rig.lastPlayback) > 1e-4 then
			rig.lastPlayback = selection.playbackSpeed
			track:AdjustSpeed(selection.playbackSpeed)
		end
	elseif state == "sit" then
		playMain(rig, "sit", rig.pack.sit, selection.fade)
	elseif state == "emote" and rig.current ~= "emote" then
		stopMain(rig, selection.fade)
		rig.current = "emote"
		local track = rig.emoteTrack
		if track ~= nil then
			track:Play(selection.fade)
		end
	end
end

-- Attach / detach

local function detach(model: Model)
	local rig = rigs[model]
	if rig == nil then
		return
	end
	rigs[model] = nil
	for _, connection in rig.connections do
		connection:Disconnect()
	end
	stopAll(rig, 0)
	for _, track in rig.tracks do
		pcall(function()
			track:Destroy()
		end)
	end
	for _, animation in rig.animations do
		animation:Destroy()
	end
end

local function animatorFor(humanoid: Humanoid): Animator?
	local existing = humanoid:FindFirstChildOfClass("Animator")
	if existing ~= nil then
		return existing
	end
	local waited = humanoid:WaitForChild("Animator", ANIMATOR_WAIT)
	if waited ~= nil and waited:IsA("Animator") then
		return waited
	end
	if humanoid.Parent == nil then
		return nil
	end
	local created = Instance.new("Animator")
	created.Parent = humanoid
	return created
end

-- May yield (waiting for the Animator); the eligibility is re-checked afterwards.
local function attach(model: Model, humanoid: Humanoid)
	if rigs[model] ~= nil then
		return
	end
	local animator = animatorFor(humanoid)
	if rigs[model] ~= nil or humanoid.Parent ~= model or not eligible(model) then
		return
	end
	local isR6 = humanoid.RigType == Enum.HumanoidRigType.R6
	local pack: Pack = if isR6 then AnimSets.R6 else AnimSets.resolve(AnimSets.packFor(model.Name))
	local seed = AnimLogic.seedFor(model.Name)
	local rig: Rig = {
		model = model,
		humanoid = humanoid,
		animator = animator,
		root = nil,
		pack = pack,
		isR6 = isR6,
		seed = seed,
		rollIndex = 1,
		idleIndex = AnimLogic.idleRoll(seed, 0, pack.idleWeights),
		animations = {},
		tracks = {},
		current = nil,
		mainTrack = nil,
		runTrack = nil,
		loopConnection = nil,
		lastPlayback = -1,
		lastWalkWeight = -1,
		state = "",
		changedAt = os.clock(),
		jumpedAt = nil,
		lastHumanoidState = nil,
		halted = false,
		emote = nil,
		emoteTrack = nil,
		emoteUntil = nil,
		emoteStartedAt = nil,
		fallbackPose = nil,
		connections = {},
	}
	rigs[model] = rig
	table.insert(
		rig.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				detach(model)
			end
		end)
	)
	table.insert(
		rig.connections,
		model.ChildAdded:Connect(function(child)
			if child.Name == ANIMATE_NAME then
				detach(model)
			end
		end)
	)
	table.insert(
		rig.connections,
		humanoid.AncestryChanged:Connect(function()
			if humanoid.Parent ~= model then
				detach(model)
			end
		end)
	)
end

local function consider(instance: Instance)
	if not instance:IsA("Humanoid") then
		return
	end
	local humanoid: Humanoid = instance
	local parent = humanoid.Parent
	if parent == nil or not parent:IsA("Model") then
		return
	end
	local model: Model = parent
	-- Deferred so siblings replicated in the same batch (an Animate script) are present before the decision.
	task.defer(function()
		if rigs[model] == nil and humanoid.Parent == model and eligible(model) then
			attach(model, humanoid)
		end
	end)
end

local function onEmote(character: unknown, emoteName: unknown, cutAfter: unknown)
	if typeof(character) ~= "Instance" or not character:IsA("Model") or character.Parent == nil then
		return
	end
	local rig = rigs[character]
	if rig == nil then
		return
	end
	if emoteName == nil then
		stopEmote(rig, config.AnimFadeTime)
		return
	end
	if type(emoteName) ~= "string" then
		return
	end
	local cut: number? = if type(cutAfter) == "number" then cutAfter else nil
	startEmote(rig, emoteName, cut, os.clock())
end

-- Wiring

workspace.DescendantAdded:Connect(consider)
for _, instance in workspace:GetDescendants() do
	consider(instance)
end

CollectionService:GetInstanceAddedSignal(IGNORE_TAG):Connect(function(instance)
	if instance:IsA("Model") then
		detach(instance)
	end
end)

local function watchPlayer(player: Player)
	player.CharacterRemoving:Connect(detach)
end
Players.PlayerAdded:Connect(watchPlayer)
for _, player in Players:GetPlayers() do
	watchPlayer(player)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for model, rig in rigs do
		local ok, err = pcall(function(): string?
			step(rig, now)
			return nil
		end)
		if not ok then
			warnOnce(`animation step failed: {tostring(err)}`)
			detach(model)
		end
	end
end)

-- The pose fallback for wave/point runs where the engine's own Transform batch is applied.
RunService.PreSimulation:Connect(function()
	local now = os.clock()
	for _, rig in rigs do
		local pose = rig.fallbackPose
		if pose == nil then
			continue
		end
		local animator = rig.animator
		if animator ~= nil and animator.EvaluationThrottled then
			continue
		end
		local joint = fallbackJoint(rig)
		if joint == nil then
			continue
		end
		local rotation = if pose == "wave"
			then CFrame.Angles(0, 0, math.rad(150) + 0.3 * math.sin(now * 12))
			else CFrame.Angles(math.rad(90), 0, 0)
		local target = joint :: any
		target.Transform = rotation * target.Transform
	end
end)

onChild(ReplicatedStorage, Remotes.FOLDER, function(folder)
	onChild(folder, Remotes.EMOTE, function(remote)
		if remote:IsA("RemoteEvent") then
			remote.OnClientEvent:Connect(onEmote)
		end
	end)
end)

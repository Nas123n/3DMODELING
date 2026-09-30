--!strict
-- The Presenter port: how an NPC's chat, emotes, typing, camera, seating, leaving and resetting show up in
-- the world. `say` goes through RobloxChatSink; `emote`, `setTyping` fire the client remotes; `setCamera`
-- writes the neutral CamYaw/CamPitch attributes (degrees, at most 2 Hz, only in HeadLook "shared");
-- `seat` sits through Seat:Sit and stands through Humanoid.Sit = false. `leave` is the leave story: the body
-- stands still for u(0.5, 2) s and is then removed in one frame, like a disconnect (Api's destroyMover calls
-- `release`, which lets a pending leave finish). `reset` is the respawn story, exactly what a real reset
-- does: the body is destroyed now, Players.RespawnTime later a fresh rig with the same identity is acquired
-- at a SpawnLocation (else an NpcSpawn, else the world spawn) and handed to `onRebind` (Api ->
-- service:onRebind). Nothing is teleported and no body is reused. It also owns the remotes folder helpers.
-- It decides nothing (which line, which emote, when to leave): the core does.
-- requires: Connections, Ports (types), Remotes, RobloxChatSink (types), Types (types)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Connections = require(script.Parent.Connections)
local Ports = require(script.Parent.Parent.Ports)
local Types = require(script.Parent.Parent.Types)
local RobloxChatSink = require(script.Parent.RobloxChatSink)
local Remotes = require(ReplicatedStorage.HumanlikeNpcShared.Remotes)

type Bag = Connections.Bag
type Identity = Types.Identity
type AvatarSpec = Types.AvatarSpec

local RobloxPresenter = {}
RobloxPresenter.__index = RobloxPresenter

-- The part of RobloxRig the presenter uses (structural, so nothing here requires the rig).
export type RigLike = {
	acquire: (
		self: any,
		identity: Identity,
		spec: AvatarSpec,
		position: Vector3,
		walkSpeed: number?
	) -> (Ports.Mover?, string?),
	release: (self: any, npcId: string) -> (),
	characterOf: (self: any, npcId: string) -> Model?,
	moverOf: (self: any, npcId: string) -> Ports.Mover?,
}

export type Options = {
	bag: Bag, -- the pool bag: leave and respawn threads live here
	clock: (() -> number)?, -- default os.clock
	sink: Ports.ChatSink, -- RobloxChatSink
	rig: RigLike,
	remotes: Instance?, -- the remotes folder (ensureRemotes); found by name when nil
	-- Who an NPC is and what it wears (Api keeps the spec it drew); nil once the NPC despawned.
	identityOf: (npcId: string) -> (Identity?, AvatarSpec?, number?),
	-- Where a respawn lands: a SpawnLocation first, else an NpcSpawn, else the world spawn (discovery).
	respawnPoint: (u1: number, u2: number, u3: number) -> Vector3?,
	onRebind: (npcId: string, mover: Ports.Mover, now: number) -> (), -- Api -> service:onRebind
	onRespawnFailed: ((npcId: string, reason: string) -> ())?, -- no body could be built; Api despawns
	onLeft: ((npcId: string) -> ())?, -- the leave story finished and the body is gone
	onEmote: ((npcId: string, name: string?, now: number) -> ())?, -- Api -> service:notifyEmote
	seatOf: ((seatId: string) -> Instance?)?, -- discovery's Seat instance by seat id
	showTypingIndicator: boolean?, -- Config.ShowTypingIndicator
	headLookShared: boolean?, -- Config.HeadLook == "shared"
}

export type Presenter = typeof(setmetatable(
	{} :: {
		bag: Bag,
		clock: () -> number,
		sink: Ports.ChatSink,
		rig: RigLike,
		remotes: Instance?,
		identityOf: (npcId: string) -> (Identity?, AvatarSpec?, number?),
		respawnPoint: (u1: number, u2: number, u3: number) -> Vector3?,
		onRebind: (npcId: string, mover: Ports.Mover, now: number) -> (),
		onRespawnFailed: ((npcId: string, reason: string) -> ())?,
		onLeft: ((npcId: string) -> ())?,
		onEmote: ((npcId: string, name: string?, now: number) -> ())?,
		seatOf: ((seatId: string) -> Instance?)?,
		showTypingIndicator: boolean,
		headLookShared: boolean,
		leaving: { [string]: boolean },
		respawning: { [string]: boolean },
		lastCameraAt: { [string]: number },
		stats: { says: number, emotes: number, leaves: number, resets: number, rebinds: number, failedRespawns: number },
	},
	RobloxPresenter
))

RobloxPresenter.LEAVE_MIN = 0.5
RobloxPresenter.LEAVE_MAX = 2
RobloxPresenter.CAMERA_PERIOD = 0.5 -- at most 2 Hz per NPC

local STOP: Types.MoveCommand = { mode = "stop", dir = Vector3.zero, magnitude = 0, jump = false }

-- Remotes this module created, so stop removes only its own instances.
local createdRemotes: { Instance } = {}
local createdFolder: Instance? = nil

local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

-- Creates (or completes) ReplicatedStorage.HumanlikeNpcRemotes with the CHAT, TYPING and EMOTE RemoteEvents,
-- plus the CAM UnreliableRemoteEvent when head look is shared. Returns the folder.
function RobloxPresenter.ensureRemotes(headLookShared: boolean?): Folder
	local existing = ReplicatedStorage:FindFirstChild(Remotes.FOLDER)
	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = Remotes.FOLDER
		folder.Parent = ReplicatedStorage
		createdFolder = folder
	end
	local function ensure(name: string, className: string)
		local child = folder:FindFirstChild(name)
		if child then
			return
		end
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = folder
		table.insert(createdRemotes, remote)
	end
	ensure(Remotes.CHAT, "RemoteEvent")
	ensure(Remotes.TYPING, "RemoteEvent")
	ensure(Remotes.EMOTE, "RemoteEvent")
	if headLookShared then
		ensure(Remotes.CAM, "UnreliableRemoteEvent")
	end
	return folder
end

-- Removes the remotes ensureRemotes created (never the developer's SharedChatSay), and the folder when it
-- was ours and is empty.
function RobloxPresenter.destroyRemotes()
	for _, remote in createdRemotes do
		pcall(function()
			remote:Destroy()
		end)
	end
	createdRemotes = {}
	local folder = createdFolder
	createdFolder = nil
	if folder then
		pcall(function()
			if #folder:GetChildren() == 0 then
				folder:Destroy()
			end
		end)
	end
end

function RobloxPresenter.new(options: Options): Presenter
	return setmetatable({
		bag = options.bag,
		clock = options.clock or os.clock,
		sink = options.sink,
		rig = options.rig,
		remotes = options.remotes,
		identityOf = options.identityOf,
		respawnPoint = options.respawnPoint,
		onRebind = options.onRebind,
		onRespawnFailed = options.onRespawnFailed,
		onLeft = options.onLeft,
		onEmote = options.onEmote,
		seatOf = options.seatOf,
		showTypingIndicator = options.showTypingIndicator == true,
		headLookShared = options.headLookShared == true,
		leaving = {},
		respawning = {},
		lastCameraAt = {},
		stats = { says = 0, emotes = 0, leaves = 0, resets = 0, rebinds = 0, failedRespawns = 0 },
	}, RobloxPresenter)
end

local function remote(self: Presenter, name: string): RemoteEvent?
	local folder = self.remotes
	if not folder or folder.Parent == nil then
		folder = ReplicatedStorage:FindFirstChild(Remotes.FOLDER)
		self.remotes = folder
	end
	local found = if folder then folder:FindFirstChild(name) else nil
	if found and found:IsA("RemoteEvent") then
		return found
	end
	return nil
end

local function liveCharacter(self: Presenter, npcId: string): Model?
	local ok, model = pcall(self.rig.characterOf, self.rig, npcId)
	if ok and model and model.Parent ~= nil then
		return model
	end
	return nil
end

local function humanoidOf(model: Model?): Humanoid?
	if not model then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid:IsA("Humanoid") then
		return humanoid
	end
	return nil
end

function RobloxPresenter.say(self: Presenter, npcId: string, text: string, target: string?)
	self.stats.says += 1
	try(function()
		self.sink:say(npcId, text, target)
	end)
end

-- Fires the emote to every client; a nil name stops the running one.
function RobloxPresenter.emote(self: Presenter, npcId: string, name: string?, cutAfter: number?)
	self.stats.emotes += 1
	local character = liveCharacter(self, npcId)
	if character then
		local event = remote(self, Remotes.EMOTE)
		if event then
			try(function()
				event:FireAllClients(character, name, cutAfter)
			end)
		end
	end
	local onEmote = self.onEmote
	if onEmote then
		try(function()
			onEmote(npcId, name, self.clock())
		end)
	end
end

-- Removes the body now and drops any pending leave for it.
local function removeBody(self: Presenter, npcId: string)
	self.leaving[npcId] = nil
	try(function()
		self.rig:release(npcId)
	end)
end

-- The leave story: stand still for a moment, then vanish in one frame like a disconnect.
function RobloxPresenter.leave(self: Presenter, npcId: string, reason: string)
	self.stats.leaves += 1
	if self.leaving[npcId] then
		return
	end
	self.leaving[npcId] = true
	local mover = self.rig:moverOf(npcId)
	if mover then
		try(function()
			mover:apply(STOP)
		end)
	end
	local delay = RobloxPresenter.LEAVE_MIN + math.random() * (RobloxPresenter.LEAVE_MAX - RobloxPresenter.LEAVE_MIN)
	local bag = self.bag
	local thread = task.delay(delay, function()
		bag:remove(coroutine.running())
		if not self.leaving[npcId] then
			return -- released already
		end
		removeBody(self, npcId)
		local onLeft = self.onLeft
		if onLeft then
			try(function()
				onLeft(npcId)
			end)
		end
	end)
	bag:add(thread)
end

-- Api's destroyMover: the body goes now unless a leave story is playing (its thread removes it).
function RobloxPresenter.release(self: Presenter, npcId: string)
	if self.leaving[npcId] then
		return
	end
	removeBody(self, npcId)
end

-- The respawn story: destroy, wait RespawnTime, acquire a fresh body with the same identity, rebind.
function RobloxPresenter.reset(self: Presenter, npcId: string)
	self.stats.resets += 1
	if self.respawning[npcId] then
		return
	end
	self.respawning[npcId] = true
	self.leaving[npcId] = nil
	try(function()
		self.rig:release(npcId)
	end)
	local bag = self.bag
	local thread = task.spawn(function()
		local respawnTime = 5
		pcall(function()
			respawnTime = Players.RespawnTime
		end)
		task.wait(respawnTime)
		bag:remove(coroutine.running())
		if not self.respawning[npcId] then
			return
		end
		self.respawning[npcId] = nil
		local identity, spec, walkSpeed = self.identityOf(npcId)
		if not identity or not spec then
			return -- despawned meanwhile
		end
		local okPoint, point = pcall(self.respawnPoint, math.random(), math.random(), math.random())
		local at: Vector3 = if okPoint and point then point else Vector3.zero
		local okAcquire, mover, why = pcall(self.rig.acquire, self.rig, identity, spec, at, walkSpeed)
		if okAcquire and mover then
			self.stats.rebinds += 1
			try(function()
				self.onRebind(npcId, mover, self.clock())
			end)
		else
			self.stats.failedRespawns += 1
			local onFailed = self.onRespawnFailed
			if onFailed then
				try(function()
					onFailed(npcId, if okAcquire then tostring(why) else tostring(mover))
				end)
			end
		end
	end)
	if coroutine.status(thread) ~= "dead" then
		bag:add(thread)
	end
end

-- Drops a pending respawn (the NPC despawned while waiting).
function RobloxPresenter.forget(self: Presenter, npcId: string)
	self.respawning[npcId] = nil
	self.leaving[npcId] = nil
	self.lastCameraAt[npcId] = nil
end

function RobloxPresenter.setTyping(self: Presenter, npcId: string, typing: boolean)
	if not self.showTypingIndicator then
		return
	end
	local character = liveCharacter(self, npcId)
	if not character then
		return
	end
	local event = remote(self, Remotes.TYPING)
	if event then
		try(function()
			event:FireAllClients(character, typing)
		end)
	end
end

-- HeadLook "shared" only: the camera attributes every character carries, in degrees, at most 2 Hz.
function RobloxPresenter.setCamera(self: Presenter, npcId: string, yaw: number, pitch: number)
	if not self.headLookShared then
		return
	end
	local now = self.clock()
	local last = self.lastCameraAt[npcId] or -math.huge
	if now - last < RobloxPresenter.CAMERA_PERIOD then
		return
	end
	local character = liveCharacter(self, npcId)
	if not character then
		return
	end
	self.lastCameraAt[npcId] = now
	try(function()
		character:SetAttribute(Remotes.CAM_ATTR_YAW, math.clamp(math.deg(yaw), -180, 180))
		character:SetAttribute(Remotes.CAM_ATTR_PITCH, math.clamp(math.deg(pitch), -90, 90))
	end)
end

-- Sits on the registered Seat (never Humanoid.Sit = true); nil stands up.
function RobloxPresenter.seat(self: Presenter, npcId: string, seatId: string?)
	local humanoid = humanoidOf(liveCharacter(self, npcId))
	if not humanoid then
		return
	end
	if seatId == nil then
		try(function()
			humanoid.Sit = false
		end)
		return
	end
	local seatOf = self.seatOf
	local seat = if seatOf then seatOf(seatId) else nil
	if not seat or seat.Parent == nil then
		return
	end
	try(function()
		if seat:IsA("Seat") then
			seat:Sit(humanoid)
		elseif seat:IsA("VehicleSeat") then
			seat:Sit(humanoid)
		end
	end)
end

function RobloxPresenter.getStats(self: Presenter): {
	says: number,
	emotes: number,
	leaves: number,
	resets: number,
	rebinds: number,
	failedRespawns: number,
}
	return table.clone(self.stats)
end

-- Cancels pending stories (their threads are in the pool bag, which Api empties on stop).
function RobloxPresenter.destroy(self: Presenter)
	self.leaving = {}
	self.respawning = {}
	self.lastCameraAt = {}
end

-- The same object seen as the port (methods take `self: Presenter`; the port takes `self: any`).
function RobloxPresenter.asPort(self: Presenter): Ports.Presenter
	return (self :: any) :: Ports.Presenter
end

-- Re-exported for Api's convenience: the sink type this presenter speaks through.
export type Sink = RobloxChatSink.Sink

return RobloxPresenter

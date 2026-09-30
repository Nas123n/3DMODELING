--!strict
-- What the world contributes to the service's perception: live views of the real players (position, velocity,
-- yaw, display name, when they last jumped, which emote they started), the three raycast checks (floor line of
-- sight, eye-to-eye occlusion, the LOD pass's player LOS), and hearing what players type. Every connection on a
-- Player or a character lives in that player's bag (a child of the root bag, emptied on PlayerRemoving) or in
-- that character's bag (a child of the player's, replaced on every CharacterAdded), so nothing about a player
-- survives them. Hearing: in ChatHook "own" it connects Player.Chatted for every player and, when the game has
-- not set one, RBXGeneral.ShouldDeliverCallback (deduped per MessageId and against the Chatted line within
-- 0.5 s); in "shared" it connects nothing and the developer feeds `hear`. It is not the Perception port itself
-- (NpcService.makePerception builds that over Spatial) and it never speaks: RobloxChatSink does.
-- requires: AnimSets, Connections, NavMath, Types (types)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Connections = require(script.Parent.Connections)
local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Types = require(script.Parent.Parent.Types)
local AnimSets = require(ReplicatedStorage.HumanlikeNpcShared.AnimSets)

type Bag = Connections.Bag
type AgentView = Types.AgentView

local RobloxPerception = {}
RobloxPerception.__index = RobloxPerception

-- Api wires this to `service:onPlayerChat(tostring(userId), text, position, now)` (the landed service
-- prefixes "p:" itself).
export type ChatHandler = (userId: number, text: string, position: Vector3, now: number) -> ()

export type Options = {
	bag: Bag, -- the root bag; player and character bags are children of it
	clock: (() -> number)?, -- default os.clock
	chatHook: string?, -- "own" (default) | "shared"
	onPlayerChat: ChatHandler?,
	onPlayerJoined: ((userId: number, displayName: string, now: number) -> ())?, -- Api -> service:onPlayerJoined
	onPlayerLeft: ((userId: number, now: number) -> ())?, -- Api -> service:onPlayerLeft
	npcCharacters: (() -> { Model })?, -- the rig's live bodies, excluded from every raycast with the players'
}

type PlayerState = {
	player: Player,
	userId: number,
	bag: Bag,
	characterBag: Bag?,
	character: Model?,
	root: BasePart?,
	humanoid: Humanoid?,
	jumpedAt: number?,
	emoteAt: number?,
	emoteName: string?,
	emoteUntil: number,
	lastPosition: Vector3?,
}

export type Perception = typeof(setmetatable(
	{} :: {
		bag: Bag,
		clock: () -> number,
		chatHook: string,
		onPlayerChat: ChatHandler?,
		onPlayerJoined: ((userId: number, displayName: string, now: number) -> ())?,
		onPlayerLeft: ((userId: number, now: number) -> ())?,
		npcCharacters: (() -> { Model })?,
		states: { [number]: PlayerState },
		order: { number }, -- user ids in join order (hash order never reaches the views)
		hookedChannel: TextChannel?,
		hookConnections: { RBXScriptConnection },
		seenMessages: { [string]: number },
		recentLines: { [string]: number },
		lastPrune: number,
		filterCache: { Instance }?,
		filterCacheAt: number,
		heard: number,
		warnedHook: boolean,
	},
	RobloxPerception
))

RobloxPerception.EYE_HEIGHT = 1.5
RobloxPerception.LOS_HEIGHT = 1
RobloxPerception.MOVING_SPEED = 0.5
RobloxPerception.CHAT_DEDUPE = 0.5
RobloxPerception.GENERIC_EMOTE = "emote" -- an Action-priority track that matches no known emote id

local PRUNE_EVERY = 10
local DEFAULT_EMOTE_SECONDS = 3

local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

-- Emote name by animation asset id, from AnimSets.EMOTES (including the multi-clip lists).
local emoteById: { [number]: string }? = nil

local function emoteNames(): { [number]: string }
	local cached = emoteById
	if cached then
		return cached
	end
	local map: { [number]: string } = {}
	for _, name in AnimSets.EMOTE_NAMES do
		local emote = AnimSets.EMOTES[name]
		if emote then
			map[emote.id] = name
			local clips = emote.weightedIds
			if clips then
				for _, clip in clips do
					map[clip.id] = name
				end
			end
		end
	end
	emoteById = map
	return map
end

-- The numeric asset id inside an AnimationId content string, if any.
function RobloxPerception.assetId(content: string): number?
	local digits = string.match(content, "[?&]id=(%d+)") or string.match(content, "://(%d+)%s*$")
	return if digits then tonumber(digits) else nil
end

-- Which emote a track is: a known emote by id, the generic name for an Action-priority clip played while
-- standing, else nil.
function RobloxPerception.emoteOf(animationId: string, priority: Enum.AnimationPriority?, standing: boolean): string?
	local id = RobloxPerception.assetId(animationId)
	if id then
		local known = emoteNames()[id]
		if known then
			return known
		end
	end
	if standing and priority == Enum.AnimationPriority.Action then
		return RobloxPerception.GENERIC_EMOTE
	end
	return nil
end

local function isStanding(humanoid: Humanoid?, root: BasePart?): boolean
	if not humanoid or not root then
		return false
	end
	local ok, standing = pcall(function()
		return humanoid:GetState() == Enum.HumanoidStateType.Running
			and humanoid.MoveDirection.Magnitude < 0.05
			and root.AssemblyLinearVelocity.Magnitude < 1
	end)
	return ok and standing == true
end

local function onAnimationPlayed(self: Perception, state: PlayerState, track: AnimationTrack)
	local ok = pcall(function()
		local animation = track.Animation
		if not animation then
			return
		end
		local name =
			RobloxPerception.emoteOf(animation.AnimationId, track.Priority, isStanding(state.humanoid, state.root))
		if not name then
			return
		end
		local now = self.clock()
		state.emoteAt = now
		state.emoteName = name
		local emote = AnimSets.EMOTES[name]
		local duration = if emote then emote.duration else DEFAULT_EMOTE_SECONDS
		state.emoteUntil = now + duration
	end)
	if not ok then
		state.emoteName = nil
	end
end

local function attachAnimator(self: Perception, state: PlayerState, bag: Bag, humanoid: Humanoid)
	local function hook(animator: Instance)
		if not animator:IsA("Animator") then
			return
		end
		pcall(function()
			bag:add(animator.AnimationPlayed:Connect(function(track: AnimationTrack)
				onAnimationPlayed(self, state, track)
			end))
		end)
	end
	local existing = humanoid:FindFirstChildOfClass("Animator")
	if existing then
		hook(existing)
		return
	end
	-- The Animator can arrive after the character does; watch for it in the same bag.
	bag:add(humanoid.ChildAdded:Connect(function(child: Instance)
		hook(child)
	end))
end

local function bindCharacter(self: Perception, state: PlayerState, character: Model?)
	local old = state.characterBag
	if old then
		old:disconnectAll()
	end
	state.characterBag = nil
	state.character = nil
	state.root = nil
	state.humanoid = nil
	state.emoteName = nil
	if character == nil then
		return
	end
	local bag = state.bag:child(`character:{state.userId}`)
	state.characterBag = bag
	state.character = character
	pcall(function()
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			state.root = root
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid:IsA("Humanoid") then
			state.humanoid = humanoid
			bag:add(humanoid.Jumping:Connect(function(active: boolean)
				if active then
					state.jumpedAt = self.clock()
				end
			end))
			attachAnimator(self, state, bag, humanoid)
		end
	end)
end

local function hear(self: Perception, userId: number, text: string, position: Vector3?)
	local now = self.clock()
	local key = `{userId}:{text}`
	local last = self.recentLines[key]
	if last and now - last < RobloxPerception.CHAT_DEDUPE then
		return
	end
	self.recentLines[key] = now
	local at = position
	if at == nil then
		local state = self.states[userId]
		if state then
			local root = state.root
			if root then
				local ok, p = pcall(function()
					return root.Position
				end)
				at = if ok then p else state.lastPosition
			else
				at = state.lastPosition
			end
		end
	end
	if at == nil then
		return -- a player without a body yet: nobody is near enough to hear anyway
	end
	self.heard += 1
	local handler = self.onPlayerChat
	if handler then
		try(function()
			handler(userId, text, at :: Vector3, now)
		end)
	end
end

local function bindPlayer(self: Perception, player: Player)
	local userId = player.UserId
	if self.states[userId] then
		return
	end
	local bag = self.bag:child(`player:{userId}`)
	local state: PlayerState = {
		player = player,
		userId = userId,
		bag = bag,
		characterBag = nil,
		character = nil,
		root = nil,
		humanoid = nil,
		jumpedAt = nil,
		emoteAt = nil,
		emoteName = nil,
		emoteUntil = 0,
		lastPosition = nil,
	}
	self.states[userId] = state
	table.insert(self.order, userId)
	bag:add(player.CharacterAdded:Connect(function(character: Model)
		bindCharacter(self, state, character)
	end))
	bag:add(player.CharacterRemoving:Connect(function()
		bindCharacter(self, state, nil)
	end))
	if self.chatHook == "own" then
		pcall(function()
			bag:add(player.Chatted:Connect(function(message: string)
				hear(self, userId, message, nil)
			end))
		end)
	end
	bindCharacter(self, state, player.Character)
end

local function unbindPlayer(self: Perception, player: Player)
	local userId = player.UserId
	local state = self.states[userId]
	if not state then
		return
	end
	self.states[userId] = nil
	for i, id in self.order do
		if id == userId then
			table.remove(self.order, i)
			break
		end
	end
	local characterBag = state.characterBag
	if characterBag then
		characterBag:disconnectAll()
	end
	state.bag:disconnectAll()
end

local function dropHookConnections(self: Perception)
	for _, connection in self.hookConnections do
		self.bag:remove(connection)
		pcall(function()
			connection:Disconnect()
		end)
	end
	self.hookConnections = {}
end

-- Assigns RBXGeneral.ShouldDeliverCallback when the game has not; true once the channel was looked at.
local function tryHookChannel(self: Perception, channel: Instance): boolean
	if not channel:IsA("TextChannel") then
		return false
	end
	local readOk, existing = pcall(function()
		return channel.ShouldDeliverCallback
	end)
	if not readOk then
		if not self.warnedHook then
			self.warnedHook = true
			warn(
				"[HumanlikeNpc] RBXGeneral.ShouldDeliverCallback could not be inspected; hearing uses Player.Chatted only"
			)
		end
		return true
	end
	if existing ~= nil then
		return true -- the game owns it; never overwrite
	end
	local assigned = pcall(function()
		channel.ShouldDeliverCallback = function(message: TextChatMessage, textSource: TextSource)
			local messageId = message.MessageId
			if self.seenMessages[messageId] == nil then
				self.seenMessages[messageId] = self.clock()
				local source = message.TextSource
				local userId = if source then source.UserId else textSource.UserId
				hear(self, userId, message.Text, nil)
			end
			return true
		end
	end)
	if assigned then
		self.hookedChannel = channel
	end
	return true
end

local function hookGeneralChannel(self: Perception)
	local TextChatService = game:GetService("TextChatService")
	local function onChannels(channels: Instance)
		local general = channels:FindFirstChild("RBXGeneral")
		if general then
			if tryHookChannel(self, general) then
				dropHookConnections(self)
			end
			return
		end
		local connection: RBXScriptConnection
		connection = channels.ChildAdded:Connect(function(child: Instance)
			if child.Name == "RBXGeneral" and tryHookChannel(self, child) then
				dropHookConnections(self)
			end
		end)
		self.bag:add(connection)
		table.insert(self.hookConnections, connection)
	end
	pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		if channels then
			onChannels(channels)
			return
		end
		local connection: RBXScriptConnection
		connection = TextChatService.ChildAdded:Connect(function(child: Instance)
			if child.Name == "TextChannels" then
				onChannels(child)
			end
		end)
		self.bag:add(connection)
		table.insert(self.hookConnections, connection)
	end)
end

function RobloxPerception.new(options: Options): Perception
	local self = setmetatable({
		bag = options.bag,
		clock = options.clock or os.clock,
		chatHook = if options.chatHook == "shared" then "shared" else "own",
		onPlayerChat = options.onPlayerChat,
		onPlayerJoined = options.onPlayerJoined,
		onPlayerLeft = options.onPlayerLeft,
		npcCharacters = options.npcCharacters,
		states = {},
		order = {},
		hookedChannel = nil,
		hookConnections = {},
		seenMessages = {},
		recentLines = {},
		lastPrune = 0,
		filterCache = nil,
		filterCacheAt = -math.huge,
		heard = 0,
		warnedHook = false,
	}, RobloxPerception)
	pcall(function()
		self.bag:add(Players.PlayerAdded:Connect(function(player: Player)
			bindPlayer(self, player)
			local onJoined = self.onPlayerJoined
			if onJoined then
				try(function()
					onJoined(player.UserId, player.DisplayName, self.clock())
				end)
			end
		end))
		self.bag:add(Players.PlayerRemoving:Connect(function(player: Player)
			unbindPlayer(self, player)
			local onLeft = self.onPlayerLeft
			if onLeft then
				try(function()
					onLeft(player.UserId, self.clock())
				end)
			end
		end))
		for _, player in Players:GetPlayers() do
			bindPlayer(self, player)
		end
	end)
	if self.chatHook == "own" then
		hookGeneralChannel(self)
	end
	return self
end

local function prune(self: Perception, now: number)
	if now - self.lastPrune < PRUNE_EVERY then
		return
	end
	self.lastPrune = now
	for id, at in self.seenMessages do
		if now - at > PRUNE_EVERY then
			self.seenMessages[id] = nil
		end
	end
	for key, at in self.recentLines do
		if now - at > PRUNE_EVERY then
			self.recentLines[key] = nil
		end
	end
end

-- One view per player with a character and a root part, in join order.
function RobloxPerception.players(self: Perception): { AgentView }
	local now = self.clock()
	prune(self, now)
	local views: { AgentView } = {}
	for _, userId in self.order do
		local state = self.states[userId]
		if not state then
			continue
		end
		local root = state.root
		local character = state.character
		if not root or not character then
			continue
		end
		local ok = pcall(function()
			if character.Parent == nil then
				return
			end
			local position = root.Position
			local velocity = root.AssemblyLinearVelocity
			state.lastPosition = position
			if state.emoteName ~= nil then
				local moving = Vector3.new(velocity.X, 0, velocity.Z).Magnitude > 1
				if now > state.emoteUntil or moving then
					state.emoteName = nil
				end
			end
			table.insert(views, {
				id = `p:{userId}`,
				kind = "player" :: "player",
				position = position,
				velocity = velocity,
				yaw = NavMath.yawOf(root.CFrame.LookVector),
				displayName = state.player.DisplayName,
				radius = 2,
				isMoving = Vector3.new(velocity.X, 0, velocity.Z).Magnitude > RobloxPerception.MOVING_SPEED,
				jumpedAt = state.jumpedAt,
				emoteAt = state.emoteAt,
				emoteName = state.emoteName,
				isTyping = nil,
			})
		end)
		if not ok then
			state.root = nil -- a vanished body; the next CharacterAdded rebinds it
		end
	end
	return views
end

-- Every character on the server (players' and NPCs'), for raycast filters; rebuilt once per clock value.
function RobloxPerception.characters(self: Perception): { Instance }
	local now = self.clock()
	local cached = self.filterCache
	if cached and self.filterCacheAt == now then
		return cached
	end
	local list: { Instance } = {}
	for _, userId in self.order do
		local state = self.states[userId]
		local character = if state then state.character else nil
		if character then
			table.insert(list, character)
		end
	end
	local npcs = self.npcCharacters
	if npcs then
		local ok, models = pcall(npcs)
		if ok then
			for _, model in models do
				table.insert(list, model)
			end
		end
	end
	self.filterCache = list
	self.filterCacheAt = now
	return list
end

local function raycastParams(self: Perception): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = self:characters()
	return params
end

-- True when nothing solid stands between the two floor points at knee height (a wall test, flat).
function RobloxPerception.losCheck(self: Perception, from: Vector3, to: Vector3): boolean
	local ok, clear = pcall(function()
		local origin = from + Vector3.new(0, RobloxPerception.LOS_HEIGHT, 0)
		local direction = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		if direction.Magnitude < 1e-3 then
			return true
		end
		return workspace:Raycast(origin, direction, raycastParams(self)) == nil
	end)
	return ok and clear == true
end

-- True when something solid blocks the line between the two eye points.
function RobloxPerception.occlusion(self: Perception, from: Vector3, to: Vector3): boolean
	local ok, blocked = pcall(function()
		local up = Vector3.new(0, RobloxPerception.EYE_HEIGHT, 0)
		local origin = from + up
		local direction = (to + up) - origin
		if direction.Magnitude < 1e-3 then
			return false
		end
		return workspace:Raycast(origin, direction, raycastParams(self)) ~= nil
	end)
	return ok and blocked == true
end

-- The LOD pass's question: can this NPC see that player (one eye-to-eye raycast)? True when unoccluded.
function RobloxPerception.playerLos(self: Perception, npcPosition: Vector3, playerPosition: Vector3): boolean
	return not self:occlusion(npcPosition, playerPosition)
end

-- ChatHook "shared": the developer's chat handler feeds a player's line here (Handle.onPlayerChat).
function RobloxPerception.hear(self: Perception, player: Player, text: string)
	local ok, userId = pcall(function()
		return player.UserId
	end)
	if not ok or type(userId) ~= "number" then
		return
	end
	hear(self, userId, text, nil)
end

-- Plain functions Api can hand to the service's WorldAdapter.
function RobloxPerception.playersFn(self: Perception): () -> { AgentView }
	return function()
		return self:players()
	end
end

function RobloxPerception.losCheckFn(self: Perception): (Vector3, Vector3) -> boolean
	return function(a: Vector3, b: Vector3)
		return self:losCheck(a, b)
	end
end

function RobloxPerception.occlusionFn(self: Perception): (Vector3, Vector3) -> boolean
	return function(a: Vector3, b: Vector3)
		return self:occlusion(a, b)
	end
end

function RobloxPerception.playerLosFn(self: Perception): (Vector3, Vector3) -> boolean
	return function(a: Vector3, b: Vector3)
		return self:playerLos(a, b)
	end
end

function RobloxPerception.stats(self: Perception): { players: number, heard: number, channelHooked: boolean }
	return { players = #self.order, heard = self.heard, channelHooked = self.hookedChannel ~= nil }
end

-- Frees every player and character bag and releases the channel callback this adapter set.
function RobloxPerception.destroy(self: Perception)
	local channel = self.hookedChannel
	if channel then
		self.hookedChannel = nil
		pcall(function()
			channel.ShouldDeliverCallback = nil :: any
		end)
	end
	dropHookConnections(self)
	for _, userId in table.clone(self.order) do
		local state = self.states[userId]
		if state then
			unbindPlayer(self, state.player)
		end
	end
	self.states = {}
	self.order = {}
	self.filterCache = nil
end

return RobloxPerception

--!strict
-- Where an NPC's words go. ChatHook "own": the Remotes.CHAT RemoteEvent is fired to every client with
-- (displayName, text, NameColor.of(username), characterModel, Remotes.METADATA); the colour is hashed on the
-- username (the Model's name) because that is what the classic chat keys on, and the client display renders
-- the window line and the bubble. ChatHook "shared": the developer's BindableFunction Remotes.SHARED_SAY under
-- the remotes folder is invoked with (displayName, text, character); when it is absent the sink warns once and
-- behaves as "own". It never sends through TextChannel:SendAsync, never names a speaker by id, and never
-- creates the remotes (RobloxPresenter.ensureRemotes does).
-- requires: NameColor, Ports (types), Remotes

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ports = require(script.Parent.Parent.Ports)
local Remotes = require(ReplicatedStorage.HumanlikeNpcShared.Remotes)
local NameColor = require(ReplicatedStorage.HumanlikeNpcShared.NameColor)

local RobloxChatSink = {}
RobloxChatSink.__index = RobloxChatSink

export type Identity = { username: string, displayName: string }

export type Options = {
	chatHook: string?, -- "own" (default) | "shared"
	remotes: Instance?, -- the HumanlikeNpcRemotes folder; found by name under ReplicatedStorage when nil
	characterOf: (npcId: string) -> Model?,
	identityOf: (npcId: string) -> Identity?,
	onSaid: ((npcId: string, text: string, target: string?) -> ())?, -- after the line went out
}

export type Sink = typeof(setmetatable(
	{} :: {
		chatHook: string,
		remotes: Instance?,
		characterOf: (npcId: string) -> Model?,
		identityOf: (npcId: string) -> Identity?,
		onSaid: ((npcId: string, text: string, target: string?) -> ())?,
		said: number,
		dropped: number,
		warnedShared: boolean,
		warnedRemote: boolean,
	},
	RobloxChatSink
))

local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

function RobloxChatSink.new(options: Options): Sink
	return setmetatable({
		chatHook = if options.chatHook == "shared" then "shared" else "own",
		remotes = options.remotes,
		characterOf = options.characterOf,
		identityOf = options.identityOf,
		onSaid = options.onSaid,
		said = 0,
		dropped = 0,
		warnedShared = false,
		warnedRemote = false,
	}, RobloxChatSink)
end

local function remotesFolder(self: Sink): Instance?
	local folder = self.remotes
	if folder and folder.Parent ~= nil then
		return folder
	end
	local found = ReplicatedStorage:FindFirstChild(Remotes.FOLDER)
	self.remotes = found
	return found
end

local function fireOwn(self: Sink, identity: Identity, text: string, character: Model?): boolean
	local folder = remotesFolder(self)
	local remote = if folder then folder:FindFirstChild(Remotes.CHAT) else nil
	if not remote or not remote:IsA("RemoteEvent") then
		if not self.warnedRemote then
			self.warnedRemote = true
			warn(`[HumanlikeNpc] RemoteEvent {Remotes.FOLDER}.{Remotes.CHAT} is missing; NPC lines are not shown`)
		end
		return false
	end
	local ok = try(function()
		remote:FireAllClients(identity.displayName, text, NameColor.of(identity.username), character, Remotes.METADATA)
	end)
	return ok
end

local function invokeShared(self: Sink, identity: Identity, text: string, character: Model?): boolean
	local folder = remotesFolder(self)
	local bindable = if folder then folder:FindFirstChild(Remotes.SHARED_SAY) else nil
	if not bindable or not bindable:IsA("BindableFunction") then
		if not self.warnedShared then
			self.warnedShared = true
			warn(
				`[HumanlikeNpc] ChatHook "shared" but {Remotes.FOLDER}.{Remotes.SHARED_SAY} is missing; using the "own" path`
			)
		end
		return fireOwn(self, identity, text, character)
	end
	local ok = try(function()
		bindable:Invoke(identity.displayName, text, character)
	end)
	if not ok then
		return fireOwn(self, identity, text, character)
	end
	return true
end

function RobloxChatSink.say(self: Sink, npcId: string, text: string, target: string?)
	local identity = self.identityOf(npcId)
	if not identity then
		self.dropped += 1
		return
	end
	local okChar, character = pcall(self.characterOf, npcId)
	local model: Model? = if okChar then character else nil
	if model and model.Parent == nil then
		model = nil -- a streamed-out or destroyed body still gets its window line, just no bubble
	end
	local shown = if self.chatHook == "shared"
		then invokeShared(self, identity, text, model)
		else fireOwn(self, identity, text, model)
	if shown then
		self.said += 1
	else
		self.dropped += 1
	end
	local onSaid = self.onSaid
	if onSaid then
		try(function()
			onSaid(npcId, text, target)
		end)
	end
end

function RobloxChatSink.stats(self: Sink): { said: number, dropped: number }
	return { said = self.said, dropped = self.dropped }
end

-- The same object seen as the port (methods take `self: Sink`; the port takes `self: any`).
function RobloxChatSink.asPort(self: Sink): Ports.ChatSink
	return (self :: any) :: Ports.ChatSink
end

return RobloxChatSink

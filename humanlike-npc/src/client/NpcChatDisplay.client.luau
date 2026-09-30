--!strict
-- Renders the CharacterChat remote's lines into the chat window and as chat bubbles so they look identical to a
-- player's line: the window line goes through RBXGeneral:DisplaySystemMessage with the prefix template this
-- client captured from a real player's message (never by assigning TextChatService.OnIncomingMessage, which the
-- game may own), the bubble goes through TextChatService:DisplayBubble on the character model. Only messages
-- carrying Remotes.METADATA are ours; every other message is left alone. It is not a chat system (nothing is sent
-- through SendAsync, no TextSource is faked) and it never marks a character: a streamed-out or missing character
-- still gets its window line and simply no bubble. Idles when the server side is not running.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("HumanlikeNpcShared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ClientConfig = require(Shared:WaitForChild("ClientConfig"))
local NameColor = require(Shared:WaitForChild("NameColor"))

local config = ClientConfig.get()

-- The decorated prefix of a real message with the display name replaced by %s and the colour hex by %c.
local DEFAULT_TEMPLATE = "<font color='#%c'>%s:</font>"
local TYPING_GUI_NAME = "TypingIndicator"

local template: string? = nil
local hexByUsername: { [string]: string } = {}
local hexByDisplayName: { [string]: string } = {}
local channel: TextChannel? = nil
local typingGuis: { [Model]: BillboardGui } = {}
local warned = false

local function warnOnce(message: string)
	if not warned then
		warned = true
		warn("[HumanlikeNpc chat] " .. message)
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

local function toHex(color: Color3): string
	return string.format(
		"%02X%02X%02X",
		math.floor(math.clamp(color.R, 0, 1) * 255 + 0.5),
		math.floor(math.clamp(color.G, 0, 1) * 255 + 0.5),
		math.floor(math.clamp(color.B, 0, 1) * 255 + 0.5)
	)
end

local function escape(text: string): string
	local escaped = string.gsub(text, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })
	return escaped
end

-- Replaces the first plain (non-pattern) occurrence of needle.
local function replaceFirst(text: string, needle: string, replacement: string): (string, boolean)
	if needle == "" then
		return text, false
	end
	local at, finish = string.find(text, needle, 1, true)
	if at == nil or finish == nil then
		return text, false
	end
	return string.sub(text, 1, at - 1) .. replacement .. string.sub(text, finish + 1), true
end

local function fill(pattern: string, displayName: string, hex: string): string
	local filled = string.gsub(pattern, "%%([sc])", function(key: string): string
		return if key == "s" then escape(displayName) else hex
	end)
	return filled
end

-- Learns the prefix template and the observed name colours from real players' messages (fires after the
-- channel's default decoration, so the prefix carries the colour and the colon exactly as shown).
local function learn(message: TextChatMessage)
	local source: TextSource? = message.TextSource
	if source == nil then
		return
	end
	local player = Players:GetPlayerByUserId(source.UserId)
	if player == nil then
		return
	end
	local prefix = message.PrefixText
	if prefix == nil or prefix == "" then
		return
	end
	local hex = string.match(prefix, "#(%x%x%x%x%x%x)")
	local pattern = prefix
	if hex then
		hexByUsername[player.Name] = hex
		hexByDisplayName[player.DisplayName] = hex
		pattern = replaceFirst(pattern, hex, "%c")
	end
	local withName, found = replaceFirst(pattern, player.DisplayName, "%s")
	if found and template == nil then
		template = withName
	end
end

local function generalChannel(): TextChannel?
	local current = channel
	if current ~= nil and current.Parent ~= nil then
		return current
	end
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = if channels then channels:FindFirstChild("RBXGeneral") else nil
	if general ~= nil and general:IsA("TextChannel") then
		channel = general
		return general
	end
	return nil
end

local function bubblesEnabled(): boolean
	local bubbleConfig = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if bubbleConfig == nil then
		return true
	end
	return bubbleConfig.Enabled
end

local function onChat(speakerName: unknown, text: unknown, color: unknown, character: unknown, metadata: unknown)
	if type(speakerName) ~= "string" or type(text) ~= "string" then
		return
	end
	if metadata ~= Remotes.METADATA then
		return
	end
	local model: Model? = nil
	if typeof(character) == "Instance" and character:IsA("Model") then
		model = character
	end
	local username = if model then model.Name else speakerName
	local hex = hexByUsername[username] or hexByDisplayName[speakerName]
	if hex == nil then
		local nameColor: Color3 = if typeof(color) == "Color3" then color else NameColor.of(username)
		hex = toHex(nameColor)
	end

	if config.ChatMode ~= "shared" then
		local general = generalChannel()
		if general == nil then
			warnOnce("RBXGeneral is not available; chat lines show as bubbles only")
		else
			local line = fill(template or DEFAULT_TEMPLATE, speakerName, hex) .. " " .. escape(text)
			local ok = pcall(function()
				general:DisplaySystemMessage(line, Remotes.METADATA)
			end)
			if not ok then
				warnOnce("DisplaySystemMessage failed; chat lines show as bubbles only")
			end
		end
	end

	if model == nil or model.Parent == nil then
		return
	end
	if bubblesEnabled() then
		local target: Model = model
		local ok = pcall(function()
			TextChatService:DisplayBubble(target, text)
		end)
		if not ok then
			warnOnce("DisplayBubble failed; no chat bubbles")
		end
	end
end

local function removeTyping(model: Model)
	local gui = typingGuis[model]
	if gui then
		typingGuis[model] = nil
		gui:Destroy()
	end
end

local function showTyping(model: Model)
	if typingGuis[model] then
		return
	end
	local adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	if adornee == nil or not adornee:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = TYPING_GUI_NAME
	gui.Size = UDim2.fromOffset(40, 20)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 60
	gui.Adornee = adornee
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Text = "..."
	label.TextColor3 = Color3.fromRGB(57, 59, 61)
	label.Parent = gui
	gui.Parent = adornee
	typingGuis[model] = gui
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			removeTyping(model)
		end
	end)
end

local function onTyping(character: unknown, on: unknown)
	if typeof(character) ~= "Instance" or not character:IsA("Model") or character.Parent == nil then
		return
	end
	if on == true then
		showTyping(character)
	else
		removeTyping(character)
	end
end

local function bindRemotes(folder: Instance)
	onChild(folder, Remotes.CHAT, function(remote)
		if remote:IsA("RemoteEvent") then
			remote.OnClientEvent:Connect(onChat)
		end
	end)
	if config.ShowTypingIndicator then
		onChild(folder, Remotes.TYPING, function(remote)
			if remote:IsA("RemoteEvent") then
				remote.OnClientEvent:Connect(onTyping)
			end
		end)
	end
end

local learnOk = pcall(function()
	TextChatService.MessageReceived:Connect(learn)
end)
if not learnOk then
	warnOnce("MessageReceived is not available; using the default prefix template")
end

onChild(ReplicatedStorage, Remotes.FOLDER, bindRemotes)

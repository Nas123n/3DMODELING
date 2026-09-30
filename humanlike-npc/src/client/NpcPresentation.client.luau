--!strict
-- Applies the two presentation switches of ClientConfig and nothing else: hides the CoreGui player list when the
-- developer sets HidePlayerList (a LocalScript is the only place SetCoreGuiEnabled is legal), and reads ChatMode so
-- the resolved value is validated once at start (its only effect lives in NpcChatDisplay, which skips the window
-- line in "shared" mode). By default it touches nothing: the player list is left as it is (NPCs are not in Players,
-- so it never shows them) and no CoreGui, chat or camera setting is changed. It is not a leaderboard and it never
-- marks a character. Idles when the server side is not running.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("HumanlikeNpcShared")
local ClientConfig = require(Shared:WaitForChild("ClientConfig"))

local config = ClientConfig.get()

-- ChatMode is validated by ClientConfig.resolve; nothing on the presentation side changes with it.
local _chatMode: string = config.ChatMode

if config.HidePlayerList then
	task.spawn(function()
		-- SetCoreGuiEnabled can fail while the CoreGui is still starting; retry briefly, then give up quietly.
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			end)
			if ok then
				return
			end
			task.wait(1)
		end
		warn("[HumanlikeNpc presentation] could not hide the player list")
	end)
end

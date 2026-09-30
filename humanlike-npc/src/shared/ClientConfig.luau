--!strict
-- Client-visible settings: module defaults merged with the attributes on the HumanlikeNpcShared folder (this
-- module's parent). Api.start copies the matching server Config keys (ChatHook → ChatMode, ShowTypingIndicator,
-- HeadLook) onto that folder's attributes so the two never disagree; the developer sets the purely client-side
-- keys (HidePlayerList, HeadLookMaxDegrees, HeadLookLerp, AnimFadeTime) as attributes on the same folder. It never
-- carries anything about NPC counts, ids or names, and it is not the server Config (nothing here reaches ring 1).
-- Pure: `get()` only reads attributes through `script.Parent:GetAttributes()`, guarded so it also runs under Lune
-- where the folder has no attributes; `resolve(attributes)` is the pure merge for tests.
-- requires: nothing

export type Resolved = {
	ChatMode: string, -- "own" | "shared"
	ShowTypingIndicator: boolean,
	HidePlayerList: boolean,
	HeadLook: string, -- "off" | "shared"
	HeadLookMaxDegrees: number,
	HeadLookLerp: number,
	AnimFadeTime: number,
}

local ClientConfig = {}

local DEFAULTS: Resolved = {
	ChatMode = "own",
	ShowTypingIndicator = false,
	HidePlayerList = false,
	HeadLook = "off",
	HeadLookMaxDegrees = 55,
	HeadLookLerp = 0.12,
	AnimFadeTime = 0.15,
}
ClientConfig.DEFAULTS = DEFAULTS

-- Accepted values per enum-like key; anything else keeps the default.
local CHAT_MODES: { [string]: boolean } = { own = true, shared = true }
local HEAD_LOOKS: { [string]: boolean } = { off = true, shared = true }

local function pickString(value: any, allowed: { [string]: boolean }, default: string): string
	if type(value) == "string" and allowed[value] then
		return value
	end
	return default
end

local function pickBoolean(value: any, default: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function pickNumber(value: any, default: number, lo: number, hi: number): number
	if type(value) == "number" and value == value and value >= lo and value <= hi then
		return value
	end
	return default
end

-- Pure merge: every key of DEFAULTS, overridden by a well-typed, in-range attribute of the same name.
function ClientConfig.resolve(attributes: { [string]: any }?): Resolved
	local a: { [string]: any } = attributes or {}
	local d = ClientConfig.DEFAULTS
	return {
		ChatMode = pickString(a.ChatMode, CHAT_MODES, d.ChatMode),
		ShowTypingIndicator = pickBoolean(a.ShowTypingIndicator, d.ShowTypingIndicator),
		HidePlayerList = pickBoolean(a.HidePlayerList, d.HidePlayerList),
		HeadLook = pickString(a.HeadLook, HEAD_LOOKS, d.HeadLook),
		HeadLookMaxDegrees = pickNumber(a.HeadLookMaxDegrees, d.HeadLookMaxDegrees, 0, 90),
		HeadLookLerp = pickNumber(a.HeadLookLerp, d.HeadLookLerp, 0.01, 1),
		AnimFadeTime = pickNumber(a.AnimFadeTime, d.AnimFadeTime, 0, 2),
	}
end

-- Reads the folder's attributes fresh on every call (cheap; the client scripts call it once at start).
function ClientConfig.get(): Resolved
	local attributes: { [string]: any } = {}
	local parent = script.Parent
	if parent ~= nil then
		local ok, result = pcall(function()
			return parent:GetAttributes()
		end)
		if ok and type(result) == "table" then
			attributes = result
		end
	end
	return ClientConfig.resolve(attributes)
end

return ClientConfig

--!strict
-- Names of the remotes, attributes and hook objects the server and the client scripts agree on. Data only: no
-- instances are created here (Api creates the folder under ReplicatedStorage at start), nothing is required, and
-- nothing in this table says "npc" to a client: every remote is named for what the client shows. It is not a
-- transport layer and it holds no defaults for behaviour (see ClientConfig).
-- requires: nothing
--
-- Payloads (server → client unless stated; every client handler tolerates a nil or streamed-out character):
--   CHAT    RemoteEvent   (speakerName: string, text: string, nameColor: Color3, bubbleFrom: Model?, metadata: string)
--                         speakerName is the display name; nameColor is NameColor.of(username); metadata == METADATA
--   TYPING  RemoteEvent   (character: Model, on: boolean); sent only when ClientConfig.ShowTypingIndicator
--   EMOTE   RemoteEvent   (character: Model, emoteName: string?, cutAfter: number?); a nil emoteName stops the emote
--   CAM     UnreliableRemoteEvent, client → server: (yawDegrees: number, pitchDegrees: number) at ≤ 5 Hz; exists
--                         only when HeadLook == "shared"; the server writes CAM_ATTR_YAW / CAM_ATTR_PITCH (degrees,
--                         clamped) on every character, players and NPCs alike

export type Remotes = {
	FOLDER: string,
	CHAT: string,
	TYPING: string,
	EMOTE: string,
	CAM: string,
	CAM_ATTR_YAW: string,
	CAM_ATTR_PITCH: string,
	SHARED_SAY: string,
	CUSTOM_WAYPOINT: string,
	TELEMETRY: string,
	METADATA: string,
}

local Remotes: Remotes = {
	-- Folder under ReplicatedStorage created by Api at start (a developer-facing name; it marks no character).
	FOLDER = "HumanlikeNpcRemotes",
	-- RemoteEvent server → client: (speakerName, text, nameColor, bubbleFrom, metadata).
	CHAT = "CharacterChat",
	-- RemoteEvent server → client: (character, on).
	TYPING = "CharacterTyping",
	-- RemoteEvent server → client: (character, emoteName?, cutAfter?).
	EMOTE = "CharacterEmote",
	-- UnreliableRemoteEvent client → server: (yaw, pitch) in degrees at ≤ 5 Hz; only in HeadLook == "shared".
	CAM = "CharacterCam",
	-- Attributes the server writes on EVERY character (players and NPCs) in "shared" head-look mode, in degrees.
	CAM_ATTR_YAW = "CamYaw",
	CAM_ATTR_PITCH = "CamPitch",
	-- BindableFunction the developer provides in ChatHook == "shared": (displayName, text, character).
	SHARED_SAY = "SharedChatSay",
	-- Optional BindableFunction under the Bootstrap script (custom waypoint provider).
	CUSTOM_WAYPOINT = "HumanlikeNpcCustomWaypoint",
	-- Optional BindableEvent under the Bootstrap script (telemetry).
	TELEMETRY = "HumanlikeNpcTelemetry",
	-- TextChatMessage.Metadata the client display sets on its own lines; everything else is ignored by it
	-- (Roblox system messages use "Roblox.*").
	METADATA = "HNPC",
}

return Remotes

--!strict
-- Where NpcEvents go: the Output window (print or warn by Config.LogLevel), every subscriber Handle.onEvent
-- registered, and a BindableEvent named Remotes.TELEMETRY when one exists under the Bootstrap script (found
-- by name, no config key). A subscriber that throws is reported once and never breaks the frame. It is not a
-- metrics store (it keeps only counters per event kind) and it is not the trace (Eval/Trace records motion;
-- this records discrete events).
-- requires: Remotes, Types (types)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Parent.Types)
local Remotes = require(ReplicatedStorage.HumanlikeNpcShared.Remotes)

type NpcEvent = Types.NpcEvent

local RobloxTelemetry = {}
RobloxTelemetry.__index = RobloxTelemetry

export type Subscriber = (event: NpcEvent) -> ()

export type Options = {
	logLevel: string?, -- "off" | "warn" | "info" (Config.LogLevel); default "warn"
	host: Instance?, -- where the optional BindableEvent lives (the Bootstrap script); looked up by name
	prefix: string?, -- Output prefix; default "[HumanlikeNpc]"
}

export type Telemetry = typeof(setmetatable(
	{} :: {
		logLevel: string,
		host: Instance?,
		prefix: string,
		subscribers: { Subscriber },
		counts: { [string]: number },
		emitted: number,
		bindable: BindableEvent?,
		warnedSubscriber: boolean,
		warnedBindable: boolean,
	},
	RobloxTelemetry
))

-- Kinds that go to `warn` at level "warn"; everything else is `print` at level "info".
local WARN_KINDS: { [string]: boolean } = { error = true, frameOverBudget = true }

local LEVELS: { [string]: number } = { off = 0, warn = 1, info = 2 }

-- pcall over a function that returns nothing, with the error message as a plain value.
local function try(fn: () -> ()): (boolean, any)
	local results = table.pack(pcall(fn))
	return results[1] == true, results[2]
end

function RobloxTelemetry.new(options: Options?): Telemetry
	local o: Options = options or {}
	return setmetatable({
		logLevel = if LEVELS[o.logLevel or ""] then o.logLevel :: string else "warn",
		host = o.host,
		prefix = o.prefix or "[HumanlikeNpc]",
		subscribers = {},
		counts = {},
		emitted = 0,
		bindable = nil,
		warnedSubscriber = false,
		warnedBindable = false,
	}, RobloxTelemetry)
end

function RobloxTelemetry.setLogLevel(self: Telemetry, level: string)
	if LEVELS[level] then
		self.logLevel = level
	end
end

-- Adds a listener; returns the function that removes it.
function RobloxTelemetry.subscribe(self: Telemetry, fn: Subscriber): () -> ()
	table.insert(self.subscribers, fn)
	return function()
		for i = #self.subscribers, 1, -1 do
			if self.subscribers[i] == fn then
				table.remove(self.subscribers, i)
			end
		end
	end
end

-- One line of text for the Output window.
function RobloxTelemetry.format(event: NpcEvent): string
	local extra = ""
	local data = event.data
	if data then
		local keys: { string } = {}
		for key, value in data do
			if typeof(value) == "string" or typeof(value) == "number" or typeof(value) == "boolean" then
				table.insert(keys, key)
			end
		end
		table.sort(keys)
		local parts: { string } = {}
		for _, key in keys do
			table.insert(parts, `{key}={tostring(data[key])}`)
		end
		if #parts > 0 then
			extra = " " .. table.concat(parts, " ")
		end
	end
	return `{event.kind} {event.npcId} t={string.format("%.2f", event.at)}{extra}`
end

local function findBindable(self: Telemetry): BindableEvent?
	local cached = self.bindable
	if cached and cached.Parent ~= nil then
		return cached
	end
	self.bindable = nil
	local host = self.host
	if host == nil then
		return nil
	end
	local ok, found = pcall(function()
		return host:FindFirstChild(Remotes.TELEMETRY)
	end)
	if ok and found and found:IsA("BindableEvent") then
		self.bindable = found
		return found
	end
	return nil
end

function RobloxTelemetry.emit(self: Telemetry, event: NpcEvent)
	self.emitted += 1
	self.counts[event.kind] = (self.counts[event.kind] or 0) + 1
	local level = LEVELS[self.logLevel] or 1
	if level >= 1 and WARN_KINDS[event.kind] then
		warn(self.prefix .. " " .. RobloxTelemetry.format(event))
	elseif level >= 2 then
		print(self.prefix .. " " .. RobloxTelemetry.format(event))
	end
	for _, subscriber in table.clone(self.subscribers) do
		local ok, err = try(function()
			subscriber(event)
		end)
		if not ok and not self.warnedSubscriber then
			self.warnedSubscriber = true
			warn(`{self.prefix} an onEvent subscriber threw (reported once): {tostring(err)}`)
		end
	end
	local bindable = findBindable(self)
	if bindable then
		local ok, err = try(function()
			bindable:Fire(event)
		end)
		if not ok and not self.warnedBindable then
			self.warnedBindable = true
			warn(`{self.prefix} telemetry BindableEvent threw (reported once): {tostring(err)}`)
		end
	end
end

-- A function Api can hand to the service as `world.telemetry`.
function RobloxTelemetry.sink(self: Telemetry): (event: NpcEvent) -> ()
	return function(event: NpcEvent)
		self:emit(event)
	end
end

function RobloxTelemetry.stats(self: Telemetry): { emitted: number, counts: { [string]: number }, subscribers: number }
	return { emitted = self.emitted, counts = table.clone(self.counts), subscribers = #self.subscribers }
end

function RobloxTelemetry.destroy(self: Telemetry)
	self.subscribers = {}
	self.bindable = nil
end

return RobloxTelemetry

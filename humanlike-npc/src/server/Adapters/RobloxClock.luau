--!strict
-- The Clock port over the engine's clocks: `now` is os.clock (monotonic, sub-millisecond, what every `now`
-- in the core means), `wall` is os.time (seconds since the epoch) and `hour` is the UTC hour of day shifted
-- by Config.LocalHourOffset so the population curve follows the developer's audience, wrapped to 0..24.
-- It holds no state but the offset, never yields and reads no Instance; the Lune fake (FakeWorld) advances
-- its own number instead.
-- requires: Ports (types)

local Ports = require(script.Parent.Parent.Ports)

local RobloxClock = {}
RobloxClock.__index = RobloxClock

export type Options = {
	localHourOffset: number?, -- Config.LocalHourOffset: hours added to UTC, may be negative or fractional
}

export type Clock = typeof(setmetatable({} :: { localHourOffset: number }, RobloxClock))

function RobloxClock.new(options: Options?): Clock
	local o: Options = options or {}
	return setmetatable({ localHourOffset = o.localHourOffset or 0 }, RobloxClock)
end

function RobloxClock.now(self: Clock): number
	return os.clock()
end

function RobloxClock.wall(self: Clock): number
	return os.time()
end

-- Local hour of day in [0, 24): the UTC hour plus the configured offset.
function RobloxClock.hour(self: Clock): number
	return RobloxClock.hourAt(os.time(), self.localHourOffset)
end

-- Pure part of `hour`, for tests: the hour of a wall-clock second plus an offset, wrapped to [0, 24).
function RobloxClock.hourAt(wallSeconds: number, offset: number): number
	local utc = os.date("!*t", wallSeconds)
	return (utc.hour + offset) % 24
end

-- The same object seen as the port (the methods take `self: Clock`; the port takes `self: any`).
function RobloxClock.asPort(self: Clock): Ports.Clock
	return (self :: any) :: Ports.Clock
end

return RobloxClock

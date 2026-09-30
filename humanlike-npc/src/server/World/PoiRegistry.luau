--!strict
-- The places NPCs know about: points of interest the developer tagged (shops, hangouts,
-- viewpoints, objectives), spawn areas, no-go volumes and the seats near the points of interest.
-- Pure data with a few queries; the Roblox adapter fills it from tags and attributes, tests fill
-- it from literals. Seat occupancy lives here too, so two NPCs never pick the same seat.
-- requires: Types

local Types = require(script.Parent.Parent.Types)

type PoiRecord = Types.PoiRecord
type SpawnRecord = Types.SpawnRecord
type AvoidRecord = Types.AvoidRecord
type SeatRecord = Types.SeatRecord

local PoiRegistry = {}
PoiRegistry.__index = PoiRegistry

export type Registry = typeof(setmetatable(
	{} :: {
		pois: { PoiRecord },
		byId: { [string]: PoiRecord },
		spawns: { SpawnRecord },
		avoids: { AvoidRecord },
		occupancy: { [string]: { [string]: boolean } }, -- poi id -> agent ids inside
		-- Seats in the order they were added; `seats()` returns this list. (It cannot be called
		-- `seats` itself: a field of that name would shadow the method on the metatable.)
		seatList: { SeatRecord },
		seatOccupants: { [string]: string }, -- seat id -> agent id sitting there
	},
	PoiRegistry
))

PoiRegistry.POI_TAG = "NpcPoi"
PoiRegistry.SPAWN_TAG = "NpcSpawn"
PoiRegistry.AVOID_TAG = "NpcAvoid"

local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function PoiRegistry.new(): Registry
	return setmetatable({
		pois = {},
		byId = {},
		spawns = {},
		avoids = {},
		occupancy = {},
		seatList = {},
		seatOccupants = {},
	}, PoiRegistry)
end

function PoiRegistry.addPoi(self: Registry, poi: PoiRecord)
	if self.byId[poi.id] then
		self:removePoi(poi.id)
	end
	table.insert(self.pois, poi)
	self.byId[poi.id] = poi
	self.occupancy[poi.id] = {}
end

function PoiRegistry.removePoi(self: Registry, id: string)
	self.byId[id] = nil
	self.occupancy[id] = nil
	for i, poi in self.pois do
		if poi.id == id then
			table.remove(self.pois, i)
			return
		end
	end
end

function PoiRegistry.addSpawn(self: Registry, spawn: SpawnRecord)
	table.insert(self.spawns, spawn)
end

function PoiRegistry.addAvoid(self: Registry, avoid: AvoidRecord)
	table.insert(self.avoids, avoid)
end

function PoiRegistry.get(self: Registry, id: string): PoiRecord?
	return self.byId[id]
end

function PoiRegistry.all(self: Registry): { PoiRecord }
	return self.pois
end

function PoiRegistry.byKind(self: Registry, kind: string): { PoiRecord }
	local out = {}
	for _, poi in self.pois do
		if poi.kind == kind then
			table.insert(out, poi)
		end
	end
	return out
end

-- Nearest POI to a position, optionally excluding one id and limiting to a kind.
function PoiRegistry.nearest(self: Registry, position: Vector3, excludeId: string?, kind: string?): (PoiRecord?, number)
	local best: PoiRecord? = nil
	local bestDistance = math.huge
	for _, poi in self.pois do
		if poi.id == excludeId or (kind and poi.kind ~= kind) then
			continue
		end
		local d = (Vector3.new(poi.position.X, 0, poi.position.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
		if d < bestDistance then
			best, bestDistance = poi, d
		end
	end
	return best, bestDistance
end

-- POIs within `radius` studs, nearest first.
function PoiRegistry.within(self: Registry, position: Vector3, radius: number): { PoiRecord }
	local out = {}
	for _, poi in self.pois do
		local d = (Vector3.new(poi.position.X, 0, poi.position.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
		if d <= radius then
			table.insert(out, poi)
		end
	end
	table.sort(out, function(a, b)
		return (a.position - position).Magnitude < (b.position - position).Magnitude
	end)
	return out
end

function PoiRegistry.enter(self: Registry, poiId: string, agentId: string)
	local set = self.occupancy[poiId]
	if set then
		set[agentId] = true
	end
end

function PoiRegistry.leave(self: Registry, poiId: string, agentId: string)
	local set = self.occupancy[poiId]
	if set then
		set[agentId] = nil
	end
end

function PoiRegistry.occupants(self: Registry, poiId: string): number
	local set = self.occupancy[poiId]
	if not set then
		return 0
	end
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

function PoiRegistry.isFull(self: Registry, poiId: string): boolean
	local poi = self.byId[poiId]
	if not poi or not poi.capacity then
		return false
	end
	return self:occupants(poiId) >= (poi.capacity :: number)
end

-- True when a point lies inside any no-go volume.
function PoiRegistry.isAvoided(self: Registry, point: Vector3): boolean
	for _, avoid in self.avoids do
		local local_ = avoid.cframe:PointToObjectSpace(point)
		local half = avoid.size / 2
		if math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z then
			return true
		end
	end
	return false
end

-- A random point on a spawn area's top surface (uniform in the rectangle).
function PoiRegistry.spawnPoint(self: Registry, u1: number, u2: number, index: number?): Vector3?
	if #self.spawns == 0 then
		return nil
	end
	local spawn = self.spawns[math.clamp(index or 1, 1, #self.spawns)]
	local half = spawn.size / 2
	local x = (u1 * 2 - 1) * math.max(0, half.X - 2)
	local z = (u2 * 2 - 1) * math.max(0, half.Z - 2)
	local point = spawn.cframe:PointToWorldSpace(Vector3.new(x, half.Y, z))
	return point
end

-- Seats -------------------------------------------------------------------------------------

-- Adds a seat, or replaces the record of a seat with the same id (a rescan keeps its occupant).
function PoiRegistry.addSeat(self: Registry, seat: SeatRecord)
	for i, existing in self.seatList do
		if existing.id == seat.id then
			self.seatList[i] = seat
			return
		end
	end
	table.insert(self.seatList, seat)
end

function PoiRegistry.removeSeat(self: Registry, id: string)
	self.seatOccupants[id] = nil
	for i, seat in self.seatList do
		if seat.id == id then
			table.remove(self.seatList, i)
			return
		end
	end
end

-- Every seat, occupied or not, in the order added.
function PoiRegistry.seats(self: Registry): { SeatRecord }
	return self.seatList
end

-- Free seats within `radius` studs (flat distance), nearest first, ties broken by id.
function PoiRegistry.seatsNear(self: Registry, position: Vector3, radius: number): { SeatRecord }
	local found: { { seat: SeatRecord, distance: number } } = {}
	for _, seat in self.seatList do
		if self.seatOccupants[seat.id] ~= nil then
			continue
		end
		local d = flatDistance(seat.position, position)
		if d <= radius then
			table.insert(found, { seat = seat, distance = d })
		end
	end
	table.sort(found, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.seat.id < b.seat.id
	end)
	local out: { SeatRecord } = {}
	for _, entry in found do
		table.insert(out, entry.seat)
	end
	return out
end

-- Claims a seat for `who`. False when someone else already sits there or the seat is unknown;
-- true again for the agent who already holds it.
function PoiRegistry.occupySeat(self: Registry, id: string, who: string): boolean
	local occupant = self.seatOccupants[id]
	if occupant ~= nil then
		return occupant == who
	end
	for _, seat in self.seatList do
		if seat.id == id then
			self.seatOccupants[id] = who
			return true
		end
	end
	return false
end

-- Frees a seat, but only for the agent holding it.
function PoiRegistry.releaseSeat(self: Registry, id: string, who: string)
	if self.seatOccupants[id] == who then
		self.seatOccupants[id] = nil
	end
end

function PoiRegistry.seatOccupant(self: Registry, id: string): string?
	return self.seatOccupants[id]
end

return PoiRegistry

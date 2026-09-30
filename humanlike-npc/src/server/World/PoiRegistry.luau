--!strict
-- The places NPCs know about: points of interest the developer tagged (shops, hangouts,
-- viewpoints, objectives), spawn areas and no-go volumes. Pure data with a few queries; the
-- Roblox adapter fills it from tags and attributes, tests fill it from literals.

local Types = require(script.Parent.Parent.Types)

type PoiRecord = Types.PoiRecord
type SpawnRecord = Types.SpawnRecord
type AvoidRecord = Types.AvoidRecord

local PoiRegistry = {}
PoiRegistry.__index = PoiRegistry

export type Registry = typeof(setmetatable(
	{} :: {
		pois: { PoiRecord },
		byId: { [string]: PoiRecord },
		spawns: { SpawnRecord },
		avoids: { AvoidRecord },
		occupancy: { [string]: { [string]: boolean } }, -- poi id -> agent ids inside
	},
	PoiRegistry
))

PoiRegistry.POI_TAG = "NpcPoi"
PoiRegistry.SPAWN_TAG = "NpcSpawn"
PoiRegistry.AVOID_TAG = "NpcAvoid"

function PoiRegistry.new(): Registry
	return setmetatable({ pois = {}, byId = {}, spawns = {}, avoids = {}, occupancy = {} }, PoiRegistry)
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

return PoiRegistry

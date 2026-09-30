--!strict
-- The shared picture of who is where, rebuilt from the adapter's entity list every step, and the
-- groups that fall out of it (design-mind §4.13.1). A group is nothing more than a connected
-- component of slow-moving entities standing within joinDist of each other: there is no leader
-- and no timer, so rings, contagion and dissolution emerge from what the members do. Groups are
-- recomputed only every 2 s, and a new component inherits the id and birth time of the previous
-- group it shares at least half of its members with, so a group that loses one member is still
-- "the same group" to everyone watching it and its age keeps growing. Players and NPCs are
-- treated alike (DR-48). Pure: plain tables, injected time, no instance API.
-- requires: (none)

local Spatial = {}
Spatial.__index = Spatial

export type Entity = {
	id: string,
	kind: "player" | "npc",
	position: Vector3,
	velocity: Vector3,
	yaw: number,
	displayName: string,
	jumpedAt: number?,
	emoteAt: number?,
	emoteName: string?,
}

export type Group = {
	id: number,
	members: { string }, -- sorted ids
	center: Vector3,
	radius: number,
	age: number, -- seconds since createdAt, refreshed on every recompute
	createdAt: number,
}

export type Spatial = typeof(setmetatable(
	{} :: {
		byId: { [string]: Entity },
		list: { Entity },
		groupList: { Group },
		groupByMember: { [string]: Group },
		nextGroupId: number,
		lastGroupAt: number,
	},
	Spatial
))

local GROUP_INTERVAL = 2 -- seconds between recomputes
local JOIN_DIST = 8 -- studs: link two candidates closer than this
local SLOW_SPEED = 4 -- studs/s: below this an entity is a candidate on its own
local CLOSE_DIST = 6 -- studs: this close to anyone makes a candidate regardless of speed
local MIN_SIZE = 2
local INHERIT_SHARE = 0.5

function Spatial.new(): Spatial
	return setmetatable({
		byId = {},
		list = {},
		groupList = {},
		groupByMember = {},
		nextGroupId = 1,
		lastGroupAt = -math.huge,
	}, Spatial)
end

local function find(parent: { number }, i: number): number
	while parent[i] ~= i do
		parent[i] = parent[parent[i]]
		i = parent[i]
	end
	return i
end

local function union(parent: { number }, a: number, b: number)
	local ra, rb = find(parent, a), find(parent, b)
	if ra ~= rb then
		parent[math.max(ra, rb)] = math.min(ra, rb)
	end
end

local function recomputeGroups(self: Spatial, now: number)
	local list = self.list
	local n = #list

	-- Candidates: slow, or close to anyone at all (§4.13.1).
	local candidate: { boolean } = table.create(n, false)
	for i = 1, n do
		candidate[i] = list[i].velocity.Magnitude < SLOW_SPEED
	end
	for i = 1, n do
		if candidate[i] then
			continue
		end
		for j = 1, n do
			if j ~= i and (list[i].position - list[j].position).Magnitude <= CLOSE_DIST then
				candidate[i] = true
				break
			end
		end
	end

	local parent: { number } = table.create(n, 0)
	for i = 1, n do
		parent[i] = i
	end
	for i = 1, n do
		if not candidate[i] then
			continue
		end
		for j = i + 1, n do
			if candidate[j] and (list[i].position - list[j].position).Magnitude <= JOIN_DIST then
				union(parent, i, j)
			end
		end
	end

	local components: { [number]: { Entity } } = {}
	local order: { number } = {}
	for i = 1, n do
		if not candidate[i] then
			continue
		end
		local root = find(parent, i)
		local bucket = components[root]
		if not bucket then
			bucket = {}
			components[root] = bucket
			table.insert(order, root)
		end
		table.insert(bucket, list[i])
	end

	-- Build the new groups, then decide which previous identity each one carries on.
	type Draft = { members: { string }, center: Vector3, radius: number, best: Group?, shared: number }
	local drafts: { Draft } = {}
	for _, root in order do
		local bucket = components[root]
		if #bucket < MIN_SIZE then
			continue
		end
		local members: { string } = {}
		local sum = Vector3.zero
		for _, e in bucket do
			table.insert(members, e.id)
			sum += e.position
		end
		table.sort(members)
		local center = sum / #bucket
		local radius = 0
		for _, e in bucket do
			radius = math.max(radius, (e.position - center).Magnitude)
		end
		local best: Group? = nil
		local bestShared = 0
		for _, previous in self.groupList do
			local shared = 0
			for _, id in members do
				if self.groupByMember[id] == previous then
					shared += 1
				end
			end
			if shared > bestShared then
				best, bestShared = previous, shared
			end
		end
		if best and bestShared / #members < INHERIT_SHARE then
			best, bestShared = nil, 0
		end
		table.insert(drafts, { members = members, center = center, radius = radius, best = best, shared = bestShared })
	end
	-- When a group splits, the larger remnant keeps the identity.
	table.sort(drafts, function(a, b)
		if a.shared ~= b.shared then
			return a.shared > b.shared
		end
		return a.members[1] < b.members[1]
	end)

	local claimed: { [number]: boolean } = {}
	local groups: { Group } = {}
	local byMember: { [string]: Group } = {}
	for _, draft in drafts do
		local id, createdAt
		local best = draft.best
		if best and not claimed[best.id] then
			claimed[best.id] = true
			id, createdAt = best.id, best.createdAt
		else
			id, createdAt = self.nextGroupId, now
			self.nextGroupId += 1
		end
		local group: Group = {
			id = id,
			members = draft.members,
			center = draft.center,
			radius = draft.radius,
			age = now - createdAt,
			createdAt = createdAt,
		}
		table.insert(groups, group)
		for _, member in draft.members do
			byMember[member] = group
		end
	end
	table.sort(groups, function(a, b)
		return a.id < b.id
	end)
	self.groupList = groups
	self.groupByMember = byMember
	self.lastGroupAt = now
end

-- Stores this step's entities; groups are refreshed at most every 2 s.
function Spatial.update(self: Spatial, entities: { Entity }, now: number)
	local byId: { [string]: Entity } = {}
	local list: { Entity } = {}
	for _, e in entities do
		byId[e.id] = e
		table.insert(list, e)
	end
	self.byId = byId
	self.list = list
	if now - self.lastGroupAt >= GROUP_INTERVAL then
		recomputeGroups(self, now)
	else
		for _, group in self.groupList do
			group.age = now - group.createdAt
		end
	end
end

-- Entities within `radius` of `position`, nearest first (ties broken by id for determinism).
function Spatial.near(self: Spatial, position: Vector3, radius: number, excludeId: string?): { Entity }
	local found: { { entity: Entity, distance: number } } = {}
	for _, e in self.list do
		if e.id == excludeId then
			continue
		end
		local distance = (e.position - position).Magnitude
		if distance <= radius then
			table.insert(found, { entity = e, distance = distance })
		end
	end
	table.sort(found, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.entity.id < b.entity.id
	end)
	local out: { Entity } = {}
	for i, item in found do
		out[i] = item.entity
	end
	return out
end

function Spatial.groups(self: Spatial): { Group }
	return self.groupList
end

function Spatial.groupOf(self: Spatial, id: string): Group?
	return self.groupByMember[id]
end

function Spatial.get(self: Spatial, id: string): Entity?
	return self.byId[id]
end

return Spatial

--!strict
-- The filter between raw player distances and the scheduler's tiers. An NPC a player can see is
-- treated as near however far it stands (a watched NPC must move like a watched one); an NPC
-- whose distance would drop it to a cheaper tier keeps its current one until it has been out of
-- that band for a couple of seconds (a player walking past a boundary, or a brief occlusion, does
-- not flap the rate); and under frame pressure every distance is stretched so that more NPCs
-- fall into the cheaper tiers. It never raycasts, never reads the world and never decides a
-- tier by itself: it returns distances, and Scheduler.assignTiers turns them into tiers with
-- its own hysteresis. `now` is injected; there is no clock here.
-- requires: Scheduler

local Scheduler = require(script.Parent.Scheduler)

local Lod = {}
Lod.__index = Lod

-- Per NPC: flat distance to the nearest player and whether any player has line of sight to it.
export type Input = { id: string, distance: number, visible: boolean }

export type Options = {
	visibleRange: number?, -- studs; a visible NPC no farther than this is promoted; default 250
	downgradeDelay: number?, -- seconds out of the band before a demotion passes; default 2
	near: number?, -- tier thresholds, the same numbers the scheduler was given; default 60
	mid: number?, -- default 200
	far: number?, -- default 500
}

export type Resolved = {
	visibleRange: number,
	downgradeDelay: number,
	near: number,
	mid: number,
	far: number,
}

export type LodT = typeof(setmetatable(
	{} :: {
		o: Resolved,
		-- When the NPC's distance first left its held band, while it is still out of it.
		lastAbove: { [string]: number },
		-- The band each NPC is held in ("near" | "mid" | "far" | "dormant"), from the last call.
		tier: { [string]: Scheduler.Tier },
		pressure: number, -- 0..1
	},
	Lod
))

local RANK: { [Scheduler.Tier]: number } = { near = 1, mid = 2, far = 3, dormant = 4 }

function Lod.new(opts: Options?): LodT
	local o: Options = opts or {}
	local d = Scheduler.DEFAULTS
	local resolved: Resolved = {
		visibleRange = o.visibleRange or 250,
		downgradeDelay = o.downgradeDelay or 2,
		near = o.near or d.near,
		mid = o.mid or d.mid,
		far = o.far or d.far,
	}
	return setmetatable({ o = resolved, lastAbove = {}, tier = {}, pressure = 0 }, Lod)
end

-- Frame pressure 0..1 from the service (§4.5); distances are scaled by 1 / (1 - 0.5 * p).
function Lod.setPressure(self: LodT, p: number)
	self.pressure = math.clamp(p, 0, 1)
end

local function bandOf(o: Resolved, distance: number): Scheduler.Tier
	if distance < o.near then
		return "near"
	elseif distance < o.mid then
		return "mid"
	elseif distance < o.far then
		return "far"
	end
	return "dormant"
end

-- A distance just inside the band's upper edge: what a held NPC reports.
local function heldDistance(o: Resolved, tier: Scheduler.Tier): number
	local edge = if tier == "near" then o.near elseif tier == "mid" then o.mid else o.far
	return math.max(0, edge - 1)
end

-- One distance per input id, ready for Scheduler.assignTiers:
--   visible and distance <= visibleRange  -> min(distance, near - 1)          (promoted to near)
--   a distance that would demote          -> held just inside the current band until it has been
--                                            out of it for downgradeDelay seconds; promotion is immediate
--   every result                          -> scaled by 1 / (1 - 0.5 * pressure)
-- Inputs are read in order; the result is keyed by id, so no hash order leaks into it.
function Lod.effectiveDistances(self: LodT, inputs: { Input }, now: number): { [string]: number }
	local o = self.o
	local scale = 1 / (1 - 0.5 * self.pressure)
	local result: { [string]: number } = {}
	for _, input in inputs do
		local id = input.id
		local distance = input.distance
		if input.visible and distance <= o.visibleRange then
			distance = math.min(distance, o.near - 1)
		end
		local band = bandOf(o, distance)
		local held = self.tier[id]
		if held == nil or RANK[band] <= RANK[held] then
			-- First sighting, same band or a promotion: take it now.
			self.tier[id] = band
			self.lastAbove[id] = nil
		else
			local since = self.lastAbove[id]
			if since == nil then
				since = now
				self.lastAbove[id] = now
			end
			if now - since >= o.downgradeDelay then
				self.tier[id] = band
				self.lastAbove[id] = nil
			else
				distance = heldDistance(o, held)
			end
		end
		result[id] = distance * scale
	end
	return result
end

-- The band an NPC is currently held in, or nil when it has never been seen.
function Lod.tierOf(self: LodT, id: string): Scheduler.Tier?
	return self.tier[id]
end

-- Drops everything remembered about an NPC; call on despawn.
function Lod.forget(self: LodT, id: string)
	self.tier[id] = nil
	self.lastAbove[id] = nil
end

return Lod

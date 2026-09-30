-- Scripted fake players for FakeWorld. Each helper returns a PlayerScript (id, displayName,
-- position, update) whose `update(player, world, now, dt)` runs every frame and moves the player
-- by writing its position, velocity and yaw, the way a real client drives a character; `world` is
-- the FakeWorld, so a script can look up NPC bodies and speak through the service. The wanderer and
-- the follower reproduce the scripts Integration.spec inlined, so switching to these helpers
-- changes no outcome; the starer, the head-jumper and the talker are the stimuli the Senses
-- detectors and the chat path react to (spec §3.4). Plain data only: no instances, no yields.

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local ScriptedPlayer = {}

export type PlayerScript = {
	id: string,
	displayName: string,
	position: any,
	update: (player: any, world: any, now: number, dt: number) -> (),
}

-- A chat line for `talker`: `{ t = 5, text = "hi" }` or positional `{ 5, "hi" }`.
export type Line = { t: number?, text: string?, [number]: any }

local WANDER_SPEED = 16
local FOLLOW_SPEED = 20
local STARE_SPEED = 16
local HOP_INTERVAL = 0.8
local HEAD_HEIGHT = 4.5 -- studs above the NPC's root: inside the Senses on-head band (3.5 .. 6.5)

local function flatTo(from: any, to: any): any
	return Vector3.new(to.X - from.X, 0, to.Z - from.Z)
end

local function face(player: any, dir: any)
	player.yaw = math.atan2(-dir.X, -dir.Z)
end

local function stand(player: any)
	player.velocity = Vector3.zero
end

-- Walks between `a` and `b`, switching target every 20 s, at `speed` (16), and hops now and then.
function ScriptedPlayer.wanderer(id: string, name: string, a: any, b: any, speed: number?): PlayerScript
	local walk = speed or WANDER_SPEED
	return {
		id = id,
		displayName = name,
		position = a,
		update = function(p, _, now, dt)
			local target = if math.floor(now / 20) % 2 == 0 then b else a
			local d = flatTo(p.position, target)
			if d.Magnitude > 1 then
				p.position = p.position + d.Unit * walk * dt
				p.velocity = d.Unit * walk
				face(p, d.Unit)
			else
				stand(p)
			end
			if math.floor(now * 10) % 150 == 0 then
				p.jumpedAt = now
			end
		end,
	}
end

-- Stands at `at` (the origin by default) until `fromT`, then tails the NPC `targetNpc` from `gap`
-- studs behind at `speed` (20), stopping when it is close enough.
function ScriptedPlayer.follower(
	id: string,
	name: string,
	targetNpc: string,
	gap: number,
	fromT: number,
	at: any?,
	speed: number?
): PlayerScript
	local run = speed or FOLLOW_SPEED
	return {
		id = id,
		displayName = name,
		position = at or Vector3.zero,
		update = function(p, world, now, dt)
			local body = world.bodies[targetNpc]
			if not body or now < fromT then
				stand(p)
				return
			end
			local d = flatTo(p.position, body.position)
			if d.Magnitude > gap then
				p.position = p.position + d.Unit * math.min(run * dt, d.Magnitude - gap)
				p.velocity = d.Unit * run
				face(p, d.Unit)
			else
				stand(p)
			end
		end,
	}
end

-- Walks up to `distance` studs from the NPC, then stands still facing it (the Senses "stared"
-- detector wants 3 .. 6 studs, no motion and a look within about 30 degrees for 3 s).
function ScriptedPlayer.starer(id: string, name: string, targetNpc: string, distance: number, at: any?): PlayerScript
	return {
		id = id,
		displayName = name,
		position = at or Vector3.zero,
		update = function(p, world, _now, dt)
			local body = world.bodies[targetNpc]
			if not body then
				stand(p)
				return
			end
			local d = flatTo(p.position, body.position)
			local dist = d.Magnitude
			if dist > distance + 0.5 then
				p.position = p.position + d.Unit * math.min(STARE_SPEED * dt, dist - distance)
				p.velocity = d.Unit * STARE_SPEED
				face(p, d.Unit)
			else
				stand(p)
				if dist > 1e-3 then
					face(p, d.Unit)
				end
			end
		end,
	}
end

-- Runs onto the NPC and stands on its head (4.5 studs up, within the on-head radius), hopping
-- every 0.8 s so `jumpedAt` keeps firing; it rides along when the NPC walks.
function ScriptedPlayer.jumperOnHead(id: string, name: string, targetNpc: string, at: any?): PlayerScript
	local lastHop = -math.huge
	return {
		id = id,
		displayName = name,
		position = at or Vector3.zero,
		update = function(p, world, now, dt)
			local body = world.bodies[targetNpc]
			if not body then
				stand(p)
				return
			end
			local d = flatTo(p.position, body.position)
			if d.Magnitude > 1 then
				local step = d.Unit * math.min(FOLLOW_SPEED * dt, d.Magnitude)
				p.position = Vector3.new(p.position.X + step.X, body.position.Y, p.position.Z + step.Z)
				p.velocity = d.Unit * FOLLOW_SPEED
				face(p, d.Unit)
			else
				p.position = body.position + Vector3.new(0, HEAD_HEIGHT, 0)
				stand(p)
				if now - lastHop >= HOP_INTERVAL then
					lastHop = now
					p.jumpedAt = now
				end
			end
		end,
	}
end

-- Stands at `at` and says each line at its time `t` (world seconds), through `world:playerSays`
-- so the service hears it the way a real player's chat arrives.
function ScriptedPlayer.talker(id: string, name: string, at: any, lines: { Line }): PlayerScript
	local queue: { { t: number, text: string } } = {}
	for _, line in lines do
		table.insert(queue, { t = line.t or line[1], text = line.text or line[2] })
	end
	table.sort(queue, function(x, y)
		return x.t < y.t
	end)
	local nextIndex = 1
	return {
		id = id,
		displayName = name,
		position = at,
		update = function(p, world, now, _dt)
			stand(p)
			while queue[nextIndex] and queue[nextIndex].t <= now do
				local line = queue[nextIndex]
				nextIndex += 1
				local index = table.find(world.players, p)
				if index and world.playerSays then
					world:playerSays(index, line.text)
				else
					world.service:onPlayerChat(string.sub(p.id, 3), line.text, p.position, now)
				end
			end
		end,
	}
end

return ScriptedPlayer

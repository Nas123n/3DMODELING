--!strict
-- What the NPC notices, as raw events for the reaction queue to delay or drop (design-mind §4.6.1,
-- §4.6.2). A person does not see everything around them: sight is a 120 degree cone in front,
-- plus a 15% chance per entity, rerolled every 2 s, that the camera happened to show what was
-- behind them, and a wall in the way (the injected occlusion callback) hides the entity for as
-- long as the raycast budget lets us check. Someone counts as newly appeared once, and again only
-- after half a minute out of view; someone counts as gone after three seconds unseen. Chat is
-- heard within the bubble range or, briefly, while the NPC is "reading the chat window", a state
-- PC players enter far more often than mobile players and that grows with chat volume. The social
-- detectors run over the same near list: being followed, blocked, stared at, stood on, bumped
-- into and a fresh group nearby, each with its own dwell condition and per-subject cooldown so a
-- single stimulus never spams the queue. With attention off (a fully AFK NPC) sightings are still
-- recorded but nothing is reported except a line that names the NPC: an AFK player does not
-- notice a follower, but does notice their name. Pure: injected now and dt, seeded rng, no
-- instance API.
-- requires: NavMath, Rng, Spatial, Memory, Personality, Reaction, Reply

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Spatial = require(script.Parent.Parent.World.Spatial)
local Reply = require(script.Parent.Parent.Chat.Reply)
local Memory = require(script.Parent.Memory)
local Personality = require(script.Parent.Personality)
local Reaction = require(script.Parent.Reaction)

type Rng = Rng.Rng
type Persona = Personality.Persona
type Entity = Spatial.Entity
type Group = Spatial.Group
type Memory = Memory.Memory

local Senses = {}
Senses.__index = Senses

-- Raw events for Reaction.push (§4.6.4), which adds the delay and the chance of missing them.
export type Event = Reaction.Event

-- A heard line; lineId is the corpus id when an NPC said it (Types.ChatEvent.lineId), so the
-- brain can echo corpus lines and never a player's bytes.
export type Chat = { fromId: string, text: string, position: Vector3, at: number, lineId: string? }

-- The NPC itself; the names are only needed to recognise a line aimed at it while attention is off.
export type Me = {
	id: string,
	position: Vector3,
	heading: Vector3,
	moving: boolean,
	velocity: Vector3,
	displayName: string?,
	username: string?,
}

export type SenseInput = {
	me: Me,
	entities: { Entity }, -- near me, excluding me
	chats: { Chat },
	groups: { Group },
	now: number,
	dt: number,
	occlusion: ((from: Vector3, to: Vector3) -> boolean)?, -- true when the line of sight is blocked
	raycastBudget: number?, -- occlusion calls allowed this step; nil = unlimited
	locomotion: { blockedBy: string?, velocityJump: number? }?,
	-- The brain's suppress.attention (a full AFK): record sightings, report only lines naming me.
	attentionOff: boolean?,
}

type Trail = { since: number, moved: number }
type BehindRoll = { at: number, aware: boolean }

export type Senses = typeof(setmetatable(
	{} :: {
		rng: Rng,
		persona: Persona,
		seen: { [string]: number }, -- last time each entity was visible
		visible: { [string]: boolean }, -- last step's verdict
		occluded: { [string]: boolean }, -- last raycast verdict, kept when the budget runs out
		behindRolls: { [string]: BehindRoll },
		leftEmitted: { [string]: boolean },
		reactedJumpAt: { [string]: number },
		reactedEmoteAt: { [string]: number },
		trails: { [string]: Trail }, -- followed: how long and how far someone has been behind me
		stareSince: { [string]: number },
		onHeadSince: { [string]: number },
		cooldowns: { [string]: number }, -- "<kind>:<id>" -> until
		bumpTimes: { number },
		groupsSeen: { [number]: boolean },
		chatTimes: { number }, -- chats heard in the last minute (volume)
		readingUntil: number,
		lastPosition: Vector3?,
		lastPruneAt: number,
	},
	Senses
))

-- Sight (§4.6.1)
local SIGHT_CONE_COS = math.cos(math.rad(120 / 2))
local BEHIND_AWARENESS = 0.15
local BEHIND_ROLL_INTERVAL = 2
local EYE = Vector3.new(0, 1.5, 0)
local REAPPEAR_AFTER = 30
local LEFT_AFTER = 3
local RECENT_ACT = 0.5 -- jumps and emotes older than this are stale
local JUMP_RANGE = 20
local EMOTE_RANGE = 25
-- Hearing and reading (§4.6.1)
local HEAR_RANGE = 100
local READ_RATE_PC = 0.12 -- windows per minute
local READ_RATE_MOBILE = 0.04
local CHAT_VOLUME_WINDOW = 60
-- Detectors (§4.6.2)
local FOLLOW_RANGE = 10
local FOLLOW_BEHIND_DOT = -0.3
local FOLLOW_TIME = 5
local FOLLOW_MOVED = 15
local FOLLOW_COOLDOWN = 30
local BLOCKED_COOLDOWN = 8
local STARE_SPEED = 1
local STARE_MIN, STARE_MAX = 3, 6
local STARE_DOT = 0.85
local STARE_TIME = 3
local STARE_COOLDOWN = 45
local ONHEAD_MIN_DY, ONHEAD_MAX_DY = 3.5, 6.5
local ONHEAD_RADIUS = 2
local ONHEAD_TIME = 1
local ONHEAD_COOLDOWN = 20
local BUMP_JUMP = 6
local BUMP_RANGE = 4
local BUMP_COOLDOWN = 5
local BUMP_WINDOW = 30
local GROUP_MIN_SIZE = 3
local GROUP_RANGE = 40
local GROUP_FRESH = 10
-- Housekeeping
local PRUNE_INTERVAL = 10
local FORGET_AFTER = 60

function Senses.new(rng: Rng, persona: Persona): Senses
	return setmetatable({
		rng = rng,
		persona = persona,
		seen = {},
		visible = {},
		occluded = {},
		behindRolls = {},
		leftEmitted = {},
		reactedJumpAt = {},
		reactedEmoteAt = {},
		trails = {},
		stareSince = {},
		onHeadSince = {},
		cooldowns = {},
		bumpTimes = {},
		groupsSeen = {},
		chatTimes = {},
		readingUntil = -math.huge,
		lastPosition = nil,
		lastPruneAt = -math.huge,
	}, Senses)
end

function Senses.isReading(self: Senses, now: number): boolean
	return now < self.readingUntil
end

local function onCooldown(self: Senses, key: string, now: number): boolean
	local untilTime = self.cooldowns[key]
	return untilTime ~= nil and now < untilTime
end

local function countSince(times: { number }, since: number): number
	local count = 0
	for _, t in times do
		if t >= since then
			count += 1
		end
	end
	return count
end

local function pruneTimes(times: { number }, since: number)
	local i = 1
	while i <= #times do
		if times[i] < since then
			table.remove(times, i)
		else
			i += 1
		end
	end
end

-- Drops the state of entities that have been out of the picture for a minute.
local function prune(self: Senses, present: { [string]: boolean }, now: number)
	local keep: { [string]: boolean } = table.clone(present)
	for id, last in self.seen do
		if now - last <= FORGET_AFTER then
			keep[id] = true
		end
	end
	local tables: { { [string]: any } } = {
		self.seen,
		self.visible,
		self.occluded,
		self.behindRolls,
		self.leftEmitted,
		self.reactedJumpAt,
		self.reactedEmoteAt,
		self.trails,
		self.stareSince,
		self.onHeadSince,
	}
	for _, t in tables do
		for id in t do
			if not keep[id] then
				t[id] = nil
			end
		end
	end
	for key, untilTime in self.cooldowns do
		if untilTime < now then
			self.cooldowns[key] = nil
		end
	end
end

-- Whether a heard line names the NPC (Reply's rule), given the names are known.
local function namesMe(me: Me, text: string): boolean
	local displayName, username = me.displayName, me.username
	if displayName == nil or username == nil then
		return false
	end
	return Reply.isNamed(Reply.normalize(text), displayName, username)
end

function Senses.step(self: Senses, input: SenseInput, memory: Memory, attachmentId: string?): { Event }
	local now, me = input.now, input.me
	local attentive = input.attentionOff ~= true
	local events: { Event } = {}
	local function emit(kind: string, salience: number, subject: string?, expected: boolean?, data: any?)
		if not attentive and kind ~= "chatHeard" then
			return
		end
		local event: Event = {
			kind = kind :: string,
			salience = salience,
			expected = expected,
			subject = subject,
			at = now,
			data = data,
		}
		table.insert(events, event)
	end

	local moved = if self.lastPosition then (me.position - self.lastPosition).Magnitude else 0
	self.lastPosition = me.position
	local heading = NavMath.flat(me.heading)
	heading = if heading.Magnitude > 1e-6 then heading.Unit else Vector3.zero
	local budget = input.raycastBudget or math.huge
	local present: { [string]: boolean } = {}
	local followers: { string } = {}
	local nearestId: string? = nil
	local nearestDist = math.huge

	for _, e in input.entities do
		if e.id == me.id then
			continue
		end
		present[e.id] = true
		local toE = e.position - me.position
		local dist = toE.Magnitude
		local flatTo = NavMath.flat(toE)
		local flatDir = if flatTo.Magnitude > 1e-6 then flatTo.Unit else Vector3.zero
		local facing = if flatDir == Vector3.zero or heading == Vector3.zero then 1 else flatDir:Dot(heading)

		-- Sight
		local inCone = facing >= SIGHT_CONE_COS
		local behind = false
		if not inCone then
			local roll = self.behindRolls[e.id]
			if roll == nil or now - roll.at >= BEHIND_ROLL_INTERVAL then
				roll = { at = now, aware = self.rng:chance(BEHIND_AWARENESS) }
				self.behindRolls[e.id] = roll
			end
			behind = roll.aware
		end
		local visible = inCone or behind
		if visible and input.occlusion then
			if budget > 0 then
				budget -= 1
				self.occluded[e.id] = input.occlusion(me.position + EYE, e.position + EYE)
			end
			-- Budget gone and never checked: not seen until a ray says otherwise.
			local occluded = self.occluded[e.id]
			visible = occluded == false
		end
		local newlySeen = Memory.observe(memory, now, e.id, e.kind, e.position, visible)
		local last = self.seen[e.id]
		if visible then
			if newlySeen or last == nil or now - last > REAPPEAR_AFTER then
				local salience = if attachmentId == e.id then 0.6 else 0.3
				emit("entityAppeared", salience, e.id, true, { position = e.position, distance = dist, kind = e.kind })
			end
			local jumpedAt = e.jumpedAt
			if
				jumpedAt
				and now - jumpedAt < RECENT_ACT
				and dist <= JUMP_RANGE
				and self.reactedJumpAt[e.id] ~= jumpedAt
			then
				self.reactedJumpAt[e.id] = jumpedAt
				emit("entityJumped", 0.2, e.id, nil, { position = e.position, distance = dist })
			end
			local emoteAt = e.emoteAt
			if
				emoteAt
				and now - emoteAt < RECENT_ACT
				and dist <= EMOTE_RANGE
				and self.reactedEmoteAt[e.id] ~= emoteAt
			then
				self.reactedEmoteAt[e.id] = emoteAt
				emit("entityEmoted", 0.3, e.id, nil, { position = e.position, distance = dist, emote = e.emoteName })
			end
			self.seen[e.id] = now
			self.leftEmitted[e.id] = nil
		elseif last ~= nil and now - last > LEFT_AFTER and not self.leftEmitted[e.id] then
			self.leftEmitted[e.id] = true
			emit("entityLeft", 0.1, e.id, nil, { position = e.position, distance = dist })
		end
		self.visible[e.id] = visible

		-- followed: behind me and close, continuously, while I actually go somewhere
		if
			attentive
			and dist <= FOLLOW_RANGE
			and flatDir ~= Vector3.zero
			and heading ~= Vector3.zero
			and facing < FOLLOW_BEHIND_DOT
		then
			local trail = self.trails[e.id]
			if trail == nil then
				trail = { since = now, moved = 0 }
				self.trails[e.id] = trail
			end
			trail.moved += moved
			if
				now - trail.since >= FOLLOW_TIME
				and trail.moved >= FOLLOW_MOVED
				and not onCooldown(self, `followed:{e.id}`, now)
			then
				table.insert(followers, e.id)
			end
		else
			self.trails[e.id] = nil
		end

		-- stared: standing still at a conversational distance, facing me
		local staring = false
		if attentive and e.velocity.Magnitude < STARE_SPEED and dist >= STARE_MIN and dist <= STARE_MAX then
			local theirLook = NavMath.dirFromYaw(e.yaw)
			staring = theirLook:Dot(-flatDir) > STARE_DOT
		end
		if staring then
			local since = self.stareSince[e.id]
			if since == nil then
				since = now
				self.stareSince[e.id] = since
			end
			if now - since >= STARE_TIME and not onCooldown(self, `stared:{e.id}`, now) then
				self.cooldowns[`stared:{e.id}`] = now + STARE_COOLDOWN
				self.stareSince[e.id] = nil
				emit("stared", 0.4, e.id, false, { distance = dist })
			end
		else
			self.stareSince[e.id] = nil
		end

		-- onHead: right above me for a second
		local dy = e.position.Y - me.position.Y
		if attentive and dy >= ONHEAD_MIN_DY and dy <= ONHEAD_MAX_DY and flatTo.Magnitude < ONHEAD_RADIUS then
			local since = self.onHeadSince[e.id]
			if since == nil then
				since = now
				self.onHeadSince[e.id] = since
			end
			if now - since >= ONHEAD_TIME and not onCooldown(self, `onHead:{e.id}`, now) then
				self.cooldowns[`onHead:{e.id}`] = now + ONHEAD_COOLDOWN
				self.onHeadSince[e.id] = nil
				emit("onHead", 0.5, e.id, nil, { dy = dy })
			end
		else
			self.onHeadSince[e.id] = nil
		end

		if dist < nearestDist then
			nearestId, nearestDist = e.id, dist
		end
	end

	-- Someone who walked out of the near list altogether has left too.
	for id, last in self.seen do
		if not present[id] and now - last > LEFT_AFTER and not self.leftEmitted[id] then
			self.leftEmitted[id] = true
			self.visible[id] = false
			emit("entityLeft", 0.1, id, nil, nil)
		end
	end

	if #followers > 0 then
		local salience = if #followers >= 2 then 0.7 else 0.5
		for _, id in followers do
			self.cooldowns[`followed:{id}`] = now + FOLLOW_COOLDOWN
			self.trails[id] = nil
			emit("followed", salience, id, false, { followers = #followers })
		end
	end

	local locomotion = input.locomotion
	if locomotion and attentive then
		local blockedBy = locomotion.blockedBy
		if blockedBy and not onCooldown(self, `blocked:{blockedBy}`, now) then
			self.cooldowns[`blocked:{blockedBy}`] = now + BLOCKED_COOLDOWN
			emit("blocked", 0.6, blockedBy, nil, nil)
		end
		local jump = locomotion.velocityJump
		if
			jump
			and jump > BUMP_JUMP
			and nearestId
			and nearestDist <= BUMP_RANGE
			and not onCooldown(self, "bumped", now)
		then
			self.cooldowns.bumped = now + BUMP_COOLDOWN
			pruneTimes(self.bumpTimes, now - BUMP_WINDOW)
			table.insert(self.bumpTimes, now)
			local salience = if #self.bumpTimes >= 3 then 0.5 else 0.2
			emit("bumped", salience, nearestId, nil, { velocityJump = jump, count = #self.bumpTimes })
		end
	end

	for _, group in input.groups do
		if not attentive then
			break
		end
		if self.groupsSeen[group.id] or #group.members < GROUP_MIN_SIZE or now - group.createdAt > GROUP_FRESH then
			continue
		end
		if (group.center - me.position).Magnitude <= GROUP_RANGE then
			self.groupsSeen[group.id] = true
			emit("groupNearby", 0.3, nil, nil, { groupId = group.id, center = group.center, size = #group.members })
		end
	end

	-- Hearing: the bubble range, or anything at all while reading the window.
	local reading = self:isReading(now)
	for _, chat in input.chats do
		if chat.fromId == me.id then
			continue
		end
		local distance = (chat.position - me.position).Magnitude
		if distance <= HEAR_RANGE or reading then
			-- With attention off only a line that names me gets through.
			local named = namesMe(me, chat.text)
			if not attentive and not named then
				continue
			end
			table.insert(self.chatTimes, now)
			emit("chatHeard", 0.25, chat.fromId, nil, {
				text = chat.text,
				position = chat.position,
				distance = distance,
				lineId = chat.lineId,
				named = named,
			})
		end
	end
	pruneTimes(self.chatTimes, now - CHAT_VOLUME_WINDOW)

	-- Reading window: a Poisson process whose rate depends on the input device and on chat volume.
	if not reading and attentive then
		local kind = self.persona.profile.kind
		local rate = if kind == "pc" or kind == "pcShiftLock" then READ_RATE_PC else READ_RATE_MOBILE
		local volume = countSince(self.chatTimes, now - CHAT_VOLUME_WINDOW)
		rate *= math.clamp(volume / 6, 0.3, 2)
		local p = 1 - math.exp(-rate * input.dt / 60)
		if self.rng:chance(p) then
			self.readingUntil = now + self.rng:logNormalClamped(4, 0.6, 1, 15)
		end
	end

	if now - self.lastPruneAt >= PRUNE_INTERVAL then
		self.lastPruneAt = now
		prune(self, present, now)
	end
	return events
end

return Senses

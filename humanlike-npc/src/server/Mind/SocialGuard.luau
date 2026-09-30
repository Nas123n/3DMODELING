--!strict
-- The rules that keep an NPC from ever becoming a nuisance, enforced in the core where no
-- adapter can bypass them: one follow episode per target, at most two unanswered direct
-- messages, an immediate and permanent back-off on any "stop"-like message, a cap on verbal
-- reactions to probes, and never two spontaneous lines in a row at the same person, and never a
-- second rude line at the same person in a session. Relations (affinity, annoyance) live here
-- too so moods and utilities can read them. This is not the reply decision (Chat/Reply).
-- requires: Reply

local Reply = require(script.Parent.Parent.Chat.Reply)

local SocialGuard = {}
SocialGuard.__index = SocialGuard

export type Relation = {
	affinity: number, -- 0..1
	annoyance: number, -- 0..1
	blocked: boolean, -- said stop: never target again
	followEpisodes: number,
	unansweredDirect: number,
	lastDirectAt: number?,
	probeReplies: number, -- verbal reactions to probes this session
	lastProbeReplyAt: { [string]: number }, -- per probe kind
	lastDecayAt: number,
	rudeAt: number?, -- when a rude line went to this person; set once, never cleared this session
}

export type Guard = typeof(setmetatable(
	{} :: {
		relations: { [string]: Relation },
		lastSpontaneousTarget: string?,
		attachment: string?,
		avoidance: string?,
	},
	SocialGuard
))

function SocialGuard.new(): Guard
	return setmetatable({ relations = {}, lastSpontaneousTarget = nil, attachment = nil, avoidance = nil }, SocialGuard)
end

function SocialGuard.relation(self: Guard, id: string, now: number): Relation
	local r = self.relations[id]
	if not r then
		r = {
			affinity = 0,
			annoyance = 0,
			blocked = false,
			followEpisodes = 0,
			unansweredDirect = 0,
			lastDirectAt = nil,
			probeReplies = 0,
			lastProbeReplyAt = {},
			lastDecayAt = now,
			rudeAt = nil,
		}
		self.relations[id] = r
	end
	return r
end

-- Affinity and annoyance fade with a 5-minute time constant.
function SocialGuard.decay(self: Guard, now: number)
	for id, r in self.relations do
		local dt = now - r.lastDecayAt
		if dt > 0 then
			local k = math.exp(-dt / 300)
			r.affinity *= k
			r.annoyance *= k
			r.lastDecayAt = now
		end
		if self.attachment == id and r.affinity < 0.2 then
			self.attachment = nil
		end
	end
end

function SocialGuard.canFollow(self: Guard, id: string, now: number): boolean
	local r = self:relation(id, now)
	return not r.blocked and r.followEpisodes < 1
end

function SocialGuard.beginFollow(self: Guard, id: string, now: number)
	self:relation(id, now).followEpisodes += 1
end

function SocialGuard.canDirectMessage(self: Guard, id: string, now: number): boolean
	local r = self:relation(id, now)
	if r.blocked or r.unansweredDirect >= 2 then
		return false
	end
	return self.lastSpontaneousTarget ~= id
end

-- Records a line said to a target (spontaneous or reply); `rude` marks a rude corpus line, which
-- this person then never gets again (see wasRudeTo).
function SocialGuard.saidTo(self: Guard, id: string, now: number, spontaneous: boolean, rude: boolean?)
	local r = self:relation(id, now)
	r.unansweredDirect += 1
	r.lastDirectAt = now
	if spontaneous then
		self.lastSpontaneousTarget = id
	end
	if rude then
		r.rudeAt = now
	end
end

-- True once a rude line was said to this person in this session.
function SocialGuard.wasRudeTo(self: Guard, id: string): boolean
	local r = self.relations[id]
	return r ~= nil and r.rudeAt ~= nil
end

-- The target said something (anything): within a minute of my line it counts as an answer.
function SocialGuard.heardFrom(self: Guard, id: string, text: string, now: number, aimedAtMe: boolean)
	local r = self:relation(id, now)
	if r.lastDirectAt and now - r.lastDirectAt < 60 then
		r.unansweredDirect = 0
	end
	if aimedAtMe then
		r.affinity = math.min(1, r.affinity + 0.15)
	end
	local normalized = Reply.normalize(text)
	for _, keyword in Reply.STOP_KEYWORDS do
		if string.find(normalized, keyword, 1, true) and aimedAtMe then
			self:block(id, now)
			return
		end
	end
end

-- Permanent back-off: no following, watching, mirroring or messaging this person again.
function SocialGuard.block(self: Guard, id: string, now: number)
	local r = self:relation(id, now)
	r.blocked = true
	r.annoyance = math.min(1, r.annoyance + 0.5)
	self.avoidance = id
	if self.attachment == id then
		self.attachment = nil
	end
end

function SocialGuard.isBlocked(self: Guard, id: string): boolean
	local r = self.relations[id]
	return r ~= nil and r.blocked
end

-- Someone probed me (followed, blocked, stared, bumped, asked if I am a bot). Returns whether a
-- verbal reaction is allowed: once per kind per minute, three per subject per session.
function SocialGuard.onProbe(self: Guard, id: string, kind: string, now: number): boolean
	local r = self:relation(id, now)
	local bump = if kind == "blocked" then 0.35 elseif kind == "botProbe" then 0.3 else 0.2
	r.annoyance = math.min(1, r.annoyance + bump)
	if r.probeReplies >= 3 then
		return false
	end
	local last = r.lastProbeReplyAt[kind]
	if last and now - last < 60 then
		return false
	end
	r.lastProbeReplyAt[kind] = now
	r.probeReplies += 1
	return true
end

-- They mirrored me or shared a group with me: warmth.
function SocialGuard.warm(self: Guard, id: string, amount: number, now: number)
	local r = self:relation(id, now)
	if r.blocked then
		return
	end
	r.affinity = math.min(1, r.affinity + amount)
	if r.affinity >= 0.5 and self.attachment == nil then
		self.attachment = id
	end
end

function SocialGuard.forget(self: Guard, id: string)
	self.relations[id] = nil
	if self.attachment == id then
		self.attachment = nil
	end
	if self.avoidance == id then
		self.avoidance = nil
	end
end

function SocialGuard.maxAnnoyance(self: Guard): number
	local max = 0
	for _, r in self.relations do
		max = math.max(max, r.annoyance)
	end
	return max
end

return SocialGuard

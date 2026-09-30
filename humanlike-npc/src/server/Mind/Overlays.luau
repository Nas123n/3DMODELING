--!strict
-- Behaviour that runs on top of whatever activity is current: talking (spontaneous spurts,
-- replies, the typing freeze), mirroring nearby people (a copied jump a second later, a copied
-- emote, an echoed line, a shadowed step), emoting, and fidgeting (jump bursts, shift-lock
-- yaw sweeps, the abrupt wake after AFK). Each overlay returns at most one intent override and
-- some actions; the activity's suppression flags are honoured so an AFK NPC stays dead still.

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Timing = require(script.Parent.Parent.Timing)
local JumpHabit = require(script.Parent.Parent.Human.JumpHabit)
local Composer = require(script.Parent.Parent.Chat.Composer)
local Reply = require(script.Parent.Parent.Chat.Reply)
local Recency = require(script.Parent.Parent.Chat.Recency)
local Safety = require(script.Parent.Parent.Chat.Safety)
local Mood = require(script.Parent.Mood)
local SocialGuard = require(script.Parent.SocialGuard)
local Activities = require(script.Parent.Activities)

type Rng = Rng.Rng
type Intent = Activities.Intent
type Action = Activities.Action

local Overlays = {}
Overlays.__index = Overlays

export type ChatShared = {
	recency: Recency.Tracker,
	safety: Safety.Gate,
	-- Server-wide rate limiter: true when one more line may be sent now.
	allow: (npcId: string, now: number) -> boolean,
}

export type Context = {
	now: number,
	dt: number,
	rng: Rng,
	persona: any,
	me: { id: string, position: Vector3, heading: Vector3, displayName: string, username: string },
	moving: boolean,
	onGround: boolean,
	mood: string,
	phase: string,
	activity: string?,
	suppress: { [string]: boolean },
	inGroup: boolean,
	groupMembers: { [string]: boolean },
	playersWithin30: number,
	playersWithin100: number,
	nearbyName: string?, -- display name of the nearest visible entity
	entity: (id: string) -> any?,
	guard: SocialGuard.Guard,
	attachment: string?,
	chat: ChatShared,
	events: { any }, -- reaction events delivered this step
	wakeBurst: boolean?,
	fellNearby: boolean?,
}

export type Output = {
	intent: Intent?,
	actions: { Action },
	typing: boolean,
}

type Pending = { at: number, text: string, lineId: string, target: string?, category: string, resumeAt: number }

export type State = typeof(setmetatable(
	{} :: {
		rng: Rng,
		persona: any,
		jumpHabit: JumpHabit.Habit,
		-- talk
		nextEpisodeAt: number,
		talkativeUntil: number,
		lineBurst: Timing.Burst,
		pending: Pending?,
		freezeUntil: number,
		freezeVariant: string,
		probedBy: { [string]: boolean },
		lastLineAt: number,
		-- mirror
		mirrorQueue: {
			{
				at: number,
				kind: string,
				name: string?,
				dir: Vector3?,
				category: string?,
				echo: string?,
				movingAtSchedule: boolean,
			}
		},
		lastMirrorAt: number,
		mirrorsThisMinute: { number },
		-- emote
		emoteUntil: number,
		-- fidget
		nextYawAt: number,
		yawUntil: number,
		yawTarget: number?,
		wasMoving: boolean,
	},
	Overlays
))

local function u(rng: Rng, lo: number, hi: number): number
	return rng:range(lo, hi)
end

local function episodeGap(rng: Rng, chattiness: number): number
	return rng:logNormalClamped(600, 0.9, 120, 3600) / (0.2 + chattiness * 2)
end

function Overlays.new(rng: Rng, persona: any, now: number): State
	local self = setmetatable({
		rng = rng,
		persona = persona,
		jumpHabit = JumpHabit.new(rng:fork("jumps"), persona.profile, now, persona.jumpTier),
		nextEpisodeAt = now + episodeGap(rng:fork("talk"), persona.chattiness) * rng:range(0.1, 1),
		talkativeUntil = 0,
		lineBurst = Timing.newBurst(rng:fork("lines"), {
			interMedian = 25,
			interSpread = 0.7,
			withinMean = 6,
			withinDev = 2,
			withinLo = 3,
			withinHi = 12,
			lengthP = 0.45,
			maxLength = 4,
			interLo = 5,
			interHi = 300,
		}, now),
		pending = nil,
		freezeUntil = -math.huge,
		freezeVariant = "still",
		probedBy = {},
		lastLineAt = -math.huge,
		mirrorQueue = {},
		lastMirrorAt = -math.huge,
		mirrorsThisMinute = {},
		emoteUntil = -math.huge,
		nextYawAt = now + rng:logNormalClamped(6, 0.8, 2, 40),
		yawUntil = 0,
		yawTarget = nil,
		wasMoving = false,
	}, Overlays)
	return self
end

-- Queues a line for sending after its typing time, freezing movement meanwhile.
local function schedule(
	self: State,
	ctx: Context,
	text: string,
	lineId: string,
	category: string,
	target: string?,
	addressed: boolean
)
	local rng = self.rng
	local latency = Reply.latency(text, self.persona.voice, rng, addressed)
	local at = ctx.now + latency
	local variant = "still"
	if not self.persona.profile.analog and ctx.moving and rng:chance(0.15) then
		variant = "walkStraight"
	end
	self.pending = {
		at = at,
		text = text,
		lineId = lineId,
		target = target,
		category = category,
		resumeAt = at + u(rng, 0.5, 2.0),
	}
	self.freezeUntil = (self.pending :: Pending).resumeAt
	self.freezeVariant = variant
end

local function compose(self: State, ctx: Context, category: string?, target: string?, echo: string?): Composer.Composed?
	local targetName = if target then (ctx.entity(target) or {}).displayName else nil
	return Composer.compose({
		npcId = ctx.me.id,
		voice = self.persona.voice,
		rng = self.rng,
		now = ctx.now,
		category = category,
		mood = ctx.mood,
		phase = ctx.phase,
		accountAge = self.persona.accountAge,
		trolliness = self.persona.trolliness,
		nearbyName = targetName or ctx.nearbyName,
		echoSource = echo,
		allowRude = self.persona.trolliness > 0.6 and ctx.mood ~= "social",
	}, ctx.chat.recency, ctx.chat.safety)
end

-- An activity or a probe asks for a specific kind of line now.
function Overlays.forceLine(self: State, ctx: Context, category: string, target: string?)
	if ctx.suppress.talk then
		return
	end
	if target and not ctx.guard:canDirectMessage(target, ctx.now) then
		return
	end
	local composed = compose(self, ctx, category, target, nil)
	if composed then
		schedule(self, ctx, composed.text, composed.lineId, composed.category, target, true)
	end
end

-- Something was said within earshot: maybe reply.
local function onHeard(self: State, ctx: Context, ev: any)
	local data = ev.data or {}
	local text = data.text or ""
	local fromId = ev.subject
	if not fromId or not text then
		return
	end
	local classified = Reply.classify(text, ctx.me.displayName, ctx.me.username, data.distance)
	ctx.guard:heardFrom(fromId, text, ctx.now, classified.named or classified.kind == "stopKeyword")
	if classified.kind == "stopKeyword" then
		return
	end
	local relation = ctx.guard:relation(fromId, ctx.now)
	local traits = {
		chattiness = self.persona.chattiness,
		helpfulness = self.persona.helpfulness,
		dialect = self.persona.dialect,
		annoyance = relation.annoyance,
		moodChat = Mood.multiplier(ctx.mood, "chat"),
		blocked = relation.blocked or not ctx.guard:canDirectMessage(fromId, ctx.now),
	}
	local probedBefore = self.probedBy[fromId] == true
	local p, category = Reply.decide(classified.kind, traits, probedBefore)
	if classified.kind == "botProbe" then
		self.probedBy[fromId] = true
		if ctx.guard:onProbe(fromId, "botProbe", ctx.now) == false then
			return
		end
	end
	if ctx.suppress.talk or not self.rng:chance(p) then
		return
	end
	if category == "help" then
		-- Vague most of the time, wrong sometimes: real knowledge is rare.
		category = "help"
	end
	local composed = compose(self, ctx, category, fromId, nil)
	if composed then
		schedule(
			self,
			ctx,
			composed.text,
			composed.lineId,
			composed.category,
			fromId,
			classified.named or classified.kind ~= "broadcast"
		)
	end
end

local function tickTalk(self: State, ctx: Context, out: Output)
	local rng = self.rng
	local p = self.persona
	for _, ev in ctx.events do
		if ev.kind == "chatHeard" or ev.kind == "chatAddressed" then
			onHeard(self, ctx, ev)
		end
	end

	-- Send what is ready.
	local pending = self.pending
	if pending and ctx.now >= pending.at then
		self.pending = nil
		if ctx.chat.allow(ctx.me.id, ctx.now) and not ctx.suppress.talk then
			table.insert(
				out.actions,
				{ kind = "say", text = pending.text, lineId = pending.lineId, target = pending.target }
			)
			ctx.chat.safety:record(ctx.me.id, pending.lineId, pending.text, ctx.now, pending.target)
			if pending.target then
				ctx.guard:saidTo(pending.target, ctx.now, pending.category ~= "probe")
			end
			self.lastLineAt = ctx.now
			-- Tagged lines sometimes get the "tags" follow-up; other lines a fragment follow-up.
			if string.match(pending.text, "^[# ]+$") and rng:chance(0.4) then
				local follow = compose(self, ctx, "tagged", nil, nil)
				if follow then
					schedule(self, ctx, follow.text, follow.lineId, follow.category, nil, true)
				end
			elseif rng:chance(0.25) and pending.category ~= "leaving" then
				local follow = compose(self, ctx, pending.category, pending.target, nil)
				if follow then
					schedule(self, ctx, follow.text, follow.lineId, follow.category, pending.target, true)
				end
			end
		end
	end

	-- Typing freeze.
	if ctx.now < self.freezeUntil then
		out.typing = true
		if p.profile.typingFreezes then
			out.intent = { kind = "freeze", duration = self.freezeUntil - ctx.now, variant = self.freezeVariant }
		end
	end

	-- Spontaneous episodes for chatters.
	if p.chattiness < 0.2 or ctx.suppress.talk or self.pending then
		return
	end
	if ctx.now >= self.nextEpisodeAt then
		self.talkativeUntil = ctx.now + rng:logNormalClamped(60, 0.8, 15, 300)
		self.nextEpisodeAt = self.talkativeUntil + episodeGap(rng, p.chattiness)
	end
	if ctx.now < self.talkativeUntil then
		local contextMul = math.clamp(0.3 + 0.15 * ctx.playersWithin100, 0.3, 1.6)
		if ctx.activity == "JoinGroup" or ctx.activity == "FaceOff" then
			contextMul *= 1.5
		end
		local moodMul = Mood.multiplier(ctx.mood, "chat")
		if self.lineBurst:poll(ctx.now) and rng:chance(contextMul * moodMul) then
			local target: string? = nil
			if ctx.nearbyName and rng:chance(0.3) then
				-- Address the nearest person only when the guard allows it.
				for id in ctx.groupMembers do
					if ctx.guard:canDirectMessage(id, ctx.now) then
						target = id
						break
					end
				end
			end
			local composed = compose(self, ctx, nil, target, nil)
			if composed then
				schedule(self, ctx, composed.text, composed.lineId, composed.category, target, false)
			end
		end
	end
end

local function tickMirror(self: State, ctx: Context, out: Output)
	local rng = self.rng
	local p = self.persona
	if ctx.suppress.mirror then
		return
	end
	-- Prune the per-minute log.
	local log = self.mirrorsThisMinute
	while #log > 0 and ctx.now - log[1] > 60 do
		table.remove(log, 1)
	end
	local moodMul = Mood.multiplier(ctx.mood, "mirror")
	for _, ev in ctx.events do
		local subject = ev.subject
		if not subject or ctx.guard:isBlocked(subject) then
			continue
		end
		local entity = ctx.entity(subject)
		if not entity or NavMath.flatDistance(entity.position, ctx.me.position) > 12 then
			continue
		end
		local base = (0.15 + 0.6 * p.mirroring)
			* moodMul
			* (if ctx.groupMembers[subject] then 1.5 else 1)
			* (if ctx.attachment == subject then 1.4 else 1)
		if ev.kind == "entityJumped" and rng:chance(base) then
			self.jumpHabit:mirror(ctx.now)
		elseif ev.kind == "entityEmoted" and rng:chance(base * 0.8) then
			local name = if rng:chance(0.7)
				then (ev.data and ev.data.name) or "dance"
				else rng:pick({ "dance", "wave", "laugh" })
			table.insert(self.mirrorQueue, {
				at = ctx.now + rng:exGaussian(3.5, 1.0, 2.0, 2),
				kind = "emote",
				name = name,
				movingAtSchedule = ctx.moving,
			})
		elseif ev.kind == "chatHeard" and ev.data and ev.data.text and #ev.data.text <= 12 then
			if rng:chance(0.08 + 0.3 * p.mirroring * p.chattiness) then
				table.insert(
					self.mirrorQueue,
					{ at = ctx.now + u(rng, 3, 10), kind = "echo", echo = ev.data.text, movingAtSchedule = ctx.moving }
				)
			end
		end
	end
	-- Shadow the attachment's small moves while idle.
	if ctx.attachment and not ctx.moving then
		local a = ctx.entity(ctx.attachment)
		if
			a
			and NavMath.flatDistance(a.position, ctx.me.position) <= 12
			and NavMath.flat(a.velocity).Magnitude > 3
			and rng:chance(ctx.dt * 0.15)
		then
			table.insert(self.mirrorQueue, {
				at = ctx.now + u(rng, 0.8, 2),
				kind = "step",
				dir = NavMath.flat(a.velocity).Unit,
				movingAtSchedule = false,
			})
		end
	end
	-- Fire due mirrors, with caps and dropout.
	for i = #self.mirrorQueue, 1, -1 do
		local m = self.mirrorQueue[i]
		if ctx.now < m.at then
			continue
		end
		table.remove(self.mirrorQueue, i)
		if ctx.now - self.lastMirrorAt < 4 or #log >= 6 then
			continue
		end
		if ctx.moving ~= m.movingAtSchedule and rng:chance(0.35) then
			continue
		end
		self.lastMirrorAt = ctx.now
		table.insert(log, ctx.now)
		if m.kind == "emote" and not ctx.moving and not out.typing then
			table.insert(out.actions, { kind = "emote", name = m.name, cutAfter = rng:logNormalClamped(4, 0.7, 1, 10) })
		elseif m.kind == "echo" and not self.pending and not ctx.suppress.talk then
			local composed = compose(self, ctx, "echo", nil, m.echo)
			if composed then
				schedule(self, ctx, composed.text, composed.lineId, "echo", nil, true)
			end
		elseif m.kind == "step" and not out.intent then
			out.intent = { kind = "step", dir = m.dir, duration = u(rng, 0.3, 0.8) }
		end
	end
end

local function tickEmote(self: State, ctx: Context, out: Output)
	local rng = self.rng
	local p = self.persona
	if ctx.suppress.emote or ctx.moving or out.typing or not ctx.onGround then
		return
	end
	if ctx.fellNearby and rng:chance(0.25 * (0.5 + p.trolliness + p.emoteHabit)) then
		table.insert(out.actions, { kind = "emote", name = "laugh", cutAfter = rng:logNormalClamped(3, 0.5, 1.5, 6) })
		self.emoteUntil = ctx.now + 3
		return
	end
	local perMinute = if ctx.inGroup then 0.5 + 1.5 * p.emoteHabit else 0.05 + 0.15 * p.emoteHabit
	local rate = perMinute * Mood.multiplier(ctx.mood, "emote") / 60
	if ctx.now < self.emoteUntil or not rng:chance(ctx.dt * rate) then
		return
	end
	local name
	if ctx.inGroup then
		name = ({ "dance", "dance2", "dance3", "wave", "laugh", "cheer" })[rng:weightedIndex({ 3, 2, 2, 1, 1, 1 })]
	else
		name = ({ "wave", "point", "dance", "laugh", "cheer" })[rng:weightedIndex({ 1, 1, 2, 1, 1 })]
	end
	local cutAfter = if ctx.inGroup and string.sub(name, 1, 5) == "dance"
		then rng:logNormalClamped(12, 0.9, 2, 60)
		else rng:logNormalClamped(4, 0.7, 1, 10)
	table.insert(out.actions, { kind = "emote", name = name, cutAfter = cutAfter })
	self.emoteUntil = ctx.now + cutAfter
end

local function tickFidget(self: State, ctx: Context, out: Output)
	local rng = self.rng
	local p = self.persona
	self.jumpHabit:setMood(ctx.mood, ctx.now)
	if ctx.suppress.fidget then
		return
	end
	if ctx.wakeBurst then
		ctx.wakeBurst = false
		if not out.intent then
			if rng:chance(0.6) then
				out.intent = { kind = "jump" }
			else
				out.intent = { kind = "step", dir = ctx.me.heading, duration = 0.15 }
			end
		end
		return
	end
	local contextMul = if ctx.playersWithin30 >= 1 then 1 else 0.6
	local typing = out.typing
	if self.jumpHabit:poll(ctx.now, ctx.moving, ctx.onGround, typing) and rng:chance(contextMul) then
		if not out.intent then
			out.intent = { kind = "jump" }
			if not ctx.moving and p.profile.strafes and rng:chance(0.25) then
				self.yawTarget = NavMath.yawOf(ctx.me.heading) + math.pi
				self.yawUntil = ctx.now + 0.3
			end
		end
	end
	-- Shift-lock yaw sweeps while idle and bored or social.
	if
		p.profile.strafes
		and not ctx.moving
		and (ctx.mood == "bored" or ctx.mood == "social")
		and ctx.now >= self.nextYawAt
	then
		self.yawTarget = NavMath.yawOf(ctx.me.heading) + math.rad(u(rng, 10, 60)) * rng:sign()
		self.yawUntil = ctx.now + u(rng, 0.5, 2)
		self.nextYawAt = ctx.now + rng:logNormalClamped(6, 0.8, 2, 40)
	end
	if self.yawTarget and ctx.now < self.yawUntil and not out.intent then
		out.intent = { kind = "face", yaw = self.yawTarget }
	elseif self.yawTarget and ctx.now >= self.yawUntil then
		self.yawTarget = nil
	end
end

-- Runs all overlays in order: talk (may freeze), mirror, emote, fidget.
function Overlays.tick(self: State, ctx: Context): Output
	local out: Output = { intent = nil, actions = {}, typing = false }
	tickTalk(self, ctx, out)
	tickMirror(self, ctx, out)
	tickEmote(self, ctx, out)
	tickFidget(self, ctx, out)
	self.wasMoving = ctx.moving
	return out
end

function Overlays.isTyping(self: State, now: number): boolean
	return now < self.freezeUntil
end

function Overlays.hasPendingLine(self: State): boolean
	return self.pending ~= nil
end

return Overlays

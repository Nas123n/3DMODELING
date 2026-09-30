--!strict
-- Behaviour that runs on top of whatever activity is current: talking (spontaneous spurts,
-- replies, the typing freeze planned by Chat/TypingFreeze and the typing-indicator action that
-- brackets every line), mirroring nearby people (a copied jump a second later, a copied emote,
-- an echoed corpus line, a shadowed step), emoting, and fidgeting (jump bursts, shift-lock yaw
-- sweeps, the abrupt wake after AFK). Each overlay returns at most one intent override and
-- some actions; the activity's suppression flags are honoured so an AFK NPC stays dead still.
-- Echoes re-render corpus lines looked up by lineId: a player's bytes are never repeated. Two
-- more small things a standing body does: a keyboard walker stops to read the chat window now
-- and then, and anyone steps away from a stranger standing inside their personal space. Only
-- shift-lock profiles ever turn in place; their camera style sets how often.
-- requires: NavMath, Rng, Timing, JumpHabit, ChatCorpus, Composer, Reply, Recency, Safety, TypingFreeze,
-- Mood, SocialGuard, Activities

local NavMath = require(script.Parent.Parent.Nav.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Timing = require(script.Parent.Parent.Timing)
local JumpHabit = require(script.Parent.Parent.Human.JumpHabit)
local ChatCorpus = require(script.Parent.Parent.Chat.ChatCorpus)
local Composer = require(script.Parent.Parent.Chat.Composer)
local Reply = require(script.Parent.Parent.Chat.Reply)
local Recency = require(script.Parent.Parent.Chat.Recency)
local Safety = require(script.Parent.Parent.Chat.Safety)
local TypingFreeze = require(script.Parent.Parent.Chat.TypingFreeze)
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
	-- Chat/ChatGuard.Guard when the service has one (typed loosely: the guard lands separately
	-- and this module only needs guard:allow(npcId, now, isReply)). When present, `allow` is
	-- ignored and the guard decides; it records the line itself when it says yes.
	guard: any?,
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
	poiWord: string?, -- the kind word of the POI the NPC stands at (or its PoiWord), for {poi} lines
	platformFreezes: boolean?, -- false when this place's chat never takes the movement keys
	reading: boolean?, -- senses:isReading(now): a keyboard walker may stop to read
	nearest: Nearest?, -- the closest standing neighbour, for the step-away rule
	knowsPoi: boolean?, -- help.right lines allowed (familiarity > 0.5 and the POI kind was visited)
	interrupted: boolean?, -- a reaction interrupted the activity this step (half-typed lines drop)
}

-- The closest standing neighbour; dir is the unit vector from the NPC toward them; friend is
-- true for the attachment, group members and anyone with real affinity (the caller decides).
export type Nearest = { id: string, distance: number, dir: Vector3, friend: boolean }

export type Output = {
	intent: Intent?,
	actions: { Action },
	typing: boolean,
}

type Pending = {
	at: number,
	text: string,
	lineId: string,
	target: string?,
	category: string,
	resumeAt: number,
	isReply: boolean, -- an answer to a heard line: the guard lets replies past its share rules
	rude: boolean, -- a rude corpus line: the guard records it so the target never gets a second one
}

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
		typingRng: Rng, -- the "typing" stream: every TypingFreeze draw
		typingPlan: TypingFreeze.Plan?, -- how the body waits while the pending line is typed
		typingSignalled: boolean, -- the indicator state last sent as a "typing" action
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
		lastRightAt: number, -- a "right"-tagged line at most once per 10 min
		readingRolled: boolean, -- the reading pause was rolled for the current reading window
		readFreezeUntil: number,
		closeSince: number?, -- since when a stranger has stood inside the personal space
		lastStepAwayAt: number,
		lastActivity: string?, -- to notice the step a ReactProbe starts
	},
	Overlays
))

local RIGHT_LINE_GAP = 600 -- seconds between two "right?" lines from one NPC
local READ_PAUSE_KEYBOARD, READ_PAUSE_THUMBS = 0.3, 0.05 -- per reading window while walking
local STEP_AWAY_AFTER, STEP_AWAY_GAP = 3, 8 -- seconds inside the space before a step; between steps
local DROP_HALF_TYPED = 0.5 -- a half-typed line is abandoned on an interrupt with this chance

local function u(rng: Rng, lo: number, hi: number): number
	return rng:range(lo, hi)
end

local function episodeGap(rng: Rng, chattiness: number): number
	return rng:logNormalClamped(600, 0.9, 120, 3600) / (0.2 + chattiness * 2)
end

-- cameraStyle stretches or shortens the idle yaw sweep gap (shift-lock profiles only, the only
-- ones that sweep): sweeper x0.7, locked x2.5 (and a smaller amplitude), twitchy x0.5.
local function sweepGapScale(persona: any): number
	local style = persona.cameraStyle
	if style == "sweeper" then
		return 0.7
	elseif style == "locked" then
		return 2.5
	elseif style == "twitchy" then
		return 0.5
	end
	return 1
end

function Overlays.new(rng: Rng, persona: any, now: number): State
	-- The draw order below is pinned ("jumps", "talk", "lines" forks, then the first yaw gap).
	-- The typing stream is forked from the talk stream after that stream's only draw, so adding
	-- it moved no value that existed before.
	local jumpHabit = JumpHabit.new(rng:fork("jumps"), persona.profile, now, persona.jumpTier)
	local talkRng = rng:fork("talk")
	local nextEpisodeAt = now + episodeGap(talkRng, persona.chattiness) * rng:range(0.1, 1)
	local lineBurst = Timing.newBurst(rng:fork("lines"), {
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
	}, now)
	local nextYawAt = now + rng:logNormalClamped(6, 0.8, 2, 40) * sweepGapScale(persona)
	local typingRng = talkRng:fork("typing")
	local self = setmetatable({
		rng = rng,
		persona = persona,
		jumpHabit = jumpHabit,
		nextEpisodeAt = nextEpisodeAt,
		talkativeUntil = 0,
		lineBurst = lineBurst,
		pending = nil,
		freezeUntil = -math.huge,
		freezeVariant = "still",
		probedBy = {},
		lastLineAt = -math.huge,
		typingRng = typingRng,
		typingPlan = nil,
		typingSignalled = false,
		mirrorQueue = {},
		lastMirrorAt = -math.huge,
		mirrorsThisMinute = {},
		emoteUntil = -math.huge,
		nextYawAt = nextYawAt,
		yawUntil = 0,
		yawTarget = nil,
		wasMoving = false,
		lastRightAt = -math.huge,
		readingRolled = false,
		readFreezeUntil = -math.huge,
		closeSince = nil,
		lastStepAwayAt = -math.huge,
		lastActivity = nil,
	}, Overlays)
	return self
end

-- Queues a composed line for sending after its typing time. The body follows a TypingFreeze
-- plan until the pinned resume moment after the line is said; the indicator action follows
-- with the tick. A "right"-tagged line starts the NPC's 10 min timer for the next one.
local function schedule(
	self: State,
	ctx: Context,
	composed: Composer.Composed,
	target: string?,
	addressed: boolean,
	isReply: boolean?
)
	local rng = self.rng
	local text = composed.text
	local latency = Reply.latency(text, self.persona.voice, rng, addressed)
	local at = ctx.now + latency
	local plan = TypingFreeze.plan(self.typingRng, self.persona.profile.kind, ctx.moving, latency, ctx.me.heading)
	self.pending = {
		at = at,
		text = text,
		lineId = composed.lineId,
		target = target,
		category = composed.category,
		resumeAt = at + u(rng, 0.5, 2.0),
		isReply = isReply == true,
		rude = composed.rude == true,
	}
	if composed.right then
		self.lastRightAt = ctx.now
	end
	self.freezeUntil = (self.pending :: Pending).resumeAt
	self.freezeVariant = if plan.variant == "heldKey" then "walkStraight" else plan.variant
	-- The freeze ends at resumeAt (pinned); the plan only says how the body waits until then.
	plan.startedAt = ctx.now
	plan.total = if plan.variant == "free" then 0 else self.freezeUntil - ctx.now
	self.typingPlan = plan
end

-- One more line may go out now: the ChatGuard when the service has one, else the plain limiter.
local function allowed(ctx: Context, isReply: boolean): boolean
	local guard = ctx.chat.guard
	if guard ~= nil then
		return guard:allow(ctx.me.id, ctx.now, isReply) == true
	end
	return ctx.chat.allow(ctx.me.id, ctx.now)
end

-- The corpus text behind a heard line's id ("category:text", the Composer's form), with its
-- slots dropped and short enough to be copied; nil for anything that is not a corpus line. This
-- is the only way a heard line reaches an {echo} slot, so a player's bytes are never repeated.
local function echoSource(lineId: any): string?
	if type(lineId) ~= "string" then
		return nil
	end
	local category, text = string.match(lineId, "^([^:]+):(.*)$")
	if not category or not text then
		return nil
	end
	local found = false
	for _, line in ChatCorpus.byCategory(category) do
		if line.text == text then
			found = true
			break
		end
	end
	if not found then
		return nil
	end
	local source = string.gsub(text, "%s*{%w+}%s*", " ")
	source = string.gsub(source, "^%s+", "")
	source = string.gsub(source, "%s+$", "")
	if #source == 0 or #source > 12 then
		return nil
	end
	return source
end

-- Rude corpus lines: only for a persona with the rudeness cap open (trolliness at 0.6 or more),
-- never in a social mood, and never twice at the same person.
local function rudeAllowed(self: State, ctx: Context, target: string?): boolean
	local p = self.persona
	local cap = p.rudenessCap
	local open = if type(cap) == "number" then cap == 1 else p.trolliness > 0.6
	if not open or ctx.mood == "social" then
		return false
	end
	return target == nil or not ctx.guard:wasRudeTo(target)
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
		allowRude = rudeAllowed(self, ctx, target),
		poiWord = ctx.poiWord,
		dialect = self.persona.dialect,
		allowRight = ctx.now - self.lastRightAt >= RIGHT_LINE_GAP,
		knowsPoi = ctx.knowsPoi == true,
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
		-- A probe answer replies to something heard; other forced lines are the NPC's own.
		schedule(self, ctx, composed, target, true, category == "probe")
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
		schedule(self, ctx, composed, fromId, classified.named or classified.kind ~= "broadcast", true)
	end
end

local function tickTalk(self: State, ctx: Context, out: Output)
	local rng = self.rng
	local p = self.persona
	-- A line still being typed when a reaction interrupts (or a ReactProbe starts) is abandoned
	-- half the time: people drop half-typed messages when something happens (§6.3).
	local interrupted = ctx.interrupted == true or (ctx.activity == "ReactProbe" and self.lastActivity ~= "ReactProbe")
	self.lastActivity = ctx.activity
	if interrupted and self.pending and rng:chance(DROP_HALF_TYPED) then
		self.pending = nil
		self.freezeUntil = -math.huge
		self.typingPlan = nil
	end
	for _, ev in ctx.events do
		if ev.kind == "chatHeard" or ev.kind == "chatAddressed" then
			onHeard(self, ctx, ev)
		end
	end

	-- Send what is ready.
	local pending = self.pending
	if pending and ctx.now >= pending.at then
		self.pending = nil
		if not ctx.suppress.talk and allowed(ctx, pending.isReply) then
			table.insert(
				out.actions,
				{ kind = "say", text = pending.text, lineId = pending.lineId, target = pending.target }
			)
			ctx.chat.safety:record(ctx.me.id, pending.lineId, pending.text, ctx.now, pending.target)
			if pending.target then
				ctx.guard:saidTo(pending.target, ctx.now, pending.category ~= "probe", pending.rude)
			end
			self.lastLineAt = ctx.now
			-- Tagged lines sometimes get the "tags" follow-up; other lines a fragment follow-up.
			if string.match(pending.text, "^[# ]+$") and rng:chance(0.4) then
				local follow = compose(self, ctx, "tagged", nil, nil)
				if follow then
					schedule(self, ctx, follow, nil, true)
				end
			elseif rng:chance(0.25) and pending.category ~= "leaving" then
				local follow = compose(self, ctx, pending.category, pending.target, nil)
				if follow then
					schedule(self, ctx, follow, pending.target, true)
				end
			end
		end
	end

	-- Typing freeze: the plan drawn when the line was scheduled says how the body waits. A place
	-- whose chat never takes the movement keys (platformFreezes false) has no freeze at all.
	if ctx.now < self.freezeUntil then
		out.typing = true
		local plan = self.typingPlan
		if p.profile.typingFreezes and ctx.platformFreezes ~= false and plan then
			local intent = TypingFreeze.intent(plan, ctx.now)
			if intent then
				intent.duration = self.freezeUntil - ctx.now
				out.intent = intent
			end
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
				schedule(self, ctx, composed, target, false)
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
		elseif ev.kind == "chatHeard" and ev.data then
			-- Only a corpus line known by its lineId can be echoed, never the heard bytes.
			local source = echoSource(ev.data.lineId)
			if source and rng:chance(0.08 + 0.3 * p.mirroring * p.chattiness) then
				table.insert(
					self.mirrorQueue,
					{ at = ctx.now + u(rng, 3, 10), kind = "echo", echo = source, movingAtSchedule = ctx.moving }
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
				schedule(self, ctx, composed, nil, true)
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
	-- Reading pause (DR-21): a walker who is reading the chat window stops for a moment, rolled
	-- once per reading window; keyboards far more often than thumbs. The runtime counts the
	-- "look" action as readingPause.
	local reading = ctx.reading == true
	if reading and ctx.moving and not self.readingRolled then
		self.readingRolled = true
		local kind = p.profile.kind
		local chance = if kind == "pc" or kind == "pcShiftLock" then READ_PAUSE_KEYBOARD else READ_PAUSE_THUMBS
		if rng:chance(chance) then
			self.readFreezeUntil = ctx.now + rng:logNormalClamped(2, 0.5, 1, 4)
			table.insert(out.actions, { kind = "look", name = "readingPause" })
		end
	elseif not reading then
		self.readingRolled = false
	end
	local readingFreeze = ctx.now < self.readFreezeUntil
	if readingFreeze and not out.intent then
		out.intent = { kind = "freeze", variant = "still", duration = self.readFreezeUntil - ctx.now }
	end
	local contextMul = if ctx.playersWithin30 >= 1 then 1 else 0.6
	local typing = out.typing or readingFreeze
	if self.jumpHabit:poll(ctx.now, ctx.moving, ctx.onGround, typing) and rng:chance(contextMul) then
		if not out.intent then
			out.intent = { kind = "jump" }
			if not ctx.moving and p.profile.strafes and rng:chance(0.25) then
				self.yawTarget = NavMath.yawOf(ctx.me.heading) + math.pi
				self.yawUntil = ctx.now + 0.3
			end
		end
	end
	-- Shift-lock yaw sweeps while idle and bored or social; the camera style sets the gap (and a
	-- locked camera barely moves).
	if
		p.profile.strafes
		and not ctx.moving
		and (ctx.mood == "bored" or ctx.mood == "social")
		and ctx.now >= self.nextYawAt
	then
		local amplitude = if p.cameraStyle == "locked" then u(rng, 5, 25) else u(rng, 10, 60)
		self.yawTarget = NavMath.yawOf(ctx.me.heading) + math.rad(amplitude) * rng:sign()
		self.yawUntil = ctx.now + u(rng, 0.5, 2)
		self.nextYawAt = ctx.now + rng:logNormalClamped(6, 0.8, 2, 40) * sweepGapScale(p)
	end
	if self.yawTarget and ctx.now < self.yawUntil and not out.intent then
		out.intent = { kind = "face", yaw = self.yawTarget }
	elseif self.yawTarget and ctx.now >= self.yawUntil then
		self.yawTarget = nil
	end
end

-- Step-away (DR-17): a stranger standing inside the personal space for a few seconds while the
-- NPC stands gets one short step directly away, at most once every few seconds. Friends (the
-- attachment, group members, anyone the caller marks) may stand close.
local function tickStepAway(self: State, ctx: Context, out: Output)
	local n = ctx.nearest
	local space = self.persona.personalSpace
	if
		n == nil
		or type(space) ~= "number"
		or ctx.moving
		or ctx.suppress.fidget
		or n.friend
		or ctx.groupMembers[n.id]
		or ctx.attachment == n.id
		or n.distance >= space
	then
		self.closeSince = nil
		return
	end
	local since = self.closeSince or ctx.now
	self.closeSince = since
	if ctx.now - since < STEP_AWAY_AFTER or ctx.now - self.lastStepAwayAt < STEP_AWAY_GAP or out.intent then
		return
	end
	local away = -NavMath.flat(n.dir)
	if away.Magnitude < 1e-6 then
		return
	end
	self.lastStepAwayAt = ctx.now
	local studs = u(self.rng, 1, 2)
	out.intent = { kind = "step", dir = away.Unit, duration = studs / (self.persona.walkSpeed or 16) }
end

-- Runs all overlays in order: talk (may freeze), mirror, emote, step-away, fidget.
function Overlays.tick(self: State, ctx: Context): Output
	local out: Output = { intent = nil, actions = {}, typing = false }
	tickTalk(self, ctx, out)
	tickMirror(self, ctx, out)
	tickEmote(self, ctx, out)
	tickStepAway(self, ctx, out)
	tickFidget(self, ctx, out)
	self.wasMoving = ctx.moving
	-- The typing indicator brackets every line: on once a line is queued, off once it was said
	-- or dropped (after the say action of the same tick, which was added first).
	local typingNow = self.pending ~= nil
	if typingNow ~= self.typingSignalled then
		self.typingSignalled = typingNow
		table.insert(out.actions, { kind = "typing", on = typingNow })
	end
	return out
end

function Overlays.isTyping(self: State, now: number): boolean
	return now < self.freezeUntil
end

function Overlays.hasPendingLine(self: State): boolean
	return self.pending ~= nil
end

return Overlays

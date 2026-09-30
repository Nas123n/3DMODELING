--!strict
-- One NPC's mind, stepped a few times a second. Each step: needs drift and the mood is
-- reviewed; events that made it through the reaction delay are weighed against the current
-- activity's resistance; when something interrupts, the activity ends, or a periodic review
-- comes due, the candidate list is scored and one is chosen softly; the activity runs and emits
-- its intent; the overlays add talk, mirroring, emotes and fidgets on top. The spawn ritual
-- (stand still, a first jump or camera spin, maybe "hi", then a short first walk) runs instead
-- of selection during the joining phase.

local Rng = require(script.Parent.Parent.Rng)
local Needs = require(script.Parent.Needs)
local Mood = require(script.Parent.Mood)
local Memory = require(script.Parent.Memory)
local Reaction = require(script.Parent.Reaction)
local Session = require(script.Parent.Session)
local Goals = require(script.Parent.Goals)
local Utility = require(script.Parent.Utility)
local Activities = require(script.Parent.Activities)
local Overlays = require(script.Parent.Overlays)
local SocialGuard = require(script.Parent.SocialGuard)
local NavMath = require(script.Parent.Parent.Nav.NavMath)

type Rng = Rng.Rng
type Candidate = Utility.Candidate
type Scored = Utility.Scored
type Intent = Activities.Intent
type Action = Activities.Action
type Event = Reaction.Event

local Brain = {}
Brain.__index = Brain

export type Input = {
	now: number,
	dt: number,
	me: { id: string, position: Vector3, heading: Vector3, displayName: string, username: string },
	locomotion: Activities.Locomotion,
	world: Goals.World,
	entity: (id: string) -> any?,
	groupOf: (id: string) -> any?,
	events: { Event }, -- raw sensed events this step (before the reaction delay)
	playersWithin30: number,
	playersWithin100: number,
	chat: Overlays.ChatShared,
	fellNearby: boolean?,
}

export type Output = {
	intent: Intent,
	actions: { Action },
	activity: string?,
	target: string?,
	interrupted: boolean,
	typing: boolean,
	phase: string,
	mood: string,
}

export type BrainT = typeof(setmetatable(
	{} :: {
		rng: Rng,
		persona: any,
		needs: Needs.Needs,
		mood: Mood.Mood,
		memory: Memory.Memory,
		reactions: Reaction.Queue,
		session: Session.Session,
		guard: SocialGuard.Guard,
		overlays: Overlays.State,
		activity: Activities.Activity?,
		state: any,
		currentScored: Scored?,
		activityStatus: string,
		startedAt: number,
		nextReviewAt: number,
		forceReselect: boolean,
		ritual: { phase: string, until_: number, done: boolean },
		favoritePoiKind: string?,
		lastForgetAt: number,
		lastDecayAt: number,
		probeTimes: { number },
		recentOtherJumps: { number },
		aboutFaceUntil: number,
		aboutFaceDir: Vector3?,
		excluded: { [string]: number }, -- target -> until
		wakeBurst: boolean,
	},
	Brain
))

local function u(rng: Rng, lo: number, hi: number): number
	return rng:range(lo, hi)
end

function Brain.new(rng: Rng, persona: any, now: number, favoritePoiKind: string?): BrainT
	local self = setmetatable({
		rng = rng,
		persona = persona,
		needs = Needs.new(rng:fork("needs"), persona),
		mood = Mood.new(now, rng:fork("mood")),
		memory = Memory.new(now),
		reactions = Reaction.new(),
		session = Session.new(now, persona, rng:fork("session")),
		guard = SocialGuard.new(),
		overlays = Overlays.new(rng:fork("overlays"), persona, now),
		activity = nil,
		state = nil,
		currentScored = nil,
		activityStatus = "success",
		startedAt = now,
		nextReviewAt = now,
		forceReselect = false,
		ritual = { phase = "still", until_ = now + rng:logNormalClamped(2.5, 0.6, 1, 6), done = false },
		favoritePoiKind = favoritePoiKind,
		lastForgetAt = now,
		lastDecayAt = now,
		probeTimes = {},
		recentOtherJumps = {},
		aboutFaceUntil = -math.huge,
		aboutFaceDir = nil,
		excluded = {},
		wakeBurst = false,
	}, Brain)
	return self
end

local function companionship(self: BrainT, input: Input): number
	if input.groupOf(input.me.id) then
		return 1
	end
	local name = if self.activity then self.activity.name else nil
	if name == "JoinGroup" or name == "FaceOff" or name == "Follow" then
		return 1
	end
	return 0
end

local function moodContext(self: BrainT, input: Input, now: number): Mood.MoodContext
	local recent = 0
	for i = #self.recentOtherJumps, 1, -1 do
		if now - self.recentOtherJumps[i] > 20 then
			table.remove(self.recentOtherJumps, i)
		else
			recent += 1
		end
	end
	local probes = 0
	for i = #self.probeTimes, 1, -1 do
		if now - self.probeTimes[i] > 120 then
			table.remove(self.probeTimes, i)
		else
			probes += 1
		end
	end
	return {
		nearbyCount = #input.world.entities,
		inGroup = input.groupOf(input.me.id) ~= nil,
		recentJumpsAndEmotes = recent,
		probeCount2min = probes,
		activity = if self.activity then self.activity.name else nil,
		maxRelationAnnoyance = self.guard:maxAnnoyance(),
	}
end

-- Side effects of an event on memory, relations and mood; returns the event kind to react to.
local function absorb(self: BrainT, ev: Event, now: number)
	local subject = ev.subject
	if ev.kind == "entityAppeared" and subject then
		self.needs.novelty = math.max(0, self.needs.novelty - 0.05)
	elseif ev.kind == "entityJumped" or ev.kind == "entityEmoted" then
		table.insert(self.recentOtherJumps, now)
	elseif
		ev.kind == "followed"
		or ev.kind == "stared"
		or ev.kind == "onHead"
		or ev.kind == "blocked"
		or ev.kind == "botProbe"
	then
		table.insert(self.probeTimes, now)
		local bump = if ev.kind == "blocked" then 0.35 elseif ev.kind == "botProbe" then 0.3 else 0.2
		Mood.raiseAnnoyance(self.mood, bump, now)
	elseif ev.kind == "chatHeard" and subject and ev.data then
		Memory.recordHeard(self.memory, subject, ev.data.text, "heard", now)
		self.needs.social = math.max(0, self.needs.social - 0.05)
	end
end

local function makeActivityContext(
	self: BrainT,
	input: Input,
	intents: { Intent },
	actions: { Action },
	suppress: { [string]: boolean }
): Activities.Context
	local guard = self.guard
	local now = input.now
	return {
		now = now,
		dt = input.dt,
		rng = self.rng,
		persona = self.persona,
		me = input.me,
		locomotion = input.locomotion,
		world = input.world,
		entity = input.entity,
		memory = self.memory,
		emit = function(intent)
			table.insert(intents, intent)
		end,
		act = function(action)
			table.insert(actions, action)
		end,
		relieve = function(event, context)
			Needs.relieve(self.needs, event, context)
		end,
		suppress = suppress,
		canFollow = function(id)
			return guard:canFollow(id, now)
		end,
		beginFollow = function(id)
			guard:beginFollow(id, now)
		end,
		affinity = function(id)
			return guard:relation(id, now).affinity
		end,
		shiftLock = self.persona.profile.strafes,
		groupOf = input.groupOf,
		inGroup = input.groupOf(input.me.id) ~= nil,
		wakeBurst = self.wakeBurst,
	}
end

local function goalsContext(self: BrainT, input: Input): Goals.Context
	local guard = self.guard
	local now = input.now
	local relations = {}
	for id, r in guard.relations do
		relations[id] = { affinity = r.affinity, annoyance = r.annoyance, blocked = r.blocked }
	end
	local excluded = self.excluded
	local world = input.world
	local failedRecently = world.failedRecently
	return {
		me = input.me,
		persona = self.persona,
		memory = self.memory,
		phase = self.session.phase,
		mood = self.mood.name,
		now = now,
		rng = self.rng,
		world = {
			pois = world.pois,
			poiOccupants = world.poiOccupants,
			entities = world.entities,
			visible = world.visible,
			groups = world.groups,
			myGroup = input.groupOf(input.me.id),
			spawnPoint = world.spawnPoint,
			reachable = world.reachable,
			randomReachable = world.randomReachable,
			sectorCenter = world.sectorCenter,
			nearbySectors = world.nearbySectors,
			totalSectors = world.totalSectors,
			isAvoided = world.isAvoided,
			failedRecently = function(target)
				local until_ = excluded[target]
				if until_ and now < until_ then
					return true
				end
				return failedRecently(target)
			end,
			props = world.props,
			mood = self.mood.name,
		} :: any,
		relations = relations,
		canFollow = function(id)
			return guard:canFollow(id, now)
		end,
		attachment = guard.attachment,
		favoritePoiKind = self.favoritePoiKind,
		fatigue = self.needs.fatigue,
	}
end

local function utilityContext(self: BrainT, now: number): Utility.Context
	local memory = self.memory
	return {
		persona = self.persona,
		needs = self.needs,
		mood = self.mood.name,
		phase = self.session.phase,
		now = now,
		lastEnd = function(activity, target)
			return Memory.lastActivityEnd(memory, activity, target)
		end,
	}
end

local function stopActivity(self: BrainT, ctx: Activities.Context, outcome: string, now: number)
	local activity = self.activity
	if not activity then
		return
	end
	activity.stop(ctx, self.state, outcome)
	local target = if self.currentScored then self.currentScored.candidate.target else nil
	Memory.recordActivity(self.memory, activity.name, target, self.startedAt, now, outcome)
	if outcome == "failed" and target then
		self.excluded[target] = now + 300
	end
	self.activity = nil
	self.state = nil
	self.currentScored = nil
end

local function startActivity(self: BrainT, ctx: Activities.Context, scored: Scored, now: number)
	local activity = Activities.get(scored.candidate.activity)
	if not activity then
		return
	end
	self.activity = activity
	self.state = activity.start(ctx, scored.candidate)
	self.currentScored = scored
	self.startedAt = now
	self.activityStatus = "running"
end

-- The spawn ritual: still, first input, maybe a greeting, then the first short walk.
local function tickRitual(
	self: BrainT,
	input: Input,
	intents: { Intent },
	actions: { Action },
	suppress: { [string]: boolean }
)
	local rng = self.rng
	local now = input.now
	local ritual = self.ritual
	suppress.fidget = true
	suppress.emote = true
	suppress.mirror = true
	if ritual.phase == "still" then
		table.insert(intents, { kind = "hold" })
		if now >= ritual.until_ then
			ritual.phase = "first"
			if rng:chance(0.6) then
				table.insert(intents, { kind = "jump" })
			elseif self.persona.profile.strafes and rng:chance(0.6) then
				table.insert(
					intents,
					{ kind = "face", yaw = NavMath.yawOf(input.me.heading) + math.rad(u(rng, 60, 180)) * rng:sign() }
				)
			else
				table.insert(intents, { kind = "step", dir = input.me.heading, duration = 0.2 })
			end
			ritual.until_ = now + 0.4
		end
	elseif ritual.phase == "first" then
		if now >= ritual.until_ then
			ritual.phase = "done"
			ritual.done = true
			if rng:chance(0.12 + 0.3 * self.persona.chattiness) then
				table.insert(actions, { kind = "forceLine", category = "greeting" })
			end
			Session.finishRitual(self.session)
			self.forceReselect = true
		else
			table.insert(intents, { kind = "hold" })
		end
	end
end

-- The first trip: nearest group or place within 60 studs gets a big bonus.
local function firstTripBonus(self: BrainT, candidates: { Candidate }, input: Input)
	local best: Candidate? = nil
	for _, c in candidates do
		if (c.activity == "JoinGroup" or c.activity == "VisitPoi") and c.distance <= 60 then
			if not best or c.distance < (best :: Candidate).distance then
				best = c
			end
		end
	end
	if not best then
		for _, c in candidates do
			if c.activity == "Wander" then
				best = c
				break
			end
		end
	end
	if best then
		(best :: Candidate).bonus = ((best :: Candidate).bonus or 0) + 3
	end
end

function Brain.step(self: BrainT, input: Input): Output
	local now, dt = input.now, input.dt
	local rng = self.rng
	local persona = self.persona
	local intents: { Intent } = {}
	local actions: { Action } = {}
	local suppress: { [string]: boolean } = {}

	-- 1. Bookkeeping.
	if now - self.lastDecayAt > 5 then
		self.guard:decay(now)
		self.lastDecayAt = now
	end
	if now - self.lastForgetAt > 10 then
		Memory.forget(self.memory, now)
		self.lastForgetAt = now
	end
	local activityName = if self.activity then self.activity.name else "IdleStand"
	local engagement = Needs.ENGAGEMENT[activityName] or 0.5
	local moodName = self.mood.name
	Needs.drift(self.needs, dt, persona, engagement, companionship(self, input), function(key)
		return Mood.multiplier(moodName, key)
	end)
	local phaseChanged = Session.update(self.session, now)
	if phaseChanged and self.session.phase == "leaving" then
		self.forceReselect = true
	end

	-- 2. Events: absorb, queue with reaction delay, then weigh the due ones.
	local salient = false
	for _, ev in input.events do
		absorb(self, ev, now)
		if ev.salience >= 0.6 then
			salient = true
		end
		Reaction.push(self.reactions, ev, now, persona, self.mood.name, rng)
	end
	Mood.update(self.mood, now, self.needs, moodContext(self, input, now), persona, rng, salient)
	local due = Reaction.due(self.reactions, now)
	local pending: Event? = nil
	local resistance = if self.activity then Utility.resistance(self.activity.name, self.state) else 0
	for _, ev in due do
		local score = ev.salience * Utility.sensitivity(ev.kind, persona) * Mood.multiplier(self.mood.name, "interrupt")
		if score > resistance and (pending == nil or ev.salience > (pending :: Event).salience) then
			pending = ev
		end
	end

	local ctx = makeActivityContext(self, input, intents, actions, suppress)

	-- 3. Ritual or (re)selection.
	if not self.ritual.done then
		tickRitual(self, input, intents, actions, suppress)
	else
		-- About-face after an abandon: walk back briefly before choosing again.
		if now < self.aboutFaceUntil then
			table.insert(
				intents,
				{ kind = "step", dir = self.aboutFaceDir or -input.me.heading, duration = self.aboutFaceUntil - now }
			)
		else
			local status = self.activityStatus
			-- Random abandonment of trips.
			if self.activity and self.activity.hasTrip and status == "running" and input.locomotion.moving then
				if rng:chance(dt * (0.004 + 0.012 * persona.impulsivity)) then
					stopActivity(self, ctx, "abandoned", now)
					status = "abandoned"
					if rng:chance(0.5) then
						self.aboutFaceUntil = now + u(rng, 0.8, 2)
						self.aboutFaceDir = -input.me.heading
					end
				end
			end
			if pending or status ~= "running" or self.forceReselect or now >= self.nextReviewAt then
				local candidates = Goals.candidates(goalsContext(self, input), pending)
				if
					self.session.phase == "orienting"
					and self.activity == nil
					and Memory.lastActivityEnd(self.memory, "IdleStand") == nil
					and #self.memory.activities == 0
				then
					firstTripBonus(self, candidates, input)
				end
				local scored = Utility.score(utilityContext(self, now), candidates)
				local current: Scored? = nil
				if self.activity and self.currentScored then
					local c = self.currentScored.candidate
					current = { candidate = c, score = Utility.scoreOne(utilityContext(self, now), c) }
				end
				local forced = pending ~= nil or status ~= "running" or self.forceReselect
				local chosen = Utility.select(scored, current, persona, rng, forced)
				if chosen and chosen ~= current then
					if self.activity then
						stopActivity(self, ctx, if pending then "interrupted" else status, now)
					end
					startActivity(self, ctx, chosen, now)
				elseif chosen == nil and self.activity == nil then
					-- Nothing scored (should not happen: IdleStand always exists).
					startActivity(self, ctx, { candidate = { activity = "IdleStand", distance = 0 }, score = 1 }, now)
				end
				self.nextReviewAt = now + rng:logNormalClamped(1.5, 0.5, 0.5, 4)
				self.forceReselect = false
			end
			-- 4. Run the activity.
			if self.activity then
				ctx.wakeBurst = self.wakeBurst
				local statusNow = self.activity.tick(ctx, self.state)
				self.wakeBurst = ctx.wakeBurst == true
				self.activityStatus = statusNow
				if statusNow ~= "running" then
					stopActivity(self, ctx, statusNow, now)
				end
			end
		end
	end

	-- 5. Overlays.
	local groupMembers: { [string]: boolean } = {}
	local myGroup = input.groupOf(input.me.id)
	if myGroup then
		for _, id in myGroup.members do
			groupMembers[id] = true
		end
	end
	local nearbyName: string? = nil
	for _, e in input.world.entities do
		if input.world.visible[e.id] then
			nearbyName = e.displayName
			break
		end
	end
	local overlayCtx: Overlays.Context = {
		now = now,
		dt = dt,
		rng = rng,
		persona = persona,
		me = input.me,
		moving = input.locomotion.moving,
		onGround = input.locomotion.onGround,
		mood = self.mood.name,
		phase = self.session.phase,
		activity = if self.activity then self.activity.name else nil,
		suppress = suppress,
		inGroup = myGroup ~= nil,
		groupMembers = groupMembers,
		playersWithin30 = input.playersWithin30,
		playersWithin100 = input.playersWithin100,
		nearbyName = nearbyName,
		entity = input.entity,
		guard = self.guard,
		attachment = self.guard.attachment,
		chat = input.chat,
		events = due,
		wakeBurst = self.wakeBurst,
		fellNearby = input.fellNearby,
	}
	-- Forced lines requested by activities go through the overlay's composer.
	for i = #actions, 1, -1 do
		local a = actions[i]
		if a.kind == "forceLine" then
			table.remove(actions, i)
			self.overlays:forceLine(overlayCtx, a.category or "reaction", a.target)
		end
	end
	local overlay = self.overlays:tick(overlayCtx)
	self.wakeBurst = overlayCtx.wakeBurst == true
	for _, a in overlay.actions do
		table.insert(actions, a)
	end

	-- Merge intents: travel from the activity is the base; an activity-level step, jump or face
	-- (a side step, a wiggle) wins over travel this tick; a freeze from typing beats everything;
	-- an overlay jump rides along with travel; overlay steps and faces only fill an idle tick.
	local intent: Intent = intents[#intents] or { kind = "hold" }
	for _, i in intents do
		if i.kind == "goto" or i.kind == "follow" then
			intent = i
		end
	end
	for _, i in intents do
		if i.kind == "step" or i.kind == "jump" then
			intent = i
		elseif i.kind == "face" and intent.kind ~= "goto" and intent.kind ~= "follow" then
			intent = i
		end
	end
	if overlay.intent then
		local o = overlay.intent
		if o.kind == "freeze" then
			intent = o
		elseif o.kind == "jump" then
			if intent.kind == "goto" or intent.kind == "follow" then
				local cloned: any = table.clone(intent)
				cloned.jump = true
				intent = cloned
			else
				intent = o
			end
		elseif (o.kind == "step" or o.kind == "face") and intent.kind == "hold" then
			intent = o
		end
	end

	return {
		intent = intent,
		actions = actions,
		activity = if self.activity then self.activity.name else nil,
		target = if self.currentScored then self.currentScored.candidate.target else nil,
		interrupted = pending ~= nil,
		typing = overlay.typing,
		phase = self.session.phase,
		mood = self.mood.name,
	}
end

-- Locomotion tells the brain a trip failed for good (recovery exhausted) or the body fell.
function Brain.onSystemEvent(self: BrainT, kind: string, now: number, position: Vector3?)
	if kind == "stuck" and position then
		Memory.recordStuck(self.memory, position, now)
	end
	Reaction.push(
		self.reactions,
		{ kind = kind, salience = 1.0, expected = true, at = now },
		now,
		self.persona,
		self.mood.name,
		self.rng
	)
	self.forceReselect = true
	if self.activity then
		self.activityStatus = "failed"
	end
end

function Brain.leaveNow(self: BrainT)
	Session.leaveNow(self.session)
	self.forceReselect = true
end

function Brain.describe(
	self: BrainT
): { activity: string?, target: string?, mood: string, phase: string, needs: Needs.Needs }
	return {
		activity = if self.activity then self.activity.name else nil,
		target = if self.currentScored then self.currentScored.candidate.target else nil,
		mood = self.mood.name,
		phase = self.session.phase,
		needs = self.needs,
	}
end

return Brain

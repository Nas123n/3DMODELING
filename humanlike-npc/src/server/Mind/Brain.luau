--!strict
-- One NPC's mind, stepped a few times a second. Each step: needs drift and the mood is
-- reviewed; events that made it through the reaction delay are weighed against the current
-- activity's resistance; when something interrupts, the activity ends, or a periodic review
-- comes due, the candidate list is scored and one is chosen softly; the activity runs and emits
-- its intent; the overlays add talk, mirroring, emotes and fidgets on top. The spawn ritual
-- (stand still, a first jump or camera spin, maybe "hi", then a short first walk) runs instead
-- of selection during the joining phase. A walking NPC very occasionally changes its mind
-- (random abandonment, at most once per trip, never right after deciding or with the goal in
-- sight); the step that drops a trip is flagged `changedMind`. The first trip after the ritual is
-- always short (nearest place or group, or a wander). In the far and dormant tiers the brain
-- keeps choosing trips but skips overlays and every reaction that is not a system event. The
-- runtime reports what happened to the body (stuck, fell, flung, pushed into a no-go area, a
-- game event) through onSystemEvent, each with its own rule. It is not the body: locomotion,
-- path planning and the humanizer live in Nav/ and Runtime/.
-- requires: Rng, Needs, Mood, Memory, Reaction, Session, Goals, Utility, Activities, Overlays, SocialGuard, NavMath

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

-- The locomotion report, including the distance still to walk (studs along the path; nil when
-- the caller does not know, which never blocks an abandonment). Kept as an alias so callers that
-- named Brain.Locomotion keep working.
export type Locomotion = Activities.Locomotion

export type Input = {
	now: number,
	dt: number,
	me: { id: string, position: Vector3, heading: Vector3, displayName: string, username: string },
	locomotion: Locomotion,
	world: Goals.World,
	entity: (id: string) -> any?,
	groupOf: (id: string) -> any?,
	events: { Event }, -- raw sensed events this step (before the reaction delay)
	playersWithin30: number,
	playersWithin100: number,
	chat: Overlays.ChatShared,
	fellNearby: boolean?,
	tier: string?, -- "near" | "mid" | "far" | "dormant" (Types.Tier); nil behaves as near
	poiWord: string?, -- kind word of the POI the NPC stands at, handed to the talk overlay
	reading: boolean?, -- senses:isReading(now): the reading pause overlay
	nearest: Overlays.Nearest?, -- the closest standing neighbour: the step-away overlay
	platformFreezes: boolean?, -- false when this place's chat never takes the movement keys
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
	changedMind: boolean?, -- true on the step where the brain dropped a running trip
	attentionOff: boolean?, -- a full AFK: pass it to the senses as attentionOff next step
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
		lastTripEndedAt: number,
		firstTripChosen: boolean, -- the first trip after the ritual is restricted (DR-37)
		attentionOff: boolean, -- suppress.attention of the last step (a full AFK)
		deferredReselectAt: number, -- flung: choose again once the body's hold is over
		override: { position: Vector3, until_: number }?, -- avoidExit: walk here before anything else
		queuedActions: { Action }, -- raised by system events, delivered on the next step
	},
	Brain
))

-- Event kinds raised by the runtime rather than sensed; the only ones a far NPC still reacts to.
local SYSTEM_EVENT_KINDS: { [string]: boolean } = {
	stuck = true,
	fell = true,
	flung = true,
	goalInvalid = true,
	avoidExit = true,
	nameCollision = true,
	serverClosing = true,
	kicked = true,
	gameEvent = true,
	pathFailed = true,
}

-- What a far or dormant NPC may still choose: nobody is close enough to watch, so only the
-- trip-shaped activities that keep it moving through the place (and standing still, and leaving).
local QUIET_ACTIVITIES: { [string]: boolean } = {
	VisitPoi = true,
	Wander = true,
	Explore = true,
	IdleStand = true,
	Leave = true,
}

-- Never abandon a trip in its first seconds or once the goal is this close.
local ABANDON_MIN_TRIP_SECONDS = 3
local ABANDON_MIN_REMAINING = 8

-- The first trip after the ritual: the nearest place within this range (bonus 3), the nearest
-- group (bonus 0.5 per member), a wander (Goals draws it within 40 studs) or standing still.
local FIRST_TRIP_POI_RANGE = 60
local FIRST_TRIP_POI_BONUS = 3
local FIRST_TRIP_GROUP_BONUS_PER_MEMBER = 0.5
local FIRST_SELECTION_ALWAYS: { [string]: boolean } =
	{ IdleStand = true, Wander = true, Leave = true, ReactProbe = true }

-- A semi-AFK player notices things, three times later.
local SEMI_AFK_DELAY_SCALE = 3
-- Flung: seconds of the locomotion hold when the runtime does not say (LNc(2, 0.5, 1, 5) median).
local FLUNG_HOLD_DEFAULT = 2
-- avoidExit: how close counts as out, and how long the exit walk may take before giving up.
local OVERRIDE_TOLERANCE = 2
local OVERRIDE_TIMEOUT = 20

local function u(rng: Rng, lo: number, hi: number): number
	return rng:range(lo, hi)
end

local function isQuiet(tier: string?): boolean
	return tier == "far" or tier == "dormant"
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
		lastTripEndedAt = -math.huge,
		firstTripChosen = false,
		attentionOff = false,
		deferredReselectAt = math.huge,
		override = nil,
		queuedActions = {},
	}, Brain)
	return self
end

-- Whether the last step left attention off (Afk with afkStyle "full"): the runtime passes it to
-- the senses as attentionOff so a follower or a stare goes unnoticed while the owner is away.
function Brain.isAttentionOff(self: BrainT): boolean
	return self.attentionOff
end

-- Multiplies the queued delay of an event just pushed, keeping the queue sorted by due time.
local function stretchDelay(queue: Reaction.Queue, ev: Event, now: number, factor: number)
	local pending = queue.pending
	for i, entry in pending do
		if entry.event == ev then
			local stretched: Reaction.Pending = { at = now + (entry.at - now) * factor, event = ev }
			table.remove(pending, i)
			local index = #pending + 1
			while index > 1 and pending[index - 1].at > stretched.at do
				index -= 1
			end
			table.insert(pending, index, stretched)
			return
		end
	end
end

-- A heard line that names the NPC: the senses mark it (data.named) with Reply's rule.
local function namesMe(ev: Event): boolean
	if ev.kind ~= "chatHeard" and ev.kind ~= "chatAddressed" then
		return false
	end
	local data = ev.data
	return type(data) == "table" and data.named == true
end

-- Whether this NPC may give real directions (help.right lines, DR-47): a veteran (familiarity
-- above 0.5) standing at a place whose kind it has visited this session.
local function knowsPoi(self: BrainT, input: Input): boolean
	local familiarity = self.persona.familiarity
	if type(familiarity) ~= "number" or familiarity <= 0.5 then
		return false
	end
	local standing: Goals.Poi? = nil
	for _, poi in input.world.pois do
		if NavMath.flatDistance(poi.position, input.me.position) <= (poi.radius or 6) then
			standing = poi
			break
		end
	end
	if not standing then
		return false
	end
	local kind = (standing :: Goals.Poi).kind
	for _, poi in input.world.pois do
		if poi.kind == kind and Memory.lastVisit(self.memory, poi.id) ~= nil then
			return true
		end
	end
	return false
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
		seats = input.world.seats,
		familiarity = self.persona.familiarity,
		afkStyle = self.persona.afkStyle,
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
			seats = world.seats,
			seatsNear = world.seatsNear,
			occupySeat = world.occupySeat,
			releaseSeat = world.releaseSeat,
			mood = self.mood.name,
		} :: any,
		relations = relations,
		canFollow = function(id)
			return guard:canFollow(id, now)
		end,
		attachment = guard.attachment,
		favoritePoiKind = self.favoritePoiKind,
		fatigue = self.needs.fatigue,
		familiarity = self.persona.familiarity,
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
	if activity.hasTrip and outcome == "success" then
		self.lastTripEndedAt = now
	end
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

-- The first trip after the ritual (DR-37: nobody beelines far in their first seconds). Until a
-- trip-shaped activity has been chosen, the choice is limited to the nearest group (bonus
-- proportional to its size), the nearest place within 60 studs (bonus 3), a wander (drawn within
-- 40 studs) and standing still; interrupt reactions and leaving stay. Everything else is
-- available from the next selection on.
local function restrictFirstSelection(candidates: { Candidate }): { Candidate }
	local nearestGroup: Candidate? = nil
	local nearestPoi: Candidate? = nil
	for _, c in candidates do
		if c.activity == "JoinGroup" then
			if nearestGroup == nil or c.distance < (nearestGroup :: Candidate).distance then
				nearestGroup = c
			end
		elseif c.activity == "VisitPoi" and c.distance <= FIRST_TRIP_POI_RANGE then
			if nearestPoi == nil or c.distance < (nearestPoi :: Candidate).distance then
				nearestPoi = c
			end
		end
	end
	if nearestGroup then
		local g = nearestGroup :: Candidate
		local group = if g.data then g.data.group else nil
		local members = if group and group.members then #group.members else 2
		g.bonus = (g.bonus or 0) + FIRST_TRIP_GROUP_BONUS_PER_MEMBER * members
	end
	if nearestPoi then
		local p = nearestPoi :: Candidate
		p.bonus = (p.bonus or 0) + FIRST_TRIP_POI_BONUS
	end
	local kept: { Candidate } = {}
	for _, c in candidates do
		if FIRST_SELECTION_ALWAYS[c.activity] or c == nearestGroup or c == nearestPoi then
			table.insert(kept, c)
		end
	end
	return kept
end

-- Random abandonment of the running trip: p = dt * (0.002 + 0.006 * impulsivity) per step, never
-- in the first seconds of a trip, never with the goal within a few studs. Since it ends the
-- activity it can fire at most once per trip. Half the time the NPC first walks back for a
-- moment (about-face) before choosing again; otherwise it chooses again on this very step.
-- Returns true when the trip was dropped.
local function maybeAbandon(self: BrainT, input: Input, ctx: Activities.Context): boolean
	local activity = self.activity
	if not activity or not activity.hasTrip or self.activityStatus ~= "running" or not input.locomotion.moving then
		return false
	end
	local now = input.now
	if now - self.startedAt < ABANDON_MIN_TRIP_SECONDS then
		return false
	end
	local remaining = input.locomotion.remaining
	if remaining ~= nil and remaining < ABANDON_MIN_REMAINING then
		return false
	end
	local rng = self.rng
	if not rng:chance(input.dt * (0.002 + 0.006 * self.persona.impulsivity)) then
		return false
	end
	stopActivity(self, ctx, "abandoned", now)
	self.activityStatus = "abandoned"
	if rng:chance(0.5) then
		self.aboutFaceUntil = now + u(rng, 0.4, 0.9)
		self.aboutFaceDir = -input.me.heading
	end
	return true
end

function Brain.step(self: BrainT, input: Input): Output
	local now, dt = input.now, input.dt
	local rng = self.rng
	local persona = self.persona
	local intents: { Intent } = {}
	local actions: { Action } = {}
	local suppress: { [string]: boolean } = {}
	local quiet = isQuiet(input.tier)
	local changedMind = false

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
	-- A flung body waits out its hold before the mind chooses again (§2.15).
	if now >= self.deferredReselectAt then
		self.deferredReselectAt = math.huge
		self.forceReselect = true
	end
	-- Actions raised by system events between steps (a word after a fall).
	for _, a in self.queuedActions do
		table.insert(actions, a)
	end
	table.clear(self.queuedActions)

	-- 2. Events: absorb, queue with reaction delay, then weigh the due ones. Far and dormant
	-- NPCs are not sensed at, so nothing sensed gets in and only system events come due. With
	-- attention off (a full AFK) only system events and lines naming the NPC get in; a semi-AFK
	-- notices everything, three times later.
	local salient = false
	if not quiet then
		local semiAfk = self.activity ~= nil
			and (self.activity :: Activities.Activity).name == "Afk"
			and persona.afkStyle == "semi"
		for _, ev in input.events do
			if self.attentionOff and not SYSTEM_EVENT_KINDS[ev.kind] and not namesMe(ev) then
				continue
			end
			absorb(self, ev, now)
			if ev.salience >= 0.6 then
				salient = true
			end
			if Reaction.push(self.reactions, ev, now, persona, self.mood.name, rng) and semiAfk then
				stretchDelay(self.reactions, ev, now, SEMI_AFK_DELAY_SCALE)
			end
		end
	end
	Mood.update(self.mood, now, self.needs, moodContext(self, input, now), persona, rng, salient)
	local due = Reaction.due(self.reactions, now)
	if quiet then
		local kept: { Event } = {}
		for _, ev in due do
			if SYSTEM_EVENT_KINDS[ev.kind] then
				table.insert(kept, ev)
			end
		end
		due = kept
	end
	local pending: Event? = nil
	local resistance = if self.activity then Utility.resistance(self.activity.name, self.state) else 0
	for _, ev in due do
		local score = ev.salience * Utility.sensitivity(ev.kind, persona) * Mood.multiplier(self.mood.name, "interrupt")
		if score > resistance and (pending == nil or ev.salience > (pending :: Event).salience) then
			pending = ev
		end
	end
	-- A game event that got through: sometimes a cheer and a word, on top of its candidates.
	if pending and (pending :: Event).kind == "gameEvent" then
		if rng:chance(0.3) then
			table.insert(actions, { kind = "emote", name = "cheer", cutAfter = rng:logNormalClamped(3, 0.5, 1.5, 6) })
		end
		if rng:chance(0.2 * persona.chattiness) then
			table.insert(actions, { kind = "forceLine", category = "reaction" })
		end
	end

	local ctx = makeActivityContext(self, input, intents, actions, suppress)

	-- An exit walk out of a no-go volume that is over (or took too long) frees the choice again.
	local override = self.override
	if override then
		local o = override :: { position: Vector3, until_: number }
		if NavMath.flatDistance(input.me.position, o.position) <= OVERRIDE_TOLERANCE or now >= o.until_ then
			self.override = nil
			override = nil
			self.forceReselect = true
		end
	end

	-- 3. Ritual, exit walk, or (re)selection.
	if not self.ritual.done then
		tickRitual(self, input, intents, actions, suppress)
	elseif override then
		-- Pushed inside a no-go area: the runtime's exit point replaces whatever was wanted.
		local o = override :: { position: Vector3, until_: number }
		if self.activity and self.activityStatus ~= "running" then
			stopActivity(self, ctx, self.activityStatus, now)
		end
		table.insert(intents, {
			kind = "goto",
			position = o.position,
			urgency = 0.9,
			tolerance = OVERRIDE_TOLERANCE,
			stopDistance = 0.5,
		})
	else
		-- Random abandonment of trips (may start an about-face that defers the next choice).
		if now >= self.aboutFaceUntil and maybeAbandon(self, input, ctx) then
			changedMind = true
		end
		if now < self.aboutFaceUntil then
			-- About-face after an abandon: walk back briefly before choosing again.
			table.insert(
				intents,
				{ kind = "step", dir = self.aboutFaceDir or -input.me.heading, duration = self.aboutFaceUntil - now }
			)
		else
			local status = self.activityStatus
			if pending or status ~= "running" or self.forceReselect or now >= self.nextReviewAt then
				local candidates = Goals.candidates(goalsContext(self, input), pending)
				if quiet then
					for i = #candidates, 1, -1 do
						if not QUIET_ACTIVITIES[candidates[i].activity] then
							table.remove(candidates, i)
						end
					end
				end
				if not self.firstTripChosen then
					candidates = restrictFirstSelection(candidates)
				end
				-- A finished trip is usually followed by a short pause before the next thing.
				if status == "success" and self.lastTripEndedAt == now then
					for _, c in candidates do
						if c.activity == "IdleStand" then
							c.bonus = (c.bonus or 0) + 1.5
						end
					end
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
					local previous = self.activity
					if previous then
						-- Swapping out a trip that was still under way is a change of mind. A failure
						-- the runtime reported (goalInvalid, stuck) stays a failure even when its
						-- own system reaction is what interrupts, so the target is excluded.
						if previous.hasTrip and status == "running" then
							changedMind = true
						end
						local outcome = status
						if status ~= "failed" and pending then
							outcome = "interrupted"
						end
						stopActivity(self, ctx, outcome, now)
					end
					startActivity(self, ctx, chosen, now)
					if self.activity and (self.activity :: Activities.Activity).hasTrip then
						self.firstTripChosen = true
					end
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
	self.attentionOff = suppress.attention == true

	-- 5. Overlays. Far and dormant NPCs skip them: nobody is close enough to read a line or
	-- see a fidget, so the talk and emote actions activities asked for are dropped too.
	local overlay: Overlays.Output? = nil
	if quiet then
		for i = #actions, 1, -1 do
			local kind = actions[i].kind
			if kind == "forceLine" or kind == "say" or kind == "emote" then
				table.remove(actions, i)
			end
		end
		self.wakeBurst = false
	else
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
			poiWord = input.poiWord,
			reading = input.reading,
			nearest = input.nearest,
			platformFreezes = input.platformFreezes,
			knowsPoi = knowsPoi(self, input),
			interrupted = pending ~= nil,
		}
		-- Forced lines requested by activities go through the overlay's composer.
		for i = #actions, 1, -1 do
			local a = actions[i]
			if a.kind == "forceLine" then
				table.remove(actions, i)
				self.overlays:forceLine(overlayCtx, a.category or "reaction", a.target)
			end
		end
		local ticked = self.overlays:tick(overlayCtx)
		overlay = ticked
		self.wakeBurst = overlayCtx.wakeBurst == true
		for _, a in ticked.actions do
			table.insert(actions, a)
		end
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
	local overlayIntent = if overlay then overlay.intent else nil
	if overlayIntent then
		local o = overlayIntent
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
		typing = if overlay then overlay.typing else false,
		phase = self.session.phase,
		mood = self.mood.name,
		changedMind = changedMind,
		attentionOff = self.attentionOff,
	}
end

-- The runtime tells the brain something happened to the body or the session. Each kind has its
-- rule: "nameCollision" (someone with this name joined) ends the session within
-- LNc(20, 0.4, 5, 45) s; "serverClosing" leaves now; "flung" (`data.hold` = the locomotion hold
-- in seconds) chooses again once the hold is over; "fell" says something with p 0.3 chattiness
-- and chooses again; "avoidExit" (`position` = the exit point the runtime picked) walks there at
-- urgency 0.9 before anything else; "gameEvent" (`data = { name, magnitude }`, `position`)
-- becomes a reaction of salience clamp(magnitude, 0.3, 1) that goes through the usual delay and
-- miss, and pulls toward the nearest objective when it lands; "goalInvalid" fails the activity
-- and drops its target from memory. Any other kind ("stuck", "kicked", "pathFailed", ...)
-- becomes an immediate system reaction, fails the running activity and forces a new choice.
function Brain.onSystemEvent(self: BrainT, kind: string, now: number, position: Vector3?, data: any?)
	local rng = self.rng
	if kind == "nameCollision" then
		local before = self.session.leaveAt
		Session.shorten(self.session, now, rng, 20, 0.4, 5, 45)
		self.session.leaveAt = math.min(before, self.session.leaveAt)
		return
	elseif kind == "serverClosing" then
		self:leaveNow()
		return
	elseif kind == "flung" then
		local hold = if type(data) == "table" and type(data.hold) == "number" then data.hold else FLUNG_HOLD_DEFAULT
		self.deferredReselectAt = now + hold
		return
	elseif kind == "fell" then
		if rng:chance(0.3 * self.persona.chattiness) then
			table.insert(self.queuedActions, { kind = "forceLine", category = "reaction" })
		end
		self.forceReselect = true
		if self.activity then
			self.activityStatus = "interrupted"
		end
		return
	elseif kind == "avoidExit" then
		if position then
			self.override = { position = position, until_ = now + OVERRIDE_TIMEOUT }
			if self.activity then
				self.activityStatus = "interrupted"
			end
		end
		return
	elseif kind == "gameEvent" then
		local d: any = if type(data) == "table" then data else {}
		local magnitude = if type(d.magnitude) == "number" then d.magnitude else 0.5
		Reaction.push(self.reactions, {
			kind = "gameEvent",
			salience = math.clamp(magnitude, 0.3, 1),
			expected = false,
			at = now,
			data = { name = d.name, position = position or d.position, magnitude = magnitude },
		}, now, self.persona, self.mood.name, rng)
		return
	end
	if kind == "stuck" and position then
		Memory.recordStuck(self.memory, position, now)
	end
	if kind == "goalInvalid" and self.currentScored then
		-- The place is gone or unreachable: forget the visit, and stopActivity excludes it.
		local target = self.currentScored.candidate.target
		if target then
			self.memory.visited[target] = nil
		end
	end
	Reaction.push(
		self.reactions,
		{ kind = kind, salience = 1.0, expected = true, at = now, data = data },
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

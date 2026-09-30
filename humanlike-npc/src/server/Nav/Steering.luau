--!strict
-- Local avoidance of other characters, done only as much as people do it: a light drift apart
-- from someone on a collision course, a shove-like slowdown when somebody is right in front,
-- and after a moment either a hop over them, a step around, or just waiting. Nobody paths around
-- every individual in a crowd, and about a third of the time the NPC does not bother at all.
--
-- With `pushOnlyBlocking` the drift is reserved for neighbours about to hit: close in time and
-- closing fast, never someone walking the same way. Humans push through a crowd and dodge only
-- what is about to collide with them. The shove and the blocked reaction are unchanged by it.
--
-- Pure: takes the desired direction, the neighbours from the perception snapshot and the clock,
-- returns an adjusted direction and whether it wants to jump.
-- requires: NavMath, Rng, Types

local NavMath = require(script.Parent.NavMath)
local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)

type Rng = Rng.Rng
type AgentView = Types.AgentView

local Steering = {}
Steering.__index = Steering

export type Options = {
	radius: number?, -- own body radius; default 2
	range: number?, -- neighbours beyond this are ignored; default 8
	ttcHorizon: number?, -- seconds; default 1.2
	personalSpace: number?, -- extra studs kept from strangers; default 1
	ignoreChance: number?, -- share of neighbours simply bumped into; default 0.3
	maxLateral: number?, -- default 0.8 (about 39 degrees of deviation)
	blockedJumpAfter: number?, -- seconds blocked before reacting; default 0.7
	jumpShare: number?, -- share of reactions that are a hop over; default 0.7
	sideBias: number?, -- -1 or 1: which way this NPC tends to dodge
	-- Only drift for a neighbour predicted to block (see ttcBlock / closingMin), never for one
	-- walking the same way; default false (the drift applies to every collision course).
	pushOnlyBlocking: boolean?,
	ttcBlock: number?, -- seconds to closest approach under which a neighbour blocks; default 0.6
	closingMin: number?, -- studs/s of closing speed above which a neighbour blocks; default 4
}

export type Input = {
	dir: Vector3, -- desired unit direction (flat)
	magnitude: number,
	position: Vector3,
	velocity: Vector3,
	neighbors: { AgentView },
	now: number,
	-- Optional free distances of short wall probes to the left and right, in studs.
	probeLeft: number?,
	probeRight: number?,
	friends: { [string]: boolean }?, -- ids that get no personal space
}

export type Output = {
	dir: Vector3,
	magnitude: number,
	blockedBy: string?,
	wantsJump: boolean,
}

export type Steerer = typeof(setmetatable(
	{} :: {
		rng: Rng,
		radius: number,
		range: number,
		ttcHorizon: number,
		personalSpace: number,
		ignoreChance: number,
		maxLateral: number,
		blockedJumpAfter: number,
		jumpShare: number,
		sideBias: number,
		pushOnlyBlocking: boolean,
		ttcBlock: number,
		closingMin: number,
		ignored: { [string]: number }, -- id -> decided-until time (true = ignoring)
		ignoreDecision: { [string]: boolean },
		blockedSince: { [string]: number },
	},
	Steering
))

function Steering.new(rng: Rng, options: Options?): Steerer
	local o: Options = options or {}
	return setmetatable({
		rng = rng,
		radius = o.radius or 2,
		range = o.range or 8,
		ttcHorizon = o.ttcHorizon or 1.2,
		personalSpace = o.personalSpace or 1,
		ignoreChance = o.ignoreChance or 0.3,
		maxLateral = o.maxLateral or 0.8,
		blockedJumpAfter = o.blockedJumpAfter or 0.7,
		jumpShare = o.jumpShare or 0.7,
		sideBias = o.sideBias or rng:sign(),
		pushOnlyBlocking = o.pushOnlyBlocking == true,
		ttcBlock = o.ttcBlock or 0.6,
		closingMin = o.closingMin or 4,
		ignored = {},
		ignoreDecision = {},
		blockedSince = {},
	}, Steering)
end

-- Decides once per neighbour per 4 seconds whether this NPC bothers avoiding them.
local function ignores(self: Steerer, id: string, now: number): boolean
	local until_ = self.ignored[id]
	if not until_ or now >= until_ then
		self.ignored[id] = now + 4
		self.ignoreDecision[id] = self.rng:chance(self.ignoreChance)
	end
	return self.ignoreDecision[id] == true
end

local SAME_WAY_DOT = 0.5 -- cosine between the two velocities above which they walk the same way
local SAME_WAY_CLOSING = 2 -- studs/s: closing slower than this while heading the same way is a companion

-- Whether a neighbour on a collision course earns a drift. Without `pushOnlyBlocking` every one
-- does; with it only a neighbour about to block: closest approach within `ttcBlock` and closing
-- faster than `closingMin`, and never a neighbour walking the same way at about the same pace.
-- `rel` is the flat offset to the neighbour, `relV` the neighbour's flat velocity relative to us.
local function pushes(
	self: Steerer,
	rel: Vector3,
	distance: number,
	relV: Vector3,
	ttc: number,
	myV: Vector3,
	nV: Vector3
): boolean
	if not self.pushOnlyBlocking then
		return true
	end
	local closing = -rel:Dot(relV) / distance -- positive while the gap shrinks
	local mine, theirs = NavMath.flat(myV), NavMath.flat(nV)
	if mine.Magnitude > 1e-6 and theirs.Magnitude > 1e-6 then
		if mine.Unit:Dot(theirs.Unit) > SAME_WAY_DOT and closing < SAME_WAY_CLOSING then
			return false
		end
	end
	return ttc < self.ttcBlock and closing > self.closingMin
end

function Steering.adjust(self: Steerer, input: Input): Output
	local d = input.dir
	if d.Magnitude < 1e-6 or input.magnitude <= 0 then
		return { dir = d, magnitude = input.magnitude, wantsJump = false }
	end
	local p = input.position
	local lateral = 0
	local blockedBy: string? = nil
	local blockedRel: Vector3? = nil
	local friends = input.friends or {}

	for _, n in input.neighbors do
		local rel = NavMath.flat(n.position - p)
		local distance = rel.Magnitude
		if distance > self.range or distance < 1e-6 then
			continue
		end
		local relV = NavMath.flat(n.velocity - input.velocity)
		local ttc = 0
		local relSpeedSq = relV:Dot(relV)
		if relSpeedSq >= 0.01 then
			ttc = math.max(0, -rel:Dot(relV) / relSpeedSq)
		end
		if ttc > self.ttcHorizon then
			continue
		end
		local closest = (rel + relV * ttc).Magnitude
		local space = if friends[n.id] then 0 else self.personalSpace
		if closest > 2 * self.radius + space then
			continue
		end
		if ignores(self, n.id, input.now) then
			continue
		end
		if pushes(self, rel, distance, relV, ttc, input.velocity, n.velocity) then
			local side = d:Cross(rel).Y
			side = if math.abs(side) < 1e-6 then self.sideBias else (if side > 0 then 1 else -1)
			local weight = (1 - distance / self.range) * (1 - ttc / self.ttcHorizon)
			lateral -= side * weight
		end
		if distance < 2 * self.radius + 0.3 and rel.Unit:Dot(d) > 0.7 then
			blockedBy = n.id
			blockedRel = rel
		end
	end

	local perp = NavMath.perp(d)
	local out = (d + perp * math.clamp(lateral, -self.maxLateral, self.maxLateral))
	out = if out.Magnitude > 1e-6 then out.Unit else d
	local magnitude = input.magnitude
	local wantsJump = false

	if blockedBy then
		local since = self.blockedSince[blockedBy]
		if not since then
			since = input.now
			self.blockedSince[blockedBy] = since
		end
		if input.now - since > self.blockedJumpAfter then
			local roll = self.rng:next()
			if roll < self.jumpShare then
				wantsJump = true
			elseif roll < self.jumpShare + 0.2 then
				-- Step around: sidestep away from where they stand.
				local side = if blockedRel and d:Cross(blockedRel :: Vector3).Y > 0 then -1 else 1
				out = perp * side
			end
			-- else: wait (keep pushing gently); do not re-roll for 1.5 s
			self.blockedSince[blockedBy] = input.now + 1.5 - self.blockedJumpAfter
		end
		magnitude = magnitude * 0.6
	else
		self.blockedSince = {}
	end

	-- Static probes: only meaningful for beeline moves without lookahead.
	if input.probeLeft and input.probeLeft < 1.5 then
		out = out + perp * -(1.5 - input.probeLeft)
	end
	if input.probeRight and input.probeRight < 1.5 then
		out = out + perp * (1.5 - input.probeRight)
	end
	out = if out.Magnitude > 1e-6 then out.Unit else d

	return { dir = out, magnitude = magnitude, blockedBy = blockedBy, wantsJump = wantsJump }
end

return Steering

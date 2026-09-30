--!strict
-- The per-frame animation state choice the client animator runs for a character without an Animate script, kept
-- pure so it is testable under Lune and pinned to the R15 Animate script's own blend rules [animate-src], so an
-- NPC's animation timing equals a player's: the 0.75·heightScale moving threshold, the walk/run cross-fade over
-- runSpeed 0.5..1 with both tracks time-warped to runSpeed, the 0.31 s jump hold before fall, and the 1/1/9 idle
-- re-roll. It plays nothing itself: the animator owns tracks, signals and time.
-- requires: AnimSets

local AnimSets = require(script.Parent.AnimSets)

export type Input = {
	onGround: boolean,
	speed: number, -- horizontal speed in studs/s
	verticalSpeed: number,
	heightScale: number, -- Humanoid.HipHeight / 2 for R15 (1 when scaling is off)
	seated: boolean,
	climbing: boolean,
	emote: string?, -- the emote currently allowed to play (the animator clears it when the character moves)
	now: number,
	lastState: string, -- the state returned last frame ("" at start)
	lastChangeAt: number,
	jumpedAt: number?, -- when the humanoid last entered Jumping
}

export type Selection = {
	state: string, -- "idle" | "walk" | "jump" | "fall" | "climb" | "sit" | "emote"
	walkWeight: number,
	runWeight: number,
	playbackSpeed: number,
	fade: number,
}

local AnimLogic = {}

-- Engine constants [animate-src].
AnimLogic.JUMP_HOLD = 0.31 -- jumpAnimDuration
AnimLogic.FALL_FADE = 0.2 -- fallTransitionTime
AnimLogic.EMOTE_FADE = 0.1 -- EMOTE_TRANSITION_TIME
AnimLogic.IDLE_FADE = 0.2
AnimLogic.WALK_FADE = 0.2
AnimLogic.JUMP_FADE = 0.1
AnimLogic.CLIMB_FADE = 0.1
AnimLogic.SIT_FADE = 0.5
AnimLogic.MOVE_THRESHOLD = 0.75
AnimLogic.CLIMB_SPEED_DIVISOR = 5
local DEFAULT_IDLE_WEIGHTS: { number } = { 1, 1, 9 }
AnimLogic.DEFAULT_IDLE_WEIGHTS = DEFAULT_IDLE_WEIGHTS

local function selection(
	state: string,
	walkWeight: number,
	runWeight: number,
	playbackSpeed: number,
	fade: number
): Selection
	return { state = state, walkWeight = walkWeight, runWeight = runWeight, playbackSpeed = playbackSpeed, fade = fade }
end

function AnimLogic.select(i: Input): Selection
	local heightScale = if i.heightScale > 0 then i.heightScale else 1
	if i.seated then
		return selection("sit", 0, 0, 1, AnimLogic.SIT_FADE)
	end
	if i.climbing then
		return selection("climb", 0, 0, i.speed / AnimLogic.CLIMB_SPEED_DIVISOR, AnimLogic.CLIMB_FADE)
	end
	if i.emote ~= nil then
		return selection("emote", 0, 0, 1, AnimLogic.EMOTE_FADE)
	end
	if not i.onGround then
		local jumpedAt = i.jumpedAt
		local holding = false
		if jumpedAt ~= nil then
			holding = i.now - jumpedAt < AnimLogic.JUMP_HOLD
		elseif i.lastState == "jump" then
			holding = i.now - i.lastChangeAt < AnimLogic.JUMP_HOLD
		elseif i.lastState ~= "fall" and i.verticalSpeed > 0 then
			-- Rising with no Jumping event seen (joined mid-jump): treat this frame as the jump start.
			holding = true
		end
		if holding then
			return selection("jump", 0, 0, 1, AnimLogic.JUMP_FADE)
		end
		return selection("fall", 0, 0, 1, AnimLogic.FALL_FADE)
	end
	if i.speed > AnimLogic.MOVE_THRESHOLD * heightScale then
		local runSpeed = (i.speed / 16) * 1.25 / heightScale
		if runSpeed <= 0.5 then
			return selection("walk", 1, 0, runSpeed, AnimLogic.WALK_FADE)
		elseif runSpeed < 1 then
			local runWeight = (runSpeed - 0.5) / 0.5
			return selection("walk", 1 - runWeight, runWeight, runSpeed, AnimLogic.WALK_FADE)
		end
		return selection("walk", 0, 1, runSpeed, AnimLogic.WALK_FADE)
	end
	return selection("idle", 0, 0, 1, AnimLogic.IDLE_FADE)
end

-- xorshift32 over the (seed, index) pair: deterministic, exact in doubles, no multiplication overflow.
local function xorshift(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	return x
end

-- A uniform number in [0, 1) for (seed, index); the same pair always gives the same value.
function AnimLogic.unit(seed: number, index: number): number
	local s = math.floor(math.abs(seed)) % 4294967296
	local n = math.floor(math.abs(index))
	local lo = n % 65536
	local hi = math.floor(n / 65536) % 65536
	local x = bit32.bxor(s, (lo * 40503) % 4294967296, (hi * 2654435761) % 4294967296)
	if x == 0 then
		x = 0x9E3779B9
	end
	x = xorshift(xorshift(xorshift(x)))
	return x / 4294967296
end

-- Deterministic weighted pick of the idle variant (1, 2 or 3) at the clip's End keyframe; weights 1/1/9 unless a
-- pack supplies its own.
function AnimLogic.idleRoll(seed: number, rollIndex: number, weights: { number }?): number
	local w = weights or DEFAULT_IDLE_WEIGHTS
	local w1 = if #w >= 1 then math.max(w[1], 0) else 0
	local w2 = if #w >= 2 then math.max(w[2], 0) else 0
	local w3 = if #w >= 3 then math.max(w[3], 0) else 0
	local total = w1 + w2 + w3
	if total <= 0 then
		return 3
	end
	local target = AnimLogic.unit(seed, rollIndex) * total
	if target < w1 then
		return 1
	elseif target < w1 + w2 then
		return 2
	end
	return 3
end

-- The per-character seed the animator uses: a hash of the character's name, so every client rolls the same
-- idle variants for the same character.
function AnimLogic.seedFor(name: string): number
	return AnimSets.hash(name)
end

return AnimLogic

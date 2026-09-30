--!strict
-- What a body does while its owner types one line. Keyboard players mostly stop dead (the chat
-- box takes the movement keys), sometimes keep a held key down and walk straight for a moment
-- before they notice, and a few keep walking because they type on a second device or dictate;
-- thumb players almost always stop. This module draws the variant and its timing and turns it
-- into a freeze intent for the locomotion runtime. It reads no clock, touches no body and does
-- not decide when the line is said or whether the typing indicator shows: Mind/Overlays owns
-- the schedule, the end of the freeze and the indicator action.

local Rng = require(script.Parent.Parent.Rng)
local Activities = require(script.Parent.Parent.Mind.Activities)

type Rng = Rng.Rng
type Intent = Activities.Intent

local TypingFreeze = {}

-- "still" | "heldKey" | "free" (plain strings: singleton unions and table literals do not mix
-- well in the current type checker).
export type Variant = string

export type Plan = {
	variant: Variant,
	-- still: the whole typing time plus the release delay; heldKey: the held walk, at most 3 s,
	-- after which the body stands still for the rest of `total`; free: 0.
	duration: number,
	dir: Vector3?, -- heldKey: the direction the held key keeps the body walking in
	total: number, -- seconds until the body is free again (typing + release; 0 for free)
	startedAt: number?, -- set by the caller when the plan starts, so intent(plan, now) counts down
}

-- Variant shares per input profile, in points. Draws follow VARIANTS, never this table's order.
TypingFreeze.WEIGHTS = {
	pc = { still = 80, heldKey = 15, free = 5 },
	pcShiftLock = { still = 80, heldKey = 15, free = 5 },
	mobile = { still = 95, heldKey = 0, free = 5 },
	console = { still = 90, heldKey = 5, free = 5 },
} :: { [string]: { [string]: number } }

local VARIANTS: { string } = { "still", "heldKey", "free" }
local HELD_KEY_MAX = 3 -- seconds before a held key is noticed and released
local RELEASE_LO, RELEASE_HI = 0.2, 0.6 -- seconds from sending the line to hands back on the keys

-- Draws how the body waits out `typingSeconds` of typing. A standing body is always "still";
-- a moving one picks a variant by the profile's weights (an unknown profile counts as pc). The
-- release delay is drawn for every plan so a plan always costs the same number of draws.
function TypingFreeze.plan(
	rng: Rng,
	profileKind: string,
	moving: boolean,
	typingSeconds: number,
	lastMoveDir: Vector3?
): Plan
	local typing = math.max(0, typingSeconds)
	local variant = "still"
	if moving then
		local shares = TypingFreeze.WEIGHTS[profileKind] or TypingFreeze.WEIGHTS.pc
		local weights: { number } = {}
		for i, name in VARIANTS do
			weights[i] = shares[name] or 0
		end
		variant = VARIANTS[rng:weightedIndex(weights)]
	end
	local release = rng:range(RELEASE_LO, RELEASE_HI)
	if variant == "free" then
		return { variant = "free", duration = 0, dir = nil, total = 0, startedAt = nil }
	elseif variant == "heldKey" then
		return {
			variant = "heldKey",
			duration = math.min(typing, HELD_KEY_MAX),
			dir = lastMoveDir,
			total = typing + release,
			startedAt = nil,
		}
	end
	return { variant = "still", duration = typing + release, dir = nil, total = typing + release, startedAt = nil }
end

-- The freeze intent to follow at `now`: walkStraight while a held key is still down, still for
-- the rest; nil for a "free" plan or once the plan is over. A plan without `startedAt` is taken
-- to start now.
function TypingFreeze.intent(plan: Plan, now: number): Intent?
	if plan.variant == "free" then
		return nil
	end
	local elapsed = now - (plan.startedAt or now)
	local remaining = plan.total - elapsed
	if remaining <= 0 then
		return nil
	end
	if plan.variant == "heldKey" and elapsed < plan.duration then
		local held: Intent = {
			kind = "freeze",
			variant = "walkStraight",
			duration = plan.duration - elapsed,
			dir = plan.dir,
		}
		return held
	end
	local still: Intent = { kind = "freeze", variant = "still", duration = remaining }
	return still
end

return TypingFreeze

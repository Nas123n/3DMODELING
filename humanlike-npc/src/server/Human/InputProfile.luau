--!strict
-- How this NPC "holds the controls". A PC player's movement snaps to eight camera-relative
-- directions and is either stopped or at full speed; a thumbstick player wobbles, walks at
-- partial speed, lifts the thumb for a moment now and then, and never walks backwards. Every
-- other humanization module reads these numbers instead of inventing its own wobble, so two
-- mobile NPCs differ only by the small jitter applied when the profile is sampled, and a PC NPC
-- never shows thumbstick tremor.
-- requires: Rng

local Rng = require(script.Parent.Parent.Rng)

type Rng = Rng.Rng

local InputProfile = {}

-- "pc" | "pcShiftLock" | "mobile" | "console" (kept as string: singleton unions and table
-- literals do not mix well in the current type checker).
export type Kind = string

export type Profile = {
	kind: Kind,
	quantize8: boolean, -- move direction snaps to 8 camera-relative directions
	analog: boolean, -- magnitude below 1 allowed
	wobbleAmpDeg: number, -- heading wobble amplitude (sum of two sines)
	wobbleHz: number,
	tremorSigma: number, -- degrees, OU tremor sigma (theta 4)
	microStopMean: number, -- seconds between thumb lifts (0 = never)
	microStopMedianDur: number, -- seconds, log-normal spread 0.5, clipped 0.1..0.45
	camRateDegPerS: number, -- virtual camera yaw rate (0 for analog profiles)
	camLag: number, -- seconds before the camera starts turning after a heading change > 30 degrees
	strafes: boolean, -- body faces the camera, moves sideways (shift-lock)
	jumpRateScale: number,
	typingFreezes: boolean,
	walksBack: boolean,
	hesitationScale: number,
	lookahead: number, -- follower lookahead in studs (PC aims at what is in front, mobile draws arcs)
}

-- Share of each profile among a typical server.
local MIX: { { kind: Kind, weight: number } } = {
	{ kind = "pc", weight = 30 },
	{ kind = "pcShiftLock", weight = 10 },
	{ kind = "mobile", weight = 55 },
	{ kind = "console", weight = 5 },
}
InputProfile.MIX = MIX

local BASE: { [Kind]: Profile } = {
	pc = {
		kind = "pc",
		quantize8 = true,
		analog = false,
		wobbleAmpDeg = 0,
		wobbleHz = 0,
		tremorSigma = 0,
		microStopMean = 0,
		microStopMedianDur = 0,
		camRateDegPerS = 45,
		camLag = 0.25,
		strafes = false,
		jumpRateScale = 1,
		typingFreezes = true,
		walksBack = true,
		hesitationScale = 1,
		lookahead = 4,
	},
	pcShiftLock = {
		kind = "pcShiftLock",
		quantize8 = true,
		analog = false,
		wobbleAmpDeg = 0,
		wobbleHz = 0,
		tremorSigma = 0,
		microStopMean = 0,
		microStopMedianDur = 0,
		camRateDegPerS = 70,
		camLag = 0.15,
		strafes = true,
		jumpRateScale = 1,
		typingFreezes = true,
		walksBack = true,
		hesitationScale = 0.8,
		lookahead = 4,
	},
	mobile = {
		kind = "mobile",
		quantize8 = false,
		analog = true,
		wobbleAmpDeg = 8,
		wobbleHz = 2.8,
		tremorSigma = 3,
		microStopMean = 12,
		microStopMedianDur = 0.2,
		camRateDegPerS = 0,
		camLag = 0,
		strafes = false,
		jumpRateScale = 0.3,
		typingFreezes = true,
		walksBack = false,
		hesitationScale = 0.6,
		lookahead = 8,
	},
	console = {
		kind = "console",
		quantize8 = false,
		analog = true,
		wobbleAmpDeg = 4,
		wobbleHz = 2,
		tremorSigma = 1.5,
		microStopMean = 20,
		microStopMedianDur = 0.2,
		camRateDegPerS = 40,
		camLag = 0.3,
		strafes = false,
		jumpRateScale = 0.5,
		typingFreezes = true,
		walksBack = false,
		hesitationScale = 0.8,
		lookahead = 6,
	},
}

InputProfile.BASE = BASE

-- Picks a kind from the mix.
function InputProfile.pickKind(rng: Rng): Kind
	local weights = {}
	for i, entry in MIX do
		weights[i] = entry.weight
	end
	return MIX[rng:weightedIndex(weights)].kind
end

-- A frozen profile for one NPC: the base numbers jittered by about 15% so no two are identical.
function InputProfile.sample(rng: Rng, kind: Kind?): Profile
	local k = kind or InputProfile.pickKind(rng)
	local base = BASE[k]
	local function jitter(value: number): number
		if value == 0 then
			return 0
		end
		return value * math.clamp(rng:gaussian(1, 0.15), 0.6, 1.4)
	end
	local profile: Profile = {
		kind = k,
		quantize8 = base.quantize8,
		analog = base.analog,
		wobbleAmpDeg = jitter(base.wobbleAmpDeg),
		wobbleHz = jitter(base.wobbleHz),
		tremorSigma = jitter(base.tremorSigma),
		microStopMean = jitter(base.microStopMean),
		microStopMedianDur = jitter(base.microStopMedianDur),
		camRateDegPerS = if base.camRateDegPerS > 0
			then math.clamp(rng:range(20, 90) * (base.camRateDegPerS / 45), 15, 120)
			else 0,
		camLag = jitter(base.camLag),
		strafes = base.strafes,
		jumpRateScale = base.jumpRateScale,
		typingFreezes = base.typingFreezes,
		walksBack = base.walksBack,
		hesitationScale = base.hesitationScale,
		lookahead = base.lookahead,
	}
	return profile
end

return InputProfile

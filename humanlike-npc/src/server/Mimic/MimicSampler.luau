--!strict
-- Blends what MotionStats learned about the local crowd into an NPC's own commands. The learned distribution
-- counts n / (n + k) of the time, so a fresh server leaves the persona's own numbers alone and a busy one
-- pulls NPC speed ratios toward what players actually do; every draw is jittered so no NPC repeats a player's
-- exact value. Identity-free and in-memory only: it sees numbers from reservoirs, never who produced them,
-- never positions, never ids, and nothing here is persisted. It does not learn anything itself (MotionStats
-- does) and does not decide whether mimicry is on (Config does).
-- requires: MotionStats, Rng, Types

local MotionStats = require(script.Parent.MotionStats)
local Rng = require(script.Parent.Parent.Rng)
local Types = require(script.Parent.Parent.Types)

type Rng = Rng.Rng
type Stats = MotionStats.Stats
type MoveCommand = Types.MoveCommand

local MimicSampler = {}
MimicSampler.__index = MimicSampler

MimicSampler.K = 200
MimicSampler.JITTER = 0.05
MimicSampler.MIN_MAGNITUDE = 0.55
MimicSampler.MAX_MAGNITUDE = 1

export type Options = { k: number?, jitter: number? }

export type Sampler = typeof(setmetatable(
	{} :: {
		stats: Stats,
		k: number,
		jitter: number,
	},
	MimicSampler
))

export type ShapeContext = {
	rng: Rng,
	moving: boolean, -- the body is already under way; a standing start keeps the profile's magnitude
	profileMagnitude: number, -- the analog magnitude the input profile / humanizer produced
}

function MimicSampler.new(stats: Stats, opts: Options?): Sampler
	local o: Options = opts or {}
	return setmetatable({
		stats = stats,
		k = math.max(0, o.k or MimicSampler.K),
		jitter = math.max(0, o.jitter or MimicSampler.JITTER),
	}, MimicSampler)
end

-- How much the learned distribution counts: n / (n + k) over everything observed for the feature.
function MimicSampler.weight(self: Sampler, feature: string): number
	local n = self.stats:count(feature)
	if n <= 0 then
		return 0
	end
	return n / (n + self.k)
end

-- With probability weight(feature): a reservoir sample scaled by (1 + jitter * N(0, 1)); otherwise the
-- fallback. The fallback is also used while the reservoir is too small to sample.
function MimicSampler.draw(self: Sampler, feature: string, fallback: number, rng: Rng): number
	local w = self:weight(feature)
	if w <= 0 or not rng:chance(w) then
		return fallback
	end
	local value = self.stats:sample(feature, rng)
	if value == nil then
		return fallback
	end
	return value * (1 + self.jitter * rng:normal())
end

-- Blends a move command's analog magnitude toward a learned speed ratio:
--   m = (1 - w) * profileMagnitude + w * drawn, clamped to [0.55, 1], with w = weight("speedRatio")
-- and `drawn` a jittered reservoir sample. Commands that are not moves, bodies not yet moving and
-- reservoirs without enough samples pass through untouched. The input command is never mutated.
function MimicSampler.shape(self: Sampler, cmd: MoveCommand, ctx: ShapeContext): MoveCommand
	if cmd.mode ~= "move" or not ctx.moving then
		return cmd
	end
	local w = self:weight("speedRatio")
	if w <= 0 then
		return cmd
	end
	local sampled = self.stats:sample("speedRatio", ctx.rng)
	if sampled == nil then
		return cmd
	end
	local drawn = sampled * (1 + self.jitter * ctx.rng:normal())
	local m = (1 - w) * ctx.profileMagnitude + w * drawn
	local shaped: MoveCommand = {
		mode = "move",
		dir = cmd.dir,
		magnitude = math.clamp(m, MimicSampler.MIN_MAGNITUDE, MimicSampler.MAX_MAGNITUDE),
		moveToPoint = cmd.moveToPoint,
		jump = cmd.jump,
		facingYaw = cmd.facingYaw,
	}
	return shaped
end

return MimicSampler

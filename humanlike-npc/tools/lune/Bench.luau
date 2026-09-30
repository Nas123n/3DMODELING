-- Measured baselines for the README, not a test: (a) NavGrid.findPath, typical and exhaustive, on
-- the arena grid; (b) eight NPCs for 600 simulated seconds through FakeWorld at 30 Hz, reported as
-- microseconds per NPC tick, per brain tick and per frame; (c) Senses.step with twenty entities;
-- (d) Composer.compose ten thousand times. It prints one table and asserts nothing; it is not part
-- of tests/run. Run from the repository root: lune run tools/lune/Bench

local roblox = require("@lune/roblox")

local FakeWorld = require("./FakeWorld")
local Loader = require("./Loader")
local Scenes = require("./Scenes")

local Vector3 = roblox.Vector3

type Row = { name: string, iterations: number, seconds: number, unit: string }

local rows: { Row } = {}

-- Times `iterations` calls of fn and records a row; returns the seconds spent.
local function bench(name: string, iterations: number, fn: (i: number) -> ()): number
	local t0 = os.clock()
	for i = 1, iterations do
		fn(i)
	end
	local seconds = os.clock() - t0
	table.insert(rows, { name = name, iterations = iterations, seconds = seconds, unit = "iter" })
	return seconds
end

local function record(name: string, count: number, seconds: number, unit: string)
	table.insert(rows, { name = name, iterations = count, seconds = seconds, unit = unit })
end

-- (a) Path searches on the arena grid.
local session = Loader.new()
local S = session.game.ServerStorage.HumanlikeNpc
local NavGrid = session.require(S.Nav.NavGrid)
local _, made = Scenes.arena(session)
local grid = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
grid:sample(session.world, { avoid = { made.avoid } })
local start = made.spawn.CFrame.Position
local goal = made.viewpoint.CFrame.Position

local typical
bench("NavGrid.findPath spawn -> viewpoint (typical, jumps on)", 50, function()
	typical = grid:findPath(start, goal)
end)
record(
	`  expanded nodes per typical search ({typical.status}, {#typical.waypoints} waypoints)`,
	typical.expanded,
	0,
	"node"
)

local walled = NavGrid.new({ minX = -60, minZ = -60, maxX = 60, maxZ = 60, cellSize = 2 })
walled:sample(session.world, { avoid = { made.avoid } })
walled:fillBlocked(50, 0, 52, 59) -- a wall across the arena: the goal beyond it is unreachable
local exhaustive
local exhaustiveSeconds = bench("NavGrid.findPath unreachable (exhaustive, 20000 nodes)", 10, function()
	exhaustive = walled:findPath(start, Vector3.new(55, 0, 0), { maxNodes = 20000 })
end)
record("  per expanded node (exhaustive)", exhaustive.expanded * 10, exhaustiveSeconds, "node")

-- (b) Eight NPCs, 600 s at 30 Hz through FakeWorld.
local worldSession = Loader.new()
local world = FakeWorld.new(worldSession, { seed = "bench" })
local Npc = worldSession.require(worldSession.game.ServerStorage.HumanlikeNpc.Runtime.Npc)
local service = world.service
local ticks, brains, tickSeconds, brainSeconds = 0, 0, 0, 0
for _ = 1, 8 do
	local id = service:spawn(world.now)
	local npc = service.records[id].npc
	-- An own field shadows the metatable's tick: every tick of this NPC is timed.
	npc.tick = function(self, now, runBrain)
		local t0 = os.clock()
		local report = Npc.tick(self, now, runBrain)
		local dt = os.clock() - t0
		ticks += 1
		tickSeconds += dt
		if runBrain then
			brains += 1
			brainSeconds += dt
		end
		return report
	end
end
local seconds, hz = 600, 30
local frames = seconds * hz
local t0 = os.clock()
world:run(seconds, hz)
local frameSeconds = os.clock() - t0
record(`FakeWorld: 8 NPCs x {seconds} s at {hz} Hz, per frame`, frames, frameSeconds, "frame")
record("  per NPC tick (all ticks)", ticks, tickSeconds, "tick")
record("  per brain tick (ticks that ran the brain)", brains, brainSeconds, "tick")
record("  per frame outside NPC ticks (spatial, planner, bodies)", frames, frameSeconds - tickSeconds, "frame")
record(`  NPCs still present at the end`, service:count(), 0, "npc")

-- (c) Senses.step with twenty entities around one NPC.
local Rng = session.require(S.Rng)
local Personality = session.require(S.Mind.Personality)
local Memory = session.require(S.Mind.Memory)
local Senses = session.require(S.Mind.Senses)
local persona = Personality.sample(Rng.new(7), { profileKind = "pc" })
local senses = Senses.new(Rng.new(8), persona)
local memory = Memory.new(0)
local entities = {}
for i = 1, 20 do
	local angle = i / 20 * math.pi * 2
	local radius = 4 + (i % 5) * 4
	local moving = i % 2 == 0
	table.insert(entities, {
		id = `e{i}`,
		kind = if i % 3 == 0 then "npc" else "player",
		position = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius),
		velocity = if moving then Vector3.new(-math.sin(angle) * 8, 0, math.cos(angle) * 8) else Vector3.zero,
		yaw = angle + math.pi,
		displayName = `e{i}`,
	})
end
local me =
	{ id = "me", position = Vector3.zero, heading = Vector3.new(0, 0, -1), moving = false, velocity = Vector3.zero }
bench("Senses.step (20 entities)", 2000, function(i)
	senses:step({ me = me, entities = entities, chats = {}, groups = {}, now = i * 0.1, dt = 0.1 }, memory)
end)

-- (d) Composer.compose.
local ChatStyle = session.require(S.Chat.ChatStyle)
local Composer = session.require(S.Chat.Composer)
local Recency = session.require(S.Chat.Recency)
local Safety = session.require(S.Chat.Safety)
local voice = ChatStyle.voice(Rng.new(9), "pc", 0.5, 0.5)
local recency, safety = Recency.new(), Safety.new()
local chatRng = Rng.new(10)
bench("Composer.compose x 10000", 10000, function(i)
	Composer.compose({
		npcId = `n{i % 8}`,
		voice = voice,
		rng = chatRng,
		now = i * 0.5,
		accountAge = 0.3,
		mood = "social",
		phase = "settled",
		nearbyName = "Milo",
	}, recency, safety)
end)

-- The table.
print(string.format("%-62s %10s %12s %14s", "benchmark", "count", "total ms", "per unit"))
print(string.rep("-", 101))
for _, row in rows do
	local per = if row.iterations > 0 then row.seconds / row.iterations * 1e6 else 0
	if row.seconds == 0 then
		print(string.format("%-62s %10d %12s %14s", row.name, row.iterations, "", ""))
	else
		print(
			string.format("%-62s %10d %12.3f %11.2f us/%s", row.name, row.iterations, row.seconds * 1000, per, row.unit)
		)
	end
end

-- Test runner: `lune run tests/run` from the humanlike-npc folder.
-- Modules load through tools/lune/Loader, so the tests exercise the same files Rojo syncs
-- into Studio. Add new suites to the list below.

local process = require("@lune/process")

local Loader = require("../tools/lune/Loader")
local T = require("./T")

local suites = {
	require("./Rng.spec"),
	require("./Timing.spec"),
	require("./NavGrid.spec"),
	require("./Names.spec"),
	require("./ChatCorpus.spec"),
	require("./ChatStyle.spec"),
	require("./WaypointFollower.spec"),
	require("./NavRuntime.spec"),
	require("./Human.spec"),
	require("./Humanizer.spec"),
	require("./Planner.spec"),
	require("./Locomotion.spec"),
	require("./Mind.spec"),
	require("./MindCore.spec"),
	require("./Persona.spec"),
	require("./Brain.spec"),
	require("./Overlays.spec"),
	require("./Senses.spec"),
	require("./Scan.spec"),
	require("./Config.spec"),
	require("./Population.spec"),
	require("./Scheduler.spec"),
	require("./Lod.spec"),
	require("./ErrorBudget.spec"),
	require("./ChatGuard.spec"),
	require("./Composer.spec"),
	require("./TypingFreeze.spec"),
	require("./Avatars.spec"),
	require("./PrimitiveRig.spec"),
	require("./Mimic.spec"),
	require("./Safety.spec"),
	require("./Shared.spec"),
	require("./Npc.spec"),
	require("./LoadAll.spec"),
	require("./Integration.spec"),
}

for _, suite in suites do
	suite(T, Loader)
end

local failed = T.report()
process.exit(if failed > 0 then 1 else 0)

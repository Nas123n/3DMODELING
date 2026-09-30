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
	require("./Mind.spec"),
	require("./MindCore.spec"),
	require("./Senses.spec"),
	require("./Integration.spec"),
}

for _, suite in suites do
	suite(T, Loader)
end

local failed = T.report()
process.exit(if failed > 0 then 1 else 0)

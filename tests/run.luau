-- Test runner: `lune run tests/run` from the repository root.
-- Pure modules and the Roblox builders both load through tools/lune/Loader, so the tests
-- exercise the same files Rojo syncs into Studio.

local process = require("@lune/process")

local Loader = require("../tools/lune/Loader")
local T = require("./T")

local suites = {
	require("./Rng.spec"),
	require("./Scatter.spec"),
	require("./EggConfig.spec"),
	require("./EggBuilder.spec"),
	require("./Props.spec"),
	require("./ZoneDecorator.spec"),
}

for _, suite in suites do
	suite(T, Loader)
end

local failed = T.report()
process.exit(if failed > 0 then 1 else 0)

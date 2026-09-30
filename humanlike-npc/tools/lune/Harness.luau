--!strict
-- Tell-score runner for Lune: scores an Eval/Trace with Eval/TellScore and prints a readable table, and
-- reads or writes traces as JSON so a recorded run (FakeWorld.trace, or a trace dumped from Studio) can be
-- scored from the command line:
--
--   lune run tools/lune/Harness <trace.json> [--budget <score>] [--json]
--
-- `--budget` makes the exit code 1 when the score is above it; `--json` prints the Result as JSON instead
-- of the table. It takes a Trace, never a FakeWorld: whoever owns a world hands over `world.trace`. It is not
-- part of the test suite and asserts nothing on its own. Ring 3 only (uses @lune/serde and @lune/fs).

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Loader = require("./Loader")

local Harness = {}

Harness.DEFAULT_BUDGET = 0.5

-- Modules through a Loader session (a fresh one when none is given).
local function modules(session: any?)
	local s = session or Loader.new()
	local S = s.game.ServerStorage.HumanlikeNpc
	return s, s.require(S.Eval.Trace), s.require(S.Eval.TellScore)
end

-- Scores a trace; `options` is TellScore.Options.
function Harness.score(session: any?, trace: any, options: any?): any
	local _, _, TellScore = modules(session)
	return TellScore.score(trace, options)
end

-- JSON text of a trace (Trace.toData), and the trace back from it.
function Harness.encode(trace: any): string
	return serde.encode("json", trace:toData())
end

function Harness.decode(session: any?, text: string): any
	local _, Trace = modules(session)
	return Trace.fromData(serde.decode("json", text))
end

function Harness.save(trace: any, path: string)
	fs.writeFile(path, Harness.encode(trace))
end

function Harness.load(session: any?, path: string): any
	return Harness.decode(session, fs.readFile(path))
end

-- Formatting ---------------------------------------------------------------------------------------------------

local function pad(text: string, width: number, right: boolean?): string
	local length = #text
	if length >= width then
		return text
	end
	local fill = string.rep(" ", width - length)
	return if right then fill .. text else text .. fill
end

local function fmt(value: number?, digits: number?): string
	if value == nil then
		return "-"
	end
	local v = value :: number
	if v == math.floor(v) and math.abs(v) < 1e9 then
		return tostring(math.floor(v))
	end
	return string.format(`%.{digits or 3}f`, v)
end

local function join(list: { string }, limit: number): string
	if #list == 0 then
		return ""
	end
	if #list <= limit then
		return table.concat(list, " ")
	end
	local shown = {}
	for i = 1, limit do
		shown[i] = list[i]
	end
	return `{table.concat(shown, " ")} +{#list - limit}`
end

-- The Result as a readable table: overall score, one row per tell (value, threshold, score, agents), then
-- one row per agent.
function Harness.format(result: any, options: { agents: boolean?, all: boolean? }?): string
	local o = options or {}
	local lines = {}
	table.insert(
		lines,
		`tell score {fmt(result.score, 3)}  ({result.npcCount} npc, {result.playerCount} player, {fmt(result.seconds, 1)} s, reference {result.reference})`
	)
	table.insert(lines, "")
	local header = `{pad("tell", 20)} {pad("class", 9)} {pad("value", 10, true)} {pad("threshold", 10, true)} {pad(
		"score",
		7,
		true
	)}  agents`
	table.insert(lines, header)
	table.insert(lines, string.rep("-", #header + 20))
	for _, tell in result.tells do
		if not tell.fired and o.all == false then
			continue
		end
		local threshold = `{if tell.direction == "above" then ">" else "<"} {fmt(tell.threshold, 2)}`
		local value = if tell.evaluated then fmt(tell.value, 3) else "n/a"
		local marker = if tell.fired then "*" else " "
		table.insert(
			lines,
			`{marker}{pad(tell.name, 19)} {pad(tell.class, 9)} {pad(value, 10, true)} {pad(threshold, 10, true)} {pad(
				fmt(tell.score, 3),
				7,
				true
			)}  {join(tell.agents, 6)}`
		)
	end
	if o.agents ~= false then
		table.insert(lines, "")
		local agentHeader = `{pad("agent", 14)} {pad("kind", 7)} {pad("profile", 12)} {pad("seconds", 8, true)} {pad(
			"idle",
			6,
			true
		)} {pad("lines", 6, true)} {pad("jumps", 6, true)}  fired`
		table.insert(lines, agentHeader)
		table.insert(lines, string.rep("-", #agentHeader + 20))
		local ids = {}
		for id in result.agents do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local a = result.agents[id]
			local idle = if a.seconds > 0 then a.stoppedSeconds / a.seconds else 0
			table.insert(
				lines,
				`{pad(id, 14)} {pad(a.kind, 7)} {pad(a.profile or "-", 12)} {pad(fmt(a.seconds, 1), 8, true)} {pad(
					fmt(idle, 2),
					6,
					true
				)} {pad(fmt(a.lines), 6, true)} {pad(fmt(a.jumps), 6, true)}  {join(a.fired, 6)}`
			)
		end
	end
	return table.concat(lines, "\n")
end

function Harness.print(result: any, options: { agents: boolean?, all: boolean? }?)
	print(Harness.format(result, options))
end

-- Loads, scores and prints one trace file; returns the Result and whether it is within the budget. (The
-- name `Harness.run` is left to the FakeWorld-driven runner of §9.6, which needs `FakeWorld.trace`.)
function Harness.scoreFile(path: string, options: { budget: number?, json: boolean?, session: any? }?): (any, boolean)
	local o = options or {}
	local session = o.session or Loader.new()
	local trace = Harness.load(session, path)
	local result = Harness.score(session, trace)
	if o.json then
		print(serde.encode("json", result))
	else
		Harness.print(result)
	end
	local budget = o.budget or Harness.DEFAULT_BUDGET
	return result, result.score <= budget
end

-- Command line: the first argument ending in ".json" is the trace to score.
function Harness.main(args: { string }): number
	local path: string? = nil
	local budget: number? = nil
	local json = false
	local i = 1
	while i <= #args do
		local arg = args[i]
		if arg == "--budget" then
			budget = tonumber(args[i + 1])
			i += 1
		elseif arg == "--json" then
			json = true
		elseif string.match(arg, "%.json$") then
			path = arg
		end
		i += 1
	end
	if not path then
		print("usage: lune run tools/lune/Harness <trace.json> [--budget <score>] [--json]")
		return 2
	end
	local _, ok = Harness.scoreFile(path :: string, { budget = budget, json = json })
	return if ok then 0 else 1
end

if process.args[1] and string.match(process.args[1], "%.json$") then
	process.exit(Harness.main(process.args))
end

return Harness

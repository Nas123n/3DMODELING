-- Prints the module dependency graph of src/server and src/shared, read from their `require(`
-- lines by tools/lune/Headers, in the layout of the design document (leaves first, then one
-- family per block), and checks it: a cycle fails the run with its path printed; a module whose
-- `-- requires:` doc line disagrees with its code is listed as a mismatch, which fails the run only
-- with `--strict` (headers are still being brought in line). check.sh runs it without `--strict`.
-- Usage, from the repository root: lune run tools/lune/DepGraph [--strict] [repo-root]

local process = require("@lune/process")

local Headers = require("./Headers")

local WIDTH = 120
local LABEL = 10 -- "Family:   " column

local strict = false
local root = "."
for _, arg in process.args do
	if arg == "--strict" then
		strict = true
	elseif string.sub(arg, 1, 2) ~= "--" then
		root = arg
	end
end

local modules = Headers.scan(root)
local edges = Headers.graph(modules)
local known: { [string]: boolean } = {}
for _, module in modules do
	known[module.name] = true
end

-- Words joined with ", ", wrapped at WIDTH with every line after the first indented to `indent`.
local function wrapped(prefix: string, words: { string }, indent: number): { string }
	local lines: { string } = {}
	local line = prefix
	for i, word in words do
		local piece = if i == #words then word else word .. ","
		if #line + 1 + #piece > WIDTH and line ~= prefix then
			table.insert(lines, line)
			line = string.rep(" ", indent) .. piece
		else
			line = if line == prefix then line .. piece else line .. " " .. piece
		end
	end
	table.insert(lines, line)
	return lines
end

local function label(family: string): string
	local text = if family == "" then "Root:" else family .. ":"
	return text .. string.rep(" ", math.max(1, LABEL - #text))
end

local leaves: { string } = {}
for _, module in modules do
	if #module.requires == 0 then
		table.insert(leaves, module.name)
	end
end
for _, line in wrapped("Leaves:   ", leaves, LABEL) do
	print(line)
end

for _, family in Headers.familyOrder(modules) do
	local first = true
	for _, module in modules do
		if module.family ~= family or #module.requires == 0 then
			continue
		end
		local deps: { string } = {}
		for _, dep in module.requires do
			table.insert(deps, if known[dep] then dep else dep .. "?")
		end
		local prefix = (if first then "\n" .. label(family) else string.rep(" ", LABEL)) .. module.name .. " -> "
		for _, line in wrapped(prefix, deps, LABEL + #module.name + 4) do
			print(line)
		end
		first = false
	end
end

local edgeCount = 0
for _, module in modules do
	edgeCount += #module.requires
end
print(`\n{#modules} modules, {edgeCount} edges, {#leaves} leaves (unknown targets are marked "?")`)

local status = 0
local cycle = Headers.findCycle(edges)
if cycle then
	print(`CYCLE: {table.concat(cycle, " -> ")}`)
	status = 1
else
	print("no require cycle")
end

local mismatches = Headers.mismatches(modules)
if #mismatches == 0 then
	print("every `-- requires:` line matches its code")
else
	print(`{#mismatches} module(s) whose "-- requires:" line disagrees with the code:`)
	for _, mismatch in mismatches do
		print(`  {mismatch.path}: {Headers.describeMismatch(mismatch)}`)
	end
	if strict then
		status = 1
	end
end

process.exit(status)

-- Reads the module headers and `require(` lines under src/server and src/shared straight from the
-- source files (through @lune/fs, never by loading a module) and answers three questions about
-- them: which module requires which, whether that graph has a cycle, and whether each header
-- follows the convention (`--!strict` first, a `--` doc comment next, and a `-- requires:` line
-- that lists exactly what the source requires). DepGraph prints from it, LoadAll.spec asserts on
-- it, and `Headers.headerViolations(root)` is the one-call listing for whoever fixes the headers.
-- It is not a loader and knows nothing about Roblox: a require target is reduced to its last path
-- segment (`script.Parent.Parent.Types` -> `Types`), which is unique across the tree.

local fs = require("@lune/fs")

local Headers = {}

export type Kind = "ModuleScript" | "Script" | "LocalScript"

export type Module = {
	name: string, -- instance name: the file name without .luau, .server.luau or .client.luau
	path: string, -- relative to the root, e.g. "src/server/Nav/NavGrid.luau"
	family: string, -- folder under the source root: "" for src/server itself, "Nav", "shared", ...
	kind: Kind,
	requires: { string }, -- module names the code requires, sorted, unique
	declared: { string }?, -- module names on the `-- requires:` line, sorted; nil when there is no such line
	strict: boolean, -- the first non-empty line is --!strict
	doc: boolean, -- the next non-empty line is a -- doc comment
}

export type CodeLine = { line: number, code: string }

export type Mismatch = { path: string, declared: { string }?, actual: { string } }

-- Source roots, relative to the repository root, and the family name of the second one's modules.
Headers.ROOTS = { "src/server", "src/shared" }
Headers.SHARED_FAMILY = "shared"

-- The order families are printed in (the design document's layout); unknown families follow, sorted.
Headers.FAMILY_ORDER =
	{ "", "Nav", "Human", "Chat", "Mind", "Identity", "World", "Mimic", "Runtime", "Eval", "Adapters", "shared" }

-- Words on a `-- requires:` line that mean "nothing".
local NONE = { nothing = true, none = true, ["(none)"] = true, ["-"] = true }

-- Segments of a require argument that name a location, not a module.
local NOT_A_MODULE = { script = true, Parent = true, game = true, workspace = true }

local function trim(text: string): string
	return (string.match(text, "^%s*(.-)%s*$")) :: string
end

local function sortedKeys(set: { [string]: boolean }): { string }
	local keys: { string } = {}
	for key in set do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

function Headers.splitLines(source: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		table.insert(lines, (string.gsub(line, "\r$", "")))
	end
	return lines
end

-- The code of every line with comments removed: whole-line and trailing `--` comments and
-- `--[[ ]]` blocks. Lines that end up empty are dropped, so a forbidden-token scan never trips on prose.
function Headers.codeLines(source: string): { CodeLine }
	local out: { CodeLine } = {}
	local inBlock = false
	for number, line in Headers.splitLines(source) do
		local code = line
		if inBlock then
			local close = string.find(code, "]]", 1, true)
			if not close then
				continue
			end
			code = string.sub(code, close + 2)
			inBlock = false
		end
		local open = string.find(code, "--[[", 1, true)
		if open then
			local close = string.find(code, "]]", open + 4, true)
			if close then
				code = string.sub(code, 1, open - 1) .. string.sub(code, close + 2)
			else
				code = string.sub(code, 1, open - 1)
				inBlock = true
			end
		end
		if string.match(code, "^%s*%-%-") then
			continue
		end
		local cut = string.find(code, "%s%-%-")
		if cut then
			code = string.sub(code, 1, cut)
		end
		if trim(code) ~= "" then
			table.insert(out, { line = number, code = code })
		end
	end
	return out
end

-- The module a require argument points at: its last `.Name` segment or `WaitForChild("Name")`.
local function targetOf(argument: string): string?
	local best: string? = nil
	local bestAt = -1
	for at, name in string.gmatch(argument, "()%.([%a_][%w_]*)") do
		if not NOT_A_MODULE[name] and at > bestAt then
			best, bestAt = name, at
		end
	end
	for at, name in string.gmatch(argument, "()Child%s*%(%s*[\"']([%w_]+)[\"']") do
		if at > bestAt then
			best, bestAt = name, at
		end
	end
	return best
end

-- Module names the code requires, sorted and unique. Each `require(` is matched to its closing
-- parenthesis by depth, so `require(game:GetService("X").Y.Z)` resolves to Z.
function Headers.parseRequires(source: string): { string }
	local found: { [string]: boolean } = {}
	for _, entry in Headers.codeLines(source) do
		local code = entry.code
		local from = 1
		while true do
			local s, e = string.find(code, "require%s*%(", from)
			if not s then
				break
			end
			local before = if s > 1 then string.sub(code, s - 1, s - 1) else ""
			local depth = 1
			local i = (e :: number) + 1
			while i <= #code and depth > 0 do
				local c = string.sub(code, i, i)
				if c == "(" then
					depth += 1
				elseif c == ")" then
					depth -= 1
				end
				i += 1
			end
			if depth == 0 and not string.match(before, "[%w_%.:]") then
				local name = targetOf(string.sub(code, (e :: number) + 1, i - 2))
				if name then
					found[name] = true
				end
			end
			from = i
		end
	end
	return sortedKeys(found)
end

-- The header: the run of comment and blank lines at the top of the file, trimmed.
local function headerLines(lines: { string }): { string }
	local out: { string } = {}
	for _, line in lines do
		local t = trim(line)
		if t == "" or string.sub(t, 1, 2) == "--" then
			table.insert(out, t)
		else
			break
		end
	end
	return out
end

-- Module names on the header's `-- requires:` line (continued over following comment lines while
-- a line ends with a comma), sorted and unique; `(types)` and other parenthetical notes are
-- dropped; "nothing", "none" and "(none)" mean an empty list. nil when the line is absent.
function Headers.parseDeclared(source: string): { string }?
	local header = headerLines(Headers.splitLines(source))
	for i, line in header do
		local rest = string.match(line, "^%-%-%s*requires:%s*(.*)$")
		if not rest then
			continue
		end
		local text = trim(rest)
		local j = i
		while string.match(text, ",%s*$") and header[j + 1] do
			j += 1
			text ..= " " .. (string.match(header[j], "^%-%-%s*(.*)$") or "")
		end
		text = trim(text)
		if text == "" or NONE[string.lower(text)] then
			return {}
		end
		text = string.gsub(text, "%b()", "")
		local names: { [string]: boolean } = {}
		for item in string.gmatch(text, "[^,]+") do
			local name = trim((string.gsub(item, "%.$", "")))
			if name ~= "" and not NONE[string.lower(name)] then
				names[name] = true
			end
		end
		return sortedKeys(names)
	end
	return nil
end

-- --!strict first, then a doc comment (a `--` line that is not another directive).
local function headerShape(lines: { string }): (boolean, boolean)
	local first: string? = nil
	local second: string? = nil
	for _, line in lines do
		local t = trim(line)
		if t ~= "" then
			if first == nil then
				first = t
			else
				second = t
				break
			end
		end
	end
	local strict = first == "--!strict"
	local doc = second ~= nil
		and string.sub(second :: string, 1, 2) == "--"
		and string.sub(second :: string, 1, 3) ~= "--!"
	return strict, doc
end

local function kindOf(fileName: string): Kind
	if string.match(fileName, "%.server%.luau$") then
		return "Script"
	elseif string.match(fileName, "%.client%.luau$") then
		return "LocalScript"
	end
	return "ModuleScript"
end

local function nameOf(fileName: string): string
	return (string.gsub(fileName, "%.%a+%.luau$", "")):gsub("%.luau$", "")
end

function Headers.describe(path: string, family: string, source: string): Module
	local fileName = string.match(path, "[^/]+$") :: string
	local lines = Headers.splitLines(source)
	local strict, doc = headerShape(lines)
	return {
		name = nameOf(fileName),
		path = path,
		family = family,
		kind = kindOf(fileName),
		requires = Headers.parseRequires(source),
		declared = Headers.parseDeclared(source),
		strict = strict,
		doc = doc,
	}
end

local function walk(base: string, relative: string, family: string?, out: { Module })
	local entries = fs.readDir(`{base}/{relative}`)
	table.sort(entries)
	for _, entry in entries do
		local rel = `{relative}/{entry}`
		if fs.isDir(`{base}/{rel}`) then
			walk(base, rel, family or entry, out)
		elseif string.match(entry, "%.luau$") then
			table.insert(out, Headers.describe(rel, family or "", fs.readFile(`{base}/{rel}`)))
		end
	end
end

-- Every .luau file under the source roots, sorted by path. `root` is the repository root ("." by default).
function Headers.scan(root: string?): { Module }
	local base = root or "."
	local modules: { Module } = {}
	for index, sub in Headers.ROOTS do
		if fs.isDir(`{base}/{sub}`) then
			walk(base, sub, if index == 1 then nil else Headers.SHARED_FAMILY, modules)
		end
	end
	table.sort(modules, function(a, b)
		return a.path < b.path
	end)
	return modules
end

-- name -> required names, for every module.
function Headers.graph(modules: { Module }): { [string]: { string } }
	local edges: { [string]: { string } } = {}
	for _, module in modules do
		edges[module.name] = module.requires
	end
	return edges
end

-- The first cycle found by a depth-first walk in sorted order, as the path round to the repeated
-- node (`{ "A", "B", "A" }`), or nil. Edges to names outside the graph are ignored.
function Headers.findCycle(edges: { [string]: { string } }): { string }?
	local state: { [string]: number } = {} -- 1 on the stack, 2 finished
	local stack: { string } = {}
	local function visit(name: string): { string }?
		state[name] = 1
		table.insert(stack, name)
		for _, dep in edges[name] or {} do
			if state[dep] == 1 then
				local cycle: { string } = {}
				for i = table.find(stack, dep) :: number, #stack do
					table.insert(cycle, stack[i])
				end
				table.insert(cycle, dep)
				return cycle
			elseif state[dep] == nil and edges[dep] then
				local found = visit(dep)
				if found then
					return found
				end
			end
		end
		table.remove(stack)
		state[name] = 2
		return nil
	end
	local names: { string } = {}
	for name in edges do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		if state[name] == nil then
			local found = visit(name)
			if found then
				return found
			end
		end
	end
	return nil
end

local function sameList(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for i, value in a do
		if b[i] ~= value then
			return false
		end
	end
	return true
end

-- Modules whose `-- requires:` line is missing or disagrees with the code.
function Headers.mismatches(modules: { Module }): { Mismatch }
	local out: { Mismatch } = {}
	for _, module in modules do
		if module.declared == nil or not sameList(module.declared :: { string }, module.requires) then
			table.insert(out, { path = module.path, declared = module.declared, actual = module.requires })
		end
	end
	return out
end

local function listOrNothing(names: { string }): string
	return if #names == 0 then "nothing" else table.concat(names, ", ")
end

-- The difference between a declared and an actual list, for a one-line message.
function Headers.describeMismatch(mismatch: Mismatch): string
	local declared = mismatch.declared
	if declared == nil then
		return `no "-- requires:" line (the code requires {listOrNothing(mismatch.actual)})`
	end
	local declaredSet: { [string]: boolean } = {}
	for _, name in declared do
		declaredSet[name] = true
	end
	local actualSet: { [string]: boolean } = {}
	for _, name in mismatch.actual do
		actualSet[name] = true
	end
	local missing: { string } = {}
	for _, name in mismatch.actual do
		if not declaredSet[name] then
			table.insert(missing, name)
		end
	end
	local extra: { string } = {}
	for _, name in declared do
		if not actualSet[name] then
			table.insert(extra, name)
		end
	end
	local parts: { string } = {}
	if #missing > 0 then
		table.insert(parts, `missing {table.concat(missing, ", ")}`)
	end
	if #extra > 0 then
		table.insert(parts, `extra {table.concat(extra, ", ")}`)
	end
	return `"-- requires:" says {listOrNothing(declared)} but the code requires {listOrNothing(mismatch.actual)} ({table.concat(
		parts,
		"; "
	)})`
end

-- One line per violated rule, "path: reason", in path order: the header convention of §2.36.
function Headers.headerViolations(root: string?): { string }
	local out: { string } = {}
	for _, module in Headers.scan(root) do
		if not module.strict then
			table.insert(out, `{module.path}: the first non-empty line is not --!strict`)
		end
		if not module.doc then
			table.insert(out, `{module.path}: no "--" doc comment on the line after --!strict`)
		end
		if module.declared == nil or not sameList(module.declared :: { string }, module.requires) then
			table.insert(
				out,
				`{module.path}: {Headers.describeMismatch({
					path = module.path,
					declared = module.declared,
					actual = module.requires,
				})}`
			)
		end
	end
	return out
end

-- Family names in printing order: the known ones first, then any others sorted.
function Headers.familyOrder(modules: { Module }): { string }
	local present: { [string]: boolean } = {}
	for _, module in modules do
		present[module.family] = true
	end
	local out: { string } = {}
	for _, family in Headers.FAMILY_ORDER do
		if present[family] then
			table.insert(out, family)
			present[family] = nil
		end
	end
	for _, family in sortedKeys(present) do
		table.insert(out, family)
	end
	return out
end

return Headers

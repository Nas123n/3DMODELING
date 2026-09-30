-- Writes one of the Scenes worlds (arena, gauntlet, plaza) as an .rbxmx model file, so the Studio
-- checklist can rebuild the exact geometry the Lune suite runs against: insert the file into
-- Workspace with "Insert from file". The model is serialized through @lune/roblox, then read back
-- from disk and compared (instance count, tags, attributes) so a silent serialization gap fails
-- the run instead of the checklist. Usage, from the repository root:
--   lune run tools/lune/ExportScene <arena|gauntlet|plaza> [out.rbxmx]   (default build/<Name>.rbxmx)

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Loader = require("./Loader")
local Scenes = require("./Scenes")

local BUILDERS = { arena = Scenes.arena, gauntlet = Scenes.gauntlet, plaza = Scenes.plaza }
local TAGS =
	{ Scenes.POI_TAG, Scenes.SPAWN_TAG, Scenes.AVOID_TAG, Scenes.SLOW_TAG, Scenes.NO_SPAWN_TAG, Scenes.SEAT_TAG }

local name = process.args[1]
local build = if name then BUILDERS[name] else nil
if not build then
	print("usage: lune run tools/lune/ExportScene <arena|gauntlet|plaza> [out.rbxmx]")
	process.exit(2)
end

-- Tags and attributes across a tree, as sorted "path tag" / "path attr=value" lines.
local function marks(root: any): { string }
	local out: { string } = {}
	local function visit(instance: any, path: string)
		for _, tag in TAGS do
			if instance:HasTag(tag) then
				table.insert(out, `{path} #{tag}`)
			end
		end
		for key, value in instance:GetAttributes() do
			table.insert(out, `{path} {key}={tostring(value)}`)
		end
		local children = instance:GetChildren()
		table.sort(children, function(a, b)
			return a.Name < b.Name
		end)
		local counts: { [string]: number } = {}
		for _, child in children do
			counts[child.Name] = (counts[child.Name] or 0) + 1
			visit(child, `{path}/{child.Name}#{counts[child.Name]}`)
		end
	end
	visit(root, root.Name)
	table.sort(out)
	return out
end

local session = Loader.new()
local model = (build :: any)(session)
local out = process.args[2] or `build/{model.Name}.rbxmx`
local dir = string.match(out, "^(.*)/[^/]+$")
if dir and dir ~= "" and not fs.isDir(dir) then
	fs.writeDir(dir)
end

local instances = 1 + #model:GetDescendants()
local before = marks(model)
fs.writeFile(out, roblox.serializeModel({ model }, true))

local back = roblox.deserializeModel(fs.readFile(out))
local status = 0
if #back ~= 1 then
	print(`round trip: expected one root instance, read back {#back}`)
	status = 1
end
local root = back[1]
local readInstances = if root then 1 + #root:GetDescendants() else 0
if readInstances ~= instances then
	print(`round trip: wrote {instances} instances, read back {readInstances}`)
	status = 1
end
local after = if root then marks(root) else {}
if table.concat(before, "\n") ~= table.concat(after, "\n") then
	print(`round trip: tags or attributes differ ({#before} marks written, {#after} read back)`)
	status = 1
end

print(`{out}: {model.Name}, {instances} instances, {#before} tag/attribute marks, {#fs.readFile(out)} bytes`)
print(if status == 0 then "round trip verified" else "round trip FAILED")
process.exit(status)

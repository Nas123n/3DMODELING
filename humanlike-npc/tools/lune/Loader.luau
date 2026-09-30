-- Runs the system's ModuleScripts under Lune (https://lune-org.github.io) without Studio.
-- Mirrors default.project.json into a real Lune DataModel, so `require(script.Parent.X)` and
-- `game:GetService(...)` resolve exactly as they do in Roblox. Lune has no physics, so
-- `workspace` is swapped for World, which answers Raycast and the bounds queries itself.
--
-- Scripts (Bootstrap.server.luau, *.client.luau) are mounted so their instances exist, but they
-- are never executed here: they connect signals Lune cannot fire. Tests require modules only.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local World = require("./World")

local Loader = {}

local SCRIPT_CLASSES = {
	server = "Script",
	client = "LocalScript",
}

local function scriptFor(name: string): Instance
	local base, kind = string.match(name, "^(.-)%.(%a+)%.luau$")
	local className = kind and SCRIPT_CLASSES[kind]
	if className then
		local instance = roblox.Instance.new(className)
		instance.Name = base
		return instance
	end
	local instance = roblox.Instance.new("ModuleScript")
	instance.Name = string.gsub(name, "%.luau$", "")
	return instance
end

export type Session = {
	game: any,
	workspace: any,
	world: any,
	require: (any) -> any,
	-- Extra globals visible to every module loaded through this session (test hooks).
	globals: { [string]: any },
}

function Loader.new(root: string?): Session
	local projectRoot = root or "."
	local project = serde.decode("json", fs.readFile(`{projectRoot}/default.project.json`))
	local game = roblox.Instance.new("DataModel")
	-- Keyed by full name: Lune hands out a new wrapper object each time an instance is
	-- indexed, so the instances themselves can't be table keys.
	local sources: { [string]: string } = {}

	local function mount(parent: any, name: string, path: string)
		if fs.isDir(path) then
			local folder = roblox.Instance.new("Folder")
			folder.Name = name
			folder.Parent = parent -- before children, so their full names are final
			for _, entry in fs.readDir(path) do
				local child = `{path}/{entry}`
				if fs.isDir(child) then
					mount(folder, entry, child)
				elseif string.match(entry, "%.luau$") then
					local instance = scriptFor(entry)
					instance.Parent = folder
					sources[instance:GetFullName()] = child
				end
			end
		else
			local instance = scriptFor(string.match(path, "[^/]+$") :: string)
			instance.Name = name
			instance.Parent = parent
			sources[instance:GetFullName()] = path
		end
	end

	local function walk(node: { [string]: any }, instance: any)
		for key, child in node do
			if string.sub(key, 1, 1) == "$" then
				continue
			end
			if child["$path"] then
				mount(instance, key, `{projectRoot}/{child["$path"]}`)
			else
				local target = if instance == game then game:GetService(key) else nil
				if not target then
					target = roblox.Instance.new(child["$className"] or "Folder")
					target.Name = key
					target.Parent = instance
				end
				walk(child, target)
			end
		end
	end
	walk(project.tree, game)

	local world = World.new(game:GetService("Workspace"))
	local cache: { [string]: any } = {}
	local loading: { [string]: boolean } = {}
	local fallback = getfenv(1)
	local globals: { [string]: any } = {}

	local function requireModule(target: any): any
		local key = if typeof(target) == "Instance" then target:GetFullName() else tostring(target)
		if cache[key] ~= nil then
			return cache[key]
		end
		local path = sources[key]
		if not path then
			error(`require: {key} is not a module from default.project.json`, 2)
		end
		assert(not loading[key], `require cycle at {path}`)
		loading[key] = true
		local env = setmetatable({
			script = target,
			require = requireModule,
			game = game,
			workspace = world,
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			BrickColor = roblox.BrickColor,
			Enum = roblox.Enum,
			UDim = roblox.UDim,
			UDim2 = roblox.UDim2,
			ColorSequence = roblox.ColorSequence,
			ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
			NumberSequence = roblox.NumberSequence,
			NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
			NumberRange = roblox.NumberRange,
			RaycastParams = World.RaycastParams,
			OverlapParams = World.OverlapParams,
		}, {
			__index = function(_, name)
				local extra = globals[name]
				if extra ~= nil then
					return extra
				end
				return fallback[name]
			end,
		})
		local chunk = luau.load(fs.readFile(path), { debugName = path, environment = env })
		local result = chunk()
		loading[key] = nil
		cache[key] = result
		return result
	end

	return {
		game = game,
		workspace = game:GetService("Workspace"),
		world = world,
		require = requireModule,
		globals = globals,
	}
end

return Loader

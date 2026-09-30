-- Enforces the rings mechanically (spec §0.2, §2.36): every ModuleScript under src/server outside
-- Adapters/ and Api, and every one under src/shared, loads under Lune from a fresh Loader session
-- and returns a table; no ring-1 source contains a forbidden token (anchored patterns, with a
-- self-test); the require graph has no cycle (the Loader's own re-entrancy guard on `require`
-- catches a dynamic one, and the source graph names its path); and every header follows the
-- convention. Source-level facts come from tools/lune/Headers, which DepGraph prints from too.
return function(T, Loader)
	local fs = require("@lune/fs")
	local Headers = require("../tools/lune/Headers")

	-- Qualified names and method calls that only ring 2 may use.
	local QUALIFIED = {
		"task%.",
		"Random%.new",
		"os%.clock",
		":Connect%(",
		"ComputeAsync",
		":MoveTo%(",
		":Move%(",
		"SetNetworkOwner",
		":PivotTo%(",
		":GetPivot%(",
		"GetTagged%(",
		":SetStateEnabled%(",
	}
	-- Free calls (not preceded by an identifier character, "." or ":"), also at line start.
	local FREE = { "tick", "wait", "spawn", "delay" }

	-- The forbidden pattern a line of code matches, or nil.
	local function forbiddenIn(code: string): string?
		for _, pattern in QUALIFIED do
			if string.find(code, pattern) then
				return pattern
			end
		end
		for _, name in FREE do
			if string.find(code, `[^%w_%.:]{name}%(`) or string.find(code, `^{name}%(`) then
				return `{name}(`
			end
		end
		return nil
	end

	local modules = Headers.scan(".")
	local ring1 = {}
	for _, module in modules do
		if module.kind == "ModuleScript" and module.family ~= "Adapters" and module.name ~= "Api" then
			table.insert(ring1, module)
		end
	end

	-- The instance a module's path names in a session's DataModel.
	local function instanceFor(session, module)
		local node, relative
		if string.sub(module.path, 1, 11) == "src/server/" then
			node = session.game.ServerStorage.HumanlikeNpc
			relative = string.sub(module.path, 12)
		else
			node = session.game.ReplicatedStorage.HumanlikeNpcShared
			relative = string.sub(module.path, 12)
		end
		for segment in string.gmatch((string.gsub(relative, "%.luau$", "")), "[^/]+") do
			node = node:FindFirstChild(segment)
			if not node then
				error(`{module.path}: {segment} is not mounted by the Loader`)
			end
		end
		return node
	end

	-- Source paths in a traceback, innermost first: the chain of module bodies that was running.
	local function chainFrom(traceback: string): { string }
		local chain, seen = {}, {}
		for path in string.gmatch(traceback, "(src/[%w_/%.]+%.luau)") do
			if not seen[path] then
				seen[path] = true
				table.insert(chain, path)
			end
		end
		return chain
	end

	-- Every ring-1 module through its own fresh session, so each cycle is met from its own entry.
	local loadErrors = {}
	local cycleErrors = {}
	for _, module in ring1 do
		local session = Loader.new()
		local traceback = nil
		local ok, result = xpcall(function()
			return session.require(instanceFor(session, module))
		end, function(err)
			traceback = debug.traceback(tostring(err), 2)
			return err
		end)
		if not ok then
			local message = tostring(result)
			table.insert(loadErrors, `{module.path}: {message}`)
			if string.find(message, "require cycle", 1, true) then
				table.insert(
					cycleErrors,
					`{module.path}: {message} (chain: {table.concat(chainFrom(traceback), " <- ")})`
				)
			end
		elseif type(result) ~= "table" then
			table.insert(loadErrors, `{module.path}: returned {typeof(result)}, not a table`)
		end
	end

	T.describe("LoadAll", function()
		T.it("every ring-1 module loads from a fresh session and returns a table", function()
			T.check(#ring1 > 0, "no ring-1 modules found under src/server and src/shared")
			T.check(
				#loadErrors == 0,
				`{#loadErrors} module(s) failed to load:\n    {table.concat(loadErrors, "\n    ")}`
			)
		end)

		T.it("forbidden-token patterns are anchored", function()
			T.equal(forbiddenIn("local x = self:tick(now)"), nil, "a tick method")
			T.equal(forbiddenIn("queue:delay(2)"), nil, "a delay method")
			T.check(forbiddenIn("task.wait(1)") ~= nil, "task.wait")
			T.check(forbiddenIn("wait(1)") ~= nil, "a free wait")
			T.check(forbiddenIn("spawn(function() end)") ~= nil, "a free spawn")
			T.check(forbiddenIn("Random.new()") ~= nil, "Random.new")
		end)

		T.it("no ring-1 source contains a forbidden token", function()
			local hits = {}
			for _, module in ring1 do
				for _, entry in Headers.codeLines(fs.readFile(module.path)) do
					local pattern = forbiddenIn(entry.code)
					if pattern then
						table.insert(hits, `{module.path}:{entry.line}: {pattern} in "{entry.code}"`)
					end
				end
			end
			T.check(#hits == 0, `{#hits} forbidden token(s):\n    {table.concat(hits, "\n    ")}`)
		end)

		T.it("no require cycle", function()
			local cycle = Headers.findCycle(Headers.graph(modules))
			T.check(cycle == nil, `require cycle in the sources: {table.concat(cycle or {}, " -> ")}`)
			T.check(#cycleErrors == 0, `the Loader met a cycle:\n    {table.concat(cycleErrors, "\n    ")}`)
		end)

		T.it("header convention", function()
			local violations = Headers.headerViolations(".")
			T.check(
				#violations == 0,
				`{#violations} header violation(s) (--!strict, a doc comment, a matching "-- requires:" line):\n    {table.concat(
					violations,
					"\n    "
				)}`
			)
		end)
	end)
end

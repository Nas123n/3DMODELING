-- Minimal test helpers: describe/it blocks and assertions that say what they compared.
-- Kept tiny on purpose so the suite has no dependencies beyond Lune itself.

local T = {}

local passed, failures = 0, {}
local prefix = ""
-- Wall time: since this module loaded (the whole run) and per top-level describe (one suite each).
local startedAt = os.clock()
local timings: { { name: string, seconds: number } } = {}

function T.describe(name: string, body: () -> ())
	local previous = prefix
	prefix = if previous == "" then name else `{previous} > {name}`
	body()
	prefix = previous
end

-- Top-level describes are the suites: time them so T.report can print each one's wall time.
local describe = T.describe
T.describe = function(name: string, body: () -> ())
	if prefix ~= "" then
		describe(name, body)
		return
	end
	local t0 = os.clock()
	describe(name, body)
	table.insert(timings, { name = name, seconds = os.clock() - t0 })
end

function T.it(name: string, body: () -> ())
	local ok, err = pcall(body)
	if ok then
		passed += 1
	else
		table.insert(failures, `{prefix} > {name}\n    {err}`)
	end
end

function T.check(condition: any, message: string?)
	if not condition then
		error(message or "check failed", 2)
	end
end

function T.equal(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "values differ"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function T.near(actual: number, expected: number, tolerance: number, message: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{message or "numbers differ"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

function T.between(actual: number, lo: number, hi: number, message: string?)
	if actual < lo or actual > hi then
		error(`{message or "number out of range"}: expected {lo}..{hi}, got {actual}`, 2)
	end
end

function T.throws(body: () -> (), pattern: string?)
	local ok, err = pcall(body)
	if ok then
		error("expected an error, none was raised", 2)
	end
	if pattern and not string.find(tostring(err), pattern) then
		error(`error "{tostring(err)}" does not match "{pattern}"`, 2)
	end
end

function T.report(): number
	for _, failure in failures do
		print(`FAIL {failure}`)
	end
	if #timings > 0 then
		print("wall time per suite:")
		for _, entry in timings do
			print(string.format("  %8.2f s  %s", entry.seconds, entry.name))
		end
	end
	print(`{passed} passed, {#failures} failed (wall {string.format("%.1f", os.clock() - startedAt)} s)`)
	return #failures
end

return T

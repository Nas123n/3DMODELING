-- Minimal test helpers: describe/it blocks, assertions that name what they compared.

local T = {}

local passed, failures = 0, {}
local prefix = ""

function T.describe(name: string, body: () -> ())
	local previous = prefix
	prefix = if previous == "" then name else `{previous} > {name}`
	body()
	prefix = previous
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
	print(`{passed} passed, {#failures} failed`)
	return #failures
end

return T

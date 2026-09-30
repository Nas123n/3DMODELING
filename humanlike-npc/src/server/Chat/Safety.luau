--!strict
-- The last gate before any NPC text leaves the server. The corpus is written to be safe, but
-- games extend it and slots fill it, so every outgoing line is checked again: a blocklist of
-- patterns that must never appear (personal information, off-platform, money, dating, lures),
-- a plain character set, a length cap, a kill switch, and an audit ring so any line can be
-- traced back to its corpus entry and removed.
--
-- Developer patterns (Config.ChatExtraPatterns) are Lua patterns typed into an attribute, so
-- they are validated at construction: a malformed one, an empty one or one that matches the
-- empty string (it would silence every line) is dropped and listed by `rejectedPatterns` for
-- Api to warn about. A pattern that only fails once it meets real text is caught inside
-- `reason` and dropped there. `check` never raises: a throw here would trip the error budget
-- and despawn NPCs over a typo in an attribute. It is not a rate limiter (ChatGuard) and not
-- a corpus lint (ChatCorpus.isSafeLine).
-- requires: (none)

local Safety = {}
Safety.__index = Safety

export type Entry = { npcId: string, lineId: string?, text: string, at: number, target: string? }

export type Gate = typeof(setmetatable(
	{} :: {
		enabled: boolean,
		patterns: { string },
		audit: { Entry },
		auditCapacity: number,
		auditNext: number,
		rejected: number,
		invalidPatterns: { string }, -- extra patterns dropped at construction or while checking
	},
	Safety
))

-- Lua patterns, matched against the lowercased text. Word-ish boundaries where it matters.
Safety.DEFAULT_PATTERNS = {
	"http",
	"www%.",
	"%.com",
	"%.gg",
	"%.net",
	"%.org",
	"discord",
	"snapchat",
	"instagram",
	"insta%f[%W]",
	"tiktok",
	"whatsapp",
	"telegram",
	"youtube%.",
	"twitch",
	"robux",
	"%$",
	"paypal",
	"gift ?card",
	"free stuff",
	"giveaway",
	"free pets?%f[%W]",
	"password",
	"phone",
	"number%f[%W]",
	"address",
	"how old",
	"ur age",
	"your age",
	"my age",
	"age%?",
	"%f[%a]age%f[%A]",
	"school",
	"where do u live",
	"where do you live",
	"where u live",
	"real name",
	"girlfriend",
	"boyfriend",
	"gf%f[%W]",
	"bf%f[%W]",
	"date me",
	"dating",
	"kiss",
	"sexy",
	"hot%f[%W]",
	"kill yourself",
	"kys%f[%W]",
	"die%f[%W]",
	"meet me",
	"meet up",
	"come to my",
	"go to my",
	"join my",
	"account",
	"trade me ur",
	"give me ur",
	"ill give u 2",
	"i'll give u",
	"@",
}

Safety.CHARSET = "^[%w%s%?%!%#%:%(%)%-%_%'%.%,]*$"

-- Every character `CHARSET` admits, lowercased like the text a pattern meets. Matching a
-- candidate pattern against it surfaces errors the empty subject cannot reach ("a%" only
-- fails after the "a" matched).
local PROBE_TEXT = "abcdefghijklmnopqrstuvwxyz 0123456789 ?!#:()-_'., \t\n"

-- Splits `patterns` into the ones the gate may use and the ones it must drop: a non-string, an
-- empty pattern, a malformed pattern (pcall(string.find, "", p) and the probe text) or a pattern
-- that matches the empty string (it would reject every line). Order is preserved.
function Safety.validatePatterns(patterns: { string }): ({ string }, { string })
	local accepted: { string } = {}
	local rejected: { string } = {}
	for _, pattern in patterns do
		local ok = type(pattern) == "string" and #pattern > 0
		if ok then
			local emptyOk, emptyHit = pcall(string.find, "", pattern)
			local probeOk = pcall(string.find, PROBE_TEXT, pattern)
			ok = emptyOk and probeOk and emptyHit == nil
		end
		table.insert(if ok then accepted else rejected, pattern)
	end
	return accepted, rejected
end

function Safety.new(extraPatterns: { string }?, auditCapacity: number?): Gate
	local patterns = table.clone(Safety.DEFAULT_PATTERNS)
	local extra: { string } = extraPatterns or {}
	local accepted, invalid = Safety.validatePatterns(extra)
	for _, p in accepted do
		table.insert(patterns, p)
	end
	return setmetatable({
		enabled = true,
		patterns = patterns,
		audit = {},
		auditCapacity = auditCapacity or 500,
		auditNext = 1,
		rejected = 0,
		invalidPatterns = invalid,
	}, Safety)
end

-- Extra patterns that were dropped (construction or a later check), in the order found.
function Safety.rejectedPatterns(self: Gate): { string }
	return table.clone(self.invalidPatterns)
end

-- Why a text is rejected, or nil when it may be said. Never raises: a pattern that errors on
-- this text is dropped from the gate and reported through `rejectedPatterns`.
function Safety.reason(self: Gate, text: string): string?
	if not self.enabled then
		return "disabled"
	end
	if #text == 0 then
		return "empty"
	end
	if #text > 120 then
		return "too long"
	end
	if not string.match(text, Safety.CHARSET) then
		return "charset"
	end
	local lower = string.lower(text)
	local i = 1
	while i <= #self.patterns do
		local pattern = self.patterns[i]
		local ok, hit = pcall(string.find, lower, pattern)
		if not ok then
			table.remove(self.patterns, i)
			table.insert(self.invalidPatterns, pattern)
		elseif hit then
			return `pattern {pattern}`
		else
			i += 1
		end
	end
	return nil
end

function Safety.check(self: Gate, text: string): boolean
	local reason = self:reason(text)
	if reason then
		self.rejected += 1
		return false
	end
	return true
end

-- Records a line that was actually said.
function Safety.record(self: Gate, npcId: string, lineId: string?, text: string, at: number, target: string?)
	self.audit[self.auditNext] = { npcId = npcId, lineId = lineId, text = text, at = at, target = target }
	self.auditNext = self.auditNext % self.auditCapacity + 1
end

-- Most recent first.
function Safety.log(self: Gate, limit: number?): { Entry }
	local out = {}
	local n = 0
	local index = self.auditNext - 1
	while n < (limit or self.auditCapacity) do
		if index < 1 then
			index = self.auditCapacity
		end
		local entry = self.audit[index]
		if not entry then
			break
		end
		table.insert(out, entry)
		n += 1
		index -= 1
		if index == self.auditNext - 1 then
			break
		end
	end
	return out
end

function Safety.setEnabled(self: Gate, enabled: boolean)
	self.enabled = enabled
end

return Safety

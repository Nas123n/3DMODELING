--!strict
-- The last gate before any NPC text leaves the server. The corpus is written to be safe, but
-- games extend it and slots fill it, so every outgoing line is checked again: a blocklist of
-- patterns that must never appear (personal information, off-platform, money, dating, lures),
-- a plain character set, a length cap, a kill switch, and an audit ring so any line can be
-- traced back to its corpus entry and removed.

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

function Safety.new(extraPatterns: { string }?, auditCapacity: number?): Gate
	local patterns = table.clone(Safety.DEFAULT_PATTERNS)
	local extra: { string } = extraPatterns or {}
	for _, p in extra do
		table.insert(patterns, p)
	end
	return setmetatable({
		enabled = true,
		patterns = patterns,
		audit = {},
		auditCapacity = auditCapacity or 500,
		auditNext = 1,
		rejected = 0,
	}, Safety)
end

-- Why a text is rejected, or nil when it may be said.
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
	for _, pattern in self.patterns do
		if string.find(lower, pattern) then
			return `pattern {pattern}`
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

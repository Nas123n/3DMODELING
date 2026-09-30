--!strict
-- A bag of things to undo together: signal connections, threads and plain cleanup functions, with child bags
-- that empty with their parent. `disconnectAll` frees children first, then entries newest first: a connection
-- is disconnected, a thread is cancelled through `task.cancel` (never the running one, never a finished one)
-- and a function is called; a child that is emptied detaches from its parent so the tree never grows with
-- players who left. `count` (this bag plus every child) is the leak gauge the Studio checklist reads.
-- It is not a signal, an event bus or a scheduler: it only holds references and frees them, touches no
-- service at all, and so loads and runs under Lune exactly as in Studio (a Lune fake connection is any table
-- with a Disconnect method).
-- requires: nothing

local Connections = {}
Connections.__index = Connections

-- What a bag holds: a connection, a thread, or a function to call on disconnect.
export type Entry = RBXScriptConnection | thread | () -> ()

export type Bag = typeof(setmetatable(
	{} :: {
		name: string,
		entries: { any }, -- Entry; kept as any so a fake connection (a table with Disconnect) is accepted too
		children: { any }, -- Bag; the alias cannot name itself inside its own typeof
		parent: any?, -- Bag?
	},
	Connections
))

function Connections.new(name: string?): Bag
	return setmetatable({
		name = name or "bag",
		entries = {},
		children = {},
		parent = nil,
	}, Connections)
end

-- Registers an entry and returns it, so `bag:add(signal:Connect(fn))` reads naturally.
function Connections.add(self: Bag, entry: Entry): Entry
	table.insert(self.entries, entry)
	return entry
end

-- Forgets an entry without disconnecting it (a thread that finished on its own). True when it was held.
function Connections.remove(self: Bag, entry: any): boolean
	for i = #self.entries, 1, -1 do
		if self.entries[i] == entry then
			table.remove(self.entries, i)
			return true
		end
	end
	return false
end

-- A nested bag emptied with this one; emptying the child alone detaches it from this bag.
function Connections.child(self: Bag, name: string): Bag
	local child = Connections.new(name)
	child.parent = self
	table.insert(self.children, child)
	return child
end

local function release(entry: any)
	local kind = type(entry)
	if kind == "function" then
		pcall(entry)
	elseif kind == "thread" then
		if entry ~= coroutine.running() and coroutine.status(entry) ~= "dead" then
			local cancelled = pcall(function()
				task.cancel(entry)
			end)
			if not cancelled then
				-- No task library (a Lune session): closing the suspended coroutine is the same outcome.
				pcall(coroutine.close, entry)
			end
		end
	else
		pcall(function()
			entry:Disconnect()
		end)
	end
end

local function detach(self: Bag)
	local parent: Bag? = self.parent
	if parent == nil then
		return
	end
	self.parent = nil
	for i = #parent.children, 1, -1 do
		if parent.children[i] == self then
			table.remove(parent.children, i)
			return
		end
	end
end

-- Frees everything: children first (each detaches itself), then this bag's entries, newest first. The bag
-- stays usable afterwards; a child is detached from its parent so it stops counting there.
function Connections.disconnectAll(self: Bag)
	local children = self.children
	self.children = {}
	for i = #children, 1, -1 do
		local child: Bag = children[i]
		child.parent = nil
		child:disconnectAll()
	end
	local entries = self.entries
	self.entries = {}
	for i = #entries, 1, -1 do
		release(entries[i])
	end
	detach(self)
end

-- Entries held here and in every child (the leak gauge).
function Connections.count(self: Bag): number
	local n = #self.entries
	for _, child in self.children do
		n += (child :: Bag):count()
	end
	return n
end

-- Number of child bags below this one, at every depth.
function Connections.childCount(self: Bag): number
	local n = #self.children
	for _, child in self.children do
		n += (child :: Bag):childCount()
	end
	return n
end

return Connections

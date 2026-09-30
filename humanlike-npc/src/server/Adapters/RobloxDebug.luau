--!strict
-- The Studio debug overlay (Config.Debug): a Folder workspace.HumanlikeNpcDebug holding one BillboardGui per
-- NPC (activity, mood, phase, tier, locomotion status, recovery level; adorned to the body, never parented
-- inside it), path polylines as thin anchored Parts (CanQuery, CanCollide and CanTouch off) and, on demand,
-- the NavGrid heatmap (walkable cells tinted by cost, blocked cells red, capped so a big grid is drawn at a
-- stride). Everything under the folder is destroyed by `stop`. It is the only adapter allowed to read an
-- Npc's internals, through `describe` (brain:describe(), locomotion:describe()), always inside pcall. It
-- never changes an NPC, never replicates anything to a character and adds no marker to any body.
-- requires: Connections, NavGrid (types)

local Connections = require(script.Parent.Connections)
local NavGrid = require(script.Parent.Parent.Nav.NavGrid)

type Bag = Connections.Bag
type Grid = NavGrid.Grid

local RobloxDebug = {}
RobloxDebug.__index = RobloxDebug

export type Info = {
	activity: string?,
	target: string?,
	mood: string?,
	phase: string?,
	tier: string?,
	locomotion: string?,
	recoveryLevel: number?,
	extra: string?, -- one free line (pressure, events)
}

export type Options = {
	bag: Bag,
	folderName: string?, -- default "HumanlikeNpcDebug"
	maxGridParts: number?, -- default 6000
	maxPathSegments: number?, -- per NPC; default 64
}

type Label = { gui: BillboardGui, text: TextLabel, model: Model }

export type Debug = typeof(setmetatable(
	{} :: {
		bag: Bag,
		folderName: string,
		maxGridParts: number,
		maxPathSegments: number,
		folder: Folder?,
		labels: { [string]: Label },
		paths: { [string]: Folder },
		gridFolder: Folder?,
		gridShown: boolean,
		stopped: boolean,
	},
	RobloxDebug
))

RobloxDebug.FOLDER_NAME = "HumanlikeNpcDebug"

function RobloxDebug.new(options: Options): Debug
	return setmetatable({
		bag = options.bag:child("debug"),
		folderName = options.folderName or RobloxDebug.FOLDER_NAME,
		maxGridParts = options.maxGridParts or 6000,
		maxPathSegments = options.maxPathSegments or 64,
		folder = nil,
		labels = {},
		paths = {},
		gridFolder = nil,
		gridShown = false,
		stopped = false,
	}, RobloxDebug)
end

local function folderOf(self: Debug): Folder?
	if self.stopped then
		return nil
	end
	local folder = self.folder
	if folder and folder.Parent ~= nil then
		return folder
	end
	local ok, created = pcall(function()
		local f = Instance.new("Folder")
		f.Name = self.folderName
		f.Parent = workspace
		return f
	end)
	if not ok then
		return nil
	end
	self.folder = created
	return created
end

-- What the overlay shows for an NPC, read from the core's describe() methods inside pcall.
function RobloxDebug.describe(npc: any): Info
	local info: Info = {}
	pcall(function()
		local brain = npc.brain
		if brain and type(brain.describe) == "function" then
			local d = brain:describe()
			info.activity = d.activity
			info.target = d.target
			info.mood = d.mood
			info.phase = d.phase
		end
	end)
	pcall(function()
		info.tier = if type(npc.tier) == "string" then npc.tier else nil
		local locomotion = npc.locomotion
		if locomotion and type(locomotion.describe) == "function" then
			local d = locomotion:describe()
			info.locomotion = d.status
			info.recoveryLevel = d.level
		else
			info.locomotion = if type(npc.locomotionStatus) == "string" then npc.locomotionStatus else nil
			local recovery = npc.recovery
			if recovery and type(recovery.level) == "number" then
				info.recoveryLevel = recovery.level
			end
		end
	end)
	return info
end

function RobloxDebug.formatInfo(info: Info): string
	local lines: { string } = {}
	local first = `{info.activity or "-"}`
	if info.target then
		first ..= ` > {info.target}`
	end
	table.insert(lines, first)
	table.insert(lines, `{info.mood or "-"} / {info.phase or "-"} / {info.tier or "-"}`)
	table.insert(lines, `{info.locomotion or "-"} L{info.recoveryLevel or 0}`)
	if info.extra then
		table.insert(lines, info.extra)
	end
	return table.concat(lines, "\n")
end

-- Creates (or re-adorns) the label of an NPC body.
function RobloxDebug.attach(self: Debug, npcId: string, model: Model)
	local folder = folderOf(self)
	if not folder then
		return
	end
	local existing = self.labels[npcId]
	if existing and existing.model == model and existing.gui.Parent ~= nil then
		return
	end
	self:detach(npcId)
	pcall(function()
		local adornee: Instance = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart") or model
		local gui = Instance.new("BillboardGui")
		gui.Name = npcId
		gui.Adornee = adornee
		gui.Size = UDim2.new(0, 220, 0, 64)
		gui.StudsOffset = Vector3.new(0, 3, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 150
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		text.BackgroundTransparency = 0.5
		text.TextColor3 = Color3.fromRGB(255, 255, 255)
		text.TextStrokeTransparency = 0.6
		text.TextSize = 12
		text.TextScaled = false
		text.RichText = false
		text.Text = npcId
		text.Parent = gui
		gui.Parent = folder
		self.labels[npcId] = { gui = gui, text = text, model = model }
	end)
end

function RobloxDebug.update(self: Debug, npcId: string, info: Info)
	local label = self.labels[npcId]
	if not label then
		return
	end
	pcall(function()
		label.text.Text = `{npcId}\n{RobloxDebug.formatInfo(info)}`
	end)
end

-- Reads the NPC's internals and updates its label in one call.
function RobloxDebug.updateFrom(self: Debug, npcId: string, npc: any, extra: string?)
	local info = RobloxDebug.describe(npc)
	info.extra = extra
	self:update(npcId, info)
end

function RobloxDebug.detach(self: Debug, npcId: string)
	local label = self.labels[npcId]
	self.labels[npcId] = nil
	if label then
		pcall(function()
			label.gui:Destroy()
		end)
	end
	self:clearPath(npcId)
end

local function segment(from: Vector3, to: Vector3, color: Color3, parent: Instance)
	local length = (to - from).Magnitude
	if length < 0.05 then
		return
	end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.35
	part.Size = Vector3.new(0.25, 0.25, length)
	part.CFrame = CFrame.lookAt((from + to) / 2, to)
	part.Parent = parent
end

-- Draws an NPC's path as a polyline through the points (replacing the previous one).
function RobloxDebug.showPath(self: Debug, npcId: string, points: { Vector3 }, color: Color3?)
	local folder = folderOf(self)
	if not folder then
		return
	end
	self:clearPath(npcId)
	if #points < 2 then
		return
	end
	pcall(function()
		local holder = Instance.new("Folder")
		holder.Name = `path:{npcId}`
		local tint = color or Color3.fromRGB(80, 200, 255)
		local up = Vector3.new(0, 0.5, 0)
		local last = math.min(#points, self.maxPathSegments + 1)
		for i = 2, last do
			segment(points[i - 1] + up, points[i] + up, tint, holder)
		end
		holder.Parent = folder
		self.paths[npcId] = holder
	end)
end

function RobloxDebug.clearPath(self: Debug, npcId: string)
	local holder = self.paths[npcId]
	self.paths[npcId] = nil
	if holder then
		pcall(function()
			holder:Destroy()
		end)
	end
end

local function costColor(multiplier: number): Color3
	local t = math.clamp((multiplier - 1) / 7, 0, 1)
	return Color3.fromRGB(math.floor(60 + 195 * t), math.floor(200 - 140 * t), 60)
end

-- Builds the heatmap parts; walkable cells green to orange by cost, blocked cells red; at most maxGridParts,
-- so a big grid is drawn every `stride` cells. Yields every 500 parts when it can.
local function buildGrid(self: Debug, grid: Grid, holder: Folder)
	local total = grid.cols * grid.rows
	local stride = math.max(1, math.ceil(math.sqrt(total / self.maxGridParts)))
	local size = grid.cellSize * stride * 0.9
	local made = 0
	for iz = 0, grid.rows - 1, stride do
		for ix = 0, grid.cols - 1, stride do
			if self.stopped or holder.Parent == nil then
				return
			end
			local y = grid:floorAt(ix, iz)
			local blocked = grid:isBlocked(ix, iz)
			if y == nil and not blocked then
				continue
			end
			local center = grid:centerOf(ix, iz)
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.SmoothPlastic
			part.Transparency = 0.5
			part.Size = Vector3.new(size, 0.2, size)
			if y ~= nil then
				part.Color = costColor(grid.cost[iz * grid.cols + ix + 1] or 1)
				part.CFrame = CFrame.new(center.X, y + 0.15, center.Z)
			else
				part.Color = Color3.fromRGB(200, 40, 40)
				part.CFrame = CFrame.new(center.X, 0.15, center.Z)
			end
			part.Parent = holder
			made += 1
			if made % 500 == 0 then
				pcall(function()
					task.wait()
				end)
			end
		end
	end
end

-- Shows or hides the NavGrid heatmap.
function RobloxDebug.showGrid(self: Debug, on: boolean, grid: Grid?)
	local old = self.gridFolder
	self.gridFolder = nil
	self.gridShown = false
	if old then
		pcall(function()
			old:Destroy()
		end)
	end
	if not on or not grid then
		return
	end
	local folder = folderOf(self)
	if not folder then
		return
	end
	local holder = Instance.new("Folder")
	holder.Name = "grid"
	holder.Parent = folder
	self.gridFolder = holder
	self.gridShown = true
	local bag = self.bag
	local ok = pcall(function()
		local thread = task.spawn(function()
			buildGrid(self, grid, holder)
			bag:remove(coroutine.running())
		end)
		if coroutine.status(thread) ~= "dead" then
			bag:add(thread)
		end
	end)
	if not ok then
		buildGrid(self, grid, holder)
	end
end

function RobloxDebug.isActive(self: Debug): boolean
	return not self.stopped
end

function RobloxDebug.count(self: Debug): { labels: number, paths: number, gridShown: boolean }
	local labels, paths = 0, 0
	for _ in self.labels do
		labels += 1
	end
	for _ in self.paths do
		paths += 1
	end
	return { labels = labels, paths = paths, gridShown = self.gridShown }
end

-- Destroys the folder and everything under it.
function RobloxDebug.stop(self: Debug)
	self.stopped = true
	self.bag:disconnectAll()
	self.labels = {}
	self.paths = {}
	self.gridFolder = nil
	self.gridShown = false
	local folder = self.folder
	self.folder = nil
	if folder then
		pcall(function()
			folder:Destroy()
		end)
	end
end

return RobloxDebug

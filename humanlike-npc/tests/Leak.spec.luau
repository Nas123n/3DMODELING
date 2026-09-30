-- Spec §2.36: two hundred NPCs come and go through one FakeWorld over twenty simulated minutes
-- (thirty of them through a presenter reset and rebind, twenty through a death), and afterwards
-- nothing is left behind: no records, no scheduler slots, no planner requests, no recency
-- entries, no reserved names, no connections, and no lasting growth of the Lua heap. Scaled to
-- the suite budget: NPCs live twenty-four seconds each and stand in the dormant tier (one player
-- far outside the arena), which changes nothing about the bookkeeping under test. Lune offers no
-- full garbage collection, so the heap is read at its troughs (the smallest count seen over a
-- minute of running) before the first join and after the last leave.
return function(T, Loader)
	local roblox = require("@lune/roblox")
	local FakeWorld = require("../tools/lune/FakeWorld")
	local Vector3 = roblox.Vector3

	local TOTAL = 200
	local MINUTES = 20
	local SPACING = (MINUTES * 60) / TOTAL -- 6 s between joins
	local LIFETIME = 24
	local RESETS = 30
	local DIED = 20
	local HZ = 10
	local BASELINE = 60 -- seconds of an empty world before the first join (heap trough)
	local TAIL = 150 -- seconds after the last join: leaves, name releases, the closing heap trough
	local GC_DRIVE = 2000 -- array slots of garbage allocated per frame to keep the collector cycling

	T.describe("Leak", function()
		local session = Loader.new()
		local Config = session.require(session.game.ServerStorage.HumanlikeNpc.Config)
		local config = Config.resolve(nil)
		config.NameRetireSeconds = 60
		local world = FakeWorld.new(session, {
			seed = "leak",
			config = config,
			players = {
				{ id = "1", displayName = "Watcher", position = Vector3.new(700, 0, 700), update = nil },
			},
		})
		local service = world.service
		local baselineConnections = world.connections:count()

		local alive = {} -- id -> { spawnedAt, index, username, reset?, died? }
		local spawned, resets, deaths, diedGone = 0, 0, 0, 0
		local retired = {}
		local diedNames = {}
		local memoryBefore, memoryAfter = math.huge, math.huge
		local endAt = BASELINE + MINUTES * 60 + TAIL
		local frames = math.floor(endAt * HZ + 0.5)
		for _ = 1, frames do
			local now = world.now
			if spawned < TOTAL and now >= BASELINE + spawned * SPACING - 1e-6 then
				spawned += 1
				local id = service:spawn(now)
				alive[id] = { spawnedAt = now, index = spawned, username = service:identity(id).username }
			end
			for id, entry in alive do
				local age = now - entry.spawnedAt
				if service:get(id) == nil then
					alive[id] = nil
				elseif entry.index <= RESETS and not entry.reset and age >= 8 then
					entry.reset = true
					resets += 1
					world.adapter.presenter:reset(id)
				elseif entry.index > RESETS and entry.index <= RESETS + DIED and not entry.died and age >= 12 then
					entry.died = true
					deaths += 1
					service:onDied(id, now)
					if service:get(id) == nil then
						diedGone += 1
						diedNames[entry.username] = true
						alive[id] = nil
					end
				elseif age >= LIFETIME then
					service:get(id):forceLeave()
					retired[entry.username] = true
					alive[id] = nil
				end
			end
			world:step(1 / HZ)
			-- The fake's own records of what happened are not what is under test: keep them from growing.
			table.clear(world.log.telemetry)
			table.clear(world.log.avatars)
			-- The incremental collector works in proportion to what is allocated: an empty world allocates
			-- little, so a steady trickle of garbage keeps its cycles turning in both measured windows.
			local _ = table.create(GC_DRIVE, 0)
			local heap = collectgarbage("count")
			if world.now <= BASELINE then
				memoryBefore = math.min(memoryBefore, heap)
			elseif world.now >= endAt - 60 then
				memoryAfter = math.min(memoryAfter, heap)
			end
		end
		print(
			`[leak] {spawned} spawned, {resets} resets, {deaths} deaths ({diedGone} gone), heap {math.floor(
				memoryBefore
			)} -> {math.floor(memoryAfter)} KB`
		)

		T.it("every NPC came and went", function()
			T.equal(spawned, TOTAL)
			T.equal(resets, RESETS)
			T.equal(deaths, DIED)
			T.equal(
				#world.log.resets,
				RESETS + (deaths - diedGone),
				"every reset and every respawn went through the presenter"
			)
			T.equal(service:count(), 0)
			T.equal(next(service.records), nil, "no records")
			T.equal(#service.order, 0, "no order entries")
			T.equal(service:stats().spawned, TOTAL)
			T.equal(service:stats().despawned, TOTAL)
		end)

		T.it("the scheduler, the planner and the grid provider are empty", function()
			T.equal(service.scheduler:count(), 0)
			T.equal(service.planner:getStats().inFlight, 0)
			T.equal(next(service.planner.pending), nil, "no pending request")
			T.equal(next(service.planner.active), nil, "no active request")
			T.equal(#service.gridProvider.queue, 0, "nothing queued at the grid")
			T.equal(service.gridProvider.active, nil, "no search in progress")
		end)

		T.it("recency, the chat guard and the error budget forgot everyone", function()
			for npcId in service.recency.selfUse do
				T.check(false, `recency still knows {npcId}`)
			end
			T.equal(next(service.guard.npcTimes), nil, "the guard holds no NPC")
			T.equal(next(service.errorBudget.times), nil, "the budget holds no NPC")
			T.equal(next(service.lod.tier), nil, "the LOD filter holds no NPC")
			T.equal(next(service.losVisible), nil, "no LOS verdicts")
		end)

		T.it("retired names were released, died names were kept", function()
			local released, kept = 0, 0
			for username in retired do
				if service.names.taken[string.lower(username)] == nil then
					released += 1
				end
			end
			for username in diedNames do
				if service.names.taken[string.lower(username)] then
					kept += 1
				end
			end
			local retiredCount = 0
			for _ in retired do
				retiredCount += 1
			end
			T.equal(released, retiredCount, "every retired name is free again")
			T.equal(kept, diedGone, "a death keeps its name")
			T.equal(next(service.reservedNames), nil, "no retirement is pending")
		end)

		T.it("the connections bag and the heap are back where they started", function()
			T.equal(world.connections:count(), baselineConnections)
			T.equal(next(world.bodies), nil, "no bodies")
			T.check(
				memoryAfter <= memoryBefore * 1.2,
				`heap grew from {math.floor(memoryBefore)} to {math.floor(memoryAfter)} KB`
			)
		end)
	end)
end

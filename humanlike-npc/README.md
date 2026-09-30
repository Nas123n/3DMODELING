# humanlike-npc

A drop-in, server-controlled population of fake players for a Roblox place. Each NPC has a plausible username
and avatar, joins and leaves like a player, walks with the imperfections of a person on a keyboard, gamepad or
phone, has needs, moods and a session arc, notices players, reacts to being followed, stared at, jumped on or
spoken to, chats in a short and rate-limited way, and never does anything only a script would do (perfect stops,
instant reactions, teleports, walking through a no-go area, standing still forever).

Status: this tree has been exercised only under Lune (the test runner in `tools/lune`). No Studio run has been
made yet; the Studio checklist in section 13 says "not yet verified" for every row. `src/server/Api.luau` and the
body of `Bootstrap.server.luau` are the last ring-2 files to land; section 6 documents the contract they
implement (design spec section 2.37).

## 1. What this is and what it is not

The goal is not to pass a Turing test; the goal is that a player watching for the classic tells finds none of
them. Two planners feed one waypoint follower: the engine's `PathfindingService` is primary, a sampled A* grid is
the fallback, and a stand-in goal resolver plus a short "just walk there" beeline make sure an NPC always has
something to do when both fail. Everything that decides is pure Luau that runs under Lune with fake bodies; only a
thin adapter ring touches Roblox instances.

It is not a game AI for enemies or quest givers, not a moderation or anti-cheat tool, and not a chat bot: every
line an NPC says comes from a fixed, developer-authored corpus rendered with typos, never from generated text and
never from a player's words. NPCs are not accounts: they have no UserId, they are not in `Players`, and the
system never collects or stores player identity.

Disclosure requirement. The game description must disclose that some characters are computer-controlled,
without identifying which. Until the Bootstrap attribute `DisclosureAck` is `true`, `Api.start` prints one
warning at startup. Ordinary clients get no way to tell NPCs from players, so this disclosure is the developer's
responsibility and the warning exists to make it hard to forget.

## 2. Install

### With Rojo

`default.project.json` maps the repository onto the place:

| Repository path | Instance |
|---|---|
| `src/server` | `ServerStorage.HumanlikeNpc` (a folder of ModuleScripts; `Bootstrap.server.luau` also appears here as a Script that never runs) |
| `src/server/Bootstrap.server.luau` | `ServerScriptService.HumanlikeNpcBootstrap` (the one Script that runs) |
| `src/shared` | `ReplicatedStorage.HumanlikeNpcShared` (`Remotes`, `ClientConfig`, `NameColor`, `AnimLogic`, `AnimSets`) |
| `src/client` | `StarterPlayer.StarterPlayerScripts.{NpcChatDisplay, NpcAnimator, NpcHeadLook, NpcPresentation}` |

`rojo serve default.project.json` for live sync, or `rojo build default.project.json -o humanlike-npc.rbxm` and
insert the model. Rojo 7.5.1 was used.

### By copying folders into Studio

Recreate the same four locations by hand: every `.luau` under `src/server` becomes a ModuleScript of the same
name inside `ServerStorage.HumanlikeNpc`, with the subfolders (`Nav`, `Human`, `Mind`, `Chat`, `Identity`,
`World`, `Runtime`, `Mimic`, `Eval`, `Adapters`) as Folders; `Bootstrap.server.luau` becomes the Script
`ServerScriptService.HumanlikeNpcBootstrap`; `src/shared/*.luau` become ModuleScripts in the Folder
`ReplicatedStorage.HumanlikeNpcShared`; each `src/client/*.client.luau` becomes a LocalScript in
`StarterPlayerScripts` named without the suffix. Module paths are relative, so nothing else needs editing.

### The Bootstrap script

The whole file, as pinned by the design spec (section 2.37):

```luau
--!strict
-- Starts the humanlike NPC population. Configuration: attributes on this Script (see Config.luau)
-- override the defaults.
local ServerStorage = game:GetService("ServerStorage")
local Api = require(ServerStorage.HumanlikeNpc.Api)
local Config = require(ServerStorage.HumanlikeNpc.Config)
local handle = Api.start({ config = Config.resolve(script) })
game:BindToClose(function()
	handle.stop()
end)
```

### Where configuration lives

- Server settings: attributes on `ServerScriptService.HumanlikeNpcBootstrap`, named exactly like the keys of
  `Config.DEFAULTS` (section 5). Numbers, booleans and strings only. An unknown name or a wrong type is never
  applied; it is collected in `Config.lastWarnings` and printed once at startup. `Config.validate(c)` lists
  values that would make a module misbehave (budgets not positive, tiers not increasing, shares outside 0..1,
  `PopulationMax > 100`, and so on).
- Client settings: attributes on `ReplicatedStorage.HumanlikeNpcShared` (`HidePlayerList`, `HeadLookMaxDegrees`,
  `HeadLookLerp`, `AnimFadeTime`). `Api.start` copies `ChatHook` (as `ChatMode`), `ShowTypingIndicator` and
  `HeadLook` from the server config onto the same folder so the two sides never disagree.
- Extra chat lines: a ModuleScript named `ChatExtra` parented to the Bootstrap script (section 5).
- Optional hooks found by name under the Bootstrap script: a BindableEvent `HumanlikeNpcTelemetry` receives every
  `NpcEvent`; a BindableFunction `HumanlikeNpcCustomWaypoint(label, position)` returns the seconds an NPC should
  hold at a `Custom` path waypoint. There is no config key for either.

## 3. Quick start

1. Open a blank baseplate. It already has a `SpawnLocation`; nothing needs tagging for the demo.
2. Sync the tree (or insert the built model) and press Play.
3. What you see: the population model asks for `InitialBurst` (2) NPCs almost at once, then adds more with gaps
   drawn around `BurstGapMedian` (8 s) up to about `PopulationBase + PopulationPerPlayer x players` (6 + 0.5 per
   player). Each body is a real default R15 avatar built from an id-less `HumanoidDescription` (body colours and
   scales, no catalog ids: the look 10 to 20 percent of real new accounts have). Names come from ten families
   (`Shadow_Wolf27`, `FrostyNinjaX`, `softmoonlight`, `n00bslayer`, `user2083741`, ...). An arriving NPC stands
   still for a couple of seconds, makes a first input (a jump, a shift-lock spin or a tap), sometimes says hi,
   then takes a short first trip. With no `NpcPoi` tags NPCs wander, explore, pace, jump about, idle, go AFK and
   leave after sessions drawn around 15 minutes (minimum 1). They never appear in the player list, because they
   are not in `Players`.
4. In Run mode (no player) only `PopulationMin` (2) NPCs exist, for `EmptyServerGraceSeconds` (600 s), then
   none: `SpawnOnlyWithPlayers` is true by default.
5. The Bootstrap attribute `Debug = true` adds a `workspace.HumanlikeNpcDebug` folder with one billboard per NPC
   (activity, mood, phase, tier, locomotion status, recovery level), path polylines and, on request
   (`handle.adapters.debug:showGrid(true)`), the fallback grid heatmap.

Then tag your world (section 4): a few `NpcPoi` parts with `PoiKind`, one or more `NpcSpawn` parts, and `NpcAvoid`
volumes over water, lava and kill zones. The fallback grid covers the union of every tagged instance and every
`SpawnLocation`, inflated by 40 studs and clamped to 1200 x 1200 studs, so tagging is also what tells the system
how big your playable area is.

## 4. World vocabulary (tags and attributes)

Read by `World/Scan` and `Adapters/RobloxDiscovery`; a tag change is picked up within about a second.

| Tag | On | Attributes (default) | Meaning |
|---|---|---|---|
| `NpcPoi` | BasePart or Model | `PoiKind: string` (`hangout`; one of shop, hangout, viewpoint, objective, spawn), `PoiWeight: number` (1), `PoiRadius: number` (6), `PoiDwell: number?` (median seconds; per-kind defaults shop 8 / hangout 25 / viewpoint 12 / objective 6 / spawn 5), `NpcCapacity: number?` (unlimited), `PoiId: string?` (`<Name>#<n>`), `PoiWord: string?` (overrides the `{poi}` chat word) | A place NPCs go to and dwell at. The position is the floor point under the marker. While an NPC interacts, the marker's `PoiInteract` attribute is set to that NPC's username and cleared afterwards |
| `NpcSpawn` | BasePart | none | NPCs spawn on the top surface, inset 2 studs, snapped to the nearest walkable cell. Without one, every `SpawnLocation` acts as a spawn of its own size; failing that, the centre of the largest walkable region |
| `NpcNoSpawn` | BasePart | none | Never a spawn or respawn point inside it (NPCs may walk through) |
| `NpcAvoid` | BasePart | none | Never entered: grid cells blocked, a `PathfindingModifier` labelled `NoGo` (cost `math.huge`) is parented under the part, `CanCollide` untouched; an NPC pushed inside walks out |
| `NpcSlow` | BasePart | `NavCost: number` (4) | Costly to cross (mud, stairs): grid cost and a `PathfindingModifier` labelled `Slow` |
| `NpcProp` | BasePart | none | Something to stand on. With `AutoProps` (default true) collidable parts 2 to 7 studs high with a 3 to 12 stud footprint are found automatically |
| `NpcIgnore` | Model or BasePart | none | Excluded from grid sampling, props, seats and the client animator (for your own NPCs, vehicles and moving platforms) |
| `NpcSeat` | Seat, VehicleSeat or BasePart | none | Optional explicit seat marker; any `Seat`/`VehicleSeat` is used anyway and attached to the POI whose radius covers the point one stud in front of it |
| `NpcNavBounds` | BasePart | none | Optional: the one box the fallback grid covers, overriding the tagged-union rule |

The modifier labels are `NoGo` and `Slow` on purpose: `PathfindingModifier.Label` replicates to clients, and a
label naming the system would tell an observer which volumes exist for NPCs.

## 5. Configuration

Every key of `Config.DEFAULTS` (`src/server/Config.luau`), grouped as in the file. Any key can be overridden by
an attribute of the same name and type on the Bootstrap script. Seconds unless stated.

| Key | Default | Meaning |
|---|---|---|
| **Identity and determinism** | | |
| `Seed` | `"humanlike-npc"` | Server run seed (string or number). Api appends `os.time()` when `SeedPerRun` is true |
| `SeedPerRun` | `true` | New seed every server run; false makes a run reproducible given the same inputs |
| `DisclosureAck` | `false` | Set true once the game description discloses computer-controlled characters; silences the startup warning |
| **Population** | | |
| `PopulationBase` / `PopulationPerPlayer` | `6` / `0.5` | Target NPC count with players present: base plus the per-player term |
| `PopulationMin` / `PopulationMax` | `2` / `30` | NPCs that linger on an empty server during the grace; hard cap on the target (validated to be at most 100) |
| `SpawnOnlyWithPlayers` | `true` | Target 0 with no players, once the empty-server grace is over |
| `EmptyServerGraceSeconds` | `600` | How long `PopulationMin` NPCs stay after the last player leaves |
| `InitialBurst` | `2` | NPCs requested on the first population tick after the first player joins |
| `BurstGapMedian` / `BurstGapSpread` / `BurstGapMin` / `BurstGapMax` | `8` / `0.6` / `2` / `30` | Gap between the first burst's arrivals (clamped log-normal) |
| `JoinGapMedian` / `JoinGapSpread` / `JoinGapMin` / `JoinGapMax` | `25` / `0.8` / `5` / `120` | Gap between later arrivals |
| `PairChance` | `0.3` | Share of arrivals that bring a friend 5 to 20 s later from the same spawn area |
| `ShortenGapMedian` / `ShortenGapSpread` / `ShortenGapMin` / `ShortenGapMax` | `30` / `0.5` / `10` / `90` | Time until an over-target NPC leaves (sessions are shortened, nobody is kicked) |
| `SessionMedianMinutes` / `SessionSpread` / `SessionMinMinutes` / `SessionMaxMinutes` | `15` / `0.9` / `1` / `240` | Session length distribution, in minutes |
| `RejoinChance` | `0.15` | Chance a departed persona returns later with the same name, avatar and personality |
| `RejoinDelayMedian` / `RejoinDelaySpread` / `RejoinDelayMin` / `RejoinDelayMax` | `900` / `0.7` / `300` / `3600` | Delay before such a rejoin |
| `NameRetireSeconds` / `NameQuarantineSeconds` | `7200` / `600` | A username is not handed out again within the retire window; the rig pool adds a quarantine during which no other body may wear it |
| `HourCurve` / `LocalHourOffset` | `""` / `0` | Empty = flat; else 24 comma-separated multipliers on the target by hour of day; hours added to the UTC hour before the curve is read |
| `NameCheckOnline` | `true` | Reject generated usernames that resolve to real accounts (`Players:GetUserIdFromNameAsync`) |
| `ReservedNames` | `""` | `;`-separated usernames of the studio's own alt accounts, handed out first |
| **Movement** | | |
| `WalkSpeedMedian` / `WalkSpeedSpread` / `WalkSpeedMax` | `16` / `0` / `32` | Per-persona walk speed draw; spread 0 keeps everyone at the median |
| `AnalogViaWalkSpeed` | `true` | Analog (sub-unit) movement is expressed by a throttled `WalkSpeed` write rather than a sub-unit `Humanoid:Move` magnitude (section 14) |
| `AgentRadius` / `AgentHeight` / `WaypointSpacing` | `2` / `5` / `4` | Pathfinding agent size (engine paths and grid sampling) and engine waypoint spacing |
| `CanJump` / `CanClimb` | `true` / `false` | Agent abilities; `CanClimb = false` also disables the Climbing humanoid state |
| `DirectMax` | `24` | Longest beeline (studs, with line of sight) used when both planners fail |
| `KillYOffset` / `KillY` | `60` / `math.huge` | Kill plane = lowest world bound minus the offset; `KillY` overrides it when not `math.huge` |
| `MaxResetsPerSession` | `3` | Resets (recovery level 4) per session before the NPC leaves instead. Note: the landed runtime uses a module constant of 3 (`Runtime/Npc.luau`) and does not read this key yet |
| `DiedRespawnChance` | `0.7` | On `Humanoid.Died`, chance the same identity respawns after `Players.RespawnTime`; otherwise the NPC is gone |
| **Navigation and budgets** | | |
| `GridCellSize` / `GridMaxCells` | `2` / `40000` | Fallback grid cell size in studs, raised automatically until the grid fits the cell cap |
| `GridMaxNodes` / `GridYieldEvery` | `4000` / `64` | Cap on nodes expanded by one grid search (`Partial` beyond); nodes between yields of the sliced search |
| `GridMaxSideStuds` | `1200` | Above this tagged-world side the grid is disabled with one warning (engine paths still work) |
| `PathBudgetMs` / `PathBudgetMaxMs` | `1.5` / `4.0` | Milliseconds per frame for path work; scaled toward the max while the engine provider is backed off |
| `TickBudgetMs` / `FrameBudgetMs` | `2.5` / `4.0` | Stop taking due NPC ticks past the tick budget; exceeding the frame budget emits a rate-limited `frameOverBudget` event |
| `MaxTicksPerFrame` | `12` | Scheduler cap on NPC ticks per frame |
| `MaxInFlightRoblox` / `RobloxTimeout` | `2` / `1.5` | Concurrent `ComputeAsync` calls; time before an engine request counts as `Timeout` |
| `PathCooldown` / `PathCacheTtl` | `1.0` / `2` | Gap between path requests for one agent; how long a completed path stays reusable |
| `StarvationAfter` / `ProviderBackoffSeconds` / `ShedAbove` | `6` / `30` / `8` | Wait before a request falls through to a beeline; how long the engine provider is skipped after repeated failures; queue length above which far-tier requests are dropped while backed off |
| `RaycastsPerBrainTick` | `8` | Occlusion raycasts per brain tick. Note: the landed runtime passes a constant 8 (`Runtime/Npc.luau`) and does not read this key yet |
| `LosRaycastsPerPass` | `16` | Line-of-sight raycasts per LOD pass (round-robin, nearest player only) |
| `ResampleEverySeconds` | `300` | Periodic fallback-grid resample (also triggered when path failures exceed 5 in 60 s) |
| **Tiers** | | |
| `TierNear` / `TierMid` / `TierFar` | `60` / `200` / `500` | Flat distance to the nearest player below which an NPC is near / mid / far; beyond is dormant |
| `VisibleRange` / `DowngradeDelay` | `250` / `2` | Line of sight to a player within this range counts as near; delay before a demotion (promotion is immediate) |
| `RateNear` / `RateMid` / `RateFar` / `RateDormant` | `10` / `5` / `2` / `0.5` | Tick rates in Hz per tier |
| `BrainDivisorNear` / `BrainDivisorMid` / `BrainDivisorFar` / `BrainDivisorDormant` | `2` / `2` / `2` / `1` | The brain runs every n-th tick |
| **Chat** | | |
| `ChatEnabled` | `true` | Kill switch; `handle.setChatEnabled(false)` flips it live |
| `ChatHook` | `"own"` | `"own"`: the built-in display path; `"shared"`: your chat system (section 7) |
| `ChatNpcMinGap` / `ChatNpcPerMinute` / `ChatNpcPer10Min` | `4` / `4` / `12` | Gap between two lines of one NPC; per-NPC caps |
| `ChatServerPerMinute` / `ChatServerShare` | `8` / `0.4` | Server-wide NPC line cap; NPC share of recent lines when players are talking |
| `ChatQuietAfterSilence` / `ChatReplyBoost` | `600` / `2` | After this long without a player line NPCs talk at a quarter of the server cap; extra per-minute allowance for replies (never bypasses the server cap) |
| `ChatExtraPatterns` | `""` | `;`-separated Lua patterns added to the safety blocklist; invalid ones are dropped with a warning |
| `FilterNpcChat` / `FilterUserId` | `false` / `0` | Run NPC lines through `TextService:FilterStringAsync` with this author UserId: a studio-owned alt account, never a player; with filtering on and id 0 every line is dropped (section 7) |
| `ShowTypingIndicator` | `false` | Show a typing bubble over NPCs (off because default chat shows none for players) |
| `ChatAuditCapacity` | `500` | Entries kept in the in-memory chat audit ring |
| **Presentation** | | |
| `HeadLook` | `"off"` | `"off"` or `"shared"` (one identical head-look routine for every character, players included). There is no NPC-only mode |
| **Avatars and rigs** | | |
| `UsePrimitiveRigs` | `false` | Debug flag: force block rigs instead of engine-built avatars |
| `RigPoolSize` | `2` | Spare bodies built ahead of demand |
| `R6Share` | `0.05` | Share of personas on an R6 rig |
| `AutoProps` | `true` | Detect standable props without tags |
| **Mimic and evaluation** | | |
| `MimicEnabled` | `true` | Learn identity-free motion statistics from present players and shape NPC rhythm toward them (section 11) |
| `MimicK` / `MimicJitter` | `200` / `0.05` | Learning weight `n / (n + MimicK)` after n player samples; random spread applied to mimicked values |
| `TraceEnabled` | `false` | Record the motion trace `handle.tellScore()` scores |
| `TraceHz` / `TraceMaxSamples` | `10` / `200000` | Trace sample rate and ring size |
| **Errors and debug** | | |
| `ErrorsPerNpc` / `ErrorWindow` | `5` / `10` | An NPC whose tick throws this many times inside the window leaves like a crashed client |
| `Debug` | `false` | The Studio overlay (section 3) |
| `LogLevel` | `"warn"` | `"off"`, `"warn"` or `"info"` for event output |
| `StreamingHint` | `true` | Warn once when `StreamingEnabled` is on and `StreamingTargetRadius < 1024` |

### Adding chat lines

The built-in corpus (`Chat/ChatCorpus.luau`) holds 1179 lines in 19 categories: greeting, reaction, question,
social, nonsense, leaving, complaint, compliment, thanks, agree, disagree, bored, help, probe, followed, blocked,
tagged, echo and game. The `game` category ships empty; it is yours. Add lines through a ModuleScript named
`ChatExtra` parented to the Bootstrap script:

```luau
return {
	game = { "anyone done the parkour yet", "the shop is open again" },
	greeting = { { text = "yo", tags = { "kid", "mobile" } } },
}
```

`Api.start` passes each category through `ChatCorpus.extend`. A line is dropped with a warning when
`ChatCorpus.isSafeLine` rejects it: longer than 60 characters, newlines, links, platform names, trading,
begging, money, friend requests, age or location content. Tags in use: `reply`, `needsName` (`{name}` slot),
`rude`, `mobile`, `probe`, `multi`, `kid` / `teen` / `older`, `right`, `poi` (`{poi}` slot) and `help.vague` /
`help.wrong` / `help.right`.

## 6. The Handle API

`src/server/Api.luau` is the facade the Bootstrap calls. Its surface is pinned by the design spec (section 2.37):

```luau
Api.start(o: { root: Instance?, config: Config.Resolved?, debug: boolean? }?): Handle

export type Adapters = {
	clock: Ports.Clock,
	mover: (id: string) -> Ports.Mover?,
	path: Ports.PathProvider,
	perception: RobloxPerception.Perception,
	presenter: Ports.Presenter,
	rig: RobloxRig.Rig,
	discovery: RobloxDiscovery.Discovered,
	telemetry: RobloxTelemetry.Telemetry,
	debug: RobloxDebug.Debug?,
	connections: Connections.Bag,
}

export type Handle = {
	service: NpcService.Service,
	config: Config.Resolved,
	adapters: Adapters,
	stop: () -> (),
	spawn: (at: Vector3?) -> string,
	despawn: (id: string, reason: string?) -> (),
	list: () -> { string },
	stats: () -> any,
	setChatEnabled: (on: boolean) -> (),
	tellScore: () -> any?,
	onEvent: (fn: (e: Types.NpcEvent) -> ()) -> () -> (),
	isNpc: (model: Instance) -> boolean,
	emitEvent: (name: string, position: Vector3, magnitude: number) -> (),
	rescan: () -> (),
	registerPoi: (instance: Instance) -> (),
	onPlayerChat: (player: Player, text: string) -> (),
}
```

| Member | What it does |
|---|---|
| `Api.start(o)` | Resolves the config (`Config.resolve(script)` when none is given), warns once when `DisclosureAck` is false, creates `ReplicatedStorage.HumanlikeNpcRemotes`, copies the client-visible keys onto `HumanlikeNpcShared`, runs discovery, builds the adapters, drives `service:stepFrame` from `RunService.Heartbeat`, owns the spawn thread that builds bodies off-frame, and forwards `Path.Blocked`, `Humanoid.Died` and respawned bodies to the service |
| `stop()` | Yields (`task.wait`) until `service:count() == 0` or 8 s have passed (every NPC leaves like a disconnect), then destroys pooled rigs, the remotes folder and the debug folder and disconnects every connection the system made |
| `spawn(at?)` | One extra NPC at `at` (else a regular spawn point); returns its id (`"npc<N>"`) |
| `despawn(id, reason?)` | Removes that NPC through the normal leave story |
| `list()` | Ids of the NPCs present |
| `stats()` | `{ spawned, despawned, linesSaid, linesDropped, errors, pressure, frame, respawns, avoidExits }`; `frame` is the last `FrameStats` (`ticks`, `brains`, `pathMs`, `tickMs`, `spent`, `pressure`, `npcCount`, `dropped`, `wantSpawn`, ...) |
| `setChatEnabled(on)` | Kill switch; `false` drops every line at once, including ones whose typing delay is running |
| `tellScore()` | `Eval/TellScore.score` over the live trace (needs `TraceEnabled = true`), else nil |
| `onEvent(fn)` | Subscribes to every `NpcEvent` (`{ kind, npcId, at, data? }`); returns a disconnect function. Kinds: `spawn`, `despawn`, `line`, `error`, `reset`, `died`, `frameOverBudget`, `gameEvent`. `spawn` data: `model`, `username`, `displayName`, `accountAgeDays`, `familiarity`, `walkSpeed`, `seed`; `despawn` data as landed in `NpcService`: `username`, `displayName`, `reason`; `line`: `text`, `lineId`, `target`; `died`: `respawn`; `gameEvent`: `name`, `magnitude` |
| `isNpc(model)` | Server-only truth. NPC models carry no tag, attribute or name pattern; this is the only way to know |
| `emitEvent(name, position, magnitude)` | A game event NPCs may react to (a boss spawn, a round start); delivered to near- and mid-tier NPCs within 100 studs |
| `rescan()` | Discovery refresh: POIs, seats, avoids, slow and no-spawn volumes; not the grid |
| `registerPoi(instance)` | Registers one POI without a tag; attributes are read as usual |
| `onPlayerChat(player, text)` | For `ChatHook = "shared"`: your chat handler feeds player lines here (the handle adds the `p:<UserId>` id, position and time) |
| `service`, `config`, `adapters` | The running `NpcService`, the resolved config, and the adapter objects (`adapters.connections:count()` is the leak gauge; `service:chatLog(limit?)` is the audit ring) |

### Snippets

Configure from attributes, no code (command bar, once, in edit mode):

```luau
local s = game.ServerScriptService.HumanlikeNpcBootstrap
s:SetAttribute("PopulationBase", 10); s:SetAttribute("PopulationPerPlayer", 1)
s:SetAttribute("ChatHook", "own"); s:SetAttribute("DisclosureAck", true); s:SetAttribute("Debug", true)
```

Tag a point of interest, a no-go volume and a spawn pad:

```luau
local CollectionService = game:GetService("CollectionService")
local part = workspace.Shop.Counter
CollectionService:AddTag(part, "NpcPoi")
part:SetAttribute("PoiKind", "shop"); part:SetAttribute("PoiWeight", 2)
part:SetAttribute("PoiRadius", 8); part:SetAttribute("PoiDwell", 10)
CollectionService:AddTag(workspace.Lava, "NpcAvoid")
CollectionService:AddTag(workspace.SpawnPad, "NpcSpawn")
```

Drive it from your own server Script instead of the Bootstrap (disable the Bootstrap script first):

```luau
local Api = require(game.ServerStorage.HumanlikeNpc.Api)
local Config = require(game.ServerStorage.HumanlikeNpc.Config)
local cfg = Config.resolve(nil); cfg.PopulationBase = 4; cfg.SpawnOnlyWithPlayers = false
local handle = Api.start({ config = cfg })
local id = handle.spawn(Vector3.new(0, 5, 0)) -- one extra NPC right here
print(handle.stats().frame.tickMs)
handle.setChatEnabled(false) -- kill switch
game:BindToClose(handle.stop)
```

Integrate with your own game logic (leaderboards, minimaps, join messages, pets, rewards). In pet or progression
games this wiring is the single strongest tell when skipped:

```luau
handle.onEvent(function(e)
	if e.kind == "spawn" then
		myLeaderboard:addRow(e.data.username, e.data.displayName, e.data.accountAgeDays)
		myJoinMessages:show(e.data.displayName .. " joined")
		myPets:giveStarterPet(e.data.model, e.data.seed) -- an entourage that fits the account age
	elseif e.kind == "despawn" then
		myLeaderboard:removeRow(e.data.username)
	end
end)
-- when something happens NPCs should react to (a boss spawn, a round start):
handle.emitEvent("roundStart", arenaCenter.Position, 1)
-- before rewarding a "player": the server-only truth (there is no client-visible marker)
if not handle.isNpc(character) then
	giveCoins(player)
end
```

Read the tell score of a live server: set `TraceEnabled = true`, then `handle.tellScore()`. Under Lune,
`lune run tools/lune/Harness <trace.json>` scores a saved trace (section 12).

Two Studio settings worth knowing: places with `Workspace.StreamingEnabled` should set `StreamingTargetRadius`
to 1024 or more (NPC models stream as `Atomic`, exactly like player characters; below that radius characters
near the edge pop for the client the way players do, and `StreamingHint` warns once). The system does not depend
on `Workspace.PlayerCharacterDestroyBehavior`: its per-character connections live in bags emptied on
`CharacterRemoving`, `CharacterAdded` and `PlayerRemoving`.

## 7. Chat integration

### Own hook (`ChatHook = "own"`, default)

- Speaking: the server fires the `CharacterChat` RemoteEvent to every client with
  `(displayName, text, NameColor.of(username), characterModel, "HNPC")`. The name colour is the classic
  eight-colour chat hash keyed on the username, so an NPC and a player with the same name get the same colour.
- Display (`NpcChatDisplay`, section 8): the client captures a prefix template from the first real player message
  seen on `TextChatService.MessageReceived` (display name replaced by `%s`, colour hex by `%c`; default
  `<font color='#%c'>%s:</font>` until then), shows the line through
  `TextChatService.TextChannels.RBXGeneral:DisplaySystemMessage(prefix .. " " .. text, "HNPC")` and, when bubble
  chat is enabled, through `TextChatService:DisplayBubble(character, text)`. Only messages whose `Metadata` is
  `"HNPC"` are touched. A streamed-out or missing character still gets its window line and simply no bubble.
  Late joiners get no history, because real players see none either.
- Hearing: `Player.Chatted` is connected per player (in that player's connection bag) and, when your game has
  not set one, `RBXGeneral.ShouldDeliverCallback` is assigned with a function that returns true, never yields and
  records each message once. The two paths are deduplicated. If no line ever arrives, hearing is silently off
  and NPCs still talk spontaneously.

### Shared hook (`ChatHook = "shared"`)

Your chat system owns display and hearing. Provide a BindableFunction
`ReplicatedStorage.HumanlikeNpcRemotes.SharedChatSay(displayName, text, character)` that shows an NPC line the
way you show a player's; when it is missing the sink warns once and behaves as `"own"`. Feed player lines with
`handle.onPlayerChat(player, text)`. In this mode `NpcChatDisplay` skips the window line and only shows bubbles.

### Reply behaviour, briefly

Lines heard beyond 100 studs are never heard; beyond 40 studs only lines naming the NPC count. Replies are
probabilistic by kind (greeting, named, question, offer, compliment, "are you a bot", broadcast) scaled by
chattiness, mood and annoyance, and they arrive after a reaction delay plus a typing time; the body freezes while
"typing" on keyboard profiles. After two unanswered direct lines an NPC stops initiating with that player. A stop
keyword aimed at an NPC blocks the speaker: no more replies, no following, avoidance. "Are you a bot" is
answered at most once per speaker from the `probe` category (deflection, joke, indignation or silence; never a
confession and never a scripted denial), and repeated probing raises annoyance until the NPC walks off.

### Safety and rate rules

- `Chat/Safety.check` gates every rendered line: at most 120 characters, a fixed character set, a blocklist and
  `ChatExtraPatterns`. A line that fails is dropped, not retried, and counted in `stats().linesDropped`. Every line
  said is recorded in an in-memory ring of `ChatAuditCapacity` (500) entries `{ npcId, lineId, text, at, target }`
  readable through `handle.service:chatLog(limit?)`.
- `Chat/ChatGuard` enforces, all at once: 4 s between lines of one NPC, 4 per NPC per minute, 12 per NPC per 10
  minutes, 8 server-wide per minute, at most a 0.4 share of recent lines when players are talking, a quarter rate
  after 600 s without a player line, and a +2 per minute allowance for replies that never bypasses the server cap.
- Text filtering is off by default (`FilterNpcChat = false`). NPC lines are developer-authored corpus text, not
  user-generated content, and `DisplaySystemMessage` does not filter them, so `Safety.check` and `isSafeLine`
  are the gate. `TextService:FilterStringAsync(text, fromUserId)` treats `fromUserId` as the author for
  moderation, so a bystander's UserId is never used: if you enable filtering you must set `FilterUserId` to a
  studio-owned alt account id, and with `FilterNpcChat = true` and `FilterUserId = 0` every line is dropped with
  one warning.

### What the server never does

It never sends NPC chat through `TextChannel:SendAsync`, never uses a player as the speaker or as the filter
author, never sets `TextSource`, never puts NPC characters into `Players`, never assigns
`TextChatService.OnIncomingMessage`, and never names a remote or attribute with "npc" where a client can see it,
except the developer-facing `HumanlikeNpcRemotes` folder name, which marks no character.

## 8. Client scripts

All four live in `StarterPlayerScripts`, read `ClientConfig` once at start, and idle when the server side is not
running.

- `NpcChatDisplay`: renders `CharacterChat` lines into the chat window and bubbles as described in section 7.
  It never assigns `OnIncomingMessage`, never sends through `SendAsync`, never fakes a `TextSource`, touches no
  message without the `"HNPC"` metadata, and shows a typing indicator only when `ShowTypingIndicator` is on.
- `NpcAnimator`: animates every character in the workspace that has a `Humanoid`, carries no `Animate` script and
  is not tagged `NpcIgnore`. It re-implements the R15 `Animate` script's rules (idle variants re-rolled 1/1/9 at
  the clip end, walk/run cross-fade, jump then fall, climb, sit, the seven default emotes) with `AnimLogic`
  choosing the state from the polled root velocity, and derives the animation pack from the model name
  (`AnimSets.packFor`), so no replicated marker is needed. It attaches on `workspace.DescendantAdded`, releases a
  character that gains an `Animate` script, gets the tag or leaves the workspace, tolerates missing parts while
  streaming, never scans the workspace per frame, never touches a player's character (every player's has an
  `Animate` script) and never reads `Players` to decide.
- `NpcHeadLook`: inert unless `HeadLook == "shared"`. Then every character with a `Humanoid` (players included,
  this client's own excluded) gets one identical routine: the neck joint's `Transform` (an `AnimationConstraint`
  or a `Motor6D`; `C0`/`C1` are never written) is rotated toward the `CamYaw`/`CamPitch` attributes the server
  keeps on every character, lerped by `HeadLookLerp` (0.12) and clamped to `HeadLookMaxDegrees` (55), in
  `PreSimulation`, skipping throttled frames. The client also publishes its own camera yaw and pitch at 5 Hz on
  the `CharacterCam` UnreliableRemoteEvent. A place with its own head-look keeps `"off"`.
- `NpcPresentation`: applies `HidePlayerList` (the only place `StarterGui:SetCoreGuiEnabled` is legal) and
  nothing else. By default it touches nothing: NPCs are not in `Players`, so the player list never shows them.

## 9. How it stays human

A compact version of the design catalogue (spec section 5). Every draw comes from a seeded `Rng` stream and every
rate below is modulated by the persona's 14 traits (sociability, curiosity, patience, jumpiness, chattiness, AFK
proneness, trolliness, skill, impulsivity, friendliness, helpfulness, mirroring, attention, emote habit) and its
derived account age and familiarity.

- Arrival and identity: a spawn ritual (stand still 1 to 6 s, a first input, maybe "hi", a short first trip);
  clustered arrivals with 30 percent pairs; session lengths around 15 minutes with a long tail; 15 percent
  rejoins; a leave that looks like a disconnect (stand, sometimes a `leaving` line, model gone in one frame);
  ten username families, display names that differ from usernames 80 percent of the time, avatar styles and
  animation packs biased by account age and trolliness, 5 percent R6.
- Input profiles: pc 30 / pcShiftLock 10 / mobile 55 / console 5 percent. Analog stick wobble and magnitude
  dips on mobile and console; 8-way keyboard quantisation with camera lag on pc; micro-stops mid-walk; corner
  clipping; overshoot and a correction tap at the end of a trip; hesitations, distractions, about-faces and wall
  bumps; jump timing spread over gaps; habitual jumping in bursts; jump mirroring.
- Idling: only shift-lock personas (about 10 percent) ever turn in place while idle (yaw sweeps, jump-turns);
  everyone else stands perfectly still, like a real third-person player. Pacing, standing on props, returning to
  spawn, AFK (full and semi; 20 to 40 percent of a real server is AFK at any moment) with an abrupt wake.
- Perception and reaction: reaction latencies drawn from a shifted distribution with misses; being followed
  (turn, face, sidestep, say something, ignore; escalation after three episodes), stared at, jumped on, bumped;
  camera glances at things seen while walking (keyboard profiles); a reading pause when chat arrives; stepping
  away from a stranger standing too close, friends allowed closer.
- Social: joining groups and standing on the ring, watching, face-offs, POI visits with dwell, hover and small
  interaction loops (read, prompt, watch, inventory, sit on a seat), exploring unvisited sectors, wandering
  nowhere in particular, random changes of mind mid-trip (once per trip, never in the first 3 s or last 8 studs).
- Chat: typing freeze before a line, typos, stretched words, caps, truncation, dialect tags, `@`-less name tags;
  the reply and rate rules of section 7; echo fragments only of corpus lines heard from other NPCs.
- Crowds and failures: pushing through crowds with occasional dodges and bumps; a stuck ladder that pauses,
  sidesteps, backs up, jumps, gives up and finally resets, with penalised re-paths; two planners plus stand-in
  goals and short beelines so nobody freezes when the engine finds no path; walking off an edge now and then
  (at most 3 per session), handling falls and flings, dying and respawning with probability 0.7, else leaving.
- Familiarity: newcomers explore more, wander aimlessly, hesitate and give vague or wrong directions; veterans
  go straight and may point the right way.
- Mimic: with players present, NPC speed ratios and stop/go rhythm are nudged toward the local crowd's
  (weight `n / (n + 200)`, 5 percent jitter) and short movement fragments are replayed while idle-wandering.
- Containment: a tick that throws gets the body a stop command; five errors in ten seconds and the NPC leaves
  like a crash. A body is never reused under a new name.

### Tiers

| Tier | Distance to nearest player (flat) | Tick | Brain | What is skipped |
|---|---|---|---|---|
| near | under 60 studs, or line of sight within 250 | 10 Hz | 5 Hz | nothing |
| mid | under 200 | 5 Hz | 2.5 Hz | senses raycasts (occlusion assumed false), mimic shaping |
| far | under 500 | 2 Hz | 1 Hz | humanizer noise, steering, overlays (talk, mirror, emote, fidget), non-system reactions; motion is `MoveTo` |
| dormant | else | 0.5 Hz | 0.5 Hz | as far; the brain only visits POIs, wanders, explores, idles or leaves; path requests are shed first |

Demotion has a 1.25 hysteresis plus a 2 s delay; promotion is immediate. With no players on the server every NPC
is near (distance 0).

### Deliberately not done

- No head-look for NPCs only. Default Roblox players' heads do not follow their camera, so an NPC-only tracker
  is a tell; `HeadLook = "shared"` treats every character identically and `"off"` is the default.
- No teleports. The only `PivotTo` writes are the placement of a freshly built body at spawn or respawn, before
  it is parented. A live body is never moved by script; facing while standing goes through one
  `AlignOrientation`, never a `CFrame` write. A reset is a destroy plus a fresh body, like a real reset.
- No ghost-walking or freezing far away. A far or dormant NPC keeps a real trip: `MoveTo` toward a point at most
  16 studs ahead, re-issued when it finishes or every 6 s. Nothing is anchored, and when a player approaches the
  NPC is mid-walk, mid-dwell or mid-idle exactly where its trip says.
- No fades, no death animations on leaving, no NPCs in `Players`, no player-list changes by default, no
  replicated marker of any kind on an NPC model.

## 10. Performance and budgets

| Budget | Default | Where enforced |
|---|---|---|
| `FrameBudgetMs` | 4.0 | `NpcService.stepFrame` total; over it, a `frameOverBudget` event at most once per 10 s |
| `TickBudgetMs` | 2.5 | Stop taking due NPCs when exceeded; the rest stay due |
| `PathBudgetMs` | 1.5 (up to `PathBudgetMaxMs` 4.0 while the engine provider is backed off) | Sliced grid search (`GridYieldEvery` 64), one active search |
| `MaxTicksPerFrame` | 12 | Scheduler cap |
| `GridMaxNodes` | 4000 (per request `clamp((d / cellSize)^2 * 4, 400, 4000)`) | Grid provider; `Partial` beyond |
| `RaycastsPerBrainTick` | 8 | Senses occlusion budget |
| `LosRaycastsPerPass` | 16 | LOD pass, round-robin |
| `MaxInFlightRoblox` | 2 | Engine path provider |
| `ShedAbove` | 8 queued | Far-tier requests dropped while backed off |
| `PopulationMax` | 30 | Population model |
| `ChatServerPerMinute` | 8 | ChatGuard |

Pressure `p` in [0, 1]: each frame `p += 0.05` when the tick budget was exceeded, else `p -= 0.01`. Effects: tier
distances shrink by `1 / (1 - 0.5 p)`, the population target is scaled by `(1 - 0.5 p)` (fewer joins under load;
nobody is kicked), and the humanizer's per-tick noise is skipped for the mid tier when `p > 0.5`. `p` is reported
as `stats().pressure` and shown in the debug overlay.

### Measured baseline (`lune run tools/lune/Bench`)

Measured on 2026-09-30 with Lune 0.10.3 on a 4-core Intel Xeon at 2.80 GHz (the container this tree was written
in). `Bench.luau` asserts nothing and is not part of `tests/run`. These are Lune numbers, not Studio numbers:
Lune's `Vector3` and `CFrame` are userdata bridged from Rust and its interpreter is not Studio's, so treat them as
a regression baseline, not as expected server frame costs.

| Benchmark | Count | Total | Per unit |
|---|---|---|---|
| `NavGrid.findPath` spawn to viewpoint on the arena grid (typical, jumps on; 115 nodes expanded, 4 waypoints) | 50 searches | 381 ms | 7.6 ms per search |
| `NavGrid.findPath` unreachable goal behind a wall (exhaustive, 20000-node cap; 2715 nodes expanded per search) | 10 searches | 922 ms | 92 ms per search, 34 us per expanded node |
| `FakeWorld`: 8 NPCs for 600 simulated seconds at 30 Hz, per frame | 18000 frames | 14.4 s | 803 us per frame |
| per NPC tick (all ticks) | 39164 ticks | 10.9 s | 278 us per tick |
| per brain tick (ticks that ran the brain) | 19582 ticks | 9.5 s | 486 us per tick |
| per frame outside NPC ticks (spatial index, planner, fake bodies) | 18000 frames | 3.5 s | 197 us per frame |
| `Senses.step` with 20 entities | 2000 steps | 384 ms | 192 us per step |
| `Composer.compose` | 10000 lines | 2.66 s | 266 us per line |

Five of the eight NPCs were still present at the end of the 600 s run (the others had left). The design targets
for a Studio server are lower (brain tick at most 250 us median, senses at most 120 us); whether Studio meets
them is checklist item C-11 and has not been measured. The `MimicEnabled = false` comparison run the design
places in `Bench.luau` is not in the landed benchmark yet.

## 11. Privacy and data

- Nothing is persisted and nothing leaves the server: the tree uses no `DataStoreService`, `HttpService`,
  `MessagingService` or `TeleportService`, and `TextService` is reached only when you enable `FilterNpcChat`.
- The mimic learner (`MimicEnabled`, default true) is identity-free and in-memory. `Mimic/MotionStats` keeps
  reservoirs of speed ratios, stop and go durations and turn rates for the players present;
  `Mimic/TraceBank` keeps a few seconds of unit directions, magnitudes, jump flags and step durations relative to
  a fragment's own first heading. Never positions, names, UserIds or text; the per-session key that keeps
  concurrent players' samples apart is a random integer, and a player's open recording is dropped when they leave.
  `MimicEnabled = false` turns all of it off; the design requires the tell score to stay at zero without it.
- Player chat is heard only to classify a possible reply. Heard lines stay in a 3-second earshot memory and are
  never stored, never echoed (`{echo}` is filled only from corpus lines heard from other NPCs) and never sent to a
  filter under a player's UserId.
- The chat audit log (`handle.service:chatLog(limit?)`) is an in-memory ring of at most `ChatAuditCapacity`
  entries of what NPCs said (`npcId`, `lineId`, `text`, `at`, `target`); it holds no player text.
- `FilterNpcChat` is off by default; when on, the author id is `FilterUserId`, a studio alt account, never a
  player (section 7).
- NPC identities carry a fake `userIdLike` number for developer code that keys characters by a numeric id; it is
  never shown to clients and never passed to a Roblox API that takes a UserId.

## 12. Running the checks and tests

Tool versions used: Lune 0.10.3, StyLua 2.1.0, luau-lsp 1.51.0, Rojo 7.5.1. On this machine they live in
`/root/.local/bin`.

```sh
cd humanlike-npc
export PATH=/root/.local/bin:$PATH
bash tools/lune/check.sh        # stylua --check, rojo sourcemap + luau-lsp analyze (strict, Roblox platform,
                                #   tools/globalTypes.d.luau), DepGraph (cycles fail), the suite under its budget
lune run tests/run              # the suite alone; prints per-suite wall times and the total
lune run tools/lune/DepGraph    # the require graph of src/server and src/shared (--strict fails on header drift)
lune run tools/lune/Bench       # the baseline of section 10 (a minute or two)
lune run tools/lune/Harness <trace.json> [--budget <score>] [--json]   # score a saved trace
lune run tools/lune/ExportScene <arena|gauntlet|plaza> [out.rbxmx]     # a Lune world as a model file for Studio
```

`tests/run.luau` registers 38 suites, in this order: Rng, Timing, NavGrid, Names, ChatCorpus, ChatStyle,
WaypointFollower, NavRuntime, Human, Humanizer, Planner, Locomotion, Mind, MindCore, Persona, Brain, Overlays,
Senses, Scan, Config, Population, Scheduler, Lod, ErrorBudget, ChatGuard, Composer, TypingFreeze, Avatars,
PrimitiveRig, Mimic, Safety, Shared, Npc, NpcService, TellScore, Leak, LoadAll, Integration. The whole run must
finish within 180 s of wall time; `check.sh` fails above that. The slowest suites are `Integration` (eight
fake-world scenarios: a crowd in the arena, a follower, the gauntlet, the engine pathfinder present and timing
out, chat probes, the population model, the far tier), `Leak` (200 NPCs through one world, nothing left behind)
and `TellScore` (every tell fires on its synthetic trace). `LoadAll` is the ring gate: every module outside
`Adapters/` and `Api` must load under Lune, be free of require cycles and contain no forbidden token (`task.`,
`Random.new`, `os.clock`, `:Connect(`, `ComputeAsync`, `:MoveTo(`, `:Move(`, `SetNetworkOwner`, `:PivotTo(`,
`:GetPivot(`, `GetTagged(`, `:SetStateEnabled(`, and free calls of `tick`, `wait`, `spawn`, `delay`).

Adding a suite: a spec file is `return function(T, Loader) ... end` under `tests/`; append its `require` to the
list in `tests/run.luau`. Modules load through `tools/lune/Loader`, which mounts `default.project.json` as a Lune
DataModel so `require(script.Parent.X)` resolves exactly as in Studio.

## 13. Studio checklist

Manual, from spec section 12.4. Nothing in this tree has run in Studio yet, so every row is unverified; the
column is here to be filled in.

| Item | Check | Verified in Studio |
|---|---|---|
| C-1 | Analog speed: with `AnalogViaWalkSpeed = false` an NPC on a mobile profile visibly varies speed; if not, keep the default `true` | **not yet verified** |
| C-2 | Hearing: say "hi" near a chatty NPC; a reply arrives within 10 s at least once in three tries; record whether `Player.Chatted` alone or the `ShouldDeliverCallback` path delivered it | **not yet verified** |
| C-3 | Chat parity: bubbles over NPC heads and window lines with the captured player-style prefix; record whether the default UI shows any "System" marker on a `DisplaySystemMessage` line; compare a real message's captured hex against `NameColor.of(player.Name)` and `NameColor.of(player.DisplayName)` and record which matches | **not yet verified** |
| C-4 | Avatars: with an empty catalog NPCs load as proper default R15 avatars, never block rigs; with `AvatarCatalog` ids filled they load with clothes; a bad id falls back to the default avatar | **not yet verified** |
| C-5 | Emote mirroring: use the emote wheel next to an NPC with high mirroring (the debug overlay shows traits) | **not yet verified** |
| C-6 | Streaming: `StreamingEnabled` with `StreamingTargetRadius 1024`; walk 600 studs away and back; NPCs stream in and out like players, mid-activity, never frozen | **not yet verified** |
| C-7 | Facing: NPCs turn smoothly to face speakers through `AlignOrientation`; no jitter | **not yet verified** |
| C-8 | Emotes: the default emote ids play; otherwise the pose fallback plays | **not yet verified** |
| C-9 | No-go: an `NpcAvoid` lava pool is never entered in 10 minutes with 10 NPCs; an NPC pushed in walks out | **not yet verified** |
| C-10 | Leave: a leaving NPC vanishes like a disconnect; the name never reappears on another body | **not yet verified** |
| C-11 | Budget: `handle.stats().frame.tickMs` under 4 ms with 30 NPCs on a plaza-like map (overlay pressure 0); every NPC root reports `GetNetworkOwner() == nil` | **not yet verified** |
| C-12 | Leaks: `handle.adapters.connections:count()` returns to its post-start baseline after 50 join/leave cycles with two test clients | **not yet verified** |
| C-13 | Names: with `NameCheckOnline` on, Output shows rejected names that resolve to real accounts; no NPC carries a real account's username | **not yet verified** |
| C-14 | Physics: kill an NPC (reset via the overlay); it respawns at a `SpawnLocation` after `RespawnTime` with the same name in about 70 percent of tries, otherwise leaves; an NPC can be seen walking off a ledge within 20 minutes with 10 NPCs | **not yet verified** |
| C-15 | Head look: with `HeadLook = "shared"` your own character's head and an NPC's head follow their camera attributes identically; with `"off"` nothing moves | **not yet verified** |

`lune run tools/lune/ExportScene arena` (or `gauntlet`, `plaza`) writes `build/<Name>.rbxmx`, the exact geometry
the Lune suite runs against, for inserting into a test place with "Insert from file".

## 14. Known limitations and risks

### Graceful degradation (APIs the research marked unverified)

| API | Use | If absent or failing | Checklist |
|---|---|---|---|
| `Humanoid:Move(dir * m)` with a sub-unit magnitude on server-owned humanoids | analog speed | `AnalogViaWalkSpeed = true` (default): walk speed is scaled instead | C-1 |
| `Player.Chatted` / `RBXGeneral.ShouldDeliverCallback` on the server | hearing players | `Chatted` alone; an existing callback is never overwritten; if no line ever arrives, hearing is off (spontaneous chat unaffected) | C-2 |
| `TextChatService.MessageReceived` on the client for prefix capture | chat window parity | the default template `<font color='#RRGGBB'>DisplayName:</font>` until a real message is seen | C-3 |
| `RBXGeneral:DisplaySystemMessage` on the client | window line | window line skipped, bubble still shown, one warning | C-3 |
| `TextChatService:DisplayBubble` on the client | chat bubbles | no bubble (there is no legacy `Chat:Chat` path any more) | C-3 |
| `Players:CreateHumanoidModelFromDescriptionAsync` with an id-less description | default avatars | `PrimitiveRig` block bodies (only then) | C-4, C-14 |
| the same call with catalog ids | dressed avatars | retry with all ids 0 (default avatar); that id set is blacklisted for the run | C-4 |
| `Animator.AnimationPlayed` for emote detection | mirroring emotes | emotes are not seen (mirroring of emotes off) | C-5 |
| `ModelStreamingMode = Atomic` | streaming | leave the default; `StreamingTargetRadius >= 1024` recommended | C-6 |
| `AlignOrientation` facing (`OneAttachment`) | smooth turns | facing skipped (the body keeps `AutoRotate`); never a per-tick `CFrame` write | C-7 |
| emote asset ids in `AnimSets` | emotes | `wave` and `point` through a pose fallback in the client animator; dances skipped | C-8 |
| `Players:GetUserIdFromNameAsync` | impersonation check | the pool works unchecked after two consecutive errors, one warning | C-13 |
| `AnimationConstraint` / `Motor6D.Transform` on the client | shared head look | head look off (`"off"` is the default anyway) | C-15 |
| `root:CanSetNetworkOwnership()` false after 30 frames | server ownership | the body is released with a warning and a new one is built | C-11 |

### Residual risks

- Exploit clients can enumerate NPCs: `CharacterChat` fires only for NPC lines, and
  `Players:GetPlayerFromCharacter(model) == nil` is testable. The guarantee is that an ordinary player cannot
  tell and that the system adds no additional marker (no tag, attribute, name pattern, folder or replicated
  instance that singles out an NPC). Likewise the client animator conditions on "Humanoid, no `Animate` script,
  not `NpcIgnore`", so a client-side script could detect the missing `Animate`; server-played animations were
  rejected because they are visibly late.
- Whether the default chat UI marks `DisplaySystemMessage` lines as system messages is not assumed; C-3 decides.
  A place with a custom chat UI needs the shared hook. The mobile typing indicator and voice chat have no parity
  story.
- The R15 default animation ids in `AnimSets` come from the engine's `Animate` script; the R6 ids were written
  from memory and are unverified (C-8).
- Large maps: beyond a 1200 x 1200 stud tagged world the fallback grid is off and the ladder is engine path,
  then beeline, then no path; on huge tagged worlds cells coarsen to 4 to 6 studs. Under engine load, NPCs far
  from players may wait up to 6 s for a path or be shed to a short beeline or idle (invisible at far tier).
- Studio runs are not bit-reproducible by design (`SeedPerRun`); budgets change only how many NPCs tick per
  frame, never decisions. `FilterNpcChat` without an alt account drops every line, by design. The mimic learner
  is on by default; a developer has to read this file to know it (section 11).
- Two config keys are not read by the landed runtime yet (`MaxResetsPerSession`, `RaycastsPerBrainTick`); the
  values are module constants equal to the defaults.

## 15. Repository layout

```
default.project.json         Rojo tree (section 2)
stylua.toml                  120 columns, tabs, indent 4, double quotes, call parentheses always
src/server/                  ServerStorage.HumanlikeNpc: 70 ModuleScripts (71 with Api.luau) plus Bootstrap.server.luau
  Types, Rng, Timing, Config, Ports          leaves: shared types, seeded Rng, timing draws, defaults, port types
  Nav/       (10)  NavMath, NavGrid, GridPathProvider, GoalResolver, PathPlanner, WaypointFollower,
                   StuckDetector, Steering, Recovery, Locomotion
  Human/     (4)   InputProfile, CameraModel, Humanizer, JumpHabit
  Mind/      (13)  Personality, Needs, Mood, Memory, Reaction, Session, SocialGuard, Utility, Goals,
                   Activities, Brain, Overlays, Senses
  Chat/      (8)   ChatCorpus, ChatStyle, Composer, Recency, Reply, Safety, ChatGuard, TypingFreeze
  Identity/  (4)   Names, Avatars, AvatarCatalog, PrimitiveRig
  World/     (3)   PoiRegistry, Spatial, Scan
  Mimic/     (3)   MotionStats, MimicSampler, TraceBank
  Runtime/   (7)   Scheduler, Lod, ErrorBudget, Report, Population, Npc, NpcService
  Eval/      (2)   Trace, TellScore
  Adapters/  (11)  Connections, RobloxClock, RobloxMover, RobloxPathProvider, RobloxPerception,
                   RobloxPresenter, RobloxChatSink, RobloxRig, RobloxDiscovery, RobloxTelemetry, RobloxDebug
  Api.luau                   the facade (section 6)
src/shared/                  ReplicatedStorage.HumanlikeNpcShared: Remotes, ClientConfig, NameColor, AnimLogic, AnimSets
src/client/                  four LocalScripts (section 8)
tools/lune/                  Loader, World, Scenes, Sim, FakeWorld, Fakes/{FakePathProvider, ScriptedPlayer},
                             Headers, DepGraph, Bench, Harness, ExportScene, check.sh
tools/globalTypes.d.luau     Roblox definitions for luau-lsp
tests/                       T.luau (helpers), run.luau (registry), 38 *.spec.luau suites
```

Three rings. Ring 1 is the pure core: everything under `src/server` except `Adapters/` and `Api.luau`, plus
`src/shared`. It never touches a Roblox service and never yields; time is a number passed in, randomness is an
injected `Rng`, the world is a table of records, the body is a `Mover` port. Ring 2 is the only place that
touches instances, signals, `task.*`, `PathfindingService`, `Humanoid`, `Players` and `TextChatService`:
`src/server/Adapters/**`, `Api.luau`, `Bootstrap.server.luau` and `src/client/**`. Ring 3 (`tools/lune/**`,
`tests/**`) fakes ring 2 so the whole of ring 1 runs under Lune with the same files Rojo syncs into Studio.

Dependency rule: every module starts with `--!strict`, a doc comment saying what it is and is not, and a
`-- requires:` line naming exactly what it requires. `tools/lune/DepGraph` regenerates the graph from the sources
(76 modules, 218 edges, 19 leaves at the time of writing), fails on a cycle and reports header drift; `LoadAll`
asserts the same in the suite. `Config` requires only `Types`, and nothing in `Nav/`, `Chat/` or `Runtime/`
requires `Config`: `NpcService` takes the resolved table as plain data. Landed public APIs are extended
additively only.

## 16. License

License: to be chosen by the repository owner.

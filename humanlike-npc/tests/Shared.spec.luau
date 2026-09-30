local roblox = require("@lune/roblox")

return function(T, Loader)
	local Color3 = roblox.Color3
	local BrickColor = roblox.BrickColor
	local session = Loader.new()
	local Shared = session.game.ReplicatedStorage.HumanlikeNpcShared
	local Remotes = session.require(Shared.Remotes)
	local ClientConfig = session.require(Shared.ClientConfig)
	local NameColor = session.require(Shared.NameColor)
	local AnimSets = session.require(Shared.AnimSets)
	local AnimLogic = session.require(Shared.AnimLogic)

	local function sameColor(a, b): boolean
		return math.abs(a.R - b.R) < 1e-6 and math.abs(a.G - b.G) < 1e-6 and math.abs(a.B - b.B) < 1e-6
	end

	local function colorIndex(color): number?
		for i, candidate in NameColor.COLORS do
			if sameColor(candidate, color) then
				return i
			end
		end
		return nil
	end

	local function input(overrides: { [string]: any }): { [string]: any }
		local i = {
			onGround = true,
			speed = 0,
			verticalSpeed = 0,
			heightScale = 1,
			seated = false,
			climbing = false,
			emote = nil,
			now = 100,
			lastState = "idle",
			lastChangeAt = 90,
			jumpedAt = nil,
		}
		for k, v in overrides do
			i[k] = v
		end
		return i
	end

	T.describe("Shared", function()
		T.describe("Remotes", function()
			T.it("pins the remote, attribute and hook names", function()
				T.equal(Remotes.FOLDER, "HumanlikeNpcRemotes")
				T.equal(Remotes.CHAT, "CharacterChat")
				T.equal(Remotes.TYPING, "CharacterTyping")
				T.equal(Remotes.EMOTE, "CharacterEmote")
				T.equal(Remotes.CAM, "CharacterCam")
				T.equal(Remotes.CAM_ATTR_YAW, "CamYaw")
				T.equal(Remotes.CAM_ATTR_PITCH, "CamPitch")
				T.equal(Remotes.SHARED_SAY, "SharedChatSay")
				T.equal(Remotes.CUSTOM_WAYPOINT, "HumanlikeNpcCustomWaypoint")
				T.equal(Remotes.TELEMETRY, "HumanlikeNpcTelemetry")
				T.equal(Remotes.METADATA, "HNPC")
			end)

			T.it("names nothing after npcs on the client-facing remotes and attributes", function()
				for _, key in { "CHAT", "TYPING", "EMOTE", "CAM", "CAM_ATTR_YAW", "CAM_ATTR_PITCH" } do
					T.check(not string.find(string.lower(Remotes[key]), "npc"), `{key} = {Remotes[key]} names npcs`)
				end
			end)
		end)

		T.describe("ClientConfig", function()
			T.it("has the pinned defaults", function()
				local d = ClientConfig.DEFAULTS
				T.equal(d.ChatMode, "own")
				T.equal(d.ShowTypingIndicator, false)
				T.equal(d.HidePlayerList, false)
				T.equal(d.HeadLook, "off")
				T.equal(d.HeadLookMaxDegrees, 55)
				T.equal(d.HeadLookLerp, 0.12)
				T.equal(d.AnimFadeTime, 0.15)
			end)

			T.it("get() works under Lune where the folder has no attributes", function()
				local resolved = ClientConfig.get()
				for key, value in ClientConfig.DEFAULTS do
					T.equal(resolved[key], value, key)
				end
			end)

			T.it("resolve merges well-typed attributes and keeps defaults for the rest", function()
				local resolved = ClientConfig.resolve({
					ChatMode = "shared",
					ShowTypingIndicator = true,
					HidePlayerList = true,
					HeadLook = "shared",
					HeadLookMaxDegrees = 30,
					HeadLookLerp = 0.5,
					AnimFadeTime = 0.3,
					Unknown = 42,
				})
				T.equal(resolved.ChatMode, "shared")
				T.equal(resolved.ShowTypingIndicator, true)
				T.equal(resolved.HidePlayerList, true)
				T.equal(resolved.HeadLook, "shared")
				T.equal(resolved.HeadLookMaxDegrees, 30)
				T.equal(resolved.HeadLookLerp, 0.5)
				T.equal(resolved.AnimFadeTime, 0.3)
				T.equal(resolved.Unknown, nil)
			end)

			T.it("rejects wrong types, unknown modes and out-of-range numbers", function()
				local resolved = ClientConfig.resolve({
					ChatMode = "npcOnly",
					ShowTypingIndicator = "yes",
					HidePlayerList = 1,
					HeadLook = "npcOnly",
					HeadLookMaxDegrees = 400,
					HeadLookLerp = 0,
					AnimFadeTime = -1,
				})
				for key, value in ClientConfig.DEFAULTS do
					T.equal(resolved[key], value, key)
				end
				T.equal(ClientConfig.resolve(nil).ChatMode, "own")
			end)

			T.it("get() reads attributes set on the shared folder", function()
				Shared:SetAttribute("HidePlayerList", true)
				Shared:SetAttribute("HeadLook", "shared")
				Shared:SetAttribute("HeadLookMaxDegrees", 40)
				local resolved = ClientConfig.get()
				T.equal(resolved.HidePlayerList, true)
				T.equal(resolved.HeadLook, "shared")
				T.equal(resolved.HeadLookMaxDegrees, 40)
				T.equal(resolved.ChatMode, "own")
				Shared:SetAttribute("HidePlayerList", nil)
				Shared:SetAttribute("HeadLook", nil)
				Shared:SetAttribute("HeadLookMaxDegrees", nil)
				T.equal(ClientConfig.get().HeadLook, "off")
			end)
		end)

		T.describe("NameColor", function()
			T.it("has the eight legacy colours in order", function()
				T.equal(#NameColor.COLORS, 8)
				T.check(sameColor(NameColor.COLORS[1], Color3.fromRGB(253, 41, 67)), "Bright red")
				T.check(sameColor(NameColor.COLORS[2], Color3.fromRGB(1, 162, 255)), "Bright blue")
				T.check(sameColor(NameColor.COLORS[3], Color3.fromRGB(2, 184, 87)), "Earth green")
				T.check(sameColor(NameColor.COLORS[4], BrickColor.new("Bright violet").Color))
				T.check(sameColor(NameColor.COLORS[5], BrickColor.new("Bright orange").Color))
				T.check(sameColor(NameColor.COLORS[6], BrickColor.new("Bright yellow").Color))
				T.check(sameColor(NameColor.COLORS[7], BrickColor.new("Light reddish violet").Color))
				T.check(sameColor(NameColor.COLORS[8], BrickColor.new("Brick yellow").Color))
			end)

			T.it("matches the legacy hash on pinned names", function()
				T.equal(NameColor.value("hi"), 1)
				T.equal(colorIndex(NameColor.of("hi")), 2)
				T.equal(NameColor.value("Roblox"), 28)
				T.equal(colorIndex(NameColor.of("Roblox")), 5)
				T.equal(NameColor.value("abc"), 100)
				T.equal(colorIndex(NameColor.of("abc")), 5)
				T.equal(NameColor.value(""), 0)
				T.equal(colorIndex(NameColor.of("")), 1)
			end)

			T.it("is total: 200 generated names all land on one of the eight colours", function()
				local state = 12345
				local function nextInt(n: number): number
					state = (state * 1103515245 + 12345) % 2147483648
					return state % n
				end
				local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
				for _ = 1, 200 do
					local length = 3 + nextInt(18)
					local chars = {}
					for _ = 1, length do
						local at = 1 + nextInt(#alphabet)
						table.insert(chars, string.sub(alphabet, at, at))
					end
					local name = table.concat(chars)
					local index = colorIndex(NameColor.of(name))
					T.check(index ~= nil, `no colour for {name}`)
					T.equal(index, NameColor.index(name), name)
				end
			end)
		end)

		T.describe("AnimSets", function()
			T.it("pins the pack weights", function()
				local expected = {
					rthro = 25,
					cartoony = 15,
					robot = 5,
					ninja = 8,
					knight = 5,
					zombie = 5,
					elder = 5,
					levitation = 3,
					stylish = 8,
					toy = 3,
					superhero = 3,
					default = 15,
				}
				local count = 0
				for name, weight in expected do
					T.equal(AnimSets.PACKS[name], weight, name)
					T.check(AnimSets.SETS[name] ~= nil, `set for {name}`)
					count += 1
				end
				T.equal(#AnimSets.PACK_NAMES, count)
				for name in AnimSets.PACKS do
					T.check(expected[name] ~= nil, `unexpected pack {name}`)
				end
			end)

			T.it("pins the default pack to the R15 Animate ids", function()
				local d = AnimSets.SETS.default
				T.equal(d.idle1, 507766666)
				T.equal(d.idle2, 507766951)
				T.equal(d.idle3, 507766388)
				T.equal(d.idleWeights[1], 1)
				T.equal(d.idleWeights[2], 1)
				T.equal(d.idleWeights[3], 9)
				T.equal(d.walk, 507777826)
				T.equal(d.run, 507767714)
				T.equal(d.jump, 507765000)
				T.equal(d.fall, 507767968)
				T.equal(d.climb, 507765644)
				T.equal(d.sit, 2506281703)
				T.equal(AnimSets.idleId(d, 1), d.idle1)
				T.equal(AnimSets.idleId(d, 2), d.idle2)
				T.equal(AnimSets.idleId(d, 3), d.idle3)
			end)

			T.it("pins the emote ids and durations", function()
				local e = AnimSets.EMOTES
				T.equal(e.wave.id, 507770239)
				T.equal(e.wave.duration, 3)
				T.equal(e.wave.loops, false)
				T.equal(e.point.id, 507770453)
				T.equal(e.point.duration, 2)
				T.equal(e.laugh.id, 507770818)
				T.equal(e.laugh.duration, 3)
				T.equal(e.cheer.id, 507770677)
				T.equal(e.cheer.duration, 3)
				local function ids(emote): { number }
					local list = {}
					for _, clip in emote.weightedIds do
						table.insert(list, clip.id)
					end
					return list
				end
				T.equal(table.concat(ids(e.dance), ","), "507771019,507771955,507772104")
				T.equal(table.concat(ids(e.dance2), ","), "507776043,507776720,507776879")
				T.equal(table.concat(ids(e.dance3), ","), "507777268,507777451,507777623")
				for _, name in { "dance", "dance2", "dance3" } do
					T.equal(e[name].duration, math.huge, name)
					T.equal(e[name].loops, true, name)
				end
				T.equal(#AnimSets.EMOTE_NAMES, 7)
			end)

			T.it("resolves 0 ids to the default pack's clips and unknown packs to default", function()
				local rthro = AnimSets.resolve("rthro")
				local d = AnimSets.SETS.default
				T.equal(rthro.walk, d.walk)
				T.equal(rthro.idle3, d.idle3)
				T.equal(rthro.sit, d.sit)
				local unknown = AnimSets.resolve("nonsense")
				T.equal(unknown.run, d.run)
				T.equal(AnimSets.resolve(nil).jump, d.jump)
				T.equal(AnimSets.resolve("default").climb, d.climb)
			end)

			T.it("picks packs deterministically from a name, following the weights", function()
				T.equal(AnimSets.packFor("coolgamer2013"), AnimSets.packFor("coolgamer2013"))
				local counts = {}
				local n = 6000
				for i = 1, n do
					local pack = AnimSets.packFor(`user_{i}_{i * 7}`)
					counts[pack] = (counts[pack] or 0) + 1
				end
				local total = 0
				for _, weight in AnimSets.PACKS do
					total += weight
				end
				for name, weight in AnimSets.PACKS do
					local expected = weight / total
					local got = (counts[name] or 0) / n
					T.between(got, expected * 0.6, expected * 1.4, `share of {name}`)
				end
			end)

			T.it("emoteId picks within the clip list", function()
				local dance = AnimSets.EMOTES.dance
				T.equal(AnimSets.emoteId(dance, 0), 507771019)
				T.equal(AnimSets.emoteId(dance, 0.5), 507771955)
				T.equal(AnimSets.emoteId(dance, 0.99), 507772104)
				T.equal(AnimSets.emoteId(AnimSets.EMOTES.wave, 0.7), 507770239)
			end)
		end)

		T.describe("AnimLogic", function()
			T.it("speed 8 cross-fades walk 0.75 / run 0.25 at playback 0.625", function()
				local s = AnimLogic.select(input({ speed = 8 }))
				T.equal(s.state, "walk")
				T.near(s.walkWeight, 0.75, 1e-9)
				T.near(s.runWeight, 0.25, 1e-9)
				T.near(s.playbackSpeed, 0.625, 1e-9)
			end)

			T.it("speed 16 is full run at playback 1.25", function()
				local s = AnimLogic.select(input({ speed = 16 }))
				T.equal(s.state, "walk")
				T.near(s.runWeight, 1, 1e-9)
				T.near(s.walkWeight, 0, 1e-9)
				T.near(s.playbackSpeed, 1.25, 1e-9)
			end)

			T.it("speed 4 is walk only, time-warped to 0.3125", function()
				local s = AnimLogic.select(input({ speed = 4 }))
				T.equal(s.state, "walk")
				T.near(s.walkWeight, 1, 1e-9)
				T.near(s.runWeight, 0, 1e-9)
				T.near(s.playbackSpeed, 0.3125, 1e-9)
			end)

			T.it("speed 0.5 is idle", function()
				local s = AnimLogic.select(input({ speed = 0.5 }))
				T.equal(s.state, "idle")
				T.near(s.fade, 0.2, 1e-9)
			end)

			T.it("heightScale 1.2 at speed 8 plays back at 0.5208", function()
				local s = AnimLogic.select(input({ speed = 8, heightScale = 1.2 }))
				T.near(s.playbackSpeed, 0.5208, 0.001)
				T.equal(AnimLogic.select(input({ speed = 0.85, heightScale = 1.2 })).state, "idle")
				T.equal(AnimLogic.select(input({ speed = 0.85, heightScale = 1 })).state, "walk")
			end)

			T.it("jump becomes fall after 0.31 s", function()
				local jump = AnimLogic.select(input({ onGround = false, jumpedAt = 100, now = 100.2 }))
				T.equal(jump.state, "jump")
				T.near(jump.fade, 0.1, 1e-9)
				local held = AnimLogic.select(input({ onGround = false, jumpedAt = 100, now = 100.3 }))
				T.equal(held.state, "jump")
				local fall = AnimLogic.select(input({ onGround = false, jumpedAt = 100, now = 100.32 }))
				T.equal(fall.state, "fall")
				T.near(fall.fade, 0.2, 1e-9)
				local edge = AnimLogic.select(input({ onGround = false, verticalSpeed = -5, lastState = "idle" }))
				T.equal(edge.state, "fall", "walking off an edge falls at once")
				local rising = AnimLogic.select(input({ onGround = false, verticalSpeed = 20, lastState = "idle" }))
				T.equal(rising.state, "jump", "rising with no event seen starts a jump")
				local heldByState = AnimLogic.select(
					input({ onGround = false, verticalSpeed = 20, lastState = "jump", lastChangeAt = 100, now = 100.2 })
				)
				T.equal(heldByState.state, "jump")
			end)

			T.it("emote wins over movement, seat and climb win over emote", function()
				local s = AnimLogic.select(input({ speed = 16, emote = "wave" }))
				T.equal(s.state, "emote")
				T.near(s.fade, 0.1, 1e-9)
				T.equal(AnimLogic.select(input({ onGround = false, emote = "wave" })).state, "emote")
				T.equal(AnimLogic.select(input({ seated = true, emote = "wave", speed = 16 })).state, "sit")
				T.equal(AnimLogic.select(input({ climbing = true, emote = "wave", speed = 16 })).state, "climb")
				T.near(AnimLogic.select(input({ climbing = true, speed = 10 })).playbackSpeed, 2, 1e-9)
				T.near(AnimLogic.select(input({ seated = true })).fade, 0.5, 1e-9)
			end)

			T.it("idleRoll picks 3 about 82% of the time", function()
				local threes, ones, twos = 0, 0, 0
				local n = 3000
				for i = 1, n do
					local pick = AnimLogic.idleRoll(4242, i)
					if pick == 3 then
						threes += 1
					elseif pick == 1 then
						ones += 1
					elseif pick == 2 then
						twos += 1
					else
						error(`idleRoll returned {pick}`)
					end
				end
				T.between(threes / n, 0.78, 0.86, "share of idle3")
				T.check(ones > 0 and twos > 0, "the rare variants do occur")
				T.equal(AnimLogic.idleRoll(7, 3), AnimLogic.idleRoll(7, 3), "deterministic")
				T.equal(AnimLogic.idleRoll(1, 1, { 0, 0, 1 }), 3)
				T.equal(AnimLogic.idleRoll(1, 1, { 1, 0, 0 }), 1)
			end)

			T.it("seeds are stable per name and units are uniform-ish", function()
				T.equal(AnimLogic.seedFor("Milo_2014"), AnimLogic.seedFor("Milo_2014"))
				T.check(AnimLogic.seedFor("Milo_2014") ~= AnimLogic.seedFor("Milo_2015"))
				local sum = 0
				local n = 2000
				for i = 1, n do
					local u = AnimLogic.unit(99, i)
					T.between(u, 0, 0.9999999999)
					sum += u
				end
				T.between(sum / n, 0.45, 0.55, "mean of unit draws")
			end)
		end)
	end)
end

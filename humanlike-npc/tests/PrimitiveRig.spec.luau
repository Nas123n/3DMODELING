return function(T, Loader)
	local session = Loader.new()
	local S = session.game.ServerStorage.HumanlikeNpc
	local Rng = session.require(S.Rng)
	local Personality = session.require(S.Mind.Personality)
	local Avatars = session.require(S.Identity.Avatars)
	local PrimitiveRig = session.require(S.Identity.PrimitiveRig)

	local function specFor(seed: number, forcePrimitive: boolean?)
		local p = Personality.sample(Rng.new(seed))
		return Avatars.sample(Rng.new(seed):fork("avatar"), p, { forcePrimitive = forcePrimitive })
	end

	local function count(model, className: string): number
		local n = 0
		for _, child in model:GetDescendants() do
			if child:IsA(className) then
				n += 1
			end
		end
		return n
	end

	T.describe("PrimitiveRig", function()
		T.it("builds 16 parts + humanoid + 15 motors", function()
			local model = PrimitiveRig.build(specFor(1, true), "TestRig")
			T.equal(model.Name, "TestRig")
			T.equal(model.ClassName, "Model")
			T.equal(count(model, "BasePart"), 16, "parts")
			T.equal(count(model, "Humanoid"), 1, "humanoid")
			T.equal(count(model, "Motor6D"), 15, "motors")
			T.equal(count(model, "Attachment"), 0, "no attachments")
			T.equal(count(model, "BodyColors"), 0, "no BodyColors")
			T.equal(#model:GetDescendants(), 32, "nothing else")
			T.equal(model.PrimaryPart.Name, "HumanoidRootPart")
			T.check(model.Parent == nil, "unparented")
			-- Every joint is parented to its Part1 and the Neck attaches Head to UpperTorso.
			for _, joint in PrimitiveRig.JOINTS do
				local part1 = model:FindFirstChild(joint.part1)
				local motor = part1:FindFirstChild(joint.name)
				T.check(motor ~= nil and motor:IsA("Motor6D"), `motor {joint.name} in {joint.part1}`)
				T.equal(motor.Part0.Name, joint.part0, `{joint.name} Part0`)
				T.equal(motor.Part1.Name, joint.part1, `{joint.name} Part1`)
			end
			local neck = model:FindFirstChild("Head"):FindFirstChild("Neck")
			T.equal(neck.Part0.Name, "UpperTorso")
		end)

		-- Lune stores part sizes and CFrames at reduced precision (about 6e-6 off), hence the tolerances.
		T.it("names and part sizes", function()
			local model = PrimitiveRig.build(specFor(2, true), "Sizes")
			T.equal(#PrimitiveRig.PART_NAMES, 16)
			for _, name in PrimitiveRig.PART_NAMES do
				local part = model:FindFirstChild(name)
				T.check(part ~= nil and part:IsA("BasePart"), `part {name}`)
				T.check((part.Size - PrimitiveRig.PART_SIZES[name]).Magnitude < 1e-3, `size of {name}`)
				local expected = PrimitiveRig.PART_OFFSETS[name]
				T.check((part.CFrame.Position - expected).Magnitude < 1e-3, `offset of {name}`)
			end
			local rootSize = model.HumanoidRootPart.Size
			T.check(
				math.abs(rootSize.X - 2) < 1e-3 and math.abs(rootSize.Y - 2) < 1e-3 and math.abs(rootSize.Z - 1) < 1e-3,
				"root size"
			)
			-- Feet stand at HipHeight + root half height below the root centre.
			local foot = model:FindFirstChild("LeftFoot")
			T.near(foot.CFrame.Position.Y - foot.Size.Y / 2, -(PrimitiveRig.HIP_HEIGHT + 1), 1e-3, "sole height")
			local head = model:FindFirstChild("Head")
			T.near(head.CFrame.Position.Y + head.Size.Y / 2, 2.2, 1e-3, "top of the head")
			-- Each motor reproduces its Part1 placement: Part1 = Part0 * C0 * C1:Inverse().
			for _, joint in PrimitiveRig.JOINTS do
				local part0 = model:FindFirstChild(joint.part0)
				local part1 = model:FindFirstChild(joint.part1)
				local motor = part1:FindFirstChild(joint.name)
				local placed = part0.CFrame * motor.C0 * motor.C1:Inverse()
				T.check((placed.Position - part1.CFrame.Position).Magnitude < 1e-3, `joint {joint.name} placement`)
				-- The pivot lies inside or on the boundary of both parts' vertical extent.
				local pivot = joint.pivot
				local lo0, hi0 = part0.CFrame.Position.Y - part0.Size.Y / 2, part0.CFrame.Position.Y + part0.Size.Y / 2
				local lo1, hi1 = part1.CFrame.Position.Y - part1.Size.Y / 2, part1.CFrame.Position.Y + part1.Size.Y / 2
				T.check(pivot.Y >= lo0 - 1e-3 and pivot.Y <= hi0 + 1e-3, `{joint.name} pivot within Part0`)
				T.check(pivot.Y >= lo1 - 1e-3 and pivot.Y <= hi1 + 1e-3, `{joint.name} pivot within Part1`)
			end
		end)

		T.it("root is transparent and non-anchored", function()
			local model = PrimitiveRig.build(specFor(3, true), "Root")
			local root = model:FindFirstChild("HumanoidRootPart")
			T.equal(root.Transparency, 1)
			T.equal(root.Anchored, false)
			T.equal(root.CanCollide, true)
			for _, name in PrimitiveRig.PART_NAMES do
				local part = model:FindFirstChild(name)
				T.equal(part.Anchored, false, `{name} anchored`)
				local colliding = name == "HumanoidRootPart" or name == "UpperTorso" or name == "LowerTorso"
				T.equal(part.CanCollide, colliding, `{name} CanCollide`)
				if name ~= "HumanoidRootPart" then
					T.equal(part.Transparency, 0, `{name} visible`)
				end
			end
		end)

		T.it("rig type and root priority are attempted", function()
			local model, attempts = PrimitiveRig.build(specFor(4, true), "Attempts")
			T.equal(type(attempts.rigType), "boolean")
			T.equal(type(attempts.hipHeight), "boolean")
			T.equal(type(attempts.rootPriority), "boolean")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			T.check(humanoid ~= nil, "humanoid present")
			-- Recorded, not asserted: under Lune 0.10.3 all three succeed, older emulators may not.
			if attempts.hipHeight then
				T.equal(humanoid.HipHeight, PrimitiveRig.HIP_HEIGHT)
			end
			if attempts.rootPriority then
				T.equal(model.HumanoidRootPart.RootPriority, PrimitiveRig.ROOT_PRIORITY)
			end
		end)

		T.it("apply recolours", function()
			local specA = specFor(5, true)
			local model = PrimitiveRig.build(specA, "Paint")
			local colorsA = PrimitiveRig.colorsFor(specA)
			T.check(model.UpperTorso.Color == colorsA.shirt, "built with A's shirt")
			T.check(model.LeftUpperLeg.Color == colorsA.pants, "built with A's pants")
			T.check(model.Head.Color == colorsA.skin, "built with A's skin")
			T.check(model.LeftHand.Color == colorsA.skin, "hands are skin")
			local specB
			for seed = 6, 60 do
				local candidate = specFor(seed, true)
				local colorsB = PrimitiveRig.colorsFor(candidate)
				if colorsB.shirt ~= colorsA.shirt and colorsB.pants ~= colorsA.pants then
					specB = candidate
					break
				end
			end
			T.check(specB ~= nil, "found a differently dressed spec")
			PrimitiveRig.apply(model, specB)
			local colorsB = PrimitiveRig.colorsFor(specB)
			for _, name in PrimitiveRig.PART_NAMES do
				local role = PrimitiveRig.PART_ROLES[name]
				local expected = if role == "shirt"
					then colorsB.shirt
					elseif role == "pants" then colorsB.pants
					else colorsB.skin
				T.check(model:FindFirstChild(name).Color == expected, `{name} recoloured`)
			end
			-- A spec that was not sampled for a block rig still dresses from its catalogSeed.
			local plain = specFor(7, false)
			T.check(plain.bodyColors.shirt == nil, "no palette in a plain spec")
			local colorsPlain = PrimitiveRig.colorsFor(plain)
			T.check(colorsPlain.shirt ~= nil and colorsPlain.pants ~= nil and colorsPlain.skin ~= nil)
			local plainModel = PrimitiveRig.build(plain, "Plain")
			T.check(plainModel.UpperTorso.Color == colorsPlain.shirt, "plain spec wears its seed's palette")
		end)
	end)
end

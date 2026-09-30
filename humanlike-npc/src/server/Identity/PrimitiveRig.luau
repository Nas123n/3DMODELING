--!strict
-- An R15-shaped placeholder character built from plain Parts: sixteen parts (HumanoidRootPart,
-- Head, UpperTorso, LowerTorso and four limbs of upper, lower and hand/foot), one Humanoid and
-- the fifteen Motor6Ds of the R15 rig, named and wired the way the engine's rig is so that
-- animation tracks published for R15 play on it. Colours come from the spec's primitive palette
-- (shirt, pants, skin), or from its catalogSeed and skin tone when the spec was not sampled for a
-- block rig, so any AvatarSpec builds.
--
-- It is a last resort, never the default install's look: the rig adapter builds real avatars
-- through CreateHumanoidModelFromDescriptionAsync and reaches this only when that call fails,
-- under Lune (tests) or with the UsePrimitiveRigs debug flag. It creates Instances with
-- Instance.new and writes properties; it touches no service, no signal and never parents the
-- model (the caller places and parents it). Only Parts, Motor6Ds and a Humanoid are used: no
-- Attachments, no BodyColors, no meshes, so the build runs unchanged under Lune's emulation.
--
-- Geometry is the block-rig silhouette computed from HipHeight 2 and the root's half height 1
-- (feet at -3 below the root centre): a 2-stud torso, 2-stud limbs, a 1.2 cube head. The engine
-- animator needs the joint names, the part hierarchy and HipHeight, not exact package sizes.

local Types = require(script.Parent.Parent.Types)
local AvatarCatalog = require(script.Parent.AvatarCatalog)

type AvatarSpec = Types.AvatarSpec

local PrimitiveRig = {}

-- The R15 animator assumes this base hip height; part offsets are computed from it.
PrimitiveRig.HIP_HEIGHT = 2
PrimitiveRig.ROOT_PRIORITY = 127

-- The colours a block rig wears.
export type Colors = { skin: Color3, shirt: Color3, pants: Color3, hair: Color3? }

-- Which pcall-guarded writes succeeded (they do in Studio; older Lune builds may lack them).
export type Attempts = { rigType: boolean, hipHeight: boolean, rootPriority: boolean }

-- One Motor6D: parented to part1, joint pivot given relative to the root centre (T-pose).
export type Joint = { name: string, part0: string, part1: string, pivot: Vector3 }

-- Build order (fixed; never iterate PART_SIZES when order matters).
PrimitiveRig.PART_NAMES = {
	"HumanoidRootPart",
	"Head",
	"UpperTorso",
	"LowerTorso",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
}

local UPPER_LIMB = Vector3.new(1, 0.8, 1)
local LOWER_LIMB = Vector3.new(1, 0.8, 1)
local END_LIMB = Vector3.new(1, 0.4, 1)

PrimitiveRig.PART_SIZES = {
	HumanoidRootPart = Vector3.new(2, 2, 1),
	Head = Vector3.new(1.2, 1.2, 1.2),
	UpperTorso = Vector3.new(2, 1.6, 1),
	LowerTorso = Vector3.new(2, 0.4, 1),
	LeftUpperArm = UPPER_LIMB,
	LeftLowerArm = LOWER_LIMB,
	LeftHand = END_LIMB,
	RightUpperArm = UPPER_LIMB,
	RightLowerArm = LOWER_LIMB,
	RightHand = END_LIMB,
	LeftUpperLeg = UPPER_LIMB,
	LeftLowerLeg = LOWER_LIMB,
	LeftFoot = END_LIMB,
	RightUpperLeg = UPPER_LIMB,
	RightLowerLeg = LOWER_LIMB,
	RightFoot = END_LIMB,
} :: { [string]: Vector3 }

-- "skin" | "shirt" | "pants": what each part is painted with.
PrimitiveRig.PART_ROLES = {
	HumanoidRootPart = "skin",
	Head = "skin",
	UpperTorso = "shirt",
	LowerTorso = "shirt",
	LeftUpperArm = "shirt",
	LeftLowerArm = "shirt",
	LeftHand = "skin",
	RightUpperArm = "shirt",
	RightLowerArm = "shirt",
	RightHand = "skin",
	LeftUpperLeg = "pants",
	LeftLowerLeg = "pants",
	LeftFoot = "pants",
	RightUpperLeg = "pants",
	RightLowerLeg = "pants",
	RightFoot = "pants",
} :: { [string]: string }

-- Parts that keep collision (the engine manages the rest of a character itself).
local COLLIDING: { [string]: boolean } = { HumanoidRootPart = true, UpperTorso = true, LowerTorso = true }

-- How far below the torso top the shoulder joints sit.
local SHOULDER_DROP = 0.3

-- Part centres relative to the root centre and the joint table, derived from the sizes above.
local function layout(): ({ [string]: Vector3 }, { Joint })
	local S = PrimitiveRig.PART_SIZES
	local rootHalf = S.HumanoidRootPart.Y / 2
	local floorY = -(PrimitiveRig.HIP_HEIGHT + rootHalf)

	local footC = floorY + S.LeftFoot.Y / 2
	local lowerLegC = floorY + S.LeftFoot.Y + S.LeftLowerLeg.Y / 2
	local upperLegC = floorY + S.LeftFoot.Y + S.LeftLowerLeg.Y + S.LeftUpperLeg.Y / 2
	local legTop = floorY + S.LeftFoot.Y + S.LeftLowerLeg.Y + S.LeftUpperLeg.Y

	local lowerTorsoC = legTop + S.LowerTorso.Y / 2
	local torsoMid = legTop + S.LowerTorso.Y
	local upperTorsoC = torsoMid + S.UpperTorso.Y / 2
	local torsoTop = torsoMid + S.UpperTorso.Y
	local headC = torsoTop + S.Head.Y / 2

	local upperArmC = torsoTop - S.LeftUpperArm.Y / 2
	local lowerArmC = torsoTop - S.LeftUpperArm.Y - S.LeftLowerArm.Y / 2
	local handC = torsoTop - S.LeftUpperArm.Y - S.LeftLowerArm.Y - S.LeftHand.Y / 2

	local armX = S.UpperTorso.X / 2 + S.LeftUpperArm.X / 2 -- character's right is +X
	local legX = S.LeftUpperLeg.X / 2

	local offsets: { [string]: Vector3 } = {
		HumanoidRootPart = Vector3.new(0, 0, 0),
		Head = Vector3.new(0, headC, 0),
		UpperTorso = Vector3.new(0, upperTorsoC, 0),
		LowerTorso = Vector3.new(0, lowerTorsoC, 0),
		LeftUpperArm = Vector3.new(-armX, upperArmC, 0),
		LeftLowerArm = Vector3.new(-armX, lowerArmC, 0),
		LeftHand = Vector3.new(-armX, handC, 0),
		RightUpperArm = Vector3.new(armX, upperArmC, 0),
		RightLowerArm = Vector3.new(armX, lowerArmC, 0),
		RightHand = Vector3.new(armX, handC, 0),
		LeftUpperLeg = Vector3.new(-legX, upperLegC, 0),
		LeftLowerLeg = Vector3.new(-legX, lowerLegC, 0),
		LeftFoot = Vector3.new(-legX, footC, 0),
		RightUpperLeg = Vector3.new(legX, upperLegC, 0),
		RightLowerLeg = Vector3.new(legX, lowerLegC, 0),
		RightFoot = Vector3.new(legX, footC, 0),
	}

	local shoulderY = torsoTop - SHOULDER_DROP
	local elbowY = torsoTop - S.LeftUpperArm.Y
	local wristY = elbowY - S.LeftLowerArm.Y
	local kneeY = legTop - S.LeftUpperLeg.Y
	local ankleY = kneeY - S.LeftLowerLeg.Y
	local shoulderX = S.UpperTorso.X / 2

	local joints: { Joint } = {
		{ name = "Root", part0 = "HumanoidRootPart", part1 = "LowerTorso", pivot = Vector3.new(0, lowerTorsoC, 0) },
		{ name = "Waist", part0 = "LowerTorso", part1 = "UpperTorso", pivot = Vector3.new(0, torsoMid, 0) },
		{ name = "Neck", part0 = "UpperTorso", part1 = "Head", pivot = Vector3.new(0, torsoTop, 0) },
		{
			name = "LeftShoulder",
			part0 = "UpperTorso",
			part1 = "LeftUpperArm",
			pivot = Vector3.new(-shoulderX, shoulderY, 0),
		},
		{ name = "LeftElbow", part0 = "LeftUpperArm", part1 = "LeftLowerArm", pivot = Vector3.new(-armX, elbowY, 0) },
		{ name = "LeftWrist", part0 = "LeftLowerArm", part1 = "LeftHand", pivot = Vector3.new(-armX, wristY, 0) },
		{
			name = "RightShoulder",
			part0 = "UpperTorso",
			part1 = "RightUpperArm",
			pivot = Vector3.new(shoulderX, shoulderY, 0),
		},
		{ name = "RightElbow", part0 = "RightUpperArm", part1 = "RightLowerArm", pivot = Vector3.new(armX, elbowY, 0) },
		{ name = "RightWrist", part0 = "RightLowerArm", part1 = "RightHand", pivot = Vector3.new(armX, wristY, 0) },
		{ name = "LeftHip", part0 = "LowerTorso", part1 = "LeftUpperLeg", pivot = Vector3.new(-legX, legTop, 0) },
		{ name = "LeftKnee", part0 = "LeftUpperLeg", part1 = "LeftLowerLeg", pivot = Vector3.new(-legX, kneeY, 0) },
		{ name = "LeftAnkle", part0 = "LeftLowerLeg", part1 = "LeftFoot", pivot = Vector3.new(-legX, ankleY, 0) },
		{ name = "RightHip", part0 = "LowerTorso", part1 = "RightUpperLeg", pivot = Vector3.new(legX, legTop, 0) },
		{ name = "RightKnee", part0 = "RightUpperLeg", part1 = "RightLowerLeg", pivot = Vector3.new(legX, kneeY, 0) },
		{ name = "RightAnkle", part0 = "RightLowerLeg", part1 = "RightFoot", pivot = Vector3.new(legX, ankleY, 0) },
	}
	return offsets, joints
end

local PART_OFFSETS, JOINTS = layout()
PrimitiveRig.PART_OFFSETS = PART_OFFSETS
PrimitiveRig.JOINTS = JOINTS

local FALLBACK_SKIN = Color3.fromRGB(204, 142, 105)

-- The colours a spec wears as a block rig: the palette slots Avatars adds for forcePrimitive when
-- present, else the palette its catalogSeed points at and the skin tone its index names.
function PrimitiveRig.colorsFor(spec: AvatarSpec): Colors
	local palettes = AvatarCatalog.PRIMITIVE_PALETTES
	local paletteEntry = palettes[AvatarCatalog.paletteIndex(spec.catalogSeed, #palettes)]
	local tones = AvatarCatalog.SKIN_TONES
	local tone = tones[math.clamp(math.floor(spec.skinToneIndex), 1, #tones)] or FALLBACK_SKIN
	local skin = spec.bodyColors.skin or spec.bodyColors.HeadColor or tone
	return {
		skin = skin,
		shirt = spec.bodyColors.shirt or paletteEntry.shirt,
		pants = spec.bodyColors.pants or paletteEntry.pants,
		hair = spec.bodyColors.hair or paletteEntry.hair,
	}
end

local function colorOf(colors: Colors, role: string): Color3
	if role == "shirt" then
		return colors.shirt
	elseif role == "pants" then
		return colors.pants
	end
	return colors.skin
end

-- Builds the character with its root at the origin, unparented; the caller pivots and parents
-- it. The second value records which guarded writes took.
function PrimitiveRig.build(spec: AvatarSpec, name: string): (Model, Attempts)
	local colors = PrimitiveRig.colorsFor(spec)
	local model = Instance.new("Model")
	model.Name = name

	local parts: { [string]: Part } = {}
	for _, partName in PrimitiveRig.PART_NAMES do
		local part = Instance.new("Part")
		part.Name = partName
		part.Size = PrimitiveRig.PART_SIZES[partName]
		part.CFrame = CFrame.new(PART_OFFSETS[partName])
		part.Color = colorOf(colors, PrimitiveRig.PART_ROLES[partName])
		part.Anchored = false
		part.CanCollide = COLLIDING[partName] == true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		if partName == "HumanoidRootPart" then
			part.Transparency = 1
		end
		part.Parent = model
		parts[partName] = part
	end
	local root = parts.HumanoidRootPart
	model.PrimaryPart = root

	for _, joint in JOINTS do
		local part0 = parts[joint.part0]
		local part1 = parts[joint.part1]
		local motor = Instance.new("Motor6D")
		motor.Name = joint.name
		motor.Part0 = part0
		motor.Part1 = part1
		-- part1.CFrame == part0.CFrame * C0 * C1:Inverse(); the pivot is the joint's centre.
		motor.C0 = CFrame.new(joint.pivot - PART_OFFSETS[joint.part0])
		motor.C1 = CFrame.new(joint.pivot - PART_OFFSETS[joint.part1])
		motor.Parent = part1
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model

	-- Pinned behind pcall by the spec: they succeed in Studio (and in Lune 0.10.3, probed), but an
	-- emulator that rejects them must not stop the build; the caller may read the record.
	local attempts: Attempts = { rigType = false, hipHeight = false, rootPriority = false }
	attempts.rigType = pcall(function()
		humanoid.RigType = Enum.HumanoidRigType.R15
	end)
	attempts.hipHeight = pcall(function()
		humanoid.HipHeight = PrimitiveRig.HIP_HEIGHT
	end)
	attempts.rootPriority = pcall(function()
		root.RootPriority = PrimitiveRig.ROOT_PRIORITY
	end)

	return model, attempts
end

-- Recolours a built rig to another spec's palette without rebuilding it.
function PrimitiveRig.apply(model: Model, spec: AvatarSpec)
	local colors = PrimitiveRig.colorsFor(spec)
	for _, partName in PrimitiveRig.PART_NAMES do
		local child = model:FindFirstChild(partName)
		if child and child:IsA("BasePart") then
			child.Color = colorOf(colors, PrimitiveRig.PART_ROLES[partName])
		end
	end
end

return PrimitiveRig

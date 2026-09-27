--!strict
-- Client-side motion for anything the builders tagged:
--   Bob      Model/BasePart floats up and down  (attributes: BobHeight studs, BobSpeed rad/s)
--   Spin     Model/BasePart turns about its pivot (attribute: SpinSpeed rad/s)
--   Flicker  PointLight brightness wavers        (attribute: FlickerAmount 0..1)
-- It runs locally, so the motion costs no network traffic; things far from the camera are skipped.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local MAX_DISTANCE = 200

type Mover = {
	instance: PVInstance,
	base: CFrame,
	bob: boolean,
	spin: boolean,
	bobHeight: number,
	bobSpeed: number,
	spinSpeed: number,
	phase: number,
}

type Flame = {
	light: PointLight,
	brightness: number,
	amount: number,
	seed: number,
	position: Vector3,
}

local movers: { [Instance]: Mover } = {}
local flames: { [Instance]: Flame } = {}

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" then value else default
end

-- Offsets each object's cycle by where it stands, so neighbors don't move in lockstep.
local function phaseFor(position: Vector3): number
	return (position.X * 0.37 + position.Z * 0.73) % (math.pi * 2)
end

local function refreshMover(instance: Instance)
	if not instance:IsA("PVInstance") then
		return
	end
	local bob, spin = instance:HasTag("Bob"), instance:HasTag("Spin")
	local mover = movers[instance]
	if not bob and not spin then
		if mover and mover.bob then
			mover.instance:PivotTo(mover.base)
		end
		movers[instance] = nil
		return
	end
	if not mover then
		local base = instance:GetPivot()
		mover = {
			instance = instance,
			base = base,
			bob = bob,
			spin = spin,
			bobHeight = numberAttribute(instance, "BobHeight", 0.35),
			bobSpeed = numberAttribute(instance, "BobSpeed", 1.6),
			spinSpeed = numberAttribute(instance, "SpinSpeed", 0.8),
			phase = phaseFor(base.Position),
		}
		movers[instance] = mover
	end
	mover.bob, mover.spin = bob, spin
end

local function forgetMover(instance: Instance)
	if not instance:HasTag("Bob") and not instance:HasTag("Spin") then
		movers[instance] = nil
	end
end

local function addFlame(instance: Instance)
	if not instance:IsA("PointLight") then
		return
	end
	local holder = instance.Parent
	flames[instance] = {
		light = instance,
		brightness = instance.Brightness,
		amount = numberAttribute(instance, "FlickerAmount", 0.25),
		seed = phaseFor(if holder and holder:IsA("BasePart") then holder.Position else Vector3.zero) * 10,
		position = if holder and holder:IsA("BasePart") then holder.Position else Vector3.zero,
	}
end

local function removeFlame(instance: Instance)
	local flame = flames[instance]
	if flame then
		flame.light.Brightness = flame.brightness
		flames[instance] = nil
	end
end

local function watch(tag: string, added: (Instance) -> (), removed: (Instance) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(added)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(removed)
	for _, instance in CollectionService:GetTagged(tag) do
		added(instance)
	end
end

watch("Bob", refreshMover, forgetMover)
watch("Spin", refreshMover, forgetMover)
watch("Flicker", addFlame, removeFlame)

local clock = 0

RunService.Heartbeat:Connect(function(dt)
	clock += dt
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position

	for _, mover in movers do
		if (mover.base.Position - eye).Magnitude > MAX_DISTANCE then
			continue
		end
		if mover.bob then
			-- Absolute from the resting pivot, so bob and spin never drift.
			local lift = math.sin(clock * mover.bobSpeed + mover.phase) * mover.bobHeight
			local turn = if mover.spin
				then CFrame.Angles(0, clock * mover.spinSpeed + mover.phase, 0)
				else CFrame.identity
			mover.instance:PivotTo(mover.base * CFrame.new(0, lift, 0) * turn)
		else
			-- Spin-only objects may sit inside something that bobs (an egg's halo), so turn
			-- relative to wherever they are now instead of snapping back to their base.
			mover.instance:PivotTo(mover.instance:GetPivot() * CFrame.Angles(0, dt * mover.spinSpeed, 0))
		end
	end

	for _, flame in flames do
		if (flame.position - eye).Magnitude > MAX_DISTANCE then
			continue
		end
		local wobble = math.noise(clock * 2.5, flame.seed, 0.5) * 2 -- roughly -1..1
		flame.light.Brightness = flame.brightness * (1 + flame.amount * wobble)
	end
end)

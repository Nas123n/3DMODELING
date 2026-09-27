--!strict
-- Part-building helpers shared by the prop and egg builders. Everything is built from
-- primitive parts and built-in materials: no uploaded meshes or textures, so nothing
-- waits on asset moderation or fails to load.

local Geometry = {}

export type Shape = "Block" | "Ball" | "Cylinder" | "Ellipsoid"

export type PartOptions = {
	material: Enum.Material?,
	collide: boolean?, -- default false: decorations are see-through for raycasts and players
	transparency: number?,
	shadow: boolean?, -- default true
	name: string?,
}

-- Rotating by this turns a cube so one corner points straight up: a faceted crystal or gem tip.
Geometry.CORNER_UP = CFrame.fromAxisAngle(Vector3.new(-1, 0, 1).Unit, math.acos(1 / math.sqrt(3)))

-- Cylinders run along a part's X axis; this stands them upright.
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

local SHAPES: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
}

function Geometry.part(
	parent: Instance,
	shape: Shape,
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	options: PartOptions?
): Part
	local opts: PartOptions = options or {}
	local p = Instance.new("Part")
	p.Name = opts.name or shape
	p.Anchored = true
	if shape == "Ellipsoid" then
		-- A sphere SpecialMesh stretches to the part's size; collision stays a box, so it never collides.
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
	else
		p.Shape = SHAPES[shape]
	end
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = opts.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = opts.transparency or 0
	p.CastShadow = opts.shadow ~= false
	p.CanTouch = false
	local collide = opts.collide == true and shape ~= "Ellipsoid"
	p.CanCollide = collide
	-- Non-colliding decor stays out of raycasts and spatial queries (camera, tools, other builders).
	p.CanQuery = collide
	p.Parent = parent
	return p
end

-- Upright cylinder whose bottom face is centered on `bottom`.
function Geometry.column(
	parent: Instance,
	bottom: CFrame,
	height: number,
	diameter: number,
	color: Color3,
	options: PartOptions?
): Part
	return Geometry.part(
		parent,
		"Cylinder",
		bottom * CFrame.new(0, height / 2, 0) * UPRIGHT,
		Vector3.new(height, diameter, diameter),
		color,
		options
	)
end

-- Orientation whose UpVector is `up`, for laying spots and coins flat against a curved surface.
function Geometry.withUp(position: Vector3, up: Vector3): CFrame
	local u = up.Unit
	local helper = if math.abs(u.Y) > 0.95 then Vector3.xAxis else Vector3.yAxis
	local right = helper:Cross(u).Unit
	return CFrame.fromMatrix(position, right, u)
end

-- Point on an axis-aligned ellipsoid (semi-axes a, b, a) at polar angle theta from the top
-- and azimuth phi, plus the outward surface normal there.
function Geometry.ellipsoidPoint(a: number, b: number, theta: number, phi: number): (Vector3, Vector3)
	local sinT, cosT = math.sin(theta), math.cos(theta)
	local point = Vector3.new(a * sinT * math.cos(phi), b * cosT, a * sinT * math.sin(phi))
	local normal = Vector3.new(point.X / (a * a), point.Y / (b * b), point.Z / (a * a)).Unit
	return point, normal
end

-- Nudges a color's brightness (and a little saturation) so repeated props don't look cloned.
function Geometry.shade(color: Color3, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.clamp(s - amount * 0.25, 0, 1), math.clamp(v + amount, 0, 1))
end

-- Model container for one prop; its pivot sits on the ground where the prop was placed.
function Geometry.model(name: string, parent: Instance, pivot: CFrame): Model
	local m = Instance.new("Model")
	m.Name = name
	m.WorldPivot = pivot
	m.Parent = parent
	return m
end

function Geometry.light(parent: Instance, color: Color3, range: number, brightness: number): PointLight
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Shadows = false
	light.Parent = parent
	return light
end

return Geometry

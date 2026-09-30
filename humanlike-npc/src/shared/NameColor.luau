--!strict
-- The classic 8-colour chat name hash, identical to the legacy Chat module's GetNameColor, so an NPC's name gets
-- exactly the colour a real player with that name would get. Keyed on the username (Player.Name; for NPCs the
-- character Model's name), never on the display name. Pure and total over any string. It is not a palette for
-- anything else and it does not decide which colour the live chat finally shows (the client display prefers a
-- colour it observed on a real message for the same name).
-- requires: nothing

local NameColor = {}

local COLORS: { Color3 } = {
	Color3.fromRGB(253, 41, 67), -- Bright red
	Color3.fromRGB(1, 162, 255), -- Bright blue
	Color3.fromRGB(2, 184, 87), -- Earth green
	BrickColor.new("Bright violet").Color,
	BrickColor.new("Bright orange").Color,
	BrickColor.new("Bright yellow").Color,
	BrickColor.new("Light reddish violet").Color,
	BrickColor.new("Brick yellow").Color,
}
NameColor.COLORS = COLORS

-- The legacy algorithm, copied exactly: a signed sum of the bytes with the sign flipped on two of every four
-- positions counted from the end (shifted by one for odd lengths), modulo 8.
function NameColor.value(name: string): number
	local value = 0
	local length = #name
	for i = 1, length do
		local c = string.byte(name, i)
		local rev = length - i + 1
		if length % 2 == 1 then
			rev -= 1
		end
		if rev % 4 >= 2 then
			c = -c
		end
		value += c
	end
	return value
end

function NameColor.index(name: string): number
	return (NameColor.value(name) % 8) + 1
end

function NameColor.of(name: string): Color3
	return COLORS[NameColor.index(name)]
end

return NameColor

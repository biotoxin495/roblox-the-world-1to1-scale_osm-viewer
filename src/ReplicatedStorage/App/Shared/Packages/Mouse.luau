local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerMouse = LocalPlayer:GetMouse()

local Mouse = {}
Mouse.__index = Mouse
Mouse.Name = "Mouse"

local mouseIcons = {
	Normal = "",
	Action = "rbxasset://textures\\Cursors\\KeyboardMouse\\ArrowCursor.png",
	DragInactive = "rbxasset://textures\\Cursors\\DragDetector\\HoverCursor.png",
	DragActive = "rbxasset://textures\\Cursors\\DragDetector\\ActivatedCursor.png",
}

function Mouse.ChangeMouseIcon(icon: string)
	local icon = mouseIcons[icon]
	if icon then
		PlayerMouse.Icon = icon
	else
		warn("Mouse icon not found: " .. tostring(icon))
	end
end

return Mouse

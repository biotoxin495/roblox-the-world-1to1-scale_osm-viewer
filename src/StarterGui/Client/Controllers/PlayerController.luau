local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local PlayerController = {}
PlayerController.__index = PlayerController
PlayerController.Name = "PlayerController"

function PlayerController:Start()
	LocalPlayer.CameraMinZoomDistance = 20
end

return PlayerController

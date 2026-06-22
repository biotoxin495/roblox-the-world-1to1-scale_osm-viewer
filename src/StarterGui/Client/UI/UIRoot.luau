--!strict

local Players = game:GetService("Players")

local UIRoot = {}

function UIRoot.GetMainUI()
	local player = Players.LocalPlayer
	local playerGui = player.PlayerGui
	local mainUI = playerGui:WaitForChild("MainUI")
	return mainUI
end

function UIRoot.GetScreens()
	local mainUI = UIRoot.GetMainUI()
	local screens = mainUI:WaitForChild("Screens")
	return screens
end

function UIRoot.GetPopups()
	local mainUI = UIRoot.GetMainUI()
	local popups = mainUI:WaitForChild("Popups")
	return popups
end

return UIRoot

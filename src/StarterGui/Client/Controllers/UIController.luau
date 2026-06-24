local UIRoot = require(script.Parent.Parent.UI.UIRoot)
local GuiButtonEffects = require(script.Parent.Parent.ClientPackages.GuiButtonEffects)

local UIController = {}
-- UIController.__index = UIController
UIController.Name = "UIController"
UIController.Priority = 20

local DEFAULT_SCREEN = "ConfirmSpawnInfo"
local currentScreen: string? = nil
local currentPopup: string? = nil

function UIController:ChangePopupOpenBackground(isOpen)
	local effectsTable = {
		self = {
			BackgroundTransparency = isOpen and 0.7 or 1,
		},
	}
	GuiButtonEffects:DoEffectsOnGuiObject(UIRoot.GetPopups(), effectsTable)
end

function UIController:ChangePopupOpen(isOpen, popupName)
	local popupFrame = UIRoot.GetPopups()[popupName]

	local goal = {
		self = {
			Position = isOpen and UDim2.fromScale(0.5, 0.5) or UDim2.fromScale(0.5, -0.1),
			AnchorPoint = isOpen and Vector2.new(0.5, 0.5) or Vector2.new(0.5, 1),
			Visible = isOpen,
		},
	}
	GuiButtonEffects:DoEffectsOnGuiObject(popupFrame, goal)
end

function UIController:OpenPopup(popupName, parseData)
	local popupModuleScript = script.Parent.Parent.UI.Popups:FindFirstChild(popupName .. ".Popup")
	if not popupModuleScript or not popupModuleScript:IsA("ModuleScript") then
		warn("Popup module not found: " .. tostring(popupName))
		return
	end

	local popupModule = require(popupModuleScript)
	if not popupModule.StartFunctions then
		warn("Popup module has no StartFunctions method: " .. tostring(popupName))
		return
	end

	currentPopup = popupName
	self:ChangePopupOpenBackground(true)
	self:ChangePopupOpen(true, popupName)
	popupModule:StartFunctions(parseData)
end

function UIController:ClosePopup(parseData)
	local closingPopupName = currentPopup
	if not closingPopupName then
		return
	end

	self:ChangePopupOpenBackground(false)
	self:ChangePopupOpen(false, closingPopupName)
	currentPopup = nil

	local popupModuleScript = script.Parent.Parent.UI.Popups:FindFirstChild(closingPopupName .. ".Popup")
	if popupModuleScript and popupModuleScript:IsA("ModuleScript") then
		local popupModule = require(popupModuleScript)
		if popupModule.StopFunctions then
			popupModule:StopFunctions(parseData)
		end
	else
		warn("Popup module not found: " .. tostring(closingPopupName))
	end
end

function UIController:CloseAllPopups()
	currentPopup = nil
	self:ChangePopupOpenBackground(false)

	for _, popupFrame in ipairs(UIRoot.GetPopups():GetChildren()) do
		if popupFrame:IsA("GuiObject") then
			self:ChangePopupOpen(false, popupFrame.Name)
		end
	end
end

function UIController:IsPopupOpen(): boolean
	return currentPopup ~= nil
end

function UIController:ChangeScreenOpen(isOpen, screenName)
	local screenFrame = UIRoot.GetScreens():FindFirstChild(screenName)
	if not screenFrame or not screenFrame:IsA("GuiObject") then
		warn("Screen frame not found: " .. tostring(screenName))
		return
	end

	local goal = {
		self = {
			Position = isOpen and UDim2.fromScale(0.5, 0.5) or UDim2.fromScale(0.5, -0.1),
			AnchorPoint = isOpen and Vector2.new(0.5, 0.5) or Vector2.new(0.5, 1),
			Visible = isOpen,
		},
	}
	GuiButtonEffects:DoEffectsOnGuiObject(screenFrame, goal)
end

function UIController:OpenScreen(screenName, parseData)
	local screenModuleScript = script.Parent.Parent.UI.Screens:FindFirstChild(screenName .. ".Screen")
	if not screenModuleScript or not screenModuleScript:IsA("ModuleScript") then
		warn("Screen module not found: " .. tostring(screenName))
		return
	end

	local screenModule = require(screenModuleScript)
	if not screenModule.StartFunctions then
		warn("Screen module has no StartFunctions method: " .. tostring(screenName))
		return
	end

	if currentScreen then
		self:CloseScreen()
	end

	print("Screen changed to:", screenName)
	currentScreen = screenName
	self:ChangeScreenOpen(true, screenName)
	screenModule:StartFunctions(parseData)
end

function UIController:CloseScreen(parseData)
	local closingScreenName = currentScreen
	if not closingScreenName then
		return
	end

	self:ChangeScreenOpen(false, closingScreenName)
	currentScreen = nil

	local screenModuleScript = script.Parent.Parent.UI.Screens:FindFirstChild(closingScreenName .. ".Screen")
	if screenModuleScript and screenModuleScript:IsA("ModuleScript") then
		local screenModule = require(screenModuleScript)
		if screenModule.StopFunctions then
			screenModule:StopFunctions(parseData)
		end
	else
		warn("Screen module not found: " .. tostring(closingScreenName))
	end
end

function UIController:CloseAllScreens()
	currentScreen = nil

	for _, screenFrame in ipairs(UIRoot.GetScreens():GetChildren()) do
		if screenFrame:IsA("GuiObject") then
			self:ChangeScreenOpen(false, screenFrame.Name)
		end
	end
end

function UIController:Init()
	print("UIController Init")
end

function UIController:Start()
	print("UIController Start")
	self:CloseAllPopups()
	self:CloseAllScreens()
	self:OpenScreen(DEFAULT_SCREEN)
end

return UIController

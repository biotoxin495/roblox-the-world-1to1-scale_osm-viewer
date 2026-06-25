local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UIRoot = require(script.Parent.Parent.UI.UIRoot)
local GuiButtonEffects = require(script.Parent.Parent.ClientPackages.GuiButtonEffects)

local DEFAULT_SCREEN = "PickSpawn"

local STARTUP_INTRO_LINES = {
	"The World",
	"1:1 Scale",
}

local LOADING_PROP_IMAGES = {
	"rbxassetid://73360772685537",
	"rbxassetid://76573692987480",
	"rbxassetid://72880080734833",
}

local LOADING_PROP_ENTRY_STAGGER_SECONDS = 0.25
local LOADING_PROP_TWEEN_SECONDS = 0.5
local LOADING_PROP_HOLD_SECONDS = 0.3
local LOADING_PROP_HIDDEN_STATE = {
	rotation = -45,
	transparency = 1,
	positionYScale = -0.5,
}
local LOADING_PROP_VISIBLE_STATE = {
	rotation = 0,
	transparency = 0,
	positionYScale = 0,
}
local LOADING_PROP_EXIT_STATE = {
	rotation = 45,
	transparency = 1,
	positionYScale = -0.5,
}
local LOADING_PROP_EXIT_SEQUENCE_START = (#LOADING_PROP_IMAGES * LOADING_PROP_ENTRY_STAGGER_SECONDS)
	+ LOADING_PROP_HOLD_SECONDS
local LOADING_PROP_LAST_EXIT_END = LOADING_PROP_EXIT_SEQUENCE_START
	+ ((#LOADING_PROP_IMAGES - 1) * LOADING_PROP_ENTRY_STAGGER_SECONDS)
	+ LOADING_PROP_TWEEN_SECONDS
local LOADING_PROP_LOOP_RESET_SECONDS = LOADING_PROP_EXIT_SEQUENCE_START
	+ (#LOADING_PROP_IMAGES * LOADING_PROP_ENTRY_STAGGER_SECONDS)
	+ LOADING_PROP_HOLD_SECONDS
local LOADING_PROP_CYCLE_SECONDS = math.max(LOADING_PROP_LAST_EXIT_END, LOADING_PROP_LOOP_RESET_SECONDS)
local STARTUP_CONTENT_TWEEN_SECONDS = 0.45
local STARTUP_MIN_LOADING_SECONDS = 2
local STARTUP_INTRO_HOLD_SECONDS = 1.35
local STARTUP_MESSAGE_DOT_STATES = {
	".",
	"..",
	"...",
}

local STARTUP_PHASE_TARGETS = {
	loading = {
		overlayTransparency = 0,
		loadingTransparency = 0,
		loadingYOffset = 0,
		loadingScale = 1,
		introTransparency = 1,
		introYOffset = 0.03,
		introScale = 0.98,
	},
	loading_out = {
		overlayTransparency = 0,
		loadingTransparency = 1,
		loadingYOffset = -0.03,
		loadingScale = 0.985,
		introTransparency = 1,
		introYOffset = 0.03,
		introScale = 0.98,
	},
	intro = {
		overlayTransparency = 0,
		loadingTransparency = 1,
		loadingYOffset = -0.03,
		loadingScale = 0.985,
		introTransparency = 0,
		introYOffset = 0,
		introScale = 1,
	},
	intro_out = {
		overlayTransparency = 0,
		loadingTransparency = 1,
		loadingYOffset = -0.03,
		loadingScale = 0.985,
		introTransparency = 1,
		introYOffset = -0.03,
		introScale = 1.015,
	},
	handoff = {
		overlayTransparency = 1,
		loadingTransparency = 1,
		loadingYOffset = -0.03,
		loadingScale = 0.985,
		introTransparency = 1,
		introYOffset = -0.03,
		introScale = 1.015,
	},
}

local UIController = {}
-- UIController.__index = UIController
UIController.Name = "UIController"
UIController.Priority = 20

local currentScreen: string? = nil
local currentPopup: string? = nil
local startupLoadingGeneration = 0

local function easeOutQuad(alpha)
	return 1 - ((1 - alpha) * (1 - alpha))
end

local function lerp(fromValue, toValue, alpha)
	return fromValue + ((toValue - fromValue) * alpha)
end

local function interpolateLoadingPropState(fromState, toState, alpha)
	local eased = easeOutQuad(alpha)

	return {
		rotation = lerp(fromState.rotation, toState.rotation, eased),
		transparency = lerp(fromState.transparency, toState.transparency, eased),
		positionYScale = lerp(fromState.positionYScale, toState.positionYScale, eased),
	}
end

local function getLoadingPropStateAtTime(index, timeInCycle)
	local entryStart = (index - 1) * LOADING_PROP_ENTRY_STAGGER_SECONDS
	local entryEnd = entryStart + LOADING_PROP_TWEEN_SECONDS
	local exitStart = LOADING_PROP_EXIT_SEQUENCE_START + ((index - 1) * LOADING_PROP_ENTRY_STAGGER_SECONDS)
	local exitEnd = exitStart + LOADING_PROP_TWEEN_SECONDS

	if timeInCycle < entryStart then
		return LOADING_PROP_HIDDEN_STATE
	end

	if timeInCycle < entryEnd then
		return interpolateLoadingPropState(
			LOADING_PROP_HIDDEN_STATE,
			LOADING_PROP_VISIBLE_STATE,
			(timeInCycle - entryStart) / LOADING_PROP_TWEEN_SECONDS
		)
	end

	if timeInCycle < exitStart then
		return LOADING_PROP_VISIBLE_STATE
	end

	if timeInCycle < exitEnd then
		return interpolateLoadingPropState(
			LOADING_PROP_VISIBLE_STATE,
			LOADING_PROP_EXIT_STATE,
			(timeInCycle - exitStart) / LOADING_PROP_TWEEN_SECONDS
		)
	end

	return LOADING_PROP_EXIT_STATE
end

local function setInstanceProperties(instance, properties)
	for property, value in pairs(properties) do
		instance[property] = value
	end

	return instance
end

local function createInstance(className, properties, parent)
	local instance = Instance.new(className)
	setInstanceProperties(instance, properties)
	instance.Parent = parent
	return instance
end

local function createTextStroke(parent, thickness)
	return createInstance("UIStroke", {
		Color = Color3.fromRGB(27, 27, 27),
		Thickness = thickness,
	}, parent)
end

local function createStartupLoadingGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local existingLoadingGui = playerGui:FindFirstChild("StartupLoadingScreen")
	if existingLoadingGui then
		existingLoadingGui:Destroy()
	end

	local screenGui = createInstance("ScreenGui", {
		Name = "StartupLoadingScreen",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 10000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	local root = createInstance("Frame", {
		Name = "Screen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(12, 12, 16),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
	}, screenGui)

	local loadingContent = createInstance("CanvasGroup", {
		Name = "LoadingContent",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		GroupTransparency = 0,
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
	}, root)
	local loadingScale = createInstance("UIScale", {
		Scale = 1,
	}, loadingContent)

	local bottomLoadingProps = createInstance("Frame", {
		Name = "BottomLoadingProps",
		Size = UDim2.fromScale(0.7, 0.18),
		Position = UDim2.fromScale(0.5, 0.96),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
	}, loadingContent)
	createInstance("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, bottomLoadingProps)

	local loadingPropImages = {}
	for index, image in ipairs(LOADING_PROP_IMAGES) do
		local propFrame = createInstance("Frame", {
			Name = "LoadingProp" .. tostring(index),
			Size = UDim2.fromScale(0.4, 1),
			BackgroundTransparency = 1,
			LayoutOrder = index,
		}, bottomLoadingProps)
		createInstance("UIAspectRatioConstraint", {
			AspectRatio = 1,
		}, propFrame)

		local imageLabel = createInstance("ImageLabel", {
			Name = "Image",
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromScale(0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Image = image,
			Rotation = LOADING_PROP_HIDDEN_STATE.rotation,
			ImageTransparency = LOADING_PROP_HIDDEN_STATE.transparency,
			ImageColor3 = Color3.fromRGB(255, 255, 255),
		}, propFrame)
		createInstance("UIAspectRatioConstraint", {
			AspectRatio = 1,
		}, imageLabel)
		table.insert(loadingPropImages, imageLabel)
	end

	local loadingTitle = createInstance("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0.15, 0),
		BackgroundTransparency = 1,
		Text = "Loading...",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextScaled = true,
		Font = Enum.Font.GothamBold,
	}, loadingContent)
	createTextStroke(loadingTitle, 4)

	local introContent = createInstance("CanvasGroup", {
		Name = "IntroContent",
		Size = UDim2.fromScale(0.8, 0.38),
		Position = UDim2.fromScale(0.5, 0.53),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
	}, root)
	local introScale = createInstance("UIScale", {
		Scale = 0.98,
	}, introContent)
	createInstance("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 4),
	}, introContent)

	local introLinesFrame = createInstance("Frame", {
		Name = "IntroLines",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, introContent)
	createInstance("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 2),
	}, introLinesFrame)
	createInstance("UIStroke", {
		Color = Color3.fromRGB(255, 255, 255),
		Transparency = 0.65,
		Thickness = 1.2,
	}, introLinesFrame)
	createInstance("UIPadding", {
		PaddingLeft = UDim.new(0, 24),
		PaddingRight = UDim.new(0, 24),
	}, introLinesFrame)

	for index, line in ipairs(STARTUP_INTRO_LINES) do
		local introLine = createInstance("TextLabel", {
			Name = "Line" .. tostring(index),
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0.37, 0),
			LayoutOrder = index,
			Text = line,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			Font = if index == 1 then Enum.Font.GothamBlack else Enum.Font.GothamBold,
		}, introLinesFrame)
		createTextStroke(introLine, 4)
	end

	return screenGui,
		{
			root = root,
			loadingContent = loadingContent,
			loadingScale = loadingScale,
			loadingTitle = loadingTitle,
			loadingPropImages = loadingPropImages,
			introContent = introContent,
			introScale = introScale,
		}
end

local function tweenStartupPhase(refs, phaseName, duration)
	local targets = STARTUP_PHASE_TARGETS[phaseName]
	if not targets then
		return
	end

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tweens = {
		TweenService:Create(refs.root, tweenInfo, {
			BackgroundTransparency = targets.overlayTransparency,
		}),
		TweenService:Create(refs.loadingContent, tweenInfo, {
			GroupTransparency = targets.loadingTransparency,
			Position = UDim2.fromScale(0.5, 0.5 + targets.loadingYOffset),
		}),
		TweenService:Create(refs.loadingScale, tweenInfo, {
			Scale = targets.loadingScale,
		}),
		TweenService:Create(refs.introContent, tweenInfo, {
			GroupTransparency = targets.introTransparency,
			Position = UDim2.fromScale(0.5, 0.5 + targets.introYOffset),
		}),
		TweenService:Create(refs.introScale, tweenInfo, {
			Scale = targets.introScale,
		}),
	}

	for _, tween in ipairs(tweens) do
		tween:Play()
	end

	task.wait(duration)

	for _, tween in ipairs(tweens) do
		tween:Destroy()
	end
end

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

function UIController:RunStartupLoadingScreen(onBeforeHandoff)
	startupLoadingGeneration += 1
	local generation = startupLoadingGeneration
	local screenGui, refs = createStartupLoadingGui()
	local cycleStartTime = os.clock()

	local propConnection = RunService.RenderStepped:Connect(function()
		if generation ~= startupLoadingGeneration then
			return
		end

		local timeInCycle = (os.clock() - cycleStartTime) % LOADING_PROP_CYCLE_SECONDS
		for index, imageLabel in ipairs(refs.loadingPropImages) do
			local state = getLoadingPropStateAtTime(index, timeInCycle)
			imageLabel.Position = UDim2.fromScale(0.5, 0.5 + state.positionYScale)
			imageLabel.Rotation = state.rotation
			imageLabel.ImageTransparency = state.transparency
		end
	end)

	local dotsTask = task.spawn(function()
		local index = 1

		while generation == startupLoadingGeneration and screenGui.Parent do
			refs.loadingTitle.Text = "Loading" .. STARTUP_MESSAGE_DOT_STATES[index]

			index += 1
			if index > #STARTUP_MESSAGE_DOT_STATES then
				index = 1
			end

			task.wait(0.45)
		end
	end)

	tweenStartupPhase(refs, "loading", STARTUP_CONTENT_TWEEN_SECONDS)

	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	task.wait(STARTUP_MIN_LOADING_SECONDS)
	tweenStartupPhase(refs, "loading_out", STARTUP_CONTENT_TWEEN_SECONDS)
	tweenStartupPhase(refs, "intro", STARTUP_CONTENT_TWEEN_SECONDS)
	task.wait(STARTUP_INTRO_HOLD_SECONDS)
	tweenStartupPhase(refs, "intro_out", STARTUP_CONTENT_TWEEN_SECONDS)

	local callbackOk = true
	local callbackError = nil
	if onBeforeHandoff then
		callbackOk, callbackError = pcall(onBeforeHandoff)
	end

	tweenStartupPhase(refs, "handoff", STARTUP_CONTENT_TWEEN_SECONDS)

	startupLoadingGeneration += 1
	if propConnection then
		propConnection:Disconnect()
	end
	if dotsTask then
		task.cancel(dotsTask)
	end
	screenGui:Destroy()

	if not callbackOk then
		error(callbackError, 0)
	end
end

function UIController:Init() end

function UIController:Start()
	self:CloseAllPopups()
	self:CloseAllScreens()

	local openedDefaultScreen = false
	local ok, errorValue = pcall(function()
		self:RunStartupLoadingScreen(function()
			self:OpenScreen(DEFAULT_SCREEN)
			openedDefaultScreen = true
		end)
	end)

	if not ok then
		warn(string.format("Startup loading screen failed: %s", tostring(errorValue)))
	end

	if not openedDefaultScreen then
		self:OpenScreen(DEFAULT_SCREEN)
	end
end

return UIController

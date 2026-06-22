local TweenService = game:GetService("TweenService")

local GuiButtonEffects = {}

local DEBUG_TRACKING = false
local DUMP_INTERVAL_SECONDS = 5

-- Internal storage for each button's effect data
local activeButtonsData = {} -- [GuiButton] = { effectsTable, tweenInfo, originalProperties, connections, isHovered, isPressed, isEnabled }
local trackedSince = {} -- [GuiButton] = time()
local dumpLoopStarted = false

-- PRIVATE HELPER FUNCTIONS --

local function applyProperties(buttonData, object, props)
	buttonData.activeTweens = buttonData.activeTweens or {}

	local tween = TweenService:Create(object, buttonData.tweenInfo, props)
	buttonData.activeTweens[object] = tween
	tween:Play()
	tween:Destroy()
end

local function updateVisuals(button)
	local buttonData = activeButtonsData[button]
	if not buttonData or not buttonData.isEnabled then
		return
	end
	-- Check MouseEffectsActive attribute
	local mouseEffectsActive = button:GetAttribute("MouseEffectsActive")
	if mouseEffectsActive ~= nil and mouseEffectsActive == false then
		return
	end

	local targetEffects = {}
	if buttonData.isPressed then
		targetEffects = buttonData.effectsTable.OnClickStart or buttonData.effectsTable.OnMouseEnter or {}
	elseif buttonData.isHovered then
		targetEffects = buttonData.effectsTable.OnMouseEnter or {}
	else
		targetEffects = buttonData.effectsTable.OnMouseLeave or {} -- Revert state
	end

	for objectName, _ in pairs(buttonData.originalPropertiesLookup) do
		local objectInstance
		if objectName == "self" then
			objectInstance = button
		elseif typeof(objectName) == "Instance" then
			objectInstance = objectName
		else
			objectInstance = button:FindFirstChild(objectName, true)
		end

		if not objectInstance then
			continue
		end

		local desiredProps = targetEffects[objectName] or buttonData.originalProperties[objectInstance]
		if desiredProps then
			applyProperties(buttonData, objectInstance, desiredProps)
		end
	end
end

local function getTrackedCount()
	local count = 0
	for _ in pairs(activeButtonsData) do
		count += 1
	end
	return count
end

local function dumpTracked()
	if not DEBUG_TRACKING then
		return
	end

	local count = getTrackedCount()
	print("GuiButtonEffects: tracked dump start", "total:", count)
	for button, _ in pairs(activeButtonsData) do
		local since = trackedSince[button]
		local age = since and (time() - since) or 0
		print("GuiButtonEffects: tracked", button, "ageSeconds:", math.floor(age))
	end
	print("GuiButtonEffects: tracked dump end")
end

local function ensureDumpLoop()
	if dumpLoopStarted then
		return
	end

	dumpLoopStarted = true
	task.spawn(function()
		while true do
			task.wait(DUMP_INTERVAL_SECONDS)
			dumpTracked()
		end
	end)
end

-- PUBLIC API --

--- Sets up mouse interaction effects for a GuiButton.
-- @param button GuiButton - The button instance to apply effects to.
-- @param effectsTable table - Defines the visual changes for different states.
-- @param tweenInfo TweenInfo? - Optional TweenInfo for the animations.

type ButtonEffectProps = { [string]: any }
type ButtonEffectTargets = { [any]: ButtonEffectProps }
type ButtonEffectsTable = {
	OnMouseEnter: ButtonEffectTargets?,
	OnMouseLeave: ButtonEffectTargets?,
	OnClickStart: ButtonEffectTargets?,
	OnClickEnd: ButtonEffectTargets?,
}

local templates = {
	CloseButton = {
		OnMouseEnter = {
			self = { BackgroundTransparency = 0.85, Rotation = 9 },
			CloseIcon = { ImageColor3 = Color3.fromRGB(255, 41, 41) },
		},
		OnMouseLeave = {
			self = { BackgroundTransparency = 1, Rotation = 0 },
			CloseIcon = { ImageColor3 = Color3.fromRGB(255, 0, 0) },
		},
		OnClickStart = {
			self = { BackgroundTransparency = 0.92 },
		},
	},

	GreenButton = {
		OnMouseEnter = {
			self = { BackgroundColor3 = Color3.fromRGB(71, 255, 83):Lerp(Color3.fromRGB(0, 0, 0), 0.2) },
		},
		OnClickStart = {
			TextLabel = { TextColor3 = Color3.fromRGB(209, 209, 209) },
		},
	},
	RedButton = {
		OnMouseEnter = {
			self = { BackgroundColor3 = Color3.fromRGB(249, 69, 69):Lerp(Color3.fromRGB(0, 0, 0), 0.2) },
		},
		OnClickStart = {
			TextLabel = { TextColor3 = Color3.fromRGB(209, 209, 209) },
		},
	},
	OrangeButton = {
		OnMouseEnter = {
			self = { BackgroundColor3 = Color3.fromRGB(255, 170, 0):Lerp(Color3.fromRGB(0, 0, 0), 0.2) },
		},
		OnClickStart = {
			TextLabel = { TextColor3 = Color3.fromRGB(209, 209, 209) },
		},
	},
	CashbackButton = {
		OnMouseEnter = {
			self = { BackgroundColor3 = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(0, 0, 0), 0.2) },
		},
		OnClickStart = {
			CashbackTitle = { TextColor3 = Color3.fromRGB(209, 209, 209) },
		},
	},
	ArrowButton = {
		OnMouseEnter = {
			self = { BackgroundColor3 = Color3.fromRGB(43, 87, 126) },
		},
		OnClickStart = {
			TextLabel = { TextColor3 = Color3.fromRGB(185, 185, 185) },
		},
	},
}

function GuiButtonEffects:Setup(
	button: GuiButton,
	effectsTable: ButtonEffectsTable,
	tweenInfo: TweenInfo?,
	mouseoverFunct,
	mouseClearFunct
)
	if activeButtonsData[button] then
		-- warn("GuiButtonEffects: Effects already set up for this button. Clearing existing first.")
		GuiButtonEffects:Clear(button)
	end

	local data = {
		effectsTable = effectsTable,
		tweenInfo = tweenInfo or TweenInfo.new(0.15),
		originalProperties = {},
		originalPropertiesLookup = {}, -- To know which objects/props to iterate
		connections = {},
		isHovered = false,
		isPressed = false,
		isEnabled = true,
		activeTweens = {},
	}
	activeButtonsData[button] = data
	trackedSince[button] = time()
	ensureDumpLoop()
	if DEBUG_TRACKING then
		print("GuiButtonEffects: tracking added", button, "total:", getTrackedCount())
	end

	-- Store original properties
	local allPossibleEffectedObjects = {}
	for objName, _ in pairs(effectsTable.OnMouseEnter or {}) do
		allPossibleEffectedObjects[objName] = true
	end
	for objName, _ in pairs(effectsTable.OnMouseLeave or {}) do
		allPossibleEffectedObjects[objName] = true
	end
	for objName, _ in pairs(effectsTable.OnClickStart or {}) do
		allPossibleEffectedObjects[objName] = true
	end
	for objName, _ in pairs(effectsTable.OnClickEnd or {}) do
		allPossibleEffectedObjects[objName] = true
	end

	for objectName, _ in pairs(allPossibleEffectedObjects) do
		local objectInstance
		if objectName == "self" then
			objectInstance = button
		elseif typeof(objectName) == "Instance" then
			objectInstance = objectName
		else
			objectInstance = button:FindFirstChild(objectName, true)
		end

		if objectInstance then
			data.originalProperties[objectInstance] = {}
			data.originalPropertiesLookup[objectName] = true -- Mark this object name for iteration

			local propsToStore = (effectsTable.OnClickStart and effectsTable.OnClickStart[objectName])
				or (effectsTable.OnMouseEnter and effectsTable.OnMouseEnter[objectName])
				or {}
			for prop, _ in pairs(propsToStore) do
				data.originalProperties[objectInstance][prop] = objectInstance[prop]
			end
		end
	end

	-- Connect events
	data.connections.MouseEnter = button.MouseEnter:Connect(function()
		if not data.isEnabled then
			return
		end
		local mouseEffectsActive = button:GetAttribute("MouseEffectsActive")
		if mouseEffectsActive ~= nil and mouseEffectsActive == false then
			return
		end
		data.isHovered = true
		updateVisuals(button)
		if mouseoverFunct then
			mouseoverFunct()
		end
	end)

	data.connections.MouseLeave = button.MouseLeave:Connect(function()
		if not data.isEnabled then
			return
		end
		local mouseEffectsActive = button:GetAttribute("MouseEffectsActive")
		if mouseEffectsActive ~= nil and mouseEffectsActive == false then
			return
		end
		data.isHovered = false
		data.isPressed = false -- Also reset pressed state on leave
		updateVisuals(button)
		if mouseClearFunct then
			mouseClearFunct()
		end
	end)

	if effectsTable.OnClickStart or effectsTable.OnClickEnd then
		data.connections.MouseButton1Down = button.MouseButton1Down:Connect(function()
			if not data.isEnabled then
				return
			end
			local mouseEffectsActive = button:GetAttribute("MouseEffectsActive")
			if mouseEffectsActive ~= nil and mouseEffectsActive == false then
				return
			end
			data.isPressed = true
			updateVisuals(button)
		end)

		data.connections.MouseButton1Up = button.MouseButton1Up:Connect(function()
			if not data.isEnabled then
				return
			end
			local mouseEffectsActive = button:GetAttribute("MouseEffectsActive")
			if mouseEffectsActive ~= nil and mouseEffectsActive == false then
				return
			end
			data.isPressed = false
			updateVisuals(button) -- Update to hover state or default if mouse also left
		end)
	end

	-- Connect to AncestryChanged to auto-clear if button is destroyed
	data.connections.AncestryChanged = button.AncestryChanged:Connect(function(_, parent)
		if not parent then
			GuiButtonEffects:Clear(button)
		end
	end)
end

function GuiButtonEffects:SetupFromTemplate(button: GuiButton, templateName: string, mouseOverFunct, mouseClearFunct)
	GuiButtonEffects:Setup(button, templates[templateName], TweenInfo.new(0.15), mouseOverFunct, mouseClearFunct)
end
function GuiButtonEffects:SetupSimpleMouseOverEffect(button: GuiButton, mouseOverFunct, mouseClearFunct)
	GuiButtonEffects:Setup(button, {
		OnMouseEnter = {
			self = { BackgroundColor3 = button.BackgroundColor3:Lerp(Color3.fromRGB(0, 0, 0), 0.2) },
		},
	}, TweenInfo.new(0.15), mouseOverFunct, mouseClearFunct)
end

--- Clears all effects, disconnects events, and reverts to original appearance.
function GuiButtonEffects:Clear(button: GuiButton)
	local buttonData = activeButtonsData[button]
	if not buttonData then
		return
	end

	-- Disconnect all events
	for _, conn in pairs(buttonData.connections) do
		conn:Disconnect()
	end

	-- Revert to original properties
	for objectInstance, props in pairs(buttonData.originalProperties) do
		if objectInstance and objectInstance.Parent then -- Check if instance still exists
			applyProperties(buttonData, objectInstance, props)
		end
	end

	activeButtonsData[button] = nil
	trackedSince[button] = nil
	if DEBUG_TRACKING then
		print("GuiButtonEffects: tracking removed", button, "total:", getTrackedCount())
	end
end

function GuiButtonEffects:DumpTracked()
	dumpTracked()
end

--- Temporarily enables or disables the effects for a button.
function GuiButtonEffects:SetEnabled(button: GuiButton, isEnabled: boolean)
	local buttonData = activeButtonsData[button]
	if not buttonData then
		return
	end

	if isEnabled then
		-- If disabling, immediately revert to original visuals
		buttonData.isHovered = false
		buttonData.isPressed = false
	end
	buttonData.isEnabled = isEnabled

	updateVisuals(button)
end

function GuiButtonEffects:DoEffectsOnGuiObject(guiObject: GuiObject, effectsTable: ButtonEffectTargets)
	for objectName, props in pairs(effectsTable) do
		local objectInstance
		if objectName == "self" then
			objectInstance = guiObject
		elseif typeof(objectName) == "Instance" then
			objectInstance = objectName
		else
			objectInstance = guiObject:FindFirstChild(objectName, true)
		end

		if objectInstance then
			applyProperties({ tweenInfo = TweenInfo.new(0.15) }, objectInstance, props)
		end
	end
end

return GuiButtonEffects

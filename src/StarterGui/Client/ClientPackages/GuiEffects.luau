local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local GuiEffects = {}
GuiEffects.__index = GuiEffects
GuiEffects.ServiceName = "GuiEffects"

local rayConns = {}
function GuiEffects:SetupRotatingRay(img: ImageLabel)
	img.Rotation = 0
	local goal = {}
	goal.Rotation = 180
	local tween =
		TweenService:Create(img, TweenInfo.new(5, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false), goal)
	tween:Play()
	rayConns[img] = tween
end
function GuiEffects:ClearRotatingRay(img)
	if rayConns[img] then
		img.Rotation = 0
		rayConns[img]:Pause()
		rayConns[img]:Destroy()
	end
end

local tapOffConns = {}
function GuiEffects:SetupTapOffForGui(frame: Frame, closedFunction, closedFunctArgs, mousePressConn: RBXScriptSignal)
	local timeOfSetup = os.clock()
	local mouseOverConn1 = frame.MouseEnter:Connect(function()
		frame:SetAttribute("mouseOver", true)
	end)
	local mouseOverConn2 = frame.MouseLeave:Connect(function()
		frame:SetAttribute("mouseOver", false)
	end)

	local function handleMousePress()
		local timeDiff = os.clock() - timeOfSetup
		if timeDiff < 0.5 then
			return
		end
		if not frame:GetAttribute("mouseOver") then
			closedFunction(closedFunctArgs)
		end
	end

	local currConn = mousePressConn:Connect(handleMousePress)

	tapOffConns[frame] = { mouseOverConn1, mouseOverConn2, currConn }

	return { mouseOverConn1, mouseOverConn2, currConn }
end

-- Function to clean up connections for a given frame
function GuiEffects:CleanupTapOff(frame: Frame)
	if tapOffConns[frame] then
		for _, conn in ipairs(tapOffConns[frame]) do
			if conn and conn.Disconnect then
				conn:Disconnect()
			end
		end
		tapOffConns[frame] = nil
	end
end

local rotatingConns = {}
function GuiEffects:SetupLoadingGui(img: ImageLabel)
	img.Rotation = 0
	local rotatingTween = TweenService:Create(
		img,
		TweenInfo.new(1.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1, false),
		{ Rotation = 360 }
	)
	rotatingTween:Play()
	rotatingConns[img] = rotatingTween
end
function GuiEffects:ClearLoadingGui(img: ImageLabel)
	if rotatingConns[img] then
		rotatingConns[img]:Destroy()
	end
end

function GuiEffects:ScaleToOffset(Scale, axis)
	local ViewPortSize = workspace.Camera.ViewportSize

	if axis == "X" then
		return ViewPortSize.X * Scale
	elseif axis == "Y" then
		return ViewPortSize.Y * Scale
	end
end
function GuiEffects.ScaleToOffsetSpecificScreenSize(Scale, screenSize, axis)
	local ViewPortSize = workspace.Camera.ViewportSize

	if axis == "X" then
		return screenSize * Scale
	elseif axis == "Y" then
		return screenSize * Scale
	end
end

function GuiEffects:OffsetToScale(Offset, axis)
	local ViewPortSize = workspace.Camera.ViewportSize

	if axis == "X" then
		return Offset / ViewPortSize.X
	elseif axis == "Y" then
		return Offset / ViewPortSize.Y
	end
end

local function makeCurrencyTextBounce(textLabel: TextLabel)
	local tween = TweenService:Create(
		textLabel,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, true),
		{ Size = UDim2.new(0.75, 0, 1.25, 0) }
	)
	tween:Play()
	tween:Destroy()
end

function GuiEffects:AdjustTextSize(textLabel, options)
	-- Validation
	if not textLabel or not textLabel:IsA("TextLabel") and not textLabel:IsA("TextButton") then
		warn("[AdjustTextSize] Invalid textLabel provided")
		return Vector2.new(0, 0)
	end

	options = options or {}
	local minWidth = options.minWidth or 10
	local maxWidth = options.maxWidth or math.huge
	local padding = options.padding or 0
	local maintainHeight = options.maintainHeight ~= false -- default true

	-- Store original properties
	local originalSize = textLabel.Size
	local originalAutoSize = textLabel.AutomaticSize

	-- Get text properties
	local text = textLabel.Text
	local fontSize = textLabel.TextSize
	local font = textLabel.Font

	-- If TextScaled is enabled, use the actual rendered size (AbsoluteSize.Y)
	if textLabel.TextScaled then
		fontSize = textLabel.AbsoluteSize.Y
	end

	-- Handle empty text case
	if text == "" or text == nil then
		local newWidth = math.max(minWidth, padding * 2)
		if maintainHeight then
			textLabel.Size = UDim2.new(0, newWidth, originalSize.Y.Scale, originalSize.Y.Offset)
		else
			textLabel.Size = UDim2.new(0, newWidth, 0, fontSize + padding)
		end
		return Vector2.new(newWidth, fontSize)
	end

	-- Use TextService for accurate measurement (non-deprecated method)
	local textSize = TextService:GetTextSize(text, fontSize, font, Vector2.new(maxWidth - padding * 2, math.huge))

	-- Apply padding and constraints
	local newWidth = math.clamp(textSize.X + padding * 2, minWidth, maxWidth)
	local newHeight = textSize.Y + padding

	-- Apply the new size
	if maintainHeight then
		textLabel.Size = UDim2.new(0, newWidth, originalSize.Y.Scale, originalSize.Y.Offset)
	else
		textLabel.Size = UDim2.new(0, newWidth, 0, newHeight)
	end

	return Vector2.new(newWidth, newHeight)
end

local currCountingUpTasks = {}
function GuiEffects:DoCountingUpEffectOnText(
	textLabel: TextLabel,
	val1,
	val2,
	formatResult,
	bounce,
	formatter,
	adjustTextSize
)
	if currCountingUpTasks[textLabel] then
		task.cancel(currCountingUpTasks[textLabel])
	end

	local currTask = task.spawn(function()
		local prevAmount = val1
		local currAmount = val2

		local diff = currAmount - prevAmount

		if bounce then
			makeCurrencyTextBounce(textLabel)
		end

		local steps
		if diff <= 50 then
			steps = diff
		else
			steps = 50
		end
		local countUp = diff / steps

		-- If the difference is large, increase the step size to speed up the counting
		if math.abs(diff) > 100 then
			steps = math.min(steps, math.abs(diff) / 2) -- Adjust the steps based on the difference
			countUp = diff / steps
		elseif math.abs(diff) > 1000 then
			steps = math.min(steps, math.abs(diff) / 5) -- Further adjust for very large differences
			countUp = diff / steps
		end

		for i = prevAmount, currAmount, countUp do
			i = math.round(i)
			local currFormatted
			if formatResult == true then
				if formatter then
					currFormatted = formatter:Format(i)
				end
			else
				currFormatted = i
			end

			textLabel.Text = currFormatted
			if adjustTextSize then
				local newSize = GuiEffects:AdjustTextSize(textLabel, {
					minWidth = 20,
					padding = 5,
					maintainHeight = true,
				})
				-- textLabel.Size = UDim2.new(0, newSize.X, 0, newSize.Y)
			end
			task.wait()
		end
		if bounce then
			makeCurrencyTextBounce(textLabel)
		end
		if formatResult == true then
			if formatter then
				textLabel.Text = formatter:Format(val2)
			end
		else
			textLabel.Text = val2
		end
		if adjustTextSize then
			local newSize = GuiEffects:AdjustTextSize(textLabel, {
				minWidth = 20,
				padding = 5,
				maintainHeight = true,
			})
			-- textLabel.Size = UDim2.new(0, newSize.X, 0, newSize.Y)
		end
	end)
	currCountingUpTasks[textLabel] = currTask
end

function GuiEffects:ChangeUIVisibility(frame: Frame, isVisible: boolean)
	local goal = {}

	if isVisible then
		goal.Position = frame:GetAttribute("openPos")
		goal.AnchorPoint = frame:GetAttribute("openAnchorPoint")
	else
		goal.Position = frame:GetAttribute("closedPos")
		goal.AnchorPoint = frame:GetAttribute("closedAnchorPoint")
	end
	goal.Visible = isVisible

	frame:SetAttribute("isOpen", isVisible)
	local tween = TweenService:Create(frame, TweenInfo.new(0.2, Enum.EasingStyle.Quad), goal)
	tween:Play()
	tween:Destroy()
end
function GuiEffects:ChangeUIVisibilityBasedOnSizeForUI(frame: Frame, isVisible: boolean, callbackFunction)
	local goal = {}
	local tweenTime = 0.15
	local easingStyle = Enum.EasingStyle.Quad

	if isVisible then
		goal.Visible = true
		goal.Size = frame:GetAttribute("openSize")
	else
		goal.Visible = false
		goal.Size = frame:GetAttribute("closedSize")
		tweenTime /= 2
	end

	frame:SetAttribute("isOpen", isVisible)
	local tween = TweenService:Create(frame, TweenInfo.new(tweenTime, easingStyle), goal)
	tween:Play()
	if callbackFunction then
		task.spawn(function()
			tween.Completed:Wait()
			callbackFunction()
			tween:Destroy()
		end)
	else
		tween:Destroy()
	end
end

function GuiEffects:SetupFlyInUI(uiHolder: Frame, timeForEveryEntry, startCountAt)
	if not timeForEveryEntry then
		timeForEveryEntry = 0.05
	end
	local count = startCountAt or 0
	for i, v in pairs(uiHolder:GetChildren()) do
		if not v:IsA("Frame") or v:IsA("TextButton") then
			continue
		end
		v.Visible = true
		v.Holder.Visible = false
		v.Holder.Position = UDim2.new(0.5, 0, 0, 0) -- Center it initially

		local tweenInfo =
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, count * timeForEveryEntry)
		local targetPos = UDim2.new(0.5, 0, 0.5, 0)
		local tween = TweenService:Create(v.Holder, tweenInfo, { Position = targetPos, Visible = true })
		tween:Play()
		tween:Destroy()
		count += 1
	end
end

return GuiEffects

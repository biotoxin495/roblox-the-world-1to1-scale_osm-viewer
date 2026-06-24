local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ICONS = {
	Challenge = { "http://www.roblox.com/asset/?id=16618010913", Color3.fromRGB(103, 240, 255) },
	Warning = { "http://www.roblox.com/asset/?id=18512366671", Color3.fromRGB(255, 255, 255) },
	Powerup = { "http://www.roblox.com/asset/?id=18516283451", Color3.fromRGB(255, 255, 255) },
	Coins = { "http://www.roblox.com/asset/?id=17090376183", Color3.fromRGB(255, 255, 255) },
	Sticks = { "http://www.roblox.com/asset/?id=18272920187", Color3.fromRGB(255, 255, 255) },
	ACoins = { "http://www.roblox.com/asset/?id=18718741756", Color3.fromRGB(255, 255, 255) },
	Reward = { "http://www.roblox.com/asset/?id=16648054267", Color3.fromRGB(255, 255, 255) },
	Info = { "", Color3.fromRGB(255, 255, 255) },
	Upgrade = { "http://www.roblox.com/asset/?id=97271518180438", Color3.fromRGB(255, 255, 255) },
	Gems = { "http://www.roblox.com/asset/?id=18512200409", Color3.fromRGB(255, 255, 255) },
	Codes = { "http://www.roblox.com/asset/?id=16612153579", Color3.fromRGB(255, 255, 255) },
	RewardTokens = { "http://www.roblox.com/asset/?id=103449909746008", Color3.fromRGB(255, 255, 255) },
	Sellers = { "http://www.roblox.com/asset/?id=85474660402487", Color3.new(1, 1, 1) },
	Potions = { "rbxassetid://17667405858", Color3.new(1, 1, 1) },
	Donation = { "rbxassetid://71318600295281", Color3.fromRGB(255, 255, 255) },
	Boosts = { "rbxassetid://104230535634501", Color3.new(1, 1, 1) },
	Success = { "", Color3.new(1, 1, 1) },
}

local NOTIFICATION_LIFETIME = 4 -- seconds
local ANIMATION_TIME = 0.2 -- seconds

local Notifications = {}
Notifications.__index = Notifications
Notifications.ServiceName = "Notifications"

local ActiveNotificationElements = nil
local NextNotificationId = 0

function Notifications:_cleanupActiveNotification(isTimeout)
	if not ActiveNotificationElements then
		return
	end

	local elements = ActiveNotificationElements
	ActiveNotificationElements = nil

	-- Cancel tweens
	if elements.Tweens then
		for _, tween in ipairs(elements.Tweens) do
			if tween then
				tween:Cancel()
			end
		end
	end
	elements.Tweens = {}

	-- Cancel timeout coroutine

	if not isTimeout then
		if elements.TimeoutCoroutine then
			task.cancel(elements.TimeoutCoroutine)
		end
	end

	-- Disconnect event connections
	if elements.Connections then
		for _, conn in ipairs(elements.Connections) do
			if conn then
				conn:Disconnect()
			end
		end
	end
	elements.Connections = {}

	-- Animate out
	local frame = elements.Frame
	if frame and frame.Parent then
		local targetYScale = -0.1 -- Above screen
		local tweenInfo = TweenInfo.new(ANIMATION_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		local goal = { Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, targetYScale, 0) }
		local outTween = TweenService:Create(frame, tweenInfo, goal)
		outTween.Completed:Connect(function()
			frame:Destroy()
		end)
		outTween:Play()
		table.insert(elements.Tweens, outTween) -- Add to local tweens to be safe, though it's short-lived
	elseif frame then
		frame:Destroy() -- If not parented, just destroy
	end
end

-- Utility function to clear all active notifications
function Notifications:ClearAllActiveNotifications()
	-- Clear any currently active notification
	self:_cleanupActiveNotification(false)
end

function Notifications:SendNotification(notificationData)
	NextNotificationId = NextNotificationId + 1
	local currentNotifId = NextNotificationId

	-- Cleanup any existing notification
	self:_cleanupActiveNotification(false)

	local iconInfo = ICONS[notificationData.Type] or {}
	local text = notificationData.Text or "Notification"
	local iconId = iconInfo[1] or "rbxassetid://18512366671" -- Default warning icon
	local iconColor = iconInfo[2] or Color3.fromRGB(255, 255, 255)
	local callback = notificationData.Callback
	-- local soundId = notificationData.Sound -- Sound not implemented in original Roact version's UI

	-- Create notification frame (TextButton for overall clickability)
	local notifFrame = Instance.new("TextButton")
	notifFrame.Name = "Notification"
	notifFrame.Size = UDim2.new(0.5, 0, 0.05, 0) -- Aspect ratio will control height
	notifFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	notifFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	notifFrame.BackgroundTransparency = 0.7
	notifFrame.BorderSizePixel = 0
	notifFrame.ZIndex = 10
	notifFrame.Text = "" -- No text on the main button
	notifFrame.AutoButtonColor = false
	notifFrame.Parent = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainUI") -- Ensure a dedicated GUI exists for notifications

	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0.15, 0)
	uiCorner.Parent = notifFrame

	local uiAspectRatio = Instance.new("UIAspectRatioConstraint")
	uiAspectRatio.AspectRatio = 14.534
	uiAspectRatio.Parent = notifFrame

	local uiListLayout = Instance.new("UIListLayout")
	uiListLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	uiListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	uiListLayout.FillDirection = Enum.FillDirection.Horizontal
	uiListLayout.Padding = UDim.new(0, 0)
	uiListLayout.Parent = notifFrame

	-- Icon
	local iconImage = Instance.new("ImageLabel")
	iconImage.Name = "Icon"
	iconImage.Image = iconId
	iconImage.ImageColor3 = iconColor
	iconImage.Size = UDim2.new(0.2, 0, 1, 0) -- Original Size
	iconImage.ScaleType = Enum.ScaleType.Fit
	iconImage.BackgroundTransparency = 1
	iconImage.Parent = notifFrame
	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.AspectRatio = 1
	iconAspect.Parent = iconImage

	-- Text
	local notifText = Instance.new("TextLabel")
	notifText.Name = "NotificationText"
	notifText.Text = text
	notifText.Font = Enum.Font.FredokaOne
	notifText.Size = UDim2.new(0.88, 0, 0.85, 0) -- Original Size
	notifText.TextXAlignment = Enum.TextXAlignment.Center
	notifText.TextYAlignment = Enum.TextYAlignment.Center
	notifText.TextWrapped = true
	notifText.TextScaled = true
	notifText.TextColor3 = Color3.fromRGB(255, 255, 255)
	notifText.BackgroundTransparency = 1
	notifText.TextStrokeTransparency = 0 -- For 'showStroke = true'
	notifText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	notifText.Parent = notifFrame

	local elements = {
		Frame = notifFrame,
		Tweens = {},
		Connections = {},
		TimeoutCoroutine = nil,
		Id = currentNotifId,
	}
	ActiveNotificationElements = elements

	-- Handle tap/click on the notification
	local tapConnection = notifFrame.Activated:Connect(function()
		if ActiveNotificationElements and ActiveNotificationElements.Id == currentNotifId then
			if callback and not notificationData.HasClaimButton then -- Only run callback if no dedicated claim button
				pcall(callback)
			end
			self:_cleanupActiveNotification() -- This will animate out and destroy
		end
	end)
	table.insert(elements.Connections, tapConnection)

	-- Conditionally render a button if a callback is provided and HasClaimButton is true or not specified
	if callback and (notificationData.HasClaimButton == nil or notificationData.HasClaimButton == true) then
		local claimButton = Instance.new("TextButton")
		claimButton.Name = "ActionButton"
		claimButton.Text = notificationData.ClaimButtonText or "Claim"
		claimButton.Size = UDim2.fromScale(0.3, 0.4) -- Original Size
		claimButton.Position = UDim2.fromScale(0.85, 0.5) -- Original Position, Y centered
		claimButton.AnchorPoint = Vector2.new(0.5, 0.5)
		claimButton.BackgroundColor3 = Color3.fromRGB(80, 180, 80)
		claimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		claimButton.TextScaled = true
		claimButton.Parent = notifFrame
		local claimCorner = Instance.new("UICorner")
		claimCorner.CornerRadius = UDim.new(0.3, 0)
		claimCorner.Parent = claimButton

		local claimTapConnection = claimButton.Activated:Connect(function()
			if ActiveNotificationElements and ActiveNotificationElements.Id == currentNotifId then
				pcall(callback)
				self:_cleanupActiveNotification()
			end
		end)
		table.insert(elements.Connections, claimTapConnection)
	end

	-- Initial position (above screen)
	local initialYScale = -0.1
	notifFrame.Position = UDim2.new(0.5, 0, initialYScale, 0)

	-- Animate In
	local targetYScale = 0.08
	if notificationData.TargetYScale then
		targetYScale = notificationData.TargetYScale
	end

	local tweenInfoIn = TweenInfo.new(ANIMATION_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local goalIn = { Position = UDim2.fromScale(0.5, targetYScale) }
	local inTween = TweenService:Create(notifFrame, tweenInfoIn, goalIn)
	table.insert(elements.Tweens, inTween)
	inTween:Play()

	inTween.Completed:Connect(function()
		if ActiveNotificationElements and ActiveNotificationElements.Id == currentNotifId then
			-- Start timeout for natural dismissal only after animation completes
			elements.TimeoutCoroutine = task.delay(NOTIFICATION_LIFETIME, function()
				if ActiveNotificationElements and ActiveNotificationElements.Id == currentNotifId then
					self:_cleanupActiveNotification(true)
				end
			end)
		end
	end)

	return currentNotifId -- Return the ID for potential tracking by caller
end

return Notifications

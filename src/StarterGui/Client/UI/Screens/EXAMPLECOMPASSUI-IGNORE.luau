-- LocalScript
-- Put in StarterPlayerScripts or inside a ScreenGui in StarterGui

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--// Settings

local USE_CAMERA_HEADING = true
-- true  = compass follows camera direction
-- false = compass follows character HumanoidRootPart direction

local BAR_WIDTH = 620
local BAR_HEIGHT = 54

local DEGREES_VISIBLE = 120
-- Total degrees shown across the compass bar.
-- Higher = more zoomed out.
-- Lower = more zoomed in.

local LABEL_SPACING_DEGREES = 30
-- 30 gives: N, 3, 6, E, 12, 15, S, 21, 24, W, 30, 33

local TICK_SPACING_DEGREES = 5
-- Tick mark every 5 degrees.

local LABEL_BUFFER_DEGREES = 20
local TICK_BUFFER_DEGREES = 10

local SHOW_SHORT_DEGREE_NUMBERS = true
-- true  = 30 degrees displays as "3"
-- false = 30 degrees displays as "30"

local MIN_LABEL_TEXT_SIZE = 16
local MAX_LABEL_TEXT_SIZE = 27

local LABEL_Y = 22
local TICK_BOTTOM_PADDING = 5

--// UI Creation

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CompassGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = playerGui

local bar = Instance.new("Frame")
bar.Name = "CompassBar"
bar.AnchorPoint = Vector2.new(0.5, 0)
bar.Position = UDim2.new(0.5, 0, 0, 18)
bar.Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT)
bar.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
bar.BackgroundTransparency = 0.35
bar.BorderSizePixel = 0
bar.ClipsDescendants = true
bar.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = bar

local centerMarker = Instance.new("Frame")
centerMarker.Name = "CenterMarker"
centerMarker.AnchorPoint = Vector2.new(0.5, 0.5)
centerMarker.Position = UDim2.new(0.5, 0, 0.5, 0)
centerMarker.Size = UDim2.fromOffset(2, BAR_HEIGHT - 12)
centerMarker.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
centerMarker.BackgroundTransparency = 0.25
centerMarker.BorderSizePixel = 0
centerMarker.ZIndex = 5
centerMarker.Parent = bar

--// Compass Data

local cardinalLabels = {
	[0] = "N",
	[90] = "E",
	[180] = "S",
	[270] = "W",
}

local activeLabels = {}
local activeTicks = {}

--// Utility

local function normalizeDegrees(degrees)
	degrees %= 360

	if degrees < 0 then
		degrees += 360
	end

	return degrees
end

local function shortestAngleDifference(targetDegrees, currentDegrees)
	-- Signed shortest difference from current heading to target heading.
	-- current 350, target 10  => 20
	-- current 10,  target 350 => -20

	return (targetDegrees - currentDegrees + 180) % 360 - 180
end

local function getCompassHeadingFromLookVector(lookVector)
	-- This mapping assumes:
	-- North = world -Z
	-- East  = world +X
	-- South = world +Z
	-- West  = world -X

	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)

	if flatLook.Magnitude <= 0.001 then
		return 0
	end

	flatLook = flatLook.Unit

	local radians = math.atan2(flatLook.X, -flatLook.Z)
	local degrees = math.deg(radians)

	return normalizeDegrees(degrees)
end

local function getCurrentHeading()
	if USE_CAMERA_HEADING then
		local camera = workspace.CurrentCamera

		if camera then
			return getCompassHeadingFromLookVector(camera.CFrame.LookVector)
		end
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	if rootPart then
		return getCompassHeadingFromLookVector(rootPart.CFrame.LookVector)
	end

	return 0
end

local function getLabelText(degrees)
	local cardinal = cardinalLabels[degrees]

	if cardinal then
		return cardinal
	end

	if SHOW_SHORT_DEGREE_NUMBERS then
		return tostring(degrees / 10)
	end

	return tostring(degrees)
end

local function isLabelDegree(degrees)
	return degrees % LABEL_SPACING_DEGREES == 0
end

local function isCardinalDegree(degrees)
	return cardinalLabels[degrees] ~= nil
end

--// Label Creation

local function createCompassLabel(degrees)
	local label = Instance.new("TextLabel")
	label.Name = "CompassLabel_" .. degrees
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = UDim2.fromOffset(70, 32)
	label.BackgroundTransparency = 1
	label.Text = getLabelText(degrees)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.45
	label.TextScaled = false
	label.TextSize = MIN_LABEL_TEXT_SIZE
	label.Font = Enum.Font.GothamBold
	label.ZIndex = 3
	label.Parent = bar

	return label
end

--// Tick Creation

local function createCompassTick(degrees)
	local tick = Instance.new("Frame")
	tick.Name = "CompassTick_" .. degrees
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	tick.BackgroundTransparency = 0.25
	tick.BorderSizePixel = 0
	tick.ZIndex = 2
	tick.Parent = bar

	return tick
end

local function getTickHeight(degrees)
	if isCardinalDegree(degrees) then
		return 18
	elseif isLabelDegree(degrees) then
		return 14
	elseif degrees % 10 == 0 then
		return 10
	else
		return 6
	end
end

local function getTickWidth(degrees)
	if isCardinalDegree(degrees) then
		return 2
	elseif isLabelDegree(degrees) then
		return 2
	else
		return 1
	end
end

--// Main Update

local function updateCompass()
	local heading = getCurrentHeading()

	local barWidth = bar.AbsoluteSize.X
	local barCenterX = barWidth / 2

	local pixelsPerDegree = barWidth / DEGREES_VISIBLE
	local halfVisibleDegrees = DEGREES_VISIBLE / 2

	local labelAllowedRange = halfVisibleDegrees + LABEL_BUFFER_DEGREES
	local tickAllowedRange = halfVisibleDegrees + TICK_BUFFER_DEGREES

	local neededLabels = {}
	local neededTicks = {}

	--// Update ticks

	for degrees = 0, 355, TICK_SPACING_DEGREES do
		local difference = shortestAngleDifference(degrees, heading)

		if math.abs(difference) <= tickAllowedRange then
			neededTicks[degrees] = true

			local tick = activeTicks[degrees]

			if not tick then
				tick = createCompassTick(degrees)
				activeTicks[degrees] = tick
			end

			local x = barCenterX + difference * pixelsPerDegree

			local tickHeight = getTickHeight(degrees)
			local tickWidth = getTickWidth(degrees)

			tick.Size = UDim2.fromOffset(tickWidth, tickHeight)
			tick.Position = UDim2.fromOffset(x, BAR_HEIGHT - TICK_BOTTOM_PADDING - tickHeight / 2)

			-- Fade ticks near the edges
			local edgeAlpha = math.clamp(math.abs(difference) / halfVisibleDegrees, 0, 1)
			tick.BackgroundTransparency = 0.25 + edgeAlpha * 0.55
		end
	end

	for degrees, tick in pairs(activeTicks) do
		if not neededTicks[degrees] then
			tick:Destroy()
			activeTicks[degrees] = nil
		end
	end

	--// Update text labels

	for degrees = 0, 330, LABEL_SPACING_DEGREES do
		local difference = shortestAngleDifference(degrees, heading)

		if math.abs(difference) <= labelAllowedRange then
			neededLabels[degrees] = true

			local label = activeLabels[degrees]

			if not label then
				label = createCompassLabel(degrees)
				activeLabels[degrees] = label
			end

			local x = barCenterX + difference * pixelsPerDegree

			label.Position = UDim2.fromOffset(x, LABEL_Y)

			-- Smooth emphasis.
			-- Labels closer to the center become bigger and more visible.
			local centerAlpha = 1 - math.clamp(math.abs(difference) / halfVisibleDegrees, 0, 1)

			local textSize = MIN_LABEL_TEXT_SIZE + centerAlpha * (MAX_LABEL_TEXT_SIZE - MIN_LABEL_TEXT_SIZE)

			if isCardinalDegree(degrees) then
				textSize += 3
			end

			label.TextSize = textSize

			-- Fade near edges.
			local edgeAlpha = 1 - centerAlpha
			label.TextTransparency = edgeAlpha * 0.45
			label.TextStrokeTransparency = 0.35 + edgeAlpha * 0.45
		end
	end

	for degrees, label in pairs(activeLabels) do
		if not neededLabels[degrees] then
			label:Destroy()
			activeLabels[degrees] = nil
		end
	end
end

-- Prefer PreRender when available, otherwise use RenderStepped.
local renderSignal = RunService.PreRender or RunService.RenderStepped

renderSignal:Connect(updateCompass)

-- GradientEffects.lua
-- Place this ModuleScript somewhere like ReplicatedStorage or inside your UI package.
-- Call from a LocalScript for PlayerGui UI.

local TweenService = game:GetService("TweenService")

local GradientEffects = {}

local Active = {}
local Effects = {}

local SUPPORTED_EFFECTS = "Shine, Hover, HoverStay, Rainbow"

local function makeColorSequence(colors)
	if #colors == 1 then
		return ColorSequence.new(colors[1])
	end

	local keypoints = {}

	for i, color in ipairs(colors) do
		local alpha = (i - 1) / (#colors - 1)
		table.insert(keypoints, ColorSequenceKeypoint.new(alpha, color))
	end

	return ColorSequence.new(keypoints)
end

local function normalizeEffectName(effectName)
	local compact = string.lower(tostring(effectName)):gsub("[%s_%-]", "")

	local aliases = {
		shine = "shine",
		shimmer = "shine",

		hover = "hover",

		hoverstay = "hoverStay",
		stayhover = "hoverStay",

		rainbow = "rainbow",
		rgb = "rainbow",
	}

	return aliases[compact]
end

local function assertGradient(gradient)
	assert(
		typeof(gradient) == "Instance" and gradient:IsA("UIGradient"),
		"GradientEffects expected a UIGradient object."
	)
end

local function assertGuiObject(guiObject, effectName)
	assert(
		guiObject ~= nil and typeof(guiObject) == "Instance" and guiObject:IsA("GuiObject"),
		string.format("Gradient effect %q needs a parent GuiObject for hover events.", effectName)
	)
end

local function makeTweenInfo(options, defaultDuration, defaultStyle, defaultDirection)
	return TweenInfo.new(
		options.Duration or defaultDuration,
		options.EasingStyle or defaultStyle,
		options.EasingDirection or defaultDirection,
		options.RepeatCount or 0,
		options.Reverses or false,
		options.DelayTime or 0
	)
end

local function trackTween(controller, tween)
	table.insert(controller.Tweens, tween)
	return tween
end

local function trackConnection(controller, connection)
	table.insert(controller.Connections, connection)
	return connection
end

local function cancellableWait(controller, seconds)
	if seconds <= 0 then
		return controller.Running
	end

	local started = os.clock()

	while controller.Running and os.clock() - started < seconds do
		task.wait(math.min(0.1, seconds - (os.clock() - started)))
	end

	return controller.Running
end

local function playAndWait(controller, tween)
	if not controller.Running then
		return false
	end

	local finished = false
	local playbackState = nil

	local connection
	connection = tween.Completed:Connect(function(state)
		playbackState = state
		finished = true
	end)

	tween:Play()

	while controller.Running and not finished do
		task.wait()
	end

	connection:Disconnect()

	if not controller.Running then
		tween:Cancel()
		return false
	end

	return playbackState == Enum.PlaybackState.Completed
end

local function colorAt(colors, index)
	local count = #colors
	return colors[((index - 1) % count) + 1]
end

local function buildRainbowColors(options)
	if options.Colors and #options.Colors >= 3 then
		return options.Colors
	end

	local steps = math.max(options.Steps or 15, 3)
	local saturation = options.Saturation or 1
	local value = options.Value or 1

	local colors = {}

	for i = 0, steps - 1 do
		table.insert(colors, Color3.fromHSV(i / steps, saturation, value))
	end

	return colors
end

--// Effect: Shine
-- Best for buttons, titles, cards, purchase prompts, etc.
Effects.shine = function(controller)
	local gradient = controller.Gradient
	local options = controller.Options

	local startOffset = options.StartOffset or Vector2.new(-1, 0)
	local endOffset = options.EndOffset or Vector2.new(1, 0)
	local delayBetweenBursts = options.Delay or 2.5
	local shinesPerBurst = options.ShinesPerBurst or 2

	if options.SetupDefaults ~= false then
		local baseColor = options.BaseColor or Color3.fromRGB(255, 75, 170)
		local shineColor = options.ShineColor or Color3.fromRGB(255, 220, 245)

		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, baseColor),
			ColorSequenceKeypoint.new(0.5, shineColor),
			ColorSequenceKeypoint.new(1, baseColor),
		})

		gradient.Rotation = options.Rotation or 45
	elseif options.Rotation ~= nil then
		gradient.Rotation = options.Rotation
	end

	gradient.Offset = startOffset

	local tweenInfo = makeTweenInfo(options, 1, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)

	local tween = trackTween(
		controller,
		TweenService:Create(gradient, tweenInfo, {
			Offset = endOffset,
		})
	)

	task.spawn(function()
		while controller.Running do
			for _ = 1, shinesPerBurst do
				if not controller.Running then
					return
				end

				gradient.Offset = startOffset

				if not playAndWait(controller, tween) then
					return
				end
			end

			gradient.Offset = startOffset

			if not cancellableWait(controller, delayBetweenBursts) then
				return
			end
		end
	end)
end

--// Effect: Hover
-- On hover, moves the gradient into view.
-- On leave, alternates the side it exits to.
Effects.hover = function(controller)
	local gradient = controller.Gradient
	local parent = controller.Parent
	local options = controller.Options

	assertGuiObject(parent, controller.Effect)

	local startOffset = options.StartOffset or Vector2.new(-1, 0)

	if options.SetupDefaults ~= false then
		gradient.Color = makeColorSequence(options.Colors or {
			Color3.fromRGB(255, 230, 80),
			Color3.fromRGB(80, 255, 130),
			Color3.fromRGB(70, 180, 255),
		})

		if options.Rotation ~= nil then
			gradient.Rotation = options.Rotation
		end
	end

	gradient.Offset = startOffset

	local tweenInfo = makeTweenInfo(options, 1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

	local hoverInTween = trackTween(
		controller,
		TweenService:Create(gradient, tweenInfo, {
			Offset = Vector2.new(0, 0),
		})
	)

	local hoverOutLeftTween = trackTween(
		controller,
		TweenService:Create(gradient, tweenInfo, {
			Offset = Vector2.new(-1, 0),
		})
	)

	local hoverOutRightTween = trackTween(
		controller,
		TweenService:Create(gradient, tweenInfo, {
			Offset = Vector2.new(1, 0),
		})
	)

	local hoverCount = 1

	local function playExclusive(tweenToPlay)
		for _, tween in ipairs(controller.Tweens) do
			if tween ~= tweenToPlay then
				tween:Cancel()
			end
		end

		tweenToPlay:Play()
	end

	trackConnection(
		controller,
		parent.MouseEnter:Connect(function()
			if not controller.Running then
				return
			end

			playExclusive(hoverInTween)
		end)
	)

	trackConnection(
		controller,
		parent.MouseLeave:Connect(function()
			if not controller.Running then
				return
			end

			if hoverCount % 2 == 0 then
				playExclusive(hoverOutLeftTween)
			else
				playExclusive(hoverOutRightTween)
			end

			hoverCount += 1
		end)
	)
end

--// Effect: HoverStay
-- While hovered, continuously slides between two colors by flipping rotation.
-- When not hovered, pauses where it is.
Effects.hoverStay = function(controller)
	local gradient = controller.Gradient
	local parent = controller.Parent
	local options = controller.Options

	assertGuiObject(parent, controller.Effect)

	local startOffset = options.StartOffset or Vector2.new(1, 0)
	local endOffset = options.EndOffset or Vector2.new(-1, 0)

	if options.SetupDefaults ~= false then
		gradient.Color = makeColorSequence(options.Colors or {
			Color3.fromRGB(255, 95, 150),
			Color3.fromRGB(95, 180, 255),
		})
	end

	gradient.Offset = startOffset
	gradient.Rotation = 0

	local currentRotation = 0
	local hovering = false

	local tweenInfo = makeTweenInfo(options, 2.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

	local tween = trackTween(
		controller,
		TweenService:Create(gradient, tweenInfo, {
			Offset = endOffset,
		})
	)

	trackConnection(
		controller,
		parent.MouseEnter:Connect(function()
			if not controller.Running then
				return
			end

			hovering = true
			tween:Play()
		end)
	)

	trackConnection(
		controller,
		parent.MouseLeave:Connect(function()
			if not controller.Running then
				return
			end

			hovering = false
			tween:Pause()
		end)
	)

	trackConnection(
		controller,
		tween.Completed:Connect(function(state)
			if not controller.Running or state ~= Enum.PlaybackState.Completed then
				return
			end

			if not hovering then
				return
			end

			currentRotation = if currentRotation == 0 then 180 else 0

			gradient.Rotation = currentRotation
			gradient.Offset = startOffset

			tween:Play()
		end)
	)
end

--// Effect: Rainbow
-- Smoothly cycles rainbow colors using offset tweens and occasional ColorSequence swaps.
Effects.rainbow = function(controller)
	local gradient = controller.Gradient
	local options = controller.Options

	local colors = buildRainbowColors(options)
	local startOffset = options.StartOffset or Vector2.new(-1, 0)
	local endOffset = options.EndOffset or Vector2.new(1, 0)

	local keypoint = ColorSequenceKeypoint.new

	gradient.Offset = startOffset
	gradient.Rotation = 0
	gradient.Color = ColorSequence.new({
		keypoint(0, colorAt(colors, #colors)),
		keypoint(0.5, colorAt(colors, #colors - 1)),
		keypoint(1, colorAt(colors, #colors - 2)),
	})

	local counter = #colors

	local tweenInfo = makeTweenInfo(options, 1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

	local tween = trackTween(
		controller,
		TweenService:Create(gradient, tweenInfo, {
			Offset = endOffset,
		})
	)

	task.spawn(function()
		while controller.Running do
			if not playAndWait(controller, tween) then
				return
			end

			gradient.Offset = startOffset
			gradient.Rotation = 180

			gradient.Color = ColorSequence.new({
				keypoint(0, gradient.Color.Keypoints[1].Value),
				keypoint(0.5, colorAt(colors, counter + 1)),
				keypoint(1, colorAt(colors, counter + 2)),
			})

			counter += 2

			if not playAndWait(controller, tween) then
				return
			end

			gradient.Offset = startOffset
			gradient.Rotation = 0

			gradient.Color = ColorSequence.new({
				keypoint(0, colorAt(colors, counter + 2)),
				keypoint(0.5, colorAt(colors, counter + 1)),
				keypoint(1, gradient.Color.Keypoints[3].Value),
			})

			counter += 2
		end
	end)
end

function GradientEffects.Start(gradient, parentGui, effectName, options)
	assertGradient(gradient)

	options = options or {}

	local normalizedEffectName = normalizeEffectName(effectName)
	assert(
		normalizedEffectName and Effects[normalizedEffectName],
		string.format("Unknown gradient effect %q. Supported effects: %s", tostring(effectName), SUPPORTED_EFFECTS)
	)

	if parentGui == nil and gradient.Parent and gradient.Parent:IsA("GuiObject") then
		parentGui = gradient.Parent
	end

	if parentGui ~= nil then
		assert(
			typeof(parentGui) == "Instance" and parentGui:IsA("GuiObject"),
			"parentGui must be a GuiObject, such as Frame, TextButton, TextLabel, ImageLabel, or ImageButton."
		)
	end

	GradientEffects.Stop(gradient)

	local controller = {
		__gradientEffectController = true,

		Gradient = gradient,
		Parent = parentGui,
		Effect = normalizedEffectName,
		Options = options,

		Running = true,
		Tweens = {},
		Connections = {},

		Initial = {
			Enabled = gradient.Enabled,
			Color = gradient.Color,
			Transparency = gradient.Transparency,
			Offset = gradient.Offset,
			Rotation = gradient.Rotation,
		},
	}

	Active[gradient] = controller

	Effects[normalizedEffectName](controller)

	return controller
end

function GradientEffects.Stop(target)
	if target == nil then
		local gradients = {}

		for gradient in pairs(Active) do
			table.insert(gradients, gradient)
		end

		for _, gradient in ipairs(gradients) do
			GradientEffects.Stop(gradient)
		end

		return true
	end

	local controller = nil

	if type(target) == "table" and target.__gradientEffectController then
		controller = target
	elseif typeof(target) == "Instance" then
		controller = Active[target]
	end

	if not controller then
		return false
	end

	controller.Running = false

	for _, connection in ipairs(controller.Connections) do
		connection:Disconnect()
	end

	for _, tween in ipairs(controller.Tweens) do
		tween:Cancel()
	end

	if controller.Options.RestoreOnStop ~= false and controller.Gradient.Parent ~= nil then
		controller.Gradient.Enabled = controller.Initial.Enabled
		controller.Gradient.Color = controller.Initial.Color
		controller.Gradient.Transparency = controller.Initial.Transparency
		controller.Gradient.Offset = controller.Initial.Offset
		controller.Gradient.Rotation = controller.Initial.Rotation
	end

	Active[controller.Gradient] = nil

	return true
end

return GradientEffects

local TweenService = game:GetService("TweenService")

local UIRoot = require(script.Parent.Parent.UIRoot)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local ClientOSMApiInterface = require(script.Parent.Parent.Parent.Controllers.ClientOSMApiInterface)

local GradientEffects = require(script.Parent.Parent.Parent.ClientPackages.GradientEffects)

local Loading = {}
Loading.__index = Loading
Loading.Name = "Loading"

local RotationTween: Tween | nil = nil
local TitleFadeTween: Tween | nil = nil
local LoadingImgFadeTween: Tween | nil = nil
local FadeOutCleanupTask: thread? = nil
local TextLoadingTask = nil
local loadingRequestGeneration = 0

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
		tween:Destroy()
	end
end

function Loading:StartFunctions(parsedData)
	loadingRequestGeneration += 1
	local requestGeneration = loadingRequestGeneration
	local loadingScreen = UIRoot.GetScreens():WaitForChild("Loading")

	local UIGradient = loadingScreen.UIGradient
	GradientEffects.Start(UIGradient, loadingScreen, "Shine", {
		BaseColor = Color3.fromRGB(97, 206, 137),
		ShineColor = Color3.fromRGB(155, 197, 197),
		SetupDefaults = false,
	})

	local LoadingImg = loadingScreen.LoadingImg
	local Title = loadingScreen.Title

	if FadeOutCleanupTask then
		task.cancel(FadeOutCleanupTask)
		FadeOutCleanupTask = nil
	end
	cancelTween(LoadingImgFadeTween)
	LoadingImgFadeTween = nil
	cancelTween(TitleFadeTween)
	TitleFadeTween = nil

	loadingScreen.Visible = true
	LoadingImg.ImageTransparency = 1
	Title.TextTransparency = 1

	local FadeTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	LoadingImgFadeTween = TweenService:Create(LoadingImg, FadeTweenInfo, { ImageTransparency = 0 })
	TitleFadeTween = TweenService:Create(Title, FadeTweenInfo, { TextTransparency = 0 })
	if LoadingImgFadeTween then
		LoadingImgFadeTween:Play()
	end
	if TitleFadeTween then
		TitleFadeTween:Play()
	end

	local RotationTweenInfo = TweenInfo.new(2, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1)
	RotationTween = TweenService:Create(LoadingImg, RotationTweenInfo, { Rotation = 360 })
	if RotationTween then
		RotationTween:Play()
	end

	local placeNameLoading = parsedData and parsedData.PlaceName or nil

	local targetBaseText = "Loading"
	if placeNameLoading then
		targetBaseText = "Loading " .. placeNameLoading
	end

	TextLoadingTask = task.spawn(function()
		local dotCount = 0
		while true do
			local dots = string.rep(".", dotCount)
			Title.Text = targetBaseText .. dots
			dotCount = (dotCount + 1) % 4
			task.wait(0.5)
		end
	end)

	if parsedData and parsedData.TargetScreen == "IngameHUD" and type(parsedData.MapData) == "table" then
		local latitude = parsedData.Latitude or parsedData.Lat
		local longitude = parsedData.Longitude or parsedData.Lon
		local mapData = parsedData.MapData

		task.delay(0.1, function()
			if requestGeneration ~= loadingRequestGeneration then
				return
			end

			UIController:OpenScreen("IngameHUD", {
				PlaceName = placeNameLoading,
				Latitude = latitude,
				Longitude = longitude,
				MapData = mapData,
			})
		end)
		return
	end

	local latitude = parsedData and parsedData.Lat
	local longitude = parsedData and parsedData.Lon
	if type(latitude) ~= "number" or type(longitude) ~= "number" then
		warn("Cannot load initial OSM data without a valid spawn location.")
		UIController:OpenScreen("PickSpawn")
		return
	end

	ClientOSMApiInterface:Initial(latitude, longitude)
		:andThen(function(response)
			if requestGeneration ~= loadingRequestGeneration then
				return
			end

			if not response.Ok or type(response.Data) ~= "table" then
				local message = response.Error and response.Error.Message or "OSM initial load failed."
				warn(string.format("OSM initial load failed: %s", message))
				UIController:OpenScreen("PickSpawn")
				return
			end

			UIController:OpenScreen("ConfirmSpawnInfo", response.Data)
		end)
		:catch(function(errorValue)
			if requestGeneration ~= loadingRequestGeneration then
				return
			end

			warn(string.format("OSM initial request failed: %s", tostring(errorValue)))
			UIController:OpenScreen("PickSpawn")
		end)
end

function Loading:StopFunctions()
	loadingRequestGeneration += 1
	local loadingScreen = UIRoot.GetScreens():WaitForChild("Loading")

	local UIGradient = loadingScreen.UIGradient
	GradientEffects.Stop(UIGradient)

	local LoadingImg = loadingScreen.LoadingImg
	local Title = loadingScreen.Title

	if FadeOutCleanupTask then
		task.cancel(FadeOutCleanupTask)
		FadeOutCleanupTask = nil
	end
	cancelTween(LoadingImgFadeTween)
	LoadingImgFadeTween = nil
	cancelTween(TitleFadeTween)
	TitleFadeTween = nil

	loadingScreen.Visible = true

	local FadeTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	LoadingImgFadeTween = TweenService:Create(LoadingImg, FadeTweenInfo, { ImageTransparency = 1 })
	TitleFadeTween = TweenService:Create(Title, FadeTweenInfo, { TextTransparency = 1 })
	if LoadingImgFadeTween then
		LoadingImgFadeTween:Play()
	end
	if TitleFadeTween then
		TitleFadeTween:Play()
	end

	FadeOutCleanupTask = task.delay(0.25, function()
		if loadingScreen.Parent then
			loadingScreen.Visible = false
		end
		FadeOutCleanupTask = nil
	end)

	if RotationTween then
		RotationTween:Destroy()
		RotationTween = nil
	end
	if TextLoadingTask then
		task.cancel(TextLoadingTask)
		TextLoadingTask = nil
	end
end

return Loading

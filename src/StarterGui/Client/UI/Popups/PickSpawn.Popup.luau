--!strict

local LocalizationService = game:GetService("LocalizationService")
local TweenService = game:GetService("TweenService")

local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)

local ClientOSMApiInterface = require(script.Parent.Parent.Parent.Controllers.ClientOSMApiInterface)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local UIRoot = require(script.Parent.Parent.UIRoot)

local PickSpawnPopup = {}
PickSpawnPopup.__index = PickSpawnPopup
PickSpawnPopup.Name = "PickSpawnPopup"

local connections = {} :: { RBXScriptConnection }
local activeReverseRequestId = 0
local activeLocationNameFadeTween: Tween? = nil
local activeLocationCountryFadeTween: Tween? = nil
local activeLocationNameStrokeFadeTween: Tween? = nil
local activeLocationCountryStrokeFadeTween: Tween? = nil
local activeLoadingImgFadeTween: Tween? = nil

local LOCATION_LABEL_FADE_DURATION = 0.2
local LOADING_IMAGE_FADE_DURATION = 0.2

type ApiTable = { [any]: any }

type MainInfo = {
	Visible: boolean,
	LocationName: TextLabel,
	Country: TextLabel,
}

local function asApiTable(value: unknown): ApiTable?
	if type(value) == "table" then
		return value :: ApiTable
	end

	return nil
end

local function normalizeText(value: unknown): string?
	if type(value) ~= "string" then
		return nil
	end

	local trimmed = string.match(value, "^%s*(.-)%s*$")
	if trimmed == nil or trimmed == "" then
		return nil
	end

	return trimmed
end

local function firstDisplayPart(value: unknown): string?
	local text = normalizeText(value)
	if text == nil then
		return nil
	end

	local firstPart = text:split(",")[1]
	return normalizeText(firstPart)
end

local function getReverseLanguage(): string?
	local localeId = LocalizationService.SystemLocaleId
	if type(localeId) ~= "string" or localeId == "" then
		return nil
	end

	return string.match(localeId, "^[^%-_]+")
end

local function formatReverseLocation(payload: unknown): (string?, string?)
	local response = asApiTable(payload)
	if response == nil then
		return nil, nil
	end

	local source = response
	for _, key in ipairs({ "location", "result", "place", "data" }) do
		local nested = asApiTable(source[key])
		if nested ~= nil then
			source = nested
			break
		end
	end

	local properties = asApiTable(source.properties)
	if properties ~= nil then
		source = properties
	end

	local address = asApiTable(source.address)
	local locationName = normalizeText(source.name)
		or normalizeText(source.displayName)
		or normalizeText(source.display_name)
		or normalizeText(source.label)
		or firstDisplayPart(source.display_name)
		or (address and normalizeText(address.neighbourhood))
		or (address and normalizeText(address.city))
		or (address and normalizeText(address.county))
		or (address and normalizeText(address.state))
	local countryName = normalizeText(source.country)
		or normalizeText(source.country_name)
		or if address then normalizeText(address.country) else nil

	return locationName, countryName
end

local function updateLocationLabels(mainInfo: MainInfo, locationName: string, countryName: string)
	mainInfo.Visible = true
	mainInfo.LocationName.Text = locationName
	mainInfo.Country.Text = countryName
end

local function cancelLocationFadeTween()
	if activeLocationNameFadeTween then
		activeLocationNameFadeTween:Cancel()
		activeLocationNameFadeTween:Destroy()
		activeLocationNameFadeTween = nil
	end
	if activeLocationCountryFadeTween then
		activeLocationCountryFadeTween:Cancel()
		activeLocationCountryFadeTween:Destroy()
		activeLocationCountryFadeTween = nil
	end
	if activeLocationNameStrokeFadeTween then
		activeLocationNameStrokeFadeTween:Cancel()
		activeLocationNameStrokeFadeTween:Destroy()
		activeLocationNameStrokeFadeTween = nil
	end
	if activeLocationCountryStrokeFadeTween then
		activeLocationCountryStrokeFadeTween:Cancel()
		activeLocationCountryStrokeFadeTween:Destroy()
		activeLocationCountryStrokeFadeTween = nil
	end
end

local function cancelLoadingImgFadeTween()
	if activeLoadingImgFadeTween then
		activeLoadingImgFadeTween:Cancel()
		activeLoadingImgFadeTween:Destroy()
		activeLoadingImgFadeTween = nil
	end
end

local function setLabelTransparency(label: TextLabel, transparency: number)
	label.TextTransparency = transparency
	local uiStroke = label:FindFirstChildOfClass("UIStroke")
	if uiStroke then
		uiStroke.Transparency = transparency
	end
end

local function setLocationLabelTransparency(popupFrame, transparency: number)
	local mainInfo = popupFrame.MainHolder.MainInfo :: MainInfo
	setLabelTransparency(mainInfo.LocationName, transparency)
	setLabelTransparency(mainInfo.Country, transparency)
end

local RotationTween: Tween? = nil

local function onLocationLoadStarted(popupFrame)
	cancelLocationFadeTween()
	cancelLoadingImgFadeTween()
	setLocationLabelTransparency(popupFrame, 1)

	local LoadingImg = popupFrame.LoadingImg
	LoadingImg.Visible = true
	LoadingImg.ImageTransparency = 1

	local loadingImgFadeTween = TweenService:Create(
		LoadingImg,
		TweenInfo.new(LOADING_IMAGE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			ImageTransparency = 0,
		}
	)
	activeLoadingImgFadeTween = loadingImgFadeTween
	loadingImgFadeTween:Play()
	loadingImgFadeTween.Completed:Connect(function()
		LoadingImg.Visible = false
		local currentLoadingTween = activeLoadingImgFadeTween
		if currentLoadingTween ~= nil and currentLoadingTween == loadingImgFadeTween then
			currentLoadingTween:Destroy()
			activeLoadingImgFadeTween = nil
		end
	end)

	local RotationTweenInfo = TweenInfo.new(2, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1)
	local rotationTween = TweenService:Create(LoadingImg, RotationTweenInfo, { Rotation = 360 })
	RotationTween = rotationTween
	rotationTween:Play()
end

local function onLocationLoadFinished(popupFrame)
	cancelLocationFadeTween()
	cancelLoadingImgFadeTween()
	setLocationLabelTransparency(popupFrame, 1)

	local LoadingImg = popupFrame.LoadingImg
	local loadingImgFadeTween = TweenService:Create(
		LoadingImg,
		TweenInfo.new(LOADING_IMAGE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{
			ImageTransparency = 1,
		}
	)
	activeLoadingImgFadeTween = loadingImgFadeTween
	loadingImgFadeTween:Play()
	loadingImgFadeTween.Completed:Connect(function()
		LoadingImg.Visible = false
		local currentLoadingTween = activeLoadingImgFadeTween
		if currentLoadingTween ~= nil and currentLoadingTween == loadingImgFadeTween then
			currentLoadingTween:Destroy()
			activeLoadingImgFadeTween = nil
		end
	end)

	if RotationTween then
		RotationTween:Destroy()
		RotationTween = nil
	end

	local mainInfo = popupFrame.MainHolder.MainInfo :: MainInfo
	local locationNameFadeTween = TweenService:Create(
		mainInfo.LocationName,
		TweenInfo.new(LOCATION_LABEL_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			TextTransparency = 0,
		}
	)
	local locationCountryFadeTween = TweenService:Create(
		mainInfo.Country,
		TweenInfo.new(LOCATION_LABEL_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			TextTransparency = 0,
		}
	)
	activeLocationNameFadeTween = locationNameFadeTween
	activeLocationCountryFadeTween = locationCountryFadeTween

	local locationNameStrokeFadeTween: Tween? = nil
	local locationNameStroke = mainInfo.LocationName:FindFirstChildOfClass("UIStroke")
	if locationNameStroke then
		locationNameStrokeFadeTween = TweenService:Create(
			locationNameStroke,
			TweenInfo.new(LOCATION_LABEL_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Transparency = 0,
			}
		)
		activeLocationNameStrokeFadeTween = locationNameStrokeFadeTween
	end

	local locationCountryStrokeFadeTween: Tween? = nil
	local countryStroke = mainInfo.Country:FindFirstChildOfClass("UIStroke")
	if countryStroke then
		locationCountryStrokeFadeTween = TweenService:Create(
			countryStroke,
			TweenInfo.new(LOCATION_LABEL_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Transparency = 0,
			}
		)
		activeLocationCountryStrokeFadeTween = locationCountryStrokeFadeTween
	end

	locationNameFadeTween:Play()
	locationCountryFadeTween:Play()
	if locationNameStrokeFadeTween then
		locationNameStrokeFadeTween:Play()
	end
	if locationCountryStrokeFadeTween then
		locationCountryStrokeFadeTween:Play()
	end

	locationCountryFadeTween.Completed:Connect(function()
		local currentCountryTween = activeLocationCountryFadeTween
		if currentCountryTween ~= nil and currentCountryTween == locationCountryFadeTween then
			currentCountryTween:Destroy()
			activeLocationCountryFadeTween = nil
		end
		local currentCountryStrokeTween = activeLocationCountryStrokeFadeTween
		if currentCountryStrokeTween ~= nil and currentCountryStrokeTween == locationCountryStrokeFadeTween then
			currentCountryStrokeTween:Destroy()
			activeLocationCountryStrokeFadeTween = nil
		end
	end)
	locationNameFadeTween.Completed:Connect(function()
		local currentNameTween = activeLocationNameFadeTween
		if currentNameTween ~= nil and currentNameTween == locationNameFadeTween then
			currentNameTween:Destroy()
			activeLocationNameFadeTween = nil
		end
		local currentNameStrokeTween = activeLocationNameStrokeFadeTween
		if currentNameStrokeTween ~= nil and currentNameStrokeTween == locationNameStrokeFadeTween then
			currentNameStrokeTween:Destroy()
			activeLocationNameStrokeFadeTween = nil
		end
	end)
end

function PickSpawnPopup:StartFunctions(parseData)
	local Lat = parseData and parseData.Lat or 0
	local Lon = parseData and parseData.Lon or 0
	local Country = parseData and parseData.Country or "Unknown"
	local IsPopularSpot = parseData and parseData.IsPopularSpot or false
	local LocationName = parseData and parseData.LocationName or "Unknown"
	local NeedsReverseGeocode = parseData and parseData.NeedsReverseGeocode or false
	local selectedLocationName = LocationName
	local selectedCountryName = Country

	local popupFrame = UIRoot.GetPopups():WaitForChild("PickSpawn")

	local ContinueButton = popupFrame.ContinueButton
	local BackButton = popupFrame.TopHolder.BackButton

	local MainHolder = popupFrame.MainHolder
	MainHolder.MainInfo.Visible = true
	MainHolder.Seperator.Visible = true
	setLocationLabelTransparency(popupFrame, 0)

	if IsPopularSpot then
		updateLocationLabels(MainHolder.MainInfo, LocationName, Country)
	else
		local initialLocationName = if NeedsReverseGeocode then "Locating nearby place..." else "Unknown Location"
		local initialCountryName = if NeedsReverseGeocode then "Finding country..." else "Unknown Country"
		selectedLocationName = initialLocationName
		selectedCountryName = initialCountryName
		updateLocationLabels(MainHolder.MainInfo, initialLocationName, initialCountryName)
	end

	MainHolder.SubLocationInfo.Latitude.Text = string.format("LAT %.4f", Lat)
	MainHolder.SubLocationInfo.Longitude.Text = string.format("LON %.4f", Lon)

	GuiButtonEffects:SetupFromTemplate(ContinueButton, "GreenButton")
	local BackButtonEffects = {
		OnMouseEnter = {
			[BackButton.Icon] = {
				ImageColor3 = Color3.fromRGB(217, 217, 217):Lerp(Color3.fromRGB(255, 255, 255), 0.2),
			},
		},
		OnClickStart = {
			[BackButton.Icon] = {
				ImageColor3 = Color3.fromRGB(217, 217, 217):Lerp(Color3.fromRGB(255, 255, 255), 0.4),
			},
		},
	}
	GuiButtonEffects:Setup(BackButton, BackButtonEffects)

	table.insert(
		connections,
		ContinueButton.Activated:Connect(function()
			UIController:ClosePopup()
			UIController:OpenScreen("Loading", {
				Lat = Lat,
				Lon = Lon,
				PlaceName = selectedLocationName,
			})
		end)
	)
	table.insert(
		connections,
		BackButton.Activated:Connect(function()
			UIController:ClosePopup()
		end)
	)

	if not IsPopularSpot and (NeedsReverseGeocode or LocationName == "Unknown" or Country == "Unknown") then
		activeReverseRequestId += 1
		local requestId = activeReverseRequestId
		local reverseLanguage = getReverseLanguage()
		onLocationLoadStarted(popupFrame)

		ClientOSMApiInterface:Reverse(Lat, Lon, reverseLanguage)
			:andThen(function(response)
				if requestId ~= activeReverseRequestId then
					return
				end

				onLocationLoadFinished(popupFrame)

				if not response.Ok then
					local message = response.Error and response.Error.Message or "Reverse geocoding failed."
					warn(string.format("Reverse geocoding failed for %.6f, %.6f: %s", Lat, Lon, message))
					selectedLocationName = "Unknown Location"
					selectedCountryName = "Unknown Country"
					updateLocationLabels(MainHolder.MainInfo, "Unknown Location", "Unknown Country")
					return
				end

				local resolvedLocationName, resolvedCountryName = formatReverseLocation(response.Data)
				selectedLocationName = resolvedLocationName or "Unknown Location"
				selectedCountryName = resolvedCountryName or "Unknown Country"
				updateLocationLabels(MainHolder.MainInfo, selectedLocationName, selectedCountryName)
			end)
			:catch(function(errorValue)
				if requestId ~= activeReverseRequestId then
					return
				end

				onLocationLoadFinished(popupFrame)
				warn(
					string.format("Reverse geocoding request failed for %.6f, %.6f: %s", Lat, Lon, tostring(errorValue))
				)
				selectedLocationName = "Unknown Location"
				selectedCountryName = "Unknown Country"
				updateLocationLabels(MainHolder.MainInfo, "Unknown Location", "Unknown Country")
			end)
	end
end

function PickSpawnPopup:StopFunctions()
	activeReverseRequestId += 1

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	connections = {}
	local popupFrame = UIRoot.GetPopups():WaitForChild("PickSpawn")
	cancelLocationFadeTween()
	cancelLoadingImgFadeTween()
	setLocationLabelTransparency(popupFrame, 0)
	popupFrame.LoadingImg.Visible = false
	popupFrame.LoadingImg.ImageTransparency = 1
	local ContinueButton = popupFrame.ContinueButton
	local BackButton = popupFrame.TopHolder.BackButton
	GuiButtonEffects:Clear(ContinueButton)
	GuiButtonEffects:Clear(BackButton)
end

return PickSpawnPopup

local LocalizationService = game:GetService("LocalizationService")

local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)

local ClientOSMApiInterface = require(script.Parent.Parent.Parent.Controllers.ClientOSMApiInterface)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local UIRoot = require(script.Parent.Parent.UIRoot)

local CustomCoordinatesPopup = {}
CustomCoordinatesPopup.__index = CustomCoordinatesPopup
CustomCoordinatesPopup.Name = "CustomCoordinatesPopup"

local connections = {} :: { RBXScriptConnection }
local activeLookupRequestId = 0
local selectedLatitude: number? = nil
local selectedLongitude: number? = nil
local selectedPlaceName = "Custom Coordinates"

type ApiTable = { [any]: any }

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

local function asFiniteNumber(value: unknown): number?
	local numberValue = if type(value) == "number"
		then value
		elseif type(value) == "string" then tonumber(value)
		else nil
	if numberValue == nil or numberValue ~= numberValue or numberValue == math.huge or numberValue == -math.huge then
		return nil
	end

	return numberValue
end

local function getReverseLanguage(): string?
	local localeId = LocalizationService.SystemLocaleId
	if type(localeId) ~= "string" or localeId == "" then
		return nil
	end

	return string.match(localeId, "^[^%-_]+")
end

local function parseCoordinates(inputText: string): (number?, number?, string?)
	local normalizedInput = string.match(inputText, "^%s*(.-)%s*$") or ""
	if normalizedInput == "" then
		return nil, nil, "Enter coordinates as LAT, LON."
	end

	local latitudeText, longitudeText = string.match(
		normalizedInput,
		"^([%+%-]?%d*%.?%d+)%s*[,;%s]%s*([%+%-]?%d*%.?%d+)$"
	)
	local latitude = latitudeText and tonumber(latitudeText) or nil
	local longitude = longitudeText and tonumber(longitudeText) or nil

	if latitude == nil or longitude == nil then
		return nil, nil, "Use LAT, LON. Example: 56.9496, 24.1052"
	end
	if latitude < -90 or latitude > 90 then
		return nil, nil, "Latitude must be between -90 and 90."
	end
	if longitude < -180 or longitude > 180 then
		return nil, nil, "Longitude must be between -180 and 180."
	end

	return latitude, longitude, nil
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
		or (address and normalizeText(address.town))
		or (address and normalizeText(address.village))
		or (address and normalizeText(address.county))
		or (address and normalizeText(address.state))
	local countryName = normalizeText(source.country)
		or normalizeText(source.country_name)
		or if address then normalizeText(address.country) else nil

	return locationName, countryName
end

local function getSearchResultItems(payload: unknown): { any }
	local response = asApiTable(payload)
	if response == nil then
		return {}
	end

	if #response > 0 then
		return response :: any
	end

	for _, key in ipairs({ "results", "places", "locations", "features" }) do
		local items = asApiTable(response[key])
		if items ~= nil then
			return items :: any
		end
	end

	return getSearchResultItems(response.data)
end

local function formatSearchLocation(payload: unknown): (string?, string?)
	for _, item in ipairs(getSearchResultItems(payload)) do
		local result = asApiTable(item)
		if result == nil then
			continue
		end

		local source = asApiTable(result.location) or result
		local properties = asApiTable(source.properties)
		if properties ~= nil then
			source = properties
		end

		local address = asApiTable(source.address)
		local latitude = asFiniteNumber(source.lat) or asFiniteNumber(source.latitude)
		local longitude = asFiniteNumber(source.lon) or asFiniteNumber(source.lng) or asFiniteNumber(source.longitude)
		local geometry = asApiTable(source.geometry) or asApiTable(result.geometry)
		local coordinates = geometry and asApiTable(geometry.coordinates)
		if coordinates ~= nil then
			longitude = longitude or asFiniteNumber(coordinates[1])
			latitude = latitude or asFiniteNumber(coordinates[2])
		end

		if latitude == nil or longitude == nil then
			continue
		end

		local name = normalizeText(source.name)
			or normalizeText(source.displayName)
			or normalizeText(source.display_name)
			or normalizeText(source.label)
			or firstDisplayPart(source.display_name)
			or (address and normalizeText(address.name))
			or (address and normalizeText(address.city))
			or (address and normalizeText(address.town))
			or (address and normalizeText(address.village))
		local country = normalizeText(source.country) or (address and normalizeText(address.country))

		return name, country
	end

	return nil, nil
end

local function setText(target: Instance?, text: string)
	if target == nil then
		return
	end

	if target:IsA("TextLabel") or target:IsA("TextButton") or target:IsA("TextBox") then
		target.Text = text
		return
	end

	local childText = target:FindFirstChildWhichIsA("TextLabel", true)
		or target:FindFirstChildWhichIsA("TextButton", true)
		or target:FindFirstChildWhichIsA("TextBox", true)
	if childText then
		childText.Text = text
	end
end

local function setButtonEnabled(button: GuiButton, isEnabled: boolean)
	button.Active = isEnabled
	button.AutoButtonColor = isEnabled
end

function CustomCoordinatesPopup:StartFunctions(parseData)
	activeLookupRequestId += 1
	selectedLatitude = nil
	selectedLongitude = nil
	selectedPlaceName = "Custom Coordinates"

	local popupFrame = UIRoot.GetPopups():WaitForChild("CustomCoordinates")

	local BackButton = popupFrame.TopHolder.BackButton

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

	local MainHolder = popupFrame.MainHolder
	local EnterCoordinatesPage = MainHolder.EnterCoordinates
	local SpawnInfoPage = MainHolder.SpawnInfo

	local EnterCoordinatesTextbox = EnterCoordinatesPage.CoordinatesInput.TextBox -- input is LAT , LON (comma seperated)
	local EnterCoordinatesContinueButton = EnterCoordinatesPage.ContinueButton

	local SpawnInfoLoadButton = SpawnInfoPage.LoadButton
	local SpawnInfoAddress1 = SpawnInfoPage.Address1
	local SpawnInfoAddress2 = SpawnInfoPage.Address2
	local isLookingUp = false
	local isLookupComplete = false

	local function showEnterCoordinatesPage()
		EnterCoordinatesPage.Visible = true
		SpawnInfoPage.Visible = false
		setButtonEnabled(EnterCoordinatesContinueButton, true)
		setButtonEnabled(SpawnInfoLoadButton, false)
	end

	local function showSpawnInfoPage()
		EnterCoordinatesPage.Visible = false
		SpawnInfoPage.Visible = true
	end

	local function setSpawnInfo(address1: string, address2: string)
		setText(SpawnInfoAddress1, address1)
		setText(SpawnInfoAddress2, address2)
	end

	showEnterCoordinatesPage()
	setSpawnInfo("", "")

	GuiButtonEffects:SetupFromTemplate(EnterCoordinatesContinueButton, "GreenButton")
	GuiButtonEffects:SetupFromTemplate(SpawnInfoLoadButton, "GreenButton")

	table.insert(
		connections,
		BackButton.Activated:Connect(function()
			if SpawnInfoPage.Visible then
				activeLookupRequestId += 1
				selectedLatitude = nil
				selectedLongitude = nil
				selectedPlaceName = "Custom Coordinates"
				isLookingUp = false
				isLookupComplete = false
				showEnterCoordinatesPage()
				return
			end

			UIController:ClosePopup()
		end)
	)
	table.insert(
		connections,
		EnterCoordinatesContinueButton.Activated:Connect(function()
			if isLookingUp then
				return
			end

			local latitude, longitude, validationError = parseCoordinates(EnterCoordinatesTextbox.Text)
			if latitude == nil or longitude == nil then
				selectedLatitude = nil
				selectedLongitude = nil
				isLookupComplete = false
				setSpawnInfo(validationError or "Invalid coordinates.", "Please enter coordinates as LAT, LON.")
				showSpawnInfoPage()
				setButtonEnabled(SpawnInfoLoadButton, false)
				return
			end

			activeLookupRequestId += 1
			local lookupRequestId = activeLookupRequestId
			selectedLatitude = latitude
			selectedLongitude = longitude
			selectedPlaceName = "Custom Coordinates"
			isLookingUp = true
			isLookupComplete = false

			showSpawnInfoPage()
			setButtonEnabled(EnterCoordinatesContinueButton, false)
			setButtonEnabled(SpawnInfoLoadButton, false)
			setSpawnInfo("Searching nearby place...", string.format("LAT %.4f, LON %.4f", latitude, longitude))

			local pendingRequests = 2
			local resolvedName: string? = nil
			local resolvedCountry: string? = nil

			local function finishLookup()
				pendingRequests -= 1
				if pendingRequests > 0 or lookupRequestId ~= activeLookupRequestId then
					return
				end

				resolvedName = resolvedName or "Unknown Location"
				resolvedCountry = resolvedCountry or "Unknown Country"
				selectedPlaceName = resolvedName
				setSpawnInfo(resolvedName, resolvedCountry .. string.format(" | LAT %.4f, LON %.4f", latitude, longitude))
				isLookingUp = false
				isLookupComplete = true
				setButtonEnabled(EnterCoordinatesContinueButton, true)
				setButtonEnabled(SpawnInfoLoadButton, true)
			end

			ClientOSMApiInterface:Search(string.format("%.6f, %.6f", latitude, longitude), {
				Limit = 1,
				Language = getReverseLanguage(),
			})
				:andThen(function(response)
					if lookupRequestId ~= activeLookupRequestId then
						return
					end

					if response.Ok then
						local searchName, searchCountry = formatSearchLocation(response.Data)
						resolvedName = resolvedName or searchName
						resolvedCountry = resolvedCountry or searchCountry
					else
						local message = response.Error and response.Error.Message or "Coordinate search failed."
						warn(string.format("Coordinate search failed for %.6f, %.6f: %s", latitude, longitude, message))
					end
					finishLookup()
				end)
				:catch(function(errorValue)
					if lookupRequestId ~= activeLookupRequestId then
						return
					end

					warn(string.format("Coordinate search request failed: %s", tostring(errorValue)))
					finishLookup()
				end)

			ClientOSMApiInterface:Reverse(latitude, longitude, getReverseLanguage())
				:andThen(function(response)
					if lookupRequestId ~= activeLookupRequestId then
						return
					end

					if response.Ok then
						local reverseName, reverseCountry = formatReverseLocation(response.Data)
						resolvedName = reverseName or resolvedName
						resolvedCountry = reverseCountry or resolvedCountry
					else
						local message = response.Error and response.Error.Message or "Reverse geocoding failed."
						warn(string.format("Reverse geocoding failed for %.6f, %.6f: %s", latitude, longitude, message))
					end
					finishLookup()
				end)
				:catch(function(errorValue)
					if lookupRequestId ~= activeLookupRequestId then
						return
					end

					warn(string.format("Reverse geocoding request failed: %s", tostring(errorValue)))
					finishLookup()
				end)
		end)
	)
	table.insert(
		connections,
		SpawnInfoLoadButton.Activated:Connect(function()
			if not isLookupComplete or selectedLatitude == nil or selectedLongitude == nil then
				return
			end

			local latitude = selectedLatitude
			local longitude = selectedLongitude
			local placeName = selectedPlaceName

			UIController:ClosePopup()
			UIController:OpenScreen("Loading", {
				Lat = latitude,
				Lon = longitude,
				PlaceName = placeName,
			})
		end)
	)
end

function CustomCoordinatesPopup:StopFunctions()
	activeLookupRequestId += 1
	selectedLatitude = nil
	selectedLongitude = nil
	selectedPlaceName = "Custom Coordinates"

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	connections = {}
	local popupFrame = UIRoot.GetPopups():WaitForChild("CustomCoordinates")
	local BackButton = popupFrame.TopHolder.BackButton
	GuiButtonEffects:Clear(BackButton)

	local MainHolder = popupFrame.MainHolder
	local EnterCoordinatesPage = MainHolder.EnterCoordinates
	local EnterCoordinatesContinueButton = EnterCoordinatesPage.ContinueButton
	local SpawnInfoPage = MainHolder.SpawnInfo
	local SpawnInfoLoadButton = SpawnInfoPage.LoadButton
	EnterCoordinatesPage.Visible = true
	SpawnInfoPage.Visible = false
	EnterCoordinatesContinueButton.Active = true
	SpawnInfoLoadButton.Active = false
	GuiButtonEffects:Clear(EnterCoordinatesContinueButton)
	GuiButtonEffects:Clear(SpawnInfoLoadButton)
end

return CustomCoordinatesPopup

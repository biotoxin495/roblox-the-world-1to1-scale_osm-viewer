--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local Configs = ReplicatedStorage.App.Shared.Config

local UIRoot = require(script.Parent.Parent.UIRoot)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local PickSpawnUtils = require(script.Parent.Parent.Utils["PickSpawn.Screen.Utils"])

local Packages = ReplicatedStorage.App.Shared.Packages
local Signal = require(Packages.Signal)

local Mouse = require(Packages.Mouse)

local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)
local ScrollFrameScaler = require(script.Parent.Parent.Parent.ClientPackages.ScrollFrameScaler)
local GuiEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiEffects)

local ClientOSMApiInterface = require(script.Parent.Parent.Parent.Controllers.ClientOSMApiInterface)

local PickSpawn = {}
PickSpawn.__index = PickSpawn
PickSpawn.Name = "PickSpawn"
PickSpawn.Priority = 20

local mapController: PickSpawnUtils.MapController? = nil
local locationButtonConnection: RBXScriptConnection? = nil
local visibleLocationsConnection: Signal.Connection? = nil
local mapScaleConnection: Signal.Connection? = nil
local selectedLocationConnection: Signal.Connection? = nil
local mapDragStartedConnection: Signal.Connection? = nil
local mapDragEndedConnection: Signal.Connection? = nil
local mapPointSelectedConnection: Signal.Connection? = nil

local INITIAL_MAP_ZOOM = 2
local SEARCH_DEBOUNCE_SECONDS = 1

type LocationUIState = {
	Location: PickSpawnUtils.Location,
	LayoutOrder: number,
	UI: GuiObject,
	Click: GuiButton,
	ClickConnection: RBXScriptConnection,

	Lat: number?,
	Lon: number?,
}

-- Keyed by location ID so a location keeps its UI while it remains visible across map renders.
local activeLocationUIs = {} :: { [string]: LocationUIState }

PickSpawn.VisibleLocations = {} :: { PickSpawnUtils.Location }
PickSpawn.ActiveLocationUIs = activeLocationUIs
PickSpawn.KilometresPerPixel = 0
PickSpawn.MapZoom = 0
PickSpawn.IsMapDragging = false
PickSpawn.ManualSpawnMapPosition = nil :: Vector2?
PickSpawn.ManualSpawnLatitude = nil :: number?
PickSpawn.ManualSpawnLongitude = nil :: number?
PickSpawn.SearchQuery = ""
PickSpawn.IsSearchActive = false
PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
PickSpawn.LastProcessedSearchQuery = nil :: string?
PickSpawn.SearchGeneration = 0

local searchDebounceTask: thread? = nil
local activeSearchRequestQuery: string? = nil
local activeSearchRequestGeneration: number? = nil

local function disconnectMapDataSignals()
	if visibleLocationsConnection then
		visibleLocationsConnection:Disconnect()
		visibleLocationsConnection = nil
	end
	if mapScaleConnection then
		mapScaleConnection:Disconnect()
		mapScaleConnection = nil
	end
	if selectedLocationConnection then
		selectedLocationConnection:Disconnect()
		selectedLocationConnection = nil
	end
	if mapDragStartedConnection then
		mapDragStartedConnection:Disconnect()
		mapDragStartedConnection = nil
	end
	if mapDragEndedConnection then
		mapDragEndedConnection:Disconnect()
		mapDragEndedConnection = nil
	end
	if mapPointSelectedConnection then
		mapPointSelectedConnection:Disconnect()
		mapPointSelectedConnection = nil
	end
end

local function getLayer(clipFrame: GuiObject, name: string, zIndex: number): GuiObject
	local layer = clipFrame:FindFirstChild(name)
	if layer and layer:IsA("GuiObject") then
		return layer :: GuiObject
	end

	local newLayer = Instance.new("Frame")
	newLayer.Name = name
	newLayer.BackgroundTransparency = 1
	newLayer.BorderSizePixel = 0
	newLayer.Size = UDim2.fromScale(1, 1)
	newLayer.ZIndex = zIndex
	newLayer.Parent = clipFrame
	return newLayer
end

local function getLocationUIKey(location: PickSpawnUtils.Location): string
	if location.Id then
		return location.Id
	end

	return string.format("%s:%s:%s", location.Name or "Location", tostring(location.X), tostring(location.Y))
end

local function spawnLocationChosen(isPopularSpot, locationData)
	local Lat = locationData and locationData.Lat or 0
	local Lon = locationData and locationData.Lon or 0
	local Country = locationData and locationData.Country or "Unknown"
	local LocationName = locationData and locationData.LocationName or "Unknown"

	UIController:OpenPopup("PickSpawn", {
		Lat = Lat,
		Lon = Lon,
		Country = Country,
		IsPopularSpot = isPopularSpot,
		LocationName = LocationName,
	})
end

local function CountryCodeToEmoji(code)
	local A = 0x1F1E6
	code = code:upper()

	return utf8.char(A + string.byte(code, 1) - string.byte("A"), A + string.byte(code, 2) - string.byte("A"))
end

-- Locations and CountryLocations use a few different display names for the same country.
local COUNTRY_LOCATION_NAME_ALIASES = {
	["Brunei"] = "Brunei Darussalam",
	["Congo (Brazzaville)"] = "Congo",
	["Congo (Kinshasa)"] = "Congo (DRC)",
	["Curacao"] = "Curaçao",
	["Czechia"] = "Czech Republic",
	["East Timor"] = "Timor-Leste",
	["eSwatini"] = "Swaziland",
	["Guinea Bissau"] = "Guinea-Bissau",
	["Hong Kong S.A.R."] = "Hong Kong",
	["Macau S.A.R"] = "Macao",
	["North Macedonia"] = "Macedonia",
	["Russia"] = "Russian Federation",
	["South Korea"] = "Korea",
	["The Bahamas"] = "Bahamas",
	["The Gambia"] = "Gambia",
	["Turkey"] = "Türkiye (Turkey)",
	["United States of America"] = "United States",
}

type ApiTable = { [any]: any }

local function asApiTable(value: unknown): ApiTable?
	if type(value) == "table" then
		return value :: ApiTable
	end

	return nil
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

local function normaliseSearchResults(payload: unknown): { PickSpawnUtils.Location }
	local locations = {} :: { PickSpawnUtils.Location }

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

		local name = source.name or source.displayName or source.display_name or source.label
		if type(name) ~= "string" or name == "" then
			name = address and (address.name or address.city or address.town or address.village)
		end
		if type(name) ~= "string" or name == "" then
			name = "Unknown Location"
		end

		local country = source.country or (address and address.country)
		if type(country) ~= "string" or country == "" then
			country = "Unknown"
		end

		local id = source.id or source.placeId or source.place_id
		if type(id) ~= "string" and type(id) ~= "number" then
			id = string.format("search:%s:%.6f:%.6f", name, latitude, longitude)
		end

		table.insert(locations, {
			Id = tostring(id),
			Name = name,
			Country = country,
			Lat = latitude,
			Lon = longitude,
		})
	end

	return locations
end

local connections = {}

function PickSpawn:StartFunctions()
	Mouse.ChangeMouseIcon("DragInactive")

	disconnectMapDataSignals()
	PickSpawn.KilometresPerPixel = 0
	PickSpawn.MapZoom = 0
	PickSpawn.IsMapDragging = false
	PickSpawn.ManualSpawnMapPosition = nil
	PickSpawn.ManualSpawnLatitude = nil
	PickSpawn.ManualSpawnLongitude = nil
	PickSpawn.SearchQuery = ""
	PickSpawn.IsSearchActive = false
	PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
	PickSpawn.LastProcessedSearchQuery = nil
	PickSpawn.SearchGeneration += 1
	if searchDebounceTask then
		task.cancel(searchDebounceTask)
		searchDebounceTask = nil
	end
	if mapController then
		mapController:Stop()
	end
	if locationButtonConnection then
		locationButtonConnection:Disconnect()
		locationButtonConnection = nil
	end

	local pickSpawnScreen = UIRoot.GetScreens():WaitForChild("PickSpawn")
	local clipFrame = pickSpawnScreen:WaitForChild("ClipFrame") :: GuiObject
	local sideButtons = pickSpawnScreen:WaitForChild("RightSide"):WaitForChild("SideButtons") :: Frame
	local zoomInButton = sideButtons:WaitForChild("ZoomInBtn") :: GuiButton
	local zoomOutButton = sideButtons:WaitForChild("ZoomOutBtn") :: GuiButton
	local locationButton = sideButtons:WaitForChild("LocationBtn") :: GuiButton
	local leftSide = pickSpawnScreen:WaitForChild("LeftSide") :: GuiObject
	local topTitle = leftSide:WaitForChild("TopTitle") :: GuiObject
	local scrollFrame = leftSide:WaitForChild("Scroll") :: ScrollingFrame

	ScrollFrameScaler:StartScrollHandling(scrollFrame, "Y")

	local rightSide = pickSpawnScreen.RightSide
	local bottomScale = rightSide.BottomScale

	local locations = require(Configs.Locations)
	local tileManifest = require(Configs.TileManifest)
	local CountryLocations = require(Configs.CountryLocations)
	local countryCodesByName = {} :: { [string]: string }
	for countryCode, countryData in pairs(CountryLocations) do
		countryCodesByName[countryData.Name] = countryCode
	end

	local function getCountryEmoji(countryName: string): string
		local normalizedCountryName = COUNTRY_LOCATION_NAME_ALIASES[countryName] or countryName
		local countryCode = countryCodesByName[normalizedCountryName]
		if not countryCode then
			return ""
		end

		return CountryCodeToEmoji(countryCode)
	end
	function updateTopTitle()
		local titleText = if PickSpawn.IsSearchActive then "Search" else "Popular"
		local titleTarget = topTitle

		if titleTarget:IsA("TextLabel") then
			titleTarget.Text = titleText
			return
		end
		if titleTarget:IsA("TextButton") then
			titleTarget.Text = titleText
			return
		end

		local textTarget = titleTarget:FindFirstChildWhichIsA("TextLabel", true)
			or titleTarget:FindFirstChildWhichIsA("TextButton", true)
		if textTarget then
			if textTarget:IsA("TextLabel") then
				textTarget.Text = titleText
			elseif textTarget:IsA("TextButton") then
				textTarget.Text = titleText
			end
		end
	end

	mapController = PickSpawnUtils.CreateMap(
		clipFrame,
		leftSide,
		getLayer(clipFrame, "BaseTileLayer", 1),
		getLayer(clipFrame, "BorderTileLayer", 2),
		getLayer(clipFrame, "PinLayer", 10),
		zoomInButton,
		zoomOutButton,
		locations,
		tileManifest
	)
	if mapController then
		mapController.IsInputEnabled = function()
			return not UIController:IsPopupOpen()
		end
	end

	local function processLocationUIClick(location: LocationUIState)
		-- Stub: handle selecting a location from the side-panel list here.
		if UIController:IsPopupOpen() then
			return
		end

		local Lat = location.Location.Lat or 0
		local Lon = location.Location.Lon or 0
		local Country = location.Location.Country or "Unknown"
		if mapController then
			mapController:FocusLatLon(Lat, Lon)
		end

		spawnLocationChosen(true, {
			LocationName = location.Location.Name or "Unknown",
			Lat = Lat,
			Lon = Lon,
			Country = Country,
		})
	end

	local function setupLocationUI(location: PickSpawnUtils.Location, layoutOrder: number): LocationUIState
		-- Stub: clone/configure the side-panel location UI here once its template/container exists.

		local Country = location.Country or "Unknown"
		local Name = location.Name or "Unknown"

		local examples = pickSpawnScreen.Examples
		local clone = examples.LocationExample:Clone()

		clone.Parent = pickSpawnScreen.LeftSide.Scroll
		clone.Visible = true
		clone.LayoutOrder = layoutOrder
		clone.Name = "LocationUI_" .. getLocationUIKey(location)

		local Click = clone.Click
		Click.Title.Text = Name
		Click.DataDisplay.Country.Text = Country
		Click.TopLeftCountry.TextLabel.Text = getCountryEmoji(Country)

		GuiButtonEffects:SetupSimpleMouseOverEffect(Click)

		local locationUI: LocationUIState
		local clickConnection = Click.Activated:Connect(function()
			processLocationUIClick(locationUI)
		end)

		locationUI = {
			Location = location,
			LayoutOrder = layoutOrder,
			UI = clone,
			Click = Click,
			ClickConnection = clickConnection,
		}

		return locationUI
	end

	local function updateLocationUI(
		locationUI: LocationUIState,
		locationKey: string,
		location: PickSpawnUtils.Location,
		layoutOrder: number
	)
		-- Stub: update the existing side-panel UI's text, data, and LayoutOrder here.
		locationUI.Location = location
		locationUI.LayoutOrder = layoutOrder
	end

	local function clearLocationUI(locationUI: LocationUIState, locationKey: string)
		-- Stub: disconnect and destroy/return the side-panel UI to its pool here.
		locationUI.ClickConnection:Disconnect()
		GuiButtonEffects:Clear(locationUI.Click)
		locationUI.UI:Destroy()
	end
	function clearVisibleLocationUIs()
		for locationKey, locationUI in pairs(activeLocationUIs) do
			clearLocationUI(locationUI, locationKey)
			activeLocationUIs[locationKey] = nil
		end

		PickSpawn.VisibleLocations = {} :: { PickSpawnUtils.Location }
	end
	clearVisibleLocationUIs()
	local latestPopularLocations = {} :: { PickSpawnUtils.Location }

	local function reconcileVisibleLocationUIs(visibleLocations: { PickSpawnUtils.Location })
		local nextVisibleLocationKeys = {} :: { [string]: boolean }

		for layoutOrder, location in ipairs(visibleLocations) do
			local locationKey = getLocationUIKey(location)
			nextVisibleLocationKeys[locationKey] = true

			local locationUI = activeLocationUIs[locationKey]
			if locationUI then
				updateLocationUI(locationUI, locationKey, location, layoutOrder)
			else
				activeLocationUIs[locationKey] = setupLocationUI(location, layoutOrder)
			end
		end

		for locationKey, locationUI in pairs(activeLocationUIs) do
			if not nextVisibleLocationKeys[locationKey] then
				clearLocationUI(locationUI, locationKey)
				activeLocationUIs[locationKey] = nil
			end
		end

		PickSpawn.VisibleLocations = visibleLocations
	end

	local function updateMapScale()
		local kilometresPerPixel = PickSpawn.KilometresPerPixel
		local scaleFrame = bottomScale.ScaleHolder.Scale

		local absoluteSizeX = scaleFrame.AbsoluteSize.X
		local kilometresPerPixelAtScale = math.round(kilometresPerPixel * absoluteSizeX)
		bottomScale.ScaleHolder.ScaleText.Text = string.format("%d km", kilometresPerPixelAtScale)
	end

	local function focusPlayerCountry(initialZoom: number?)
		local success, countryRegion = pcall(function()
			return LocalizationService:GetCountryRegionForPlayerAsync(LocalPlayer)
		end)
		if not success or type(countryRegion) ~= "string" then
			warn("Could not determine the player's country region for map focus")
			return
		end

		local countryData = CountryLocations[countryRegion]
		if not countryData then
			warn(string.format("No map location is configured for country region %q", countryRegion))
			return
		end

		if not mapController then
			return
		end

		if initialZoom then
			mapController:SetViewLatLon(countryData.Lat, countryData.Lon, initialZoom)
		else
			mapController:FocusLatLon(countryData.Lat, countryData.Lon)
		end
	end

	if mapController then
		visibleLocationsConnection = mapController.VisibleLocationsChanged:Connect(function(visibleLocations)
			latestPopularLocations = visibleLocations
			if not PickSpawn.IsSearchActive then
				reconcileVisibleLocationUIs(latestPopularLocations)
			end
		end)
		mapScaleConnection = mapController.MapScaleChanged:Connect(function(kilometresPerPixel, zoom)
			-- Stub: use this scale for map UI such as a distance legend.
			PickSpawn.KilometresPerPixel = kilometresPerPixel
			PickSpawn.MapZoom = zoom
			updateMapScale()
		end)
		selectedLocationConnection = mapController.SelectedLocationPressed:Connect(function(locationName)
			if UIController:IsPopupOpen() then
				return
			end

			local locationData
			for _, location in pairs(locations) do
				if location.Name == locationName then
					locationData = location
					break
				end
			end
			local Lat = locationData and locationData.Lat or 0
			local Lon = locationData and locationData.Lon or 0
			local Country = locationData and locationData.Country or "Unknown"
			mapController:FocusLatLon(Lat, Lon)

			spawnLocationChosen(true, {
				LocationName = locationName,
				Lat = Lat,
				Lon = Lon,
				Country = Country,
			})
		end)
		mapDragStartedConnection = mapController.MapDragStarted:Connect(function(_isDragging)
			PickSpawn.IsMapDragging = true
			Mouse.ChangeMouseIcon("DragActive")
		end)
		mapDragEndedConnection = mapController.MapDragEnded:Connect(function(_isDragging)
			PickSpawn.IsMapDragging = false
			Mouse.ChangeMouseIcon("DragInactive")
		end)
		mapPointSelectedConnection = mapController.MapPointSelected:Connect(function(mapPosition, latitude, longitude)
			if UIController:IsPopupOpen() then
				return
			end

			-- Stub: use these coordinates to create the player's manual spawn point.
			PickSpawn.ManualSpawnMapPosition = mapPosition
			PickSpawn.ManualSpawnLatitude = latitude
			PickSpawn.ManualSpawnLongitude = longitude

			spawnLocationChosen(false, {
				Lat = latitude,
				Lon = longitude,
				Country = "Unknown",
				LocationName = "Unknown",
			})
		end)
		focusPlayerCountry(INITIAL_MAP_ZOOM)
		mapController:Start()
	end

	locationButtonConnection = locationButton.Activated:Connect(function()
		if UIController:IsPopupOpen() then
			return
		end

		focusPlayerCountry()
	end)

	for i, button in pairs(sideButtons:GetChildren()) do
		if button:IsA("TextButton") then
			local imageLabel = button:WaitForChild("ImageLabel")
			local sideButtonsEffects = {
				OnMouseEnter = {
					self = {
						BackgroundColor3 = Color3.fromRGB(27, 27, 27):Lerp(Color3.fromRGB(0, 0, 0), 0.2),
					},
					[imageLabel] = {
						ImageColor3 = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(0, 0, 0), 0.5),
					},
				},
				OnClickStart = {
					self = {
						BackgroundColor3 = Color3.fromRGB(27, 27, 27):Lerp(Color3.fromRGB(0, 0, 0), 0.4),
					},
					[imageLabel] = {
						ImageColor3 = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(0, 0, 0), 0.7),
					},
				},
			}

			GuiButtonEffects:Setup(button, sideButtonsEffects)
		end
	end

	local SearchByFrame = pickSpawnScreen.LeftSide.SearchBy
	local TextBox = SearchByFrame.TextBox
	local deleteButton = SearchByFrame.DeleteButton

	local LoadingImg = pickSpawnScreen.LeftSide.LoadingImg
	local function changeLoadingVisibility(isVisible: boolean)
		local goal = {
			Visible = isVisible,
			ImageTransparency = if isVisible then 0 else 1,
		}
		local tween = TweenService:Create(LoadingImg, TweenInfo.new(0.2, Enum.EasingStyle.Quad), goal)
		tween:Play()
		tween:Destroy()
	end

	local function beginSearchRequest(query: string, generation: number)
		activeSearchRequestQuery = query
		activeSearchRequestGeneration = generation
		print(string.format("OSM search started for %q (generation %d)", query, generation))
		changeLoadingVisibility(true)
		GuiEffects:SetupLoadingGui(LoadingImg)
	end
	function stopSearchRequest(query: string?, generation: number?)
		if query == nil or generation == nil then
			return
		end
		if activeSearchRequestQuery ~= query or activeSearchRequestGeneration ~= generation then
			return
		end

		print(string.format("OSM search stopped for %q (generation %d)", query, generation))
		activeSearchRequestQuery = nil
		activeSearchRequestGeneration = nil
		changeLoadingVisibility(false)
		GuiEffects:ClearLoadingGui(LoadingImg)
	end

	local function processSearch(query: string, generation: number)
		if
			not PickSpawn.IsSearchActive
			or PickSpawn.SearchQuery ~= query
			or PickSpawn.SearchGeneration ~= generation
		then
			return
		end
		if PickSpawn.LastProcessedSearchQuery == query then
			return
		end

		PickSpawn.LastProcessedSearchQuery = query

		local trimmedQuery = string.match(query, "^%s*(.-)%s*$") or ""
		if trimmedQuery == "" then
			PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
			reconcileVisibleLocationUIs(PickSpawn.SearchResults)
			return
		end

		beginSearchRequest(trimmedQuery, generation)

		ClientOSMApiInterface:Search(trimmedQuery)
			:andThen(function(response)
				if
					not PickSpawn.IsSearchActive
					or PickSpawn.SearchQuery ~= query
					or PickSpawn.SearchGeneration ~= generation
				then
					return
				end

				if not response.Ok then
					local message = response.Error and response.Error.Message or "OSM search failed."
					warn(string.format("OSM search failed for %q: %s", trimmedQuery, message))
					PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
					reconcileVisibleLocationUIs(PickSpawn.SearchResults)
					stopSearchRequest(trimmedQuery, generation)
					return
				end

				PickSpawn.SearchResults = normaliseSearchResults(response.Data)
				reconcileVisibleLocationUIs(PickSpawn.SearchResults)
				stopSearchRequest(trimmedQuery, generation)
			end)
			:catch(function(errorValue)
				if
					not PickSpawn.IsSearchActive
					or PickSpawn.SearchQuery ~= query
					or PickSpawn.SearchGeneration ~= generation
				then
					return
				end

				warn(string.format("OSM search request failed for %q: %s", trimmedQuery, tostring(errorValue)))
				PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
				reconcileVisibleLocationUIs(PickSpawn.SearchResults)
				stopSearchRequest(trimmedQuery, generation)
			end)
	end

	local function cancelPendingSearch()
		if searchDebounceTask then
			task.cancel(searchDebounceTask)
			searchDebounceTask = nil
		end
	end

	local function processTextboxTextChanged()
		local textboxText = TextBox.Text
		local isSearchActive = #textboxText > 0

		cancelPendingSearch()
		PickSpawn.SearchGeneration += 1
		PickSpawn.SearchQuery = textboxText
		PickSpawn.IsSearchActive = isSearchActive
		PickSpawn.LastProcessedSearchQuery = nil
		deleteButton.Visible = isSearchActive

		if not isSearchActive then
			PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
			reconcileVisibleLocationUIs(latestPopularLocations)
			updateTopTitle()
			return
		end

		-- New input invalidates any prior results until the new search is processed.
		PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
		reconcileVisibleLocationUIs(PickSpawn.SearchResults)
		updateTopTitle()

		local generation = PickSpawn.SearchGeneration
		searchDebounceTask = task.delay(SEARCH_DEBOUNCE_SECONDS, function()
			searchDebounceTask = nil
			processSearch(textboxText, generation)
		end)
	end

	table.insert(
		connections,
		deleteButton.Activated:Connect(function()
			TextBox.Text = ""
		end)
	)
	table.insert(connections, TextBox:GetPropertyChangedSignal("Text"):Connect(processTextboxTextChanged))
	table.insert(
		connections,
		TextBox.FocusLost:Connect(function()
			if not PickSpawn.IsSearchActive then
				return
			end

			cancelPendingSearch()
			processSearch(PickSpawn.SearchQuery, PickSpawn.SearchGeneration)
		end)
	)
	processTextboxTextChanged()
end

function PickSpawn:StopFunctions()
	disconnectMapDataSignals()
	if searchDebounceTask then
		task.cancel(searchDebounceTask)
		searchDebounceTask = nil
	end
	stopSearchRequest(activeSearchRequestQuery, activeSearchRequestGeneration)
	PickSpawn.SearchGeneration += 1
	PickSpawn.IsSearchActive = false
	PickSpawn.SearchQuery = ""
	PickSpawn.LastProcessedSearchQuery = nil
	PickSpawn.SearchResults = {} :: { PickSpawnUtils.Location }
	clearVisibleLocationUIs()
	updateTopTitle()
	PickSpawn.IsMapDragging = false
	PickSpawn.ManualSpawnMapPosition = nil
	PickSpawn.ManualSpawnLatitude = nil
	PickSpawn.ManualSpawnLongitude = nil
	if locationButtonConnection then
		locationButtonConnection:Disconnect()
		locationButtonConnection = nil
	end

	if mapController then
		mapController:Stop()
		mapController = nil
	end

	for i, button in pairs(UIRoot.GetScreens().PickSpawn.RightSide.SideButtons:GetChildren()) do
		if button:IsA("TextButton") then
			GuiButtonEffects:Clear(button)
		end
	end

	for i, v in pairs(connections) do
		v:Disconnect()
	end
	connections = {}

	ScrollFrameScaler:StopScrollHandling(UIRoot.GetScreens().PickSpawn.LeftSide.Scroll)
end

return PickSpawn

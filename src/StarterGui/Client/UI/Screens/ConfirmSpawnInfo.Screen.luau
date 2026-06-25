-- !strict

local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local ConfirmSpawnUtils = require(script.Parent.Parent.Utils["ConfirmSpawnInfo.Screen.Utils"])
local OsmApiReturnedDataUtils = require(script.Parent.Parent.Utils["OsmApiReturnedData.Utils"])
local DefaultOsmApiReturnedData = require(game.ReplicatedStorage.App.OsmApiReturnedData)

local ConfirmSpawnInfo = {}
ConfirmSpawnInfo.__index = ConfirmSpawnInfo
ConfirmSpawnInfo.Name = "ConfirmSpawnInfo"

local mapRenderer: ConfirmSpawnUtils.MapRenderer? = nil
local isGeneratingMap = false

local function destroyMap()
	if mapRenderer then
		mapRenderer:Destroy()
		mapRenderer = nil
	end
end

local function buildAddressText(address)
	local parts = {}

	local function addPart(value)
		if typeof(value) == "string" and value ~= "" then
			table.insert(parts, value)
		end
	end

	addPart(address and address.neighbourhood)
	addPart(address and address.city)
	addPart(address and address.county)
	addPart(address and address.state)
	addPart(address and address.postcode)
	addPart(address and address.country)

	if #parts == 0 then
		return "Unknown Address"
	end

	return table.concat(parts, ", ")
end

local function normaliseOsmApiReturnedData(osmApiReturnedData: any): any
	-- The bundled data is a raw chunk response, whereas the live initial request
	-- includes that response under `chunk` alongside the selected location.
	-- Adapt raw responses to the live shape so the remainder of this screen has
	-- one consistent data contract.
	local function wrapRawChunk(rawChunk: any): any
		if type(rawChunk) ~= "table" or type(rawChunk.chunk) ~= "table" then
			return nil
		end

		local origin = if type(rawChunk.origin) == "table" then rawChunk.origin else {}
		return {
			origin = origin,
			location = if type(rawChunk.location) == "table"
				then rawChunk.location
				else {
					lat = origin.lat,
					lon = origin.lon,
				},
			chunk = rawChunk,
		}
	end

	if type(osmApiReturnedData) == "table" then
		if type(osmApiReturnedData.roads) == "table" then
			return wrapRawChunk(osmApiReturnedData)
		end

		if type(osmApiReturnedData.chunk) == "table" then
			return osmApiReturnedData
		end
	end

	return wrapRawChunk(DefaultOsmApiReturnedData)
end

local connections = {}

function ConfirmSpawnInfo:StartFunctions(osmApiReturnedData)
	destroyMap()
	osmApiReturnedData = normaliseOsmApiReturnedData(osmApiReturnedData)

	if type(osmApiReturnedData) ~= "table" then
		warn("ConfirmSpawnInfo requires initial OSM data or a valid bundled fallback.")
		UIController:OpenScreen("PickSpawn")
		return
	end

	local confirmSpawnInfoScreen = UIRoot.GetScreens():WaitForChild("ConfirmSpawnInfo")
	local clipFrame = confirmSpawnInfoScreen:WaitForChild("ClipFrame") :: GuiObject

	local locationData = if type(osmApiReturnedData.location) == "table" then osmApiReturnedData.location else {}
	local osmSummary = OsmApiReturnedDataUtils.Process(osmApiReturnedData)
	confirmSpawnInfoScreen:SetAttribute("RoadsCount", osmSummary.Counts.Roads)
	confirmSpawnInfoScreen:SetAttribute("BuildingsCount", osmSummary.Counts.Buildings)
	confirmSpawnInfoScreen:SetAttribute("WaterCount", osmSummary.Counts.Water)
	confirmSpawnInfoScreen:SetAttribute("POIsCount", osmSummary.Counts.POIs)
	confirmSpawnInfoScreen:SetAttribute("RoadsAmount", osmSummary.Densities.Roads)
	confirmSpawnInfoScreen:SetAttribute("BuildingsAmount", osmSummary.Densities.Buildings)
	confirmSpawnInfoScreen:SetAttribute("WaterAmount", osmSummary.Densities.Water)
	confirmSpawnInfoScreen:SetAttribute("POIsAmount", osmSummary.Densities.POIs)

	print(osmSummary, "osm summary")

	local ExpectedDetailList = confirmSpawnInfoScreen.LeftSide.ExpectedDetailList
	ExpectedDetailList.Roads.DetailValue.Text = osmSummary.Densities.Roads
	ExpectedDetailList.Buildings.DetailValue.Text = osmSummary.Densities.Buildings
	ExpectedDetailList.Water.DetailValue.Text = osmSummary.Densities.Water
	ExpectedDetailList.POIs.DetailValue.Text = osmSummary.Densities.POIs

	local renderer = ConfirmSpawnUtils.Create(clipFrame, osmApiReturnedData.chunk)
	mapRenderer = renderer
	renderer:Render()

	local leftSide = confirmSpawnInfoScreen.LeftSide
	leftSide.SubLocationInfo.Latitude.Text = string.format("LAT %.5f", locationData.lat or 0)
	leftSide.SubLocationInfo.Longitude.Text = string.format("LON %.5f", locationData.lon or 0)

	leftSide.MainInfo.PlaceName.Text = locationData.name or "Unknown Location"
	leftSide.MainInfo.PlaceSubname.Text = buildAddressText(locationData.address)

	local spawnButton = confirmSpawnInfoScreen.SpawnButton
	spawnButton.Active = true
	table.insert(
		connections,
		spawnButton.Activated:Connect(function()
			if UIController:IsPopupOpen() or isGeneratingMap then
				return
			end

			local latitude = type(locationData) == "table" and tonumber(locationData.lat) or nil
			local longitude = type(locationData) == "table" and tonumber(locationData.lon) or nil
			if type(latitude) ~= "number" or type(longitude) ~= "number" then
				warn("Cannot generate an OSM map without valid spawn coordinates.")
				return
			end

			isGeneratingMap = true
			spawnButton.Active = false
			UIController:OpenScreen("Loading", {
				TargetScreen = "IngameHUD",
				PlaceName = locationData.name or "Unknown Location",
				Latitude = latitude,
				Longitude = longitude,
				MapData = osmApiReturnedData,
			})
		end)
	)
	GuiButtonEffects:SetupFromTemplate(spawnButton, "GreenButton")

	local backButton = confirmSpawnInfoScreen.LeftSide.BackButton
	table.insert(
		connections,
		backButton.Activated:Connect(function()
			if UIController:IsPopupOpen() then
				return
			end

			UIController:OpenScreen("PickSpawn")
		end)
	)
	local effects = {
		OnMouseEnter = {
			self = {
				BackgroundColor3 = Color3.fromRGB(27, 27, 27):Lerp(Color3.fromRGB(255, 255, 255), 0.2),
			},
		},
		OnClickStart = {
			self = {
				BackgroundColor3 = Color3.fromRGB(27, 27, 27):Lerp(Color3.fromRGB(255, 255, 255), 0.4),
			},
		},
	}
	GuiButtonEffects:Setup(backButton, effects)
end

function ConfirmSpawnInfo:StopFunctions()
	destroyMap()
	isGeneratingMap = false
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	connections = {}

	local confirmSpawnInfoScreen = UIRoot.GetScreens():WaitForChild("ConfirmSpawnInfo")
	local spawnButton = confirmSpawnInfoScreen.SpawnButton
	GuiButtonEffects:Clear(spawnButton)
	GuiButtonEffects:Clear(confirmSpawnInfoScreen.LeftSide.BackButton)
end

return ConfirmSpawnInfo

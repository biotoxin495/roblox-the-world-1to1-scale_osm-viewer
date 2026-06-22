-- !strict

local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local ClientOSMApiInterface = require(script.Parent.Parent.Parent.Controllers.ClientOSMApiInterface)
local PickSpawnUtils = require(script.Parent.Parent.Utils["PickSpawn.Screen.Utils"])
local ConfirmSpawnUtils = require(script.Parent.Parent.Utils["ConfirmSpawnInfo.Screen.Utils"])
local OsmApiReturnedDataUtils = require(script.Parent.Parent.Utils["OsmApiReturnedData.Utils"])

local ConfirmSpawnInfo = {}
ConfirmSpawnInfo.__index = ConfirmSpawnInfo
ConfirmSpawnInfo.Name = "ConfirmSpawnInfo"

local mapRenderer: ConfirmSpawnUtils.MapRenderer? = nil
local mapController: PickSpawnUtils.MapController? = nil
local mapViewChangedConnection: any = nil
local interactionSupport: Frame? = nil
local mapLoadGeneration = 0

local MAX_CHUNK_DISTANCE = 10
local MAX_CONCURRENT_CHUNK_REQUESTS = 6

-- Debug only: exposes the PickSpawn camera without pan or zoom limits so the
-- OSM renderer can be inspected independently of normal map bounds.
local DEBUG_ALLOW_UNBOUNDED_MAP_CAMERA = true

local OSM_INTERACTION_TILE_MANIFEST: PickSpawnUtils.TileManifest = {
	-- The PickSpawn controller owns all input, drag thresholds, wheel behaviour,
	-- zoom animation, and camera bounds. This empty manifest intentionally
	-- suppresses its raster tile rendering; the OSM vector renderer is the map.
	TileSize = 256,
	MinZoom = 0,
	MaxZoom = 4,
	Layers = {
		base = {},
		borders = {},
	},
}

local function createLayer(parent: Instance, name: string, zIndex: number): Frame
	local layer = Instance.new("Frame")
	layer.Name = name
	layer.Active = false
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = zIndex
	layer.Parent = parent
	return layer
end

local function createZoomButton(parent: GuiObject, name: string, text: string, position: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(1, 1)
	button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	button.BackgroundTransparency = 0.1
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.Position = position
	button.Size = UDim2.fromOffset(32, 32)
	button.Text = text
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 20
	button.ZIndex = parent.ZIndex + 1
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = button

	return button
end

local function destroyMap()
	mapLoadGeneration += 1
	if mapViewChangedConnection then
		mapViewChangedConnection:Disconnect()
		mapViewChangedConnection = nil
	end
	if mapController then
		mapController:Stop()
		mapController = nil
	end
	if mapRenderer then
		mapRenderer:Destroy()
		mapRenderer = nil
	end
	if interactionSupport then
		interactionSupport:Destroy()
		interactionSupport = nil
	end
end

local function getChunkRequestInfo(osmApiReturnedData)
	local initialChunk = if type(osmApiReturnedData) == "table" then osmApiReturnedData.chunk else nil
	local metadata = if type(initialChunk) == "table" and type(initialChunk.chunk) == "table"
		then initialChunk.chunk
		else {}
	local origin = if type(initialChunk) == "table" and type(initialChunk.origin) == "table"
		then initialChunk.origin
		elseif type(osmApiReturnedData) == "table" and type(osmApiReturnedData.origin) == "table"
			then osmApiReturnedData.origin
			elseif type(osmApiReturnedData) == "table" and type(osmApiReturnedData.location) == "table"
				then osmApiReturnedData.location
			else nil

	local originLat = origin and tonumber(origin.lat)
	local originLon = origin and tonumber(origin.lon)
	local chunkSize = tonumber(metadata.size) or 256

	return originLat, originLon, tonumber(metadata.x) or 0, tonumber(metadata.z) or 0, chunkSize
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

local connections = {}

function ConfirmSpawnInfo:StartFunctions(osmApiReturnedData)
	destroyMap()

	if type(osmApiReturnedData) ~= "table" then
		warn("ConfirmSpawnInfo requires initial OSM data.")
		UIController:OpenScreen("PickSpawn")
		return
	end

	local confirmSpawnInfoScreen = UIRoot.GetScreens():WaitForChild("ConfirmSpawnInfo")
	local clipFrame = confirmSpawnInfoScreen:WaitForChild("ClipFrame") :: GuiObject

	local locationData = osmApiReturnedData.location
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
	local requestGeneration = mapLoadGeneration
	local originLat, originLon, initialChunkX, initialChunkZ, chunkSize = getChunkRequestInfo(osmApiReturnedData)
	local loadedChunks = {
		[string.format("%d:%d", initialChunkX, initialChunkZ)] = true,
	} :: { [string]: boolean }
	local queuedChunks = {} :: { { X: number, Z: number, Key: string } }
	local queuedChunkKeys = {} :: { [string]: boolean }
	local failedChunks = {} :: { [string]: boolean }
	local activeChunkRequests = 0
	local requestVisibleChunks: () -> ()
	local processNextChunk: () -> ()

	processNextChunk = function()
		if requestGeneration ~= mapLoadGeneration or renderer ~= mapRenderer then
			return
		end

		while activeChunkRequests < MAX_CONCURRENT_CHUNK_REQUESTS do
			local nextChunk = table.remove(queuedChunks, 1)
			while nextChunk and (loadedChunks[nextChunk.Key] or failedChunks[nextChunk.Key]) do
				queuedChunkKeys[nextChunk.Key] = nil
				nextChunk = table.remove(queuedChunks, 1)
			end
			if not nextChunk then
				return
			end

			queuedChunkKeys[nextChunk.Key] = nil
			activeChunkRequests += 1
			renderer:SetChunkLoading(nextChunk.X, nextChunk.Z, true)
			ClientOSMApiInterface:Chunk({
				OriginLat = originLat or 0,
				OriginLon = originLon or 0,
				ChunkX = nextChunk.X,
				ChunkZ = nextChunk.Z,
				ChunkSize = chunkSize,
			})
				:andThen(function(response)
					if requestGeneration ~= mapLoadGeneration or renderer ~= mapRenderer then
						return
					end

					if response.Ok and type(response.Data) == "table" then
						loadedChunks[nextChunk.Key] = true
						renderer:AddChunk(nextChunk.X, nextChunk.Z, response.Data)
					else
						failedChunks[nextChunk.Key] = true
						local message = response.Error and response.Error.Message or "Unknown chunk request failure."
						warn(string.format("OSM chunk %s failed: %s", nextChunk.Key, message))
					end
				end)
				:catch(function(errorValue)
					if requestGeneration == mapLoadGeneration and renderer == mapRenderer then
						failedChunks[nextChunk.Key] = true
						warn(string.format("OSM chunk %s request failed: %s", nextChunk.Key, tostring(errorValue)))
					end
				end)
				:finally(function()
					activeChunkRequests -= 1
					if requestGeneration == mapLoadGeneration and renderer == mapRenderer then
						if not loadedChunks[nextChunk.Key] then
							renderer:SetChunkLoading(nextChunk.X, nextChunk.Z, false)
						end
						requestVisibleChunks()
					end
				end)
		end
	end

	requestVisibleChunks = function()
		if requestGeneration ~= mapLoadGeneration or renderer ~= mapRenderer then
			return
		end

		local visibleChunkKeys = {} :: { [string]: boolean }
		for _, coordinate in ipairs(renderer:GetVisibleChunkCoordinates(MAX_CHUNK_DISTANCE)) do
			local key = string.format("%d:%d", coordinate.X, coordinate.Z)
			visibleChunkKeys[key] = true
			if not loadedChunks[key] and not failedChunks[key] and not queuedChunkKeys[key] then
				queuedChunkKeys[key] = true
				table.insert(queuedChunks, {
					X = coordinate.X,
					Z = coordinate.Z,
					Key = key,
				})
			end
		end

		-- Do not continue fetching chunks the player has already dragged away
		-- from. Loaded chunks stay cached for the lifetime of this screen.
		for index = #queuedChunks, 1, -1 do
			local queuedChunk = queuedChunks[index]
			if not visibleChunkKeys[queuedChunk.Key] then
				queuedChunkKeys[queuedChunk.Key] = nil
				table.remove(queuedChunks, index)
			end
		end

		processNextChunk()
	end

	if type(originLat) ~= "number" or type(originLon) ~= "number" then
		warn("Cannot stream OSM chunks: initial response has no valid origin.")
		requestVisibleChunks = function() end
	end

	-- Keep the controller support restricted to the controls themselves. A full
	-- transparent frame above the map would become the pointer target and stop
	-- ClipFrame (which PickSpawnUtils listens to) from receiving drag starts.
	local support = createLayer(clipFrame, "OsmMapInteractionSupport", clipFrame.ZIndex + 10)
	interactionSupport = support
	support.AnchorPoint = Vector2.new(1, 1)
	support.Position = UDim2.fromScale(1, 1)
	support.Size = UDim2.fromOffset(76, 44)
	local baseTileLayer = createLayer(support, "BaseTileLayer", support.ZIndex)
	local borderTileLayer = createLayer(support, "BorderTileLayer", support.ZIndex + 1)
	local pinLayer = createLayer(support, "PinLayer", support.ZIndex + 2)

	local zoomOutButton = createZoomButton(support, "ZoomOutBtn", "−", UDim2.fromOffset(36, 38))
	local zoomInButton = createZoomButton(support, "ZoomInBtn", "+", UDim2.fromOffset(70, 38))
	local locations = {} :: { PickSpawnUtils.Location }
	local controller = PickSpawnUtils.CreateMap(
		clipFrame,
		support,
		baseTileLayer,
		borderTileLayer,
		pinLayer,
		zoomInButton,
		zoomOutButton,
		locations,
		OSM_INTERACTION_TILE_MANIFEST
	)
	controller.AllowUnboundedCamera = DEBUG_ALLOW_UNBOUNDED_MAP_CAMERA
	controller.IsInputEnabled = function()
		return not UIController:IsPopupOpen()
	end
	mapController = controller
	mapViewChangedConnection = controller.ViewChanged:Connect(function(center, zoom, worldSize, zoomScale, zoomAnchor)
		renderer:SetCamera(center, zoom, worldSize, zoomScale, zoomAnchor)
		requestVisibleChunks()
	end)

	controller:Start()
	renderer:Render()

	local leftSide = confirmSpawnInfoScreen.LeftSide
	leftSide.SubLocationInfo.Latitude.Text = string.format("LAT %.5f", locationData.lat or 0)
	leftSide.SubLocationInfo.Longitude.Text = string.format("LON %.5f", locationData.lon or 0)

	leftSide.MainInfo.PlaceName.Text = locationData.name or "Unknown Location"
	leftSide.MainInfo.PlaceSubname.Text = buildAddressText(locationData.address)

	local spawnButton = confirmSpawnInfoScreen.SpawnButton
	table.insert(
		connections,
		spawnButton.Activated:Connect(function()
			if UIController:IsPopupOpen() then
				return
			end

			print("Spawn button clicked") -- IGNORE
			-- Handle spawn button click here
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

local UIRoot = require(script.Parent.Parent.UIRoot)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)
local Notifications = require(script.Parent.Parent.Parent.ClientPackages.Notifications)

local ClientOSMApiInterface = require(script.Parent.Parent.Parent.Controllers.ClientOSMApiInterface)
local Packages = game:GetService("ReplicatedStorage").App.Shared.Packages
local OSMWorldRenderer = require(Packages.OSMMap.World3DRenderer)
local ConfirmSpawnInfoUtils = require(Packages.OSMMap.ChunkPreviewRenderer)
local DefaultOsmApiReturnedData = require(game.ReplicatedStorage.App.OsmApiReturnedData)

local IngameHUD = {}
IngameHUD.__index = IngameHUD
IngameHUD.Name = "IngameHUD"

local connections = {}
local worldRenderer = OSMWorldRenderer.Create()
local localPlayer = Players.LocalPlayer
local minimapRenderer: ConfirmSpawnInfoUtils.MapRenderer? = nil
local minimapMarker: Frame? = nil

local DEFAULT_LAYER_VISIBILITY = {
	Roads = true,
	Buildings = true,
	Water = true,
	Landuse = true,
	Trees = true,
	Pois = true,
	Boundaries = true,
}
local MINIMAP_ZOOM = 2
local CHUNK_EDGE_THRESHOLD = 0.4
local CHUNK_RETRY_DELAY = 3
-- The server coalesces only identical URLs, so distinct chunk requests can run
-- concurrently. Keep a bounded client limit to avoid burst-loading the API.
local MAX_CONCURRENT_CHUNK_REQUESTS = 3
local hudGeneration = 0
local compassCleanup: (() -> ())? = nil

local COMPASS_BAR_WIDTH = 620
local COMPASS_BAR_HEIGHT = 54
local COMPASS_DEGREES_VISIBLE = 120
local COMPASS_LABEL_SPACING_DEGREES = 30
local COMPASS_TICK_SPACING_DEGREES = 5
local COMPASS_LABEL_BUFFER_DEGREES = 20
local COMPASS_TICK_BUFFER_DEGREES = 10
local COMPASS_MIN_LABEL_TEXT_SIZE = 16
local COMPASS_MAX_LABEL_TEXT_SIZE = 27

local COMPASS_CARDINAL_LABELS = {
	[0] = "N",
	[90] = "E",
	[180] = "S",
	[270] = "W",
}

local OSM_VECTOR_CHUNK_LAYERS = {
	"roads",
	"buildings",
	"water",
	"landuse",
	"trees",
	"pois",
}

local function getMapLocation(mapData)
	if type(mapData) ~= "table" then
		return {}
	end
	if type(mapData.location) == "table" then
		return mapData.location
	end
	if type(mapData.chunk) == "table" and type(mapData.chunk.location) == "table" then
		return mapData.chunk.location
	end
	return {}
end

local function getMapChunk(mapData)
	if type(mapData) ~= "table" then
		return nil
	end
	if type(mapData.roads) == "table" then
		return mapData
	end
	if type(mapData.chunk) == "table" and type(mapData.chunk.roads) == "table" then
		return mapData.chunk
	end
	return nil
end

local function getChunkKey(chunkX: number, chunkZ: number): string
	return string.format("%d:%d", chunkX, chunkZ)
end

local function getChunkBounds(mapData)
	local chunk = getMapChunk(mapData)
	local metadata = chunk and chunk.chunk
	if type(metadata) ~= "table" then
		return nil
	end
	local minX, minZ = tonumber(metadata.minX), tonumber(metadata.minZ)
	local maxX, maxZ = tonumber(metadata.maxX), tonumber(metadata.maxZ)
	if not minX or not minZ or not maxX or not maxZ or maxX <= minX or maxZ <= minZ then
		return nil
	end
	return minX, minZ, maxX, maxZ
end

local function finiteNumber(value): number?
	local numberValue = tonumber(value)
	if numberValue and numberValue == numberValue and numberValue ~= math.huge and numberValue ~= -math.huge then
		return numberValue
	end
	return nil
end

local function readMapPoint(point: any): Vector2?
	if type(point) ~= "table" then
		return nil
	end

	local x = finiteNumber(point[1])
	local z = finiteNumber(point[3]) or finiteNumber(point[2])
	if not x or not z then
		return nil
	end

	return Vector2.new(x, z)
end

local function readFeatureName(feature: any): string?
	if type(feature) ~= "table" or type(feature.name) ~= "string" or feature.name == "" then
		return nil
	end

	return feature.name
end

local function distanceSquaredToSegment(point: Vector2, segmentStart: Vector2, segmentEnd: Vector2): number
	local segment = segmentEnd - segmentStart
	local segmentLengthSquared = segment:Dot(segment)
	if segmentLengthSquared <= 0.000001 then
		local delta = point - segmentStart
		return delta:Dot(delta)
	end

	local alpha = math.clamp((point - segmentStart):Dot(segment) / segmentLengthSquared, 0, 1)
	local closestPoint = segmentStart + segment * alpha
	local delta = point - closestPoint
	return delta:Dot(delta)
end

local function findClosestNamedFeature(
	loadedChunks: { [string]: { X: number, Z: number, Data: any } },
	mapPosition: Vector3
): string?
	local queryPoint = Vector2.new(mapPosition.X, mapPosition.Z)
	local closestName: string? = nil
	local closestDistanceSquared = math.huge

	for _, chunkInfo in pairs(loadedChunks) do
		local chunk = getMapChunk(chunkInfo.Data)
		if type(chunk) ~= "table" then
			continue
		end

		if type(chunk.pois) == "table" then
			for _, poi in ipairs(chunk.pois) do
				local name = readFeatureName(poi)
				local position = type(poi) == "table" and readMapPoint(poi.position) or nil
				if name and position then
					local delta = queryPoint - position
					local distanceSquared = delta:Dot(delta)
					if distanceSquared < closestDistanceSquared then
						closestName = name
						closestDistanceSquared = distanceSquared
					end
				end
			end
		end

		if type(chunk.roads) == "table" then
			for _, road in ipairs(chunk.roads) do
				local name = readFeatureName(road)
				if not name or type(road) ~= "table" or type(road.points) ~= "table" then
					continue
				end

				local previousPoint: Vector2? = nil
				for _, rawPoint in ipairs(road.points) do
					local point = readMapPoint(rawPoint)
					if point then
						if previousPoint then
							local distanceSquared = distanceSquaredToSegment(queryPoint, previousPoint, point)
							if distanceSquared < closestDistanceSquared then
								closestName = name
								closestDistanceSquared = distanceSquared
							end
						else
							local delta = queryPoint - point
							local distanceSquared = delta:Dot(delta)
							if distanceSquared < closestDistanceSquared then
								closestName = name
								closestDistanceSquared = distanceSquared
							end
						end
						previousPoint = point
					end
				end
			end
		end
	end

	return closestName
end

-- Notification stubs. Replace these with the game's notification service when
-- that system is available.
local function notifyChunkLoadingStarted(chunkKey: string)
	Notifications:SendNotification({
		Type = "Info",
		Text = string.format("Chunk %s loading started.", chunkKey),
	})
end

local function notifyChunkLoadingFinished(chunkKey: string)
	Notifications:SendNotification({
		Type = "Success",
		Text = string.format("Chunk %s loading finished.", chunkKey),
	})
end

local function notifyChunkLoadingFailed(chunkKey: string, message: string)
	Notifications:SendNotification({
		Type = "Warning",
		Text = string.format("Chunk %s failed to load: %s", chunkKey, message),
	})
end

local function createMinimapMarker(parent: GuiObject): Frame
	local marker = Instance.new("Frame")
	marker.Name = "PlayerMarker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundColor3 = Color3.fromRGB(77, 181, 111)
	marker.BorderSizePixel = 0
	marker.Size = UDim2.fromOffset(10, 10)
	marker.Visible = false
	marker.ZIndex = parent.ZIndex + 50
	marker.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = marker

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 1.5
	stroke.Parent = marker
	return marker
end

local function updateMinimapMarker(mapData, worldPosition: Vector3)
	local renderer = minimapRenderer
	local marker = minimapMarker
	local mapChunk = getMapChunk(mapData)
	if not renderer or not marker or type(mapChunk) ~= "table" or type(mapChunk.chunk) ~= "table" then
		return
	end

	local metadata = mapChunk.chunk
	local minX, minZ = tonumber(metadata.minX), tonumber(metadata.minZ)
	local maxX, maxZ = tonumber(metadata.maxX), tonumber(metadata.maxZ)
	if not minX or not minZ or not maxX or not maxZ or maxX <= minX or maxZ <= minZ then
		return
	end

	local mapPosition = worldRenderer:WorldPositionToMap(worldPosition)
	local layerSize = renderer.Layer.AbsoluteSize
	local canvasSide = math.max(layerSize.X, layerSize.Y)
	if canvasSide < 1 then
		return
	end

	local relativeX = (mapPosition.X - minX) / (maxX - minX)
	local relativeZ = (mapPosition.Z - minZ) / (maxZ - minZ)
	local zoomFactor = 2 ^ MINIMAP_ZOOM
	renderer:SetCamera(
		Vector2.new(relativeX, 1 - relativeZ),
		MINIMAP_ZOOM,
		Vector2.new(canvasSide * zoomFactor, canvasSide * zoomFactor),
		1,
		nil
	)

	-- The camera follows the player, so the marker remains fixed at the centre
	-- even after the player walks beyond the initial chunk bounds.
	marker.Visible = true
	marker.Position = UDim2.fromScale(0.5, 0.5)
end

local function normalizeDegrees(degrees: number): number
	degrees %= 360
	return if degrees < 0 then degrees + 360 else degrees
end

local function getCompassHeading(lookVector: Vector3): number
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude <= 0.001 then
		return 0
	end

	flatLook = flatLook.Unit
	return normalizeDegrees(math.deg(math.atan2(flatLook.X, -flatLook.Z)))
end

local function shortestAngleDifference(targetDegrees: number, currentDegrees: number): number
	return (targetDegrees - currentDegrees + 180) % 360 - 180
end

local function createCompass(parent: GuiObject): () -> ()
	local existingCompass = parent:FindFirstChild("GeneratedCompass")
	if existingCompass then
		existingCompass:Destroy()
	end

	local bar = Instance.new("Frame")
	bar.Name = "GeneratedCompass"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 18)
	bar.Size = UDim2.fromOffset(COMPASS_BAR_WIDTH, COMPASS_BAR_HEIGHT)
	bar.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	bar.BackgroundTransparency = 0.35
	bar.BorderSizePixel = 0
	bar.ClipsDescendants = true
	bar.ZIndex = 10
	bar.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = bar

	local centerMarker = Instance.new("Frame")
	centerMarker.Name = "CenterMarker"
	centerMarker.AnchorPoint = Vector2.new(0.5, 0.5)
	centerMarker.Position = UDim2.fromScale(0.5, 0.5)
	centerMarker.Size = UDim2.fromOffset(2, COMPASS_BAR_HEIGHT - 12)
	centerMarker.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	centerMarker.BackgroundTransparency = 0.25
	centerMarker.BorderSizePixel = 0
	centerMarker.ZIndex = 15
	centerMarker.Parent = bar

	local activeLabels = {} :: { [number]: TextLabel }
	local activeTicks = {} :: { [number]: Frame }

	local function isLabelDegree(degrees: number): boolean
		return degrees % COMPASS_LABEL_SPACING_DEGREES == 0
	end

	local function isCardinalDegree(degrees: number): boolean
		return COMPASS_CARDINAL_LABELS[degrees] ~= nil
	end

	local function createLabel(degrees: number): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = "Label_" .. degrees
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Size = UDim2.fromOffset(70, 32)
		label.BackgroundTransparency = 1
		label.Text = COMPASS_CARDINAL_LABELS[degrees] or tostring(degrees / 10)
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0.45
		label.TextSize = COMPASS_MIN_LABEL_TEXT_SIZE
		label.Font = Enum.Font.GothamBold
		label.ZIndex = 13
		label.Parent = bar
		return label
	end

	local function createTick(degrees: number): Frame
		local tick = Instance.new("Frame")
		tick.Name = "Tick_" .. degrees
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		tick.BackgroundTransparency = 0.25
		tick.BorderSizePixel = 0
		tick.ZIndex = 12
		tick.Parent = bar
		return tick
	end

	local function getTickHeight(degrees: number): number
		if isCardinalDegree(degrees) then
			return 18
		elseif isLabelDegree(degrees) then
			return 14
		elseif degrees % 10 == 0 then
			return 10
		end
		return 6
	end

	local function getTickWidth(degrees: number): number
		return if isCardinalDegree(degrees) or isLabelDegree(degrees) then 2 else 1
	end

	local function updateCompass()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		local barWidth = bar.AbsoluteSize.X
		if barWidth <= 0 then
			return
		end

		local heading = getCompassHeading(camera.CFrame.LookVector)
		local halfVisibleDegrees = COMPASS_DEGREES_VISIBLE / 2
		local pixelsPerDegree = barWidth / COMPASS_DEGREES_VISIBLE
		local barCenterX = barWidth / 2
		local neededTicks = {} :: { [number]: boolean }
		local neededLabels = {} :: { [number]: boolean }

		for degrees = 0, 355, COMPASS_TICK_SPACING_DEGREES do
			local difference = shortestAngleDifference(degrees, heading)
			if math.abs(difference) <= halfVisibleDegrees + COMPASS_TICK_BUFFER_DEGREES then
				neededTicks[degrees] = true
				local tick = activeTicks[degrees] or createTick(degrees)
				activeTicks[degrees] = tick

				local tickHeight = getTickHeight(degrees)
				local tickWidth = getTickWidth(degrees)
				tick.Size = UDim2.fromOffset(tickWidth, tickHeight)
				tick.Position =
					UDim2.fromOffset(barCenterX + difference * pixelsPerDegree, COMPASS_BAR_HEIGHT - 5 - tickHeight / 2)
				tick.BackgroundTransparency = 0.25 + math.clamp(math.abs(difference) / halfVisibleDegrees, 0, 1) * 0.55
			end
		end

		for degrees, tick in pairs(activeTicks) do
			if not neededTicks[degrees] then
				tick:Destroy()
				activeTicks[degrees] = nil
			end
		end

		for degrees = 0, 330, COMPASS_LABEL_SPACING_DEGREES do
			local difference = shortestAngleDifference(degrees, heading)
			if math.abs(difference) <= halfVisibleDegrees + COMPASS_LABEL_BUFFER_DEGREES then
				neededLabels[degrees] = true
				local label = activeLabels[degrees] or createLabel(degrees)
				activeLabels[degrees] = label

				local centerAlpha = 1 - math.clamp(math.abs(difference) / halfVisibleDegrees, 0, 1)
				label.Position = UDim2.fromOffset(barCenterX + difference * pixelsPerDegree, 22)
				label.TextSize = COMPASS_MIN_LABEL_TEXT_SIZE
					+ centerAlpha * (COMPASS_MAX_LABEL_TEXT_SIZE - COMPASS_MIN_LABEL_TEXT_SIZE)
					+ (if isCardinalDegree(degrees) then 3 else 0)
				label.TextTransparency = (1 - centerAlpha) * 0.45
				label.TextStrokeTransparency = 0.35 + (1 - centerAlpha) * 0.45
			end
		end

		for degrees, label in pairs(activeLabels) do
			if not neededLabels[degrees] then
				label:Destroy()
				activeLabels[degrees] = nil
			end
		end
	end

	local renderSignal = RunService.PreRender or RunService.RenderStepped
	local connection = renderSignal:Connect(updateCompass)
	updateCompass()
	return function()
		connection:Disconnect()
		if bar.Parent then
			bar:Destroy()
		end
	end
end

function IngameHUD:StartFunctions(parsedData)
	hudGeneration += 1
	local requestGeneration = hudGeneration
	local ingameHUD = UIRoot.GetScreens():WaitForChild("IngameHUD")
	if compassCleanup then
		compassCleanup()
	end
	compassCleanup = createCompass(ingameHUD :: GuiObject)

	local gameInfo = ingameHUD.RightSide.GameInfo
	local mapData = parsedData and parsedData.MapData
	local layerVisibility = table.clone(DEFAULT_LAYER_VISIBILITY)

	local actions = gameInfo.Actions

	table.insert(
		connections,
		actions.Buttons.BackButton.Activated:Connect(function()
			if UIController:IsPopupOpen() then
				return
			end
			UIController:OpenScreen("PickSpawn")
			-- print("[OSM] Back button pressed. Implement screen transition to PickSpawn.")
			-- Notifications:SendNotification({
			-- 	Type = "Info",
			-- 	Text = "[OSM] Back button pressed. Implement screen transition to PickSpawn.",
			-- 	TargetYScale = 0.2,
			-- })
		end)
	)
	table.insert(
		connections,
		actions.Buttons.LayersButton.Activated:Connect(function()
			UIController:OpenPopup("FilterLayers", {
				LayerVisibility = layerVisibility,
				OnLayerVisibilityChanged = function(updatedVisibility)
					worldRenderer:SetLayerVisibility(updatedVisibility)
					if minimapRenderer then
						minimapRenderer:SetLayerVisibility(updatedVisibility)
					end
				end,
			})
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
	GuiButtonEffects:Setup(actions.Buttons.BackButton, effects)
	GuiButtonEffects:Setup(actions.Buttons.LayersButton, effects)

	local placeTitle = gameInfo.Actions.PlaceTitle
	local coordinates = gameInfo.Actions.Coordinates
	local placeName = parsedData and parsedData.PlaceName
	local latitude = parsedData and parsedData.Latitude
	local longitude = parsedData and parsedData.Longitude
	if type(mapData) ~= "table" then
		mapData = DefaultOsmApiReturnedData
		local origin = type(mapData.origin) == "table" and mapData.origin or {}
		latitude = latitude or tonumber(origin.lat)
		longitude = longitude or tonumber(origin.lon)
		placeName = placeName or "Debug OSM Map"
	end
	local mapLocation = getMapLocation(mapData)
	placeName = mapLocation.name or mapLocation.display_name or placeName
	latitude = tonumber(mapLocation.lat) or latitude
	longitude = tonumber(mapLocation.lon) or longitude

	local fallbackPlaceName = if type(placeName) == "string" and placeName ~= "" then placeName else "Unknown Location"
	local displayedPlaceName = fallbackPlaceName
	placeTitle.Text = fallbackPlaceName
	if type(latitude) == "number" and type(longitude) == "number" then
		coordinates.Text = string.format("LAT %.5f  LON %.5f", latitude, longitude)
	else
		coordinates.Text = "LAT —  LON —"
	end

	worldRenderer:Render(mapData, {
		Layers = layerVisibility,
	})

	local minimap = gameInfo.Minimap :: GuiObject
	local renderer = ConfirmSpawnInfoUtils.Create(minimap, mapData)
	renderer:SetLayerVisibility(layerVisibility)
	renderer:Render()
	minimapRenderer = renderer
	minimapMarker = createMinimapMarker(renderer.Layer)

	local initialChunk = getMapChunk(mapData)
	local initialMetadata = initialChunk and initialChunk.chunk
	local origin = if type(initialChunk) == "table" and type(initialChunk.origin) == "table"
		then initialChunk.origin
		elseif type(mapData) == "table" and type(mapData.origin) == "table" then mapData.origin
		else {}
	local originLat, originLon = tonumber(origin.lat), tonumber(origin.lon)
	local chunkSize = if type(initialMetadata) == "table" then tonumber(initialMetadata.size) or 256 else 256
	local loadedChunks = {} :: { [string]: { X: number, Z: number, Data: any } }
	local requestedChunks = {} :: { [string]: boolean }
	local pendingChunkBases = {} :: { [string]: { X: number, Z: number } }
	local failedChunkRetryAt = {} :: { [string]: number }
	local activeChunkRequests = 0
	if type(initialMetadata) == "table" then
		local initialX = tonumber(initialMetadata.x) or 0
		local initialZ = tonumber(initialMetadata.z) or 0
		loadedChunks[getChunkKey(initialX, initialZ)] = {
			X = initialX,
			Z = initialZ,
			Data = mapData,
		}
	end

	local lastRootPosition: Vector3? = nil
	local function updatePlaceTitleForWorldPosition(worldPosition: Vector3)
		local nearestName = findClosestNamedFeature(loadedChunks, worldRenderer:WorldPositionToMap(worldPosition))
		local nextPlaceName = nearestName or fallbackPlaceName
		if nextPlaceName == displayedPlaceName then
			return
		end

		displayedPlaceName = nextPlaceName
		placeTitle.Text = nextPlaceName
	end

	local function ensureSurroundingChunkBases(centerChunkX: number?, centerChunkZ: number?)
		for _, chunkInfo in pairs(loadedChunks) do
			local minX, minZ, maxX, maxZ = getChunkBounds(chunkInfo.Data)
			if not minX or not minZ or not maxX or not maxZ then
				continue
			end
			local width, height = maxX - minX, maxZ - minZ
			for offsetX = -1, 1 do
				for offsetZ = -1, 1 do
					if offsetX == 0 and offsetZ == 0 then
						continue
					end
					local chunkX = chunkInfo.X + offsetX
					local chunkZ = chunkInfo.Z + offsetZ
					local chunkKey = getChunkKey(chunkX, chunkZ)
					local isWithinRetentionRadius = centerChunkX == nil
						or centerChunkZ == nil
						or math.max(math.abs(chunkX - centerChunkX), math.abs(chunkZ - centerChunkZ)) <= 2
					if isWithinRetentionRadius and not loadedChunks[chunkKey] and not pendingChunkBases[chunkKey] then
						local targetMinX = minX + offsetX * width
						local targetMinZ = minZ + offsetZ * height
						worldRenderer:EnsureChunkBase(
							chunkX,
							chunkZ,
							targetMinX,
							targetMinZ,
							targetMinX + width,
							targetMinZ + height
						)
						pendingChunkBases[chunkKey] = { X = chunkX, Z = chunkZ }
					end
				end
			end
		end
	end
	ensureSurroundingChunkBases()

	local function requestAdjacentChunk(worldPosition: Vector3)
		if
			activeChunkRequests >= MAX_CONCURRENT_CHUNK_REQUESTS
			or type(originLat) ~= "number"
			or type(originLon) ~= "number"
		then
			return
		end

		local mapPosition = worldRenderer:WorldPositionToMap(worldPosition)
		local currentChunk
		for _, chunkInfo in pairs(loadedChunks) do
			local minX, minZ, maxX, maxZ = getChunkBounds(chunkInfo.Data)
			if
				minX
				and minZ
				and maxX
				and maxZ
				and mapPosition.X >= minX
				and mapPosition.X <= maxX
				and mapPosition.Z >= minZ
				and mapPosition.Z <= maxZ
			then
				currentChunk = chunkInfo
				break
			end
		end
		if not currentChunk then
			return
		end

		local minX, minZ, maxX, maxZ = getChunkBounds(currentChunk.Data)
		if not minX or not minZ or not maxX or not maxZ then
			return
		end
		local width, height = maxX - minX, maxZ - minZ
		local edgeCandidates = {
			{ Distance = mapPosition.X - minX, Span = width, X = -1, Z = 0 },
			{ Distance = maxX - mapPosition.X, Span = width, X = 1, Z = 0 },
			{ Distance = mapPosition.Z - minZ, Span = height, X = 0, Z = -1 },
			{ Distance = maxZ - mapPosition.Z, Span = height, X = 0, Z = 1 },
		}
		table.sort(edgeCandidates, function(a, b)
			return a.Distance / a.Span < b.Distance / b.Span
		end)
		local edge = edgeCandidates[1]
		if not edge or edge.Distance / edge.Span > CHUNK_EDGE_THRESHOLD then
			return
		end

		local chunkX = currentChunk.X + edge.X
		local chunkZ = currentChunk.Z + edge.Z
		local chunkKey = getChunkKey(chunkX, chunkZ)
		if loadedChunks[chunkKey] or requestedChunks[chunkKey] or (failedChunkRetryAt[chunkKey] or 0) > os.clock() then
			return
		end

		activeChunkRequests += 1
		requestedChunks[chunkKey] = true
		local targetMinX = minX + edge.X * width
		local targetMinZ = minZ + edge.Z * height
		worldRenderer:EnsureChunkBase(chunkX, chunkZ, targetMinX, targetMinZ, targetMinX + width, targetMinZ + height)
		pendingChunkBases[chunkKey] = { X = chunkX, Z = chunkZ }
		notifyChunkLoadingStarted(chunkKey)
		ClientOSMApiInterface:Chunk({
			OriginLat = originLat,
			OriginLon = originLon,
			ChunkX = chunkX,
			ChunkZ = chunkZ,
			ChunkSize = chunkSize,
			Detail = "full",
			Layers = OSM_VECTOR_CHUNK_LAYERS,
		})
			:andThen(function(response)
				if requestGeneration ~= hudGeneration then
					return
				end
				if not response.Ok or type(response.Data) ~= "table" then
					local message = response.Error and response.Error.Message or "Unknown chunk request failure."
					failedChunkRetryAt[chunkKey] = os.clock() + CHUNK_RETRY_DELAY
					pendingChunkBases[chunkKey] = nil
					worldRenderer:RemoveChunk(chunkX, chunkZ)
					notifyChunkLoadingFailed(chunkKey, message)
					return
				end

				loadedChunks[chunkKey] = {
					X = chunkX,
					Z = chunkZ,
					Data = response.Data,
				}
				pendingChunkBases[chunkKey] = nil
				worldRenderer:AddChunk(response.Data)
				if minimapRenderer then
					minimapRenderer:AddChunk(chunkX, chunkZ, response.Data)
				end
				if lastRootPosition then
					updatePlaceTitleForWorldPosition(lastRootPosition)
				end
				ensureSurroundingChunkBases()
				notifyChunkLoadingFinished(chunkKey)
			end)
			:catch(function(errorValue)
				if requestGeneration == hudGeneration then
					failedChunkRetryAt[chunkKey] = os.clock() + CHUNK_RETRY_DELAY
					pendingChunkBases[chunkKey] = nil
					worldRenderer:RemoveChunk(chunkX, chunkZ)
					notifyChunkLoadingFailed(chunkKey, tostring(errorValue))
				end
			end)
			:finally(function()
				activeChunkRequests -= 1
				requestedChunks[chunkKey] = nil
			end)
	end

	local function cleanupDistantChunks(worldPosition: Vector3)
		local mapPosition = worldRenderer:WorldPositionToMap(worldPosition)
		local currentChunk
		for _, chunkInfo in pairs(loadedChunks) do
			local minX, minZ, maxX, maxZ = getChunkBounds(chunkInfo.Data)
			if
				minX
				and minZ
				and maxX
				and maxZ
				and mapPosition.X >= minX
				and mapPosition.X <= maxX
				and mapPosition.Z >= minZ
				and mapPosition.Z <= maxZ
			then
				currentChunk = chunkInfo
				break
			end
		end
		if not currentChunk then
			return
		end

		for chunkKey, chunkInfo in pairs(loadedChunks) do
			if math.max(math.abs(chunkInfo.X - currentChunk.X), math.abs(chunkInfo.Z - currentChunk.Z)) > 2 then
				loadedChunks[chunkKey] = nil
				worldRenderer:RemoveChunk(chunkInfo.X, chunkInfo.Z)
				if minimapRenderer then
					minimapRenderer:RemoveChunk(chunkInfo.X, chunkInfo.Z)
				end
			end
		end
		for chunkKey, chunkInfo in pairs(pendingChunkBases) do
			if math.max(math.abs(chunkInfo.X - currentChunk.X), math.abs(chunkInfo.Z - currentChunk.Z)) > 2 then
				pendingChunkBases[chunkKey] = nil
				worldRenderer:RemoveChunk(chunkInfo.X, chunkInfo.Z)
			end
		end
		ensureSurroundingChunkBases(currentChunk.X, currentChunk.Z)
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
			local character = localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if not rootPart or not rootPart:IsA("BasePart") then
				return
			end

			if lastRootPosition and (rootPart.Position - lastRootPosition).Magnitude < 0.1 then
				return
			end
			lastRootPosition = rootPart.Position

			local playerLatitude, playerLongitude = worldRenderer:WorldPositionToLatLon(rootPart.Position)
			if playerLatitude and playerLongitude then
				coordinates.Text = string.format("LAT %.5f  LON %.5f", playerLatitude, playerLongitude)
			end
			updateMinimapMarker(mapData, rootPart.Position)
			cleanupDistantChunks(rootPart.Position)
			updatePlaceTitleForWorldPosition(rootPart.Position)
			requestAdjacentChunk(rootPart.Position)
		end)
	)
end

function IngameHUD:StopFunctions()
	hudGeneration += 1
	local ingameHUD = UIRoot.GetScreens():WaitForChild("IngameHUD")
	if compassCleanup then
		compassCleanup()
		compassCleanup = nil
	end
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	if minimapRenderer then
		minimapRenderer:Destroy()
		minimapRenderer = nil
	end
	minimapMarker = nil
	worldRenderer:Destroy()
end

return IngameHUD

--!strict

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage.App.Shared.Packages
local Signal = require(Packages.Signal)

local PickSpawnUtils = {}
PickSpawnUtils.__index = PickSpawnUtils
PickSpawnUtils.Name = "PickSpawnUtils"

export type Location = {
	Id: string?,
	Name: string?,
	Country: string?,
	Lat: number?,
	Lon: number?,
	X: number?,
	Y: number?,
	MinZoom: number?,
	LabelMinZoom: number?,
	Priority: number?,
}

export type SimplifiedMapData = {
	Features: { any }?,
	Meta: any?,
}
type ImageTile = {
	Gui: ImageLabel,
	Image: any,
	Offset: Vector2,
	Size: Vector2,
}
type RenderTarget = {
	Tiles: { ImageTile },
	Size: Vector2,
}
type LocationCandidate = {
	Location: Location,
	ScreenPosition: Vector2,
}
type PinMap = { [string]: TextButton }
type ConnectionList = { RBXScriptConnection }
type VisibleLocationsSignal = Signal.Signal<{ Location }>
type MapScaleSignal = Signal.Signal<number, number>
type SelectedLocationPressedSignal = Signal.Signal<string>
type MapDragSignal = Signal.Signal<boolean>
type MapPointSelectedSignal = Signal.Signal<Vector2, number, number>
export type MapViewChangedSignal = Signal.Signal<Vector2, number, Vector2, number, Vector2?>

local MAP_CLICK_DRAG_THRESHOLD = 6
local BUTTON_ZOOM_STEP = 0.75
local WHEEL_ZOOM_STEP = 0.35
local MAP_PIN_ATTRIBUTE = "PickSpawnMapPin"
local PIN_IN_POOL_ATTRIBUTE = "PickSpawnPinInPool"
local WORLD_IMAGE_SIZE = Vector2.new(2046, 1023)
local MAX_EDITABLE_IMAGE_SIZE = 1023
local MAP_WATER = Color3.fromRGB(157, 203, 225)
local MAP_LAND = Color3.fromRGB(203, 220, 187)
local MAP_COUNTRY_FILL = Color3.fromRGB(203, 220, 187)
local MAP_COASTLINE = Color3.fromRGB(151, 138, 121)
local MAP_BORDER = Color3.fromRGB(151, 138, 121)
local WORLD_IMAGE_BATCH_SIZE = 28

export type MapController = {
	Start: (self: MapController) -> (),
	Stop: (self: MapController) -> (),
	FocusLatLon: (self: MapController, latitude: number, longitude: number) -> (),
	SetViewLatLon: (self: MapController, latitude: number, longitude: number, zoom: number) -> (),
	VisibleLocations: { Location },
	KilometresPerPixel: number,
	VisibleLocationsChanged: VisibleLocationsSignal,
	MapScaleChanged: MapScaleSignal,
	SelectedLocationPressed: SelectedLocationPressedSignal,
	MapDragStarted: MapDragSignal,
	MapDragEnded: MapDragSignal,
	MapPointSelected: MapPointSelectedSignal,
	ViewChanged: MapViewChangedSignal,
	AllowUnboundedCamera: boolean,
	IsInputEnabled: () -> boolean,
	MinCameraZoom: number?,
}

type MapControllerPrivate = MapController & {
	ClipFrame: GuiObject,
	ZoomExclusionRegion: GuiObject,
	MapLayer: GuiObject,
	BorderLayer: GuiObject,
	PinLayer: GuiObject,
	ZoomInButton: GuiButton,
	ZoomOutButton: GuiButton,
	Locations: { Location },
	CountriesData: SimplifiedMapData,
	LandData: SimplifiedMapData,
	VisibleLocations: { Location },
	KilometresPerPixel: number,
	VisibleLocationsChanged: VisibleLocationsSignal,
	SelectedLocationPressed: SelectedLocationPressedSignal,
	MapScaleChanged: MapScaleSignal,
	MapDragStarted: MapDragSignal,
	MapDragEnded: MapDragSignal,
	MapPointSelected: MapPointSelectedSignal,
	ViewChanged: MapViewChangedSignal,
	AllowUnboundedCamera: boolean,
	IsInputEnabled: () -> boolean,
	TileSize: number,
	MinZoom: number,
	MaxZoom: number,
	MinCameraZoom: number?,
	Center: Vector2,
	Zoom: number,
	ShowBorders: boolean,
	WorldImageTiles: { ImageTile },
	WorldImageSignature: string,
	WorldImageBuildVersion: number,
	WorldImageBuildState: "idle" | "building" | "generated",
	ActivePins: PinMap,
	PinPool: { TextButton },
	Connections: ConnectionList,
	IsPointerDown: boolean,
	IsDragging: boolean,
	PointerDownPosition: Vector3?,
	LastDragPosition: Vector3?,
	RenderQueued: boolean,
	Started: boolean,
	ZoomScale: number,
	ZoomAnchor: Vector2?,
	CameraTween: Tween?,
	CenterProgressValue: NumberValue?,
	ZoomScaleValue: NumberValue?,
	PendingZoom: number?,
	PendingCenter: Vector2?,
	AnimationValueConnection: RBXScriptConnection?,
	AnimationCompletedConnection: RBXScriptConnection?,
	getWorldPixelSize: (self: MapControllerPrivate, zoom: number) -> Vector2,
	clampCenter: (self: MapControllerPrivate, center: Vector2, zoom: number) -> Vector2,
	mapToScreen: (self: MapControllerPrivate, mapPosition: Vector2, zoom: number) -> Vector2,
	screenToMap: (self: MapControllerPrivate, screenPosition: Vector2, zoom: number) -> Vector2,
	rebuildWorldImage: (self: MapControllerPrivate) -> (),
	renderWorldImage: (self: MapControllerPrivate) -> (),
	getPinFromPool: (self: MapControllerPrivate) -> TextButton,
	releaseAllPins: (self: MapControllerPrivate) -> (),
	renderPins: (self: MapControllerPrivate) -> (),
	render: (self: MapControllerPrivate) -> (),
	queueRender: (self: MapControllerPrivate) -> (),
	panByScreenDelta: (self: MapControllerPrivate, delta: Vector3) -> (),
	isPointerOverPin: (self: MapControllerPrivate, pointerPosition: Vector3) -> boolean,
	zoomBy: (self: MapControllerPrivate, deltaZoom: number, screenPoint: Vector2?) -> (),
	SetViewLatLon: (self: MapControllerPrivate, latitude: number, longitude: number, zoom: number) -> (),
	animateCenterTo: (self: MapControllerPrivate, targetCenter: Vector2) -> (),
	cancelCameraAnimation: (self: MapControllerPrivate, completeZoom: boolean?) -> (),
	transformForZoomAnimation: (self: MapControllerPrivate, screenPosition: Vector2) -> Vector2,
	outputVisibleLocations: (self: MapControllerPrivate, locations: { Location }) -> (),
	outputMapScale: (self: MapControllerPrivate) -> (),
}

local function getTilesXYForZoom(zoom: number): (number, number)
	return 2 ^ (zoom + 1), 2 ^ zoom
end

local function getLocationSeparationRadius(zoom: number): number
	-- Keep the overview uncluttered, then reveal increasingly dense cities as
	-- the player zooms in. The value is measured in on-screen pixels.
	return math.max(40, 96 - zoom * 8)
end

local function getMinimumCameraZoom(self: MapControllerPrivate): number
	local minCameraZoom = self.MinCameraZoom
	if minCameraZoom == nil then
		return self.MinZoom
	end

	if minCameraZoom > self.MinZoom then
		return minCameraZoom
	end

	return self.MinZoom
end

local function createEditableImage(size: Vector2): any?
	local ok, editableImage = pcall(function()
		return (AssetService :: any):CreateEditableImage({
			Size = size,
		})
	end)
	if ok then
		return editableImage
	end

	warn("Cannot create EditableImage for pick-spawn map: " .. tostring(editableImage))
	return nil
end

local function setImageContent(imageLabel: ImageLabel, editableImage: any)
	local ok, result = pcall(function()
		return (Content :: any).fromObject(editableImage)
	end)
	if ok then
		(imageLabel :: any).ImageContent = result
		return
	end

	warn("Cannot bind EditableImage to pick-spawn map ImageLabel: " .. tostring(result))
end

local function drawImageRectangle(image: any, position: Vector2, size: Vector2, colour: Color3)
	if not image or size.X <= 0 or size.Y <= 0 then
		return
	end

	local ok = pcall(function()
		image:DrawRectangle(position, size, colour, 0, Enum.ImageCombineType.Overwrite)
	end)
	if not ok then
		pcall(function()
			image:DrawRectangle(position, size, colour, 0)
		end)
	end
end

local function rectanglesOverlap(position: Vector2, size: Vector2, tile: ImageTile): boolean
	return position.X < tile.Offset.X + tile.Size.X
		and position.X + size.X > tile.Offset.X
		and position.Y < tile.Offset.Y + tile.Size.Y
		and position.Y + size.Y > tile.Offset.Y
end

local function drawTargetRectangle(target: RenderTarget, position: Vector2, size: Vector2, colour: Color3)
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	for _, tile in ipairs(target.Tiles) do
		if not rectanglesOverlap(position, size, tile) then
			continue
		end

		local left = math.max(position.X, tile.Offset.X)
		local top = math.max(position.Y, tile.Offset.Y)
		local right = math.min(position.X + size.X, tile.Offset.X + tile.Size.X)
		local bottom = math.min(position.Y + size.Y, tile.Offset.Y + tile.Size.Y)
		drawImageRectangle(
			tile.Image,
			Vector2.new(left - tile.Offset.X, top - tile.Offset.Y),
			Vector2.new(right - left, bottom - top),
			colour
		)
	end
end

local function fillScreenPolygon(target: RenderTarget, polygon: { Vector2 }, colour: Color3, step: number?)
	if #polygon < 3 then
		return
	end

	local minY = math.huge
	local maxY = -math.huge
	for _, point in ipairs(polygon) do
		minY = math.min(minY, point.Y)
		maxY = math.max(maxY, point.Y)
	end

	local scanlineStep = step or 1
	local startY = math.max(0, math.floor(minY / scanlineStep) * scanlineStep)
	local endY = math.min(target.Size.Y, math.ceil(maxY / scanlineStep) * scanlineStep)
	for y = startY, endY, scanlineStep do
		local intersections = {} :: { number }
		for index, point in ipairs(polygon) do
			local nextPoint = polygon[index % #polygon + 1]
			if (point.Y <= y and nextPoint.Y > y) or (nextPoint.Y <= y and point.Y > y) then
				local progress = (y - point.Y) / (nextPoint.Y - point.Y)
				table.insert(intersections, point.X + (nextPoint.X - point.X) * progress)
			end
		end

		table.sort(intersections)
		for index = 1, #intersections - 1, 2 do
			local left = math.max(0, intersections[index])
			local right = math.min(target.Size.X, intersections[index + 1])
			if right > left then
				drawTargetRectangle(target, Vector2.new(left, y), Vector2.new(right - left, scanlineStep), colour)
			end
		end
	end
end

local function drawSegment(target: RenderTarget, from: Vector2, to: Vector2, thickness: number, colour: Color3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.1 then
		return
	end

	local halfThickness = math.max(0.5, thickness * 0.5)
	local normal = Vector2.new(-delta.Y / length, delta.X / length) * halfThickness
	fillScreenPolygon(target, {
		from + normal,
		to + normal,
		to - normal,
		from - normal,
	}, colour, 1)
end

local function normalisedRingToPoints(ring: any, imageSize: Vector2): { Vector2 }
	local points = {} :: { Vector2 }
	if type(ring) ~= "table" then
		return points
	end

	local index = 1
	while index < #ring do
		local x = tonumber(ring[index])
		local y = tonumber(ring[index + 1])
		if x and y then
			table.insert(points, Vector2.new(x * imageSize.X, y * imageSize.Y))
		end
		index += 2
	end

	return points
end

function PickSpawnUtils.CreateMap(
	clipFrame: GuiObject,
	zoomExclusionRegion: GuiObject,
	mapLayer: GuiObject,
	borderLayer: GuiObject,
	pinLayer: GuiObject,
	zoomInButton: GuiButton,
	zoomOutButton: GuiButton,
	locations: { Location },
	countriesData: SimplifiedMapData,
	landData: SimplifiedMapData
): MapController
	local controller = setmetatable(
		{
			ClipFrame = clipFrame,
			ZoomExclusionRegion = zoomExclusionRegion,
			MapLayer = mapLayer,
			BorderLayer = borderLayer,
			PinLayer = pinLayer,
			ZoomInButton = zoomInButton,
			ZoomOutButton = zoomOutButton,
			Locations = locations,
			CountriesData = countriesData,
			LandData = landData,
			VisibleLocations = {} :: { Location },
			KilometresPerPixel = 0,
			VisibleLocationsChanged = Signal.new() :: VisibleLocationsSignal,
			MapScaleChanged = Signal.new() :: MapScaleSignal,
			SelectedLocationPressed = Signal.new() :: Signal.Signal<string>,
			MapDragStarted = Signal.new() :: MapDragSignal,
			MapDragEnded = Signal.new() :: MapDragSignal,
			MapPointSelected = Signal.new() :: MapPointSelectedSignal,
			ViewChanged = Signal.new() :: MapViewChangedSignal,
			AllowUnboundedCamera = false,
			IsInputEnabled = function()
				return true
			end,
			TileSize = 512,
			MinZoom = 0,
			MaxZoom = 5,
			MinCameraZoom = nil,
			Center = Vector2.new(0.5, 0.5),
			Zoom = 0,
			ShowBorders = true,
			WorldImageTiles = {} :: { ImageTile },
			WorldImageSignature = "",
			WorldImageBuildVersion = 0,
			WorldImageBuildState = "idle",
			ActivePins = {} :: PinMap,
			PinPool = {} :: { TextButton },
			Connections = {} :: ConnectionList,
			IsPointerDown = false,
			IsDragging = false,
			PointerDownPosition = nil,
			LastDragPosition = nil,
			RenderQueued = false,
			Started = false,
			ZoomScale = 1,
			ZoomAnchor = nil,
			CameraTween = nil,
			CenterProgressValue = nil,
			ZoomScaleValue = nil,
			PendingZoom = nil,
			PendingCenter = nil,
			AnimationValueConnection = nil,
			AnimationCompletedConnection = nil,
		} :: any,
		PickSpawnUtils
	) :: MapControllerPrivate

	return controller
end

function PickSpawnUtils.getWorldPixelSize(self: MapControllerPrivate, zoom: number): Vector2
	local tilesX, tilesY = getTilesXYForZoom(zoom)
	return Vector2.new(tilesX * self.TileSize, tilesY * self.TileSize)
end

function PickSpawnUtils.clampCenter(self: MapControllerPrivate, center: Vector2, zoom: number): Vector2
	if self.AllowUnboundedCamera then
		return center
	end

	local viewportSize = self.ClipFrame.AbsoluteSize
	local worldSize = self:getWorldPixelSize(zoom)

	local halfViewNormX = (viewportSize.X / worldSize.X) / 2
	local halfViewNormY = (viewportSize.Y / worldSize.Y) / 2
	local minX, maxX = halfViewNormX, 1 - halfViewNormX
	local minY, maxY = halfViewNormY, 1 - halfViewNormY

	if minX > maxX then
		minX, maxX = 0.5, 0.5
	end
	if minY > maxY then
		minY, maxY = 0.5, 0.5
	end

	return Vector2.new(math.clamp(center.X, minX, maxX), math.clamp(center.Y, minY, maxY))
end

function PickSpawnUtils.mapToScreen(self: MapControllerPrivate, mapPosition: Vector2, zoom: number): Vector2
	local viewportSize = self.ClipFrame.AbsoluteSize
	local worldSize = self:getWorldPixelSize(zoom)
	return viewportSize / 2 + (mapPosition * worldSize - self.Center * worldSize)
end

function PickSpawnUtils.screenToMap(self: MapControllerPrivate, screenPosition: Vector2, zoom: number): Vector2
	local viewportSize = self.ClipFrame.AbsoluteSize
	local worldSize = self:getWorldPixelSize(zoom)
	local targetPosition = self.Center * worldSize + (screenPosition - viewportSize / 2)
	return Vector2.new(targetPosition.X / worldSize.X, targetPosition.Y / worldSize.Y)
end

function PickSpawnUtils.transformForZoomAnimation(self: MapControllerPrivate, screenPosition: Vector2): Vector2
	if not self.ZoomAnchor then
		return screenPosition
	end

	return self.ZoomAnchor + (screenPosition - self.ZoomAnchor) * self.ZoomScale
end

function PickSpawnUtils.rebuildWorldImage(self: MapControllerPrivate)
	if self.WorldImageBuildState == "generated" or self.WorldImageBuildState == "building" then
		return
	end

	self.WorldImageBuildVersion += 1
	local buildVersion = self.WorldImageBuildVersion
	self.WorldImageBuildState = "building"
	self.WorldImageSignature = "generated"
	self.MapLayer.BackgroundColor3 = MAP_WATER
	self.MapLayer.BackgroundTransparency = 0
	self.MapLayer.BorderSizePixel = 0
	self.MapLayer.ClipsDescendants = true
	self.BorderLayer.Visible = false
	for _, child in ipairs(self.MapLayer:GetChildren()) do
		child:Destroy()
	end
	table.clear(self.WorldImageTiles)

	local columns = math.max(1, math.ceil(WORLD_IMAGE_SIZE.X / MAX_EDITABLE_IMAGE_SIZE))
	local rows = math.max(1, math.ceil(WORLD_IMAGE_SIZE.Y / MAX_EDITABLE_IMAGE_SIZE))
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local offset = Vector2.new(column * MAX_EDITABLE_IMAGE_SIZE, row * MAX_EDITABLE_IMAGE_SIZE)
			local tileSize = Vector2.new(
				math.min(MAX_EDITABLE_IMAGE_SIZE, WORLD_IMAGE_SIZE.X - offset.X),
				math.min(MAX_EDITABLE_IMAGE_SIZE, WORLD_IMAGE_SIZE.Y - offset.Y)
			)
			local editableImage = createEditableImage(tileSize)
			if not editableImage then
				self.WorldImageSignature = ""
				self.WorldImageBuildState = "idle"
				return
			end

			local imageLabel = Instance.new("ImageLabel")
			imageLabel.Name = string.format("World_%d_%d", column, row)
			imageLabel.Active = false
			imageLabel.BackgroundTransparency = 1
			imageLabel.BorderSizePixel = 0
			imageLabel.ScaleType = Enum.ScaleType.Stretch
			imageLabel.ZIndex = self.MapLayer.ZIndex
			imageLabel.Parent = self.MapLayer
			setImageContent(imageLabel, editableImage)

			table.insert(self.WorldImageTiles, {
				Gui = imageLabel,
				Image = editableImage,
				Offset = offset,
				Size = tileSize,
			})
		end
	end

	local renderTarget = {
		Tiles = self.WorldImageTiles,
		Size = WORLD_IMAGE_SIZE,
	}

	drawTargetRectangle(renderTarget, Vector2.new(0, 0), WORLD_IMAGE_SIZE, MAP_WATER)

	local function isBuildCurrent(): boolean
		return self.Started and self.WorldImageBuildVersion == buildVersion
	end

	local function drawFeatures(
		data: SimplifiedMapData,
		fillColour: Color3?,
		lineColour: Color3?,
		lineThickness: number
	)
		local features = data.Features
		if type(features) ~= "table" then
			return
		end

		local processedRings = 0
		for _, feature in ipairs(features) do
			local polygons = if type(feature) == "table" then feature.Polygons else nil
			if type(polygons) ~= "table" then
				continue
			end

			for _, polygon in ipairs(polygons) do
				if type(polygon) ~= "table" then
					continue
				end

				for _, ring in ipairs(polygon) do
					local points = normalisedRingToPoints(ring, WORLD_IMAGE_SIZE)
					if #points < 2 then
						continue
					end
					if fillColour and #points >= 3 then
						fillScreenPolygon(renderTarget, points, fillColour, 2)
					end
					if lineColour then
						for index, point in ipairs(points) do
							local nextPoint = points[index % #points + 1]
							drawSegment(renderTarget, point, nextPoint, lineThickness, lineColour)
						end
					end

					processedRings += 1
					if processedRings >= WORLD_IMAGE_BATCH_SIZE then
						processedRings = 0
						if not isBuildCurrent() then
							return
						end
						task.wait()
					end
				end
			end
		end
	end

	task.defer(function()
		if not isBuildCurrent() then
			return
		end

		drawFeatures(self.LandData, MAP_LAND, nil, 0.9)
		if not isBuildCurrent() then
			return
		end

		-- -- Country fill matches the land fill, so only the border pass is needed here.
		drawFeatures(self.CountriesData, nil, MAP_BORDER, 0.9)
		if not isBuildCurrent() then
			return
		end

		self.WorldImageBuildState = "generated"
	end)
end

function PickSpawnUtils.renderWorldImage(self: MapControllerPrivate)
	self:rebuildWorldImage()

	local viewportSize = self.ClipFrame.AbsoluteSize
	local worldSize = self:getWorldPixelSize(self.Zoom)
	local centerPixel = self.Center * worldSize
	for _, tile in ipairs(self.WorldImageTiles) do
		local tileTopLeftWorld = Vector2.new(
			(tile.Offset.X / WORLD_IMAGE_SIZE.X) * worldSize.X,
			(tile.Offset.Y / WORLD_IMAGE_SIZE.Y) * worldSize.Y
		)
		local tileSizeWorld = Vector2.new(
			(tile.Size.X / WORLD_IMAGE_SIZE.X) * worldSize.X,
			(tile.Size.Y / WORLD_IMAGE_SIZE.Y) * worldSize.Y
		) * self.ZoomScale
		local position = viewportSize / 2 + (tileTopLeftWorld - centerPixel) * self.ZoomScale
		position = self:transformForZoomAnimation(position)
		tile.Gui.Position = UDim2.fromOffset(math.floor(position.X), math.floor(position.Y))
		tile.Gui.Size = UDim2.fromOffset(math.ceil(tileSizeWorld.X), math.ceil(tileSizeWorld.Y))
		tile.Gui.Visible = true
	end
end

function PickSpawnUtils.getPinFromPool(self: MapControllerPrivate): TextButton
	local oldPin: TextButton? = table.remove(self.PinPool)
	if oldPin then
		oldPin:SetAttribute(PIN_IN_POOL_ATTRIBUTE, false)
		oldPin.Visible = true
		return oldPin
	end

	local pin = Instance.new("TextButton")
	pin.Name = "Pin"
	pin.Size = UDim2.fromOffset(16, 16)
	pin.AnchorPoint = Vector2.new(0.5, 0.5)
	pin.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	pin.BackgroundTransparency = 0.05
	pin.BorderSizePixel = 0
	pin.Text = ""
	pin.AutoButtonColor = true
	pin.ZIndex = 10
	pin:SetAttribute(MAP_PIN_ATTRIBUTE, true)
	pin:SetAttribute(PIN_IN_POOL_ATTRIBUTE, false)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = pin

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Transparency = 0.2
	stroke.Parent = pin

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 1)
	label.Size = UDim2.fromOffset(120, 15)
	label.BackgroundTransparency = 0.7
	label.BackgroundColor3 = Color3.fromRGB(27, 27, 27)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 12
	label.ZIndex = 11
	label.TextScaled = true
	label.Parent = pin

	local labelCorner = Instance.new("UICorner")
	labelCorner.CornerRadius = UDim.new(0, 4)
	labelCorner.Parent = label

	pin.Activated:Connect(function()
		if not self.IsInputEnabled() then
			return
		end

		local locationName = pin:GetAttribute("LocationName") :: string
		self.SelectedLocationPressed:Fire(locationName)
	end)

	return pin
end

local function releasePinToPool(self: MapControllerPrivate, pin: TextButton)
	if pin:GetAttribute(PIN_IN_POOL_ATTRIBUTE) == true then
		return
	end

	pin.Visible = false
	pin.Parent = nil
	pin:SetAttribute(PIN_IN_POOL_ATTRIBUTE, true)
	table.insert(self.PinPool, pin)
end

function PickSpawnUtils.releaseAllPins(self: MapControllerPrivate)
	for _, pin in pairs(self.ActivePins) do
		releasePinToPool(self, pin)
	end
	table.clear(self.ActivePins)

	-- The active table is only an optimization. Sweep the layer as well so a
	-- pin cannot survive if an entry was overwritten or otherwise lost.
	for _, child in ipairs(self.PinLayer:GetChildren()) do
		if child:IsA("TextButton") then
			local isGeneratedPin = child:GetAttribute(MAP_PIN_ATTRIBUTE) == true
				or string.sub(child.Name, 1, 4) == "Pin_"
			if isGeneratedPin then
				releasePinToPool(self, child)
			end
		end
	end
end

function PickSpawnUtils.renderPins(self: MapControllerPrivate)
	self:releaseAllPins()

	local viewportSize = self.ClipFrame.AbsoluteSize
	local margin = 32
	local candidates: { LocationCandidate } = {}
	for _, location in ipairs(self.Locations) do
		local minZoom = location.MinZoom or 0
		if self.Zoom >= minZoom and location.X and location.Y then
			local screenPosition = self:mapToScreen(Vector2.new(location.X, location.Y), self.Zoom)
			local visible = screenPosition.X >= -margin
				and screenPosition.Y >= -margin
				and screenPosition.X <= viewportSize.X + margin
				and screenPosition.Y <= viewportSize.Y + margin

			if visible then
				table.insert(candidates, {
					Location = location,
					ScreenPosition = screenPosition,
				})
			end
		end
	end

	table.sort(candidates, function(a, b)
		local aPriority = a.Location.Priority or 0
		local bPriority = b.Location.Priority or 0
		if aPriority == bPriority then
			return (a.Location.Name or "") < (b.Location.Name or "")
		end
		return aPriority > bPriority
	end)

	local separationRadius = getLocationSeparationRadius(self.Zoom)
	local separationRadiusSquared = separationRadius * separationRadius
	local acceptedPositionsByCell: { [string]: { Vector2 } } = {}
	local visibleLocations: { Location } = {}

	for _, candidate in ipairs(candidates) do
		local screenPosition = candidate.ScreenPosition
		local cellX = math.floor(screenPosition.X / separationRadius)
		local cellY = math.floor(screenPosition.Y / separationRadius)
		local tooClose = false

		for offsetY = -1, 1 do
			for offsetX = -1, 1 do
				local nearbyPositions =
					acceptedPositionsByCell[string.format("%d:%d", cellX + offsetX, cellY + offsetY)]
				if nearbyPositions then
					for _, nearbyPosition in ipairs(nearbyPositions) do
						local delta = screenPosition - nearbyPosition
						if delta:Dot(delta) < separationRadiusSquared then
							tooClose = true
							break
						end
					end
				end
				if tooClose then
					break
				end
			end
			if tooClose then
				break
			end
		end

		if not tooClose then
			local cellKey = string.format("%d:%d", cellX, cellY)
			local acceptedPositions = acceptedPositionsByCell[cellKey]
			if not acceptedPositions then
				acceptedPositions = {} :: { Vector2 }
				acceptedPositionsByCell[cellKey] = acceptedPositions
			end
			table.insert(acceptedPositions, screenPosition)

			local location = candidate.Location
			local minZoom = location.MinZoom or 0
			table.insert(visibleLocations, location)

			local pin = self:getPinFromPool()
			pin.Name = "Pin_" .. (location.Id or location.Name or "Location")
			local visualScreenPosition = self:transformForZoomAnimation(screenPosition)
			pin.Position = UDim2.fromOffset(visualScreenPosition.X, visualScreenPosition.Y)
			pin:SetAttribute("LocationName", location.Name or "Location")
			pin.Parent = self.PinLayer

			local label = pin:FindFirstChild("Label") :: TextLabel?
			if label then
				label.Text = location.Name or "Location"
				label.Visible = self.Zoom >= (location.LabelMinZoom or minZoom)
			end

			self.ActivePins[location.Id or location.Name or tostring(location.X) .. ":" .. tostring(location.Y)] = pin
		end
	end

	self:outputVisibleLocations(visibleLocations)
end

function PickSpawnUtils.outputVisibleLocations(self: MapControllerPrivate, locations: { Location })
	-- Stub: replace this with the spawn-list UI update when that UI is available.
	self.VisibleLocations = locations
	self.VisibleLocationsChanged:Fire(locations)
end

function PickSpawnUtils.outputMapScale(self: MapControllerPrivate)
	-- Equirectangular world width at the equator, in kilometres per map pixel.
	local earthCircumferenceKilometres = 40075.017
	local kilometresPerPixel = earthCircumferenceKilometres / self:getWorldPixelSize(self.Zoom).X
	self.KilometresPerPixel = kilometresPerPixel
	self.MapScaleChanged:Fire(kilometresPerPixel, self.Zoom)
end

function PickSpawnUtils.render(self: MapControllerPrivate)
	if not self.Started then
		return
	end

	self.Center = self:clampCenter(self.Center, self.Zoom)
	self.ViewChanged:Fire(self.Center, self.Zoom, self:getWorldPixelSize(self.Zoom), self.ZoomScale, self.ZoomAnchor)
	self:renderWorldImage()
	self:renderPins()
end

function PickSpawnUtils.queueRender(self: MapControllerPrivate)
	if self.RenderQueued then
		return
	end

	self.RenderQueued = true
	task.defer(function()
		self.RenderQueued = false
		self:render()
	end)
end

function PickSpawnUtils.panByScreenDelta(self: MapControllerPrivate, delta: Vector3)
	self:cancelCameraAnimation(true)
	local worldSize = self:getWorldPixelSize(self.Zoom)
	self.Center -= Vector2.new(delta.X / worldSize.X, delta.Y / worldSize.Y)
	self.Center = self:clampCenter(self.Center, self.Zoom)
	self:queueRender()
end

function PickSpawnUtils.isPointerOverPin(self: MapControllerPrivate, pointerPosition: Vector3): boolean
	for _, pin in pairs(self.ActivePins) do
		if pin.Visible then
			local pinPosition = pin.AbsolutePosition
			local pinSize = pin.AbsoluteSize
			if
				pointerPosition.X >= pinPosition.X
				and pointerPosition.X <= pinPosition.X + pinSize.X
				and pointerPosition.Y >= pinPosition.Y
				and pointerPosition.Y <= pinPosition.Y + pinSize.Y
			then
				return true
			end
		end
	end

	return false
end

function PickSpawnUtils.cancelCameraAnimation(self: MapControllerPrivate, completeZoom: boolean?)
	local pendingZoom = self.PendingZoom
	local pendingCenter = self.PendingCenter
	self.PendingZoom = nil
	self.PendingCenter = nil

	local activeTween = self.CameraTween
	self.CameraTween = nil
	if activeTween then
		activeTween:Cancel()
	end
	if self.AnimationValueConnection then
		self.AnimationValueConnection:Disconnect()
		self.AnimationValueConnection = nil
	end
	if self.AnimationCompletedConnection then
		self.AnimationCompletedConnection:Disconnect()
		self.AnimationCompletedConnection = nil
	end
	if self.CenterProgressValue then
		self.CenterProgressValue:Destroy()
		self.CenterProgressValue = nil
	end
	if self.ZoomScaleValue then
		self.ZoomScaleValue:Destroy()
		self.ZoomScaleValue = nil
	end

	self.ZoomScale = 1
	self.ZoomAnchor = nil

	if completeZoom and pendingZoom and pendingCenter then
		self.Zoom = pendingZoom
		self.Center = pendingCenter
		self:outputMapScale()
		self:queueRender()
	end
end

function PickSpawnUtils.animateCenterTo(self: MapControllerPrivate, targetCenter: Vector2)
	self:cancelCameraAnimation(true)
	if (targetCenter - self.Center).Magnitude < 0.0001 then
		return
	end

	local startCenter = self.Center
	local centerProgressValue = Instance.new("NumberValue")
	centerProgressValue.Value = 0
	self.CenterProgressValue = centerProgressValue
	self.AnimationValueConnection = centerProgressValue:GetPropertyChangedSignal("Value"):Connect(function()
		self.Center = self:clampCenter(startCenter:Lerp(targetCenter, centerProgressValue.Value), self.Zoom)
		self:queueRender()
	end)

	local tween = TweenService:Create(
		centerProgressValue,
		TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	self.CameraTween = tween
	self.AnimationCompletedConnection = tween.Completed:Connect(function()
		if self.CameraTween ~= tween then
			return
		end

		self.Center = targetCenter
		self:cancelCameraAnimation(false)
		self:queueRender()
	end)
	tween:Play()
end

function PickSpawnUtils.FocusLatLon(self: MapControllerPrivate, latitude: number, longitude: number)
	-- The tile set uses a 2:1 equirectangular projection.
	local mapPosition = Vector2.new(math.clamp((longitude + 180) / 360, 0, 1), math.clamp((90 - latitude) / 180, 0, 1))
	self:animateCenterTo(self:clampCenter(mapPosition, self.Zoom))
end

function PickSpawnUtils.SetViewLatLon(self: MapControllerPrivate, latitude: number, longitude: number, zoom: number)
	self:cancelCameraAnimation(false)
	self.Zoom = math.clamp(zoom, getMinimumCameraZoom(self), self.MaxZoom)

	local mapPosition = Vector2.new(math.clamp((longitude + 180) / 360, 0, 1), math.clamp((90 - latitude) / 180, 0, 1))
	self.Center = self:clampCenter(mapPosition, self.Zoom)
	self:outputMapScale()
	self:queueRender()
end

function PickSpawnUtils.zoomBy(self: MapControllerPrivate, deltaZoom: number, screenPoint: Vector2?)
	self:cancelCameraAnimation(true)
	local oldZoom = self.Zoom
	local newZoom = if self.AllowUnboundedCamera
		then oldZoom + deltaZoom
		else math.clamp(oldZoom + deltaZoom, getMinimumCameraZoom(self), self.MaxZoom)
	if newZoom == oldZoom then
		return
	end

	local localScreenPoint = if screenPoint
		then screenPoint - self.ClipFrame.AbsolutePosition
		else self.ClipFrame.AbsoluteSize / 2
	local mapPointBefore = self:screenToMap(localScreenPoint, oldZoom)

	local viewportSize = self.ClipFrame.AbsoluteSize
	local newWorldSize = self:getWorldPixelSize(newZoom)
	local desiredCenter = mapPointBefore * newWorldSize - (localScreenPoint - viewportSize / 2)
	local targetCenter =
		self:clampCenter(Vector2.new(desiredCenter.X / newWorldSize.X, desiredCenter.Y / newWorldSize.Y), newZoom)

	local zoomProgressValue = Instance.new("NumberValue")
	zoomProgressValue.Value = 0
	self.ZoomScaleValue = zoomProgressValue
	self.ZoomAnchor = localScreenPoint
	self.PendingZoom = newZoom
	self.PendingCenter = targetCenter
	self.AnimationValueConnection = zoomProgressValue:GetPropertyChangedSignal("Value"):Connect(function()
		local progress = zoomProgressValue.Value
		local currentZoom = oldZoom + (newZoom - oldZoom) * progress
		local currentWorldSize = self:getWorldPixelSize(currentZoom)
		local currentDesiredCenter = mapPointBefore * currentWorldSize - (localScreenPoint - viewportSize / 2)
		self.Zoom = currentZoom
		self.Center = self:clampCenter(
			Vector2.new(currentDesiredCenter.X / currentWorldSize.X, currentDesiredCenter.Y / currentWorldSize.Y),
			currentZoom
		)
		self.ZoomScale = 1
		self:outputMapScale()
		self:queueRender()
	end)

	local tween = TweenService:Create(
		zoomProgressValue,
		TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	self.CameraTween = tween
	self.AnimationCompletedConnection = tween.Completed:Connect(function()
		if self.CameraTween ~= tween then
			return
		end

		self.Zoom = newZoom
		self.Center = targetCenter
		self.PendingZoom = nil
		self.PendingCenter = nil
		self:cancelCameraAnimation(false)
		self:outputMapScale()
		self:queueRender()
	end)
	tween:Play()
end

function PickSpawnUtils.Start(self: MapControllerPrivate)
	if self.Started then
		return
	end

	self.Started = true
	self.ClipFrame.Active = true
	self:outputMapScale()

	local function cancelPointerInteraction()
		local wasDragging = self.IsDragging
		self.IsPointerDown = false
		self.IsDragging = false
		self.PointerDownPosition = nil
		self.LastDragPosition = nil

		if wasDragging then
			self.MapDragEnded:Fire(false)
		end
	end

	table.insert(
		self.Connections,
		self.ClipFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if not self.IsInputEnabled() then
					return
				end

				if self.IsPointerDown then
					return
				end
				self:cancelCameraAnimation(true)
				self.IsPointerDown = true
				self.IsDragging = false
				self.PointerDownPosition = input.Position
				self.LastDragPosition = input.Position
			end
		end)
	)

	table.insert(
		self.Connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and self.IsPointerDown then
				local wasDragging = self.IsDragging
				cancelPointerInteraction()

				if not self.IsInputEnabled() then
					return
				end

				if wasDragging then
				elseif not self:isPointerOverPin(input.Position) then
					local localScreenPosition = Vector2.new(input.Position.X, input.Position.Y)
						- self.ClipFrame.AbsolutePosition
					local mapPosition = self:screenToMap(localScreenPosition, self.Zoom)
					mapPosition = Vector2.new(math.clamp(mapPosition.X, 0, 1), math.clamp(mapPosition.Y, 0, 1))

					local latitude = 90 - mapPosition.Y * 180
					local longitude = mapPosition.X * 360 - 180
					self.MapPointSelected:Fire(mapPosition, latitude, longitude)
				end
			end
		end)
	)

	table.insert(
		self.Connections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				and self.IsPointerDown
				and self.PointerDownPosition
			then
				if not self.IsInputEnabled() then
					cancelPointerInteraction()
					return
				end

				if not self.IsDragging then
					local totalDelta = input.Position - self.PointerDownPosition
					if totalDelta.Magnitude < MAP_CLICK_DRAG_THRESHOLD then
						return
					end

					self.IsDragging = true
					self.MapDragStarted:Fire(true)
					self:panByScreenDelta(totalDelta)
				else
					local delta = input.Position - (self.LastDragPosition or input.Position)
					self:panByScreenDelta(delta)
				end
				self.LastDragPosition = input.Position
			elseif input.UserInputType == Enum.UserInputType.MouseWheel and self.IsInputEnabled() then
				local mousePosition = UserInputService:GetMouseLocation()
				local clipPosition = self.ClipFrame.AbsolutePosition
				local clipSize = self.ClipFrame.AbsoluteSize
				local exclusionPosition = self.ZoomExclusionRegion.AbsolutePosition
				local exclusionSize = self.ZoomExclusionRegion.AbsoluteSize
				local inside = mousePosition.X >= clipPosition.X
					and mousePosition.Y >= clipPosition.Y
					and mousePosition.X <= clipPosition.X + clipSize.X
					and mousePosition.Y <= clipPosition.Y + clipSize.Y
				local overZoomExclusionRegion = mousePosition.X >= exclusionPosition.X
					and mousePosition.Y >= exclusionPosition.Y
					and mousePosition.X <= exclusionPosition.X + exclusionSize.X
					and mousePosition.Y <= exclusionPosition.Y + exclusionSize.Y
				if inside and not overZoomExclusionRegion then
					self:zoomBy((if input.Position.Z > 0 then 1 else -1) * WHEEL_ZOOM_STEP, mousePosition)
				end
			end
		end)
	)

	table.insert(
		self.Connections,
		self.ZoomInButton.MouseButton1Click:Connect(function()
			if self.IsInputEnabled() then
				self:zoomBy(BUTTON_ZOOM_STEP)
			end
		end)
	)
	table.insert(
		self.Connections,
		self.ZoomOutButton.MouseButton1Click:Connect(function()
			if self.IsInputEnabled() then
				self:zoomBy(-BUTTON_ZOOM_STEP)
			end
		end)
	)
	table.insert(
		self.Connections,
		self.ClipFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:queueRender()
		end)
	)

	self:queueRender()
end

function PickSpawnUtils.Stop(self: MapControllerPrivate)
	if not self.Started then
		return
	end

	self:cancelCameraAnimation(false)
	self.Started = false
	self.IsPointerDown = false
	self.IsDragging = false
	self.PointerDownPosition = nil
	self.LastDragPosition = nil
	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end
	table.clear(self.Connections)

	for _, child in ipairs(self.MapLayer:GetChildren()) do
		child:Destroy()
	end
	table.clear(self.WorldImageTiles)
	self.WorldImageSignature = ""
	self.WorldImageBuildVersion += 1
	self.WorldImageBuildState = "idle"
	self:releaseAllPins()
end

return PickSpawnUtils

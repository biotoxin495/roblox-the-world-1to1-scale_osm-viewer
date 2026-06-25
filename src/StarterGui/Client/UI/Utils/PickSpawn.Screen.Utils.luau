--!strict

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
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

export type TileManifest = {
	TileSize: number?,
	MinZoom: number?,
	MaxZoom: number?,
	Layers: {
		[string]: {
			[string]: string,
		},
	},
}

type TileLayerName = "base" | "borders"
type TileMap = { [string]: ImageLabel }
type TileImage = {
	Image: string,
	SourceZoom: number,
}
type LocationCandidate = {
	Location: Location,
	ScreenPosition: Vector2,
}
type TilePool = { ImageLabel }
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
	BaseTileLayer: GuiObject,
	BorderTileLayer: GuiObject,
	PinLayer: GuiObject,
	ZoomInButton: GuiButton,
	ZoomOutButton: GuiButton,
	Locations: { Location },
	TileManifest: TileManifest,
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
	ActiveTiles: { [TileLayerName]: TileMap },
	TilePools: { [TileLayerName]: TilePool },
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
	getTileImage: (
		self: MapControllerPrivate,
		layerName: TileLayerName,
		zoom: number,
		x: number,
		y: number
	) -> TileImage?,
	getTileFromPool: (self: MapControllerPrivate, layerName: TileLayerName) -> ImageLabel,
	releaseTile: (self: MapControllerPrivate, layerName: TileLayerName, key: string) -> (),
	renderTileLayer: (
		self: MapControllerPrivate,
		layerName: TileLayerName,
		parentLayer: GuiObject,
		enabled: boolean
	) -> (),
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

local function getTileZoomForCameraZoom(self: MapControllerPrivate): number
	return math.clamp(math.floor(self.Zoom), self.MinZoom, self.MaxZoom)
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

function PickSpawnUtils.CreateMap(
	clipFrame: GuiObject,
	zoomExclusionRegion: GuiObject,
	baseTileLayer: GuiObject,
	borderTileLayer: GuiObject,
	pinLayer: GuiObject,
	zoomInButton: GuiButton,
	zoomOutButton: GuiButton,
	locations: { Location },
	tileManifest: TileManifest
): MapController
	local controller = setmetatable(
		{
			ClipFrame = clipFrame,
			ZoomExclusionRegion = zoomExclusionRegion,
			BaseTileLayer = baseTileLayer,
			BorderTileLayer = borderTileLayer,
			PinLayer = pinLayer,
			ZoomInButton = zoomInButton,
			ZoomOutButton = zoomOutButton,
			Locations = locations,
			TileManifest = tileManifest,
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
			TileSize = tileManifest.TileSize or 512,
			MinZoom = tileManifest.MinZoom or 0,
			MaxZoom = tileManifest.MaxZoom or 3,
			MinCameraZoom = nil,
			Center = Vector2.new(0.5, 0.5),
			Zoom = tileManifest.MinZoom or 0,
			ShowBorders = true,
			ActiveTiles = {
				base = {} :: TileMap,
				borders = {} :: TileMap,
			},
			TilePools = {
				base = {} :: TilePool,
				borders = {} :: TilePool,
			},
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

local function isUsableTileImage(image: string?): boolean
	return image ~= nil and image ~= "" and image ~= "rbxassetid://PLACEHOLDER"
end

function PickSpawnUtils.getTileImage(
	self: MapControllerPrivate,
	layerName: TileLayerName,
	zoom: number,
	x: number,
	y: number
): TileImage?
	local layer = self.TileManifest.Layers[layerName]
	if not layer then
		return nil
	end

	local image = layer[string.format("%d/%d/%d", zoom, x, y)]
	if isUsableTileImage(image) then
		return { Image = image, SourceZoom = zoom }
	end

	-- Higher-resolution assets are optional. Missing tiles are cropped from the
	-- corresponding first-level tile and scaled to the requested zoom level.
	local sourceZoom = self.MinZoom
	if zoom <= sourceZoom then
		return nil
	end

	local subdivisions = 2 ^ (zoom - sourceZoom)
	local sourceX = math.floor(x / subdivisions)
	local sourceY = math.floor(y / subdivisions)
	image = layer[string.format("%d/%d/%d", sourceZoom, sourceX, sourceY)]
	if not isUsableTileImage(image) then
		return nil
	end

	return { Image = image, SourceZoom = sourceZoom }
end

function PickSpawnUtils.getTileFromPool(self: MapControllerPrivate, layerName: TileLayerName): ImageLabel
	local tile = table.remove(self.TilePools[layerName]) :: ImageLabel?
	if tile then
		tile.Visible = true
		return tile
	end

	local newTile = Instance.new("ImageLabel")
	newTile.Name = "Tile"
	newTile.BackgroundTransparency = 1
	newTile.BorderSizePixel = 0
	newTile.ScaleType = Enum.ScaleType.Stretch
	newTile.Size = UDim2.fromOffset(self.TileSize, self.TileSize)
	newTile.ZIndex = if layerName == "base" then 1 else 2
	return newTile
end

function PickSpawnUtils.releaseTile(self: MapControllerPrivate, layerName: TileLayerName, key: string)
	local tile = self.ActiveTiles[layerName][key]
	if not tile then
		return
	end

	self.ActiveTiles[layerName][key] = nil
	tile.Visible = false
	tile.Image = ""
	tile.Parent = nil
	table.insert(self.TilePools[layerName], tile)
end

function PickSpawnUtils.renderTileLayer(
	self: MapControllerPrivate,
	layerName: TileLayerName,
	parentLayer: GuiObject,
	enabled: boolean
)
	local active = self.ActiveTiles[layerName]
	if not enabled then
		for key in pairs(active) do
			self:releaseTile(layerName, key)
		end
		return
	end

	local viewportSize = self.ClipFrame.AbsoluteSize
	local tileZoom = getTileZoomForCameraZoom(self)
	local tileWorldSize = self:getWorldPixelSize(tileZoom)
	local tileScale = (2 ^ (self.Zoom - tileZoom)) * self.ZoomScale
	local centerPixel = self.Center * tileWorldSize
	local viewMinPixel = centerPixel - viewportSize / (2 * tileScale)
	local viewMaxPixel = centerPixel + viewportSize / (2 * tileScale)
	local tilesX, tilesY = getTilesXYForZoom(tileZoom)
	local maxTileXBound = math.max(0, tilesX - 1)
	local maxTileYBound = math.max(0, tilesY - 1)
	local minTileX = math.clamp(math.floor(viewMinPixel.X / self.TileSize) - 1, 0, maxTileXBound)
	local maxTileX = math.clamp(math.floor(viewMaxPixel.X / self.TileSize) + 1, 0, maxTileXBound)
	local minTileY = math.clamp(math.floor(viewMinPixel.Y / self.TileSize) - 1, 0, maxTileYBound)
	local maxTileY = math.clamp(math.floor(viewMaxPixel.Y / self.TileSize) + 1, 0, maxTileYBound)
	local needed: { [string]: boolean } = {}

	for y = minTileY, maxTileY do
		for x = minTileX, maxTileX do
			local key = string.format("%d/%d/%d", tileZoom, x, y)
			needed[key] = true
			local tile = active[key] :: ImageLabel?
			local tileImage = self:getTileImage(layerName, tileZoom, x, y)

			if tileImage then
				if not tile then
					local pooledTile = self:getTileFromPool(layerName)
					pooledTile.Name = layerName .. "_" .. key
					pooledTile.Parent = parentLayer
					active[key] = pooledTile
					tile = pooledTile
				end

				assert(tile)
				tile.Image = tileImage.Image
				local subdivisions = 2 ^ (tileZoom - tileImage.SourceZoom)
				if subdivisions == 1 then
					tile.ImageRectOffset = Vector2.new(0, 0)
					tile.ImageRectSize = Vector2.new(0, 0)
				else
					local croppedSize = self.TileSize / subdivisions
					tile.ImageRectOffset =
						Vector2.new((x % subdivisions) * croppedSize, (y % subdivisions) * croppedSize)
					tile.ImageRectSize = Vector2.new(croppedSize, croppedSize)
				end

				local position = viewportSize / 2
					+ (Vector2.new(x * self.TileSize, y * self.TileSize) - centerPixel) * tileScale
				position = self:transformForZoomAnimation(position)
				tile.Position = UDim2.fromOffset(math.floor(position.X), math.floor(position.Y))
				tile.Size = UDim2.fromOffset(math.ceil(self.TileSize * tileScale), math.ceil(self.TileSize * tileScale))
			end
		end
	end

	for key in pairs(active) do
		if not needed[key] then
			self:releaseTile(layerName, key)
		end
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
	label.Size = UDim2.fromOffset(120, 22)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 12
	label.ZIndex = 11
	label.Parent = pin

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
	self:renderTileLayer("base", self.BaseTileLayer, true)
	self:renderTileLayer("borders", self.BorderTileLayer, self.ShowBorders)
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

	for layerName, active in pairs(self.ActiveTiles) do
		for key in pairs(active) do
			self:releaseTile(layerName :: TileLayerName, key :: string)
		end
	end
	self:releaseAllPins()
end

return PickSpawnUtils

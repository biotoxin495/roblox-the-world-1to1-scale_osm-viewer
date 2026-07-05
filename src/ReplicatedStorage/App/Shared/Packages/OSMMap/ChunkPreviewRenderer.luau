--!strict

--[=[
	A lightweight vector renderer for the chunk payload returned by the OSM API.
	Coordinates in the payload are already expressed in the chunk's world space:
	roads are [x, y, z], and area geometry is [x, z].  The renderer projects
	that space directly into the supplied ClipFrame.
]=]

local ConfirmSpawnInfoUtils = {}
ConfirmSpawnInfoUtils.__index = ConfirmSpawnInfoUtils
ConfirmSpawnInfoUtils.Name = "ConfirmSpawnInfoUtils"

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapSystem = ReplicatedStorage.App.Shared.Packages.MapSystem
local EditableImageCanvas = require(MapSystem.EditableImageCanvas)
local PrimitiveRasterizer = require(MapSystem.PrimitiveRasterizer)
local OSMChunkInterpreter = require(script.Parent.OSMChunkInterpreter)

type Point = Vector2
type ImageTile = EditableImageCanvas.ImageTile
type RenderTarget = {
	Gui: GuiObject,
	Tiles: { EditableImageCanvas.ImageTile },
	Size: Vector2,
}
type RoadLabelCandidate = {
	Name: string,
	From: Point,
	To: Point,
	Length: number,
}

export type LayerVisibility = {
	Roads: boolean,
	Buildings: boolean,
	Water: boolean,
	Landuse: boolean,
	Trees: boolean,
	Pois: boolean,
}

export type MapRenderer = {
	ClipFrame: GuiObject,
	Layer: Frame,
	Canvas: Frame,
	TileLayer: Frame,
	Overlay: Frame,
	ImageTiles: { ImageTile },
	TileSignature: string,
	Chunks: { [string]: any },
	LoadingChunks: { [string]: { X: number, Z: number } },
	InitialChunkKey: string,
	ResizeConnection: RBXScriptConnection?,
	Destroyed: boolean,
	CameraCenter: Vector2,
	CameraReferenceCenter: Vector2,
	CameraWorldSize: Vector2,
	CameraZoom: number,
	CameraBaseZoom: number,
	CameraZoomScale: number,
	CameraZoomAnchor: Vector2?,
	RenderQueued: boolean,
	LayerVisibility: LayerVisibility,
	Render: (self: MapRenderer) -> (),
	SetLayerVisibility: (self: MapRenderer, layerVisibility: LayerVisibility) -> (),
	SetCamera: (self: MapRenderer, center: Vector2, zoom: number, worldSize: Vector2, zoomScale: number, zoomAnchor: 
Vector2?) -> (),
	AddChunk: (self: MapRenderer, chunkX: number, chunkZ: number, data: any) -> (),
	RemoveChunk: (self: MapRenderer, chunkX: number, chunkZ: number) -> (),
	SetChunkLoading: (self: MapRenderer, chunkX: number, chunkZ: number, isLoading: boolean) -> (),
	GetVisibleChunkCoordinates: (self: MapRenderer, maxDistance: number) -> { { X: number, Z: number } },
	Destroy: (self: MapRenderer) -> (),
}

local MAP_BACKGROUND = Color3.fromRGB(235, 232, 222)
local BUILDING_FILL = Color3.fromRGB(208, 190, 169)
local BUILDING_OUTLINE = Color3.fromRGB(177, 157, 136)
local WATER_FILL = Color3.fromRGB(157, 203, 225)
local LANDUSE_FILL = Color3.fromRGB(203, 220, 187)
local LANDUSE_OUTLINE = Color3.fromRGB(184, 201, 169)
local FOREST_FILL = Color3.fromRGB(154, 187, 132)
local FOREST_OUTLINE = Color3.fromRGB(128, 159, 109)
local ORCHARD_FILL = Color3.fromRGB(176, 205, 139)
local ORCHARD_OUTLINE = Color3.fromRGB(143, 175, 111)
local ROAD_OUTLINE = Color3.fromRGB(192, 187, 177)
local POI_COLOUR = Color3.fromRGB(202, 78, 72)
local TREE_FILL = Color3.fromRGB(108, 156, 86)
local TREE_OUTLINE = Color3.fromRGB(69, 104, 57)
local TREE_ROW_COLOUR = Color3.fromRGB(122, 167, 99)
local SPAWN_MARKER_COLOUR = Color3.fromRGB(77, 181, 111)
local BOUNDARY_MARKER_COLOUR = Color3.fromRGB(247, 194, 64)
local ROAD_COLOURS = {
	motorway = Color3.fromRGB(242, 185, 145),
	trunk = Color3.fromRGB(245, 198, 159),
	primary = Color3.fromRGB(247, 211, 167),
	secondary = Color3.fromRGB(250, 225, 184),
	tertiary = Color3.fromRGB(252, 239, 202),
	residential = Color3.fromRGB(255, 255, 255),
	living_street = Color3.fromRGB(255, 255, 255),
	service = Color3.fromRGB(250, 250, 250),
	pedestrian = Color3.fromRGB(237, 229, 211),
	footway = Color3.fromRGB(223, 217, 205),
	path = Color3.fromRGB(223, 217, 205),
	cycleway = Color3.fromRGB(210, 229, 233),
}

local MAX_EDITABLE_IMAGE_SIZE = 1023

local function clearOverlay(layer: GuiObject)
	for _, child in ipairs(layer:GetChildren()) do
		child:Destroy()
	end
end

local function drawTargetRectangle(target: RenderTarget, position: Vector2, size: Vector2, colour: Color3)
	PrimitiveRasterizer.Rectangle(target :: any, position, size, colour)
end

local function drawTargetCircle(target: RenderTarget, center: Point, radius: number, colour: Color3)
	PrimitiveRasterizer.Circle(target :: any, center, radius, colour)
end

local function fillScreenPolygon(target: RenderTarget, polygon: { Point }, colour: Color3, step: number?)
	PrimitiveRasterizer.Polygon(target :: any, polygon, colour, step)
end

local function getOrCreateLayer(clipFrame: GuiObject): (Frame, Frame, Frame, Frame)
	local existing = clipFrame:FindFirstChild("OsmMapLayer")
	if existing and existing:IsA("Frame") then
		existing:Destroy()
	end

	local layer = Instance.new("Frame")
	layer.Name = "OsmMapLayer"
	layer.Active = false
	layer.BackgroundColor3 = MAP_BACKGROUND
	layer.BorderSizePixel = 0
	layer.ClipsDescendants = true
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = clipFrame.ZIndex + 1
	layer.Parent = clipFrame

	local canvas = Instance.new("Frame")
	canvas.Name = "MapCanvas"
	canvas.Active = false
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.BackgroundColor3 = MAP_BACKGROUND
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0
	canvas.ClipsDescendants = true
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.ZIndex = layer.ZIndex + 1
	canvas.Parent = layer

	local tileLayer = Instance.new("Frame")
	tileLayer.Name = "MapImageTiles"
	tileLayer.Active = false
	tileLayer.BackgroundTransparency = 1
	tileLayer.BorderSizePixel = 0
	tileLayer.ClipsDescendants = true
	tileLayer.Size = UDim2.fromScale(1, 1)
	tileLayer.ZIndex = canvas.ZIndex
	tileLayer.Parent = canvas

	local overlay = Instance.new("Frame")
	overlay.Name = "MapOverlay"
	overlay.Active = false
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ClipsDescendants = true
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = canvas.ZIndex + 50
	overlay.Parent = canvas

	return layer, canvas, tileLayer, overlay
end

local function createSegment(target: RenderTarget, from: Point, to: Point, thickness: number, colour: Color3, _zIndex: number)
	PrimitiveRasterizer.Segment(target :: any, from, to, thickness, colour)
end

local function finiteNumber(value: any): number?
	return OSMChunkInterpreter.FiniteNumber(value)
end

local function readPointCoordinates(point: any, isRoad: boolean): (number?, number?)
	return OSMChunkInterpreter.ReadPointCoordinates(point, isRoad)
end

local function projectCoordinates(
	x: number,
	z: number,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?
): Point
	-- This view's vertical coordinate is opposite to screen space. Horizontal
	-- coordinates already match screen space, so only mirror the vertical axis.
	local mapPosition = Vector2.new((x - minX) * scaleX, viewportSize.Y - (z - minZ) * scaleZ)
	local position = viewportSize / 2 + (mapPosition - viewportSize / 2) * zoomFactor - cameraOffset
	if animationZoomScale ~= 1 then
		local anchor = zoomAnchor or viewportSize / 2
		position = anchor + (position - anchor) * animationZoomScale
	end

	return position
end

local function getChunkBounds(data: any): (number, number, number, number)
	return OSMChunkInterpreter.GetChunkBounds(data)
end

local function getMapData(data: any): any
	return OSMChunkInterpreter.GetMapData(data)
end

local function getChunkKey(chunkX: number, chunkZ: number): string
	return OSMChunkInterpreter.GetChunkKey(chunkX, chunkZ)
end

local function clipSegmentToRect(from: Point, to: Point, minX: number, minY: number, maxX: number, maxY: number): 
(Point?, Point?)
	local delta = to - from
	local t0 = 0
	local t1 = 1
	local tests = {
		{ -delta.X, from.X - minX },
		{ delta.X, maxX - from.X },
		{ -delta.Y, from.Y - minY },
		{ delta.Y, maxY - from.Y },
	}

	for _, test in ipairs(tests) do
		local p = test[1]
		local q = test[2]
		if p == 0 then
			if q < 0 then
				return nil, nil
			end
		else
			local ratio = q / p
			if p < 0 then
				if ratio > t1 then
					return nil, nil
				end
				t0 = math.max(t0, ratio)
			elseif ratio < t0 then
				return nil, nil
			else
				t1 = math.min(t1, ratio)
			end
		end
	end

	return from + delta * t0, from + delta * t1
end

local function projectPoint(
	point: any,
	isRoad: boolean,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?
): Point?
	local x, z = readPointCoordinates(point, isRoad)
	if not x or not z then
		return nil
	end

	return projectCoordinates(
		x,
		z,
		minX,
		minZ,
		scaleX,
		scaleZ,
		viewportSize,
		cameraOffset,
		zoomFactor,
		animationZoomScale,
		zoomAnchor
	)
end

local function drawPath(
	target: RenderTarget,
	points: any,
	isRoad: boolean,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	thickness: number,
	colour: Color3,
	zIndex: number,
	closed: boolean?
)
	if type(points) ~= "table" or #points < 2 then
		return
	end

	local first = projectPoint(
		points[1],
		isRoad,
		minX,
		minZ,
		scaleX,
		scaleZ,
		viewportSize,
		cameraOffset,
		zoomFactor,
		animationZoomScale,
		zoomAnchor
	)
	local previous = first
	for index = 2, #points do
		local current = projectPoint(
			points[index],
			isRoad,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor
		)
		if previous and current then
			local clippedFrom, clippedTo = clipSegmentToRect(previous, current, 0, 0, target.Size.X, target.Size.Y)
			if clippedFrom and clippedTo then
				createSegment(target, clippedFrom, clippedTo, thickness, colour, zIndex)
			end
		end
		previous = current
	end

	if closed and previous and first then
		local clippedFrom, clippedTo = clipSegmentToRect(previous, first, 0, 0, target.Size.X, target.Size.Y)
		if clippedFrom and clippedTo then
			createSegment(target, clippedFrom, clippedTo, thickness, colour, zIndex)
		end
	end
end

local function getLongestVisibleRoadSegment(
	points: any,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?
): (Point?, Point?, number)
	if type(points) ~= "table" or #points < 2 then
		return nil, nil, 0
	end

	local previous = projectPoint(
		points[1],
		true,
		minX,
		minZ,
		scaleX,
		scaleZ,
		viewportSize,
		cameraOffset,
		zoomFactor,
		animationZoomScale,
		zoomAnchor
	)
	local longestFrom: Point? = nil
	local longestTo: Point? = nil
	local longestLength = 0

	for index = 2, #points do
		local current = projectPoint(
			points[index],
			true,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor
		)
		if previous and current then
			local clippedFrom, clippedTo = clipSegmentToRect(previous, current, 0, 0, viewportSize.X, viewportSize.Y)
			if clippedFrom and clippedTo then
				local length = (clippedTo - clippedFrom).Magnitude
				if length > longestLength then
					longestFrom = clippedFrom
					longestTo = clippedTo
					longestLength = length
				end
			end
		end
		previous = current
	end

	return longestFrom, longestTo, longestLength
end

local function drawRoadLabel(parent: GuiObject, candidate: RoadLabelCandidate, zIndex: number)
	if candidate.Length < 52 then
		return
	end

	local delta = candidate.To - candidate.From
	local rotation = math.deg(math.atan2(delta.Y, delta.X))
	if rotation > 90 or rotation < -90 then
		rotation += 180
	end

	local label = Instance.new("TextLabel")
	label.Name = "RoadLabel"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Position = UDim2.fromOffset((candidate.From.X + candidate.To.X) * 0.5, (candidate.From.Y + candidate.To.Y) * 
0.5)
	label.Rotation = rotation
	label.Size = UDim2.fromOffset(math.min(candidate.Length - 8, 180), 16)
	label.Text = candidate.Name
	label.TextColor3 = Color3.fromRGB(58, 58, 58)
	label.TextSize = 11
	label.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.2
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.ZIndex = zIndex
	label.Parent = parent
end

local function fillPolygon(
	target: RenderTarget,
	points: any,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	colour: Color3,
	zIndex: number
)
	if type(points) ~= "table" or #points < 3 then
		return
	end

	local polygon = {} :: { Point }
	for _, point in ipairs(points) do
		local projected = projectPoint(
			point,
			false,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor
		)
		if projected then
			table.insert(polygon, projected)
		end
	end
	if #polygon < 3 then
		return
	end

	fillScreenPolygon(target, polygon, colour, 2)
end

local function drawAreaCollection(
	target: RenderTarget,
	features: any,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	fillColour: Color3,
	outlineColour: Color3,
	zIndex: number,
	resolveColours: ((any) -> (Color3, Color3))?
)
	if type(features) ~= "table" then
		return
	end

	for _, feature in ipairs(features) do
		local featureFillColour = fillColour
		local featureOutlineColour = outlineColour
		if resolveColours then
			featureFillColour, featureOutlineColour = resolveColours(feature)
		end

		local polygons = feature.polygons
		if not polygons and feature.footprint then
			polygons = { feature.footprint }
		end
		if type(polygons) == "table" then
			for _, polygon in ipairs(polygons) do
				fillPolygon(
					target,
					polygon,
					minX,
					minZ,
					scaleX,
					scaleZ,
					viewportSize,
					cameraOffset,
					zoomFactor,
					animationZoomScale,
					zoomAnchor,
					featureFillColour,
					zIndex
				)
				drawPath(
					target,
					polygon,
					false,
					minX,
					minZ,
					scaleX,
					scaleZ,
					viewportSize,
					cameraOffset,
					zoomFactor,
					animationZoomScale,
					zoomAnchor,
					1,
					featureOutlineColour,
					zIndex + 1,
					true
				)
			end
		end
	end
end

local function resolveLanduseColours(feature: any): (Color3, Color3)
	local kind = if type(feature) == "table" and type(feature.kind) == "string" then string.lower(feature.kind) else ""
	if kind == "forest" or kind == "wood" then
		return FOREST_FILL, FOREST_OUTLINE
	end
	if kind == "orchard" then
		return ORCHARD_FILL, ORCHARD_OUTLINE
	end
	return LANDUSE_FILL, LANDUSE_OUTLINE
end

local function createCircularMarker(
	target: RenderTarget,
	_name: string,
	position: Point,
	diameter: number,
	fillColour: Color3,
	outlineColour: Color3,
	_zIndex: number
)
	drawTargetCircle(target, position, diameter * 0.5, outlineColour)
	drawTargetCircle(target, position, math.max(1, diameter * 0.5 - 1), fillColour)
end

local function getTreeMarkerDiameter(
	tree: any,
	scaleX: number,
	scaleZ: number,
	zoomFactor: number,
	animationZoomScale: number
): number
	local crownDiameter = if type(tree) == "table" then finiteNumber(tree.crownDiameter) else nil
	if crownDiameter and crownDiameter > 0 then
		return math.clamp(crownDiameter * math.min(scaleX, scaleZ) * zoomFactor * animationZoomScale, 4, 14)
	end

	return math.clamp(5 * math.sqrt(math.max(zoomFactor * animationZoomScale, 0.35)), 4, 10)
end

local function getTreeRowPoints(tree: any): any
	if type(tree) ~= "table" then
		return nil
	end

	if type(tree.points) == "table" then
		return tree.points
	end
	if type(tree.positions) == "table" then
		return tree.positions
	end
	if type(tree.path) == "table" then
		return tree.path
	end

	return nil
end

local function drawTreeCollection(
	target: RenderTarget,
	trees: any,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	zIndex: number
)
	if type(trees) ~= "table" then
		return
	end

	local rowThickness = math.clamp(1.5 * math.sqrt(math.max(zoomFactor * animationZoomScale, 0.5)), 1, 5)
	for _, tree in ipairs(trees) do
		if type(tree) ~= "table" then
			continue
		end

		local position = projectPoint(
			tree.position,
			true,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor
		)
		if position then
			local diameter = getTreeMarkerDiameter(tree, scaleX, scaleZ, zoomFactor, animationZoomScale)
			if
				position.X >= -diameter
				and position.Y >= -diameter
				and position.X <= target.Size.X + diameter
				and position.Y <= target.Size.Y + diameter
			then
				createCircularMarker(target, "Tree", position, diameter, TREE_FILL, TREE_OUTLINE, zIndex)
			end
			continue
		end

		local rowPoints = getTreeRowPoints(tree)
		if type(rowPoints) ~= "table" or #rowPoints == 0 then
			continue
		end

		drawPath(
			target,
			rowPoints,
			true,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			rowThickness + 1,
			TREE_OUTLINE,
			zIndex,
			false
		)
		drawPath(
			target,
			rowPoints,
			true,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			rowThickness,
			TREE_ROW_COLOUR,
			zIndex + 1,
			false
		)

		for _, rowPoint in ipairs(rowPoints) do
			local rowPosition = projectPoint(
				rowPoint,
				true,
				minX,
				minZ,
				scaleX,
				scaleZ,
				viewportSize,
				cameraOffset,
				zoomFactor,
				animationZoomScale,
				zoomAnchor
			)
			local rowMarkerDiameter = math.max(4, rowThickness + 3)
			if
				rowPosition
				and rowPosition.X >= -rowMarkerDiameter
				and rowPosition.Y >= -rowMarkerDiameter
				and rowPosition.X <= target.Size.X + rowMarkerDiameter
				and rowPosition.Y <= target.Size.Y + rowMarkerDiameter
			then
				createCircularMarker(target, "TreeRowPoint", rowPosition, rowMarkerDiameter, TREE_FILL, TREE_OUTLINE, zIndex + 2)
			end
		end
	end
end

local function drawPois(
	target: RenderTarget,
	pois: any,
	minX: number,
	minZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	zIndex: number
)
	if type(pois) ~= "table" then
		return
	end

	for _, poi in ipairs(pois) do
		local position = projectPoint(
			poi.position,
			true,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor
		)
		if
			position
			and position.X >= -8
			and position.Y >= -8
			and position.X <= target.Size.X + 8
			and position.Y <= target.Size.Y + 8
		then
			createCircularMarker(target, "Poi", position, 10, POI_COLOUR, Color3.fromRGB(255, 255, 255), zIndex)

			if type(poi.name) == "string" and poi.name ~= "" then
				local label = Instance.new("TextLabel")
				label.Name = "Label"
				label.AnchorPoint = Vector2.new(0.5, 1)
				label.BackgroundTransparency = 1
				label.Position = UDim2.fromOffset(position.X, position.Y - 8)
				label.Size = UDim2.fromOffset(140, 18)
				label.Font = Enum.Font.GothamMedium
				label.Text = poi.name
				label.TextColor3 = Color3.fromRGB(50, 50, 50)
				label.TextSize = 11
				label.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
				label.TextStrokeTransparency = 0.15
				label.TextTruncate = Enum.TextTruncate.AtEnd
				label.ZIndex = zIndex + 1
				label.Parent = target.Gui
			end
		end
	end
end

local function drawReferenceMarker(
	target: RenderTarget,
	_name: string,
	position: Point,
	colour: Color3,
	size: number,
	zIndex: number,
	labelText: string?
)
	if position.X < -size or position.Y < -size or position.X > target.Size.X + size or position.Y > target.Size.Y + size then
		return
	end

	createCircularMarker(target, _name, position, size, colour, Color3.fromRGB(255, 255, 255), zIndex)

	if labelText then
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(position.X, position.Y - size * 0.5 - 3)
		label.Size = UDim2.fromOffset(110, 18)
		label.Font = Enum.Font.GothamBold
		label.Text = labelText
		label.TextColor3 = Color3.fromRGB(38, 78, 51)
		label.TextSize = 11
		label.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0.1
		label.ZIndex = zIndex + 1
		label.Parent = target.Gui
	end
end

local function drawChunkReferenceMarkers(
	target: RenderTarget,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	spawnX: number,
	spawnZ: number,
	mapMinX: number,
	mapMinZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	zIndex: number,
	drawSpawnMarker: boolean?
)
	-- Draw a continuous outline as well as corner markers. Corner-only markers
	-- sit half outside the ClipFrame at the exact chunk edge and are easy to
	-- miss, especially at the initial zoom.
	drawPath(
		target,
		{
			{ minX, 0, minZ },
			{ minX, 0, maxZ },
			{ maxX, 0, maxZ },
			{ maxX, 0, minZ },
		},
		true,
		mapMinX,
		mapMinZ,
		scaleX,
		scaleZ,
		viewportSize,
		cameraOffset,
		zoomFactor,
		animationZoomScale,
		zoomAnchor,
		3,
		BOUNDARY_MARKER_COLOUR,
		zIndex,
		true
	)

	local function projectWorldPosition(x: number, z: number): Point?
		return projectPoint(
			{ x, 0, z },
			true,
			mapMinX,
			mapMinZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor
		)
	end

	local spawnPosition = projectWorldPosition(spawnX, spawnZ)
	if drawSpawnMarker and spawnPosition then
		drawReferenceMarker(target, "SpawnMarker", spawnPosition, SPAWN_MARKER_COLOUR, 14, zIndex + 1, "SPAWN")
	end

	for _, corner in ipairs({
		Vector2.new(minX, minZ),
		Vector2.new(minX, maxZ),
		Vector2.new(maxX, minZ),
		Vector2.new(maxX, maxZ),
	}) do
		local position = projectWorldPosition(corner.X, corner.Y)
		if position then
			drawReferenceMarker(target, "ChunkBoundaryMarker", position, BOUNDARY_MARKER_COLOUR, 8, zIndex, nil)
		end
	end
end

local function drawChunkLoadingLabel(
	parent: GuiObject,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	mapMinX: number,
	mapMinZ: number,
	scaleX: number,
	scaleZ: number,
	viewportSize: Vector2,
	cameraOffset: Vector2,
	zoomFactor: number,
	animationZoomScale: number,
	zoomAnchor: Vector2?,
	zIndex: number
)
	local position = projectPoint(
		{ (minX + maxX) * 0.5, 0, (minZ + maxZ) * 0.5 },
		true,
		mapMinX,
		mapMinZ,
		scaleX,
		scaleZ,
		viewportSize,
		cameraOffset,
		zoomFactor,
		animationZoomScale,
		zoomAnchor
	)
	if not position then
		return
	end

	local horizontalMargin = math.min(52, parent.AbsoluteSize.X * 0.5)
	local verticalMargin = math.min(13, parent.AbsoluteSize.Y * 0.5)
	position = Vector2.new(
		math.clamp(position.X, horizontalMargin, parent.AbsoluteSize.X - horizontalMargin),
		math.clamp(position.Y, verticalMargin, parent.AbsoluteSize.Y - verticalMargin)
	)

	local label = Instance.new("TextLabel")
	label.Name = "ChunkLoading"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	label.BackgroundTransparency = 0.15
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Position = UDim2.fromOffset(position.X, position.Y)
	label.Size = UDim2.fromOffset(104, 26)
	label.Text = "LOADING..."
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 11
	label.ZIndex = zIndex
	label.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = label
end

local function buildTileSignature(size: Vector2): string
	return string.format("%dx%d", math.ceil(size.X), math.ceil(size.Y))
end

local function createImageTiles(tileLayer: Frame, size: Vector2, zIndex: number): { ImageTile }?
	clearOverlay(tileLayer)

	local tiles = {} :: { ImageTile }
	local columns = math.max(1, math.ceil(size.X / MAX_EDITABLE_IMAGE_SIZE))
	local rows = math.max(1, math.ceil(size.Y / MAX_EDITABLE_IMAGE_SIZE))
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local offset = Vector2.new(column * MAX_EDITABLE_IMAGE_SIZE, row * MAX_EDITABLE_IMAGE_SIZE)
			local tileSize = Vector2.new(
				math.min(MAX_EDITABLE_IMAGE_SIZE, size.X - offset.X),
				math.min(MAX_EDITABLE_IMAGE_SIZE, size.Y - offset.Y)
			)
			if tileSize.X <= 0 or tileSize.Y <= 0 then
				continue
			end

			local editableImage = EditableImageCanvas.CreateEditableImage(tileSize, "OSM map")
			if not editableImage then
				return nil
			end

			local imageLabel = Instance.new("ImageLabel")
			imageLabel.Name = string.format("Tile_%d_%d", column, row)
			imageLabel.Active = false
			imageLabel.BackgroundTransparency = 1
			imageLabel.BorderSizePixel = 0
			imageLabel.Position = UDim2.fromOffset(offset.X, offset.Y)
			imageLabel.ScaleType = Enum.ScaleType.Stretch
			imageLabel.Size = UDim2.fromOffset(tileSize.X, tileSize.Y)
			imageLabel.ZIndex = zIndex
			imageLabel.Parent = tileLayer
			EditableImageCanvas.SetImageContent(imageLabel, editableImage, "OSM map")

			table.insert(tiles, {
				Gui = imageLabel,
				Image = editableImage,
				Offset = offset,
				Size = tileSize,
			})
		end
	end

	return tiles
end

local function getImageTiles(self: MapRenderer, size: Vector2): { ImageTile }?
	local signature = buildTileSignature(size)
	if self.TileSignature ~= signature then
		local tiles = createImageTiles(self.TileLayer, size, self.Canvas.ZIndex)
		if not tiles then
			self.ImageTiles = {}
			self.TileSignature = ""
			return nil
		end
		self.ImageTiles = tiles
		self.TileSignature = signature
	end

	return self.ImageTiles
end

function ConfirmSpawnInfoUtils.Create(clipFrame: GuiObject, data: any): MapRenderer
	local layer, canvas, tileLayer, overlay = getOrCreateLayer(clipFrame)
	local initialData = getMapData(data)
	local initialMetadata = if type(initialData) == "table" then initialData.chunk else nil
	local initialChunkX = if type(initialMetadata) == "table" then tonumber(initialMetadata.x) or 0 else 0
	local initialChunkZ = if type(initialMetadata) == "table" then tonumber(initialMetadata.z) or 0 else 0
	local initialChunkKey = getChunkKey(initialChunkX, initialChunkZ)
	local self = setmetatable({
		ClipFrame = clipFrame,
		Layer = layer,
		Canvas = canvas,
		TileLayer = tileLayer,
		Overlay = overlay,
		ImageTiles = {} :: { ImageTile },
		TileSignature = "",
		Chunks = {
			[initialChunkKey] = data,
		},
		LoadingChunks = {} :: { [string]: { X: number, Z: number } },
		InitialChunkKey = initialChunkKey,
		ResizeConnection = nil,
		Destroyed = false,
		CameraCenter = Vector2.new(0.5, 0.5),
		CameraReferenceCenter = Vector2.new(0.5, 0.5),
		CameraWorldSize = Vector2.new(512, 256),
		CameraZoom = 0,
		CameraBaseZoom = 0,
		CameraZoomScale = 1,
		CameraZoomAnchor = nil,
		RenderQueued = false,
		LayerVisibility = {
			Roads = true,
			Buildings = true,
			Water = true,
			Landuse = true,
			Trees = true,
			Pois = true,
		},
	}, ConfirmSpawnInfoUtils) :: any

	self.ResizeConnection = clipFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:Render()
	end)

	return self
end

function ConfirmSpawnInfoUtils.SetLayerVisibility(self: MapRenderer, layerVisibility: LayerVisibility)
	if self.Destroyed then
		return
	end
	self.LayerVisibility = layerVisibility
	self:Render()
end

function ConfirmSpawnInfoUtils.AddChunk(self: MapRenderer, chunkX: number, chunkZ: number, data: any)
	if self.Destroyed then
		return
	end

	local chunkKey = getChunkKey(chunkX, chunkZ)
	self.Chunks[chunkKey] = data
	self.LoadingChunks[chunkKey] = nil
	self:Render()
end

function ConfirmSpawnInfoUtils.RemoveChunk(self: MapRenderer, chunkX: number, chunkZ: number)
	if self.Destroyed then
		return
	end
	local chunkKey = getChunkKey(chunkX, chunkZ)
	if chunkKey == self.InitialChunkKey then
		return
	end
	self.Chunks[chunkKey] = nil
	self.LoadingChunks[chunkKey] = nil
	self:Render()
end

function ConfirmSpawnInfoUtils.SetChunkLoading(
	self: MapRenderer,
	chunkX: number,
	chunkZ: number,
	isLoading: boolean
)
	if self.Destroyed then
		return
	end

	local chunkKey = getChunkKey(chunkX, chunkZ)
	if isLoading then
		self.LoadingChunks[chunkKey] = {
			X = chunkX,
			Z = chunkZ,
		}
	else
		self.LoadingChunks[chunkKey] = nil
	end
	self:Render()
end

function ConfirmSpawnInfoUtils.GetVisibleChunkCoordinates(
	self: MapRenderer,
	maxDistance: number
): { { X: number, Z: number } }
	local initialData = getMapData(self.Chunks[self.InitialChunkKey])
	if type(initialData) ~= "table" then
		return {}
	end

	local layerSize = self.Layer.AbsoluteSize
	if layerSize.X < 1 or layerSize.Y < 1 then
		return {}
	end

	local minX, minZ, maxX, maxZ = getChunkBounds(initialData)
	local initialMetadata = initialData.chunk or {}
	local initialChunkX = tonumber(initialMetadata.x) or 0
	local initialChunkZ = tonumber(initialMetadata.z) or 0
	local chunkWidth = maxX - minX
	local chunkHeight = maxZ - minZ
	local canvasSide = math.max(layerSize.X, layerSize.Y)
	-- Derive this from the layout rather than Canvas.AbsolutePosition: a view
	-- change may arrive before the deferred renderer has applied its new size.
	local canvasOffset = (layerSize - Vector2.new(canvasSide, canvasSide)) / 2
	local zoomFactor = 2 ^ (self.CameraZoom - self.CameraBaseZoom)
	local animationZoomScale = self.CameraZoomScale
	local zoomAnchor = if self.CameraZoomAnchor then self.CameraZoomAnchor - canvasOffset else Vector2.new(canvasSide, canvasSide) / 2
	local cameraOffset = (self.CameraCenter - self.CameraReferenceCenter) * self.CameraWorldSize

	local function screenToWorld(screenPosition: Vector2): Vector2
		local canvasPosition = screenPosition - canvasOffset
		if animationZoomScale ~= 1 then
			canvasPosition = zoomAnchor + (canvasPosition - zoomAnchor) / animationZoomScale
		end
		local mapPosition = Vector2.new(
			canvasSide / 2 + (canvasPosition.X + cameraOffset.X - canvasSide / 2) / zoomFactor,
			canvasSide / 2 + (canvasPosition.Y + cameraOffset.Y - canvasSide / 2) / zoomFactor
		)
		return Vector2.new(minX + mapPosition.X * chunkWidth / canvasSide, minZ + (canvasSide - mapPosition.Y) * chunkHeight / canvasSide)
	end

	local firstCorner = screenToWorld(Vector2.zero)
	local secondCorner = screenToWorld(layerSize)
	local minVisibleX = math.min(firstCorner.X, secondCorner.X)
	local maxVisibleX = math.max(firstCorner.X, secondCorner.X)
	local minVisibleZ = math.min(firstCorner.Y, secondCorner.Y)
	local maxVisibleZ = math.max(firstCorner.Y, secondCorner.Y)
	-- A chunk that only shares the viewport edge is not visible yet. The small
	-- epsilon prevents the initial exact-fit view from preloading neighbours.
	local edgeEpsilon = 0.001
	local startX = math.floor((minVisibleX - minX + edgeEpsilon) / chunkWidth)
	local endX = math.floor((maxVisibleX - minX - edgeEpsilon) / chunkWidth)
	local startZ = math.floor((minVisibleZ - minZ + edgeEpsilon) / chunkHeight)
	local endZ = math.floor((maxVisibleZ - minZ - edgeEpsilon) / chunkHeight)
	local coordinates = {} :: { { X: number, Z: number } }

	for offsetZ = startZ, endZ do
		for offsetX = startX, endX do
			if math.abs(offsetX) <= maxDistance and math.abs(offsetZ) <= maxDistance then
				table.insert(coordinates, {
					X = initialChunkX + offsetX,
					Z = initialChunkZ + offsetZ,
				})
			end
		end
	end

	return coordinates
end

function ConfirmSpawnInfoUtils.SetCamera(
	self: MapRenderer,
	center: Vector2,
	zoom: number,
	worldSize: Vector2,
	zoomScale: number,
	zoomAnchor: Vector2?
)
	if self.Destroyed then
		return
	end

	self.CameraCenter = center
	self.CameraZoom = zoom
	self.CameraWorldSize = worldSize
	self.CameraZoomScale = zoomScale
	self.CameraZoomAnchor = zoomAnchor

	if self.RenderQueued then
		return
	end
	self.RenderQueued = true
	task.defer(function()
		self.RenderQueued = false
		self:Render()
	end)
end

function ConfirmSpawnInfoUtils.Render(self: MapRenderer)
	if self.Destroyed then
		return
	end

	local layer = self.Layer
	local layerSize = layer.AbsoluteSize
	if layerSize.X < 1 or layerSize.Y < 1 then
		return
	end

	-- A chunk is square in world space. Rendering directly into a rectangular
	-- ClipFrame independently scales X and Z, which distorts all OSM geometry.
	-- Use a centered square canvas with cover sizing: it preserves scale while
	-- filling the full viewport, and the parent layer clips the excess axis.
	local canvas = self.Canvas
	local canvasSide = math.max(layerSize.X, layerSize.Y)
	canvas.Size = UDim2.fromOffset(canvasSide, canvasSide)
	self.TileLayer.Size = UDim2.fromOffset(canvasSide, canvasSide)
	self.Overlay.Size = UDim2.fromOffset(canvasSide, canvasSide)
	local imageSide = math.max(1, math.ceil(canvasSide))
	local size = Vector2.new(imageSide, imageSide)

	clearOverlay(self.Overlay)
	local imageTiles = getImageTiles(self, size)
	if not imageTiles then
		return
	end
	local renderTarget: RenderTarget = {
		Gui = self.Overlay,
		Tiles = imageTiles,
		Size = size,
	}
	drawTargetRectangle(renderTarget, Vector2.zero, size, MAP_BACKGROUND)
	local initialData = getMapData(self.Chunks[self.InitialChunkKey])
	if type(initialData) ~= "table" then
		warn("Cannot render OSM map: expected a decoded data table")
		return
	end

	-- Every chunk uses the initial chunk's world-space projection. Chunk payload
	-- coordinates are already relative to the same API origin, so this keeps
	-- adjacent chunks continuous while the camera pans between them.
	local minX, minZ, maxX, maxZ = getChunkBounds(initialData)
	local zoomFactor = 2 ^ (self.CameraZoom - self.CameraBaseZoom)
	local scaleX = size.X / (maxX - minX)
	local scaleZ = scaleX
	local cameraOffset = (self.CameraCenter - self.CameraReferenceCenter) * self.CameraWorldSize
	local viewportSize = size
	local animationZoomScale = self.CameraZoomScale
	local canvasOffset = canvas.AbsolutePosition - layer.AbsolutePosition
	local zoomAnchor = if self.CameraZoomAnchor then self.CameraZoomAnchor - canvasOffset else nil
	local zIndex = canvas.ZIndex + 1
	local function isChunkVisible(data: any): boolean
		local chunkMinX, chunkMinZ, chunkMaxX, chunkMaxZ = getChunkBounds(data)
		local corners = {
			projectCoordinates(chunkMinX, chunkMinZ, minX, minZ, scaleX, scaleZ, viewportSize, cameraOffset, zoomFactor, animationZoomScale, zoomAnchor),
			projectCoordinates(chunkMinX, chunkMaxZ, minX, minZ, scaleX, scaleZ, viewportSize, cameraOffset, zoomFactor, animationZoomScale, zoomAnchor),
			projectCoordinates(chunkMaxX, chunkMinZ, minX, minZ, scaleX, scaleZ, viewportSize, cameraOffset, zoomFactor, animationZoomScale, zoomAnchor),
			projectCoordinates(chunkMaxX, chunkMaxZ, minX, minZ, scaleX, scaleZ, viewportSize, cameraOffset, zoomFactor, animationZoomScale, zoomAnchor),
		}
		local visibleMinX, visibleMinY = math.huge, math.huge
		local visibleMaxX, visibleMaxY = -math.huge, -math.huge
		for _, corner in ipairs(corners) do
			visibleMinX = math.min(visibleMinX, corner.X)
			visibleMinY = math.min(visibleMinY, corner.Y)
			visibleMaxX = math.max(visibleMaxX, corner.X)
			visibleMaxY = math.max(visibleMaxY, corner.Y)
		end
		return visibleMaxX >= 0 and visibleMinX <= size.X and visibleMaxY >= 0 and visibleMinY <= size.Y
	end

	local roadLabelsByName = {} :: { [string]: RoadLabelCandidate }
	for _, chunkData in pairs(self.Chunks) do
		local data = getMapData(chunkData)
		if type(data) ~= "table" then
			continue
		end
		if not isChunkVisible(data) then
			continue
		end

		-- Areas first, then roads, matching normal cartographic layer order.
		if self.LayerVisibility.Water then drawAreaCollection(
			renderTarget,
			data.water,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			WATER_FILL,
			WATER_FILL,
			zIndex,
			nil
		) end
		if self.LayerVisibility.Landuse then drawAreaCollection(
			renderTarget,
			data.landuse,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			LANDUSE_FILL,
			LANDUSE_OUTLINE,
			zIndex + 2,
			resolveLanduseColours
		) end
		if self.LayerVisibility.Trees then drawTreeCollection(
			renderTarget,
			data.trees,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			zIndex + 4
		) end
		if self.LayerVisibility.Buildings then drawAreaCollection(
			renderTarget,
			data.buildings,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			BUILDING_FILL,
			BUILDING_OUTLINE,
			zIndex + 6,
			nil
		) end

		if self.LayerVisibility.Roads and type(data.roads) == "table" then
			for _, road in ipairs(data.roads) do
				local width = tonumber(road.width) or 3
				local roadThickness = math.max(1, width * math.min(scaleX, scaleZ) * zoomFactor * animationZoomScale)
				local roadColour = ROAD_COLOURS[road.class] or Color3.fromRGB(248, 248, 248)
				drawPath(
					renderTarget,
					road.points,
					true,
					minX,
					minZ,
					scaleX,
					scaleZ,
					viewportSize,
					cameraOffset,
					zoomFactor,
					animationZoomScale,
					zoomAnchor,
					roadThickness + 1.5,
					ROAD_OUTLINE,
					zIndex + 8,
					false
				)
				drawPath(
					renderTarget,
					road.points,
					true,
					minX,
					minZ,
					scaleX,
					scaleZ,
					viewportSize,
					cameraOffset,
					zoomFactor,
					animationZoomScale,
					zoomAnchor,
					roadThickness,
					roadColour,
					zIndex + 9,
					false
				)

				if type(road.name) == "string" and road.name ~= "" then
					local from, to, length = getLongestVisibleRoadSegment(
						road.points,
						minX,
						minZ,
						scaleX,
						scaleZ,
						viewportSize,
						cameraOffset,
						zoomFactor,
						animationZoomScale,
						zoomAnchor
					)
					if from and to and length >= 52 then
						local existing = roadLabelsByName[road.name]
						if not existing or length > existing.Length then
							roadLabelsByName[road.name] = {
								Name = road.name,
								From = from,
								To = to,
								Length = length,
							}
						end
					end
				end
			end
			end

		if self.LayerVisibility.Pois then drawPois(
			renderTarget,
			data.pois,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			zIndex + 11
		) end
	end

	if self.LayerVisibility.Roads then
		for _, candidate in pairs(roadLabelsByName) do
			drawRoadLabel(self.Overlay, candidate, zIndex + 10)
		end
	end

	-- Draw a boundary for every streamed chunk. The spawn marker remains tied
	-- to the original chunk so neighbouring chunks do not look like spawns.
	for chunkKey, chunkData in pairs(self.Chunks) do
		local data = getMapData(chunkData)
		if type(data) ~= "table" then
			continue
		end
		if not isChunkVisible(data) then
			continue
		end

		local chunkMinX, chunkMinZ, chunkMaxX, chunkMaxZ = getChunkBounds(data)
		local metadata = data.chunk or {}
		local chunkSpawnX = tonumber(metadata.x) or chunkMinX
		local chunkSpawnZ = tonumber(metadata.z) or chunkMinZ
		drawChunkReferenceMarkers(
			renderTarget,
			chunkMinX,
			chunkMinZ,
			chunkMaxX,
			chunkMaxZ,
			chunkSpawnX,
			chunkSpawnZ,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			zIndex + 20,
			chunkKey == self.InitialChunkKey
		)
	end

	local initialMetadata = initialData.chunk or {}
	local initialChunkX = tonumber(initialMetadata.x) or 0
	local initialChunkZ = tonumber(initialMetadata.z) or 0
	local chunkWidth = maxX - minX
	local chunkHeight = maxZ - minZ
	for chunkKey, coordinate in pairs(self.LoadingChunks) do
		if self.Chunks[chunkKey] then
			continue
		end

		local offsetX = coordinate.X - initialChunkX
		local offsetZ = coordinate.Z - initialChunkZ
		local chunkMinX = minX + offsetX * chunkWidth
		local chunkMinZ = minZ + offsetZ * chunkHeight
		local chunkMaxX = chunkMinX + chunkWidth
		local chunkMaxZ = chunkMinZ + chunkHeight
		drawChunkReferenceMarkers(
			renderTarget,
			chunkMinX,
			chunkMinZ,
			chunkMaxX,
			chunkMaxZ,
			chunkMinX + chunkWidth * 0.5,
			chunkMinZ + chunkHeight * 0.5,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			zIndex + 20,
			false
		)
		drawChunkLoadingLabel(
			self.Overlay,
			chunkMinX,
			chunkMinZ,
			chunkMaxX,
			chunkMaxZ,
			minX,
			minZ,
			scaleX,
			scaleZ,
			viewportSize,
			cameraOffset,
			zoomFactor,
			animationZoomScale,
			zoomAnchor,
			zIndex + 22
		)
	end
end

function ConfirmSpawnInfoUtils.Destroy(self: MapRenderer)
	if self.Destroyed then
		return
	end

	self.Destroyed = true
	if self.ResizeConnection then
		self.ResizeConnection:Disconnect()
		self.ResizeConnection = nil
	end
	self.Layer:Destroy()
end

return ConfirmSpawnInfoUtils

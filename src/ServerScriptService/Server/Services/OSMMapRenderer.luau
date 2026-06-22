--!strict

--[[
	Turns decoded OSM map chunks into server-owned, physical Roblox geometry.

	The API's X/Z coordinates are already local world coordinates.  This module
	deliberately keeps them as X/Z (rather than mirroring Z as the UI renderer
	does for screen space), so a point from the payload maps directly to the
	corresponding point in Workspace.

	Render replaces the whole current map. AddChunk is intended for chunk
	streaming and replaces only the chunk with matching metadata x/z values.
]]

local Workspace = game:GetService("Workspace")

local OsmApiReturnedData = require(game.ReplicatedStorage.App.OsmApiReturnedData)

type MapPoint = Vector2

export type RenderOptions = {
	Parent: Instance?,
	WorldOffset: Vector3?,
	StudsPerMapUnit: number?,
	DebugReferences: boolean?,
	-- Retained for caller compatibility. Exact polygon prisms do not need a
	-- resolution-dependent quality setting.
	Quality: "Low" | "Medium" | "High"?,
}

local OSMMapRenderer = {
	Name = "OSMMapRenderer",
	Priority = 50,
	Root = nil :: Folder?,
	ChunkModels = {} :: { [string]: Model },
	WorldOffset = Vector3.zero,
	StudsPerMapUnit = 1,
	DebugReferences = false,
}

local ROOT_NAME = "OSMMap"
local ROAD_HEIGHT = 0.16
local WATER_HEIGHT = 0.08
local WATERWAY_HEIGHT = 0.035
local WATERWAY_SURFACE_OFFSET = 0.002
local LANDUSE_HEIGHT = 0.06
local BUILDING_MIN_HEIGHT = 6
local BUILDING_DEFAULT_FLOOR_HEIGHT = 3
local BUILDING_EDGE_THICKNESS = 0.16
local AREA_EDGE_THICKNESS = 0.08
local TRIANGULATION_EPSILON = 0.00001
local OPEN_WATERWAY_CLOSURE_RATIO = 0.15

local WATERWAY_WIDTHS: { [string]: number } = {
	stream = 2,
	ditch = 1.25,
	drain = 1.25,
	canal = 5,
	river = 8,
}

local ROAD_COLOURS: { [string]: Color3 } = {
	motorway = Color3.fromRGB(74, 80, 91),
	trunk = Color3.fromRGB(84, 88, 94),
	primary = Color3.fromRGB(94, 96, 96),
	secondary = Color3.fromRGB(110, 109, 103),
	tertiary = Color3.fromRGB(125, 120, 108),
	residential = Color3.fromRGB(139, 136, 128),
	living_street = Color3.fromRGB(145, 140, 131),
	service = Color3.fromRGB(136, 133, 124),
	pedestrian = Color3.fromRGB(168, 157, 139),
	footway = Color3.fromRGB(174, 166, 151),
	path = Color3.fromRGB(157, 151, 137),
	cycleway = Color3.fromRGB(108, 143, 157),
	sidewalk = Color3.fromRGB(174, 166, 151),
	steps = Color3.fromRGB(174, 166, 151),
}

-- Every road surface gets a stable, tiny vertical offset. Vehicle roads sit
-- slightly above footways and sidewalks, while surface offsets stop coplanar
-- material layers from flickering where OSM ways overlap.
local ROAD_CLASS_Y_OFFSETS: { [string]: number } = {
	footway = -0.0012,
	sidewalk = -0.001,
	path = -0.0008,
	steps = -0.0006,
	cycleway = -0.0004,
	pedestrian = -0.0002,
	living_street = 0,
	service = 0.0002,
	residential = 0.0004,
	tertiary = 0.0006,
	secondary = 0.0008,
	primary = 0.001,
	trunk = 0.0012,
	motorway = 0.0014,
}

local ROAD_SURFACE_Y_OFFSETS: { [string]: number } = {
	asphalt = -0.0004,
	concrete = -0.0002,
	paving_stones = 0,
	cobblestone = 0.00015,
	unhewn_cobblestone = 0.00025,
	gravel = 0.0004,
	fine_gravel = 0.0005,
	dirt = 0.0006,
	earth = 0.0007,
	ground = 0.0008,
	wood = 0.0009,
}

local BUILDING_COLOURS: { [string]: Color3 } = {
	commercial = Color3.fromRGB(174, 166, 153),
	industrial = Color3.fromRGB(151, 157, 160),
	hospital = Color3.fromRGB(209, 191, 185),
	school = Color3.fromRGB(204, 179, 142),
	church = Color3.fromRGB(185, 170, 150),
	default = Color3.fromRGB(190, 181, 167),
}

local function finiteNumber(value: unknown): number?
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

local function getMapData(data: any): any
	-- Initial responses wrap the actual map in `chunk`; streamed chunk responses
	-- are normally already the map object.
	if type(data) == "table" and type(data.chunk) == "table" and type(data.chunk.roads) == "table" then
		return data.chunk
	end
	return data
end

local function chunkKey(mapData: any): string
	local metadata = if type(mapData) == "table" and type(mapData.chunk) == "table" then mapData.chunk else {}
	local x = finiteNumber(metadata.x) or 0
	local z = finiteNumber(metadata.z) or 0
	return string.format("%d:%d", x, z)
end

local function readRoadPoint(point: any): Vector3?
	if type(point) ~= "table" then
		return nil
	end
	local x = finiteNumber(point[1])
	local y = finiteNumber(point[2]) or 0
	local z = finiteNumber(point[3])
	if x == nil or z == nil then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function readAreaPoint(point: any): MapPoint?
	if type(point) ~= "table" then
		return nil
	end
	local x = finiteNumber(point[1])
	local z = finiteNumber(point[2])
	if x == nil or z == nil then
		return nil
	end
	return Vector2.new(x, z)
end

local function toWorld(point: Vector3, offset: Vector3, scale: number): Vector3
	return offset + point * scale
end

local function getOrCreateRoot(parent: Instance): Folder
	local root = OSMMapRenderer.Root
	if root and root.Parent then
		if root.Parent ~= parent then
			root.Parent = parent
		end
		return root
	end

	local existing = parent:FindFirstChild(ROOT_NAME)
	if existing and existing:IsA("Folder") then
		root = existing
	else
		root = Instance.new("Folder")
		if root then
			root.Name = ROOT_NAME
			root.Parent = parent
		end
	end
	local resolvedRoot = root or error("OSMMapRenderer failed to create a root folder.")
	resolvedRoot:SetAttribute("GeneratedBy", OSMMapRenderer.Name)
	OSMMapRenderer.Root = resolvedRoot
	return resolvedRoot
end

local function makeLayer(chunk: Model, name: string): Folder
	local layer = Instance.new("Folder")
	layer.Name = name
	layer.Parent = chunk
	return layer
end

local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	colour: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cframe
	part.Color = colour
	part.Material = material
	part.Parent = parent
	return part
end

local function makeWedge(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	colour: Color3,
	material: Enum.Material
): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	wedge.Anchored = true
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Size = size
	wedge.CFrame = cframe
	wedge.Color = colour
	wedge.Material = material
	wedge.Parent = parent
	return wedge
end

local function materialForSurface(surface: any): Enum.Material
	if surface == "concrete" then
		return Enum.Material.Concrete
	elseif surface == "paving_stones" or surface == "cobblestone" or surface == "unhewn_cobblestone" then
		return Enum.Material.Cobblestone
	elseif surface == "gravel" or surface == "fine_gravel" then
		return Enum.Material.SmoothPlastic
	elseif surface == "dirt" or surface == "earth" or surface == "ground" then
		return Enum.Material.Ground
	elseif surface == "wood" then
		return Enum.Material.WoodPlanks
	end
	return Enum.Material.Asphalt
end

local function roadLayerOffset(roadClass: any, surface: any): number
	local className = if type(roadClass) == "string" then roadClass else ""
	local surfaceName = if type(surface) == "string" then surface else ""
	local classOffset = ROAD_CLASS_Y_OFFSETS[className] or 0
	local surfaceOffset = ROAD_SURFACE_Y_OFFSETS[surfaceName] or 0
	return classOffset + surfaceOffset
end

local function readAreaPoints(points: any): { MapPoint }
	local result = {} :: { MapPoint }
	if type(points) ~= "table" then
		return result
	end

	for _, rawPoint in ipairs(points) do
		local point = readAreaPoint(rawPoint)
		if point and (#result == 0 or (point - result[#result]).Magnitude > 0.001) then
			table.insert(result, point)
		end
	end
	return result
end

local function normalisePolygon(points: any): { MapPoint }
	local polygon = readAreaPoints(points)

	if #polygon > 2 and (polygon[1] - polygon[#polygon]).Magnitude <= 0.001 then
		table.remove(polygon)
	end

	-- OSM ways frequently retain vertices that lie on the same straight wall.
	-- Removing them avoids degenerate ears without changing the footprint.
	local removedCollinearPoint = true
	while #polygon >= 3 and removedCollinearPoint do
		removedCollinearPoint = false
		for index = #polygon, 1, -1 do
			local previous = polygon[(index - 2) % #polygon + 1]
			local current = polygon[index]
			local nextPoint = polygon[index % #polygon + 1]
			local incoming = current - previous
			local outgoing = nextPoint - current
			if math.abs(incoming.X * outgoing.Y - incoming.Y * outgoing.X) <= TRIANGULATION_EPSILON then
				table.remove(polygon, index)
				removedCollinearPoint = true
			end
		end
	end
	return polygon
end

local function triangleCross(a: MapPoint, b: MapPoint, c: MapPoint): number
	local ab = b - a
	local ac = c - a
	return ab.X * ac.Y - ab.Y * ac.X
end

local function polygonSignedArea(polygon: { MapPoint }): number
	local area = 0
	for index, point in ipairs(polygon) do
		local nextPoint = polygon[index % #polygon + 1]
		area += point.X * nextPoint.Y - nextPoint.X * point.Y
	end
	return area * 0.5
end

local function pointInCounterClockwiseTriangle(point: MapPoint, a: MapPoint, b: MapPoint, c: MapPoint): boolean
	return triangleCross(a, b, point) >= -TRIANGULATION_EPSILON
		and triangleCross(b, c, point) >= -TRIANGULATION_EPSILON
		and triangleCross(c, a, point) >= -TRIANGULATION_EPSILON
end

-- Ear clipping keeps concave building footprints exact. The returned ears are
-- counter-clockwise, which lets the wedge builder consistently face outward.
local function triangulatePolygon(polygon: { MapPoint }): { { MapPoint } }
	local triangles = {} :: { { MapPoint } }
	if #polygon < 3 or math.abs(polygonSignedArea(polygon)) <= TRIANGULATION_EPSILON then
		return triangles
	end

	local remaining = {} :: { number }
	if polygonSignedArea(polygon) > 0 then
		for index = 1, #polygon do
			table.insert(remaining, index)
		end
	else
		for index = #polygon, 1, -1 do
			table.insert(remaining, index)
		end
	end

	while #remaining > 3 do
		local clippedEar = false
		for index, currentIndex in ipairs(remaining) do
			local previousIndex = remaining[(index - 2) % #remaining + 1]
			local nextIndex = remaining[index % #remaining + 1]
			local a = polygon[previousIndex]
			local b = polygon[currentIndex]
			local c = polygon[nextIndex]

			if triangleCross(a, b, c) > TRIANGULATION_EPSILON then
				local containsVertex = false
				for _, candidateIndex in ipairs(remaining) do
					if
						candidateIndex ~= previousIndex
						and candidateIndex ~= currentIndex
						and candidateIndex ~= nextIndex
					then
						if pointInCounterClockwiseTriangle(polygon[candidateIndex], a, b, c) then
							containsVertex = true
							break
						end
					end
				end

				if not containsVertex then
					table.insert(triangles, { a, b, c })
					table.remove(remaining, index)
					clippedEar = true
					break
				end
			end
		end

		-- An invalid or self-intersecting OSM way cannot be triangulated safely.
		-- Leave it to the facade renderer instead of creating fill outside it.
		if not clippedEar then
			return {}
		end
	end

	local a = polygon[remaining[1]]
	local b = polygon[remaining[2]]
	local c = polygon[remaining[3]]
	if triangleCross(a, b, c) > TRIANGULATION_EPSILON then
		table.insert(triangles, { a, b, c })
	end
	return triangles
end

local function createTrianglePrisms(
	parent: Instance,
	name: string,
	triangle: { MapPoint },
	y: number,
	height: number,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material,
	canCollide: boolean
)
	-- This is the supplied two-wedge construction, applied in the horizontal
	-- X/Z plane while local X is the vertical extrusion axis. It creates both
	-- halves of every ear without a minimum-size cutoff.
	local a = toWorld(Vector3.new(triangle[1].X, y + height * 0.5, triangle[1].Y), offset, scale)
	local b = toWorld(Vector3.new(triangle[2].X, y + height * 0.5, triangle[2].Y), offset, scale)
	local c = toWorld(Vector3.new(triangle[3].X, y + height * 0.5, triangle[3].Y), offset, scale)

	local ab = b - a
	local ac = c - a
	local bc = c - b
	local abLengthSquared = ab:Dot(ab)
	local acLengthSquared = ac:Dot(ac)
	local bcLengthSquared = bc:Dot(bc)
	if abLengthSquared > acLengthSquared and abLengthSquared > bcLengthSquared then
		c, a = a, c
	elseif acLengthSquared > bcLengthSquared and acLengthSquared > abLengthSquared then
		a, b = b, a
	end

	ab = b - a
	ac = c - a
	bc = c - b
	if
		ab.Magnitude <= TRIANGULATION_EPSILON
		or ac.Magnitude <= TRIANGULATION_EPSILON
		or bc.Magnitude <= TRIANGULATION_EPSILON
	then
		return
	end

	local extrusionAxis = ac:Cross(ab)
	if extrusionAxis.Magnitude <= TRIANGULATION_EPSILON then
		return
	end

	local localX = extrusionAxis.Unit
	local localY = bc:Cross(localX).Unit
	local localZ = bc.Unit
	local triangleHeight = math.abs(ab:Dot(localY))
	local firstWidth = math.abs(ab:Dot(localZ))
	local secondWidth = math.abs(ac:Dot(localZ))
	local worldHeight = height * scale
	if
		triangleHeight <= TRIANGULATION_EPSILON
		or firstWidth <= TRIANGULATION_EPSILON
		or secondWidth <= TRIANGULATION_EPSILON
	then
		return
	end

	local firstWedge = makeWedge(
		parent,
		name,
		Vector3.new(worldHeight, triangleHeight, firstWidth),
		CFrame.fromMatrix((a + b) * 0.5, localX, localY, localZ),
		colour,
		material
	)
	firstWedge.CanCollide = canCollide
	firstWedge.CanTouch = canCollide
	firstWedge.CanQuery = canCollide

	local secondWedge = makeWedge(
		parent,
		name,
		Vector3.new(worldHeight, triangleHeight, secondWidth),
		CFrame.fromMatrix((a + c) * 0.5, -localX, localY, -localZ),
		colour,
		material
	)
	secondWedge.CanCollide = canCollide
	secondWedge.CanTouch = canCollide
	secondWedge.CanQuery = canCollide
end

-- Rectangular buildings are common enough to justify one solid Part instead
-- of four wedges. Everything else follows the exact ear-clipped path below.
local function createRectanglePrism(
	parent: Instance,
	name: string,
	polygon: { MapPoint },
	y: number,
	height: number,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material,
	canCollide: boolean
): boolean
	if #polygon ~= 4 then
		return false
	end

	local firstEdge = polygon[2] - polygon[1]
	local secondEdge = polygon[3] - polygon[2]
	local thirdEdge = polygon[4] - polygon[3]
	local fourthEdge = polygon[1] - polygon[4]
	local firstLength = firstEdge.Magnitude
	local secondLength = secondEdge.Magnitude
	if firstLength <= TRIANGULATION_EPSILON or secondLength <= TRIANGULATION_EPSILON then
		return false
	end

	local tolerance = 0.001
	if
		math.abs(firstEdge:Dot(secondEdge)) > tolerance * firstLength * secondLength
		or (firstEdge + thirdEdge).Magnitude > tolerance
		or (secondEdge + fourthEdge).Magnitude > tolerance
	then
		return false
	end

	local center = (polygon[1] + polygon[2] + polygon[3] + polygon[4]) * 0.25
	local horizontalAxis = Vector3.new(firstEdge.X, 0, firstEdge.Y).Unit
	local verticalAxis = horizontalAxis:Cross(Vector3.yAxis)
	local part = makePart(
		parent,
		name,
		Vector3.new(firstLength * scale, height * scale, secondLength * scale),
		CFrame.fromMatrix(
			toWorld(Vector3.new(center.X, y + height * 0.5, center.Y), offset, scale),
			horizontalAxis,
			Vector3.yAxis,
			verticalAxis
		),
		colour,
		material
	)
	part.CanCollide = canCollide
	part.CanTouch = canCollide
	part.CanQuery = canCollide
	return true
end

-- Builds an exact extruded polygon from a single Part when rectangular, or
-- ear-clipped WedgeParts for every other convex or concave footprint.
local function createPolygonPrism(
	parent: Instance,
	name: string,
	polygon: { MapPoint },
	y: number,
	height: number,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material,
	canCollide: boolean
)
	if #polygon < 3 then
		return
	end

	if createRectanglePrism(parent, name, polygon, y, height, offset, scale, colour, material, canCollide) then
		return
	end

	for _, triangle in ipairs(triangulatePolygon(polygon)) do
		createTrianglePrisms(parent, name, triangle, y, height, offset, scale, colour, material, canCollide)
	end
end

local function createBuildingFill(
	parent: Instance,
	polygon: { MapPoint },
	height: number,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material
)
	createPolygonPrism(parent, "BuildingFill", polygon, 0, height, offset, scale, colour, material, true)
end

-- Adds a continuous outline around an already-filled polygon footprint.
local function createPolygonPerimeter(
	parent: Instance,
	name: string,
	polygon: { MapPoint },
	y: number,
	height: number,
	thickness: number,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material,
	canCollide: boolean
)
	if #polygon < 2 then
		return
	end

	for index, from in ipairs(polygon) do
		local to = polygon[index % #polygon + 1]
		local mapDelta = to - from
		if mapDelta.Magnitude > 0.001 then
			local mapCenter = Vector3.new((from.X + to.X) * 0.5, y + height * 0.5, (from.Y + to.Y) * 0.5)
			local worldFrom = toWorld(Vector3.new(from.X, y + height * 0.5, from.Y), offset, scale)
			local worldTo = toWorld(Vector3.new(to.X, y + height * 0.5, to.Y), offset, scale)
			local edge = makePart(
				parent,
				name,
				Vector3.new(thickness * scale, height * scale, (worldTo - worldFrom).Magnitude),
				CFrame.lookAt(toWorld(mapCenter, offset, scale), worldTo, Vector3.yAxis),
				colour,
				material
			)
			edge.CanCollide = canCollide
			edge.CanTouch = canCollide
			edge.CanQuery = canCollide
		end
	end
end

-- Some water-layer ways (streams, rivers, drains) are open OSM centerlines,
-- not closed area boundaries. Closing them into a polygon creates a large,
-- incorrect triangle across the map, so they must be rendered as ribbons.
local function isOpenWaterway(points: { MapPoint }): boolean
	if #points < 2 then
		return false
	end

	local pathLength = 0
	for index = 1, #points - 1 do
		pathLength += (points[index + 1] - points[index]).Magnitude
	end
	if pathLength <= TRIANGULATION_EPSILON then
		return false
	end

	local closingDistance = (points[1] - points[#points]).Magnitude
	return closingDistance / pathLength > OPEN_WATERWAY_CLOSURE_RATIO
end

local function renderWaterway(
	parent: Instance,
	points: { MapPoint },
	kind: any,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material
)
	if #points < 2 then
		return
	end

	local kindName = if type(kind) == "string" then kind else ""
	local width = WATERWAY_WIDTHS[kindName] or WATERWAY_WIDTHS.stream
	local worldHeight = WATERWAY_HEIGHT * scale
	local worldWidth = width * scale
	local centerY = WATER_HEIGHT + WATERWAY_SURFACE_OFFSET + WATERWAY_HEIGHT * 0.5
	local previous: Vector3? = nil
	for _, point in ipairs(points) do
		local worldPoint = toWorld(Vector3.new(point.X, centerY, point.Y), offset, scale)
		local joint = makePart(
			parent,
			"WaterwayJoint",
			Vector3.new(worldHeight, worldWidth, worldWidth),
			CFrame.new(worldPoint) * CFrame.Angles(0, 0, math.pi * 0.5),
			colour,
			material
		)
		joint.Shape = Enum.PartType.Cylinder
		joint.CanCollide = false
		joint.CanTouch = false
		joint.CanQuery = false

		if previous then
			local delta = worldPoint - previous
			local length = delta.Magnitude
			if length > 0.001 then
				local segment = makePart(
					parent,
					"Waterway",
					Vector3.new(worldWidth, worldHeight, length),
					CFrame.lookAt((previous + worldPoint) * 0.5, worldPoint, Vector3.yAxis),
					colour,
					material
				)
				segment.CanCollide = false
				segment.CanTouch = false
				segment.CanQuery = false
			end
		end
		previous = worldPoint
	end
end

local function renderAreas(
	parent: Instance,
	features: any,
	name: string,
	y: number,
	height: number,
	colour: Color3,
	material: Enum.Material,
	canCollide: boolean,
	offset: Vector3,
	scale: number,
	renderOpenWaterways: boolean
)
	if type(features) ~= "table" then
		return
	end

	for _, feature in ipairs(features) do
		if type(feature) == "table" and type(feature.polygons) == "table" then
			for _, rawPolygon in ipairs(feature.polygons) do
				local points = readAreaPoints(rawPolygon)
				if renderOpenWaterways and isOpenWaterway(points) then
					renderWaterway(parent, points, feature.kind, offset, scale, colour, material)
				else
					local polygon = normalisePolygon(rawPolygon)
					createPolygonPrism(
						parent,
						name .. "Fill",
						polygon,
						y,
						height,
						offset,
						scale,
						colour,
						material,
						canCollide
					)
					-- This outline makes the exact filled footprint easier to read at
					-- distance and gives lakes, parks, and plazas a crisp OSM shape.
					createPolygonPerimeter(
						parent,
						name .. "Edge",
						polygon,
						y + height,
						0.025,
						AREA_EDGE_THICKNESS,
						offset,
						scale,
						colour:Lerp(Color3.new(0, 0, 0), 0.16),
						material,
						false
					)
				end
			end
		end
	end
end

local function createRoadJoint(
	parent: Instance,
	position: Vector3,
	width: number,
	height: number,
	colour: Color3,
	material: Enum.Material
)
	-- Cylinder primitives have a vertical axis after this rotation. They round
	-- every OSM polyline corner and remove the square caps between segments.
	local joint = makePart(
		parent,
		"RoadJoint",
		Vector3.new(height, width, width),
		CFrame.new(position) * CFrame.Angles(0, 0, math.pi * 0.5),
		colour,
		material
	)
	joint.Shape = Enum.PartType.Cylinder
	joint.CanCollide = true
	return joint
end

local function renderRoads(parent: Instance, roads: any, offset: Vector3, scale: number)
	if type(roads) ~= "table" then
		return
	end

	for _, road in ipairs(roads) do
		if type(road) ~= "table" or type(road.points) ~= "table" then
			continue
		end

		local width = math.max(finiteNumber(road.width) or 3, 0.75) * scale
		local colour = ROAD_COLOURS[road.class] or ROAD_COLOURS.residential
		local material = materialForSurface(road.surface)
		local layerOffset = roadLayerOffset(road.class, road.surface)
		local previous: Vector3? = nil
		for _, rawPoint in ipairs(road.points) do
			local point = readRoadPoint(rawPoint)
			if point then
				local worldPoint = toWorld(point, offset, scale)
					+ Vector3.new(0, (ROAD_HEIGHT * 0.5 + layerOffset) * scale, 0)
				createRoadJoint(parent, worldPoint, width, ROAD_HEIGHT * scale, colour, material)
				if previous then
					local delta = worldPoint - previous
					local length = delta.Magnitude
					if length > 0.01 then
						local roadPart = makePart(
							parent,
							"Road",
							Vector3.new(width, ROAD_HEIGHT * scale, length),
							CFrame.lookAt((previous + worldPoint) * 0.5, worldPoint, Vector3.yAxis),
							colour,
							material
						)
						roadPart.CanCollide = true
					end
				end
				previous = worldPoint
			end
		end
	end
end

local function getBuildingHeight(building: any): number
	local explicitHeight = finiteNumber(building.height)
	if explicitHeight and explicitHeight > 0 then
		return math.max(explicitHeight, BUILDING_MIN_HEIGHT)
	end
	local levels = finiteNumber(building.levels)
	if levels and levels > 0 then
		return math.max(levels * BUILDING_DEFAULT_FLOOR_HEIGHT, BUILDING_MIN_HEIGHT)
	end
	return BUILDING_MIN_HEIGHT
end

local function renderBuildings(parent: Instance, buildings: any, offset: Vector3, scale: number)
	if type(buildings) ~= "table" then
		return
	end

	for _, building in ipairs(buildings) do
		if type(building) == "table" then
			local height = getBuildingHeight(building)
			local colour = BUILDING_COLOURS[building.kind] or BUILDING_COLOURS.default
			local footprint = normalisePolygon(building.footprint)
			createBuildingFill(parent, footprint, height, offset, scale, colour, Enum.Material.SmoothPlastic)
			createPolygonPerimeter(
				parent,
				"BuildingFacade",
				footprint,
				0,
				height,
				BUILDING_EDGE_THICKNESS,
				offset,
				scale,
				colour:Lerp(Color3.new(0, 0, 0), 0.12),
				Enum.Material.SmoothPlastic,
				true
			)
		end
	end
end

local function renderPois(parent: Instance, pois: any, offset: Vector3, scale: number)
	if type(pois) ~= "table" then
		return
	end

	for _, poi in ipairs(pois) do
		if type(poi) ~= "table" then
			continue
		end
		local position = readRoadPoint(poi.position)
		if position then
			local marker = makePart(
				parent,
				"Poi",
				Vector3.new(1.5, 1.5, 1.5),
				CFrame.new(toWorld(position, offset, scale) + Vector3.new(0, 1.25, 0)),
				Color3.fromRGB(202, 78, 72),
				Enum.Material.Neon
			)
			marker.Shape = Enum.PartType.Ball
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false

			if type(poi.name) == "string" and poi.name ~= "" then
				local label = Instance.new("BillboardGui")
				label.Name = "Label"
				label.AlwaysOnTop = false
				label.MaxDistance = 150
				label.Size = UDim2.fromOffset(180, 28)
				label.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
				label.Parent = marker

				local text = Instance.new("TextLabel")
				text.BackgroundTransparency = 1
				text.Size = UDim2.fromScale(1, 1)
				text.Font = Enum.Font.GothamBold
				text.Text = poi.name
				text.TextColor3 = Color3.new(1, 1, 1)
				text.TextSize = 13
				text.TextStrokeTransparency = 0.35
				text.TextTruncate = Enum.TextTruncate.AtEnd
				text.Parent = label
			end
		end
	end
end

local function renderDebugReferences(parent: Instance, mapData: any, offset: Vector3, scale: number)
	local metadata = if type(mapData.chunk) == "table" then mapData.chunk else nil
	if not metadata then
		return
	end

	local minX = finiteNumber(metadata.minX)
	local minZ = finiteNumber(metadata.minZ)
	local maxX = finiteNumber(metadata.maxX)
	local maxZ = finiteNumber(metadata.maxZ)
	if not minX or not minZ or not maxX or not maxZ then
		return
	end

	local corners = {
		Vector3.new(minX, 0, minZ),
		Vector3.new(minX, 0, maxZ),
		Vector3.new(maxX, 0, maxZ),
		Vector3.new(maxX, 0, minZ),
	}
	for index, from in ipairs(corners) do
		local to = corners[index % #corners + 1]
		local worldFrom = toWorld(from, offset, scale) + Vector3.new(0, 0.35, 0)
		local worldTo = toWorld(to, offset, scale) + Vector3.new(0, 0.35, 0)
		local length = (worldTo - worldFrom).Magnitude
		if length > 0 then
			local edge = makePart(
				parent,
				"ChunkBoundary",
				Vector3.new(0.35, 0.35, length),
				CFrame.lookAt((worldFrom + worldTo) * 0.5, worldTo),
				Color3.fromRGB(247, 194, 64),
				Enum.Material.Neon
			)
			edge.CanCollide = false
		end
	end

	local origin = mapData.origin
	if type(origin) == "table" then
		-- The chunk origin is local (0, 0) even though its lat/lon lives in
		-- metadata. Showing it confirms that streamed chunks share an origin.
		local spawn = makePart(
			parent,
			"SpawnOrigin",
			Vector3.new(2, 2, 2),
			CFrame.new(offset + Vector3.new(0, 1.1, 0)),
			Color3.fromRGB(77, 181, 111),
			Enum.Material.Neon
		)
		spawn.Shape = Enum.PartType.Ball
		spawn.CanCollide = false
		spawn.CanTouch = false
	end
end

local function clearLegacyWaterDebugPoints()
	for _, child in ipairs(Workspace:GetChildren()) do
		if
			child:IsA("BasePart")
			and child.Name:match("^WaterPoint_%d+$")
			and child:GetAttribute("WaterPointIndex") ~= nil
		then
			child:Destroy()
		end
	end
end

function OSMMapRenderer:Init()
	clearLegacyWaterDebugPoints()
	getOrCreateRoot(Workspace)
end

function OSMMapRenderer:AddChunk(data: any, options: RenderOptions?): Model?
	local mapData = getMapData(data)
	if type(mapData) ~= "table" then
		warn("OSMMapRenderer:AddChunk expected a decoded OSM chunk table.")
		return nil
	end
	clearLegacyWaterDebugPoints()

	local renderOptions = (options or {}) :: RenderOptions
	local parent = renderOptions.Parent or Workspace
	local offset = renderOptions.WorldOffset or self.WorldOffset
	local scale = renderOptions.StudsPerMapUnit or self.StudsPerMapUnit
	if scale <= 0 then
		warn("OSMMapRenderer:AddChunk requires StudsPerMapUnit to be greater than zero.")
		return nil
	end

	local root = getOrCreateRoot(parent)
	local key = chunkKey(mapData)
	local existing = self.ChunkModels[key]
	if existing then
		existing:Destroy()
	end

	local chunk = Instance.new("Model")
	chunk.Name = "Chunk_" .. key
	chunk:SetAttribute("ChunkKey", key)
	chunk:SetAttribute("StudsPerMapUnit", scale)
	chunk.Parent = root
	self.ChunkModels[key] = chunk

	local water = makeLayer(chunk, "Water")
	local landuse = makeLayer(chunk, "Landuse")
	local buildings = makeLayer(chunk, "Buildings")
	local roads = makeLayer(chunk, "Roads")
	local pois = makeLayer(chunk, "Pois")

	renderAreas(
		water,
		mapData.water,
		"Water",
		0,
		WATER_HEIGHT,
		Color3.fromRGB(73, 157, 207),
		-- Transparent Glass exposes sorting seams between the ear-clipped wedge
		-- parts. SmoothPlastic keeps the exact tessellation visually solid.
		Enum.Material.SmoothPlastic,
		false,
		offset,
		scale,
		true
	)
	renderAreas(
		landuse,
		mapData.landuse,
		"Landuse",
		WATER_HEIGHT,
		LANDUSE_HEIGHT,
		Color3.fromRGB(105, 153, 86),
		Enum.Material.Grass,
		false,
		offset,
		scale,
		false
	)
	renderBuildings(buildings, mapData.buildings, offset, scale)
	renderRoads(roads, mapData.roads, offset, scale)
	renderPois(pois, mapData.pois, offset, scale)

	if renderOptions.DebugReferences == true or (renderOptions.DebugReferences == nil and self.DebugReferences) then
		local debug = makeLayer(chunk, "Debug")
		renderDebugReferences(debug, mapData, offset, scale)
	end

	return chunk
end

function OSMMapRenderer:Render(data: any, options: RenderOptions?): Model?
	self:Clear()
	return self:AddChunk(data, options)
end

function OSMMapRenderer:RemoveChunk(chunkX: number, chunkZ: number)
	local key = string.format("%d:%d", chunkX, chunkZ)
	local chunk = self.ChunkModels[key]
	if chunk then
		chunk:Destroy()
		self.ChunkModels[key] = nil
	end
end

function OSMMapRenderer:Clear()
	for key, chunk in pairs(self.ChunkModels) do
		if chunk.Parent then
			chunk:Destroy()
		end
		self.ChunkModels[key] = nil
	end
end

function OSMMapRenderer:Destroy()
	self:Clear()
	local root = self.Root
	if root then
		root:Destroy()
	end
end

function OSMMapRenderer:Start()
	-- Keep the bundled decoded response as an immediately visible integration
	-- check. Game code can replace it with the user's initial response via
	-- OSMMapRenderer:Render(response) and stream adjacent chunks with AddChunk.
	self:Render(OsmApiReturnedData, {
		DebugReferences = true,
	})
end

return OSMMapRenderer

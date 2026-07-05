--!strict

--[[
	Client-owned OSM world renderer. Instances created here exist only for the
	local player, which allows every player in a server to view a different map.
	It deliberately keeps collision disabled: client-created parts are visual
	only and cannot provide authoritative multiplayer physics.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local OSMWorldRenderer = {}
OSMWorldRenderer.__index = OSMWorldRenderer
OSMWorldRenderer.Name = "OSMWorldRenderer"

export type LayerOptions = {
	Roads: boolean?,
	Buildings: boolean?,
	Water: boolean?,
	Landuse: boolean?,
	Trees: boolean?,
	Pois: boolean?,
	Boundaries: boolean?,
}

export type RenderOptions = {
	WorldOffset: Vector3?,
	StudsPerMapUnit: number?,
	Layers: LayerOptions?,
}

export type Renderer = {
	Root: Folder?,
	WorldOffset: Vector3,
	StudsPerMapUnit: number,
	OriginLatitude: number?,
	OriginLongitude: number?,
	Data: any,
	Chunks: { [string]: any },
	PendingChunkBounds: { [string]: { X: number, Z: number, MinX: number, MinZ: number, MaxX: number, MaxZ: number } },
	LayerVisibility: LayerOptions,
	LayerFadeTokens: { [string]: number },
	Render: (self: Renderer, data: any, options: RenderOptions?) -> (),
	AddChunk: (self: Renderer, data: any) -> boolean,
	EnsureChunkBase: (self: Renderer, chunkX: number, chunkZ: number, minX: number, minZ: number, maxX: number, maxZ: number) -> (),
	RemoveChunk: (self: Renderer, chunkX: number, chunkZ: number) -> (),
	SetLayerVisibility: (self: Renderer, layerVisibility: LayerOptions) -> (),
	WorldPositionToMap: (self: Renderer, worldPosition: Vector3) -> Vector3,
	WorldPositionToLatLon: (self: Renderer, worldPosition: Vector3) -> (number?, number?),
	Clear: (self: Renderer) -> (),
	Destroy: (self: Renderer) -> (),
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
local RAILWAY_COLOUR = Color3.fromRGB(78, 61, 52)
local RAILWAY_CLASSES = {
	rail = true,
	railway = true,
	light_rail = true,
	tram = true,
	subway = true,
	narrow_gauge = true,
}

local BUILDING_COLOURS: { [string]: Color3 } = {
	commercial = Color3.fromRGB(174, 166, 153),
	industrial = Color3.fromRGB(151, 157, 160),
	hospital = Color3.fromRGB(209, 191, 185),
	school = Color3.fromRGB(204, 179, 142),
	church = Color3.fromRGB(185, 170, 150),
	default = Color3.fromRGB(190, 181, 167),
}

local LANDUSE_DEFAULT_COLOUR = Color3.fromRGB(124, 151, 102)
local LANDUSE_DEFAULT_MATERIAL = Enum.Material.Grass
local LANDUSE_STYLES: { [string]: { Colour: Color3, Material: Enum.Material } } = {
	forest = { Colour = Color3.fromRGB(61, 109, 66), Material = Enum.Material.Grass },
	wood = { Colour = Color3.fromRGB(61, 109, 66), Material = Enum.Material.Grass },
	grass = { Colour = Color3.fromRGB(108, 161, 89), Material = Enum.Material.Grass },
	meadow = { Colour = Color3.fromRGB(122, 172, 93), Material = Enum.Material.Grass },
	park = { Colour = Color3.fromRGB(105, 153, 86), Material = Enum.Material.Grass },
	recreation_ground = { Colour = Color3.fromRGB(99, 157, 82), Material = Enum.Material.Grass },
	village_green = { Colour = Color3.fromRGB(104, 160, 88), Material = Enum.Material.Grass },
	garden = { Colour = Color3.fromRGB(116, 166, 91), Material = Enum.Material.Grass },
	cemetery = { Colour = Color3.fromRGB(100, 142, 93), Material = Enum.Material.Grass },
	orchard = { Colour = Color3.fromRGB(119, 151, 72), Material = Enum.Material.Grass },
	farmland = { Colour = Color3.fromRGB(164, 151, 100), Material = Enum.Material.Ground },
	farmyard = { Colour = Color3.fromRGB(151, 136, 98), Material = Enum.Material.Ground },
	allotments = { Colour = Color3.fromRGB(142, 157, 92), Material = Enum.Material.Grass },
	scrub = { Colour = Color3.fromRGB(117, 137, 79), Material = Enum.Material.Grass },
	heath = { Colour = Color3.fromRGB(132, 121, 88), Material = Enum.Material.Grass },
	wetland = { Colour = Color3.fromRGB(88, 130, 106), Material = Enum.Material.Grass },
}

local TRIANGULATION_EPSILON = 0.00001
local BUILDING_MIN_HEIGHT = 6
local BUILDING_DEFAULT_FLOOR_HEIGHT = 3
local ROAD_HEIGHT = 0.16
local WATER_HEIGHT = 0.08
local WATERWAY_HEIGHT = 0.035
local WATERWAY_SURFACE_OFFSET = 0.002
local LANDUSE_HEIGHT = 0.06
local TREE_GROUND_Y = WATER_HEIGHT + LANDUSE_HEIGHT + 0.01
local OPEN_WATERWAY_CLOSURE_RATIO = 0.15
local treeTemplateWarningIssued = false
local LOADED_BASE_COLOUR = Color3.fromRGB(88, 116, 77)
local LOADING_BASE_COLOUR = Color3.fromRGB(145, 119, 61)

local WATERWAY_WIDTHS = { stream = 2, ditch = 1.25, drain = 1.25, canal = 5, river = 8 }
local ROAD_CLASS_Y_OFFSETS = { footway = -0.0012, sidewalk = -0.001, path = -0.0008, steps = -0.0006, cycleway = -0.0004, pedestrian = -0.0002, living_street = 0, service = 0.0002, residential = 0.0004, tertiary = 0.0006, secondary = 0.0008, primary = 0.001, trunk = 0.0012, motorway = 0.0014 }
local ROAD_SURFACE_Y_OFFSETS = { asphalt = -0.0004, concrete = -0.0002, paving_stones = 0, cobblestone = 0.00015, unhewn_cobblestone = 0.00025, gravel = 0.0004, fine_gravel = 0.0005, dirt = 0.0006, earth = 0.0007, ground = 0.0008, wood = 0.0009 }

local function finiteNumber(value: unknown): number?
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

local function getMapData(data: any): any
	if type(data) ~= "table" then
		return nil
	end
	if type(data.roads) == "table" then
		return data
	end
	if type(data.chunk) == "table" and type(data.chunk.roads) == "table" then
		return data.chunk
	end
	return nil
end

local function getOrCreateRoot(self: Renderer): Folder
	local root = self.Root
	if root and root.Parent then
		return root
	end

	root = Instance.new("Folder")
	root.Name = "LocalOSMMap"
	root:SetAttribute("GeneratedBy", OSMWorldRenderer.Name)
	root.Parent = Workspace
	self.Root = root
	return root
end

local function makeLayer(parent: Instance, name: string): Folder
	local layer = Instance.new("Folder")
	layer.Name = name
	layer.Parent = parent
	return layer
end

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, colour: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cframe
	part.Color = colour
	part.Material = material
	part.Parent = parent
	return part
end

local function makeWedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, colour: Color3, material: Enum.Material): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanTouch = false
	wedge.CanQuery = false
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Size = size
	wedge.CFrame = cframe
	wedge.Color = colour
	wedge.Material = material
	wedge.Parent = parent
	return wedge
end

local function toWorld(self: Renderer, x: number, y: number, z: number): Vector3
	-- Roblox's conventional north is -Z, while the OSM payload uses positive Z
	-- for north. Mirror Z so the physical map and cardinal movement agree.
	return self.WorldOffset + Vector3.new(x, y, -z) * self.StudsPerMapUnit
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

local function readTreePoint(point: any): Vector3?
	if type(point) ~= "table" then return nil end
	local x = finiteNumber(point[1])
	local y = finiteNumber(point[2]) or 0
	local z = finiteNumber(point[3])
	if z == nil then
		z = finiteNumber(point[2])
		y = 0
	end
	if x == nil or z == nil then return nil end
	return Vector3.new(x, y, z)
end

local function readAreaPoint(point: any): Vector2?
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

local function materialForSurface(surface: any): Enum.Material
	if surface == "concrete" then return Enum.Material.Concrete end
	if surface == "paving_stones" or surface == "cobblestone" or surface == "unhewn_cobblestone" then return Enum.Material.Cobblestone end
	if surface == "gravel" or surface == "fine_gravel" then return Enum.Material.SmoothPlastic end
	if surface == "dirt" or surface == "earth" or surface == "ground" then return Enum.Material.Ground end
	if surface == "wood" then return Enum.Material.WoodPlanks end
	return Enum.Material.Asphalt
end

local function roadLayerOffset(roadClass: any, surface: any): number
	local classOffset = ROAD_CLASS_Y_OFFSETS[if type(roadClass) == "string" then roadClass else ""] or 0
	local surfaceOffset = ROAD_SURFACE_Y_OFFSETS[if type(surface) == "string" then surface else ""] or 0
	return classOffset + surfaceOffset
end

local function isRailway(road: any): boolean
	if type(road) ~= "table" then
		return false
	end
	return RAILWAY_CLASSES[if type(road.class) == "string" then road.class else ""] == true
		or RAILWAY_CLASSES[if type(road.kind) == "string" then road.kind else ""] == true
		or type(road.railway) == "string"
end

local function renderRoads(self: Renderer, parent: Instance, roads: any)
	if type(roads) ~= "table" then
		return
	end

	for _, road in ipairs(roads) do
		if type(road) ~= "table" or type(road.points) ~= "table" then
			continue
		end

		local width = math.max(finiteNumber(road.width) or 3, 0.75) * self.StudsPerMapUnit
		local railway = isRailway(road)
		local colour = if railway then RAILWAY_COLOUR else ROAD_COLOURS[road.class] or ROAD_COLOURS.residential
		local material = if railway then Enum.Material.Metal else materialForSurface(road.surface)
		local layerOffset = roadLayerOffset(road.class, road.surface) + (if railway then 0.0016 else 0)
		local previous: Vector3? = nil
		for _, rawPoint in ipairs(road.points) do
			local point = readRoadPoint(rawPoint)
			if point then
				local worldPoint = toWorld(self, point.X, point.Y + ROAD_HEIGHT * 0.5 + layerOffset, point.Z)
				local joint = makePart(parent, "RoadJoint", Vector3.new(ROAD_HEIGHT * self.StudsPerMapUnit, width, width), CFrame.new(worldPoint) * CFrame.Angles(0, 0, math.pi * 0.5), colour, material)
				joint.Shape = Enum.PartType.Cylinder
				if previous then
					local length = (worldPoint - previous).Magnitude
					if length > 0.01 then
						makePart(parent, "Road", Vector3.new(width, ROAD_HEIGHT * self.StudsPerMapUnit, length), CFrame.lookAt((previous + worldPoint) * 0.5, worldPoint, Vector3.yAxis), colour, material)
					end
				end
				previous = worldPoint
			end
		end
	end
end

local function normalisePolygon(points: any): { Vector2 }
	local polygon = {} :: { Vector2 }
	if type(points) ~= "table" then
		return polygon
	end
	for _, rawPoint in ipairs(points) do
		local point = readAreaPoint(rawPoint)
		if point and (#polygon == 0 or (point - polygon[#polygon]).Magnitude > 0.001) then
			table.insert(polygon, point)
		end
	end
	if #polygon > 2 and (polygon[1] - polygon[#polygon]).Magnitude <= 0.001 then
		table.remove(polygon)
	end

	local removedCollinear = true
	while #polygon >= 3 and removedCollinear do
		removedCollinear = false
		for index = #polygon, 1, -1 do
			local previous = polygon[(index - 2) % #polygon + 1]
			local current = polygon[index]
			local nextPoint = polygon[index % #polygon + 1]
			local incoming = current - previous
			local outgoing = nextPoint - current
			if math.abs(incoming.X * outgoing.Y - incoming.Y * outgoing.X) <= TRIANGULATION_EPSILON then
				table.remove(polygon, index)
				removedCollinear = true
			end
		end
	end
	return polygon
end

local function triangleCross(a: Vector2, b: Vector2, c: Vector2): number
	local ab = b - a
	local ac = c - a
	return ab.X * ac.Y - ab.Y * ac.X
end

local function polygonSignedArea(polygon: { Vector2 }): number
	local area = 0
	for index, point in ipairs(polygon) do
		local nextPoint = polygon[index % #polygon + 1]
		area += point.X * nextPoint.Y - nextPoint.X * point.Y
	end
	return area * 0.5
end

local function pointInTriangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2): boolean
	return triangleCross(a, b, point) >= -TRIANGULATION_EPSILON
		and triangleCross(b, c, point) >= -TRIANGULATION_EPSILON
		and triangleCross(c, a, point) >= -TRIANGULATION_EPSILON
end

local function triangulatePolygon(polygon: { Vector2 }): { { Vector2 } }
	local triangles = {} :: { { Vector2 } }
	if #polygon < 3 or math.abs(polygonSignedArea(polygon)) <= TRIANGULATION_EPSILON then
		return triangles
	end

	local remaining = {} :: { number }
	if polygonSignedArea(polygon) > 0 then
		for index = 1, #polygon do table.insert(remaining, index) end
	else
		for index = #polygon, 1, -1 do table.insert(remaining, index) end
	end

	while #remaining > 3 do
		local clippedEar = false
		for index, currentIndex in ipairs(remaining) do
			local previousIndex = remaining[(index - 2) % #remaining + 1]
			local nextIndex = remaining[index % #remaining + 1]
			local a, b, c = polygon[previousIndex], polygon[currentIndex], polygon[nextIndex]
			if triangleCross(a, b, c) > TRIANGULATION_EPSILON then
				local containsVertex = false
				for _, candidateIndex in ipairs(remaining) do
					if candidateIndex ~= previousIndex and candidateIndex ~= currentIndex and candidateIndex ~= nextIndex and pointInTriangle(polygon[candidateIndex], a, b, c) then
						containsVertex = true
						break
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
		if not clippedEar then return {} end
	end

	local a, b, c = polygon[remaining[1]], polygon[remaining[2]], polygon[remaining[3]]
	if triangleCross(a, b, c) > TRIANGULATION_EPSILON then
		table.insert(triangles, { a, b, c })
	end
	return triangles
end

local function createTrianglePrisms(self: Renderer, parent: Instance, name: string, triangle: { Vector2 }, y: number, height: number, colour: Color3, material: Enum.Material)
	local a = toWorld(self, triangle[1].X, y + height * 0.5, triangle[1].Y)
	local b = toWorld(self, triangle[2].X, y + height * 0.5, triangle[2].Y)
	local c = toWorld(self, triangle[3].X, y + height * 0.5, triangle[3].Y)
	local ab, ac, bc = b - a, c - a, c - b
	local abLengthSquared, acLengthSquared, bcLengthSquared = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abLengthSquared > acLengthSquared and abLengthSquared > bcLengthSquared then
		c, a = a, c
	elseif acLengthSquared > bcLengthSquared and acLengthSquared > abLengthSquared then
		a, b = b, a
	end

	ab, ac, bc = b - a, c - a, c - b
	if ab.Magnitude <= TRIANGULATION_EPSILON or ac.Magnitude <= TRIANGULATION_EPSILON or bc.Magnitude <= TRIANGULATION_EPSILON then return end
	local extrusionAxis = ac:Cross(ab)
	if extrusionAxis.Magnitude <= TRIANGULATION_EPSILON then return end
	local localX = extrusionAxis.Unit
	local localY = bc:Cross(localX).Unit
	local localZ = bc.Unit
	local triangleHeight = math.abs(ab:Dot(localY))
	local firstWidth = math.abs(ab:Dot(localZ))
	local secondWidth = math.abs(ac:Dot(localZ))
	local worldHeight = height * self.StudsPerMapUnit
	if triangleHeight <= TRIANGULATION_EPSILON or firstWidth <= TRIANGULATION_EPSILON or secondWidth <= TRIANGULATION_EPSILON then return end

	makeWedge(parent, name, Vector3.new(worldHeight, triangleHeight, firstWidth), CFrame.fromMatrix((a + b) * 0.5, localX, localY, localZ), colour, material)
	makeWedge(parent, name, Vector3.new(worldHeight, triangleHeight, secondWidth), CFrame.fromMatrix((a + c) * 0.5, -localX, localY, -localZ), colour, material)
end

local function createRectanglePrism(self: Renderer, parent: Instance, name: string, polygon: { Vector2 }, y: number, height: number, colour: Color3, material: Enum.Material): boolean
	if #polygon ~= 4 then return false end
	local firstEdge = polygon[2] - polygon[1]
	local secondEdge = polygon[3] - polygon[2]
	local thirdEdge = polygon[4] - polygon[3]
	local fourthEdge = polygon[1] - polygon[4]
	local firstLength, secondLength = firstEdge.Magnitude, secondEdge.Magnitude
	if firstLength <= TRIANGULATION_EPSILON or secondLength <= TRIANGULATION_EPSILON then return false end
	local tolerance = 0.001
	if math.abs(firstEdge:Dot(secondEdge)) > tolerance * firstLength * secondLength or (firstEdge + thirdEdge).Magnitude > tolerance or (secondEdge + fourthEdge).Magnitude > tolerance then
		return false
	end
	local center = (polygon[1] + polygon[2] + polygon[3] + polygon[4]) * 0.25
	local horizontalAxis = Vector3.new(firstEdge.X, 0, -firstEdge.Y).Unit
	local verticalAxis = horizontalAxis:Cross(Vector3.yAxis)
	makePart(parent, name, Vector3.new(firstLength * self.StudsPerMapUnit, height * self.StudsPerMapUnit, secondLength * self.StudsPerMapUnit), CFrame.fromMatrix(toWorld(self, center.X, y + height * 0.5, center.Y), horizontalAxis, Vector3.yAxis, verticalAxis), colour, material)
	return true
end

local function createPolygonPrism(self: Renderer, parent: Instance, name: string, polygon: { Vector2 }, y: number, height: number, colour: Color3, material: Enum.Material)
	if #polygon < 3 then return end
	if createRectanglePrism(self, parent, name, polygon, y, height, colour, material) then return end
	for _, triangle in ipairs(triangulatePolygon(polygon)) do
		createTrianglePrisms(self, parent, name, triangle, y, height, colour, material)
	end
end

local function renderBuildings(self: Renderer, parent: Instance, buildings: any)
	if type(buildings) ~= "table" then return end
	for _, building in ipairs(buildings) do
		if type(building) ~= "table" then continue end
		local height = math.max(finiteNumber(building.height) or (finiteNumber(building.levels) or 2) * BUILDING_DEFAULT_FLOOR_HEIGHT, BUILDING_MIN_HEIGHT)
		local footprint = normalisePolygon(building.footprint)
		local colour = BUILDING_COLOURS[building.kind] or BUILDING_COLOURS.default
		createPolygonPrism(self, parent, "BuildingFill", footprint, 0, height, colour, Enum.Material.SmoothPlastic)
	end
end

local function isOpenWaterway(points: { Vector2 }): boolean
	if #points < 2 then return false end
	local pathLength = 0
	for index = 1, #points - 1 do pathLength += (points[index + 1] - points[index]).Magnitude end
	if pathLength <= TRIANGULATION_EPSILON then return false end
	return (points[1] - points[#points]).Magnitude / pathLength > OPEN_WATERWAY_CLOSURE_RATIO
end

local function renderWaterway(self: Renderer, parent: Instance, points: { Vector2 }, kind: any, colour: Color3, material: Enum.Material)
	if #points < 2 then return end
	local width = WATERWAY_WIDTHS[if type(kind) == "string" then kind else ""] or WATERWAY_WIDTHS.stream
	local worldHeight = WATERWAY_HEIGHT * self.StudsPerMapUnit
	local worldWidth = width * self.StudsPerMapUnit
	local centerY = WATER_HEIGHT + WATERWAY_SURFACE_OFFSET + WATERWAY_HEIGHT * 0.5
	local previous: Vector3? = nil
	for _, point in ipairs(points) do
		local worldPoint = toWorld(self, point.X, centerY, point.Y)
		local joint = makePart(parent, "WaterwayJoint", Vector3.new(worldHeight, worldWidth, worldWidth), CFrame.new(worldPoint) * CFrame.Angles(0, 0, math.pi * 0.5), colour, material)
		joint.Shape = Enum.PartType.Cylinder
		if previous then
			local length = (worldPoint - previous).Magnitude
			if length > 0.001 then
				makePart(parent, "Waterway", Vector3.new(worldWidth, worldHeight, length), CFrame.lookAt((previous + worldPoint) * 0.5, worldPoint, Vector3.yAxis), colour, material)
			end
		end
		previous = worldPoint
	end
end

local function landuseStyle(feature: any): (Color3, Enum.Material)
	local kind = if type(feature) == "table" and type(feature.kind) == "string" then string.lower(feature.kind) else ""
	local style = LANDUSE_STYLES[kind]
	if style then return style.Colour, style.Material end
	return LANDUSE_DEFAULT_COLOUR, LANDUSE_DEFAULT_MATERIAL
end

local function renderAreas(self: Renderer, parent: Instance, features: any, name: string, y: number, height: number, colour: Color3, material: Enum.Material, renderOpenWaterways: boolean, styleForFeature: ((any) -> (Color3, Enum.Material))?)
	if type(features) ~= "table" then return end
	for _, feature in ipairs(features) do
		if type(feature) ~= "table" or type(feature.polygons) ~= "table" then continue end
		local featureColour, featureMaterial = colour, material
		if styleForFeature then featureColour, featureMaterial = styleForFeature(feature) end
		for _, rawPolygon in ipairs(feature.polygons) do
			local points = {} :: { Vector2 }
			if type(rawPolygon) == "table" then
				for _, rawPoint in ipairs(rawPolygon) do
					local point = readAreaPoint(rawPoint)
					if point then table.insert(points, point) end
				end
			end
			if renderOpenWaterways and isOpenWaterway(points) then
				renderWaterway(self, parent, points, feature.kind, featureColour, featureMaterial)
			else
				createPolygonPrism(self, parent, name .. "Fill", normalisePolygon(rawPolygon), y, height, featureColour, featureMaterial)
			end
		end
	end
end

local function getTreeTemplate(): Model?
	local exampleModels = ReplicatedStorage:FindFirstChild("ExampleModels")
	local treeTemplate = if exampleModels then exampleModels:FindFirstChild("Tree") else nil
	if treeTemplate and treeTemplate:IsA("Model") then return treeTemplate end
	if not treeTemplateWarningIssued then
		treeTemplateWarningIssued = true
		warn("OSMWorldRenderer could not find ReplicatedStorage.ExampleModels.Tree; skipping tree rendering.")
	end
	return nil
end

local function placeTree(self: Renderer, parent: Instance, template: Model, position: Vector3, tree: any)
	local clone = template:Clone()
	clone.Name = "Tree"
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
	local worldPosition = toWorld(self, position.X, position.Y, position.Z) + Vector3.new(0, TREE_GROUND_Y * self.StudsPerMapUnit + ((clone.PrimaryPart and clone.PrimaryPart.Size.Y or 0) / 2), 0)
	clone:PivotTo(CFrame.new(worldPosition))
	if type(tree) == "table" and type(tree.id) == "string" then clone:SetAttribute("OsmId", tree.id) end
	clone.Parent = parent
end

local function renderTrees(self: Renderer, parent: Instance, trees: any)
	if type(trees) ~= "table" or next(trees) == nil then return end
	local template = getTreeTemplate()
	if not template then return end
	for _, tree in ipairs(trees) do
		if type(tree) ~= "table" then continue end
		local position = readTreePoint(tree.position)
		if position then placeTree(self, parent, template, position, tree) end
		local rowPoints = tree.points or tree.positions or tree.path
		if type(rowPoints) == "table" then
			for _, rawPoint in ipairs(rowPoints) do
				local rowPosition = readTreePoint(rawPoint)
				if rowPosition then placeTree(self, parent, template, rowPosition, tree) end
			end
		end
	end
end

local function renderPois(self: Renderer, parent: Instance, pois: any)
	if type(pois) ~= "table" then
		return
	end
	for _, poi in ipairs(pois) do
		local point = if type(poi) == "table" then readRoadPoint(poi.position) else nil
		if point then
			local marker = makePart(parent, "Poi", Vector3.new(1.5, 1.5, 1.5) * self.StudsPerMapUnit, CFrame.new(toWorld(self, point.X, 1.25, point.Z)), Color3.fromRGB(202, 78, 72), Enum.Material.Neon)
			marker.Shape = Enum.PartType.Ball
		end
	end
end

local function renderBase(self: Renderer, parent: Instance, mapData: any)
	local metadata = if type(mapData.chunk) == "table" then mapData.chunk else nil
	if type(metadata) ~= "table" then
		return
	end
	local minX = finiteNumber(metadata.minX)
	local minZ = finiteNumber(metadata.minZ)
	local maxX = finiteNumber(metadata.maxX)
	local maxZ = finiteNumber(metadata.maxZ)
	if not minX or not minZ or not maxX or not maxZ or maxX <= minX or maxZ <= minZ then
		return
	end
	local center = toWorld(self, (minX + maxX) * 0.5, -0.04, (minZ + maxZ) * 0.5)
	local base = makePart(parent, "MapBase", Vector3.new((maxX - minX) * self.StudsPerMapUnit, 0.08 * self.StudsPerMapUnit, (maxZ - minZ) * self.StudsPerMapUnit), CFrame.new(center), LOADED_BASE_COLOUR, Enum.Material.Grass)
	base.CanCollide = true
	base:SetAttribute("ChunkLoadState", "Loaded")
end

local WORLD_LAYER_NAMES = { "Water", "Landuse", "Buildings", "Roads", "Trees", "Pois", "Boundaries" }
local FADE_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function layerEnabled(layerVisibility: LayerOptions, layerName: string): boolean
	if layerName == "Water" then return layerVisibility.Water ~= false end
	if layerName == "Landuse" then return layerVisibility.Landuse ~= false end
	if layerName == "Buildings" then return layerVisibility.Buildings ~= false end
	if layerName == "Roads" then return layerVisibility.Roads ~= false end
	if layerName == "Trees" then return layerVisibility.Trees ~= false end
	if layerName == "Pois" then return layerVisibility.Pois ~= false end
	if layerName == "Boundaries" then return layerVisibility.Boundaries ~= false end
	return false
end

local function getChunkKey(mapData: any): string
	local metadata = if type(mapData) == "table" and type(mapData.chunk) == "table" then mapData.chunk else {}
	return string.format("%d:%d", finiteNumber(metadata.x) or 0, finiteNumber(metadata.z) or 0)
end

local function renderChunkBoundary(self: Renderer, parent: Instance, minX: number, minZ: number, maxX: number, maxZ: number)
	local corners = {
		Vector2.new(minX, minZ),
		Vector2.new(minX, maxZ),
		Vector2.new(maxX, maxZ),
		Vector2.new(maxX, minZ),
	}
	for index, from in ipairs(corners) do
		local to = corners[index % #corners + 1]
		local worldFrom = toWorld(self, from.X, 0.22, from.Y)
		local worldTo = toWorld(self, to.X, 0.22, to.Y)
		local length = (worldTo - worldFrom).Magnitude
		if length > 0.01 then
			local boundary = makePart(parent, "ChunkBoundary", Vector3.new(0.1 * self.StudsPerMapUnit, 0.05 * self.StudsPerMapUnit, length), CFrame.lookAt((worldFrom + worldTo) * 0.5, worldTo, Vector3.yAxis), Color3.fromRGB(232, 195, 100), Enum.Material.Neon)
			boundary.Transparency = 0.55
		end
	end
end

local function renderChunkLayer(self: Renderer, parent: Instance, layerName: string, mapData: any, chunkKey: string): Folder
	local existing = parent:FindFirstChild("Chunk_" .. chunkKey)
	if existing then
		existing:Destroy()
	end
	local chunkFolder = makeLayer(parent, "Chunk_" .. chunkKey)
	if layerName == "Base" then
		renderBase(self, chunkFolder, mapData)
	elseif layerName == "Water" then
		renderAreas(self, chunkFolder, mapData.water, "Water", 0, WATER_HEIGHT, Color3.fromRGB(73, 157, 207), Enum.Material.SmoothPlastic, true, nil)
	elseif layerName == "Landuse" then
		renderAreas(self, chunkFolder, mapData.landuse, "Landuse", WATER_HEIGHT, LANDUSE_HEIGHT, LANDUSE_DEFAULT_COLOUR, LANDUSE_DEFAULT_MATERIAL, false, landuseStyle)
	elseif layerName == "Buildings" then
		renderBuildings(self, chunkFolder, mapData.buildings)
	elseif layerName == "Roads" then
		renderRoads(self, chunkFolder, mapData.roads)
	elseif layerName == "Trees" then
		renderTrees(self, chunkFolder, mapData.trees)
	elseif layerName == "Pois" then
		renderPois(self, chunkFolder, mapData.pois)
	elseif layerName == "Boundaries" then
		local metadata = mapData.chunk or {}
		local minX, minZ = finiteNumber(metadata.minX), finiteNumber(metadata.minZ)
		local maxX, maxZ = finiteNumber(metadata.maxX), finiteNumber(metadata.maxZ)
		if minX and minZ and maxX and maxZ then
			renderChunkBoundary(self, chunkFolder, minX, minZ, maxX, maxZ)
		end
	end
	return chunkFolder
end

local function renderWorldLayer(self: Renderer, root: Instance, layerName: string): Folder
	local existing = root:FindFirstChild(layerName)
	if existing then existing:Destroy() end
	local layer = makeLayer(root, layerName)
	for chunkKey, chunkData in pairs(self.Chunks) do
		local mapData = getMapData(chunkData)
		if type(mapData) == "table" then
			renderChunkLayer(self, layer, layerName, mapData, chunkKey)
		end
	end
	if layerName == "Boundaries" then
		for chunkKey, bounds in pairs(self.PendingChunkBounds) do
			if not self.Chunks[chunkKey] then
				local pendingFolder = makeLayer(layer, "Chunk_" .. chunkKey)
				renderChunkBoundary(self, pendingFolder, bounds.MinX, bounds.MinZ, bounds.MaxX, bounds.MaxZ)
			end
		end
	end
	return layer
end

local function fadeLayer(layer: Instance, fadingIn: boolean)
	for _, descendant in ipairs(layer:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local baseTransparency = descendant:GetAttribute("OsmBaseTransparency")
			if type(baseTransparency) ~= "number" then
				baseTransparency = descendant.Transparency
				descendant:SetAttribute("OsmBaseTransparency", baseTransparency)
			end
			if fadingIn then
				if descendant.Transparency >= 0.999 then
					descendant.Transparency = 1
				end
				TweenService:Create(descendant, FADE_TWEEN_INFO, { Transparency = baseTransparency }):Play()
			else
				TweenService:Create(descendant, FADE_TWEEN_INFO, { Transparency = 1 }):Play()
			end
		end
	end
end

function OSMWorldRenderer.Create(): Renderer
	return setmetatable({
		Root = nil,
		WorldOffset = Vector3.zero,
		StudsPerMapUnit = 1,
		OriginLatitude = nil,
		OriginLongitude = nil,
		Data = nil,
		Chunks = {},
		PendingChunkBounds = {},
		LayerVisibility = {
			Roads = true,
			Buildings = true,
			Water = true,
			Landuse = true,
			Trees = true,
			Pois = true,
			Boundaries = true,
		},
		LayerFadeTokens = {},
	}, OSMWorldRenderer) :: any
end

function OSMWorldRenderer.Clear(self: Renderer)
	if self.Root then
		self.Root:ClearAllChildren()
	end
end

function OSMWorldRenderer.Render(self: Renderer, data: any, options: RenderOptions?)
	local mapData = getMapData(data)
	if type(mapData) ~= "table" then
		warn("OSMWorldRenderer expected a decoded OSM chunk table.")
		return
	end

	local renderOptions = options or {}
	self.WorldOffset = renderOptions.WorldOffset or Vector3.zero
	self.StudsPerMapUnit = renderOptions.StudsPerMapUnit or 1
	if self.StudsPerMapUnit <= 0 then
		warn("OSMWorldRenderer requires StudsPerMapUnit to be greater than zero.")
		return
	end
	local origin = if type(mapData.origin) == "table" then mapData.origin else {}
	self.OriginLatitude = finiteNumber(origin.lat)
	self.OriginLongitude = finiteNumber(origin.lon)

	local layers = renderOptions.Layers or {}
	self.Data = data
	self.Chunks = {
		[getChunkKey(mapData)] = data,
	}
	self.PendingChunkBounds = {}
	self.LayerVisibility = table.clone(layers)
	local root = getOrCreateRoot(self)
	root:ClearAllChildren()
	renderWorldLayer(self, root, "Base")
	for _, layerName in ipairs(WORLD_LAYER_NAMES) do
		if layerEnabled(layers, layerName) then
			renderWorldLayer(self, root, layerName)
		end
	end
end

function OSMWorldRenderer.AddChunk(self: Renderer, data: any): boolean
	local mapData = getMapData(data)
	if type(mapData) ~= "table" then
		warn("OSMWorldRenderer:AddChunk expected a decoded OSM chunk table.")
		return false
	end

	local chunkKey = getChunkKey(mapData)
	if self.Chunks[chunkKey] then
		return false
	end
	self.Chunks[chunkKey] = data
	self.PendingChunkBounds[chunkKey] = nil

	-- Every generated BasePart is first made fully transparent and then tweened
	-- to its authored transparency below, so a completed chunk never pops in.
	local root = getOrCreateRoot(self)
	local baseLayer = root:FindFirstChild("Base")
	if baseLayer and baseLayer:IsA("Folder") then
		local baseChunk = renderChunkLayer(self, baseLayer, "Base", mapData, chunkKey)
		for _, descendant in ipairs(baseChunk:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant:SetAttribute("OsmBaseTransparency", descendant.Transparency)
				descendant.Transparency = 1
			end
		end
		fadeLayer(baseChunk, true)
	end

	for _, layerName in ipairs(WORLD_LAYER_NAMES) do
		if layerEnabled(self.LayerVisibility, layerName) then
			local layer = root:FindFirstChild(layerName)
			if not layer or not layer:IsA("Folder") then
				layer = renderWorldLayer(self, root, layerName)
				for _, descendant in ipairs(layer:GetDescendants()) do
					if descendant:IsA("BasePart") then
						descendant:SetAttribute("OsmBaseTransparency", descendant.Transparency)
						descendant.Transparency = 1
					end
				end
				fadeLayer(layer, true)
			else
				local chunkLayer = renderChunkLayer(self, layer, layerName, mapData, chunkKey)
				for _, descendant in ipairs(chunkLayer:GetDescendants()) do
					if descendant:IsA("BasePart") then
						descendant:SetAttribute("OsmBaseTransparency", descendant.Transparency)
						descendant.Transparency = 1
					end
				end
				fadeLayer(chunkLayer, true)
			end
		end
	end
	return true
end

function OSMWorldRenderer.EnsureChunkBase(
	self: Renderer,
	chunkX: number,
	chunkZ: number,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number
)
	if maxX <= minX or maxZ <= minZ then
		return
	end
	local root = getOrCreateRoot(self)
	local baseLayer = root:FindFirstChild("Base")
	if not baseLayer or not baseLayer:IsA("Folder") then
		baseLayer = makeLayer(root, "Base")
	end
	local chunkKey = getChunkKey({
		chunk = { x = chunkX, z = chunkZ },
	})
	if baseLayer:FindFirstChild("Chunk_" .. chunkKey) then
		return
	end

	local chunkFolder = makeLayer(baseLayer, "Chunk_" .. chunkKey)
	local center = toWorld(self, (minX + maxX) * 0.5, -0.04, (minZ + maxZ) * 0.5)
	local base = makePart(
		chunkFolder,
		"PendingMapBase",
		Vector3.new((maxX - minX) * self.StudsPerMapUnit, 0.08 * self.StudsPerMapUnit, (maxZ - minZ) * self.StudsPerMapUnit),
		CFrame.new(center),
		LOADING_BASE_COLOUR,
		Enum.Material.Grass
	)
	-- This is the immediately available walkable surface while the server data
	-- request is in flight. Detailed geometry replaces it once the chunk arrives.
	base.CanCollide = true
	base:SetAttribute("PendingChunkBase", true)
	base:SetAttribute("ChunkLoadState", "Loading")
	self.PendingChunkBounds[chunkKey] = {
		X = chunkX,
		Z = chunkZ,
		MinX = minX,
		MinZ = minZ,
		MaxX = maxX,
		MaxZ = maxZ,
	}
	if layerEnabled(self.LayerVisibility, "Boundaries") then
		local boundaryLayer = root:FindFirstChild("Boundaries")
		if not boundaryLayer or not boundaryLayer:IsA("Folder") then
			boundaryLayer = makeLayer(root, "Boundaries")
		end
		local boundaryFolder = boundaryLayer:FindFirstChild("Chunk_" .. chunkKey)
		if boundaryFolder then
			boundaryFolder:Destroy()
		end
		boundaryFolder = makeLayer(boundaryLayer, "Chunk_" .. chunkKey)
		renderChunkBoundary(self, boundaryFolder, minX, minZ, maxX, maxZ)
	end
end

function OSMWorldRenderer.RemoveChunk(self: Renderer, chunkX: number, chunkZ: number)
	local chunkKey = getChunkKey({
		chunk = { x = chunkX, z = chunkZ },
	})
	self.Chunks[chunkKey] = nil
	self.PendingChunkBounds[chunkKey] = nil
	local root = self.Root
	if not root then
		return
	end
	for _, layer in ipairs(root:GetChildren()) do
		local chunkFolder = layer:FindFirstChild("Chunk_" .. chunkKey)
		if chunkFolder then
			chunkFolder:Destroy()
		end
	end
end

function OSMWorldRenderer.SetLayerVisibility(self: Renderer, layerVisibility: LayerOptions)
	if next(self.Chunks) == nil then
		return
	end
	local root = getOrCreateRoot(self)
	for _, layerName in ipairs(WORLD_LAYER_NAMES) do
		local wasEnabled = layerEnabled(self.LayerVisibility, layerName)
		local isEnabled = layerEnabled(layerVisibility, layerName)
		if wasEnabled ~= isEnabled then
			local token = (self.LayerFadeTokens[layerName] or 0) + 1
			self.LayerFadeTokens[layerName] = token
			local existing = root:FindFirstChild(layerName)
			if isEnabled then
				local layer = if existing and existing:IsA("Folder") then existing else renderWorldLayer(self, root, layerName)
				if not existing then
					for _, descendant in ipairs(layer:GetDescendants()) do
						if descendant:IsA("BasePart") then
							descendant:SetAttribute("OsmBaseTransparency", descendant.Transparency)
							descendant.Transparency = 1
						end
					end
				end
				fadeLayer(layer, true)
			elseif existing then
				fadeLayer(existing, false)
				task.delay(FADE_TWEEN_INFO.Time, function()
					if self.LayerFadeTokens[layerName] == token and existing.Parent then
						existing:Destroy()
					end
				end)
			end
		end
	end
	self.LayerVisibility = table.clone(layerVisibility)
end

function OSMWorldRenderer.WorldPositionToMap(self: Renderer, worldPosition: Vector3): Vector3
	if self.StudsPerMapUnit <= 0 then
		return Vector3.zero
	end
	local localPosition = (worldPosition - self.WorldOffset) / self.StudsPerMapUnit
	return Vector3.new(localPosition.X, localPosition.Y, -localPosition.Z)
end

function OSMWorldRenderer.WorldPositionToLatLon(self: Renderer, worldPosition: Vector3): (number?, number?)
	if self.OriginLatitude == nil or self.OriginLongitude == nil or self.StudsPerMapUnit <= 0 then
		return nil, nil
	end
	local mapPosition = self:WorldPositionToMap(worldPosition)
	local latitude = self.OriginLatitude + mapPosition.Z / 111320
	local longitudeScale = 111320 * math.cos(math.rad(latitude))
	if math.abs(longitudeScale) <= 0.00001 then
		return latitude, self.OriginLongitude
	end
	return latitude, self.OriginLongitude + mapPosition.X / longitudeScale
end

function OSMWorldRenderer.Destroy(self: Renderer)
	if self.Root then
		self.Root:Destroy()
		self.Root = nil
	end
end

return OSMWorldRenderer

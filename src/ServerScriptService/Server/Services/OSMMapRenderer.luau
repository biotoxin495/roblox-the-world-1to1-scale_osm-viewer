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

local AssetService = game:GetService("AssetService")
local Workspace = game:GetService("Workspace")

local OsmApiReturnedData = require(game.ReplicatedStorage.App.OsmApiReturnedData)

type MapPoint = Vector2
type Triangle = {}

export type RenderOptions = {
	Parent: Instance?,
	WorldOffset: Vector3?,
	StudsPerMapUnit: number?,
	DebugReferences: boolean?,
	Quality: "Low" | "Medium" | "High"?,
}

type RenderQuality = "Low" | "Medium" | "High"
type QualityProfile = {
	BuildingBandStep: number,
	BuildingMaxBands: number,
	AreaBandStep: number,
	AreaMaxBands: number,
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
local LANDUSE_HEIGHT = 0.06
local BUILDING_MIN_HEIGHT = 6
local BUILDING_DEFAULT_FLOOR_HEIGHT = 3
local BUILDING_EDGE_THICKNESS = 0.16
local AREA_EDGE_THICKNESS = 0.08
local TRIANGULATION_EPSILON = 0.00001

local editableMeshSupported: boolean? = nil
local didWarnAboutEditableMesh = false

-- Areas are still constructed from Parts because that keeps them physical and
-- collidable. Fine bands plus exact perimeter pieces make their outline read
-- as a continuous footprint rather than a set of coarse rectangular steps.
local QUALITY_PROFILES: { [RenderQuality]: QualityProfile } = {
	Low = {
		BuildingBandStep = 1,
		BuildingMaxBands = 96,
		AreaBandStep = 1.25,
		AreaMaxBands = 128,
	},
	Medium = {
		BuildingBandStep = 0.5,
		BuildingMaxBands = 192,
		AreaBandStep = 0.65,
		AreaMaxBands = 256,
	},
	High = {
		BuildingBandStep = 0.25,
		BuildingMaxBands = 320,
		AreaBandStep = 0.35,
		AreaMaxBands = 384,
	},
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

local function getQualityProfile(quality: RenderQuality?): QualityProfile
	-- Medium is smooth at normal player distance without multiplying chunk
	-- streaming cost. High is available for close-up or showcase maps.
	return QUALITY_PROFILES[quality or "Medium"]
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
	if root then
		root:SetAttribute("GeneratedBy", OSMMapRenderer.Name)
	end
	OSMMapRenderer.Root = root
	return root
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

local function materialForSurface(surface: any): Enum.Material
	if surface == "concrete" then
		return Enum.Material.Concrete
	elseif surface == "paving_stones" or surface == "cobblestone" or surface == "unhewn_cobblestone" then
		return Enum.Material.Cobblestone
	elseif surface == "gravel" or surface == "fine_gravel" then
		return Enum.Material.Gravel
	elseif surface == "dirt" or surface == "earth" or surface == "ground" then
		return Enum.Material.Ground
	elseif surface == "wood" then
		return Enum.Material.WoodPlanks
	end
	return Enum.Material.Asphalt
end

local function normalisePolygon(points: any): { MapPoint }
	local polygon = {} :: { MapPoint }
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

local function signedPolygonArea(polygon: { MapPoint }): number
	local area = 0
	for index, point in ipairs(polygon) do
		local nextPoint = polygon[index % #polygon + 1]
		area += point.X * nextPoint.Y - nextPoint.X * point.Y
	end
	return area * 0.5
end

local function cross2D(from: MapPoint, through: MapPoint, to: MapPoint): number
	return (through.X - from.X) * (to.Y - from.Y) - (through.Y - from.Y) * (to.X - from.X)
end

local function pointIsInsideTriangle(point: MapPoint, a: MapPoint, b: MapPoint, c: MapPoint): boolean
	local ab = cross2D(a, b, point)
	local bc = cross2D(b, c, point)
	local ca = cross2D(c, a, point)
	return (ab >= -TRIANGULATION_EPSILON and bc >= -TRIANGULATION_EPSILON and ca >= -TRIANGULATION_EPSILON)
		or (ab <= TRIANGULATION_EPSILON and bc <= TRIANGULATION_EPSILON and ca <= TRIANGULATION_EPSILON)
end

-- Ear clipping handles both convex and concave OSM footprints. Its output is
-- an exact polygon tessellation: no grid resolution or scanline approximation.
local function triangulatePolygon(polygon: { MapPoint }): { Triangle }?
	if #polygon < 3 or math.abs(signedPolygonArea(polygon)) <= TRIANGULATION_EPSILON then
		return nil
	end

	local counterClockwise = signedPolygonArea(polygon) > 0
	local active = {} :: { number }
	for index = 1, #polygon do
		table.insert(active, index)
	end

	local triangles = {} :: { Triangle }
	local safety = #polygon * #polygon
	while #active > 3 and safety > 0 do
		local earFound = false
		for activeIndex, currentIndex in ipairs(active) do
			local previousIndex = active[(activeIndex - 2) % #active + 1]
			local nextIndex = active[activeIndex % #active + 1]
			local previous = polygon[previousIndex]
			local current = polygon[currentIndex]
			local next = polygon[nextIndex]
			local cross = cross2D(previous, current, next)
			local convex = if counterClockwise then cross > TRIANGULATION_EPSILON else cross < -TRIANGULATION_EPSILON
			if not convex then
				continue
			end

			local containsVertex = false
			for _, candidateIndex in ipairs(active) do
				if
					candidateIndex ~= previousIndex
					and candidateIndex ~= currentIndex
					and candidateIndex ~= nextIndex
				then
					if pointIsInsideTriangle(polygon[candidateIndex], previous, current, next) then
						containsVertex = true
						break
					end
				end
			end

			if not containsVertex then
				table.insert(triangles, { previousIndex, currentIndex, nextIndex })
				table.remove(active, activeIndex)
				earFound = true
				break
			end
		end

		if not earFound then
			return nil
		end
		safety -= 1
	end

	if #active == 3 then
		table.insert(triangles, { active[1], active[2], active[3] })
	end
	return triangles
end

local function createExtrudedBuildingMesh(
	parent: Instance,
	polygon: { MapPoint },
	height: number,
	offset: Vector3,
	scale: number,
	colour: Color3
): MeshPart?
	if editableMeshSupported == false then
		return nil
	end

	local triangles = triangulatePolygon(polygon)
	if not triangles then
		return nil
	end

	local ok, result = pcall(function(): MeshPart
		local editableMesh = AssetService:CreateEditableMesh()
		local bottomVertexIds = {} :: { any }
		local topVertexIds = {} :: { any }
		for index, point in ipairs(polygon) do
			bottomVertexIds[index] = editableMesh:AddVertex(Vector3.new(point.X * scale, 0, point.Y * scale))
			topVertexIds[index] = editableMesh:AddVertex(Vector3.new(point.X * scale, height * scale, point.Y * scale))
		end

		local counterClockwise = signedPolygonArea(polygon) > 0
		for _, triangle in ipairs(triangles) do
			local a, b, c = triangle[1], triangle[2], triangle[3]
			-- In Roblox's X/Z plane, a counter-clockwise 2D triangle faces down.
			-- Reverse only the roof winding so its normal faces upwards.
			if counterClockwise then
				editableMesh:AddTriangle(topVertexIds[a], topVertexIds[c], topVertexIds[b])
				editableMesh:AddTriangle(bottomVertexIds[a], bottomVertexIds[b], bottomVertexIds[c])
			else
				editableMesh:AddTriangle(topVertexIds[a], topVertexIds[b], topVertexIds[c])
				editableMesh:AddTriangle(bottomVertexIds[a], bottomVertexIds[c], bottomVertexIds[b])
			end
		end

		for index = 1, #polygon do
			local nextIndex = index % #polygon + 1
			local bottomA, bottomB = bottomVertexIds[index], bottomVertexIds[nextIndex]
			local topA, topB = topVertexIds[index], topVertexIds[nextIndex]
			if counterClockwise then
				editableMesh:AddTriangle(bottomA, topB, bottomB)
				editableMesh:AddTriangle(bottomA, topA, topB)
			else
				editableMesh:AddTriangle(bottomA, bottomB, topB)
				editableMesh:AddTriangle(bottomA, topB, topA)
			end
		end

		local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(editableMesh), {
			CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
		})
		meshPart.Name = "Building"
		meshPart.Anchored = true
		meshPart.CanCollide = true
		meshPart.CanTouch = true
		meshPart.CanQuery = true
		meshPart.CFrame = CFrame.new(offset)
		meshPart.Color = colour
		meshPart.Material = Enum.Material.Concrete
		meshPart.Parent = parent
		return meshPart
	end)

	if ok then
		editableMeshSupported = true
		return result :: MeshPart
	end

	editableMeshSupported = false
	if not didWarnAboutEditableMesh then
		didWarnAboutEditableMesh = true
		warn("OSMMapRenderer: EditableMesh is unavailable; falling back to band-filled buildings. " .. tostring(result))
	end
	return nil
end

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

-- Fills a polygon with horizontal bands. Unlike a bounding box, this preserves
-- concave footprints and keeps the resulting pieces collidable for buildings.
local function createPolygonBands(
	parent: Instance,
	name: string,
	polygon: { MapPoint },
	y: number,
	height: number,
	step: number,
	maxBands: number,
	offset: Vector3,
	scale: number,
	colour: Color3,
	material: Enum.Material,
	canCollide: boolean
)
	if #polygon < 3 then
		return
	end

	local minZ = math.huge
	local maxZ = -math.huge
	for _, point in ipairs(polygon) do
		minZ = math.min(minZ, point.Y)
		maxZ = math.max(maxZ, point.Y)
	end

	local bandCount = math.ceil((maxZ - minZ) / step)
	if bandCount > maxBands then
		step = (maxZ - minZ) / maxBands
	end

	local bandStart = minZ
	while bandStart < maxZ do
		local bandEnd = math.min(bandStart + step, maxZ)
		local scanZ = (bandStart + bandEnd) * 0.5
		local intersections = {} :: { number }

		for index, point in ipairs(polygon) do
			local nextPoint = polygon[index % #polygon + 1]
			if (point.Y <= scanZ and nextPoint.Y > scanZ) or (nextPoint.Y <= scanZ and point.Y > scanZ) then
				local progress = (scanZ - point.Y) / (nextPoint.Y - point.Y)
				table.insert(intersections, point.X + (nextPoint.X - point.X) * progress)
			end
		end

		table.sort(intersections)
		for index = 1, #intersections - 1, 2 do
			local left = intersections[index]
			local right = intersections[index + 1]
			if right - left > 0.01 then
				local center = Vector3.new((left + right) * 0.5, y + height * 0.5, (bandStart + bandEnd) * 0.5)
				local size = Vector3.new((right - left) * scale, height * scale, (bandEnd - bandStart) * scale)
				local part = makePart(parent, name, size, CFrame.new(toWorld(center, offset, scale)), colour, material)
				part.CanCollide = canCollide
				part.CanTouch = canCollide
				part.CanQuery = canCollide
			end
		end

		bandStart = bandEnd
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
	quality: QualityProfile
)
	if type(features) ~= "table" then
		return
	end

	for _, feature in ipairs(features) do
		if type(feature) == "table" and type(feature.polygons) == "table" then
			for _, rawPolygon in ipairs(feature.polygons) do
				local polygon = normalisePolygon(rawPolygon)
				createPolygonBands(
					parent,
					name,
					polygon,
					y,
					height,
					quality.AreaBandStep,
					quality.AreaMaxBands,
					offset,
					scale,
					colour,
					material,
					canCollide
				)
				-- A narrow continuous edge disguises the remaining sub-stud band
				-- approximation and gives lakes, parks, and plazas a crisp OSM shape.
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
		local previous: Vector3? = nil
		for _, rawPoint in ipairs(road.points) do
			local point = readRoadPoint(rawPoint)
			if point then
				local worldPoint = toWorld(point, offset, scale) + Vector3.new(0, ROAD_HEIGHT * scale * 0.5, 0)
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

local function renderBuildings(
	parent: Instance,
	buildings: any,
	offset: Vector3,
	scale: number,
	quality: QualityProfile
)
	if type(buildings) ~= "table" then
		return
	end

	for _, building in ipairs(buildings) do
		if type(building) == "table" then
			local height = getBuildingHeight(building)
			local colour = BUILDING_COLOURS[building.kind] or BUILDING_COLOURS.default
			local footprint = normalisePolygon(building.footprint)
			if createExtrudedBuildingMesh(parent, footprint, height, offset, scale, colour) then
				continue
			end

			-- EditableMesh can be unavailable in experiences that have not enabled
			-- the Mesh & Image APIs. Preserve a physical fallback in that case.
			createPolygonBands(
				parent,
				"Building",
				footprint,
				0,
				height,
				quality.BuildingBandStep,
				quality.BuildingMaxBands,
				offset,
				scale,
				colour,
				Enum.Material.Concrete,
				true
			)
			-- Exact vertical facade segments preserve the source footprint's straight
			-- edges even where the physical fill uses very fine bands underneath.
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

function OSMMapRenderer:Init()
	getOrCreateRoot(Workspace)
end

function OSMMapRenderer:AddChunk(data: any, options: RenderOptions?): Model?
	local mapData = getMapData(data)
	if type(mapData) ~= "table" then
		warn("OSMMapRenderer:AddChunk expected a decoded OSM chunk table.")
		return nil
	end

	local renderOptions = options or {}
	local parent = renderOptions.Parent or Workspace
	local offset = renderOptions.WorldOffset or self.WorldOffset
	local scale = renderOptions.StudsPerMapUnit or self.StudsPerMapUnit
	local quality = getQualityProfile(renderOptions.Quality)
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
		Enum.Material.Glass,
		false,
		offset,
		scale,
		quality
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
		quality
	)
	renderBuildings(buildings, mapData.buildings, offset, scale, quality)
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
	if self.Root then
		self.Root:Destroy()
		self.Root = nil
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

-- Polygon fill using ear clipping triangulation
-- Put this Script in ServerScriptService or Workspace.
-- Create a Folder in Workspace named "PolygonPoints".
-- Put Parts inside it named 1, 2, 3, 4... in boundary order.
-- Concave polygons are okay. Self-intersecting polygons and holes are not supported.

local POINTS_FOLDER = workspace:WaitForChild("PolygonPoints")
local OUTPUT_FOLDER_NAME = "PolygonFill"

local THICKNESS = 0.08
local FILL_COLOR = Color3.fromRGB(0, 170, 255)
local FILL_TRANSPARENCY = 0.2
local FILL_MATERIAL = Enum.Material.SmoothPlastic

local AUTO_REBUILD = true
local EPS = 1e-6

local function cross2(a: Vector2, b: Vector2, c: Vector2): number
	local ab = b - a
	local ac = c - a
	return ab.X * ac.Y - ab.Y * ac.X
end

local function getPointOrder(part: BasePart): number?
	local attr = part:GetAttribute("Order")
	if typeof(attr) == "number" then
		return attr
	end

	local numberFromName = tonumber(part.Name:match("%-?%d+"))
	return numberFromName
end

local function getPointParts(): { BasePart }
	local parts = {}

	for _, child in ipairs(POINTS_FOLDER:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end

	if #parts < 3 then
		error("Need at least 3 point parts inside workspace.PolygonPoints.")
	end

	local allHaveOrder = true
	for _, part in ipairs(parts) do
		if getPointOrder(part) == nil then
			allHaveOrder = false
			break
		end
	end

	if allHaveOrder then
		table.sort(parts, function(a, b)
			return getPointOrder(a) < getPointOrder(b)
		end)
	else
		warn(
			"[PolygonFill] Not every point has an Order attribute or numeric name. Falling back to angle sorting. This may fail for concave polygons."
		)
	end

	return parts
end

local function makePlaneBasis(points: { Vector3 })
	local origin = points[1]

	for i = 2, #points - 1 do
		for j = i + 1, #points do
			local u = points[i] - origin
			local v = points[j] - origin
			local normal = u:Cross(v)

			if u.Magnitude > EPS and normal.Magnitude > EPS then
				local axisU = u.Unit
				local axisN = normal.Unit
				local axisV = axisN:Cross(axisU).Unit

				return origin, axisU, axisV, axisN
			end
		end
	end

	error("Could not create polygon plane. Points may be duplicate or collinear.")
end

local function projectPoint(point: Vector3, origin: Vector3, axisU: Vector3, axisV: Vector3): Vector2
	local relative = point - origin
	return Vector2.new(relative:Dot(axisU), relative:Dot(axisV))
end

local function signedArea2D(vertices): number
	local area = 0

	for i = 1, #vertices do
		local a = vertices[i].coord
		local b = vertices[(i % #vertices) + 1].coord
		area += a.X * b.Y - b.X * a.Y
	end

	return area * 0.5
end

local function reverseArray(array)
	local reversed = {}

	for i = #array, 1, -1 do
		table.insert(reversed, array[i])
	end

	return reversed
end

local function sanitizeVertices(vertices)
	local changed = true

	while changed and #vertices >= 3 do
		changed = false

		for i = #vertices, 1, -1 do
			local current = vertices[i]
			local previous = vertices[((i - 2) % #vertices) + 1]

			if (current.coord - previous.coord).Magnitude < EPS then
				table.remove(vertices, i)
				changed = true
			end
		end

		if #vertices < 3 then
			break
		end

		for i = #vertices, 1, -1 do
			local previous = vertices[((i - 2) % #vertices) + 1].coord
			local current = vertices[i].coord
			local nextPoint = vertices[(i % #vertices) + 1].coord

			if math.abs(cross2(previous, current, nextPoint)) < EPS then
				table.remove(vertices, i)
				changed = true
			end
		end
	end

	return vertices
end

local function pointInTriangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2): boolean
	local c1 = cross2(a, b, p)
	local c2 = cross2(b, c, p)
	local c3 = cross2(c, a, p)

	return c1 >= -EPS and c2 >= -EPS and c3 >= -EPS
end

local function isEar(vertices, indices, listIndex): boolean
	local count = #indices

	local prevIndex = indices[((listIndex - 2) % count) + 1]
	local currIndex = indices[listIndex]
	local nextIndex = indices[(listIndex % count) + 1]

	local a = vertices[prevIndex].coord
	local b = vertices[currIndex].coord
	local c = vertices[nextIndex].coord

	if cross2(a, b, c) <= EPS then
		return false
	end

	for _, testIndex in ipairs(indices) do
		if testIndex ~= prevIndex and testIndex ~= currIndex and testIndex ~= nextIndex then
			local p = vertices[testIndex].coord

			if pointInTriangle(p, a, b, c) then
				return false
			end
		end
	end

	return true
end

local function triangulate(vertices)
	local triangles = {}
	local indices = {}

	for i = 1, #vertices do
		table.insert(indices, i)
	end

	local guard = 0
	local maxGuard = #vertices * #vertices

	while #indices > 3 do
		guard += 1

		if guard > maxGuard then
			error(
				"Ear clipping failed. Check point order, self-intersections, duplicate points, or non-simple polygon shape."
			)
		end

		local earFound = false

		for i = 1, #indices do
			if isEar(vertices, indices, i) then
				local count = #indices

				local prevIndex = indices[((i - 2) % count) + 1]
				local currIndex = indices[i]
				local nextIndex = indices[(i % count) + 1]

				table.insert(triangles, {
					prevIndex,
					currIndex,
					nextIndex,
				})

				table.remove(indices, i)
				earFound = true
				break
			end
		end

		if not earFound then
			error("No valid ear found. The polygon may be self-intersecting or incorrectly ordered.")
		end
	end

	table.insert(triangles, {
		indices[1],
		indices[2],
		indices[3],
	})

	return triangles
end

local function applyWedgeProperties(wedge: WedgePart)
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanTouch = false
	wedge.CanQuery = false
	wedge.CastShadow = false

	wedge.Color = FILL_COLOR
	wedge.Transparency = FILL_TRANSPARENCY
	wedge.Material = FILL_MATERIAL

	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.FrontSurface = Enum.SurfaceType.Smooth
	wedge.BackSurface = Enum.SurfaceType.Smooth
	wedge.LeftSurface = Enum.SurfaceType.Smooth
	wedge.RightSurface = Enum.SurfaceType.Smooth
end

local function newWedge(name: string, parent: Instance): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	applyWedgeProperties(wedge)
	wedge.Parent = parent
	return wedge
end

local function drawTriangle(a: Vector3, b: Vector3, c: Vector3, parent: Instance, triangleIndex: number)
	local ab = b - a
	local ac = c - a
	local bc = c - b

	local abd = ab:Dot(ab)
	local acd = ac:Dot(ac)
	local bcd = bc:Dot(bc)

	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end

	ab = b - a
	ac = c - a
	bc = c - b

	if ab.Magnitude < EPS or ac.Magnitude < EPS or bc.Magnitude < EPS then
		return
	end

	local rightVector = ac:Cross(ab)
	if rightVector.Magnitude < EPS then
		return
	end

	local right = rightVector.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit

	local height = math.abs(ab:Dot(up))
	local width1 = math.abs(ab:Dot(back))
	local width2 = math.abs(ac:Dot(back))

	if height < EPS or width1 < EPS or width2 < EPS then
		return
	end

	local wedge1 = newWedge("Triangle_" .. triangleIndex .. "_A", parent)
	wedge1.Size = Vector3.new(THICKNESS, height, width1)
	wedge1.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, up, back)

	local wedge2 = newWedge("Triangle_" .. triangleIndex .. "_B", parent)
	wedge2.Size = Vector3.new(THICKNESS, height, width2)
	wedge2.CFrame = CFrame.fromMatrix((a + c) * 0.5, -right, up, -back)
end

local function buildVertices()
	local parts = getPointParts()

	local worldPoints = {}
	for _, part in ipairs(parts) do
		table.insert(worldPoints, part.Position)
	end

	local origin, axisU, axisV = makePlaneBasis(worldPoints)

	local allHaveOrder = true
	for _, part in ipairs(parts) do
		if getPointOrder(part) == nil then
			allHaveOrder = false
			break
		end
	end

	local vertices = {}

	for _, part in ipairs(parts) do
		table.insert(vertices, {
			part = part,
			world = part.Position,
			coord = projectPoint(part.Position, origin, axisU, axisV),
		})
	end

	if not allHaveOrder then
		local center = Vector2.zero

		for _, vertex in ipairs(vertices) do
			center += vertex.coord
		end

		center /= #vertices

		table.sort(vertices, function(a, b)
			local angleA = math.atan2(a.coord.Y - center.Y, a.coord.X - center.X)
			local angleB = math.atan2(b.coord.Y - center.Y, b.coord.X - center.X)
			return angleA < angleB
		end)
	end

	vertices = sanitizeVertices(vertices)

	if #vertices < 3 then
		error("Polygon became invalid after removing duplicate or collinear points.")
	end

	if signedArea2D(vertices) < 0 then
		vertices = reverseArray(vertices)
	end

	return vertices
end

local function rebuild()
	local oldFill = workspace:FindFirstChild(OUTPUT_FOLDER_NAME)
	if oldFill then
		oldFill:Destroy()
	end

	local outputFolder = Instance.new("Folder")
	outputFolder.Name = OUTPUT_FOLDER_NAME
	outputFolder.Parent = workspace

	local success, result = pcall(function()
		local vertices = buildVertices()
		local triangles = triangulate(vertices)

		for triangleIndex, triangle in ipairs(triangles) do
			local a = vertices[triangle[1]].world
			local b = vertices[triangle[2]].world
			local c = vertices[triangle[3]].world

			drawTriangle(a, b, c, outputFolder, triangleIndex)
		end

		print("[PolygonFill] Built", #triangles, "triangles.")
	end)

	if not success then
		warn("[PolygonFill] " .. tostring(result))
	end
end

local rebuildQueued = false

local function queueRebuild()
	if rebuildQueued then
		return
	end

	rebuildQueued = true

	task.defer(function()
		rebuildQueued = false
		rebuild()
	end)
end

rebuild()

if AUTO_REBUILD then
	for _, child in ipairs(POINTS_FOLDER:GetChildren()) do
		if child:IsA("BasePart") then
			child:GetPropertyChangedSignal("Position"):Connect(queueRebuild)
			child:GetAttributeChangedSignal("Order"):Connect(queueRebuild)
		end
	end

	POINTS_FOLDER.ChildAdded:Connect(function(child)
		if child:IsA("BasePart") then
			child:GetPropertyChangedSignal("Position"):Connect(queueRebuild)
			child:GetAttributeChangedSignal("Order"):Connect(queueRebuild)
		end

		queueRebuild()
	end)

	POINTS_FOLDER.ChildRemoved:Connect(queueRebuild)
end

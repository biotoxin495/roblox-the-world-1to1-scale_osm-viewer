--!strict

--[=[
	Context-agnostic tiled EditableImage canvas.

	This module knows nothing about OSM, locations, spawn screens, or game UI. It
	only creates ImageLabel tiles and clips simple raster draw calls across them.
]=]

local AssetService = game:GetService("AssetService")

local EditableImageCanvas = {}

export type ImageTile = {
	Gui: ImageLabel,
	Image: any,
	Offset: Vector2,
	Size: Vector2,
}

export type RenderTarget = {
	Tiles: { ImageTile },
	Size: Vector2,
}

function EditableImageCanvas.CreateEditableImage(size: Vector2, warningContext: string): any?
	local ok, editableImage = pcall(function()
		return (AssetService :: any):CreateEditableImage({
			Size = size,
		})
	end)
	if ok then
		return editableImage
	end

	warn(string.format("Cannot create EditableImage for %s: %s", warningContext, tostring(editableImage)))
	return nil
end

function EditableImageCanvas.SetImageContent(imageLabel: ImageLabel, editableImage: any, warningContext: string)
	local ok, result = pcall(function()
		return (Content :: any).fromObject(editableImage)
	end)
	if ok then
		(imageLabel :: any).ImageContent = result
		return
	end

	warn(string.format("Cannot bind EditableImage to %s ImageLabel: %s", warningContext, tostring(result)))
end

function EditableImageCanvas.DrawImageRectangle(image: any, position: Vector2, size: Vector2, colour: Color3)
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

function EditableImageCanvas.RectanglesOverlap(position: Vector2, size: Vector2, tile: ImageTile): boolean
	return position.X < tile.Offset.X + tile.Size.X
		and position.X + size.X > tile.Offset.X
		and position.Y < tile.Offset.Y + tile.Size.Y
		and position.Y + size.Y > tile.Offset.Y
end

function EditableImageCanvas.DrawTargetRectangle(target: RenderTarget, position: Vector2, size: Vector2, colour: Color3)
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	for _, tile in ipairs(target.Tiles) do
		if not EditableImageCanvas.RectanglesOverlap(position, size, tile) then
			continue
		end

		local left = math.max(position.X, tile.Offset.X)
		local top = math.max(position.Y, tile.Offset.Y)
		local right = math.min(position.X + size.X, tile.Offset.X + tile.Size.X)
		local bottom = math.min(position.Y + size.Y, tile.Offset.Y + tile.Size.Y)
		EditableImageCanvas.DrawImageRectangle(
			tile.Image,
			Vector2.new(left - tile.Offset.X, top - tile.Offset.Y),
			Vector2.new(right - left, bottom - top),
			colour
		)
	end
end

function EditableImageCanvas.FillPolygon(target: RenderTarget, polygon: { Vector2 }, colour: Color3, step: number?)
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
				EditableImageCanvas.DrawTargetRectangle(
					target,
					Vector2.new(left, y),
					Vector2.new(right - left, scanlineStep),
					colour
				)
			end
		end
	end
end

return EditableImageCanvas

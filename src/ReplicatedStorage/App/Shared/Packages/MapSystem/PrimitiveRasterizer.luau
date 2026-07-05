--!strict

-- Draws map primitives into a RenderTarget. Interpreters should convert their
-- source data into these primitives before handing work to the renderer.

local EditableImageCanvas = require(script.Parent.EditableImageCanvas)

local PrimitiveRasterizer = {}

export type RenderTarget = EditableImageCanvas.RenderTarget

function PrimitiveRasterizer.Rectangle(target: RenderTarget, position: Vector2, size: Vector2, colour: Color3)
	EditableImageCanvas.DrawTargetRectangle(target, position, size, colour)
end

function PrimitiveRasterizer.Polygon(target: RenderTarget, polygon: { Vector2 }, colour: Color3, step: number?)
	EditableImageCanvas.FillPolygon(target, polygon, colour, step)
end

function PrimitiveRasterizer.Segment(target: RenderTarget, from: Vector2, to: Vector2, thickness: number, colour: Color3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.1 then
		return
	end

	local halfThickness = math.max(0.5, thickness * 0.5)
	local normal = Vector2.new(-delta.Y / length, delta.X / length) * halfThickness
	PrimitiveRasterizer.Polygon(target, {
		from + normal,
		to + normal,
		to - normal,
		from - normal,
	}, colour, 1)
end

function PrimitiveRasterizer.Circle(target: RenderTarget, center: Vector2, radius: number, colour: Color3)
	if radius <= 0 then
		return
	end

	local integerRadius = math.ceil(radius)
	for offsetY = -integerRadius, integerRadius do
		local span = math.sqrt(math.max(0, radius * radius - offsetY * offsetY))
		local left = center.X - span
		local width = span * 2
		if width > 0 then
			PrimitiveRasterizer.Rectangle(target, Vector2.new(left, center.Y + offsetY), Vector2.new(width, 1), colour)
		end
	end
end

return PrimitiveRasterizer

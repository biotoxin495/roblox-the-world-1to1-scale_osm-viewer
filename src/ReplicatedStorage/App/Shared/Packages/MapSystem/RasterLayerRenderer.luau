--!strict

--[=[
	Data-neutral layer renderer.

	Map-specific code should act as an interpreter: convert roads, buildings,
	tiles, planets, dungeons, or any other source data into this document shape.
	This renderer only cares about layer order, visibility, and drawing primitive
	operations into a RenderTarget.
]=]

local PrimitiveRasterizer = require(script.Parent.PrimitiveRasterizer)

local RasterLayerRenderer = {}

export type Operation =
	{ Kind: "Rectangle", Position: Vector2, Size: Vector2, Colour: Color3 }
	| { Kind: "Polygon", Points: { Vector2 }, Colour: Color3, Step: number? }
	| { Kind: "Segment", From: Vector2, To: Vector2, Thickness: number, Colour: Color3 }
	| { Kind: "Circle", Center: Vector2, Radius: number, Colour: Color3 }

export type Layer = {
	Id: string,
	Visible: boolean?,
	Operations: { Operation },
}

export type Document = {
	Layers: { Layer },
}

function RasterLayerRenderer.Render(target: PrimitiveRasterizer.RenderTarget, document: Document)
	for _, layer in ipairs(document.Layers) do
		if layer.Visible == false then
			continue
		end

		for _, operation in ipairs(layer.Operations) do
			if operation.Kind == "Rectangle" then
				PrimitiveRasterizer.Rectangle(target, operation.Position, operation.Size, operation.Colour)
			elseif operation.Kind == "Polygon" then
				PrimitiveRasterizer.Polygon(target, operation.Points, operation.Colour, operation.Step)
			elseif operation.Kind == "Segment" then
				PrimitiveRasterizer.Segment(target, operation.From, operation.To, operation.Thickness, operation.Colour)
			elseif operation.Kind == "Circle" then
				PrimitiveRasterizer.Circle(target, operation.Center, operation.Radius, operation.Colour)
			end
		end
	end
end

return RasterLayerRenderer

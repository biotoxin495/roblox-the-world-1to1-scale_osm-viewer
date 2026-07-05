--!strict

--[=[
	Context-agnostic map rendering package.

	Adapters/interpreters should translate source data into generic layers and
	primitives. This package then handles raster drawing, projection helpers, and
	standard map interactions without knowing where the data came from.
]=]

return {
	EditableImageCanvas = require(script.EditableImageCanvas),
	EquirectangularProjection = require(script.EquirectangularProjection),
	PrimitiveRasterizer = require(script.PrimitiveRasterizer),
	RasterLayerRenderer = require(script.RasterLayerRenderer),
	DragZoomInteraction = require(script.DragZoomInteraction),
}

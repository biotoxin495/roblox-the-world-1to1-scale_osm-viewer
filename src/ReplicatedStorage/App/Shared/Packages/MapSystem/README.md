# MapSystem

`MapSystem` is a context-agnostic map rendering package. It should not know
about OSM, spawn selection, Roblox screens, countries, roads, buildings, or any
specific game feature. Its job is to provide reusable map primitives that other
packages can feed with interpreted data.

## Responsibilities

- Create and draw into tiled `EditableImage` UI canvases.
- Render generic raster primitives such as rectangles, polygons, line segments,
  and circles.
- Render generic ordered map layers from a simple document shape.
- Provide projection helpers that can be reused by adapters.
- Bind common drag, click-select, mouse-wheel zoom, and zoom-button behaviour
  through callbacks supplied by the consuming controller.

## Package Modules

### `EditableImageCanvas`

Low-level tiled `EditableImage` helper.

Use this when a renderer needs to draw into a UI surface larger than a single
editable image. It owns image creation, binding `ImageContent`, rectangle
clipping, and tiled raster writes.

```luau
local MapSystem = ReplicatedStorage.App.Shared.Packages.MapSystem
local EditableImageCanvas = require(MapSystem.EditableImageCanvas)
```

### `PrimitiveRasterizer`

Draws generic primitives into an `EditableImageCanvas.RenderTarget`.

Supported operations:

- `Rectangle(target, position, size, colour)`
- `Polygon(target, points, colour, step?)`
- `Segment(target, from, to, thickness, colour)`
- `Circle(target, center, radius, colour)`

Adapters should convert source data into these primitive operations instead of
placing source-specific parsing inside renderers.

### `RasterLayerRenderer`

Renders a generic document:

```luau
local document = {
	Layers = {
		{
			Id = "Water",
			Visible = true,
			Operations = {
				{
					Kind = "Polygon",
					Points = waterPolygon,
					Colour = Color3.fromRGB(157, 203, 225),
					Step = 2,
				},
			},
		},
	},
}

RasterLayerRenderer.Render(renderTarget, document)
```

This is the preferred boundary for non-OSM data sources. A dungeon map, tilemap,
fantasy world map, city generator, or custom API should write an interpreter
that emits this document shape.

### `EquirectangularProjection`

Projection helpers for 2:1 world maps:

- `LatLonToMap(latitude, longitude)`
- `MapToLatLon(mapPosition)`
- `GetWorldPixelSize(tileSize, zoom)`
- `NormalisedRingToPoints(ring, imageSize)`

Only use this for map data that actually uses this projection. Other projection
types should live in separate projection modules.

### `DragZoomInteraction`

Generic input binder for map controllers.

The controller supplies state and methods such as `panByScreenDelta`, `zoomBy`,
`screenToMap`, and `queueRender`. The adapter supplies callbacks for converting
screen points to map points and reacting to map selections.

```luau
DragZoomInteraction.Bind(controller, {
	ClickDragThreshold = 6,
	ButtonZoomStep = 0.75,
	WheelZoomStep = 0.35,

	ScreenPointToMapPoint = function(targetController, screenPoint)
		return targetController:screenToMap(screenPoint, targetController.Zoom)
	end,

	MapPointSelected = function(targetController, mapPoint)
		targetController.MapPointSelected:Fire(mapPoint)
	end,

	ShouldIgnoreClick = function(targetController, inputPosition)
		return false
	end,
})
```

## Adapter Pattern

`MapSystem` should be used through adapters or interpreters:

1. Read source-specific data in an adapter package.
2. Convert it into generic primitives or a `RasterLayerRenderer.Document`.
3. Pass the generic output to `MapSystem`.
4. Keep source-specific names, IDs, tags, API quirks, and game workflows outside
   `MapSystem`.

Example:

```luau
local function interpretCustomTiles(tileData)
	local layers = {}

	for _, tile in ipairs(tileData.Tiles) do
		table.insert(layers, {
			Id = tile.Layer,
			Visible = true,
			Operations = {
				{
					Kind = "Rectangle",
					Position = tile.ScreenPosition,
					Size = tile.ScreenSize,
					Colour = tile.Colour,
				},
			},
		})
	end

	return { Layers = layers }
end
```

## What Not To Put Here

- OSM payload parsing.
- Spawn screen UI.
- Country/city/location concepts.
- Game-specific popup or network code.
- Road/building/water semantics.
- Asset templates for a specific game.

Those belong in an adapter package such as `OSMMap` or a game-specific package.

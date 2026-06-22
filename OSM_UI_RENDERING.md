# OSM UI Rendering

This document describes the current OpenStreetMap chunk renderer used by the
`ConfirmSpawnInfo` screen. It is the reference implementation for the planned
Roblox 3D-world renderer.

## Entry points

| File | Responsibility |
| --- | --- |
| `src/StarterGui/Client/OsmApiReturnedData.luau` | Temporary decoded example payload returned by the OSM API. |
| `src/StarterGui/Client/UI/Screens/ConfirmSpawnInfo.Screen.luau` | Creates the map, connects the shared camera controller, and owns its lifecycle. |
| `src/StarterGui/Client/UI/Utils/ConfirmSpawnInfo.Screen.Utils.luau` | Projects and draws all OSM geometry into UI frames. |
| `src/StarterGui/Client/UI/Utils/PickSpawn.Screen.Utils.luau` | Shared drag, zoom, camera animation, and camera-bound logic. |

`ConfirmSpawnInfo:StartFunctions()` creates the renderer with
`osmApiReturnedData.chunk`, starts a `PickSpawnUtils.CreateMap` controller with
an empty tile manifest, then forwards `ViewChanged` camera events to the OSM
renderer. The empty manifest means the controller supplies only interaction;
the OSM vector renderer supplies the visual map.

## API payload shape

The location response wraps the actual map chunk:

```lua
local response = require(...OsmApiReturnedData)
local mapData = response.chunk
local location = response.location
```

The map chunk contains another `chunk` object with its local bounds:

```lua
mapData.chunk.minX
mapData.chunk.minZ
mapData.chunk.maxX
mapData.chunk.maxZ
mapData.origin.lat
mapData.origin.lon
```

Supported feature collections are:

| Collection | Geometry |
| --- | --- |
| `roads` | `points = { { x, y, z }, ... }` |
| `buildings` | `footprint = { { x, z }, ... }` |
| `water` | `polygons = { { { x, z }, ... }, ... }` |
| `landuse` | `polygons = { { { x, z }, ... }, ... }` |
| `pois` | `position = { x, y, z }` |

The renderer accepts both the wrapped response and a direct map chunk through
`getMapData`, but screen code should normally pass the map chunk explicitly.

## Coordinate projection

All rendering flows through `projectPoint` in
`ConfirmSpawnInfo.Screen.Utils.luau`.

The API provides local world coordinates. UI screen space has its Y axis
pointing down, while this map view's local Z direction must be mirrored:

```text
screenX = (worldX - minX) * scale
screenY = canvasHeight - (worldZ - minZ) * scale
```

`scale` is uniform for both axes. Do not independently scale X and Z to fit a
rectangular UI frame; that stretches the map.

The renderer uses a centered square `MapCanvas` inside the rectangular
`OsmMapLayer`. The canvas uses *cover* sizing:

```text
canvasSide = max(clipFrameWidth, clipFrameHeight)
```

The parent clips the excess axis. This fills the map UI while preserving the
chunk's 1:1 world scale. The alternative, `min(width, height)`, shows the full
chunk but letterboxes the map.

## Rendering order

Features are drawn from lowest to highest visual priority:

1. Water polygons
2. Land-use polygons
3. Building footprints
4. Road outlines
5. Road surfaces
6. Street-name labels
7. POI markers and labels
8. Spawn and chunk-boundary references

Polygon fills are implemented with scanlines because Roblox GUI does not have
a native arbitrary-polygon fill primitive. Polygon outlines and roads use thin
rotated `Frame` instances, one per line segment.

## Labels and markers

Named roads are grouped by name. The renderer finds the longest visible segment
for each road name and places one rotated label on it. This avoids repeating a
street name for every OSM way segment.

POIs are circular markers. Named POIs always receive a label.

The green `SPAWN` marker represents the local chunk origin associated with
`chunk.origin.lat/lon`. Yellow corner markers and a yellow outline represent
the `minX/minZ/maxX/maxZ` chunk boundary.

## Interaction

The UI does not implement a second drag/zoom system. It reuses the PickSpawn
controller:

```lua
local controller = PickSpawnUtils.CreateMap(...)
controller.ViewChanged:Connect(function(center, zoom, worldSize, zoomScale, zoomAnchor)
    renderer:SetCamera(center, zoom, worldSize, zoomScale, zoomAnchor)
end)
```

`ViewChanged` is emitted by `PickSpawnUtils.render`. It includes the camera
center, stable zoom, world pixel size, active tween zoom scale, and zoom anchor
so the OSM overlay follows the same drag and zoom motion as the tile map.

`DEBUG_ALLOW_UNBOUNDED_MAP_CAMERA` in `ConfirmSpawnInfo.Screen.luau` enables
the controller's `AllowUnboundedCamera` flag. It removes pan and zoom clamps
for renderer debugging only. Set it to `false` for normal player behavior.

## Lifecycle

`ConfirmSpawnInfo:StartFunctions()` destroys any prior renderer/controller,
creates the map layer and its controls, subscribes to `ViewChanged`, then
starts the controller.

`ConfirmSpawnInfo:StopFunctions()` disconnects the signal, stops the controller,
destroys the renderer and generated controls, and clears button effects.

## 3D renderer guidance

Reuse the data interpretation and coordinate conventions above when converting
the same chunk into Roblox instances:

- Convert a road point `{ x, y, z }` to `Vector3.new(x, y, z)` after applying
  the same chosen Z-axis convention everywhere.
- Build roads from consecutive points; each segment can become a rotated part,
  mesh, or generated terrain strip.
- Buildings use closed `footprint` polygons. Triangulate or otherwise fill
  them before extruding by `height` or `levels`.
- Water and land-use use polygon fills at a chosen terrain height.
- POIs should use their `position` coordinates and remain separate from road
  and building geometry.
- Keep chunk-boundary and spawn-origin helpers available in development builds;
  they are useful checks that UI and world projections agree.

The 3D implementation should share pure payload parsing and coordinate
conversion helpers with the UI renderer. It should not depend on GUI frame
creation, scanline filling, or `PickSpawnUtils` camera state.

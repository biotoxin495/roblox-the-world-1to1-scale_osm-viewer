--!strict

--[=[
	Reusable OSM adapter package.

	Implementation guide:
	- Generic map rendering pieces live in ReplicatedStorage.App.Shared.Packages.MapSystem.
	  OSMMap should interpret OSM data and wire game-specific OSM controllers to
	  those generic pieces.
	- PickSpawnMapController: interactive overview map with drag, wheel/button zoom,
	  visible-location signals, and map-point selection.
	- ChunkPreviewRenderer: 2D renderer for the OSM API chunk payload used by the
	  confirm-spawn screen. It follows the overview camera via SetCamera.
	- World3DRenderer: client-side 3D OSM chunk renderer for Workspace previews.
	- ReturnedDataSummary: small data utility for counts and density labels.
	- SimplifiedWorldInterpreter: converts simplified OSM world/country data into
	  generic raster operations.
	- OSMChunkInterpreter: reads OSM chunk payload shape and chunk coordinate
	  metadata for renderers.

	New game usage:
	local OSMMap = require(ReplicatedStorage.App.Shared.Packages.OSMMap)
	local map = OSMMap.PickSpawnMapController.CreateMap(...)
	map:Start()
]=]

return {
	PickSpawnMapController = require(script.PickSpawnMapController),
	ChunkPreviewRenderer = require(script.ChunkPreviewRenderer),
	World3DRenderer = require(script.World3DRenderer),
	ReturnedDataSummary = require(script.ReturnedDataSummary),
	SimplifiedWorldInterpreter = require(script.SimplifiedWorldInterpreter),
	OSMChunkInterpreter = require(script.OSMChunkInterpreter),
	EditableImageCanvas = require(script.EditableImageCanvas),
	EquirectangularProjection = require(script.EquirectangularProjection),
	MapInteraction = require(script.MapInteraction),
	ImplementationNotes = require(script.ImplementationNotes),
}

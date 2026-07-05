--!strict

--[=[
	How to replicate this package in another game:

	1. Copy ReplicatedStorage.App.Shared.Packages.MapSystem and OSMMap, plus the
	   shared Signal module dependency.
	2. Put your simplified country/land data under your game's config folder and
	   pass it into PickSpawnMapController.CreateMap.
	3. Build the UI layers in the consuming screen:
	   - ClipFrame clips and receives drag/wheel input.
	   - BaseTileLayer receives the world image tiles.
	   - PinLayer receives generated location buttons.
	   - ZoomInButton and ZoomOutButton call the packaged zoom behavior.
	4. Subscribe to controller signals instead of editing the package:
	   - VisibleLocationsChanged updates side-panel lists.
	   - MapScaleChanged updates scale labels.
	   - MapPointSelected opens manual-coordinate flows.
	   - ViewChanged can drive ChunkPreviewRenderer.SetCamera for minimaps.
	5. Keep game-specific UI, popups, network calls, and spawn decisions in your
	   screen/controller code. The package should stay map/render/input focused.

	Where behaviour lives:
	- MapSystem owns context-agnostic canvas, primitives, layers, projections, and
	  drag/zoom input binding.
	- OSMMap owns OSM-specific interpreters and controllers.
	- SimplifiedWorldInterpreter converts simplified OSM vectors into generic
	  MapSystem raster operations.
	- OSMChunkInterpreter reads live OSM chunk payload shape and metadata.
	- PickSpawnMapController owns spawn-map camera state, animation, pins, and
	  signals.
]=]

return {
	PackageName = "OSMMap",
	EntryPoint = "ReplicatedStorage.App.Shared.Packages.OSMMap",
	GenericMapSystem = "ReplicatedStorage.App.Shared.Packages.MapSystem",
	PrimaryModules = {
		"PickSpawnMapController",
		"ChunkPreviewRenderer",
		"World3DRenderer",
		"ReturnedDataSummary",
		"SimplifiedWorldInterpreter",
		"OSMChunkInterpreter",
		"EditableImageCanvas",
		"EquirectangularProjection",
		"MapInteraction",
	},
}

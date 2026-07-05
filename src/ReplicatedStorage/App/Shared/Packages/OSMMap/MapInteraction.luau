--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapSystem = ReplicatedStorage.App.Shared.Packages.MapSystem
local DragZoomInteraction = require(MapSystem.DragZoomInteraction)
local EquirectangularProjection = require(MapSystem.EquirectangularProjection)

local MapInteraction = {}

export type Options = DragZoomInteraction.Options

function MapInteraction.Bind(controller: any, options: Options)
	DragZoomInteraction.Bind(controller, {
		ClickDragThreshold = options.ClickDragThreshold,
		ButtonZoomStep = options.ButtonZoomStep,
		WheelZoomStep = options.WheelZoomStep,
		ScreenPointToMapPoint = function(targetController, screenPoint)
			local mapPosition = targetController:screenToMap(screenPoint, targetController.Zoom)
			return Vector2.new(math.clamp(mapPosition.X, 0, 1), math.clamp(mapPosition.Y, 0, 1))
		end,
		MapPointSelected = function(targetController, mapPosition)
			local latitude, longitude = EquirectangularProjection.MapToLatLon(mapPosition)
			targetController.MapPointSelected:Fire(mapPosition, latitude, longitude)
		end,
		ShouldIgnoreClick = function(targetController, inputPosition)
			return targetController:isPointerOverPin(inputPosition)
		end,
	})
end

return MapInteraction

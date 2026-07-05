--!strict

-- Context-agnostic pointer drag, click-select, mouse-wheel zoom, and zoom-button
-- binding for map controllers. The controller supplies projection callbacks.

local UserInputService = game:GetService("UserInputService")

local DragZoomInteraction = {}

export type Options = {
	ClickDragThreshold: number,
	ButtonZoomStep: number,
	WheelZoomStep: number,
	ScreenPointToMapPoint: (controller: any, screenPoint: Vector2) -> Vector2,
	MapPointSelected: (controller: any, mapPoint: Vector2) -> (),
	ShouldIgnoreClick: ((controller: any, inputPosition: Vector3) -> boolean)?,
}

local function isInsideRect(position: Vector2, rectPosition: Vector2, rectSize: Vector2): boolean
	return position.X >= rectPosition.X
		and position.Y >= rectPosition.Y
		and position.X <= rectPosition.X + rectSize.X
		and position.Y <= rectPosition.Y + rectSize.Y
end

function DragZoomInteraction.Bind(controller: any, options: Options)
	local function cancelPointerInteraction()
		local wasDragging = controller.IsDragging
		controller.IsPointerDown = false
		controller.IsDragging = false
		controller.PointerDownPosition = nil
		controller.LastDragPosition = nil

		if wasDragging then
			controller.MapDragEnded:Fire(false)
		end
	end

	table.insert(controller.Connections, controller.ClipFrame.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if not controller.IsInputEnabled() or controller.IsPointerDown then
			return
		end

		controller:cancelCameraAnimation(true)
		controller.IsPointerDown = true
		controller.IsDragging = false
		controller.PointerDownPosition = input.Position
		controller.LastDragPosition = input.Position
	end))

	table.insert(controller.Connections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not controller.IsPointerDown then
			return
		end

		local wasDragging = controller.IsDragging
		cancelPointerInteraction()

		local shouldIgnoreClick = options.ShouldIgnoreClick
		if
			not controller.IsInputEnabled()
			or wasDragging
			or (shouldIgnoreClick and shouldIgnoreClick(controller, input.Position))
		then
			return
		end

		local localScreenPosition = Vector2.new(input.Position.X, input.Position.Y) - controller.ClipFrame.AbsolutePosition
		options.MapPointSelected(controller, options.ScreenPointToMapPoint(controller, localScreenPosition))
	end))

	table.insert(controller.Connections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseMovement
			and controller.IsPointerDown
			and controller.PointerDownPosition
		then
			if not controller.IsInputEnabled() then
				cancelPointerInteraction()
				return
			end

			if not controller.IsDragging then
				local totalDelta = input.Position - controller.PointerDownPosition
				if totalDelta.Magnitude < options.ClickDragThreshold then
					return
				end

				controller.IsDragging = true
				controller.MapDragStarted:Fire(true)
				controller:panByScreenDelta(totalDelta)
			else
				local delta = input.Position - (controller.LastDragPosition or input.Position)
				controller:panByScreenDelta(delta)
			end
			controller.LastDragPosition = input.Position
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and controller.IsInputEnabled() then
			local mousePosition = UserInputService:GetMouseLocation()
			local insideMap = isInsideRect(mousePosition, controller.ClipFrame.AbsolutePosition, controller.ClipFrame.AbsoluteSize)
			local overZoomExclusionRegion = isInsideRect(
				mousePosition,
				controller.ZoomExclusionRegion.AbsolutePosition,
				controller.ZoomExclusionRegion.AbsoluteSize
			)

			if insideMap and not overZoomExclusionRegion then
				controller:zoomBy((if input.Position.Z > 0 then 1 else -1) * options.WheelZoomStep, mousePosition)
			end
		end
	end))

	table.insert(controller.Connections, controller.ZoomInButton.MouseButton1Click:Connect(function()
		if controller.IsInputEnabled() then
			controller:zoomBy(options.ButtonZoomStep)
		end
	end))
	table.insert(controller.Connections, controller.ZoomOutButton.MouseButton1Click:Connect(function()
		if controller.IsInputEnabled() then
			controller:zoomBy(-options.ButtonZoomStep)
		end
	end))
	table.insert(controller.Connections, controller.ClipFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		controller:queueRender()
	end))
end

return DragZoomInteraction

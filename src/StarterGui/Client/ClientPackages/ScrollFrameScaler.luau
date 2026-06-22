--[[
	ScrollFrame Sizing ScrollFrameScaler
	
	Automatically adjusts the CanvasSize of a ScrollingFrame to fit its contents.
	Supports:
	- UIListLayout (Vertical, Horizontal, and Wrapping)
	- UIGridLayout
	- UIPadding
	- Absolute positioned elements (no layout)
	
	Handles dynamic changes to children (add/remove/resize) and the scroll frame itself.
	
	Usage:
	local ScrollUtil = require(path.to.this.ScrollFrameScaler)
	
	-- To start managing a scroll frame:
	ScrollUtil:StartScrollHandling(myScrollingFrame, "Y") -- For vertical scrolling
	
	-- To stop managing it and prevent memory leaks:
	ScrollUtil:StopScrollHandling(myScrollingFrame)
]]

local TweenService = game:GetService("TweenService")

local ScrollFrameScaler = {}
ScrollFrameScaler.__index = ScrollFrameScaler
ScrollFrameScaler.ServiceName = "ScrollFrameScaler"

-- Private table to store connections for each managed ScrollingFrame
local connections = {}

-- Debounce settings to prevent spamming updates from rapid size changes
local DEBOUNCE_TIME = 0.05 -- 50ms is usually sufficient
local childDebounceTimes = {}
local DEBUG_MIN_INTERVAL = 0.2
local MAX_DEBUG_CHILDREN = 20

local function getDebugState(scroll: ScrollingFrame)
	local entry = connections[scroll]
	return entry and entry.debug or nil
end

local function debugLog(scroll: ScrollingFrame, message: string)
	local debugState = getDebugState(scroll)
	if not debugState or not debugState.enabled then
		return
	end

	local now = tick()
	local minInterval = debugState.minInterval or DEBUG_MIN_INTERVAL
	if minInterval > 0 and now - debugState.lastLog < minInterval then
		return
	end

	debugState.lastLog = now
	local tag = debugState.tag or scroll.Name
	print(string.format("[ScrollFrameScaler:%s] %s", tag, message))
end

local function debugLogVerbose(scroll: ScrollingFrame, message: string)
	local debugState = getDebugState(scroll)
	if not debugState or not debugState.enabled or not debugState.verbose then
		return
	end

	local tag = debugState.tag or scroll.Name
	print(string.format("[ScrollFrameScaler:%s] %s", tag, message))
end

-- ============================================= --
--        PRIVATE: SIZE CALCULATION HELPERS      --
-- ============================================= --

-- Filters and sorts children to be included in the calculation
local function getRelevantChildren(scroll: ScrollingFrame): { GuiObject }
	local childrenToProcess = {}
	for _, child in ipairs(scroll:GetChildren()) do
		-- Only consider visible GUI elements that can be laid out
		if child:IsA("GuiObject") and child.Visible then
			table.insert(childrenToProcess, child)
		end
	end

	-- Sort by LayoutOrder, which is essential for UIListLayout and UIGridLayout
	table.sort(childrenToProcess, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)

	return childrenToProcess
end

-- Calculates size for a non-wrapping UIListLayout
local function _calculateSize_UIListLayout(
	children: { GuiObject },
	layout: UIListLayout,
	debugVerbose: boolean
): (number, number, { [string]: any })
	local totalWidth, totalHeight = 0, 0
	if #children == 0 then
		return 0, 0, { kind = "UIListLayout", children = 0, paddingOffset = layout.Padding.Offset }
	end

	local padding = layout.Padding

	if layout.FillDirection == Enum.FillDirection.Vertical then
		local maxHeight = 0
		local maxWidth = 0
		for _, child in ipairs(children) do
			maxHeight += child.AbsoluteSize.Y
			maxWidth = math.max(maxWidth, child.AbsoluteSize.X)
		end
		totalHeight = maxHeight + padding.Offset * (#children - 1)
		totalWidth = maxWidth
	else -- Horizontal
		local maxWidth = 0
		local maxHeight = 0
		for _, child in ipairs(children) do
			maxWidth += child.AbsoluteSize.X
			maxHeight = math.max(maxHeight, child.AbsoluteSize.Y)
		end
		totalWidth = maxWidth + padding.Offset * (#children - 1)
		totalHeight = maxHeight
	end

	local details = {
		kind = "UIListLayout",
		children = #children,
		fillDirection = layout.FillDirection.Name,
		paddingOffset = padding.Offset,
		totalWidth = totalWidth,
		totalHeight = totalHeight,
	}

	if debugVerbose then
		local childSummary = {}
		for i, child in ipairs(children) do
			if i > MAX_DEBUG_CHILDREN then
				break
			end
			table.insert(
				childSummary,
				string.format("%s#%d(%d,%d)", child.Name, child.LayoutOrder, child.AbsoluteSize.X, child.AbsoluteSize.Y)
			)
		end
		details.childSummary = childSummary
		details.childTotal = #children
	end

	return totalWidth, totalHeight, details
end

-- Calculates size for a wrapping UIListLayout
local function _calculateSize_UIListLayout_Wrapped(
	children: { GuiObject },
	layout: UIListLayout,
	availableWidth: number,
	debugVerbose: boolean
): (number, number, { [string]: any })
	if #children == 0 or availableWidth <= 0 then
		return 0, 0, { kind = "UIListLayout.Wraps", children = #children, availableWidth = availableWidth }
	end

	local padding = layout.Padding.Offset
	local totalHeight = 0

	local currentRowWidth = 0
	local currentRowMaxHeight = 0
	local isFirstInRow = true
	local rowCount = 1
	local maxRowWidth = 0
	local rows = {}
	local rowChildCount = 0
	local childSummary = {}

	for i, child in ipairs(children) do
		local childSize = child.AbsoluteSize
		local widthToAdd = (isFirstInRow and 0 or padding) + childSize.X

		if currentRowWidth + widthToAdd > availableWidth and not isFirstInRow then
			-- Current row is full, finalize it and start a new one
			totalHeight += currentRowMaxHeight + padding
			maxRowWidth = math.max(maxRowWidth, currentRowWidth)
			table.insert(rows, {
				width = currentRowWidth,
				height = currentRowMaxHeight,
				count = rowChildCount,
			})

			-- Start the new row with the current child
			currentRowWidth = childSize.X
			currentRowMaxHeight = childSize.Y
			isFirstInRow = false
			rowChildCount = 0
			rowCount += 1
		else
			-- Add to the current row
			currentRowWidth += widthToAdd
			currentRowMaxHeight = math.max(currentRowMaxHeight, childSize.Y)
			isFirstInRow = false
		end

		rowChildCount += 1
		if debugVerbose and i <= MAX_DEBUG_CHILDREN then
			table.insert(
				childSummary,
				string.format("%s#%d row=%d(%d,%d)", child.Name, child.LayoutOrder, rowCount, childSize.X, childSize.Y)
			)
		end
	end

	-- Add the height of the last row
	maxRowWidth = math.max(maxRowWidth, currentRowWidth)
	totalHeight += currentRowMaxHeight
	table.insert(rows, {
		width = currentRowWidth,
		height = currentRowMaxHeight,
		count = rowChildCount,
	})

	-- The width is just the available space, as it wraps.
	local details = {
		kind = "UIListLayout.Wraps",
		children = #children,
		availableWidth = availableWidth,
		paddingOffset = padding,
		rowCount = rowCount,
		maxRowWidth = maxRowWidth,
		totalHeight = totalHeight,
		rows = rows,
	}

	if debugVerbose then
		details.childSummary = childSummary
		details.childTotal = #children
	end

	return availableWidth, totalHeight, details
end

-- Calculates size for a UIGridLayout
local function _calculateSize_UIGridLayout(
	children: { GuiObject },
	layout: UIGridLayout,
	availableWidth: number,
	debugVerbose: boolean
): (number, number, { [string]: any })
	if #children == 0 or availableWidth <= 0 then
		return 0, 0, { kind = "UIGridLayout", children = #children, availableWidth = availableWidth }
	end

	local cellSize = layout.CellSize
	local cellPadding = layout.CellPadding

	-- We must use absolute pixel values for this calculation
	local cellWidth = cellSize.X.Offset
	local cellPaddingX = cellPadding.X.Offset

	local itemsPerRow = math.floor((availableWidth + cellPaddingX) / (cellWidth + cellPaddingX))
	itemsPerRow = math.max(1, itemsPerRow) -- Must have at least one column

	local numRows = math.ceil(#children / itemsPerRow)

	local totalHeight = (numRows * layout.CellSize.Y.Offset) + (math.max(0, numRows - 1) * layout.CellPadding.Y.Offset)
	local totalWidth = (itemsPerRow * cellWidth) + (math.max(0, itemsPerRow - 1) * cellPaddingX)

	local details = {
		kind = "UIGridLayout",
		children = #children,
		availableWidth = availableWidth,
		itemsPerRow = itemsPerRow,
		numRows = numRows,
		cellWidth = cellWidth,
		cellHeight = layout.CellSize.Y.Offset,
		cellPaddingX = cellPaddingX,
		cellPaddingY = layout.CellPadding.Y.Offset,
		totalWidth = totalWidth,
		totalHeight = totalHeight,
	}

	if debugVerbose then
		local childSummary = {}
		for i, child in ipairs(children) do
			if i > MAX_DEBUG_CHILDREN then
				break
			end
			table.insert(
				childSummary,
				string.format("%s#%d(%d,%d)", child.Name, child.LayoutOrder, child.AbsoluteSize.X, child.AbsoluteSize.Y)
			)
		end
		details.childSummary = childSummary
		details.childTotal = #children
	end

	return totalWidth, totalHeight, details
end

-- Calculates size by finding the maximum bounds of all children (used when no layout is present)
local function _calculateSize_Absolute(
	children: { GuiObject },
	debugVerbose: boolean
): (number, number, { [string]: any })
	local maxX, maxY = 0, 0
	for _, child in ipairs(children) do
		maxX = math.max(maxX, child.AbsolutePosition.X + child.AbsoluteSize.X)
		maxY = math.max(maxY, child.AbsolutePosition.Y + child.AbsoluteSize.Y)
	end
	local details = { kind = "Absolute", children = #children, maxX = maxX, maxY = maxY }

	if debugVerbose then
		local childSummary = {}
		for i, child in ipairs(children) do
			if i > MAX_DEBUG_CHILDREN then
				break
			end
			table.insert(
				childSummary,
				string.format(
					"%s#%d pos=(%d,%d) size=(%d,%d)",
					child.Name,
					child.LayoutOrder,
					child.AbsolutePosition.X,
					child.AbsolutePosition.Y,
					child.AbsoluteSize.X,
					child.AbsoluteSize.Y
				)
			)
		end
		details.childSummary = childSummary
		details.childTotal = #children
	end

	return maxX, maxY, details
end

local function formatDebugDetails(details: { [string]: any }?)
	if not details then
		return "details=none"
	end

	local kind = details.kind or "Unknown"
	if kind == "UIListLayout" then
		return string.format(
			"details=list dir=%s padding=%.2f total=(%.2f,%.2f)",
			details.fillDirection or "?",
			details.paddingOffset or 0,
			details.totalWidth or 0,
			details.totalHeight or 0
		)
	elseif kind == "UIListLayout.Wraps" then
		return string.format(
			"details=wrap rows=%d maxRowW=%.2f padding=%.2f totalH=%.2f",
			details.rowCount or 0,
			details.maxRowWidth or 0,
			details.paddingOffset or 0,
			details.totalHeight or 0
		)
	elseif kind == "UIGridLayout" then
		return string.format(
			"details=grid perRow=%d rows=%d cell=(%.2f,%.2f) pad=(%.2f,%.2f) total=(%.2f,%.2f)",
			details.itemsPerRow or 0,
			details.numRows or 0,
			details.cellWidth or 0,
			details.cellHeight or 0,
			details.cellPaddingX or 0,
			details.cellPaddingY or 0,
			details.totalWidth or 0,
			details.totalHeight or 0
		)
	elseif kind == "Absolute" then
		return string.format("details=absolute max=(%.2f,%.2f)", details.maxX or 0, details.maxY or 0)
	end

	return string.format("details=%s", kind)
end

local function formatChildSummary(details: { [string]: any }?)
	if not details or not details.childSummary then
		return nil
	end

	local text = table.concat(details.childSummary, ", ")
	if details.childTotal and details.childTotal > #details.childSummary then
		text = text .. string.format(" ...(+%d)", details.childTotal - #details.childSummary)
	end

	return text
end

local function formatRowSummary(details: { [string]: any }?)
	if not details or not details.rows then
		return nil
	end

	local parts = {}
	local maxRowsToShow = 10
	for i, row in ipairs(details.rows) do
		if i > maxRowsToShow then
			break
		end
		table.insert(parts, string.format("#%d w=%.2f h=%.2f n=%d", i, row.width, row.height, row.count))
	end
	local text = table.concat(parts, " | ")
	if #details.rows > maxRowsToShow then
		text = text .. string.format(" ...(+%d)", #details.rows - maxRowsToShow)
	end

	return text
end

-- ============================================= --
--          PUBLIC: ScrollFrameScaler FUNCTIONS             --
-- ============================================= --

--- Core function to recalculate and apply the new CanvasSize.
-- @param scroll The ScrollingFrame to update.
-- @param axis A string containing "X" and/or "Y" to indicate which axes to size.
-- @param isInitialLoad A boolean to prevent resetting scroll position on first load.
function ScrollFrameScaler:UpdateScrollFrame(scroll: ScrollingFrame, axis: string, isInitialLoad: boolean)
	if not scroll or not scroll:IsA("ScrollingFrame") then
		return
	end

	-- Store previous position to restore it later, preventing scroll jumps
	local prevCanvasPos = scroll.CanvasPosition

	-- Determine which axes to update
	local doX = string.find(axis, "X")
	local doY = string.find(axis, "Y")

	local children = getRelevantChildren(scroll)
	local padding = scroll:FindFirstChildOfClass("UIPadding")
	local debugState = getDebugState(scroll)
	local debugVerbose = debugState and debugState.verbose or false

	-- Find a layout object
	local uiListLayout = scroll:FindFirstChildOfClass("UIListLayout")
	local uiGridLayout = scroll:FindFirstChildOfClass("UIGridLayout")

	local contentWidth, contentHeight = 0, 0
	local debugDetails = nil
	local availableWidth = scroll.AbsoluteSize.X
		- (padding and (padding.PaddingLeft.Offset + padding.PaddingRight.Offset) or 0)
	local layoutKind = "None"

	-- Calculate content size based on the layout found
	if uiGridLayout then
		layoutKind = "UIGridLayout"
		contentWidth, contentHeight, debugDetails =
			_calculateSize_UIGridLayout(children, uiGridLayout, availableWidth, debugVerbose)
	elseif uiListLayout then
		layoutKind = "UIListLayout"
		if uiListLayout.Wraps then
			layoutKind = "UIListLayout.Wraps"
			contentWidth, contentHeight, debugDetails =
				_calculateSize_UIListLayout_Wrapped(children, uiListLayout, availableWidth, debugVerbose)
		else
			contentWidth, contentHeight, debugDetails =
				_calculateSize_UIListLayout(children, uiListLayout, debugVerbose)
		end
	else
		-- No layout, calculate based on absolute positions and sizes (bounding box)
		-- This is less common but good to support.
		local scrollAbsPos = scroll.AbsolutePosition
		local maxChildX, maxChildY
		maxChildX, maxChildY, debugDetails = _calculateSize_Absolute(children, debugVerbose)
		contentWidth = maxChildX - scrollAbsPos.X
		contentHeight = maxChildY - scrollAbsPos.Y
	end

	-- Add padding from UIPadding to the final canvas size
	local totalPaddingX = 0
	local totalPaddingY = 0
	if padding then
		totalPaddingY = padding.PaddingTop.Offset + padding.PaddingBottom.Offset
		totalPaddingX = padding.PaddingLeft.Offset + padding.PaddingRight.Offset
	end

	local finalWidth = contentWidth + totalPaddingX
	local finalHeight = contentHeight + totalPaddingY
	local previousCanvasSize = scroll.CanvasSize

	-- Create the new CanvasSize UDim2, only using the calculated values for the specified axes.
	-- If an axis is not specified, it defaults to 0 scale, 0 offset (effectively unconstrained).
	scroll.CanvasSize = UDim2.new(
		0,
		doX and finalWidth or scroll.CanvasSize.X.Offset,
		0,
		doY and finalHeight or scroll.CanvasSize.Y.Offset
	)

	debugLog(
		scroll,
		string.format(
			"axis=%s layout=%s children=%d availableW=%.2f content=(%.2f,%.2f) padding=(%.2f,%.2f) final=(%.2f,%.2f) prevCanvas=(%d,%d) newCanvas=(%d,%d) %s",
			axis,
			layoutKind,
			#children,
			availableWidth,
			contentWidth,
			contentHeight,
			totalPaddingX,
			totalPaddingY,
			finalWidth,
			finalHeight,
			previousCanvasSize.X.Offset,
			previousCanvasSize.Y.Offset,
			scroll.CanvasSize.X.Offset,
			scroll.CanvasSize.Y.Offset,
			formatDebugDetails(debugDetails)
		)
	)

	local childSummary = formatChildSummary(debugDetails)
	if childSummary then
		debugLogVerbose(scroll, "children: " .. childSummary)
	end

	local rowSummary = formatRowSummary(debugDetails)
	if rowSummary then
		debugLogVerbose(scroll, "rows: " .. rowSummary)
	end

	-- Restore the scroll position unless it's the very first time this is running
	if not isInitialLoad then
		scroll.CanvasPosition = prevCanvasPos
	end
end

--- Starts the automatic management of a ScrollingFrame.
-- Sets up all necessary connections to listen for changes.
-- @param scroll The ScrollingFrame to manage.
-- @param axis A string containing "X" and/or "Y".
function ScrollFrameScaler:StartScrollHandling(
	scroll: ScrollingFrame,
	axis: string,
	options: {
		debug: boolean?,
		debugTag: string?,
		debugVerbose: boolean?,
		debugMinInterval: number?,
	}?
)
	if not scroll then
		return
	end

	-- Stop any previous handling to prevent duplicate connections
	ScrollFrameScaler:StopScrollHandling(scroll)

	-- Initialize storage for this scroll frame's connections
	connections[scroll] = {
		static = {},
		children = {},
		debug = {
			enabled = options and options.debug or false,
			tag = options and options.debugTag or nil,
			verbose = options and options.debugVerbose or false,
			minInterval = options and options.debugMinInterval or nil,
			lastLog = 0,
		},
	}

	-- Helper to set up listeners for a single child
	local function setupChild(child: GuiObject)
		if not child:IsA("GuiObject") then
			return
		end

		-- Listen for size changes on the child
		local conn = child:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			local now = tick()
			if not childDebounceTimes[child] or now - childDebounceTimes[child] > DEBOUNCE_TIME then
				childDebounceTimes[child] = now
				self:UpdateScrollFrame(scroll, axis, false)
			end
		end)
		local visibleChangedConn = child:GetPropertyChangedSignal("Visible"):Connect(function()
			if child.Visible then
				self:UpdateScrollFrame(scroll, axis, false)
			end
		end)
		connections[scroll].children[child] = { conn, visibleChangedConn }
	end

	-- 1. Listen for children being added or removed from the scroll frame
	table.insert(
		connections[scroll].static,
		scroll.ChildAdded:Connect(function(child)
			setupChild(child)
			self:UpdateScrollFrame(scroll, axis, false)
		end)
	)

	table.insert(
		connections[scroll].static,
		scroll.ChildRemoved:Connect(function(child)
			-- Clean up the connections for the removed child
			if connections[scroll] and connections[scroll].children[child] then
				for _, conn in ipairs(connections[scroll].children[child]) do
					conn:Disconnect()
				end
				connections[scroll].children[child] = nil
				childDebounceTimes[child] = nil -- Clear debounce timer
			end
			self:UpdateScrollFrame(scroll, axis, false)
		end)
	)

	-- 2. Listen for changes to the scroll frame's own size (e.g., window resize)
	table.insert(
		connections[scroll].static,
		scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:UpdateScrollFrame(scroll, axis, false)
		end)
	)

	-- 3. Setup listeners for all existing children
	for _, child in ipairs(scroll:GetChildren()) do
		setupChild(child)
	end

	-- 4. Perform the initial size calculation
	self:UpdateScrollFrame(scroll, axis, true)
end

--- Stops managing a ScrollingFrame and disconnects all associated event listeners.
-- Crucial for preventing memory leaks when the UI is destroyed.
-- @param scroll The ScrollingFrame to stop managing.
function ScrollFrameScaler:StopScrollHandling(scroll: ScrollingFrame)
	local conns = connections[scroll]
	if not conns then
		return
	end

	-- Disconnect static connections (ChildAdded/Removed, etc.)
	for _, conn in ipairs(conns.static) do
		conn:Disconnect()
	end

	-- Disconnect all individual child connections
	for child, childConnections in pairs(conns.children) do
		for _, conn in ipairs(childConnections) do
			conn:Disconnect()
		end
		childDebounceTimes[child] = nil
	end

	-- Remove the entry from the main connections table
	connections[scroll] = nil
end

function ScrollFrameScaler:InScrollFrameFocusOnObject(
	scrollFrame: ScrollingFrame,
	object: GuiObject,
	options: {
		tweenInfo: TweenInfo?,
		focusAlignment: Enum.VerticalAlignment?,
		forceScroll: boolean?,
	}?
)
	-- 1. VALIDATION AND DEFAULTS --
	if not scrollFrame or not object or not object:IsDescendantOf(scrollFrame) then
		warn("Scroll target is invalid or not a descendant of the ScrollingFrame.")
		return
	end

	local focusOptions = options
		or {} :: {
			tweenInfo: TweenInfo?,
			focusAlignment: Enum.VerticalAlignment?,
			forceScroll: boolean?,
		}
	local tweenInfo = focusOptions.tweenInfo or TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local alignment = focusOptions.focusAlignment or Enum.VerticalAlignment.Center
	local forceScroll = focusOptions.forceScroll or false

	-- 2. GATHER NECESSARY DATA --
	-- The size of the visible "window"
	local viewportSize = scrollFrame.AbsoluteSize
	-- The current top-left of the visible window, in canvas pixels
	local currentCanvasPos = scrollFrame.CanvasPosition
	-- The total size of the scrollable content area
	local canvasSize = scrollFrame.CanvasSize

	-- The object's position and size relative to the canvas's top-left corner.
	-- We must use AbsolutePosition and subtract the scrollFrame's origin to get the true
	-- position on the canvas, as `object.Position` might be relative to a parent Frame within the SF.
	local objectPos = object.AbsolutePosition - scrollFrame.AbsolutePosition + currentCanvasPos
	local objectSize = object.AbsoluteSize

	-- 3. CHECK IF ALREADY VISIBLE --
	if not forceScroll then
		local isVisibleX = (objectPos.X >= currentCanvasPos.X)
			and (objectPos.X + objectSize.X <= currentCanvasPos.X + viewportSize.X)
		local isVisibleY = (objectPos.Y >= currentCanvasPos.Y)
			and (objectPos.Y + objectSize.Y <= currentCanvasPos.Y + viewportSize.Y)

		if isVisibleX and isVisibleY then
			-- Object is already fully in view, no need to scroll.
			return
		end
	end

	-- 4. CALCULATE TARGET CANVAS POSITION --
	local targetX = currentCanvasPos.X
	local targetY = currentCanvasPos.Y

	-- Calculate Vertical (Y) Target
	if alignment == Enum.VerticalAlignment.Top then
		-- Align the top of the object with the top of the viewport
		targetY = objectPos.Y
	elseif alignment == Enum.VerticalAlignment.Center then
		-- Center the object in the viewport
		targetY = objectPos.Y - (viewportSize.Y / 2) + (objectSize.Y / 2)
	elseif alignment == Enum.VerticalAlignment.Bottom then
		-- Align the bottom of the object with the bottom of the viewport
		targetY = objectPos.Y - viewportSize.Y + objectSize.Y
	end

	-- Note: The same logic can be applied to HorizontalAlignment if needed.
	-- For this example, we'll keep horizontal scrolling simple (align to left edge if out of view).
	if
		not (
			(objectPos.X >= currentCanvasPos.X) and (objectPos.X + objectSize.X <= currentCanvasPos.X + viewportSize.X)
		)
	then
		targetX = objectPos.X
	end

	-- 5. CLAMP THE TARGET POSITION TO AVOID SCROLLING BEYOND BOUNDS --
	-- Calculate the maximum possible scroll values
	local maxScrollX = math.max(0, canvasSize.X.Offset - viewportSize.X)
	local maxScrollY = math.max(0, canvasSize.Y.Offset - viewportSize.Y)

	targetX = math.clamp(targetX, 0, maxScrollX)
	targetY = math.clamp(targetY, 0, maxScrollY)

	local targetPosition = Vector2.new(targetX, targetY)

	-- 6. PERFORM THE SCROLL --
	local tween = TweenService:Create(scrollFrame, tweenInfo, { CanvasPosition = targetPosition })
	tween:Play()
end

-- function ScrollFrameScaler:FocusOnObjectInScrollFrame(scrollFrame:ScrollingFrame,object:Frame,animate)
-- 	local objectAbsolutePos = object.AbsolutePosition
-- 	local scrollFrameAbsolutePos = scrollFrame.AbsolutePosition

-- 	-- Calculate the relative position of the object within the ScrollingFrame
-- 	local relativePos = objectAbsolutePos - scrollFrameAbsolutePos

-- 	-- Get the size of the visible area of the ScrollingFrame
-- 	local visibleAreaSize = scrollFrame.AbsoluteSize

-- 	-- Get the size of the object
-- 	local objectSize = object.AbsoluteSize

-- 	-- Calculate the new CanvasPosition to center the object
-- 	local newCanvasPosX = relativePos.X + (objectSize.X / 2) - (visibleAreaSize.X / 2)
-- 	local newCanvasPosY = relativePos.Y + (objectSize.Y / 2) - (visibleAreaSize.Y / 2)

-- 	-- Set the ScrollingFrame's CanvasPosition

-- 	--scrollFrame.ScrollingEnabled = false
-- 	local goal = {}
-- 	goal.CanvasPosition = Vector2.new(newCanvasPosX, newCanvasPosY)
-- 	local tweenTime = 0
-- 	if animate then
-- 		tweenTime = 0.3
-- 	end
-- 	local tween = tweenService:Create(scrollFrame,TweenInfo.new(tweenTime,Enum.EasingStyle.Quad),goal)
-- 	tween:Play()
-- 	tween.Completed:Wait()
-- 	tween:Destroy()
-- 	--scrollFrame.ScrollingEnabled = true
-- end

return ScrollFrameScaler

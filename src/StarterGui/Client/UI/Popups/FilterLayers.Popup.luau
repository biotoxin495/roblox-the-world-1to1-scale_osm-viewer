local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)
local ScrollFrameScaler = require(script.Parent.Parent.Parent.ClientPackages.ScrollFrameScaler)

local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local UIRoot = require(script.Parent.Parent.UIRoot)

local FilterLayersPopup = {}
FilterLayersPopup.__index = FilterLayersPopup
FilterLayersPopup.Name = "FilterLayersPopup"

local connections = {} :: { RBXScriptConnection }
local createdFilterFrames = {} :: { Instance }

local listOfFilters = {
	"Roads",
	"Buildings",
	"Water",
	"Landuse",
	"POIs",
	"Trees",
	"Chunk Boundaries",
}

local filterKeys = {
	Roads = "Roads",
	Buildings = "Buildings",
	Water = "Water",
	Landuse = "Landuse",
	POIs = "Pois",
	Trees = "Trees",
	["Chunk Boundaries"] = "Boundaries",
}

local function setFilterAppearance(button: GuiButton, enabled: boolean)
	print("[OSM] Setting filter appearance for button:", button, "Enabled:", enabled)
	button:SetAttribute("Enabled", enabled)
	-- button.BackgroundTransparency = if enabled then 0 else 0.55

	-- local indicator = button:FindFirstChild("Checkmark", true)
	-- 	or button:FindFirstChild("Check", true)
	-- 	or button:FindFirstChild("Enabled", true)
	-- if indicator and indicator:IsA("GuiObject") then
	-- 	indicator.Visible = enabled
	-- end

	-- local status = button:FindFirstChild("Status", true)
	-- if status and status:IsA("TextLabel") then
	-- 	status.Text = if enabled then "ON" else "OFF"
	-- end

	local Box = button.Box

	if enabled then
		Box.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
	else
		Box.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
	end
end

function FilterLayersPopup:StartFunctions(parseData)
	local popupFrame = UIRoot.GetPopups():WaitForChild("FilterLayers")

	local BackButton = popupFrame.TopHolder.BackButton

	local BackButtonEffects = {
		OnMouseEnter = {
			[BackButton.Icon] = {
				ImageColor3 = Color3.fromRGB(217, 217, 217):Lerp(Color3.fromRGB(255, 255, 255), 0.2),
			},
		},
		OnClickStart = {
			[BackButton.Icon] = {
				ImageColor3 = Color3.fromRGB(217, 217, 217):Lerp(Color3.fromRGB(255, 255, 255), 0.4),
			},
		},
	}
	GuiButtonEffects:Setup(BackButton, BackButtonEffects)

	table.insert(
		connections,
		BackButton.Activated:Connect(function()
			print("BackButton activated, closing popup")
			UIController:ClosePopup()
		end)
	)

	local scrollFrame = popupFrame.LayersList
	local layerVisibility = if type(parseData) == "table" and type(parseData.LayerVisibility) == "table"
		then parseData.LayerVisibility
		else {
			Roads = true,
			Buildings = true,
			Water = true,
			Landuse = true,
			Pois = true,
			Trees = true,
			Boundaries = true,
		}
	local onLayerVisibilityChanged = if type(parseData) == "table"
			and type(parseData.OnLayerVisibilityChanged) == "function"
		then parseData.OnLayerVisibilityChanged
		else nil

	for i, filterType in pairs(listOfFilters) do
		local clone = popupFrame.Examples.ExampleFilter:Clone()
		clone.Name = filterType
		clone.Visible = true
		clone.InfoText.Text = filterType
		clone.Parent = popupFrame.LayersList
		table.insert(createdFilterFrames, clone)
		local layerKey = filterKeys[filterType]
		local enabled = layerVisibility[layerKey] ~= false
		setFilterAppearance(clone, enabled)

		table.insert(
			connections,
			clone.Activated:Connect(function()
				local nextEnabled = layerVisibility[layerKey] == false
				layerVisibility[layerKey] = nextEnabled
				setFilterAppearance(clone, nextEnabled)
				if onLayerVisibilityChanged then
					onLayerVisibilityChanged(layerVisibility)
				end
			end)
		)
	end
	ScrollFrameScaler:StartScrollHandling(scrollFrame, "Y")
end

function FilterLayersPopup:StopFunctions()
	local popupFrame = UIRoot.GetPopups():WaitForChild("FilterLayers")
	print("FilterLayersPopup:StopFunctions called")

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	for _, filterFrame in ipairs(createdFilterFrames) do
		if filterFrame.Parent ~= nil then
			filterFrame:Destroy()
		end
	end
	table.clear(createdFilterFrames)

	local scrollFrame = popupFrame.LayersList
	ScrollFrameScaler:StopScrollHandling(scrollFrame, "Y")
end

return FilterLayersPopup

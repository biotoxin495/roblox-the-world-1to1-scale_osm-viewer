local GuiButtonEffects = require(script.Parent.Parent.Parent.ClientPackages.GuiButtonEffects)

local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)
local UIRoot = require(script.Parent.Parent.UIRoot)

local PickSpawnPopup = {}
PickSpawnPopup.__index = PickSpawnPopup
PickSpawnPopup.Name = "PickSpawnPopup"

local connections = {} :: { RBXScriptConnection }

function PickSpawnPopup:StartFunctions(parseData)
	local Lat = parseData and parseData.Lat or 0
	local Lon = parseData and parseData.Lon or 0
	local Country = parseData and parseData.Country or "Unknown"
	local IsPopularSpot = parseData and parseData.IsPopularSpot or false
	local LocationName = parseData and parseData.LocationName or "Unknown"

	local popupFrame = UIRoot.GetPopups():WaitForChild("PickSpawn")

	local ContinueButton = popupFrame.ContinueButton
	local BackButton = popupFrame.TopHolder.BackButton

	local MainHolder = popupFrame.MainHolder
	MainHolder.MainInfo.Visible = IsPopularSpot
	MainHolder.Seperator.Visible = IsPopularSpot

	if IsPopularSpot then
		MainHolder.MainInfo.LocationName.Text = LocationName
		MainHolder.MainInfo.Country.Text = Country
	else
		MainHolder.MainInfo.LocationName.Text = "Unknown Location"
		MainHolder.MainInfo.Country.Text = "Unknown Country"
	end

	MainHolder.SubLocationInfo.Latitude.Text = string.format("LAT %.4f", Lat)
	MainHolder.SubLocationInfo.Longitude.Text = string.format("LON %.4f", Lon)

	GuiButtonEffects:SetupFromTemplate(ContinueButton, "GreenButton")
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
		ContinueButton.Activated:Connect(function()
			UIController:ClosePopup()
			UIController:OpenScreen("Loading", {
				Lat = Lat,
				Lon = Lon,
				PlaceName = LocationName,
			})
		end)
	)
	table.insert(
		connections,
		BackButton.Activated:Connect(function()
			UIController:ClosePopup()
		end)
	)
end

function PickSpawnPopup:StopFunctions()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	connections = {}
	local popupFrame = UIRoot.GetPopups():WaitForChild("PickSpawn")
	local ContinueButton = popupFrame.ContinueButton
	local BackButton = popupFrame.TopHolder.BackButton
	GuiButtonEffects:Clear(ContinueButton)
	GuiButtonEffects:Clear(BackButton)
end

return PickSpawnPopup

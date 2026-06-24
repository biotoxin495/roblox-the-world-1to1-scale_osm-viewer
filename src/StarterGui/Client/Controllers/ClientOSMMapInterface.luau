--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OSMMapNet = require(ReplicatedStorage.App.Shared.Network.OSMMapNet)

local ClientOSMMapInterface = {}
ClientOSMMapInterface.__index = ClientOSMMapInterface
ClientOSMMapInterface.Name = "ClientOSMMapInterface"

function ClientOSMMapInterface:Generate(latitude: number, longitude: number)
	return OSMMapNet.Client.GenerateAsync({
		Latitude = latitude,
		Longitude = longitude,
	})
end

return ClientOSMMapInterface

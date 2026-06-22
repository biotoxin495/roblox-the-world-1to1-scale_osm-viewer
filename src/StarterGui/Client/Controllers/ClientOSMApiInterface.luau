--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OSMApiNet = require(ReplicatedStorage.App.Shared.Network.OSMApiNet)

local ClientOSMApiInterface = {}
ClientOSMApiInterface.__index = ClientOSMApiInterface
ClientOSMApiInterface.Name = "ClientOSMApiInterface"

function ClientOSMApiInterface:Search(query: string, options: OSMApiNet.SearchOptions?)
	return OSMApiNet.Client.SearchAsync(query, options)
end

function ClientOSMApiInterface:Reverse(latitude: number, longitude: number, language: string?)
	return OSMApiNet.Client.ReverseAsync(latitude, longitude, language)
end

function ClientOSMApiInterface:Initial(latitude: number, longitude: number, options: OSMApiNet.MapLoadOptions?)
	return OSMApiNet.Client.InitialAsync(latitude, longitude, options)
end

function ClientOSMApiInterface:Chunk(options: OSMApiNet.ChunkOptions)
	return OSMApiNet.Client.ChunkAsync(options)
end

return ClientOSMApiInterface

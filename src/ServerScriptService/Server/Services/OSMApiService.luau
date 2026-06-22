--!strict

--[[
	Binds the shared OSM network contract to the server-only HTTP interface.
	The service awaits API promises before returning so RemoteFunctions only send
	serializable response tables to clients.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OSMApiNet = require(ReplicatedStorage.App.Shared.Network.OSMApiNet)
local OSMApiInterface = require(script.Parent.OSMApiInterface)

local OSMApiService = {
	Name = "OSMApiService",
}

local function toResponse(request: any): OSMApiNet.Response
	local ok, value = request:await()

	if ok then
		return {
			Ok = true,
			Data = value,
		}
	end

	local errorValue = value :: { [string]: unknown }
	return {
		Ok = false,
		Error = {
			Kind = if type(errorValue) == "table" and type(errorValue.Kind) == "string" then errorValue.Kind else "Unknown",
			Message = if type(errorValue) == "table" and type(errorValue.Message) == "string"
				then errorValue.Message
				else tostring(value),
			StatusCode = if type(errorValue) == "table" and type(errorValue.StatusCode) == "number"
				then errorValue.StatusCode
				else nil,
		},
	}
end

function OSMApiService:Start()
	OSMApiNet.Server.BindSearch(function(_, query, options)
		return toResponse(OSMApiInterface.Search(query, options))
	end)

	OSMApiNet.Server.BindReverse(function(_, latitude, longitude, language)
		return toResponse(OSMApiInterface.Reverse(latitude, longitude, language))
	end)

	OSMApiNet.Server.BindInitial(function(_, latitude, longitude, options)
		return toResponse(OSMApiInterface.Initial(latitude, longitude, options))
	end)

	OSMApiNet.Server.BindChunk(function(_, options)
		return toResponse(OSMApiInterface.Chunk(options))
	end)
end

return OSMApiService

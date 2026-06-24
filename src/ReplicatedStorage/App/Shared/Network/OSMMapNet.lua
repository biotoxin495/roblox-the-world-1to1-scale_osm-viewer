--!strict

--[[
	Owns the hand-off from the spawn-confirm UI to the server map service.
	The returned payload is intentionally data only: each client creates its own
	visual map, so one player's selected location never replaces another's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Middleware = require(script.Parent.Middleware)
local NetUtil = require(script.Parent.NetUtil)
local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)

export type SpawnRequest = {
	Latitude: number,
	Longitude: number,
}

export type ApiError = {
	Kind: string,
	Message: string,
	StatusCode: number?,
}

export type Response = {
	Ok: boolean,
	Data: unknown?,
	Error: ApiError?,
}

export type GenerateHandler = (player: Player, request: SpawnRequest) -> Response

local GENERATE_REMOTE = "OSMMap/Generate"

local OSMMapNet = {
	Client = {},
	Server = {},
}

function OSMMapNet.Client.Generate(request: SpawnRequest): Response
	return NetUtil.GetFunction(GENERATE_REMOTE):InvokeServer(request) :: Response
end

function OSMMapNet.Client.GenerateAsync(request: SpawnRequest)
	return Promise.new(function(resolve, reject)
		local ok, result = pcall(OSMMapNet.Client.Generate, request)
		if ok then
			resolve(result)
		else
			reject(result)
		end
	end)
end

local function rejectRequest(reason: string): Response
	return {
		Ok = false,
		Error = {
			Kind = "Request",
			Message = reason,
		},
	}
end

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function OSMMapNet.Server.BindGenerate(handler: GenerateHandler)
	local remote = NetUtil.GetFunction(GENERATE_REMOTE)

	Middleware.BindServerFunction(remote, GENERATE_REMOTE, function(context, request): Response
		return handler(context.Player, request :: SpawnRequest)
	end, {
		Middleware.ValidateArgs(function(request: unknown): (boolean, string?)
			if type(request) ~= "table" then
				return false, "Map generation request must be a table."
			end

			local typedRequest = request :: { [string]: unknown }
			local latitude = typedRequest.Latitude
			local longitude = typedRequest.Longitude
			if not isFinite(latitude) or latitude < -90 or latitude > 90 then
				return false, "Latitude must be a finite number between -90 and 90."
			end
			if not isFinite(longitude) or longitude < -180 or longitude > 180 then
				return false, "Longitude must be a finite number between -180 and 180."
			end

			return true
		end),
		Middleware.RateLimit({
			Window = 10,
			MaxCalls = 3,
			Reason = "You are requesting map generation too quickly.",
		}),
	}, rejectRequest)
end

return OSMMapNet

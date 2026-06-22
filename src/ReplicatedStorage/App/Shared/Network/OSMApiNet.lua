--!strict

--[[
	The client-facing contract for the server-side OSM API interface. HTTP access
	and API credentials remain server-only; clients only invoke these typed
	requests.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Middleware = require(script.Parent.Middleware)
local NetUtil = require(script.Parent.NetUtil)
local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)

export type Layers = { string }

export type SearchOptions = {
	Limit: number?,
	Language: string?,
}

export type MapLoadOptions = {
	ChunkSize: number?,
	Detail: string?,
	Layers: Layers?,
	Debug: boolean?,
}

export type ChunkOptions = MapLoadOptions & {
	OriginLat: number,
	OriginLon: number,
	ChunkX: number,
	ChunkZ: number,
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

export type SearchHandler = (player: Player, query: string, options: SearchOptions?) -> Response
export type ReverseHandler = (player: Player, latitude: number, longitude: number, language: string?) -> Response
export type InitialHandler = (player: Player, latitude: number, longitude: number, options: MapLoadOptions?) -> Response
export type ChunkHandler = (player: Player, options: ChunkOptions) -> Response

local SEARCH_REMOTE = "OSMApi/Search"
local REVERSE_REMOTE = "OSMApi/Reverse"
local INITIAL_REMOTE = "OSMApi/Initial"
local CHUNK_REMOTE = "OSMApi/Chunk"

local OSMApiNet = {}

OSMApiNet.Client = {}

function OSMApiNet.Client.Search(query: string, options: SearchOptions?): Response
	return NetUtil.GetFunction(SEARCH_REMOTE):InvokeServer(query, options) :: Response
end

function OSMApiNet.Client.SearchAsync(query: string, options: SearchOptions?)
	return Promise.new(function(resolve, reject)
		local ok, result = pcall(OSMApiNet.Client.Search, query, options)

		if ok then
			resolve(result)
		else
			reject(result)
		end
	end)
end

function OSMApiNet.Client.Reverse(latitude: number, longitude: number, language: string?): Response
	return NetUtil.GetFunction(REVERSE_REMOTE):InvokeServer(latitude, longitude, language) :: Response
end

function OSMApiNet.Client.ReverseAsync(latitude: number, longitude: number, language: string?)
	return Promise.new(function(resolve, reject)
		local ok, result = pcall(OSMApiNet.Client.Reverse, latitude, longitude, language)

		if ok then
			resolve(result)
		else
			reject(result)
		end
	end)
end

function OSMApiNet.Client.Initial(latitude: number, longitude: number, options: MapLoadOptions?): Response
	return NetUtil.GetFunction(INITIAL_REMOTE):InvokeServer(latitude, longitude, options) :: Response
end

function OSMApiNet.Client.InitialAsync(latitude: number, longitude: number, options: MapLoadOptions?)
	return Promise.new(function(resolve, reject)
		local ok, result = pcall(OSMApiNet.Client.Initial, latitude, longitude, options)

		if ok then
			resolve(result)
		else
			reject(result)
		end
	end)
end

function OSMApiNet.Client.Chunk(options: ChunkOptions): Response
	return NetUtil.GetFunction(CHUNK_REMOTE):InvokeServer(options) :: Response
end

function OSMApiNet.Client.ChunkAsync(options: ChunkOptions)
	return Promise.new(function(resolve, reject)
		local ok, result = pcall(OSMApiNet.Client.Chunk, options)

		if ok then
			resolve(result)
		else
			reject(result)
		end
	end)
end

OSMApiNet.Server = {}

local function rejectRequest(reason: string): Response
	return {
		Ok = false,
		Error = {
			Kind = "Request",
			Message = reason,
		},
	}
end

local function requestRateLimit(): Middleware.MiddlewareFn
	return Middleware.RateLimit({
		Window = 10,
		MaxCalls = 12,
		Reason = "You are requesting OSM data too quickly.",
	})
end

function OSMApiNet.Server.BindSearch(handler: SearchHandler)
	local remote = NetUtil.GetFunction(SEARCH_REMOTE)

	Middleware.BindServerFunction(remote, SEARCH_REMOTE, function(context, query, options): Response
		return handler(context.Player, query :: string, options :: SearchOptions?)
	end, {
		Middleware.ValidateArgs(function(query: unknown, options: unknown): (boolean, string?)
			if type(query) ~= "string" then
				return false, "Search query must be a string."
			end

			if options ~= nil and type(options) ~= "table" then
				return false, "Search options must be a table."
			end

			return true
		end),
		requestRateLimit(),
	}, rejectRequest)
end

function OSMApiNet.Server.BindReverse(handler: ReverseHandler)
	local remote = NetUtil.GetFunction(REVERSE_REMOTE)

	Middleware.BindServerFunction(remote, REVERSE_REMOTE, function(context, latitude, longitude, language): Response
		return handler(context.Player, latitude :: number, longitude :: number, language :: string?)
	end, {
		Middleware.ValidateArgs(function(latitude: unknown, longitude: unknown, language: unknown): (boolean, string?)
			if type(latitude) ~= "number" or type(longitude) ~= "number" then
				return false, "Latitude and longitude must be numbers."
			end

			if language ~= nil and type(language) ~= "string" then
				return false, "Language must be a string."
			end

			return true
		end),
		requestRateLimit(),
	}, rejectRequest)
end

function OSMApiNet.Server.BindInitial(handler: InitialHandler)
	local remote = NetUtil.GetFunction(INITIAL_REMOTE)

	Middleware.BindServerFunction(remote, INITIAL_REMOTE, function(context, latitude, longitude, options): Response
		return handler(context.Player, latitude :: number, longitude :: number, options :: MapLoadOptions?)
	end, {
		Middleware.ValidateArgs(function(latitude: unknown, longitude: unknown, options: unknown): (boolean, string?)
			if type(latitude) ~= "number" or type(longitude) ~= "number" then
				return false, "Latitude and longitude must be numbers."
			end

			if options ~= nil and type(options) ~= "table" then
				return false, "Map options must be a table."
			end

			return true
		end),
		requestRateLimit(),
	}, rejectRequest)
end

function OSMApiNet.Server.BindChunk(handler: ChunkHandler)
	local remote = NetUtil.GetFunction(CHUNK_REMOTE)

	Middleware.BindServerFunction(remote, CHUNK_REMOTE, function(context, options): Response
		return handler(context.Player, options :: ChunkOptions)
	end, {
		Middleware.ValidateArgs(function(options: unknown): (boolean, string?)
			if type(options) ~= "table" then
				return false, "Chunk options must be a table."
			end

			return true
		end),
		requestRateLimit(),
	}, rejectRequest)
end

return OSMApiNet

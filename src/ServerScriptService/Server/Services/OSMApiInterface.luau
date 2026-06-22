--!strict

--[[
	A small server-only client for the osm-viewer API. Consumers should use the
	endpoint methods below instead of HttpService directly so authentication,
	retries, validation, and caching stay consistent as the API grows.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)

local DEFAULT_BASE_URL = "https://api.playallava.com/osm-viewer/api/v1"
local DEFAULT_TOKEN = "change_me"
local DEFAULT_CACHE_TTL = 15
local DEFAULT_MAX_CACHE_ENTRIES = 128
local MAX_ATTEMPTS = 3

export type Layers = { string }

export type ErrorKind = "Configuration" | "Validation" | "Network" | "Http" | "Decode"

export type RequestError = {
	Kind: ErrorKind,
	Message: string,
	StatusCode: number?,
	Body: string?,
}

export type Configuration = {
	BaseUrl: string?,
	Token: string?,
	CacheTtl: number?,
	MaxCacheEntries: number?,
}

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

type QueryValue = string | number | boolean
type Query = { [string]: QueryValue? }
type CachedResponse = {
	Value: unknown,
	ExpiresAt: number,
	LastAccessedAt: number,
}
type HttpResponse = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Body: string,
}

local configuration = {
	BaseUrl = DEFAULT_BASE_URL,
	Token = DEFAULT_TOKEN,
	CacheTtl = DEFAULT_CACHE_TTL,
	MaxCacheEntries = DEFAULT_MAX_CACHE_ENTRIES,
}

local responseCache: { [string]: CachedResponse } = {}
local inFlightRequests: { [string]: any } = {}

local OSMApiInterface = {}

local function makeError(
	kind: ErrorKind,
	message: string,
	statusCode: number?,
	body: string?
): RequestError
	return {
		Kind = kind,
		Message = message,
		StatusCode = statusCode,
		Body = body,
	}
end

local function rejectValidation(message: string)
	return Promise.reject(makeError("Validation", message))
end

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validateLatitude(latitude: number): string?
	if not isFiniteNumber(latitude) or latitude < -90 or latitude > 90 then
		return "Latitude must be a finite number between -90 and 90."
	end

	return nil
end

local function validateLongitude(longitude: number): string?
	if not isFiniteNumber(longitude) or longitude < -180 or longitude > 180 then
		return "Longitude must be a finite number between -180 and 180."
	end

	return nil
end

local function validatePositiveInteger(value: number, name: string): string?
	if not isFiniteNumber(value) or value < 1 or value % 1 ~= 0 then
		return string.format("%s must be a positive integer.", name)
	end

	return nil
end

local function trimTrailingSlash(url: string): string
	return string.gsub(url, "/+$", "")
end

local function buildUrl(path: string, query: Query): string
	local encodedPairs = {}

	for key, value in pairs(query) do
		if value ~= nil then
			table.insert(encodedPairs, HttpService:UrlEncode(key) .. "=" .. HttpService:UrlEncode(tostring(value)))
		end
	end

	table.sort(encodedPairs)

	local url = trimTrailingSlash(configuration.BaseUrl) .. "/" .. path
	if #encodedPairs > 0 then
		url ..= "?" .. table.concat(encodedPairs, "&")
	end

	return url
end

local function isRetryable(errorValue: unknown): boolean
	if type(errorValue) ~= "table" then
		return true
	end

	local error = errorValue :: RequestError
	if error.Kind == "Network" then
		return true
	end

	return error.Kind == "Http"
		and error.StatusCode ~= nil
		and (error.StatusCode == 408 or error.StatusCode == 429 or error.StatusCode >= 500)
end

local function getRetryDelay(errorValue: unknown, attempt: number): number
	if type(errorValue) == "table" then
		local error = errorValue :: RequestError
		if error.StatusCode == 429 then
			return 1.5 * attempt
		end
	end

	return 0.5 * (2 ^ (attempt - 1))
end

local function executeRequest(url: string)
	return Promise.try(function()
		local headers: { [string]: string } = {
			Accept = "application/json",
		}

		if configuration.Token ~= "" then
			headers.Authorization = "Bearer " .. configuration.Token
		end

		local requestResult: { any } = table.pack(pcall(function()
			return HttpService:RequestAsync({
				Url = url,
				Method = "GET",
				Headers = headers,
			})
		end))
		local ok = requestResult[1] :: boolean
		local response: HttpResponse = requestResult[2]

		if not ok then
			return Promise.reject(makeError("Network", "OSM API request failed: " .. tostring(response)))
		end

		if not response.Success then
			return Promise.reject(makeError(
				"Http",
				string.format("OSM API returned HTTP %d: %s", response.StatusCode, response.StatusMessage),
				response.StatusCode,
				response.Body
			))
		end

		local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if not decodedOk then
			return Promise.reject(makeError("Decode", "OSM API returned invalid JSON: " .. tostring(decoded), response.StatusCode, response.Body))
		end

		return decoded
	end)
end

local function executeWithRetry(url: string, attempt: number)
	return executeRequest(url):catch(function(errorValue)
		if attempt >= MAX_ATTEMPTS or not isRetryable(errorValue) then
			return Promise.reject(errorValue)
		end

		return Promise.delay(getRetryDelay(errorValue, attempt)):andThen(function()
			return executeWithRetry(url, attempt + 1)
		end)
	end)
end

local function evictCacheIfNeeded()
	local now = os.clock()
	local oldestKey: string? = nil
	local oldestAccess = math.huge
	local count = 0

	for key, entry in pairs(responseCache) do
		if entry.ExpiresAt <= now then
			responseCache[key] = nil
		else
			count += 1
			if entry.LastAccessedAt < oldestAccess then
				oldestKey = key
				oldestAccess = entry.LastAccessedAt
			end
		end
	end

	if count >= configuration.MaxCacheEntries and oldestKey ~= nil then
		responseCache[oldestKey] = nil
	end
end

local function requestJson(path: string, query: Query)
	if configuration.BaseUrl == "" then
		return Promise.reject(makeError("Configuration", "OSM API BaseUrl has not been configured."))
	end

	local url = buildUrl(path, query)
	local now = os.clock()
	local cached = responseCache[url]
	if cached ~= nil and cached.ExpiresAt > now then
		cached.LastAccessedAt = now
		return Promise.resolve(cached.Value)
	end

	if cached ~= nil then
		responseCache[url] = nil
	end

	if inFlightRequests[url] ~= nil then
		return inFlightRequests[url]
	end

	local request = executeWithRetry(url, 1)
	inFlightRequests[url] = request

	request:andThen(function(value)
		evictCacheIfNeeded()
		local cachedAt = os.clock()
		responseCache[url] = {
			Value = value,
			ExpiresAt = cachedAt + configuration.CacheTtl,
			LastAccessedAt = cachedAt,
		}
	end, function()
		-- The caller receives the original rejection. Handling it here prevents
		-- this cache-observer chain from creating an unhandled rejection warning.
	end):finally(function()
		inFlightRequests[url] = nil
	end)

	return request
end

local function getMapQuery(latitude: number, longitude: number, options: MapLoadOptions): Query
	local layers = options.Layers or { "roads", "buildings", "water", "pois" }

	return {
		lat = latitude,
		lon = longitude,
		chunkSize = options.ChunkSize or 256,
		detail = options.Detail or "full",
		layers = table.concat(layers, ","),
		debug = options.Debug,
	}
end

local function validateMapOptions(options: MapLoadOptions): string?
	if options.ChunkSize ~= nil then
		local chunkSizeError = validatePositiveInteger(options.ChunkSize, "ChunkSize")
		if chunkSizeError ~= nil then
			return chunkSizeError
		end
	end

	if options.Detail ~= nil and (type(options.Detail) ~= "string" or options.Detail == "") then
		return "Detail must be a non-empty string."
	end

	if options.Debug ~= nil and type(options.Debug) ~= "boolean" then
		return "Debug must be a boolean."
	end

	if options.Layers ~= nil then
		if #options.Layers == 0 then
			return "Layers must contain at least one layer."
		end

		for index, layer in ipairs(options.Layers) do
			if type(layer) ~= "string" or layer == "" then
				return string.format("Layer %d must be a non-empty string.", index)
			end
		end
	end

	return nil
end

function OSMApiInterface.Configure(options: Configuration)
	if options.BaseUrl ~= nil then
		assert(type(options.BaseUrl) == "string" and options.BaseUrl ~= "", "BaseUrl must be a non-empty string.")
		configuration.BaseUrl = options.BaseUrl
	end

	if options.Token ~= nil then
		assert(type(options.Token) == "string", "Token must be a string.")
		configuration.Token = options.Token
	end

	if options.CacheTtl ~= nil then
		assert(isFiniteNumber(options.CacheTtl) and options.CacheTtl >= 0, "CacheTtl must be a non-negative finite number.")
		configuration.CacheTtl = options.CacheTtl
	end

	if options.MaxCacheEntries ~= nil then
		assert(validatePositiveInteger(options.MaxCacheEntries, "MaxCacheEntries") == nil, "MaxCacheEntries must be a positive integer.")
		configuration.MaxCacheEntries = options.MaxCacheEntries
	end

	OSMApiInterface.ClearCache()
end

function OSMApiInterface.ClearCache()
	table.clear(responseCache)
end

function OSMApiInterface.Search(query: string, options: SearchOptions?)
	if type(query) ~= "string" or query:match("^%s*$") then
		return rejectValidation("Search query must be a non-empty string.")
	end

	local searchOptions: SearchOptions = options or {}
	local limit = searchOptions.Limit or 5
	local limitError = validatePositiveInteger(limit, "Search limit")
	if limitError ~= nil then
		return rejectValidation(limitError)
	end

	if searchOptions.Language ~= nil and (type(searchOptions.Language) ~= "string" or searchOptions.Language == "") then
		return rejectValidation("Search language must be a non-empty string.")
	end

	return requestJson("search", {
		q = query,
		limit = limit,
		language = searchOptions.Language or "en",
	})
end

function OSMApiInterface.Reverse(latitude: number, longitude: number, language: string?)
	local latitudeError = validateLatitude(latitude)
	if latitudeError ~= nil then
		return rejectValidation(latitudeError)
	end

	local longitudeError = validateLongitude(longitude)
	if longitudeError ~= nil then
		return rejectValidation(longitudeError)
	end

	if language ~= nil and (type(language) ~= "string" or language == "") then
		return rejectValidation("Language must be a non-empty string.")
	end

	return requestJson("reverse", {
		lat = latitude,
		lon = longitude,
		language = language or "en",
	})
end

function OSMApiInterface.Initial(latitude: number, longitude: number, options: MapLoadOptions?)
	local latitudeError = validateLatitude(latitude)
	if latitudeError ~= nil then
		return rejectValidation(latitudeError)
	end

	local longitudeError = validateLongitude(longitude)
	if longitudeError ~= nil then
		return rejectValidation(longitudeError)
	end

	local mapOptions: MapLoadOptions = options or {}
	local optionsError = validateMapOptions(mapOptions)
	if optionsError ~= nil then
		return rejectValidation(optionsError)
	end

	return requestJson("initial", getMapQuery(latitude, longitude, mapOptions))
end

function OSMApiInterface.Chunk(options: ChunkOptions)
	if type(options) ~= "table" then
		return rejectValidation("Chunk options must be a table.")
	end

	local latitudeError = validateLatitude(options.OriginLat)
	if latitudeError ~= nil then
		return rejectValidation(latitudeError)
	end

	local longitudeError = validateLongitude(options.OriginLon)
	if longitudeError ~= nil then
		return rejectValidation(longitudeError)
	end

	if not isFiniteNumber(options.ChunkX) or options.ChunkX % 1 ~= 0 then
		return rejectValidation("ChunkX must be a finite integer.")
	end

	if not isFiniteNumber(options.ChunkZ) or options.ChunkZ % 1 ~= 0 then
		return rejectValidation("ChunkZ must be a finite integer.")
	end

	local optionsError = validateMapOptions(options)
	if optionsError ~= nil then
		return rejectValidation(optionsError)
	end

	local query = getMapQuery(options.OriginLat, options.OriginLon, options)
	query.originLat = query.lat
	query.originLon = query.lon
	query.lat = nil
	query.lon = nil
	query.chunkX = options.ChunkX
	query.chunkZ = options.ChunkZ

	return requestJson("chunk", query)
end

-- Descriptive aliases for call sites that do not mirror the API route names.
OSMApiInterface.ReverseGeocode = OSMApiInterface.Reverse
OSMApiInterface.LoadInitial = OSMApiInterface.Initial
OSMApiInterface.LoadChunk = OSMApiInterface.Chunk

return OSMApiInterface

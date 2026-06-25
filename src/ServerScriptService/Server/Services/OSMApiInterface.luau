--!strict

--[[
	A small server-only client for the osm-viewer API. Consumers should use the
	endpoint methods below instead of HttpService directly so authentication,
	retries, validation, and caching stay consistent as the API grows.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)
local OSMDirectApiInterface = require(script.Parent.OSM.OSMDirectApiInterface)

local DEFAULT_BASE_URL = "https://api.playallava.com/osm-viewer/api/v1"
local DEFAULT_TOKEN = "change_me"
local DEFAULT_CACHE_TTL = 15
local DEFAULT_MAX_CACHE_ENTRIES = 128
local MAX_ATTEMPTS = 3
local USE_DIRECT_OSM = false
local DEBUG_REQUEST_FLOW = true

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
	UseDirectOSM: boolean?,
	DirectOverpassUrl: string?,
	DirectNominatimUrl: string?,
	DirectNominatimUserAgent: string?,
	DirectNominatimEmail: string?,
	DirectNominatimReferer: string?,
	DirectCacheTtl: number?,
	DirectRawCacheTtl: number?,
	DirectMaxCacheEntries: number?,
	DebugRequests: boolean?,
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
	UseDirectOSM = USE_DIRECT_OSM,
	DebugRequests = DEBUG_REQUEST_FLOW,
}

local responseCache: { [string]: CachedResponse } = {}
local inFlightRequests: { [string]: any } = {}

local OSMApiInterface = {}

local function formatDebugValue(value: unknown): string
	if type(value) == "table" then
		local parts = {}
		for key, childValue in pairs(value :: { [any]: any }) do
			table.insert(parts, tostring(key) .. "=" .. formatDebugValue(childValue))
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ", ") .. "}"
	end

	return tostring(value)
end

local function logRequestFlow(event: string, details: { [string]: any }?)
	if not configuration.DebugRequests then
		return
	end

	if details == nil then
		print("[OSMApi] " .. event)
		return
	end

	local parts = {}
	for key, value in pairs(details) do
		table.insert(parts, tostring(key) .. "=" .. formatDebugValue(value))
	end
	table.sort(parts)
	print("[OSMApi] " .. event .. " | " .. table.concat(parts, " "))
end

local function makeError(kind: ErrorKind, message: string, statusCode: number?, body: string?): RequestError
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
		logRequestFlow("proxy.http.start", {
			url = url,
		})

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
			logRequestFlow("proxy.http.network_error", {
				url = url,
				error = tostring(response),
			})
			return Promise.reject(makeError("Network", "OSM API request failed: " .. tostring(response)))
		end

		if not response.Success then
			logRequestFlow("proxy.http.error", {
				url = url,
				statusCode = response.StatusCode,
				statusMessage = response.StatusMessage,
			})
			return Promise.reject(
				makeError(
					"Http",
					string.format("OSM API returned HTTP %d: %s", response.StatusCode, response.StatusMessage),
					response.StatusCode,
					response.Body
				)
			)
		end

		local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if not decodedOk then
			logRequestFlow("proxy.http.decode_error", {
				url = url,
				statusCode = response.StatusCode,
				error = tostring(decoded),
			})
			return Promise.reject(
				makeError(
					"Decode",
					"OSM API returned invalid JSON: " .. tostring(decoded),
					response.StatusCode,
					response.Body
				)
			)
		end

		logRequestFlow("proxy.http.success", {
			url = url,
			statusCode = response.StatusCode,
			bodyBytes = #response.Body,
		})

		return decoded
	end)
end

local function executeWithRetry(url: string, attempt: number)
	return executeRequest(url):catch(function(errorValue)
		if attempt >= MAX_ATTEMPTS or not isRetryable(errorValue) then
			logRequestFlow("proxy.retry.stop", {
				url = url,
				attempt = attempt,
				error = errorValue,
			})
			return Promise.reject(errorValue)
		end

		local retryDelay = getRetryDelay(errorValue, attempt)
		logRequestFlow("proxy.retry.schedule", {
			url = url,
			attempt = attempt,
			nextAttempt = attempt + 1,
			delaySeconds = retryDelay,
			error = errorValue,
		})

		return Promise.delay(retryDelay):andThen(function()
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
		logRequestFlow("proxy.configuration_error", {
			path = path,
			message = "BaseUrl has not been configured.",
		})
		return Promise.reject(makeError("Configuration", "OSM API BaseUrl has not been configured."))
	end

	local url = buildUrl(path, query)
	local now = os.clock()
	local cached = responseCache[url]
	if cached ~= nil and cached.ExpiresAt > now then
		cached.LastAccessedAt = now
		logRequestFlow("proxy.cache.hit", {
			path = path,
			url = url,
		})
		return Promise.resolve(cached.Value)
	end

	if cached ~= nil then
		logRequestFlow("proxy.cache.expired", {
			path = path,
			url = url,
		})
		responseCache[url] = nil
	end

	if inFlightRequests[url] ~= nil then
		logRequestFlow("proxy.inflight.join", {
			path = path,
			url = url,
		})
		return inFlightRequests[url]
	end

	logRequestFlow("proxy.cache.miss", {
		path = path,
		url = url,
	})

	local request = executeWithRetry(url, 1)
	inFlightRequests[url] = request

	request
		:andThen(function(value)
			logRequestFlow("proxy.cache.store", {
				path = path,
				url = url,
				ttlSeconds = configuration.CacheTtl,
			})
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
		end)
		:finally(function()
			logRequestFlow("proxy.inflight.clear", {
				path = path,
				url = url,
			})
			inFlightRequests[url] = nil
		end)

	return request
end

local function getMapQuery(latitude: number, longitude: number, options: MapLoadOptions): Query
	local layers = options.Layers or { "roads", "buildings", "water", "pois" }

	return {
		lat = latitude,
		lon = longitude,
		chunkSize = options.ChunkSize or 512,
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
		assert(
			isFiniteNumber(options.CacheTtl) and options.CacheTtl >= 0,
			"CacheTtl must be a non-negative finite number."
		)
		configuration.CacheTtl = options.CacheTtl
	end

	if options.MaxCacheEntries ~= nil then
		assert(
			validatePositiveInteger(options.MaxCacheEntries, "MaxCacheEntries") == nil,
			"MaxCacheEntries must be a positive integer."
		)
		configuration.MaxCacheEntries = options.MaxCacheEntries
	end

	if options.UseDirectOSM ~= nil then
		assert(type(options.UseDirectOSM) == "boolean", "UseDirectOSM must be a boolean.")
		configuration.UseDirectOSM = options.UseDirectOSM
	end

	if options.DebugRequests ~= nil then
		assert(type(options.DebugRequests) == "boolean", "DebugRequests must be a boolean.")
		configuration.DebugRequests = options.DebugRequests
	end

	local directConfiguration = {}
	if options.DirectOverpassUrl ~= nil then
		assert(
			type(options.DirectOverpassUrl) == "string" and options.DirectOverpassUrl ~= "",
			"DirectOverpassUrl must be a non-empty string."
		)
		directConfiguration.OverpassUrl = options.DirectOverpassUrl
	end
	if options.DirectNominatimUrl ~= nil then
		assert(
			type(options.DirectNominatimUrl) == "string" and options.DirectNominatimUrl ~= "",
			"DirectNominatimUrl must be a non-empty string."
		)
		directConfiguration.NominatimUrl = options.DirectNominatimUrl
	end
	if options.DirectNominatimUserAgent ~= nil then
		assert(
			type(options.DirectNominatimUserAgent) == "string" and options.DirectNominatimUserAgent ~= "",
			"DirectNominatimUserAgent must be a non-empty string."
		)
		directConfiguration.NominatimUserAgent = options.DirectNominatimUserAgent
	end
	if options.DirectNominatimEmail ~= nil then
		assert(type(options.DirectNominatimEmail) == "string", "DirectNominatimEmail must be a string.")
		directConfiguration.NominatimEmail = options.DirectNominatimEmail
	end
	if options.DirectNominatimReferer ~= nil then
		assert(type(options.DirectNominatimReferer) == "string", "DirectNominatimReferer must be a string.")
		directConfiguration.NominatimReferer = options.DirectNominatimReferer
	end
	if options.DirectCacheTtl ~= nil then
		assert(
			isFiniteNumber(options.DirectCacheTtl) and options.DirectCacheTtl >= 0,
			"DirectCacheTtl must be a non-negative finite number."
		)
		directConfiguration.CacheTtl = options.DirectCacheTtl
	end
	if options.DirectRawCacheTtl ~= nil then
		assert(
			isFiniteNumber(options.DirectRawCacheTtl) and options.DirectRawCacheTtl >= 0,
			"DirectRawCacheTtl must be a non-negative finite number."
		)
		directConfiguration.RawCacheTtl = options.DirectRawCacheTtl
	end
	if options.DirectMaxCacheEntries ~= nil then
		assert(
			validatePositiveInteger(options.DirectMaxCacheEntries, "DirectMaxCacheEntries") == nil,
			"DirectMaxCacheEntries must be a positive integer."
		)
		directConfiguration.MaxCacheEntries = options.DirectMaxCacheEntries
	end
	if options.DebugRequests ~= nil then
		directConfiguration.DebugRequests = options.DebugRequests
	end

	if next(directConfiguration) ~= nil then
		OSMDirectApiInterface.Configure(directConfiguration)
	end

	logRequestFlow("configure", {
		baseUrl = configuration.BaseUrl,
		useDirectOSM = configuration.UseDirectOSM,
		debugRequests = configuration.DebugRequests,
	})

	OSMApiInterface.ClearCache()
end

function OSMApiInterface.ClearCache()
	logRequestFlow("cache.clear")
	table.clear(responseCache)
	OSMDirectApiInterface.ClearCache()
end

function OSMApiInterface.Search(query: string, options: SearchOptions?)
	logRequestFlow("search.received", {
		query = query,
		mode = if configuration.UseDirectOSM then "direct" else "proxy",
	})

	if type(query) ~= "string" or query:match("^%s*$") then
		logRequestFlow("search.validation_failed", {
			message = "Search query must be a non-empty string.",
		})
		return rejectValidation("Search query must be a non-empty string.")
	end

	local searchOptions: SearchOptions = options or {}
	local limit = searchOptions.Limit or 5
	local limitError = validatePositiveInteger(limit, "Search limit")
	if limitError ~= nil then
		logRequestFlow("search.validation_failed", {
			message = limitError,
		})
		return rejectValidation(limitError)
	end

	if searchOptions.Language ~= nil and (type(searchOptions.Language) ~= "string" or searchOptions.Language == "") then
		logRequestFlow("search.validation_failed", {
			message = "Search language must be a non-empty string.",
		})
		return rejectValidation("Search language must be a non-empty string.")
	end

	if configuration.UseDirectOSM then
		logRequestFlow("search.dispatch", {
			mode = "direct",
			query = query,
			limit = limit,
			language = searchOptions.Language or "en",
		})
		return OSMDirectApiInterface.Search(query, searchOptions)
	end

	logRequestFlow("search.dispatch", {
		mode = "proxy",
		query = query,
		limit = limit,
		language = searchOptions.Language or "en",
	})

	return requestJson("search", {
		q = query,
		limit = limit,
		language = searchOptions.Language or "en",
	})
end

function OSMApiInterface.Reverse(latitude: number, longitude: number, language: string?)
	logRequestFlow("reverse.received", {
		lat = latitude,
		lon = longitude,
		language = language or "en",
		mode = if configuration.UseDirectOSM then "direct" else "proxy",
	})

	local latitudeError = validateLatitude(latitude)
	if latitudeError ~= nil then
		logRequestFlow("reverse.validation_failed", {
			message = latitudeError,
		})
		return rejectValidation(latitudeError)
	end

	local longitudeError = validateLongitude(longitude)
	if longitudeError ~= nil then
		logRequestFlow("reverse.validation_failed", {
			message = longitudeError,
		})
		return rejectValidation(longitudeError)
	end

	if language ~= nil and (type(language) ~= "string" or language == "") then
		logRequestFlow("reverse.validation_failed", {
			message = "Language must be a non-empty string.",
		})
		return rejectValidation("Language must be a non-empty string.")
	end

	if configuration.UseDirectOSM then
		logRequestFlow("reverse.dispatch", {
			mode = "direct",
		})
		return OSMDirectApiInterface.Reverse(latitude, longitude, language)
	end

	logRequestFlow("reverse.dispatch", {
		mode = "proxy",
	})

	return requestJson("reverse", {
		lat = latitude,
		lon = longitude,
		language = language or "en",
	})
end

function OSMApiInterface.Initial(latitude: number, longitude: number, options: MapLoadOptions?)
	logRequestFlow("initial.received", {
		lat = latitude,
		lon = longitude,
		mode = if configuration.UseDirectOSM then "direct" else "proxy",
		options = options or {},
	})

	local latitudeError = validateLatitude(latitude)
	if latitudeError ~= nil then
		logRequestFlow("initial.validation_failed", {
			message = latitudeError,
		})
		return rejectValidation(latitudeError)
	end

	local longitudeError = validateLongitude(longitude)
	if longitudeError ~= nil then
		logRequestFlow("initial.validation_failed", {
			message = longitudeError,
		})
		return rejectValidation(longitudeError)
	end

	local mapOptions: MapLoadOptions = options or {}
	local optionsError = validateMapOptions(mapOptions)
	if optionsError ~= nil then
		logRequestFlow("initial.validation_failed", {
			message = optionsError,
		})
		return rejectValidation(optionsError)
	end

	if configuration.UseDirectOSM then
		logRequestFlow("initial.dispatch", {
			mode = "direct",
			query = getMapQuery(latitude, longitude, mapOptions),
		})
		return OSMDirectApiInterface.Initial(latitude, longitude, mapOptions)
	end

	logRequestFlow("initial.dispatch", {
		mode = "proxy",
		query = getMapQuery(latitude, longitude, mapOptions),
	})

	return requestJson("initial", getMapQuery(latitude, longitude, mapOptions))
end

function OSMApiInterface.Chunk(options: ChunkOptions)
	logRequestFlow("chunk.received", {
		mode = if configuration.UseDirectOSM then "direct" else "proxy",
		options = options,
	})

	if type(options) ~= "table" then
		logRequestFlow("chunk.validation_failed", {
			message = "Chunk options must be a table.",
		})
		return rejectValidation("Chunk options must be a table.")
	end

	local latitudeError = validateLatitude(options.OriginLat)
	if latitudeError ~= nil then
		logRequestFlow("chunk.validation_failed", {
			message = latitudeError,
		})
		return rejectValidation(latitudeError)
	end

	local longitudeError = validateLongitude(options.OriginLon)
	if longitudeError ~= nil then
		logRequestFlow("chunk.validation_failed", {
			message = longitudeError,
		})
		return rejectValidation(longitudeError)
	end

	if not isFiniteNumber(options.ChunkX) or options.ChunkX % 1 ~= 0 then
		logRequestFlow("chunk.validation_failed", {
			message = "ChunkX must be a finite integer.",
		})
		return rejectValidation("ChunkX must be a finite integer.")
	end

	if not isFiniteNumber(options.ChunkZ) or options.ChunkZ % 1 ~= 0 then
		logRequestFlow("chunk.validation_failed", {
			message = "ChunkZ must be a finite integer.",
		})
		return rejectValidation("ChunkZ must be a finite integer.")
	end

	local optionsError = validateMapOptions(options)
	if optionsError ~= nil then
		logRequestFlow("chunk.validation_failed", {
			message = optionsError,
		})
		return rejectValidation(optionsError)
	end

	local query = getMapQuery(options.OriginLat, options.OriginLon, options)
	query.originLat = query.lat
	query.originLon = query.lon
	query.lat = nil
	query.lon = nil
	query.chunkX = options.ChunkX
	query.chunkZ = options.ChunkZ

	if configuration.UseDirectOSM then
		logRequestFlow("chunk.dispatch", {
			mode = "direct",
			query = query,
		})
		return OSMDirectApiInterface.Chunk(options)
	end

	logRequestFlow("chunk.dispatch", {
		mode = "proxy",
		query = query,
	})

	return requestJson("chunk", query)
end

-- Descriptive aliases for call sites that do not mirror the API route names.
OSMApiInterface.ReverseGeocode = OSMApiInterface.Reverse
OSMApiInterface.LoadInitial = OSMApiInterface.Initial
OSMApiInterface.LoadChunk = OSMApiInterface.Chunk

return OSMApiInterface

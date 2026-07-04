--!strict

--[[
	Server-only facade for OSM data requests. Public builds use the direct OSM
	implementation, which requests Overpass/Nominatim from Roblox without the
	old private osm-viewer backend.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)
local OSMDirectApiInterface = require(script.Parent.OSM.OSMDirectApiInterface)

export type Layers = { string }

export type ErrorKind = "Validation"

export type RequestError = {
	Kind: ErrorKind,
	Message: string,
	StatusCode: number?,
	Body: string?,
}

export type Configuration = {
	OverpassUrl: string?,
	NominatimUrl: string?,
	NominatimUserAgent: string?,
	NominatimEmail: string?,
	NominatimReferer: string?,
	CacheTtl: number?,
	RawCacheTtl: number?,
	MaxCacheEntries: number?,
	DebugRequests: boolean?,

	-- Backward-compatible names used by older local configuration.
	DirectOverpassUrl: string?,
	DirectNominatimUrl: string?,
	DirectNominatimUserAgent: string?,
	DirectNominatimEmail: string?,
	DirectNominatimReferer: string?,
	DirectCacheTtl: number?,
	DirectRawCacheTtl: number?,
	DirectMaxCacheEntries: number?,
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
	Language: string?,
}

export type ChunkOptions = MapLoadOptions & {
	OriginLat: number,
	OriginLon: number,
	ChunkX: number,
	ChunkZ: number,
}

local DEBUG_REQUEST_FLOW = true

local configuration = {
	DebugRequests = DEBUG_REQUEST_FLOW,
}

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

local function makeError(kind: ErrorKind, message: string): RequestError
	return {
		Kind = kind,
		Message = message,
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

	if options.Language ~= nil and (type(options.Language) ~= "string" or options.Language == "") then
		return "Language must be a non-empty string."
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

local function applyStringOption(
	source: Configuration,
	target: { [string]: any },
	publicName: string,
	legacyName: string?,
	targetName: string
)
	local value = (source :: any)[publicName]
	if value == nil and legacyName ~= nil then
		value = (source :: any)[legacyName]
	end
	if value ~= nil then
		assert(type(value) == "string" and value ~= "", publicName .. " must be a non-empty string.")
		target[targetName] = value
	end
end

local function applyOptionalStringOption(
	source: Configuration,
	target: { [string]: any },
	publicName: string,
	legacyName: string?,
	targetName: string
)
	local value = (source :: any)[publicName]
	if value == nil and legacyName ~= nil then
		value = (source :: any)[legacyName]
	end
	if value ~= nil then
		assert(type(value) == "string", publicName .. " must be a string.")
		target[targetName] = value
	end
end

local function applyNonNegativeNumberOption(
	source: Configuration,
	target: { [string]: any },
	publicName: string,
	legacyName: string?,
	targetName: string
)
	local value = (source :: any)[publicName]
	if value == nil and legacyName ~= nil then
		value = (source :: any)[legacyName]
	end
	if value ~= nil then
		assert(isFiniteNumber(value) and value >= 0, publicName .. " must be a non-negative finite number.")
		target[targetName] = value
	end
end

local function applyPositiveIntegerOption(
	source: Configuration,
	target: { [string]: any },
	publicName: string,
	legacyName: string?,
	targetName: string
)
	local value = (source :: any)[publicName]
	if value == nil and legacyName ~= nil then
		value = (source :: any)[legacyName]
	end
	if value ~= nil then
		assert(validatePositiveInteger(value, publicName) == nil, publicName .. " must be a positive integer.")
		target[targetName] = value
	end
end

function OSMApiInterface.Configure(options: Configuration)
	if options.DebugRequests ~= nil then
		assert(type(options.DebugRequests) == "boolean", "DebugRequests must be a boolean.")
		configuration.DebugRequests = options.DebugRequests
	end

	local directConfiguration = {}
	applyStringOption(options, directConfiguration, "OverpassUrl", "DirectOverpassUrl", "OverpassUrl")
	applyStringOption(options, directConfiguration, "NominatimUrl", "DirectNominatimUrl", "NominatimUrl")
	applyStringOption(
		options,
		directConfiguration,
		"NominatimUserAgent",
		"DirectNominatimUserAgent",
		"NominatimUserAgent"
	)
	applyOptionalStringOption(
		options,
		directConfiguration,
		"NominatimEmail",
		"DirectNominatimEmail",
		"NominatimEmail"
	)
	applyOptionalStringOption(
		options,
		directConfiguration,
		"NominatimReferer",
		"DirectNominatimReferer",
		"NominatimReferer"
	)
	applyNonNegativeNumberOption(options, directConfiguration, "CacheTtl", "DirectCacheTtl", "CacheTtl")
	applyNonNegativeNumberOption(options, directConfiguration, "RawCacheTtl", "DirectRawCacheTtl", "RawCacheTtl")
	applyPositiveIntegerOption(options, directConfiguration, "MaxCacheEntries", "DirectMaxCacheEntries", "MaxCacheEntries")

	if options.DebugRequests ~= nil then
		directConfiguration.DebugRequests = options.DebugRequests
	end

	logRequestFlow("configure", {
		mode = "direct",
		debugRequests = configuration.DebugRequests,
	})

	if next(directConfiguration) ~= nil then
		OSMDirectApiInterface.Configure(directConfiguration)
	end
end

function OSMApiInterface.ClearCache()
	logRequestFlow("cache.clear")
	OSMDirectApiInterface.ClearCache()
end

function OSMApiInterface.Search(query: string, options: SearchOptions?)
	logRequestFlow("search.received", {
		query = query,
		mode = "direct",
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

	logRequestFlow("search.dispatch", {
		mode = "direct",
		query = query,
		limit = limit,
		language = searchOptions.Language or "en",
	})
	return OSMDirectApiInterface.Search(query, searchOptions)
end

function OSMApiInterface.Reverse(latitude: number, longitude: number, language: string?)
	logRequestFlow("reverse.received", {
		lat = latitude,
		lon = longitude,
		language = language or "en",
		mode = "direct",
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

	logRequestFlow("reverse.dispatch", {
		mode = "direct",
	})
	return OSMDirectApiInterface.Reverse(latitude, longitude, language)
end

function OSMApiInterface.Initial(latitude: number, longitude: number, options: MapLoadOptions?)
	logRequestFlow("initial.received", {
		lat = latitude,
		lon = longitude,
		mode = "direct",
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

	logRequestFlow("initial.dispatch", {
		mode = "direct",
	})
	return OSMDirectApiInterface.Initial(latitude, longitude, mapOptions)
end

function OSMApiInterface.Chunk(options: ChunkOptions)
	logRequestFlow("chunk.received", {
		mode = "direct",
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

	logRequestFlow("chunk.dispatch", {
		mode = "direct",
		originLat = options.OriginLat,
		originLon = options.OriginLon,
		chunkX = options.ChunkX,
		chunkZ = options.ChunkZ,
	})
	return OSMDirectApiInterface.Chunk(options)
end

-- Descriptive aliases for call sites that do not mirror the API route names.
OSMApiInterface.ReverseGeocode = OSMApiInterface.Reverse
OSMApiInterface.LoadInitial = OSMApiInterface.Initial
OSMApiInterface.LoadChunk = OSMApiInterface.Chunk

return OSMApiInterface

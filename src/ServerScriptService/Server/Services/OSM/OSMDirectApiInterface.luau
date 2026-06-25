--!strict

--[[
	Server-only direct OSM implementation for the same shape exposed by the
	osm-viewer backend. This mirrors SOURCE_OSM_VIEWER's chunk, initial, and
	search behavior while requesting Overpass/Nominatim directly from Roblox.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)

local DEFAULT_OVERPASS_URL = "https://overpass-api.de/api/interpreter"
local DEFAULT_NOMINATIM_URL = "https://nominatim.openstreetmap.org"
local DEFAULT_NOMINATIM_USER_AGENT = "roblox-osm-viewer/1.0"
local DEFAULT_CACHE_TTL = 60
local DEFAULT_RAW_CACHE_TTL = 300
local DEFAULT_MAX_CACHE_ENTRIES = 64
local DEFAULT_CHUNK_SIZE = 512
local DEFAULT_DETAIL = "full"
local DEFAULT_LAYERS = { "roads", "buildings", "water", "landuse", "trees", "pois" }
local OVERPASS_TIMEOUT_SECONDS = 25
local OVERPASS_MAX_ATTEMPTS = 2
local EARTH_METERS_PER_DEGREE = 111320
local CHUNK_PADDING_METERS = 32
local OSM_ATTRIBUTION = "© OpenStreetMap contributors"

local KNOWN_LAYERS = { "roads", "buildings", "water", "landuse", "trees", "pois" }

local CAPS = {
	roads = 300,
	buildings = 500,
	water = 50,
	landuse = 80,
	trees = 300,
	pois = 40,
}

local MAX_POINTS = {
	building = 64,
	landuse = 128,
	water = 256,
}

local ROAD_WIDTH_METERS = {
	motorway = 14,
	trunk = 12,
	primary = 10,
	secondary = 8,
	tertiary = 7,
	residential = 5,
	unclassified = 5,
	service = 3,
	living_street = 4,
	pedestrian = 4,
	footway = 2,
	path = 1.5,
	cycleway = 2,
	rail = 4,
}

local POI_PRIORITY_THRESHOLD = 55

local POI_QUERY_GROUPS: { [string]: any } = {
	tourism = {
		"attraction",
		"artwork",
		"museum",
		"gallery",
		"viewpoint",
		"information",
		"hotel",
		"motel",
		"guest_house",
		"hostel",
		"apartment",
		"theme_park",
		"zoo",
		"aquarium",
	},
	amenity = {
		"university",
		"hospital",
		"townhall",
		"school",
		"college",
		"restaurant",
		"cafe",
		"theatre",
		"library",
		"bank",
		"post_office",
		"fuel",
		"marketplace",
		"place_of_worship",
		"cinema",
		"bus_station",
		"ferry_terminal",
		"police",
		"fire_station",
	},
	shop = { "mall", "supermarket", "convenience", "department_store" },
	building = {
		"school",
		"public",
		"church",
		"cathedral",
		"hospital",
		"university",
		"retail",
		"commercial",
		"civic",
		"office",
	},
	railway = { "station" },
	historic = true,
}

local POI_EXCLUDED_TAGS = {
	tourism = { "brewery", "distillery", "winery" },
	amenity = { "bar", "pub", "nightclub", "pharmacy" },
	shop = { "alcohol", "tobacco", "vape" },
}

local TOLERANCES = {
	full = { roads = 0.5, polygons = 1 },
	medium = { roads = 2, polygons = 4 },
	low = { roads = 8, polygons = 16 },
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
}

type Request = {
	originLat: number,
	originLon: number,
	chunkX: number,
	chunkZ: number,
	chunkSize: number,
	detail: string,
	layers: { string },
	debug: boolean?,
}

type CacheEntry = {
	Value: any,
	ExpiresAt: number,
	LastAccessedAt: number,
}

type Point = { x: number, z: number }

local configuration = {
	OverpassUrl = DEFAULT_OVERPASS_URL,
	NominatimUrl = DEFAULT_NOMINATIM_URL,
	NominatimUserAgent = DEFAULT_NOMINATIM_USER_AGENT,
	NominatimEmail = "",
	NominatimReferer = "",
	CacheTtl = DEFAULT_CACHE_TTL,
	RawCacheTtl = DEFAULT_RAW_CACHE_TTL,
	MaxCacheEntries = DEFAULT_MAX_CACHE_ENTRIES,
	DebugRequests = true,
}

local responseCache: { [string]: CacheEntry } = {}
local inFlightRequests: { [string]: any } = {}

local OSMDirectApiInterface = {}

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
		print("[OSMDirect] " .. event)
		return
	end

	local parts = {}
	for key, value in pairs(details) do
		table.insert(parts, tostring(key) .. "=" .. formatDebugValue(value))
	end
	table.sort(parts)
	print("[OSMDirect] " .. event .. " | " .. table.concat(parts, " "))
end

local function trimTrailingSlash(url: string): string
	return string.gsub(url, "/+$", "")
end

local function roundCoord(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

local function clamp(value: number, minValue: number, maxValue: number): number
	return math.min(maxValue, math.max(minValue, value))
end

local function tableHas(list: { any }, value: any): boolean
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local function makeSet(list: { string }): { [string]: boolean }
	local set = {}
	for _, value in ipairs(list) do
		set[value] = true
	end
	return set
end

local function normalizeLayers(layers: { string }?): { string }
	if layers == nil or #layers == 0 then
		return table.clone(DEFAULT_LAYERS)
	end

	local normalized = {}
	for _, layer in ipairs(layers) do
		if tableHas(KNOWN_LAYERS, layer) then
			table.insert(normalized, layer)
		end
	end

	return if #normalized > 0 then normalized else table.clone(DEFAULT_LAYERS)
end

local function makeCacheKey(prefix: string, parts: { any }): string
	local textParts = { prefix }
	for _, part in ipairs(parts) do
		table.insert(textParts, tostring(part))
	end
	return table.concat(textParts, "|")
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
		logRequestFlow("cache.evict_lru", {
			key = oldestKey,
			maxEntries = configuration.MaxCacheEntries,
		})
		responseCache[oldestKey] = nil
	end
end

local function getCached(key: string): any?
	local now = os.clock()
	local cached = responseCache[key]
	if cached ~= nil and cached.ExpiresAt > now then
		cached.LastAccessedAt = now
		logRequestFlow("cache.hit", {
			key = key,
		})
		return cached.Value
	end

	if cached ~= nil then
		logRequestFlow("cache.expired", {
			key = key,
		})
		responseCache[key] = nil
	end

	logRequestFlow("cache.miss", {
		key = key,
	})
	return nil
end

local function setCached(key: string, value: any, ttl: number)
	evictCacheIfNeeded()
	local now = os.clock()
	responseCache[key] = {
		Value = value,
		ExpiresAt = now + ttl,
		LastAccessedAt = now,
	}
	logRequestFlow("cache.store", {
		key = key,
		ttlSeconds = ttl,
	})
end

local function getOrRunInflight(key: string, factory: () -> any)
	if inFlightRequests[key] ~= nil then
		logRequestFlow("inflight.join", {
			key = key,
		})
		return inFlightRequests[key]
	end

	logRequestFlow("inflight.start", {
		key = key,
	})
	local request = Promise.try(factory):finally(function()
		logRequestFlow("inflight.clear", {
			key = key,
		})
		inFlightRequests[key] = nil
	end)
	inFlightRequests[key] = request
	return request
end

local function makeProviderRequestError(message: string, statusCode: number?)
	return {
		Kind = "Http",
		Message = message,
		StatusCode = statusCode or 503,
	}
end

local function requestJson(requestOptions: { [string]: any }, errorPrefix: string)
	return Promise.try(function()
		logRequestFlow("http.start", {
			provider = errorPrefix,
			method = requestOptions.Method or "GET",
			url = requestOptions.Url,
			bodyBytes = if type(requestOptions.Body) == "string" then #requestOptions.Body else 0,
		})

		local packed = table.pack(pcall(function()
			return HttpService:RequestAsync(requestOptions)
		end))
		local ok = packed[1] :: boolean
		local response = packed[2] :: any

		if not ok then
			logRequestFlow("http.network_error", {
				provider = errorPrefix,
				url = requestOptions.Url,
				error = tostring(response),
			})
			error(errorPrefix .. " request failed: " .. tostring(response))
		end

		if not response.Success then
			logRequestFlow("http.error", {
				provider = errorPrefix,
				url = requestOptions.Url,
				statusCode = response.StatusCode,
				statusMessage = response.StatusMessage,
			})
			error(
				string.format(
					"%s returned HTTP %d: %s",
					errorPrefix,
					response.StatusCode,
					response.StatusMessage
				)
			)
		end

		local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if not decodedOk then
			logRequestFlow("http.decode_error", {
				provider = errorPrefix,
				url = requestOptions.Url,
				statusCode = response.StatusCode,
				error = tostring(decoded),
			})
			error(errorPrefix .. " returned invalid JSON: " .. tostring(decoded))
		end

		logRequestFlow("http.success", {
			provider = errorPrefix,
			url = requestOptions.Url,
			statusCode = response.StatusCode,
			bodyBytes = #response.Body,
		})

		return decoded
	end)
end

local function requestJsonWithRetry(
	requestOptions: { [string]: any },
	errorPrefix: string,
	maxAttempts: number,
	shouldRetry: ((any) -> boolean)?
)
	local function runAttempt(attempt: number): any
		return requestJson(requestOptions, errorPrefix):catch(function(errorValue)
			local retryable = attempt < maxAttempts and (shouldRetry == nil or shouldRetry(errorValue))
			if not retryable then
				logRequestFlow("http.retry.stop", {
					provider = errorPrefix,
					attempt = attempt,
					error = tostring(errorValue),
				})
				return Promise.reject(errorValue)
			end

			local delaySeconds = 0.75 * attempt
			logRequestFlow("http.retry.schedule", {
				provider = errorPrefix,
				attempt = attempt,
				nextAttempt = attempt + 1,
				delaySeconds = delaySeconds,
				error = tostring(errorValue),
			})
			return Promise.delay(delaySeconds):andThen(function()
				return runAttempt(attempt + 1)
			end)
		end)
	end

	return runAttempt(1)
end

local function isOverpassRetryable(errorValue: any): boolean
	local text = tostring(errorValue)
	return text:find("HTTP 504", 1, true) ~= nil
		or text:find("HTTP 429", 1, true) ~= nil
		or text:find("HTTP 5", 1, true) ~= nil
		or text:find("timed out", 1, true) ~= nil
end

local function buildQueryUrl(baseUrl: string, path: string, query: { [string]: any }): string
	local pairsList = {}
	for key, value in pairs(query) do
		if value ~= nil and value ~= "" then
			table.insert(pairsList, HttpService:UrlEncode(key) .. "=" .. HttpService:UrlEncode(tostring(value)))
		end
	end
	table.sort(pairsList)

	local url = trimTrailingSlash(baseUrl) .. "/" .. path
	if #pairsList > 0 then
		url ..= "?" .. table.concat(pairsList, "&")
	end
	return url
end

local function getChunkBounds(request: Request)
	local halfChunkSize = request.chunkSize / 2
	local minX = request.chunkX * request.chunkSize - halfChunkSize
	local minZ = request.chunkZ * request.chunkSize - halfChunkSize
	local maxX = minX + request.chunkSize
	local maxZ = minZ + request.chunkSize

	return {
		x = request.chunkX,
		z = request.chunkZ,
		size = request.chunkSize,
		minX = minX,
		minZ = minZ,
		maxX = maxX,
		maxZ = maxZ,
	}
end

local function localMetersToLatLon(originLat: number, originLon: number, xMeters: number, zMeters: number)
	local lat = originLat + zMeters / EARTH_METERS_PER_DEGREE
	local lon = originLon + xMeters / (EARTH_METERS_PER_DEGREE * math.cos(math.rad(originLat)))
	return { lat = lat, lon = lon }
end

local function getPaddedBbox(request: Request)
	local chunk = getChunkBounds(request)
	local sw = localMetersToLatLon(
		request.originLat,
		request.originLon,
		chunk.minX - CHUNK_PADDING_METERS,
		chunk.minZ - CHUNK_PADDING_METERS
	)
	local ne = localMetersToLatLon(
		request.originLat,
		request.originLon,
		chunk.maxX + CHUNK_PADDING_METERS,
		chunk.maxZ + CHUNK_PADDING_METERS
	)

	return {
		south = math.min(sw.lat, ne.lat),
		west = math.min(sw.lon, ne.lon),
		north = math.max(sw.lat, ne.lat),
		east = math.max(sw.lon, ne.lon),
	}
end

local function latLonToLocalMeters(originLat: number, originLon: number, lat: number, lon: number): Point
	return {
		z = (lat - originLat) * EARTH_METERS_PER_DEGREE,
		x = (lon - originLon) * EARTH_METERS_PER_DEGREE * math.cos(math.rad(originLat)),
	}
end

local function toRobloxPoint(projected: Point): { number }
	return { roundCoord(projected.x), 0, roundCoord(projected.z) }
end

local function toFootprintPoint(projected: Point): { number }
	return { roundCoord(projected.x), roundCoord(projected.z) }
end

local function pointInBounds(point: Point, bounds: any): boolean
	return point.x >= bounds.minX and point.x <= bounds.maxX and point.z >= bounds.minZ and point.z <= bounds.maxZ
end

local function geometryBounds(points: { Point })
	local bounds = {
		minX = math.huge,
		minZ = math.huge,
		maxX = -math.huge,
		maxZ = -math.huge,
	}

	for _, point in ipairs(points) do
		bounds.minX = math.min(bounds.minX, point.x)
		bounds.minZ = math.min(bounds.minZ, point.z)
		bounds.maxX = math.max(bounds.maxX, point.x)
		bounds.maxZ = math.max(bounds.maxZ, point.z)
	end

	return bounds
end

local function geometryCenter(points: { Point }): Point
	local bounds = geometryBounds(points)
	return {
		x = (bounds.minX + bounds.maxX) / 2,
		z = (bounds.minZ + bounds.maxZ) / 2,
	}
end

local function geometryIntersectsBounds(points: { Point }, bounds: any): boolean
	if #points == 0 then
		return false
	end

	local geometry = geometryBounds(points)
	return geometry.minX <= bounds.maxX
		and geometry.maxX >= bounds.minX
		and geometry.minZ <= bounds.maxZ
		and geometry.maxZ >= bounds.minZ
end

local function squaredDistance(a: Point, b: Point): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return dx * dx + dz * dz
end

local function squaredSegmentDistance(point: Point, startPoint: Point, endPoint: Point): number
	local x = startPoint.x
	local z = startPoint.z
	local dx = endPoint.x - x
	local dz = endPoint.z - z

	if dx ~= 0 or dz ~= 0 then
		local t = ((point.x - x) * dx + (point.z - z) * dz) / (dx * dx + dz * dz)
		if t > 1 then
			x = endPoint.x
			z = endPoint.z
		elseif t > 0 then
			x += dx * t
			z += dz * t
		end
	end

	local outDx = point.x - x
	local outDz = point.z - z
	return outDx * outDx + outDz * outDz
end

local function simplifyRadial(points: { Point }, toleranceSquared: number): { Point }
	if #points <= 2 then
		return points
	end

	local simplified = { points[1] }
	local previous = points[1]

	for index = 2, #points do
		local point = points[index]
		if squaredDistance(point, previous) > toleranceSquared then
			table.insert(simplified, point)
			previous = point
		end
	end

	local last = points[#points]
	if previous ~= last then
		table.insert(simplified, last)
	end

	return simplified
end

local function simplifyDouglasPeucker(points: { Point }, toleranceSquared: number): { Point }
	local markers = table.create(#points, false)
	local stack = { { first = 1, last = #points } }
	markers[1] = true
	markers[#points] = true

	while #stack > 0 do
		local range = table.remove(stack)
		assert(range ~= nil, "Douglas-Peucker stack should contain a range.")
		local maxDistance = 0
		local maxIndex = 0

		for current = range.first + 1, range.last - 1 do
			local distance = squaredSegmentDistance(points[current], points[range.first], points[range.last])
			if distance > maxDistance then
				maxIndex = current
				maxDistance = distance
			end
		end

		if maxDistance > toleranceSquared then
			markers[maxIndex] = true
			table.insert(stack, { first = range.first, last = maxIndex })
			table.insert(stack, { first = maxIndex, last = range.last })
		end
	end

	local simplified = {}
	for index, point in ipairs(points) do
		if markers[index] then
			table.insert(simplified, point)
		end
	end
	return simplified
end

local function simplifyPoints(points: { Point }, tolerance: number): { Point }
	if #points <= 2 or tolerance <= 0 then
		return points
	end

	local toleranceSquared = tolerance * tolerance
	return simplifyDouglasPeucker(simplifyRadial(points, toleranceSquared), toleranceSquared)
end

local function simplifyClosedPolygon(points: { Point }, tolerance: number): { Point }
	if #points <= 4 then
		return points
	end

	local isPolygonClosed = points[1].x == points[#points].x and points[1].z == points[#points].z
	local openPoints = if isPolygonClosed then table.move(points, 1, #points - 1, 1, {}) else points
	local simplified = simplifyPoints(openPoints, tolerance)
	local first = simplified[1]
	local last = simplified[#simplified]

	if first == nil or (first.x == last.x and first.z == last.z) then
		return simplified
	end

	table.insert(simplified, first)
	return simplified
end

local function parseMeters(value: any): number?
	if value == nil then
		return nil
	end

	local match = tostring(value):match("-?%d+%.?%d*")
	if match == nil then
		return nil
	end

	local parsed = tonumber(match)
	return parsed
end

local function roadClass(tags: { [string]: any }): string?
	if tags.railway ~= nil then
		return "rail"
	end
	return tags.highway
end

local function roadWidth(tags: { [string]: any }): number
	local explicit = parseMeters(tags.width)
	if explicit ~= nil then
		return clamp(explicit, 0.5, 40)
	end

	local class = roadClass(tags)
	return if class ~= nil and ROAD_WIDTH_METERS[class] ~= nil then ROAD_WIDTH_METERS[class] else 5
end

local function resolveBuildingHeight(tags: { [string]: any }): number
	local explicit = parseMeters(tags.height)
	if explicit ~= nil then
		return clamp(explicit, 2, 300)
	end

	local levels = tonumber(tags["building:levels"])
	if levels ~= nil and levels > 0 then
		return clamp(levels * 3, 3, 300)
	end

	if tags.building == "house" or tags.building == "detached" or tags.building == "residential" then
		return 7
	elseif tags.building == "apartments" then
		return 18
	elseif tags.building == "commercial" or tags.building == "retail" then
		return 12
	elseif tags.building == "industrial" then
		return 10
	elseif tags.building == "church" or tags.building == "cathedral" then
		return 22
	end

	return 9
end

local function isExcludedPoi(tags: { [string]: any }): boolean
	for key, values in pairs(POI_EXCLUDED_TAGS) do
		if tableHas(values, tags[key]) then
			return true
		end
	end
	return false
end

local function hasPoiBaseTag(tags: { [string]: any }): boolean
	if tags.historic ~= nil then
		return true
	end

	for key, values in pairs(POI_QUERY_GROUPS) do
		if key ~= "historic" and type(values) == "table" and tableHas(values, tags[key]) then
			return true
		end
	end

	return false
end

local function poiPriority(tags: { [string]: any }): number
	if isExcludedPoi(tags) then
		return 0
	end

	if tags.tourism == "attraction" then
		return 100
	elseif tags.tourism == "artwork" then
		return 98
	elseif tags.tourism == "museum" then
		return 96
	elseif tags.tourism == "gallery" then
		return 95
	elseif tags.tourism == "viewpoint" then
		return 94
	elseif tags.tourism == "information" then
		return 92
	elseif tags.tourism == "theme_park" then
		return 89
	elseif tags.tourism == "zoo" then
		return 88
	elseif tags.tourism == "aquarium" then
		return 87
	elseif tags.tourism == "hotel" then
		return 76
	elseif tags.tourism == "motel" then
		return 75
	elseif tags.tourism == "guest_house" then
		return 74
	elseif tags.tourism == "hostel" then
		return 73
	elseif tags.tourism == "apartment" then
		return 72
	elseif tags.historic ~= nil then
		return 90
	elseif tags.railway == "station" then
		return 85
	elseif tags.amenity == "university" then
		return 80
	elseif tags.amenity == "hospital" then
		return 75
	elseif tags.amenity == "townhall" then
		return 70
	elseif tags.amenity == "school" or tags.building == "school" then
		return 68
	elseif tags.building == "public" then
		return 66
	elseif tags.amenity == "place_of_worship" then
		return 66
	elseif tags.amenity == "restaurant" or tags.amenity == "cafe" or tags.amenity == "theatre" then
		return 64
	elseif tags.amenity == "cinema" or tags.amenity == "bus_station" or tags.shop == "mall" then
		return 63
	elseif tags.amenity == "library" or tags.amenity == "bank" or tags.amenity == "post_office" then
		return 62
	elseif tags.amenity == "police" or tags.amenity == "fire_station" or tags.amenity == "fuel" or tags.amenity == "marketplace" then
		return 61
	elseif tags.amenity == "parking" or tags.building == "civic" or tags.building == "office" then
		return 60
	elseif tags.shop == "supermarket" or tags.shop == "convenience" or tags.shop == "department_store" then
		return 60
	elseif tags.name ~= nil and hasPoiBaseTag(tags) then
		return POI_PRIORITY_THRESHOLD
	end

	return 0
end

local function poiKind(tags: { [string]: any }): string
	return tags.tourism or tags.historic or tags.amenity or tags.shop or tags.building or tags.railway or "poi"
end

local function waterKind(tags: { [string]: any }): string
	return tags.water or tags.waterway or tags.natural or "water"
end

local function landuseKind(tags: { [string]: any }): string
	return tags.landuse or tags.leisure or "landuse"
end

local function numericId(element: any): string
	return tostring(element.type) .. "/" .. tostring(element.id)
end

local function buildIndexes(raw: any)
	local nodes = {}
	local ways = {}
	local relations = {}

	for _, element in ipairs(raw.elements or {}) do
		if element.type == "node" then
			nodes[element.id] = element
		elseif element.type == "way" then
			ways[element.id] = element
		elseif element.type == "relation" then
			table.insert(relations, element)
		end
	end

	return nodes, ways, relations
end

local function projectNode(node: any, request: Request): Point
	return latLonToLocalMeters(request.originLat, request.originLon, tonumber(node.lat) or 0, tonumber(node.lon) or 0)
end

local function wayPoints(way: any, nodes: { [any]: any }, request: Request): { Point }
	local points = {}
	for _, id in ipairs(way.nodes or {}) do
		local node = nodes[id]
		if node ~= nil then
			table.insert(points, projectNode(node, request))
		end
	end
	return points
end

local function capPoints(points: { Point }, maxPoints: number): { Point }
	if #points <= maxPoints then
		return points
	end

	local step = math.ceil(#points / maxPoints)
	local capped = {}
	for index, point in ipairs(points) do
		if (index - 1) % step == 0 then
			table.insert(capped, point)
		end
	end

	local first = capped[1]
	local last = capped[#capped]
	if first ~= nil and last ~= nil and (first.x ~= last.x or first.z ~= last.z) then
		table.insert(capped, first)
	end

	if #capped <= maxPoints then
		return capped
	end

	local shortened = {}
	for index = 1, maxPoints - 1 do
		table.insert(shortened, capped[index])
	end
	if first ~= nil then
		table.insert(shortened, first)
	end
	return shortened
end

local function isClosed(points: { Point }): boolean
	if #points < 4 then
		return false
	end
	local first = points[1]
	local last = points[#points]
	return first.x == last.x and first.z == last.z
end

local function polygonToOutput(points: { Point }): { { number } }
	local outputPoints = {}
	for index = 1, #points - 1 do
		table.insert(outputPoints, toFootprintPoint(points[index]))
	end
	return outputPoints
end

local function compileRoad(way: any, points: { Point }, request: Request, chunk: any, tolerances: any): any?
	local tags = way.tags or {}
	local simplified = simplifyPoints(points, tolerances.roads)
	if #simplified < 2 or not geometryIntersectsBounds(simplified, chunk) then
		return nil
	end

	local outputPoints = {}
	for _, point in ipairs(simplified) do
		table.insert(outputPoints, toRobloxPoint(point))
	end

	return {
		id = numericId(way),
		class = roadClass(tags),
		width = roadWidth(tags),
		surface = tags.surface or nil,
		name = tags.name or nil,
		points = outputPoints,
	}
end

local function compileBuilding(way: any, points: { Point }, chunk: any, tolerances: any): any?
	local tags = way.tags or {}
	local simplified = capPoints(simplifyClosedPolygon(points, tolerances.polygons), MAX_POINTS.building + 1)
	if not isClosed(simplified) or not geometryIntersectsBounds(simplified, chunk) then
		return nil
	end

	return {
		id = numericId(way),
		kind = tags.building or "yes",
		height = resolveBuildingHeight(tags),
		levels = tonumber(tags["building:levels"]),
		name = tags.name or tags["addr:housenumber"] or nil,
		footprint = polygonToOutput(simplified),
	}
end

local function compileWater(element: any, points: { Point }, chunk: any, tolerances: any): any?
	local tags = element.tags or {}
	local simplified = capPoints(simplifyClosedPolygon(points, tolerances.polygons), MAX_POINTS.water + 1)
	if not isClosed(simplified) or not geometryIntersectsBounds(simplified, chunk) then
		return nil
	end

	return {
		id = numericId(element),
		kind = waterKind(tags),
		polygons = { polygonToOutput(simplified) },
	}
end

local function compileLanduse(element: any, points: { Point }, chunk: any, tolerances: any): any?
	local tags = element.tags or {}
	local simplified = capPoints(simplifyClosedPolygon(points, tolerances.polygons), MAX_POINTS.landuse + 1)
	if not isClosed(simplified) or not geometryIntersectsBounds(simplified, chunk) then
		return nil
	end

	return {
		id = numericId(element),
		kind = landuseKind(tags),
		polygons = { polygonToOutput(simplified) },
	}
end

local function compileTree(node: any, request: Request, chunk: any): any?
	local tags = node.tags or {}
	local projected = projectNode(node, request)
	if not pointInBounds(projected, chunk) then
		return nil
	end

	return {
		id = numericId(node),
		kind = "tree",
		position = toRobloxPoint(projected),
		height = parseMeters(tags.height),
		crownDiameter = parseMeters(tags.diameter_crown),
		species = tags.species or nil,
		genus = tags.genus or nil,
	}
end

local function compileTreeRow(way: any, points: { Point }, chunk: any, tolerances: any): any?
	local simplified = simplifyPoints(points, tolerances.roads)
	if #simplified < 2 or not geometryIntersectsBounds(simplified, chunk) then
		return nil
	end

	local outputPoints = {}
	for _, point in ipairs(simplified) do
		table.insert(outputPoints, toRobloxPoint(point))
	end

	return {
		id = numericId(way),
		kind = "tree_row",
		points = outputPoints,
	}
end

local function compileForest(element: any, points: { Point }, chunk: any, tolerances: any): any?
	local simplified = capPoints(simplifyClosedPolygon(points, tolerances.polygons), MAX_POINTS.landuse + 1)
	if not isClosed(simplified) or not geometryIntersectsBounds(simplified, chunk) then
		return nil
	end

	return {
		id = numericId(element),
		kind = "forest",
		polygons = { polygonToOutput(simplified) },
	}
end

local function relationOuterWays(relation: any, ways: { [any]: any }): { any }
	local output = {}
	for _, member in ipairs(relation.members or {}) do
		if member.type == "way" and (member.role == nil or member.role == "" or member.role == "outer") then
			local way = ways[member.ref]
			if way ~= nil then
				table.insert(output, way)
			end
		end
	end
	return output
end

local function collectPoiPoints(element: any, nodes: { [any]: any }, ways: { [any]: any }, request: Request): { Point }
	if element.type == "node" then
		return { projectNode(element, request) }
	elseif element.type == "way" then
		return wayPoints(element, nodes, request)
	elseif element.type == "relation" then
		local points = {}
		for _, way in ipairs(relationOuterWays(element, ways)) do
			for _, point in ipairs(wayPoints(way, nodes, request)) do
				table.insert(points, point)
			end
		end
		return points
	end

	return {}
end

local function compilePoi(element: any, nodes: { [any]: any }, ways: { [any]: any }, request: Request, chunk: any): any?
	local tags = element.tags or {}
	local priority = poiPriority(tags)
	if priority < POI_PRIORITY_THRESHOLD then
		return nil
	end

	local points = collectPoiPoints(element, nodes, ways, request)
	if #points == 0 then
		return nil
	end

	local projected = if #points == 1 then points[1] else geometryCenter(points)
	if not pointInBounds(projected, chunk) then
		return nil
	end

	return {
		id = numericId(element),
		kind = poiKind(tags),
		name = tags.name or nil,
		position = toRobloxPoint(projected),
		priority = priority,
	}
end

local function countElements(raw: any)
	local counts = {
		nodes = 0,
		ways = 0,
		relations = 0,
		roads = 0,
		buildings = 0,
		water = 0,
		landuse = 0,
		trees = 0,
		pois = 0,
	}

	for _, element in ipairs(raw.elements or {}) do
		if element.type == "node" then
			counts.nodes += 1
		elseif element.type == "way" then
			counts.ways += 1
		elseif element.type == "relation" then
			counts.relations += 1
		end

		local tags = element.tags or {}
		if tags.highway ~= nil or tags.railway ~= nil then
			counts.roads += 1
		end
		if tags.building ~= nil then
			counts.buildings += 1
		end
		if tags.natural == "water" or tags.waterway ~= nil then
			counts.water += 1
		end
		if tags.landuse ~= nil or tags.leisure == "park" then
			counts.landuse += 1
		end
		if tags.natural == "tree" or tags.natural == "tree_row" or tags.landuse == "forest" then
			counts.trees += 1
		end
		if poiPriority(tags) >= POI_PRIORITY_THRESHOLD then
			counts.pois += 1
		end
	end

	return counts
end

local function applyCaps(payload: any)
	local function cap(list: { any }, maxCount: number): { any }
		local output = {}
		for index = 1, math.min(#list, maxCount) do
			table.insert(output, list[index])
		end
		return output
	end

	payload.roads = cap(payload.roads, CAPS.roads)
	payload.buildings = cap(payload.buildings, CAPS.buildings)
	payload.water = cap(payload.water, CAPS.water)
	payload.landuse = cap(payload.landuse, CAPS.landuse)
	payload.trees = cap(payload.trees, CAPS.trees)
	table.sort(payload.pois, function(a, b)
		return (a.priority or 0) > (b.priority or 0)
	end)
	payload.pois = cap(payload.pois, CAPS.pois)
end

local function compileRelationPolygons(
	relation: any,
	ways: { [any]: any },
	nodes: { [any]: any },
	request: Request,
	chunk: any,
	tolerances: any,
	requestedLayers: { [string]: boolean }
): { any }
	local compiled = {}
	local tags = relation.tags or {}

	for _, way in ipairs(relationOuterWays(relation, ways)) do
		local points = wayPoints(way, nodes, request)
		local element = table.clone(relation)
		element.type = "relation"

		if requestedLayers.buildings and tags.building ~= nil then
			local building = compileBuilding(element, points, chunk, tolerances)
			if building ~= nil then
				table.insert(compiled, { layer = "buildings", feature = building })
			end
		end

		if requestedLayers.water and (tags.natural == "water" or tags.waterway ~= nil) then
			local water = compileWater(element, points, chunk, tolerances)
			if water ~= nil then
				table.insert(compiled, { layer = "water", feature = water })
			end
		end

		if requestedLayers.landuse and (tags.landuse ~= nil or tags.leisure == "park") then
			local landuse = compileLanduse(element, points, chunk, tolerances)
			if landuse ~= nil then
				table.insert(compiled, { layer = "landuse", feature = landuse })
			end
		end

		if requestedLayers.trees and tags.landuse == "forest" then
			local forest = compileForest(element, points, chunk, tolerances)
			if forest ~= nil then
				table.insert(compiled, { layer = "trees", feature = forest })
			end
		end
	end

	return compiled
end

local function makeEmptyDegradedChunk(request: Request, chunk: any, bbox: any, code: string, message: string, rawStats: any?, rawCache: string?)
	local stats = {
		roads = 0,
		buildings = 0,
		water = 0,
		landuse = 0,
		trees = 0,
		pois = 0,
		cache = "miss",
	}

	if rawStats ~= nil then
		stats.roads = rawStats.roads
		stats.buildings = rawStats.buildings
		stats.water = rawStats.water
		stats.landuse = rawStats.landuse
		stats.trees = rawStats.trees
		stats.pois = rawStats.pois
	end

	local payload = {
		version = 1,
		status = "degraded",
		source = "openstreetmap",
		attribution = OSM_ATTRIBUTION,
		origin = {
			lat = request.originLat,
			lon = request.originLon,
		},
		chunk = chunk,
		stats = stats,
		roads = {},
		buildings = {},
		water = {},
		landuse = {},
		trees = {},
		pois = {},
		error = {
			code = code,
			message = message,
		},
	}

	if request.debug then
		payload.debug = {
			paddedBbox = bbox,
			layers = request.layers,
			detail = request.detail,
			rawCache = rawCache,
			rawStats = rawStats,
		}
	end

	return payload
end

local function compileChunkPayload(raw: any, request: Request, chunk: any, bbox: any, rawStats: any, rawCache: string)
	local nodes, ways, relations = buildIndexes(raw)
	local tolerances = TOLERANCES[request.detail] or TOLERANCES.full
	local requestedLayers = makeSet(request.layers)
	local payload = {
		version = 1,
		status = "ok",
		source = "openstreetmap",
		attribution = OSM_ATTRIBUTION,
		origin = {
			lat = request.originLat,
			lon = request.originLon,
		},
		chunk = chunk,
		stats = {
			roads = 0,
			buildings = 0,
			water = 0,
			landuse = 0,
			trees = 0,
			pois = 0,
			cache = "miss",
		},
		roads = {},
		buildings = {},
		water = {},
		landuse = {},
		trees = {},
		pois = {},
	}

	for _, way in pairs(ways) do
		local tags = way.tags or {}
		local points = wayPoints(way, nodes, request)
		if #points < 2 then
			continue
		end

		if requestedLayers.pois then
			local poi = compilePoi(way, nodes, ways, request, chunk)
			if poi ~= nil then
				table.insert(payload.pois, poi)
			end
		end

		if requestedLayers.roads and (tags.highway ~= nil or tags.railway ~= nil) then
			local road = compileRoad(way, points, request, chunk, tolerances)
			if road ~= nil then
				table.insert(payload.roads, road)
			end
			continue
		end

		if requestedLayers.buildings and tags.building ~= nil then
			local building = compileBuilding(way, points, chunk, tolerances)
			if building ~= nil then
				table.insert(payload.buildings, building)
			end
			continue
		end

		if requestedLayers.water and (tags.natural == "water" or tags.waterway ~= nil) then
			local water = compileWater(way, points, chunk, tolerances)
			if water ~= nil then
				table.insert(payload.water, water)
			end
			continue
		end

		if requestedLayers.landuse and (tags.landuse ~= nil or tags.leisure == "park") then
			local landuse = compileLanduse(way, points, chunk, tolerances)
			if landuse ~= nil then
				table.insert(payload.landuse, landuse)
			end
		end

		if requestedLayers.trees and tags.natural == "tree_row" then
			local treeRow = compileTreeRow(way, points, chunk, tolerances)
			if treeRow ~= nil then
				table.insert(payload.trees, treeRow)
			end
		end

		if requestedLayers.trees and tags.landuse == "forest" then
			local forest = compileForest(way, points, chunk, tolerances)
			if forest ~= nil then
				table.insert(payload.trees, forest)
			end
		end
	end

	if requestedLayers.pois or requestedLayers.trees then
		for _, node in pairs(nodes) do
			if node.tags == nil then
				continue
			end

			if requestedLayers.pois then
				local poi = compilePoi(node, nodes, ways, request, chunk)
				if poi ~= nil then
					table.insert(payload.pois, poi)
				end
			end

			if requestedLayers.trees and node.tags.natural == "tree" then
				local tree = compileTree(node, request, chunk)
				if tree ~= nil then
					table.insert(payload.trees, tree)
				end
			end
		end
	end

	for _, relation in ipairs(relations) do
		local tags = relation.tags or {}
		local isPolygonRelevant = (requestedLayers.buildings and tags.building ~= nil)
			or (requestedLayers.water and (tags.natural == "water" or tags.waterway ~= nil))
			or (requestedLayers.landuse and (tags.landuse ~= nil or tags.leisure == "park"))
			or (requestedLayers.trees and tags.landuse == "forest")
		local isPoiRelevant = requestedLayers.pois and poiPriority(tags) >= POI_PRIORITY_THRESHOLD

		if not isPolygonRelevant and not isPoiRelevant then
			continue
		end

		if isPolygonRelevant then
			for _, compiled in ipairs(compileRelationPolygons(relation, ways, nodes, request, chunk, tolerances, requestedLayers)) do
				table.insert(payload[compiled.layer], compiled.feature)
			end
		end

		if isPoiRelevant then
			local poi = compilePoi(relation, nodes, ways, request, chunk)
			if poi ~= nil then
				table.insert(payload.pois, poi)
			end
		end
	end

	applyCaps(payload)
	payload.stats.roads = #payload.roads
	payload.stats.buildings = #payload.buildings
	payload.stats.water = #payload.water
	payload.stats.landuse = #payload.landuse
	payload.stats.trees = #payload.trees
	payload.stats.pois = #payload.pois

	if request.debug then
		payload.debug = {
			paddedBbox = bbox,
			layers = request.layers,
			detail = request.detail,
			rawCache = rawCache,
			rawStats = rawStats,
			rawElements = #(raw.elements or {}),
			skippedRelations = #relations,
		}
	end

	return payload
end

local function formatBbox(bbox: any): string
	return string.format("%.7f,%.7f,%.7f,%.7f", bbox.south, bbox.west, bbox.north, bbox.east)
end

local function escapeRegex(value: string): string
	-- Current OSM tag values are plain words/underscores. Keep this helper
	-- isolated so richer values can be escaped here later without touching query assembly.
	return value
end

local function makePoiClauses(bboxText: string): { string }
	local clauses = {}

	for _, elementType in ipairs({ "node", "way", "relation" }) do
		for key, values in pairs(POI_QUERY_GROUPS) do
			if type(values) == "table" then
				local escaped = {}
				for _, value in ipairs(values) do
					table.insert(escaped, escapeRegex(value))
				end
				table.insert(clauses, string.format('%s["%s"~"^(%s)$"](%s);', elementType, key, table.concat(escaped, "|"), bboxText))
			elseif values == true then
				table.insert(clauses, string.format('%s["%s"](%s);', elementType, key, bboxText))
			end
		end
	end

	return clauses
end

local function layerClauses(layers: { string }, bboxText: string): { string }
	local clauses = {}
	local requested = makeSet(layers)

	if requested.roads then
		table.insert(clauses, string.format('way["highway"](%s);', bboxText))
		table.insert(clauses, string.format('way["railway"~"^(rail|tram|subway|light_rail)$"](%s);', bboxText))
	end

	if requested.buildings then
		table.insert(clauses, string.format('way["building"](%s);', bboxText))
		table.insert(clauses, string.format('relation["building"](%s);', bboxText))
	end

	if requested.water then
		table.insert(clauses, string.format('way["natural"="water"](%s);', bboxText))
		table.insert(clauses, string.format('relation["natural"="water"](%s);', bboxText))
		table.insert(clauses, string.format('way["waterway"](%s);', bboxText))
	end

	if requested.landuse then
		table.insert(clauses, string.format('way["landuse"](%s);', bboxText))
		table.insert(clauses, string.format('relation["landuse"](%s);', bboxText))
		table.insert(clauses, string.format('way["leisure"="park"](%s);', bboxText))
		table.insert(clauses, string.format('relation["leisure"="park"](%s);', bboxText))
	end

	if requested.trees then
		table.insert(clauses, string.format('node["natural"="tree"](%s);', bboxText))
		table.insert(clauses, string.format('way["natural"="tree_row"](%s);', bboxText))
		table.insert(clauses, string.format('way["landuse"="forest"](%s);', bboxText))
		table.insert(clauses, string.format('relation["landuse"="forest"](%s);', bboxText))
	end

	if requested.pois then
		for _, clause in ipairs(makePoiClauses(bboxText)) do
			table.insert(clauses, clause)
		end
	end

	return clauses
end

local function buildOverpassQuery(bbox: any, layers: { string }): string
	local clauses = layerClauses(layers, formatBbox(bbox))
	local lines = {
		string.format("[out:json][timeout:%d];", OVERPASS_TIMEOUT_SECONDS),
		"(",
	}

	for _, clause in ipairs(clauses) do
		table.insert(lines, "  " .. clause)
	end

	table.insert(lines, ");")
	table.insert(lines, "out body;")
	table.insert(lines, ">;")
	table.insert(lines, "out skel qt;")
	return table.concat(lines, "\n")
end

local function fetchOverpass(bbox: any, layers: { string }, detail: string)
	local rawKey = makeCacheKey("overpass:raw", {
		formatBbox(bbox),
		table.concat(layers, ","),
		detail,
	})
	local cached = getCached(rawKey)
	if cached ~= nil then
		logRequestFlow("overpass.raw_cache.hit", {
			bbox = formatBbox(bbox),
			layers = table.concat(layers, ","),
			detail = detail,
		})
		return Promise.resolve(cached), "hit"
	end

	local query = buildOverpassQuery(bbox, layers)
	local body = "data=" .. HttpService:UrlEncode(query)
	logRequestFlow("overpass.query.ready", {
		url = configuration.OverpassUrl,
		bbox = formatBbox(bbox),
		layers = table.concat(layers, ","),
		detail = detail,
		queryBytes = #query,
		bodyBytes = #body,
	})

	return requestJsonWithRetry({
		Url = configuration.OverpassUrl,
		Method = "POST",
		Headers = {
			Accept = "application/json",
			["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8",
		},
		Body = body,
	}, "Overpass", OVERPASS_MAX_ATTEMPTS, isOverpassRetryable):andThen(function(raw)
		if type(raw) ~= "table" or type(raw.elements) ~= "table" then
			logRequestFlow("overpass.invalid_payload", {
				bbox = formatBbox(bbox),
			})
			error("Overpass returned invalid feature data.")
		end

		logRequestFlow("overpass.raw_received", {
			bbox = formatBbox(bbox),
			elements = #(raw.elements or {}),
		})
		setCached(rawKey, raw, configuration.RawCacheTtl)
		return raw
	end), "miss"
end

local function makeRequest(originLat: number, originLon: number, chunkX: number, chunkZ: number, options: any?): Request
	local requestOptions = options or {}
	return {
		originLat = originLat,
		originLon = originLon,
		chunkX = chunkX,
		chunkZ = chunkZ,
		chunkSize = requestOptions.ChunkSize or DEFAULT_CHUNK_SIZE,
		detail = requestOptions.Detail or DEFAULT_DETAIL,
		layers = normalizeLayers(requestOptions.Layers),
		debug = requestOptions.Debug,
	}
end

local function cloneWithCache(payload: any, cacheState: string): any
	local cloned = table.clone(payload)
	cloned.stats = table.clone(payload.stats or {})
	cloned.stats.cache = cacheState
	return cloned
end

local function getChunk(request: Request)
	local chunkKey = makeCacheKey("chunk", {
		request.originLat,
		request.originLon,
		request.chunkX,
		request.chunkZ,
		request.chunkSize,
		request.detail,
		table.concat(request.layers, ","),
		tostring(request.debug == true),
	})

	local cached = getCached(chunkKey)
	if cached ~= nil then
		logRequestFlow("chunk.cache.hit", {
			originLat = request.originLat,
			originLon = request.originLon,
			chunkX = request.chunkX,
			chunkZ = request.chunkZ,
		})
		return Promise.resolve(cloneWithCache(cached, "hit"))
	end

	return getOrRunInflight(chunkKey, function()
		local chunk = getChunkBounds(request)
		local bbox = getPaddedBbox(request)
		logRequestFlow("chunk.generate.start", {
			originLat = request.originLat,
			originLon = request.originLon,
			chunkX = request.chunkX,
			chunkZ = request.chunkZ,
			chunkSize = request.chunkSize,
			detail = request.detail,
			layers = table.concat(request.layers, ","),
			bbox = formatBbox(bbox),
		})
		local rawPromise, rawCache = fetchOverpass(bbox, request.layers, request.detail)

		return rawPromise
			:andThen(function(raw)
				local rawStats = countElements(raw)
				logRequestFlow("chunk.raw_stats", {
					rawCache = rawCache,
					rawStats = rawStats,
				})
				local payload = compileChunkPayload(raw, request, chunk, bbox, rawStats, rawCache)
				logRequestFlow("chunk.compile.done", {
					status = payload.status,
					cache = payload.stats.cache,
					roads = payload.stats.roads,
					buildings = payload.stats.buildings,
					water = payload.stats.water,
					landuse = payload.stats.landuse,
					trees = payload.stats.trees,
					pois = payload.stats.pois,
				})
				setCached(chunkKey, payload, configuration.CacheTtl)
				return cloneWithCache(payload, "miss")
			end)
			:catch(function(errorValue)
				logRequestFlow("chunk.generate.degraded", {
					error = tostring(errorValue),
					chunkX = request.chunkX,
					chunkZ = request.chunkZ,
				})
				return makeEmptyDegradedChunk(
					request,
					chunk,
					bbox,
					"CHUNK_GENERATION_FAILED",
					"Chunk generation failed and no stale cache was available: " .. tostring(errorValue),
					nil,
					rawCache
				)
			end)
	end)
end

local function parseNumber(value: any): number?
	local number = tonumber(value)
	return number
end

local function normalizeBbox(boundingbox: any): { number }?
	if type(boundingbox) ~= "table" or #boundingbox ~= 4 then
		return nil
	end

	local south = parseNumber(boundingbox[1])
	local north = parseNumber(boundingbox[2])
	local west = parseNumber(boundingbox[3])
	local east = parseNumber(boundingbox[4])
	if south == nil or north == nil or west == nil or east == nil then
		return nil
	end

	return { south, west, north, east }
end

local function stringOrNull(value: any): string?
	local text = tostring(value or ""):match("^%s*(.-)%s*$")
	return if text ~= "" then text else nil
end

local function normalizeAddress(address: any)
	local source = if type(address) == "table" then address else {}
	return {
		neighbourhood = stringOrNull(source.neighbourhood or source.suburb),
		city = stringOrNull(source.city or source.town or source.village or source.municipality),
		county = stringOrNull(source.county),
		state = stringOrNull(source.state),
		postcode = stringOrNull(source.postcode),
		country = stringOrNull(source.country),
		countryCode = stringOrNull(source.country_code),
	}
end

local function firstDisplayPart(displayName: any): string?
	local first = tostring(displayName or ""):split(",")[1]
	return stringOrNull(first)
end

local function normalizeKind(place: any): string
	return place.addresstype or place.type or place.category or "place"
end

local function normalizePlace(place: any)
	local displayName = place.display_name or ""
	return {
		name = place.name or firstDisplayPart(displayName),
		displayName = displayName,
		address = normalizeAddress(place.address),
		lat = parseNumber(place.lat),
		lon = parseNumber(place.lon),
		kind = normalizeKind(place),
		importance = parseNumber(place.importance) or 0,
		bbox = normalizeBbox(place.boundingbox),
	}
end

local function getNominatimHeaders(): { [string]: string }
	local headers = {
		Accept = "application/json",
	}
	return headers
end

local function fetchNominatim(path: string, query: { [string]: any })
	query.format = "jsonv2"
	query.addressdetails = 1
	if configuration.NominatimEmail ~= "" then
		query.email = configuration.NominatimEmail
	end

	local url = buildQueryUrl(configuration.NominatimUrl, path, query)
	logRequestFlow("nominatim.request.ready", {
		path = path,
		url = url,
	})

	return requestJson({
		Url = url,
		Method = "GET",
		Headers = getNominatimHeaders(),
	}, "Nominatim")
end

function OSMDirectApiInterface.Configure(options: Configuration)
	if options.OverpassUrl ~= nil then
		configuration.OverpassUrl = options.OverpassUrl
	end
	if options.NominatimUrl ~= nil then
		configuration.NominatimUrl = options.NominatimUrl
	end
	if options.NominatimUserAgent ~= nil then
		configuration.NominatimUserAgent = options.NominatimUserAgent
	end
	if options.NominatimEmail ~= nil then
		configuration.NominatimEmail = options.NominatimEmail
	end
	if options.NominatimReferer ~= nil then
		configuration.NominatimReferer = options.NominatimReferer
	end
	if options.CacheTtl ~= nil then
		configuration.CacheTtl = options.CacheTtl
	end
	if options.RawCacheTtl ~= nil then
		configuration.RawCacheTtl = options.RawCacheTtl
	end
	if options.MaxCacheEntries ~= nil then
		configuration.MaxCacheEntries = options.MaxCacheEntries
	end
	if options.DebugRequests ~= nil then
		configuration.DebugRequests = options.DebugRequests
	end

	logRequestFlow("configure", {
		overpassUrl = configuration.OverpassUrl,
		nominatimUrl = configuration.NominatimUrl,
		cacheTtl = configuration.CacheTtl,
		rawCacheTtl = configuration.RawCacheTtl,
		maxCacheEntries = configuration.MaxCacheEntries,
		debugRequests = configuration.DebugRequests,
	})
	OSMDirectApiInterface.ClearCache()
end

function OSMDirectApiInterface.ClearCache()
	logRequestFlow("cache.clear")
	table.clear(responseCache)
	table.clear(inFlightRequests)
end

function OSMDirectApiInterface.Search(query: string, options: any?)
	local searchOptions = options or {}
	local limit = math.min(searchOptions.Limit or 5, 10)
	local language = searchOptions.Language or "en"
	local cacheKey = makeCacheKey("search", { query:lower(), limit, language })
	logRequestFlow("search.start", {
		query = query,
		limit = limit,
		language = language,
	})
	local cached = getCached(cacheKey)
	if cached ~= nil then
		local cloned = table.clone(cached)
		cloned.cache = "hit"
		logRequestFlow("search.done", {
			cache = "hit",
			results = #(cloned.results or {}),
		})
		return Promise.resolve(cloned)
	end

	return getOrRunInflight(cacheKey, function()
		return fetchNominatim("search", {
			q = query,
			limit = limit,
			["accept-language"] = language,
		})
			:andThen(function(json)
				local results = {}
				for _, place in ipairs(json) do
					local normalized = normalizePlace(place)
					if normalized.lat ~= nil and normalized.lon ~= nil then
						normalized.displayName = nil
						table.insert(results, normalized)
					end
				end

				local payload = {
					query = query:lower():match("^%s*(.-)%s*$"),
					results = results,
					cache = "miss",
				}
				setCached(cacheKey, payload, configuration.CacheTtl)
				logRequestFlow("search.done", {
					cache = payload.cache,
					results = #payload.results,
				})
				return payload
			end)
			:catch(function(errorValue)
				logRequestFlow("search.failed", {
					error = tostring(errorValue),
				})
				return Promise.reject(
					makeProviderRequestError(
						"The geocoding provider is temporarily unavailable: " .. tostring(errorValue),
						503
					)
				)
			end)
	end)
end

local function reverseGeocode(latitude: number, longitude: number, language: string?)
	local selectedLanguage = language or "en"
	local cacheKey = makeCacheKey("reverse", { latitude, longitude, selectedLanguage })
	logRequestFlow("reverse.start", {
		lat = latitude,
		lon = longitude,
		language = selectedLanguage,
	})
	local cached = getCached(cacheKey)
	if cached ~= nil then
		local cloned = table.clone(cached)
		cloned.cache = "hit"
		logRequestFlow("reverse.done", {
			cache = "hit",
			name = cloned.name,
			kind = cloned.kind,
		})
		return Promise.resolve(cloned)
	end

	return getOrRunInflight(cacheKey, function()
		return fetchNominatim("reverse", {
			lat = latitude,
			lon = longitude,
			["accept-language"] = selectedLanguage,
		})
			:andThen(function(json)
				local place = normalizePlace(json)
				local payload = {
					lat = latitude,
					lon = longitude,
					name = place.name,
					kind = place.kind,
					address = place.address,
					bbox = place.bbox,
					cache = "miss",
				}
				setCached(cacheKey, payload, configuration.CacheTtl)
				logRequestFlow("reverse.done", {
					cache = payload.cache,
					name = payload.name,
					kind = payload.kind,
				})
				return payload
			end)
			:catch(function(errorValue)
				logRequestFlow("reverse.degraded", {
					error = tostring(errorValue),
				})
				return {
					lat = latitude,
					lon = longitude,
					name = nil,
					kind = nil,
					address = nil,
					bbox = nil,
					cache = "skip",
					error = {
						code = "GEOCODER_FAILED",
						message = "The reverse geocoding provider is temporarily unavailable: " .. tostring(errorValue),
						statusCode = 503,
					},
				}
			end)
	end)
end

function OSMDirectApiInterface.Reverse(latitude: number, longitude: number, language: string?)
	logRequestFlow("reverse.public.start", {
		lat = latitude,
		lon = longitude,
		language = language or "en",
	})
	return reverseGeocode(latitude, longitude, language):andThen(function(payload: any)
		if payload.error ~= nil then
			logRequestFlow("reverse.public.failed", {
				error = payload.error,
			})
			return Promise.reject(makeProviderRequestError(payload.error.message, payload.error.statusCode))
		end

		logRequestFlow("reverse.public.done", {
			cache = payload.cache,
			name = payload.name,
		})
		return payload
	end)
end

function OSMDirectApiInterface.Initial(latitude: number, longitude: number, options: any?)
	local request = makeRequest(latitude, longitude, 0, 0, options)
	local language = if options ~= nil then options.Language else nil
	logRequestFlow("initial.start", {
		lat = latitude,
		lon = longitude,
		chunkSize = request.chunkSize,
		detail = request.detail,
		layers = table.concat(request.layers, ","),
	})

	return Promise.all({
		getChunk(request),
		reverseGeocode(latitude, longitude, language),
	}):andThen(function(results)
		logRequestFlow("initial.done", {
			chunkStatus = results[1].status,
			chunkCache = results[1].stats and results[1].stats.cache,
			locationCache = results[2].cache,
			locationError = if results[2].error then results[2].error.code else nil,
		})
		return {
			origin = {
				lat = latitude,
				lon = longitude,
			},
			chunk = results[1],
			location = results[2],
		}
	end)
end

function OSMDirectApiInterface.Chunk(options: any)
	local request = makeRequest(options.OriginLat, options.OriginLon, options.ChunkX, options.ChunkZ, options)
	logRequestFlow("chunk.start", {
		originLat = request.originLat,
		originLon = request.originLon,
		chunkX = request.chunkX,
		chunkZ = request.chunkZ,
		chunkSize = request.chunkSize,
		detail = request.detail,
		layers = table.concat(request.layers, ","),
	})
	return getChunk(request)
end

return OSMDirectApiInterface

--!strict

-- Generic 2:1 equirectangular projection helpers.

local Projection = {}

function Projection.GetTilesXYForZoom(zoom: number): (number, number)
	return 2 ^ (zoom + 1), 2 ^ zoom
end

function Projection.GetWorldPixelSize(tileSize: number, zoom: number): Vector2
	local tilesX, tilesY = Projection.GetTilesXYForZoom(zoom)
	return Vector2.new(tilesX * tileSize, tilesY * tileSize)
end

function Projection.LatLonToMap(latitude: number, longitude: number): Vector2
	return Vector2.new(math.clamp((longitude + 180) / 360, 0, 1), math.clamp((90 - latitude) / 180, 0, 1))
end

function Projection.MapToLatLon(mapPosition: Vector2): (number, number)
	return 90 - mapPosition.Y * 180, mapPosition.X * 360 - 180
end

function Projection.NormalisedRingToPoints(ring: any, imageSize: Vector2): { Vector2 }
	local points = {} :: { Vector2 }
	if type(ring) ~= "table" then
		return points
	end

	local index = 1
	while index < #ring do
		local x = tonumber(ring[index])
		local y = tonumber(ring[index + 1])
		if x and y then
			table.insert(points, Vector2.new(x * imageSize.X, y * imageSize.Y))
		end
		index += 2
	end

	return points
end

return Projection

--!strict

-- OSM payload-shape helpers. Renderers should ask this module how to read OSM
-- chunks, then pass interpreted coordinates/primitives to MapSystem.

local OSMChunkInterpreter = {}

function OSMChunkInterpreter.FiniteNumber(value: any): number?
	local numberValue = tonumber(value)
	if numberValue and numberValue == numberValue and numberValue ~= math.huge and numberValue ~= -math.huge then
		return numberValue
	end
	return nil
end

function OSMChunkInterpreter.GetMapData(data: any): any
	if type(data) == "table" and type(data.chunk) == "table" and type(data.chunk.roads) == "table" then
		return data.chunk
	end

	return data
end

function OSMChunkInterpreter.GetChunkBounds(data: any): (number, number, number, number)
	local chunk = data.chunk or {}
	local minX = tonumber(chunk.minX) or 0
	local minZ = tonumber(chunk.minZ) or 0
	local maxX = tonumber(chunk.maxX) or (minX + (tonumber(chunk.size) or 256))
	local maxZ = tonumber(chunk.maxZ) or (minZ + (tonumber(chunk.size) or 256))

	if maxX <= minX then
		maxX = minX + 1
	end
	if maxZ <= minZ then
		maxZ = minZ + 1
	end

	return minX, minZ, maxX, maxZ
end

function OSMChunkInterpreter.GetChunkKey(chunkX: number, chunkZ: number): string
	return string.format("%d:%d", chunkX, chunkZ)
end

function OSMChunkInterpreter.ReadPointCoordinates(point: any, isRoad: boolean): (number?, number?)
	if type(point) ~= "table" then
		return nil, nil
	end

	local x = OSMChunkInterpreter.FiniteNumber(point[1])
	local preferredZ = if isRoad then OSMChunkInterpreter.FiniteNumber(point[3]) else OSMChunkInterpreter.FiniteNumber(point[2])
	local fallbackZ = if isRoad then OSMChunkInterpreter.FiniteNumber(point[2]) else OSMChunkInterpreter.FiniteNumber(point[3])
	local z = preferredZ or fallbackZ
	if not x or not z then
		return nil, nil
	end

	return x, z
end

return OSMChunkInterpreter

--!strict

--[=[
	Summarises the decoded OSM payload into per-layer counts and density labels.
	The counts come from the parsed feature arrays when available, with
	`chunk.stats` used as a fallback if a collection is missing.
]=]

local OsmApiReturnedDataUtils = {}

export type Density = "None" | "Low" | "Medium" | "High"

export type Counts = {
	Roads: number,
	Buildings: number,
	Water: number,
	POIs: number,
}

export type Amounts = {
	Roads: Density,
	Buildings: Density,
	Water: Density,
	POIs: Density,
}

export type Summary = {
	Counts: Counts,
	Densities: Amounts,
}

local DENSITY_BOUNDS = {
	Low = 1,
	Medium = 25,
	High = 100,
}

local function countArray(value: any): number
	if type(value) ~= "table" then
		return 0
	end

	local count = 0
	for _ in ipairs(value) do
		count += 1
	end

	return count
end

local function readCount(collection: any, stats: any, key: string): number
	local count = countArray(collection)
	if count > 0 then
		return count
	end

	if type(stats) == "table" then
		local statCount = tonumber(stats[key])
		if statCount then
			return statCount
		end
	end

	return 0
end

local function getDensity(count: number): Density
	if count <= 0 then
		return "None"
	end

	if count < DENSITY_BOUNDS.Medium then
		return "Low"
	end

	if count < DENSITY_BOUNDS.High then
		return "Medium"
	end

	return "High"
end

function OsmApiReturnedDataUtils.Process(osmApiReturnedData: any): Summary
	local chunk = if type(osmApiReturnedData) == "table" then osmApiReturnedData.chunk else nil
	local stats = if type(chunk) == "table" then chunk.stats else nil

	local counts = {
		Roads = readCount(if type(chunk) == "table" then chunk.roads else nil, stats, "roads"),
		Buildings = readCount(if type(chunk) == "table" then chunk.buildings else nil, stats, "buildings"),
		Water = readCount(if type(chunk) == "table" then chunk.water else nil, stats, "water"),
		POIs = readCount(if type(chunk) == "table" then chunk.pois else nil, stats, "pois"),
	} :: Counts

	return {
		Counts = counts,
		Densities = {
			Roads = getDensity(counts.Roads),
			Buildings = getDensity(counts.Buildings),
			Water = getDensity(counts.Water),
			POIs = getDensity(counts.POIs),
		},
	}
end

function OsmApiReturnedDataUtils.Calculate(osmApiReturnedData: any): Amounts
	local summary = OsmApiReturnedDataUtils.Process(osmApiReturnedData)
	return {
		Roads = summary.Densities.Roads,
		Buildings = summary.Densities.Buildings,
		Water = summary.Densities.Water,
		POIs = summary.Densities.POIs,
	}
end

return OsmApiReturnedDataUtils

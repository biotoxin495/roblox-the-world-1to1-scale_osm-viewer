--!strict

--[=[
	OSM-specific interpreter for simplified world/country vector data.

	This is the adapter layer between OSM-ish payloads and the context-agnostic
	MapSystem raster primitives. Keep source-data assumptions here, not in the
	generic MapSystem package.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapSystem = ReplicatedStorage.App.Shared.Packages.MapSystem
local EquirectangularProjection = require(MapSystem.EquirectangularProjection)

local SimplifiedWorldInterpreter = {}

export type SimplifiedMapData = {
	Features: { any }?,
	Meta: any?,
}

export type Style = {
	FillColour: Color3?,
	LineColour: Color3?,
	LineThickness: number,
}

export type Operation =
	{ Kind: "Polygon", Points: { Vector2 }, Colour: Color3, Step: number? }
	| { Kind: "Segment", From: Vector2, To: Vector2, Thickness: number, Colour: Color3 }

export type Options = {
	BatchSize: number?,
	ShouldContinue: (() -> boolean)?,
	Yield: (() -> ())?,
}

function SimplifiedWorldInterpreter.ForEachOperation(
	data: SimplifiedMapData,
	imageSize: Vector2,
	style: Style,
	callback: (Operation) -> (),
	options: Options?
)
	local features = data.Features
	if type(features) ~= "table" then
		return
	end

	local batchSize = (options and options.BatchSize) or math.huge
	local shouldContinue = options and options.ShouldContinue
	local yield = options and options.Yield
	local processedRings = 0

	for _, feature in ipairs(features) do
		local polygons = if type(feature) == "table" then feature.Polygons else nil
		if type(polygons) ~= "table" then
			continue
		end

		for _, polygon in ipairs(polygons) do
			if type(polygon) ~= "table" then
				continue
			end

			for _, ring in ipairs(polygon) do
				local points = EquirectangularProjection.NormalisedRingToPoints(ring, imageSize)
				if #points < 2 then
					continue
				end

				if style.FillColour and #points >= 3 then
					callback({
						Kind = "Polygon",
						Points = points,
						Colour = style.FillColour,
						Step = 2,
					})
				end
				if style.LineColour then
					for index, point in ipairs(points) do
						local nextPoint = points[index % #points + 1]
						callback({
							Kind = "Segment",
							From = point,
							To = nextPoint,
							Thickness = style.LineThickness,
							Colour = style.LineColour,
						})
					end
				end

				processedRings += 1
				if processedRings >= batchSize then
					processedRings = 0
					if shouldContinue and not shouldContinue() then
						return
					end
					if yield then
						yield()
					end
				end
			end
		end
	end
end

return SimplifiedWorldInterpreter

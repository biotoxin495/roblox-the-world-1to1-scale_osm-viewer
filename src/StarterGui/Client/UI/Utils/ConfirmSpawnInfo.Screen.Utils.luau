--!strict

-- Compatibility shim.
-- New games should require:
-- ReplicatedStorage.App.Shared.Packages.OSMMap.ChunkPreviewRenderer

local ReplicatedStorage = game:GetService("ReplicatedStorage")

return require(ReplicatedStorage.App.Shared.Packages.OSMMap.ChunkPreviewRenderer)

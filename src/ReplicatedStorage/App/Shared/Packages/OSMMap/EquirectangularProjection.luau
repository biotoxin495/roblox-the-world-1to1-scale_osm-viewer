--!strict

-- Compatibility shim for older OSMMap imports.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return require(ReplicatedStorage.App.Shared.Packages.MapSystem.EquirectangularProjection)

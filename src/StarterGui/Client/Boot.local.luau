--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.App.Shared.Framework.Loader)

Loader.RunFolderOnce("Client", script.Parent, {
	Label = "Client",
})

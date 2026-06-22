local UIRoot = require(script.Parent.Parent.UIRoot)
local UIController = require(script.Parent.Parent.Parent.Controllers.UIController)

local IngameHUD = {}
IngameHUD.__index = IngameHUD
IngameHUD.Name = "IngameHUD"

function IngameHUD:StartFunctions(parsedData)
	local ingameHUD = UIRoot.GetScreens():WaitForChild("IngameHUD")

	print("IngameHUD:StartFunctions called with data:", parsedData)
end

function IngameHUD:StopFunctions()
	local ingameHUD = UIRoot.GetScreens():WaitForChild("IngameHUD")
	print("IngameHUD:StopFunctions called")
end

return IngameHUD

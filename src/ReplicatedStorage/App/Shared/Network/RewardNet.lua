--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetUtil = require(script.Parent.NetUtil)
local Middleware = require(script.Parent.Middleware)
local Promise = require(ReplicatedStorage.App.Shared.Packages.Promise)

export type ClaimRewardResult = {
	Ok: boolean,
	Amount: number?,
	Reason: string?,
}

export type ClaimDailyRewardHandler = (player: Player) -> ClaimRewardResult

local REMOTE_NAME = "Reward/ClaimDailyReward"

local RewardNet = {}

RewardNet.Client = {}

function RewardNet.Client.ClaimDailyReward(): ClaimRewardResult
	local remote = NetUtil.GetFunction(REMOTE_NAME)

	return remote:InvokeServer() :: ClaimRewardResult
end

function RewardNet.Client.ClaimDailyRewardAsync()
	return Promise.new(function(resolve, reject)
		local ok, result = pcall(RewardNet.Client.ClaimDailyReward)

		if ok then
			resolve(result)
		else
			reject(result)
		end
	end)
end

RewardNet.Server = {}

local function rejectClaimDailyReward(reason: string): ClaimRewardResult
	return {
		Ok = false,
		Reason = reason,
	}
end

function RewardNet.Server.BindClaimDailyReward(handler: ClaimDailyRewardHandler)
	print("[RewardNet] Binding server function for ClaimDailyReward")
	local remote = NetUtil.GetFunction(REMOTE_NAME)

	Middleware.BindServerFunction(remote, REMOTE_NAME, function(context: Middleware.NetworkContext): ClaimRewardResult
		return handler(context.Player)
	end, {
		Middleware.RateLimit({
			Window = 10,
			MaxCalls = 1,
			Reason = "You are claiming rewards too quickly.",
		}),
	}, rejectClaimDailyReward)
end

return RewardNet

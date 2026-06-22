--!strict

--[[
	Server-side network middleware for typed feature network modules.

	The feature modules still own their typed API. This file only provides reusable
	server protection behavior: validation, rate limiting, and safe error handling.
]]

local Middleware = {}

export type NetworkContext = {
	Player: Player,
	RemoteName: string,
	Kind: "Function" | "Event",
	Reject: (reason: string) -> any,
}

export type Handler = (context: NetworkContext, ...any) -> any
export type MiddlewareFn = (context: NetworkContext, next: Handler, ...any) -> any
export type RejectFactory = (reason: string) -> any

export type RateLimitOptions = {
	Window: number,
	MaxCalls: number,
	Reason: string?,
}

local function defaultReject(reason: string): any
	return {
		Ok = false,
		Reason = reason,
	}
end

local function compose(middlewares: { MiddlewareFn }?, handler: Handler): Handler
	local pipeline = handler

	if middlewares == nil then
		return pipeline
	end

	for index = #middlewares, 1, -1 do
		local middleware = middlewares[index]
		local nextHandler = pipeline

		pipeline = function(context: NetworkContext, ...: any): any
			return middleware(context, nextHandler, ...)
		end
	end

	return pipeline
end

function Middleware.Reject(context: NetworkContext, reason: string): any
	return context.Reject(reason)
end

function Middleware.ValidateArgs(validator: (...any) -> (boolean, string?)): MiddlewareFn
	return function(context: NetworkContext, next: Handler, ...: any): any
		local ok, reason = validator(...)

		if not ok then
			return Middleware.Reject(context, reason or "Invalid request.")
		end

		return next(context, ...)
	end
end

function Middleware.RateLimit(options: RateLimitOptions): MiddlewareFn
	assert(options.Window > 0, "RateLimit.Window must be greater than 0.")
	assert(options.MaxCalls > 0, "RateLimit.MaxCalls must be greater than 0.")

	local buckets: { [Player]: { StartedAt: number, Count: number } } = setmetatable({}, {
		__mode = "k",
	}) :: any

	local window = options.Window
	local maxCalls = options.MaxCalls
	local reason = options.Reason or "Too many requests."

	return function(context: NetworkContext, next: Handler, ...: any): any
		local now = os.clock()
		local bucket = buckets[context.Player]

		if bucket == nil or now - bucket.StartedAt > window then
			bucket = {
				StartedAt = now,
				Count = 0,
			}

			buckets[context.Player] = bucket
		end

		bucket.Count += 1

		if bucket.Count > maxCalls then
			warn(("[Network:%s] Rate limit exceeded by %s"):format(context.RemoteName, context.Player.Name))
			return Middleware.Reject(context, reason)
		end

		return next(context, ...)
	end
end

function Middleware.BindServerFunction(
	remote: RemoteFunction,
	remoteName: string,
	handler: Handler,
	middlewares: { MiddlewareFn }?,
	rejectFactory: RejectFactory?
)
	local pipeline = compose(middlewares, handler)
	local makeReject = rejectFactory or defaultReject

	print("binding server function for remote:", remoteName)

	remote.OnServerInvoke = function(player: Player, ...: any): any
		print("invoked by player ", player, " for remote ", remoteName)
		local context: NetworkContext = {
			Player = player,
			RemoteName = remoteName,
			Kind = "Function",
			Reject = makeReject,
		}

		local ok, result = pcall(function(...: any): any
			return pipeline(context, ...)
		end, ...)

		if not ok then
			warn(("[Network:%s] Handler failed: %s"):format(remoteName, tostring(result)))
			return makeReject("Internal server error.")
		end

		return result
	end
end

function Middleware.ConnectServerEvent(
	remote: RemoteEvent,
	remoteName: string,
	handler: Handler,
	middlewares: { MiddlewareFn }?
): RBXScriptConnection
	local pipeline = compose(middlewares, handler)

	return remote.OnServerEvent:Connect(function(player: Player, ...: any)
		local context: NetworkContext = {
			Player = player,
			RemoteName = remoteName,
			Kind = "Event",
			Reject = function(reason: string)
				warn(("[Network:%s] Rejected event from %s: %s"):format(remoteName, player.Name, reason))
				return nil
			end,
		}

		local ok, err = pcall(function(...: any)
			pipeline(context, ...)
		end, ...)

		if not ok then
			warn(("[Network:%s] Event handler failed: %s"):format(remoteName, tostring(err)))
		end
	end)
end

return Middleware

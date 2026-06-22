--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NetUtil = {}

local ROOT_FOLDER_NAME = "AppRemotes"
local CLIENT_WAIT_TIMEOUT = 10

local function getRootFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(ROOT_FOLDER_NAME)

	if existing ~= nil then
		assert(existing:IsA("Folder"), ROOT_FOLDER_NAME .. " must be a Folder.")
		return existing
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = ROOT_FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end

	local folder = ReplicatedStorage:WaitForChild(ROOT_FOLDER_NAME, CLIENT_WAIT_TIMEOUT)
	assert(folder ~= nil and folder:IsA("Folder"), "Timed out waiting for " .. ROOT_FOLDER_NAME)
	return folder :: Folder
end

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)

	if existing ~= nil then
		assert(existing:IsA("Folder"), name .. " must be a Folder.")
		return existing
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
		return folder
	end

	local folder = parent:WaitForChild(name, CLIENT_WAIT_TIMEOUT)
	assert(folder ~= nil and folder:IsA("Folder"), "Timed out waiting for remote folder " .. name)
	return folder :: Folder
end

local function splitPath(path: string): {string}
	local parts = {}

	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end

	assert(#parts > 0, "Remote path cannot be empty.")
	return parts
end

local function getParentFolder(path: string): (Folder, string)
	local parts = splitPath(path)
	local remoteName = parts[#parts]
	table.remove(parts, #parts)

	local parent: Instance = getRootFolder()

	for _, folderName in ipairs(parts) do
		parent = getOrCreateFolder(parent, folderName)
	end

	return parent :: Folder, remoteName
end

local function getOrCreateRemote<T>(path: string, className: string): T
	local parent, remoteName = getParentFolder(path)
	local existing = parent:FindFirstChild(remoteName)

	if existing ~= nil then
		assert(existing.ClassName == className, path .. " must be a " .. className .. ".")
		return existing :: any
	end

	if RunService:IsServer() then
		local remote = Instance.new(className)
		remote.Name = remoteName
		remote.Parent = parent
		return remote :: any
	end

	local remote = parent:WaitForChild(remoteName, CLIENT_WAIT_TIMEOUT)
	assert(remote ~= nil and remote.ClassName == className, "Timed out waiting for remote " .. path)
	return remote :: any
end

function NetUtil.GetEvent(path: string): RemoteEvent
	return getOrCreateRemote(path, "RemoteEvent")
end

function NetUtil.GetFunction(path: string): RemoteFunction
	return getOrCreateRemote(path, "RemoteFunction")
end

return NetUtil

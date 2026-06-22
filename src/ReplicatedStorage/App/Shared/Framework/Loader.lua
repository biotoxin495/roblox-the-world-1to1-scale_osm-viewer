--!strict

--[[
	Lifecycle loader with convention-based auto-discovery.

	The loader is intentionally small:
	- It discovers lifecycle modules from folders.
	- It runs Init on every discovered unit.
	- It then runs Start on every discovered unit.

	It does not act as a service locator or Kernel. Modules should still directly
	require the dependencies they use so Luau/VS Code autocomplete can understand
	the actual returned module types.
]]

local Loader = {}

-- ModuleScript requires are cached per Luau VM. This makes a run key a
-- process-local guard: one server startup and one startup for each client.
local startedRunKeys: { [string]: boolean } = {}

export type Unit = {
	Name: string?,
	Priority: number?,
	Load: boolean?,
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
	Destroy: ((self: any) -> ())?,
}

export type RunOptions = {
	Label: string?,
	Recursive: boolean?,
	IncludeSuffixes: { string }?,
	ExcludeSuffixes: { string }?,
}

local DEFAULT_INCLUDE_SUFFIXES = {
	"Service",
	"Controller",
	"System",
	"Component",
}

local DEFAULT_EXCLUDE_SUFFIXES = {
	"Types",
	"Type",
	"Util",
	"Utils",
	"Config",
	"Constants",
	"View",
	"Views",
	"Net",
	"Network",
	"Middleware",
}

local function getUnitName(unit: Unit, index: number): string
	return unit.Name or ("Unit" .. tostring(index))
end

local function copyUnits(units: { Unit }): { Unit }
	local result = {}

	for _, unit in ipairs(units) do
		table.insert(result, unit)
	end

	return result
end

local function endsWith(value: string, suffix: string): boolean
	if suffix == "" then
		return false
	end

	return string.sub(value, -#suffix) == suffix
end

local function matchesAnySuffix(value: string, suffixes: { string }): boolean
	for _, suffix in ipairs(suffixes) do
		if endsWith(value, suffix) then
			return true
		end
	end

	return false
end

local function isInsideRoots(instance: Instance, roots: { Instance }): boolean
	for _, root in ipairs(roots) do
		if instance == root then
			return true
		end
	end

	return false
end

local function isPrivateName(name: string): boolean
	return string.sub(name, 1, 1) == "_"
end

local function isInPrivatePath(instance: Instance, roots: { Instance }): boolean
	if isPrivateName(instance.Name) then
		return true
	end

	local current = instance.Parent

	while current ~= nil do
		if isInsideRoots(current, roots) then
			return false
		end

		if isPrivateName(current.Name) then
			return true
		end

		current = current.Parent
	end

	return false
end

local function shouldConsiderModule(moduleScript: ModuleScript, roots: { Instance }, options: RunOptions): boolean
	if isInPrivatePath(moduleScript, roots) then
		return false
	end

	local includeSuffixes = options.IncludeSuffixes or DEFAULT_INCLUDE_SUFFIXES
	local excludeSuffixes = options.ExcludeSuffixes or DEFAULT_EXCLUDE_SUFFIXES
	local name = moduleScript.Name

	if matchesAnySuffix(name, excludeSuffixes) then
		return false
	end

	return matchesAnySuffix(name, includeSuffixes)
end

local function collectModuleScripts(root: Instance, recursive: boolean, result: { ModuleScript })
	if root:IsA("ModuleScript") then
		table.insert(result, root)
		return
	end

	local descendants

	if recursive then
		descendants = root:GetDescendants()
	else
		descendants = root:GetChildren()
	end

	for _, descendant in ipairs(descendants) do
		if descendant:IsA("ModuleScript") then
			table.insert(result, descendant)
		end
	end
end

local function getModuleSortKey(moduleScript: ModuleScript): string
	return moduleScript:GetFullName()
end

function Loader.Discover(roots: { Instance }, options: RunOptions?): { Unit }
	local resolvedOptions: RunOptions = options or {}
	local recursive: boolean = true

	if resolvedOptions.Recursive ~= nil then
		recursive = resolvedOptions.Recursive
	end

	local moduleScripts: { ModuleScript } = {}

	for _, root in ipairs(roots) do
		assert(typeof(root) == "Instance", "[Loader] Discover roots must be Instances.")
		collectModuleScripts(root, recursive, moduleScripts)
	end

	table.sort(moduleScripts, function(a: ModuleScript, b: ModuleScript): boolean
		return getModuleSortKey(a) < getModuleSortKey(b)
	end)

	local units: { Unit } = {}
	local label = resolvedOptions.Label or "Runtime"

	for _, moduleScript in ipairs(moduleScripts) do
		if shouldConsiderModule(moduleScript, roots, resolvedOptions) then
			local ok, result = pcall(require, moduleScript)

			if not ok then
				error(
					"[Loader:"
						.. label
						.. "] Failed to require "
						.. moduleScript:GetFullName()
						.. ":\n"
						.. tostring(result),
					0
				)
			end

			assert(
				typeof(result) == "table",
				"[Loader:" .. label .. "] " .. moduleScript:GetFullName() .. " must return a table."
			)

			local unit = result :: Unit

			if unit.Load ~= false then
				if unit.Name == nil then
					unit.Name = moduleScript.Name
				end

				table.insert(units, unit)
			end
		end
	end

	return units
end

function Loader.Run(units: { Unit }, label: string?): { Unit }
	local scope = label or "Runtime"
	local ordered = copyUnits(units)

	table.sort(ordered, function(a: Unit, b: Unit): boolean
		return (a.Priority or 0) < (b.Priority or 0)
	end)

	local seen: { [string]: boolean } = {}

	for index, unit in ipairs(ordered) do
		assert(typeof(unit) == "table", "[Loader:" .. scope .. "] Every unit must be a table.")

		local name = getUnitName(unit, index)
		assert(not seen[name], "[Loader:" .. scope .. "] Duplicate unit name: " .. name)
		seen[name] = true
	end

	for index, unit in ipairs(ordered) do
		local init = unit.Init

		if init ~= nil then
			local ok, err = pcall(function(): any
				return init(unit)
			end)

			if not ok then
				error(
					"[Loader:" .. scope .. "] Init failed for " .. getUnitName(unit, index) .. ":\n" .. tostring(err),
					0
				)
			end
		end
	end

	for index, unit in ipairs(ordered) do
		local start = unit.Start

		if start ~= nil then
			local ok, err = pcall(function(): any
				return start(unit)
			end)

			if not ok then
				error(
					"[Loader:" .. scope .. "] Start failed for " .. getUnitName(unit, index) .. ":\n" .. tostring(err),
					0
				)
			end
		end
	end

	return ordered
end

function Loader.RunFolders(roots: { Instance }, options: RunOptions?): { Unit }
	local resolvedOptions: RunOptions = options or {}
	local units = Loader.Discover(roots, resolvedOptions)
	return Loader.Run(units, resolvedOptions.Label)
end

function Loader.RunFolder(root: Instance, options: RunOptions?): { Unit }
	return Loader.RunFolders({ root }, options)
end

function Loader.RunFolderOnce(runKey: string, root: Instance, options: RunOptions?): { Unit }
	assert(runKey ~= "", "[Loader] Run key cannot be empty.")

	if startedRunKeys[runKey] then
		warn("[Loader:" .. runKey .. "] Duplicate boot ignored.")
		return {}
	end

	-- Mark before discovery so a second boot cannot interleave and run the same
	-- lifecycle modules while the first boot is initializing them.
	startedRunKeys[runKey] = true

	return Loader.RunFolder(root, options)
end

return Loader

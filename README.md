# Roblox Modular Loader v4

A minimal Roblox project skeleton focused on modular structure, strong Luau IntelliSense, typed networking, sane UI separation, and automatic lifecycle discovery.

## Main idea

The project uses a hybrid loading approach:

- Boot scripts point at the client/server root, not individual modules.
- The loader automatically discovers lifecycle modules by naming convention.
- Services/controllers still directly `require(...)` the modules they actually depend on.
- No central Kernel is passed around.
- No manual `Registry.lua` files are needed.

This keeps the old convenience of automatic loading while avoiding the IntelliSense problems caused by large dynamic dependency tables.

## Current structure

```txt
src
├─ ReplicatedStorage
│  └─ App
│     └─ Shared
│        ├─ Framework
│        │  └─ Loader.lua
│        ├─ Network
│        │  ├─ NetUtil.lua
│        │  ├─ Middleware.lua
│        │  ├─ CurrencyNet.lua
│        │  └─ InventoryNet.lua
│        └─ Packages
│           ├─ Promise.lua
│           └─ Signal.lua
├─ ServerScriptService
│  └─ Server
│     ├─ Boot.server.lua
│     └─ Services
│        ├─ PlayerDataService.lua
│        ├─ CurrencyService.lua
│        └─ InventoryService.lua
└─ StarterPlayer
   └─ StarterPlayerScripts
      └─ Client
         ├─ Boot.client.lua
         ├─ Controllers
         │  ├─ HUDController.lua
         │  └─ InputController.lua
         └─ UI
            ├─ UIRoot.lua
            └─ Views
               └─ HUDView.lua
```

## Auto-discovery lifecycle

Server boot:

```lua
local Loader = require(ReplicatedStorage.App.Shared.Framework.Loader)

Loader.RunFolder(script.Parent, {
	Label = "Server",
})
```

Client boot:

```lua
local Loader = require(ReplicatedStorage.App.Shared.Framework.Loader)

Loader.RunFolder(script.Parent, {
	Label = "Client",
})
```

The loader recursively scans those roots and loads modules whose names end with one of these suffixes:

```txt
Service
Controller
System
Component
```

It ignores helper-style suffixes by default:

```txt
Types
Type
Util
Utils
Config
Constants
View
Views
Net
Network
Middleware
```

It also ignores modules or folders that start with `_`.

Example:

```txt
Services
├─ PlayerDataService.lua     loaded
├─ InventoryService.lua      loaded
├─ ItemConfig.lua            ignored
├─ InventoryTypes.lua        ignored
└─ _Private
   └─ SomeService.lua        ignored
```

## Adding a new service

Create a ModuleScript under `Server/Services` with a loadable suffix:

```lua
--!strict

local ExampleService = {
	Name = "ExampleService",
	Priority = 40,
}

function ExampleService:Init()
	-- Prepare internal state here.
end

function ExampleService:Start()
	-- Connect events, bind networking, or start runtime behavior here.
end

return ExampleService
```

No registry update. No boot script update.

## Adding a new controller

Create a ModuleScript under `Client/Controllers` with a loadable suffix:

```lua
--!strict

local ExampleController = {
	Name = "ExampleController",
	Priority = 20,
}

function ExampleController:Init()
	-- Create UI, load local state, etc.
end

function ExampleController:Start()
	-- Connect input, network listeners, UI signals, etc.
end

return ExampleController
```

No registry update. No boot script update.

## Dependency rule

Auto-discovery is only for lifecycle startup.

When a module needs another module, directly require it:

```lua
local PlayerDataService = require(script.Parent.PlayerDataService)
```

Avoid this pattern:

```lua
function InventoryService:Init(kernel)
	self.PlayerDataService = kernel.PlayerDataService
end
```

Direct requires are the part that keeps Luau autocomplete useful.

## UI rule

Controllers own behavior. Views own Roblox UI instances.

For example:

- `HUDController` listens to networking, owns UI behavior, and reacts to view signals.
- `HUDView` creates the `ScreenGui`, labels, button, and exposes typed UI signals.

This prevents UI code from becoming tangled with services and networking.

## Networking rule

Gameplay code should use typed network contracts, not raw remotes.

Use this:

```lua
local InventoryNet = require(ReplicatedStorage.App.Shared.Network.InventoryNet)

InventoryNet.Client.RequestAddItemAsync("ExampleItem")
```

Avoid this in gameplay code:

```lua
SomeRemote:FireServer("Inventory", "AddItem", "ExampleItem")
```

Typed feature network modules preserve discoverability and keep remote names centralized.

## Middleware

`Shared/Network/Middleware.lua` includes reusable server-side middleware for:

- rate limiting
- argument validation
- safe handler execution
- standard rejection responses

Feature network modules decide which middleware applies to each request.

## Promise and Signal

`Shared/Packages/Promise.lua` and `Shared/Packages/Signal.lua` are lightweight integrated modules so the project works immediately.

For production, you can replace them with the official community packages, such as evaera's Promise and sleitnick's Signal, while keeping the rest of the architecture the same.

## Context

Read `CONTEXT.md` for the architectural reasoning, conventions, and rules for future work.

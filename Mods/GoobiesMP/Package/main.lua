-- Managed entry: staging places the existing startup chunk and modules in Package/lib.
local ctx = ...
assert(type(ctx) == "table" and type(ctx.packagePath) == "string", "GoobiesMP framework context unavailable")
local modules = ctx.packagePath .. "/Package/lib"
local chunk = assert(loadfile(modules .. "/main.lua", "t", _G))
return chunk({framework=ctx, scriptDir=modules})

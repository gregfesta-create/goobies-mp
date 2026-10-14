-- Bounded cosmetic state; no game access or identity claims.
local V={}
local fields={'pitch','yaw','roll','motion'}
function V.meshPath(model)
    if math.type(model)~='integer' or model<1 or model>5 then return nil end
    local name=string.format('SM_Player%02d',model)
    return '/Game/Meshes/Player/'..name..'.'..name
end
function V.meshId(name)
    for i=1,5 do if name=='StaticMesh '..V.meshPath(i) then return i end end
    return 0
end
function V.valid(p)
    if type(p)~='table' then return false end
    for _,k in ipairs(fields) do
        local n=p[k]
        if math.type(n)~='integer' or math.abs(n)>(k=='motion' and 10000 or 18000) then return false end
    end
    if p.model~=nil and (math.type(p.model)~='integer' or p.model<0 or p.model>5) then return false end
    return p.motion>=0
end
function V.pack(p)
    if type(p)~='table' then return nil end
    local out={}
    for _,k in ipairs(fields) do
        local n=p[k]
        if type(n)~='number' or n~=n or math.abs(n)==math.huge then return nil end
        if k~='motion' then n=(n+180)%360-180 end
        out[k]=math.tointeger(math.floor(n*(k=='motion' and 1000 or 100)+.5))
    end
    if p.mesh then out.model=V.meshId(p.mesh) end
    return V.valid(out) and out or nil
end
function V.copy(p)
    if not V.valid(p) then return nil end
    return {pitch=p.pitch,yaw=p.yaw,roll=p.roll,motion=p.motion,model=p.model}
end
function V.blend(a,b,t)
    if not a then return V.copy(b) end
    if not b then return nil end
    local out={}
    out.model=b.model
    for _,k in ipairs(fields) do
        local d=b[k]-a[k]
        if k~='motion' then d=(d+18000)%36000-18000 end
        local v=a[k]+d*t
        if k~='motion' then v=(v+18000)%36000-18000 end
        out[k]=math.tointeger(math.floor(v+.5))
    end
    return out
end
return V

-- Verified catalogue input; transport tokens are not Unreal class paths.
local Limits=require('gmp_config').LOBBY
local L={}
local function token(s)
    return type(s)=='string' and #s>0 and #s<=Limits.MAX_TOKEN_BYTES
        and s:match('^[%w_%- ]+$') and not s:match('^%s') and not s:match('%s$')
end
function L.Catalogue(value)
    if type(value)~='table' then return nil,'catalogue_unavailable' end
    local out={classes={},artifacts={}}
    for _,domain in ipairs{'classes','artifacts'} do
        if type(value[domain])~='table' or #value[domain]>256 then return nil,'invalid_catalogue' end
        local seen={}
        for _,entry in ipairs(value[domain]) do
            if type(entry)~='table' or not token(entry.id) or type(entry.label)~='string'
                or #entry.label<1 or #entry.label>128 or seen[entry.id:lower()]
                or type(entry.available)~='boolean' then return nil,'invalid_catalogue' end
            seen[entry.id:lower()]=true
            out[domain][#out[domain]+1]={id=entry.id,label=entry.label,available=entry.available}
        end
    end
    return out
end
function L.Artifacts(text)
    local out={}
    for id in tostring(text or ''):gmatch('[^+]+') do out[#out+1]=id end
    return out
end
function L.Same(a,b)
    if type(a)~='table' or type(b)~='table' or a.class~=b.class then return false end
    local function canonical(text)
        if type(text)~='string' or #text>Limits.MAX_ARTIFACTS*(Limits.MAX_TOKEN_BYTES+1) then return nil end
        local selected,seen=L.Artifacts(text),{}
        if #selected>Limits.MAX_ARTIFACTS then return nil end
        for _,id in ipairs(selected) do if not token(id) or seen[id] then return nil end;seen[id]=true end
        table.sort(selected);return table.concat(selected,'+')
    end
    local left,right=canonical(a.artifacts),canonical(b.artifacts)
    return left~=nil and right~=nil and left==right
end
function L.Change(catalogue,current,kind,id)
    local domain=kind=='class' and 'classes' or kind=='artifact' and 'artifacts'
    if not domain then return nil,'bad_selection' end
    local allowed=false
    for _,choice in ipairs(catalogue[domain]) do if choice.id==id then allowed=choice.available end end
    if not allowed then return nil,'selection_unavailable' end
    local result={class=current.class or '',artifacts=current.artifacts or ''}
    if kind=='class' then result.class=id;return result end
    local selected=L.Artifacts(result.artifacts);local found
    for i,value in ipairs(selected) do if value==id then found=i;break end end
    if found then table.remove(selected,found)
    elseif #selected>=Limits.MAX_ARTIFACTS then return nil,'too_many_artifacts'
    else selected[#selected+1]=id end
    result.artifacts=table.concat(selected,'+');return result
end
return L

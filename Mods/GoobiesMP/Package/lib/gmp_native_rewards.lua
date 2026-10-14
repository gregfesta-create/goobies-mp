-- Native reward continuity slice: retain existing widget and queued choices.
-- Recreating active roulette/picker widgets and item-offer structs is pending.
local R={};R.__index=R
R.CompleteCapture=false;R.CompleteRestore=false
local fields={rarity='OverrideRarity_2_AA0E26F64AAE65768C0A9EBD9D4A352B',
    isItem='IsItem?_13_696CD91741855A1C980CF39AAC1FF3DD',
    text='Text_14_18130E2747923D6BCF8B8E9EC13FE906',
    xpMultiplier='DissolveXPMulti_17_72FCC8F0419C14C6BCC205B8F51C4155',
    customText='CustomText?_20_4B27EA8546C98590EA34AEAD690925E9',
    items='Items_24_DF09D88646EE51A7016617BE105B7873'}
R.Fields=fields
R.ItemFields={index='DT_index_13_F9FE29E14CA7B884284E7F8FBD7EF470',
    rarity='Rarity_10_76505F814BB0D5EFE72490915E3F1030',
    character='CharacterSpecific_6_51CF7B0D4F30B1965AEFA4A929F4389C',
    actor='Actor_3_09A71EC44F4F2584D7EB1084695EE571'}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<=1e12 end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end;return true
end
function R.new(world) return setmetatable({world=world},R) end
function R:Capture()
    local ok,s=pcall(function()
        local w=self.world:_world();local pawn=w and self.world:_pawn(w);if not pawn then return nil end
        assert(type(pawn['PresentTime?'])=='boolean','missing_present_flag')
        assert(#pawn.PresentQueue<=256,'reward_queue_limit')
        local out={version=1,pawn=pawn:GetFullName(),active=pawn['PresentTime?'],queue={}}
        pawn.PresentQueue:ForEach(function(_,element)
            local row=element:get();local item={}
            for key,field in pairs(fields) do
                local value=row[field]
                if key=='items' then
                    assert(#value<=32,'queued_item_offer_limit');item.items={}
                    value:ForEach(function(_,offerElement)
                        local offer=offerElement:get();local entry={}
                        for attr,name in pairs(R.ItemFields) do
                            local v=offer[name]
                            if attr=='actor' then
                                assert(v and v:IsValid(),'queued_item_actor_unavailable');entry.actor=v:GetFullName()
                            else
                                assert(finite(v) and v%1==0 and v>=-1 and v<=2147483647,'invalid_queued_item:'..attr)
                                entry[attr]=v
                            end
                        end
                        item.items[#item.items+1]=entry
                    end)
                elseif key=='text' then
                    item.text=value:ToString();assert(type(item.text)=='string' and #item.text<=4096,'invalid_reward_text')
                elseif key=='isItem' or key=='customText' then
                    assert(type(value)=='boolean','invalid_reward_bool');item[key]=value
                else assert(finite(value),'invalid_reward_number');item[key]=value end
            end
            out.queue[#out.queue+1]=item
        end)
        return out
    end)
    if not ok or not s then return nil,'reward_capture_unavailable:'..tostring(s):sub(1,1200) end
    return s
end
function R:ValidateRestore(state)
    local current=self:Capture()
    if not current or not equal(current,state) then return false,'reward_continuity_mismatch' end
    return true
end
function R:Restore(state)
    local world=self.world:_world();local lib=self.world:_statics()
    if not world or not lib then return false,'missing_world' end
    local ok,dilation=pcall(lib.GetGlobalTimeDilation,lib,world)
    if not ok or not finite(dilation) or dilation<=0 or dilation>.001 then return false,'not_paused' end
    -- Do not replay PresentRoulette/PresentItems: that would advance artifact
    -- roulette counters and apply native pause/widget creation a second time.
    return self:ValidateRestore(state)
end
return R

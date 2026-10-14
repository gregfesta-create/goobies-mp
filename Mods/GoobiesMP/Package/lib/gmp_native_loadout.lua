-- Identity continuity for a retained pawn. Never assigns Character or spawns
-- artifacts: those operations also initialize meshes, passives and upgrades.
local L={};L.__index=L
L.CompleteCapture=false;L.CompleteRestore=false
function L.new(world) return setmetatable({world=world},L) end
function L:Capture()
    local ok,state=pcall(function()
        local w=self.world:_world();local pawn=w and self.world:_pawn(w);assert(pawn,'missing_pawn')
        local name=pawn:GetFullName();local class=pawn.Character
        assert(type(class)=='number' and class%1==0 and class>=0 and class<=255,'invalid_character')
        assert(#pawn.AllArtifacts<=256,'artifact_limit')
        local lib=self.world:_statics();assert(lib,'missing_statics')
        local gi=lib:GetGameInstance(w);assert(gi and gi:IsValid(),'missing_game_instance')
        assert(#gi.Artifacts<=256,'selected_artifact_limit')
        local out={version=1,pawn=name,character=class,artifacts={},selected={}};local seen={}
        -- AllArtifacts contains all instantiated artifact implementations.
        -- BP_Player initializes only classes selected in GameInstance.Artifacts.
        gi.Artifacts:ForEach(function(_,element)
            local row=element:get();local actor=row.Actor_8_C1984DE445F528C4E0C3E0840A7776F8
            assert(actor and actor:IsValid(),'missing_selected_artifact_class')
            local path=actor:GetFullName();assert(type(path)=='string' and #path>0 and #path<=4096,'invalid_selected_artifact')
            out.selected[#out.selected+1]=path
        end)
        pawn.AllArtifacts:ForEach(function(_,element)
            local actor=element:get();assert(actor and actor:IsValid(),'missing_artifact')
            local path=actor:GetFullName()
            assert(type(path)=='string' and #path>0 and #path<=4096 and not seen[path],'invalid_artifact_identity')
            seen[path]=true;out.artifacts[#out.artifacts+1]=path
        end)
        local current=self.world:_pawn(w)
        assert(current and current:GetFullName()==name and current.Character==class,'loadout_context_changed')
        return out
    end)
    if not ok then return nil,'loadout_capture:'..tostring(state):sub(1,700) end
    return state
end
function L:ValidateRestore(state)
    if type(state)~='table' or state.version~=1 or type(state.artifacts)~='table' or type(state.selected)~='table' then return false,'invalid_loadout' end
    local current=self:Capture()
    if not current or state.pawn~=current.pawn or state.character~=current.character
        or #state.artifacts~=#current.artifacts or #state.selected~=#current.selected then return false,'loadout_continuity_mismatch' end
    for i,path in ipairs(current.artifacts) do if state.artifacts[i]~=path then return false,'artifact_continuity_mismatch' end end
    for i,path in ipairs(current.selected) do if state.selected[i]~=path then return false,'selected_artifact_mismatch' end end
    return true
end
function L:Restore(state)
    local w=self.world:_world();local lib=self.world:_statics()
    if not w or not lib then return false,'missing_world' end
    local ok,d=pcall(lib.GetGlobalTimeDilation,lib,w)
    if not ok or type(d)~='number' or d~=d or d<=0 or d>.001 then return false,'not_paused' end
    return self:ValidateRestore(state)
end
return L

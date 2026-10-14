-- Bounded detached checkpoint transfer. No Lua evaluation or engine references.
-- Session/peer authentication is the caller's responsibility. The digest only
-- detects fragment mixing/corruption; it is not an authentication mechanism.
local H=require('gmp_handover');local Codec=require('gmp_codec')
local S={};S.__index=S
S.BYTES=400;S.MAX_BYTES=1600000
local function integer(v,lo,hi) return type(v)=='number' and v==v and v%1==0 and v>=lo and v<=hi end
local function digest(data)
    local h=2166136261
    for i=1,#data do h=((h~data:byte(i))*16777619)&0xffffffff end
    return string.format('%08x',h)
end
local function encode(value)
    local kind=type(value)
    if kind=='boolean' then return value and 'b1' or 'b0' end
    if kind=='number' or kind=='string' then
        local text=kind=='number' and string.format('%.17g',value) or value
        return (kind=='number' and 'n' or 's')..#text..':'..text
    end
    local keys={};for key in pairs(value) do keys[#keys+1]=key end
    table.sort(keys,function(a,b) if type(a)~=type(b) then return type(a)<type(b) end;return a<b end)
    local parts={'t'..#keys..':'}
    for _,key in ipairs(keys) do parts[#parts+1]=encode(key);parts[#parts+1]=encode(value[key]) end
    return table.concat(parts)
end
local function decode(data)
    local cursor,count=1,0
    local function read(depth)
        count=count+1;assert(depth<=20 and count<=100000,'decode_limit')
        local tag=data:sub(cursor,cursor);cursor=cursor+1
        if tag=='b' then local b=data:sub(cursor,cursor);cursor=cursor+1;assert(b=='0' or b=='1','bad_bool');return b=='1' end
        assert(tag=='t' or tag=='s' or tag=='n','bad_type')
        local colon=data:find(':',cursor,true);assert(colon and colon-cursor<=8,'bad_length')
        local text=data:sub(cursor,colon-1);assert(text:match('^%d+$'),'bad_length')
        local length=tonumber(text);cursor=colon+1
        if tag=='t' then
            assert(length<=100000,'table_limit');local out={}
            for _=1,length do
                local key=read(depth+1)
                assert(type(key)=='string' or integer(key,1,100000),'bad_key')
                assert(out[key]==nil,'duplicate_key');out[key]=read(depth+1)
            end
            return out
        end
        assert(length<=4096 and cursor+length-1<=#data,'truncated_atom')
        local atom=data:sub(cursor,cursor+length-1);cursor=cursor+length
        if tag=='s' then return atom end
        local n=tonumber(atom);assert(n and n==n and math.abs(n)<math.huge,'bad_number');return n
    end
    local value=read(0);assert(cursor==#data+1,'trailing_data');return value
end
function S.Packets(checkpoint,term,sequence,sid)
    return S.ValidatedPackets(checkpoint,term,sequence,sid,H.Validate,'CHECKPOINT_CHUNK')
end
function S.ValidatedPackets(checkpoint,term,sequence,sid,validate,messageType)
    if type(validate)~='function' then return nil,'missing_validator' end
    if not integer(term,1,2147483647) or not integer(sequence,1,9007199254740991) then return nil,'bad_generation' end
    local ok,state=validate(checkpoint);if not ok then return nil,state end
    local data=encode(state);if #data>S.MAX_BYTES then return nil,'checkpoint_budget' end
    local total=math.ceil(#data/S.BYTES);local hash=digest(data);local packets={}
    for i=1,total do
        local raw=data:sub((i-1)*S.BYTES+1,i*S.BYTES)
        local hex=raw:gsub('.',function(c) return string.format('%02x',c:byte()) end)
        local f={term=term,sequence=sequence,index=i,total=total,size=#data,digest=hash,data=hex}
        local wire=Codec.Encode({type=messageType,ch='R',ep=2147483647,
            seq=9007199254740991,ack=9007199254740991,sid=sid or '',f=f})
        if not wire or #wire>1380 then return nil,'packet_budget' end
        packets[i]=f
    end
    return packets
end
function S.new(term,validate) return setmetatable({term=term or 1,sequence=0,validate=validate or H.Validate},S) end
function S:Receive(f,now)
    if type(now)~='number' or now~=now or now<0 or now==math.huge then return false,'invalid_clock' end
    if type(f)~='table' or f.term~=self.term or not integer(f.sequence,1,9007199254740991)
        or not integer(f.size,1,S.MAX_BYTES) or not integer(f.total,1,math.ceil(S.MAX_BYTES/S.BYTES))
        or f.total~=math.ceil(f.size/S.BYTES) or not integer(f.index,1,f.total)
        or type(f.digest)~='string' or not f.digest:match('^%x%x%x%x%x%x%x%x$')
        or type(f.data)~='string' or f.data:find('[^0-9a-f]') then return false,'invalid_fragment' end
    local expected=math.min(S.BYTES,f.size-(f.index-1)*S.BYTES)*2
    if #f.data~=expected then return false,'invalid_fragment' end
    if f.sequence<self.sequence then return false,'stale_checkpoint' end
    if f.sequence==self.sequence then return self.hash==f.digest,self.hash==f.digest and 'duplicate' or 'fragment_conflict' end
    -- Expire stalled assembly, not a large transfer making steady progress.
    -- Replayed fragments do not extend the deadline.
    if self.pending and now-self.pending.progressAt>15 then self.pending=nil end
    local p=self.pending
    if p and f.sequence<p.sequence then return false,'stale_fragment' end
    if not p or f.sequence>p.sequence then
        p={sequence=f.sequence,total=f.total,size=f.size,hash=f.digest,parts={},count=0,started=now,progressAt=now};self.pending=p
    end
    if p.total~=f.total or p.size~=f.size or p.hash~=f.digest then return false,'fragment_conflict' end
    if p.parts[f.index] then return p.parts[f.index]==f.data,p.parts[f.index]==f.data and 'pending' or 'fragment_conflict' end
    p.parts[f.index]=f.data;p.count=p.count+1;p.progressAt=now
    if p.count<p.total then return true,'pending' end
    local hex=table.concat(p.parts)
    local raw=hex:gsub('%x%x',function(pair) return string.char(tonumber(pair,16)) end)
    self.pending=nil
    if #raw~=p.size or digest(raw)~=p.hash then return false,'digest_mismatch' end
    local ok,state=pcall(decode,raw);if not ok then return false,'invalid_checkpoint' end
    ok,state=self.validate(state);if not ok then return false,state end
    self.state=state;self.sequence=p.sequence;self.hash=p.hash;return true,'applied'
end
function S:Snapshot()
    if not self.state then return nil end
    local ok,copy=self.validate(self.state);return ok and copy or nil
end
return S

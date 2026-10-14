-- GoobiesMP production: deterministic text serialization of M1 messages. Lua 5.4 compatible, no Unreal references.
--
-- Packet = one line (no raw newlines), fields separated by '|':
--   GMP | v | type | ch | ep | seq | ack | sid | <payload fields in schema order...>
--   v    protocol major version (integer). A different major is rejected ("unsupported_version"); extra trailing payload
--        fields are ignored (additive minor evolution); missing fields are an error.
--   ch   "R" reliable / "U" unreliable; must equal the schema's channel for the type.
--   ep   sender link epoch (stale-connection filter), seq per-sender per-channel sequence number, ack cumulative reliable ack
--   sid  session id ("" before the client has learned it)
-- Atom escaping: '%', '|', ',', ';' and control characters become %XX (so text can never break the framing).
-- Lists: records separated by ';', record atoms separated by ','. Integers are decimal; bool is 0/1. No floats in M1.
local Config = require("gmp_config")
local Messages = require("gmp_messages")

local Codec = {}
Codec.MAGIC = "GMP"
Codec.MAX_PACKET = 1400        -- matches the POC relay's datagram limit; larger roster => needs fragmentation (later)
local MAXINT = 9007199254740992  -- 2^53

local function esc(s)
    return (s:gsub("[%%|,;%c]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function unesc(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "%" then
            local h = s:sub(i + 1, i + 2)
            if not h:match("^%x%x$") then return nil end
            out[#out + 1] = string.char(tonumber(h, 16))
            i = i + 3
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function split(s, sep)
    local parts, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then parts[#parts + 1] = s:sub(start); break end
        parts[#parts + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return parts
end

local function encInt(v)
    if type(v) ~= "number" or v ~= math.floor(v) or v ~= v or math.abs(v) > MAXINT then return nil end
    return string.format("%d", v)
end
local function decInt(s)
    if not s:match("^%-?%d+$") or #s > 16 then return nil end
    local n = tonumber(s)
    if not n or math.abs(n) > MAXINT then return nil end
    return math.tointeger(n) or n
end

local function encAtom(t, v)
    if t == "int" then return encInt(v)
    elseif t == "str" then if type(v) ~= "string" then return nil end return esc(v)
    elseif t == "bool" then if type(v) ~= "boolean" then return nil end return v and "1" or "0" end
    return nil
end
local function decAtom(t, s)
    if t == "int" then return decInt(s)
    elseif t == "str" then return unesc(s)
    elseif t == "bool" then if s == "1" then return true elseif s == "0" then return false end return nil end
    return nil
end

local function encField(fd, v)
    if fd.type ~= "list" then return encAtom(fd.type, v) end
    if type(v) ~= "table" then return nil end
    local recs = {}
    for _, rec in ipairs(v) do
        local atoms = {}
        for i, sub in ipairs(fd.of) do
            local a = encAtom(sub.type, rec[sub.name])
            if a == nil then return nil end
            atoms[i] = a
        end
        recs[#recs + 1] = table.concat(atoms, ",")
    end
    return table.concat(recs, ";")
end

local function decField(fd, s)
    if fd.type ~= "list" then return decAtom(fd.type, s) end
    local list = {}
    if s == "" then return list end
    for _, recS in ipairs(split(s, ";")) do
        local atoms = split(recS, ",")
        if #atoms ~= #fd.of then return nil end
        local rec = {}
        for i, sub in ipairs(fd.of) do
            local v = decAtom(sub.type, atoms[i])
            if v == nil then return nil end
            rec[sub.name] = v
        end
        list[#list + 1] = rec
    end
    return list
end

-- env = { type=, ch=, ep=, seq=, ack=, sid=, f={ fieldName=value } }  ->  string | nil, err
function Codec.Encode(env)
    local sch = Messages.Schema[env.type]
    if not sch then return nil, "unknown_type" end
    if env.ch ~= sch.ch then return nil, "bad_channel" end
    local ep, seq, ack = encInt(env.ep), encInt(env.seq), encInt(env.ack)
    if not ep or not seq or not ack or env.ep < 0 or env.seq < 0 or env.ack < 0 then return nil, "bad_header" end
    local sid = env.sid or ""
    if type(sid) ~= "string" then return nil, "bad_header" end
    local parts = { Codec.MAGIC, tostring(Config.PROTOCOL_VERSION), env.type, env.ch, ep, seq, ack, esc(sid) }
    local f = env.f or {}
    for _, fd in ipairs(sch.fields) do
        local s = encField(fd, f[fd.name])
        if s == nil then return nil, "bad_field:" .. fd.name end
        parts[#parts + 1] = s
    end
    for k in pairs(f) do
        local known = false
        for _, fd in ipairs(sch.fields) do if fd.name == k then known = true break end end
        if not known then return nil, "unexpected_field:" .. tostring(k) end
    end
    local out = table.concat(parts, "|")
    if #out > Codec.MAX_PACKET then return nil, "too_large" end
    return out
end

-- string -> env | nil, err
function Codec.Decode(s)
    if type(s) ~= "string" or s == "" then return nil, "empty" end
    if #s > Codec.MAX_PACKET then return nil, "too_large" end
    local p = split(s, "|")
    if p[1] ~= Codec.MAGIC then return nil, "bad_magic" end
    local v = decInt(p[2] or "")
    if not v then return nil, "bad_header" end
    if v ~= Config.PROTOCOL_VERSION then return nil, "unsupported_version" end
    local sch = Messages.Schema[p[3] or ""]
    if not sch then return nil, "unknown_type" end
    if p[4] ~= sch.ch then return nil, "bad_channel" end
    local ep, seq, ack = decInt(p[5] or ""), decInt(p[6] or ""), decInt(p[7] or "")
    if not ep or not seq or not ack or ep < 0 or seq < 0 or ack < 0 then return nil, "bad_header" end
    local sid = unesc(p[8] or "")
    if not sid then return nil, "bad_header" end
    if #p < 8 + #sch.fields then return nil, "missing_fields" end
    local f = {}
    for i, fd in ipairs(sch.fields) do
        local val = decField(fd, p[8 + i])
        if val == nil then return nil, "bad_field:" .. fd.name end
        f[fd.name] = val
    end
    return { type = p[3], ch = p[4], ep = ep, seq = seq, ack = ack, sid = sid, f = f }
end

Codec.Escape, Codec.Unescape = esc, unesc
return Codec

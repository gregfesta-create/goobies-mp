-- Lossless line-oriented INI edits: unrelated sections, comments and bad lines survive.
local M = {}
function M.header(line)
    return line:match('^%s*%[([^%]]+)%]%s*$') or line:match('^%s*%[([^%]]+)%]%s*[;#]')
end
function M.lines(text)
    local out = {}
    for line in ((text or ''):gsub('^\239\187\191', ''):gsub('\r\n', '\n') .. '\n'):gmatch('(.-)\n') do
        out[#out + 1] = line
    end
    return out
end
function M.read(text)
    local sections, issues, section = {}, {}, ''
    for n, line in ipairs(M.lines(text)) do
        local header = M.header(line)
        if header then section = header; sections[section] = sections[section] or {}
        elseif not line:match('^%s*[;#]') and not line:match('^%s*$') then
            local key, value = line:match('^%s*([%w_%-%.]+)%s*=%s*(.-)%s*$')
            if key then
                sections[section] = sections[section] or {}
                if sections[section][key] == nil then sections[section][key] = value
                else issues[#issues + 1] = 'Duplicate key at line ' .. n end
            else issues[#issues + 1] = 'Malformed line ' .. n end
        end
    end
    return sections, issues
end
function M.mergeDefaults(text,defaults)
    local current=M.read(text)
    local _,issues=M.read(defaults)
    if #issues>0 then return nil,'Malformed or duplicate settings defaults' end
    local additions,section,lastSection={},'',nil
    for _,line in ipairs(M.lines(defaults)) do
        local header=M.header(line)
        if header then section=header
        else
            local key,value=line:match('^%s*([%w_%-%.]+)%s*=%s*(.-)%s*$')
            if key and not (current[section] and current[section][key]~=nil) then
                if section=='' then return nil,'Settings defaults require named sections' end
                if lastSection~=section then additions[#additions+1]='['..section..']'; lastSection=section end
                additions[#additions+1]=key..'='..value
            end
        end
    end
    if #additions==0 then return text end
    local newline=text:find('\r\n',1,true) and '\r\n' or '\n'
    local separator=(text=='' or text:sub(-1)=='\n') and '' or newline
    return text..separator..table.concat(additions,newline)..newline
end
function M.set(text, wanted, key, value, insensitive)
    assert(not tostring(value):find('[\r\n]'), 'multiline INI value')
    local out, section, found, hadSection = {}, '', false, false
    local function same(a,b) return a and (a==b or (insensitive and a:lower()==b:lower())) end
    for _, line in ipairs(M.lines(text)) do
        local header = M.header(line)
        if header then
            if same(section,wanted) and not found then out[#out + 1] = key .. '=' .. value; found = true end
            section = header
            if same(section,wanted) then hadSection = true end
        end
        local k = line:match('^%s*([%w_%-%.]+)%s*=')
        if same(section,wanted) and same(k,key) then
            if not found then out[#out + 1] = key .. '=' .. value; found = true
            else out[#out + 1] = '; superseded duplicate: ' .. line end
        else out[#out + 1] = line end
    end
    if not found then
        if not hadSection then out[#out + 1] = '[' .. wanted .. ']' end
        out[#out + 1] = key .. '=' .. value
    end
    return table.concat(out, '\n'):gsub('\n+$', '') .. '\n'
end
-- One parser for every registry value. Whitespace/case are recoverable;
-- unknown state, absent/unknown version, and trailing garbage are not ON.
function M.state(value, versionValid)
    local clean=value:gsub('%s*[;#].*$', '')
    local flag,rest=clean:match('^%s*(%a+)%s*|%s*(.-)%s*$')
    flag=flag and flag:lower()
    local metadata={extras={},comment=value:match('([;#].*)$')}
    local seen={}
    for part in ((rest or '')..'|'):gmatch('(.-)|') do
        local key,v=part:match('^%s*([%w_]+)%s*:%s*(.-)%s*$')
        key=key and key:lower()
        if key=='version' then key='ver' end
        if not key or seen[key] then return false,'Malformed or duplicate registry field: '..value end
        seen[key]=true
        if key=='ver' then metadata.version=v
        elseif key=='inst' then metadata.installed=M.date(v) and v or '?'
        elseif key=='upd' then metadata.updated=M.date(v) and v or '?'
        else metadata.extras[#metadata.extras+1]=part end
    end
    if (flag~='true' and flag~='false') or not versionValid(metadata.version) then
        return false,'Malformed state or unknown version: '..value
    end
    return flag=='true',nil,metadata
end
function M.date(value)
    if type(value)~='string' then return false end
    local y,m,d=value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    y,m,d=tonumber(y),tonumber(m),tonumber(d)
    if not y or y<1 or m<1 or m>12 then return false end
    local days={31,28,31,30,31,30,31,31,30,31,30,31}
    if y%4==0 and (y%100~=0 or y%400==0) then days[2]=29 end
    return d>=1 and d<=days[m]
end
function M.registry(text, versionValid)
    local records,issues,section,hasSection={},{},'',false
    for n,line in ipairs(M.lines(text)) do
        local header=M.header(line)
        if header then section=header:lower(); if section=='mods' then hasSection=true end
        elseif section=='mods' and not line:match('^%s*[;#]') and not line:match('^%s*$') then
            local id,value=line:match('^%s*([%w_%-%.]+)%s*=%s*(.-)%s*$')
            if not id then
                issues[#issues+1]='Malformed registry line '..n
                local suspected=line:match('^%s*([%w_%-%.]+)')
                if suspected then records[suspected:lower()]={on=false,problem='Malformed registry line '..n} end
            else
                local on,why,metadata=M.state(value,versionValid); local key=id:lower()
                local r=records[key]
                if r then
                    issues[#issues+1]='Duplicate registry entry '..id..'; OFF/invalid takes precedence'
                    r.on=r.on and on; r.problem=r.problem or why
                else r={on=on,problem=why,metadata=metadata}; records[key]=r end
                if why then issues[#issues+1]=id..': '..why end
            end
        elseif not header and line:match('^%s*%[') then
            issues[#issues+1]='Malformed section header at line '..n
        end
    end
    if not hasSection then issues[#issues+1]='Missing [Mods] section' end
    return records,issues
end
return M

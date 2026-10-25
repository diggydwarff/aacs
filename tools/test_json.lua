-- Standalone test runner only. Production uses CC:Tweaked's JSON implementation.
local M={}
local function quote(s)
    return '"'..s:gsub('[%z\1-\31\\"]',function(c)
        local escapes={['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
        return escapes[c] or string.format('\\u%04x',c:byte())
    end)..'"'
end
function M.encode(v)
    local kind=type(v)
    if kind=='string' then return quote(v) end
    if kind=='number' then assert(v==v and math.abs(v)~=math.huge);return string.format('%.17g',v) end
    if kind=='boolean' then return tostring(v) end
    if kind=='nil' then return 'null' end
    assert(kind=='table','Not serializable')
    local count=0;local array=true;local keys={}
    for k in pairs(v) do count=count+1;keys[#keys+1]=k;if type(k)~='number' then array=false end end
    if count==0 then return '{}' end
    local out={}
    if array and #v==count then
        for i=1,count do out[i]=M.encode(v[i]) end
        return '['..table.concat(out,',')..']'
    end
    table.sort(keys)
    for _,k in ipairs(keys) do out[#out+1]=quote(k)..':'..M.encode(v[k]) end
    return '{'..table.concat(out,',')..'}'
end
function M.decode(s)
    local i=1
    local function white() while s:sub(i,i):match('%s') do i=i+1 end end
    local parse
    local function str()
        assert(s:sub(i,i)=='"');i=i+1;local out={}
        while i<=#s do
            local c=s:sub(i,i);i=i+1
            if c=='"' then return table.concat(out) end
            if c=='\\' then
                local e=s:sub(i,i);i=i+1
                local escape={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
                if e=='u' then
                    local n=assert(tonumber(s:sub(i,i+3),16));i=i+4
                    if n<128 then c=string.char(n) elseif n<2048 then c=string.char(192+math.floor(n/64),128+n%64)
                    else c=string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
                else c=assert(escape[e]) end
            end
            out[#out+1]=c
        end
        error('Unterminated string')
    end
    parse=function()
        white();local c=s:sub(i,i)
        if c=='"' then return str() end
        if c=='{' then
            i=i+1;white();local o={}
            if s:sub(i,i)=='}' then i=i+1;return o end
            while true do
                white();local k=str();white();assert(s:sub(i,i)==':');i=i+1;o[k]=parse();white()
                c=s:sub(i,i);i=i+1;if c=='}' then return o end;assert(c==',')
            end
        end
        if c=='[' then
            i=i+1;white();local a={};if s:sub(i,i)==']' then i=i+1;return a end
            while true do
                a[#a+1]=parse();white();c=s:sub(i,i);i=i+1;if c==']' then return a end;assert(c==',')
            end
        end
        for literal,value in pairs({['true']=true,['false']=false}) do
            if s:sub(i,i+#literal-1)==literal then i=i+#literal;return value end
        end
        if s:sub(i,i+3)=='null' then i=i+4;return nil end
        local n=s:sub(i):match('^%-?%d+%.?%d*[eE]?[+%-]?%d*');assert(n,'Invalid JSON')
        i=i+#n;return assert(tonumber(n))
    end
    local result=parse();white();assert(i>#s,'Trailing JSON');return result
end
return M

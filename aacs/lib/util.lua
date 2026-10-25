local M = {}

function M.now() return os.epoch('utc') end
function M.id(s,limit)
    return type(s)=='string' and #s>0 and #s<=(limit or 80) and s:match('^[%w_:%-%.]+$')~=nil
end
function M.dimension(s)
    return type(s)=='string' and #s<=128 and s:match('^[a-z0-9_.%-]+:[a-z0-9_./%-]+$')~=nil
end
function M.number(n,lo,hi)
    return type(n)=='number' and n==n and n>=lo and n<=hi
end
function M.integer(n,lo,hi) return M.number(n,lo,hi) and n==math.floor(n) end
function M.text(s,max,empty)
    return type(s)=='string' and #s<=(max or 80) and (empty or #s>0) and not s:find('[%z\1-\31\127]')
end
function M.uuid(s)
    return type(s)=='string' and s:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')~=nil
end
function M.position(p)
    return type(p)=='table' and M.number(p.x,-30000000,30000000)
        and M.number(p.z,-30000000,30000000) and M.number(p.y,-1000000,1000000)
end
function M.count(t) local n=0; for _ in pairs(t or {}) do n=n+1 end; return n end
function M.sorted(t) local keys={}; for k in pairs(t or {}) do keys[#keys+1]=k end; table.sort(keys); return keys end
function M.copy(t)
    if type(t)~='table' then return t end
    local out={}; for k,v in pairs(t) do out[k]=M.copy(v) end; return out
end
function M.json(t) return textutils.serializeJSON(t) end
function M.decode(s)
    local ok,data=pcall(textutils.unserializeJSON,s)
    if ok and type(data)=='table' then return data end
    return nil
end
function M.date(t) return os.date('!%Y-%m-%d %H:%M:%S',math.floor(t/1000))..' UTC' end
function M.distance(a,b)
    return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)
end
function M.read(path)
    local file,err=fs.open(path,'r'); assert(file,err or ('Cannot read '..path))
    local data=file.readAll(); file.close(); return data
end
function M.write(path,data)
    local dir=fs.getDir(path)
    if dir~='' and not fs.exists(dir) then fs.makeDir(dir) end
    local file,err=fs.open(path,'w'); assert(file,err or ('Cannot write '..path))
    file.write(data); file.close()
end
function M.methods(name)
    local methods={}
    for _,method in ipairs(peripheral.getMethods(name) or {}) do methods[method]=true end
    return methods
end
function M.namesWith(method)
    local names={}
    for _,name in ipairs(peripheral.getNames()) do if M.methods(name)[method] then names[#names+1]=name end end
    table.sort(names); return names
end
function M.safeCall(object,method,...)
    if type(object)~='table' or type(object[method])~='function' then return nil,'Missing '..method end
    local ok,value,detail=pcall(object[method],...)
    if not ok then return nil,tostring(value) end
    return value,detail
end
function M.pause() print('Press Enter.'); read() end
return M

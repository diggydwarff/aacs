-- Isolated test doubles. Never use these as live peripherals or filesystem APIs.
local M={}
function M.new()
    local self={files={},directories={['/']=true},time=1800000000000,devices={},outputs={}}
    local function norm(p) if p:sub(1,1)~='/' then p='/'..p end; return p:gsub('/+$','')=='' and '/' or p:gsub('/+$','') end
    self.fs={}
    local f=self.fs
    function f.exists(p) p=norm(p); return self.files[p]~=nil or self.directories[p]==true end
    function f.isDir(p) return self.directories[norm(p)]==true end
    function f.getDir(p) return norm(p):match('^(.*)/[^/]*$') or '' end
    function f.getName(p) return norm(p):match('([^/]+)$') or '' end
    function f.combine(a,b) return norm(a..'/'..b) end
    function f.makeDir(p)
        p=norm(p); self.directories[p]=true
        local parent=f.getDir(p); if parent~='' and parent~=p then f.makeDir(parent) end
    end
    function f.delete(p) p=norm(p); self.files[p]=nil; self.directories[p]=nil end
    function f.move(a,b)
        a,b=norm(a),norm(b)
        assert(self.files[a]~=nil,'Source missing: '..a); assert(not f.exists(b),'Destination exists')
        self.files[b]=self.files[a]; self.files[a]=nil
    end
    function f.copy(a,b) self.files[norm(b)]=assert(self.files[norm(a)]) end
    function f.getSize(p) return #(self.files[norm(p)] or '') end
    function f.getFreeSpace() return 100000000 end
    function f.list(p)
        p=norm(p); if p~='/' then p=p..'/' end
        local result={}; local seen={}
        for name in pairs(self.files) do
            if name:sub(1,#p)==p then local part=name:sub(#p+1):match('^[^/]+'); if part and not seen[part] then result[#result+1]=part;seen[part]=true end end
        end
        table.sort(result); return result
    end
    function f.open(path,mode)
        path=norm(path)
        if mode=='r' and self.files[path]==nil then return nil,'not found' end
        local pos=1; local closed=false
        if mode=='w' then self.files[path]='' elseif mode=='a' then self.files[path]=self.files[path] or '' end
        local handle={}
        function handle.readAll() assert(not closed); return self.files[path]:sub(pos) end
        function handle.readLine()
            assert(not closed)
            local s=self.files[path]; if pos>#s then return nil end
            local n=s:find('\n',pos,true)
            local line=s:sub(pos,n and n-1 or #s); pos=n and n+1 or #s+1; return line
        end
        function handle.write(s) assert(not closed); self.files[path]=self.files[path]..tostring(s) end
        function handle.writeLine(s) handle.write(tostring(s)..'\n') end
        function handle.close() closed=true end
        function handle.flush() end
        return handle
    end
    self.peripheral={}
    function self.peripheral.getNames() local r={};for name in pairs(self.devices) do r[#r+1]=name end;table.sort(r);return r end
    function self.peripheral.wrap(name) return self.devices[name] end
    function self.peripheral.isPresent(name) return self.devices[name]~=nil end
    function self.peripheral.hasType(name,kind) return self.devices[name]~=nil and self.devices[name]._type==kind end
    function self.peripheral.getMethods(name)
        local r={}; for method,value in pairs(self.devices[name] or {}) do if type(value)=='function' then r[#r+1]=method end end;return r
    end
    function self.peripheral.getType(name) return self.devices[name] and self.devices[name]._type or 'unknown' end
    function self.peripheral.find(kind) for _,p in pairs(self.devices) do if p._type==kind then return p end end end
    self.redstone={setOutput=function(side,value) self.outputs[side]=value end}
    return self
end

function M.install(mock)
    local old={fs=fs,peripheral=peripheral,redstone=redstone,epoch=os.epoch,term=term,parallel=parallel,
        pullEvent=os.pullEvent,startTimer=os.startTimer,cancelTimer=os.cancelTimer,rednet=rednet}
    fs=mock.fs; peripheral=mock.peripheral; redstone=mock.redstone
    os.epoch=function() return mock.time end
    return function()
        fs=old.fs;peripheral=old.peripheral;redstone=old.redstone;os.epoch=old.epoch
        term=old.term;parallel=old.parallel;rednet=old.rednet
        os.pullEvent=old.pullEvent;os.startTimer=old.startTimer;os.cancelTimer=old.cancelTimer
    end
end
return M

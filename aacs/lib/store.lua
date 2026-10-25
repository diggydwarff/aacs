-- Checksummed, replace-on-write storage. Recovery is explicit, never silent rollback.
local util=require('aacs.lib.util')
local crypto=require('aacs.lib.crypto')
local M={}

function M.load(path,default)
    assert(not fs.exists(path..'.new'), 'Interrupted write: '..path..'.new; read RECOVERY.md')
    if not fs.exists(path) then
        assert(not fs.exists(path..'.bak'),'Missing live file with backup: '..path..'; read RECOVERY.md')
        assert(default~=nil,'Required state missing: '..path..'; re-key before recovery')
        return util.copy(default)
    end
    local envelope=util.decode(util.read(path))
    assert(envelope and type(envelope.payload)=='string' and type(envelope.sha256)=='string', 'Invalid store: '..path)
    assert(crypto.equal(crypto.sha256(envelope.payload),envelope.sha256),'Store checksum failed: '..path)
    return assert(util.decode(envelope.payload),'Invalid store payload: '..path)
end

function M.save(path,value)
    assert(not fs.exists(path..'.new'),'Unresolved interrupted write: '..path)
    local payload=util.json(value)
    local encoded=util.json({payload=payload,sha256=crypto.sha256(payload)})
    util.write(path..'.new',encoded)
    assert(util.read(path..'.new')==encoded,'Write verification failed: '..path)
    if fs.exists(path..'.bak') then fs.delete(path..'.bak') end
    if fs.exists(path) then fs.move(path,path..'.bak') end
    fs.move(path..'.new',path)
end

function M.log(path,row,limit,segments)
    limit=limit or 49152; segments=segments or 3
    local line=util.json(row)..'\n'
    if fs.exists(path) and fs.getSize(path)+#line>limit then
        if fs.exists(path..'.'..segments) then fs.delete(path..'.'..segments) end
        for i=segments-1,1,-1 do
            if fs.exists(path..'.'..i) then fs.move(path..'.'..i,path..'.'..(i+1)) end
        end
        fs.move(path,path..'.1')
    end
    local dir=fs.getDir(path)
    if not fs.exists(dir) then fs.makeDir(dir) end
    local file,err=fs.open(path,'a'); assert(file,err)
    file.write(line); file.close()
end

function M.rows(path,callback,segments)
    local malformed=0
    local function consume(filePath)
        if not fs.exists(filePath) then return end
        local f=assert(fs.open(filePath,'r'))
        while true do
            local line=f.readLine()
            if not line then break end
            local row=util.decode(line)
            if row then callback(row) else malformed=malformed+1 end
        end
        f.close()
    end
    for i=(segments or 3),1,-1 do consume(path..'.'..i) end
    consume(path)
    return malformed
end
return M

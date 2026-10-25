-- Peripherals are discovered by METHOD, not a guessed mod-specific type string.
local u=require('aacs.lib.util')
local M={}

function M.isShipTrack(track)
    if track.entityType~=nil and type(track.entityType)~='string' then return false end
    if track.category~=nil and type(track.category)~='string' then return false end
    local category=type(track.category)=='string' and track.category:upper() or ''
    local entityType=type(track.entityType)=='string' and track.entityType:lower() or ''
    -- Radar entity types also describe Sable ships; a nonempty type is not an exclusion.
    if category=='PLAYER' or category=='ENTITY' or category=='CONTRAPTION' then return false end
    if category=='SABLE' then return entityType=='' or entityType=='sable:ship' end
    if entityType=='sable:ship' then return category=='' end
    -- Preserve the older radar format, which reports ships without an entity type.
    return track.entityType==nil or track.entityType==''
end

function M.new(config)
    local self={config=config,tokens={},health={},errors={}}
    local function errorMessage(name,message) self.errors[name]=message end

    function self:scan()
        local out={}
        self.errors={}; self.health={}
        local now=u.now()
        local names=self.config.radars or {}
        for _,name in ipairs(names) do
            local p=peripheral.wrap(name)
            local tracks,err=u.safeCall(p,'getTracks')
            if type(tracks)~='table' then errorMessage(name,err or 'Invalid radar response')
            else
                self.health[name]='readable (coverage not proven)'
                local seen={}
                for _,t in pairs(tracks) do
                    if type(t)=='table' and u.id(t.id,100) and u.position(t.position)
                        and M.isShipTrack(t) then
                        local tokenKey=name..':'..t.id
                        seen[tokenKey]=true
                        local memory=self.tokens[tokenKey]
                        local validToken=type(t.scannedTime)=='number' and t.scannedTime==t.scannedTime
                        if not memory then
                            -- Require a NEW scan token after startup; don't adopt a cached ghost.
                            memory={token=t.scannedTime,changedAt=now,confirmed=false}
                            self.tokens[tokenKey]=memory
                        elseif validToken and memory.token~=t.scannedTime then
                            memory.token=t.scannedTime; memory.changedAt=now; memory.confirmed=true
                        end
                        if not validToken then errorMessage(name,'Missing scannedTime; refusing unverified freshness') end
                        local pos=t.position
                        local coverage=self.config.coverage
                        if memory.confirmed and validToken and now-memory.changedAt<=(self.config.radarFreshMs or 15000)
                            and (not coverage or u.distance(coverage,pos)<=coverage.radius) then
                            out[#out+1]={kind='ship',id=t.id,namespace=self.config.namespace,
                                dimension=self.config.dimension,x=pos.x,y=pos.y,z=pos.z,
                                time=memory.changedAt,source=self.config.node,sensor=name}
                        end
                    end
                end
                for key in pairs(self.tokens) do
                    if key:sub(1,#name+1)==name..':' and not seen[key] then self.tokens[key]=nil end
                end
            end
        end
        local detectorName=self.config.playerDetector
        if detectorName and detectorName~='' then
            local detector=peripheral.wrap(detectorName)
            local players,err=u.safeCall(detector,'getPlayersInRange',self.config.playerRange or 128)
            if type(players)~='table' then errorMessage(detectorName,err or 'Invalid detector response')
            else
                self.health[detectorName]='readable'
                local methods=u.methods(detectorName)
                local method=methods.getPlayer and 'getPlayer' or 'getPlayerPos'
                for _,entry in pairs(players) do
                    local name=type(entry)=='table' and (entry.uuid or entry.name) or entry
                    if type(name)=='string' then
                        local info,readError
                        if method=='getPlayer' then
                            -- AP 0.8 includes the dimension in its detailed response.
                            info,readError=u.safeCall(detector,method,name,true)
                        else
                            info,readError=u.safeCall(detector,method,name)
                        end
                        if type(info)=='table' and u.position(info) and u.uuid(info.uuid)
                            and info.dimension==self.config.dimension then
                            out[#out+1]={kind='player',id=info.uuid:lower(),name=info.name or name,
                                dimension=info.dimension,x=info.x,y=info.y,z=info.z,time=now,
                                source=self.config.node,sensor=detectorName}
                        elseif info then errorMessage(detectorName,'Player result has no valid UUID/world position/dimension; skipped')
                        elseif readError then errorMessage(detectorName,tostring(readError)) end
                    end
                end
            end
        end
        if #names==0 and (not detectorName or detectorName=='') then errorMessage('setup','No sensors configured') end
        -- Do not let a mod's unexpectedly huge response generate unbounded packets.
        while #out>128 do table.remove(out); errorMessage('capacity','128 observations per scan limit reached') end
        return out,self.errors,self.health
    end
    return self
end

function M.beacon()
    if type(sublevel)~='table' then return nil,'CC: Sable sublevel API unavailable' end
    local id,err=u.safeCall(sublevel,'getUniqueId')
    if not u.uuid(id) then return nil,err or 'Computer is not on a ship' end
    local report={claimedUuid=id}
    local pose=u.safeCall(sublevel,'getLogicalPose')
    if type(pose)=='table' and u.position(pose.position) then report.position=pose.position end
    return report
end
return M

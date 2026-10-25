-- Headquarters owns the only writable national registry.
local u=require('aacs.lib.util')
local store=require('aacs.lib.store')
local policy=require('aacs.lib.policy')
local M={}
-- Binding lifetimes use real UTC minutes, independently of Minecraft's day cycle.
M.MAX_BINDING_MINUTES = 365 * 24 * 60

local collections={vessels=true,players=true,zones=true,permits=true,applications=true,bindings=true,pilots=true}
local rights={
    kiosk={apply=true,application_status=true,ping=true},
    registrar={apply=true,application_status=true,ping=true,list=true,create_vessel=true,approve=true,reject=true},
    station={ping=true},beacon={ping=true}
}

function M.empty()
    return {revision=1,nextVessel=1,nextApplication=1,nextPermit=1,vessels={},players={},
        zones={},permits={},bindings={},applications={},receipts={},receiptOrder={},
        disabledPeers={},beaconAssignments={},lastApplication={},pilots={}}
end

local function vesselFields(q)
    assert(u.text(q.name,60),'Vessel name: 1-60 printable characters')
    assert(u.text(q.craftType,40),'Craft type required')
    assert(u.text(q.owner,40),'Owner/operator required')
    assert(u.text(q.nation,40),'Nation required')
    assert(u.text(q.purpose,60),'Purpose required')
    assert(u.text(q.description or '',200,true),'Description too long or invalid')
    assert(q.claimedUuid==nil or q.claimedUuid=='' or u.uuid(q.claimedUuid),'Invalid claimed ship UUID')
    return {name=q.name,craftType=q.craftType,owner=q.owner,nation=q.nation,purpose=q.purpose,
        description=q.description or '',claimedUuid=q.claimedUuid or '',status='active'}
end

local function addVessel(db,fields)
    assert(u.count(db.vessels)<256,'Vessel registry limit (256); archive or extend deliberately')
    local id=string.format('ARD-%04d',db.nextVessel)
    db.nextVessel=db.nextVessel+1
    fields.registration=id; fields.created=u.now()
    db.vessels[id]=fields
    return {registration=id}
end

function M.new(config,root)
    local self={config=config,root=root}
    self.db=store.load(root..'/database.json',M.empty())
    self.db.pilots=self.db.pilots or {}
    if not fs.exists(root..'/database.json') then store.save(root..'/database.json',self.db) end

    function self:applyRevocations()
        for name,peer in pairs(config.peers) do peer.revoked=self.db.disabledPeers[name]==true end
    end
    self:applyRevocations()

    function self:execute(from,role,q)
        if type(q)~='table' or not u.id(q.op,40) then return {ok=false,error='Invalid operation'} end
        if role~='local_admin' and not (rights[role] and rights[role][q.op]) then
            return {ok=false,error='Permission denied'}
        end
        if q.op=='ping' then return {ok=true,version='0.2.3-beta.1',revision=self.db.revision} end
        if q.op=='list' then
            if role=='registrar' and q.collection~='vessels' and q.collection~='applications' then
                return {ok=false,error='Permission denied'}
            end
            if not collections[q.collection] or not u.integer(q.page or 1,1,10000) then return {ok=false,error='Invalid list query'} end
            local keys=u.sorted(self.db[q.collection])
            local items={}; local start=((q.page or 1)-1)*8+1
            for i=start,math.min(#keys,start+7) do items[#items+1]={id=keys[i],record=self.db[q.collection][keys[i]]} end
            return {ok=true,items=items,count=#keys,more=start+7<#keys}
        end
        if q.op=='application_status' then
            local a=self.db.applications[q.id]
            if not a or (role=='kiosk' and a.submittedBy~=from) then return {ok=false,error='Application not found'} end
            return {ok=true,status=a.status,registration=a.registration,reason=a.reason}
        end
        if not u.id(q.request,110) then return {ok=false,error='Request ID required'} end
        local receipt=from..':'..q.request
        if self.db.receipts[receipt] then return u.copy(self.db.receipts[receipt]) end
        local db=u.copy(self.db)
        local now=u.now()

        local ok,result=pcall(function()
            if q.op=='apply' then
                assert(now-(db.lastApplication[from] or 0)>=30000,'Please wait 30 seconds between applications')
                assert(u.count(db.applications)<128,'Application archive full; ADOT must archive old applications')
                local fields=vesselFields(q)
                local id=string.format('APP-%06d',db.nextApplication)
                db.nextApplication=db.nextApplication+1
                fields.status='pending'; fields.submittedBy=from; fields.submitted=now
                fields.identityEvidence='Applicant-entered details; not authenticated ownership'
                db.applications[id]=fields; db.lastApplication[from]=now
                return {application=id,status='pending'}
            elseif q.op=='create_vessel' then
                return addVessel(db,vesselFields(q))
            elseif q.op=='approve' then
                local a=assert(db.applications[q.id],'Unknown application')
                if a.status=='approved' then return {registration=a.registration} end
                assert(a.status=='pending','Application not pending')
                local result=addVessel(db,vesselFields(a))
                a.status='approved'; a.registration=result.registration; a.reviewedBy=from
                return result
            elseif q.op=='reject' then
                local a=assert(db.applications[q.id],'Unknown application')
                assert(a.status=='pending','Application not pending')
                assert(u.text(q.reason,160),'Reason required')
                a.status='rejected'; a.reason=q.reason; a.reviewedBy=from
                return {status='rejected'}
            elseif q.op=='archive_application' then
                local a=assert(db.applications[q.id],'Unknown application')
                assert(a.status~='pending','Resolve pending application first')
                db.applications[q.id]=nil
                return {archived=q.id}
            elseif q.op=='player' then
                assert(u.uuid(q.uuid) and u.text(q.name,40) and u.text(q.nation,40),'Player UUID, name and nation required')
                local id=q.uuid:lower()
                assert(db.players[id] or u.count(db.players)<256,'Player registry full')
                db.players[id]={name=q.name,nation=q.nation,status='active'}
                return {subject='player:'..id}
            elseif q.op=='authorize_pilot' then
                assert(u.uuid(q.uuid),'Valid player UUID required')
                assert(require('aacs.lib.chat').username(q.username),'Minecraft username required')
                assert(db.vessels[q.registration] and db.vessels[q.registration].status=='active','Active vessel required')
                assert(u.integer(q.minutes,1,10080),'Pilot approval must be 1-10080 minutes')
                local uuid=q.uuid:lower()
                for id,pilot in pairs(db.pilots) do if pilot.expires<=now then db.pilots[id]=nil end end
                assert(db.pilots[uuid] or u.count(db.pilots)<256,'Pilot approval limit reached')
                db.pilots[uuid]={uuid=uuid,username=q.username,registration=q.registration,expires=now+q.minutes*60000,by=from}
                return {pilot=uuid,registration=q.registration,note='Pilot must check in through chat. No zone clearance granted.'}
            elseif q.op=='revoke_pilot' then
                assert(u.uuid(q.uuid),'Valid player UUID required');db.pilots[q.uuid:lower()]=nil
                return {revoked=q.uuid:lower()}
            elseif q.op=='status' then
                assert(q.collection=='vessels' or q.collection=='players','Invalid registry')
                local record=assert(db[q.collection][q.id],'Unknown registration')
                assert(({active=true,suspended=true,hostile=true,retired=true})[q.status],'Invalid status')
                record.status=q.status
                return {id=q.id,status=q.status}
            elseif q.op=='bind' then
                assert(u.id(q.sensorKey,180) and q.sensorKey:sub(1,5)=='ship:','Use a ship sensorKey from Live Contacts')
                assert(db.vessels[q.registration] and db.vessels[q.registration].status=='active','Active vessel required')
                assert(
                    u.integer(q.minutes, 1, M.MAX_BINDING_MINUTES),
                    'Binding lifetime must be 1-'..M.MAX_BINDING_MINUTES..' real minutes (365 days maximum)'
                )
                local previous=db.bindings[q.sensorKey]
                assert(not previous or previous.registration==q.registration or previous.expires<=now,'Track already belongs to another vessel; unbind it first')
                db.bindings[q.sensorKey]={registration=q.registration,expires=now+q.minutes*60000,by=from}
                return {bound=q.sensorKey,registration=q.registration}
            elseif q.op=='unbind' then
                assert(u.id(q.sensorKey,180),'Invalid track key'); db.bindings[q.sensorKey]=nil
                return {unbound=q.sensorKey}
            elseif q.op=='zone' then
                local valid,err=policy.validateZone(q.zone); assert(valid,err)
                assert(db.zones[q.zone.id] or u.count(db.zones)<64,'Zone limit (64) reached')
                -- Preserve only recognized fields; no executable scripts or callbacks.
                local z=q.zone
                db.zones[z.id]={id=z.id,name=z.name,class=z.class,dimension=z.dimension,shape=z.shape,
                    applies=z.applies,minY=z.minY,maxY=z.maxY,minX=z.minX,maxX=z.maxX,
                    minZ=z.minZ,maxZ=z.maxZ,x=z.x,z=z.z,radius=z.radius,enabled=z.enabled~=false}
                return {zone=z.id}
            elseif q.op=='delete_zone' then
                assert(u.id(q.id,40),'Invalid zone ID'); db.zones[q.id]=nil
                for id,p in pairs(db.permits) do if p.zone==q.id then db.permits[id]=nil end end
                return {deleted=q.id}
            elseif q.op=='permit' then
                assert(u.id(q.subject,100) and db.zones[q.zone],'Valid subject and zone required')
                local vessel=q.subject:match('^vessel:(.+)$')
                local player=q.subject:match('^player:(.+)$')
                assert((vessel and db.vessels[vessel]) or (player and db.players[player]),'Register the subject first')
                assert(u.integer(q.minutes,1,43200),'Permit duration must be 1-43200 minutes')
                for id,p in pairs(db.permits) do if p.expires<=now or p.revoked then db.permits[id]=nil end end
                assert(u.count(db.permits)<512,'Permit limit reached')
                local id=string.format('PER-%06d',db.nextPermit); db.nextPermit=db.nextPermit+1
                db.permits[id]={id=id,subject=q.subject,zone=q.zone,starts=now,expires=now+q.minutes*60000,by=from}
                return {permit=id,expires=db.permits[id].expires}
            elseif q.op=='revoke_permit' then
                local permit=assert(db.permits[q.id],'Unknown permit'); permit.revoked=true
                return {revoked=q.id}
            elseif q.op=='assign_beacon' then
                assert(config.peers[q.peer] and config.peers[q.peer].role=='beacon','Unknown beacon peer')
                assert(db.vessels[q.registration],'Unknown vessel')
                db.beaconAssignments[q.peer]=q.registration
                return {peer=q.peer,registration=q.registration,note='Credential association only; not a radar identity binding'}
            elseif q.op=='revoke_peer' then
                assert(config.peers[q.peer],'Unknown peer'); db.disabledPeers[q.peer]=true
                return {revoked=q.peer}
            else error('Unknown operation') end
        end)
        if not ok then
            return {ok=false,error=tostring(result):gsub('^.-:%d+: ','')}
        end
        db.revision=db.revision+1
        -- Reject growth before committing if stations could no longer receive it.
        -- Still allow an oversized imported database to be reduced deliberately.
        local encodedOk,snapshot=pcall(function() return u.json(policy.snapshot(db,now)) end)
        local oldSize=#u.json(policy.snapshot(self.db,now))
        if not encodedOk or (#snapshot>256000 and #snapshot>=oldSize) then
            return {ok=false,error='Policy snapshot exceeds station capacity; remove expired/unneeded records first'}
        end
        result.ok=true
        db.receipts[receipt]=u.copy(result)
        db.receiptOrder[#db.receiptOrder+1]=receipt
        while #db.receiptOrder>256 do db.receipts[table.remove(db.receiptOrder,1)]=nil end
        store.save(root..'/database.json',db)
        self.db=db; self:applyRevocations()
        store.log(root..'/audit.jsonl',{time=now,actor=from,role=role,operation=q.op,request=q.request,result=result})
        return result
    end
    return self
end
return M

local u=require('aacs.lib.util')
local store=require('aacs.lib.store')
local crypto=require('aacs.lib.crypto')
local Wire=require('aacs.lib.wire')
local Policy=require('aacs.lib.policy')
local Tracker=require('aacs.lib.tracker')
local Sensors=require('aacs.lib.sensors')
local Service=require('aacs.lib.service')
local UI=require('aacs.lib.ui')
local Display=require('aacs.lib.display')
local Chat=require('aacs.lib.chat')
local Comms=require('aacs.lib.comms')
local M={ROOT='/aacs/data',CONFIG='/aacs/config.json'}
local sides={left=true,right=true,top=true,bottom=true,front=true,back=true}

function M.config()
    assert(fs.exists(M.CONFIG),'No deployment configuration. Run tools/provision.py on your PC; see QUICKSTART.md.')
    local c=assert(u.decode(u.read(M.CONFIG)),'Invalid config JSON')
    assert(c.schema==1 and u.id(c.realm) and u.id(c.node) and type(c.peers)=='table','Invalid node config')
    assert(u.dimension(c.dimension),'Invalid dimension resource ID')
    assert(c.computer==os.getComputerID(),'Configuration is for a different computer. Do not clone credentials.')
    assert(({hq=true,station=true,kiosk=true,registrar=true,beacon=true})[c.role],'Invalid role')
    for name,peer in pairs(c.peers) do
        assert(u.id(name) and type(peer)=='table' and u.integer(peer.computer,0,2147483647),'Invalid peer')
        assert(type(peer.key)=='string' and #peer.key==64 and not peer.key:find('[^0-9a-f]'),'Peer needs a 32-byte hex key')
    end
    if c.role~='hq' then assert(c.peers[c.hq] and c.peers[c.hq].role=='hq','Pinned HQ is missing') end
    return c
end

local function openNetwork(c)
    local names=c.modems or {}
    if #names==0 then names=u.namesWith('isWireless') end
    assert(#names>0,'Attach a modem and provide a working network link to HQ')
    for _,name in ipairs(names) do rednet.open(name) end
    return names
end

local function eventLogger(c,root)
    return function(row) store.log(root..'/events.jsonl',row,c.logBytes,c.logSegments) end
end

function M.outputs(c,alarm,fault)
    if c.alarmSide and sides[c.alarmSide] then redstone.setOutput(c.alarmSide,alarm==true) end
    if c.faultSide and sides[c.faultSide] then redstone.setOutput(c.faultSide,fault==true) end
end

local function acceptedObservation(raw,peer,name,now)
    if type(raw)~='table' or (raw.kind~='ship' and raw.kind~='player') or not u.position(raw)
        or not u.integer(raw.time,now-20000,now+1000) or raw.dimension~=peer.dimension then return nil end
    if peer.coverage and u.distance(raw,peer.coverage)>peer.coverage.radius then return nil end
    if raw.kind=='player' and not u.uuid(raw.id) then return nil end
    if raw.kind=='ship' and not u.id(raw.id,100) then return nil end
    return {kind=raw.kind,id=raw.id,namespace=peer.namespace,dimension=peer.dimension,
        x=raw.x,y=raw.y,z=raw.z,time=raw.time,source=name,
        name=u.text(raw.name,40) and raw.name or nil}
end
M.acceptedObservation=acceptedObservation -- exposed for deterministic tests

function M.hq(c,wire,root)
    local service=Service.new(c,root)
    local tracker=Tracker.new(eventLogger(c,root))
    local stations,beacons,pending={},{},{}
    local requestCounter=0
    local display=Display.new(c,root)
    local communications=Comms.new(service,tracker,stations,function(peer,body) wire:send(peer,body) end,eventLogger(c,root))
    local function request(q)
        requestCounter=requestCounter+1
        q.request='local-'..string.format('%.0f',u.now())..'-'..requestCounter
        if q.op=='pilot_candidates' then return communications:candidates(u.now()) end
        if q.op=='pilot_messages' then return communications:messages() end
        if q.op=='controller_message' then return communications:controller(q,u.now()) end
        return service:execute('hq-console','local_admin',q)
    end
    local function queuePolicy(name)
        if pending[name] then return end
        local data=u.json(Policy.snapshot(service.db,u.now()))
        if #data>256000 then
            wire:send(name,{op='policy_unavailable',note='HQ policy exceeds transfer capacity; controller must remove old records'})
            return
        end
        pending[name]={data=data,digest=crypto.sha256(data),revision=service.db.revision,
            index=1,total=math.ceil(#data/4000)}
    end
    local function handle(message)
        local b=message.body
        local from,role=message.from,message.role
        if b.op=='observations' and role=='station' then
            if type(b.items)~='table' or #b.items>24 then return end
            local now=u.now()
            local chat=type(b.chat)=='table' and b.chat or {}
            local previous=stations[from]
            if chat.ready==true and (not previous or not previous.chat.ready) then communications:resetStation(from) end
            stations[from]={lastMessage=now,note=u.text(b.note,200,true) and b.note or '',count=#b.items,
                chat={ready=chat.ready==true,publicHails=chat.publicHails==true}}
            for _,raw in ipairs(b.items) do
                local obs=acceptedObservation(raw,c.peers[from],from,now)
                if obs then tracker:ingest(obs,service.db,now) end
            end
        elseif b.op=='pilot_chat' and role=='station' then communications:handleChat(from,b,u.now())
        elseif b.op=='chat_result' and role=='station' then communications:result(from,b,u.now())
        elseif b.op=='sync' and role=='station' then queuePolicy(from)
        elseif b.op=='rpc' and (role=='kiosk' or role=='registrar') then
            if type(b.query)~='table' or not u.id(b.query.request,110) then return end
            local result=service:execute(from,role,b.query)
            wire:send(from,{op='reply',request=b.query.request,result=result})
        elseif b.op=='beacon' and role=='beacon' then
            local claimed=type(b.claimedUuid)=='string' and u.uuid(b.claimedUuid) and b.claimedUuid or ''
            local registration=service.db.beaconAssignments[from]
            local previous=beacons[from]
            beacons[from]={time=u.now(),registration=registration,claimedUuid=claimed}
            if not previous or u.now()-previous.logged>=30000 then
                store.log(root..'/events.jsonl',{event='beacon_claim',time=u.now(),key='beacon:'..from,
                    subject=registration and 'vessel:'..registration or nil,
                    note='Authenticated credential, NOT independently verified ship position or UUID',claimedUuid=claimed},c.logBytes,c.logSegments)
                beacons[from].logged=u.now()
            else beacons[from].logged=previous.logged end
            local notice='Credential received. Physical ship identity NOT verified by beacon.'
            if registration then
                for _,contact in pairs(tracker.contacts) do
                    if contact.subject=='vessel:'..registration and contact.decision.violation then
                        notice='AIRSPACE WARNING: '..contact.decision.zone..' / '..contact.decision.reason
                    end
                end
            end
            wire:send(from,{op='beacon_ack',registration=registration or 'UNASSIGNED',notice=notice})
        end
    end
    local function network()
        local timer=os.startTimer(0.25)
        local nextRefresh=0
        while true do
            local e={os.pullEvent()}
            if e[1]=='rednet_message' and e[4]==Wire.PROTOCOL then
                local message=wire:decode(e[2],e[3])
                if message then handle(message) end
            elseif e[1]=='timer' and e[2]==timer then
                local sent=0
                for _,name in ipairs(u.sorted(pending)) do
                    local p=pending[name]
                    if c.peers[name].revoked then pending[name]=nil
                    elseif sent<8 then
                        wire:send(name,{op='policy_part',revision=p.revision,digest=p.digest,index=p.index,total=p.total,
                            data=p.data:sub((p.index-1)*4000+1,p.index*4000)})
                        p.index=p.index+1; sent=sent+1
                        if p.index>p.total then pending[name]=nil end
                    end
                end
                if u.now()>=nextRefresh then
                    tracker:refresh(service.db,u.now()); nextRefresh=u.now()+1000
                    communications:tick(u.now())
                    display:draw('AACS NATIONAL AIRSPACE',tracker,'HQ ONLINE | registered ships '..u.count(service.db.vessels),service.db)
                end
                timer=os.startTimer(0.25)
            end
        end
    end
    parallel.waitForAny(network,function() UI.headquarters(request,tracker,root,stations,service) end)
end

function M.station(c,wire,root)
    assert(c.sensorsConfigured,'Run /aacs/start.lua setup to configure this station first')
    local cache=store.load(root..'/policy.json',{revision=0,validUntil=0,zones={},vessels={},players={},bindings={},permits={}})
    local tracker=Tracker.new(eventLogger(c,root))
    local sensors=Sensors.new(c)
    local display=Display.new(c,root)
    local chat=Chat.new(c,root,function(body) wire:send(c.hq,body) end)
    chat:tick(u.now())
    local chatTimer=c.chatBox and c.chatBox~='' and os.startTimer(0.5) or nil
    local assembly=nil
    local policyProblem=nil
    local nextSync=0
    local function receivePolicy(b)
        if b.op~='policy_part' or not u.integer(b.revision,cache.revision,1000000000)
            or not u.integer(b.total,1,64) or not u.integer(b.index,1,b.total)
            or type(b.data)~='string' or #b.data>4000 or type(b.digest)~='string' or #b.digest~=64 then return end
        if not assembly or assembly.digest~=b.digest then
            assembly={digest=b.digest,revision=b.revision,total=b.total,parts={},started=u.now()}
        end
        if assembly.revision~=b.revision or assembly.total~=b.total then return end
        assembly.parts[b.index]=b.data
        for i=1,assembly.total do if not assembly.parts[i] then return end end
        local data=table.concat(assembly.parts)
        if not crypto.equal(crypto.sha256(data),assembly.digest) then assembly=nil; return end
        local new=u.decode(data)
        if not new or new.revision~=assembly.revision or not u.integer(new.validUntil,u.now(),u.now()+61000)
            or type(new.zones)~='table' or type(new.vessels)~='table' or type(new.players)~='table'
            or type(new.bindings)~='table' or type(new.permits)~='table' then assembly=nil; return end
        for _,zone in pairs(new.zones) do if not Policy.validateZone(zone) then assembly=nil; return end end
        store.save(root..'/policy.json',new)
        cache=new; assembly=nil; policyProblem=nil
    end
    local timer=os.startTimer(0.1)
    print('AACS station starting. Press Q to stop.')
    while true do
        local e={os.pullEvent()}
        if e[1]=='char' and e[2]:lower()=='q' then return end
        if e[1]=='rednet_message' and e[4]==Wire.PROTOCOL then
            local message=wire:decode(e[2],e[3])
            if message and message.from==c.hq then
                if message.body.op=='chat_notice' then
                    -- Wire sequences persist across HQ restarts; local counters do not.
                    if message.body.thread and message.seq then message.body.version=message.seq end
                    chat:accept(message.body,u.now())
                elseif message.body.op=='chat_cancel' then chat:cancel(message.body.id)
                elseif message.body.op=='chat_reset' then chat:reset()
                elseif message.body.op=='policy_unavailable' then
                    policyProblem=true;cache.validUntil=0
                else receivePolicy(message.body) end
            end
        elseif e[1]=='chat' then
            local username,message,uuid=Chat.event(e)
            local relay=chat:relay(username,message,uuid,u.now())
            if relay then wire:send(c.hq,relay) end
        elseif e[1]=='timer' and e[2]==chatTimer then
            chat:tick(u.now())
            chatTimer=os.startTimer(0.5)
        elseif e[1]=='timer' and e[2]==timer then
            local now=u.now()
            local observations,errors=sensors:scan()
            for _,obs in ipairs(observations) do tracker:ingest(obs,cache,now) end
            tracker:refresh(cache,now)
            local note=table.concat(u.sorted(errors),', ')
            if note~='' then note='Sensor warnings: '..note else note='Sensor calls OK; coverage requires field verification' end
            for first=1,math.max(1,#observations),24 do
                local items={}
                for i=first,math.min(#observations,first+23) do items[#items+1]=observations[i] end
                wire:send(c.hq,{op='observations',items=items,note=note:sub(1,200),chat=chat:status()})
            end
            if now>=nextSync then wire:send(c.hq,{op='sync'}); nextSync=now+20000 end
            if assembly and now-assembly.started>30000 then assembly=nil end
            local offline=now>cache.validUntil
            local alarm=false
            for _,contact in pairs(tracker.contacts) do if contact.decision.violation then alarm=true end end
            M.outputs(c,alarm,offline or next(errors)~=nil)
            local status=offline and 'HQ POLICY STALE: cached rules, observation only' or ('HQ POLICY CURRENT r'..cache.revision)
            if next(errors) then status=status..' | SENSOR FAULT' end
            if policyProblem then status=status..' | HQ POLICY UNAVAILABLE' end
            if c.chatBox and c.chatBox~='' and not chat.ready then status=status..' | CHAT OFFLINE' end
            local monitorReady=display:draw('AACS '..c.node,tracker,status,cache)
            if not monitorReady then status=status..' | MONITOR OFFLINE' end
            local chatStatus=c.chatBox and c.chatBox~='' and (' | Chat '..(chat.ready and 'ready' or 'OFFLINE')) or ''
            UI.draw(term,'AACS '..c.node..' | Q stops',tracker,status,cache,display:footer()..chatStatus)
            timer=os.startTimer(c.scanSeconds or 2)
        end
    end
end

function M.rpc(c,wire,query)
    local pendingPath=M.ROOT..'/pending-request.json'
    local pending=store.load(pendingPath,{})
    if query.op=='resume_pending' then
        if not pending.query then return {ok=false,error='No pending request'} end
        query=pending.query
    else
        if pending.query then return {ok=false,error='An earlier request is unresolved. Choose R to retry it first.'} end
        query.request=c.node..'-'..string.format('%.0f',wire.nextSequence)
        store.save(pendingPath,{query=query,time=u.now()})
    end
    for attempt=1,3 do
        wire:send(c.hq,{op='rpc',query=query})
        local timer=os.startTimer(5)
        while true do
            local e={os.pullEvent()}
            if e[1]=='timer' and e[2]==timer then break end
            if e[1]=='rednet_message' and e[4]==Wire.PROTOCOL then
                local message=wire:decode(e[2],e[3])
                if message and message.from==c.hq and message.body.op=='reply'
                    and message.body.request==query.request and type(message.body.result)=='table' then
                    os.cancelTimer(timer)
                    store.save(pendingPath,{})
                    return message.body.result
                end
            end
        end
    end
    return {ok=false,error='HQ did not acknowledge. Outcome may be unknown; check the receipt/registry before resubmitting.',request=query.request}
end

function M.beacon(c,wire)
    local notice='Waiting for HQ'
    local timer=os.startTimer(0.1)
    while true do
        local e={os.pullEvent()}
        if e[1]=='char' and e[2]:lower()=='q' then return end
        if e[1]=='timer' and e[2]==timer then
            local claim,err=Sensors.beacon()
            local body=claim or {}; body.op='beacon'
            wire:send(c.hq,body)
            term.clear(); term.setCursorPos(1,1)
            print('AACS CREDENTIAL BEACON | '..c.node)
            print(claim and ('Local claimed UUID: '..claim.claimedUuid) or (err or 'No ship API'))
            print(notice)
            print('Broadcast identity is NOT physical proof. Q stops.')
            timer=os.startTimer(5)
        elseif e[1]=='rednet_message' and e[4]==Wire.PROTOCOL then
            local message=wire:decode(e[2],e[3])
            if message and message.from==c.hq and message.body.op=='beacon_ack'
                and u.text(message.body.notice,200) then
                notice=tostring(message.body.registration)..': '..message.body.notice
            end
        end
    end
end

function M.run(boot)
    local c=M.config()
    fs.makeDir(M.ROOT)
    local lock=M.ROOT..'/run.lock'
    if boot and fs.exists(lock) then fs.delete(lock) end
    assert(not fs.exists(lock),'AACS is running or stopped uncleanly. Reboot, or stop every AACS process before unlock.')
    u.write(lock,tostring(u.now()))
    local opened={}
    local ok,err=xpcall(function()
        settings.set('shell.allow_disk_startup',false); settings.save()
        opened=openNetwork(c)
        local wire=Wire.new(c,M.ROOT)
        if c.role=='hq' then M.hq(c,wire,M.ROOT)
        elseif c.role=='station' then M.station(c,wire,M.ROOT)
        elseif c.role=='beacon' then M.beacon(c,wire)
        else UI.registration(function(q) return M.rpc(c,wire,q) end,c.role=='kiosk',true) end
    end,function(e) return tostring(e) end)
    M.outputs(c,false,false)
    for _,name in ipairs(opened) do pcall(rednet.close,name) end
    if fs.exists(lock) then fs.delete(lock) end
    if not ok then error(err,0) end
end

function M.setup()
    local c=M.config()
    assert(not fs.exists(M.ROOT..'/run.lock'),'Stop AACS first')
    print('Node: '..c.node..' ('..c.role..')')
    print('Available peripherals:')
    for _,name in ipairs(peripheral.getNames()) do print('  '..name..' | '..tostring(peripheral.getType(name))) end
    c.monitor=UI.prompt('Optional monitor name (- disables)',c.monitor or '')
    if c.monitor=='-' then c.monitor='' end
    if c.role=='station' then
        print('Radar candidates: '..table.concat(u.namesWith('getTracks'),', '))
        local radar=UI.prompt('Radar name(s), comma separated; blank for player-only',table.concat(c.radars or {},','))
        c.radars={}
        for name in radar:gmatch('[^,%s]+') do assert(u.methods(name).getTracks,'No getTracks on '..name); c.radars[#c.radars+1]=name end
        c.playerDetector=UI.prompt('Player Detector peripheral name (optional)',c.playerDetector or '')
        if c.playerDetector~='' then assert(u.methods(c.playerDetector).getPlayersInRange,'Invalid Player Detector') end
        assert(#c.radars>0 or c.playerDetector~='','Configure at least one sensor')
        c.playerRange=tonumber(UI.prompt('Player detection radius (blocks)',c.playerRange or 128))
        assert(u.number(c.playerRange,1,1000000),'Invalid radius')
        local cov=c.coverage or {x=0,y=64,z=0,radius=4096}
        for _,axis in ipairs({'x','y','z'}) do cov[axis]=tonumber(UI.prompt('Ground station world '..axis,cov[axis])) end
        cov.radius=tonumber(UI.prompt('Maximum plausible radar distance',cov.radius))
        assert(u.position(cov) and u.number(cov.radius,1,1000000),'Invalid station coverage')
        c.coverage=cov
        c.alarmSide=UI.prompt('Alarm output side (lamp/siren ONLY; blank disables)',c.alarmSide or '')
        c.faultSide=UI.prompt('Fault indicator side (blank disables)',c.faultSide or '')
        assert(c.alarmSide=='' or sides[c.alarmSide],'Invalid side')
        assert(c.faultSide=='' or sides[c.faultSide],'Invalid side')
        assert(c.alarmSide=='' or c.alarmSide~=c.faultSide,'Alarm and fault outputs must differ')
        local candidates=u.namesWith('sendMessage')
        local default=c.chatBox
        if default==nil or default=='' then default=#candidates==1 and candidates[1] or '' end
        c.chatBox=UI.prompt('Chat Box peripheral name (- disables)',default)
        if c.chatBox=='-' then c.chatBox='' end
        if c.chatBox~='' then
            local box,problem=Chat.inspect(c)
            assert(box,problem)
            c.chatPublicHails=UI.prompt('Allow public hails for unassigned vessels? y/N',c.chatPublicHails and 'y' or 'n'):lower()=='y'
            c.chatIntervalSeconds=1.5
        end
        c.sensorsConfigured=true
    end
    u.write(M.CONFIG,u.json(c))
    settings.set('shell.allow_disk_startup',false); settings.save()
    print('Saved. Start with /aacs/start.lua run')
end

function M.diagnose()
    print('Computer ID: '..os.getComputerID())
    print('CC host: '..tostring(_HOST))
    local lines={}
    for _,name in ipairs(peripheral.getNames()) do
        local methods=u.methods(name)
        local line=name..' ['..tostring(peripheral.getType(name))..'] '..table.concat(u.sorted(methods),', ')
        print(line); lines[#lines+1]=line
        if methods.getTracks then
            local tracks,err=u.safeCall(peripheral.wrap(name),'getTracks')
            lines[#lines+1]=err or u.json(tracks or {})
            print('  Raw tracks: '..tostring(type(tracks)=='table' and u.count(tracks) or 'ERROR'))
        end
    end
    local configured,c=pcall(M.config)
    if configured and c.role=='station' then
        local configuredLine='Configured sensors: '..u.json({radars=c.radars or {},
            playerDetector=c.playerDetector or '',playerRange=c.playerRange,coverage=c.coverage})
        print(configuredLine); lines[#lines+1]=configuredLine
        local scanner=Sensors.new(c)
        local observations,errors=scanner:scan()
        local summary='Sensor check: '..#observations..' observations (radar needs another scan), '..u.count(errors)..' errors'
        print(summary); lines[#lines+1]=summary
        for _,name in ipairs(u.sorted(errors)) do
            local message='Sensor error ['..name..']: '..tostring(errors[name])
            print(message); lines[#lines+1]=message
        end
    end
    if configured then
        local ok,screen,reason=pcall(Display.inspect,c)
        local summary='Configured monitor: '..tostring(c.monitor or '')..' | '..
            (ok and screen and 'available' or tostring(ok and reason or screen))
        print(summary); lines[#lines+1]=summary
        local statusPath=M.ROOT..'/monitor-status.json'
        if fs.exists(statusPath) then
            local saved=u.decode(u.read(statusPath))
            if saved then
                local message='Last monitor write: '..u.json(saved)
                print(message); lines[#lines+1]=message
            end
        end
        if c.role=='station' then
            local ok,box,reason=pcall(Chat.inspect,c)
            local summary='Configured Chat Box: '..tostring(c.chatBox or '')..' | '..
                (ok and box and 'available' or tostring(ok and reason or box))
            print(summary);lines[#lines+1]=summary
            local chatPath=M.ROOT..'/chat-status.json'
            if fs.exists(chatPath) then
                local health=u.decode(u.read(chatPath))
                if health then local line='Last Chat Box status: '..u.json(health);print(line);lines[#lines+1]=line end
            end
        end
    end
    local claim,err=Sensors.beacon()
    lines[#lines+1]=claim and u.json(claim) or ('Optional onboard beacon: '..tostring(err))
    u.write('/aacs/diagnostics.txt',table.concat(lines,'\n'))
    print('Saved /aacs/diagnostics.txt (contains coordinates; keep private).')
end
return M

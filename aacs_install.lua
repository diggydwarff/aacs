-- AACS 0.2.3-beta.1: offline, code-only installer. No credentials or network downloads.
-- Stop AACS first. Updates never touch /aacs/config.json or /aacs/data/.
local args={...}
local upgrade=args[1]=='--upgrade'
assert(args[1]==nil or upgrade,'Usage: aacs_install.lua [--upgrade]')
assert(not fs.exists('/aacs/data/run.lock'),'Stop AACS before installing/upgrading')
assert(upgrade or not fs.exists('/aacs/start.lua'),'Already installed. Use --upgrade to replace code only.')
local files={
    ["/aacs/lib/app.lua"] = [===[
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
]===],
    ["/aacs/lib/chat.lua"] = [===[
-- Station-side Chat Box adapter. Work is queued; no sleep blocks radar scans.
local util = require('aacs.lib.util')
local M = {}

function M.username(value)
    return type(value) == 'string' and #value >= 1 and #value <= 16
        and value:match('^[A-Za-z0-9_]+$') ~= nil
end

function M.command(message)
    if not util.text(message, 240) then return nil end
    local text = message:gsub('^%$', '')
    local prefix, rest = text:match('^(%S+)%s*(.-)%s*$')
    if not prefix or prefix:lower() ~= 'atc' then return nil end
    return rest ~= '' and rest or 'help'
end

function M.event(event)
    -- AP 0.7: name, message, UUID. AP 0.8: UUID, name, message.
    -- Validate the event fields; never take an identity from command text.
    if util.uuid(event[2]) and M.username(event[3]) then
        return event[3], event[4], event[2]
    end
    if M.username(event[2]) and util.uuid(event[4]) then
        return event[2], event[3], event[4]
    end
    return nil
end

function M.inspect(config)
    local name = config.chatBox
    if type(name) ~= 'string' or name == '' then return nil, 'Chat Box disabled' end
    if not peripheral.isPresent(name) then return nil, 'Configured Chat Box is unavailable' end
    if not peripheral.hasType(name, 'chat_box') and not peripheral.hasType(name, 'chatBox') then
        return nil, 'Configured peripheral is not a Chat Box'
    end
    local box = peripheral.wrap(name)
    if not box or type(box.sendMessage) ~= 'function' then
        return nil, 'Chat Box has no sendMessage method'
    end
    return box
end

function M.send(box, message, recipient)
    -- AP 0.7 / the user's existing peripheral exposes sendMessageToPlayer.
    -- AP 0.8 consolidated targeting into the sendMessage options table.
    if type(box.sendMessageToPlayer) == 'function' then
        if recipient then return util.safeCall(box, 'sendMessageToPlayer', message, recipient, 'AACS') end
        return util.safeCall(box, 'sendMessage', message, 'AACS')
    end
    return util.safeCall(box, 'sendMessage', message, {player = recipient, prefix = 'AACS'})
end

function M.new(config, root, report)
    local self = {queue = {}, completed = {}, order = {}, relays = {}, sent = 0,
        nextSend = 0, ready = false, error = nil}
    local interval = tonumber(config.chatIntervalSeconds) or 1.5
    interval = math.max(1, math.min(interval, 30)) * 1000

    local function finish(item, status, detail, quiet)
        local result = {op = 'chat_result', id = item.id, status = status,
            detail = tostring(detail or ''):sub(1, 160)}
        self.completed[item.id] = result
        self.order[#self.order + 1] = item.id
        while #self.order > 128 do self.completed[table.remove(self.order, 1)] = nil end
        if not quiet then report(result) end
    end

    function self:cancel(id)
        if not util.id(id, 100) then return false end
        if self.completed[id] then return true end
        for index = #self.queue, 1, -1 do
            if self.queue[index].id == id then table.remove(self.queue, index) end
        end
        -- Keep a tombstone even if cancellation arrives before its notice.
        finish({id = id}, 'cancelled', 'Cancelled by HQ')
        return true
    end

    function self:reset()
        for index = #self.queue, 1, -1 do
            local item = table.remove(self.queue, index)
            finish(item, 'cancelled', 'HQ connection reset', true)
        end
    end

    function self:accept(body, now)
        if type(body) ~= 'table' or not util.id(body.id, 100)
            or not util.integer(body.expires, now + 1, now + 30000)
            or not util.text(body.text, 600)
            or (body.recipient ~= nil and not M.username(body.recipient))
            or not util.integer(body.priority or 1, 1, 3)
            or (body.thread ~= nil and (not util.text(body.thread, 240) or not util.integer(body.version, 1, 9007199254740991))) then return false end
        if self.completed[body.id] then report(self.completed[body.id]); return true end
        for _, item in ipairs(self.queue) do if item.id == body.id then return true end end
        if body.thread then
            for index = #self.queue, 1, -1 do
                local item = self.queue[index]
                if item.thread == body.thread then
                    if item.version >= body.version then finish(body, 'failed', 'Newer notice already queued'); return false end
                    table.remove(self.queue, index)
                    finish(item, 'failed', 'Superseded by a newer airspace notice')
                end
            end
        end
        if not body.recipient and config.chatPublicHails ~= true then
            finish(body, 'failed', 'Public broadcasts disabled on this station')
            return false
        end
        if #self.queue >= 32 then
            local lowest = 1
            for index, item in ipairs(self.queue) do
                if item.priority < self.queue[lowest].priority then lowest = index end
            end
            if self.queue[lowest].priority < (body.priority or 1) then
                local displaced = table.remove(self.queue, lowest)
                finish(displaced, 'failed', 'Displaced by a higher-priority notice')
            else
                finish(body, 'failed', 'Chat queue full')
                return false
            end
        end
        local item = util.copy(body)
        item.priority = item.priority or 1
        item.attempts = 0
        self.queue[#self.queue + 1] = item
        return true
    end

    function self:relay(username, message, uuid, now)
        local command = M.command(message)
        if not self.ready or not command or not M.username(username) or not util.uuid(uuid) then return nil end
        uuid = uuid:lower()
        for id, stamp in pairs(self.relays) do if now - stamp > 60000 then self.relays[id] = nil end end
        if now - (self.relays[uuid] or 0) < 2000 then return nil end
        if util.count(self.relays) >= 128 and not self.relays[uuid] then return nil end
        local second = math.floor(now / 1000)
        if self.relaySecond ~= second then self.relaySecond = second; self.relayCount = 0 end
        if self.relayCount >= 4 then return nil end
        self.relayCount = self.relayCount + 1
        self.relays[uuid] = now
        return {op = 'pilot_chat', username = username, uuid = uuid, command = command, time = now}
    end

    function self:tick(now)
        local ok, box, problem = pcall(M.inspect, config)
        if not ok then problem = box; box = nil end
        self.ready = box ~= nil
        if self.ready then self.error = self.sendError
        else self.error = tostring(problem):sub(1, 200) end
        for index = #self.queue, 1, -1 do
            local item = self.queue[index]
            if item.expires <= now then
                table.remove(self.queue, index)
                finish(item, 'failed', 'Notice expired before sending')
            end
        end
        if box and now >= self.nextSend and #self.queue > 0 then
            local selected = 1
            for index, item in ipairs(self.queue) do
                if item.priority > self.queue[selected].priority then selected = index end
            end
            local item = self.queue[selected]
            local sent, detail = M.send(box, item.text, item.recipient)
            item.attempts = item.attempts + 1
            self.nextSend = now + interval
            if sent == true then
                table.remove(self.queue, selected)
                self.sent = self.sent + 1
                self.lastSent = now
                self.sendError = nil
                self.error = nil
                finish(item, 'sent', 'Chat Box accepted message; pilot reading is not confirmed')
            else
                self.error = tostring(detail or 'Chat Box did not accept message'):sub(1, 200)
                self.sendError = self.error
                self.nextSend = now + math.min(interval * item.attempts, 10000)
                if item.attempts >= 3 then
                    table.remove(self.queue, selected)
                    finish(item, 'failed', self.error)
                end
            end
        end
        local state = self:status()
        local signature = tostring(state.ready) .. tostring(state.error) .. ':' .. state.queued .. ':' .. state.sent
        if root and (signature ~= self.saved or now - (self.savedAt or 0) >= 5000) then
            pcall(util.write, root .. '/chat-status.json', util.json(state))
            self.saved = signature
            self.savedAt = now
        end
    end

    function self:status()
        return {configured = type(config.chatBox) == 'string' and config.chatBox ~= '',
            peripheral = config.chatBox or '', ready = self.ready, error = self.error,
            queued = #self.queue, sent = self.sent, lastSent = self.lastSent,
            publicHails = config.chatPublicHails == true}
    end

    return self
end

return M
]===],
    ["/aacs/lib/comms.lua"] = [===[
-- HQ owns pilot sessions and notice decisions. Stations only relay and send.
local util = require('aacs.lib.util')
local Chat = require('aacs.lib.chat')
local M = {}
local SESSION_MS = 2 * 60 * 60 * 1000
local WARNING_MS = 30000

local function clean(text, limit)
    return tostring(text or ''):gsub('[%c&]', ''):sub(1, limit or 120)
end

local function label(contact, db)
    local registration = contact.subject and contact.subject:match('^vessel:(.+)$')
    local vessel = registration and db.vessels[registration]
    return vessel and (clean(vessel.name, 60) .. ' [' .. registration .. ']')
        or (contact.kind == 'player' and clean(contact.name or contact.id, 40) or 'Unidentified vessel')
end

local function zoneText(zone)
    return clean(zone.name, 60) .. ' [' .. zone.id .. ', ' .. zone.class .. ']'
end

function M.new(service, tracker, stations, send, emit)
    local self = {sessions = {}, recent = {}, seenCommands = {}, states = {},
        queue = {}, pending = {}, counter = 0, lastPublic = 0, unroutable = {}, inbox = {}}
    emit = emit or function() end

    local function record(event, fields)
        fields = fields or {}
        fields.event = event
        fields.time = util.now()
        emit(fields)
    end

    local function available(name, now, public)
        local station = stations[name]
        local peer = service.config.peers[name]
        return peer and not peer.revoked and peer.role == 'station' and station
            and now - station.lastMessage <= 15000 and station.chat and station.chat.ready == true
            and (not public or station.chat.publicHails == true)
    end

    function self:cancel(predicate, reason, quiet)
        for index = #self.queue, 1, -1 do
            local item = self.queue[index]
            if predicate(item) then
                table.remove(self.queue, index)
                record('chat_cancelled', {id = item.body.id, subject = item.subject, note = reason})
            end
        end
        for id, item in pairs(self.pending) do
            if predicate(item) then
                self.pending[id] = nil
                if not quiet then
                    pcall(send, item.station, {op = 'chat_cancel', id = id})
                end
                record('chat_cancelled', {id = id, station = item.station, subject = item.subject, note = reason})
            end
        end
    end

    function self:resetStation(name)
        self:cancel(function(item) return item.station == name end, 'Sending station reconnected', true)
        pcall(send, name, {op = 'chat_reset'})
    end

    local function cancelPilot(uuid)
        self:cancel(function(item)
            return item.uuid == uuid and item.subject and item.subject:match('^vessel:') ~= nil
        end, 'Pilot checked out, expired, or approval changed')
    end

    function self:station(preferred, now, public)
        if preferred and available(preferred, now, public) then return preferred end
        for _, name in ipairs(util.sorted(stations)) do
            if available(name, now, public) then return name end
        end
        return nil
    end

    function self:session(uuid, now)
        local session = self.sessions[uuid]
        local authorization = (service.db.pilots or {})[uuid]
        local vessel = session and service.db.vessels[session.registration]
        if not session or session.expires <= now or not authorization or authorization.expires <= now
            or authorization.registration ~= session.registration or not vessel then
            if session then cancelPilot(uuid) end
            self.sessions[uuid] = nil
            return nil
        end
        return session
    end

    function self:notice(station, recipient, text, priority, subject, now, uuid, thread)
        if thread then
            self:cancel(function(item) return item.body.thread == thread end, 'Superseded by current airspace status')
        end
        station = self:station(station, now, recipient == nil)
        if not station then return nil, 'No station with a current, available Chat Box' end
        if #self.queue >= 128 then
            local lowest = 1
            for index, item in ipairs(self.queue) do
                if item.body.priority < self.queue[lowest].body.priority then lowest = index end
            end
            if self.queue[lowest].body.priority >= (priority or 1) then return nil, 'HQ notice queue full' end
            local displaced = table.remove(self.queue, lowest)
            record('chat_failed', {id = displaced.body.id, subject = displaced.subject,
                note = 'Displaced by a higher-priority notice'})
        end
        self.counter = self.counter + 1
        local id = 'ATC-' .. string.format('%.0f', now) .. '-' .. self.counter
        if priority == 3 and recipient and uuid then text = clean(text, 500) .. ' Notice ' .. id .. '. Reply $atc ack.' end
        local body = {op = 'chat_notice', id = id, recipient = recipient,
            text = clean(text, 600), priority = priority or 1, expires = now + 20000,
            thread = thread, version = thread and self.counter or nil}
        self.queue[#self.queue + 1] = {station = station, body = body, subject = subject, uuid = uuid}
        return id
    end

    local function contactFor(registration, now)
        local contact = tracker.contacts['vessel:' .. registration]
        if contact and now - contact.time <= 20000 then return contact end
        return nil
    end

    local function statusText(registration, now)
        local contact = contactFor(registration, now)
        if not contact then return registration .. ': no fresh radar contact. Position and airspace status unknown.' end
        if contact.conflict then return label(contact, service.db) .. ': radar position inconsistent; contact control.' end
        local parts = {}
        for _, state in ipairs(contact.decision.zones) do
            local zone = service.db.zones[state.id]
            if zone then parts[#parts + 1] = zoneText(zone) .. (state.allowed and ': allowed' or ': NO CLEARANCE') end
        end
        local position = string.format(' X %.0f Y %.0f Z %.0f. ', contact.x, contact.y, contact.z)
        return label(contact, service.db) .. position .. (#parts > 0 and table.concat(parts, '; ') or 'Outside configured zones.')
    end

    local function reply(from, username, uuid, text, now)
        return self:notice(from, username, text, 2, 'pilot:' .. uuid, now, uuid)
    end

    function self:candidates(now)
        local items = {}
        for uuid, item in pairs(self.recent) do
            if now - item.time <= 600000 then
                items[#items + 1] = {uuid = uuid, username = item.username,
                    registration = item.registration, station = item.station, time = item.time}
            end
        end
        table.sort(items, function(a, b) return a.username < b.username end)
        return {ok = true, items = items}
    end

    function self:messages()
        return {ok = true, items = util.copy(self.inbox)}
    end

    local function inbox(row)
        self.inbox[#self.inbox + 1] = row
        while #self.inbox > 64 do table.remove(self.inbox, 1) end
    end

    function self:handleChat(from, body, now)
        if not available(from, now, false) or type(body) ~= 'table'
            or not Chat.username(body.username) or not util.uuid(body.uuid)
            or not util.text(body.command, 240) or not util.integer(body.time, now - 10000, now + 1000) then return false end
        local uuid = body.uuid:lower()
        local command, argument = body.command:match('^(%S+)%s*(.-)%s*$')
        if not command then return false end
        command = command:lower()
        for id, seen in pairs(self.seenCommands) do if now - seen.time >= 60000 then self.seenCommands[id] = nil end end
        local signature = command .. ' ' .. argument
        local seen = self.seenCommands[uuid]
        -- Every station may hear the same server chat event. Process it once.
        if seen and (now - seen.time < 2000 or (seen.signature == signature and now - seen.time < 3000)) then return false end
        if util.count(self.seenCommands) >= 256 and not seen then return false end
        self.seenCommands[uuid] = {time = now, signature = signature}
        local username = body.username
        if command == 'help' then
            reply(from, username, uuid, 'Commands: $atc checkin ARD-0001 | checkout | status | zones [page] | zone ID | ack [notice ID] | say MESSAGE. Check-in needs HQ pilot approval. Chat cannot grant clearance.', now)
        elseif command == 'checkin' then
            argument = argument:upper()
            if not argument:match('^ARD%-%d+$') or #argument > 20 then
                reply(from, username, uuid, 'Use $atc checkin ARD-0001 with your vessel registration.', now)
                return true
            end
            for id, item in pairs(self.recent) do if now - item.time > 600000 then self.recent[id] = nil end end
            if util.count(self.recent) < 128 or self.recent[uuid] then
                self.recent[uuid] = {username = username, registration = argument, station = from, time = now}
            end
            local authorization = (service.db.pilots or {})[uuid]
            local vessel = service.db.vessels[argument]
            if not authorization or authorization.registration ~= argument or authorization.expires <= now or not vessel then
                reply(from, username, uuid, 'Check-in requires HQ approval for your account and this registered vessel. Controller: HQ menu P, approve recent check-in. Then repeat check-in. No clearance granted.', now)
                return true
            end
            local previous = self:session(uuid, now)
            if previous and (previous.registration ~= argument or previous.username ~= username) then cancelPilot(uuid) end
            self.sessions[uuid] = {uuid = uuid, username = username, registration = argument, station = from,
                expires = math.min(now + SESSION_MS, authorization.expires),
                warnings = previous and previous.registration == argument and previous.warnings or {},
                lastWarning = previous and previous.registration == argument and previous.lastWarning or nil}
            record('pilot_checkin', {subject = 'vessel:' .. argument, pilot = uuid, station = from})
            reply(from, username, uuid, 'Checked in for up to 2 hours; renew with checkin. ' .. statusText(argument, now), now)
        elseif command == 'checkout' then
            local session = self:session(uuid, now)
            record('pilot_checkout', {pilot = uuid, subject = session and 'vessel:' .. session.registration})
            cancelPilot(uuid)
            self.sessions[uuid] = nil
            reply(from, username, uuid, 'Checked out. Private vessel notices to this account are stopped.', now)
        elseif command == 'zones' then
            local page = argument == '' and 1 or tonumber(argument)
            local keys = {}
            for _, id in ipairs(util.sorted(service.db.zones)) do
                if service.db.zones[id].enabled ~= false then keys[#keys + 1] = id end
            end
            local pages = math.max(1, math.ceil(#keys / 3))
            if not util.integer(page, 1, pages) then
                reply(from, username, uuid, 'Use $atc zones PAGE, from 1 to ' .. pages .. '.', now)
                return true
            end
            local parts = {}
            for index = (page - 1) * 3 + 1, math.min(page * 3, #keys) do
                parts[#parts + 1] = zoneText(service.db.zones[keys[index]])
            end
            reply(from, username, uuid, 'Zones ' .. page .. '/' .. pages .. ': ' .. (#parts > 0 and table.concat(parts, '; ') or 'none configured') .. '. Details: $atc zone ID', now)
        elseif command == 'zone' then
            local zone = service.db.zones[argument]
            if not zone or zone.enabled == false then reply(from, username, uuid, 'Unknown or disabled zone. Use $atc zones.', now); return true end
            local boundary
            if zone.shape == 'box' then
                boundary = string.format('X %g..%g, Z %g..%g', zone.minX, zone.maxX, zone.minZ, zone.maxZ)
            else
                boundary = string.format('center X %g Z %g, radius %g blocks', zone.x, zone.z, zone.radius)
            end
            local rule = ({unrestricted = 'Open to observed contacts.', controlled = 'Active registration required.',
                restricted = 'Active registration and explicit zone permit required.',
                prohibited = 'Entry prohibited without an explicit zone permit and active registration.'})[zone.class]
            reply(from, username, uuid, zoneText(zone) .. ': ' .. boundary .. string.format(', Y %g..%g. ', zone.minY, zone.maxY)
                .. zone.dimension .. '; applies to ' .. zone.applies .. '. ' .. rule, now)
        elseif command == 'status' or command == 'ack' or command == 'say' then
            local session = self:session(uuid, now)
            if not session then reply(from, username, uuid, 'No active pilot check-in. Use $atc checkin ARD-0001.', now); return true end
            session.username = username
            session.station = from
            if command == 'status' then
                reply(from, username, uuid, statusText(session.registration, now), now)
            elseif command == 'say' then
                if not util.text(argument, 160) then
                    reply(from, username, uuid, 'Use $atc say MESSAGE (1-160 characters).', now)
                else
                    local row = {pilot = uuid, username = username, registration = session.registration,
                        subject = 'vessel:' .. session.registration, text = clean(argument, 160), time = now, station = from}
                    inbox(row)
                    record('pilot_message', util.copy(row))
                    reply(from, username, uuid, 'Message recorded for control. This does not confirm a controller has read it or grant clearance.', now)
                end
            else
                local id = argument ~= '' and argument or session.lastWarning
                local warning = id and session.warnings[id]
                if not warning or now - warning.time > 600000 then
                    reply(from, username, uuid, 'No recent warning with that ID for your active check-in.', now)
                else
                    warning.acknowledged = true
                    record('pilot_ack', {id = id, pilot = uuid, username = username, station = from, subject = 'vessel:' .. session.registration})
                    inbox({username = username, registration = session.registration, time = now,
                        text = 'Acknowledged notice ' .. id, station = from})
                    reply(from, username, uuid, 'Acknowledged ' .. id .. '. Acknowledgement does not grant clearance; unresolved warnings continue.', now)
                end
            end
        else
            reply(from, username, uuid, 'Unknown ATC command. Use $atc help. Clearance changes require a controller.', now)
        end
        return true
    end

    function self:result(from, body, now)
        if type(body) ~= 'table' then return false end
        local item = self.pending[body.id]
        if not item or item.station ~= from or item.body.expires <= now
            or (body.status ~= 'sent' and body.status ~= 'failed') then return false end
        self.pending[body.id] = nil
        record(body.status == 'sent' and 'chat_sent' or 'chat_failed', {id = body.id, station = from,
            subject = item.subject, pilot = item.uuid, note = clean(body.detail, 160)})
        return true
    end

    local function notify(contact, text, priority, now)
        local reached = false
        for _, uuid in ipairs(util.sorted(self.sessions)) do
            local session = self:session(uuid, now)
            if session and contact.subject == 'vessel:' .. session.registration then
                local id = self:notice(contact.source or session.station, session.username,
                    text, priority, contact.subject, now, uuid, 'airspace:' .. contact.key .. ':' .. uuid)
                if id then
                    reached = true
                    if priority == 3 then
                        session.lastWarning = id
                        session.warnings[id] = {time = now}
                        for warningId, warning in pairs(session.warnings) do
                            if now - warning.time > 600000 then session.warnings[warningId] = nil end
                        end
                    end
                end
            end
        end
        if not reached then
            if priority == 3 and now - self.lastPublic >= WARNING_MS then
                local station = self:station(contact.source, now, true)
                if station then
                    local position = string.format(' near X %.0f Y %.0f Z %.0f', contact.x, contact.y, contact.z)
                    reached = self:notice(station, nil, label(contact, service.db) .. position .. ': ' .. text, priority, contact.subject or contact.sensorKey, now,
                        nil, 'airspace:' .. contact.key .. ':public') ~= nil
                    if reached then self.lastPublic = now end
                end
            end
            local key = contact.subject or contact.sensorKey or contact.key
            if not reached and now - (self.unroutable[key] or 0) >= WARNING_MS then
                self.unroutable[key] = now
                record('chat_unroutable', {subject = contact.subject, key = key,
                    note = 'No checked-in pilot or available sending station; public hails may be disabled'})
            end
        end
        return reached
    end

    function self:controller(query, now)
        if not util.text(query.text, 400) then return {ok = false, error = 'Message must be 1-400 printable characters'} end
        local target = query.target
        if type(target) ~= 'string' then return {ok = false, error = 'Choose a registration, username, or ALL'} end
        if target:match('^ARD%-%d+$') then
            local count = 0
            for _, uuid in ipairs(util.sorted(self.sessions)) do
                local session = self:session(uuid, now)
                if session and session.registration == target then
                    if self:notice(query.station ~= '' and query.station or session.station, session.username,
                        'CONTROL: ' .. query.text, 2, 'vessel:' .. target, now, uuid) then count = count + 1 end
                end
            end
            return {ok = count > 0, queued = count, error = count == 0 and 'No checked-in pilot or available station' or nil}
        end
        if target ~= 'ALL' and not Chat.username(target) then return {ok = false, error = 'Invalid target'} end
        local id, problem = self:notice(query.station, target ~= 'ALL' and target or nil, 'CONTROL: ' .. query.text, 2, nil, now)
        return {ok = id ~= nil, id = id, error = problem}
    end

    function self:tick(now)
        for _, uuid in ipairs(util.sorted(self.sessions)) do self:session(uuid, now) end
        for id, item in pairs(self.pending) do
            if item.body.expires <= now then
                record('chat_unknown', {id = id, station = item.station, subject = item.subject,
                    note = 'No send result before expiry; delivery is unconfirmed'})
                self.pending[id] = nil
            end
        end
        for key, stamp in pairs(self.unroutable) do if now - stamp > 60000 then self.unroutable[key] = nil end end
        local present = {}
        for _, key in ipairs(util.sorted(tracker.contacts)) do
            local contact = tracker.contacts[key]
            if contact.kind == 'ship' and now - contact.time <= 20000 then
                present[key] = true
                local previous = self.states[key]
                local zones = {}
                for _, state in ipairs(contact.decision.zones or {}) do zones[state.id] = state.allowed end
                local continuous = previous and contact.time - previous.contact.time <= 10000
                    and contact.dimension == previous.contact.dimension and not contact.conflict
                    and not previous.contact.conflict and previous.revision == service.db.revision
                local vessel = label(contact, service.db)
                local changes, priority = {}, 1
                for _, id in ipairs(util.sorted(zones)) do
                    local zone = service.db.zones[id]
                    if zone and (not previous or previous.zones[id] == nil) then
                        local phrase = continuous and 'entering ' or 'detected within '
                        changes[#changes + 1] = phrase .. zoneText(zone)
                    elseif previous and previous.zones[id] ~= zones[id] and zone then
                        changes[#changes + 1] = zoneText(zone) .. (zones[id] and ': clearance now valid' or ': clearance no longer valid')
                        priority = math.max(priority, 2)
                    end
                end
                if previous then
                    for _, id in ipairs(util.sorted(previous.zones)) do
                        if zones[id] == nil then
                            local zone = service.db.zones[id]
                            local title = zone and zoneText(zone) or id
                            changes[#changes + 1] = continuous and ('observed leaving ' .. title)
                                or ('currently outside ' .. title .. '; crossing unconfirmed')
                        end
                    end
                end
                local lastWarning = previous and previous.lastWarning or 0
                if contact.decision.violation and (#changes > 0 or now - lastWarning >= WARNING_MS) then
                    priority = 3
                    if #changes == 0 then changes[1] = 'Violation remains observed' end
                    lastWarning = now
                end
                if #changes > 0 then
                    -- One summary per contact per cycle, including overlapping zones.
                    -- A newer summary replaces unsent older airspace notices.
                    local prefix = vessel .. ': '
                    if contact.conflict then prefix = prefix .. 'radar position inconsistent; ' end
                    local summary = table.concat(changes, '; ')
                    if contact.decision.violation then
                        -- Keep the actual restriction visible even with many overlapping zones.
                        summary = 'WARNING: ' .. clean(contact.decision.zone, 40) .. ': '
                            .. clean(contact.decision.reason, 100) .. '. Leave or contact control. ' .. summary
                    elseif next(zones) then
                        summary = summary .. '. Entry allowed under current rules.'
                    end
                    notify(contact, prefix .. summary, priority, now)
                end
                self.states[key] = {contact = util.copy(contact), zones = zones,
                    revision = service.db.revision, lastWarning = lastWarning}
            end
        end
        for key, previous in pairs(self.states) do
            if not present[key] then
                local reclassified = false
                for _, contact in pairs(tracker.contacts) do
                    if now - contact.time <= 20000 and contact.sensorKey == previous.contact.sensorKey then
                        reclassified = true
                        break
                    end
                end
                local notice = reclassified
                    and ': radar identity binding changed. Vessel association must be verified with control.'
                    or ': radar contact lost. Position unknown; this is not a confirmed airspace exit.'
                notify(previous.contact, label(previous.contact, service.db) .. notice, 2, now)
                self.states[key] = nil
            end
        end
        local sent = 0
        while #self.queue > 0 and sent < 4 and util.count(self.pending) < 64 do
            local selected = 1
            for index, item in ipairs(self.queue) do
                if item.body.priority > self.queue[selected].body.priority then selected = index end
            end
            local item = table.remove(self.queue, selected)
            if item.body.expires > now and available(item.station, now, item.body.recipient == nil) then
                self.pending[item.body.id] = item
                local ok, problem = pcall(send, item.station, item.body)
                if not ok then
                    self.pending[item.body.id] = nil
                    record('chat_failed', {id = item.body.id, station = item.station, note = clean(problem, 160)})
                end
                sent = sent + 1
            else
                record('chat_failed', {id = item.body.id, station = item.station, subject = item.subject,
                    note = 'Notice expired or sending station unavailable'})
            end
        end
    end

    return self
end

return M
]===],
    ["/aacs/lib/contact_ui.lua"] = [===[
-- Keep numbered contacts stable while the network continues receiving observations.
local util = require('aacs.lib.util')
local M = {}

function M.label(contact, registry)
    local registration = contact.subject and contact.subject:match('^vessel:(.+)$')
    local vessel = registration and registry and registry.vessels and registry.vessels[registration]
    if vessel and util.text(vessel.name, 60) then
        return vessel.name .. ' [' .. registration .. ']'
    end
    return contact.subject or contact.name or contact.id
end

function M.nameAndRegistration(contact, registry)
    local registration = contact.subject and contact.subject:match('^vessel:(.+)$')
    if not registration then return M.label(contact, registry), '-' end

    local vessel = registry and registry.vessels and registry.vessels[registration]
    if vessel and util.text(vessel.name, 60) then
        return vessel.name, registration
    end
    return contact.id or 'Unknown vessel', registration
end

function M.freshShip(tracker, sensorKey)
    for _, contact in pairs(tracker.contacts) do
        if contact.kind == 'ship' and contact.sensorKey == sensorKey
            and util.now() - contact.time < 20000 then
            return contact
        end
    end
end

local function snapshot(tracker, shipsOnly)
    local contacts = {}
    for _, key in ipairs(util.sorted(tracker.contacts)) do
        local contact = tracker.contacts[key]
        if not shipsOnly or (contact.kind == 'ship' and util.now() - contact.time < 20000) then
            contacts[#contacts + 1] = util.copy(contact)
        end
    end
    return contacts
end

function M.showDetails(contact, registry)
    term.clear()
    term.setCursorPos(1, 1)
    local lines = {
        M.label(contact, registry),
        'Kind: ' .. tostring(contact.kind),
        'World: ' .. tostring(contact.dimension),
        string.format('Position: %.1f, %.1f, %.1f', contact.x, contact.y, contact.z),
        'Track ID: ' .. tostring(contact.id),
        'Bind key: ' .. tostring(contact.sensorKey),
        'State: ' .. tostring(contact.decision and contact.decision.reason or ''),
    }
    textutils.pagedPrint(table.concat(lines, '\n'))
end

local function showStations(stations)
    term.clear()
    term.setCursorPos(1, 1)
    local lines = {'STATIONS'}
    for _, name in ipairs(util.sorted(stations or {})) do
        local station = stations[name]
        lines[#lines + 1] = string.format('%s | age %ds | %s', name,
            math.floor((util.now() - station.lastMessage) / 1000), station.note or '')
    end
    if #lines == 1 then lines[#lines + 1] = 'No station reports received.' end
    textutils.pagedPrint(table.concat(lines, '\n'))
    util.pause()
end

function M.browse(tracker, registry, stations, selectShip)
    local contacts = snapshot(tracker, selectShip)
    local page = 1

    while true do
        local width, height = term.getSize()
        local pageSize = math.max(1, math.min(8, math.floor((height - 7) / 2)))
        local pages = math.max(1, math.ceil(#contacts / pageSize))
        page = math.max(1, math.min(page, pages))
        local first = (page - 1) * pageSize + 1
        local last = math.min(#contacts, first + pageSize - 1)

        term.clear()
        term.setCursorPos(1, 1)
        local function line(value)
            print(tostring(value):sub(1, width))
        end

        line(selectShip and 'SELECT VESSEL TO BIND' or 'LIVE CONTACTS')
        line(string.format('Page %d/%d | %d contacts', page, pages, #contacts))
        line('')
        for index = first, last do
            local contact = contacts[index]
            line(string.format('%d. %s', index, M.label(contact, registry)))
            line(string.format('   X %.0f  Y %.0f  Z %.0f', contact.x, contact.y, contact.z))
        end
        if #contacts == 0 then line('No contacts available. R refreshes.') end
        line('N next | P previous | R refresh | S stations')
        line(selectShip and 'Number selects a vessel. Q cancels.' or 'Number shows details. Q returns.')
        local action = M.prompt()
        local command = action:lower()

        if command == '' or command == 'q' then
            return nil
        elseif command == 'n' then
            page = math.min(pages, page + 1)
        elseif command == 'p' then
            page = math.max(1, page - 1)
        elseif command == 'r' then
            contacts = snapshot(tracker, selectShip)
            page = 1
        elseif command == 's' then
            showStations(stations)
        else
            local chosen
            local index = tonumber(action)
            if index and index == math.floor(index) and index >= first and index <= last then
                chosen = contacts[index]
            elseif selectShip and action:sub(1, 5) == 'ship:' then
                chosen = M.freshShip(tracker, action)
            end

            local current
            if chosen then
                for _, contact in pairs(tracker.contacts) do
                    if contact.sensorKey == chosen.sensorKey then current = contact; break end
                end
            end
            if selectShip and current then current = M.freshShip(tracker, current.sensorKey) end

            if current then
                M.showDetails(current, registry)
                if selectShip then return current.sensorKey end
                util.pause()
            else
                print('Choose a current contact from this page.')
                util.pause()
            end
        end
    end
end

function M.prompt()
    write('Choice: ')
    return read()
end

return M
]===],
    ["/aacs/lib/crypto.lua"] = [===[
-- AACS cryptographic primitives. No dependencies beyond CC:Tweaked's bit32.
-- ChaCha20 (RFC 8439) + full-length HMAC-SHA256, encrypt-then-MAC.
-- This is NOT the RFC 8439 ChaCha20-Poly1305 construction or an audited library.
local M = {}
local b = assert(bit32, "AACS requires bit32")
local band, bxor, bnot = b.band, b.bxor, b.bnot
local shr, ror, rol = b.rshift, b.rrotate, b.lrotate
local MOD = 4294967296

local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
}

local function be(n)
    return string.char(shr(n,24), band(shr(n,16),255), band(shr(n,8),255), band(n,255))
end

function M.le(n)
    return string.char(band(n,255), band(shr(n,8),255), band(shr(n,16),255), shr(n,24))
end

local function word(s, i, little)
    local a,c,d,e = s:byte(i, i+3)
    if little then return a + c*256 + d*65536 + e*16777216 end
    return a*16777216 + c*65536 + d*256 + e
end

function M.hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

function M.unhex(s)
    assert(type(s)=="string" and #s%2==0 and not s:find('[^0-9a-fA-F]'), "Invalid hex")
    return (s:gsub('..', function(c) return string.char(tonumber(c,16)) end))
end

function M.sha256(message, raw)
    local size = #message
    local data = message .. '\128' .. string.rep('\0', (55-size)%64)
        .. be(math.floor(size/536870912)) .. be((size*8)%MOD)
    local h = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}

    for offset=1,#data,64 do
        local w = {}
        for i=1,16 do w[i] = word(data, offset+(i-1)*4, false) end
        for i=17,64 do
            local x,y = w[i-15],w[i-2]
            w[i] = (w[i-16]+bxor(ror(x,7),ror(x,18),shr(x,3))+w[i-7]
                +bxor(ror(y,17),ror(y,19),shr(y,10)))%MOD
        end
        local a,c,d,e,f,g,j,k = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
        for i=1,64 do
            local t1 = (k+bxor(ror(f,6),ror(f,11),ror(f,25))
                +bxor(band(f,g),band(bnot(f),j))+K[i]+w[i])%MOD
            local t2 = (bxor(ror(a,2),ror(a,13),ror(a,22))
                +bxor(band(a,c),band(a,d),band(c,d)))%MOD
            k,j,g,f,e,d,c,a = j,g,f,(e+t1)%MOD,d,c,a,(t1+t2)%MOD
        end
        local v = {a,c,d,e,f,g,j,k}
        for i=1,8 do h[i]=(h[i]+v[i])%MOD end
    end
    local out = {}
    for i=1,8 do out[i]=be(h[i]) end
    local digest = table.concat(out)
    return raw and digest or M.hex(digest)
end

function M.hmac(key, message, raw)
    if #key>64 then key=M.sha256(key,true) end
    key=key..string.rep('\0',64-#key)
    local inner,outer = {},{}
    for i=1,64 do
        inner[i]=string.char(bxor(key:byte(i),0x36))
        outer[i]=string.char(bxor(key:byte(i),0x5c))
    end
    local digest=M.sha256(table.concat(outer)..M.sha256(table.concat(inner)..message,true),true)
    return raw and digest or M.hex(digest)
end

function M.equal(a,c)
    if type(a)~='string' or type(c)~='string' or #a~=#c then return false end
    local difference=0
    for i=1,#a do difference=b.bor(difference,bxor(a:byte(i),c:byte(i))) end
    return difference==0
end

local function quarter(s,a,c,d,e)
    s[a]=(s[a]+s[c])%MOD; s[e]=rol(bxor(s[e],s[a]),16)
    s[d]=(s[d]+s[e])%MOD; s[c]=rol(bxor(s[c],s[d]),12)
    s[a]=(s[a]+s[c])%MOD; s[e]=rol(bxor(s[e],s[a]),8)
    s[d]=(s[d]+s[e])%MOD; s[c]=rol(bxor(s[c],s[d]),7)
end

function M.chachaBlock(key,nonce,counter)
    assert(#key==32 and #nonce==12, "Invalid ChaCha20 input")
    local initial={0x61707865,0x3320646e,0x79622d32,0x6b206574}
    for i=1,8 do initial[4+i]=word(key,(i-1)*4+1,true) end
    initial[13]=counter
    for i=1,3 do initial[13+i]=word(nonce,(i-1)*4+1,true) end
    local s={}
    for i=1,16 do s[i]=initial[i] end
    for _=1,10 do
        quarter(s,1,5,9,13); quarter(s,2,6,10,14)
        quarter(s,3,7,11,15); quarter(s,4,8,12,16)
        quarter(s,1,6,11,16); quarter(s,2,7,12,13)
        quarter(s,3,8,9,14); quarter(s,4,5,10,15)
    end
    local out={}
    for i=1,16 do out[i]=M.le((s[i]+initial[i])%MOD) end
    return table.concat(out)
end

function M.chacha(key,nonce,data)
    local out={}
    for offset=1,#data,64 do
        local stream=M.chachaBlock(key,nonce,math.floor((offset-1)/64)+1)
        local chunk={}
        for i=1,math.min(64,#data-offset+1) do
            chunk[i]=string.char(bxor(data:byte(offset+i-1),stream:byte(i)))
        end
        out[#out+1]=table.concat(chunk)
    end
    return table.concat(out)
end

-- 64-bit sequence encoded without Lua integer-only operators (CC uses doubles).
function M.nonce(seq)
    return string.rep('\0',4)..M.le(math.floor(seq/MOD))..M.le(seq%MOD)
end

return M
]===],
    ["/aacs/lib/display.lua"] = [===[
-- Resolve the configured monitor again on every frame so reconnects can recover.
local util = require('aacs.lib.util')
local UI = require('aacs.lib.ui')
local M = {}

function M.inspect(config)
    local name = config.monitor
    if type(name) ~= 'string' or name == '' then return nil, 'No monitor configured' end
    if not peripheral.isPresent(name) then return nil, 'Configured monitor is unavailable' end
    if not peripheral.hasType(name, 'monitor') then return nil, 'Configured peripheral is not a monitor' end
    local screen = peripheral.wrap(name)
    if not screen then return nil, 'Monitor could not be opened' end
    return screen
end

function M.new(config, root)
    local self = {frames = 0, lastSuccess = nil, lastSaved = nil, lastState = nil}
    root = root or '/aacs/data'

    local function saveStatus(state, problem, now, tracker)
        local summary = state .. ':' .. tostring(problem or '')
        if summary == self.lastState and self.lastSaved and now - self.lastSaved < 5000 then return end
        local ok = pcall(util.write, root .. '/monitor-status.json', util.json({
            computer = config.computer, node = config.node, monitor = config.monitor or '',
            state = state, error = problem, attemptedAt = now, renderedAt = self.lastSuccess,
            frames = self.frames, contacts = util.count(tracker.contacts),
        }))
        if ok then self.lastSaved = now; self.lastState = summary end
    end

    function self:draw(title, tracker, status, registry)
        local now = util.now()
        if not config.monitor or config.monitor == '' then
            self.problem = nil
            saveStatus('disabled', nil, now, tracker)
            return true
        end

        local ok, problem = pcall(function()
            local screen, reason = M.inspect(config)
            assert(screen, reason)
            if not self.connected and screen.getTextScale and screen.setTextScale then
                -- Force a fresh terminal surface while restoring the chosen text size.
                local scale = screen.getTextScale()
                local temporary = scale < 5 and scale + 0.5 or scale - 0.5
                local resized, resizeError = pcall(screen.setTextScale, temporary)
                local restored, restoreError = pcall(screen.setTextScale, scale)
                assert(resized and restored, tostring(resizeError or restoreError))
            end
            local stamp = os.date('!%H:%M:%S', math.floor(now / 1000))
            local footer = string.format('PC %s | %s | Updated %s UTC | #%d',
                tostring(config.computer or '?'), config.monitor, stamp, self.frames + 1)
            UI.draw(screen, title, tracker, status, registry, footer)
        end)

        if ok then
            self.connected = true
            self.frames = self.frames + 1
            self.lastSuccess = now
            self.problem = nil
            saveStatus('ok', nil, now, tracker)
            return true
        end

        self.connected = false
        self.problem = tostring(problem):sub(1, 400)
        saveStatus('error', self.problem, now, tracker)
        return false, self.problem
    end

    function self:footer()
        if not config.monitor or config.monitor == '' then return 'No external monitor configured' end
        if self.problem then return config.monitor .. ': OFFLINE - run diagnose' end
        return config.monitor .. ': updated | frame ' .. self.frames
    end

    return self
end

return M
]===],
    ["/aacs/lib/policy.lua"] = [===[
-- All restrictions are cumulative. Exemption from one zone never exempts another.
local u=require('aacs.lib.util')
local M={levels={unrestricted=1,controlled=2,restricted=3,prohibited=4}}

function M.validateZone(z)
    if type(z)~='table' or not u.id(z.id,40) or not u.text(z.name,60)
        or not M.levels[z.class] or not u.dimension(z.dimension)
        or not u.number(z.minY,-1000000,1000000) or not u.number(z.maxY,z.minY,1000000)
        or (z.applies~='ships' and z.applies~='players' and z.applies~='both') then return false,'Invalid zone fields' end
    if z.shape=='box' then
        if not u.number(z.minX,-30000000,30000000) or not u.number(z.maxX,z.minX,30000000)
            or not u.number(z.minZ,-30000000,30000000) or not u.number(z.maxZ,z.minZ,30000000) then return false,'Invalid box' end
    elseif z.shape=='cylinder' then
        if not u.number(z.x,-30000000,30000000) or not u.number(z.z,-30000000,30000000)
            or not u.number(z.radius,1,1000000) then return false,'Invalid cylinder' end
    else return false,'Shape must be box or cylinder' end
    return true
end

function M.applies(z,c)
    return z.enabled~=false and z.dimension==c.dimension
        and (z.applies=='both' or (z.applies=='ships' and c.kind=='ship') or (z.applies=='players' and c.kind=='player'))
end

function M.contains(z,c)
    if not M.applies(z,c) or c.y<z.minY or c.y>z.maxY then return false end
    if z.shape=='box' then return c.x>=z.minX and c.x<=z.maxX and c.z>=z.minZ and c.z<=z.maxZ end
    return (c.x-z.x)^2+(c.z-z.z)^2<=z.radius^2
end

function M.identity(db,c,now)
    if c.kind=='player' and u.uuid(c.id) then
        local id=c.id:lower()
        return 'player:'..id,db.players[id]
    end
    if c.kind=='ship' then
        local binding=db.bindings[c.sensorKey]
        if binding and binding.expires>now then
            return 'vessel:'..binding.registration,db.vessels[binding.registration]
        end
    end
    return nil,nil
end

function M.allowed(db,z,c,now)
    if z.class=='unrestricted' then return true,'Open airspace' end
    local subject,record=M.identity(db,c,now)
    if not subject or not record then return false,'Unidentified or unbound contact' end
    if record.status~='active' then return false,'Registration '..tostring(record.status) end
    if z.class=='controlled' then return true,'Active registration' end
    for _,permit in pairs(db.permits or {}) do
        if permit.subject==subject and permit.zone==z.id and permit.starts<=now
            and permit.expires>now and permit.revoked~=true then return true,'Permit '..permit.id end
    end
    return false,'Explicit zone clearance required'
end

function M.evaluate(db,c,now)
    local result={violation=false,level=0,zone='',reason='Outside configured zones',zones={}}
    for _,id in ipairs(u.sorted(db.zones)) do
        local z=db.zones[id]
        if M.contains(z,c) then
            local allowed,reason=M.allowed(db,z,c,now)
            local level=M.levels[z.class]
            result.zones[#result.zones+1]={id=id,class=z.class,allowed=allowed}
            if not allowed and (not result.violation or level>result.level) then
                result.violation=true; result.level=level; result.zone=id; result.reason=reason
            elseif not result.violation and level>result.level then
                result.level=level; result.zone=id; result.reason=reason
            end
        end
    end
    return result
end

local function interval(lo,hi,p,delta,t0,t1)
    if math.abs(delta)<1e-12 then if p<lo or p>hi then return nil end; return t0,t1 end
    local a,b=(lo-p)/delta,(hi-p)/delta
    if a>b then a,b=b,a end
    t0,t1=math.max(t0,a),math.min(t1,b)
    if t0>t1 then return nil end
    return t0,t1
end

-- Estimated straight-line crossing between samples, never called a confirmed path.
function M.intersects(z,a,c)
    if a.dimension~=c.dimension or not M.applies(z,c) then return false end
    local lo,hi=interval(z.minY,z.maxY,a.y,c.y-a.y,0,1)
    if not lo then return false end
    if z.shape=='box' then
        lo,hi=interval(z.minX,z.maxX,a.x,c.x-a.x,lo,hi)
        if not lo then return false end
        lo,hi=interval(z.minZ,z.maxZ,a.z,c.z-a.z,lo,hi)
        return lo~=nil
    end
    local dx,dz=c.x-a.x,c.z-a.z
    local px,pz=a.x-z.x,a.z-z.z
    local A=dx*dx+dz*dz
    local C=px*px+pz*pz-z.radius*z.radius
    if A<1e-12 then return C<=0 end
    local B=2*(px*dx+pz*dz)
    local disc=B*B-4*A*C
    if disc<0 then return false end
    local r=math.sqrt(disc)
    return math.max(lo,(-B-r)/(2*A))<=math.min(hi,(-B+r)/(2*A))
end

function M.snapshot(db,now)
    local out={revision=db.revision,issued=now,validUntil=now+60000,zones=u.copy(db.zones),
        vessels={},players={},bindings=u.copy(db.bindings),permits=u.copy(db.permits)}
    for id,r in pairs(db.vessels) do out.vessels[id]={name=r.name,nation=r.nation,status=r.status} end
    for id,r in pairs(db.players) do out.players[id]={name=r.name,nation=r.nation,status=r.status} end
    return out
end
return M
]===],
    ["/aacs/lib/reports.lua"] = [===[
local u=require('aacs.lib.util')
local store=require('aacs.lib.store')
local M={}

local function csv(value)
    local s=tostring(value or '')
    -- Prevent formula injection if an exported CSV is opened in spreadsheet software.
    if s:match('^[=+@%-]') then s="'"..s end
    return '"'..s:gsub('"','""')..'"'
end

function M.export(root,query)
    query=query or {}
    local from=query.from or 0
    local untilTime=query.untilTime or u.now()
    local name='report-'..os.date('!%Y%m%d-%H%M%S',math.floor(u.now()/1000))
    local base=root..'/reports/'..name
    local n=1
    while fs.exists(base..'.csv') do base=root..'/reports/'..name..'-'..n; n=n+1 end
    fs.makeDir(root..'/reports')
    local file=assert(fs.open(base..'.csv','w'))
    file.writeLine('time_utc,event,contact,subject,zone,source,dimension,x,y,z,reason,message_id,pilot_uuid,username,station,message')
    local counts={}; local total=0; local first,last
    local visitEvents={}
    local timeline={}
    local malformed=store.rows(root..'/events.jsonl',function(row)
        if (row.time or 0)<from or (row.time or 0)>untilTime then return end
        if query.subject and query.subject~='' and row.key~=query.subject and row.subject~=query.subject
            and (not row.contact or row.contact.sensorKey~=query.subject) then return end
        if query.zone and query.zone~='' and row.zone~=query.zone then return end
        if query.incidents and not ({violation=true,estimated_crossing=true,policy_change=true,position_discontinuity=true})[row.event] then return end
        local c=row.contact or {}
        local values={u.date(row.time),row.event,row.key,row.subject,row.zone,c.source,c.dimension,c.x,c.y,c.z,row.reason or row.note,
            row.id,row.pilot,row.username,row.station,row.text}
        local fields={}; for i=1,17 do fields[i]=csv(values[i]) end
        file.writeLine(table.concat(fields,','))
        total=total+1; counts[row.event]=(counts[row.event] or 0)+1
        first=first and math.min(first,row.time) or row.time
        last=last and math.max(last,row.time) or row.time
        if row.event=='zone_enter' or row.event=='zone_exit' or row.event=='lost' then visitEvents[#visitEvents+1]=row end
        if row.event~='position' then
            timeline[#timeline+1]=u.date(row.time)..' | '..tostring(row.event)..' | '..tostring(row.subject or row.key or '')
                ..' | '..tostring(row.zone or '')..' | '..tostring(row.reason or row.note or row.text or row.id or '')
            if #timeline>120 then table.remove(timeline,1) end
        end
    end)
    file.close()
    table.sort(visitEvents,function(a,b) return a.time<b.time end)
    local visits=assert(fs.open(base..'-visits.csv','w'))
    visits.writeLine('contact,subject,zone,observed_entry_utc,observed_exit_utc,observed_span_seconds,outcome')
    local active={}
    local visitCount=0
    local function finish(v,exitTime,outcome)
        local columns={csv(v.key),csv(v.subject),csv(v.zone),csv(u.date(v.entry)),
            csv(exitTime and u.date(exitTime) or ''),csv(exitTime and math.max(0,(exitTime-v.entry)/1000) or ''),csv(outcome)}
        visits.writeLine(table.concat(columns,','));visitCount=visitCount+1
    end
    for _,e in ipairs(visitEvents) do
        local visitKey=tostring(e.key)..'|'..tostring(e.zone)
        if e.event=='zone_enter' then
            if active[visitKey] then finish(active[visitKey],nil,'entry repeated; intervening coverage unknown') end
            active[visitKey]={key=e.key,subject=e.subject,zone=e.zone,entry=e.time}
        elseif e.event=='zone_exit' and active[visitKey] then
            finish(active[visitKey],e.time,'observed exit; duration is sampled estimate');active[visitKey]=nil
        elseif e.event=='lost' then
            for key,v in pairs(active) do
                if v.key==e.key then finish(v,nil,'contact lost; exit time and duration unknown');active[key]=nil end
            end
        end
    end
    for _,v in pairs(active) do finish(v,nil,'no exit in retained matching observations') end
    visits.close()
    local lines={'ARDENNIAN DEPARTMENT OF TRANSPORTATION','AACS MOVEMENT / INCIDENT REPORT',
        'Generated: '..u.date(u.now()),'Subject: '..tostring(query.subject or 'all'),
        'Zone filter: '..tostring(query.zone or 'all'),'Matched rows: '..total,'Visit records: '..visitCount,
        'First retained match: '..(first and u.date(first) or 'none'),
        'Last retained match: '..(last and u.date(last) or 'none'),'','EVENT COUNTS'}
    for _,event in ipairs(u.sorted(counts)) do lines[#lines+1]=event..': '..counts[event] end
    lines[#lines+1]=''; lines[#lines+1]='RECENT NON-POSITION EVENTS (last 120 matches)'
    for _,line in ipairs(timeline) do lines[#lines+1]=line end
    lines[#lines+1]=''; lines[#lines+1]='NOTES'
    lines[#lines+1]='Only retained observations are included. Rotating logs, outages, unloaded chunks, sensor range and sample intervals cause gaps.'
    lines[#lines+1]='Lost contact is not a confirmed exit or landing. Estimated crossings assume a straight line between samples.'
    lines[#lines+1]='Beacon claims do not prove a physical vessel identity. HQ reports omit samples never delivered by a station.'
    lines[#lines+1]='Malformed log rows skipped: '..malformed
    u.write(base..'.txt',table.concat(lines,'\n')..'\n')
    return {text=base..'.txt',csv=base..'.csv',visits=base..'-visits.csv',rows=total,malformed=malformed}
end

function M.wrap(text,width)
    local lines={}
    for line in (text..'\n'):gmatch('(.-)\n') do
        if line=='' then lines[#lines+1]='' end
        while #line>width do
            local cut=width
            for i=width,math.max(1,width-12),-1 do if line:sub(i,i)==' ' then cut=i; break end end
            lines[#lines+1]=line:sub(1,cut):gsub('%s+$','')
            line=line:sub(cut+1):gsub('^%s+','')
        end
        if line~='' then lines[#lines+1]=line end
    end
    return lines
end

function M.printFile(path,printerName,startPage)
    local p=printerName and peripheral.wrap(printerName) or peripheral.find('printer')
    assert(p and p.newPage,'Attach a CC:Tweaked printer')
    local first=startPage or 1
    assert(u.integer(first,1,100000),'Invalid starting page')
    if not p.newPage() then return false,'No paper/ink. Resume at page '..first end
    local width,height=p.getPageSize()
    local lines=M.wrap(u.read(path),width)
    local perPage=height-2
    local pages=math.max(1,math.ceil(#lines/perPage))
    assert(first<=pages,'Starting page exceeds report length')
    for page=first,pages do
        if page~=first and not p.newPage() then return false,'No paper/ink. Resume at page '..page end
        p.setPageTitle(('AACS '..page..'/'..pages):sub(1,32))
        p.setCursorPos(1,1); p.write('AACS '..page..'/'..pages)
        for i=1,perPage do
            local line=lines[(page-1)*perPage+i]
            if not line then break end
            p.setCursorPos(1,i+2); p.write(line)
        end
        if not p.endPage() then
            return false,'Output tray full; current page remains in printer. Empty tray, endPage() manually, then resume at page '..(page+1)
        end
    end
    return true,'Printed '..(pages-first+1)..' page(s)'
end
return M
]===],
    ["/aacs/lib/sensors.lua"] = [===[
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
]===],
    ["/aacs/lib/service.lua"] = [===[
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
]===],
    ["/aacs/lib/store.lua"] = [===[
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
]===],
    ["/aacs/lib/tracker.lua"] = [===[
local u=require('aacs.lib.util')
local policy=require('aacs.lib.policy')
local M={}

function M.key(c)
    if c.kind=='player' then return 'player:'..c.id:lower() end
    return 'ship:'..c.namespace..':'..c.id
end

function M.new(emit)
    local self={contacts={},sampleMs=10000,staleMs=20000,maxContacts=512}
    self.emit=emit or function() end

    function self:ingest(c,db,now)
        c.sensorKey=M.key(c)
        local subject=policy.identity(db,c,now)
        local key=subject or c.sensorKey
        local old=self.contacts[key]
        local identityChanged=false
        local aliases={}
        -- Remove the old unknown/registered alias when an operator changes a binding.
        for otherKey,contact in pairs(self.contacts) do
            if otherKey~=key and contact.sensorKey==c.sensorKey then
                old=old or contact
                identityChanged=true
                aliases[#aliases+1]=otherKey
            end
        end
        if not old and u.count(self.contacts)>=self.maxContacts then return false,'Contact limit' end
        if old and not identityChanged and c.time<=(old.sourceTimes[c.source] or 0) then return false,'Duplicate/old observation' end
        if old and c.time<old.time then
            old.sourceTimes[c.source]=math.max(old.sourceTimes[c.source] or 0,c.time)
            return false,'Older than merged track'
        end
        -- Do not delete an existing alias until this observation is accepted.
        for _,otherKey in ipairs(aliases) do
            self.contacts[otherKey]=nil
            self.emit({event='identity_reclassified',time=now,key=key,subject=subject,
                previousKey=otherKey,contact=c})
        end
        local decision=policy.evaluate(db,c,now)
        local current=u.copy(c)
        current.key=key; current.subject=subject; current.decision=decision
        current.firstSeen=old and old.firstSeen or c.time
        current.sourceTimes=old and u.copy(old.sourceTimes) or {}
        current.sourceTimes[c.source]=c.time
        current.lastLogged=old and old.lastLogged or 0
        current.conflict=false

        if old then
            local dt=(c.time-old.time)/1000
            local distance=u.distance(old,c)
            if c.dimension~=old.dimension or distance>120+math.max(0,dt)*600 then
                current.conflict=true
                self.emit({event='position_discontinuity',time=now,key=key,contact=c,
                    note='Teleport, inconsistent sensor data, or movement beyond configured plausibility threshold'})
            end
            if not current.conflict and dt>0 and dt<=10 then
                current.speed=distance/dt -- blocks per real second, not radar velocity units
                for _,z in pairs(db.zones) do
                    if not policy.contains(z,old) and not policy.contains(z,c) and policy.intersects(z,old,c) then
                        local allowed,reason=policy.allowed(db,z,c,now)
                        self.emit({event='estimated_crossing',time=now,key=key,subject=subject,
                            zone=z.id,violation=not allowed,reason=reason,contact=c,
                            note='Straight-line estimate between samples; not an observed continuous route'})
                    end
                end
            end
            local previousZones={}
            for _,z in ipairs(old.decision.zones) do previousZones[z.id]=true end
            for _,z in ipairs(decision.zones) do
                if not previousZones[z.id] then self.emit({event='zone_enter',time=c.time,key=key,subject=subject,zone=z.id,contact=c}) end
                previousZones[z.id]=nil
            end
            for z in pairs(previousZones) do self.emit({event='zone_exit',time=c.time,key=key,subject=subject,zone=z,contact=c}) end
        else
            self.emit({event='acquired',time=c.time,key=key,subject=subject,contact=c})
            for _,z in ipairs(decision.zones) do self.emit({event='zone_enter',time=c.time,key=key,subject=subject,zone=z.id,contact=c}) end
        end
        if decision.violation and (not old or not old.decision.violation or old.decision.zone~=decision.zone) then
            self.emit({event='violation',time=c.time,key=key,subject=subject,zone=decision.zone,reason=decision.reason,contact=c})
        elseif old and old.decision.violation and not decision.violation then
            self.emit({event='violation_cleared',time=c.time,key=key,subject=subject,contact=c})
        end
        if c.time-current.lastLogged>=self.sampleMs then
            self.emit({event='position',time=c.time,key=key,subject=subject,contact=c,speed=current.speed})
            current.lastLogged=c.time
        end
        self.contacts[key]=current
        return true,current
    end

    function self:refresh(db,now)
        for _,key in ipairs(u.sorted(self.contacts)) do
            local c=self.contacts[key]
            if c then
            if now-c.time>self.staleMs then
                self.emit({event='lost',time=now,key=key,subject=c.subject,contact=c,
                    note='Coverage ended; NOT evidence of a zone exit or landing'})
                self.contacts[key]=nil
            else
                local subject=policy.identity(db,c,now)
                local currentKey=subject or c.sensorKey
                if currentKey~=key then
                    local merged=self.contacts[currentKey]
                    if merged and merged.time>c.time then
                        merged.sourceTimes[c.source]=math.max(merged.sourceTimes[c.source] or 0,c.time)
                        c=merged
                    else
                        if merged then
                            for source,stamp in pairs(merged.sourceTimes) do
                                c.sourceTimes[source]=math.max(c.sourceTimes[source] or 0,stamp)
                            end
                        end
                        c.key=currentKey;c.subject=subject
                        self.contacts[currentKey]=c
                    end
                    self.contacts[key]=nil
                    self.emit({event='identity_reclassified',time=now,key=currentKey,subject=subject,
                        previousKey=key,contact=c})
                end
                local d=policy.evaluate(db,c,now)
                if d.violation~=c.decision.violation or d.zone~=c.decision.zone then
                    self.emit({event='policy_change',time=now,key=c.key,subject=c.subject,
                        zone=d.zone,violation=d.violation,reason=d.reason,contact=c})
                end
                c.decision=d
            end
            end
        end
    end
    return self
end
return M
]===],
    ["/aacs/lib/ui.lua"] = [===[
local u=require('aacs.lib.util')
local reports=require('aacs.lib.reports')
local contacts=require('aacs.lib.contact_ui')
local Service=require('aacs.lib.service')
local M={}

function M.prompt(label,default)
    write(label..(default~=nil and (' ['..tostring(default)..']') or '')..': ')
    local answer=read()
    if answer=='' and default~=nil then return default end
    return answer
end

function M.show(value)
    if type(value)=='table' then textutils.pagedPrint(textutils.serialize(value)) else print(tostring(value)) end
end

function M.vesselForm()
    return {
        name=M.prompt('Vessel name'),craftType=M.prompt('Type (airship/plane/etc.)'),
        owner=M.prompt('Owner Minecraft username'),nation=M.prompt('Nation'),
        purpose=M.prompt('Purpose','civilian'),description=M.prompt('Description',''),
        claimedUuid=M.prompt('Ship UUID, if known (not proof of ownership)',''),
    }
end

local function zoneForm()
    local z={}
    z.id=M.prompt('Zone ID (letters/numbers/dashes)')
    z.name=M.prompt('Display name')
    z.class=M.prompt('unrestricted / controlled / restricted / prohibited','controlled')
    z.dimension=M.prompt('Dimension','minecraft:overworld')
    z.applies=M.prompt('Applies to ships / players / both','ships')
    z.shape=M.prompt('Shape: box / cylinder','box')
    z.minY=tonumber(M.prompt('Minimum Y','64')); z.maxY=tonumber(M.prompt('Maximum Y','1000'))
    if z.shape=='box' then
        z.minX=tonumber(M.prompt('Minimum X')); z.maxX=tonumber(M.prompt('Maximum X'))
        z.minZ=tonumber(M.prompt('Minimum Z')); z.maxZ=tonumber(M.prompt('Maximum Z'))
    else
        z.x=tonumber(M.prompt('Center X')); z.z=tonumber(M.prompt('Center Z'))
        z.radius=tonumber(M.prompt('Horizontal radius'))
    end
    z.enabled=true
    return z
end

local function contactColumns(width, rows)
    local name = {key = 'name', title = 'NAME', width = 1}
    local registration = {key = 'registration', title = 'ARD ID', width = 8}
    local x = {key = 'x', title = 'X', width = 5, right = true}
    local y = {key = 'y', title = 'Y', width = 5, right = true}
    local z = {key = 'z', title = 'Z', width = 5, right = true}
    local state = {key = 'state', title = 'STATE', width = 5}
    local columns = {name, registration, x, y, z, state}

    -- Reserve complete registrations and coordinates before giving the name
    -- all remaining space. Recalculate each frame to handle monitor resizing.
    for _, row in ipairs(rows) do
        for index = 2, #columns do
            local column = columns[index]
            column.width = math.max(column.width, #row[column.key])
        end
    end

    local function reservedWidth()
        local reserved = #columns - 1 -- One space between each column.
        for index = 2, #columns do
            reserved = reserved + columns[index].width
        end
        return reserved
    end

    -- On very small screens, keep identity and status readable rather than
    -- cutting a registration or a coordinate in half at the right edge.
    if width - reservedWidth() < 4 then columns = {name, registration, state} end
    if width - reservedWidth() < 4 then columns = {name, registration} end
    if width - reservedWidth() < 1 then
        registration.width = width
        return {registration}
    end
    name.width = width - reservedWidth()
    return columns
end

local function contactRow(columns, values)
    local cells = {}
    for _, column in ipairs(columns) do
        local value = tostring(values and values[column.key] or column.title)
        if #value > column.width then
            if column.width > 3 then
                value = value:sub(1, column.width - 3)..'...'
            else
                value = value:sub(1, column.width)
            end
        end
        local padding = string.rep(' ', column.width - #value)
        cells[#cells + 1] = column.right and padding..value or value..padding
    end
    return table.concat(cells, ' ')
end

function M.draw(target, title, tracker, status, registry, footer)
    local width, height = target.getSize()
    if target.setBackgroundColor then target.setBackgroundColor(32768) end -- black
    if target.setTextColor then target.setTextColor(1) end -- white
    target.setCursorPos(1, 1)
    target.clear()

    local rows = {}
    local capacity = math.max(0, height - 4)
    for _, key in ipairs(u.sorted(tracker.contacts)) do
        if #rows >= capacity then break end
        local contact = tracker.contacts[key]
        local name, registration = contacts.nameAndRegistration(contact, registry)
        rows[#rows + 1] = {
            name = tostring(name or 'Unknown contact'),
            registration = registration,
            x = string.format('%.0f', contact.x),
            y = string.format('%.0f', contact.y),
            z = string.format('%.0f', contact.z),
            state = contact.conflict and 'CHECK' or (contact.decision.violation and 'ALERT' or 'TRACK'),
        }
    end
    local columns = contactColumns(width, rows)

    local function line(row, text)
        if row >= 1 and row <= height then
            target.setCursorPos(1, row)
            target.write(tostring(text):sub(1, width))
        end
    end
    line(1, title)
    line(2, status)
    line(3, contactRow(columns))
    for index, row in ipairs(rows) do line(index + 3, contactRow(columns, row)) end
    line(height, footer or 'Observation/alerts only. No automatic weapon firing.')
end

local function listRecords(request,collection)
    local page=1
    while true do
        local result=request({op='list',collection=collection,page=page})
        if not result.ok then M.show(result); break end
        for _,item in ipairs(result.items) do
            local r=item.record
            print(item.id..' | '..tostring(r.name or r.subject or r.registration or '')..' | '..tostring(r.status or r.class or r.zone or ''))
        end
        print('Page '..page..' / '..result.count..' entries')
        -- Full application details stay available for actual ADOT review.
        local nextPage=false
        while true do
            local action=M.prompt('Record ID for details / N next / Enter done','')
            if action=='' then return end
            if action:lower()=='n' then
                if result.more then nextPage=true; break else print('No further pages.') end
            else
                local found=false
                for _,item in ipairs(result.items) do
                    if item.id==action then M.show(item.record); found=true; break end
                end
                if not found then print('Choose an ID shown on this page.') end
            end
        end
        if nextPage then page=page+1 end
    end
end

local function pilotMenu(request)
    print('1. Approve a recent pilot check-in request')
    print('2. Approve a pilot by UUID manually')
    print('3. List pilot approvals')
    print('4. Revoke pilot approval')
    local choice=M.prompt('Choice (Enter cancels)','')
    if choice=='3' then listRecords(request,'pilots');return end
    if choice=='4' then return request({op='revoke_pilot',uuid=M.prompt('Player UUID')}) end
    if choice~='1' and choice~='2' then return end
    local uuid,username,registration
    if choice=='1' then
        local result=request({op='pilot_candidates'})
        assert(result.ok,result.error)
        if #result.items==0 then
            print('No recent requests. Pilot: type $atc checkin ARD-0001 in Minecraft chat first.')
            return
        end
        for index,item in ipairs(result.items) do
            print(index..'. '..item.username..' | '..item.registration..' | '..item.station)
        end
        local index=tonumber(M.prompt('Request number'))
        assert(index and result.items[index],'Choose a listed request')
        local item=result.items[index]
        uuid,username,registration=item.uuid,item.username,item.registration
        print('Account UUID: '..uuid)
        print('Independently verify this player is permitted to pilot this vessel.')
        if M.prompt('Approve this association? y/N','n'):lower()~='y' then return end
    else
        uuid=M.prompt('Player UUID from a trusted source')
        username=M.prompt('Minecraft username')
        registration=M.prompt('ARD registration'):upper()
    end
    return request({op='authorize_pilot',uuid=uuid,username=username,registration=registration,
        minutes=tonumber(M.prompt('Approval lifetime, minutes','1440'))})
end

function M.registration(request,public,remote)
    while true do
        term.clear(); term.setCursorPos(1,1)
        print('ARDENNIAN DEPARTMENT OF TRANSPORTATION')
        print(public and 'PUBLIC APPLICATION TERMINAL' or 'AUTHORIZED ADOT REGISTRAR')
        print('1. Submit vessel registration application')
        print('2. Check application receipt')
        if not public then
            print('3. Review applications')
            print('4. Approve application')
            print('5. Reject application')
            print('6. Register a vessel directly')
            print('7. List registered vessels')
        end
        if remote then print('R. Retry unacknowledged network request') end
        print('Q. Exit')
        local choice=read():lower()
        if choice=='q' then return end
        local ok,result=pcall(function()
            if choice=='r' and remote then return request({op='resume_pending'})
            elseif choice=='1' then local q=M.vesselForm(); q.op='apply'; return request(q)
            elseif choice=='2' then return request({op='application_status',id=M.prompt('APP receipt')})
            elseif not public and choice=='3' then listRecords(request,'applications')
            elseif not public and choice=='4' then
                print('Verify ownership and the craft in person before approving.')
                return request({op='approve',id=M.prompt('Application ID')})
            elseif not public and choice=='5' then return request({op='reject',id=M.prompt('Application ID'),reason=M.prompt('Reason')})
            elseif not public and choice=='6' then local q=M.vesselForm(); q.op='create_vessel'; return request(q)
            elseif not public and choice=='7' then listRecords(request,'vessels') end
        end)
        if result then M.show(ok and result or ('Error: '..tostring(result))) end
        u.pause()
    end
end

function M.headquarters(request,tracker,root,stations,service)
    while true do
        term.clear(); term.setCursorPos(1,1)
        print('AACS NATIONAL COMMAND | ADOT')
        print('1. Live contacts / stations')
        print('2. Vessel registrations / applications')
        print('3. Register player UUID')
        print('4. Create / replace a zone')
        print('5. Bind observed ship to registration')
        print('6. Grant temporary zone clearance')
        print('7. Reports / print')
        print('8. List records')
        print('9. Revoke / retire / remove')
        print('B. Associate a beacon credential')
        print('P. Pilot approvals')
        print('C. Send controller message')
        print('M. Pilot messages / acknowledgements')
        print('Q. Stop HQ')
        local choice=read():lower()
        if choice=='q' then return end
        local skipPause=false
        local ok,result=pcall(function()
            if choice=='1' then
                contacts.browse(tracker,service.db,stations,false)
                skipPause=true
            elseif choice=='2' then M.registration(request,false)
            elseif choice=='3' then
                return request({op='player',uuid=M.prompt('Player UUID from trusted detector'),name=M.prompt('Username'),nation=M.prompt('Nation')})
            elseif choice=='4' then return request({op='zone',zone=zoneForm()})
            elseif choice=='5' then
                local key=contacts.browse(tracker,service.db,stations,true)
                if not key then skipPause=true; return end
                print('Verify this is the physical vessel you intend to register.')
                local registration=M.prompt('ARD registration')
                print('Binding lifetime uses real time, up to 365 days.')
                print('1 day = 1440 min; 365 days = 525600 min.')
                local minutes=tonumber(M.prompt('Binding lifetime, minutes',tostring(Service.MAX_BINDING_MINUTES)))
                assert(contacts.freshShip(tracker,key),'Contact is no longer fresh; select it again')
                return request({op='bind',sensorKey=key,registration=registration,minutes=minutes})
            elseif choice=='6' then
                return request({op='permit',subject=M.prompt('Subject: vessel:ARD-0001 or player:UUID'),zone=M.prompt('Zone ID'),minutes=tonumber(M.prompt('Duration, minutes','60'))})
            elseif choice=='7' then
                local subject=M.prompt('Subject or sensor key (blank = all)','')
                local zone=M.prompt('Zone filter (blank = all)','')
                local hours=tonumber(M.prompt('Look back hours','24'))
                assert(u.number(hours,0.01,87600),'Invalid hours')
                local r=reports.export(root,{subject=subject,zone=zone,from=u.now()-hours*3600000,
                    incidents=M.prompt('Incident-only? y/N','n')=='y'})
                M.show(r)
                if M.prompt('Print summary? y/N','n')=='y' then
                    local success,message=reports.printFile(r.text)
                    print(message); if not success then print('Keep the saved report; follow resume instructions.') end
                end
            elseif choice=='8' then
                listRecords(request,M.prompt('vessels / players / zones / permits / bindings / applications','vessels'))
            elseif choice=='9' then
                local action=M.prompt('status / permit / binding / zone / peer / application','status')
                if action=='status' then
                    return request({op='status',collection=M.prompt('vessels or players','vessels'),id=M.prompt('Registration/UUID'),status=M.prompt('active / suspended / hostile / retired','suspended')})
                elseif action=='permit' then return request({op='revoke_permit',id=M.prompt('Permit ID')})
                elseif action=='binding' then return request({op='unbind',sensorKey=M.prompt('Ship sensor key')})
                elseif action=='zone' then return request({op='delete_zone',id=M.prompt('Zone ID')})
                elseif action=='peer' then return request({op='revoke_peer',peer=M.prompt('Node name')})
                elseif action=='application' then return request({op='archive_application',id=M.prompt('Resolved APP ID')}) end
            elseif choice=='b' then
                return request({op='assign_beacon',peer=M.prompt('Provisioned beacon node name'),registration=M.prompt('ARD registration')})
            elseif choice=='p' then return pilotMenu(request)
            elseif choice=='m' then
                local result=request({op='pilot_messages'})
                assert(result.ok,result.error)
                local lines={}
                for _,message in ipairs(result.items) do
                    lines[#lines+1]=u.date(message.time)..' | '..message.username..' | '..message.registration..' | '..message.text
                end
                textutils.pagedPrint(#lines>0 and table.concat(lines,'\n') or 'No pilot messages in this HQ session.')
            elseif choice=='c' then
                local target=M.prompt('To: ARD registration / Minecraft username / ALL')
                if target=='ALL' and M.prompt('Public broadcast? y/N','n'):lower()~='y' then return end
                return request({op='controller_message',target=target,
                    station=M.prompt('Preferred station (blank = automatic)',''),text=M.prompt('Message')})
            end
        end)
        if result then M.show(ok and result or ('Error: '..tostring(result))) end
        if not skipPause then u.pause() end
    end
end
return M
]===],
    ["/aacs/lib/util.lua"] = [===[
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
]===],
    ["/aacs/lib/wire.lua"] = [===[
-- Pairwise, directional keys. No shared national secret, discovery or remote code.
local crypto=require('aacs.lib.crypto')
local util=require('aacs.lib.util')
local store=require('aacs.lib.store')
local M={PROTOCOL='aacs.secure.v1',MAX_PLAIN=12000,MAX_WIRE=25000}
local MAX_SEQ=4503599627370000

local function derive(config,peer,from,to)
    local root=crypto.unhex(peer.key)
    local context='AACS1|'..config.realm..'|'..from..'|'..to..'|'
    return crypto.hmac(root,context..'enc',true),crypto.hmac(root,context..'mac',true)
end
local function header(c,from,to,seq,stamp,cipher)
    return table.concat({'AACS1',c.realm,from,to,string.format('%.0f',seq),string.format('%.0f',stamp),cipher},'|')
end

function M.new(config,root)
    local self={config=config,root=root,keys={},budget={},globalBudget={at=0,n=0}}
    self.state=store.load(root..'/transport.json')
    assert(self.state.realm==config.realm and self.state.node==config.node,'Transport belongs to a different node')
    self.nextSequence=self.state.sentThrough+1
    self.reserved=self.state.sentThrough
    assert(type(self.state.received)=='table','Invalid replay state')

    function self:encode(peerName,body)
        local peer=assert(self.config.peers[peerName],'Unknown peer')
        assert(not peer.revoked,'Peer revoked')
        local plain=util.json(body)
        assert(#plain<=M.MAX_PLAIN,'Packet too large; reduce batch size')
        if self.nextSequence>self.reserved then
            self.reserved=self.nextSequence+127
            assert(self.reserved<MAX_SEQ,'Sequence exhausted; re-key')
            self.state.sentThrough=self.reserved
            store.save(self.root..'/transport.json',self.state)
        end
        local seq=self.nextSequence; self.nextSequence=seq+1
        local enc,mac=derive(self.config,peer,self.config.node,peerName)
        local cipher=crypto.hex(crypto.chacha(enc,crypto.nonce(seq),plain))
        local stamp=util.now()
        local unsigned=header(self.config,self.config.node,peerName,seq,stamp,cipher)
        return unsigned..'|'..crypto.hmac(mac,unsigned),seq
    end

    function self:decode(sender,packet)
        if type(packet)~='string' or #packet>M.MAX_WIRE then return nil,'size' end
        local version,realm,from,to,seqText,timeText,cipher,tag=packet:match('^([^|]+)|([^|]+)|([^|]+)|([^|]+)|(%d+)|(%d+)|([0-9a-f]*)|([0-9a-f]+)$')
        if version~='AACS1' or realm~=self.config.realm or to~=self.config.node or not util.id(from) then return nil,'header' end
        local peer=self.config.peers[from]
        if not peer or peer.revoked or sender~=peer.computer then return nil,'peer' end
        local seq,stamp=tonumber(seqText),tonumber(timeText)
        if not util.integer(seq,1,MAX_SEQ) or not util.integer(stamp,1,9007199254740991)
            or #seqText>16 or #timeText>16 or #tag~=64 or #cipher%2~=0 then return nil,'format' end
        if seq<=(self.state.received[from] or 0) then return nil,'replay' end
        if math.abs(util.now()-stamp)>30000 then return nil,'expired' end

        -- A flood can still jam CC's event queue. These limits bound OUR crypto work.
        local second=math.floor(util.now()/1000)
        local g=self.globalBudget
        if g.at~=second then g.at=second; g.n=0 end
        local budget=self.budget[from] or {at=second,n=0}
        self.budget[from]=budget
        if budget.at~=second then budget.at=second; budget.n=0 end
        if g.n>=80 or budget.n>=20 then return nil,'rate' end
        g.n=g.n+1; budget.n=budget.n+1

        local enc,mac=derive(self.config,peer,from,self.config.node)
        local unsigned=packet:sub(1,#packet-65)
        if not crypto.equal(crypto.hmac(mac,unsigned),tag) then return nil,'authentication' end
        local body=util.decode(crypto.chacha(enc,crypto.nonce(seq),crypto.unhex(cipher)))
        if not body then return nil,'json' end
        -- Persist before delivering. A crash may LOSE a request, never replay it.
        self.state.received[from]=seq
        store.save(self.root..'/transport.json',self.state)
        return {from=from,role=peer.role,body=body,seq=seq,stamp=stamp}
    end

    function self:send(peer,body)
        local packet,seq=self:encode(peer,body)
        rednet.send(self.config.peers[peer].computer,packet,M.PROTOCOL)
        return seq
    end
    return self
end
return M
]===],
    ["/aacs/start.lua"] = [===[
-- AACS entry point. Everything executes locally; no downloaded code or remote shell.
package.path='/?.lua;'..package.path
local args={...}
local command=args[1] or 'help'
local App=require('aacs.lib.app')

if command=='run' or command=='boot' then
    App.run(command=='boot')
elseif command=='setup' then App.setup()
elseif command=='diagnose' then App.diagnose()
elseif command=='chat-test' then
    assert(not fs.exists(App.ROOT..'/run.lock'),'Stop AACS before running chat-test')
    local Chat=require('aacs.lib.chat')
    assert(Chat.username(args[2]),'Usage: /aacs/start.lua chat-test MinecraftUsername')
    local box,problem=Chat.inspect(App.config())
    assert(box,problem)
    local sent,detail=Chat.send(box,'AACS station Chat Box test. Reply $atc help after the station and HQ are running.',args[2])
    print(sent==true and 'Chat Box accepted the test message. Check the recipient chat.' or ('Chat test failed: '..tostring(detail)))
elseif command=='selftest' then require('aacs.tests.selftest').run()
elseif command=='demo' then require('aacs.tests.demo').run()
elseif command=='unlock' then
    print('Only continue after ALL AACS processes on this computer have stopped.')
    write('Type UNLOCK: ')
    if read()=='UNLOCK' and fs.exists(App.ROOT..'/run.lock') then fs.delete(App.ROOT..'/run.lock') end
elseif command=='report' then
    local query={subject=args[2] or '',from=os.epoch('utc')-(tonumber(args[3]) or 24)*3600000}
    local result=require('aacs.lib.reports').export(App.ROOT,query)
    print(result.text); print(result.csv); print(result.visits)
elseif command=='print' then
    assert(args[2],'Usage: /aacs/start.lua print /aacs/data/reports/report.txt [start-page]')
    local ok,message=require('aacs.lib.reports').printFile(args[2],nil,tonumber(args[3]))
    print(message)
    if not ok then print('Printing paused. Keep the report and follow the page-resume message.') end
else
    print('AACS 0.2.3-beta.1 | Ardennian Airspace Control')
    print('/aacs/start.lua setup      Configure local peripherals')
    print('/aacs/start.lua run        HQ/station/registration/beacon')
    print('/aacs/start.lua diagnose   List API capabilities / raw tracks')
    print('/aacs/start.lua chat-test <MinecraftUsername>')
    print('/aacs/start.lua selftest   Isolated automatic tests')
    print('/aacs/start.lua demo       Synthetic zone / movement demo')
    print('/aacs/start.lua report [subject] [hours]')
    print('/aacs/start.lua print <report.txt> [start-page]')
    print('Read QUICKSTART.md before deployment. No automatic firing.')
end
]===],
    ["/aacs/tests/chat_test.lua"] = [===[
local Chat = require('aacs.lib.chat')
local Comms = require('aacs.lib.comms')
local Service = require('aacs.lib.service')
local Policy = require('aacs.lib.policy')
local Tracker = require('aacs.lib.tracker')
local Store = require('aacs.lib.store')
local U = require('aacs.lib.util')
local M = {}
local PILOT = '12345678-1234-1234-1234-123456789abc'
local OTHER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

function M.run(check)
    local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
    local function fixture(mock)
        local sent, log = {controls = {}}, {}
        local cfg = {peers = {capital = {role = 'station'}, border = {role = 'station'}, kiosk = {role = 'kiosk'}}}
        local service = Service.new(cfg, '/hq')
        service.db.vessels['ARD-0001'] = {name = 'Dragonfly', status = 'active'}
        service.db.pilots[PILOT] = {username = 'Pilot', registration = 'ARD-0001', expires = mock.time + 600000}
        service.db.zones.test = {id = 'test', name = 'Capital', class = 'restricted', shape = 'box',
            dimension = 'minecraft:overworld', applies = 'ships', minX = 0, maxX = 100,
            minY = 0, maxY = 200, minZ = 0, maxZ = 100}
        service.db.bindings['ship:radar-capital:plane'] = {registration = 'ARD-0001', expires = mock.time + 600000}
        service.db.bindings['ship:radar-border:plane'] = {registration = 'ARD-0001', expires = mock.time + 600000}
        local tracker = Tracker.new()
        local stations = {capital = {lastMessage = mock.time, chat = {ready = true}},
            border = {lastMessage = mock.time, chat = {ready = true}}}
        local comms = Comms.new(service, tracker, stations, function(station, body)
            local destination = body.op == 'chat_notice' and sent or sent.controls
            destination[#destination + 1] = {station = station, body = U.copy(body)}
        end, function(row) log[#log + 1] = row end)
        local function refresh(milliseconds)
            mock.time = mock.time + (milliseconds or 2000)
            stations.capital.lastMessage = mock.time
            stations.border.lastMessage = mock.time
        end
        local function command(text, uuid, from)
            return comms:handleChat(from or 'capital', {username = uuid == OTHER and 'Other' or 'Pilot',
                uuid = uuid or PILOT, command = text, time = mock.time}, mock.time)
        end
        local function observe(x, source)
            source = source or 'capital'
            tracker:ingest({kind = 'ship', id = 'plane', namespace = 'radar-' .. source,
                source = source, dimension = 'minecraft:overworld', x = x, y = 80, z = 50, time = mock.time}, service.db, mock.time)
            tracker:refresh(service.db, mock.time)
        end
        local function tick() comms:tick(mock.time) end
        return comms, service, tracker, stations, sent, log, command, observe, refresh, tick
    end

    local function boxFixture(mock, modern)
        local messages = {}
        local box = {_type = 'chat_box'}
        if modern then
            box.sendMessage = function(text, options)
                messages[#messages + 1] = {text = text, recipient = options.player, prefix = options.prefix}
                return true
            end
        else
            box.sendMessage = function(text, prefix)
                messages[#messages + 1] = {text = text, prefix = prefix}; return true
            end
            box.sendMessageToPlayer = function(text, recipient, prefix)
                messages[#messages + 1] = {text = text, recipient = recipient, prefix = prefix}; return true
            end
        end
        mock.devices.chat_box_0 = box
        return box, messages
    end

    local function notice(mock, id, recipient)
        return {id = id or 'N-1', recipient = recipient or 'Pilot', text = 'Airspace warning',
            expires = mock.time + 20000, priority = 3}
    end

    check('Chat command parser accepts hidden or visible ATC and ignores ordinary chat', function()
        eq(Chat.command('$atc checkin ARD-0001'), 'checkin ARD-0001')
        eq(Chat.command('ATC help'), 'help'); eq(Chat.command('$atc'), 'help')
        eq(Chat.command('atcclear help'), nil); eq(Chat.command('hello atc'), nil)
        eq(Chat.command('atc help\n'), nil)
    end)
    check('Legacy Chat Box private and public messages use the correct methods', function(m)
        local box, messages = boxFixture(m)
        assert(Chat.send(box, 'private', 'Pilot')); assert(Chat.send(box, 'public'))
        eq(messages[1].recipient, 'Pilot'); eq(messages[2].recipient, nil); eq(messages[1].prefix, 'AACS')
    end)
    check('AP options-table Chat Box keeps private targets private', function(m)
        local box, messages = boxFixture(m, true)
        assert(Chat.send(box, 'private', 'Pilot')); assert(Chat.send(box, 'public'))
        eq(messages[1].recipient, 'Pilot'); eq(messages[2].recipient, nil)
    end)
    check('Chat Box nil,error and thrown errors are failures', function(m)
        local box = boxFixture(m)
        box.sendMessageToPlayer = function() return nil, 'cooldown' end
        local ok, problem = Chat.send(box, 'test', 'Pilot'); eq(ok, nil); eq(problem, 'cooldown')
        box.sendMessageToPlayer = function() error('unloaded') end
        ok, problem = Chat.send(box, 'test', 'Pilot'); eq(ok, nil); assert(problem:find('unloaded', 1, true))
    end)
    check('Chat queue honors cooldown without blocking and prioritizes warnings', function(m)
        local _, messages = boxFixture(m)
        local reports = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) reports[#reports + 1] = r end)
        local routine = notice(m, 'routine'); routine.priority = 1
        chat:accept(routine, m.time); chat:accept(notice(m, 'warning'), m.time)
        chat:tick(m.time); eq(#messages, 1); eq(reports[1].id, 'warning')
        chat:tick(m.time + 1000); eq(#messages, 1)
        chat:tick(m.time + 1500); eq(#messages, 2)
    end)
    check('Chat retries a cooldown failure, recovers, and reports success once', function(m)
        local box, messages = boxFixture(m)
        local send = box.sendMessageToPlayer
        local attempt = 0
        box.sendMessageToPlayer = function(...)
            attempt = attempt + 1
            if attempt == 1 then return nil, 'cooldown' end
            return send(...)
        end
        local reports = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) reports[#reports + 1] = r end)
        chat:accept(notice(m), m.time); chat:tick(m.time); eq(#reports, 0)
        chat:tick(m.time + 1500); eq(#messages, 1); eq(#reports, 1); eq(reports[1].status, 'sent')
        eq(chat:status().error, nil)
    end)
    check('Chat detachment recovers and expired messages are never sent', function(m)
        local reports = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) reports[#reports + 1] = r end)
        chat:accept(notice(m), m.time); chat:tick(m.time); assert(not chat.ready)
        local _, messages = boxFixture(m)
        chat:tick(m.time + 21000); eq(#messages, 0); eq(reports[1].status, 'failed')
        chat:accept(notice(m, 'new'), m.time); chat:tick(m.time); eq(#messages, 1); assert(chat.ready)
    end)
    check('Chat retransmission never sends the same notice twice', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        local body = notice(m)
        chat:accept(body, m.time); chat:accept(body, m.time); chat:tick(m.time)
        chat:accept(body, m.time + 2000); chat:tick(m.time + 2000); eq(#messages, 1)
    end)
    check('New airspace notice supersedes an unsent old warning', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        local old, new = notice(m, 'old'), notice(m, 'new')
        old.thread = 'vessel:ARD-0001:Pilot'; old.version = 1
        new.thread = old.thread; new.version = 2; new.text = 'Observed leaving'; new.priority = 1
        chat:accept(old, m.time); chat:accept(new, m.time); chat:tick(m.time)
        eq(#messages, 1); eq(messages[1].text, 'Observed leaving')
    end)
    check('Chat queue is bounded and public sends require explicit station opt-in', function(m)
        boxFixture(m)
        local results = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) results[#results + 1] = r end)
        local public = notice(m, 'public'); public.recipient = nil
        assert(not chat:accept(public, m.time))
        for i = 1, 32 do assert(chat:accept(notice(m, 'N-' .. i), m.time)) end
        assert(not chat:accept(notice(m, 'overflow'), m.time)); eq(#chat.queue, 32)
    end)
    check('Pilot relay validates event UUID, rate limits, and never parses a claimed UUID from text', function(m)
        boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end); chat:tick(m.time)
        assert(not chat:relay('Pilot', '$atc help', 'fake', m.time))
        local body = chat:relay('Pilot', '$atc checkin ARD-0001', PILOT, m.time)
        eq(body.uuid, PILOT); assert(not chat:relay('Pilot', '$atc help', PILOT, m.time + 1000))
        assert(chat:relay('Pilot', '$atc help', PILOT, m.time + 2000))
    end)
    check('HQ pilot authorization requires local administration and persists', function(m)
        local _, service = fixture(m)
        local q = {op = 'authorize_pilot', request = 'pilot-1', uuid = OTHER, username = 'Other', registration = 'ARD-0001', minutes = 60}
        for _, role in ipairs({'station', 'beacon', 'kiosk', 'registrar'}) do assert(not service:execute(role, role, q).ok) end
        assert(service:execute('hq-console', 'local_admin', q).ok)
        eq(Store.load('/hq/database.json').pilots[OTHER].registration, 'ARD-0001')
        q.request = 'pilot-2'; q.minutes = 0; assert(not service:execute('hq-console', 'local_admin', q).ok)
    end)
    check('Unknown pilot request appears at HQ but cannot self-authorize or gain clearance', function(m)
        local comms, service, _, _, sent, _, command, _, _, tick = fixture(m)
        command('checkin ARD-0001', OTHER); tick(); eq(comms:session(OTHER, m.time), nil)
        eq(comms:candidates(m.time).items[1].uuid, OTHER)
        assert(sent[1].body.text:find('requires HQ approval', 1, true)); eq(U.count(service.db.permits), 0)
    end)
    check('Approved pilot can check in and check out with the authenticated account UUID', function(m)
        local comms, _, _, _, sent, _, command, _, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); eq(comms:session(PILOT, m.time).username, 'Pilot')
        eq(sent[1].body.recipient, 'Pilot')
        refresh(3000); command('checkout'); tick(); eq(comms:session(PILOT, m.time), nil)
    end)
    check('Overlapping stations relay one command and send one vessel notice', function(m)
        local comms, _, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); assert(not command('checkin ARD-0001', PILOT, 'border')); tick()
        eq(#sent, 1)
        refresh(); observe(50, 'capital'); observe(50, 'border'); tick()
        eq(#sent, 2); eq(sent[2].body.recipient, 'Pilot'); eq(sent[2].station, 'border')
        assert(sent[2].body.text:find('detected within', 1, true))
    end)
    check('Fresh observations announce entry and exit; disappearance never announces exit', function(m)
        local _, _, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(-10); tick()
        refresh(); observe(50); tick(); assert(sent[#sent].body.text:find('entering', 1, true))
        refresh(); observe(110); tick(); assert(sent[#sent].body.text:find('observed leaving', 1, true))
        refresh(); observe(50); tick()
        refresh(21000); tracker:refresh({}, m.time); tick()
        assert(sent[#sent].body.text:find('contact lost', 1, true)); assert(not sent[#sent].body.text:find('observed leaving', 1, true))
    end)
    check('Initial radar acquisition inside a zone is detected within, not a claimed boundary crossing', function(m)
        local _, _, _, _, sent, _, command, observe, _, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local found = false
        for _, item in ipairs(sent) do
            if item.body.priority == 3 then
                assert(item.body.text:find('detected within', 1, true)); assert(not item.body.text:find('entering', 1, true)); found = true
            end
        end
        assert(found)
    end)
    check('Restricted warnings repeat at 30 seconds and acknowledgement never grants a permit', function(m)
        local comms, service, _, _, sent, log, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local before = #sent
        refresh(29000); observe(50); tick(); eq(#sent, before)
        refresh(1000); observe(50); tick(); eq(#sent, before + 1)
        local id = comms:session(PILOT, m.time).lastWarning
        refresh(3000); command('ack ' .. id); tick()
        eq(U.count(service.db.permits), 0)
        local acknowledged = false
        for _, row in ipairs(log) do if row.event == 'pilot_ack' then acknowledged = true end end
        assert(acknowledged)
        assert(sent[#sent].body.text:find('does not grant clearance', 1, true))
    end)
    check('Permit grant and expiry send updated clearance notices', function(m)
        local _, service, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        refresh(); service.db.permits.P = {id = 'P', subject = 'vessel:ARD-0001', zone = 'test', starts = m.time, expires = m.time + 1000}
        tracker:refresh(service.db, m.time); tick()
        assert(sent[#sent].body.text:find('clearance now valid', 1, true))
        refresh(); observe(50); tick(); assert(sent[#sent].body.text:find('clearance no longer valid', 1, true))
    end)
    check('Pilot revocation and session expiry stop further private vessel routing', function(m)
        local comms, service, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); service.db.pilots[PILOT] = nil
        refresh(); observe(50); tick(); eq(#sent, 1); eq(comms:session(PILOT, m.time), nil)
    end)
    check('Zone commands disclose actual geometry and altitude without changing policy', function(m)
        local _, service, _, _, sent, _, command, _, refresh, tick = fixture(m)
        command('zone test', OTHER); tick()
        assert(sent[1].body.text:find('X 0..100', 1, true)); assert(sent[1].body.text:find('Y 0..200', 1, true))
        refresh(3000); command('zones 999', OTHER); tick(); assert(sent[#sent].body.text:find('from 1 to 1', 1, true))
        eq(U.count(service.db.permits), 0)
    end)
    check('Unknown ships are not privately assigned to nearby players; public hails are opt-in', function(m)
        local _, service, _, stations, sent, log, _, observe, refresh, tick = fixture(m)
        service.db.bindings = {}; observe(50); tick(); eq(#sent, 0)
        assert(log[#log].event == 'chat_unroutable')
        stations.capital.chat.publicHails = true
        refresh(30000); observe(50); tick(); eq(#sent, 1); eq(sent[1].body.recipient, nil)
        assert(sent[1].body.text:find('near X', 1, true))
    end)
    check('Offline or revoked stations cannot relay commands and are not chosen as senders', function(m)
        local comms, service, _, stations, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); refresh(); stations.capital.chat.ready = false
        assert(not command('help')); observe(50); tick(); eq(sent[#sent].station, 'border')
        service.config.peers.border.revoked = true
        eq(comms:station(nil, m.time), nil)
    end)
    check('Only the chosen station can report a pending notice as sent', function(m)
        local comms, _, _, _, sent, log, command, _, _, tick = fixture(m)
        command('help'); tick(); local id = sent[1].body.id
        assert(not comms:result('border', {id = id, status = 'sent'}, m.time))
        assert(comms:result('capital', {id = id, status = 'sent', detail = 'accepted'}, m.time))
        eq(log[#log].event, 'chat_sent'); assert(not comms:result('capital', {id = id, status = 'sent'}, m.time))
    end)
    check('HQ restart retains authorizations but requires a new pilot check-in', function(m)
        local comms, service, tracker, stations, _, _, command = fixture(m)
        command('checkin ARD-0001'); assert(comms:session(PILOT, m.time))
        local restarted = Comms.new(service, tracker, stations, function() end)
        eq(restarted:session(PILOT, m.time), nil); assert(service.db.pilots[PILOT])
    end)
    check('Controller sends remain private by default and broadcast needs station opt-in', function(m)
        local comms, _, _, stations, sent, _, command, _, _, tick = fixture(m)
        command('checkin ARD-0001'); tick()
        assert(comms:controller({target = 'ARD-0001', station = '', text = 'Contact Capital tower'}, m.time).ok)
        tick(); eq(sent[#sent].body.recipient, 'Pilot')
        assert(not comms:controller({target = 'ALL', text = 'Notice'}, m.time).ok)
        stations.capital.chat.publicHails = true
        assert(comms:controller({target = 'ALL', text = 'Notice'}, m.time).ok); tick(); eq(sent[#sent].body.recipient, nil)
    end)
    check('Pilot messages reach the HQ inbox without changing clearances', function(m)
        local comms, service, _, _, sent, log, command, _, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); refresh(3000)
        command('say Request permission to enter Capital'); tick()
        eq(comms:messages().items[1].username, 'Pilot')
        assert(comms:messages().items[1].text:find('Request permission', 1, true))
        assert(sent[#sent].body.text:find('does not confirm', 1, true))
        eq(U.count(service.db.permits), 0)
        local found = false
        for _, row in ipairs(log) do if row.event == 'pilot_message' then found = true end end
        assert(found)
    end)
    check('Station event loop relays chat, accepts only HQ notices, and returns send results', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local _, messages = boxFixture(m)
        m.devices.radar = {getTracks = function() return {} end}
        local valid = notice(m, 'valid'); valid.op = 'chat_notice'
        local invalid = notice(m, 'invalid'); invalid.op = 'chat_notice'
        local decoded = {{from = 'beacon', body = invalid}, {from = 'hq', body = valid}}
        local events = {{'timer', 2}, {'chat', 'Pilot', '$atc help', PILOT}, {'chat', OTHER, 'Other', '$atc help'},
            {'rednet_message', 112, 'fake', Wire.PROTOCOL}, {'rednet_message', 112, 'valid', Wire.PROTOCOL},
            {'timer', 1}, {'char', 'q'}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function() local event = assert(table.remove(events, 1), 'Unexpected event wait'); return table.unpack(event) end
        term = {getSize = function() return 75, 20 end, setCursorPos = function() end, clear = function() end, write = function() end}
        local sent = {}
        local wire = {send = function(_, _, body) sent[#sent + 1] = U.copy(body) end,
            decode = function() return table.remove(decoded, 1) end}
        App.station({node = 'capital', hq = 'hq', sensorsConfigured = true, radars = {'radar'},
            namespace = 'radar-capital', dimension = 'minecraft:overworld', chatBox = 'chat_box_0'}, wire, '/station')
        eq(#messages, 1); eq(messages[1].recipient, 'Pilot')
        local relay, result, heartbeat = 0, false, false
        for _, body in ipairs(sent) do
            if body.op == 'pilot_chat' then assert(body.uuid == PILOT or body.uuid == OTHER); relay = relay + 1 end
            if body.op == 'chat_result' then eq(body.id, 'valid'); eq(body.status, 'sent'); result = true end
            if body.op == 'observations' then eq(body.chat.ready, true); heartbeat = true end
        end
        assert(relay == 2 and result and heartbeat)
    end)
    check('HQ event loop processes station pilot commands and dispatches a private reply', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local _, service = fixture(m)
        Store.save('/hq/database.json', service.db)
        local decoded = {{from = 'capital', role = 'station', body = {op = 'observations', items = {}, chat = {ready = true}}},
            {from = 'capital', role = 'station', body = {op = 'pilot_chat', username = 'Pilot', uuid = PILOT,
                command = 'checkin ARD-0001', time = m.time}}}
        local events = {{'rednet_message', 108, 'observations', Wire.PROTOCOL},
            {'rednet_message', 108, 'checkin', Wire.PROTOCOL}, {'timer', 1}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function()
            local event = table.remove(events, 1)
            if not event then error('TEST_STOP') end
            return table.unpack(event)
        end
        parallel = {waitForAny = function(network) network() end}
        local sent = {}
        local wire = {send = function(_, station, body) sent[#sent + 1] = {station = station, body = U.copy(body)} end,
            decode = function() return table.remove(decoded, 1) end}
        local ok, problem = pcall(App.hq, service.config, wire, '/hq')
        assert(not ok and tostring(problem):find('TEST_STOP', 1, true), tostring(problem))
        eq(#sent, 2); eq(sent[1].body.op, 'chat_reset')
        eq(sent[2].station, 'capital'); eq(sent[2].body.op, 'chat_notice')
        eq(sent[2].body.recipient, 'Pilot'); assert(sent[2].body.text:find('Checked in', 1, true))
    end)

    check('Both AP chat event orders use the actual event UUID and reject command senders', function()
        local name, text, uuid = Chat.event({'chat', 'Pilot', '$atc status', PILOT})
        eq(name, 'Pilot'); eq(text, '$atc status'); eq(uuid, PILOT)
        name, text, uuid = Chat.event({'chat', PILOT, 'Pilot', '$atc status'})
        eq(name, 'Pilot'); eq(text, '$atc status'); eq(uuid, PILOT)
        eq(Chat.event({'chat', nil, '[say]', '$atc checkin ARD-0001'}), nil)
        eq(Chat.event({'chat', 'Pilot', '$atc ' .. PILOT, 'fake-uuid'}), nil)
    end)
    check('Cancellation before notice arrival prevents it from ever sending', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        assert(chat:cancel('late'))
        assert(chat:accept(notice(m, 'late'), m.time))
        chat:tick(m.time); eq(#messages, 0)
    end)
    check('HQ cancels a queued warning at the old station when a different station observes exit', function(m)
        local _, _, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick()
        local _, messagesA = boxFixture(m)
        local first = Chat.new({chatBox = 'chat_box_0'}, '/first', function() end)
        first.nextSend = m.time + 10000
        refresh(); observe(50, 'capital'); tick()
        local warning = sent[#sent]
        eq(warning.station, 'capital'); assert(warning.body.text:find('WARNING', 1, true))
        first:accept(warning.body, m.time)
        refresh(); observe(110, 'border'); tick()
        local cancelled = false
        for _, control in ipairs(sent.controls) do
            if control.station == 'capital' and control.body.id == warning.body.id then
                eq(control.body.op, 'chat_cancel'); first:cancel(control.body.id); cancelled = true
            end
        end
        assert(cancelled); first:tick(m.time + 10000); eq(#messagesA, 0)
        local latest = sent[#sent]
        eq(latest.station, 'border'); assert(latest.body.text:find('observed leaving', 1, true))
    end)
    check('Pilot checkout cancels both pending and not-yet-dispatched vessel notices', function(m)
        local comms, _, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); refresh(); observe(50); tick()
        local warningId = sent[#sent].body.id
        assert(comms:controller({target = 'ARD-0001', station = '', text = 'Private vessel message'}, m.time).ok)
        refresh(3000); command('checkout')
        for _, item in ipairs(comms.queue) do assert(item.subject ~= 'vessel:ARD-0001') end
        eq(comms.pending[warningId], nil)
        local found = false
        for _, control in ipairs(sent.controls) do if control.body.id == warningId then found = true end end
        assert(found)
    end)
    check('HQ reconnection clears old station queues and keeps duplicate tombstones', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        local old = notice(m, 'before-restart'); chat:accept(old, m.time); chat:reset()
        chat:accept(old, m.time); chat:tick(m.time); eq(#messages, 0)
        chat:accept(notice(m, 'after-restart'), m.time); chat:tick(m.time); eq(#messages, 1)
    end)
    check('Station notice ordering uses persistent wire sequence rather than reset HQ counter', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local _, messages = boxFixture(m)
        m.devices.radar = {getTracks = function() return {} end}
        local old, new = notice(m, 'old-counter'), notice(m, 'new-counter')
        old.op = 'chat_notice'; old.thread = 'same-contact'; old.version = 9000
        new.op = 'chat_notice'; new.thread = old.thread; new.version = 1; new.text = 'New HQ status'; new.priority = 1
        local decoded = {{from = 'hq', body = old, seq = 100}, {from = 'hq', body = new, seq = 101}}
        local events = {{'rednet_message', 112, 'old', Wire.PROTOCOL}, {'rednet_message', 112, 'new', Wire.PROTOCOL}, {'timer', 1}, {'char', 'q'}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function() local event = assert(table.remove(events, 1)); return table.unpack(event) end
        term = {getSize = function() return 75, 20 end, setCursorPos = function() end, clear = function() end, write = function() end}
        local wire = {send = function() end, decode = function() return table.remove(decoded, 1) end}
        App.station({node = 'capital', hq = 'hq', sensorsConfigured = true, radars = {'radar'},
            namespace = 'radar-capital', dimension = 'minecraft:overworld', chatBox = 'chat_box_0'}, wire, '/station')
        eq(#messages, 1); eq(messages[1].text, 'New HQ status')
    end)
    check('A full HQ queue still accepts a replacement for the same contact', function(m)
        local comms = fixture(m)
        for i = 1, 128 do
            assert(comms:notice('capital', 'Pilot', 'Status ' .. i, 1, nil, m.time, nil, 'thread-' .. i))
        end
        assert(comms:notice('capital', 'Pilot', 'Current status', 1, nil, m.time, nil, 'thread-1'))
        eq(#comms.queue, 128)
    end)
    check('Suspending registration preserves pilot communication while denying zone access', function(m)
        local comms, service, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        service.db.zones.test.class = 'controlled'
        command('checkin ARD-0001'); observe(50); tick()
        refresh(); service.db.vessels['ARD-0001'].status = 'suspended'
        tracker:refresh(service.db, m.time); tick()
        assert(comms:session(PILOT, m.time)); eq(sent[#sent].body.recipient, 'Pilot')
        assert(sent[#sent].body.text:find('Registration suspended', 1, true)); eq(sent[#sent].body.priority, 3)
        refresh(3000); assert(command('checkin ARD-0001')); assert(comms:session(PILOT, m.time))
    end)
    check('Renewing the same pilot check-in retains a recent warning acknowledgement ID', function(m)
        local comms, _, _, _, _, log, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local id = comms:session(PILOT, m.time).lastWarning
        refresh(3000); command('checkin ARD-0001'); tick()
        refresh(3000); command('ack ' .. id); tick()
        local found = false
        for _, row in ipairs(log) do if row.event == 'pilot_ack' and row.id == id then found = true end end
        assert(found)
    end)
    check('Binding expiry reclassifies a retained contact without waiting for another scan', function(m)
        local _, service, tracker, _, _, _, _, observe = fixture(m)
        observe(50)
        service.db.bindings['ship:radar-capital:plane'].expires = m.time + 1000
        m.time = m.time + 1001; tracker:refresh(service.db, m.time)
        eq(tracker.contacts['vessel:ARD-0001'], nil)
        local contact = tracker.contacts['ship:radar-capital:plane']
        assert(contact); eq(contact.subject, nil); assert(contact.decision.violation)
    end)
    check('An older observation after rebinding cannot delete the last known contact', function(m)
        local _, service, tracker, _, _, _, _, observe = fixture(m)
        service.db.bindings = {}; observe(50)
        local original = tracker.contacts['ship:radar-capital:plane']
        service.db.bindings[original.sensorKey] = {registration = 'ARD-0001', expires = m.time + 60000}
        local older = U.copy(original); older.time = m.time - 1
        assert(not tracker:ingest(older, service.db, m.time)); eq(tracker.contacts[original.sensorKey], original)
        tracker:refresh(service.db, m.time)
        assert(tracker.contacts['vessel:ARD-0001']); eq(tracker.contacts[original.sensorKey], nil)
    end)
    check('Reclassified radar identity is not announced as lost contact or an airspace exit', function(m)
        local _, service, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        refresh(); service.db.bindings = {}; tracker:refresh(service.db, m.time); tick()
        local text = sent[#sent].body.text
        assert(text:find('binding changed', 1, true)); assert(not text:find('contact lost', 1, true)); assert(not text:find('leaving', 1, true))
    end)
    check('Policy refresh merges newly bound aliases without replacing a newer position', function(m)
        local _, service, tracker, _, _, _, _, observe, refresh = fixture(m)
        service.db.bindings = {}; observe(10, 'capital'); refresh(); observe(60, 'border')
        service.db.bindings['ship:radar-capital:plane'] = {registration = 'ARD-0001', expires = m.time + 60000}
        service.db.bindings['ship:radar-border:plane'] = {registration = 'ARD-0001', expires = m.time + 60000}
        tracker:refresh(service.db, m.time)
        eq(U.count(tracker.contacts), 1); eq(tracker.contacts['vessel:ARD-0001'].x, 60)
    end)
    check('Chat report exports retain pilot messages, acknowledgement IDs and account fields', function(m)
        local Reports = require('aacs.lib.reports')
        Store.log('/hq/events.jsonl', {event = 'pilot_message', time = m.time, subject = 'vessel:ARD-0001',
            pilot = PILOT, username = 'Pilot', station = 'capital', text = '=Requesting clearance'})
        Store.log('/hq/events.jsonl', {event = 'pilot_ack', time = m.time + 1, subject = 'vessel:ARD-0001', id = 'ATC-123', pilot = PILOT})
        m.time = m.time + 2
        local result = Reports.export('/hq', {})
        local csv = U.read(result.csv)
        assert(csv:find('message_id,pilot_uuid,username,station,message', 1, true))
        assert(csv:find("'=Requesting clearance", 1, true)); assert(csv:find(PILOT, 1, true)); assert(csv:find('ATC-123', 1, true))
        local text = U.read(result.text)
        assert(text:find('Requesting clearance', 1, true)); assert(text:find('ATC-123', 1, true))
    end)

    check('Critical notices displace routine messages from full station and HQ queues', function(m)
        boxFixture(m)
        local results = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(row) results[#results + 1] = row end)
        for i = 1, 32 do local body = notice(m, 'routine-' .. i); body.priority = 1; assert(chat:accept(body, m.time)) end
        assert(chat:accept(notice(m, 'urgent'), m.time)); eq(#chat.queue, 32)
        eq(results[1].id, 'routine-1'); eq(results[1].status, 'failed')
        local comms = fixture(m)
        for i = 1, 128 do assert(comms:notice('capital', 'Pilot', 'Routine', 1, nil, m.time)) end
        assert(comms:notice('capital', 'Pilot', 'Urgent warning', 3, nil, m.time)); eq(#comms.queue, 128)
        local found = false
        for _, item in ipairs(comms.queue) do if item.body.priority == 3 then found = true end end
        assert(found)
    end)
    check('Pilot approval expiry cancels a station warning already awaiting send', function(m)
        local comms, service, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local id = comms:session(PILOT, m.time).lastWarning
        service.db.pilots[PILOT].expires = m.time + 1000
        refresh(1001); tick(); eq(comms:session(PILOT, m.time), nil); eq(comms.pending[id], nil)
        local found = false
        for _, row in ipairs(sent.controls) do if row.body.id == id and row.body.op == 'chat_cancel' then found = true end end
        assert(found)
    end)
    check('Missing Chat Box and malformed sender events fail closed', function(m)
        local chat = Chat.new({chatBox = 'missing'}, '/station', function() end)
        chat:tick(m.time); assert(not chat.ready)
        local name, text, uuid = Chat.event({'chat', nil, '[say]', '$atc checkin ARD-0001'})
        eq(chat:relay(name, text, uuid, m.time), nil)
        eq(chat:status().queued, 0)
    end)

    check('An unavailable HQ policy marks the cached station rules stale without stopping scans', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local db = Service.empty()
        Store.save('/station/policy.json', Policy.snapshot(db, m.time))
        m.devices.radar = {getTracks = function() return {} end}
        local events = {{'rednet_message', 112, 'limit', Wire.PROTOCOL}, {'timer', 1}, {'char', 'q'}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function() local event = assert(table.remove(events, 1)); return table.unpack(event) end
        term = {getSize = function() return 90, 20 end, setCursorPos = function() end, clear = function() end, write = function() end}
        local observations = false
        local wire = {send = function(_, _, body) if body.op == 'observations' then observations = true end end,
            decode = function() return {from = 'hq', body = {op = 'policy_unavailable'}} end}
        App.station({node = 'capital', hq = 'hq', sensorsConfigured = true, radars = {'radar'},
            namespace = 'radar-capital', dimension = 'minecraft:overworld', faultSide = 'right'}, wire, '/station')
        eq(m.outputs.right, true); assert(observations)
    end)

end

return M
]===],
    ["/aacs/tests/demo.lua"] = [===[
-- Pure simulation: no modem, real registry changes, redstone or weapon calls.
local M={}
function M.run()
    local P=require('aacs.lib.policy')
    local S=require('aacs.lib.service')
    local T=require('aacs.lib.tracker')
    local U=require('aacs.lib.util')
    local db=S.empty()
    for i,class in ipairs({'unrestricted','controlled','restricted','prohibited'}) do
        db.zones[class]={id=class,name=class,class=class,dimension='minecraft:overworld',applies='ships',shape='box',
            minX=(i-1)*150,maxX=(i-1)*150+100,minZ=-50,maxZ=50,minY=100,maxY=1000}
    end
    local tracker=T.new(function(e)
        if e.event~='position' then print(e.event..' | '..tostring(e.zone or '')..' | '..tostring(e.reason or '')) end
    end)
    local start=U.now()
    for i=0,12 do
        local c={kind='ship',id='DEMO',namespace='simulation',source='demo',dimension='minecraft:overworld',
            x=-50+i*60,y=400,z=0,time=start+i*1000}
        tracker:ingest(c,db,c.time)
    end
    print('Demo complete. No production files or peripherals changed.')
end
return M
]===],
    ["/aacs/tests/mock.lua"] = [===[
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
]===],
    ["/aacs/tests/selftest.lua"] = [===[
local C=require('aacs.lib.crypto')
local U=require('aacs.lib.util')
local Store=require('aacs.lib.store')
local Wire=require('aacs.lib.wire')
local Policy=require('aacs.lib.policy')
local Tracker=require('aacs.lib.tracker')
local Service=require('aacs.lib.service')
local Sensors=require('aacs.lib.sensors')
local Reports=require('aacs.lib.reports')
local App=require('aacs.lib.app')
local ContactUI=require('aacs.lib.contact_ui')
local UI=require('aacs.lib.ui')
local Display=require('aacs.lib.display')
local Mock=require('aacs.tests.mock')
local M={}

function M.run()
    local passed,failed=0,0
    local function check(name,fn)
        local mock=Mock.new()
        local restore=Mock.install(mock)
        local ok,err=pcall(fn,mock)
        restore()
        if ok then passed=passed+1;print('PASS '..name)
        else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
    end
    local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
    local function bad(fn) assert(not pcall(fn),'Expected failure') end
    local function pair()
        local key=string.rep('12',32) -- TEST ONLY; provision.py never uses fixed keys.
        local a={realm='test-realm',node='station',peers={hq={computer=10,role='hq',key=key}}}
        local b={realm='test-realm',node='hq',peers={station={computer=11,role='station',key=key}}}
        Store.save('/a/transport.json',{realm=a.realm,node=a.node,sentThrough=0,received={}})
        Store.save('/b/transport.json',{realm=b.realm,node=b.node,sentThrough=0,received={}})
        return Wire.new(a,'/a'),Wire.new(b,'/b'),a,b
    end
    local function dbFixture()
        local db=Service.empty()
        db.zones.test={id='test',name='Test zone',class='controlled',dimension='minecraft:overworld',
            applies='ships',shape='box',minX=0,maxX=100,minZ=0,maxZ=100,minY=0,maxY=100}
        local c={kind='ship',id='craft',namespace='radar-one',sensorKey='ship:radar-one:craft',
            dimension='minecraft:overworld',x=50,y=50,z=50,time=U.now(),source='one'}
        return db,c,db.zones.test
    end
    local function registered(db,c)
        db.vessels['ARD-0001']={name='Test craft',status='active'}
        db.bindings[c.sensorKey]={registration='ARD-0001',expires=U.now()+600000}
    end
    local function fields(op,request)
        return {op=op,request=request or 'req-1',name='Test craft',craftType='airship',owner='Pilot',
            nation='Ardennes',purpose='civilian',description='',claimedUuid='12345678-1234-1234-1234-123456789abc'}
    end

    local function bindingFixture()
        local db, contact = dbFixture()
        db.vessels['ARD-0001'] = {name = 'Test craft', status = 'active'}
        Store.save('/hq/database.json', db)
        return Service.new({peers = {}}, '/hq'), contact
    end

    local function contactsFixture(mock,count)
        local tracker={contacts={}}
        for i=1,count do
            local id=string.format('ship-%02d',i)
            local key='ship:radar-capital:'..id
            tracker.contacts[key]={id=id,sensorKey=key,kind='ship',dimension='minecraft:overworld',
                x=i*10,y=80,z=0,time=mock.time,decision={reason='Outside configured zones'}}
        end
        return tracker
    end

    local function monitorFixture()
        local screen={_type='monitor',rows={},clears=0,row=1}
        screen.getSize=function() return 75,20 end
        screen.setCursorPos=function(_,y) screen.row=y end
        screen.clear=function() screen.rows={};screen.clears=screen.clears+1 end
        screen.write=function(value) screen.rows[screen.row]=value end
        screen.setBackgroundColor=function(value) screen.background=value end
        screen.setTextColor=function(value) screen.foreground=value end
        return screen
    end

    check('Monitor missing at startup is retried and draws when connected later',function(m)
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14'},'/station')
        local tracker=contactsFixture(m,1)
        assert(not driver:draw('AACS capital',tracker,'HQ POLICY CURRENT r3',{}))
        local failure=U.decode(U.read('/station/monitor-status.json'))
        eq(failure.state,'error');eq(failure.frames,0)
        local screen=monitorFixture();m.devices.monitor_14=screen;m.time=m.time+2000
        assert(driver:draw('AACS capital',tracker,'HQ POLICY CURRENT r3',{}))
        local current=U.decode(U.read('/station/monitor-status.json'))
        eq(current.state,'ok');eq(current.frames,1);eq(current.monitor,'monitor_14')
        assert(screen.rows[20]:find('PC 108 | monitor_14 | Updated',1,true))
    end)
    check('Monitor reconnect uses the new peripheral instead of the detached object',function(m)
        local first=monitorFixture();m.devices.monitor_14=first
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14'},'/station')
        local tracker=contactsFixture(m,1)
        assert(driver:draw('AACS capital',tracker,'CURRENT',{}));eq(first.clears,1)
        m.devices.monitor_14=nil;m.time=m.time+2000
        assert(not driver:draw('AACS capital',tracker,'CURRENT',{}));eq(first.clears,1)
        local replacement=monitorFixture();m.devices.monitor_14=replacement;m.time=m.time+2000
        assert(driver:draw('AACS capital',tracker,'CURRENT',{}))
        eq(first.clears,1);eq(replacement.clears,1);eq(driver.frames,2)
    end)
    check('Monitor write errors are reported and a later frame recovers',function(m)
        local screen=monitorFixture()
        local write=screen.write
        screen.write=function() error('Disconnected during monitor write') end
        m.devices.monitor_14=screen
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14'},'/station')
        local tracker=contactsFixture(m,1)
        assert(not driver:draw('AACS capital',tracker,'CURRENT',{}))
        assert(driver:footer():find('OFFLINE',1,true))
        assert(U.decode(U.read('/station/monitor-status.json')).error:find('Disconnected',1,true))
        screen.write=write;m.time=m.time+2000
        assert(driver:draw('AACS capital',tracker,'CURRENT',{}))
        assert(not driver:footer():find('OFFLINE',1,true))
    end)
    check('Monitor heartbeat advances when the radar contact data is unchanged',function(m)
        local screen=monitorFixture();m.devices.monitor_14=screen
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14'},'/station')
        local tracker=contactsFixture(m,1)
        assert(driver:draw('AACS capital',tracker,'CURRENT',{}))
        local first=screen.rows[20]
        m.time=m.time+6000;assert(driver:draw('AACS capital',tracker,'CURRENT',{}))
        assert(screen.rows[20]~=first);assert(screen.rows[20]:find('#2',1,true))
        local health=U.decode(U.read('/station/monitor-status.json'))
        eq(health.frames,2);eq(health.renderedAt,m.time)
    end)
    check('Monitor surface refresh restores text scale and runs only on connection',function(m)
        local screen=monitorFixture()
        local scale,resizes=1.5,0
        screen.getTextScale=function() return scale end
        screen.setTextScale=function(value) scale=value;resizes=resizes+1 end
        m.devices.monitor_14=screen
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14'},'/station')
        local tracker=contactsFixture(m,1)
        assert(driver:draw('AACS capital',tracker,'CURRENT',{}));eq(scale,1.5);eq(resizes,2)
        m.time=m.time+2000;assert(driver:draw('AACS capital',tracker,'CURRENT',{}));eq(resizes,2)
        m.devices.monitor_14=nil;assert(not driver:draw('AACS capital',tracker,'CURRENT',{}))
        m.devices.monitor_14=screen;assert(driver:draw('AACS capital',tracker,'CURRENT',{}))
        eq(scale,1.5);eq(resizes,4)
    end)
    check('Monitor status does not expose credentials or switch to another display',function(m)
        local other=monitorFixture();m.devices.monitor_13=other
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14',
            peers={hq={key='PRIVATE ENDPOINT KEY'}}},'/station')
        assert(not driver:draw('AACS capital',contactsFixture(m,1),'CURRENT',{}))
        eq(other.clears,0)
        assert(not U.read('/station/monitor-status.json'):find('PRIVATE ENDPOINT KEY',1,true))
        m.devices.monitor_14={_type='inventory'}
        local ready,problem=driver:draw('AACS capital',contactsFixture(m,1),'CURRENT',{})
        eq(ready,false);assert(problem:find('not a monitor',1,true))
    end)
    check('Diagnostic storage failure does not stop monitor rendering',function(m)
        local screen=monitorFixture();m.devices.monitor_14=screen
        local original=m.fs.open
        m.fs.open=function(path,mode)
            if path=='/station/monitor-status.json' then return nil,'Disk full' end
            return original(path,mode)
        end
        local driver=Display.new({computer=108,node='capital',monitor='monitor_14'},'/station')
        assert(driver:draw('AACS capital',contactsFixture(m,1),'CURRENT',{}))
        eq(driver.frames,1);eq(screen.clears,1)
    end)
    check('Station recovers a late monitor and renders the same named contact on both displays',function(m)
        local native=monitorFixture();term=native
        local external=monitorFixture()
        local db=Service.empty()
        db.vessels['ARD-0001']={name='SUPER-DRAGONFLY-LG1',status='active'}
        db.bindings['ship:radar-capital:plane']={registration='ARD-0001',expires=m.time+60000}
        local snapshot=U.json(Policy.snapshot(db,m.time))
        local token=1
        m.devices.radar={getTracks=function() return {{id='plane',position={x=0,y=80,z=0},
            scannedTime=token,entityType='Sable:ship',category='SABLE'}} end}
        local events={{'timer',1},{'rednet_message',112,'policy',Wire.PROTOCOL},
            {'timer',2,before=function() m.time=m.time+2000;token=2;m.devices.monitor_14=external end},
            {'timer',3,before=function() m.time=m.time+2000 end},{'char','q'}}
        local timer=0
        os.startTimer=function() timer=timer+1;return timer end
        os.pullEvent=function()
            local event=assert(table.remove(events,1),'Unexpected event wait')
            if event.before then event.before() end
            return table.unpack(event)
        end
        local sent={}
        local wire={send=function(_,peer,body) sent[#sent+1]=body end,decode=function()
            return {from='hq',body={op='policy_part',revision=1,digest=C.sha256(snapshot),index=1,total=1,data=snapshot}}
        end}
        App.station({computer=108,node='capital',hq='hq',monitor='monitor_14',sensorsConfigured=true,
            radars={'radar'},namespace='radar-capital',dimension='minecraft:overworld'},wire,'/station')
        eq(native.rows[2],external.rows[2]);eq(native.rows[4],external.rows[4])
        assert(external.rows[4]:find('SUPER-DRAGONFLY-LG1',1,true))
        assert(external.rows[20]:find('PC 108 | monitor_14 | Updated',1,true))
        assert(native.rows[20]:find('monitor_14: updated | frame 2',1,true))
        local observed=false
        for _,body in ipairs(sent) do if body.op=='observations' and #body.items>0 then observed=true end end
        assert(observed)
    end)

    local function withTerminal(inputs,body)
        local old={term=term,print=print,write=write,read=read,pagedPrint=textutils.pagedPrint}
        local state={frames={},details={},lines={},row=1,input=0}
        local function output(value)
            value=tostring(value)
            state.lines[#state.lines+1]=value
            state.row=state.row+math.max(1,math.ceil(#value/51))
        end
        term={getSize=function() return 51,19 end,
            clear=function() state.lines={};state.row=1 end,
            setCursorPos=function(_,y) state.row=y end,write=output}
        print=function(value) output(value or '') end
        write=function(value) state.lines[#state.lines+1]=tostring(value) end
        read=function()
            state.frames[#state.frames+1]={text=table.concat(state.lines,'\n'),row=state.row}
            state.input=state.input+1
            local input=inputs[state.input]
            assert(input~=nil,'UI requested unexpected input '..state.input)
            if type(input)=='function' then return input() end
            return input
        end
        textutils.pagedPrint=function(value) state.details[#state.details+1]=value end
        local ok,result=pcall(body,state)
        term=old.term;print=old.print;write=old.write;read=old.read;textutils.pagedPrint=old.pagedPrint
        assert(ok,result)
        return result,state
    end

    check('Contact browser fits a standard terminal and keeps numbers stable during updates',function(m)
        local tracker=contactsFixture(m,14)
        local result,state=withTerminal({function()
            local c=U.copy(tracker.contacts['ship:radar-capital:ship-01'])
            c.id='000-new';c.sensorKey='ship:radar-capital:000-new';tracker.contacts[c.sensorKey]=c
            return 'n'
        end,'8'},function() return ContactUI.browse(tracker,{}, {},true) end)
        eq(result,'ship:radar-capital:ship-08')
        assert(state.frames[2].text:find('Page 2/3',1,true))
        assert(state.frames[2].text:find('8. ship-08',1,true))
        for _,frame in ipairs(state.frames) do assert(frame.row<=19,'Contact page overflowed terminal') end
    end)
    check('Contact browser refresh deliberately rebuilds numbered choices',function(m)
        local tracker=contactsFixture(m,8)
        local result=withTerminal({function()
            local c=U.copy(tracker.contacts['ship:radar-capital:ship-01'])
            c.id='000-new';c.sensorKey='ship:radar-capital:000-new';tracker.contacts[c.sensorKey]=c
            return 'r'
        end,'1'},function() return ContactUI.browse(tracker,{}, {},true) end)
        eq(result,'ship:radar-capital:000-new')
    end)
    check('Contact browser supports previous page and rejects off-page numbers',function(m)
        local tracker=contactsFixture(m,14)
        local result=withTerminal({'n','p','2'},function() return ContactUI.browse(tracker,{}, {},true) end)
        eq(result,'ship:radar-capital:ship-02')
        local cancelled,state=withTerminal({'10','','q'},function() return ContactUI.browse(tracker,{}, {},true) end)
        eq(cancelled,nil);eq(#state.details,0)
    end)
    check('Contact selection rejects a ship lost while the user is choosing',function(m)
        local tracker=contactsFixture(m,1)
        local result,state=withTerminal({function() m.time=m.time+20001;return '1' end,'','q'},
            function() return ContactUI.browse(tracker,{}, {},true) end)
        eq(result,nil);eq(#state.details,0)
    end)
    check('Contact details retain the full sensor key with paged output',function(m)
        local tracker=contactsFixture(m,1)
        local original=tracker.contacts['ship:radar-capital:ship-01']
        tracker.contacts={}
        original.id='62f3e71a-c996-41b1-beaf-e371e25f6b69'
        original.sensorKey='ship:radar-capital:'..original.id
        tracker.contacts[original.sensorKey]=original
        local _,state=withTerminal({'1','','q'},function() ContactUI.browse(tracker,{}, {},false) end)
        assert(state.details[1]:find('Bind key: '..original.sensorKey,1,true))
    end)
    check('Registered contact labels use the approved vessel name',function()
        local contact={id='raw-uuid',subject='vessel:ARD-0001',name='Untrusted broadcast'}
        local db={vessels={['ARD-0001']={name='First Vessel'}}}
        eq(ContactUI.label(contact,db),'First Vessel [ARD-0001]')
        eq(ContactUI.label({id='unknown-uuid'},db),'unknown-uuid')
    end)
    check('HQ binding selects the exact numbered ship without copying its key',function(m)
        local tracker=contactsFixture(m,3)
        local requests={}
        local request=function(q) requests[#requests+1]=q;return {ok=true} end
        withTerminal({'5','2','ARD-0001','1440','','q'},function()
            UI.headquarters(request,tracker,'/hq',{}, {db={vessels={}}})
        end)
        eq(#requests,1);eq(requests[1].op,'bind')
        eq(requests[1].sensorKey,'ship:radar-capital:ship-02')
        eq(requests[1].registration,'ARD-0001');eq(requests[1].minutes,1440)
    end)
    check('HQ binding defaults to 365 real days and explains the minute units', function(m)
        local tracker = contactsFixture(m, 1)
        local requests = {}
        local _, state = withTerminal({'5', '1', 'ARD-0001', '', '', 'q'}, function()
            UI.headquarters(function(q)
                requests[#requests + 1] = q
                return {ok = true}
            end, tracker, '/hq', {}, {db = {vessels = {}}})
        end)
        eq(#requests, 1)
        eq(requests[1].minutes, 525600)
        assert(state.frames[4].text:find('real time, up to 365 days', 1, true))
        assert(state.frames[4].text:find('365 days = 525600 min.', 1, true))
    end)
    check('HQ binding rechecks freshness after registration entry',function(m)
        local tracker=contactsFixture(m,1)
        local requests=0
        withTerminal({'5','1','ARD-0001',function() m.time=m.time+20001;return '1440' end,'','q'},function()
            UI.headquarters(function() requests=requests+1;return {ok=true} end,
                tracker,'/hq',{}, {db={vessels={}}})
        end)
        eq(requests,0)
    end)
    check('Cancelling the HQ contact picker returns without a binding request',function(m)
        local requests=0
        withTerminal({'5','q','q'},function()
            UI.headquarters(function() requests=requests+1;return {ok=true} end,
                contactsFixture(m,1),'/hq',{}, {db={vessels={}}})
        end)
        eq(requests,0)
    end)

    check('Dimension IDs support namespaced paths and reject malformed values',function()
        assert(U.dimension('minecraft:overworld')); assert(U.dimension('custom:worlds/air'))
        assert(not U.dimension('overworld')); assert(not U.dimension('custom:bad world'))
        assert(not U.dimension('custom:world|packet'))
        local db,c,z=dbFixture();z.dimension='custom:worlds/air';assert(Policy.validateZone(z))
    end)
    check('SHA256 empty',function() eq(C.sha256(''),'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') end)
    check('SHA256 abc',function() eq(C.sha256('abc'),'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') end)
    check('SHA256 multiple blocks',function()
        eq(C.sha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),'248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
    end)
    check('HMAC RFC4231 case 1',function() eq(C.hmac(string.rep('\11',20),'Hi There'),'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7') end)
    check('HMAC RFC4231 case 2',function() eq(C.hmac('Jefe','what do ya want for nothing?'),'5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843') end)
    check('HMAC RFC4231 long key',function()
        eq(C.hmac(string.rep('\170',131),'Test Using Larger Than Block-Size Key - Hash Key First'),'60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54')
    end)
    check('ChaCha20 RFC8439 block',function()
        local key=C.unhex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')
        local nonce=C.unhex('000000090000004a00000000')
        eq(C.hex(C.chachaBlock(key,nonce,1)),
            '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e')
    end)
    check('ChaCha20 RFC8439 encryption',function()
        local key=C.unhex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')
        local nonce=C.unhex('000000000000004a00000000')
        local text="Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
        eq(C.hex(C.chacha(key,nonce,text)),
            '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d')
        eq(C.chacha(key,nonce,C.chacha(key,nonce,text)),text)
    end)
    check('Tag comparison and hex validation',function()
        assert(C.equal('abc','abc'));assert(not C.equal('abc','abd'));assert(not C.equal('a','aa'));bad(function() C.unhex('xz') end)
    end)
    check('Encrypted authenticated round trip',function()
        local a,b=pair();local packet=a:encode('hq',{op='secret-position',x=123})
        assert(not packet:find('secret-position',1,true))
        local message=assert(b:decode(11,packet));eq(message.body.x,123);eq(message.role,'station')
    end)
    check('Spoofed computer ID rejected',function() local a,b=pair();assert(not b:decode(99,a:encode('hq',{x=1}))) end)
    check('Tampered packet rejected',function()
        local a,b=pair();local p=a:encode('hq',{x=1});local last=p:sub(-1)=='0' and '1' or '0'
        assert(not b:decode(11,p:sub(1,-2)..last))
    end)
    check('Bad MAC does not consume sequence',function()
        local a,b=pair();local p=a:encode('hq',{x=1})
        assert(not b:decode(11,p:sub(1,-65)..string.rep('0',64)));assert(b:decode(11,p))
    end)
    check('Replay rejected',function() local a,b=pair();local p=a:encode('hq',{x=1});assert(b:decode(11,p));local m,e=b:decode(11,p);eq(m,nil);eq(e,'replay') end)
    check('Replay rejected after receiver restart',function()
        local a,b,_,bc=pair();local p=a:encode('hq',{x=1});assert(b:decode(11,p));b=Wire.new(bc,'/b');assert(not b:decode(11,p))
    end)
    check('Sender restart skips reserved nonces',function()
        local a,b,ac=pair();local p,seq=a:encode('hq',{x=1});assert(b:decode(11,p))
        a=Wire.new(ac,'/a');local p2,seq2=a:encode('hq',{x=2});assert(seq2>seq+100);assert(b:decode(11,p2))
    end)
    check('Out-of-order older packet rejected',function()
        local a,b=pair();local p1=a:encode('hq',{x=1});local p2=a:encode('hq',{x=2});assert(b:decode(11,p2));assert(not b:decode(11,p1))
    end)
    check('Reflection rejected; reverse direction valid',function()
        local a,b=pair();local p=a:encode('hq',{x=1});assert(not a:decode(10,p));assert(a:decode(10,b:encode('station',{x=2})))
    end)
    check('Expired packet rejected',function(m) local a,b=pair();local p=a:encode('hq',{x=1});m.time=m.time+31000;assert(not b:decode(11,p)) end)
    check('Future packet rejected',function(m) local a,b=pair();local p=a:encode('hq',{x=1});m.time=m.time-31000;assert(not b:decode(11,p)) end)
    check('Other realm rejected',function()
        local a,b=pair();local p=a:encode('hq',{x=1});b.config.realm='other';assert(not b:decode(11,p))
    end)
    check('Revoked peer rejected',function() local a,b=pair();local p=a:encode('hq',{x=1});b.config.peers.station.revoked=true;assert(not b:decode(11,p)) end)
    check('Different pairwise key rejected',function() local a,b=pair();b.config.peers.station.key=string.rep('34',32);assert(not b:decode(11,a:encode('hq',{x=1}))) end)
    check('Oversized and non-string packets rejected',function()
        local _,b=pair();assert(not b:decode(11,{}));assert(not b:decode(11,string.rep('x',25001)))
    end)
    check('Oversized plaintext refused',function() local a=pair();bad(function() a:encode('hq',{value=string.rep('x',12001)}) end) end)
    check('Missing security state fails closed',function() bad(function() Wire.new({realm='r',node='n'},'/missing') end) end)
    check('Store round trip',function() Store.save('/test.json',{a=1,b='value'});eq(Store.load('/test.json').a,1) end)
    check('Corrupt store fails closed',function(m)
        Store.save('/test.json',{a=1});m.files['/test.json']=m.files['/test.json']:gsub('value','value')..'X';bad(function() Store.load('/test.json') end)
    end)
    check('Interrupted write fails closed',function(m) Store.save('/test.json',{a=1});m.files['/test.json.new']='partial';bad(function() Store.load('/test.json') end) end)
    check('Missing primary never silently restores backup',function(m)
        Store.save('/test.json',{a=1});Store.save('/test.json',{a=2});m.files['/test.json']=nil;bad(function() Store.load('/test.json',{}) end)
    end)
    check('Unrestricted accepts unknown',function() local db,c,z=dbFixture();z.class='unrestricted';assert(not Policy.evaluate(db,c,U.now()).violation) end)
    check('Controlled rejects unknown',function() local db,c=dbFixture();assert(Policy.evaluate(db,c,U.now()).violation) end)
    check('Controlled accepts observed bound registration',function() local db,c=dbFixture();registered(db,c);assert(not Policy.evaluate(db,c,U.now()).violation) end)
    check('Claimed UUID and friendly nation grant nothing',function()
        local db,c=dbFixture();db.vessels['ARD-0001']={status='active',claimedUuid='craft'};c.nation='Ardennes';c.claimedUuid='craft';assert(Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Restricted needs explicit permit',function() local db,c,z=dbFixture();registered(db,c);z.class='restricted';assert(Policy.evaluate(db,c,U.now()).violation) end)
    check('Prohibited needs explicit permit',function() local db,c,z=dbFixture();registered(db,c);z.class='prohibited';assert(Policy.evaluate(db,c,U.now()).violation) end)
    check('Valid zone-specific permit accepted',function()
        local db,c,z=dbFixture();registered(db,c);z.class='restricted'
        db.permits.P={id='P',subject='vessel:ARD-0001',zone='test',starts=U.now()-1,expires=U.now()+10}
        assert(not Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Permit expiration exact boundary',function()
        local db,c,z=dbFixture();registered(db,c);z.class='restricted'
        db.permits.P={id='P',subject='vessel:ARD-0001',zone='test',starts=U.now()-1,expires=U.now()}
        assert(Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Future and revoked permits rejected',function()
        local db,c,z=dbFixture();registered(db,c);z.class='restricted'
        db.permits.P={id='P',subject='vessel:ARD-0001',zone='test',starts=U.now()+1,expires=U.now()+100}
        assert(Policy.evaluate(db,c,U.now()).violation)
        db.permits.P.starts=U.now()-1;db.permits.P.revoked=true;assert(Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Suspension overrides permit',function()
        local db,c,z=dbFixture();registered(db,c);z.class='restricted';db.vessels['ARD-0001'].status='suspended'
        db.permits.P={id='P',subject='vessel:ARD-0001',zone='test',starts=U.now()-1,expires=U.now()+100}
        assert(Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Expired radar binding grants nothing',function()
        local db,c=dbFixture();registered(db,c);db.bindings[c.sensorKey].expires=U.now();assert(Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Overlap exemption is not global',function()
        local db,c,z=dbFixture();registered(db,c);z.class='restricted'
        db.zones.other=U.copy(z);db.zones.other.id='other';db.zones.other.class='prohibited'
        db.permits.P={id='P',subject='vessel:ARD-0001',zone='other',starts=U.now()-1,expires=U.now()+100}
        local d=Policy.evaluate(db,c,U.now());assert(d.violation);eq(d.zone,'test')
    end)
    check('Wrong dimension ignored',function() local db,c=dbFixture();c.dimension='minecraft:the_nether';assert(not Policy.evaluate(db,c,U.now()).violation) end)
    check('Ships-only zones exclude ground players',function() local db,c=dbFixture();c.kind='player';assert(not Policy.evaluate(db,c,U.now()).violation) end)
    check('Player UUID identifies registered player',function()
        local db,c,z=dbFixture();z.applies='players';c.kind='player';c.id='12345678-1234-1234-1234-123456789abc';db.players[c.id]={status='active'}
        assert(not Policy.evaluate(db,c,U.now()).violation)
    end)
    check('Zone boundaries inclusive',function() local db,c,z=dbFixture();c.x=0;c.y=100;assert(Policy.contains(z,c));c.y=100.01;assert(not Policy.contains(z,c)) end)
    check('Invalid zone rejected',function() local _,_,z=dbFixture();z.maxX=-1;assert(not Policy.validateZone(z)) end)
    check('Fast box crossing detected',function() local _,c,z=dbFixture();local a=U.copy(c);a.x=-100;c.x=200;assert(Policy.intersects(z,a,c)) end)
    check('High path outside altitude band rejected',function() local _,c,z=dbFixture();local a=U.copy(c);a.x=-100;c.x=200;a.y=200;c.y=200;assert(not Policy.intersects(z,a,c)) end)
    check('Cylinder crossing and miss',function()
        local _,c,z=dbFixture();z.shape='cylinder';z.x=50;z.z=50;z.radius=20
        local a=U.copy(c);a.x=0;c.x=100;assert(Policy.intersects(z,a,c));a.z=100;c.z=100;assert(not Policy.intersects(z,a,c))
    end)
    check('Repeated sensor scan does not refresh contact',function(m)
        local db,c=dbFixture();local t=Tracker.new();assert(t:ingest(c,db,m.time));m.time=m.time+1000;assert(not t:ingest(c,db,m.time));eq(t.contacts[c.sensorKey].time,c.time)
    end)
    check('Known multi-station track avoids duplicate acquisition',function(m)
        local db,c=dbFixture();registered(db,c);local events={};local t=Tracker.new(function(e) events[#events+1]=e end)
        assert(t:ingest(c,db,m.time));local second=U.copy(c);second.source='two';assert(t:ingest(second,db,m.time))
        eq(U.count(t.contacts),1);local n=0;for _,e in ipairs(events) do if e.event=='acquired' then n=n+1 end end;eq(n,1)
    end)
    check('Contact loss is not an exit',function(m)
        local db,c=dbFixture();local events={};local t=Tracker.new(function(e) events[#events+1]=e end)
        t:ingest(c,db,m.time);t:refresh(db,m.time+20001);eq(U.count(t.contacts),0)
        local lost=false;for _,e in ipairs(events) do assert(e.event~='zone_exit');if e.event=='lost' then lost=true end end;assert(lost)
    end)
    check('Crossing logged as estimate',function(m)
        local db,c=dbFixture();c.x=-10;local events={};local t=Tracker.new(function(e) events[#events+1]=e end)
        t:ingest(c,db,m.time);local next=U.copy(c);next.x=110;next.time=next.time+1000;t:ingest(next,db,next.time)
        local found=false;for _,e in ipairs(events) do if e.event=='estimated_crossing' then found=true end end;assert(found)
    end)
    check('Kiosk cannot approve applications or edit zones',function()
        local s=Service.new({peers={}},'/hq');assert(not s:execute('kiosk','kiosk',{op='approve',request='q',id='x'}).ok)
        assert(not s:execute('kiosk','kiosk',{op='zone',request='q',zone={}}).ok)
    end)
    check('Registrar cannot view permissions or edit zones',function()
        local s=Service.new({peers={}},'/hq');assert(not s:execute('desk','registrar',{op='list',collection='permits'}).ok)
        assert(not s:execute('desk','registrar',{op='zone',request='q',zone={}}).ok)
    end)
    check('Station cannot register vessels',function() local s=Service.new({peers={}},'/hq');assert(not s:execute('station','station',fields('create_vessel')).ok) end)
    check('HQ accepts binding lifetimes from one minute through exactly 365 days', function(m)
        local service, contact = bindingFixture()
        eq(Service.MAX_BINDING_MINUTES, 525600)
        for index, minutes in ipairs({1, 10080, 10081, 525600}) do
            local result = service:execute('hq-console', 'local_admin', {
                op = 'bind', request = 'duration-'..index, sensorKey = contact.sensorKey,
                registration = 'ARD-0001', minutes = minutes
            })
            assert(result.ok, result.error)
            eq(service.db.bindings[contact.sensorKey].expires, m.time + minutes * 60000)
        end
    end)
    check('Invalid or over-one-year binding lifetimes do not change stored state', function()
        local service, contact = bindingFixture()
        local original = U.read('/hq/database.json')
        local cases = {
            {name = 'over-limit', value = 525601},
            {name = 'zero', value = 0},
            {name = 'negative', value = -1},
            {name = 'fraction', value = 1.5},
            {name = 'text', value = '525600'},
            {name = 'missing'},
            {name = 'nan', value = 0 / 0},
            {name = 'infinity', value = math.huge}
        }
        for _, case in ipairs(cases) do
            local result = service:execute('hq-console', 'local_admin', {
                op = 'bind', request = 'invalid-'..case.name, sensorKey = contact.sensorKey,
                registration = 'ARD-0001', minutes = case.value
            })
            assert(not result.ok, case.name..' was accepted')
            assert(result.error:find('365 days maximum', 1, true))
            eq(U.read('/hq/database.json'), original)
            eq(U.count(service.db.bindings), 0)
            eq(service.db.revision, 1)
        end
    end)
    check('Year-long bindings survive restart and station storage and expire at the exact UTC boundary', function(m)
        local service, contact = bindingFixture()
        local result = service:execute('hq-console', 'local_admin', {
            op = 'bind', request = 'year-binding', sensorKey = contact.sensorKey,
            registration = 'ARD-0001', minutes = 525600
        })
        assert(result.ok, result.error)
        local expiry = m.time + 31536000000
        m.time = m.time + 8 * 24 * 60 * 60000
        local restarted = Service.new({peers = {}}, '/hq')
        eq(restarted.db.bindings[contact.sensorKey].expires, expiry)
        Store.save('/station/policy.json', Policy.snapshot(restarted.db, m.time))
        local cached = Store.load('/station/policy.json')
        eq(cached.bindings[contact.sensorKey].expires, expiry)
        assert(not Policy.evaluate(cached, contact, m.time).violation)
        assert(not Policy.evaluate(cached, contact, expiry - 1).violation)
        assert(Policy.evaluate(cached, contact, expiry).violation)
        assert(Policy.evaluate(cached, contact, expiry + 1).violation)
    end)
    check('Renewal starts a fresh year while retrying the same request does not extend it', function(m)
        local service, contact = bindingFixture()
        assert(service:execute('hq-console', 'local_admin', {
            op = 'bind', request = 'old-binding', sensorKey = contact.sensorKey,
            registration = 'ARD-0001', minutes = 1440
        }).ok)
        m.time = m.time + 60000
        local renewal = {
            op = 'bind', request = 'renew-binding', sensorKey = contact.sensorKey,
            registration = 'ARD-0001', minutes = 525600
        }
        assert(service:execute('hq-console', 'local_admin', renewal).ok)
        local expiry = m.time + 31536000000
        local revision = service.db.revision
        m.time = m.time + 60000
        assert(service:execute('hq-console', 'local_admin', renewal).ok)
        eq(service.db.bindings[contact.sensorKey].expires, expiry)
        eq(service.db.revision, revision)
    end)
    check('A year-long binding cannot be reassigned until it is explicitly removed', function()
        local service, contact = bindingFixture()
        service.db.vessels['ARD-0002'] = {name = 'Other craft', status = 'active'}
        assert(service:execute('hq-console', 'local_admin', {
            op = 'bind', request = 'first-owner', sensorKey = contact.sensorKey,
            registration = 'ARD-0001', minutes = 525600
        }).ok)
        local replacement = {
            op = 'bind', request = 'other-owner', sensorKey = contact.sensorKey,
            registration = 'ARD-0002', minutes = 525600
        }
        assert(not service:execute('hq-console', 'local_admin', replacement).ok)
        eq(service.db.bindings[contact.sensorKey].registration, 'ARD-0001')
        assert(service:execute('hq-console', 'local_admin', {
            op = 'unbind', request = 'remove-binding', sensorKey = contact.sensorKey
        }).ok)
        eq(U.count(service.db.bindings), 0)
        assert(service:execute('hq-console', 'local_admin', replacement).ok)
        eq(service.db.bindings[contact.sensorKey].registration, 'ARD-0002')
    end)
    check('Loading an existing short binding preserves its original expiry', function(m)
        local service, contact = bindingFixture()
        service.db.bindings[contact.sensorKey] = {
            registration = 'ARD-0001', expires = m.time + 60000, by = 'hq-console'
        }
        Store.save('/hq/database.json', service.db)
        local original = U.read('/hq/database.json')
        local restarted = Service.new({peers = {}}, '/hq')
        eq(restarted.db.bindings[contact.sensorKey].expires, m.time + 60000)
        eq(U.read('/hq/database.json'), original)
        assert(Policy.evaluate(restarted.db, contact, m.time + 60000).violation)
    end)
    check('The extended binding limit does not extend pilot approvals or zone permits', function()
        local service = bindingFixture()
        local pilot = {
            op = 'authorize_pilot', request = 'long-pilot',
            uuid = '12345678-1234-1234-1234-123456789abc', username = 'Pilot',
            registration = 'ARD-0001', minutes = 10081
        }
        assert(not service:execute('hq-console', 'local_admin', pilot).ok)
        pilot.request = 'valid-pilot'; pilot.minutes = 10080
        assert(service:execute('hq-console', 'local_admin', pilot).ok)
        local permit = {
            op = 'permit', request = 'long-permit', subject = 'vessel:ARD-0001',
            zone = 'test', minutes = 43201
        }
        assert(not service:execute('hq-console', 'local_admin', permit).ok)
        permit.request = 'valid-permit'; permit.minutes = 43200
        assert(service:execute('hq-console', 'local_admin', permit).ok)
    end)
    check('Application, approval and idempotent retry',function()
        local s=Service.new({peers={}},'/hq');local q=fields('apply')
        local first=s:execute('kiosk','kiosk',q);assert(first.ok);eq(first.application,'APP-000001')
        local again=s:execute('kiosk','kiosk',q);eq(first.application,again.application);eq(U.count(s.db.applications),1)
        local approved=s:execute('hq-console','local_admin',{op='approve',request='approve-1',id=first.application})
        assert(approved.ok);eq(approved.registration,'ARD-0001');eq(U.count(s.db.bindings),0)
    end)
    check('Kiosk cannot inspect another kiosk receipt',function(m)
        local s=Service.new({peers={}},'/hq');local r=s:execute('one','kiosk',fields('apply'));assert(r.ok)
        assert(not s:execute('two','kiosk',{op='application_status',id=r.application}).ok)
    end)
    check('Malformed registration rejected',function()
        local s=Service.new({peers={}},'/hq');local q=fields('apply');q.name='a\nb';assert(not s:execute('one','kiosk',q).ok)
    end)
    check('Peer revocation survives HQ restart',function()
        local cfg={peers={one={role='station'}}};local s=Service.new(cfg,'/hq')
        assert(s:execute('hq-console','local_admin',{op='revoke_peer',peer='one',request='revoke-1'}).ok)
        assert(cfg.peers.one.revoked);cfg.peers.one.revoked=false;Service.new(cfg,'/hq');assert(cfg.peers.one.revoked)
    end)
    check('Policy snapshots contain no endpoint secrets',function()
        local db=Service.empty();db.disabledPeers.secret=true;db.receipts.test={secret='hidden'}
        local snap=Policy.snapshot(db,U.now());assert(not snap.disabledPeers and not snap.receipts and not snap.peers)
    end)
    check('Observation source and namespace cannot be supplied by packet',function(m)
        local peer={namespace='trusted',dimension='minecraft:overworld'}
        local raw={kind='ship',id='v',namespace='forged',source='hq',dimension=peer.dimension,x=0,y=0,z=0,time=m.time}
        local o=assert(App.acceptedObservation(raw,peer,'station-one',m.time));eq(o.source,'station-one');eq(o.namespace,'trusted')
    end)
    check('Stale, out-of-world and wrong-dimension observations rejected',function(m)
        local peer={namespace='trusted',dimension='minecraft:overworld'}
        local raw={kind='ship',id='v',dimension=peer.dimension,x=0,y=0,z=0,time=m.time-20001}
        assert(not App.acceptedObservation(raw,peer,'s',m.time));raw.time=m.time;raw.x=math.huge
        assert(not App.acceptedObservation(raw,peer,'s',m.time));raw.x=0;raw.dimension='minecraft:the_nether';assert(not App.acceptedObservation(raw,peer,'s',m.time))
    end)
    check('Radar warm-up rejects cached initial contacts',function(m)
        m.devices.radar={getTracks=function() return {{id='v',position={x=0,y=50,z=0},scannedTime=1,entityType=''}} end}
        local s=Sensors.new({radars={'radar'},namespace='radar-one',node='one',dimension='minecraft:overworld'})
        eq(#s:scan(),0)
    end)
    check('Advancing radar scan accepted; stale token expires',function(m)
        local token=1;m.devices.radar={getTracks=function() return {{id='v',position={x=0,y=50,z=0},scannedTime=token,entityType=''}} end}
        local s=Sensors.new({radars={'radar'},namespace='radar-one',node='one',dimension='minecraft:overworld'})
        eq(#s:scan(),0);token=2;m.time=m.time+1000;eq(#s:scan(),1);m.time=m.time+16000;eq(#s:scan(),0)
    end)
    check('Missing radar scan token refused',function(m)
        m.devices.radar={getTracks=function() return {{id='v',position={x=0,y=50,z=0}}} end}
        local s=Sensors.new({radars={'radar'},namespace='n',node='s',dimension='minecraft:overworld'})
        s:scan();m.time=m.time+1000;eq(#s:scan(),0)
    end)
    check('Sable ship type survives warm-up and expires without a fresh scan',function(m)
        local token=273289751
        m.devices.radar={getTracks=function() return {{id='62f3e71a-c996-41b1-beaf-e371e25f6b69',
            position={x=10,y=79,z=20},scannedTime=token,entityType='Sable:ship',category='SABLE'}} end}
        local scanner=Sensors.new({radars={'radar'},namespace='radar-one',node='one',dimension='minecraft:overworld'})
        eq(#scanner:scan(),0)
        token=token+20;m.time=m.time+1000
        local rows,errors=scanner:scan()
        eq(#rows,1);eq(U.count(errors),0);eq(rows[1].kind,'ship')
        eq(rows[1].id,'62f3e71a-c996-41b1-beaf-e371e25f6b69')
        m.time=m.time+15001;eq(#scanner:scan(),0)
    end)
    check('Mixed radar response imports seven ships and excludes players and contraptions',function(m)
        local token=273289796
        m.devices.radar={getTracks=function()
            local tracks={}
            for i=1,7 do tracks[#tracks+1]={id='ship-'..i,position={x=i,y=80,z=0},
                scannedTime=token,entityType='Sable:ship',category='SABLE'} end
            for i=1,2 do tracks[#tracks+1]={id='player-'..i,position={x=i,y=80,z=0},
                scannedTime=token,entityType='entity.minecraft.player',category='PLAYER'} end
            for i=1,3 do tracks[#tracks+1]={id='contraption-'..i,position={x=i,y=80,z=0},
                scannedTime=token,entityType='entity.create.stationary_contraption',category='CONTRAPTION'} end
            return tracks
        end}
        local scanner=Sensors.new({radars={'radar'},namespace='n',node='s',dimension='minecraft:overworld'})
        eq(#scanner:scan(),0);token=token+20;m.time=m.time+1000
        local rows=scanner:scan();eq(#rows,7)
        for _,row in ipairs(rows) do assert(row.id:match('^ship%-')) end
    end)
    check('Radar category exclusions override empty or conflicting entity types',function()
        for _,category in ipairs({'PLAYER','ENTITY','CONTRAPTION'}) do
            assert(not Sensors.isShipTrack({category=category,entityType=''}))
            assert(not Sensors.isShipTrack({category=category,entityType='Sable:ship'}))
        end
        assert(Sensors.isShipTrack({category='SABLE',entityType='Sable:ship'}))
        assert(Sensors.isShipTrack({entityType='Sable:ship'}))
        assert(Sensors.isShipTrack({entityType=''}));assert(Sensors.isShipTrack({}))
        assert(not Sensors.isShipTrack({category='SABLE',entityType=123}))
        assert(not Sensors.isShipTrack({category='SABLE',entityType='entity.minecraft.player'}))
    end)
    check('Sable contacts retain configured coverage and scan-token checks',function(m)
        local token=1
        local track={id='ship',position={x=101,y=0,z=0},category='SABLE',entityType='Sable:ship'}
        m.devices.radar={getTracks=function() track.scannedTime=token;return {track} end}
        local scanner=Sensors.new({radars={'radar'},namespace='n',node='s',dimension='minecraft:overworld',
            coverage={x=0,y=0,z=0,radius=100}})
        scanner:scan();token=2;m.time=m.time+1000;eq(#scanner:scan(),0)
        track.position.x=99;token=3;m.time=m.time+1000;eq(#scanner:scan(),1)
        token=nil;local rows,errors=scanner:scan();eq(#rows,0);assert(errors.radar)
    end)
    check('AP detailed getPlayer supplies the dimension for validation',function(m)
        local requested=false
        m.devices.detector={getPlayersInRange=function() return {'Pilot'} end,getPlayer=function(name,detailed)
            requested=detailed==true
            return {uuid='12345678-1234-1234-1234-123456789abc',name=name,x=1,y=65,z=2,
                dimension=detailed and 'minecraft:overworld' or nil}
        end}
        local scanner=Sensors.new({playerDetector='detector',node='s',dimension='minecraft:overworld'})
        local rows,errors=scanner:scan();assert(requested);eq(#rows,1);eq(U.count(errors),0)
    end)
    check('Peripheral returned errors remain available to sensor diagnostics',function(m)
        local value,message=U.safeCall({read=function() return nil,'Peripheral range exceeded' end},'read')
        eq(value,nil);eq(message,'Peripheral range exceeded')
        m.devices.detector={getPlayersInRange=function() return {'Pilot'} end,
            getPlayer=function() return nil,'Player API unavailable' end}
        local scanner=Sensors.new({playerDetector='detector',node='s',dimension='minecraft:overworld'})
        local rows,errors=scanner:scan();eq(#rows,0);eq(errors.detector,'Player API unavailable')
    end)
    check('Station diagnostics show sensor errors without endpoint keys',function(m)
        local oldId,oldSublevel=os.getComputerID,sublevel
        local ok,err=pcall(function()
            os.getComputerID=function() return 108 end
            sublevel={getUniqueId=function() error('This computer is not on a Sub-Level!') end}
            local secret=string.rep('44',32)
            U.write('/aacs/config.json',U.json({schema=1,realm='test-realm',node='station',role='station',
                computer=108,dimension='minecraft:overworld',hq='hq',radars={'missing-radar'},
                peers={hq={role='hq',computer=112,key=secret}}}))
            App.diagnose()
            local report=U.read('/aacs/diagnostics.txt')
            assert(report:find('Sensor error [missing-radar]: Missing getTracks',1,true))
            assert(report:find('Optional onboard beacon:',1,true))
            assert(not report:find(secret,1,true))
        end)
        os.getComputerID=oldId;sublevel=oldSublevel
        assert(ok,err)
    end)
    check('AP getPlayerPos and UUID path works',function(m)
        m.devices.detector={getPlayersInRange=function() return {'Pilot'} end,getPlayerPos=function()
            return {uuid='12345678-1234-1234-1234-123456789abc',name='Pilot',dimension='minecraft:overworld',x=1,y=65,z=2}
        end}
        local s=Sensors.new({playerDetector='detector',node='s',dimension='minecraft:overworld'});local rows=s:scan();eq(#rows,1);eq(rows[1].kind,'player')
    end)
    check('AP getPlayer path works and missing UUID refused',function(m)
        local valid=true;m.devices.detector={getPlayersInRange=function() return {'Pilot'} end,getPlayer=function()
            return {uuid=valid and '12345678-1234-1234-1234-123456789abc' or nil,name='Pilot',dimension='minecraft:overworld',x=1,y=65,z=2}
        end}
        local s=Sensors.new({playerDetector='detector',node='s',dimension='minecraft:overworld'});eq(#s:scan(),1);valid=false;eq(#s:scan(),0)
    end)
    check('Report export preserves rows and escapes spreadsheet formulas',function(m)
        Store.log('/hq/events.jsonl',{time=m.time,event='violation',key='ship:s:v',subject='vessel:ARD-0001',zone='test',reason='=danger',contact={x=1,y=2,z=3,source='s'}})
        local r=Reports.export('/hq',{subject='vessel:ARD-0001'});eq(r.rows,1);assert(m.files[r.csv]:find("'=danger",1,true));assert(m.files[r.text]:find('Matched rows: 1',1,true))
    end)
    check('Printer starts page before requesting geometry and paginates',function(m)
        local active=false;local pages=0
        m.devices.printer={_type='printer',newPage=function() active=true;return true end,
            getPageSize=function() assert(active,'No page');return 25,21 end,
            setPageTitle=function() assert(active) end,setCursorPos=function(x,y) assert(x>=1 and y<=21) end,
            write=function(s) assert(#s<=25) end,endPage=function() active=false;pages=pages+1;return true end}
        U.write('/report.txt',string.rep('A long report line that needs wrapping\n',35))
        assert(Reports.printFile('/report.txt'));assert(pages>=3)
    end)
    check('Printer missing consumables returns actionable failure',function(m)
        m.devices.printer={_type='printer',newPage=function() return false end}
        local ok,message=Reports.printFile('/unused');eq(ok,false);assert(message:find('paper/ink',1,true))
    end)
    check('Alarm and fault outputs are separate',function(m)
        App.outputs({alarmSide='left',faultSide='right'},true,false);eq(m.outputs.left,true);eq(m.outputs.right,false)
        App.outputs({alarmSide='left',faultSide='right'},false,false);eq(m.outputs.left,false)
    end)

    check('Binding update retains contact even without a fresh scan',function(m)
        local db,c=dbFixture();local t=Tracker.new();t:ingest(c,db,m.time)
        registered(db,c);assert(t:ingest(c,db,m.time));eq(U.count(t.contacts),1)
        assert(t.contacts['vessel:ARD-0001']);assert(not t.contacts[c.sensorKey])
    end)
    check('Visit report pairs entry/exit and leaves lost visits incomplete',function(m)
        for _,e in ipairs({
            {event='zone_enter',time=m.time,key='v',subject='vessel:ARD-0001',zone='z'},
            {event='zone_exit',time=m.time+60000,key='v',subject='vessel:ARD-0001',zone='z'},
            {event='zone_enter',time=m.time+70000,key='v',subject='vessel:ARD-0001',zone='z'},
            {event='lost',time=m.time+80000,key='v',subject='vessel:ARD-0001'},
        }) do Store.log('/hq/events.jsonl',e) end
        m.time=m.time+90000
        local r=Reports.export('/hq',{})
        assert(m.files[r.visits]:match('"60%.?0*"'),m.files[r.visits])
        assert(m.files[r.visits]:find('exit time and duration unknown',1,true))
    end)
    check('Station event loop applies policy, observes radar and raises alarm',function(m)
        local db=Service.empty()
        db.zones.test={id='test',name='test',class='controlled',dimension='minecraft:overworld',
            applies='ships',shape='box',minX=-10,maxX=10,minZ=-10,maxZ=10,minY=0,maxY=100}
        local snapshot=U.json(Policy.snapshot(db,m.time))
        local token=1
        m.devices.radar={getTracks=function() return {{id='plane',position={x=0,y=50,z=0},scannedTime=token,entityType=''}} end}
        local events={
            {'timer',1},
            {'rednet_message',10,'packet',Wire.PROTOCOL},
            {'timer',2,before=function() m.time=m.time+2000;token=2 end},
            {'char','q'},
        }
        local nextTimer=0
        os.startTimer=function() nextTimer=nextTimer+1;return nextTimer end
        os.pullEvent=function()
            local e=assert(table.remove(events,1),'Unexpected event wait')
            if e.before then e.before() end
            return table.unpack(e)
        end
        term={getSize=function() return 60,20 end,setCursorPos=function() end,clear=function() end,write=function() end}
        local sent={}
        local wire={send=function(_,peer,b) sent[#sent+1]=b end,decode=function()
            return {from='hq',body={op='policy_part',revision=db.revision,digest=C.sha256(snapshot),index=1,total=1,data=snapshot}}
        end}
        App.station({node='station',hq='hq',sensorsConfigured=true,radars={'radar'},namespace='radar-station',
            dimension='minecraft:overworld',alarmSide='left',faultSide='right'},wire,'/station')
        eq(Store.load('/station/policy.json').revision,1);eq(m.outputs.left,true);eq(m.outputs.right,false)
        local observed=false
        for _,b in ipairs(sent) do if b.op=='observations' and #b.items==1 then observed=true end end
        assert(observed)
    end)
    check('HQ event loop refuses beacon sensor injection and serves policy',function(m)
        local cfg={peers={station={role='station',namespace='radar-station',dimension='minecraft:overworld'},beacon={role='beacon'}}}
        local db=Service.empty();Store.save('/hq/database.json',db)
        local observation={kind='ship',id='plane',dimension='minecraft:overworld',x=1,y=50,z=1,time=m.time}
        local messages={
            {from='beacon',role='beacon',body={op='observations',items={observation}}},
            {from='station',role='station',body={op='observations',items={observation},note='OK'}},
            {from='station',role='station',body={op='sync'}},
        }
        local events={{'rednet_message',1,'packet',Wire.PROTOCOL},{'rednet_message',1,'packet',Wire.PROTOCOL},
            {'rednet_message',1,'packet',Wire.PROTOCOL},{'timer',1}}
        local timer=0
        os.startTimer=function() timer=timer+1;return timer end
        os.pullEvent=function() local e=table.remove(events,1);if not e then error('TEST_STOP') end;return table.unpack(e) end
        parallel={waitForAny=function(network) network() end}
        local sent={}
        local wire={decode=function() return table.remove(messages,1) end,send=function(_,peer,b) sent[#sent+1]={peer=peer,body=b} end}
        local ok,err=pcall(App.hq,cfg,wire,'/hq');assert(not ok and tostring(err):find('TEST_STOP',1,true),tostring(err))
        local positions=0
        Store.rows('/hq/events.jsonl',function(e) if e.event=='position' then positions=positions+1;eq(e.contact.source,'station') end end)
        eq(positions,1);eq(sent[1].peer,'station');eq(sent[1].body.op,'policy_part')
    end)
    check('RPC timeout persists request; retry reuses ID and clears on acknowledgement',function(m)
        local events={{'timer',1},{'timer',2},{'timer',3}}
        local timer=0
        os.startTimer=function() timer=timer+1;return timer end
        os.cancelTimer=function() end
        os.pullEvent=function() local e=assert(table.remove(events,1),'Unexpected event wait');return table.unpack(e) end
        local sends={};local wire={nextSequence=1}
        wire.send=function(_,peer,b) sends[#sends+1]=U.copy(b);wire.nextSequence=wire.nextSequence+1 end
        wire.decode=function() return {from='hq',body={op='reply',request='kiosk-1',result={ok=true,application='APP-000001'}}} end
        local cfg={node='kiosk',hq='hq'}
        local first=App.rpc(cfg,wire,fields('apply'));assert(not first.ok)
        local pending=Store.load(App.ROOT..'/pending-request.json');eq(pending.query.request,'kiosk-1')
        wire.nextSequence=129
        events={{'rednet_message',10,'reply',Wire.PROTOCOL}}
        local result=App.rpc(cfg,wire,{op='resume_pending'});assert(result.ok)
        for _,b in ipairs(sends) do eq(b.query.request,'kiosk-1') end
        assert(not Store.load(App.ROOT..'/pending-request.json').query)
    end)

    require('aacs.tests.chat_test').run(check)

    print(string.format('AACS SELFTEST: %d passed, %d failed',passed,failed))
    if failed>0 then error('AACS self-test failed; do not deploy',0) end
    return passed
end
return M
]===],
}
local paths={}
local extra=0
for path,source in pairs(files) do
    assert(path:match('^/aacs/') and path:match('%.lua$'),'Invalid packaged path')
    assert(load(source,'@'..path,'t',{}),'Invalid Lua in packaged file: '..path)
    paths[#paths+1]=path
    extra=extra+math.max(0,#source-(fs.exists(path) and fs.getSize(path) or 0))+512
end
table.sort(paths)
local space=fs.getFreeSpace('/')
assert(type(space)~='number' or space>=extra+4096,'Insufficient free space for runtime code')
for _,path in ipairs(paths) do
    fs.makeDir(fs.getDir(path))
    local h,err=fs.open(path,'w');assert(h,err or ('Cannot write '..path))
    h.write(files[path]);h.close()
    local verify=assert(fs.open(path,'r'))
    local saved=verify.readAll();verify.close()
    assert(saved==files[path],'Write verification failed: '..path)
end
print('AACS code installed: '..#paths..' files. Private config/data were not changed.')
print('Fresh install: provision this computer on your PC, then copy ONLY its config and transport state.')
print('Next: /aacs/start.lua selftest ; /aacs/start.lua setup')
print('Use QUICKSTART.md. Do not connect alarm outputs to weapons.')

-- Host-only signed-network flight simulation: texlua tools/check_scenarios.lua
-- Real AACS wire/storage/decision code; simulated peripherals and world time.
package.path='./?.lua;'..package.path
local json=dofile('tools/test_json.lua')
textutils={serializeJSON=json.encode,unserializeJSON=json.decode}
local U=require('aacs.lib.util')
local Store=require('aacs.lib.store')
local Wire=require('aacs.lib.wire')
local Chat=require('aacs.lib.chat')
local Comms=require('aacs.lib.comms')
local Service=require('aacs.lib.service')
local Tracker=require('aacs.lib.tracker')
local App=require('aacs.lib.app')
local Mock=require('aacs.tests.mock')
local mock=Mock.new()
local restore=Mock.install(mock)
local cfg={realm='flight-test',node='hq',computer=112,peers={}}
local configurations={}
for index,name in ipairs({'capital','border'}) do
    local key=string.rep(index==1 and '12' or '34',32) -- Public test keys only.
    local id=index==1 and 108 or 120
    cfg.peers[name]={computer=id,role='station',key=key,namespace='radar-'..name,dimension='minecraft:overworld'}
    configurations[name]={realm=cfg.realm,node=name,computer=id,peers={hq={computer=112,role='hq',key=key}},chatBox=name}
    Store.save('/'..name..'/transport.json',{realm=cfg.realm,node=name,sentThrough=0,received={}})
end
Store.save('/hq/transport.json',{realm=cfg.realm,node='hq',sentThrough=0,received={}})
local service=Service.new(cfg,'/hq')
local tracker=Tracker.new()
local stations={}
local wires={capital=Wire.new(configurations.capital,'/capital'),border=Wire.new(configurations.border,'/border')}
local hqWire=Wire.new(cfg,'/hq')
local drivers={}
local comms
local failedLink={}
local delivered, events, sentIDs={}, {}, {}
local cancelled, encrypted, replayChecks, epoch=0,0,0,0
local staleWarnings={}
local latestStationPacket
local players={}
for index=1,6 do
    local registration=string.format('ARD-%04d',index)
    local uuid=string.format('00000000-0000-0000-0000-%012x',index)
    players[index]={uuid=uuid,name='Pilot'..index,registration=registration}
    service.db.vessels[registration]={name='Craft '..index,status='active'}
    service.db.pilots[uuid]={username='Pilot'..index,registration=registration,expires=mock.time+3600000}
    for _,name in ipairs({'capital','border'}) do
        service.db.bindings['ship:radar-'..name..':plane-'..index]={registration=registration,expires=mock.time+3600000}
    end
end
service.db.zones.capital={id='capital',name='Capital',class='restricted',shape='box',dimension='minecraft:overworld',
    applies='ships',minX=0,maxX=100,minY=0,maxY=200,minZ=0,maxZ=100}

local function toHQ(name,body)
    local packet=wires[name]:encode('hq',body)
    latestStationPacket={name=name,packet=packet}
    encrypted=encrypted+1
    if failedLink[name] then return end
    local message=assert(hqWire:decode(configurations[name].computer,packet),'Signed station packet rejected')
    if body.op=='pilot_chat' then comms:handleChat(name,message.body,mock.time)
    elseif body.op=='chat_result' then
        if message.body.status=='sent' then
            assert(not sentIDs[message.body.id],'One notice sent by multiple stations')
            sentIDs[message.body.id]=true
        end
        comms:result(name,message.body,mock.time)
    elseif body.op=='observations' then
        local first=not stations[name]
        stations[name]={lastMessage=mock.time,chat={ready=true}}
        if first then comms:resetStation(name) end
        for _,raw in ipairs(message.body.items) do
            local contact=assert(App.acceptedObservation(raw,cfg.peers[name],name,mock.time))
            tracker:ingest(contact,service.db,mock.time)
        end
    end
end

local function toStation(name,body)
    local packet=hqWire:encode(name,body)
    encrypted=encrypted+1
    if failedLink[name] then return end
    local message=assert(wires[name]:decode(112,packet),'Signed HQ packet rejected')
    if body.op=='chat_notice' then
        if message.body.thread then message.body.version=message.seq end
        drivers[name]:accept(message.body,mock.time)
    elseif body.op=='chat_cancel' then drivers[name]:cancel(message.body.id);cancelled=cancelled+1
    elseif body.op=='chat_reset' then drivers[name]:reset() end
end

local function newComms()
    return Comms.new(service,tracker,stations,toStation,function(row) events[#events+1]=row end)
end

for index,name in ipairs({'capital','border'}) do
    local nextAllowed=0
    local function accept(text,recipient)
        if mock.time<nextAllowed then return nil,'Simulated Chat Box cooldown' end
        nextAllowed=mock.time+1500
        delivered[#delivered+1]={time=mock.time,station=name,recipient=recipient,text=text}
        if recipient and text:find('WARNING:',1,true) and not failedLink[name] then
            local number=tonumber(recipient:match('^Pilot(%d+)$'))
            local contact=number and tracker.contacts['vessel:'..players[number].registration]
            if not contact or not contact.decision.violation then staleWarnings[#staleWarnings+1]=recipient..': '..text end
        end
        return true
    end
    if index==1 then
        mock.devices[name]={_type='chat_box',sendMessage=function(text) return accept(text) end,
            sendMessageToPlayer=function(text,recipient) return accept(text,recipient) end}
    else
        mock.devices[name]={_type='chat_box',sendMessage=function(text,options) return accept(text,options.player) end}
    end
    drivers[name]=Chat.new(configurations[name],'/'..name,function(body) toHQ(name,body) end)
    drivers[name]:tick(mock.time)
end
comms=newComms()

local function pilot(index,command)
    local p=players[index]
    for _,name in ipairs({'capital','border'}) do
        local event=name=='capital' and {'chat',p.name,'$atc '..command,p.uuid} or {'chat',p.uuid,p.name,'$atc '..command}
        local username,text,uuid=Chat.event(event)
        local relay=drivers[name]:relay(username,text,uuid,mock.time)
        if relay then toHQ(name,relay) end
    end
end

local function advance(milliseconds)
    mock.time=mock.time+milliseconds
    tracker:refresh(service.db,mock.time)
    comms:tick(mock.time)
    for _,name in ipairs({'capital','border'}) do drivers[name]:tick(mock.time) end
end

-- Stations heartbeat first, then all six pilots check in once through both API forms.
for _,name in ipairs({'capital','border'}) do toHQ(name,{op='observations',items={}}) end
for index=1,6 do
    pilot(index,'checkin '..players[index].registration)
    advance(3000)
end
assert(U.count(comms.sessions)==6,'Check-in was lost or duplicated')

for step=1,180 do
    if step==30 then drivers.capital.nextSend=mock.time+15000
    elseif step==40 then
        for _,p in ipairs(players) do
            assert(service:execute('hq-console','local_admin',{op='permit',request='scenario-permit-'..p.registration,
                subject='vessel:'..p.registration,zone='capital',minutes=1}).ok)
        end
    elseif step==60 then failedLink.capital=true
    elseif step==70 then
        failedLink.capital=nil
        local captured=latestStationPacket
        hqWire=Wire.new(cfg,'/hq')
        -- Persisted replay counters survive a real wire-instance restart.
        if captured and mock.time-2000>0 then
            assert(not hqWire:decode(configurations[captured.name].computer,captured.packet),'Restart accepted a replay')
            replayChecks=replayChecks+1
        end
        tracker=Tracker.new();stations={};comms=newComms();epoch=epoch+1
        for _,name in ipairs({'capital','border'}) do toHQ(name,{op='observations',items={}}) end
        for index=1,6 do pilot(index,'checkin '..players[index].registration);advance(3000) end
        assert(U.count(comms.sessions)==6,'HQ restart did not permit fresh check-in')
    elseif step==90 then service.db.vessels['ARD-0002'].status='suspended';service.db.revision=service.db.revision+1
    elseif step==100 then service.db.vessels['ARD-0002'].status='active';service.db.revision=service.db.revision+1
    elseif step==110 then service.db.pilots[players[3].uuid]=nil
    elseif step==120 then pilot(4,'checkout') end
    local names=step%2==0 and {'capital','border'} or {'border','capital'}
    for _,name in ipairs(names) do
        local items={}
        for index=1,6 do
            if not(index==1 and step>=150 and step<=162) then
                items[#items+1]={kind='ship',id='plane-'..index,dimension='minecraft:overworld',
                    x=(step*16+index*11)%180-40,y=80,z=50,time=mock.time}
            end
        end
        toHQ(name,{op='observations',items=items})
    end
    if step%20==0 then
        assert(not hqWire:decode(configurations[latestStationPacket.name].computer,latestStationPacket.packet),'Duplicate accepted')
        replayChecks=replayChecks+1
    end
    advance(2000)
end

local suspendedNotice,contactLost=false,false
for _,row in ipairs(delivered) do
    if row.recipient=='Pilot2' and row.text:find('Registration suspended',1,true) then suspendedNotice=true end
    if row.recipient=='Pilot1' and row.text:find('radar contact lost',1,true) then contactLost=true end
end
assert(suspendedNotice,'Suspended pilot did not receive a private warning')
assert(contactLost,'Coverage loss did not produce a lost-contact notice')
assert(not comms:session(players[3].uuid,mock.time),'Revoked pilot remained active')
assert(not comms:session(players[4].uuid,mock.time),'Checked-out pilot remained active')
assert(epoch==1 and cancelled>0 and replayChecks>=9,string.format('epoch=%d cancelled=%d replays=%d',epoch,cancelled,replayChecks))
assert(#staleWarnings==0,staleWarnings[1])
restore()
print(string.format('PASS 180 flight steps, 6 vessels, 2 stations, %d signed packets, %d accepted chat messages, %d cross-station cancellations, %d replay rejections',
    encrypted,#delivered,cancelled,replayChecks))
print('PASS both AP event/send API forms, duplicate relays, permit expiry, HQ restart, station outage, suspension, revocation, checkout and coverage loss')

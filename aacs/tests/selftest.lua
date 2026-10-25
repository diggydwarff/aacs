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

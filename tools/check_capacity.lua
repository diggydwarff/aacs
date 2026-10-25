-- Host-only capacity test: texlua tools/check_capacity.lua
package.path='./?.lua;'..package.path
local json=dofile('tools/test_json.lua')
textutils={serializeJSON=json.encode,unserializeJSON=json.decode}
local U=require('aacs.lib.util')
local Store=require('aacs.lib.store')
local Policy=require('aacs.lib.policy')
local Service=require('aacs.lib.service')
local Mock=require('aacs.tests.mock')
local mock=Mock.new()
local restore=Mock.install(mock)
local service=Service.new({peers={}},'/hq')
service.db.vessels['ARD-0001']={name='Test craft',status='active'}
for i=1,1800 do
    local key='ship:radar-capital:'..string.rep('a',100)..i
    service.db.bindings[key]={registration='ARD-0001',expires=mock.time+600000,by='hq-console'}
end
assert(#U.json(Policy.snapshot(service.db,mock.time))>256000)
local revision=service.db.revision
local result=service:execute('hq-console','local_admin',{op='player',request='capacity-grow',
    uuid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',name='Other',nation='Ardennes'})
assert(not result.ok and service.db.revision==revision)
local key='ship:radar-capital:'..string.rep('a',100)..'1'
result=service:execute('hq-console','local_admin',{op='unbind',request='capacity-shrink',sensorKey=key})
assert(result.ok and not service.db.bindings[key])
Store.save('/hq/database.json',service.db)
local App=require('aacs.lib.app')
local Wire=require('aacs.lib.wire')
local timer=0
os.startTimer=function() timer=timer+1;return timer end
local delivered=false
os.pullEvent=function()
    if delivered then error('TEST_STOP') end
    delivered=true
    return 'rednet_message',108,'sync',Wire.PROTOCOL
end
parallel={waitForAny=function(network) network() end}
local sent={}
local wire={decode=function() return {from='capital',role='station',body={op='sync'}} end,
    send=function(_,_,body) sent[#sent+1]=body end}
local ok,problem=pcall(App.hq,{peers={capital={role='station'}}},wire,'/hq')
assert(not ok and tostring(problem):find('TEST_STOP',1,true),tostring(problem))
assert(#sent==1 and sent[1].op=='policy_unavailable')
restore()
print('PASS oversized imported policy returns an unavailable response and HQ continues serving events')
print('PASS oversized policy rejects growth, preserves the prior revision and allows cleanup')

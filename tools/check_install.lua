-- Standalone packaging check. Run from the AACS root with Lua 5.2/5.3 + bit32.
package.path='./?.lua;'..package.path
local mock=require('aacs.tests.mock').new()
local restore=require('aacs.tests.mock').install(mock)
mock.files['/aacs/config.json']='KEEP PRIVATE CONFIG'
mock.files['/aacs/data/transport.json']='KEEP LIVE COUNTERS'
mock.files['/aacs/data/database.json']='KEEP EXISTING REGISTRATIONS AND BINDING EXPIRY'
mock.files['/aacs/data/policy.json']='KEEP CACHED STATION POLICY'
assert(loadfile('aacs_install.lua'))()
local count=0
for name,content in pairs(mock.files) do
    if name:match('%.lua$') then
        local original=assert(io.open(name:sub(2),'r'))
        assert(original:read('*a')==content,'Installer content mismatch: '..name)
        original:close();count=count+1
    end
end
assert(count>=10)
assert(mock.files['/aacs/config.json']=='KEEP PRIVATE CONFIG')
assert(mock.files['/aacs/data/transport.json']=='KEEP LIVE COUNTERS')
assert(mock.files['/aacs/data/database.json']=='KEEP EXISTING REGISTRATIONS AND BINDING EXPIRY')
assert(mock.files['/aacs/data/policy.json']=='KEEP CACHED STATION POLICY')
assert(not pcall(assert(loadfile('aacs_install.lua'))),'Unflagged reinstall should fail')
assert(loadfile('aacs_install.lua'))('--upgrade')
assert(mock.files['/aacs/config.json']=='KEEP PRIVATE CONFIG')
assert(mock.files['/aacs/data/transport.json']=='KEEP LIVE COUNTERS')
assert(mock.files['/aacs/data/database.json']=='KEEP EXISTING REGISTRATIONS AND BINDING EXPIRY')
assert(mock.files['/aacs/data/policy.json']=='KEEP CACHED STATION POLICY')
mock.files['/aacs/data/run.lock']='running'
assert(not pcall(assert(loadfile('aacs_install.lua')),'--upgrade'),'Live upgrade must be refused')
restore()
print('PASS installer writes exact sources; preserves private state; refuses live/unflagged upgrades: '..count..' runtime files')

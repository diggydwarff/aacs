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

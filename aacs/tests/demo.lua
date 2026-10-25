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

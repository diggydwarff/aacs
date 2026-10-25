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

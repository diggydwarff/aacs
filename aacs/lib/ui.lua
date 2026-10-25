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

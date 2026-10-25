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

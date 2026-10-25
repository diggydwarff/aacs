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

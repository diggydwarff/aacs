local Chat = require('aacs.lib.chat')
local Comms = require('aacs.lib.comms')
local Service = require('aacs.lib.service')
local Policy = require('aacs.lib.policy')
local Tracker = require('aacs.lib.tracker')
local Store = require('aacs.lib.store')
local U = require('aacs.lib.util')
local M = {}
local PILOT = '12345678-1234-1234-1234-123456789abc'
local OTHER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

function M.run(check)
    local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
    local function fixture(mock)
        local sent, log = {controls = {}}, {}
        local cfg = {peers = {capital = {role = 'station'}, border = {role = 'station'}, kiosk = {role = 'kiosk'}}}
        local service = Service.new(cfg, '/hq')
        service.db.vessels['ARD-0001'] = {name = 'Dragonfly', status = 'active'}
        service.db.pilots[PILOT] = {username = 'Pilot', registration = 'ARD-0001', expires = mock.time + 600000}
        service.db.zones.test = {id = 'test', name = 'Capital', class = 'restricted', shape = 'box',
            dimension = 'minecraft:overworld', applies = 'ships', minX = 0, maxX = 100,
            minY = 0, maxY = 200, minZ = 0, maxZ = 100}
        service.db.bindings['ship:radar-capital:plane'] = {registration = 'ARD-0001', expires = mock.time + 600000}
        service.db.bindings['ship:radar-border:plane'] = {registration = 'ARD-0001', expires = mock.time + 600000}
        local tracker = Tracker.new()
        local stations = {capital = {lastMessage = mock.time, chat = {ready = true}},
            border = {lastMessage = mock.time, chat = {ready = true}}}
        local comms = Comms.new(service, tracker, stations, function(station, body)
            local destination = body.op == 'chat_notice' and sent or sent.controls
            destination[#destination + 1] = {station = station, body = U.copy(body)}
        end, function(row) log[#log + 1] = row end)
        local function refresh(milliseconds)
            mock.time = mock.time + (milliseconds or 2000)
            stations.capital.lastMessage = mock.time
            stations.border.lastMessage = mock.time
        end
        local function command(text, uuid, from)
            return comms:handleChat(from or 'capital', {username = uuid == OTHER and 'Other' or 'Pilot',
                uuid = uuid or PILOT, command = text, time = mock.time}, mock.time)
        end
        local function observe(x, source)
            source = source or 'capital'
            tracker:ingest({kind = 'ship', id = 'plane', namespace = 'radar-' .. source,
                source = source, dimension = 'minecraft:overworld', x = x, y = 80, z = 50, time = mock.time}, service.db, mock.time)
            tracker:refresh(service.db, mock.time)
        end
        local function tick() comms:tick(mock.time) end
        return comms, service, tracker, stations, sent, log, command, observe, refresh, tick
    end

    local function boxFixture(mock, modern)
        local messages = {}
        local box = {_type = 'chat_box'}
        if modern then
            box.sendMessage = function(text, options)
                messages[#messages + 1] = {text = text, recipient = options.player, prefix = options.prefix}
                return true
            end
        else
            box.sendMessage = function(text, prefix)
                messages[#messages + 1] = {text = text, prefix = prefix}; return true
            end
            box.sendMessageToPlayer = function(text, recipient, prefix)
                messages[#messages + 1] = {text = text, recipient = recipient, prefix = prefix}; return true
            end
        end
        mock.devices.chat_box_0 = box
        return box, messages
    end

    local function notice(mock, id, recipient)
        return {id = id or 'N-1', recipient = recipient or 'Pilot', text = 'Airspace warning',
            expires = mock.time + 20000, priority = 3}
    end

    check('Chat command parser accepts hidden or visible ATC and ignores ordinary chat', function()
        eq(Chat.command('$atc checkin ARD-0001'), 'checkin ARD-0001')
        eq(Chat.command('ATC help'), 'help'); eq(Chat.command('$atc'), 'help')
        eq(Chat.command('atcclear help'), nil); eq(Chat.command('hello atc'), nil)
        eq(Chat.command('atc help\n'), nil)
    end)
    check('Legacy Chat Box private and public messages use the correct methods', function(m)
        local box, messages = boxFixture(m)
        assert(Chat.send(box, 'private', 'Pilot')); assert(Chat.send(box, 'public'))
        eq(messages[1].recipient, 'Pilot'); eq(messages[2].recipient, nil); eq(messages[1].prefix, 'AACS')
    end)
    check('AP options-table Chat Box keeps private targets private', function(m)
        local box, messages = boxFixture(m, true)
        assert(Chat.send(box, 'private', 'Pilot')); assert(Chat.send(box, 'public'))
        eq(messages[1].recipient, 'Pilot'); eq(messages[2].recipient, nil)
    end)
    check('Chat Box nil,error and thrown errors are failures', function(m)
        local box = boxFixture(m)
        box.sendMessageToPlayer = function() return nil, 'cooldown' end
        local ok, problem = Chat.send(box, 'test', 'Pilot'); eq(ok, nil); eq(problem, 'cooldown')
        box.sendMessageToPlayer = function() error('unloaded') end
        ok, problem = Chat.send(box, 'test', 'Pilot'); eq(ok, nil); assert(problem:find('unloaded', 1, true))
    end)
    check('Chat queue honors cooldown without blocking and prioritizes warnings', function(m)
        local _, messages = boxFixture(m)
        local reports = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) reports[#reports + 1] = r end)
        local routine = notice(m, 'routine'); routine.priority = 1
        chat:accept(routine, m.time); chat:accept(notice(m, 'warning'), m.time)
        chat:tick(m.time); eq(#messages, 1); eq(reports[1].id, 'warning')
        chat:tick(m.time + 1000); eq(#messages, 1)
        chat:tick(m.time + 1500); eq(#messages, 2)
    end)
    check('Chat retries a cooldown failure, recovers, and reports success once', function(m)
        local box, messages = boxFixture(m)
        local send = box.sendMessageToPlayer
        local attempt = 0
        box.sendMessageToPlayer = function(...)
            attempt = attempt + 1
            if attempt == 1 then return nil, 'cooldown' end
            return send(...)
        end
        local reports = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) reports[#reports + 1] = r end)
        chat:accept(notice(m), m.time); chat:tick(m.time); eq(#reports, 0)
        chat:tick(m.time + 1500); eq(#messages, 1); eq(#reports, 1); eq(reports[1].status, 'sent')
        eq(chat:status().error, nil)
    end)
    check('Chat detachment recovers and expired messages are never sent', function(m)
        local reports = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) reports[#reports + 1] = r end)
        chat:accept(notice(m), m.time); chat:tick(m.time); assert(not chat.ready)
        local _, messages = boxFixture(m)
        chat:tick(m.time + 21000); eq(#messages, 0); eq(reports[1].status, 'failed')
        chat:accept(notice(m, 'new'), m.time); chat:tick(m.time); eq(#messages, 1); assert(chat.ready)
    end)
    check('Chat retransmission never sends the same notice twice', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        local body = notice(m)
        chat:accept(body, m.time); chat:accept(body, m.time); chat:tick(m.time)
        chat:accept(body, m.time + 2000); chat:tick(m.time + 2000); eq(#messages, 1)
    end)
    check('New airspace notice supersedes an unsent old warning', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        local old, new = notice(m, 'old'), notice(m, 'new')
        old.thread = 'vessel:ARD-0001:Pilot'; old.version = 1
        new.thread = old.thread; new.version = 2; new.text = 'Observed leaving'; new.priority = 1
        chat:accept(old, m.time); chat:accept(new, m.time); chat:tick(m.time)
        eq(#messages, 1); eq(messages[1].text, 'Observed leaving')
    end)
    check('Chat queue is bounded and public sends require explicit station opt-in', function(m)
        boxFixture(m)
        local results = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(r) results[#results + 1] = r end)
        local public = notice(m, 'public'); public.recipient = nil
        assert(not chat:accept(public, m.time))
        for i = 1, 32 do assert(chat:accept(notice(m, 'N-' .. i), m.time)) end
        assert(not chat:accept(notice(m, 'overflow'), m.time)); eq(#chat.queue, 32)
    end)
    check('Pilot relay validates event UUID, rate limits, and never parses a claimed UUID from text', function(m)
        boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end); chat:tick(m.time)
        assert(not chat:relay('Pilot', '$atc help', 'fake', m.time))
        local body = chat:relay('Pilot', '$atc checkin ARD-0001', PILOT, m.time)
        eq(body.uuid, PILOT); assert(not chat:relay('Pilot', '$atc help', PILOT, m.time + 1000))
        assert(chat:relay('Pilot', '$atc help', PILOT, m.time + 2000))
    end)
    check('HQ pilot authorization requires local administration and persists', function(m)
        local _, service = fixture(m)
        local q = {op = 'authorize_pilot', request = 'pilot-1', uuid = OTHER, username = 'Other', registration = 'ARD-0001', minutes = 60}
        for _, role in ipairs({'station', 'beacon', 'kiosk', 'registrar'}) do assert(not service:execute(role, role, q).ok) end
        assert(service:execute('hq-console', 'local_admin', q).ok)
        eq(Store.load('/hq/database.json').pilots[OTHER].registration, 'ARD-0001')
        q.request = 'pilot-2'; q.minutes = 0; assert(not service:execute('hq-console', 'local_admin', q).ok)
    end)
    check('Unknown pilot request appears at HQ but cannot self-authorize or gain clearance', function(m)
        local comms, service, _, _, sent, _, command, _, _, tick = fixture(m)
        command('checkin ARD-0001', OTHER); tick(); eq(comms:session(OTHER, m.time), nil)
        eq(comms:candidates(m.time).items[1].uuid, OTHER)
        assert(sent[1].body.text:find('requires HQ approval', 1, true)); eq(U.count(service.db.permits), 0)
    end)
    check('Approved pilot can check in and check out with the authenticated account UUID', function(m)
        local comms, _, _, _, sent, _, command, _, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); eq(comms:session(PILOT, m.time).username, 'Pilot')
        eq(sent[1].body.recipient, 'Pilot')
        refresh(3000); command('checkout'); tick(); eq(comms:session(PILOT, m.time), nil)
    end)
    check('Overlapping stations relay one command and send one vessel notice', function(m)
        local comms, _, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); assert(not command('checkin ARD-0001', PILOT, 'border')); tick()
        eq(#sent, 1)
        refresh(); observe(50, 'capital'); observe(50, 'border'); tick()
        eq(#sent, 2); eq(sent[2].body.recipient, 'Pilot'); eq(sent[2].station, 'border')
        assert(sent[2].body.text:find('detected within', 1, true))
    end)
    check('Fresh observations announce entry and exit; disappearance never announces exit', function(m)
        local _, _, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(-10); tick()
        refresh(); observe(50); tick(); assert(sent[#sent].body.text:find('entering', 1, true))
        refresh(); observe(110); tick(); assert(sent[#sent].body.text:find('observed leaving', 1, true))
        refresh(); observe(50); tick()
        refresh(21000); tracker:refresh({}, m.time); tick()
        assert(sent[#sent].body.text:find('contact lost', 1, true)); assert(not sent[#sent].body.text:find('observed leaving', 1, true))
    end)
    check('Initial radar acquisition inside a zone is detected within, not a claimed boundary crossing', function(m)
        local _, _, _, _, sent, _, command, observe, _, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local found = false
        for _, item in ipairs(sent) do
            if item.body.priority == 3 then
                assert(item.body.text:find('detected within', 1, true)); assert(not item.body.text:find('entering', 1, true)); found = true
            end
        end
        assert(found)
    end)
    check('Restricted warnings repeat at 30 seconds and acknowledgement never grants a permit', function(m)
        local comms, service, _, _, sent, log, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local before = #sent
        refresh(29000); observe(50); tick(); eq(#sent, before)
        refresh(1000); observe(50); tick(); eq(#sent, before + 1)
        local id = comms:session(PILOT, m.time).lastWarning
        refresh(3000); command('ack ' .. id); tick()
        eq(U.count(service.db.permits), 0)
        local acknowledged = false
        for _, row in ipairs(log) do if row.event == 'pilot_ack' then acknowledged = true end end
        assert(acknowledged)
        assert(sent[#sent].body.text:find('does not grant clearance', 1, true))
    end)
    check('Permit grant and expiry send updated clearance notices', function(m)
        local _, service, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        refresh(); service.db.permits.P = {id = 'P', subject = 'vessel:ARD-0001', zone = 'test', starts = m.time, expires = m.time + 1000}
        tracker:refresh(service.db, m.time); tick()
        assert(sent[#sent].body.text:find('clearance now valid', 1, true))
        refresh(); observe(50); tick(); assert(sent[#sent].body.text:find('clearance no longer valid', 1, true))
    end)
    check('Pilot revocation and session expiry stop further private vessel routing', function(m)
        local comms, service, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); service.db.pilots[PILOT] = nil
        refresh(); observe(50); tick(); eq(#sent, 1); eq(comms:session(PILOT, m.time), nil)
    end)
    check('Zone commands disclose actual geometry and altitude without changing policy', function(m)
        local _, service, _, _, sent, _, command, _, refresh, tick = fixture(m)
        command('zone test', OTHER); tick()
        assert(sent[1].body.text:find('X 0..100', 1, true)); assert(sent[1].body.text:find('Y 0..200', 1, true))
        refresh(3000); command('zones 999', OTHER); tick(); assert(sent[#sent].body.text:find('from 1 to 1', 1, true))
        eq(U.count(service.db.permits), 0)
    end)
    check('Unknown ships are not privately assigned to nearby players; public hails are opt-in', function(m)
        local _, service, _, stations, sent, log, _, observe, refresh, tick = fixture(m)
        service.db.bindings = {}; observe(50); tick(); eq(#sent, 0)
        assert(log[#log].event == 'chat_unroutable')
        stations.capital.chat.publicHails = true
        refresh(30000); observe(50); tick(); eq(#sent, 1); eq(sent[1].body.recipient, nil)
        assert(sent[1].body.text:find('near X', 1, true))
    end)
    check('Offline or revoked stations cannot relay commands and are not chosen as senders', function(m)
        local comms, service, _, stations, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); refresh(); stations.capital.chat.ready = false
        assert(not command('help')); observe(50); tick(); eq(sent[#sent].station, 'border')
        service.config.peers.border.revoked = true
        eq(comms:station(nil, m.time), nil)
    end)
    check('Only the chosen station can report a pending notice as sent', function(m)
        local comms, _, _, _, sent, log, command, _, _, tick = fixture(m)
        command('help'); tick(); local id = sent[1].body.id
        assert(not comms:result('border', {id = id, status = 'sent'}, m.time))
        assert(comms:result('capital', {id = id, status = 'sent', detail = 'accepted'}, m.time))
        eq(log[#log].event, 'chat_sent'); assert(not comms:result('capital', {id = id, status = 'sent'}, m.time))
    end)
    check('HQ restart retains authorizations but requires a new pilot check-in', function(m)
        local comms, service, tracker, stations, _, _, command = fixture(m)
        command('checkin ARD-0001'); assert(comms:session(PILOT, m.time))
        local restarted = Comms.new(service, tracker, stations, function() end)
        eq(restarted:session(PILOT, m.time), nil); assert(service.db.pilots[PILOT])
    end)
    check('Controller sends remain private by default and broadcast needs station opt-in', function(m)
        local comms, _, _, stations, sent, _, command, _, _, tick = fixture(m)
        command('checkin ARD-0001'); tick()
        assert(comms:controller({target = 'ARD-0001', station = '', text = 'Contact Capital tower'}, m.time).ok)
        tick(); eq(sent[#sent].body.recipient, 'Pilot')
        assert(not comms:controller({target = 'ALL', text = 'Notice'}, m.time).ok)
        stations.capital.chat.publicHails = true
        assert(comms:controller({target = 'ALL', text = 'Notice'}, m.time).ok); tick(); eq(sent[#sent].body.recipient, nil)
    end)
    check('Pilot messages reach the HQ inbox without changing clearances', function(m)
        local comms, service, _, _, sent, log, command, _, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); refresh(3000)
        command('say Request permission to enter Capital'); tick()
        eq(comms:messages().items[1].username, 'Pilot')
        assert(comms:messages().items[1].text:find('Request permission', 1, true))
        assert(sent[#sent].body.text:find('does not confirm', 1, true))
        eq(U.count(service.db.permits), 0)
        local found = false
        for _, row in ipairs(log) do if row.event == 'pilot_message' then found = true end end
        assert(found)
    end)
    check('Station event loop relays chat, accepts only HQ notices, and returns send results', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local _, messages = boxFixture(m)
        m.devices.radar = {getTracks = function() return {} end}
        local valid = notice(m, 'valid'); valid.op = 'chat_notice'
        local invalid = notice(m, 'invalid'); invalid.op = 'chat_notice'
        local decoded = {{from = 'beacon', body = invalid}, {from = 'hq', body = valid}}
        local events = {{'timer', 2}, {'chat', 'Pilot', '$atc help', PILOT}, {'chat', OTHER, 'Other', '$atc help'},
            {'rednet_message', 112, 'fake', Wire.PROTOCOL}, {'rednet_message', 112, 'valid', Wire.PROTOCOL},
            {'timer', 1}, {'char', 'q'}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function() local event = assert(table.remove(events, 1), 'Unexpected event wait'); return table.unpack(event) end
        term = {getSize = function() return 75, 20 end, setCursorPos = function() end, clear = function() end, write = function() end}
        local sent = {}
        local wire = {send = function(_, _, body) sent[#sent + 1] = U.copy(body) end,
            decode = function() return table.remove(decoded, 1) end}
        App.station({node = 'capital', hq = 'hq', sensorsConfigured = true, radars = {'radar'},
            namespace = 'radar-capital', dimension = 'minecraft:overworld', chatBox = 'chat_box_0'}, wire, '/station')
        eq(#messages, 1); eq(messages[1].recipient, 'Pilot')
        local relay, result, heartbeat = 0, false, false
        for _, body in ipairs(sent) do
            if body.op == 'pilot_chat' then assert(body.uuid == PILOT or body.uuid == OTHER); relay = relay + 1 end
            if body.op == 'chat_result' then eq(body.id, 'valid'); eq(body.status, 'sent'); result = true end
            if body.op == 'observations' then eq(body.chat.ready, true); heartbeat = true end
        end
        assert(relay == 2 and result and heartbeat)
    end)
    check('HQ event loop processes station pilot commands and dispatches a private reply', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local _, service = fixture(m)
        Store.save('/hq/database.json', service.db)
        local decoded = {{from = 'capital', role = 'station', body = {op = 'observations', items = {}, chat = {ready = true}}},
            {from = 'capital', role = 'station', body = {op = 'pilot_chat', username = 'Pilot', uuid = PILOT,
                command = 'checkin ARD-0001', time = m.time}}}
        local events = {{'rednet_message', 108, 'observations', Wire.PROTOCOL},
            {'rednet_message', 108, 'checkin', Wire.PROTOCOL}, {'timer', 1}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function()
            local event = table.remove(events, 1)
            if not event then error('TEST_STOP') end
            return table.unpack(event)
        end
        parallel = {waitForAny = function(network) network() end}
        local sent = {}
        local wire = {send = function(_, station, body) sent[#sent + 1] = {station = station, body = U.copy(body)} end,
            decode = function() return table.remove(decoded, 1) end}
        local ok, problem = pcall(App.hq, service.config, wire, '/hq')
        assert(not ok and tostring(problem):find('TEST_STOP', 1, true), tostring(problem))
        eq(#sent, 2); eq(sent[1].body.op, 'chat_reset')
        eq(sent[2].station, 'capital'); eq(sent[2].body.op, 'chat_notice')
        eq(sent[2].body.recipient, 'Pilot'); assert(sent[2].body.text:find('Checked in', 1, true))
    end)

    check('Both AP chat event orders use the actual event UUID and reject command senders', function()
        local name, text, uuid = Chat.event({'chat', 'Pilot', '$atc status', PILOT})
        eq(name, 'Pilot'); eq(text, '$atc status'); eq(uuid, PILOT)
        name, text, uuid = Chat.event({'chat', PILOT, 'Pilot', '$atc status'})
        eq(name, 'Pilot'); eq(text, '$atc status'); eq(uuid, PILOT)
        eq(Chat.event({'chat', nil, '[say]', '$atc checkin ARD-0001'}), nil)
        eq(Chat.event({'chat', 'Pilot', '$atc ' .. PILOT, 'fake-uuid'}), nil)
    end)
    check('Cancellation before notice arrival prevents it from ever sending', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        assert(chat:cancel('late'))
        assert(chat:accept(notice(m, 'late'), m.time))
        chat:tick(m.time); eq(#messages, 0)
    end)
    check('HQ cancels a queued warning at the old station when a different station observes exit', function(m)
        local _, _, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick()
        local _, messagesA = boxFixture(m)
        local first = Chat.new({chatBox = 'chat_box_0'}, '/first', function() end)
        first.nextSend = m.time + 10000
        refresh(); observe(50, 'capital'); tick()
        local warning = sent[#sent]
        eq(warning.station, 'capital'); assert(warning.body.text:find('WARNING', 1, true))
        first:accept(warning.body, m.time)
        refresh(); observe(110, 'border'); tick()
        local cancelled = false
        for _, control in ipairs(sent.controls) do
            if control.station == 'capital' and control.body.id == warning.body.id then
                eq(control.body.op, 'chat_cancel'); first:cancel(control.body.id); cancelled = true
            end
        end
        assert(cancelled); first:tick(m.time + 10000); eq(#messagesA, 0)
        local latest = sent[#sent]
        eq(latest.station, 'border'); assert(latest.body.text:find('observed leaving', 1, true))
    end)
    check('Pilot checkout cancels both pending and not-yet-dispatched vessel notices', function(m)
        local comms, _, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); tick(); refresh(); observe(50); tick()
        local warningId = sent[#sent].body.id
        assert(comms:controller({target = 'ARD-0001', station = '', text = 'Private vessel message'}, m.time).ok)
        refresh(3000); command('checkout')
        for _, item in ipairs(comms.queue) do assert(item.subject ~= 'vessel:ARD-0001') end
        eq(comms.pending[warningId], nil)
        local found = false
        for _, control in ipairs(sent.controls) do if control.body.id == warningId then found = true end end
        assert(found)
    end)
    check('HQ reconnection clears old station queues and keeps duplicate tombstones', function(m)
        local _, messages = boxFixture(m)
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function() end)
        local old = notice(m, 'before-restart'); chat:accept(old, m.time); chat:reset()
        chat:accept(old, m.time); chat:tick(m.time); eq(#messages, 0)
        chat:accept(notice(m, 'after-restart'), m.time); chat:tick(m.time); eq(#messages, 1)
    end)
    check('Station notice ordering uses persistent wire sequence rather than reset HQ counter', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local _, messages = boxFixture(m)
        m.devices.radar = {getTracks = function() return {} end}
        local old, new = notice(m, 'old-counter'), notice(m, 'new-counter')
        old.op = 'chat_notice'; old.thread = 'same-contact'; old.version = 9000
        new.op = 'chat_notice'; new.thread = old.thread; new.version = 1; new.text = 'New HQ status'; new.priority = 1
        local decoded = {{from = 'hq', body = old, seq = 100}, {from = 'hq', body = new, seq = 101}}
        local events = {{'rednet_message', 112, 'old', Wire.PROTOCOL}, {'rednet_message', 112, 'new', Wire.PROTOCOL}, {'timer', 1}, {'char', 'q'}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function() local event = assert(table.remove(events, 1)); return table.unpack(event) end
        term = {getSize = function() return 75, 20 end, setCursorPos = function() end, clear = function() end, write = function() end}
        local wire = {send = function() end, decode = function() return table.remove(decoded, 1) end}
        App.station({node = 'capital', hq = 'hq', sensorsConfigured = true, radars = {'radar'},
            namespace = 'radar-capital', dimension = 'minecraft:overworld', chatBox = 'chat_box_0'}, wire, '/station')
        eq(#messages, 1); eq(messages[1].text, 'New HQ status')
    end)
    check('A full HQ queue still accepts a replacement for the same contact', function(m)
        local comms = fixture(m)
        for i = 1, 128 do
            assert(comms:notice('capital', 'Pilot', 'Status ' .. i, 1, nil, m.time, nil, 'thread-' .. i))
        end
        assert(comms:notice('capital', 'Pilot', 'Current status', 1, nil, m.time, nil, 'thread-1'))
        eq(#comms.queue, 128)
    end)
    check('Suspending registration preserves pilot communication while denying zone access', function(m)
        local comms, service, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        service.db.zones.test.class = 'controlled'
        command('checkin ARD-0001'); observe(50); tick()
        refresh(); service.db.vessels['ARD-0001'].status = 'suspended'
        tracker:refresh(service.db, m.time); tick()
        assert(comms:session(PILOT, m.time)); eq(sent[#sent].body.recipient, 'Pilot')
        assert(sent[#sent].body.text:find('Registration suspended', 1, true)); eq(sent[#sent].body.priority, 3)
        refresh(3000); assert(command('checkin ARD-0001')); assert(comms:session(PILOT, m.time))
    end)
    check('Renewing the same pilot check-in retains a recent warning acknowledgement ID', function(m)
        local comms, _, _, _, _, log, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local id = comms:session(PILOT, m.time).lastWarning
        refresh(3000); command('checkin ARD-0001'); tick()
        refresh(3000); command('ack ' .. id); tick()
        local found = false
        for _, row in ipairs(log) do if row.event == 'pilot_ack' and row.id == id then found = true end end
        assert(found)
    end)
    check('Binding expiry reclassifies a retained contact without waiting for another scan', function(m)
        local _, service, tracker, _, _, _, _, observe = fixture(m)
        observe(50)
        service.db.bindings['ship:radar-capital:plane'].expires = m.time + 1000
        m.time = m.time + 1001; tracker:refresh(service.db, m.time)
        eq(tracker.contacts['vessel:ARD-0001'], nil)
        local contact = tracker.contacts['ship:radar-capital:plane']
        assert(contact); eq(contact.subject, nil); assert(contact.decision.violation)
    end)
    check('An older observation after rebinding cannot delete the last known contact', function(m)
        local _, service, tracker, _, _, _, _, observe = fixture(m)
        service.db.bindings = {}; observe(50)
        local original = tracker.contacts['ship:radar-capital:plane']
        service.db.bindings[original.sensorKey] = {registration = 'ARD-0001', expires = m.time + 60000}
        local older = U.copy(original); older.time = m.time - 1
        assert(not tracker:ingest(older, service.db, m.time)); eq(tracker.contacts[original.sensorKey], original)
        tracker:refresh(service.db, m.time)
        assert(tracker.contacts['vessel:ARD-0001']); eq(tracker.contacts[original.sensorKey], nil)
    end)
    check('Reclassified radar identity is not announced as lost contact or an airspace exit', function(m)
        local _, service, tracker, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        refresh(); service.db.bindings = {}; tracker:refresh(service.db, m.time); tick()
        local text = sent[#sent].body.text
        assert(text:find('binding changed', 1, true)); assert(not text:find('contact lost', 1, true)); assert(not text:find('leaving', 1, true))
    end)
    check('Policy refresh merges newly bound aliases without replacing a newer position', function(m)
        local _, service, tracker, _, _, _, _, observe, refresh = fixture(m)
        service.db.bindings = {}; observe(10, 'capital'); refresh(); observe(60, 'border')
        service.db.bindings['ship:radar-capital:plane'] = {registration = 'ARD-0001', expires = m.time + 60000}
        service.db.bindings['ship:radar-border:plane'] = {registration = 'ARD-0001', expires = m.time + 60000}
        tracker:refresh(service.db, m.time)
        eq(U.count(tracker.contacts), 1); eq(tracker.contacts['vessel:ARD-0001'].x, 60)
    end)
    check('Chat report exports retain pilot messages, acknowledgement IDs and account fields', function(m)
        local Reports = require('aacs.lib.reports')
        Store.log('/hq/events.jsonl', {event = 'pilot_message', time = m.time, subject = 'vessel:ARD-0001',
            pilot = PILOT, username = 'Pilot', station = 'capital', text = '=Requesting clearance'})
        Store.log('/hq/events.jsonl', {event = 'pilot_ack', time = m.time + 1, subject = 'vessel:ARD-0001', id = 'ATC-123', pilot = PILOT})
        m.time = m.time + 2
        local result = Reports.export('/hq', {})
        local csv = U.read(result.csv)
        assert(csv:find('message_id,pilot_uuid,username,station,message', 1, true))
        assert(csv:find("'=Requesting clearance", 1, true)); assert(csv:find(PILOT, 1, true)); assert(csv:find('ATC-123', 1, true))
        local text = U.read(result.text)
        assert(text:find('Requesting clearance', 1, true)); assert(text:find('ATC-123', 1, true))
    end)

    check('Critical notices displace routine messages from full station and HQ queues', function(m)
        boxFixture(m)
        local results = {}
        local chat = Chat.new({chatBox = 'chat_box_0'}, '/station', function(row) results[#results + 1] = row end)
        for i = 1, 32 do local body = notice(m, 'routine-' .. i); body.priority = 1; assert(chat:accept(body, m.time)) end
        assert(chat:accept(notice(m, 'urgent'), m.time)); eq(#chat.queue, 32)
        eq(results[1].id, 'routine-1'); eq(results[1].status, 'failed')
        local comms = fixture(m)
        for i = 1, 128 do assert(comms:notice('capital', 'Pilot', 'Routine', 1, nil, m.time)) end
        assert(comms:notice('capital', 'Pilot', 'Urgent warning', 3, nil, m.time)); eq(#comms.queue, 128)
        local found = false
        for _, item in ipairs(comms.queue) do if item.body.priority == 3 then found = true end end
        assert(found)
    end)
    check('Pilot approval expiry cancels a station warning already awaiting send', function(m)
        local comms, service, _, _, sent, _, command, observe, refresh, tick = fixture(m)
        command('checkin ARD-0001'); observe(50); tick()
        local id = comms:session(PILOT, m.time).lastWarning
        service.db.pilots[PILOT].expires = m.time + 1000
        refresh(1001); tick(); eq(comms:session(PILOT, m.time), nil); eq(comms.pending[id], nil)
        local found = false
        for _, row in ipairs(sent.controls) do if row.body.id == id and row.body.op == 'chat_cancel' then found = true end end
        assert(found)
    end)
    check('Missing Chat Box and malformed sender events fail closed', function(m)
        local chat = Chat.new({chatBox = 'missing'}, '/station', function() end)
        chat:tick(m.time); assert(not chat.ready)
        local name, text, uuid = Chat.event({'chat', nil, '[say]', '$atc checkin ARD-0001'})
        eq(chat:relay(name, text, uuid, m.time), nil)
        eq(chat:status().queued, 0)
    end)

    check('An unavailable HQ policy marks the cached station rules stale without stopping scans', function(m)
        local App = require('aacs.lib.app')
        local Wire = require('aacs.lib.wire')
        local db = Service.empty()
        Store.save('/station/policy.json', Policy.snapshot(db, m.time))
        m.devices.radar = {getTracks = function() return {} end}
        local events = {{'rednet_message', 112, 'limit', Wire.PROTOCOL}, {'timer', 1}, {'char', 'q'}}
        local timer = 0
        os.startTimer = function() timer = timer + 1; return timer end
        os.pullEvent = function() local event = assert(table.remove(events, 1)); return table.unpack(event) end
        term = {getSize = function() return 90, 20 end, setCursorPos = function() end, clear = function() end, write = function() end}
        local observations = false
        local wire = {send = function(_, _, body) if body.op == 'observations' then observations = true end end,
            decode = function() return {from = 'hq', body = {op = 'policy_unavailable'}} end}
        App.station({node = 'capital', hq = 'hq', sensorsConfigured = true, radars = {'radar'},
            namespace = 'radar-capital', dimension = 'minecraft:overworld', faultSide = 'right'}, wire, '/station')
        eq(m.outputs.right, true); assert(observations)
    end)

end

return M

-- Station-side Chat Box adapter. Work is queued; no sleep blocks radar scans.
local util = require('aacs.lib.util')
local M = {}

function M.username(value)
    return type(value) == 'string' and #value >= 1 and #value <= 16
        and value:match('^[A-Za-z0-9_]+$') ~= nil
end

function M.command(message)
    if not util.text(message, 240) then return nil end
    local text = message:gsub('^%$', '')
    local prefix, rest = text:match('^(%S+)%s*(.-)%s*$')
    if not prefix or prefix:lower() ~= 'atc' then return nil end
    return rest ~= '' and rest or 'help'
end

function M.event(event)
    -- AP 0.7: name, message, UUID. AP 0.8: UUID, name, message.
    -- Validate the event fields; never take an identity from command text.
    if util.uuid(event[2]) and M.username(event[3]) then
        return event[3], event[4], event[2]
    end
    if M.username(event[2]) and util.uuid(event[4]) then
        return event[2], event[3], event[4]
    end
    return nil
end

function M.inspect(config)
    local name = config.chatBox
    if type(name) ~= 'string' or name == '' then return nil, 'Chat Box disabled' end
    if not peripheral.isPresent(name) then return nil, 'Configured Chat Box is unavailable' end
    if not peripheral.hasType(name, 'chat_box') and not peripheral.hasType(name, 'chatBox') then
        return nil, 'Configured peripheral is not a Chat Box'
    end
    local box = peripheral.wrap(name)
    if not box or type(box.sendMessage) ~= 'function' then
        return nil, 'Chat Box has no sendMessage method'
    end
    return box
end

function M.send(box, message, recipient)
    -- AP 0.7 / the user's existing peripheral exposes sendMessageToPlayer.
    -- AP 0.8 consolidated targeting into the sendMessage options table.
    if type(box.sendMessageToPlayer) == 'function' then
        if recipient then return util.safeCall(box, 'sendMessageToPlayer', message, recipient, 'AACS') end
        return util.safeCall(box, 'sendMessage', message, 'AACS')
    end
    return util.safeCall(box, 'sendMessage', message, {player = recipient, prefix = 'AACS'})
end

function M.new(config, root, report)
    local self = {queue = {}, completed = {}, order = {}, relays = {}, sent = 0,
        nextSend = 0, ready = false, error = nil}
    local interval = tonumber(config.chatIntervalSeconds) or 1.5
    interval = math.max(1, math.min(interval, 30)) * 1000

    local function finish(item, status, detail, quiet)
        local result = {op = 'chat_result', id = item.id, status = status,
            detail = tostring(detail or ''):sub(1, 160)}
        self.completed[item.id] = result
        self.order[#self.order + 1] = item.id
        while #self.order > 128 do self.completed[table.remove(self.order, 1)] = nil end
        if not quiet then report(result) end
    end

    function self:cancel(id)
        if not util.id(id, 100) then return false end
        if self.completed[id] then return true end
        for index = #self.queue, 1, -1 do
            if self.queue[index].id == id then table.remove(self.queue, index) end
        end
        -- Keep a tombstone even if cancellation arrives before its notice.
        finish({id = id}, 'cancelled', 'Cancelled by HQ')
        return true
    end

    function self:reset()
        for index = #self.queue, 1, -1 do
            local item = table.remove(self.queue, index)
            finish(item, 'cancelled', 'HQ connection reset', true)
        end
    end

    function self:accept(body, now)
        if type(body) ~= 'table' or not util.id(body.id, 100)
            or not util.integer(body.expires, now + 1, now + 30000)
            or not util.text(body.text, 600)
            or (body.recipient ~= nil and not M.username(body.recipient))
            or not util.integer(body.priority or 1, 1, 3)
            or (body.thread ~= nil and (not util.text(body.thread, 240) or not util.integer(body.version, 1, 9007199254740991))) then return false end
        if self.completed[body.id] then report(self.completed[body.id]); return true end
        for _, item in ipairs(self.queue) do if item.id == body.id then return true end end
        if body.thread then
            for index = #self.queue, 1, -1 do
                local item = self.queue[index]
                if item.thread == body.thread then
                    if item.version >= body.version then finish(body, 'failed', 'Newer notice already queued'); return false end
                    table.remove(self.queue, index)
                    finish(item, 'failed', 'Superseded by a newer airspace notice')
                end
            end
        end
        if not body.recipient and config.chatPublicHails ~= true then
            finish(body, 'failed', 'Public broadcasts disabled on this station')
            return false
        end
        if #self.queue >= 32 then
            local lowest = 1
            for index, item in ipairs(self.queue) do
                if item.priority < self.queue[lowest].priority then lowest = index end
            end
            if self.queue[lowest].priority < (body.priority or 1) then
                local displaced = table.remove(self.queue, lowest)
                finish(displaced, 'failed', 'Displaced by a higher-priority notice')
            else
                finish(body, 'failed', 'Chat queue full')
                return false
            end
        end
        local item = util.copy(body)
        item.priority = item.priority or 1
        item.attempts = 0
        self.queue[#self.queue + 1] = item
        return true
    end

    function self:relay(username, message, uuid, now)
        local command = M.command(message)
        if not self.ready or not command or not M.username(username) or not util.uuid(uuid) then return nil end
        uuid = uuid:lower()
        for id, stamp in pairs(self.relays) do if now - stamp > 60000 then self.relays[id] = nil end end
        if now - (self.relays[uuid] or 0) < 2000 then return nil end
        if util.count(self.relays) >= 128 and not self.relays[uuid] then return nil end
        local second = math.floor(now / 1000)
        if self.relaySecond ~= second then self.relaySecond = second; self.relayCount = 0 end
        if self.relayCount >= 4 then return nil end
        self.relayCount = self.relayCount + 1
        self.relays[uuid] = now
        return {op = 'pilot_chat', username = username, uuid = uuid, command = command, time = now}
    end

    function self:tick(now)
        local ok, box, problem = pcall(M.inspect, config)
        if not ok then problem = box; box = nil end
        self.ready = box ~= nil
        if self.ready then self.error = self.sendError
        else self.error = tostring(problem):sub(1, 200) end
        for index = #self.queue, 1, -1 do
            local item = self.queue[index]
            if item.expires <= now then
                table.remove(self.queue, index)
                finish(item, 'failed', 'Notice expired before sending')
            end
        end
        if box and now >= self.nextSend and #self.queue > 0 then
            local selected = 1
            for index, item in ipairs(self.queue) do
                if item.priority > self.queue[selected].priority then selected = index end
            end
            local item = self.queue[selected]
            local sent, detail = M.send(box, item.text, item.recipient)
            item.attempts = item.attempts + 1
            self.nextSend = now + interval
            if sent == true then
                table.remove(self.queue, selected)
                self.sent = self.sent + 1
                self.lastSent = now
                self.sendError = nil
                self.error = nil
                finish(item, 'sent', 'Chat Box accepted message; pilot reading is not confirmed')
            else
                self.error = tostring(detail or 'Chat Box did not accept message'):sub(1, 200)
                self.sendError = self.error
                self.nextSend = now + math.min(interval * item.attempts, 10000)
                if item.attempts >= 3 then
                    table.remove(self.queue, selected)
                    finish(item, 'failed', self.error)
                end
            end
        end
        local state = self:status()
        local signature = tostring(state.ready) .. tostring(state.error) .. ':' .. state.queued .. ':' .. state.sent
        if root and (signature ~= self.saved or now - (self.savedAt or 0) >= 5000) then
            pcall(util.write, root .. '/chat-status.json', util.json(state))
            self.saved = signature
            self.savedAt = now
        end
    end

    function self:status()
        return {configured = type(config.chatBox) == 'string' and config.chatBox ~= '',
            peripheral = config.chatBox or '', ready = self.ready, error = self.error,
            queued = #self.queue, sent = self.sent, lastSent = self.lastSent,
            publicHails = config.chatPublicHails == true}
    end

    return self
end

return M

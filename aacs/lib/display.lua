-- Resolve the configured monitor again on every frame so reconnects can recover.
local util = require('aacs.lib.util')
local UI = require('aacs.lib.ui')
local M = {}

function M.inspect(config)
    local name = config.monitor
    if type(name) ~= 'string' or name == '' then return nil, 'No monitor configured' end
    if not peripheral.isPresent(name) then return nil, 'Configured monitor is unavailable' end
    if not peripheral.hasType(name, 'monitor') then return nil, 'Configured peripheral is not a monitor' end
    local screen = peripheral.wrap(name)
    if not screen then return nil, 'Monitor could not be opened' end
    return screen
end

function M.new(config, root)
    local self = {frames = 0, lastSuccess = nil, lastSaved = nil, lastState = nil}
    root = root or '/aacs/data'

    local function saveStatus(state, problem, now, tracker)
        local summary = state .. ':' .. tostring(problem or '')
        if summary == self.lastState and self.lastSaved and now - self.lastSaved < 5000 then return end
        local ok = pcall(util.write, root .. '/monitor-status.json', util.json({
            computer = config.computer, node = config.node, monitor = config.monitor or '',
            state = state, error = problem, attemptedAt = now, renderedAt = self.lastSuccess,
            frames = self.frames, contacts = util.count(tracker.contacts),
        }))
        if ok then self.lastSaved = now; self.lastState = summary end
    end

    function self:draw(title, tracker, status, registry)
        local now = util.now()
        if not config.monitor or config.monitor == '' then
            self.problem = nil
            saveStatus('disabled', nil, now, tracker)
            return true
        end

        local ok, problem = pcall(function()
            local screen, reason = M.inspect(config)
            assert(screen, reason)
            if not self.connected and screen.getTextScale and screen.setTextScale then
                -- Force a fresh terminal surface while restoring the chosen text size.
                local scale = screen.getTextScale()
                local temporary = scale < 5 and scale + 0.5 or scale - 0.5
                local resized, resizeError = pcall(screen.setTextScale, temporary)
                local restored, restoreError = pcall(screen.setTextScale, scale)
                assert(resized and restored, tostring(resizeError or restoreError))
            end
            local stamp = os.date('!%H:%M:%S', math.floor(now / 1000))
            local footer = string.format('PC %s | %s | Updated %s UTC | #%d',
                tostring(config.computer or '?'), config.monitor, stamp, self.frames + 1)
            UI.draw(screen, title, tracker, status, registry, footer)
        end)

        if ok then
            self.connected = true
            self.frames = self.frames + 1
            self.lastSuccess = now
            self.problem = nil
            saveStatus('ok', nil, now, tracker)
            return true
        end

        self.connected = false
        self.problem = tostring(problem):sub(1, 400)
        saveStatus('error', self.problem, now, tracker)
        return false, self.problem
    end

    function self:footer()
        if not config.monitor or config.monitor == '' then return 'No external monitor configured' end
        if self.problem then return config.monitor .. ': OFFLINE - run diagnose' end
        return config.monitor .. ': updated | frame ' .. self.frames
    end

    return self
end

return M

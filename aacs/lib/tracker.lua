local u=require('aacs.lib.util')
local policy=require('aacs.lib.policy')
local M={}

function M.key(c)
    if c.kind=='player' then return 'player:'..c.id:lower() end
    return 'ship:'..c.namespace..':'..c.id
end

function M.new(emit)
    local self={contacts={},sampleMs=10000,staleMs=20000,maxContacts=512}
    self.emit=emit or function() end

    function self:ingest(c,db,now)
        c.sensorKey=M.key(c)
        local subject=policy.identity(db,c,now)
        local key=subject or c.sensorKey
        local old=self.contacts[key]
        local identityChanged=false
        local aliases={}
        -- Remove the old unknown/registered alias when an operator changes a binding.
        for otherKey,contact in pairs(self.contacts) do
            if otherKey~=key and contact.sensorKey==c.sensorKey then
                old=old or contact
                identityChanged=true
                aliases[#aliases+1]=otherKey
            end
        end
        if not old and u.count(self.contacts)>=self.maxContacts then return false,'Contact limit' end
        if old and not identityChanged and c.time<=(old.sourceTimes[c.source] or 0) then return false,'Duplicate/old observation' end
        if old and c.time<old.time then
            old.sourceTimes[c.source]=math.max(old.sourceTimes[c.source] or 0,c.time)
            return false,'Older than merged track'
        end
        -- Do not delete an existing alias until this observation is accepted.
        for _,otherKey in ipairs(aliases) do
            self.contacts[otherKey]=nil
            self.emit({event='identity_reclassified',time=now,key=key,subject=subject,
                previousKey=otherKey,contact=c})
        end
        local decision=policy.evaluate(db,c,now)
        local current=u.copy(c)
        current.key=key; current.subject=subject; current.decision=decision
        current.firstSeen=old and old.firstSeen or c.time
        current.sourceTimes=old and u.copy(old.sourceTimes) or {}
        current.sourceTimes[c.source]=c.time
        current.lastLogged=old and old.lastLogged or 0
        current.conflict=false

        if old then
            local dt=(c.time-old.time)/1000
            local distance=u.distance(old,c)
            if c.dimension~=old.dimension or distance>120+math.max(0,dt)*600 then
                current.conflict=true
                self.emit({event='position_discontinuity',time=now,key=key,contact=c,
                    note='Teleport, inconsistent sensor data, or movement beyond configured plausibility threshold'})
            end
            if not current.conflict and dt>0 and dt<=10 then
                current.speed=distance/dt -- blocks per real second, not radar velocity units
                for _,z in pairs(db.zones) do
                    if not policy.contains(z,old) and not policy.contains(z,c) and policy.intersects(z,old,c) then
                        local allowed,reason=policy.allowed(db,z,c,now)
                        self.emit({event='estimated_crossing',time=now,key=key,subject=subject,
                            zone=z.id,violation=not allowed,reason=reason,contact=c,
                            note='Straight-line estimate between samples; not an observed continuous route'})
                    end
                end
            end
            local previousZones={}
            for _,z in ipairs(old.decision.zones) do previousZones[z.id]=true end
            for _,z in ipairs(decision.zones) do
                if not previousZones[z.id] then self.emit({event='zone_enter',time=c.time,key=key,subject=subject,zone=z.id,contact=c}) end
                previousZones[z.id]=nil
            end
            for z in pairs(previousZones) do self.emit({event='zone_exit',time=c.time,key=key,subject=subject,zone=z,contact=c}) end
        else
            self.emit({event='acquired',time=c.time,key=key,subject=subject,contact=c})
            for _,z in ipairs(decision.zones) do self.emit({event='zone_enter',time=c.time,key=key,subject=subject,zone=z.id,contact=c}) end
        end
        if decision.violation and (not old or not old.decision.violation or old.decision.zone~=decision.zone) then
            self.emit({event='violation',time=c.time,key=key,subject=subject,zone=decision.zone,reason=decision.reason,contact=c})
        elseif old and old.decision.violation and not decision.violation then
            self.emit({event='violation_cleared',time=c.time,key=key,subject=subject,contact=c})
        end
        if c.time-current.lastLogged>=self.sampleMs then
            self.emit({event='position',time=c.time,key=key,subject=subject,contact=c,speed=current.speed})
            current.lastLogged=c.time
        end
        self.contacts[key]=current
        return true,current
    end

    function self:refresh(db,now)
        for _,key in ipairs(u.sorted(self.contacts)) do
            local c=self.contacts[key]
            if c then
            if now-c.time>self.staleMs then
                self.emit({event='lost',time=now,key=key,subject=c.subject,contact=c,
                    note='Coverage ended; NOT evidence of a zone exit or landing'})
                self.contacts[key]=nil
            else
                local subject=policy.identity(db,c,now)
                local currentKey=subject or c.sensorKey
                if currentKey~=key then
                    local merged=self.contacts[currentKey]
                    if merged and merged.time>c.time then
                        merged.sourceTimes[c.source]=math.max(merged.sourceTimes[c.source] or 0,c.time)
                        c=merged
                    else
                        if merged then
                            for source,stamp in pairs(merged.sourceTimes) do
                                c.sourceTimes[source]=math.max(c.sourceTimes[source] or 0,stamp)
                            end
                        end
                        c.key=currentKey;c.subject=subject
                        self.contacts[currentKey]=c
                    end
                    self.contacts[key]=nil
                    self.emit({event='identity_reclassified',time=now,key=currentKey,subject=subject,
                        previousKey=key,contact=c})
                end
                local d=policy.evaluate(db,c,now)
                if d.violation~=c.decision.violation or d.zone~=c.decision.zone then
                    self.emit({event='policy_change',time=now,key=c.key,subject=c.subject,
                        zone=d.zone,violation=d.violation,reason=d.reason,contact=c})
                end
                c.decision=d
            end
            end
        end
    end
    return self
end
return M

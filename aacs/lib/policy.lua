-- All restrictions are cumulative. Exemption from one zone never exempts another.
local u=require('aacs.lib.util')
local M={levels={unrestricted=1,controlled=2,restricted=3,prohibited=4}}

function M.validateZone(z)
    if type(z)~='table' or not u.id(z.id,40) or not u.text(z.name,60)
        or not M.levels[z.class] or not u.dimension(z.dimension)
        or not u.number(z.minY,-1000000,1000000) or not u.number(z.maxY,z.minY,1000000)
        or (z.applies~='ships' and z.applies~='players' and z.applies~='both') then return false,'Invalid zone fields' end
    if z.shape=='box' then
        if not u.number(z.minX,-30000000,30000000) or not u.number(z.maxX,z.minX,30000000)
            or not u.number(z.minZ,-30000000,30000000) or not u.number(z.maxZ,z.minZ,30000000) then return false,'Invalid box' end
    elseif z.shape=='cylinder' then
        if not u.number(z.x,-30000000,30000000) or not u.number(z.z,-30000000,30000000)
            or not u.number(z.radius,1,1000000) then return false,'Invalid cylinder' end
    else return false,'Shape must be box or cylinder' end
    return true
end

function M.applies(z,c)
    return z.enabled~=false and z.dimension==c.dimension
        and (z.applies=='both' or (z.applies=='ships' and c.kind=='ship') or (z.applies=='players' and c.kind=='player'))
end

function M.contains(z,c)
    if not M.applies(z,c) or c.y<z.minY or c.y>z.maxY then return false end
    if z.shape=='box' then return c.x>=z.minX and c.x<=z.maxX and c.z>=z.minZ and c.z<=z.maxZ end
    return (c.x-z.x)^2+(c.z-z.z)^2<=z.radius^2
end

function M.identity(db,c,now)
    if c.kind=='player' and u.uuid(c.id) then
        local id=c.id:lower()
        return 'player:'..id,db.players[id]
    end
    if c.kind=='ship' then
        local binding=db.bindings[c.sensorKey]
        if binding and binding.expires>now then
            return 'vessel:'..binding.registration,db.vessels[binding.registration]
        end
    end
    return nil,nil
end

function M.allowed(db,z,c,now)
    if z.class=='unrestricted' then return true,'Open airspace' end
    local subject,record=M.identity(db,c,now)
    if not subject or not record then return false,'Unidentified or unbound contact' end
    if record.status~='active' then return false,'Registration '..tostring(record.status) end
    if z.class=='controlled' then return true,'Active registration' end
    for _,permit in pairs(db.permits or {}) do
        if permit.subject==subject and permit.zone==z.id and permit.starts<=now
            and permit.expires>now and permit.revoked~=true then return true,'Permit '..permit.id end
    end
    return false,'Explicit zone clearance required'
end

function M.evaluate(db,c,now)
    local result={violation=false,level=0,zone='',reason='Outside configured zones',zones={}}
    for _,id in ipairs(u.sorted(db.zones)) do
        local z=db.zones[id]
        if M.contains(z,c) then
            local allowed,reason=M.allowed(db,z,c,now)
            local level=M.levels[z.class]
            result.zones[#result.zones+1]={id=id,class=z.class,allowed=allowed}
            if not allowed and (not result.violation or level>result.level) then
                result.violation=true; result.level=level; result.zone=id; result.reason=reason
            elseif not result.violation and level>result.level then
                result.level=level; result.zone=id; result.reason=reason
            end
        end
    end
    return result
end

local function interval(lo,hi,p,delta,t0,t1)
    if math.abs(delta)<1e-12 then if p<lo or p>hi then return nil end; return t0,t1 end
    local a,b=(lo-p)/delta,(hi-p)/delta
    if a>b then a,b=b,a end
    t0,t1=math.max(t0,a),math.min(t1,b)
    if t0>t1 then return nil end
    return t0,t1
end

-- Estimated straight-line crossing between samples, never called a confirmed path.
function M.intersects(z,a,c)
    if a.dimension~=c.dimension or not M.applies(z,c) then return false end
    local lo,hi=interval(z.minY,z.maxY,a.y,c.y-a.y,0,1)
    if not lo then return false end
    if z.shape=='box' then
        lo,hi=interval(z.minX,z.maxX,a.x,c.x-a.x,lo,hi)
        if not lo then return false end
        lo,hi=interval(z.minZ,z.maxZ,a.z,c.z-a.z,lo,hi)
        return lo~=nil
    end
    local dx,dz=c.x-a.x,c.z-a.z
    local px,pz=a.x-z.x,a.z-z.z
    local A=dx*dx+dz*dz
    local C=px*px+pz*pz-z.radius*z.radius
    if A<1e-12 then return C<=0 end
    local B=2*(px*dx+pz*dz)
    local disc=B*B-4*A*C
    if disc<0 then return false end
    local r=math.sqrt(disc)
    return math.max(lo,(-B-r)/(2*A))<=math.min(hi,(-B+r)/(2*A))
end

function M.snapshot(db,now)
    local out={revision=db.revision,issued=now,validUntil=now+60000,zones=u.copy(db.zones),
        vessels={},players={},bindings=u.copy(db.bindings),permits=u.copy(db.permits)}
    for id,r in pairs(db.vessels) do out.vessels[id]={name=r.name,nation=r.nation,status=r.status} end
    for id,r in pairs(db.players) do out.players[id]={name=r.name,nation=r.nation,status=r.status} end
    return out
end
return M

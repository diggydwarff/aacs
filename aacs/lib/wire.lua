-- Pairwise, directional keys. No shared national secret, discovery or remote code.
local crypto=require('aacs.lib.crypto')
local util=require('aacs.lib.util')
local store=require('aacs.lib.store')
local M={PROTOCOL='aacs.secure.v1',MAX_PLAIN=12000,MAX_WIRE=25000}
local MAX_SEQ=4503599627370000

local function derive(config,peer,from,to)
    local root=crypto.unhex(peer.key)
    local context='AACS1|'..config.realm..'|'..from..'|'..to..'|'
    return crypto.hmac(root,context..'enc',true),crypto.hmac(root,context..'mac',true)
end
local function header(c,from,to,seq,stamp,cipher)
    return table.concat({'AACS1',c.realm,from,to,string.format('%.0f',seq),string.format('%.0f',stamp),cipher},'|')
end

function M.new(config,root)
    local self={config=config,root=root,keys={},budget={},globalBudget={at=0,n=0}}
    self.state=store.load(root..'/transport.json')
    assert(self.state.realm==config.realm and self.state.node==config.node,'Transport belongs to a different node')
    self.nextSequence=self.state.sentThrough+1
    self.reserved=self.state.sentThrough
    assert(type(self.state.received)=='table','Invalid replay state')

    function self:encode(peerName,body)
        local peer=assert(self.config.peers[peerName],'Unknown peer')
        assert(not peer.revoked,'Peer revoked')
        local plain=util.json(body)
        assert(#plain<=M.MAX_PLAIN,'Packet too large; reduce batch size')
        if self.nextSequence>self.reserved then
            self.reserved=self.nextSequence+127
            assert(self.reserved<MAX_SEQ,'Sequence exhausted; re-key')
            self.state.sentThrough=self.reserved
            store.save(self.root..'/transport.json',self.state)
        end
        local seq=self.nextSequence; self.nextSequence=seq+1
        local enc,mac=derive(self.config,peer,self.config.node,peerName)
        local cipher=crypto.hex(crypto.chacha(enc,crypto.nonce(seq),plain))
        local stamp=util.now()
        local unsigned=header(self.config,self.config.node,peerName,seq,stamp,cipher)
        return unsigned..'|'..crypto.hmac(mac,unsigned),seq
    end

    function self:decode(sender,packet)
        if type(packet)~='string' or #packet>M.MAX_WIRE then return nil,'size' end
        local version,realm,from,to,seqText,timeText,cipher,tag=packet:match('^([^|]+)|([^|]+)|([^|]+)|([^|]+)|(%d+)|(%d+)|([0-9a-f]*)|([0-9a-f]+)$')
        if version~='AACS1' or realm~=self.config.realm or to~=self.config.node or not util.id(from) then return nil,'header' end
        local peer=self.config.peers[from]
        if not peer or peer.revoked or sender~=peer.computer then return nil,'peer' end
        local seq,stamp=tonumber(seqText),tonumber(timeText)
        if not util.integer(seq,1,MAX_SEQ) or not util.integer(stamp,1,9007199254740991)
            or #seqText>16 or #timeText>16 or #tag~=64 or #cipher%2~=0 then return nil,'format' end
        if seq<=(self.state.received[from] or 0) then return nil,'replay' end
        if math.abs(util.now()-stamp)>30000 then return nil,'expired' end

        -- A flood can still jam CC's event queue. These limits bound OUR crypto work.
        local second=math.floor(util.now()/1000)
        local g=self.globalBudget
        if g.at~=second then g.at=second; g.n=0 end
        local budget=self.budget[from] or {at=second,n=0}
        self.budget[from]=budget
        if budget.at~=second then budget.at=second; budget.n=0 end
        if g.n>=80 or budget.n>=20 then return nil,'rate' end
        g.n=g.n+1; budget.n=budget.n+1

        local enc,mac=derive(self.config,peer,from,self.config.node)
        local unsigned=packet:sub(1,#packet-65)
        if not crypto.equal(crypto.hmac(mac,unsigned),tag) then return nil,'authentication' end
        local body=util.decode(crypto.chacha(enc,crypto.nonce(seq),crypto.unhex(cipher)))
        if not body then return nil,'json' end
        -- Persist before delivering. A crash may LOSE a request, never replay it.
        self.state.received[from]=seq
        store.save(self.root..'/transport.json',self.state)
        return {from=from,role=peer.role,body=body,seq=seq,stamp=stamp}
    end

    function self:send(peer,body)
        local packet,seq=self:encode(peer,body)
        rednet.send(self.config.peers[peer].computer,packet,M.PROTOCOL)
        return seq
    end
    return self
end
return M

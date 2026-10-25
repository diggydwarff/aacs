-- AACS cryptographic primitives. No dependencies beyond CC:Tweaked's bit32.
-- ChaCha20 (RFC 8439) + full-length HMAC-SHA256, encrypt-then-MAC.
-- This is NOT the RFC 8439 ChaCha20-Poly1305 construction or an audited library.
local M = {}
local b = assert(bit32, "AACS requires bit32")
local band, bxor, bnot = b.band, b.bxor, b.bnot
local shr, ror, rol = b.rshift, b.rrotate, b.lrotate
local MOD = 4294967296

local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
}

local function be(n)
    return string.char(shr(n,24), band(shr(n,16),255), band(shr(n,8),255), band(n,255))
end

function M.le(n)
    return string.char(band(n,255), band(shr(n,8),255), band(shr(n,16),255), shr(n,24))
end

local function word(s, i, little)
    local a,c,d,e = s:byte(i, i+3)
    if little then return a + c*256 + d*65536 + e*16777216 end
    return a*16777216 + c*65536 + d*256 + e
end

function M.hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

function M.unhex(s)
    assert(type(s)=="string" and #s%2==0 and not s:find('[^0-9a-fA-F]'), "Invalid hex")
    return (s:gsub('..', function(c) return string.char(tonumber(c,16)) end))
end

function M.sha256(message, raw)
    local size = #message
    local data = message .. '\128' .. string.rep('\0', (55-size)%64)
        .. be(math.floor(size/536870912)) .. be((size*8)%MOD)
    local h = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}

    for offset=1,#data,64 do
        local w = {}
        for i=1,16 do w[i] = word(data, offset+(i-1)*4, false) end
        for i=17,64 do
            local x,y = w[i-15],w[i-2]
            w[i] = (w[i-16]+bxor(ror(x,7),ror(x,18),shr(x,3))+w[i-7]
                +bxor(ror(y,17),ror(y,19),shr(y,10)))%MOD
        end
        local a,c,d,e,f,g,j,k = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
        for i=1,64 do
            local t1 = (k+bxor(ror(f,6),ror(f,11),ror(f,25))
                +bxor(band(f,g),band(bnot(f),j))+K[i]+w[i])%MOD
            local t2 = (bxor(ror(a,2),ror(a,13),ror(a,22))
                +bxor(band(a,c),band(a,d),band(c,d)))%MOD
            k,j,g,f,e,d,c,a = j,g,f,(e+t1)%MOD,d,c,a,(t1+t2)%MOD
        end
        local v = {a,c,d,e,f,g,j,k}
        for i=1,8 do h[i]=(h[i]+v[i])%MOD end
    end
    local out = {}
    for i=1,8 do out[i]=be(h[i]) end
    local digest = table.concat(out)
    return raw and digest or M.hex(digest)
end

function M.hmac(key, message, raw)
    if #key>64 then key=M.sha256(key,true) end
    key=key..string.rep('\0',64-#key)
    local inner,outer = {},{}
    for i=1,64 do
        inner[i]=string.char(bxor(key:byte(i),0x36))
        outer[i]=string.char(bxor(key:byte(i),0x5c))
    end
    local digest=M.sha256(table.concat(outer)..M.sha256(table.concat(inner)..message,true),true)
    return raw and digest or M.hex(digest)
end

function M.equal(a,c)
    if type(a)~='string' or type(c)~='string' or #a~=#c then return false end
    local difference=0
    for i=1,#a do difference=b.bor(difference,bxor(a:byte(i),c:byte(i))) end
    return difference==0
end

local function quarter(s,a,c,d,e)
    s[a]=(s[a]+s[c])%MOD; s[e]=rol(bxor(s[e],s[a]),16)
    s[d]=(s[d]+s[e])%MOD; s[c]=rol(bxor(s[c],s[d]),12)
    s[a]=(s[a]+s[c])%MOD; s[e]=rol(bxor(s[e],s[a]),8)
    s[d]=(s[d]+s[e])%MOD; s[c]=rol(bxor(s[c],s[d]),7)
end

function M.chachaBlock(key,nonce,counter)
    assert(#key==32 and #nonce==12, "Invalid ChaCha20 input")
    local initial={0x61707865,0x3320646e,0x79622d32,0x6b206574}
    for i=1,8 do initial[4+i]=word(key,(i-1)*4+1,true) end
    initial[13]=counter
    for i=1,3 do initial[13+i]=word(nonce,(i-1)*4+1,true) end
    local s={}
    for i=1,16 do s[i]=initial[i] end
    for _=1,10 do
        quarter(s,1,5,9,13); quarter(s,2,6,10,14)
        quarter(s,3,7,11,15); quarter(s,4,8,12,16)
        quarter(s,1,6,11,16); quarter(s,2,7,12,13)
        quarter(s,3,8,9,14); quarter(s,4,5,10,15)
    end
    local out={}
    for i=1,16 do out[i]=M.le((s[i]+initial[i])%MOD) end
    return table.concat(out)
end

function M.chacha(key,nonce,data)
    local out={}
    for offset=1,#data,64 do
        local stream=M.chachaBlock(key,nonce,math.floor((offset-1)/64)+1)
        local chunk={}
        for i=1,math.min(64,#data-offset+1) do
            chunk[i]=string.char(bxor(data:byte(offset+i-1),stream:byte(i)))
        end
        out[#out+1]=table.concat(chunk)
    end
    return table.concat(out)
end

-- 64-bit sequence encoded without Lua integer-only operators (CC uses doubles).
function M.nonce(seq)
    return string.rep('\0',4)..M.le(math.floor(seq/MOD))..M.le(seq%MOD)
end

return M

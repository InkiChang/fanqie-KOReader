--[[ SHA-512（FIPS 180-4）—— 纯 Lua / LuaJIT。

为什么需要它：设备注册链里 `tt_encrypt` 用 SHA-512 派生 AES 密钥/IV
（`key/iv = SHA512(SHA512(random32) ‖ fixed)[0:16]/[16:32]`），而 `sign_crypto.lua` 里只有 SHA-256/MD5。

实现要点：SHA-512 是 64 位字运算，而 LuaJIT 的 `bit` 只有 32 位，
所以每个 64 位字用 {lo, hi} 两个半字表示，并自己实现带进位的加法与逻辑右移/循环右移。
（Simon 那边用的是同一套表示法，但那里不需要加法。）
]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local M = {}

local MOD32 = 4294967296

local IV_HEX = "6a09e667f3bcc908 bb67ae8584caa73b 3c6ef372fe94f82b a54ff53a5f1d36f1"
    .. " 510e527fade682d1 9b05688c2b3e6c1f 1f83d9abfb41bd6b 5be0cd19137e2179"

local K_HEX = "428a2f98d728ae22 7137449123ef65cd b5c0fbcfec4d3b2f e9b5dba58189dbbc"
    .. " 3956c25bf348b538 59f111f1b605d019 923f82a4af194f9b ab1c5ed5da6d8118"
    .. " d807aa98a3030242 12835b0145706fbe 243185be4ee4b28c 550c7dc3d5ffb4e2"
    .. " 72be5d74f27b896f 80deb1fe3b1696b1 9bdc06a725c71235 c19bf174cf692694"
    .. " e49b69c19ef14ad2 efbe4786384f25e3 0fc19dc68b8cd5b5 240ca1cc77ac9c65"
    .. " 2de92c6f592b0275 4a7484aa6ea6e483 5cb0a9dcbd41fbd4 76f988da831153b5"
    .. " 983e5152ee66dfab a831c66d2db43210 b00327c898fb213f bf597fc7beef0ee4"
    .. " c6e00bf33da88fc2 d5a79147930aa725 06ca6351e003826f 142929670a0e6e70"
    .. " 27b70a8546d22ffc 2e1b21385c26c926 4d2c6dfc5ac42aed 53380d139d95b3df"
    .. " 650a73548baf63de 766a0abb3c77b2a8 81c2c92e47edaee6 92722c851482353b"
    .. " a2bfe8a14cf10364 a81a664bbc423001 c24b8b70d0f89791 c76c51a30654be30"
    .. " d192e819d6ef5218 d69906245565a910 f40e35855771202a 106aa07032bbd1b8"
    .. " 19a4c116b8d2d0c8 1e376c085141ab53 2748774cdf8eeb99 34b0bcb5e19b48a8"
    .. " 391c0cb3c5c95a63 4ed8aa4ae3418acb 5b9cca4f7763e373 682e6ff3d6b2b8a3"
    .. " 748f82ee5defb2fc 78a5636f43172f60 84c87814a1f0ab72 8cc702081a6439ec"
    .. " 90befffa23631e28 a4506cebde82bde9 bef9a3f7b2c67915 c67178f2e372532b"
    .. " ca273eceea26619c d186b8c721c0c207 eada7dd6cde0eb1e f57d4f7fee6ed178"
    .. " 06f067aa72176fba 0a637dc5a2c898a6 113f9804bef90dae 1b710b35131c471b"
    .. " 28db77f523047d84 32caab7b40c72493 3c9ebe0a15c9bebc 431d67c49c100d4c"
    .. " 4cc5d4becb3e42b6 597f299cfc657e2a 5fcb6fab3ad6faec 6c44198c4a475817"

local function parse_hex_list(s)
    local out = {}
    for h in s:gmatch("%x+") do
        out[#out + 1] = { lo = tonumber(h:sub(9, 16), 16), hi = tonumber(h:sub(1, 8), 16) }
    end
    return out
end

local IV = parse_hex_list(IV_HEX)
local K = parse_hex_list(K_HEX)

-- ── 64 位字运算（{lo, hi}，**分量恒在 0..2^32-1**）──────────────────────
-- 注意：`bit` 库的运算结果是**带符号 32 位**（可能为负）。凡是产生新字的地方都必须
-- 用 mk() 归一化，否则负分量会破坏 uadd2 的进位判断——第一版就栽在这里，
-- 表现是"每个向量都算错、且大输入时 string.char 收到非法值"。
local function n32(x) return x % MOD32 end
local function mk(lo, hi) return { lo = n32(lo), hi = n32(hi) } end

local function uadd2(a, b)
    local lo = a.lo + b.lo
    local carry = 0
    if lo >= MOD32 then lo = lo - MOD32; carry = 1 end
    local hi = a.hi + b.hi + carry
    if hi >= MOD32 then hi = hi - MOD32 end
    return { lo = lo, hi = hi }
end

local function uadd(...)
    local n = select("#", ...)
    local r = select(1, ...)
    for i = 2, n do r = uadd2(r, select(i, ...)) end
    return r
end

local function uxor(...)
    local lo, hi = 0, 0
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        lo = bxor(lo, v.lo)
        hi = bxor(hi, v.hi)
    end
    return mk(lo, hi)
end

local function uand(a, b) return mk(band(a.lo, b.lo), band(a.hi, b.hi)) end
local function unot(a) return mk(bnot(a.lo), bnot(a.hi)) end

local function rotr(v, n)
    n = n % 64
    if n == 0 then return { lo = v.lo, hi = v.hi } end
    if n < 32 then
        return mk(bor(rshift(v.lo, n), lshift(v.hi, 32 - n)),
                  bor(rshift(v.hi, n), lshift(v.lo, 32 - n)))
    end
    local m = n - 32
    return mk(bor(rshift(v.hi, m), lshift(v.lo, 32 - m)),
              bor(rshift(v.lo, m), lshift(v.hi, 32 - m)))
end

local function ushr(v, n)
    n = n % 64
    if n == 0 then return { lo = v.lo, hi = v.hi } end
    if n < 32 then
        return mk(bor(rshift(v.lo, n), lshift(v.hi, 32 - n)), rshift(v.hi, n))
    end
    return mk(rshift(v.hi, n - 32), 0)
end

local function be64(s, off)
    local hi = 0
    local lo = 0
    for i = 0, 3 do hi = hi * 256 + string.byte(s, off + i) end
    for i = 4, 7 do lo = lo * 256 + string.byte(s, off + i) end
    return { lo = lo, hi = hi }
end

local function u64_bytes(v)
    local out = {}
    local hi, lo = v.hi % MOD32, v.lo % MOD32
    for i = 3, 0, -1 do out[#out + 1] = string.char(math.floor(hi / 2 ^ (8 * i)) % 256) end
    for i = 3, 0, -1 do out[#out + 1] = string.char(math.floor(lo / 2 ^ (8 * i)) % 256) end
    return table.concat(out)
end

-- ── 压缩函数 ───────────────────────────────────────────────────────────
local function cf(h, block)
    local w = {}
    for i = 0, 15 do w[i] = be64(block, i * 8 + 1) end
    for t = 16, 79 do
        local s0 = uxor(rotr(w[t - 15], 1), rotr(w[t - 15], 8), ushr(w[t - 15], 7))
        local s1 = uxor(rotr(w[t - 2], 19), rotr(w[t - 2], 61), ushr(w[t - 2], 6))
        w[t] = uadd(w[t - 16], s0, w[t - 7], s1)
    end

    local a, b, c, d = h[1], h[2], h[3], h[4]
    local e, f, g, hh = h[5], h[6], h[7], h[8]

    for t = 0, 79 do
        local S1 = uxor(rotr(e, 14), rotr(e, 18), rotr(e, 41))
        local ch = uxor(uand(e, f), uand(unot(e), g))
        local t1 = uadd(hh, S1, ch, K[t + 1], w[t])
        local S0 = uxor(rotr(a, 28), rotr(a, 34), rotr(a, 39))
        local maj = uxor(uand(a, b), uand(a, c), uand(b, c))
        local t2 = uadd(S0, maj)
        hh = g
        g = f
        f = e
        e = uadd(d, t1)
        d = c
        c = b
        b = a
        a = uadd(t1, t2)
    end

    return {
        uadd(h[1], a), uadd(h[2], b), uadd(h[3], c), uadd(h[4], d),
        uadd(h[5], e), uadd(h[6], f), uadd(h[7], g), uadd(h[8], hh),
    }
end

--- SHA-512，返回 64 字节字符串
function M.hash(msg)
    local len = #msg
    local bitlen = len * 8
    -- 128 位大端长度：高 64 位（我们的输入远不到 2^61 字节，恒为 0）+ 低 64 位
    local lo_len = bitlen % MOD32
    local hi_len = math.floor(bitlen / MOD32)
    local tail = string.char(0, 0, 0, 0, 0, 0, 0, 0)
        .. string.char(math.floor(hi_len / 16777216) % 256, math.floor(hi_len / 65536) % 256,
            math.floor(hi_len / 256) % 256, hi_len % 256)
        .. string.char(math.floor(lo_len / 16777216) % 256, math.floor(lo_len / 65536) % 256,
            math.floor(lo_len / 256) % 256, lo_len % 256)

    local reserve = (len % 128) + 1
    local range_end = 112                     -- 128 - 16
    if range_end < reserve then range_end = range_end + 128 end
    local padded = msg .. "\128" .. string.rep("\0", range_end - reserve) .. tail

    local h = {}
    for i = 1, 8 do h[i] = { lo = IV[i].lo, hi = IV[i].hi } end
    for i = 0, (#padded / 128) - 1 do
        h = cf(h, padded:sub(i * 128 + 1, i * 128 + 128))
    end

    local out = {}
    for i = 1, 8 do out[#out + 1] = u64_bytes(h[i]) end
    return table.concat(out)
end

local HEX = "0123456789abcdef"

function M.hash_hex(msg)
    return (M.hash(msg):gsub(".", function(c)
        local n = string.byte(c)
        return HEX:sub(math.floor(n / 16) + 1, math.floor(n / 16) + 1)
            .. HEX:sub(n % 16 + 1, n % 16 + 1)
    end))
end

return M

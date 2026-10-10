--[[ SM3 哈希（GB/T 32905-2016）—— 纯 Lua / LuaJIT，无外部依赖。

为什么单独一个模块：番茄移动端签名里，bodyHash 与 queryHash 都是 **SM3 取前 6 字节**，
而 `sign_crypto.lua` 里已有的 SHA-256/MD5 都不适用。这个模块只做 SM3，便于单独用向量验证。

用到的位运算来自 LuaJIT 的 `bit` 库（KOReader 的运行时自带）。
]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol, tobit = bit.rol, bit.tobit

local M = {}

local IV = {
    0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
    0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
}

local function p0(x) return bxor(x, rol(x, 9), rol(x, 17)) end
local function p1(x) return bxor(x, rol(x, 15), rol(x, 23)) end

local function ff(x, y, z, j)
    if j < 16 then return bxor(x, y, z) end
    return bor(band(x, y), band(x, z), band(y, z))
end

local function gg(x, y, z, j)
    if j < 16 then return bxor(x, y, z) end
    return bor(band(x, y), band(bnot(x), z))
end

-- 压缩函数：v 是 8 个字的表（会被就地替换成新表）
local function cf(v, block)
    local w = {}
    for i = 0, 15 do
        local o = i * 4 + 1
        w[i] = bor(
            bit.lshift(string.byte(block, o), 24),
            bit.lshift(string.byte(block, o + 1), 16),
            bit.lshift(string.byte(block, o + 2), 8),
            string.byte(block, o + 3))
    end
    for j = 16, 67 do
        local t = bxor(w[j - 16], w[j - 9], rol(w[j - 3], 15))
        w[j] = bxor(p1(t), rol(w[j - 13], 7), w[j - 6])
    end
    local w1 = {}
    for j = 0, 63 do w1[j] = bxor(w[j], w[j + 4]) end

    local a, b, c, d = v[1], v[2], v[3], v[4]
    local e, f, g, h = v[5], v[6], v[7], v[8]

    for j = 0, 63 do
        local tj = (j < 16) and 0x79cc4519 or 0x7a879d8a
        local ss1 = rol(tobit(rol(a, 12) + e + rol(tj, j % 32)), 7)
        local ss2 = bxor(ss1, rol(a, 12))
        local tt1 = tobit(ff(a, b, c, j) + d + ss2 + w1[j])
        local tt2 = tobit(gg(e, f, g, j) + h + ss1 + w[j])
        d = c
        c = rol(b, 9)
        b = a
        a = tt1
        h = g
        g = rol(f, 19)
        f = e
        e = p0(tt2)
    end

    return {
        bxor(a, v[1]), bxor(b, v[2]), bxor(c, v[3]), bxor(d, v[4]),
        bxor(e, v[5]), bxor(f, v[6]), bxor(g, v[7]), bxor(h, v[8]),
    }
end

--- 计算 SM3，返回 32 字节的 Lua 字符串。
function M.hash(msg)
    local len = #msg
    -- 填充：0x80，若干 0x00，最后 8 字节大端比特长度。
    -- 这里刻意与 Python 参考实现同构（reserve / range_end 的写法），避免 off-by-one。
    local reserve = (len % 64) + 1
    local range_end = 56
    if range_end < reserve then range_end = range_end + 64 end
    local zeros = string.rep("\0", range_end - reserve)
    local bitlen = len * 8
    -- 8 字节大端；len*8 在 Lua double 里精确（现实长度远小于 2^53）
    local hi = math.floor(bitlen / 4294967296) % 4294967296
    local lo = bitlen % 4294967296
    local tail = string.char(
        math.floor(hi / 16777216) % 256, math.floor(hi / 65536) % 256,
        math.floor(hi / 256) % 256, hi % 256,
        math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256,
        math.floor(lo / 256) % 256, lo % 256)
    local padded = msg .. "\128" .. zeros .. tail

    local v = {}
    for i = 1, 8 do v[i] = IV[i] end
    for i = 0, (#padded / 64) - 1 do
        v = cf(v, padded:sub(i * 64 + 1, i * 64 + 64))
    end

    local out = {}
    for i = 1, 8 do
        local x = v[i] % 4294967296
        out[#out + 1] = string.char(
            math.floor(x / 16777216) % 256, math.floor(x / 65536) % 256,
            math.floor(x / 256) % 256, x % 256)
    end
    return table.concat(out)
end

local HEX = "0123456789abcdef"

function M.hash_hex(msg)
    local b = M.hash(msg)
    return (b:gsub(".", function(c)
        local n = string.byte(c)
        return HEX:sub(math.floor(n / 16) + 1, math.floor(n / 16) + 1)
            .. HEX:sub(n % 16 + 1, n % 16 + 1)
    end))
end

--- 签名里用的是「SM3 的前 6 字节」。
function M.prefix6(msg)
    return M.hash(msg):sub(1, 6)
end

return M

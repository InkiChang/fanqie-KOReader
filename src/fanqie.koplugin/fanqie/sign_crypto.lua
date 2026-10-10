--- 番茄小说字节系风控签名的**纯密码学原语**（纯 Lua 5.1 / LuaJIT，不用 ffi）。
--
-- 这个模块对应 Python 参考实现 `fanqie_sign.py`（照抄 linzj/fanqie-dl，MIT）。
-- 它只做**与密钥无关**的部分：哈希 / base64 / AES-128 / X-Ladon 的 Speck 风格
-- 轮函数 / protobuf 写入器，以及 X-Argus 的整条流水线骨架。
--
-- 为什么单独成一个文件、而不塞进 fanqie/crypto.lua：
--   1. crypto.lua 已经有 md5_hex，但这边还要 SHA-256 / AES-128 / Speck；
--      混进去会让那个文件的职责从"一个小工具"变成"半个密码学库"。
--   2. 真机移植（Kindle）时要能**整文件**审一遍——风险全集中在这里。
--   3. AES 的 round key、S 盒是载入时算出来的：任何一个算错都会让后续所有
--      字节全错，所以载入即自检（FIPS-197 / NIST SP800-38A），坏掉就立刻报错，
--      而不是等到设备上拿到一段"看起来正常"的签名。
--
-- 与 Python 参考实现对齐时**刻意保留的三个怪癖**（照抄，不"修正"）：
--   * write_varint 把值先截断成 u32（`v &= 0xFFFFFFFF`），循环条件是 `v > 0x80`
--     （不是 `>=`）——0x80..0xFF 会被多写一个续延字节。
--   * pkcs7 对**已对齐**数据仍然追加一整块（`n = bs - len % bs`）。
--   * get_sign 里 CBC 之前先手工 pkcs7 一次，CBC 再 pad 一次。
-- 改动这三处都会让签名字节与线上不一致。
--
-- 随机量（get_sign 的 rand_val、ladon 的 rand4）全部走**可注入参数**：
-- 不传才去读随机源。测试必须传死值，否则无法逐字节比对。

-- ── bit 库（LuaJIT 自带；缺了就明确报错，不做静默兜底）─────────────────

local ok_bit, bit = pcall(require, "bit")
if not ok_bit or not bit then
    error("fanqie.sign_crypto 需要 LuaJIT 的 bit 库（require('bit') 失败）："
        .. tostring(bit), 0)
end

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, ror = bit.lshift, bit.rshift, bit.rol, bit.ror

local M32 = 0xffffffff
local byte, char, rep, format = string.byte, string.char, string.rep, string.format
local floor, sin, abs, random = math.floor, math.sin, math.abs, math.random
local concat = table.concat
-- LuaJIT/Lua 5.1 是全局 unpack，5.2+ 挪进了 table。取一次存成局部变量：
-- 写成 `unpack and unpack(t) or table.unpack(t)` 是**错的**——and/or 只会保留
-- 第一个返回值，char() 就只拿到 1 个字节。
local unpack_ = table.unpack or unpack

--- 归一化成 [0, 2^32) 的**无符号** Lua 数字。
--
-- 关键：LuaJIT 的 bit.* 返回的是**有符号** int32——`band(0xdeadbeef, 0xffffffff)`
-- 得到的是 -559038737，不是 3735928559。位模式虽然对，但只要后面出现
-- `>` 比较（varint 的 `while v > 0x80`）、`>= 2^32` 进位判断、或者要拿去做
-- 十进制算术，就会静默出错。所以凡是"当数值用"的地方都必须过一遍 u32()。
local function u32(n)
    local r = band(n, M32)
    if r < 0 then
        r = r + 4294967296
    end
    return r
end

-- ── 小工具 ────────────────────────────────────────────────────────────

local function to_bytes(v)
    if v == nil then return "" end
    return tostring(v)
end

local function hex_encode(s)
    local out = {}
    for i = 1, #s do
        out[i] = format("%02x", byte(s, i))
    end
    return concat(out)
end

--- 十六进制字符串 → 字节。非法输入返回 nil（调用方自己决定怎么兜底）。
local function hex_decode(s)
    if type(s) ~= "string" then return nil end
    if #s % 2 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 2 do
        local b = tonumber(s:sub(i, i + 1), 16)
        if not b then return nil end
        out[#out + 1] = b
    end
    return char(unpack_(out))
end

-- ── SHA-256 ───────────────────────────────────────────────────────────

-- FIPS 180-4 的 64 个轮常量：前 64 个素数立方根小数部分的前 32 位。
-- 这里直接写死而不是用 `i^(1/3)` 现算——那是**前 64 个整数**的立方根，
-- 跟标准值完全不是一回事（K[1] 应该是 0x428a2f98，不是 0）。
local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- SHA-256，返回 32 字节二进制串（不是 hex）。
local function sha256(data)
    data = to_bytes(data)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local bitlen = #data * 8
    local padded = data .. char(0x80)
    padded = padded .. rep("\0", (56 - #padded % 64) % 64)
    -- 消息长度按 64 位大端追加（Lua 数字只有 53 位精度，高位按 0 处理；
    -- 单条签名消息远小于 2^53 位，够用）
    local hi = floor(bitlen / 4294967296)
    local lo = bitlen % 4294967296
    padded = padded .. char(
        band(rshift(hi, 24), 0xff), band(rshift(hi, 16), 0xff),
        band(rshift(hi, 8), 0xff), band(hi, 0xff),
        band(rshift(lo, 24), 0xff), band(rshift(lo, 16), 0xff),
        band(rshift(lo, 8), 0xff), band(lo, 0xff))

    local w = {}
    for chunk = 1, #padded, 64 do
        for i = 0, 15 do
            local o = chunk + i * 4
            w[i + 1] = bor(lshift(byte(padded, o), 24),
                lshift(byte(padded, o + 1), 16),
                lshift(byte(padded, o + 2), 8),
                byte(padded, o + 3))
        end
        for i = 17, 64 do
            local x = w[i - 15]
            local y = w[i - 2]
            local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
            local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
            w[i] = u32(w[i - 16] + s0 + w[i - 7] + s1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, hh = h4, h5, h6, h7
        for i = 1, 64 do
            local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = u32(hh + S1 + ch + SHA256_K[i] + w[i])
            local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = u32(S0 + maj)
            hh, g, f, e = g, f, e, u32(d + t1)
            d, c, b, a = c, b, a, u32(t1 + t2)
        end

        h0 = u32(h0 + a); h1 = u32(h1 + b); h2 = u32(h2 + c); h3 = u32(h3 + d)
        h4 = u32(h4 + e); h5 = u32(h5 + f); h6 = u32(h6 + g); h7 = u32(h7 + hh)
    end

    local out = {}
    for i, hv in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
        out[i] = char(
            band(rshift(hv, 24), 0xff), band(rshift(hv, 16), 0xff),
            band(rshift(hv, 8), 0xff), band(hv, 0xff))
    end
    return concat(out)
end

local function sha256_hex(data)
    return hex_encode(sha256(data))
end

-- ── MD5 ───────────────────────────────────────────────────────────────

local MD5_S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local MD5_K = {}
for i = 1, 64 do
    MD5_K[i] = floor(abs(sin(i)) * 4294967296)
end

local function md5(data)
    data = to_bytes(data)
    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

    local bitlen = #data * 8
    local padded = data .. char(0x80)
    padded = padded .. rep("\0", (56 - #padded % 64) % 64)
    local lo = bitlen % 4294967296
    padded = padded .. char(
        band(lo, 0xff), band(rshift(lo, 8), 0xff),
        band(rshift(lo, 16), 0xff), band(rshift(lo, 24), 0xff),
        0, 0, 0, 0)   -- 长度低 32 位在前，高 32 位恒 0（消息 < 2^32 位）

    local m = {}
    for chunk = 1, #padded, 64 do
        for i = 0, 15 do
            local o = chunk + i * 4
            m[i] = bor(byte(padded, o), lshift(byte(padded, o + 1), 8),
                lshift(byte(padded, o + 2), 16), lshift(byte(padded, o + 3), 24))
        end

        local a, b, c, d = a0, b0, c0, d0
        for i = 1, 64 do
            local f, g
            if i <= 16 then
                f = bor(band(b, c), band(bnot(b), d)); g = i - 1
            elseif i <= 32 then
                f = bor(band(d, b), band(bnot(d), c)); g = (5 * (i - 1) + 1) % 16
            elseif i <= 48 then
                f = bxor(b, c, d); g = (3 * (i - 1) + 5) % 16
            else
                f = bxor(c, bor(b, bnot(d))); g = (7 * (i - 1)) % 16
            end
            local tmp = d
            d = c
            c = b
            b = u32(b + rol(u32(a + f + MD5_K[i] + m[g]), MD5_S[i]))
            a = tmp
        end

        a0 = u32(a0 + a); b0 = u32(b0 + b)
        c0 = u32(c0 + c); d0 = u32(d0 + d)
    end

    local out = {}
    local function put(idx, v)
        out[#out + 1] = char(band(v, 0xff), band(rshift(v, 8), 0xff),
            band(rshift(v, 16), 0xff), band(rshift(v, 24), 0xff))
    end
    put(1, a0); put(2, b0); put(3, c0); put(4, d0)
    return concat(out)
end

local function md5_hex(data)
    return hex_encode(md5(data))
end

-- ── base64（标准表，带 '=' 补齐；不解码，签名方向用不到）───────────────

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    data = to_bytes(data)
    local out = {}
    local n = #data
    for i = 1, n - n % 3, 3 do
        local b1, b2, b3 = byte(data, i), byte(data, i + 1), byte(data, i + 2)
        out[#out + 1] = B64:sub(rshift(b1, 2) + 1, rshift(b1, 2) + 1)
            .. B64:sub(band(lshift(b1, 4), 0x30) + rshift(b2, 4) + 1,
                band(lshift(b1, 4), 0x30) + rshift(b2, 4) + 1)
            .. B64:sub(band(lshift(b2, 2), 0x3c) + rshift(b3, 6) + 1,
                band(lshift(b2, 2), 0x3c) + rshift(b3, 6) + 1)
            .. B64:sub(band(b3, 0x3f) + 1, band(b3, 0x3f) + 1)
    end
    local rem = n % 3
    if rem == 1 then
        local b1 = byte(data, n)
        out[#out + 1] = B64:sub(rshift(b1, 2) + 1, rshift(b1, 2) + 1)
            .. B64:sub(band(lshift(b1, 4), 0x30) + 1, band(lshift(b1, 4), 0x30) + 1)
            .. "=="
    elseif rem == 2 then
        local b1, b2 = byte(data, n - 1), byte(data, n)
        out[#out + 1] = B64:sub(rshift(b1, 2) + 1, rshift(b1, 2) + 1)
            .. B64:sub(band(lshift(b1, 4), 0x30) + rshift(b2, 4) + 1,
                band(lshift(b1, 4), 0x30) + rshift(b2, 4) + 1)
            .. B64:sub(band(lshift(b2, 2), 0x3c) + 1, band(lshift(b2, 2), 0x3c) + 1)
            .. "="
    end
    return concat(out)
end

-- ── pkcs7 ─────────────────────────────────────────────────────────────

--- PKCS#7 填充。
--
-- 注意：**已对齐的数据仍然追加一整块**（与 Python 参考实现一致）。
-- 标准 PKCS#7 本来就是这个语义，但很多手写实现会写成 `if #data % bs == 0 then
-- return data end`。那样在这里会少一块，整条 CBC 结果偏移 16 字节。
local function pkcs7_pad(data, block_size)
    data = to_bytes(data)
    block_size = block_size or 16
    local n = block_size - (#data % block_size)
    return data .. rep(char(n), n)
end

-- ── AES-128（ECB / CBC 加密）──────────────────────────────────────────

--- S 盒：按 FIPS-197 的构造法现场算出（与 Python 参考实现同一套循环）。
local function build_sbox()
    local sbox = {}
    local p, q = 1, 1
    while true do
        -- p *= 3 in GF(2^8)
        p = bxor(p, band(lshift(p, 1), 0xff), band(p, 0x80) ~= 0 and 0x1b or 0)
        -- q /= 3
        q = bxor(q, band(lshift(q, 1), 0xff))
        q = bxor(q, band(lshift(q, 2), 0xff))
        q = bxor(q, band(lshift(q, 4), 0xff))
        q = band(q, 0xff)
        if band(q, 0x80) ~= 0 then
            q = bxor(q, 0x09)
        end
        local x = bxor(q,
            bor(band(lshift(q, 1), 0xff), rshift(q, 7)),
            bor(band(lshift(q, 2), 0xff), rshift(q, 6)),
            bor(band(lshift(q, 3), 0xff), rshift(q, 5)),
            bor(band(lshift(q, 4), 0xff), rshift(q, 4)))
        sbox[p] = band(bxor(x, 0x63), 0xff)
        if p == 1 then break end
    end
    sbox[0] = 0x63
    return sbox
end

local SBOX = build_sbox()
local RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 }

local function xtime(a)
    a = lshift(a, 1)
    if band(a, 0x100) ~= 0 then
        return band(bxor(a, 0x1b), 0xff)
    end
    return a
end

local function word_at(s, i)
    return bor(byte(s, i), lshift(byte(s, i + 1), 8),
        lshift(byte(s, i + 2), 16), lshift(byte(s, i + 3), 24))
end

local function word_bytes(w)
    return char(band(w, 0xff), band(rshift(w, 8), 0xff),
        band(rshift(w, 16), 0xff), band(rshift(w, 24), 0xff))
end

--- 密钥扩展：支持 AES-128/192/256（16/24/32 字节密钥）。
--- 返回 rk[1..nr+1]，每项是 16 字节字符串；nr = #key/4 + 6。
local function expand_key(key)
    if type(key) ~= "string" or (#key ~= 16 and #key ~= 24 and #key ~= 32) then
        error("aes 需要 16/24/32 字节密钥（实际 " .. tostring(key and #key or "nil") .. "）", 0)
    end
    local nk = #key / 4
    local nr = nk + 6
    local total = 4 * (nr + 1)
    local w = {}
    for i = 0, nk - 1 do
        w[i] = word_at(key, i * 4 + 1)
    end
    for i = nk, total - 1 do
        local t = w[i - 1]
        if i % nk == 0 then
            -- RotWord + SubWord + Rcon
            local b0 = band(rshift(t, 8), 0xff)
            local b1 = band(rshift(t, 16), 0xff)
            local b2 = band(rshift(t, 24), 0xff)
            local b3 = band(t, 0xff)
            t = bor(
                SBOX[b0], lshift(SBOX[b1], 8),
                lshift(SBOX[b2], 16), lshift(SBOX[b3], 24))
            t = bxor(t, RCON[i / nk])
        elseif nk > 6 and i % nk == 4 then
            -- AES-256 特有的额外 SubWord：**只做 SubWord，不做 RotWord**。
            -- （上面那个分支是 RotWord+SubWord；这里若照抄成同样带旋转的写法，
            --   就只有在 24/32 字节密钥下才会静默出错——所以由 NIST 向量盯着。）
            t = bor(
                SBOX[band(t, 0xff)],
                lshift(SBOX[band(rshift(t, 8), 0xff)], 8),
                lshift(SBOX[band(rshift(t, 16), 0xff)], 16),
                lshift(SBOX[band(rshift(t, 24), 0xff)], 24))
        end
        w[i] = bxor(w[i - nk], t)
    end
    local rk = {}
    for r = 0, nr do
        rk[r + 1] = word_bytes(w[r * 4]) .. word_bytes(w[r * 4 + 1])
            .. word_bytes(w[r * 4 + 2]) .. word_bytes(w[r * 4 + 3])
    end
    return rk
end

--- 单块加密（16 字节 → 16 字节）。
local function aes_encrypt_block(block, rk)
    local s = {}
    for i = 0, 15 do
        s[i] = bxor(byte(block, i + 1), byte(rk[1], i + 1))
    end
    local nr = #rk - 1
    for rnd = 1, nr do
        for i = 0, 15 do
            s[i] = SBOX[s[i]]
        end
        -- ShiftRows：状态按列主序存放（s[c*4+r]）
        local shifted = {}
        for c = 0, 3 do
            for r = 0, 3 do
                shifted[c * 4 + r] = s[((c + r) % 4) * 4 + r]
            end
        end
        s = shifted
        if rnd ~= nr then
            local mixed = {}
            for c = 0, 3 do
                local a0, a1 = s[c * 4], s[c * 4 + 1]
                local a2, a3 = s[c * 4 + 2], s[c * 4 + 3]
                local t = bxor(a0, a1, a2, a3)
                mixed[c * 4] = bxor(a0, t, xtime(bxor(a0, a1)))
                mixed[c * 4 + 1] = bxor(a1, t, xtime(bxor(a1, a2)))
                mixed[c * 4 + 2] = bxor(a2, t, xtime(bxor(a2, a3)))
                mixed[c * 4 + 3] = bxor(a3, t, xtime(bxor(a3, a0)))
            end
            s = mixed
        end
        local rkstr = rk[rnd + 1]
        for i = 0, 15 do
            s[i] = bxor(s[i], byte(rkstr, i + 1))
        end
    end
    local out = {}
    for i = 0, 15 do
        out[i + 1] = char(s[i])
    end
    return concat(out)
end

--- AES-128-ECB 加密。**不做填充**：data 长度必须是 16 的倍数（与 Python 一致）。
local function aes128_ecb_encrypt(data, key)
    data = to_bytes(data)
    local rk = expand_key(key)
    local out = {}
    for i = 1, #data, 16 do
        out[#out + 1] = aes_encrypt_block(data:sub(i, i + 15), rk)
    end
    return concat(out)
end

--- AES-128-CBC 加密。**不做填充**（与 Python 一致），data 长度必须是 16 的倍数。
local function aes128_cbc_encrypt(data, key, iv)
    data = to_bytes(data)
    if type(iv) ~= "string" or #iv ~= 16 then
        error("aes128_cbc 需要 16 字节 IV（实际 " .. tostring(iv and #iv or "nil") .. "）", 0)
    end
    local rk = expand_key(key)
    local prev = iv
    local out = {}
    for i = 1, #data, 16 do
        local blk = data:sub(i, i + 15)
        local x = {}
        for j = 1, 16 do
            x[j] = char(bxor(byte(blk, j), byte(prev, j)))
        end
        prev = aes_encrypt_block(concat(x), rk)
        out[#out + 1] = prev
    end
    return concat(out)
end

-- ── AES 解密（CM 握手解正文要用；支持 16/24/32 字节密钥）──────────────
-- 逆 S 盒由正 S 盒反演得到，省掉一张 256 项的硬编码表（少一处抄错的机会）。
local INV_SBOX = {}
for i = 0, 255 do INV_SBOX[SBOX[i]] = i end

local function gf_mul(a, b)
    local r = 0
    for _ = 1, 8 do
        if band(b, 1) == 1 then r = bxor(r, a) end
        b = rshift(b, 1)
        local hi = band(a, 0x80)
        a = band(lshift(a, 1), 0xff)
        if hi ~= 0 then a = bxor(a, 0x1b) end
    end
    return r
end

local function aes_decrypt_block(block, rk)
    local nr = #rk - 1
    local s = {}
    for i = 0, 15 do s[i] = bxor(byte(block, i + 1), byte(rk[nr + 1], i + 1)) end
    for rnd = nr - 1, 0, -1 do
        -- InvShiftRows（状态列主序 s[c*4+r]）
        local shifted = {}
        for c = 0, 3 do
            for r = 0, 3 do shifted[c * 4 + r] = s[((c - r) % 4) * 4 + r] end
        end
        s = shifted
        for i = 0, 15 do s[i] = INV_SBOX[s[i]] end
        local rkstr = rk[rnd + 1]
        for i = 0, 15 do s[i] = bxor(s[i], byte(rkstr, i + 1)) end
        if rnd ~= 0 then
            local mixed = {}
            for c = 0, 3 do
                local a0, a1 = s[c * 4], s[c * 4 + 1]
                local a2, a3 = s[c * 4 + 2], s[c * 4 + 3]
                mixed[c * 4] = bxor(gf_mul(a0, 14), gf_mul(a1, 11), gf_mul(a2, 13), gf_mul(a3, 9))
                mixed[c * 4 + 1] = bxor(gf_mul(a0, 9), gf_mul(a1, 14), gf_mul(a2, 11), gf_mul(a3, 13))
                mixed[c * 4 + 2] = bxor(gf_mul(a0, 13), gf_mul(a1, 9), gf_mul(a2, 14), gf_mul(a3, 11))
                mixed[c * 4 + 3] = bxor(gf_mul(a0, 11), gf_mul(a1, 13), gf_mul(a2, 9), gf_mul(a3, 14))
            end
            s = mixed
        end
    end
    local out = {}
    for i = 0, 15 do out[i + 1] = char(s[i]) end
    return concat(out)
end

--- AES-CBC 解密。**不去填充**（与 Python 一致）：调用方自己处理 PKCS7。
local function aes_cbc_decrypt(data, key, iv)
    data = to_bytes(data)
    if type(iv) ~= "string" or #iv ~= 16 then
        error("aes_cbc_decrypt 需要 16 字节 IV（实际 " .. tostring(iv and #iv or "nil") .. "）", 0)
    end
    local rk = expand_key(key)
    local prev = iv
    local out = {}
    for i = 1, #data, 16 do
        local blk = data:sub(i, i + 15)
        local dec = aes_decrypt_block(blk, rk)
        local x = {}
        for j = 1, 16 do x[j] = char(bxor(byte(dec, j), byte(prev, j))) end
        out[#out + 1] = concat(x)
        prev = blk
    end
    return concat(out)
end

-- ── X-Ladon：Speck 风格轮函数（64 位，用高低 32 位两个字模拟）──────────

--- 读 n 字节随机量。默认 /dev/urandom（Kindle/Android 都有）；失败退回 math.random。
--
-- 注意：签名函数里**不要**依赖它来求值——测试必须走可注入的 rand 参数，
-- 否则结果不可复现。它只服务于真机上的默认路径。

-- math.random 不播种时序列是固定的：写盘上等于每次启动都拿到同一组 rand_val /
-- rand4，那不只是"不够随机"，而是**签名复用**。所以退回分支必须先播种。
--
-- 但也不能在模块加载时就播种：math.randomseed 动的是全局状态，会把其他模块
-- （main/download 等）自己的随机序列一起搅掉，那不是本模块该管的事。
-- 折中：只在**真的**要走 math.random 时播种一次，且只用一次性熵源。
local seeded = false
local function seed_once()
    if seeded then return end
    seeded = true
    -- 三个熵源都不够好，但坏在不同位上：
    --   * tostring({}) 的地址带 ASLR——**高位**会变，低位因为堆布局固定反而不变；
    --   * os.time 只到秒；
    --   * os.clock 是进程 CPU 时间，同一份工作量下两次启动几乎相同。
    -- 所以不能截低位当种子（第一版写 `addr % 1000` 就是这么错的，实测两个
    -- 进程拿到同一串字节）。先用 md5 把这堆东西打散，让任意一位的变化都扩散
    -- 到种子的每个字节，再播种。
    local raw = format("%s|%d|%d", tostring({}), os.time(),
        floor(os.clock() * 1000000))
    local d = md5(raw)
    local s = byte(d, 1) + byte(d, 2) * 256 + byte(d, 3) * 65536
        + byte(d, 4) * 16777216
    math.randomseed(s % 2147483647)
    for _ = 1, 8 do random() end   -- 丢掉最初几个，避开弱自相关
end

local function random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local got = f:read(n)
        f:close()
        if got and #got == n then
            return got
        end
    end
    seed_once()
    local out = {}
    for i = 1, n do
        out[i] = char(random(0, 255))
    end
    return concat(out)
end

--- 与 Python 的 `int.from_bytes(os.urandom(4), "little") & 0x7FFFFFFF` 同语义。
local function random_u31()
    local b = random_bytes(4)
    local v = byte(b, 1) + byte(b, 2) * 256 + byte(b, 3) * 65536
        + byte(b, 4) * 16777216
    return v % 2147483648
end

--- 64 位量拆成两个 32 位字。本模块只需要"加法 + 循环右移 + 异或"三种运算。
local function u64(hi, lo)
    return { hi = u32(hi), lo = u32(lo) }
end

--- 64 位循环右移（模 2^64），c 会被归一到 [0,63]。
--
-- 不用 Lua 5.3 的整数（KOReader 是 5.1/LuaJIT），而是用高低两个字手工拼——
-- 这样任何中间值都不会超过 2^32，双精度存得下，结果必然精确。
-- 与 Python 的 `_ror64` 逐位等价。
local function ror64(v, c)
    c = c % 64
    if c == 0 then
        return u64(v.hi, v.lo)
    end
    local hi, lo = v.hi, v.lo
    if c < 32 then
        return u64(bor(rshift(hi, c), lshift(lo, 32 - c)),
            bor(rshift(lo, c), lshift(hi, 32 - c)))
    end
    local d = c - 32
    return u64(bor(rshift(lo, d), lshift(hi, 32 - d)),
        bor(rshift(hi, d), lshift(lo, 32 - d)))
end

--- 64 位加法（mod 2^64）：先加低字，溢出就进一位。
local function u64_add(a, b)
    local lo = a.lo + b.lo
    local carry = 0
    if lo >= 4294967296 then
        lo = lo - 4294967296
        carry = 1
    end
    return u64(a.hi + b.hi + carry, lo)
end

local function u64_xor(a, b)
    return u64(bxor(a.hi, b.hi), bxor(a.lo, b.lo))
end

--- 第 i 个字节（1-based）；字符串或「1-based 字节表」都接受，越界按 0。
-- 轮常量表在展开过程中是表、物化之后是字符串，两种形态都要能读。
local function at8(s, i)
    if type(s) == "string" then
        return byte(s, i) or 0
    end
    return s[i] or 0
end

--- 从 off+1 开始读 8 字节小端（越界按 0，与 Python 的零填充块等价）。
local function read_le64(s, off)
    local b = {}
    for i = 0, 7 do
        b[i] = at8(s, off + i + 1)
    end    return u64(
        bor(b[4], lshift(b[5], 8), lshift(b[6], 16), lshift(b[7], 24)),
        bor(b[0], lshift(b[1], 8), lshift(b[2], 16), lshift(b[3], 24)))
end

local function write_le64(v)
    local bl, bh = v.lo, v.hi
    return char(
        band(bl, 0xff), band(rshift(bl, 8), 0xff),
        band(rshift(bl, 16), 0xff), band(rshift(bl, 24), 0xff),
        band(bh, 0xff), band(rshift(bh, 8), 0xff),
        band(rshift(bh, 16), 0xff), band(rshift(bh, 24), 0xff))
end

--- Speck 风格的一轮组（0x22 = 34 轮），输入输出都是 16 字节。
local function ladon_block(ht, inp)
    local d0 = read_le64(inp, 0)
    local d1 = read_le64(inp, 8)
    for i = 0, 0x21 do
        local h = read_le64(ht, i * 8)
        d1 = u64_xor(h, u64_add(d0, ror64(d1, 8)))
        d0 = u64_xor(d1, ror64(d0, 0x3d))
    end
    return write_le64(d0) .. write_le64(d1)
end

--- 由 4 字节随机量展开出 34 个 8 字节轮常量（存在 1-based 字节表里，越界即 0）。
local function ladon_round_table(rand4, aid)
    local md5hex = md5_hex(rand4 .. tostring(aid))
    -- Python 是 `ht[0:32] = md5hex[:32]`：把**32 个 ASCII 十六进制字符本身**
    -- 当字节写进去，不是把 hex 解码成 16 字节。别"优化"成解码。
    local ht = {}
    for i = 1, 32 do
        ht[i] = byte(md5hex, i)
    end

    -- 初始四个 64 位字（temp 的滑动窗口）
    local temp = {}
    for i = 0, 3 do
        temp[i + 1] = read_le64(ht, i * 8)
    end
    local b0, b8 = temp[1], temp[2]
    table.remove(temp, 1)
    table.remove(temp, 1)

    for i = 0, 0x21 do
        -- x9/x8 就是 Python 里的 b0/b8（同一个滑动窗口的前两个元素）
        local x9 = b0
        local x8 = u64_add(ror64(b8, 8), x9)
        -- Python 是 `x8 ^= i`（对一个 64 位整数异或小整数），所以 i 落在**低字**。
        x8 = u64_xor(x8, u64(0, i))
        temp[#temp + 1] = x8
        x8 = u64_xor(x8, ror64(x9, 61))
        local bytes = write_le64(x8)
        for j = 0, 7 do
            ht[(i + 1) * 8 + j + 1] = byte(bytes, j + 1)
        end
        b0, b8 = x8, temp[1]
        table.remove(temp, 1)
    end

    -- 物化成 Python `bytes(ht)` 那样的扁平字节串（未写到的位置补 0）。
    -- 长度取 288（= 272+16），与参考实现里 bytearray 的初始长度一致。
    local flat = {}
    for i = 1, 288 do
        flat[i] = char(ht[i] or 0)
    end
    return concat(flat), md5hex
end

--- X-Ladon 签名。不需要任何密钥。
--
-- `rand4` 是 4 字节随机量（**必须可注入**，否则结果每次都不同）。
-- 不传时读 /dev/urandom，失败退回 math.random。
local function ladon(khronos, lc_id, aid, rand4)
    if rand4 == nil then
        rand4 = random_bytes(4)
    end
    if #rand4 ~= 4 then
        error("ladon 的 rand4 必须是 4 字节（实际 " .. tostring(#rand4) .. "）", 0)
    end
    local data = tostring(khronos) .. "-" .. tostring(lc_id) .. "-" .. tostring(aid)
    local ht = ladon_round_table(rand4, aid)
    local padded = pkcs7_pad(data, 16)

    local out = {}
    for i = 1, #padded, 16 do
        out[#out + 1] = ladon_block(ht, padded:sub(i, i + 15))
    end
    return base64_encode(rand4 .. concat(out))
end

-- ── protobuf 写入器（照抄 protobuf.rs 的怪癖）─────────────────────────

--- varint 写入。
--
-- 两个怪癖必须保留：
--   1. 先截断成 u32：Rust 原版是 `v = (v as u32) as u64`。
--   2. 循环条件 `v > 0x80`（不是 `>= 0x80`）：0x80..0xFF 会多写一个 0x80/0x81
--      续延字节——这不是标准 protobuf，但线上生成端就是这么写的。
local function write_varint(out, v)
    local n = #out
    -- 必须用 u32()（无符号）而不是 band()：下面要拿 v 跟 0x80 比大小。
    v = u32(v)
    while v > 0x80 do
        n = n + 1
        out[n] = char(bor(band(v, 0x7f), 0x80))
        v = rshift(v, 7)
    end
    n = n + 1
    out[n] = char(band(v, 0x7f))
end

--- fields 是 { idx, kind, value } 的数组；kind ∈ varint / bytes / utf8 / dict。
local function encode_dict(fields)
    local out = {}
    for i = 1, #fields do
        local f = fields[i]
        local idx, kind, val = f[1], f[2], f[3]
        if kind == "varint" then
            write_varint(out, band(idx, M32) * 8)      -- (idx << 3) | 0
            write_varint(out, val)
        elseif kind == "bytes" or kind == "utf8" or kind == "dict" then
            local payload
            if kind == "dict" then
                payload = encode_dict(val)
            elseif kind == "utf8" then
                payload = tostring(val)
            else
                payload = val
            end
            write_varint(out, band(idx, M32) * 8 + 2)  -- (idx << 3) | 2
            write_varint(out, #payload)
            out[#out + 1] = payload
        else
            error("encode_dict: 未知字段类型 " .. tostring(kind), 0)
        end
    end
    return concat(out)
end

-- ── X-Argus 全链路 ────────────────────────────────────────────────────

--- 模块级常量：以后换成真 key 只改这里。
local SIGN_KEY = char(
    0xac, 0x1a, 0xda, 0xae, 0x95, 0xa7, 0xaf, 0x94, 0xa5, 0x11, 0x4a, 0xb3, 0xb3, 0xa9,
    0x7d, 0xd8, 0x00, 0x50, 0xaa, 0x0a, 0x39, 0x31, 0x4c, 0x40, 0x52, 0x8c, 0xae, 0xc9,
    0x52, 0x56, 0xc2, 0x8c)

local SALT = char(0xf2, 0x81, 0x61, 0x6f)
local LICENSE_ID = 1611921764
local SDK_VERSION_STR = "v04.04.05-ov-android"

local function derive_inner_key()
    return sha256(SIGN_KEY .. SALT .. SIGN_KEY)
end

--- data 为 hex 字符串（x-ss-stub）；非法或为空时按 16 个 0 字节处理。
local function body_hash(stub)
    local raw = hex_decode(stub)
    if not raw then
        raw = rep("\0", 16)
    end
    return sha256(raw):sub(1, 6)
end

local function query_hash(query)
    local raw = query
    if raw == nil or raw == "" then
        raw = rep("\0", 16)
    end
    return sha256(raw):sub(1, 6)
end

--- protobuf 密文的混淆：前 8 字节当 XOR 密钥，整段再反转。
local function enc_pb(data, l)
    local d = {}
    for i = 1, l do
        d[i] = byte(data, i)
    end
    local key = {}
    for i = 1, 8 do
        key[i] = d[i]
    end
    for i = 9, l do
        d[i] = bxor(d[i], key[(i - 1) % 8 + 1])
    end
    local out = {}
    for i = 1, l do
        out[i] = char(d[l - i + 1])
    end
    return concat(out)
end

--- X-Argus 签名（protobuf → AES-128-ECB → XOR/reverse → AES-128-CBC → base64）。
--
-- 参数与 Python 参考实现一一对应：
--   query        x-ss-stub 之外的查询串（用作 query hash 的原文，不是它的哈希）
--   data         x-ss-stub 的 hex 字符串，可为 nil
--   timestamp    秒级时间戳（内部会 << 1）
--   aid          数字或字符串都可以（Python 里是 str(aid)）
--   device_id    设备 id 字符串
--   version_name 版本名，可为 nil（Python 里是 str(version_name)）
--   rand_val     **可注入**的随机数；不传才去读随机源
local function get_sign(query, data, timestamp, aid, device_id, version_name, rand_val)
    if rand_val == nil then
        rand_val = random_u31()
    end

    local fields = {
        { 1, "varint", lshift(0x20200929, 1) },
        { 2, "varint", 2 },
        { 3, "varint", rand_val },
        { 4, "utf8", tostring(aid) },
        { 5, "utf8", tostring(device_id) },
        { 6, "utf8", tostring(LICENSE_ID) },
        { 7, "utf8", tostring(version_name) },
        { 8, "utf8", SDK_VERSION_STR },
        { 9, "varint", 134744640 },
        { 10, "bytes", rep("\0", 8) },
        { 11, "varint", 0 },
        { 12, "varint", lshift(timestamp, 1) },
        { 13, "bytes", body_hash(data) },
        { 14, "bytes", query_hash(query) },
        { 15, "dict", {
            { 1, "varint", 1 }, { 2, "varint", 1 }, { 3, "varint", 1 },
            { 7, "varint", 3348294860 },
        } },
        { 16, "utf8", "" },
        { 20, "utf8", "none" },
        { 21, "varint", 738 },
        { 23, "dict", {
            { 1, "utf8", "NX551J" }, { 2, "varint", 8196 }, { 4, "varint", 2162219008 },
        } },
        { 25, "varint", 2 },
    }

    local pb = encode_dict(fields)
    local padded = pkcs7_pad(pb, 16)
    local new_len = #padded

    local inner = aes128_ecb_encrypt(padded, derive_inner_key():sub(1, 16))
    local prefixed = char(0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff) .. inner
    local b_inner = enc_pb(prefixed, new_len + 8)
    local b_buffer = char(0xa6, 0x6e, 0xad, 0x9f, 0x77, 0x01, 0xd0, 0x0c, 0x18)
        .. b_inner .. "ao"

    local aes_key = md5(SIGN_KEY:sub(1, 16))
    local aes_iv = md5(SIGN_KEY:sub(17, 32))
    -- 注意：参考实现先手工 pad 一次，CBC 的 PKCS#7 再 pad 一次——照抄。
    local encrypted = aes128_cbc_encrypt(pkcs7_pad(b_buffer, 16), aes_key, aes_iv)
    return base64_encode(char(0xf2, 0x81) .. encrypted)
end

-- ── 载入自检（官方向量；任何一处不对都立刻报错，不留到设备上）──────────

do
    local kv = char(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
    local pt = hex_decode("00112233445566778899aabbccddeeff")
    local ct = aes_encrypt_block(pt, expand_key(kv))
    if hex_encode(ct) ~= "69c4e0d86a7b0430d8cdb78070b4c55a" then
        error("fanqie.sign_crypto AES 自检失败（FIPS-197）：" .. hex_encode(ct), 0)
    end
    local nk = hex_decode("2b7e151628aed2a6abf7158809cf4f3c")
    local niv = hex_decode("000102030405060708090a0b0c0d0e0f")
    local np = hex_decode("6bc1bee22e409f96e93d7e117393172a")
    local nc = aes128_cbc_encrypt(np, nk, niv)
    if hex_encode(nc) ~= "7649abac8119b246cee98e9b12e9197d" then
        error("fanqie.sign_crypto AES-CBC 自检失败（NIST SP800-38A）：" .. hex_encode(nc), 0)
    end
    if sha256("") ~= hex_decode(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") then
        error("fanqie.sign_crypto SHA-256 自检失败", 0)
    end
    if md5("") ~= hex_decode("d41d8cd98f00b204e9800998ecf8427e") then
        error("fanqie.sign_crypto MD5 自检失败", 0)
    end
end

return {
    -- 哈希 / 编码
    sha256 = sha256,
    sha256_hex = sha256_hex,
    md5 = md5,
    md5_hex = md5_hex,
    base64_encode = base64_encode,
    hex_encode = hex_encode,
    hex_decode = hex_decode,
    -- 分组密码
    aes128_ecb_encrypt = aes128_ecb_encrypt,
    aes128_cbc_encrypt = aes128_cbc_encrypt,
    -- 同一份实现现在支持 16/24/32 字节密钥，另给一组不带位数的别名。
    -- 番茄正文解密（CM 握手）用的是 32 字节密钥走 CBC。
    aes_ecb_encrypt = aes128_ecb_encrypt,
    aes_cbc_encrypt = aes128_cbc_encrypt,
    -- 解密：CM 握手拿到的会话密钥是 32 字节，用它解正文
    aes_cbc_decrypt = aes_cbc_decrypt,
    aes_decrypt_block = aes_decrypt_block,
    pkcs7_pad = pkcs7_pad,
    -- X-Ladon
    ladon = ladon,
    ladon_block = ladon_block,
    ladon_round_table = ladon_round_table,
    ror64 = ror64,
    u64_add = u64_add,
    -- protobuf
    encode_dict = encode_dict,
    write_varint = write_varint,
    -- X-Argus
    get_sign = get_sign,
    body_hash = body_hash,
    query_hash = query_hash,
    enc_pb = enc_pb,
    derive_inner_key = derive_inner_key,
    -- 随机源
    random_bytes = random_bytes,
    random_u31 = random_u31,
    -- 常量
    SIGN_KEY = SIGN_KEY,
    SALT = SALT,
    LICENSE_ID = LICENSE_ID,
    SDK_VERSION_STR = SDK_VERSION_STR,
}

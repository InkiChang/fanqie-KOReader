--[[ Simon 分组密码（64/128 参数，72 轮）—— 纯 Lua / LuaJIT，无外部依赖。

用途：番茄 X-Argus 的内层加密就是这个（`argus.rs` 里 `simon_encrypt_padded`），
把 protobuf 载荷按 16 字节一块、每块拆成两个 64-bit 字送进来。

实现要点：LuaJIT 的 `bit` 只有 32 位，所以 64 位字用 {lo, hi} 两个 32 位半字表示。
好消息是 **Simon 的轮函数与密钥编排里没有加法**，只有 XOR / AND / NOT / 循环移位，
所以两半分开算就够了，不需要实现 64 位进位加法。

与 Python 参考实现 `fanqie_argus.py` 的 `simon_key_expansion` / `simon_enc` 逐行对应。
]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local M = {}

-- _SIMON_Z = 0x3DC94C3A046D678B（拆成两个 32 位半字）
local Z_HI, Z_LO = 0x3DC94C3A, 0x046D678B

local function zbit(k)
    if k < 32 then return band(rshift(Z_LO, k), 1) end
    return band(rshift(Z_HI, k - 32), 1)
end

local function uxor(...)
    local lo, hi = 0, 0
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        lo = bxor(lo, v.lo)
        hi = bxor(hi, v.hi)
    end
    return { lo = lo, hi = hi }
end

local function uand(a, b) return { lo = band(a.lo, b.lo), hi = band(a.hi, b.hi) } end
local function unot(a) return { lo = bnot(a.lo), hi = bnot(a.hi) } end

--- 64 位循环右移（n 可为 0..63；逻辑移位，不做符号扩展）
local function rotr(v, n)
    n = n % 64
    if n == 0 then return { lo = v.lo, hi = v.hi } end
    if n < 32 then
        return { lo = bor(rshift(v.lo, n), lshift(v.hi, 32 - n)),
                 hi = bor(rshift(v.hi, n), lshift(v.lo, 32 - n)) }
    end
    local m = n - 32
    return { lo = bor(rshift(v.hi, m), lshift(v.lo, 32 - m)),
             hi = bor(rshift(v.lo, m), lshift(v.hi, 32 - m)) }
end

local function rotl(v, n) return rotr(v, (64 - n) % 64) end

--- hex（最多 16 位，按大端数值）→ {lo, hi}
function M.from_hex(s)
    s = string.rep("0", 16 - #s) .. s
    return { lo = tonumber(s:sub(9, 16), 16) % 4294967296,
             hi = tonumber(s:sub(1, 8), 16) % 4294967296 }
end

function M.to_hex(v)
    return string.format("%08x%08x", v.hi % 4294967296, v.lo % 4294967296)
end

--- 8 字节小端串 → {lo, hi}
local function le64(s)
    local lo, hi = 0, 0
    for i = 4, 1, -1 do lo = lo * 256 + string.byte(s, i) end
    for i = 8, 5, -1 do hi = hi * 256 + string.byte(s, i) end
    return { lo = lo, hi = hi }
end

--- 16 个 hex 字符 → 8 字节串
local function unhex8(s)
    local out = {}
    for i = 0, 7 do
        out[#out + 1] = string.char(tonumber(s:sub(i * 2 + 1, i * 2 + 2), 16))
    end
    return table.concat(out)
end

--- 把 16 字节的字节串（little-endian）拆成两个 u64 —— 与 argus.rs 的做法一致
function M.block_to_words(block)
    return le64(block:sub(1, 8)), le64(block:sub(9, 16))
end

--- 密钥编排：4 个 64 位字 → 72 个轮密钥
function M.key_expansion(key)
    local k = {}
    for i = 1, 4 do k[i] = { lo = key[i].lo, hi = key[i].hi } end
    for li = 5, 72 do
        local t = rotr(k[li - 1], 3)
        t = uxor(t, k[li - 3])
        t = uxor(t, rotr(t, 1))
        -- Python: not_val ^ tmp ^ bit_val ^ 3，其中 bit_val = (_SIMON_Z >> ((i-4) % 62)) & 1
        k[li] = uxor(unot(k[li - 4]), t, { lo = zbit((li - 5) % 62), hi = 0 }, { lo = 3, hi = 0 })
    end
    return k
end

--- 加密一个 128 位块（两个 64 位字），返回两个 64 位字
function M.encrypt(a, b, key)
    local k = M.key_expansion(key)
    local xi, xi1 = a, b
    for r = 1, 72 do
        local tmp = xi1
        local f = uand(rotl(xi1, 1), rotl(xi1, 8))
        xi1 = uxor(xi, f, rotl(xi1, 2), k[r])
        xi = tmp
    end
    return xi, xi1
end

--- 给测试/上层用的便捷接口：输入输出都是 hex 字符串。
--- 注意 a/b（以及输出）是**数值**的 hex；而 key 那 64 个 hex 字符是**字节序**，
--- 参考实现是逐 8 字节按 little-endian 解成 u64 的 —— 这两者不能混。
function M.encrypt_hex(a_hex, b_hex, key_hex)
    local k = {
        le64(unhex8(key_hex:sub(1, 16))),
        le64(unhex8(key_hex:sub(17, 32))),
        le64(unhex8(key_hex:sub(33, 48))),
        le64(unhex8(key_hex:sub(49, 64))),
    }
    local ca, cb = M.encrypt(M.from_hex(a_hex), M.from_hex(b_hex), k)
    return M.to_hex(ca), M.to_hex(cb)
end

local function le64_bytes(v)
    local t = {}
    for i = 0, 3 do t[#t + 1] = string.char(math.floor(v.lo / 2 ^ (8 * i)) % 256) end
    for i = 0, 3 do t[#t + 1] = string.char(math.floor(v.hi / 2 ^ (8 * i)) % 256) end
    return table.concat(t)
end

--- 64 个 hex 字符 → 4 个 u64（**逐 8 字节 little-endian**，与 argus.rs / Python 一致）
function M.key_from_hex(key_hex)
    return {
        le64(unhex8(key_hex:sub(1, 16))),
        le64(unhex8(key_hex:sub(17, 32))),
        le64(unhex8(key_hex:sub(33, 48))),
        le64(unhex8(key_hex:sub(49, 64))),
    }
end

--- 加密一个 16 字节块（小端拆字、小端回写），返回 16 字节
function M.encrypt_block16(block, key)
    local a, b = M.block_to_words(block)
    local ca, cb = M.encrypt(a, b, key)
    return le64_bytes(ca) .. le64_bytes(cb)
end

return M

--[[ gzip **编码器** —— 纯 Lua / LuaJIT（KOReader 上没有 zlib 绑定）。

用途：设备注册的请求体是 `tt_encrypt(gzip(json))`，我们必须能自己压出一个**合法 gzip**。

关键取巧：deflate 允许 **stored（未压缩）块**——把原始数据原样放进 `LEN/NLEN` 头之后即可，
不需要实现霍夫曼编码。压缩率是 0（体积略增），但**产物是合法 gzip，任何 gzip 解压器都能读**。
注册请求只有几百字节到几 KB，多几十字节完全无所谓。

验证方式：`tests/spec/` 里把本模块的输出交给 Python 的 `gzip.decompress` 还原，
必须逐字节等于原文（"合法 gzip"这条由 Python 独立证明，而不是我们自己说了算）。
]]

local bit = require("bit")
local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift

local M = {}

-- ── CRC32（IEEE 802.3，多项式 0xEDB88320）────────────────────────────
local CRC_TABLE = nil

local function crc_table()
    if CRC_TABLE then return CRC_TABLE end
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if band(c, 1) == 1 then
                c = bxor(0xEDB88320, rshift(c, 1))
            else
                c = rshift(c, 1)
            end
        end
        t[i] = c % 4294967296
    end
    CRC_TABLE = t
    return t
end

function M.crc32(data)
    local t = crc_table()
    local c = 0xFFFFFFFF
    for i = 1, #data do
        c = bxor(t[band(bxor(c, string.byte(data, i)), 0xff)], rshift(c, 8))
    end
    return bxor(c, 0xFFFFFFFF) % 4294967296
end

local function le32(n)
    n = n % 4294967296
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function le16(n)
    n = n % 65536
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local MAX_STORED = 65535

--- gzip 编码（stored blocks）。返回完整 gzip 字节流。
function M.encode(data)
    local out = {}
    -- 10 字节头：magic(1f 8b) + CM=8(deflate) + FLG=0 + MTIME=0 + XFL=0 + OS=255(unknown)
    out[#out + 1] = "\31\139\8\0\0\0\0\0\0\255"

    local n = #data
    if n == 0 then
        out[#out + 1] = string.char(0x01) .. le16(0) .. le16(0xFFFF)
    else
        local pos = 1
        while pos <= n do
            local len = math.min(MAX_STORED, n - pos + 1)
            local final = (pos + len - 1 == n) and 0x01 or 0x00
            out[#out + 1] = string.char(final)
            out[#out + 1] = le16(len)
            out[#out + 1] = le16(bxor(len, 0xFFFF) % 65536)
            out[#out + 1] = data:sub(pos, pos + len - 1)
            pos = pos + len
        end
    end

    out[#out + 1] = le32(M.crc32(data))       -- CRC32（原文）
    out[#out + 1] = le32(n)                   -- ISIZE（原文长度 mod 2^32）
    return table.concat(out)
end

return M

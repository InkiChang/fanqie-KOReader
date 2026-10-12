-- gzip encoder/decoder used by the App registration and reader flows.

local bit = require("bit")
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local M = {}
local CRC_TABLE

local function crc_table()
    if CRC_TABLE then return CRC_TABLE end
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
        end
        t[i] = c % 4294967296
    end
    CRC_TABLE = t
    return t
end

function M.crc32(data)
    local c, t = 0xFFFFFFFF, crc_table()
    for i = 1, #data do c = bxor(t[band(bxor(c, string.byte(data, i)), 0xff)], rshift(c, 8)) end
    return bxor(c, 0xFFFFFFFF) % 4294967296
end

local function le16(n) n = n % 65536; return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) n = n % 4294967296; return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end

function M.encode(data)
    local out = { "\31\139\8\0\0\0\0\0\0\255" }
    local pos, n = 1, #data
    if n == 0 then out[#out + 1] = string.char(1) .. le16(0) .. le16(0xFFFF)
    else
        while pos <= n do
            local len = math.min(65535, n - pos + 1)
            local final = (pos + len - 1 == n) and 1 or 0
            out[#out + 1] = string.char(final) .. le16(len) .. le16(bxor(len, 0xFFFF) % 65536) .. data:sub(pos, pos + len - 1)
            pos = pos + len
        end
    end
    out[#out + 1], out[#out + 2] = le32(M.crc32(data)), le32(n)
    return table.concat(out)
end

function M.decode(data)
    if type(data) ~= "string" or #data < 2 then error("gzip data empty", 0) end
    if data:sub(1, 2) ~= "\31\139" then return data end
    local ok, ffi = pcall(require, "ffi")
    if not ok then error("KOReader lacks ffi for gzip response", 0) end
    if not M._ffi_ready then
        pcall(ffi.cdef, [[
            typedef unsigned char fq_gz_Bytef;
            typedef unsigned long fq_gz_uLong;
            typedef struct fq_gz_stream_s {
                const fq_gz_Bytef *next_in;
                unsigned int avail_in;
                fq_gz_uLong total_in;
                fq_gz_Bytef *next_out;
                unsigned int avail_out;
                fq_gz_uLong total_out;
                const char *msg;
                void *state;
                void *zalloc;
                void *zfree;
                void *opaque;
                int data_type;
                fq_gz_uLong adler;
                fq_gz_uLong reserved;
            } fq_gz_stream;
            const char *zlibVersion(void);
            int inflateInit2_(fq_gz_stream *, int, const char *, int);
            int inflate(fq_gz_stream *, int);
            int inflateEnd(fq_gz_stream *);
        ]])
        M._ffi_ready = true
    end
    local z, zs = ffi.load("z"), ffi.new("fq_gz_stream")
    zs.next_in, zs.avail_in = ffi.cast("const fq_gz_Bytef *", data), #data
    local version = "1.2.13"; pcall(function() version = ffi.string(z.zlibVersion()) end)
    local rc = z.inflateInit2_(zs, 31, version, ffi.sizeof(zs)); if rc ~= 0 then error("gzip inflateInit2 failed: " .. tostring(rc), 0) end
    local chunks, done = {}, false
    local ok2, err = pcall(function()
        while not done do
            local buf = ffi.new("fq_gz_Bytef[65536]"); zs.next_out, zs.avail_out = buf, 65536; rc = z.inflate(zs, 0)
            local produced = 65536 - zs.avail_out; if produced > 0 then chunks[#chunks + 1] = ffi.string(buf, produced) end
            if rc == 1 then done = true elseif rc ~= 0 then error("gzip inflate failed: " .. tostring(rc), 0) elseif produced == 0 and zs.avail_in == 0 then error("incomplete gzip data", 0) end
        end
    end)
    z.inflateEnd(zs); if not ok2 then error(err, 0) end
    return table.concat(chunks)
end

return M

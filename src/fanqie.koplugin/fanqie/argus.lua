--[[ X-Argus 签名（551 封装）—— 纯 Lua / LuaJIT。

算法来源：ch6vip/fqapp 的 `rust/src/sign/{argus,protobuf,simon,sm3}.rs`（GPL-3.0，**只当规格读**），
并与已通过上游黄金向量的 Python 参考实现 `fanqie_argus.py` 逐行对应。

流程：protobuf bean → PKCS7 → Simon（每 16 字节一块）→ 551 框架（f2f7fcff 魔数 + 9 字节尾巴）
      → 逐字节 XOR 后整体反转 → 追加 "ao" → PKCS7 → AES-128-CBC → 前缀 f281 → base64。

注意与本仓库 `sign_crypto.lua` 里那个旧 `get_sign` **不是一回事**：旧版是社区那套
（SHA-256 + AES-ECB + 社区密钥），实测被服务端拒绝；这里是能过的 551 版。
]]

local sm3 = require("fanqie.sm3")
local simon = require("fanqie.simon")
local SC = require("fanqie.sign_crypto")

local M = {}

M.SIGN_KEY_HEX = "fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304"
M.AES_KEY_HEX = "d31e3718288a1027baab59f146a09a9c"
M.AES_IV_HEX = "ea180a0336ed352fcd24e4d50018ae54"
M.LICENSE_ID = 1611921764
M.AID = 1967

local MAGIC8 = string.char(0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff)
local TAIL9 = string.char(0xea, 0xfb, 0x2c, 0xfe, 0x85, 0x68, 0x51, 0x91, 0x54)
local PREFIX = string.char(0xf2, 0x81)
local ZERO16 = string.rep("\0", 16)

-- ── protobuf 写入器（与 fanqie_argus.py 的 ProtoBuf 一致）────────────────
-- 与 sign_crypto 里那版不同：这里的 varint 是正确 LEB128（`while v >= 128`），
-- 旧版用的是 fanqie-dl 那套 `> 0x80`，两者在值恰为 128 时不同。

local function wvar(out, v)
    v = v % 4294967296
    while v >= 128 do
        out[#out + 1] = string.char((v % 128) + 128)
        v = math.floor(v / 128)
    end
    out[#out + 1] = string.char(v)
end

local function fvar(out, idx, v)
    wvar(out, idx * 8)          -- (idx << 3) | 0
    wvar(out, v)
end

local function fbytes(out, idx, s)
    wvar(out, idx * 8 + 2)      -- (idx << 3) | 2
    wvar(out, #s)
    out[#out + 1] = s
end

local function pkcs7_align(s)
    local pad = 16 - (#s % 16)
    return s .. string.rep(string.char(pad), pad)
end

--- 等价于 Rust 侧 url::form_urlencoded::parse（取首个匹配）
function M.query_param(query, name)
    if not query or query == "" then return nil end
    for pair in query:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=(.*)$")
        if k then
            local function dec(s)
                s = s:gsub("+", " ")
                return (s:gsub("%%(%x%x)", function(cc) return string.char(tonumber(cc, 16)) end))
            end
            if dec(k) == name then return dec(v) end
        end
    end
    return nil
end

--- getBodyHash：SM3 前 6 字节（stub 是 body 的 MD5 hex；空则用 16 个零字节）
function M.body_hash(stub_hex)
    if not stub_hex or stub_hex == "" then
        return sm3.hash(ZERO16):sub(1, 6)
    end
    return sm3.hash(SC.hex_decode(stub_hex)):sub(1, 6)
end

--- getQueryHash：SM3 前 6 字节（空则用 16 个零字节）
function M.query_hash(query)
    if not query or query == "" then
        return sm3.hash(ZERO16):sub(1, 6)
    end
    return sm3.hash(query):sub(1, 6)
end

--- Simon 加密整段（长度必须是 16 的倍数）
local function simon_padded(data, key)
    local out = {}
    for i = 1, #data, 16 do
        out[#out + 1] = simon.encrypt_block16(data:sub(i, i + 15), key)
    end
    return table.concat(out)
end

--- 551 封装（上游真正接受的那个）
function M.encrypt_551(protobuf)
    local pb = pkcs7_align(protobuf)
    local enc = simon_padded(pb, simon.key_from_hex(M.SIGN_KEY_HEX))

    local un = MAGIC8 .. enc .. TAIL9
    local bytes = { MAGIC8 }
    for i = 9, #un do
        -- Python: buf[i] = un[i] ^ MAGIC8[i % 8]（0 基）→ Lua 用 (i-1)%8+1
        bytes[#bytes + 1] = string.char(
            bit.bxor(string.byte(un, i), string.byte(MAGIC8, (i - 1) % 8 + 1)))
    end
    local buf = table.concat(bytes)
    buf = buf:reverse() .. "ao"
    buf = pkcs7_align(buf)

    local out = SC.aes_cbc_encrypt(buf, SC.hex_decode(M.AES_KEY_HEX), SC.hex_decode(M.AES_IV_HEX))
    return SC.base64_encode(PREFIX .. out)
end

--- 组装 bean（字段与 fanqie_argus.py 的 build_argus_bean 一一对应）
function M.build_bean(query, stub_hex, ts, aid, license_id, device_id, install_id, style, rand_field)
    local o = {}
    fvar(o, 1, 1077940818)
    fvar(o, 2, 2)
    fvar(o, 3, rand_field)
    fbytes(o, 4, tostring(aid))
    fbytes(o, 5, device_id or "")
    fbytes(o, 6, tostring(license_id))
    fbytes(o, 7, M.query_param(query, "version_name") or "")
    if style == "551" then
        fbytes(o, 8, "v04.04.05-ov-android")
        fvar(o, 9, 134744640)
        fbytes(o, 10, string.rep("\0", 8))
        fvar(o, 11, 0)
    elseif style == "sigmgr" then
        fbytes(o, 8, "v04.04.05-ov-android")
        fvar(o, 9, 134744640)
        fbytes(o, 10, "")
        fbytes(o, 11, "0")
    else
        fbytes(o, 8, "")
        fvar(o, 9, 0)
        fbytes(o, 10, "")
        fbytes(o, 11, "")
    end
    fvar(o, 12, ts * 2)                       -- timestamp << 1
    fbytes(o, 13, M.body_hash(stub_hex))
    fbytes(o, 14, M.query_hash(query))

    local s15 = {}
    fvar(s15, 1, 1); fvar(s15, 2, 1); fvar(s15, 3, 1); fvar(s15, 7, 0xC792ECCC)
    fbytes(o, 15, table.concat(s15))

    fbytes(o, 16, install_id or "")
    fbytes(o, 20, "none")
    fvar(o, 21, 738)

    local s23 = {}
    fbytes(s23, 1, "NX551J"); fvar(s23, 2, 8196); fvar(s23, 4, 0x80E0D800)
    fbytes(o, 23, table.concat(s23))

    fvar(o, 25, 2)
    return table.concat(o)
end

--- 生成 x-argus 头。rand_field 固定时输出可复现（测试用）。
function M.get_sign(query, stub_hex, ts, aid, license_id, device_id, install_id, style, rand_field)
    aid = (aid and aid ~= 0) and aid or M.AID
    license_id = (license_id and license_id ~= 0) and license_id or M.LICENSE_ID
    style = style or "551"
    if rand_field == nil then
        rand_field = SC.random_u31 and SC.random_u31() or math.random(0, 2147483647)
    end
    local bean = M.build_bean(query, stub_hex, ts, aid, license_id, device_id, install_id,
        style, rand_field)
    -- 目前只有 551 被上游接受；另外两种保留以便排查
    return M.encrypt_551(bean)
end

M.MAGIC8 = MAGIC8
M.TAIL9 = TAIL9
M.PREFIX = PREFIX

return M

-- Legacy FanQie App reader flow inspired by fqapp and imengying/unidbg.
-- Unlike the unidbg project, this module does not embed a JVM/native signer:
-- it reuses the pure-Lua x-argus/x-ladon implementation already shipped here.
-- The flow is: signed batch_full -> registerkey -> AES-CBC -> optional gzip.
local H = require("fanqie.helper")
local SC = require("fanqie.sign_crypto")
local CM = require("fanqie.cm")
local argus = require("fanqie.argus")
local gzip = require("fanqie.gzip")

local M = {}
M.BASE_URL = "https://api5-normal-sinfonlineb.fqnovel.com"
M.REGISTER_KEY_URL = "https://reading.snssdk.com/reading/crypt/registerkey"
M.REGISTER_KEY_MASTER = "ac25c67ddd8f38c1b37a2348828e222e"
M.REGISTER_KEY_REQ_B64 = "rCXGfd2POMGzeiNIgo4iLg=="
M.VERSION_CODE = "68132"
M.VERSION_NAME = "6.8.1.32"
M.AID = 1967

local function now_ms()
    return tostring(math.floor(os.time() * 1000))
end

local function sorted_pairs(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        if t[k] ~= nil then out[#out + 1] = H.url_encode(k) .. "=" .. H.url_encode(t[k]) end
    end
    return table.concat(out, "&")
end

local function valid_id(v)
    return v ~= nil and tostring(v) ~= "" and tostring(v) ~= "0"
end

local function pkcs7_unpad(data, block_size)
    block_size = block_size or 16
    local n = #data
    if n == 0 or n % block_size ~= 0 then error("PKCS7 数据长度无效", 0) end
    local pad = string.byte(data, n)
    if not pad or pad < 1 or pad > block_size then error("PKCS7 填充无效", 0) end
    if data:sub(n - pad + 1) ~= string.rep(string.char(pad), pad) then error("PKCS7 填充无效", 0) end
    return data:sub(1, n - pad)
end

local function put(out, key, value)
    out[key] = tostring(value or "")
end

function M.common_params(device_id, install_id, opts)
    opts = opts or {}
    local p = {}
    put(p, "iid", install_id)
    put(p, "device_id", device_id)
    put(p, "ac", "wifi")
    put(p, "channel", "googleplay")
    put(p, "aid", M.AID)
    put(p, "app_name", "novelapp")
    put(p, "version_code", opts.version_code or M.VERSION_CODE)
    put(p, "version_name", opts.version_name or M.VERSION_NAME)
    put(p, "device_platform", "android")
    put(p, "os", "android")
    put(p, "ssmix", "a")
    put(p, "device_type", opts.device_type or "Sirius")
    put(p, "device_brand", opts.device_brand or "Xiaomi")
    put(p, "language", "zh")
    put(p, "os_api", opts.os_api or "33")
    put(p, "os_version", opts.os_version or "13")
    put(p, "manifest_version_code", opts.version_code or M.VERSION_CODE)
    put(p, "resolution", opts.resolution or "2244*1080")
    put(p, "dpi", opts.dpi or "440")
    put(p, "update_version_code", opts.update_version_code or M.VERSION_CODE)
    put(p, "_rticket", now_ms())
    put(p, "host_abi", opts.host_abi or "arm64-v8a")
    put(p, "dragon_device_type", "phone")
    put(p, "pv_player", opts.version_code or M.VERSION_CODE)
    put(p, "compliance_status", "0")
    put(p, "need_personal_recommend", "1")
    put(p, "player_so_load", "1")
    put(p, "is_android_pad_screen", "0")
    put(p, "rom_version", opts.rom_version or "V417IR+release-keys")
    put(p, "cdid", opts.cdid or "")
    return p
end

local function reverse_hex_device_id(device_id)
    local n = tostring(device_id or ""):match("^%d+$")
    if not n then error("device_id 必须是十进制数字", 0) end
    -- Lua numbers cannot safely represent all 64-bit IDs. Convert decimal to
    -- hex using repeated division, then reverse bytes as fqapp does.
    local digits = {}
    for i = 1, #n do digits[i] = tonumber(n:sub(i, i)) end
    local hex = {}
    while #digits > 0 do
        local carry, next_digits = 0, {}
        for _, d in ipairs(digits) do
            local value = carry * 10 + d
            local q = math.floor(value / 16)
            carry = value % 16
            if #next_digits > 0 or q > 0 then next_digits[#next_digits + 1] = q end
        end
        hex[#hex + 1] = string.format("%x", carry)
        digits = next_digits
    end
    local h = table.concat(hex):reverse()
    h = string.rep("0", 32 - #h) .. h
    local out = {}
    for i = #h, 2, -2 do out[#out + 1] = h:sub(i - 1, i) end
    return table.concat(out)
end

function M.build_register_key_content(device_id)
    local key = CM.base64_decode(M.REGISTER_KEY_REQ_B64)
    local raw = SC.hex_decode(reverse_hex_device_id(device_id))
    local iv = SC.random_bytes(16)
    local padded = SC.pkcs7_pad(raw, 16)
    return SC.base64_encode(iv .. SC.aes_cbc_encrypt(padded, key, iv))
end

local function decrypt_register_key(encoded)
    local raw = CM.base64_decode(encoded or "")
    if #raw < 32 then error("registerkey 密文过短", 0) end
    local plain = SC.aes_cbc_decrypt(raw:sub(17), SC.hex_decode(M.REGISTER_KEY_MASTER), raw:sub(1, 16))
    plain = pkcs7_unpad(plain, 16)
    if #plain < 16 then error("registerkey 明文过短", 0) end
    return SC.hex_encode(plain:sub(1, 16)), plain
end

local function sign_headers(query, body, device_id, install_id, aid)
    local ts = os.time()
    local headers = {
        ["User-Agent"] = "com.dragon.read",
        ["Accept"] = "application/json; charset=utf-8,application/x-protobuf",
        ["Accept-Encoding"] = "identity",
        ["x-ss-req-ticket"] = tostring(ts * 1000),
        ["x-khronos"] = tostring(ts),
    }
    if body and body ~= "" then
        headers["x-ss-stub"] = SC.md5_hex(body)
    end
    headers["x-argus"] = argus.get_sign(query, headers["x-ss-stub"] or "", ts,
        aid or M.AID, argus.LICENSE_ID, device_id, install_id, "551")
    headers["x-ladon"] = SC.ladon(ts, argus.LICENSE_ID, aid or M.AID)
    return headers
end

function M.fetch_register_key(client, device_id, install_id, opts)
    opts = opts or {}
    -- registerkey uses the compact 6.1.5.32 parameter set from fqapp.
    local query_params = {
        aid = M.AID, app_name = "novelapp", channel = "0",
        device_id = tostring(device_id), device_platform = "android", iid = tostring(install_id),
        os_version = "0", version_code = "6.1.5.32", version_name = "6.1.5.32",
        manifest_version_code = "61532", update_version_code = "61532",
    }
    local query = sorted_pairs(query_params)
    local url = M.REGISTER_KEY_URL .. "?" .. query
    local payload_json = "{\"content\":\"" .. M.build_register_key_content(device_id) .. "\",\"keyver\":1}"
    local body = gzip.encode(payload_json)
    local headers = sign_headers(query, body, device_id, install_id, M.AID)
    headers["Content-Type"] = "application/json"
    headers["Content-Encoding"] = "gzip"
    local text, code = client:request({ url = url, method = "POST", headers = headers, body = body, timeout = 20 })
    if type(text) == "string" and text:sub(1, 2) == "\31\139" then text = gzip.decode(text) end
    if not code or code < 200 or code >= 300 then error("registerkey HTTP " .. tostring(code), 0) end
    local root = client:json_decode(text)
    local data = root and root.data
    if type(root) ~= "table" then error("registerkey 响应不是 JSON 对象", 0) end
    if tonumber(root.code or 0) ~= 0 then error("registerkey 返回失败: " .. tostring(root.message), 0) end
    local enc = type(data) == "table" and (data.key or data.key_info) or nil
    if type(enc) == "table" then enc = enc.key or enc.value end
    if type(enc) ~= "string" or enc == "" then error("registerkey 响应缺少 data.key", 0) end
    local key, plain = decrypt_register_key(enc)
    return { key = key, keyver = data.keyver or data.key_version, raw = plain }
end

local function decode_content(encoded, key)
    local raw = CM.base64_decode(encoded or "")
    if #raw < 32 or (#raw - 16) % 16 ~= 0 then error("batch_full content 密文无效", 0) end
    local plain = SC.aes_cbc_decrypt(raw:sub(17), SC.hex_decode(key), raw:sub(1, 16))
    plain = pkcs7_unpad(plain, 16)
    if plain:sub(1, 2) == "\31\139" then
        plain = gzip.decode(plain)
    end
    return plain
end

local function html_to_text(text)
    text = tostring(text or "")
    text = text:gsub("<br%s*/?>", "\n")
        :gsub("</p%s*>", "\n")
        :gsub("</div%s*>", "\n")
        :gsub("<[^>]*>", "")
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
    return text:gsub("\n\n+", "\n"):gsub("^%s+", "")
end

function M.fetch_batch(client, book_id, item_ids, device_id, install_id, opts)
    opts = opts or {}
    local p = M.common_params(device_id, install_id, opts)
    local retried = opts._register_key_retried == true
    -- batch_full accepts the current App parameter profile; key_version is read from each item.
    p.item_ids = table.concat(item_ids, ",")
    p.key_register_ts = "0"
    p.book_id = tostring(book_id)
    p.req_type = opts.download and "0" or "1"
    local query = sorted_pairs(p)
    local url = M.BASE_URL .. "/reading/reader/batch_full/v?" .. query
    local headers = sign_headers(query, nil, device_id, install_id, M.AID)
    local text, code = client:request({ url = url, method = "GET", headers = headers, timeout = 30 })
    if not code or code < 200 or code >= 300 then error("batch_full HTTP " .. tostring(code), 0) end
    if type(text) == "string" and text:sub(1, 2) == "\31\139" then text = gzip.decode(text) end
    local root = client:json_decode(text)
    if type(root) ~= "table" or tonumber(root.code or 0) ~= 0 then
        error("batch_full 返回失败: " .. tostring(root and root.message), 0)
    end
    local data = root.data or {}
    local item_infos = data.item_infos or data
    if type(item_infos) ~= "table" then item_infos = {} end
    local key_info = opts.register_key
    local out = {}
    local function add_item(id, item)
        if type(item) ~= "table" or not item.content or item.content == "" then return end
        local required_keyver = item.key_version or item.keyVersion
        if required_keyver and key_info and key_info.keyver
                and tostring(required_keyver) ~= tostring(key_info.keyver) then
            return
        end
        local key = key_info and key_info.key
        if not key then error("batch_full 需要 registerkey 才能解密", 0) end
        local ok, plain = pcall(decode_content, item.content, key)
        if ok and plain and #plain > 0 then
            out[tostring(id)] = { content = html_to_text(plain), title = item.title or "" }
        end
    end
    if #item_infos > 0 then
        for index, item in ipairs(item_infos) do
            add_item(item.item_id or item.itemId or index, item)
        end
    else
        for id, item in pairs(item_infos) do add_item(id, item) end
    end
    -- A key can rotate independently of the device identity. Refresh once when
    -- every item failed decryption, matching the upstream service retry policy.
    if not next(out) and not retried then
        local fresh = M.fetch_register_key(client, device_id, install_id, opts)
        local retry_opts = {}
        for k, v in pairs(opts) do retry_opts[k] = v end
        retry_opts.register_key, retry_opts._register_key_retried = fresh, true
        return M.fetch_batch(client, book_id, item_ids, device_id, install_id, retry_opts)
    end
    return out
end


return M

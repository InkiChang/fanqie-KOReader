--[[ 设备注册 —— 纯 Lua。让插件自己拿到 install_id / device_id，不再需要手动塞文件。

规格来源：ch6vip/fqapp 的 `rust/src/device/{register,crypto}.rs`（GPL-3.0，**只当规格读**）。
规格要点（全部已在 `TASK-device-register.md` 里留档）：

  body = tt_encrypt( gzip( json{ magic_tag:"ss_app_log", header:{…}, _gen_time } ) )

  tt_encrypt(data) =
      fixed = b64(TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA==)
      hv    = SHA512( SHA512(random32) ‖ fixed );  key = hv[1..16], iv = hv[17..32]
      body  = AES-128-CBC( PKCS7( SHA512(data) ‖ data ), key, iv )
      out   = TT_MAGIC(74 63 05 10 00 00) ‖ random32 ‖ body

  POST https://log.snssdk.com/service/2/device_register/?<sorted_query>
  Content-Type: application/octet-stream;tt-data=a

只需要 install_id / device_id；上游接下来的 app_alert_check / privilege / register_key
对"取正文"不是必需，故此处不做。
]]

local sha512 = require("fanqie.sha512")
local gzip = require("fanqie.gzip")
local SC = require("fanqie.sign_crypto")
local cm = require("fanqie.cm")          -- 借它的 base64_decode

local M = {}

local ok_logger, logger = pcall(require, "fanqie.logger")
if not ok_logger then logger = nil end
M.TT_FIXED_STRING_B64 = "TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA=="
M.TT_MAGIC = string.char(0x74, 0x63, 0x05, 0x10, 0x00, 0x00)
M.REGISTER_HOST = "https://log.snssdk.com"
M.REGISTER_PATH = "/service/2/device_register/"
M.USER_AGENT = "com.dragon.read/65132 (Linux; U; Android 10; zh_CN; MI 12; Build/MMB29M; Cronet/TTNetVersion:9ac8d95c 2024-11-25 QuicVersion:3f326df4 2024-11-14)"
M.INSTALL_ID_URL = "https://log.snssdk.com/service/2/device_register/?"

local function pkcs7(data)
    local pad = 16 - (#data % 16)
    return data .. string.rep(string.char(pad), pad)
end

--- 规格里的 tt_encrypt。random32 可注入（测试用固定值）。
function M.tt_encrypt(data, random32)
    random32 = random32 or SC.random_bytes(32)
    if #random32 ~= 32 then error("tt_encrypt 需要 32 字节随机量", 0) end
    local fixed = cm.base64_decode(M.TT_FIXED_STRING_B64)
    local hv = sha512.hash(sha512.hash(random32) .. fixed)
    local key, iv = hv:sub(1, 16), hv:sub(17, 32)
    local hashed = sha512.hash(data) .. data
    local enc = SC.aes_cbc_encrypt(pkcs7(hashed), key, iv)
    return M.TT_MAGIC .. random32 .. enc
end

--- URL 查询参数转义。**必须做**：设备名里有空格（"Pixel 6"），不转义会被服务端判成
--- HTTP 400（实测收到的是一张 249 字节的 HTML 错误页，首字节 `<!DOCTYP`）。
local function url_escape(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        if c == " " then return "+" end
        return string.format("%%%02X", string.byte(c))
    end))
end

--- 服务端对"同一套画像"有去重/限流：重复注册会回 `device_id=0`（实测）。
--- 所以"0"必须当作**失败**，而且要换一套画像再试。
local function is_valid_id(v)
    return v ~= nil and v ~= "" and v ~= "0"
end

local function find_valid_id(value, names, depth)
    if depth > 6 or type(value) ~= "table" then return nil end
    for _, name in ipairs(names) do
        local candidate = value[name]
        if candidate ~= nil and is_valid_id(tostring(candidate)) then
            return tostring(candidate)
        end
    end
    for _, child in pairs(value) do
        local found = find_valid_id(child, names, depth + 1)
        if found then return found end
    end
    return nil
end

--- 备用画像池（换一套再注册，实测能拿到真身份）
local PROFILES = {
    { device_model = "MI 12", device_brand = "Xiaomi", os_version = "10",
      resolution = "1440x2392", os_api = "29", dpi = "560" },
    { device_model = "MI 11", device_brand = "Xiaomi", os_version = "11",
      resolution = "1440x2392", os_api = "30", dpi = "560" },
    { device_model = "Redmi K40", device_brand = "Xiaomi", os_version = "12",
      resolution = "1080x2400", os_api = "31", dpi = "440" },
    { device_model = "Honor10", device_brand = "honor", os_version = "9",
      resolution = "1080x1920", os_api = "28", dpi = "420" }
}

local function rand_alnum(n)
    local chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    -- generated from OS entropy; this remains an Android identity.
    local raw = SC.random_bytes(n)
    local out = {}
    for i = 1, n do
        out[i] = chars:sub((string.byte(raw, i) % #chars) + 1, (string.byte(raw, i) % #chars) + 1)
    end
    return table.concat(out)
end

local function rand_hex_lower(n)
    local hex = "0123456789abcdef"
    local raw = SC.random_bytes(n)
    local out = {}
    for i = 1, n do
        local pos = (string.byte(raw, i) % #hex) + 1
        out[i] = hex:sub(pos, pos)
    end
    return table.concat(out)
end

local function rand_mac()
    local HEX = "0123456789ABCDEF"
    local raw = SC.random_bytes(12)
    local out = {}
    for i = 1, 12 do
        local pos = (string.byte(raw, i) % #HEX) + 1
        out[i] = HEX:sub(pos, pos)
    end
    return table.concat(out)
end

local function uuid4()
    local HEX = "0123456789abcdef"
    local raw = SC.random_bytes(32)
    local out = {}
    for i = 1, 32 do
        local pos = (string.byte(raw, i) % #HEX) + 1
        out[i] = HEX:sub(pos, pos)
    end
    local s = table.concat(out)
    return s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-4" .. s:sub(14, 16) .. "-a"
        .. s:sub(18, 20) .. "-" .. s:sub(21, 32)
end

local function build_user_agent(opts)
    return string.format(
        "com.dragon.read/%s (Linux; U; Android %s; zh_CN; %s; Build/MMB29M; Cronet/TTNetVersion:9ac8d95c 2024-11-25 QuicVersion:3f326df4 2024-11-14)",
        tostring(opts.version_code or 65132), tostring(opts.os_version or "10"),
        tostring(opts.device_model or "MI 12"))
end
--- 组装注册请求体（未压缩的 JSON 字符串）
function M.build_json(opts)
    opts = opts or {}
    local now_ms = math.floor(os.time() * 1000)
    local header = {
        display_name = "番茄小说",
        update_version_code = opts.update_version_code or "65132",
        -- Android registration profile follows fqapp's 6.5.1.32 schema.
        manifest_version_code = tostring(opts.version_code or 65132),
        -- Keep the same Android schema and field shapes as fqapp.
        aid = 1967,
        channel = opts.channel or "xiaomi_1967_64",
        package = opts.package or "com.dragon.read",
        app_version = opts.version_name or "6.5.1.32",
        version_code = tostring(opts.version_code or 65132),
        sdk_version = opts.sdk_version or "v04.04.05-ov-android",
        sdk_target_version = 29,
        os = "Android",
        os_version = opts.os_version or "10",
        os_api = tostring(opts.os_api or "29"),
        device_model = opts.device_model or "MI 12",
        device_brand = opts.device_brand or "Xiaomi",
        device_manufacturer = "Google",
        device_category = "phone",
        cpu_abi = "arm64-v8a",
        release_build = opts.release_build or uuid4(),
        density_dpi = tostring(opts.dpi or "560"),
        display_density = "mdpi",
        resolution = opts.resolution or "1440x2392",
        language = "zh",
        mac = opts.mac or rand_mac(),
        timezone = 8,
        access = "wifi",
        not_request_sender = 0,
        carrier = "CHINA MOBILE",
        mcc_mnc = "46007",
        rom = opts.rom or ("EMUI-" .. rand_alnum(13)),
        rom_version = opts.rom_version or rand_alnum(2),
        sig_hash = SC.md5_hex(uuid4()),
        openudid = opts.openudid or rand_alnum(16),
        clientudid = opts.clientudid or uuid4(),
        sim_serial_number = {},
        region = "CN",
        tz_name = "Asia/Shanghai",
        tz_offset = 28800,
        sim_region = "cn",
    }
    local body = { magic_tag = "ss_app_log", header = header, _gen_time = now_ms }

    local ok, json = pcall(require, "json")
    if ok then
        local ok2, s = pcall(json.encode, body)
        if ok2 and type(s) == "string" then return s end
    end
    error("缺少可用的 json 模块，无法组装注册请求", 0)
end

--- 注册一次，返回 install_id, device_id, err
function M.register(opts)
    opts = opts or {}
    -- Android-only registration: Kindle hardware is never consulted.
    -- Identity fields below are generated from OS entropy; Kindle hardware is never read.
    -- fqapp uses a 16-character lowercase hexadecimal OpenUDID.
    local openudid = opts.openudid or rand_hex_lower(16)
    local clientudid = opts.clientudid or uuid4()

    opts.openudid = openudid
    opts.clientudid = clientudid
    opts.cdid = opts.cdid or uuid4()
    opts.rom = opts.rom or ("EMUI-" .. rand_alnum(13))
    opts.rom_version = opts.rom_version or rand_alnum(2)
    opts.release_build = opts.release_build or uuid4()
    opts.mac = opts.mac or rand_mac()
    local body_json = M.build_json(opts)
    local compressed = gzip.encode(body_json)
    local payload = M.tt_encrypt(compressed, opts.random32)

    local query_params = {
        aid="1967", app_name="novel", channel=opts.channel or "xiaomi_1967_64",
        device_platform="android", device_type=opts.device_model or "MI 12", os_version=opts.os_version or "10",
        version_code=tostring(opts.version_code or 65132), version_name=opts.version_name or "6.5.1.32", tt_data="a",
        update_version_code=tostring(opts.update_version_code or opts.version_code or 65132),
        os_api=tostring(opts.os_api or "29"), ssmix="a", manifest_version_code=tostring(opts.version_code or 65132), dpi=tostring(opts.dpi or "560"),
        ts=tostring(os.time()), _rticket=tostring(math.floor(os.time() * 1000)), cpu_support64="true", app_type="normal",
        appTheme="light", ac="wifi", host_abi="arm64-v8a", device_brand=opts.device_brand or "Xiaomi", os="android",
        minor_status="0",
        is_android_pad="0", package="com.dragon.read", resolution=(opts.resolution or "1440x2392"):gsub("x", "*"), language="zh", need_personal_recommend="1",
        mcc_mnc="46007", openudid=openudid, cdid=opts.cdid,
    }
    local query_keys, query_parts = {}, {}
    for k in pairs(query_params) do query_keys[#query_keys + 1] = k end
    table.sort(query_keys)
    for _, k in ipairs(query_keys) do query_parts[#query_parts + 1] = url_escape(k) .. "=" .. url_escape(query_params[k]) end
    local query = table.concat(query_parts, "&")

    local url = M.REGISTER_HOST .. M.REGISTER_PATH .. "?" .. query
    local headers = {
        ["content-type"] = "application/octet-stream;tt-data=a",
        -- LuaSocket may otherwise choose chunked transfer; the Android client sends a fixed length.
        ["content-length"] = tostring(#payload),
        -- 上游规格里写的是 "gzip"，但那会让响应也变成 gzip，而 KOReader 上没有 zlib，
        -- 于是 `json.decode` 直接失败（真机实测报「注册响应不是合法 JSON」）。
        -- 改成 identity 直接要明文；正文接口（full/mget）也是这么干的，同样能过。
        ["accept-encoding"] = "gzip",
        ["user-agent"] = build_user_agent(opts),
        ["host"] = "log.snssdk.com",
        ["connection"] = "Keep-Alive",
    }

    local okh, https = pcall(require, "ssl.https")
    local okl, ltn12 = pcall(require, "ltn12")
    if not (okh and okl) then return nil, nil, "缺少 ssl.https / ltn12" end

    local chunks = {}
    local ok, code, response_headers = https.request({
        url = url, method = "POST", headers = headers,
        source = ltn12.source.string(payload), sink = ltn12.sink.table(chunks),
    })
    local raw = table.concat(chunks)
    if not raw or raw == "" then
        return nil, nil, string.format("注册响应为空（ok=%s code=%s）", tostring(ok), tostring(code))
    end
    if raw:sub(1, 2) == "\31\139" then
        local ok_gz, decoded = pcall(gzip.decode, raw)
        if ok_gz and decoded then raw = decoded else
            return nil, nil, "注册响应是 gzip 且解压失败：" .. tostring(decoded)
        end
    end

    local okj, json = pcall(require, "json")
    if not okj then return nil, nil, "缺少 json 模块" end
    local okd, root = pcall(json.decode, raw)
    if not okd or type(root) ~= "table" then
        -- 诊断信息要够用：状态码、长度、首几字节、内容类型。
        -- 光说"不是合法 JSON"没法判断到底是 gzip、HTML 错误页还是别的封装。
        local function hexhead(n)
            local t = {}
            for i = 1, math.min(n, #raw) do
                t[#t + 1] = string.format("%02x", string.byte(raw, i))
            end
            return table.concat(t)
        end
        return nil, nil, string.format(
            "注册响应不是合法 JSON（code=%s len=%d 首字节=%s content-type=%s）",
            tostring(code), #raw, hexhead(8),
            tostring(response_headers and (response_headers["content-type"] or response_headers["Content-Type"])))
    end

    local function pick(t, k)
        local v = t[k]
        if v == nil then return nil end
        return tostring(v)
    end
    local iid = pick(root, "install_id") or pick(root, "install_id_str")
    local did = pick(root, "device_id") or pick(root, "device_id_str")
    local data = root.data
    if type(data) == "table" then
        iid = iid or pick(data, "install_id") or pick(data, "install_id_str")
        did = did or pick(data, "device_id") or pick(data, "device_id_str")
    end
    -- Some responses include numeric install_id/device_id=0 at the top level
    -- and the real *_str values inside data. A Lua string "0" is truthy, so
    -- plain `or` selection would incorrectly discard the valid nested IDs.
    local function first_valid(...)
        for i = 1, select("#", ...) do
            local value = select(i, ...)
            if is_valid_id(value) then return value end
        end
        return nil
    end
    local root_iid = first_valid(pick(root, "install_id_str"), pick(root, "install_id"))
    local root_did = first_valid(pick(root, "device_id_str"), pick(root, "device_id"))
    local data_iid, data_did
    if type(data) == "table" then
        data_iid = first_valid(pick(data, "install_id_str"), pick(data, "install_id"))
        data_did = first_valid(pick(data, "device_id_str"), pick(data, "device_id"))
    end
    iid, did = data_iid or root_iid, data_did or root_did
    iid = find_valid_id(root, { "install_id_str", "install_id" }, 0) or iid
    did = find_valid_id(root, { "device_id_str", "device_id" }, 0) or did
    if not is_valid_id(iid) or not is_valid_id(did) then
        return nil, nil, string.format(
            "注册返回无有效 Android 身份（HTTP=%s install_id=%s device_id=%s raw=%s）",
            tostring(code), tostring(iid), tostring(did), tostring(raw):sub(1, 180):gsub("[%c]", " "))
    end
    return iid, did
end

--- 保证数据目录里有一份可用身份：已有就复用，没有就注册并落盘。
function M.ensure_identity(data_dir, opts)
    local path = data_dir .. "/fanqie_device.json"
    local f = io.open(path, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local ok, json = pcall(require, "json")
        if ok then
            local okd, d = pcall(json.decode, raw)
            if okd and type(d) == "table" and d.install_id and d.device_id
                and tostring(d.install_id) ~= "" and tostring(d.install_id) ~= "0"
                and tostring(d.device_id) ~= "" and tostring(d.device_id) ~= "0" then
                return { install_id = tostring(d.install_id), device_id = tostring(d.device_id) }
            end
        end
    end

    -- 去重/限流时服务端回 0：换一套随机画像再试几次。
    -- **必须间隔**：实测同一套画像连着发会被拒，隔几秒再发就能拿到真身份（PC 侧验证过）。
    local ok_sleep, socket = pcall(require, "socket")
    local iid, did, err
    for attempt = 1, #PROFILES do
        local o = {}
        for k, v in pairs(opts or {}) do o[k] = v end
        for k, v in pairs(PROFILES[attempt]) do o[k] = v end
        iid, did, err = M.register(o)
        if iid then break end
        if attempt < #PROFILES and ok_sleep and socket and socket.sleep then
            socket.sleep(4)
        end
    end
    if not iid then
        return nil, tostring(err) .. "（服务端对注册有去重/限流，可稍后重试；或手动放 fanqie_device.json）"
    end

    local ok, json = pcall(require, "json")
    local fo = io.open(path, "w")
    if fo then
        if ok then
            fo:write(json.encode({ install_id = iid, device_id = did }))
        else
            fo:write(string.format('{"install_id":"%s","device_id":"%s"}', iid, did))
        end
        fo:close()
    end
    return { install_id = iid, device_id = did }
end

return M

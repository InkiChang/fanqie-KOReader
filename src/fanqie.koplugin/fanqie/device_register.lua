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

M.TT_FIXED_STRING_B64 = "TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA=="
M.TT_MAGIC = string.char(0x74, 0x63, 0x05, 0x10, 0x00, 0x00)
M.REGISTER_HOST = "https://log.snssdk.com"
M.REGISTER_PATH = "/service/2/device_register/"
M.USER_AGENT = "com.dragon.read/68132 (Linux; U; Android 10; zh_CN; Pixel 6; Build/QP1A.191005.007;tt-ok/3.12.13.4-tiktok)"
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
        return string.format("%%%02X", string.byte(c))
    end))
end

--- 服务端对"同一套画像"有去重/限流：重复注册会回 `device_id=0`（实测）。
--- 所以"0"必须当作**失败**，而且要换一套画像再试。
local function is_valid_id(v)
    return v ~= nil and v ~= "" and v ~= "0"
end

--- 备用画像池（换一套再注册，实测能拿到真身份）
local PROFILES = {
    { device_model = "Pixel 6", device_brand = "realme", os_version = "10",
      resolution = "1080x2400", rom = "QP1A.191005.007" },
    { device_model = "SM-G9810", device_brand = "samsung", os_version = "11",
      resolution = "1080x2400", rom = "RP1A.200720.012" },
    { device_model = "V2049A", device_brand = "vivo", os_version = "12",
      resolution = "1080x2376", rom = "SP1A.210812.003" },
    { device_model = "M2104K10AC", device_brand = "Xiaomi", os_version = "12",
      resolution = "1080x2400", rom = "SKQ1.211006.001" },
}

local function rand_alnum(n)
    local chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local out = {}
    for i = 1, n do
        out[i] = chars:sub(math.random(1, #chars), math.random(1, #chars))
    end
    return table.concat(out)
end

local function rand_mac()
    local HEX = "0123456789ABCDEF"
    local out = {}
    for i = 1, 12 do out[i] = HEX:sub(math.random(1, 16), math.random(1, 16)) end
    return table.concat(out)
end

local function uuid4()
    local HEX = "0123456789abcdef"
    local out = {}
    for i = 1, 32 do out[i] = HEX:sub(math.random(1, 16), math.random(1, 16)) end
    local s = table.concat(out)
    return s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-4" .. s:sub(14, 16) .. "-a"
        .. s:sub(18, 20) .. "-" .. s:sub(21, 32)
end

--- 组装注册请求体（未压缩的 JSON 字符串）
function M.build_json(opts)
    opts = opts or {}
    local now_ms = math.floor(os.time()) * 1000
    local header = {
        display_name = "番茄小说",
        update_version_code = opts.update_version_code or "68132",
        manifest_version_code = opts.version_code or 68132,
        aid = 1967,
        channel = opts.channel or "xiaomi_8993_64",
        package = opts.package or "com.dragon.read",
        app_version = opts.version_name or "6.8.1.32",
        version_code = opts.version_code or 68132,
        sdk_version = opts.sdk_version or "2.16.4",
        sdk_target_version = 29,
        os = "Android",
        os_version = opts.os_version or "10",
        os_api = 29,
        device_model = opts.device_model or "Pixel 6",
        device_brand = opts.device_brand or "realme",
        device_manufacturer = "Google",
        device_category = "phone",
        cpu_abi = "arm64-v8a",
        release_build = uuid4(),
        density_dpi = 420,
        display_density = "mdpi",
        resolution = opts.resolution or "1080x2400",
        language = "zh",
        mac = rand_mac(),
        timezone = 8,
        access = "wifi",
        not_request_sender = 0,
        carrier = "CHINA MOBILE",
        mcc_mnc = "46007",
        rom = opts.rom or "QP1A.191005.007",
        rom_version = opts.rom_version or "release-keys",
        sig_hash = SC.md5_hex(uuid4()),
        openudid = rand_alnum(16),
        clientudid = uuid4(),
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
    math.randomseed(os.time() + (os.clock() * 1000000) % 1000000)

    local body_json = M.build_json(opts)
    local payload = M.tt_encrypt(gzip.encode(body_json), opts.random32)

    local query = table.concat({
        "aid=1967", "app_name=novelapp", "channel=" .. url_escape(opts.channel or "xiaomi_8993_64"),
        "device_platform=android", "device_type=" .. url_escape(opts.device_model or "Pixel 6"),
        "os_version=" .. url_escape(opts.os_version or "10"), "tt_data=a",
        "version_code=" .. tostring(opts.version_code or 68132),
        "version_name=" .. url_escape(opts.version_name or "6.8.1.32"),
    }, "&")

    local url = M.REGISTER_HOST .. M.REGISTER_PATH .. "?" .. query
    local headers = {
        ["content-type"] = "application/octet-stream;tt-data=a",
        -- 上游规格里写的是 "gzip"，但那会让响应也变成 gzip，而 KOReader 上没有 zlib，
        -- 于是 `json.decode` 直接失败（真机实测报「注册响应不是合法 JSON」）。
        -- 改成 identity 直接要明文；正文接口（full/mget）也是这么干的，同样能过。
        ["accept-encoding"] = "identity",
        ["user-agent"] = M.USER_AGENT,
        ["host"] = "log.snssdk.com",
        ["connection"] = "Keep-Alive",
    }

    local okh, https = pcall(require, "ssl.https")
    local okl, ltn12 = pcall(require, "ltn12")
    if not (okh and okl) then return nil, nil, "缺少 ssl.https / ltn12" end

    local chunks = {}
    local ok, code = https.request({
        url = url, method = "POST", headers = headers,
        source = ltn12.source.string(payload), sink = ltn12.sink.table(chunks),
    })
    local raw = table.concat(chunks)
    if not raw or raw == "" then
        return nil, nil, string.format("注册响应为空（ok=%s code=%s）", tostring(ok), tostring(code))
    end
    if raw:sub(1, 2) == "\31\139" then
        return nil, nil, "注册响应是 gzip（本模块未解压；应让请求不要带 accept-encoding: gzip）"
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
            tostring(headers and headers["content-type"]))
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
    if not is_valid_id(iid) or not is_valid_id(did) then
        return nil, nil, string.format(
            "注册被去重/限流（install_id=%s device_id=%s）——需换随机画像重试",
            tostring(iid), tostring(did))
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
                and tostring(d.install_id) ~= "" and tostring(d.device_id) ~= "" then
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

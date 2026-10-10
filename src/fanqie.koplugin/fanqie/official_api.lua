--[[ 官方移动端接口的「请求组装 + 响应解析/解密」—— 纯 Lua。

对应 Python 参考实现 `full_mget_client.py`（已成功解出可读中文）。
要点（这几条是踩过坑才定下来的）：
  * 取正文走 **POST** `novelfm-hl.snssdk.com/novelfm/playerapi/full/mget/v1/`（aid=3040），
    不是 GET `reading.snssdk.com/reading/reader/full/v/`（那条对加密章节只给占位串 "Invalid"）；
  * **POST 非空 body 必须发 `x-ss-stub = MD5(body)`**；GET 空 body 时**不能发**（发了被静默拒绝）；
  * body 用紧凑 JSON（`separators=(",",":")`），因为签名/`x-ss-stub` 都按 body 字节算；
  * query 里的参数与顺序也要与签名时一致（`x-argus` 的 queryHash 覆盖整个 query）。
]]

local argus = require("fanqie.argus")
local cm = require("fanqie.cm")
local SC = require("fanqie.sign_crypto")

local M = {}

M.MGET_HOST = "https://novelfm-hl.snssdk.com"
M.MGET_PATH = "/novelfm/playerapi/full/mget/v1/"
M.UA = "com.dragon.read"
M.CONTENT_TYPE = "application/json; charset=utf-8"
M.AID = 3040

--- 组装 POST full/mget 的 url / query / body
-- @param book_id 字符串
-- @param item_ids 字符串数组
-- @param device_id, install_id 设备身份
-- @param key_b64 CM 握手产出的 key
function M.build_mget(book_id, item_ids, device_id, install_id, key_b64)
    local url = M.MGET_HOST .. M.MGET_PATH
        .. "?aid=3040&app_name=novelapp&channel=0&device_id=" .. device_id
        .. "&device_platform=android&device_type=UGFFI55&iid=" .. install_id
        .. "&os_version=0&version_code=58932&version_name=5.8.9.32"
    local query = url:match("%?(.*)$")

    local ids = {}
    for i, v in ipairs(item_ids) do ids[i] = '"' .. tostring(v) .. '"' end
    local body = '{"book_id":"' .. tostring(book_id) .. '","item_ids":['
        .. table.concat(ids, ",") .. '],"key":"' .. key_b64 .. '"}'
    return url, query, body
end

--- 组装请求头。opts.rand_field 可注入（测试用），否则随机。
function M.mget_headers(query, body, kh, device_id, install_id, opts)
    opts = opts or {}
    local stub = SC.md5_hex(body)
    local headers = {
        ["User-Agent"] = M.UA,
        ["Content-Type"] = M.CONTENT_TYPE,
        ["x-ss-req-ticket"] = tostring(kh * 1000),
        ["x-khronos"] = tostring(kh),
        ["x-ss-stub"] = stub,
        ["x-argus"] = argus.get_sign(query, stub, kh, M.AID, argus.LICENSE_ID,
            device_id, install_id, "551", opts.rand_field),
        ["x-ladon"] = SC.ladon(kh, argus.LICENSE_ID, M.AID),
    }
    return headers, stub
end

--- 一次完整请求的组装：返回 url, body, headers, cm_state
function M.new_mget_request(book_id, item_ids, device_id, install_id, opts)
    local state = cm.new()
    local url, query, body = M.build_mget(book_id, item_ids, device_id, install_id, state.key_b64)
    local kh = (opts and opts.kh) or os.time()
    local headers = M.mget_headers(query, body, kh, device_id, install_id, opts)
    return { url = url, query = query, body = body, headers = headers,
             cm = state, kh = kh }
end

--- 段评（idea list）——规格来自 fqapp `rust/src/endpoints/comments.rs`，已 PC 实测 `code:0`。
--- 之前一直 404/110001 的原因：路径少 `/{item_id}/v1`，且缺下面这包公共参数。
--- 返回：`data.data` 的键就是**段落号**，每段带 `count`（段评数）与 `bubble_data`。
M.IDEA_HOST = "https://api5-normal.fqnovel.com"
M.IDEA_PATH_PREFIX = "/novel/commentapi/idea/list/"

--- 公共参数包（照抄 reading724_params()，顺序一致）
function M.reading724_params(device_id, install_id)
    return {
        { "iid", install_id }, { "device_id", device_id }, { "ac", "wifi" },
        { "channel", "xiaomi_1967_64" }, { "aid", "1967" }, { "app_name", "novelapp" },
        { "version_code", "72432" }, { "version_name", "7.2.4.32" },
        { "device_platform", "android" }, { "os", "android" }, { "ssmix", "a" },
        { "device_type", "25053RT47C" }, { "device_brand", "Redmi" }, { "language", "zh" },
        { "os_api", "36" }, { "os_version", "16" }, { "manifest_version_code", "72432" },
        { "resolution", "1280*2620" }, { "dpi", "520" }, { "update_version_code", "72432" },
        { "host_abi", "arm64-v8a" }, { "dragon_device_type", "phone" }, { "pv_player", "72432" },
        { "compliance_status", "0" }, { "need_personal_recommend", "1" },
        { "player_so_load", "1" }, { "is_android_pad_screen", "0" },
        { "rom_version", "miui_V816_OS3.0.9.0.WOLCNXM" },
    }
end

local function url_escape(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function M.encode_pairs(pairs)
    local out = {}
    for i, kv in ipairs(pairs) do
        out[i] = url_escape(kv[1]) .. "=" .. url_escape(kv[2])
    end
    return table.concat(out, "&")
end

--- 组装段评请求：返回 url, query, body。`para_index` 非空时**只问那一段**
--- （路由 `/api/v1/chapters/{id}/paragraphs/{para}/reviews` → `idea_list` + `para_index`，
---  这时 `infos` 里才会带**那一段**的 comment_id）。
function M.build_ideas_request(book_id, item_id, device_id, install_id, para_index)
    local query = M.encode_pairs(M.reading724_params(device_id, install_id))
    local para = ""
    if para_index and tonumber(para_index) then
        para = ',"para_index":' .. tostring(math.floor(tonumber(para_index)))
    end
    local body = table.concat({
        '{"comment_source":1,"compliance_status":0,"item_id":"', tostring(item_id),
        '","book_id":"', tostring(book_id),
        '","item_version":"0","server_channel":7', para, '}',
    })
    local url = M.IDEA_HOST .. M.IDEA_PATH_PREFIX .. tostring(item_id) .. "/v1?" .. query
    return url, query, body
end

--- 段评请求头：签名覆盖 query，`x-ss-stub = MD5(body)`（POST 必须发）
function M.ideas_headers(query, body, kh, device_id, install_id, opts)
    opts = opts or {}
    local stub = SC.md5_hex(body)
    return {
        ["User-Agent"] = M.UA,
        ["Content-Type"] = "application/json; charset=utf-8",
        ["Accept-Encoding"] = "identity",
        ["x-ss-req-ticket"] = tostring(kh * 1000),
        ["x-khronos"] = tostring(kh),
        ["x-ss-stub"] = stub,
        ["x-argus"] = argus.get_sign(query, stub, kh, 1967, argus.LICENSE_ID,
            device_id, install_id, "551", opts.rand_field),
        ["x-ladon"] = SC.ladon(kh, argus.LICENSE_ID, 1967),
    }, stub
end

--- 移动端目录请求头（**GET 且空 body：不要发 `x-ss-stub`** —— 实测发了会被拒）。
--- 用于 `GET /reading/bookapi/directory/all_items/v/`（`data.item_data_list[].version` 是段评
--- 接口必须的 `item_version`）。
function M.directory_headers(query, kh, device_id, install_id)
    return {
        ["User-Agent"] = M.UA,
        ["Accept-Encoding"] = "identity",
        ["x-khronos"] = tostring(kh),
        ["x-ss-req-ticket"] = tostring(kh * 1000),
        ["x-argus"] = argus.get_sign(query, "", kh, 1967, argus.LICENSE_ID,
            device_id, install_id, "551"),
        ["x-ladon"] = SC.ladon(kh, argus.LICENSE_ID, 1967),
    }
end

--- 用 KOReader 自带的 json 解码（测试环境可能没有；调用方决定怎么处理）
function M.decode_response(raw)
    local ok, json = pcall(require, "json")
    if not ok then return nil, "本环境没有 json 模块" end
    local ok2, res = pcall(json.decode, raw)
    if not ok2 then return nil, "JSON 解析失败" end
    return res
end

--- 从已解码的响应里取出各章正文并解密
-- 返回 { {item_id, title, crypt_status, text|error}, ... }, err
function M.parse_mget(root, priv)
    if type(root) ~= "table" then return nil, "响应不是表" end
    if root.code ~= 0 then return nil, "code=" .. tostring(root.code) .. " " .. tostring(root.message) end
    local infos = ((root.data or {}).item_infos) or {}
    local out = {}
    for id, item in pairs(infos) do
        local rec = { item_id = id, title = item.title, crypt_status = item.crypt_status }
        local ck, sk = item.content, item.key
        if ck and ck ~= "" and ck ~= "Invalid" and sk and sk ~= "" then
            local ok, pt = pcall(cm.decrypt, priv, sk, ck)
            if ok then
                rec.text = pt
            else
                rec.error = tostring(pt)
            end
        else
            rec.error = "content 缺失或为占位串（crypt_status=" .. tostring(item.crypt_status) .. "）"
        end
        out[#out + 1] = rec
    end
    return out
end

--- 正文里的 <p idx="N"> 分段 → 纯文本（等价于 content_util.rs 的清洗思路）
function M.html_to_text(s)
    if not s then return "" end
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("</p>", "\n")
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("[ \t]+\n", "\n")
    s = s:gsub("\n\n+", "\n")
    return (s:gsub("^\n+", ""))
end

return M

-- fanqie.official_api 用例：请求组装 + 响应解析/解密
--
-- 这是"在真机之前"能拿到的最强验证：把一次完整请求（url/query/body/头）与一次完整响应
-- （合成服务端 + 合成正文）在 Lua 里重放一遍，并且 **x-argus 与 Python 参考实现逐字节对比**
-- （Python 那边已命中上游 4 条黄金向量，所以这条对比是有含金量的）。
--
-- 向量里不含真实设备标识，也不含任何作品正文。

local T = require("tap")
local K = require("koreader")

local official = require("fanqie.official_api")
local cm = require("fanqie.cm")
local SC = require("fanqie.sign_crypto")

local function load_vectors()
    for _, p in ipairs({
        "tests/spec/vectors_official.lua",
        "tests/spec/vectors_official.lua",
    }) do
        local ok, res = pcall(dofile, p)
        if ok and type(res) == "table" then return res end
    end
    error("找不到 tests/spec/vectors_official.lua（请从仓库根目录运行测试）")
end

local V = load_vectors()
local function unhex(s)
    return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end
local hex = SC.hex_encode

T.test("请求组装：url / query / body 与参考实现逐字节一致", function(t)
    local key_b64 = cm.handshake(unhex(V.priv_hex), unhex(V.iv_hex))
    local url, query, body = official.build_mget(V.book_id, { V.item_id },
        V.device_id, V.install_id, key_b64)
    t:eq(url, V.url, "url")
    t:eq(query, V.query, "query")
    t:eq(hex(body), V.body_hex, "body（紧凑 JSON，字节级一致）")
    t:eq(#body, V.body_len, "body 长度")
end)

T.test("请求头：x-ss-stub 与 x-argus 对上 Python 参考实现", function(t)
    local key_b64 = cm.handshake(unhex(V.priv_hex), unhex(V.iv_hex))
    local _, query, body = official.build_mget(V.book_id, { V.item_id },
        V.device_id, V.install_id, key_b64)
    local h, stub = official.mget_headers(query, body, V.kh, V.device_id, V.install_id,
        { rand_field = V.rand_field })
    t:eq(stub, V.stub_md5, "x-ss-stub = MD5(body)")
    t:eq(h["x-ss-stub"], V.stub_md5, "头里带了 x-ss-stub（POST 必须发）")
    t:eq(h["x-argus"], V.x_argus, "x-argus 与 Python 参考逐字节一致")
    t:eq(h["x-khronos"], tostring(V.kh), "x-khronos")
    t:eq(h["x-ss-req-ticket"], tostring(V.kh * 1000), "x-ss-req-ticket 是毫秒")
    t:ok(#h["x-ladon"] > 0, "x-ladon 非空")
    t:eq(h["Content-Type"], "application/json; charset=utf-8", "Content-Type")
end)

T.test("响应解析 + 解密：合成章节能解回明文", function(t)
    local _, priv = cm.public_key_bytes(unhex(V.priv_hex))
    local root = {
        code = 0,
        data = {
            item_infos = {
                [V.item_id] = {
                    title = "第一章",
                    crypt_status = 1,
                    key = V.server_key_b64,
                    content = V.content_b64,
                },
            },
        },
    }
    local recs, err = official.parse_mget(root, priv)
    t:eq(err, nil, "没有错误")
    t:eq(#recs, 1, "解出 1 条")
    t:eq(hex(recs[1].text), V.plain_hex, "明文逐字节一致")
    t:eq(recs[1].text, V.plain_head, "明文内容")
    t:eq(recs[1].crypt_status, 1, "crypt_status 带回来了")
end)

T.test("响应解析：错误码与占位串不会被当成正文", function(t)
    local _, priv = cm.public_key_bytes(unhex(V.priv_hex))
    local recs, err = official.parse_mget({ code = 1001, message = "ILLEGAL_ACCESS" }, priv)
    t:eq(recs, nil, "非 0 code 直接失败")
    t:ok(err and err:find("1001"), "错误里带上 code")

    local root = { code = 0, data = { item_infos = { [V.item_id] = {
        crypt_status = 2, key = "", content = "Invalid" } } } }
    local r2 = official.parse_mget(root, priv)
    t:eq(#r2, 1, "仍返回一条")
    t:eq(r2[1].text, nil, "没有明文")
    t:ok(r2[1].error and r2[1].error:find("占位串"), "说明是占位串而不是崩溃")
end)

T.test("正文清洗：把 <p idx> 分段变成纯文本", function(t)
    local out = official.html_to_text('<header></header><article><p idx="0">甲</p><p idx="1">乙</p></article>')
    t:ok(not out:find("<"), "没有残留标签")
    t:ok(out:find("甲") and out:find("乙"), "两段都在")
end)

--[[ 设备端自测：在真机上把「官方移动端源」这条链路跑一遍，并把结果写进文件。

为什么单独一个模块：真机实测需要的东西（设备身份、HTTPS、gzip、日志）与纯算法模块解耦，
这样算法部分仍能在测试基座里验；本模块只在设备上跑。

触发方式：`<数据目录>/fanqie_selftest.flag` 存在时，插件加载后执行一次（flag 随即删除）。
结果同时写到 `<数据目录>/fanqie_selftest.out`（纯文本，便于 adb 直接读）。

设备身份：从 `<数据目录>/fanqie_device.json` 读（{"install_id":...,"device_id":...}）。
]]

local M = {}

local function data_dir()
    local ok, ds = pcall(require, "datastorage")
    if ok and ds then
        local d = ds:getDataDir()
        if d and d ~= "" then return d end
    end
    return "."
end

local OUT = {}

local function say(s)
    OUT[#OUT + 1] = tostring(s)
    local ok, lg = pcall(require, "fanqie.logger")
    if ok and lg and lg.info then pcall(lg.info, "[自测] " .. tostring(s)) end
end

local function read_file(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- 执行一次端到端自测。返回 true/false，结果文本见 written file。
function M.run()
    local d = data_dir()
    local out_path = d .. "/fanqie_selftest.out"
    local ok_all, err = pcall(function()
        say("数据目录：" .. d)

        -- 1) 设备身份（优先已有文件；没有就**自动注册**，这正是"重新登录/全新设备"要走的路）
        local reg = require("fanqie.device_register")
        local okr, id, regerr = pcall(reg.ensure_identity, d)
        if not okr then
            say("FAIL: 设备身份处理异常：" .. tostring(id))
            return false
        end
        if type(id) ~= "table" or not id.install_id or not id.device_id then
            say("FAIL: 拿不到设备身份：" .. tostring(regerr))
            return false
        end
        say(string.format("设备身份：已就绪（install_id 长度=%d，device_id 长度=%d；值不打印）",
            #tostring(id.install_id), #tostring(id.device_id)))
        local did = tostring(id.device_id)
        local iid = tostring(id.install_id)

        -- 2) 造请求（含 CM 握手，会做一次 1536 位模幂）
        local official = require("fanqie.official_api")
        local t0 = os.time()
        local req = official.new_mget_request(
            "7241818860003789863", { "7241820475482079783" }, did, iid, { kh = t0 })
        say(string.format("请求已组装：url=%d 字节 body=%d 字节 x-argus=%d 字符；握手耗时约 %d 秒",
            #req.url, #req.body, #(req.headers["x-argus"] or ""), os.time() - t0))

        -- 3) 发 HTTPS
        local okh, https = pcall(require, "ssl.https")
        local okl, ltn12 = pcall(require, "ltn12")
        if not (okh and okl) then
            say("FAIL: 缺少 ssl.https / ltn12"); return false
        end
        req.headers["Accept-Encoding"] = "identity"     -- 尽量让服务端别 gzip
        local chunks = {}
        local t1 = os.time()
        local ok2, code, headers, status = https.request {
            url = req.url,
            method = "POST",
            headers = req.headers,
            source = ltn12.source.string(req.body),
            sink = ltn12.sink.table(chunks),
        }
        local raw = table.concat(chunks)
        say(string.format("HTTP 请求：ok=%s code=%s status=%s 响应 %d 字节，耗时 %d 秒",
            tostring(ok2), tostring(code), tostring(status), #raw, os.time() - t1))
        if not raw or raw == "" then
            say("FAIL: 响应为空（多为风控拒绝或网络不通）")
            return false
        end

        -- 4) gzip？
        if raw:sub(1, 2) == "\31\139" then
            say("响应是 gzip：说明请求已被接受（风控通过），但本模块暂不解压")
            return false
        end

        -- 5) 解析 + 解密
        local okj2, json2 = pcall(require, "json")
        if not okj2 then say("FAIL: 没有 json 模块"); return false end
        local root = json2.decode(raw)
        say("顶层 code=" .. tostring(root and root.code) .. " message=" .. tostring(root and root.message))
        local recs, perr = official.parse_mget(root, req.cm.priv)
        if not recs then
            say("FAIL: 解析失败 " .. tostring(perr))
            return false
        end
        say("解出 " .. #recs .. " 条")
        for i, r in ipairs(recs) do
            if r.text then
                local txt = official.html_to_text(r.text)
                say(string.format("  [%d] %s 明文 %d 字节，首 80 字：%s",
                    i, tostring(r.title), #txt, txt:sub(1, 80)))
            else
                say(string.format("  [%d] %s 无明文：%s", i, tostring(r.title), tostring(r.error)))
            end
        end
        return true
    end)
    if not ok_all then say("异常：" .. tostring(err)) end

    local fo = io.open(out_path, "w")
    if fo then
        fo:write(table.concat(OUT, "\n") .. "\n")
        fo:close()
    end
    return ok_all
end

return M

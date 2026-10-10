--- 基座自检：先证明"假 KOReader"本身是可信的，再去信它跑出来的插件结论。
--
-- 这个文件是整套测试的地基。它一旦红了，其它 spec 的结果都不必看。

local K = require("koreader")

local T = require("tap")

T.test("基座.gettext 恒等且保留 %N 占位语义", function(t)
    local _ = require("gettext")
    t:eq(_("番茄小说"), "番茄小说", "无参数时原样返回")
    t:eq(_("共 %1 章", 12), "共 12 章", "支持 KOReader 的 %N 占位")
end)

T.test("基座.datastorage 指向临时数据目录", function(t)
    local DataStorage = require("datastorage")
    t:eq(DataStorage:getFullDataDir(), K.data_dir, "数据目录不应落到真实 KOReader 目录")
    t:ok(not K.data_dir:find("koreader/settings"), "不能写进用户真实配置目录")
end)

T.test("基座.lfs 能建目录、看属性、列目录、删目录", function(t)
    local lfs = require("libs/libkoreader-lfs")
    local dir = K.data_dir .. "/lfs_probe"
    t:eq(lfs.attributes(dir, "mode"), nil, "目录一开始不存在")
    t:ok(lfs.mkdir(dir), "mkdir 应成功")
    t:eq(lfs.attributes(dir, "mode"), "directory", "建完应识别为目录")

    K.write_file(dir .. "/a.txt", "hello")
    local size = lfs.attributes(dir .. "/a.txt", "size")
    t:eq(size, 5, "size 应是字节数")
    t:eq(lfs.attributes(dir .. "/a.txt", "mode"), "file", "普通文件")
    t:eq(lfs.attributes(dir .. "/nope"), nil, "不存在的路径返回 nil")
    t:ok(type(lfs.attributes(dir)) == "table", "不传字段时返回属性表")

    local seen = {}
    for entry in lfs.dir(dir) do
        seen[entry] = true
    end
    t:ok(seen["a.txt"], "dir 应列出 a.txt")
    -- 真 LuaFileSystem 会给 "." 与 ".."；基座必须一致，否则"遍历目录"类代码
    -- 在测试里看到的输入集与真机不同（现有调用点都过滤两者，但语义差要消除）。
    t:ok(seen["."], "dir 应包含 .")
    t:ok(seen[".."], "dir 应包含 ..")

    t:ok(lfs.remove(dir .. "/a.txt"), "remove 文件")
    t:eq(lfs.attributes(dir .. "/a.txt"), nil, "删掉后就查不到了")
    t:ok(lfs.rmdir(dir), "rmdir 空目录")
    t:eq(lfs.attributes(dir), nil, "目录已消失")
end)

T.test("基座.util.makePath 递归建目录且幂等", function(t)
    local util = require("util")
    local deep = K.data_dir .. "/a/b/c"
    t:ok(util.makePath(deep), "递归创建应成功")
    t:ok(K.is_dir(deep), "叶子目录存在")
    t:ok(util.makePath(deep), "重复调用应幂等返回真")
    t:ok(util.pathExists(deep .. "/.."), "pathExists 能处理相对片段")
    t:eq(util.joinPath("x/", "/y/", "z"), "x/y/z", "joinPath 归一化斜杠")
    t:eq(select(2, util.splitFileNameSuffix("book.epub")), "epub", "拆扩展名")
end)

T.test("基座.util.template 复刻 KOReader 的 %N 模板语义", function(t)
    -- 这是插件最容易踩空的一处：main.lua:52 直接 `local T = T_util.template`，
    -- 然后 26 处 `T(_("...%1..."), a)`。桩化会让全部文案断言失真。
    local util = require("util")
    local _ = require("gettext")
    local T = util.template

    t:eq(T("共 %1 章", 12), "共 12 章", "单占位")
    t:eq(T(_("段评 %1/%2 (共%3条)"), 3, 10, 27), "段评 3/10 (共27条)", "多占位，形如插件原文案")
    t:eq(T("章节 %1", 0), "章节 0", "0 也是有效值，不能被判成缺失")
    t:eq(T("没有占位"), "没有占位", "无占位时原样返回")
    t:eq(T("缺参数 %1|%2", "A"), "缺参数 A|", "缺失的参数退化为空串")
    t:eq(select("#", T("a%1", 1)), 1, "只返回一个值，不会漏出 gsub 的替换计数")
end)

T.test("基座.logger 收集日志", function(t)
    local logger = require("logger")
    K.reset_log()
    logger.warn("磁盘快满了")
    logger.err("请求失败")
    local lines = K.log_lines
    t:eq(#lines, 2, "应有两条日志")
    t:eq(lines[1].level, "warn", "级别保留")
    t:eq(lines[1].text, "磁盘快满了", "文本保留")
    t:eq(lines[2].level, "err", "第二条级别")
end)

T.test("基座.网络替身可按注入的响应驱动 socket.http", function(t)
    local http = require("socket.http")
    local seen_url
    K.net.set_transport(function(req)
        seen_url = req.url
        return {
            status = 200,
            headers = { ["content-type"] = "application/json" },
            body = '{"code":0,"data":{"id":"7351"}}',
        }
    end)

    local chunks = {}
    local status, headers, _, url = http.request({
        url = "https://api5-normal-hl.fqnovel.com/api/book/simple/info?book_id=7351",
        method = "GET",
        sink = function(chunk) chunks[#chunks + 1] = chunk end,
    })

    t:eq(status, 200, "状态码透传")
    t:eq(headers["content-type"], "application/json", "响应头被规范化为小写")
    t:eq(table.concat(chunks), '{"code":0,"data":{"id":"7351"}}', "body 流入 sink")
    t:eq(seen_url, "https://api5-normal-hl.fqnovel.com/api/book/simple/info?book_id=7351", "URL 原样送达传输层")
end)

T.test("基座.网络替身也接受 LuaSocket 风格的响应头数组", function(t)
    local http = require("socket.http")
    K.net.set_transport(function()
        return {
            status = 403,
            headers = { "X-RateLimit-Remaining: 0", "Content-Type: text/plain" },
            body = "blocked",
        }
    end)
    local body = {}
    local status, headers = http.request({
        url = "https://fanqienovel.com/x",
        sink = function(c) body[#body + 1] = c end,
    })
    t:eq(status, 403, "状态码")
    t:eq(headers["x-ratelimit-remaining"], "0", "数组式响应头也能解析")
    t:eq(headers["content-type"], "text/plain", "第二行也解析")
    t:eq(table.concat(body), "blocked", "body 仍到位")
end)

T.test("基座.传输函数缺失时给出可读错误而不是崩溃", function(t)
    local http = require("socket.http")
    K.net.reset()
    local ok, status, err = pcall(http.request, { url = "https://example.com", sink = function() end })
    t:ok(ok, "不应抛异常")
    t:eq(status, nil, "没有传输层时不返回状态码")
    t:contains(tostring(err), "transport", "错误信息说明是传输层问题")
end)

T.test("基座.宽松桩让 KOReader 的 UI 模块 require 得到", function(t)
    -- --strict 的语义就是"拒绝为 UI 模块造桩"，本用例的前提在那里根本不存在。
    -- 报失败是误报，所以显式跳过（而不是让 --strict 永远带着一条假红）。
    if os.getenv("FANQIE_TEST_STRICT") == "1" then
        t:skip("--strict 刻意关闭了宽松桩，本用例的前提不成立")
    end

    local UIManager = require("ui/uimanager")
    t:ok(UIManager ~= nil, "ui/uimanager 应能被 require")
    -- 桩的特点：任意字段都是函数、任意调用都返回新桩，所以插件代码不会炸
    t:ok(type(UIManager.show) == "function", "任意方法存在")
    t:ok(type(UIManager.some_future_api) == "function", "未见过的方法也存在")
    local widget = require("ui/widget/buttondialog")
    t:ok(widget ~= nil, "深层 UI 模块同样可用")
end)

T.test("基座.数据目录可写且写盘内容可读回", function(t)
    -- 逐 spec 的清空由 tests/run.lua 负责（每个 spec 文件之前 rmrf + mkdir），
    -- 所以这里只验证"写进去能读回来"这条插件缓存逻辑依赖的能力。
    t:ok(K.is_dir(K.data_dir), "数据目录存在")
    local f = K.data_dir .. "/roundtrip/中文 目录/缓存.txt"
    t:ok(K.write_file(f, "番茄小说"), "嵌套 + 中文 + 空格路径可写")
    t:eq(K.read_file(f), "番茄小说", "读回内容一致")
    t:eq(select(1, require("libs/libkoreader-lfs").attributes(f, "size")),
        #"番茄小说", "size 按字节计（UTF-8 下中文 4 字 12 字节）")
end)

T.test("基座.io.open 保持 LF 不被翻译成 CRLF", function(t)
    -- KOReader 只跑 Linux/Android，C 库 stdio 不做换行翻译；而 Windows 文本模式会把
    -- \n 写成 \r\n。不抹平这一处，同一个字节级断言会在本地与 CI 给出不同结果。
    local f = K.data_dir .. "/newline.txt"
    local h = assert(io.open(f, "wb"))
    h:write("a\nb\n")
    h:close()
    t:eq(K.read_file(f), "a\nb\n", "换行原样保留")
    t:eq(K.read_file(f):find("\r", 1, true), nil, "不应出现 \\r")
end)

T.test("基座.io.open 对 UTF-8 中文路径可写可读", function(t)
    -- Windows 的 fopen 走 ANSI 代码页，中文路径直接失败；真机没这问题，但测试里会
    -- 表现为"章节缓存写不进去"。基座在这种情况下回退到 Python 文件对象。
    local dir = K.data_dir .. "/中文目录/子目录"
    t:ok(K.mkdir_p(dir), "中文目录可创建")
    local f = dir .. "/chapter_7541813009765633048.html" -- 形如插件真实缓存名
    t:ok(K.write_file(f, "<p>正文</p>"), "中文目录 + 长数字文件名可写")
    t:eq(K.read_file(f), "<p>正文</p>", "读回一致")

    local h = assert(io.open(f, "r"))
    t:eq(h:read("*a"), "<p>正文</p>", "io.open 走兜底也能整读")
    h:close()

    t:ok(K.rmrf(dir), "中文路径可递归删除")
    t:ok(not K.exists(dir), "删完即消失")
end)

T.test("基座.io.open 对中文路径传输任意字节而不做编码转换", function(t)
    -- 这条钉住基座最容易出错的一处边界：lupa 在 encoding="utf-8" 下，会把送进
    -- Python 的 Lua 字符串**先按 UTF-8 解码**，任何非法 UTF-8 字节都直接抛
    -- UnicodeDecodeError。所以"写"不能跨边界传数据——改成 Lua 先写一个纯 ASCII
    -- 路径的中转文件，再由 Python 按路径搬到目标位置：跨过边界的只有路径。
    -- EPUB 产物是 zip，字节里必然出现 0x80-0xFF 的裸字节，这条一旦红，
    -- "--含中文路径的落盘"就是假的绿灯。
    local dir = K.data_dir .. "/字节保真"
    t:ok(K.mkdir_p(dir), "中文目录可创建")
    local f = dir .. "/raw.bin"

    -- 故意混入非法 UTF-8 起始字节 0xAB/0xCD/0xFF，以及 NUL 与 SUB
    local payload = "\120\171\205\255\0\26\1"
    local h = assert(io.open(f, "wb"))
    t:ok(h:write(payload), "应能写入裸字节")
    t:ok(h:close(), "close 应返回成功（它才是真正落盘的一步）")

    t:eq(K.read_file(f), payload, "读回必须逐字节相同")
    t:eq(select(1, require("libs/libkoreader-lfs").attributes(f, "size")),
        #payload, "size 必须按字节计（中文路径下也一样）")

    -- 覆盖写：确认是截断而不是续写
    local h2 = assert(io.open(f, "wb"))
    h2:write("\1\2\3")
    h2:close()
    t:eq(#K.read_file(f), 3, "覆盖写后长度应变成 3")
end)

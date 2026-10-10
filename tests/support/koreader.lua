--- KOReader 运行时替身（test harness bootstrap）
--
-- 目标：让 `src/fanqie.koplugin/` 里的纯逻辑模块（content / cookie / sources /
-- settings / fanqie / epub / client）能在**不装 KOReader** 的情况下被真实执行与断言。
--
-- 策略分三层，从"真"到"假"：
--   1. 真实实现——少数被依赖语义的模块自己写一份可用实现：
--        gettext、datastorage、util.makePath、logger、libs/libkoreader-lfs
--   2. 可控替身——网络栈（socket / ltn12 / ssl）由测试注入传输函数，
--      这样 client.lua 可以对着 mock 番茄服务跑完整请求-解析链路
--   3. 宽松桩——其余 KOReader 模块（ui/*、apps/*、device、ffi/*）按需返回
--      一个"什么方法都存在、调用都返回新桩"的表，保证 require 与调用不炸
--
-- 环境变量：
--   FANQIE_REPO_ROOT    仓库根目录（未设置时按相对路径猜）
--   FANQIE_TEST_STRICT  设为 1 时，第 3 层桩会直接报错。
--                       用途：在 CI 里守住"纯逻辑模块不许依赖 UI"这条边界。
--   FANQIE_STUB_LOG     设为 1 时，把被桩化的模块名打印出来（排查隐式依赖）

local M = {}

local repo_root = rawget(_G, "__FANQIE_REPO_ROOT")
    or os.getenv("FANQIE_REPO_ROOT")
    or "."
M.repo_root = repo_root

-- ---------------------------------------------------------------------------
-- 1. 模块搜索路径
-- ---------------------------------------------------------------------------
local plugin_root = repo_root .. "/src/fanqie.koplugin"
local support_root = repo_root .. "/tests/support"

local paths = {
    support_root .. "/?.lua",
    repo_root .. "/tests/?.lua",
    repo_root .. "/tests/spec/?.lua",
    plugin_root .. "/?.lua",
    plugin_root .. "/?/init.lua",
    plugin_root .. "/?.lua",
}
-- 保留原有搜索路径（原生 lua-filesystem 等模块还要靠它找），项目路径排在前面
local existing = {}
for part in package.path:gmatch("[^;]+") do existing[#existing + 1] = part end
package.path = table.concat(paths, ";") .. ";" .. table.concat(existing, ";")

-- ---------------------------------------------------------------------------
-- 2. LuaFileSystem：优先真实模块，其次 Python 桥接
-- ---------------------------------------------------------------------------
local lfs
do
    local ok, mod = pcall(require, "lfs")
    if ok and mod then
        lfs = mod
        M.lfs_source = "native"
    else
        local bridged, err = require("lfs_python")
        if not bridged then
            error("找不到 LuaFileSystem，且 Python 桥接不可用：" .. tostring(err), 0)
        end
        lfs = bridged
        M.lfs_source = "python-bridge"
    end
    package.preload["libs/libkoreader-lfs"] = function() return lfs end
    M.lfs = lfs
end

-- ---------------------------------------------------------------------------
-- 3. 真实实现层
-- ---------------------------------------------------------------------------

-- KOReader 的文案模板是 %1/%2 占位（不是 string.format 的 %s），照此实现。
-- 必须定义在 gettext 之前——Lua 的词法作用域不认后面的 local。
local function template(str, ...)
    local args = { ... }
    return (tostring(str):gsub("%%(%d+)", function(d)
        local v = args[tonumber(d)]
        if v == nil then return "" end
        return tostring(v)
    end))
end

-- gettext：插件里大量 `_("中文")`。测试不做翻译（恒等），但保留 KOReader 的
-- %1/%2 占位替换语义，这样 `_("共 %1 章", 12)` 与 `T(_("共 %1 章"), 12)` 都对。
package.preload["gettext"] = function()
    return function(text, ...)
        if select("#", ...) == 0 then return text end
        return template(text, ...)
    end
end

-- 数据目录：所有写盘用例都落在临时目录里，测试之间互不污染
local data_dir = rawget(_G, "__FANQIE_TEST_DATA_DIR")
    or os.getenv("FANQIE_TEST_DATA_DIR")
    or "/tmp/fanqie-koreader-test"
M.data_dir = data_dir
package.preload["datastorage"] = function()
    local DataStorage = {}
    function DataStorage:getFullDataDir() return data_dir end
    function DataStorage:getSettingsDir() return data_dir .. "/settings" end
    function DataStorage:getDataDir() return data_dir end
    DataStorage._data_dir = data_dir
    return DataStorage
end

local function mkdir_p(path)
    if path == "" or path == "/" then return true end
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdir_p(parent) end
    lfs.mkdir(path)
    return lfs.attributes(path, "mode") == "directory"
end
M.mkdir_p = mkdir_p

-- util / ffi/util：KOReader 的通用工具。
-- 这里必须是**真实现**而不是桩，原因有两处硬依赖：
--   * main.lua:52 `local T = T_util.template`——插件的 26 处文案拼接全靠它，
--     桩会把 `T(_("共 %1 章"), n)` 变成假值，让字符串断言全部失真；
--   * main.lua:54 `local util = safe_require("util")`。
local util = {}
util.template = template
util.makePath = mkdir_p
util.pathExists = function(p) return lfs.attributes(p, "mode") ~= nil end
util.splitFilePathName = function(p)
    local dir, name = tostring(p):match("^(.*)/([^/]*)$")
    if not dir then return "./", tostring(p) end
    return dir .. "/", name
end
util.splitFileNameSuffix = function(name)
    local base, suffix = tostring(name):match("^(.*)%.([^.]*)$")
    if not base then return tostring(name), "" end
    return base, suffix
end
util.joinPath = function(...)
    local parts = { ... }
    local out = {}
    for _, p in ipairs(parts) do
        p = tostring(p or ""):gsub("^/+", ""):gsub("/+$", "")
        if p ~= "" then out[#out + 1] = p end
    end
    return table.concat(out, "/")
end

package.preload["util"] = function() return util end
-- KOReader 里 `ffi/util` 才是真正实现，`util` 是它的门面；测试里两者同一张表即可
package.preload["ffi/util"] = function() return util end

-- ---------------------------------------------------------------------------
-- io.open：抹平 Windows 与 Linux 的三处偏差
-- ---------------------------------------------------------------------------
-- 偏差一（换行）：KOReader 只跑 Linux/Android，C 库 stdio 不做换行翻译；而 Windows
--   文本模式会把 \n 写成 \r\n。这会让字节级断言在 Windows 与 CI 上给出不同结果。
--   于是这里一律按二进制打开——这正是 Linux 上 KOReader 看到的行为。
-- 偏差二（路径编码）：Windows 的 fopen 走 ANSI 代码页，UTF-8 中文路径直接失败。
--   真机没这问题，但测试里会出现"中文目录写不进去"。此时回退到 Python。
-- 偏差三（编码层，最容易被忽略的一条）：lupa 在 encoding="utf-8" 下，
--   Python 返回的 bytes 能原样进 Lua（**读方向没问题**），但 Lua 字符串进 Python
--   会按 UTF-8 解码，任意字节直接抛 UnicodeDecodeError（**写方向有问题**）。
--   所以"写"绝不能经过 Python 传数据；改成：Lua 先写一个 ASCII 路径的中转文件，
--   再由 Python 按路径把它搬到目标位置。**跨过 lupa 边界的只有路径，没有数据。**
local real_io_open = io.open

local function has_nonascii(p)
    return tostring(p):find("[\128-\255]") ~= nil
end
M.has_nonascii = has_nonascii

--- 把 Python 文件对象包成 Lua 侧的文件表，对齐 stdio 的常用子集。
local function wrap_python_file(h)
    local f = { _py = h }
    function f:write(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        local ok, err = __PYF_WRITE(h, table.concat(parts))
        if not ok then return nil, err end
        return self
    end
    function f:read(fmt)
        if fmt == nil then fmt = "*l" end
        if type(fmt) == "number" then fmt = tostring(fmt) end
        return __PYF_READ(h, fmt)
    end
    function f:seek(whence, offset)
        return __PYF_SEEK(h, whence or "cur", offset or 0)
    end
    function f:flush()
        __PYF_FLUSH(h)
        return self
    end
    function f:close()
        return __PYF_CLOSE(h)
    end
    function f:lines(...)
        local fmts = { ... }
        if #fmts == 0 then fmts = { "*l" } end
        return function()
            local vals = {}
            for i = 1, #fmts do
                local v = __PYF_READ(h, fmts[i])
                if v == nil then return nil end
                vals[i] = v
            end
            return unpack(vals)
        end
    end
    return f
end
M.wrap_python_file = wrap_python_file

-- --- 非 ASCII 路径的"写"：ASCII 中转文件 + Python 搬家 ---

local bridge_counter = 0

--- 中转文件必须落在纯 ASCII 路径上，否则 Windows 的 fopen 照样打不开。
local function bridge_temp_path()
    bridge_counter = bridge_counter + 1
    local root = rawget(_G, "__FANQIE_TEST_DATA_DIR")
        or M.data_dir or (M.repo_root .. "/tests/.tmp/data")
    local dir = root .. "/.bridge"
    M.mkdir_p(dir)
    return dir .. "/tmp_" .. bridge_counter .. ".bin"
end

local function open_bridge_write(path, mode)
    -- 保持与真 stdio 一致的语义：父目录不存在就该失败，
    -- 而不是等到写完了才发现没地方放。
    if rawget(_G, "__PYF_PARENT") and not __PYF_PARENT(tostring(path)) then
        return nil, "父目录不存在：" .. tostring(path)
    end

    local temp = bridge_temp_path()
    local f = real_io_open(temp, (mode:gsub("b", "")) .. "b")
    if not f then
        return nil, "无法创建中转文件：" .. temp
    end

    local proxy = { _file = f, _temp = temp, _path = tostring(path) }
    function proxy:write(...)
        local ok, err = self._file:write(...)
        if not ok then return nil, err end
        return self
    end
    function proxy:read(...) return self._file:read(...) end
    function proxy:seek(...) return self._file:seek(...) end
    function proxy:lines(...) return self._file:lines(...) end
    function proxy:flush() return self._file:flush() end
    function proxy:close()
        local _, cerr = self._file:close()
        if cerr then return nil, cerr end
        -- 真正的落盘发生在这一步：close 的返回值必须被调用方检查，
        -- 否则"磁盘写满/目录消失"会表现为静默成功。
        return __PYF_MOVE(self._temp, self._path)
    end
    return proxy
end

io.open = function(path, mode)
    mode = mode or "r"
    if path == nil then
        return nil, "io.open: 路径为 nil"
    end

    -- 先走真正的 stdio。绝大多数路径（ASCII）在这里就成功，
    -- 这正是真机上的行为路径，也是基座不应该替被测代码"兜底"的部分。
    local f, err, errno = real_io_open(path, (mode:gsub("b", "")) .. "b")
    if f then return f end

    if has_nonascii(path) and rawget(_G, "__PYF_OPEN") then
        if mode:match("^[wa]") then
            local proxy, perr = open_bridge_write(path, mode)
            if proxy then return proxy end
            return nil, perr or err, errno
        end
        local h, perr = __PYF_OPEN(tostring(path), mode)
        if h then return wrap_python_file(h) end
        return nil, perr or err, errno
    end
    return nil, err, errno
end

-- logger：把日志收进内存缓冲，便于断言"确实告警了"
local log_lines = {}
M.log_lines = log_lines
package.preload["logger"] = function()
    local logger = {}
    local function push(level)
        return function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            log_lines[#log_lines + 1] = { level = level, text = table.concat(parts, " ") }
        end
    end
    logger.dbg = push("dbg")
    logger.info = push("info")
    logger.warn = push("warn")
    logger.err = push("err")
    logger.warn_exc = function(err) push("warn")(tostring(err)) end
    return logger
end
function M.reset_log()
    for i = #log_lines, 1, -1 do log_lines[i] = nil end
end

-- ---------------------------------------------------------------------------
-- 4. 网络栈替身：由测试注入传输函数
-- ---------------------------------------------------------------------------
-- 用法（spec 中）：
--   local net = require("koreader").net
--   net.set_transport(function(req) return { status = 200, headers = {}, body = "..." } end)
local transport = nil
M.net = {
    set_transport = function(fn) transport = fn end,
    get_transport = function() return transport end,
    reset = function() transport = nil end,
}

local function emit_request(req)
    if not transport then
        return nil, "测试未注入网络传输函数（require('koreader').net.set_transport）"
    end
    local resp = transport(req)
    if not resp then return nil, "传输函数返回空" end
    return resp
end
M.emit_request = emit_request

package.preload["ltn12"] = function()
    local ltn12 = { source = {}, sink = {}, filter = {}, pump = {} }
    function ltn12.pump.all(src, snk)
        local chunk, err = src()
        while chunk do
            local ok, sink_err = snk(chunk)
            if not ok then return nil, sink_err end
            chunk, err = src()
        end
        return 1
    end
    function ltn12.source.string(s)
        local done = false
        return function()
            if done then return nil end
            done = true
            return s
        end
    end
    function ltn12.source.empty()
        return function() return nil end
    end
    function ltn12.sink.table(t)
        t = t or {}
        return function(chunk)
            if chunk then t[#t + 1] = chunk end
            return 1
        end, t
    end
    function ltn12.sink.null() return function() return 1 end end
    return ltn12
end

package.preload["socket"] = function()
    local socket = {}
    socket.gettime = function() return os.time() end
    socket.sleep = function() end
    socket._VERSION = "LuaSocket 3.0 (test stub)"
    return socket
end

package.preload["socket.http"] = function()
    local http = {}
    -- KOReader 插件走的是 socket.http.request{...}
    function http.request(req)
        local resp = emit_request(req)
        if not resp then
            return nil, "transport error"
        end
        local sink = req.sink
        if sink and resp.body then sink(resp.body) end
        local headers = {}
        local response_headers = resp.headers or {}
        -- 兼容 {'Content-Type: text/html', ...} 与 {['content-type']='text/html'} 两种形态
        if #response_headers > 0 then
            for _, line in ipairs(response_headers) do
                local k, v = tostring(line):match("^([^:]+):%s*(.*)$")
                if k then
                    k = k:lower()
                    if headers[k] then headers[k] = headers[k] .. ", " .. v else headers[k] = v end
                end
            end
        else
            for k, v in pairs(response_headers) do headers[k:lower()] = v end
        end
        return resp.status or 200, headers, resp.status or 200, resp.url or req.url
    end
    return http
end

package.preload["ssl.https"] = package.preload["socket.http"]
package.preload["ssl"] = function() return { https = require("socket.http") } end

-- ---------------------------------------------------------------------------
-- 5. 宽松桩层
-- ---------------------------------------------------------------------------
local stub_log = {}
M.stub_log = stub_log
local strict = os.getenv("FANQIE_TEST_STRICT") == "1"
local verbose = os.getenv("FANQIE_STUB_LOG") == "1"

local function make_stub(name)
    local mt = {}
    mt.__index = function(t, k)
        local fn = function() return setmetatable({}, mt) end
        rawset(t, k, fn)
        return fn
    end
    mt.__call = function() return setmetatable({}, mt) end
    mt.__tostring = function() return "<koreader-stub " .. name .. ">" end
    mt.__name = name
    return setmetatable({}, mt)
end

local stub_cache = {}

table.insert(package.loaders, function(name)
    -- 只接管"看起来像 KOReader 模块"的名字，拼错的本项目模块仍应报错
    if not name:match("^[%w_]+$") and not name:match("^%w[%w_/]*$") then return nil end
    if strict then
        return "\n\t测试处于 FANQIE_TEST_STRICT=1：模块 '" .. name
            .. "' 未在测试替身中定义，refusing to stub（纯逻辑模块不应依赖它）"
    end
    stub_log[#stub_log + 1] = name
    if verbose then io.write("# [stub] " .. name .. "\n") end
    if not stub_cache[name] then stub_cache[name] = make_stub(name) end
    local value = stub_cache[name]
    return function() return value end
end)

function M.stubbed_modules()
    local copy = {}
    for i, v in ipairs(stub_log) do copy[i] = v end
    return copy
end

function M.make_stub(name) return make_stub(name) end

-- ---------------------------------------------------------------------------
-- 6. 便捷断言辅助
-- ---------------------------------------------------------------------------
function M.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, data)
    mkdir_p(path:match("^(.*)/[^/]+$") or ".")
    local f = io.open(path, "wb")
    if not f then return nil, "cannot open " .. path end
    f:write(data)
    f:close()
    return true
end

function M.exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

function M.is_dir(path)
    return lfs.attributes(path, "mode") == "directory"
end

function M.rmrf(path)
    local mode = lfs.attributes(path, "mode")
    if mode == nil then return true end
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                M.rmrf(path .. "/" .. entry)
            end
        end
        return lfs.rmdir(path)
    end
    -- 走 lfs 而不是 os.remove：嵌入模式下 lfs 由 Python 支撑，能处理 UTF-8 中文路径，
    -- 而 Windows 的 os.remove 受 ANSI 代码页限制。
    return lfs.remove(path)
end

return M

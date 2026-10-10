--- 日志不得泄漏凭据。
--
-- 这组用例的由来：审查时发现扫码登录成功会往 fanqie.log 写**完整 Cookie 头**
-- （含 sessionid），另有几处把 Set-Cookie 原文、跨进程载荷、cookie 串前缀打了出来。
-- 而日志恰恰是本仓库缺陷模板要求用户上传的文件——等于在系统性收集账号凭据。
--
-- 只靠"这次改掉了"不够，所以这里把它变成一条可执行的约束：
-- 在含日志调用的行里，禁止出现整份登录态、或对敏感变量做截断。
--
-- 已知局限（如实写明，避免给使用者虚假的安全感）：
--   * 基于行的静态扫描，**不覆盖跨多行拼接的日志调用**；
--   * 只覆盖这里列出的敏感标识符，新命名的变量需要同步加进来；
--   * 因此它是"防止已知类型回归"的护栏，不是凭据泄漏的完备证明。
--     真正的边界仍靠 code review，以及"日志里只打长度与名字"这条约定。

local T = require("tap")
local K = require("koreader")

local PLUGIN_ROOT = K.repo_root .. "/src/fanqie.koplugin"

--- 收集插件下全部 .lua 源文件（跳过 .git 等目录）
local function collect_sources()
    local files = {}
    local function walk(dir, prefix)
        for entry in K.lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." and entry ~= ".git" then
                local full = dir .. "/" .. entry
                local rel = (prefix == nil or prefix == "")
                    and entry or (prefix .. "/" .. entry)
                if K.is_dir(full) then
                    walk(full, rel)
                elseif entry:match("%.lua$") then
                    files[#files + 1] = { path = full, rel = rel }
                end
            end
        end
    end
    walk(PLUGIN_ROOT, "")
    table.sort(files, function(a, b) return a.rel < b.rel end)
    return files
end

--- 逐行扫描：命中 condition(line) 时收集一条违规
local function scan_violations(condition)
    local violations = {}
    for _, file in ipairs(collect_sources()) do
        local content = K.read_file(file.path)
        if content then
            local lineno = 0
            for line in (content .. "\n"):gmatch("([^\n]*)\n") do
                lineno = lineno + 1
                -- 只看含日志调用的行
                if line:find("Log%.%w+%(", 1) then
                    local hit = condition(line)
                    if hit then
                        violations[#violations + 1] = string.format(
                            "%s:%d  %s", file.rel, lineno, line:match("^%s*(.-)%s*$"))
                    end
                end
            end
        end
    end
    return violations
end

--============================================================================

T.test("日志护栏.扫描目标存在（否则整组用例会变成空转的绿灯）", function(t)
    -- 没有这一条，路径写错就会"零文件、零违规、全绿"——正是本仓库
    -- tests/run.lua 里那条"装载成功但没登记用例"警戒要防的同一类错误。
    local files = collect_sources()
    t:ok(#files >= 20, "应扫到至少 20 个插件源文件，实际 " .. #files)
    local names = {}
    for _, f in ipairs(files) do names[f.rel] = true end
    t:ok(names["fanqie/cookie.lua"], "应包含 fanqie/cookie.lua")
    t:ok(names["fanqie/qrlogin.lua"], "应包含 fanqie/qrlogin.lua")
    t:ok(names["fanqie/async.lua"], "应包含 fanqie/async.lua")
    t:ok(names["main.lua"], "应包含 main.lua")
end)

T.test("日志护栏.不得把完整 Cookie 头写进日志", function(t)
    local bad = scan_violations(function(line)
        if line:find("Cookie%.to_header", 1) then
            return "在日志里打印整份 Cookie 头"
        end
        return nil
    end)
    t:eq(#bad, 0, "以下日志行会把登录态写进文件：\n      "
        .. table.concat(bad, "\n      "))
end)

T.test("日志护栏.不得对凭据变量做截断后打印", function(t)
    -- 截断的仍然是凭据本体（前缀足以暴露账号，且 Set-Cookie 里就含 sessionid）
    local sensitive = {
        jar_str = true, raw_set_cookie = true, payload = true,
        ret_str = true, new_jar = true,
    }
    local bad = scan_violations(function(line)
        for name in pairs(sensitive) do
            -- 形如 name):sub( 或 name:sub(
            if line:find(name .. "%)%:sub%(", 1) or line:find(name .. "%:sub%(", 1) then
                return "在日志里截断打印 " .. name
            end
        end
        return nil
    end)
    t:eq(#bad, 0, "以下日志行会打印凭据片段：\n      "
        .. table.concat(bad, "\n      "))
end)

T.test("日志护栏.打长度与名字是允许的（避免把修复写成新的隐患）", function(t)
    -- 修复方式刻意选的是"只打长度/键名"，所以当前源码里应当能找到这种写法。
    -- 这一条同时防止有人为了过护栏而把有用的诊断信息一并删光。
    local by_file = {}
    for _, file in ipairs(collect_sources()) do
        by_file[file.rel] = K.read_file(file.path) or ""
    end
    t:matches(by_file["fanqie/qrlogin.lua"] or "",
        "Set%-Cookie 字节数", "qrlogin.lua 应报告 Set-Cookie 长度而不是内容")
    t:contains(by_file["fanqie/async.lua"] or "", "payload len=",
        "async.lua 应报告载荷长度")
end)

T.test("日志护栏.Cookie.to_header 仍用于构造请求（护栏不是靠改名通过的）", function(t)
    -- 反空洞检查：如果哪天 Cookie.to_header 被改名或删除，上一条"日志里没有它"
    -- 就会变成毫无意义的真命题。这里确认它仍然存在，并且用在请求头构造上。
    local client = K.read_file(PLUGIN_ROOT .. "/fanqie/client.lua") or ""
    local qrlogin = K.read_file(PLUGIN_ROOT .. "/fanqie/qrlogin.lua") or ""
    t:contains(client, "Cookie.to_header", "client.lua 应仍在用它构造 Cookie 请求头")
    t:contains(qrlogin, "Cookie.to_header", "qrlogin.lua 应仍在使用它")
    -- 它应当出现在 headers["Cookie"] 这类赋值里，而不是日志里
    t:matches(qrlogin, 'headers%["Cookie"%]%s*=%s*Cookie%.to_header',
        "qrlogin.lua 里它应被赋给请求头，而不是送进日志")
end)

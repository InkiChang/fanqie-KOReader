--- 极简 TAP 风格测试框架
--
-- 设计目标：
--   * 零外部依赖（不依赖 busted / luarocks），Lua 5.1 与 LuaJIT 通用
--   * 因此在 Windows 本机（lupa/LuaJIT）、WSL/Linux（lua5.1）与 CI 上行为一致
--   * 输出 TAP 13，便于任何 CI 消费
--
-- 用法：
--   local T = require("tap")
--   T.test("模块.行为", function(t)
--       t:eq(actual, expected, "说明")
--       t:ok(cond, "说明")
--       t:contains(haystack, "needle", "说明")
--   end)
--   os.exit(T.report("套件名"))

local T = {
    passed = 0,
    failed = 0,
    errored = 0,
    skipped = 0,
    _failures = {},
    _skips = {},
    _suite = "fanqie",
}

local function is_array(v)
    if type(v) ~= "table" then return false end
    local n = 0
    for k in pairs(v) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #v
end

local function dump(v, indent, seen)
    indent = indent or ""
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    if is_array(v) then
        local parts = {}
        for _, item in ipairs(v) do
            parts[#parts + 1] = dump(item, indent, seen)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local key_repr = tostring(k):match("^%d+$") and ("[" .. k .. "]") or k
        parts[#parts + 1] = key_repr .. " = " .. dump(v[k], indent .. "  ", seen)
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

T.dump = dump

local Assert = {}
Assert.__index = Assert

local function record_failure(t, message)
    t._failed = t._failed + 1
    T._failures[#T._failures + 1] = {
        case = t._case,
        message = message,
    }
end

function Assert:ok(cond, message)
    message = message or "期望为真"
    if cond then
        return true
    end
    record_failure(self, message .. "（实际值：" .. dump(cond) .. "）")
    return false
end

--- 断言"拿到了东西"，并把那个值返回。
--
-- 给"先构造、再检查"的用例用：
--   local bytes = t:assert_ok(Epub.build(opts))
-- 这么写既断言了非空，又省掉一层判空分支；失败时错误信息里带得上说明。
-- 注意 false 也算失败——被测函数很可能是 `return false, err` 这种约定。
function Assert:assert_ok(value, message)
    message = message or "期望拿到非 nil/false 的值"
    if value ~= nil and value ~= false then
        return value
    end
    record_failure(self, message .. "（实际值：" .. dump(value) .. "）")
    return nil
end

function Assert:eq(actual, expected, message)
    message = message or "值不相等"
    if actual == expected then
        return true
    end
    record_failure(self, message
        .. "\n      期望：" .. dump(expected)
        .. "\n      实际：" .. dump(actual))
    return false
end

function Assert:neq(actual, unexpected, message)
    message = message or "值不应相等"
    if actual ~= unexpected then
        return true
    end
    record_failure(self, message .. "（两者均为：" .. dump(actual) .. "）")
    return false
end

function Assert:contains(haystack, needle, message)
    message = message or "未找到子串"
    haystack = tostring(haystack or "")
    needle = tostring(needle or "")
    if haystack:find(needle, 1, true) then
        return true
    end
    record_failure(self, message
        .. "\n      查找：" .. string.format("%q", needle)
        .. "\n      实际：" .. string.format("%q", haystack))
    return false
end

function Assert:not_contains(haystack, needle, message)
    message = message or "不应包含子串"
    haystack = tostring(haystack or "")
    needle = tostring(needle or "")
    if not haystack:find(needle, 1, true) then
        return true
    end
    record_failure(self, message
        .. "\n      不应出现：" .. string.format("%q", needle))
    return false
end

function Assert:matches(text, pattern, message)
    message = message or "未匹配模式"
    if tostring(text or ""):match(pattern) then
        return true
    end
    record_failure(self, message
        .. "\n      模式：" .. string.format("%q", pattern)
        .. "\n      实际：" .. string.format("%q", tostring(text)))
    return false
end

function Assert:fail(message)
    record_failure(self, message or "显式失败")
    return false
end

function Assert:throws(fn, message)
    message = message or "期望抛出错误"
    local ok = pcall(fn)
    if not ok then
        return true
    end
    record_failure(self, message)
    return false
end

--- 跳过当前用例（TAP 13 的 SKIP 指令）。
--
-- 用途是"前提不成立"而不是"懒得写"：例如基座自检里那条验证**宽松桩**的用例，
-- 在 --strict 模式下宽松桩被刻意关掉，它的前提根本不存在，报失败就是误报。
-- 它借用 error() 来实现，所以调用之后的代码不会再跑——不需要作者记得 return。
function Assert:skip(reason)
    error({ __skip = true, reason = tostring(reason or "前提不成立") }, 0)
end

--- 声明并执行一个测试用例。fn 抛出的异常计为 errored（而非 failed），
--- 以便区分"断言失败"与"代码崩了"。
function T.test(name, fn)
    local t = setmetatable({ _failed = 0, _case = name }, Assert)
    local ok, err = pcall(fn, t)
    if not ok then
        -- 跳过是"前提不成立"，不是失败，也不是错误：单列一类。
        if type(err) == "table" and err.__skip then
            T.skipped = T.skipped + 1
            T._skips[#T._skips + 1] = { case = name, reason = err.reason }
            io.write(string.format("ok - %s # SKIP %s\n", name, err.reason))
            return true
        end
        T.errored = T.errored + 1
        T._failures[#T._failures + 1] = {
            case = name,
            message = "用例抛出异常：" .. tostring(err),
        }
        io.write(string.format("not ok - %s # ERROR\n", name))
        return false
    end
    if t._failed == 0 then
        T.passed = T.passed + 1
        io.write(string.format("ok - %s\n", name))
        return true
    end
    T.failed = T.failed + 1
    io.write(string.format("not ok - %s # %d 处断言失败\n", name, t._failed))
    return false
end

--- 一条用例是否已经跑过（无论结果）。用于 run.lua 判断"装载后到底有没有登记用例"。
function T.total()
    return T.passed + T.failed + T.errored + T.skipped
end

--- 输出 TAP 汇总。返回适合 os.exit 的退出码（0 = 全绿）。
function T.report(suite)
    suite = suite or T._suite
    -- 计划行必须等于实际打印的用例行数：跳过也是打印了的用例，必须计入
    io.write("1.." .. tostring(T.total()) .. "\n")
    for _, f in ipairs(T._failures) do
        io.write("# FAIL: " .. f.case .. "\n")
        io.write("#   " .. tostring(f.message):gsub("\n", "\n#   ") .. "\n")
    end
    for _, s in ipairs(T._skips) do
        io.write("# SKIP: " .. s.case .. " —— " .. s.reason .. "\n")
    end
    io.write(string.format(
        "# suite=%s passed=%d failed=%d errored=%d skipped=%d\n",
        suite, T.passed, T.failed, T.errored, T.skipped))
    if T.failed + T.errored > 0 then
        return 1
    end
    return 0
end

return T

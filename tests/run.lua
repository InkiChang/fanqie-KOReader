--- 测试入口（原生 Lua 版）
--
-- 用法（仓库根目录下执行）：
--   lua tests/run.lua                       -- 自动装载 tests/spec 下全部用例
--   lua tests/run.lua cookie_spec           -- 只跑指定模块
--
-- 适用环境：Linux / macOS / WSL / 任何装了 lua5.1 或 luajit 的机器；CI 走这条路。
-- Windows 本机没有原生 Lua 时走 tests/run_tests.py（lupa + LuaJIT 2.1）。
--
-- 嵌入式模式：tests/run_tests.py 会把本文件读进 Python 里的 Lua 运行时执行。
--   那时 `arg` 不存在，且本文件不做 os.exit，而是 `return` 退出码。
--   驱动方通过全局变量交接：
--     __FANQIE_REPO_ROOT       仓库根（koreader.lua 也读它）
--     __FANQIE_TEST_DATA_DIR   临时数据目录
--     __FANQIE_SPECS           可选的用例名数组
--     __FANQIE_EMBEDDED        true 时用 return 代替 os.exit

local embedded = rawget(_G, "__FANQIE_EMBEDDED") and true or false

local function derive_repo_root()
    if rawget(_G, "__FANQIE_REPO_ROOT") then
        return _G.__FANQIE_REPO_ROOT
    end
    if arg and arg[0] then
        local root = tostring(arg[0]):match("^(.*)[/\\]tests[/\\]run%.lua$")
        if root and root ~= "" then return root end
    end
    return "."
end

local repo_root = derive_repo_root()
_G.__FANQIE_REPO_ROOT = repo_root
if not _G.__FANQIE_TEST_DATA_DIR then
    _G.__FANQIE_TEST_DATA_DIR = os.getenv("FANQIE_TEST_DATA_DIR")
        or (repo_root .. "/tests/.tmp/data")
end

-- 先用最小信息引导模块搜索路径：koreader.lua 自己也会扩 path，
-- 但"找到 koreader.lua"这件事必须先于 require 它发生。
package.path = table.concat({
    repo_root .. "/tests/support/?.lua",
    repo_root .. "/tests/?.lua",
    repo_root .. "/?.lua",
    package.path,
}, ";")

local K = require("koreader")
local T = require("tap")

io.write("# fanqie-KOReader test harness\n")
io.write("# runtime     = " .. tostring(_VERSION)
    .. (rawget(_G, "jit") and (" / " .. tostring(jit.version)) or "") .. "\n")
io.write("# repo_root   = " .. K.repo_root .. "\n")
io.write("# data_dir    = " .. K.data_dir .. "\n")
io.write("# filesystem  = " .. tostring(K.lfs_source) .. "\n")

-- 把用户写的用例名归一化成可以 require 的模块名。
-- 允许写成 cookie、cookie_spec、tests/spec/cookie_spec.lua 三种形式——
-- 手敲命令时不该还要记住后缀，记错了要能报出来而不是悄悄跑 0 条。
local function normalize_spec(name)
    local base = tostring(name):gsub("\\", "/")
    base = base:match("([^/]+)$") or base
    base = base:gsub("%.lua$", "")
    if base:match("_spec$") then return base end
    local candidate = K.repo_root .. "/tests/spec/" .. base .. "_spec.lua"
    if K.lfs.attributes(candidate) then
        return base .. "_spec"
    end
    return base
end

-- 用例清单：优先用调用方给的，其次用命令行参数，最后靠 lfs 自动发现
local specs = _G.__FANQIE_SPECS
if type(specs) ~= "table" or #specs == 0 then
    specs = {}
    if arg then
        for i = 1, #arg do
            local name = tostring(arg[i])
            if not name:match("^%-%-") then
                specs[#specs + 1] = name
            end
        end
    end
    if #specs == 0 then
        -- 自动发现，避免维护一份会漂移的清单
        local dir = K.repo_root .. "/tests/spec"
        if K.lfs.attributes(dir, "mode") == "directory" then
            for entry in K.lfs.dir(dir) do
                local base = entry:match("^(.-)%.lua$")
                if base and base:match("_spec$") then specs[#specs + 1] = base end
            end
            table.sort(specs)
        end
    end
end

for i = 1, #specs do
    specs[i] = normalize_spec(specs[i])
end

if #specs == 0 then
    io.write("# 没有找到任何测试用例（tests/spec/*_spec.lua）\n")
    io.write("1..0\n# suite=none passed=0 failed=0 errored=0 skipped=0\n")
    if embedded then return 0 end
    os.exit(0)
end

io.write("# specs       = " .. table.concat(specs, " ") .. "\n")

-- 每个用例前清空数据目录与日志，保证用例之间互不残留状态
for _, name in ipairs(specs) do
    K.rmrf(K.data_dir)
    K.mkdir_p(K.data_dir)
    K.reset_log()
    K.net.reset()

    io.write("# ---- " .. name .. " ----\n")
    local before = T.total()
    local ok, err = pcall(require, name)
    if not ok then
        io.write("not ok - " .. name .. " # 用例文件装载失败\n")
        io.write("#   " .. tostring(err):gsub("\n", "\n#   ") .. "\n")
        T.errored = T.errored + 1
        T._failures[#T._failures + 1] = {
            case = name,
            message = "用例文件装载失败：" .. tostring(err),
        }
    elseif T.total() == before then
        -- 装载成功却一条用例都没登记：这是最危险的失败模式。
        -- 最常见的成因是名字写错，被基座的宽松桩当成"某个 KOReader 模块"
        -- 接管了——于是 require 成功、套件却什么都没跑，整体还是绿的。
        -- 这里必须把它变成硬错误，否则测试会骗人。
        io.write("not ok - " .. name
            .. " # 装载成功但一条用例都没登记\n")
        io.write("#   常见原因：用例名写错，被宽松桩当成 KOReader 模块接管了。\n")
        io.write("#   请确认 tests/spec/" .. name .. ".lua 存在。\n")
        T.errored = T.errored + 1
        T._failures[#T._failures + 1] = {
            case = name,
            message = "装载成功但一条用例都没登记（检查用例名是否存在）",
        }
    end
end

local code = T.report("fanqie-koplugin")
if embedded then
    return code
end
os.exit(code)

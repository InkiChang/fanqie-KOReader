--- 用 Python 注入的 OS 原语实现 LuaFileSystem 兼容层
--
-- 为什么需要它：
--   KOReader 的 `libs/libkoreader-lfs` 就是 LuaFileSystem，而纯 Lua 无法创建目录。
--   在 Windows 本机没有原生 Lua 解释器时，我们通过 lupa 让 Python 提供这几个原语，
--   于是在 Windows 上也能真实地跑「写缓存文件 / 列目录 / 递归删除」这类用例。
--
-- 在 CI / WSL（装了 lua-filesystem）上不会走到这里——那时直接用真的 lfs 模块。

local P = rawget(_G, "__PYFS")
if not P then
    return nil, "未注入 __PYFS：本机既没有原生 lua-filesystem，也没有 Python 桥接"
end

local lfs = {}

local function wrap_err(ok, err)
    if ok then return true end
    return nil, err
end

function lfs.attributes(path, field)
    local mode, size, mtime = P.attributes(tostring(path))
    if mode == nil then
        return nil, "cannot obtain information from file `" .. tostring(path) .. "'"
    end
    if field == "mode" then return mode end
    if field == "size" then return size end
    if field == "modification" then return mtime end
    if field ~= nil then
        local t = { mode = mode, size = size, modification = mtime }
        return t[field]
    end
    return { mode = mode, size = size, modification = mtime }
end

function lfs.dir(path)
    local names = P.listdir(tostring(path))
    if names == nil then
        error("cannot open " .. tostring(path) .. " (No such file or directory)")
    end
    -- 真 LuaFileSystem 的 lfs.dir 会先给出 "." 与 ".."；这里必须一并补上，
    -- 否则"遍历目录"的代码在测试里的输入集与真机不同。现有调用点都同时过滤
    -- 这两个名字，所以过去没暴露问题，但少一个就等于基座与真机存在语义差。
    table.insert(names, 1, ".")
    names[#names + 1] = ".."
    local i = 0
    return function()
        i = i + 1
        return names[i]
    end
end

function lfs.mkdir(path)
    return wrap_err(P.mkdir(tostring(path)))
end

function lfs.rmdir(path)
    return wrap_err(P.rmdir(tostring(path)))
end

function lfs.remove(path)
    return wrap_err(P.remove(tostring(path)))
end

function lfs.currentdir()
    return P.getcwd()
end

function lfs.chdir(path)
    return wrap_err(P.chdir(tostring(path)))
end

function lfs.touch(path)
    return wrap_err(P.touch(tostring(path)))
end

return lfs

#!/usr/bin/env python3
"""跨平台测试驱动：在 **没有原生 Lua 解释器** 的机器上跑同一套 Lua 用例。

背景
----
KOReader 插件是 Lua 代码，常规做法是装 lua5.1 / luajit 后 `lua tests/run.lua`。
但 Windows 本机往往既没有 Lua 也没有 WSL，于是这里用 lupa 把 Lua 运行时嵌进
Python 进程——而且刻意选 **LuaJIT 2.1** 这个子模块，因为 KOReader 自己就是
LuaJIT 2.1（Lua 5.1 语义 + bit 库 + goto），比 PUC Lua 5.5 忠实得多。

真正的测试逻辑一行都不在 Python 里：Python 只负责
  1. 提供 LuaFileSystem 的 OS 原语（纯 Lua 无法 mkdir）
  2. 替掉 io.write 以便收集 TAP 输出
  3. 把 tests/spec/*_spec.lua 交给 tests/run.lua 执行

用法
----
    python tests/run_tests.py                     # 自动发现全部用例
    python tests/run_tests.py cookie_spec         # 只跑指定用例
    python tests/run_tests.py --strict            # 未定义的 KOReader 模块直接报错
    python tests/run_tests.py --stub-log          # 打印所有被桩化的模块名
    python tests/run_tests.py --native            # 改用 PATH 上的 lua/luajit
    python tests/run_tests.py --native --lua lua5.1
    python tests/run_tests.py --list              # 只列用例

退出码：0 全绿；1 有用例失败；2 测试基座自身出错（例如 lupa 缺失）。
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import traceback

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
RUN_LUA = REPO_ROOT / "tests" / "run.lua"
SPEC_DIR = REPO_ROOT / "tests" / "spec"
DEFAULT_DATA_DIR = REPO_ROOT / "tests" / ".tmp" / "data"

# lupa 的查找位置：环境变量优先，其次是仓库内 / 仓库同级缓存目录
PYLIBS_CANDIDATES = [
    REPO_ROOT / ".pylibs",
    REPO_ROOT.parent / ".cache" / "pylibs",
]


# ---------------------------------------------------------------------------
# 用例发现
# ---------------------------------------------------------------------------
def discover_specs() -> list[str]:
    if not SPEC_DIR.is_dir():
        return []
    return sorted(p.stem for p in SPEC_DIR.glob("*_spec.lua"))


# ---------------------------------------------------------------------------
# lupa 定位
# ---------------------------------------------------------------------------
def load_lupa_runtime():
    """返回 lupa.luajit21.LuaRuntime，找不到则返回 (None, 原因)。"""
    candidates = []
    env_pylibs = os.environ.get("FANQIE_PYLIBS")
    if env_pylibs:
        candidates.append(pathlib.Path(env_pylibs))
    candidates.extend(PYLIBS_CANDIDATES)

    for extra in candidates:
        if extra.is_dir() and str(extra) not in sys.path:
            sys.path.insert(0, str(extra))

    try:
        from lupa.luajit21 import LuaRuntime  # type: ignore
    except ImportError as exc:
        return None, str(exc)
    return LuaRuntime, None


# ---------------------------------------------------------------------------
# 把 Python 的 OS 原语注入 Lua，充当 LuaFileSystem
# ---------------------------------------------------------------------------
PYFS_PRELUDE = r"""
-- 由 tests/run_tests.py 注入的 Python 原语包装层
function __PYFS_MAKE_LIST(...)
    return { ... }
end

__PYFS = {
    attributes = function(path) return __PYFS_ATTR(path) end,
    listdir    = function(path) return __PYFS_LIST(path) end,
    mkdir      = function(path) return __PYFS_MKDIR(path) end,
    rmdir      = function(path) return __PYFS_RMDIR(path) end,
    remove     = function(path) return __PYFS_REMOVE(path) end,
    getcwd     = function()     return __PYFS_GETCWD() end,
    chdir      = function(path) return __PYFS_CHDIR(path) end,
    touch      = function(path) return __PYFS_TOUCH(path) end,
}

-- TAP 输出改为交给 Python 收集，避免 C stdio 在嵌入式运行时里跑丢
io.write = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring((select(i, ...)))
    end
    __PYIO_WRITE(table.concat(parts))
end

print = function(...)
    io.write(...)
    io.write(string.char(10))
end
"""


def install_pyfs(lua) -> None:
    """把 tests/support/lfs_python.lua 需要的 __PYFS 挂到 Lua 全局上。"""
    g = lua.globals()

    def attributes(path):
        try:
            st = os.lstat(path)
        except OSError:
            return None
        if stat.S_ISDIR(st.st_mode):
            mode = "directory"
        elif stat.S_ISLNK(st.st_mode):
            mode = "link"
        else:
            mode = "file"
        # lupa 的 unpack_returned_tuples=True 会把三元组摊成 3 个 Lua 返回值
        return (mode, st.st_size, st.st_mtime)

    def listdir(path):
        try:
            names = os.listdir(path)
        except OSError:
            return None
        return g.__PYFS_MAKE_LIST(*names)

    def _flag(fn, path):
        try:
            fn(path)
        except OSError:
            return False
        return True

    def mkdir(path):
        if os.path.isdir(path):
            return False
        return _flag(os.mkdir, path)

    def rmdir(path):
        return _flag(os.rmdir, path)

    def remove(path):
        return _flag(os.remove, path)

    def getcwd():
        return os.getcwd()

    def chdir(path):
        return _flag(os.chdir, path)

    def touch(path):
        try:
            pathlib.Path(path).touch()
        except OSError:
            return False
        return True

    g.__PYFS_ATTR = attributes
    g.__PYFS_LIST = listdir
    g.__PYFS_MKDIR = mkdir
    g.__PYFS_RMDIR = rmdir
    g.__PYFS_REMOVE = remove
    g.__PYFS_GETCWD = getcwd
    g.__PYFS_CHDIR = chdir
    g.__PYFS_TOUCH = touch

    lua.execute(PYFS_PRELUDE)


# ---------------------------------------------------------------------------
# 给 io.open 兜底：UTF-8 路径的 Python 文件对象
# ---------------------------------------------------------------------------
def install_pyfile(lua) -> None:
    """Windows 的 fopen 走 ANSI 代码页，中文路径直接失败。

    真机（Linux/Android）没有这个问题，但测试里会出现"中文目录写不进去"。
    tests/support/koreader.lua 的 io.open 覆写只在这些路径上回退到这里。

    边界纪律：**跨 lupa 边界的数据一律当字节流**。读方向 Python 返回 bytes，
    Lua 原样收下（Lua 字符串本来就是字节串）；写方向不能走这里——lupa 在
    encoding="utf-8" 下会把 Lua 字符串按 UTF-8 解码，任意字节直接抛
    UnicodeDecodeError，所以非 ASCII 路径的"写"由 koreader.lua 写成 ASCII
    中转文件，再用 __PYF_MOVE 按路径搬过去。这里只搬运路径，不搬运数据。
    """
    import re as _re

    # 二进制模式下读的是 bytes，正则也要用 bytes 模式
    number_re = _re.compile(rb"[ \t\r\n]*[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")

    def pyf_open(path, mode):
        # 一律二进制：既不翻译换行（Linux 语义），也不做编码转换。
        py_mode = mode if "b" in mode else mode + "b"
        try:
            return (open(path, py_mode), None)
        except OSError as exc:
            return (None, str(exc))

    def pyf_write(handle, text):
        # 正常情况不会被调用（写走中转文件）。保留是为了在有人误用时给出
        # 明确报错，而不是一个看不懂的类型错误。
        try:
            handle.write(text.encode("utf-8"))
        except (OSError, ValueError, TypeError) as exc:
            return (False, str(exc))
        return True

    def read_number(handle):
        start = handle.tell()
        match = number_re.match(handle.read())
        if not match:
            handle.seek(start)
            return None
        handle.seek(start)
        handle.read(match.end())
        raw = match.group().strip().decode("ascii")
        try:
            return int(raw)
        except ValueError:
            return float(raw)

    def pyf_read(handle, fmt):
        try:
            if fmt in ("*a", "a"):
                return handle.read()
            if fmt in ("*l", "l", "*L", "L"):
                line = handle.readline()
                if line == b"":
                    return None
                if line.endswith(b"\r\n"):
                    return line[:-2]
                if line[-1:] in (b"\r", b"\n"):
                    return line[:-1]
                return line
            if fmt in ("*n", "n"):
                return read_number(handle)
            if fmt.isdigit():
                data = handle.read(int(fmt))
                return data if data != b"" else None
        except (OSError, ValueError) as exc:
            return None, str(exc)
        return None, f"invalid format '{fmt}'"

    def pyf_seek(handle, whence, offset):
        idx = {"set": 0, "cur": 1, "end": 2}.get(whence)
        if idx is None:
            return None, "invalid option"
        try:
            # 二进制模式下 tell() 就是真实字节偏移，seek 可以自由算术
            return handle.seek(int(offset), idx)
        except (OSError, ValueError) as exc:
            return None, str(exc)

    def pyf_flush(handle):
        try:
            handle.flush()
        except (OSError, ValueError) as exc:
            return False, str(exc)
        return True

    def pyf_close(handle):
        try:
            handle.close()
        except (OSError, ValueError) as exc:
            return False, str(exc)
        return True

    def pyf_parent(path):
        """目标路径的父目录是否存在——对齐 stdio"父目录缺失则 open 失败"的语义。"""
        return os.path.isdir(os.path.dirname(os.path.abspath(path)))

    def pyf_move(src, dst):
        """把 ASCII 中转文件搬到目标（可能含非 ASCII 的）路径。

        这是非 ASCII 路径"写"真正落盘的一步，所以它的失败必须向上报，
        否则磁盘满/目录消失会表现为静默成功。
        """
        try:
            shutil.move(src, dst)
        except (OSError, ValueError, shutil.Error) as exc:
            return (False, str(exc))
        return True

    g = lua.globals()
    g.__PYF_OPEN = pyf_open
    g.__PYF_WRITE = pyf_write
    g.__PYF_READ = pyf_read
    g.__PYF_SEEK = pyf_seek
    g.__PYF_FLUSH = pyf_flush
    g.__PYF_CLOSE = pyf_close
    g.__PYF_PARENT = pyf_parent
    g.__PYF_MOVE = pyf_move


# ---------------------------------------------------------------------------
# 嵌入式执行
# ---------------------------------------------------------------------------
def run_embedded(specs: list[str], data_dir: pathlib.Path, strict: bool, stub_log: bool) -> int:
    LuaRuntime, reason = load_lupa_runtime()
    if LuaRuntime is None:
        print("找不到 lupa，无法在嵌入式模式下运行。", file=sys.stderr)
        print(f"  原因：{reason}", file=sys.stderr)
        print("  解决：python scripts/bootstrap_pylibs.py  （或 pip install lupa）", file=sys.stderr)
        print("  或者：python tests/run_tests.py --native --lua <解释器路径>", file=sys.stderr)
        return 2

    os.environ["FANQIE_REPO_ROOT"] = str(REPO_ROOT)
    os.environ["FANQIE_TEST_DATA_DIR"] = str(data_dir)
    if strict:
        os.environ["FANQIE_TEST_STRICT"] = "1"
    else:
        os.environ.pop("FANQIE_TEST_STRICT", None)
    if stub_log:
        os.environ["FANQIE_STUB_LOG"] = "1"
    else:
        os.environ.pop("FANQIE_STUB_LOG", None)

    lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")

    captured: list[str] = []
    lua.globals().__PYIO_WRITE = captured.append

    install_pyfs(lua)
    install_pyfile(lua)

    g = lua.globals()
    g.__FANQIE_REPO_ROOT = str(REPO_ROOT)
    g.__FANQIE_TEST_DATA_DIR = str(data_dir)
    g.__FANQIE_EMBEDDED = True
    if specs:
        g.__FANQIE_SPECS = g.__PYFS_MAKE_LIST(*specs)

    print(f"# driver      = lupa/luajit21 (embedded) [{sys.version.split()[0]}]")
    try:
        code = lua.execute(RUN_LUA.read_text(encoding="utf-8"))
    except BaseException:  # noqa: BLE001 - 任何 Lua 异常都要把已产出的 TAP 打出来
        sys.stdout.write("".join(captured))
        print("\n# --- 测试基座异常 ---", file=sys.stderr)
        traceback.print_exc()
        return 2

    sys.stdout.write("".join(captured))
    return int(code) if isinstance(code, int) else 1


# ---------------------------------------------------------------------------
# 原生执行
# ---------------------------------------------------------------------------
def find_native_lua(explicit: str | None) -> str | None:
    if explicit:
        return shutil.which(explicit) or (explicit if pathlib.Path(explicit).is_file() else None)
    for name in ("luajit", "lua", "lua5.1", "lua51"):
        found = shutil.which(name)
        if found:
            return found
    return None


def run_native(specs: list[str], data_dir: pathlib.Path, interpreter: str | None, strict: bool, stub_log: bool) -> int:
    exe = find_native_lua(interpreter)
    if not exe:
        print("找不到原生 Lua 解释器（试过 luajit / lua / lua5.1）。", file=sys.stderr)
        print("  解决：去掉 --native 用 lupa 模式，或安装 luajit / lua5.1", file=sys.stderr)
        return 2

    env = dict(os.environ)
    env["FANQIE_REPO_ROOT"] = str(REPO_ROOT)
    env["FANQIE_TEST_DATA_DIR"] = str(data_dir)
    if strict:
        env["FANQIE_TEST_STRICT"] = "1"
    if stub_log:
        env["FANQIE_STUB_LOG"] = "1"

    print(f"# driver      = native {exe}")
    proc = subprocess.run([exe, str(RUN_LUA), *specs], cwd=str(REPO_ROOT), env=env)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="run_tests.py",
        description="fanqie-KOReader 测试驱动（lupa 嵌入模式 / 原生 Lua 模式）",
    )
    parser.add_argument("specs", nargs="*", help="要跑的用例名，cookie / cookie_spec / tests/spec/cookie_spec.lua 均可；省略则跑全部")
    parser.add_argument("--native", action="store_true", help="用 PATH 上的原生 lua/luajit 执行")
    parser.add_argument("--lua", default=None, help="指定原生解释器（配合 --native）")
    parser.add_argument("--data-dir", default=None, help="测试数据目录（默认 tests/.tmp/data）")
    parser.add_argument("--strict", action="store_true", help="未在替身里定义的 KOReader 模块直接报错")
    parser.add_argument("--stub-log", action="store_true", help="打印被桩化的模块名")
    parser.add_argument("--list", action="store_true", help="只列出发现的用例")
    args = parser.parse_args()

    specs = args.specs or discover_specs()
    if args.list:
        for name in specs:
            print(name)
        return 0
    if not specs:
        print("没有发现任何用例（tests/spec/*_spec.lua）。", file=sys.stderr)
        return 0

    data_dir = pathlib.Path(args.data_dir) if args.data_dir else DEFAULT_DATA_DIR
    data_dir.mkdir(parents=True, exist_ok=True)

    if args.native or args.lua:
        return run_native(specs, data_dir, args.lua, args.strict, args.stub_log)
    return run_embedded(specs, data_dir, args.strict, args.stub_log)


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001 - 老版本 Python 没有 reconfigure
        pass
    sys.exit(main())

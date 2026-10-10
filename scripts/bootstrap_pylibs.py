#!/usr/bin/env python3
"""把 lupa 装进本地缓存目录，供 tests/run_tests.py 的嵌入式模式使用。

为什么不用 `pip install lupa`
-----------------------------
本机沙箱会在 pip 写 `*.whl.metadata` 时返回 `[Errno 13] Permission denied`，
而 PEP 427 的 wheel 本来就是一个 zip——直接下载、解包、放到 sys.path 上，
效果与 pip 安装完全一致，且不需要写 site-packages，也不需要管理员权限。

装到哪儿
--------
默认 `C:\\Users\\<你>\\Documents\\.cache\\pylibs`（仓库的上级目录里），
仓库本身保持干净。也可用 `--target` 指定别处，再用环境变量 `FANQIE_PYLIBS`
告诉 tests/run_tests.py。

用法
----
    python scripts/bootstrap_pylibs.py
    python scripts/bootstrap_pylibs.py --target D:\\pylibs
    python scripts/bootstrap_pylibs.py --check      # 只检查，不下载
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.request
import zipfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_TARGET = REPO_ROOT.parent / ".cache" / "pylibs"
DEFAULT_WHEEL_CACHE = REPO_ROOT.parent / ".cache" / "wheels"

PACKAGE = "lupa"
PY_TAG = f"cp{sys.version_info.major}{sys.version_info.minor}"
PLATFORM_TAG = "win_amd64" if sys.platform == "win32" else None


def already_importable(target: pathlib.Path) -> str | None:
    if str(target) not in sys.path:
        sys.path.insert(0, str(target))
    try:
        import lupa  # type: ignore
    except ImportError:
        return None
    flavours = sorted(
        n.stem.split(".")[0] for n in (target / "lupa").glob("lua*.pyd")
    ) + sorted(n.stem for n in (target / "lupa").glob("lua*.so"))
    return f"{lupa.__version__}（可用运行时：{', '.join(sorted(set(flavours))) or '未知'}）"


def pick_wheel(release_files: list[dict]) -> dict | None:
    for f in release_files:
        name = f["filename"]
        if not name.endswith(".whl"):
            continue
        if PY_TAG not in name:
            continue
        if PLATFORM_TAG and PLATFORM_TAG not in name:
            continue
        if not PLATFORM_TAG and "win" in name:
            continue
        return f
    return None


def main() -> int:
    parser = argparse.ArgumentParser(prog="bootstrap_pylibs.py", description=__doc__.split("\n")[0])
    parser.add_argument("--target", default=str(DEFAULT_TARGET), help="解包目标目录")
    parser.add_argument("--wheel-cache", default=str(DEFAULT_WHEEL_CACHE), help="wheel 下载缓存目录")
    parser.add_argument("--check", action="store_true", help="只检查是否已可用")
    args = parser.parse_args()

    target = pathlib.Path(args.target)
    wheel_cache = pathlib.Path(args.wheel_cache)

    ready = already_importable(target)
    if ready:
        print(f"OK：{PACKAGE} 已就绪 -> {target}（版本 {ready}）")
        return 0
    if args.check:
        print(f"未就绪：{target} 里没有可用的 {PACKAGE}", file=sys.stderr)
        return 1

    target.mkdir(parents=True, exist_ok=True)
    wheel_cache.mkdir(parents=True, exist_ok=True)

    print(f"# 查询 PyPI：{PACKAGE}")
    with urllib.request.urlopen(f"https://pypi.org/pypi/{PACKAGE}/json", timeout=60) as resp:
        data = json.load(resp)

    version = data["info"]["version"]
    files = data["releases"][version]
    wheel = pick_wheel(files)
    if wheel is None:
        print(f"没有匹配 {PY_TAG}/{PLATFORM_TAG} 的 wheel。该版本可用文件：", file=sys.stderr)
        for f in files:
            print("   ", f["filename"], file=sys.stderr)
        return 2

    dest = wheel_cache / wheel["filename"]
    if dest.exists():
        print(f"# 复用已缓存 wheel：{dest.name}")
    else:
        print(f"# 下载 {wheel['filename']}（{wheel['size'] / 1024:.0f} KiB）")
        urllib.request.urlretrieve(wheel["url"], dest)

    print(f"# 解包到 {target}")
    with zipfile.ZipFile(dest) as zf:
        zf.extractall(target)

    ready = already_importable(target)
    if not ready:
        print("解包完成但仍无法导入，请检查 Python 版本与 wheel 标签是否匹配。", file=sys.stderr)
        return 3
    print(f"OK：{PACKAGE} {ready} -> {target}")
    print(f"# 提示：如目标目录在别处，运行测试前设 FANQIE_PYLIBS={target}")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())

#!/usr/bin/env python3
"""把 src/fanqie.koplugin/ 打成可直接安装的 zip（跨平台）。

KOReader 的插件扫描规则要求 zip 的**顶层目录名必须等于插件目录名**
（即 `fanqie.koplugin/`），所以不能从仓库根直接打包——那样解压出来会是
`src/fanqie.koplugin/...` 这种多余层级，KOReader 认不出来。

为什么是 Python 而不是 shell：`zip`/`unzip` 在 Windows 上通常不存在，
而这个仓库本来就依赖 Python 跑测试。用标准库 `zipfile` 写、再用 `zipfile`
读回来自检，就能做到**在打包发生的同一台机器上验证打包结果**；
`scripts/package.sh` 只是它的一层薄封装。

用法：
    python scripts/package.py                  # 输出 dist/fanqie.koplugin-v<版本>.zip
    python scripts/package.py --out-dir DIR    # 换输出目录
    python scripts/package.py --name NAME      # 换产物名（不含 .zip）
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys
import zipfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN_SRC = REPO_ROOT / "src" / "fanqie.koplugin"
ARCHIVE_ROOT = "fanqie.koplugin"

# KOReader 靠 _meta.lua 识别插件；main.lua 是入口。两者缺一插件都装不上。
REQUIRED = [f"{ARCHIVE_ROOT}/_meta.lua", f"{ARCHIVE_ROOT}/main.lua"]

# 排除项：
#   config.lua   用户的本地配置（含登录凭据），绝不能进发行包
#   *.luac       编译产物
#   *.zip        误放进源码目录的历史产物
#   .DS_Store/.git/__pycache__  编辑器与版本控制残渣
EXCLUDE_SUFFIXES = {".luac", ".zip"}
EXCLUDE_NAMES = {"config.lua", "config.local.lua", "fanqie_device.json", ".DS_Store"}
EXCLUDE_DIRS = {".git", "__pycache__", ".pytest_cache", "node_modules"}

# 固定时间戳 → 同样的输入产出同样的字节（可复现构建）
FIXED_DATE = (2020, 1, 1, 0, 0, 0)


def read_version() -> str:
    """版本号的唯一来源是 fanqie/info.lua（_meta.lua 也读它），不在这里二次维护。"""
    info = PLUGIN_SRC / "fanqie" / "info.lua"
    if not info.is_file():
        return "0.0.0"
    # 必须用行首锚定，否则将来的 min_version = "x" 会被误当成版本号
    pattern = re.compile(r'^[ \t]*version[ \t]*=[ \t]*"([^"]+)"', re.MULTILINE)
    match = pattern.search(info.read_text(encoding="utf-8"))
    return match.group(1) if match else "0.0.0"


def should_skip(rel: pathlib.Path) -> bool:
    if rel.name in EXCLUDE_NAMES:
        return True
    if rel.suffix in EXCLUDE_SUFFIXES:
        return True
    return any(part in EXCLUDE_DIRS for part in rel.parts)


def collect_files() -> list[tuple[pathlib.Path, str]]:
    """返回 [(磁盘路径, zip 内路径)]，按 zip 内路径排序以保证顺序稳定。"""
    wanted: list[tuple[pathlib.Path, str]] = []
    for path in sorted(PLUGIN_SRC.rglob("*")):
        rel = path.relative_to(PLUGIN_SRC)
        if should_skip(rel):
            continue
        if path.is_dir():
            continue
        arcname = f"{ARCHIVE_ROOT}/{rel.as_posix()}"
        wanted.append((path, arcname))
    wanted.sort(key=lambda item: item[1])
    return wanted


def build_zip(zip_path: pathlib.Path, files: list[tuple[pathlib.Path, str]]) -> None:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    if zip_path.exists():
        zip_path.unlink()

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        # 顶层目录条目放在第一位：解压时先建目录，也让"第一层是什么"一眼可查
        top = zipfile.ZipInfo(f"{ARCHIVE_ROOT}/", date_time=FIXED_DATE)
        top.external_attr = (0o40755 << 16) | 0x10
        zf.writestr(top, b"")

        seen_dirs = {ARCHIVE_ROOT}
        for src, arcname in files:
            # 补齐中间层目录条目（与 `zip -r` 的行为一致）
            parent = arcname.rsplit("/", 1)[0]
            parts = parent.split("/")
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d in seen_dirs:
                    continue
                seen_dirs.add(d)
                info = zipfile.ZipInfo(d + "/", date_time=FIXED_DATE)
                info.external_attr = (0o40755 << 16) | 0x10
                zf.writestr(info, b"")

            info = zipfile.ZipInfo(arcname, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            zf.writestr(info, src.read_bytes())


def self_check(zip_path: pathlib.Path) -> list[str]:
    """把刚写出的 zip 读回来验一遍。

    这一步的意义在于：能读回来才说明产物不是"看起来像 zip 的字节"。
    检查项与 CI 里 `zipinfo` 做的那几步一致，但这里不依赖外部工具。
    """
    problems: list[str] = []

    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()

        if not names:
            return ["产出的 zip 是空的"]

        if names[0] != f"{ARCHIVE_ROOT}/":
            problems.append(
                f"zip 第一层是 {names[0]!r}，应为 {ARCHIVE_ROOT + '/'!r}"
                "（KOReader 会因此识别不到插件）"
            )

        for required in REQUIRED:
            if required not in names:
                problems.append(f"缺少必需文件：{required}")

        for name in names:
            if name.endswith("config.lua") or name.endswith("config.local.lua"):
                problems.append(f"发行包里混进了本地配置：{name}")
            if pathlib.PurePosixPath(name).name in EXCLUDE_NAMES:
                problems.append(f"发行包里混进了运行时敏感或本地文件：{name}")
            if pathlib.PurePosixPath(name).suffix in EXCLUDE_SUFFIXES:
                problems.append(f"发行包里混进了编译产物或历史压缩包：{name}")

        # CRC 校验：让"解压出来是坏的"在这里就暴露
        bad = zf.testzip()
        if bad is not None:
            problems.append(f"条目 CRC 校验失败：{bad}")

        if not names[0].endswith("/"):
            # 顶层不是目录条目，说明打包路径拼错了
            problems.append("zip 第一个条目不是目录")

    return problems


def main(argv: list[str] | None = None) -> int:
    # Windows 控制台默认是 GBK，中文提示会变成乱码；与 tests/run_tests.py 保持一致。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):  # 3.6 以前 / 被重定向到不支持的对象
            pass

    parser = argparse.ArgumentParser(
        description="打包 fanqie.koplugin 为可安装的 zip",
    )
    parser.add_argument("--out-dir", default=str(REPO_ROOT / "dist"))
    parser.add_argument("--name", default="", help="产物名（不含 .zip）")
    args = parser.parse_args(argv)

    if not PLUGIN_SRC.is_dir():
        print(f"找不到插件源码目录：{PLUGIN_SRC}", file=sys.stderr)
        return 1

    version = read_version()
    zip_name = args.name or f"fanqie.koplugin-v{version}"
    out_dir = pathlib.Path(args.out_dir).resolve()
    zip_path = out_dir / f"{zip_name}.zip"

    files = collect_files()
    if not files:
        print("插件源码目录里没有可打包的文件", file=sys.stderr)
        return 1

    print(f"插件版本：{version}")
    print(f"源目录  ：{PLUGIN_SRC}")
    print(f"产物    ：{zip_path}")

    build_zip(zip_path, files)

    problems = self_check(zip_path)
    if problems:
        print("\n打包自检失败：", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    checksum_path = zip_path.with_suffix(zip_path.suffix + ".sha256")
    # sha256sum 的格式：<hex>  <文件名>
    checksum_path.write_text(f"{digest}  {zip_path.name}\n", encoding="utf-8")

    print()
    print(f"自检通过：{len(files)} 个文件，顶层为 {ARCHIVE_ROOT}/")
    print("安装方式：把 zip 解压到设备的 koreader/plugins/ 下，重启 KOReader。")
    print(f"校验和：{digest}  {zip_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

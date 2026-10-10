#!/usr/bin/env python3
"""下载 KOReader 官方 Linux 构建到本地缓存，供 WSL2 里的实测环境使用。

为什么需要这个脚本
------------------
Windows 上**没有** KOReader（官方只发 Kindle / Kobo / PocketBook / Cervantes /
reMarkable / Android / Linux 构建，从无 Windows 版）。所以"在 Windows 上实测插件"
的现实做法是：WSL2 + WSLg 跑官方 Linux 桌面版——桌面 Linux 是官方一等公民，
而且 `frontend/pluginloader.lua` 证明它加载插件的方式与 Kindle 版完全一致。

而本机 Windows 自己的 TLS 栈被环境挡住，两条常规路都不通：
  * `Invoke-WebRequest`（本机是 Windows PowerShell 5.1.26100.3624）
    → `基础连接已经关闭: 接收时发生错误`（默认 SecurityProtocol 不含 TLS 1.2）
  * `curl.exe` → `curl: (35) schannel: AcquireCredentialsHandle failed:
    SEC_E_NO_CREDENTIALS (0x8009030E)`
只有 Python 的 urllib（自带 OpenSSL）能出网，所以下载放在这里做。

它只负责**下载 + 校验**；解压与装插件由 `tools/win/setup-koreader-wsl.sh` 在 WSL 里完成。

用法
----
    python tools/win/fetch_koreader.py                # 下到 <仓库上级>/.cache/koreader
    python tools/win/fetch_koreader.py --check        # 只检查是否已就绪
    python tools/win/fetch_koreader.py --cache-dir D:\\ko
    python tools/win/fetch_koreader.py --force        # 即使已存在也重新下载
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import sys
import urllib.request

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE = REPO_ROOT.parent / ".cache" / "koreader"

# 版本与校验和一并写死：这样"下载到的东西是不是官方原版"是可验证的，
# 而不是只凭 URL 判断。升级时两个值一起改。
VERSION = "v2026.07.1"
ASSET = f"koreader-linux-x86_64-{VERSION}.tar.xz"
SHA256 = "299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0"
SIZE = 30144476
URL = f"https://github.com/koreader/koreader/releases/download/{VERSION}/{ASSET}"

CHUNK = 1 << 16


def sha256_of(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, dest: pathlib.Path) -> tuple[str, int]:
    """流式下载到 `.part` 再改名，顺便累加 sha256——避免半个文件被当成成品。"""
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "fanqie-KOReader-fetch/1.0"})
    h = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(req, timeout=120) as resp, tmp.open("wb") as out:
        while True:
            chunk = resp.read(CHUNK)
            if not chunk:
                break
            h.update(chunk)
            total += len(chunk)
            out.write(chunk)
    tmp.replace(dest)
    return h.hexdigest(), total


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="fetch_koreader.py", description=__doc__.split("\n")[0])
    parser.add_argument("--cache-dir", default=str(DEFAULT_CACHE), help="下载缓存目录")
    parser.add_argument("--check", action="store_true", help="只检查，不下载")
    parser.add_argument("--force", action="store_true", help="已存在也重新下载")
    args = parser.parse_args()

    cache = pathlib.Path(args.cache_dir)
    dest = cache / ASSET

    if dest.exists() and not args.force:
        got = sha256_of(dest)
        ok = got == SHA256
        print(f"{'OK' if ok else 'FAIL'}：已存在 {dest}")
        print(f"     sha256 {got}")
        if not ok:
            print(f"     期望   {SHA256}", file=sys.stderr)
            print("     文件不完整或不是官方原版；用 --force 重新下载。", file=sys.stderr)
            return 1
        print("     （用 --force 可强制重新下载）")
        return 0

    if args.check:
        print(f"未就绪：{dest} 不存在", file=sys.stderr)
        return 1

    cache.mkdir(parents=True, exist_ok=True)
    print(f"# 版本 {VERSION}")
    print(f"# 下载 {ASSET}（约 {SIZE / 1048576:.1f} MB）")
    print(f"# 从   {URL}")
    try:
        got, size = download(URL, dest)
    except Exception as exc:  # noqa: BLE001 - 网络失败要把原始原因原样报出来
        print(f"下载失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 2

    print(f"# 落盘 {dest}")
    print(f"# 大小 {size} 字节（{size / 1048576:.1f} MB）")
    if got != SHA256:
        print(f"校验失败：sha256 实得 {got}", file=sys.stderr)
        print(f"          期望     {SHA256}", file=sys.stderr)
        return 3
    print("校验通过 ✓（sha256 与官方发布页一致）")
    print()
    print("下一步（在 WSL 里执行，或等 WSL 装好后让我来做）：")
    wsl_path = "/mnt/" + str(dest).replace(":", "").replace("\\", "/").lower()
    print(f"  bash tools/win/setup-koreader-wsl.sh --tarball {wsl_path}")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())

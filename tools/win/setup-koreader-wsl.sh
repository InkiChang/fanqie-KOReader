#!/usr/bin/env bash
#
# 在 WSL(Ubuntu) 里装好 KOReader，并把本仓库的插件放到它**会自动加载**的位置。
#
# 依据（都已在代码里核实过，不是猜的）：
#   * frontend/pluginloader.lua 的 _discover() 会把 "$data_dir/plugins/" 加进插件搜索路径，
#     并加载其中所有以 .koplugin 结尾的目录（dofile 其 main.lua，且把该目录前置进
#     package.path，所以 require("fanqie.helper") 能解析）。插件名 = 目录名去掉
#     .koplugin 后缀（本次为 "fanqie"），会出现在 菜单 → 插件管理 → User plugins。
#     桌面 Linux 版与 Kindle 版共用同一套前端，所以这样装能被认出来。
#   * 官方 tar.xz 的顶层是 README.md / bin / lib / share，**程序本体在 lib/koreader/**。
#     bin/koreader 与 lib/koreader/koreader.sh 正文相同，两者都会先 cd 到自己所在目录
#     再跑 ./reader.lua —— 而 reader.lua 只在 lib/koreader/ 下，所以
#     **必须用 lib/koreader/koreader.sh 启动**（deb 里 /usr/bin/koreader 是指向它的符号链接，
#     realpath 才让两者等价）。
#
# 用法：
#   bash tools/win/setup-koreader-wsl.sh --tarball /mnt/c/.../koreader-linux-x86_64-v2026.07.1.tar.xz
#   bash tools/win/setup-koreader-wsl.sh --tarball ... --prefix "$HOME/koreader" --skip-check
#
# 参数：
#   --tarball PATH   官方 Linux 构建的 .tar.xz（必填；可用 tools/win/fetch_koreader.py 先下）
#   --prefix DIR     解压位置，默认 $HOME/koreader
#   --repo DIR       本仓库根目录（含 src/fanqie.koplugin），默认按脚本位置推断
#   --skip-check     跳过无窗口自检

set -euo pipefail

TARBALL=""
PREFIX="${HOME}/koreader"
REPO=""
SKIP_CHECK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --tarball)    TARBALL="${2:-}"; shift 2 ;;
        --prefix)     PREFIX="${2:-}"; shift 2 ;;
        --repo)       REPO="${2:-}"; shift 2 ;;
        --skip-check) SKIP_CHECK=1; shift ;;
        -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

die() { echo "错误：$*" >&2; exit 1; }
step() { echo; echo "── $* ──"; }

[ -n "$TARBALL" ] || die "缺少 --tarball。先用 python tools/win/fetch_koreader.py 下载官方 Linux 构建。"

if [ -z "$REPO" ]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    REPO="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
fi

PLUGIN_SRC="${REPO}/src/fanqie.koplugin"
[ -f "$TARBALL" ]        || die "找不到文件：$TARBALL"
[ -d "$PLUGIN_SRC" ]     || die "找不到插件源码目录：$PLUGIN_SRC"
[ -f "$PLUGIN_SRC/main.lua" ] || die "$PLUGIN_SRC 里没有 main.lua，路径不对？"

step "环境自检"
echo "  发行版   ：$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-未知}" )"
echo "  内核     ：$(uname -r)"
echo "  tarball  ：$TARBALL"
echo "  解压到   ：$PREFIX"
echo "  仓库     ：$REPO"
command -v tar    >/dev/null || die "缺少 tar"
command -v timeout >/dev/null || echo "  提示：没有 timeout，自检环节会跳过"

step "解压 KOReader"
mkdir -p "$PREFIX"
tar -xJf "$TARBALL" -C "$PREFIX"
LAUNCHER="$PREFIX/lib/koreader/koreader.sh"
[ -f "$LAUNCHER" ] || die "解压后没有 $LAUNCHER —— 包结构与预期不符，请把 tar -tJf 的前 20 行发我"
[ -f "$PREFIX/lib/koreader/reader.lua" ] || die "缺少 lib/koreader/reader.lua"
chmod +x "$LAUNCHER" 2>/dev/null || true
echo "  ✓ 启动脚本 $LAUNCHER"
echo "  ✓ 正文入口 $PREFIX/lib/koreader/reader.lua"

step "安装插件（放到 KOReader 会自动加载的目录）"
DATA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/koreader"
PLUGIN_DST="${DATA_DIR}/plugins/fanqie.koplugin"
mkdir -p "${DATA_DIR}/plugins"
rm -rf "$PLUGIN_DST"
cp -a "$PLUGIN_SRC" "$PLUGIN_DST"
echo "  ✓ $PLUGIN_DST"
echo "    插件名 = 目录名去后缀 = fanqie（会出现在 菜单 → 插件管理 → User plugins）"

# config.lua 里是账号/凭据，发行包里刻意不带；这里给一份模板方便填聚合书源。
if [ -f "${PLUGIN_DST}/config.example.lua" ] && [ ! -f "${PLUGIN_DST}/config.lua" ]; then
    cp "${PLUGIN_DST}/config.example.lua" "${PLUGIN_DST}/config.lua"
    echo "  ✓ 已从 config.example.lua 生成 config.lua（只用扫码登录的话可以不管它）"
fi

if [ "$SKIP_CHECK" -eq 0 ] && command -v timeout >/dev/null; then
    step "无窗口自检：KOReader 能否启动并发现插件"
    LOG="$(mktemp -t koreader-boot-XXXX.log)"
    set +e
    ( cd "$PREFIX/lib/koreader" && \
      SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
      timeout 30 ./koreader.sh --debug ) >"$LOG" 2>&1
    rc=$?
    set -e
    echo "  退出码 $rc（124 = 被 timeout 掐断，说明它确实跑起来并一直运行着）"
    echo "  日志 $LOG"
    echo "  ── 与插件相关的日志行 ──"
    grep -i -E "plugin|fanqie" "$LOG" | head -30 || echo "  （没有任何 plugin/fanqie 相关输出）"
    echo "  ── 日志末尾 8 行 ──"
    tail -8 "$LOG" | sed 's/^/  /' || true
    if grep -qi "fanqie" "$LOG"; then
        echo "  ✓ 日志里出现了 fanqie —— 插件已被扫描到"
    else
        echo "  ✗ 日志里没有 fanqie。可能是自检环境起不来（SDL dummy 不被接受等），"
        echo "    不代表插件有问题：请改用有窗口的方式启动后再看 插件管理。"
    fi
fi

step "下一步"
cat <<EOF
  1) 在 Windows 桌面启动（WSLg 会把窗口开出来）：
       powershell -File tools\\win\\launch-koreader.ps1
     或在 WSL 里手动：
       cd $PREFIX/lib/koreader && ./koreader.sh
  2) 菜单 → 插件管理 → User plugins → 启用「番茄小说」（①）
  3) 菜单 → 番茄小说 → 扫码登录，用手机番茄 App 扫（②）
  4) 打开书架里的一本书，读几页；再回手机 App 看进度是否同步（②）
  5) 日志：$DATA_DIR/crash.log 与 $DATA_DIR/fanqie.log（后者含凭据只在开启开发者日志时写，已修）
EOF

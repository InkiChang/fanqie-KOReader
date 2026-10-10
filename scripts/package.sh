#!/usr/bin/env bash
#
# 把 src/fanqie.koplugin/ 打成可直接安装的 zip。
#
# 真正的实现在 scripts/package.py —— 用 Python 标准库写，是为了让**打包与自检
# 不依赖 zip/unzip 命令**，从而在任何装了 Python 的机器（含 Windows）上都能跑，
# 也能在打包的同一台机器上把产物读回来验一遍。
# 本脚本只是给习惯 shell 的人（以及 CI 里的 unix 风格调用）留的一层薄封装。
#
# 用法：
#   scripts/package.sh                 # 输出 dist/fanqie.koplugin-v<版本>.zip
#   scripts/package.sh --out-dir DIR    # 换输出目录
#   scripts/package.sh --name NAME      # 换产物名（不含 .zip）

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PYTHON="${PYTHON:-}"
if [[ -z "${PYTHON}" ]]; then
    for candidate in python3 python; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            PYTHON="${candidate}"
            break
        fi
    done
fi

if [[ -z "${PYTHON}" ]]; then
    echo "找不到 python3（打包脚本用 Python 标准库实现，见 scripts/package.py）" >&2
    exit 1
fi

exec "${PYTHON}" "${SCRIPT_DIR}/package.py" "$@"

#!/usr/bin/env bash
set -euo pipefail

# looper installer
#
# Usage:
#   bash install.sh [--target <claude_home>]
#   CLAUDE_DIR=<claude_home> bash install.sh      # packer 约定（优先级低于 --target）
#
# 安装内容：
#   commands/looper.md → <claude_home>/commands/looper.md
#
# 运行时说明（install.sh 本身不处理，仅供参考）：
#   镜像选择策略（4 级优先级）：
#     1. devcontainer.json image（自动检测）
#     2. --image <image> 参数（显式指定）
#     3. 本地已有 cc-runtime-minimal（之前构建或拉取的缓存）
#     4. fallback：引导用户构建或拉取 cc-runtime-minimal 后重试
#   获取 cc-runtime-minimal（任选其一）：
#     拉取：docker pull easyfan/agents-slim:cc-runtime-minimal && docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
#     构建：docker build -t cc-runtime-minimal <pkg>/assets/image/
#   首次调用后镜像配置持久化到 <project>/looper/.looper-state.json；非首次调用默认沿用。
#   如需切换镜像：/looper --command <name> --image <image>

TARGET="${CLAUDE_DIR:-${HOME}/.claude}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${TARGET}/commands"
cp "${SCRIPT_DIR}/commands/looper.md" "${TARGET}/commands/looper.md"
echo "✅ looper installed → ${TARGET}/commands/looper.md"

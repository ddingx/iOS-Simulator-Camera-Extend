#!/usr/bin/env bash
# bootstrap-xcode.sh —— 一行生成 SimCam.xcodeproj。
#
#   $ scripts/bootstrap-xcode.sh
#   $ open SimCam.xcodeproj
#   ⌘R 跑 SimCam scheme（会弹窗让你到「系统设置 ▸ 隐私与安全性」批准 Camera Extension）
#   ⌘U 跑 13 个 unit test

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "→ xcodegen 没装，用 brew 安装..."
    brew install xcodegen
fi

mkdir -p Generated

echo "→ 用 project.yml 生成 SimCam.xcodeproj ..."
xcodegen generate --spec project.yml

echo
echo "✓ 完成。下一步：open SimCam.xcodeproj 然后 ⌘R 跑 SimCam scheme。"

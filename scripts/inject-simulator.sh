#!/bin/zsh
# inject-simulator.sh
#
# 把被测 app 启动到 iOS Simulator 里，并在启动时通过 DYLD_INSERT_LIBRARIES
# 把 SimCamHook.dylib 注入进去。dylib 在 dyld 阶段 swizzle AVFoundation，
# 让被测 app 调标准 AVCaptureDevice / AVCaptureSession / AVCaptureVideoPreviewLayer
# / AVCaptureMetadataOutput 时拿到 host SimCamApp 推过来的画面。
#
# 用法：
#   ./scripts/inject-simulator.sh <bundle-id> [simulator-udid]
# 例：
#   ./scripts/inject-simulator.sh dev.simcam.demo
#   ./scripts/inject-simulator.sh com.example.MyApp 06D3B9B6-...
#
# 前置：
#   - 已经在 Xcode（或命令行）build 过 SimCamHook（iOS Simulator 平台）
#   - 已经把目标 app .app bundle install 进 simulator
#     (xcrun simctl install <udid> /path/to/MyApp.app)
#   - host 端 SimCamApp 在跑（unix sock /tmp/com.simcam.frames.sock）

set -e
BUNDLE_ID=${1:?"usage: $0 <bundle-id> [simulator-udid]"}
SIM_UDID=${2:-booted}

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 找最新一次 build 的 SimCamHook.dylib —— 优先用 Build/Products/ 目录里的
# universal+codesigned 产物，intermediate 的那份是 *未签名* 的，新版
# iOS Simulator (>= 17) 会拒绝 dyld 加载。
# IMPORTANT:
#   - 排除 Index.noindex —— 那是 Xcode index server 生成的空壳，
#     没有真二进制，也没有完整 Info.plist，install/inject 会失败。
#   - 按 mtime 排序取最新一份。多次 clone / 多个 scheme 共存时，老的
#     Build/Products/Debug-iphonesimulator/ 也会留着，`head -1` 不带排序
#     可能拿到隔月的旧 hook，注入后表现是「画面对得上但 swizzle 行为
#     和源码对不上」，最难排查。
pick_latest_hook() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    find "$root" \
            -path '*/Index.noindex/*' -prune -o \
            -path '*Build/Products/Debug-iphonesimulator/libSimCamHook.dylib' \
            -print 2>/dev/null \
        | grep -v Index.noindex \
        | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
        | sort -rn \
        | awk 'NR==1 {$1=""; sub(/^ /, ""); print}'
}

HOOK=$(pick_latest_hook "$HOME/Library/Developer/Xcode/DerivedData")
if [[ -z "$HOOK" ]]; then
    HOOK=$(pick_latest_hook "$PROJECT_ROOT/build")
fi
if [[ -z "$HOOK" ]]; then
    echo "❌ libSimCamHook.dylib not found in any DerivedData Build/Products."
    echo "   Build it first:  xcodebuild -project SimCam.xcodeproj -scheme SimCamDemo \\"
    echo "       -configuration Debug -destination 'generic/platform=iOS Simulator' build"
    exit 1
fi

# Hard-fail if the hook isn't signed at all. iOS Simulator 17+ refuses to
# DYLD_INSERT an unsigned dylib (the launched app then immediately exits
# with `Library not loaded`), and that error message is several layers
# deep in os_log so it's worth checking up front. Both ad-hoc (Signature=adhoc)
# and proper authority (Authority=...) are acceptable.
if ! codesign -dvv "$HOOK" 2>&1 | grep -qE 'Signature=adhoc|Authority='; then
    echo "❌ $HOOK is not codesigned (neither ad-hoc nor with an authority)."
    echo "   xcodebuild produces signed output under Build/Products/. If you got"
    echo "   this from the intermediate Build/Intermediates.noindex/ tree, rebuild"
    echo "   the SimCamHook scheme so Xcode runs the codesign phase."
    exit 1
fi
echo "==> hook dylib:   $HOOK"
echo "==> bundle id:    $BUNDLE_ID"
echo "==> simulator:    $SIM_UDID"

# 确认目标 app 已经装进 simulator
if ! xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "❌ $BUNDLE_ID is not installed on $SIM_UDID."
    echo "   xcrun simctl install $SIM_UDID /path/to/YourApp.app"
    exit 1
fi

# host 端 sock 文件应该可访问
if [[ ! -S /tmp/com.simcam.frames.sock ]]; then
    echo "⚠️  /tmp/com.simcam.frames.sock not found — start SimCamApp on the host first."
fi

echo "==> terminating any running instance"
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "==> launching with DYLD_INSERT_LIBRARIES injected"
# simctl forwards env vars whose names start with SIMCTL_CHILD_ into the
# launched simulator process (stripping the prefix). That's how we get
# DYLD_INSERT_LIBRARIES into the target app.
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$HOOK" \
SIMCTL_CHILD_SIMCAM_HOOK_VERBOSE=1 \
xcrun simctl launch \
    --terminate-running-process \
    "$SIM_UDID" "$BUNDLE_ID"

echo
echo "✅ Launched $BUNDLE_ID with SimCamHook injected."
echo "   Tail logs: xcrun simctl spawn $SIM_UDID log stream --level debug --predicate 'eventMessage CONTAINS \"SimCamHook\"'"

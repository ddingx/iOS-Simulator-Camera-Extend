#!/bin/zsh
# Install SimCamApp.app to /Applications/ with ad-hoc signature + entitlements injected.
# This is the ONLY supported path for sysextd to accept a system extension on this machine.
# Requires:
#   - SIP disabled (kext signing / debugging restrictions / kernel integrity)
#   - sudo systemextensionsctl developer on
# Run from project root:
#   sudo ./scripts/install-systemext.sh
set -e

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$HOME/Library/Developer/Xcode/DerivedData/SimCam-aouwuqkfbsoimbabffvggfvsvtip/Build/Products/Debug/SimCamApp.app"
DST="/Applications/SimCamApp.app"

if [[ ! -d "$SRC" ]]; then
    echo "❌ Built app not found at $SRC"
    echo "   Build first:  xcodebuild -project SimCam.xcodeproj -scheme SimCam -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ℹ️  Re-running with sudo to write into /Applications/"
    exec sudo "$0" "$@"
fi

echo "==> Stopping any running instance"
pkill -9 -f SimCamApp 2>/dev/null || true
sleep 0.3

echo "==> Uninstalling any previously activated SimCamExtension to avoid db.plist zombies"
# `-` 占位 team id 需要 SIP / developer mode 才能用；失败时静默继续。
sudo systemextensionsctl uninstall - dev.simcam.app.extension 2>/dev/null || true

echo "==> Removing old install"
rm -rf "$DST"

echo "==> Copying $(basename "$SRC") -> $DST"
cp -R "$SRC" "$DST"
# IMPORTANT: sysextd refuses /Applications apps owned by a regular user
# with "no policy, cannot allow apps outside /Applications" — keep root:wheel
chown -R root:wheel "$DST"
chmod -R 755 "$DST"

cat > /tmp/simcam_app.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.developer.system-extension.install</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>dev.simcam.app</string>
    </array>
</dict>
</plist>
EOF

cat > /tmp/simcam_ext.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>dev.simcam.app</string>
    </array>
</dict>
</plist>
EOF

echo "==> Re-signing system extension (ad-hoc + entitlements)"
codesign --force --sign - \
    --entitlements /tmp/simcam_ext.entitlements \
    --timestamp=none --generate-entitlement-der \
    "$DST/Contents/Library/SystemExtensions/dev.simcam.app.extension.systemextension"

echo "==> Re-signing host app (ad-hoc + system-extension.install entitlement)"
codesign --force --sign - \
    --entitlements /tmp/simcam_app.entitlements \
    --timestamp=none --generate-entitlement-der \
    "$DST"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$DST"
codesign -d --entitlements - "$DST" 2>&1 | grep -E "system-extension|sandbox" || true

echo "==> Registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$DST"

echo
echo "✅ Installed at $DST"
echo
echo "Next: open it (NOT as root) and watch the menubar -> 'Activate Virtual Camera'"
echo "    open '$DST'"

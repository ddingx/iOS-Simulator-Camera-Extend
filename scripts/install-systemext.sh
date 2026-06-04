#!/bin/zsh
# Install SimCamApp.app to /Applications/ signed by the local self-signed
# code-signing identity "SimCam Local Dev" (created by scripts/bootstrap-cert.sh).
# Self-signed (vs ad-hoc) keeps the designated requirement stable across rebuilds,
# so TCC (Camera / Screen Recording) consents survive recompiles.
# Requires:
#   - SIP relaxed enough for sysextd dev mode (kext signing / debugging restrictions / kernel integrity off)
#   - sudo systemextensionsctl developer on
#   - SimCam Local Dev identity present in login keychain (run scripts/bootstrap-cert.sh once)
# Run from project root:
#   sudo ./scripts/install-systemext.sh
set -e

CODESIGN_IDENTITY="SimCam Local Dev"

# Verify identity exists *before* sudo re-exec, because root has its own keychain
# search list and won't see the user's login keychain.
if [[ $EUID -ne 0 ]]; then
    if ! security find-identity -v -p codesigning login.keychain-db 2>/dev/null | grep -q "$CODESIGN_IDENTITY"; then
        if ! security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
            echo "❌ Code signing identity '$CODESIGN_IDENTITY' not found in login keychain."
            echo "   Run: ./scripts/bootstrap-cert.sh"
            exit 1
        fi
    fi
fi

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Locate the freshest SimCamApp.app under DerivedData. Avoid hard-coding the
# project hash suffix (e.g. SimCam-aouwuqkfbsoimbabffvggfvsvtip) — that hash
# is per-machine, so a checkout on another box will silently fall through to
# `Built app not found` if we pin it. Strategy:
#   1. Glob `*Build/Products/Debug/SimCamApp.app` under DerivedData.
#   2. Skip Index.noindex/ shells (Xcode's index server stages empty dirs).
#   3. Sort by mtime (newest first) so multi-clone / CI scenarios pick the
#      build that just finished, not a stale sibling.
#   4. Fall back to the in-tree build/ dir Xcode produces when DerivedData is
#      redirected.
SRC=""
DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
if [[ -d "$DERIVED_ROOT" ]]; then
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        case "$candidate" in
            *Index.noindex*) continue ;;
        esac
        SRC="$candidate"
        break
    # NUL-delimited find -> xargs to survive spaces in $HOME (e.g. corp
    # laptops with names like "Volumes/Macintosh HD/Users/First Last/...").
    # macOS BSD `stat -f` does NOT honour \t escapes inside the format
    # string, so we emit "<mtime> <path>" with a single space and let awk
    # peel off field 1 and re-emit the rest, preserving any embedded
    # spaces inside the path.
    done < <(find "$DERIVED_ROOT" -type d -name SimCamApp.app -path '*Build/Products/Debug/SimCamApp.app' -print0 2>/dev/null \
        | xargs -0 stat -f '%m %N' 2>/dev/null \
        | sort -rn \
        | awk '{ mtime = $1; sub(/^[0-9]+ /, ""); print }')
fi
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    FALLBACK="$PROJECT_ROOT/build/Build/Products/Debug/SimCamApp.app"
    if [[ -d "$FALLBACK" ]]; then
        SRC="$FALLBACK"
    fi
fi
DST="/Applications/SimCamApp.app"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "❌ Built SimCamApp.app not found under $DERIVED_ROOT or $PROJECT_ROOT/build/"
    echo "   Build first:  xcodebuild -project SimCam.xcodeproj -scheme SimCam -configuration Debug build"
    exit 1
fi

echo "==> Using build product: $SRC"

if [[ $EUID -ne 0 ]]; then
    echo "ℹ️  Re-running with sudo to write into /Applications/"
    exec sudo -E "$0" "$@"
fi

# When running as root after sudo, $SUDO_USER tells us whose keychain to use.
RUN_AS_USER="${SUDO_USER:-$USER}"

echo "==> Stopping any running instance"
pkill -9 -f SimCamApp 2>/dev/null || true
sleep 0.3

# Detect zombie sysext entries left over from previous installs.
# Once `systemextensionsctl uninstall` runs, the old bundle drops to
# state "[terminated waiting to uninstall on reboot]" and stays there
# until the machine reboots. They look ugly in `systemextensionsctl
# list` but empirically do NOT prevent a fresh activation from
# succeeding (verified on macOS 26 with 25 zombie entries — activation
# still went through fine once the entitlements were correct). So
# this is informational only.
ZOMBIE_COUNT=$(systemextensionsctl list 2>/dev/null | grep -c "dev.simcam.app.extension.*waiting to uninstall on reboot" || true)
if (( ZOMBIE_COUNT >= 1 )); then
    echo "ℹ️  Found $ZOMBIE_COUNT pending uninstall-on-reboot entries for dev.simcam.app.extension."
    echo "   These will only be cleaned by a reboot, but they don't block a fresh activation."
fi

echo "==> Uninstalling any previously activated SimCamExtension to avoid db.plist zombies"
# `-` 占位 team id 需要 SIP / developer mode 才能用；失败时静默继续。
sudo systemextensionsctl uninstall - dev.simcam.app.extension 2>/dev/null || true

echo "==> Removing old install"
rm -rf "$DST"

echo "==> Copying $(basename "$SRC") -> $DST"
cp -R "$SRC" "$DST"
# IMPORTANT: keep $DST user-owned for now so the upcoming
# `sudo -u $RUN_AS_USER codesign` can write _CodeSignature/.
# We'll chown root:wheel AFTER re-signing — that's what sysextd
# really cares about ("no policy, cannot allow apps outside /Applications"
# rejects user-owned apps in /Applications, but only at sysext submit time).
chown -R "$RUN_AS_USER":staff "$DST"

cat > /tmp/simcam_app.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.developer.system-extension.install</key>
    <true/>
    <!-- application-groups MUST be present here AND must match the sysext
         side. Without it, sysextd fails the activation request with
         "extension category returned error" and the host banner stays at
         "CMIO extension not activated". This was empirically verified on
         macOS 26: install once with the key removed → activation fails;
         restore the key → activation succeeds. -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>dev.simcam.app</string>
    </array>
    <!-- Without library-validation disabled, hardened runtime refuses to map
         SimCamApp.debug.dylib / __preview.dylib because they are not signed
         by Apple and our self-signed cert has no Team ID. dyld then aborts
         with "different Team IDs". -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
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

echo "==> Re-signing system extension as '$CODESIGN_IDENTITY' (via $RUN_AS_USER's keychain)"
sudo -u "$RUN_AS_USER" codesign --force --sign "$CODESIGN_IDENTITY" \
    --entitlements /tmp/simcam_ext.entitlements \
    --options runtime \
    --timestamp=none --generate-entitlement-der \
    "$DST/Contents/Library/SystemExtensions/dev.simcam.app.extension.systemextension"

# Re-sign every dylib/bundle inside the host BEFORE the host wrapper.
# Why: codesign on a .app bundle does NOT recurse into Contents/MacOS/*.dylib
# (e.g. Xcode debug build's SimCamApp.debug.dylib, __preview.dylib). Those keep
# their build-time signature, and dyld then refuses to map them with
# "mapping process and mapped file (non-platform) have different Team IDs"
# because main binary is now signed by SimCam Local Dev (TeamIdentifier=not set)
# while the dylib still has the Xcode build-time signature.
echo "==> Re-signing inner dylibs/frameworks under host bundle"
INNER_PATHS=()
while IFS= read -r -d '' f; do INNER_PATHS+=("$f"); done < <(find "$DST/Contents/MacOS" "$DST/Contents/Frameworks" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
while IFS= read -r -d '' f; do INNER_PATHS+=("$f"); done < <(find "$DST/Contents/Frameworks" -maxdepth 2 -type d -name '*.framework' -print0 2>/dev/null)
for p in "${INNER_PATHS[@]}"; do
    echo "  - $(basename "$p")"
    sudo -u "$RUN_AS_USER" codesign --force --sign "$CODESIGN_IDENTITY" \
        --options runtime \
        --timestamp=none --generate-entitlement-der \
        "$p"
done

echo "==> Re-signing host app as '$CODESIGN_IDENTITY' (via $RUN_AS_USER's keychain)"
sudo -u "$RUN_AS_USER" codesign --force --sign "$CODESIGN_IDENTITY" \
    --entitlements /tmp/simcam_app.entitlements \
    --options runtime \
    --timestamp=none --generate-entitlement-der \
    "$DST"

echo "==> Locking down ownership to root:wheel (sysextd hard requirement)"
chown -R root:wheel "$DST"
chmod -R 755 "$DST"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$DST"
codesign -d --entitlements - "$DST" 2>&1 | grep -E "system-extension|sandbox" || true
codesign -dvv "$DST" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier" || true

echo "==> Registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$DST"

echo
echo "✅ Installed at $DST"
echo
echo "Next: open it (NOT as root); AppDelegate.applicationDidFinishLaunching"
echo "      auto-runs ExtensionActivator.shared.activate(). On first run macOS"
echo "      will prompt 'System Settings -> Privacy & Security -> allow extension'."
echo "    open '$DST'"

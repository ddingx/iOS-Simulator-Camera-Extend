#!/bin/zsh
# Diagnose why sysextd rejects /Applications/SimCamApp.app with
# "no policy, cannot allow apps outside /Applications"
#
# Usage:  ./scripts/diagnose-sysext.sh
echo "==========================================="
echo "  SimCam System Extension Diagnostic"
echo "==========================================="
echo

APP="/Applications/SimCamApp.app"
EXT="$APP/Contents/Library/SystemExtensions/SimCamExtension.systemextension"

echo "── 1. SIP status ────────────────────────────"
csrutil status 2>&1 | sed 's/^/   /'
echo

echo "── 2. Developer mode ────────────────────────"
systemextensionsctl developer 2>&1 | sed 's/^/   /'
echo

echo "── 3. /Applications mount / symlink ─────────"
ls -la / | grep -E "Applications" | sed 's/^/   /'
echo "   readlink chain:"
python3 -c 'import os; p = os.path.realpath("/Applications/SimCamApp.app"); print("   real path:", p)'
mount | grep -E "/Applications|firmlink" | sed 's/^/   /' || echo "   (no special mount)"
echo

echo "── 4. App on disk ───────────────────────────"
if [[ ! -d "$APP" ]]; then
    echo "   ❌ NOT FOUND: $APP"
    echo "   Run: sudo ./scripts/install-systemext.sh"
    exit 1
fi
ls -ld "$APP" | sed 's/^/   /'
ls -ld "$EXT" 2>&1 | sed 's/^/   /'
echo

echo "── 5. Code signing ──────────────────────────"
echo "   APP ↓"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|Format" | sed 's/^/      /'
echo "   APP entitlements ↓"
codesign -d --entitlements - "$APP" 2>&1 | grep -E "system-extension|sandbox|Key" | sed 's/^/      /'
echo "   EXT ↓"
codesign -dv "$EXT" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|Format" | sed 's/^/      /'
echo "   --verify --deep --strict:"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -5 | sed 's/^/      /'
echo

echo "── 6. Currently running SimCamApp ──────────"
pgrep -fl SimCamApp | sed 's/^/   /'
echo

echo "── 7. systemextensionsctl list ──────────────"
systemextensionsctl list 2>&1 | sed 's/^/   /'
echo

echo "── 8. Last sysextd verdict on dev.simcam ────"
log show --last 5m --predicate 'process == "sysextd" OR subsystem == "dev.simcam.app"' --info --debug 2>&1 \
    | grep -E "Submitting|client activation|attempting to realize|no policy|requires user|approval|finished|failed|Extension not found|policy violation|invalid|missing entitlement" \
    | tail -20 | sed 's/^/   /'
echo

echo "──────────── End of diagnostic ──────────────"

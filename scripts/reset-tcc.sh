#!/bin/zsh
# reset-tcc.sh — wipe stale TCC entries that were keyed off old ad-hoc cdhashes.
#
# Why
# ---
# Until commit "switch host+extension to Personal Team signing" SimCamApp and
# its embedded SimCamExtension were signed ad-hoc. Every rebuild produced a
# new cdhash, and TCC indexes its grants by (bundle id, code requirement).
# With ad-hoc, the requirement effectively pins the cdhash, so each rebuild
# looked like a brand-new app to TCC and the user had to keep removing the app
# from System Settings -> Privacy & Security -> Screen Recording (and re-grant)
# on every rebuild.
#
# This script does the cleanup macOS expects when the signing identity
# changes:
#   1. tccutil reset for the relevant services and bundle ids, so the next
#      launch creates a fresh, Personal-Team-keyed entry.
#   2. kill any running SimCamApp / SimCamExtension so launchd reloads.
#   3. (best effort) move /Applications/SimCamApp.app aside if you ever ran
#      `cp` it there — old copies signed ad-hoc would otherwise re-poison the
#      database.
#
# References
#   - Apple DTS Quinn on TCC + ad-hoc signing:
#     https://developer.apple.com/forums/thread/819406
#     https://developer.apple.com/forums/thread/678816
#   - tccutil(1)

set -euo pipefail

bundles=(
  "dev.simcam.app"
  "dev.simcam.app.extension"
)

services=(
  ScreenCapture
  Camera
  Microphone
  SystemPolicyAllFiles
  Accessibility
)

echo "Resetting TCC entries..."
for svc in "${services[@]}"; do
  for bid in "${bundles[@]}"; do
    # Use sudo on Sonoma+ where tccutil reset for some services requires root.
    sudo tccutil reset "$svc" "$bid" >/dev/null 2>&1 || true
    echo "  tccutil reset $svc $bid"
  done
done

echo "Killing any running SimCamApp / SimCamExtension..."
pkill -9 -x SimCamApp >/dev/null 2>&1 || true
pkill -9 -f "dev.simcam.app.extension" >/dev/null 2>&1 || true

stale_app="/Applications/SimCamApp.app"
if [[ -d "$stale_app" ]]; then
  ts="$(date +%s)"
  echo "Moving stale $stale_app -> $stale_app.old.$ts"
  sudo mv "$stale_app" "$stale_app.old.$ts"
fi

cat <<'EOF'
Done.

Now rebuild and launch SimCamApp from the build products dir or from
/Applications. macOS will prompt for permissions ONCE; the grants will be
keyed off your Personal Team's designated requirement, so subsequent rebuilds
keep the permission.

  $ make build && make run
EOF

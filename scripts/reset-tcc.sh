#!/bin/zsh
# reset-tcc.sh — wipe stale TCC entries that were keyed off old (ad-hoc or
# Apple-Development) cdhashes / authorities, so the first launch under the
# new "SimCam Local Dev" self-signed identity records a fresh grant.
#
# Why
# ---
# TCC indexes its grants by (bundle id, designated requirement). The
# designated requirement embeds the signing authority and, for ad-hoc
# signatures, the exact cdhash. Whenever you switch signing identities or
# (with ad-hoc) rebuild, the requirement no longer matches the stored grant
# and macOS demands re-authorization.
#
# Switching to a *stable* self-signed CA (CN=SimCam Local Dev, see
# scripts/bootstrap-cert.sh) keeps the requirement constant across rebuilds,
# but the very first transition still leaves stale rows behind. This script
# resets them once.
#
# References
#   - Apple DTS Quinn on TCC + ad-hoc signing:
#     https://developer.apple.com/forums/thread/819406
#     https://developer.apple.com/forums/thread/678816
#     https://developer.apple.com/forums/thread/823200
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

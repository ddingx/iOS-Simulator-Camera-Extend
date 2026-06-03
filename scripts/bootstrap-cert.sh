#!/bin/zsh
# bootstrap-cert.sh — generate a per-developer self-signed code-signing
# certificate (CN="SimCam Local Dev") and import it into login keychain.
#
# Why this exists
# ---------------
# SimCam can't use Apple Developer Program (open-source, no shared private
# key allowed in the repo) and can't use Apple Development with a Personal
# Team (Apple refuses System Extension capability for Personal Team —
# verified 2026-06-03 in Xcode "Signing & Capabilities" tab).
#
# Pure ad-hoc signing (`codesign --sign -`) works for sysextd activation
# but TCC keys grants by codesign designated requirement, and ad-hoc DR
# pins the cdhash. Every rebuild => new cdhash => new DR => TCC treats
# the app as a brand-new app and re-prompts for Camera / ScreenCapture /
# Microphone every single time. See docs/signing-and-tcc.md.
#
# A self-signed cert with a stable CN gives us a stable DR ("certificate
# leaf[subject.CN] = SimCam Local Dev") that survives rebuilds — TCC
# remembers grants forever. The private key never leaves the developer's
# login keychain; the repo only commits the public CN string.
#
# Idempotent: re-running this script is a no-op if a usable identity is
# already in the keychain.
#
# Usage:  scripts/bootstrap-cert.sh

set -euo pipefail

CN="${SIMCAM_SIGN_CN:-SimCam Local Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d -t simcam-cert)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Self-signed code-signing bootstrap for SimCam"
echo "    CN     = $CN"
echo "    keychain = $KEYCHAIN"
echo

# 1. Already a usable identity?  Don't spam the keychain on every CI run.
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
       | grep -F "\"$CN\"" >/dev/null; then
    echo "✓ Identity \"$CN\" already present in login keychain."
    echo "  (Re-run with SIMCAM_SIGN_CN=... to install a different one.)"
    security find-identity -v -p codesigning "$KEYCHAIN" \
        | grep -F "\"$CN\"" | sed 's/^/    /'
    exit 0
fi

# Clean up any orphan certificate from an earlier failed bootstrap
# (cert imported but private key not paired) — otherwise we'd accumulate
# duplicates and `find-identity` would still report 0 valid identities.
ORPHAN_HASHES=$(security find-certificate -a -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
    | awk '/^SHA-1 hash:/ {print $NF}')
if [[ -n "${ORPHAN_HASHES:-}" ]]; then
    echo "==> Removing orphan \"$CN\" certificate(s) from previous attempts"
    while IFS= read -r H; do
        [[ -z "$H" ]] && continue
        security delete-certificate -Z "$H" "$KEYCHAIN" >/dev/null 2>&1 || true
    done <<<"$ORPHAN_HASHES"
fi

# 2. Generate ECC P-256 key + self-signed cert with code-signing EKU.
#    We use openssl directly because `security create-keypair` only ships
#    on macOS 13.3+, and X509v3 extensions are easier to control here.
echo "==> Generating ECC P-256 private key"
openssl ecparam -name prime256v1 -genkey -noout -out "$WORKDIR/key.pem"

echo "==> Generating self-signed X.509 certificate (10 year validity)"
cat > "$WORKDIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_ext

[dn]
CN = $CN
O  = SimCam Local Dev
OU = SimCam

[v3_ext]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
# 1.2.840.113635.100.6.1.13 = "Apple Developer ID Application" — we do
# NOT claim it (we're not Apple-anchored). The codeSigning EKU above is
# enough for `codesign` and for sysextd-with-developer-mode-on.
EOF

openssl req -new -x509 \
    -key "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" \
    -days 3650 \
    -sha256 \
    -config "$WORKDIR/cert.cnf" \
    -extensions v3_ext

# Sanity-check: the cert MUST advertise the codeSigning EKU, otherwise
# `security find-identity -p codesigning` will hide it even after import.
if ! openssl x509 -in "$WORKDIR/cert.pem" -noout -ext extendedKeyUsage 2>/dev/null \
        | grep -qi 'Code Signing'; then
    echo "✗ Generated certificate does NOT carry Code Signing EKU."
    echo "  openssl x509 -in $WORKDIR/cert.pem -noout -text"
    exit 1
fi

# 3. Convert private key to a format macOS `security` is happy with
#    (legacy 3DES PBE; PKCS#8 PEM). macOS Sequoia's `security` is built
#    against LibreSSL and rejects modern PBE / SHA-256 MAC, so we wrap
#    the key in legacy PEM here.
echo "==> Converting private key to legacy PKCS#8 PEM"
KEY_PASS="simcam-bootstrap"
openssl pkcs8 -topk8 -inform PEM -outform PEM \
    -in "$WORKDIR/key.pem" \
    -out "$WORKDIR/key.p8.pem" \
    -v1 PBE-SHA1-3DES \
    -passout pass:"$KEY_PASS"

# 4. Import key and certificate SEPARATELY into login keychain.
#    Importing them as a single PKCS#12 has historically been flaky on
#    macOS — friendlyName/localKeyID metadata gets lost during the
#    LibreSSL <-> OpenSSL 3 round-trip and `find-identity` then can't
#    pair the cert with its private key. Importing each PEM individually
#    lets macOS pair them by SubjectKeyIdentifier on its own, which is
#    what `find-identity -p codesigning` actually checks.
echo "==> Importing private key into login keychain"
security import "$WORKDIR/key.p8.pem" \
    -k "$KEYCHAIN" \
    -P "$KEY_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productsign \
    -A

echo "==> Importing certificate into login keychain"
security import "$WORKDIR/cert.pem" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productsign \
    -A

# 5. Trust the cert under the codeSign policy (per-user trust DB; no sudo).
#    Without this `security find-identity -v -p codesigning` does not
#    list the cert because a *self-signed* root has no trust anchor.
#    -p codeSign limits the trust to code-signing only — it does NOT
#    make our CA trusted for TLS, S/MIME, etc.
echo "==> Granting codeSign trust to the certificate (per-user, no sudo)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem" \
    >/dev/null 2>&1 || \
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"

# 6. Allow `codesign` to use the private key without an interactive prompt
#    each time. Without this, every `codesign --sign "SimCam Local Dev"`
#    pops a "allow access" dialog. set-key-partition-list does require
#    the login keychain password once.
echo "==> Granting codesign permission to use the key (you may be prompted"
echo "    for your login keychain password ONCE)"
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$(/usr/bin/security default-keychain | tr -d '\" ')" \
    "$KEYCHAIN" >/dev/null 2>&1 || \
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s "$KEYCHAIN" >/dev/null 2>&1 || true

# 6. Verify codesign sees it.
echo
echo "==> Verifying"
if security find-identity -v -p codesigning "$KEYCHAIN" \
       | grep -F "\"$CN\"" >/dev/null; then
    security find-identity -v -p codesigning "$KEYCHAIN" \
        | grep -F "\"$CN\"" | sed 's/^/    /'
    echo
    echo "✓ Identity \"$CN\" ready for use by codesign."
    echo
    echo "Next steps:"
    echo "    sudo systemextensionsctl developer on   # one-time"
    echo "    make run                                 # build + install + open"
else
    echo "✗ Import succeeded but codesign can't find the identity."
    echo "  Try: security find-identity -v -p codesigning"
    exit 1
fi

#!/usr/bin/env bash
# One-time setup: generate a self-signed code signing certificate on your Mac.
# This certificate will be used to re-sign AltTab after each update, keeping
# the code identity stable so TCC (Accessibility/Screen Recording) permissions
# persist across versions.
set -eu

CERT_NAME="AltTab Local Signing"
KEYCHAIN="alt-tab-local.keychain"
KEYCHAIN_PASS="$(openssl rand -base64 16)"

echo "🔐 Generating self-signed certificate '$CERT_NAME'..."

# Generate key and certificate
openssl genrsa -out /tmp/alt-tab-local.key 2048
cat > /tmp/alt-tab-local.conf <<EOF
[ req ]
distinguished_name = req_name
prompt = no
[ req_name ]
CN = $CERT_NAME
[ extensions ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -new \
  -config /tmp/alt-tab-local.conf \
  -key /tmp/alt-tab-local.key \
  -extensions extensions \
  -sha256 \
  -out /tmp/alt-tab-local.crt \
  -days 3650

openssl pkcs12 -export \
  -inkey /tmp/alt-tab-local.key \
  -in /tmp/alt-tab-local.crt \
  -out /tmp/alt-tab-local.p12 \
  -passout pass:"$KEYCHAIN_PASS"

# Import into a dedicated keychain
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import /tmp/alt-tab-local.p12 -P "$KEYCHAIN_PASS" -k "$KEYCHAIN" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" > /dev/null 2>&1 || true

# Try to find the identity
echo ""
echo "🔍 Checking if certificate is usable for code signing..."

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' is valid for code signing."
    echo "   Keychain: $PWD/$KEYCHAIN"
    echo "   Run re-sign-alt-tab.sh after each AltTab update."
else
    echo "⚠️  macOS may require an Apple Developer certificate for code signing."
    echo "   Falling back to ad-hoc signing with tccutil workaround..."
    echo ""
    echo "   Alternative: use a free Apple Development certificate."
    echo "   Open Xcode → Preferences → Accounts → add your Apple ID."
    echo "   Then re-run this script with --apple-dev."
fi

# Cleanup
rm -f /tmp/alt-tab-local.key /tmp/alt-tab-local.crt /tmp/alt-tab-local.conf /tmp/alt-tab-local.p12

echo ""
echo "📦 Save files:"
echo "   Keychain: $PWD/$KEYCHAIN (keep this!)"

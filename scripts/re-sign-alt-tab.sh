#!/usr/bin/env bash
# Re-sign the installed AltTab.app with your local signing certificate.
# Run this after each AltTab update to keep TCC permissions stable.
set -eu

APP_PATH="${1:-/Applications/AltTab.app}"
CERT_NAME="AltTab Local Signing"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ AltTab not found at $APP_PATH"
    echo "   Usage: $0 [path/to/AltTab.app]"
    exit 1
fi

# Try the local keychain first
KEYCHAIN_PATH="${HOME}/.alt-tab/alt-tab-local.keychain"
if [ -f "$KEYCHAIN_PATH" ]; then
    echo "🔑 Unlocking local keychain..."
    KEYCHAIN_PASS="alt-tab-local"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" 2>/dev/null || true
    IDENTITY="$CERT_NAME"
else
    echo "🔍 Looking for '$CERT_NAME' in default keychains..."
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME" | head -1 | awk -F'"' '{print $2}')
    if [ -z "$IDENTITY" ]; then
        # Try without -p codesigning (may work on some macOS versions)
        IDENTITY=$(security find-identity -v 2>/dev/null | grep "$CERT_NAME" | head -1 | awk -F'"' '{print $2}')
    fi
    if [ -z "$IDENTITY" ]; then
        echo "❌ Signing certificate '$CERT_NAME' not found."
        echo "   Run setup-local-signing.sh first."
        exit 1
    fi
fi

echo "✍️  Re-signing $APP_PATH with '$IDENTITY'..."
codesign --force --deep --sign "$IDENTITY" \
    --options runtime \
    --entitlements "$(dirname "$0")/../alt_tab_macos.entitlements" \
    "$APP_PATH" 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Re-signed successfully!"
    echo ""
    echo "🔍 New signature info:"
    codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier"
    echo ""
    echo "⚠️  IMPORTANT: You may need to re-grant Accessibility/Screen Recording"
    echo "   permission ONE MORE TIME after this initial re-sign. After that,"
    echo "   future updates re-signed with the same certificate will keep permissions."
else
    echo "❌ Signing failed."
    echo "   Try running setup-local-signing.sh again, or use a free Apple"
    echo "   Development certificate via Xcode."
    exit 1
fi

#!/bin/bash
# Build → sign (Developer ID) → notarize → staple → zip the Mac app, so it opens
# with NO "right-click → Open" / "unidentified developer" warning.
#
# ── WHAT YOU NEED FIRST (one-time, from Matrack's Apple Developer account) ──────
#  1. A "Developer ID Application" certificate, installed in this Mac's login Keychain.
#       developer.apple.com → Certificates → + → "Developer ID Application" → download → double-click.
#       (Needs Account Holder / Admin on the team. This Mac currently has only
#        "Apple Development" certs, which CANNOT notarize.)
#  2. An App Store Connect API key for notarization:
#       App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key
#       (Access: "Developer"). Download the AuthKey_XXXX.p8 ONCE and note the Key ID + Issuer ID.
#
# ── RUN ────────────────────────────────────────────────────────────────────────
#   export AC_API_KEY=/path/to/AuthKey_XXXXXXXXXX.p8
#   export AC_KEY_ID=XXXXXXXXXX
#   export AC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ./notarize-mac.sh
#
# Optional: also upload to the GitHub release →  UPLOAD_RELEASE=v1.0.0 ./notarize-mac.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${AC_API_KEY:?Set AC_API_KEY to your AuthKey_*.p8 path}"
: "${AC_KEY_ID:?Set AC_KEY_ID}"
: "${AC_ISSUER_ID:?Set AC_ISSUER_ID}"

APP="MatrackTruckSim.app"
OUT="dist-notarized"
ZIP="MatrackTruckSim-mac.zip"

# 1. find the Developer ID Application identity
DEVID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
[ -n "$DEVID" ] || { echo "✗ No 'Developer ID Application' certificate in the Keychain. Install it first (see top of this script)."; exit 1; }
echo "→ Signing identity: $DEVID"

# 2. build the universal release binary
echo "→ Building universal release…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MatrackTruckSim"

# 3. assemble the .app bundle
rm -rf "$OUT"; mkdir -p "$OUT/$APP/Contents/MacOS" "$OUT/$APP/Contents/Resources"
cp "$BIN" "$OUT/$APP/Contents/MacOS/MatrackTruckSim"
cat > "$OUT/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MatrackTruckSim</string>
  <key>CFBundleDisplayName</key><string>Matrack Truck Sim</string>
  <key>CFBundleIdentifier</key><string>com.matrack.trucksim</string>
  <key>CFBundleExecutable</key><string>MatrackTruckSim</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Matrack Truck Sim uses Bluetooth to act as a test ELD tracker so the Matrack app can connect to it.</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>Matrack Truck Sim uses Bluetooth to act as a test ELD tracker so the Matrack app can connect to it.</string>
</dict></plist>
PLIST

# 4. sign with hardened runtime + secure timestamp (required for notarization)
echo "→ Signing (hardened runtime + timestamp)…"
codesign --force --options runtime --timestamp --sign "$DEVID" "$OUT/$APP"
codesign --verify --strict --verbose=2 "$OUT/$APP"

# 5. notarize (zip → submit → wait)
echo "→ Submitting to Apple notary service (waits for the result)…"
ditto -c -k --keepParent "$OUT/$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --key "$AC_API_KEY" --key-id "$AC_KEY_ID" --issuer "$AC_ISSUER_ID" --wait

# 6. staple the ticket so it works offline, then re-zip for distribution
echo "→ Stapling…"
xcrun stapler staple "$OUT/$APP"
xcrun stapler validate "$OUT/$APP"
( cd "$OUT" && ditto -c -k --keepParent "$APP" "../$ZIP" )
echo "✓ Notarized app ready: $ZIP  (opens with no Gatekeeper warning)"

# 7. optional: publish to the GitHub release
if [ -n "${UPLOAD_RELEASE:-}" ]; then
  echo "→ Uploading to release $UPLOAD_RELEASE…"
  gh release upload "$UPLOAD_RELEASE" "$ZIP" --clobber
  echo "✓ Uploaded — the website's Mac download is now notarized."
fi

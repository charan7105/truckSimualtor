#!/bin/bash
# Build -> assemble -> ad-hoc sign -> zip the Mac app (UNSIGNED "right-click > Open" model).
# This is the reproducible packaging used by CI (.github/workflows/build-mac.yml) AND for a local
# build:  ./package-mac.sh  =>  MatrackTruckSim-mac.zip
#
# For a *notarized* build that opens with NO Gatekeeper warning, use notarize-mac.sh instead
# (that needs a Developer ID cert + an App Store Connect notary key - see the top of that script).
set -euo pipefail
cd "$(dirname "$0")"

APP="MatrackTruckSim.app"
OUT="dist-mac"
ZIP="MatrackTruckSim-mac.zip"

echo "Building universal release (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MatrackTruckSim"

echo "Assembling ${APP} ..."
rm -rf "${OUT}"
mkdir -p "${OUT}/${APP}/Contents/MacOS" "${OUT}/${APP}/Contents/Resources"
cp "${BIN}" "${OUT}/${APP}/Contents/MacOS/MatrackTruckSim"
cat > "${OUT}/${APP}/Contents/Info.plist" <<'PLIST'
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

echo "Ad-hoc signing..."
codesign --force --deep -s - "${OUT}/${APP}"
codesign --verify --verbose=1 "${OUT}/${APP}"

echo "Zipping..."
( cd "${OUT}" && ditto -c -k --keepParent "${APP}" "../${ZIP}" )
echo "OK: ${ZIP} ready (universal, ad-hoc signed - opens with right-click > Open)."

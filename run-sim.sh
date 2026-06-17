#!/bin/bash
# Matrack Truck Sim launcher.
#
# WHY THIS EXISTS:
#   iOS reads a BLE peripheral's name from the GAP Device Name (2A00), which on macOS
#   is ALWAYS the system ComputerName — Apple gives no API to override it. The ELD app
#   routes MT-vs-PT by name.hasPrefix("ELD-MA"), so the Mac's name must read "ELD-MA"
#   at connect time. This script sets it to "ELD-MA" ONLY while the sim runs and
#   RESTORES your real name automatically on exit. You never manually rename anything.
#
# USAGE:   sudo ./run-sim.sh
#   (sudo is required only to set the system Bluetooth name; it is reverted on quit.)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo ./run-sim.sh"
  exit 1
fi

SIM_NAME="ELD-MA"
RUN_USER="${SUDO_USER:-$(whoami)}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

ORIG_COMPUTER="$(scutil --get ComputerName 2>/dev/null || echo '')"
ORIG_LOCALHOST="$(scutil --get LocalHostName 2>/dev/null || echo '')"

restore() {
  echo ""
  echo "↩︎  Restoring Mac name to '${ORIG_COMPUTER}'..."
  [[ -n "$ORIG_COMPUTER"  ]] && scutil --set ComputerName  "$ORIG_COMPUTER"  || true
  [[ -n "$ORIG_LOCALHOST" ]] && scutil --set LocalHostName "$ORIG_LOCALHOST" || true
  killall bluetoothd 2>/dev/null || true
  echo "✓  Done. Your Mac name is back to normal."
}
trap restore EXIT INT TERM

echo "→  Temporarily setting Mac Bluetooth name to '${SIM_NAME}' (was '${ORIG_COMPUTER}')"
scutil --set ComputerName  "$SIM_NAME"
scutil --set LocalHostName "$SIM_NAME"
killall bluetoothd 2>/dev/null || true   # force the BLE GAP name to refresh
sleep 2

echo "→  Launching the simulator dashboard (Bluetooth name is '${SIM_NAME}' until you quit)"
echo "   The Mac name auto-reverts when you close the app / press Ctrl-C."
echo ""
# Build + run as the normal user so .build isn't created as root.
sudo -u "$RUN_USER" bash -lc "cd '$PROJECT_DIR' && swift run"

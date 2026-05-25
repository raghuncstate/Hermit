#!/usr/bin/env bash
set -euo pipefail

XCODE_APP="${XCODE_APP:-/Applications/Xcode.app}"
XCODE_DEVELOPER_DIR="$XCODE_APP/Contents/Developer"

if [[ ! -d "$XCODE_DEVELOPER_DIR" ]]; then
  echo "Xcode not found at: $XCODE_APP" >&2
  echo "Install Xcode from the App Store, or run with XCODE_APP=/path/to/Xcode.app $0" >&2
  exit 1
fi

echo "Using Xcode at $XCODE_APP"

echo "Requesting admin access once for Xcode license/first-launch setup..."
sudo -v

echo "Selecting Xcode developer directory..."
sudo xcode-select -s "$XCODE_DEVELOPER_DIR"

echo "Accepting Xcode license..."
sudo xcodebuild -license accept

echo "Running Xcode first-launch setup..."
sudo xcodebuild -runFirstLaunch

echo "Checking installed iOS simulator runtimes..."
if xcrun simctl list runtimes | grep -q "iOS .*available"; then
  xcrun simctl list runtimes | grep "iOS .*available"
else
  echo "No available iOS simulator runtime found; downloading iOS platform..."
  xcodebuild -downloadPlatform iOS
  xcrun simctl list runtimes | grep "iOS .*available" || {
    echo "iOS runtime download finished, but no available iOS runtime was reported." >&2
    exit 1
  }
fi

echo
echo "Xcode and iOS simulator setup is complete."
echo "Next run command:"
echo "  ./run-hermit-simulator.sh"

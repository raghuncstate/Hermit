#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-Hermit.xcodeproj}"
SCHEME="${SCHEME:-Hermit}"
BUNDLE_ID="${BUNDLE_ID:-com.zeromissionllc.hermit}"
SIM_NAME="${SIM_NAME:-Hermit Test iPhone}"
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
SCREENSHOT="${SCREENSHOT:-/tmp/hermit-sim.png}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-420}"
OPEN_SIMULATOR="${OPEN_SIMULATOR:-1}"
LAUNCH_TIMEOUT_SECONDS="${LAUNCH_TIMEOUT_SECONDS:-15}"
SCREENSHOT_DELAY_SECONDS="${SCREENSHOT_DELAY_SECONDS:-10}"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

latest_ios_runtime() {
  xcrun simctl list runtimes |
    awk -F' - ' '/^iOS / && $0 !~ /unavailable/ { runtime = $NF } END { print runtime }'
}

device_udid() {
  xcrun simctl list devices available |
    awk -v name="$SIM_NAME" '
      $0 ~ "^[[:space:]]*" name " \\(" {
        if (match($0, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)) {
          print substr($0, RSTART, RLENGTH)
        }
        exit
      }
    '
}

ensure_device_type_exists() {
  if xcrun simctl list devicetypes | grep -Fq "($DEVICE_TYPE)"; then
    return
  fi

  DEVICE_TYPE="$(
    xcrun simctl list devicetypes |
      awk -F'[()]' '/^iPhone / { print $2; exit }'
  )"

  [[ -n "$DEVICE_TYPE" ]] || fail "No iPhone simulator device type is installed."
  log "Requested device type was unavailable; using $DEVICE_TYPE"
}

wait_for_boot() {
  local udid="$1"
  local output_file
  output_file="$(mktemp)"

  xcrun simctl bootstatus "$udid" -b >"$output_file" 2>&1 &
  local bootstatus_pid=$!
  local deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))

  while kill -0 "$bootstatus_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill "$bootstatus_pid" 2>/dev/null || true
      wait "$bootstatus_pid" 2>/dev/null || true
      cat "$output_file" >&2
      rm -f "$output_file"
      return 1
    fi
    sleep 5
  done

  local status=0
  wait "$bootstatus_pid" || status=$?
  cat "$output_file"
  rm -f "$output_file"
  return "$status"
}

nudge_stuck_first_boot() {
  log "Boot is still waiting; restarting simulator migration/location helpers once"

  local pids
  pids="$(
    ps -axo pid=,command= |
    awk '
      /CoreSimulator\/Volumes\/.*\/RuntimeRoot\/usr\/libexec\/locationd/ ||
      /CoreSimulator\/Volumes\/.*\/RuntimeRoot\/System\/Library\/PrivateFrameworks\/GeoServices\.framework\/geod/ ||
      /CoreSimulator\/Volumes\/.*\/RuntimeRoot\/System\/Library\/DataClassMigrators/ ||
      /CoreSimulator\/Volumes\/.*\/RuntimeRoot\/usr\/libexec\/datamigrator/ ||
      /CoreSimulator\/Volumes\/.*\/RuntimeRoot\/usr\/libexec\/migrationpluginwrapper/ {
        print $1
      }
    ' |
    tr '\n' ' '
  )"

  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
  fi
}

boot_device() {
  local udid="$1"

  xcrun simctl boot "$udid" 2>/dev/null || true
  if wait_for_boot "$udid"; then
    return
  fi

  nudge_stuck_first_boot
  if wait_for_boot "$udid"; then
    return
  fi

  fail "Simulator did not finish booting. Try rebooting the Mac, then run this script again."
}

show_build_setting() {
  local setting="$1"
  local settings_file="$2"

  awk -F'= ' -v setting="$setting" '
    $1 ~ "^[[:space:]]*" setting "[[:space:]]*$" {
      print $2
      exit
    }
  ' "$settings_file"
}

app_is_running() {
  local udid="$1"

  ps -axo command= |
    awk -v udid="$udid" '
      index($0, "/Devices/" udid "/") && index($0, "/Hermit.app/Hermit") {
        found = 1
      }
      END {
        exit found ? 0 : 1
      }
    '
}

run_launch_command() {
  local udid="$1"
  local output_file="$2"
  : >"$output_file"

  xcrun simctl launch "$udid" "$BUNDLE_ID" >"$output_file" 2>&1 &
  local launch_pid=$!
  local deadline=$((SECONDS + LAUNCH_TIMEOUT_SECONDS))

  while kill -0 "$launch_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill "$launch_pid" 2>/dev/null || true
      wait "$launch_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done

  wait "$launch_pid"
}

launch_app() {
  local udid="$1"
  local output_file
  output_file="$(mktemp)"

  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1

  for attempt in 1 2; do
    if run_launch_command "$udid" "$output_file"; then
      cat "$output_file"
      rm -f "$output_file"
      return 0
    fi

    cat "$output_file" >&2
    sleep 2

    if app_is_running "$udid"; then
      log "$BUNDLE_ID is running even though simctl did not return a process handle"
      rm -f "$output_file"
      return 0
    fi

    log "Launch attempt $attempt failed; retrying"
  done

  rm -f "$output_file"
  return 1
}

log "Selecting an iOS simulator runtime"
RUNTIME="$(latest_ios_runtime)"
[[ -n "$RUNTIME" ]] || fail "No available iOS simulator runtime found. Run ./setup-xcode-ios.sh first."

ensure_device_type_exists

UDID="$(device_udid)"
if [[ -z "$UDID" ]]; then
  log "Creating $SIM_NAME"
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME")"
else
  log "Using existing $SIM_NAME ($UDID)"
fi

log "Booting $SIM_NAME"
boot_device "$UDID"

if [[ "$OPEN_SIMULATOR" == "1" ]]; then
  open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
fi

log "Building $SCHEME for $SIM_NAME"
xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" -destination "id=$UDID" build

SETTINGS_FILE="$(mktemp)"
trap 'rm -f "$SETTINGS_FILE"' EXIT
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$UDID" -showBuildSettings >"$SETTINGS_FILE"
TARGET_BUILD_DIR="$(show_build_setting TARGET_BUILD_DIR "$SETTINGS_FILE")"
FULL_PRODUCT_NAME="$(show_build_setting FULL_PRODUCT_NAME "$SETTINGS_FILE")"
APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

[[ -d "$APP_PATH" ]] || fail "Built app was not found at $APP_PATH"

log "Installing $APP_PATH"
xcrun simctl install "$UDID" "$APP_PATH"

log "Launching $BUNDLE_ID"
launch_app "$UDID"

log "Capturing screenshot"
sleep "$SCREENSHOT_DELAY_SECONDS"
xcrun simctl io "$UDID" screenshot "$SCREENSHOT"

printf '\nDone.\n'
printf 'Simulator: %s (%s)\n' "$SIM_NAME" "$UDID"
printf 'Screenshot: %s\n' "$SCREENSHOT"

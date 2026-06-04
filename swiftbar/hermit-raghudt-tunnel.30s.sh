#!/usr/bin/env bash

CMD="$HOME/bin/hermit-raghudt-tunnel"
APP_DIR="$HOME/Library/Application Support/Hermit"
LOG_DIR="$HOME/Library/Logs/Hermit"
ACTION_STATE="$APP_DIR/raghudt-tunnel.last-action"

last_nonempty_line() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk 'NF { line=$0 } END { if (line) print line }' "$file" 2>/dev/null | tr -d '\r'
}

first_line() {
  sed -n '1p' 2>/dev/null
}

file_first_line() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -n '1p' "$file" 2>/dev/null | tr -d '\r'
}

if [[ ! -x "$CMD" ]]; then
  echo "Hermit Tunnel: Missing | color=red"
  echo "---"
  echo "Missing command: $CMD"
  exit 0
fi

STATUS_OUTPUT="$("$CMD" status 2>&1 || true)"
STATUS_LINE="$(printf '%s\n' "$STATUS_OUTPUT" | first_line)"
LAST_ACTION="$(file_first_line "$ACTION_STATE")"
LAST_LOG="$(last_nonempty_line "$LOG_DIR/raghudt-tunnel.log")"
LAST_ERROR="$(last_nonempty_line "$LOG_DIR/raghudt-tunnel.err.log")"

if "$CMD" quiet-status >/dev/null 2>&1; then
  echo "Hermit Tunnel: On | color=green bash='$CMD' param1=swiftbar-action param2=toggle terminal=false refresh=true"
  TOGGLE_LABEL="Disable Tunnel"
  STATE_LABEL="Connected"
  STATE_COLOR="green"
elif "$CMD" loaded-status >/dev/null 2>&1; then
  echo "Hermit Tunnel: Retrying | color=orange bash='$CMD' param1=swiftbar-action param2=toggle terminal=false refresh=true"
  TOGGLE_LABEL="Stop Retry"
  STATE_LABEL="LaunchAgent loaded, not connected"
  STATE_COLOR="orange"
else
  echo "Hermit Tunnel: Off | color=red bash='$CMD' param1=swiftbar-action param2=toggle terminal=false refresh=true"
  TOGGLE_LABEL="Enable Tunnel"
  STATE_LABEL="Stopped"
  STATE_COLOR="red"
fi

echo "---"
echo "State: $STATE_LABEL | color=$STATE_COLOR"
if [[ -n "$STATUS_LINE" ]]; then
  echo "Status: $STATUS_LINE | color=$STATE_COLOR"
fi
if [[ -n "$LAST_ACTION" ]]; then
  echo "Last action: $LAST_ACTION | size=12"
fi
if [[ -n "$LAST_LOG" ]]; then
  echo "Last log: $LAST_LOG | size=12"
fi
if [[ -n "$LAST_ERROR" && "$STATE_LABEL" == "Connected" ]]; then
  echo "Previous error: $LAST_ERROR | color=gray size=12"
elif [[ -n "$LAST_ERROR" ]]; then
  echo "Last error: $LAST_ERROR | color=red size=12"
fi
echo "---"
echo "$TOGGLE_LABEL | bash='$CMD' param1=swiftbar-action param2=toggle terminal=false refresh=true"
echo "Start LaunchAgent | bash='$CMD' param1=swiftbar-action param2=start terminal=false refresh=true"
echo "Stop LaunchAgent | bash='$CMD' param1=swiftbar-action param2=stop terminal=false refresh=true"
echo "Restart | bash='$CMD' param1=swiftbar-action param2=restart terminal=false refresh=true"
echo "Clear Stale Remote Port | bash='$CMD' param1=swiftbar-action param2=clear-remote-port terminal=false refresh=true"
echo "Status | bash='$CMD' param1=swiftbar-action param2=show-status terminal=false refresh=true"
echo "Diagnose | bash='$CMD' param1=swiftbar-action param2=show-diagnose terminal=false refresh=true"
echo "Logs | bash='$CMD' param1=swiftbar-action param2=show-logs terminal=false refresh=true"

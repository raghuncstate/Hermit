#!/usr/bin/env bash

CMD="$HOME/bin/hermit-raghudt-tunnel"

if [[ -x "$CMD" ]] && "$CMD" quiet-status >/dev/null 2>&1; then
  echo "Hermit Tunnel: On | color=green bash='$CMD' param1=toggle terminal=false refresh=true"
  TOGGLE_LABEL="Disable Tunnel"
else
  echo "Hermit Tunnel: Off | color=red bash='$CMD' param1=toggle terminal=false refresh=true"
  TOGGLE_LABEL="Enable Tunnel"
fi

echo "---"
echo "$TOGGLE_LABEL | bash='$CMD' param1=toggle terminal=false refresh=true"
echo "Start LaunchAgent | bash='$CMD' param1=start terminal=false refresh=true"
echo "Stop LaunchAgent | bash='$CMD' param1=stop terminal=false refresh=true"
echo "Restart | bash='$CMD' param1=restart terminal=false refresh=true"
echo "Status | bash='$CMD' param1=status terminal=true refresh=true"
echo "Logs | bash='$CMD' param1=logs terminal=true"

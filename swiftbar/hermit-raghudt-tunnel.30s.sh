#!/usr/bin/env bash

CMD="$HOME/bin/hermit-raghudt-tunnel"

if [[ -x "$CMD" ]] && "$CMD" quiet-status >/dev/null 2>&1; then
  echo "Hermit Tunnel: On | color=green"
else
  echo "Hermit Tunnel: Off | color=red"
fi

echo "---"
echo "Start | bash='$CMD' param1=start terminal=false refresh=true"
echo "Stop | bash='$CMD' param1=stop terminal=false refresh=true"
echo "Restart | bash='$CMD' param1=restart terminal=false refresh=true"
echo "Status | bash='$CMD' param1=status terminal=true refresh=true"
echo "Logs | bash='$CMD' param1=logs terminal=true"

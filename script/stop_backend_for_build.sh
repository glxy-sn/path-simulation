#!/bin/bash
# Stop only this project's listener and its workers before replacing bundled code.
set -euo pipefail
PORT="${PRISM_SIDECAR_PORT:-8765}"
WORKSPACE="$(cd "$SRCROOT/.." && pwd -P)"
PIDS=$(/usr/sbin/lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)

stop_tree() {
    local pid="$1" child
    for child in $(/usr/bin/pgrep -P "$pid" || true); do
        stop_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

for pid in $PIDS; do
    backend_cwd=$(/usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p')
    command_line=$(/bin/ps -p "$pid" -o command=)
    case "$command_line" in
        *"$backend_cwd/server.py"*) ;;
        *) echo "error: Port $PORT belongs to an unrelated process ($pid). Stop it manually."; exit 1 ;;
    esac
    case "$backend_cwd" in
        "$WORKSPACE/be/path-simulation"|"$WORKSPACE/"*.app/Contents/Resources/backend|*/DerivedData/foodcourt-*/Build/Products/*/foodcourt.app/Contents/Resources/backend) ;;
        *) echo "error: Backend location is not owned by this project: $backend_cwd"; exit 1 ;;
    esac
    echo "Stopping previous backend PID $pid: $backend_cwd"
    stop_tree "$pid"
done

# Wait for graceful shutdown. Do not force-kill or start a second server.
for attempt in {1..50}; do
    if ! /usr/sbin/lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Backend port $PORT is free. The app will start the freshly bundled backend on launch."
        exit 0
    fi
    sleep 0.1
done
echo "error: Backend port $PORT is still occupied after shutdown."
exit 1

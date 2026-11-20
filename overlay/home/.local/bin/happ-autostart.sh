#!/usr/bin/env bash
set -u

for _ in {1..50}; do
    if busctl --user list 2>/dev/null | grep -q '^org\.kde\.StatusNotifierWatcher[[:space:]]'; then
        break
    fi
    sleep 0.2
done

exec /opt/happ/bin/Happ --autostart

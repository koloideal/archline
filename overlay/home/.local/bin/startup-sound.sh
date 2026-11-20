#!/usr/bin/env bash
set -u

sound="$HOME/.config/hypr/sounds/startup.m4a"
[[ -f "$sound" ]] || exit 0

for _ in {1..50}; do
    pactl info >/dev/null 2>&1 && break
    sleep 0.2
done
pactl info >/dev/null 2>&1 || exit 0

exec timeout 4s ffplay -nodisp -autoexit -loglevel error -t 2 "$sound" >/dev/null 2>&1

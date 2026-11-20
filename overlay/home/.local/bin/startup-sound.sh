#!/usr/bin/env bash
set -u

sound="$HOME/.config/hypr/sounds/startup.m4a"
[[ -f "$sound" ]] || exit 0

for _ in {1..50}; do
    pactl info >/dev/null 2>&1 && break
    sleep 0.2
done
pactl info >/dev/null 2>&1 || exit 0

old_volume="$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -o '[0-9]\+%' | head -n 1 | tr -d '%')"
old_mute=0
pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -q 'yes' && old_mute=1

pactl set-sink-mute @DEFAULT_SINK@ 0 >/dev/null 2>&1 || true
pactl set-sink-volume @DEFAULT_SINK@ 85% >/dev/null 2>&1 || true

timeout 4s ffplay -nodisp -autoexit -loglevel error -t 2 "$sound" >/dev/null 2>&1 || true

[[ -n "$old_volume" ]] && pactl set-sink-volume @DEFAULT_SINK@ "$old_volume%" >/dev/null 2>&1 || true
pactl set-sink-mute @DEFAULT_SINK@ "$old_mute" >/dev/null 2>&1 || true

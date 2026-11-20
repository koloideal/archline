#!/usr/bin/env bash
set -u

sound="$HOME/.config/hypr/sounds/startup.wav"
log="$HOME/.cache/startup-sound.log"
exec >"$log" 2>&1
echo "== $(date -Is) =="

[[ -f "$sound" ]] || { echo "no sound file"; exit 0; }

# wait for the PipeWire pulse socket
for _ in {1..75}; do
    pactl info >/dev/null 2>&1 && break
    sleep 0.2
done
pactl info >/dev/null 2>&1 || { echo "pactl never came up"; exit 0; }

# wait for a real default sink (not the early-boot auto_null dummy)
sink=''
for _ in {1..75}; do
    sink="$(pactl get-default-sink 2>/dev/null || true)"
    [[ -n "$sink" && "$sink" != *auto_null* && "$sink" != *Dummy* ]] && break
    sleep 0.2
done
echo "sink=${sink:-none}"
[[ -n "$sink" && "$sink" != *auto_null* && "$sink" != *Dummy* ]] || exit 0

old_volume="$(pactl get-sink-volume "$sink" 2>/dev/null | grep -o '[0-9]\+%' | head -n 1 | tr -d '%')"
old_mute="$(pactl get-sink-mute "$sink" 2>/dev/null | grep -q 'yes' && echo 1 || echo 0)"
echo "old_volume=$old_volume old_mute=$old_mute"

pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true
pactl set-sink-volume "$sink" 100% >/dev/null 2>&1 || true

timeout 5s pw-play --volume=1.0 --target="$sink" "$sound"
echo "pw-play exit=$?"

[[ -n "$old_volume" ]] && pactl set-sink-volume "$sink" "$old_volume%" >/dev/null 2>&1 || true
pactl set-sink-mute "$sink" "${old_mute:-0}" >/dev/null 2>&1 || true

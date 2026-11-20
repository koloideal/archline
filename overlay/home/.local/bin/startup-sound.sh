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

timeout 5s pw-play --volume=0.85 --target="$sink" "$sound"
echo "pw-play exit=$?"

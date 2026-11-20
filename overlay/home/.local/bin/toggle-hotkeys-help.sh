#!/usr/bin/env bash
set -u

class='hotkeys-help'
file="$HOME/.config/hypr/hotkeys.txt"
keymap="$HOME/.config/hypr/hotkeys.lesskey"

pids="$(hyprctl clients 2>/dev/null | awk -v cls="$class" '
    /^[[:space:]]*class:[[:space:]]*/ { matched = ($2 == cls) }
    /^[[:space:]]*pid:[[:space:]]*/ && matched { print $2 }
')"
if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 0.2
    for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    exit 0
fi

[[ -f "$file" ]] || exit 0
less_args=(-R "$file")
[[ -f "$keymap" ]] && less_args=(-R --lesskey-src="$keymap" "$file")
kitty --class "$class" --title 'Hyprland hotkeys' \
    less "${less_args[@]}" >/dev/null 2>&1 &

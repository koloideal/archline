#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "cycle" ]]; then
    current="$(powerprofilesctl get 2>/dev/null || printf 'balanced')"
    case "$current" in
        power-saver) powerprofilesctl set balanced ;;
        balanced)    powerprofilesctl set performance ;;
        *)           powerprofilesctl set power-saver ;;
    esac
    exit 0
fi

current="$(powerprofilesctl get 2>/dev/null || printf 'balanced')"
case "$current" in
    power-saver)  icon='󰌪'; label='saver'; class='saver' ;;
    balanced)     icon='󰾅'; label='bal'; class='balanced' ;;
    performance)  icon='󰓅'; label='perf'; class='performance' ;;
    *)            icon='󰾅'; label='bal'; class='balanced' ;;
esac

printf '{"text":"%s %s","tooltip":"power profile: %s — click to cycle","class":"%s"}\n' \
    "$icon" "$label" "$current" "$class"

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
    power-saver)  icon='󰌪'; class='saver' ;;
    balanced)     icon='󰾅'; class='balanced' ;;
    performance)  icon='󰓅'; class='performance' ;;
    *)            icon='󰾅'; class='balanced' ;;
esac

printf '{"text":"%s","tooltip":"power profile: %s — click to cycle","class":"%s"}\n' \
    "$icon" "$current" "$class"

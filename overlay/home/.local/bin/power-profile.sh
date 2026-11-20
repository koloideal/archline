#!/usr/bin/env bash
set -u

emit() {
    current="$(powerprofilesctl get 2>/dev/null || printf 'balanced')"
    case "$current" in
        power-saver)  icon='󰌪'; label='quiet'; class='saver' ;;
        balanced)     icon='󰾅'; label='bal'; class='balanced' ;;
        performance)  icon='󰓅'; label='perf'; class='performance' ;;
        *)            icon='󰾅'; label='bal'; class='balanced' ;;
    esac

    printf '{"text":"%s %s","tooltip":"power profile: %s — click to cycle","class":"%s"}\n' \
        "$icon" "$label" "$current" "$class"
}

if [[ "${1:-}" == "cycle" ]]; then
    current="$(powerprofilesctl get 2>/dev/null || printf 'balanced')"
    case "$current" in
        power-saver) powerprofilesctl set balanced ;;
        balanced)    powerprofilesctl set performance ;;
        *)           powerprofilesctl set power-saver ;;
    esac
    exit 0
fi

pidfile="${XDG_RUNTIME_DIR:-/tmp}/waybar-power-profile.pgid"
currentpgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
if [[ -f "$pidfile" ]]; then
    oldpgid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ "$oldpgid" =~ ^[0-9]+$ && "$oldpgid" != "$currentpgid" ]] && \
       ps -eo pgid=,cmd= | awk -v pgid="$oldpgid" '$1 == pgid' | \
       grep -Eq 'power-profile\.sh|gdbus monitor --system --dest net\.hadess\.PowerProfiles'; then
        kill -TERM -- "-$oldpgid" 2>/dev/null || true
        sleep 0.1
    fi
fi
printf '%s\n' "$currentpgid" > "$pidfile"

emit
while true; do
    stdbuf -oL gdbus monitor --system \
        --dest net.hadess.PowerProfiles \
        --object-path /net/hadess/PowerProfiles 2>/dev/null |
    while IFS= read -r line; do
        [[ "$line" == *"'ActiveProfile'"* ]] && emit
    done
    sleep 1
    emit
done

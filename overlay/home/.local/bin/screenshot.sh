#!/usr/bin/env bash
set -u

mode="${1:-full}"
pictures="$(xdg-user-dir PICTURES 2>/dev/null || printf '%s' "$HOME/Pictures")"
dir="$pictures/Screenshots"
mkdir -p "$dir"

base="$dir/$(date +%Y-%m-%d_%H-%M-%S).png"
file="$base"
for i in {1..99}; do
    [[ ! -e "$file" ]] && break
    file="${base%.png}-$i.png"
done

case "$mode" in
    full)
        grim "$file" || exit 1
        ;;
    area)
        geometry="$(slurp 2>/dev/null)" || exit 0
        [[ -n "$geometry" ]] || exit 0
        grim -g "$geometry" "$file" || exit 1
        ;;
    *)
        echo "usage: $0 [full|area]" >&2
        exit 2
        ;;
esac

wl-copy < "$file" 2>/dev/null || true
notify-send -i "$file" 'Скриншот сохранён' "$file\nСкопирован в буфер обмена" 2>/dev/null || true
printf '%s\n' "$file"

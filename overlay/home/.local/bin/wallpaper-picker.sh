#!/usr/bin/env bash
set -u

monitor='eDP-1'
conf="$HOME/.config/hypr/hyprpaper.conf"
roots=("$HOME/Pictures/wallpapers" "$HOME/.config/hypr/wallpapers")

choice="$(
    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        find "$root" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
            -printf 'img:%p:text:%P\n'
    done | sort -t: -k4 | wofi --dmenu --allow-images -i -p 'Wallpaper' -W 900 -H 600 -L 12
)"
[[ -z "$choice" ]] && exit 0

path="${choice#img:}"
path="${path%%:text:*}"
[[ -f "$path" ]] || exit 0

hyprctl hyprpaper wallpaper "$monitor,$path" >/dev/null 2>&1 || true
cat > "$conf" <<EOF
ipc = on
wallpaper {
	monitor = 
	path = $path
	fit_mode = cover
}
splash = false
EOF

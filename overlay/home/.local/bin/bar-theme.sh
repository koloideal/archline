#!/usr/bin/env bash
# Подстраивает фон островков waybar под обои:
# тёмные обои -> кремовые островки, светлые -> тёмные; лёгкий тинт доминантным цветом.
set -u
wp="${1:-$(cat "$HOME/.config/hypr/wallpaper" 2>/dev/null || true)}"
[[ -f "$wp" ]] || exit 0

python3 - "$wp" "$HOME/.config/hypr/colors.css" <<'PY'
import sys
import gi
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import GdkPixbuf

wp, out = sys.argv[1], sys.argv[2]
pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(wp, 1, 1, True)
r, g, b = pb.get_pixels()[0:3]
lum = 0.2126*r + 0.7152*g + 0.0722*b

if lum < 110:                      # тёмные обои -> кремовые островки
    base_bg, fg, power = (235, 219, 178), 'rgb(40, 40, 40)', '#cc241d'
else:                              # светлые обои -> тёмные островки
    base_bg, fg, power = (40, 40, 40), 'rgb(235, 219, 178)', '#D65D0E'

bg = tuple(round(bx*0.85 + dx*0.15) for bx, dx in zip(base_bg, (r, g, b)))

# fg пишем литеральными правилами: GTK-переменные для свойства color не резолвятся
with open(out, 'w', encoding='utf-8') as f:
    f.write(f'@define-color color_bg rgb{bg};\n')
    f.write(f'@define-color color_fg {fg};\n')
    f.write('@define-color color_accent #D65D0E;\n')
    f.write(f'''
#custom-power,
#workspaces,
#clock,
#pulseaudio,
#backlight,
#network,
#battery,
#custom-powerprofile,
#language,
#tray,
#custom-happ {{
    color: {fg};
}}

#workspaces button,
#workspaces button label {{
    color: {fg};
}}

#workspaces button.active {{
    border-bottom-color: {fg};
}}

#custom-power {{
    color: {power};
}}

#tray menu {{
    background: rgb{bg};
    color: {fg};
}}
''')
PY

# waybar следит за style.css через inotify: touch (только mtime) и sed -i
# (новый inode) не вызывают мгновенную перезагрузку — пишем в тот же inode.
if [[ $? -eq 0 ]]; then
    css="$HOME/.config/hypr/waybar/style.css"
    { grep -v '/\* theme:' "$css"; printf '/* theme:%s */\n' "$(date +%s%N)"; } > "$css.tmp"
    cat "$css.tmp" > "$css" && rm -f "$css.tmp"
fi

#!/usr/bin/env bash
# Собирает конфиги текущей системы в dotfiles/home.tar.gz (tar сохраняет права на exFAT-флешке).
# Систему не меняет.
# Поверх собранного накладывается overlay/home (ручные файлы: hyprland.lua и т.п.).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(mktemp -d)"
trap 'rm -rf "$DEST"' EXIT
SRC="$HOME"

PATHS=(
  .config/hypr
  .config/kitty
  .config/gtk-3.0
  .config/gtk-4.0
  .config/Kvantum
  .config/qt5ct
  .config/qt6ct
  .config/nwg-look
  .config/xsettingsd
  .config/fastfetch
  .config/hyfetch.json
  .config/macchina
  .config/btop
  .config/Thunar
  .config/xfce4
  .config/mimeapps.list
  .config/user-dirs.dirs
  .config/user-dirs.locale
  .config/autostart/org.telegram.desktop.desktop
  .config/zed/settings.json
  .config/zed/themes
  .config/qimgv
  .config/xarchiver
  .config/pavucontrol.ini
  .config/menus
  .local/share/applications/chrome-focus.desktop
  .zshrc
  .zfunc
  .zshalias
  .gtkrc-2.0
  .gitconfig
)

# Заменены Lua-конфигом (overlay/home/.config/hypr/hyprland.lua) или не нужны в бандле:
# привязаны к конкретной машине (state-файлы, закладки, старый wallpaper-бэкенд).
LEGACY=(
  .config/hypr/hyprland.conf
  .config/hypr/monitors.conf
  .config/hypr/workspaces.conf
  .config/hypr/scripts/workspace-setup.sh
  .config/hypr/hyprpaper.conf
  .config/hypr/wallpaper
  .config/gtk-3.0/bookmarks
  .config/qimgv/savedState.conf
)


for p in "${PATHS[@]}"; do
  if [[ -e "$SRC/$p" ]]; then
    mkdir -p "$DEST/$(dirname "$p")"
    cp -a "$SRC/$p" "$DEST/$p"
  else
    echo "skip (нет): $p" >&2
  fi
done

for p in "${LEGACY[@]}"; do rm -f "$DEST/$p"; done
rmdir "$DEST/.config/hypr/scripts" 2>/dev/null || true

mkdir -p "$DEST/.local/share/tg-theme"
if [[ -f "$SRC/Downloads/gruvbox.tdesktop-theme" ]]; then
  cp -a "$SRC/Downloads/gruvbox.tdesktop-theme" "$DEST/.local/share/tg-theme/"
else
  echo "skip (нет): Downloads/gruvbox.tdesktop-theme" >&2
fi

# zshrc: строки, которые падают, если uv/mise не стоят
sed -i \
  -e 's|^\. "\$HOME/\.local/share/\.\./bin/env"$|[[ -f "$HOME/.local/bin/env" ]] \&\& . "$HOME/.local/bin/env"|' \
  -e 's|^eval "\$(mise activate zsh)"$|command -v mise \&>/dev/null \&\& eval "$(mise activate zsh)"|' \
  "$DEST/.zshrc"

cp -a "$ROOT/overlay/home/." "$DEST/"

mkdir -p "$ROOT/dotfiles"
rm -rf "$ROOT/dotfiles/home"
tar -C "$DEST" -czf "$ROOT/dotfiles/home.tar.gz" .
echo "Готово: $(du -sh "$ROOT/dotfiles/home.tar.gz" | cut -f1) в $ROOT/dotfiles/home.tar.gz"

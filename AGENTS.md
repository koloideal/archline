# Relocatable_Arch

Переносит сетап Arch + Hyprland с текущего ноута (ohmyarch, kolo) на Lenovo LOQ 15IAX9 (barelkvaza@myarchbtw).

- `collect.sh` — собирает конфиги из $HOME в `dotfiles/home.tar.gz`, поверх кладёт `overlay/home`. Систему не меняет.
- `overlay/home` — файлы, написанные руками: `hyprland.lua` (Lua-конфиг, Hyprland >= 0.55), `hypridle.conf`, Waybar `config.jsonc`/`style.css`, `power-menu.sh`, `power-profile.sh`, `happ-autostart.sh` + `autostart/Happ.desktop`, `chrome-focus.sh`, конфиг gammastep. Автологин без greeter'а; пароль только на `Super+L`/`hyprlock`.
- `install.sh` — запускается из live-ISO от root, стирает выбранный диск и ставит всё.
- Пакеты: `packages/pacman.txt`, `packages/aur.txt`.

Проверка:
- `bash -n install.sh collect.sh`, shellcheck `-S warning`
- `Hyprland --verify-config -c overlay/home/.config/hypr/hyprland.lua` (ошибки ловит реально)
- После правок пересобрать: `./collect.sh`, затем скопировать бандл в `/run/media/kolo/Ventoy/Relocatable_Arch`.

С Lua-конфигом `hyprctl dispatch` принимает Lua: `hyprctl dispatch 'hl.dsp.focus({ workspace = 1 })'`.

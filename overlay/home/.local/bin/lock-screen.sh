#!/usr/bin/env bash
# hyprlock не трогает раскладку: если залочил в RU, пароль набирается
# кириллицей и не проходит. Перед блокировкой ставим первую раскладку (us) —
# пароль в любом случае задавался в ней. Вернуть ru можно после входа
# через Caps Lock.
pidof hyprlock >/dev/null && exit 0
hyprctl switchxkblayout all 0 >/dev/null 2>&1 || true
exec hyprlock

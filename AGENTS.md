# myArch

Переносимая сборка Arch Linux + Hyprland: репозиторий разворачивается
в полноценную систему на любой машине через `install.sh` с live-ISO.
Никаких жёстко зашитых имён пользователей, домашних путей,
geo-координат или названий дисплеев — всё спрашивается при установке
или определяется автоматически.

- `collect.sh` — собирает конфиги из `$HOME` в `dotfiles/home.tar.gz`,
  поверх кладёт `overlay/home`. Систему не меняет. Машинно-зависимые
  файлы (закладки GTK, state-файлы, старые конфиги) выкидываются
  через список `LEGACY`.
- `overlay/home` — файлы, написанные руками: `hyprland.lua`
  (Lua-конфиг, Hyprland >= 0.55), `hypridle.conf`, `hyprlock.conf`
  приходит из собранных, Waybar `config.jsonc`/`style.css`,
  `power-menu.sh`, `power-profile.sh`, `happ-autostart.sh` +
  `autostart/Happ.desktop`, `startup-sound.sh` + `sounds/startup.wav`,
  `toggle-hotkeys-help.sh` + `hotkeys.txt`/`hotkeys.lesskey`,
  `wallpapers/girl-2.png` (дефолт; `~/.config/hypr/wallpaper` хранит
  выбранный путь и в бандл не входит), `wallpaper-picker.py`
  (GTK4-сетка, awww live-превью, `--warm`/`--restore` на старте),
  `lock-screen.sh` (us-раскладка перед hyprlock), `chrome-focus.sh`, конфиг gammastep (geoclue2). Автологин без
  greeter-окна; пароль только на `Super+L`/`hyprlock`.
- `install.sh` — запускается из live-ISO от root, стирает выбранный
  диск и ставит всё. Имя пользователя/hostname/часовой пояс спрашивает
  или берёт из `RA_USERNAME`, `RA_HOSTNAME`, `RA_TZ`. После развёртки
  бандла переписывает все `/home/<старое>` на `/home/<новый>`.
- Пакеты: `packages/pacman.txt`, `packages/aur.txt`.

Проверка:
- `bash -n install.sh collect.sh`, shellcheck `-S warning`
- `Hyprland --verify-config -c overlay/home/.config/hypr/hyprland.lua` (ошибки ловит реально)
- После правок пересобрать: `./collect.sh` — заодно проверяет, что
  в бандл не просочились `/home/<имя>`: `tar -xzf dotfiles/home.tar.gz`
  в tmp и `grep -rn '/home/'`.

С Lua-конфигом `hyprctl dispatch` принимает Lua: `hyprctl dispatch 'hl.dsp.focus({ workspace = 1 })'`.

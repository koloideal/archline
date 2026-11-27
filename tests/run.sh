#!/usr/bin/env bash
# E2E-тесты archline: реальный пайплайн collect.sh → бандл → развёртка,
# функциональные проверки install.sh (через source с RA_FUNCS_ONLY=1),
# целостность ссылок в конфигах и валидность пакетных списков.
# Запуск: bash tests/run.sh   (из корня репы или откуда угодно)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
step() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# source install.sh без запуска установки — только в подшелле
src() { RA_FUNCS_ONLY=1 source "$ROOT/install.sh"; }

T="$(mktemp -d)"
archline_bootstrap_ran=0
cleanup() {
  if (( archline_bootstrap_ran )); then rm -rf /tmp/archline; fi
  rm -rf "$T"
}
trap cleanup EXIT

bundle_hash_before="$(sha256sum dotfiles/home.tar.gz 2>/dev/null | cut -d' ' -f1)"

gsettings_state() {
  command -v gsettings >/dev/null 2>&1 || return 0
  local schema key
  while read -r schema key; do
    printf '%s/%s=' "$schema" "$key"
    gsettings get "$schema" "$key" 2>/dev/null || printf '<unavailable>'
    printf '\n'
  done <<'EOF'
org.gnome.desktop.interface gtk-theme
org.gnome.desktop.interface icon-theme
org.gnome.desktop.interface font-name
org.gnome.desktop.interface cursor-theme
org.gnome.desktop.interface color-scheme
org.gnome.desktop.input-sources sources
EOF
}

gsettings_before="$(gsettings_state)"

verify_hyprland() {
  local cfg="$ROOT/overlay/home/.config/hypr/hyprland.lua"
  local fakehome="$T/verify-home" rundir="$T/verify-runtime" bindir="$T/verify-bin"
  mkdir -p "$fakehome" "$rundir" "$bindir"
  chmod 700 "$rundir"
  cat > "$bindir/gsettings" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$bindir/gsettings"

  if command -v dbus-run-session >/dev/null 2>&1; then
    env HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" \
      XDG_CACHE_HOME="$fakehome/.cache" XDG_STATE_HOME="$fakehome/.local/state" \
      XDG_RUNTIME_DIR="$rundir" PATH="$bindir:$PATH" \
      dbus-run-session -- Hyprland --verify-config -c "$cfg"
  else
    env -u DBUS_SESSION_BUS_ADDRESS HOME="$fakehome" \
      XDG_CONFIG_HOME="$fakehome/.config" XDG_CACHE_HOME="$fakehome/.cache" \
      XDG_STATE_HOME="$fakehome/.local/state" XDG_RUNTIME_DIR="$rundir" \
      PATH="$bindir:$PATH" Hyprland --verify-config -c "$cfg"
  fi
}

# ---------- Синтаксис ----------
step "Синтаксис скриптов"
check "bash -n install.sh"    'bash -n install.sh'
check "bash -n collect.sh"    'bash -n collect.sh'
check "bash -n sync-repo.sh"  'bash -n sync-repo.sh'
check "bash -n screenshot.sh" 'bash -n overlay/home/.local/bin/screenshot.sh'
check "clipboard-menu.py syntax" 'python3 -c "import ast; ast.parse(open(\"overlay/home/.local/bin/clipboard-menu.py\").read())"'
check "clipboard без wofi" '! grep -qi wofi overlay/home/.local/bin/clipboard-menu.py'
check "clipboard window rule" 'grep -q "dev.clipboard.menu" overlay/home/.config/hypr/hyprland.lua'
check "cliphist в pacman.txt" 'grep -qw cliphist packages/pacman.txt'

# ---------- collect.sh → бандл ----------
step "collect.sh → бандл"
check "committed home.tar.gz есть" '[[ -f dotfiles/home.tar.gz ]]'
mkdir -p "$T/committed" "$T/fresh" "$T/collect-src" "$T/deploy"
tar -xzf dotfiles/home.tar.gz -C "$T/committed"
cp -a collect.sh overlay "$T/collect-src/"

if (cd "$T/collect-src" && ./collect.sh >/dev/null 2>&1); then
  ok "collect.sh отрабатывает в изолированной копии"
else
  bad "collect.sh отрабатывает в изолированной копии"
fi
check "fresh home.tar.gz собран" '[[ -f $T/collect-src/dotfiles/home.tar.gz ]]'
if [[ -f "$T/collect-src/dotfiles/home.tar.gz" ]]; then
  tar -xzf "$T/collect-src/dotfiles/home.tar.gz" -C "$T/fresh"
  collect_diff="$(diff -qr --no-dereference "$T/committed" "$T/fresh" 2>&1 || true)"
else
  collect_diff="fresh bundle missing"
fi
# Живая система может осознанно расходиться с репозиторием: синхронизация
# бандла — отдельное ручное решение, поэтому drift показываем как warning.
if [[ -z "$collect_diff" ]]; then
  ok "committed bundle свежий"
else
  warn "committed bundle отстаёт от живой системы"
  printf '%s\n' "$collect_diff" \
    | sed -e "s#$T/committed#COMMITTED#g" -e "s#$T/fresh#FRESH#g" \
    | head -20
fi

B="$T/committed"
check "hyprland.lua в бандле"   '[[ -f $B/.config/hypr/hyprland.lua ]]'
check "clipboard-menu.py в бандле" '[[ -x $B/.local/bin/clipboard-menu.py ]]'
check "screenshot.sh в бандле"  '[[ -x $B/.local/bin/screenshot.sh ]]'
check "clipboard.css в бандле"  '[[ -f $B/.config/hypr/wofi/clipboard.css ]]'
check "стартовых обоев >= 8"    '[[ $(find $B/Pictures/wallpapers -type f | wc -l) -ge 8 ]]'
check "дефолтная обоина"        '[[ -f $B/.config/hypr/wallpapers/girl-2.png ]]'
check "все .local/bin +x"       '[[ $(find $B/.local/bin -type f ! -perm -u+x | wc -l) -eq 0 ]]'
check "нет .gitconfig"          '! find $B -name .gitconfig | grep -q .'
check "нет tdata телеги"        '! find $B -type d -name tdata | grep -q .'
check "нет gtk-закладок"        '! find $B -name bookmarks | grep -q .'
check "нет /home/s3rius"        '! grep -rlI "/home/s3rius" $B | grep -q .'
check "нет /home/barelkvaza"    '! grep -rlI "/home/barelkvaza" $B | grep -q .'

# /home/<автор> в wofi/desktop — штатно переписывается при установке:
# симулируем деплой и проверяем, что старых путей не осталось
cp -a "$B/." "$T/deploy/"
( RA_FUNCS_ONLY=1 source "$ROOT/install.sh"; USERNAME=newuser
  rewrite_home_paths "$T/deploy" >/dev/null 2>&1 )
check "после rewrite нет старых /home" \
  '! grep -rlIE "/home/(kolo|s3rius|barelkvaza|olduser)" $T/deploy | grep -q .'

# ---------- Конфиги ----------
step "Конфиги"
top_exec="$(grep -E '^hl\.exec_cmd\(' overlay/home/.config/hypr/hyprland.lua \
  | grep -vE '^hl\.exec_cmd\("gsettings ' || true)"
check "top-level exec только gsettings" '[[ -z "$top_exec" ]]'
if [[ -n "$top_exec" ]]; then printf '%s\n' "$top_exec"; fi

if verify_hyprland >"$T/hyprland-verify.log" 2>&1; then
  ok "hyprland.lua --verify-config изолированно"
else
  bad "hyprland.lua --verify-config изолированно"
  sed -n '1,80p' "$T/hyprland-verify.log"
fi

# скрипты, на которые ссылается lua через ~/.local/bin/, должны быть в overlay
missing=$(grep -oP 'local/bin/\K[A-Za-z0-9._-]+' overlay/home/.config/hypr/hyprland.lua \
  | sort -u | while read -r b; do
    [[ "$b" == firstrun.sh ]] && continue   # генерится в deploy_dotfiles
    [[ -e "overlay/home/.local/bin/$b" ]] || echo "$b"; done)
check "все ~/.local/bin из lua есть в overlay" '[[ -z "$missing" ]]'

# ---------- install.sh: функции ----------
step "install.sh: pkgs"
check "pkgs >100 пакетов"       '[[ $(src; pkgs packages/pacman.txt | wc -w) -gt 100 ]]'
check "комментарии отфильтраны" '[[ $(src; pkgs packages/pacman.txt | grep -c "#") -eq 0 ]]'

step "install.sh: apply_gpu_filter"
out=$(src; HAS_NVIDIA=0; HAS_AMDGPU=0; apply_gpu_filter "mesa nvidia-open-dkms nvidia-utils egl-wayland libva-nvidia-driver base" 2>/dev/null)
check "без NVIDIA → nvidia вырезан" '! grep -q nvidia <<< "$out"'
out=$(src; HAS_NVIDIA=1; HAS_AMDGPU=0; apply_gpu_filter "mesa nvidia-utils base")
check "с NVIDIA → остаётся"         'grep -q nvidia-utils <<< "$out"'
out=$(src; HAS_NVIDIA=0; HAS_AMDGPU=1; apply_gpu_filter "mesa base")
check "AMD → +vulkan-radeon"        'grep -q vulkan-radeon <<< "$out"'

step "install.sh: choose_repo"
mkdir -p "$T/repo" && touch "$T/repo/archline.db.tar.gz"
# choose_repo <<< 'x': here-string, не пайп — иначе функция уйдёт в подшелл
# и переменные потеряются. set +e/trap - ERR: source'нутый -e+trap не мешает.
r=$(src; set +e; trap - ERR; REPO_DIR="$T/repo"; REPO_DB="$T/repo/archline.db.tar.gz"
    online(){ return 1; }; choose_repo <<< 'n' >/dev/null 2>&1; echo "$USE_LOCAL_REPO")
check "нет сети + пул → local"        '[[ "$r" = 1 ]]'
r=$(src; set +e; trap - ERR; REPO_DIR="$T/repo"; REPO_DB="$T/repo/archline.db.tar.gz"
    online(){ return 0; }; choose_repo <<< '1' >/dev/null 2>&1; echo "$USE_LOCAL_REPO")
check "сеть + выбор пула → local"     '[[ "$r" = 1 ]]'
r=$(src; set +e; trap - ERR; REPO_DIR="$T/repo"; REPO_DB="$T/repo/archline.db.tar.gz"
    online(){ return 0; }; choose_repo <<< '2' >/dev/null 2>&1; echo "$USE_LOCAL_REPO")
check "сеть + выбор сети → online"    '[[ "$r" = 0 ]]'
r=$(src; RA_REPO=online; online(){ return 1; }
    choose_repo >/dev/null 2>&1; echo "$USE_LOCAL_REPO" || true)
check "RA_REPO=online без сети → die" '[[ -z "$r" ]]'
r=$(src; RA_REPO=local; online(){ return 1; }
    choose_repo >/dev/null 2>&1; echo "$USE_LOCAL_REPO" || true)
check "RA_REPO=local без пула → die"  '[[ -z "$r" ]]'

step "install.sh: оффлайн pacman.conf"
( src; USE_LOCAL_REPO=1; REPO_DIR="$T/repo"; REPO_CONF="$T/pac.conf"
  timedatectl(){ :; }; prepare_live >/dev/null 2>&1 )
check "Server=file://пул"  'grep -q "Server = file://$T/repo" $T/pac.conf'
check "SigLevel = Never"   'grep -q "SigLevel = Never" $T/pac.conf'
check "без официальных реп" '! grep -q "^\[core\]" $T/pac.conf'

step "install.sh: rewrite_home_paths"
mkdir -p "$T/home/.config/x" "$T/home/Pictures"
echo 'bg=/home/olduser/wp.png' > "$T/home/.config/x/f.conf"
echo '/home/olduser/keep'      > "$T/home/Pictures/keep.txt"
( src; USERNAME=newuser; rewrite_home_paths "$T/home" )
check "путь → новый юзер"  'grep -q "/home/newuser" $T/home/.config/x/f.conf'
check "Pictures пропущен"  'grep -q olduser $T/home/Pictures/keep.txt'

step "install.sh: бутстрап без репозитория"
mkdir -p "$T/fake" "$T/bin"
cp install.sh "$T/fake/"
cat > "$T/bin/git" <<G
#!/bin/bash
[[ "\$1" == clone ]] && cp -r "$ROOT" "\${@: -1}"
G
chmod +x "$T/bin/git"
if [[ -e /tmp/archline ]]; then
  echo "  (бутстрап-тест пропущен: /tmp/archline уже существует)"
else
  archline_bootstrap_ran=1
  out="$(PATH="$T/bin:$PATH" bash "$T/fake/install.sh" 2>&1 || true)"
  check "клонирует в /tmp/archline" 'grep -q "Клонирую archline" <<< "$out"'
  check "доходит до preflight"      'grep -q "Запусти от root\|UEFI\|Secure Boot" <<< "$out"'
fi

# ---------- Пакетные списки ----------
step "pacman.txt: все пакеты существуют"
not_found=$(src; set +e; trap - ERR; pkgs packages/pacman.txt | tr ' ' '\n' \
  | while read -r p; do pacman -Si "$p" >/dev/null 2>&1 || echo "$p"; done)
check "все pacman-пакеты в репах" '[[ -z "$not_found" ]]'

if curl -fsI --max-time 5 https://aur.archlinux.org >/dev/null 2>&1; then
  bad_aur=$(src; set +e; trap - ERR; pkgs packages/aur.txt | tr ' ' '\n' \
    | while read -r p; do
        curl -fs "https://aur.archlinux.org/rpc/v5/info/$p" 2>/dev/null \
          | grep -q '"resultcount":0' && echo "$p"
      done)
  check "aur.txt пакеты существуют в AUR" '[[ -z "$bad_aur" ]]'
else
  echo "  (AUR-проверка пропущена: нет сети)"
fi

# ---------- Изоляция ----------
step "Изоляция тестов"
bundle_hash_after="$(sha256sum dotfiles/home.tar.gz 2>/dev/null | cut -d' ' -f1)"
check "committed bundle не изменён" '[[ "$bundle_hash_after" == "$bundle_hash_before" ]]'
check "gsettings не изменились"      '[[ "$(gsettings_state)" == "$gsettings_before" ]]'

# ---------- Итог ----------
echo
if (( FAIL )); then
  printf '\033[31m✗ %d провалено, %d ок\033[0m\n' "$FAIL" "$PASS"
  exit 1
else
  printf '\033[32m✓ все %d тестов прошли\033[0m\n' "$PASS"
fi

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
step() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# source install.sh без запуска установки — только в подшелле
src() { RA_FUNCS_ONLY=1 source "$ROOT/install.sh"; }

T="$(mktemp -d)"
trap 'rm -rf "$T" /tmp/archline' EXIT

# ---------- Синтаксис ----------
step "Синтаксис скриптов"
check "bash -n install.sh"    'bash -n install.sh'
check "bash -n collect.sh"    'bash -n collect.sh'
check "bash -n sync-repo.sh"  'bash -n sync-repo.sh'

# ---------- collect.sh → бандл ----------
step "collect.sh → бандл"
if ./collect.sh >/dev/null 2>&1; then ok "collect.sh отрабатывает"; else bad "collect.sh отрабатывает"; fi
check "home.tar.gz собран"      '[[ -f dotfiles/home.tar.gz ]]'
tar -xzf dotfiles/home.tar.gz -C "$T"

check "hyprland.lua в бандле"   '[[ -f $T/.config/hypr/hyprland.lua ]]'
check "стартовых обоев >= 8"    '[[ $(find $T/Pictures/wallpapers -type f | wc -l) -ge 8 ]]'
check "дефолтная обоина"        '[[ -f $T/.config/hypr/wallpapers/girl-2.png ]]'
check "все .local/bin +x"       '[[ $(find $T/.local/bin -type f ! -perm -u+x | wc -l) -eq 0 ]]'
check "нет .gitconfig"          '! find $T -name .gitconfig | grep -q .'
check "нет tdata телеги"        '! find $T -type d -name tdata | grep -q .'
check "нет gtk-закладок"        '! find $T -name bookmarks | grep -q .'
check "нет /home/s3rius"        '! grep -rlI "/home/s3rius" $T | grep -q .'
check "нет /home/barelkvaza"    '! grep -rlI "/home/barelkvaza" $T | grep -q .'

# /home/<автор> в wofi/desktop — штатно переписывается при установке:
# симулируем деплой и проверяем, что старых путей не осталось
( RA_FUNCS_ONLY=1 source "$ROOT/install.sh"; USERNAME=newuser
  rewrite_home_paths "$T" >/dev/null 2>&1 )
check "после rewrite нет старых /home" \
  '! grep -rlIE "/home/(kolo|s3rius|barelkvaza|olduser)" $T | grep -q .'

# ---------- Конфиги ----------
step "Конфиги"
check "hyprland.lua --verify-config" \
  'Hyprland --verify-config -c overlay/home/.config/hypr/hyprland.lua'

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
out="$(PATH="$T/bin:$PATH" bash "$T/fake/install.sh" 2>&1 || true)"
check "клонирует в /tmp/archline" 'grep -q "Клонирую archline" <<< "$out"'
check "доходит до preflight"      'grep -q "Запусти от root\|UEFI\|Secure Boot" <<< "$out"'

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

# ---------- Итог ----------
echo
if (( FAIL )); then
  printf '\033[31m✗ %d провалено, %d ок\033[0m\n' "$FAIL" "$PASS"
  exit 1
else
  printf '\033[32m✓ все %d тестов прошли\033[0m\n' "$PASS"
fi

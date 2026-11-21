#!/usr/bin/env bash
# Собирает оффлайн-пул пакетов repo/ для install.sh.
# Запускать на рабочей системе (НЕ на live-ISO), обычным пользователем —
# sudo спросит пароль для pacman -Sy/-Sw.
#
#  1. packages/pacman.txt + полное замыкание зависимостей → repo/*.pkg.tar.zst
#  2. packages/aur.txt собирается makepkg'ом и кладётся туда же
#  3. repo-add индексирует repo/archline.db.tar.gz
#  4. extras/oh-my-zsh.tar.gz — чтобы шелл развернулся без сети
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$ROOT/repo"
REPO_NAME="archline"
EXTRAS="$ROOT/extras"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*"; exit 1; }
pkgs() { grep -v '^\s*#' "$1" | xargs; }

[[ $EUID -ne 0 ]] || die "Запускай от обычного пользователя"
[[ -f "$ROOT/packages/pacman.txt" && -f "$ROOT/packages/aur.txt" ]] \
  || die "Нет packages/pacman.txt или aur.txt"
command -v pactree  >/dev/null || die "Нет pactree — sudo pacman -S pacman-contrib"
command -v repo-add >/dev/null || die "Нет repo-add — странно, он идёт с pacman"
command -v makepkg  >/dev/null || die "Нет makepkg — sudo pacman -S base-devel"
command -v git      >/dev/null || die "Нет git"
command -v curl     >/dev/null || die "Нет curl"
mkdir -p "$REPO_DIR" "$EXTRAS"

step "Обновление sync-базы"
sudo pacman -Sy

step "Замыкание зависимостей pacman.txt"
read -ra want <<< "$(pkgs "$ROOT/packages/pacman.txt")"
# pactree -su: имя пакета + все зависимости рекурсивно (включая уже установленные
# на этой машине — pacman -Sw их иначе пропустит). Виртуальные зависимости
# (sh, ttf-font и т.п.) отфильтруем через pacman -Slq ниже.
mapfile -t closure < <(
  for p in "${want[@]}"; do
    pactree -su "$p" 2>/dev/null || echo "$p"
  done | sort -u
)
mapfile -t avail < <(pacman -Slq | sort -u)
mapfile -t dl < <(comm -12 <(printf '%s\n' "${closure[@]}") <(printf '%s\n' "${avail[@]}"))
echo "Пакетов в списке: ${#want[@]}, с зависимостями: ${#dl[@]}"

step "Скачивание в $REPO_DIR"
# Без --needed: уже установленные на этой системе пакеты тоже должны лечь в пул.
# pacman сам возьмёт файл из кэша, если версия совпадает.
sudo pacman -Sw --noconfirm --cachedir "$REPO_DIR" "${dl[@]}"

step "Сборка AUR"
# pacman.conf для сборки: официальные репы + локальный пул —
# AUR-пакет сможет тянуть dep'ы из уже собранных AUR-соседей.
cp /etc/pacman.conf "$BUILD_DIR/pacman.conf"
cat >> "$BUILD_DIR/pacman.conf" <<EOF
[$REPO_NAME]
SigLevel = Never
Server = file://$REPO_DIR
EOF
export PACMAN="pacman --config $BUILD_DIR/pacman.conf"

refresh_db() { (cd "$REPO_DIR" && repo-add "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst >/dev/null); }

AUR_BAD=()
for a in $(pkgs "$ROOT/packages/aur.txt"); do
  rm -rf "$BUILD_DIR/$a"
  if git clone -q --depth=1 "https://aur.archlinux.org/$a.git" "$BUILD_DIR/$a" \
     && (cd "$BUILD_DIR/$a" && makepkg -sf --noconfirm >/dev/null) \
     && cp "$BUILD_DIR/$a"/*.pkg.tar.zst "$REPO_DIR/" 2>/dev/null; then
    refresh_db   # сразу в индекс — следующие AUR-пакеты увидят его как dep
    echo "  + $a"
  else
    AUR_BAD+=("$a"); echo "  ! $a не собрался"
  fi
done
unset PACMAN

step "Чистка старых версий и финальный индекс"
if command -v paccache >/dev/null; then
  paccache -rk1 -c "$REPO_DIR" || true   # pacman-contrib: оставить только свежую версию каждого пакета
fi
(cd "$REPO_DIR" && repo-add "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst)

step "extras: oh-my-zsh"
curl -fsSL --retry 2 \
  https://github.com/ohmyzsh/ohmyzsh/archive/refs/heads/master.tar.gz \
  -o "$EXTRAS/oh-my-zsh.tar.gz" \
  || echo "omz не скачался — на таргете склонируется, если будет сеть"

echo
(( ${#AUR_BAD[@]} )) && echo "Не собрались из AUR: ${AUR_BAD[*]}"
echo "Готово: $(du -sh "$REPO_DIR" | cut -f1) в $REPO_DIR"

#!/usr/bin/env bash
# Полная установка Arch + Hyprland из этого бандла.
# Запускать из live-ISO Arch от root:
#
#   udevadm trigger; udevadm settle
#   mkdir -p /usb && mount -L <метка флешки> /usb
#   bash /usb/myArch/install.sh
#
# Имя пользователя, hostname и часовой пояс спрашиваются при установке
# (можно задать заранее через RA_USERNAME, RA_HOSTNAME, RA_TZ).
#
# ВНИМАНИЕ: выбранный диск стирается полностью (Windows в том числе).
set -Eeuo pipefail

USERNAME="${RA_USERNAME:-}"
HOSTNAME="${RA_HOSTNAME:-}"
TIMEZONE="${RA_TZ:-}"

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/tmp/relocatable-arch.log"
MNT="/mnt"
BTRFS_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

exec > >(tee -a "$LOG") 2>&1
trap 'echo; echo "!!! Ошибка на строке $LINENO: $BASH_COMMAND"; echo "Лог: $LOG"' ERR

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*"; exit 1; }
online() { curl -fsI --max-time 5 https://archlinux.org >/dev/null 2>&1; }
pkgs() { grep -v '^\s*#' "$1" | xargs; }
as_user() { arch-chroot "$MNT" runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" "$@"; }

preflight() {
  setfont cyr-sun16 2>/dev/null || true
  [[ $EUID -eq 0 ]] || die "Запусти от root"
  [[ -d /sys/firmware/efi/efivars ]] || die "Система загружена не в UEFI-режиме"
  [[ -f "$BUNDLE/packages/pacman.txt" && -f "$BUNDLE/dotfiles/home.tar.gz" ]] || die "Бандл неполный: $BUNDLE"
  if [[ "$(cat /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | od -An -tu1 | awk '{print $NF}')" == "1" ]]; then
    die "Secure Boot включён. Выключи его в BIOS (F2) и запусти заново"
  fi
}

setup_network() {
  step "Сеть"
  WIFI_SSID="" WIFI_PASS=""
  if online; then echo "Интернет уже есть"; return; fi

  local dev ifaces=(/sys/class/net/wl*)
  [[ -e "${ifaces[0]}" ]] || die "Нет Wi-Fi адаптера и нет интернета"
  dev="${ifaces[0]##*/}"
  rfkill unblock wifi || true
  while ! online; do
    iwctl station "$dev" scan || true
    sleep 4
    iwctl station "$dev" get-networks || true
    read -rp "SSID сети: " WIFI_SSID
    read -rsp "Пароль Wi-Fi: " WIFI_PASS; echo
    iwctl --passphrase "$WIFI_PASS" station "$dev" connect "$WIFI_SSID" || true
    for _ in $(seq 20); do online && break; sleep 1; done
    online || echo "Не подключилось, ещё раз"
  done
  echo "Подключено к $WIFI_SSID"
}

ask_identity() {
  step "Пользователь и имя машины"
  local in
  if [[ -z "$USERNAME" ]]; then
    while true; do
      read -rp "Имя пользователя [arch]: " in
      USERNAME="${in:-arch}"
      [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
      echo "Только строчные буквы, цифры, - и _; первая — буква"
    done
  fi
  if [[ -z "$HOSTNAME" ]]; then
    read -rp "Имя компьютера [arch-pc]: " in
    HOSTNAME="${in:-arch-pc}"
  fi
  if [[ -z "$TIMEZONE" ]]; then
    TIMEZONE="$(curl -fs --max-time 5 https://ipapi.co/timezone 2>/dev/null || true)"
    while true; do
      read -rp "Часовой пояс [${TIMEZONE:-UTC}]: " in
      TIMEZONE="${in:-${TIMEZONE:-UTC}}"
      [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] && break
      echo "Зоны $TIMEZONE нет, пример: Europe/Moscow"
      TIMEZONE=""
    done
  fi
  echo "→ $USERNAME@$HOSTNAME, зона $TIMEZONE"
}

pick_disk() {
  step "Выбор диска"
  local -a disks
  mapfile -t disks < <(lsblk -dpno NAME,TYPE,TRAN | awk '$2=="disk" && $3!="usb" {print $1}')
  (( ${#disks[@]} )) || die "Не найдено ни одного внутреннего диска"

  lsblk -dpo NAME,SIZE,MODEL "${disks[@]}"
  if (( ${#disks[@]} == 1 )); then
    DISK="${disks[0]}"
  else
    select DISK in "${disks[@]}"; do [[ -n "${DISK:-}" ]] && break; done
  fi

  echo
  lsblk -po NAME,SIZE,FSTYPE,LABEL "$DISK"
  echo
  echo "Диск $DISK будет ПОЛНОСТЬЮ стёрт (Windows и все данные на нём)."
  local answer
  read -rp "Напиши YES для продолжения: " answer
  [[ "$answer" == "YES" ]] || die "Отменено"

  if [[ "$DISK" =~ [0-9]$ ]]; then PART="${DISK}p"; else PART="$DISK"; fi
}

ask_password() {
  step "Пароль для $USERNAME (он же для root)"
  local p2
  while true; do
    read -rsp "Пароль: " USER_PASS; echo
    read -rsp "Ещё раз: " p2; echo
    [[ -n "$USER_PASS" && "$USER_PASS" == "$p2" ]] && break
    echo "Не совпадают или пустой, ещё раз"
  done
}

prepare_live() {
  step "Подготовка live-окружения"
  timedatectl set-ntp true || true
  sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
  if ! reflector --protocol https --age 24 \
       --sort rate --latest 15 --save /etc/pacman.d/mirrorlist; then
    echo "reflector не сработал, беру mirrorlist из бандла"
    cp "$BUNDLE/packages/mirrorlist" /etc/pacman.d/mirrorlist
  fi
  pacman -Sy --noconfirm archlinux-keyring
}

partition() {
  step "Разметка $DISK"
  umount -R "$MNT" 2>/dev/null || true
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:+1G -t1:ef00 -c1:EFI -n2:0:0 -t2:8304 -c2:archroot "$DISK"
  partprobe "$DISK"; udevadm settle

  ESP="${PART}1"; ROOTP="${PART}2"
  mkfs.fat -F32 -n EFI "$ESP"
  mkfs.btrfs -f -L arch "$ROOTP"

  mount "$ROOTP" "$MNT"
  for sv in @ @home @pkg @log; do btrfs subvolume create "$MNT/$sv"; done
  umount "$MNT"

  mount -o "$BTRFS_OPTS,subvol=@" "$ROOTP" "$MNT"
  mkdir -p "$MNT"/{boot,home,var/cache/pacman/pkg,var/log}
  mount -o "$BTRFS_OPTS,subvol=@home" "$ROOTP" "$MNT/home"
  mount -o "$BTRFS_OPTS,subvol=@pkg"  "$ROOTP" "$MNT/var/cache/pacman/pkg"
  mount -o "$BTRFS_OPTS,subvol=@log"  "$ROOTP" "$MNT/var/log"
  mount -o fmask=0077,dmask=0077 "$ESP" "$MNT/boot"
}

install_base() {
  step "pacstrap (долго)"
  # shellcheck disable=SC2046
  pacstrap -K "$MNT" $(pkgs "$BUNDLE/packages/pacman.txt")
  genfstab -U "$MNT" >> "$MNT/etc/fstab"
  cp /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
}

configure_system() {
  step "Настройка системы"
  local root_partuuid
  root_partuuid="$(blkid -s PARTUUID -o value "$ROOTP")"

  cat > "$MNT/root/setup.sh" <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i -e 's/^#\(en_US.UTF-8 UTF-8\)/\1/' -e 's/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
printf 'KEYMAP=us\nFONT=default8x16\n' > /etc/vconsole.conf
echo '$HOSTNAME' > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 $HOSTNAME.localdomain $HOSTNAME\n' > /etc/hosts

sed -i -e 's/^#Color/Color/' -e 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf

# initramfs: kms убираем, чтобы nouveau не попал в образ (NVIDIA)
sed -i -E '/^HOOKS=/ s/ kms//' /etc/mkinitcpio.conf
echo 'root=PARTUUID=$root_partuuid rootflags=subvol=@ rw rootfstype=btrfs zswap.enabled=0 nvidia_drm.modeset=1 nvidia_drm.fbdev=1' > /etc/kernel/cmdline
cat > /etc/mkinitcpio.d/linux-zen.preset <<'P'
ALL_kver="/boot/vmlinuz-linux-zen"

PRESETS=('default')

default_uki="/boot/EFI/Linux/arch-linux-zen.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
P
rm -f /boot/initramfs-linux-zen*.img
mkdir -p /boot/EFI/Linux
mkinitcpio -P

bootctl install
printf 'timeout 3\neditor no\n' > /boot/loader/loader.conf

printf '[zram0]\ncompression-algorithm = zstd\n' > /etc/systemd/zram-generator.conf
echo 'options nvidia NVreg_PreserveVideoMemoryAllocations=1' > /etc/modprobe.d/nvidia.conf
cat > /etc/udev/rules.d/61-gpu-paths.rules <<'R'
SUBSYSTEM=="drm", KERNEL=="card*", ATTRS{vendor}=="0x8086", SYMLINK+="dri/igpu"
SUBSYSTEM=="drm", KERNEL=="card*", ATTRS{vendor}=="0x10de", SYMLINK+="dri/dgpu"
R

useradd -m -G wheel -s /usr/bin/zsh $USERNAME
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

cat > /etc/greetd/config.toml <<'G'
[terminal]
vt = 1

[initial_session]
command = "uwsm start hyprland.desktop"
user = "$USERNAME"

[default_session]
command = "uwsm start hyprland.desktop"
user = "$USERNAME"
G

sed -i -e 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' \
       -e 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw || true
sed -i 's/^ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf || true
for unit in NetworkManager bluetooth greetd systemd-timesyncd fstrim.timer \
  cups power-profiles-daemon ufw earlyoom fwupd-refresh.timer snapper-cleanup.timer; do
  systemctl enable "$unit" || true
done
systemctl disable snapper-timeline.timer || true
systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume || true
EOF
  arch-chroot "$MNT" bash /root/setup.sh
  rm -f "$MNT/root/setup.sh"

  printf '%s:%s\nroot:%s\n' "$USERNAME" "$USER_PASS" "$USER_PASS" | arch-chroot "$MNT" chpasswd

  if [[ -n "$WIFI_SSID" ]]; then
    local f="$MNT/etc/NetworkManager/system-connections/${WIFI_SSID//\//_}.nmconnection"
    cat > "$f" <<EOF
[connection]
id=$WIFI_SSID
type=wifi

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASS

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    chmod 600 "$f"
  fi
}

install_aur() {
  step "AUR (yay + пакеты)"
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > "$MNT/etc/sudoers.d/99-installer"
  chmod 440 "$MNT/etc/sudoers.d/99-installer"

  AUR_FAILED=()
  if ! as_user bash -c 'rm -rf /tmp/yay-bin && git clone --depth=1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && cd /tmp/yay-bin && makepkg -si --noconfirm'; then
    echo "yay не собрался, AUR-пакеты придётся доставить после загрузки"
    read -ra AUR_FAILED <<< "yay-bin $(pkgs "$BUNDLE/packages/aur.txt")"
    rm -f "$MNT/etc/sudoers.d/99-installer"
    return
  fi

  local p
  for p in $(pkgs "$BUNDLE/packages/aur.txt"); do
    as_user yay -S --needed --noconfirm --answerdiff None --answerclean None --removemake "$p" \
      || AUR_FAILED+=("$p")
  done
  rm -f "$MNT/etc/sudoers.d/99-installer"
}

deploy_dotfiles() {
  step "Конфиги, обои, тема"
  local home="$MNT/home/$USERNAME"
  tar -C "$home" -xzpf "$BUNDLE/dotfiles/home.tar.gz" --no-same-owner --no-overwrite-dir
  # Переписываем захардкоженные /home/<старое имя> на /home/<новый пользователь>
  grep -rlIZ --exclude-dir=Pictures -E '/home/[A-Za-z0-9_.-]+' "$home" \
    | xargs -0 -r sed -i -E "s|/home/[A-Za-z0-9_.-]+|/home/$USERNAME|g"

  as_user git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "/home/$USERNAME/.oh-my-zsh" \
    || echo "oh-my-zsh не склонировался: git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh"

  cat > "$home/.local/bin/firstrun.sh" <<'EOF'
#!/bin/bash
# Одноразово: после входа в Telegram открыть тему Gruvbox (нажать «Применить»), затем удалиться.
theme="$HOME/.local/share/tg-theme/gruvbox.tdesktop-theme"
for _ in $(seq 360); do
  if [[ -d "$HOME/.local/share/TelegramDesktop/tdata/D877F783D5D3EF8C" ]] && pgrep -x Telegram >/dev/null; then
    sleep 5
    Telegram -- "$theme" && rm -f "$0"
    exit 0
  fi
  sleep 5
done
EOF
  chmod +x "$home/.local/bin/firstrun.sh"

  if (( ${#AUR_FAILED[@]} )); then
    {
      if [[ "${AUR_FAILED[0]}" == "yay-bin" ]]; then
        echo 'git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && (cd /tmp/yay-bin && makepkg -si)'
        AUR_FAILED=("${AUR_FAILED[@]:1}")
      fi
      printf 'yay -S --needed %s\n' "${AUR_FAILED[*]}"
    } > "$home/aur-failed.txt"
  fi

  arch-chroot "$MNT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
  as_user xdg-user-dirs-update
}

finish() {
  step "Готово"
  cp "$LOG" "$MNT/var/log/relocatable-arch-install.log" || true
  if (( ${#AUR_FAILED[@]} )); then
    echo "Не поставились из AUR: ${AUR_FAILED[*]}"
    echo "После загрузки: bash ~/aur-failed.txt"
  fi
  sync
  umount -R "$MNT"
  local answer
  read -rp "Перезагрузить сейчас? [Y/n] " answer
  [[ "${answer,,}" == "n" ]] || reboot
}

preflight
setup_network
ask_identity
pick_disk
ask_password
prepare_live
partition
install_base
configure_system
install_aur
deploy_dotfiles
finish

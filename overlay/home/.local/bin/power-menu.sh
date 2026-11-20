#!/usr/bin/env bash
set -u

choice="$(printf 'Lock\nSuspend\nReboot\nShutdown\nLogout\n' | wofi --show dmenu --conf "$HOME/.config/hypr/wofi/config.conf" --style "$HOME/.config/hypr/wofi/style.css" --prompt 'Power')"

case "${choice:-}" in
    Lock)     hyprlock ;;
    Suspend)  systemctl suspend ;;
    Reboot)   systemctl reboot ;;
    Shutdown) systemctl poweroff ;;
    Logout)   uwsm stop ;;
esac

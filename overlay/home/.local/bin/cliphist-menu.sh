#!/usr/bin/env bash
set -u

cliphist list | wofi --dmenu -i -p 'Clipboard' -L 15 | cliphist decode | wl-copy

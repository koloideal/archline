#!/bin/bash

focus() { hyprctl dispatch 'hl.dsp.focus({ window = "class:^(google-chrome)$" })' >/dev/null; }

if pgrep -x "chrome" >/dev/null; then
  focus
  google-chrome-stable "$@" >/dev/null 2>&1 &
else
  google-chrome-stable "$@" >/dev/null 2>&1 &
  sleep 2
  focus
fi

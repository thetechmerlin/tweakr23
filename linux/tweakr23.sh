#!/usr/bin/env bash
# Tweakr23 launcher for Ubuntu / Debian-based Linux - by Tech Merlin
# https://github.com/thetechmerlin/Tweakr23
cd "$(dirname "$(readlink -f "$0")")" || exit 1
printf '\033]0;Tweakr23 engine\007'

if ! command -v python3 >/dev/null 2>&1; then
  echo "Tweakr23 needs python3:  sudo apt install python3"; read -r _; exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "Run Tweakr23 as your normal user, not with sudo. It asks for your password itself."; exit 1
fi

echo
echo "  Tweakr23 asks for your password once so it can clean the apt cache,"
echo "  old snaps and logs, read drive health and toggle services."
echo "  (Press Ctrl+C here to skip - those tools will then be limited.)"
echo
if sudo -v; then
  # keep the sudo timestamp fresh while the panel is open
  ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
fi
exec python3 tweakr23.py "$@"

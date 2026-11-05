#!/usr/bin/env bash
# Adds Tweakr23 (with its eye icon) to your app menu, and optionally your desktop.
# Run it from the folder you want to keep Tweakr23 in. Moved the folder? Run it again.
set -e
HERE="$(dirname "$(readlink -f "$0")")"
ICON="$(readlink -f "$HERE/../assets/tweakr23.png")"
chmod +x "$HERE/tweakr23.sh" "$HERE/tweakr23.py"
APPS="$HOME/.local/share/applications"; mkdir -p "$APPS"
cat > "$APPS/tweakr23.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Tweakr23
GenericName=System Tune-up
Comment=Light tune-up panel: startup, junk, privacy, drivers, health - by Tech Merlin
Exec=bash "$HERE/tweakr23.sh"
Icon=$ICON
Terminal=true
Categories=System;Settings;Utility;
Keywords=clean;optimize;startup;junk;privacy;drivers;
StartupNotify=false
DESK
chmod +x "$APPS/tweakr23.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "Added Tweakr23 to your app menu."

DESKTOP="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [ -d "$DESKTOP" ]; then
  read -r -p "Also put a shortcut on your desktop? [y/N] " a
  if [[ "$a" =~ ^[Yy] ]]; then
    cp "$APPS/tweakr23.desktop" "$DESKTOP/tweakr23.desktop"
    chmod +x "$DESKTOP/tweakr23.desktop"
    gio set "$DESKTOP/tweakr23.desktop" metadata::trusted true 2>/dev/null || true
    echo "Desktop shortcut created (right-click it > Allow Launching if asked)."
  fi
fi
for t in smartmontools timeshift; do
  dpkg -s "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -n "$MISSING" ] && echo "Optional extras for more features: sudo apt install$MISSING"
exit 0

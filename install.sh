#!/bin/bash
# One-line installer: curl -fsSL https://raw.githubusercontent.com/slavashootit/kadr/main/install.sh | bash
set -euo pipefail

REPO="slavashootit/kadr"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[ "$(uname)" = "Darwin" ] || { echo "Kadr працює лише на macOS."; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || { echo "Потрібна macOS 15 або новіша."; exit 1; }

echo "Завантажую Kadr…"
curl -fsSL -o "$tmp/Kadr.zip" "https://github.com/$REPO/releases/latest/download/Kadr.zip"

pkill -x Kadr 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Kadr >/dev/null || break; sleep 0.3; done
rm -rf /Applications/Kadr.app
ditto -x -k "$tmp/Kadr.zip" /Applications
xattr -cr /Applications/Kadr.app

echo "Готово: /Applications/Kadr.app"
open /Applications/Kadr.app
echo "Дай дозвіл «Запис екрана» в Системних параметрах і перезапусти Kadr."

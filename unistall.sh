#!/usr/bin/env bash

EXT_FILE="$HOME/.local/share/nautilus-python/extensions/create_desktop_shortcut.py"

echo "🧹 Removing Nautilus Desktop Shortcut Extension..."

if [ -f "$EXT_FILE" ]; then
    rm "$EXT_FILE"
    echo "✔ Extension removed"
else
    echo "ℹ Extension not found"
fi

nautilus -q || true
echo "✅ Done"

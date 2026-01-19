#!/usr/bin/env bash
set -e

echo "🐚 Nautilus Desktop Shortcut Installer"
echo "-------------------------------------"

# Detect package manager
detect_pm() {
    if command -v apt >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    else echo "unknown"
    fi
}

PM=$(detect_pm)

if [ "$PM" = "unknown" ]; then
    echo "❌ Unsupported package manager"
    exit 1
fi

# Install Nautilus if missing
if command -v nautilus >/dev/null 2>&1; then
    echo "✔ Nautilus already installed — skipping"
else
    echo "📦 Installing Nautilus..."

    case "$PM" in
        apt)
            sudo apt update
            sudo apt install -y nautilus
            ;;
        dnf)
            sudo dnf install -y nautilus
            ;;
        pacman)
            sudo pacman -Sy --noconfirm nautilus
            ;;
        zypper)
            sudo zypper install -y nautilus
            ;;
    esac
fi

# Install Python bindings
echo "🐍 Installing Nautilus Python bindings..."
case "$PM" in
    apt)
        sudo apt install -y python3-nautilus
        ;;
    dnf)
        sudo dnf install -y python3-nautilus
        ;;
    pacman)
        sudo pacman -Sy --noconfirm python-nautilus
        ;;
    zypper)
        sudo zypper install -y python3-nautilus
        ;;
esac

# Install extension
EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
EXT_FILE="$EXT_DIR/create_desktop_shortcut.py"

mkdir -p "$EXT_DIR"

cat > "$EXT_FILE" <<'EOF'
from gi.repository import Nautilus, GObject
import os
import urllib.parse
import subprocess

DESKTOP_DIR = os.path.join(os.path.expanduser("~"), "Desktop")

class CreateDesktopShortcut(GObject.GObject, Nautilus.MenuProvider):

    def get_file_items(self, files):
        if not files:
            return []

        item = Nautilus.MenuItem(
            name="CreateDesktopShortcut",
            label="Create Desktop Shortcut",
            tip="Create a trusted desktop shortcut"
        )

        item.connect("activate", self.create_shortcut, files)
        return [item]

    def create_shortcut(self, menu, files):
        for file in files:
            path = urllib.parse.unquote(file.get_uri()[7:])
            name = os.path.basename(path)
            shortcut_path = os.path.join(DESKTOP_DIR, f"{name}.desktop")

            with open(shortcut_path, "w") as f:
                f.write(f"""[Desktop Entry]
Type=Application
Name={name}
Exec=xdg-open "{path}"
Icon=text-x-generic
Terminal=false
""")

            # Make executable
            os.chmod(shortcut_path, 0o755)

            # 🔐 Mark as trusted (removes "Allow Launching")
            subprocess.run(
                ["gio", "set", shortcut_path, "metadata::trusted", "true"],
                check=False
            )
EOF

# Restart Nautilus
echo "🔄 Restarting Nautilus..."
nautilus -q || true

echo "✅ Installation complete!"
echo "➡ Right-click any file → Create Desktop Shortcut"
echo "🚀 Shortcut launches immediately (no Allow Launching prompt)"

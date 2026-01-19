#!/usr/bin/env bash
set -Eeuo pipefail

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
EXT_NAME="create_desktop_shortcut.py"
EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
EXT_PATH="$EXT_DIR/$EXT_NAME"
DESKTOP_DIR="$HOME/Desktop"

LOG_PREFIX="[Nautilus-Shortcut]"

# ─────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────
log()  { echo -e "✅ $LOG_PREFIX $*"; }
warn() { echo -e "⚠️  $LOG_PREFIX $*" >&2; }
err()  { echo -e "❌ $LOG_PREFIX $*" >&2; }

trap 'err "Installation failed on line $LINENO"' ERR

# ─────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────
command -v bash >/dev/null || { err "bash required"; exit 1; }

# Desktop directory (some systems remove it)
if [[ ! -d "$DESKTOP_DIR" ]]; then
    warn "Desktop directory missing — creating it"
    mkdir -p "$DESKTOP_DIR"
fi

# ─────────────────────────────────────────────
# PACKAGE MANAGER DETECTION
# ─────────────────────────────────────────────
detect_pm() {
    if command -v apt >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    else echo unknown
    fi
}

PM=$(detect_pm)

[[ "$PM" != "unknown" ]] || { err "Unsupported distro"; exit 1; }

log "Detected package manager: $PM"

# ─────────────────────────────────────────────
# DEPENDENCY INSTALLATION
# ─────────────────────────────────────────────
install_pkg() {
    case "$PM" in
        apt)     sudo apt update && sudo apt install -y "$@" ;;
        dnf)     sudo dnf install -y "$@" ;;
        pacman) sudo pacman -Sy --noconfirm "$@" ;;
        zypper) sudo zypper install -y "$@" ;;
    esac
}

# Nautilus
if ! command -v nautilus >/dev/null 2>&1; then
    log "Installing Nautilus"
    install_pkg nautilus
else
    log "Nautilus already installed"
fi

# Python bindings
log "Installing Nautilus Python bindings"
case "$PM" in
    apt|zypper) install_pkg python3-nautilus ;;
    dnf)        install_pkg python3-nautilus ;;
    pacman)     install_pkg python-nautilus ;;
esac

# Core tools
for bin in gio xdg-open; do
    command -v "$bin" >/dev/null || { err "$bin missing"; exit 1; }
done

# ─────────────────────────────────────────────
# INSTALL EXTENSION
# ─────────────────────────────────────────────
log "Installing Nautilus extension"

mkdir -p "$EXT_DIR"

cat > "$EXT_PATH" <<'PYEOF'
from gi.repository import Nautilus, GObject, Gio
import os
import urllib.parse
import subprocess
import hashlib
import time

DESKTOP_DIR = os.path.join(os.path.expanduser("~"), "Desktop")

XDG_OPEN = "/usr/bin/xdg-open"
NAUTILUS = "/usr/bin/nautilus"

# ─────────────────────────────────────────────
# GNOME THUMBNAIL HANDLING
# ─────────────────────────────────────────────

def ensure_gnome_thumbnail(path):
    try:
        subprocess.run(
            ["gio", "info", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
    except Exception:
        pass


def get_gnome_thumbnail(path, wait=True):
    uri = "file://" + path
    md5 = hashlib.md5(uri.encode("utf-8")).hexdigest()

    thumb_dirs = [
        os.path.expanduser("~/.cache/thumbnails/large"),
        os.path.expanduser("~/.cache/thumbnails/normal"),
    ]

    for _ in range(5 if wait else 1):
        for d in thumb_dirs:
            thumb = os.path.join(d, f"{md5}.png")
            if os.path.exists(thumb):
                return thumb
        time.sleep(0.2)

    return None


# ─────────────────────────────────────────────
# ICON RESOLUTION
# ─────────────────────────────────────────────

def get_icon_for_desktop(path):
    file = Gio.File.new_for_path(path)

    ensure_gnome_thumbnail(path)

    thumb = get_gnome_thumbnail(path)
    if thumb:
        return thumb

    try:
        info = file.query_info(
            "metadata::custom-icon,standard::icon",
            Gio.FileQueryInfoFlags.NONE,
            None
        )

        custom = info.get_attribute_string("metadata::custom-icon")
        if custom:
            return custom.replace("file://", "")

        icon = info.get_icon()
        if isinstance(icon, Gio.ThemedIcon):
            return icon.get_names()[0]

    except Exception:
        pass

    return "folder" if os.path.isdir(path) else "text-x-generic"


# ─────────────────────────────────────────────
# NAUTILUS EXTENSION
# ─────────────────────────────────────────────

class CreateDesktopShortcut(GObject.GObject, Nautilus.MenuProvider):

    def get_file_items(self, files):
        if not files:
            return []

        item = Nautilus.MenuItem(
            name="CreateDesktopShortcut",
            label="Create Desktop Shortcut",
            tip="Create a trusted desktop shortcut using GNOME thumbnails"
        )

        item.connect("activate", self.create_shortcut, files)
        return [item]

    def create_shortcut(self, menu, files):
        for file in files:
            uri = file.get_uri()
            path = urllib.parse.unquote(uri.replace("file://", ""))

            name = os.path.basename(path)
            base = os.path.splitext(name)[0]

            icon = get_icon_for_desktop(path)

            exec_cmd = (
                f'{NAUTILUS} "{path}"'
                if os.path.isdir(path)
                else f'{XDG_OPEN} "{path}"'
            )

            shortcut_path = os.path.join(DESKTOP_DIR, f"{base}.desktop")

            with open(shortcut_path, "w") as f:
                f.write(f"""[Desktop Entry]
Type=Application
Name={base}
Exec={exec_cmd}
Icon={icon}
Terminal=false
StartupNotify=false
""")

            os.chmod(shortcut_path, 0o755)

            subprocess.run(
                ["gio", "set", shortcut_path, "metadata::trusted", "true"],
                check=False
            )
PYEOF

log "Extension installed at $EXT_PATH"

# ─────────────────────────────────────────────
# RESTART NAUTILUS SAFELY
# ─────────────────────────────────────────────
log "Restarting Nautilus"
nautilus -q || true

log "Done!"
echo
echo "➡ Right-click any file or folder → Create Desktop Shortcut"
echo "🚀 Trusted, thumbnail-aware, GNOME-native shortcuts enabled"

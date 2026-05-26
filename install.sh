#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# Nautilus Desktop Shortcut Extension Installer
# =========================================================

LOG_PREFIX="[Nautilus-Shortcut]"

EXT_NAME="create_desktop_shortcut.py"
EXT_DIR="${HOME}/.local/share/nautilus-python/extensions"
EXT_PATH="${EXT_DIR}/${EXT_NAME}"

# =========================================================
# Logging
# =========================================================

log() {
    printf "✅ %s %s\n" "$LOG_PREFIX" "$*"
}

warn() {
    printf "⚠️  %s %s\n" "$LOG_PREFIX" "$*" >&2
}

err() {
    printf "❌ %s %s\n" "$LOG_PREFIX" "$*" >&2
}

trap 'err "Failed at line $LINENO"' ERR

# =========================================================
# Detect Desktop Directory
# =========================================================

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"

if [[ -z "${DESKTOP_DIR}" ]]; then
    DESKTOP_DIR="${HOME}/Desktop"
fi

mkdir -p "$DESKTOP_DIR"

# =========================================================
# Detect Package Manager
# =========================================================

detect_pm() {
    if command -v apt >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    elif command -v zypper >/dev/null 2>&1; then
        echo zypper
    else
        echo unknown
    fi
}

PM="$(detect_pm)"

[[ "$PM" != "unknown" ]] || {
    err "Unsupported distribution"
    exit 1
}

log "Detected package manager: $PM"

# =========================================================
# Package Installer
# =========================================================

install_pkg() {
    case "$PM" in
        apt)
            sudo apt update
            sudo apt install -y "$@"
            ;;
        dnf)
            sudo dnf install -y "$@"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm "$@"
            ;;
        zypper)
            sudo zypper install -y "$@"
            ;;
    esac
}

# =========================================================
# Dependencies
# =========================================================

if ! command -v nautilus >/dev/null 2>&1; then
    log "Installing Nautilus"

    case "$PM" in
        apt) install_pkg nautilus ;;
        dnf) install_pkg nautilus ;;
        pacman) install_pkg nautilus ;;
        zypper) install_pkg nautilus ;;
    esac
else
    log "Nautilus already installed"
fi

log "Installing Nautilus Python bindings"

case "$PM" in
    apt)
        install_pkg python3-nautilus
        ;;
    dnf)
        install_pkg nautilus-python
        ;;
    pacman)
        install_pkg python-nautilus
        ;;
    zypper)
        install_pkg python3-nautilus
        ;;
esac

# Required tools

for bin in gio xdg-open python3; do
    command -v "$bin" >/dev/null 2>&1 || {
        err "$bin missing"
        exit 1
    }
done

# =========================================================
# Install Extension
# =========================================================

log "Installing extension"

mkdir -p "$EXT_DIR"

cat > "$EXT_PATH" <<'PYEOF'
from gi.repository import Nautilus, GObject, Gio
import os
import subprocess
import urllib.parse
import hashlib
import time
import shlex

DESKTOP_DIR = subprocess.check_output(
    ["xdg-user-dir", "DESKTOP"],
    text=True
).strip()

if not DESKTOP_DIR:
    DESKTOP_DIR = os.path.join(os.path.expanduser("~"), "Desktop")

XDG_OPEN = "xdg-open"
NAUTILUS_BIN = "nautilus"

THUMB_DIRS = [
    os.path.expanduser("~/.cache/thumbnails/large"),
    os.path.expanduser("~/.cache/thumbnails/normal"),
]


# =========================================================
# Helpers
# =========================================================

def decode_file_path(uri):
    return urllib.parse.unquote(uri.replace("file://", ""))


def ensure_thumbnail(path):
    try:
        subprocess.run(
            ["gio", "info", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except Exception:
        pass


def get_thumbnail(path):
    uri = Gio.File.new_for_path(path).get_uri()
    md5 = hashlib.md5(uri.encode()).hexdigest()

    for _ in range(3):
        for directory in THUMB_DIRS:
            thumb = os.path.join(directory, f"{md5}.png")
            if os.path.exists(thumb):
                return thumb

        time.sleep(0.15)

    return None


def resolve_icon(path):
    ensure_thumbnail(path)

    thumb = get_thumbnail(path)
    if thumb:
        return thumb

    try:
        gfile = Gio.File.new_for_path(path)

        info = gfile.query_info(
            "metadata::custom-icon,standard::icon",
            Gio.FileQueryInfoFlags.NONE,
            None
        )

        custom_icon = info.get_attribute_string(
            "metadata::custom-icon"
        )

        if custom_icon:
            return custom_icon.replace("file://", "")

        icon = info.get_icon()

        if isinstance(icon, Gio.ThemedIcon):
            names = icon.get_names()
            if names:
                return names[0]

    except Exception:
        pass

    return "folder" if os.path.isdir(path) else "text-x-generic"


def unique_shortcut_path(base_name):
    candidate = os.path.join(
        DESKTOP_DIR,
        f"{base_name}.desktop"
    )

    if not os.path.exists(candidate):
        return candidate

    counter = 2

    while True:
        candidate = os.path.join(
            DESKTOP_DIR,
            f"{base_name}_{counter}.desktop"
        )

        if not os.path.exists(candidate):
            return candidate

        counter += 1


def create_desktop_file(name, exec_cmd, icon, out_path):
    content = f"""[Desktop Entry]
Version=1.0
Type=Application
Name={name}
Exec={exec_cmd}
Icon={icon}
Terminal=false
StartupNotify=true
"""

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(content)

    os.chmod(out_path, 0o755)

    subprocess.run(
        [
            "gio",
            "set",
            out_path,
            "metadata::trusted",
            "true",
        ],
        check=False,
    )


# =========================================================
# Nautilus Extension
# =========================================================

class CreateDesktopShortcut(
    GObject.GObject,
    Nautilus.MenuProvider
):

    def get_file_items(self, *args):
        files = args[-1]

        if not files:
            return []

        item = Nautilus.MenuItem(
            name="CreateDesktopShortcut",
            label="Create Desktop Shortcut",
            tip="Create trusted desktop launcher"
        )

        item.connect(
            "activate",
            self.create_shortcut,
            files
        )

        return [item]

    def create_shortcut(self, menu, files):

        for file_obj in files:

            try:
                uri = file_obj.get_uri()
                path = decode_file_path(uri)

                if not os.path.exists(path):
                    continue

                name = os.path.basename(path)
                base = os.path.splitext(name)[0]

                icon = resolve_icon(path)

                escaped = shlex.quote(path)

                if os.path.isdir(path):
                    exec_cmd = f'{NAUTILUS_BIN} {escaped}'
                else:
                    exec_cmd = f'{XDG_OPEN} {escaped}'

                shortcut = unique_shortcut_path(base)

                create_desktop_file(
                    base,
                    exec_cmd,
                    icon,
                    shortcut
                )

            except Exception as e:
                print(f"Shortcut creation failed: {e}")
PYEOF

chmod 644 "$EXT_PATH"

log "Extension installed:"
echo "$EXT_PATH"

# =========================================================
# Restart Nautilus
# =========================================================

log "Restarting Nautilus"

nautilus -q || true

sleep 1

nohup nautilus >/dev/null 2>&1 & disown

# =========================================================
# Complete
# =========================================================

echo
log "Installation complete"
echo
echo "Right click any file/folder in Nautilus"
echo "→ Create Desktop Shortcut"

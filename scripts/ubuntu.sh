#!/bin/bash

set -euo pipefail

MOTD_DIR="/etc/update-motd.d"
OLD_MOTD_DIR="${MOTD_DIR}/old-motd"
STATE_DIR="/var/lib/t1amat-motd"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="${STATE_DIR}/sshd_config.backup"
SSH_HASH="${STATE_DIR}/sshd_config.installed.sha256"

REPO_URL="https://github.com/T1aMat/motd/archive/refs/heads/master.tar.gz"

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Please run this script as root or with sudo."
        exit 1
    fi
}

configure_printlastlog() {
    echo
    echo "== Configuring SSH PrintLastLog =="

    local overrides
    overrides="$(grep -RnsE '^[[:space:]]*PrintLastLog[[:space:]]+' /etc/ssh/sshd_config.d 2>/dev/null || true)"

    if [[ -n "$overrides" ]]; then
        echo "Active PrintLastLog override found:"
        echo "$overrides"
        echo
        echo "Leaving $SSH_CONFIG unchanged."
        return 0
    fi

    mkdir -p "$STATE_DIR"

    python3 - "$SSH_CONFIG" "$SSH_BACKUP" <<'PY'
import shutil
import sys
from pathlib import Path

config = Path(sys.argv[1])
backup = Path(sys.argv[2])
lines = config.read_text().splitlines()
result = []
found = False

for line in lines:
    stripped = line.lstrip()

    if stripped.startswith("PrintLastLog") and (
        stripped == "PrintLastLog"
        or stripped[len("PrintLastLog"):].startswith((" ", "\t"))
    ):
        result.append("PrintLastLog no")
        found = True
        continue

    if stripped.startswith("#PrintLastLog") and (
        stripped == "#PrintLastLog"
        or stripped[len("#PrintLastLog"):].startswith((" ", "\t"))
    ):
        result.append("PrintLastLog no")
        found = True
        continue

    result.append(line)

if not found:
    if result and result[-1] != "":
        result.append("")
    result.append("PrintLastLog no")

new_content = "\n".join(result) + "\n"
old_content = config.read_text()

if new_content != old_content:
    if not backup.exists():
        shutil.copy2(config, backup)
    config.write_text(new_content)
    print("PrintLastLog changed to: no")
    print(f"SSH configuration backup: {backup}")
else:
    print("PrintLastLog is already configured as: no")
PY

    echo "Validating SSH configuration..."
    if ! sshd -t; then
        echo
        echo "ERROR: sshd configuration validation failed."
        if [[ -f "$SSH_BACKUP" ]]; then
            cp -f "$SSH_BACKUP" "$SSH_CONFIG"
        fi
        exit 1
    fi

    if [[ -f "$SSH_BACKUP" ]]; then
        sha256sum "$SSH_CONFIG" > "$SSH_HASH"
    fi

    echo "Reloading SSH..."
    if systemctl reload ssh 2>/dev/null; then
        :
    elif systemctl reload sshd 2>/dev/null; then
        :
    else
        echo "WARNING: Could not reload SSH automatically."
        echo "The configuration itself is valid."
    fi

    echo "Effective setting:"
    sshd -T | grep -i '^printlastlog '
}

configure_header() {
    local header_file="${MOTD_DIR}/00-header"
    local current_header=""
    local header_name

    echo
    echo "== MOTD Header =="

    if [[ ! -f "$header_file" ]]; then
        echo "WARNING: $header_file does not exist."
        return 0
    fi

    current_header="$(sed -n 's/.*toilet .* -f ivrit \("\|\x27\)\(.*\)\1.*/\2/p' "$header_file" | head -n1 || true)"

    if [[ -z "$current_header" ]]; then
        current_header="T1aMat"
    fi

    echo "Current header: $current_header"
    read -r -p "Enter new header name [keep $current_header]: " header_name

    if [[ -z "$header_name" ]]; then
        echo "Keeping header as: $current_header"
        return 0
    fi

    python3 - "$header_file" "$header_name" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
header = sys.argv[2]

text = path.read_text()
pattern = re.compile(r'(toilet\s+-d\s+/etc/update-motd\.d/\s+-f\s+ivrit\s+)(["\']).*?\2')
new_text, count = pattern.subn(lambda m: m.group(1) + json.dumps(header), text, count=1)

if count != 1:
    print("ERROR: Could not find the expected toilet header line.")
    sys.exit(1)

path.write_text(new_text)
PY

    echo "Header changed to: $header_name"
}

backup_old_motd() {
    echo
    echo "== Backing up old MOTD =="

    mkdir -p "$MOTD_DIR"

    if [[ -d "$OLD_MOTD_DIR" ]] && find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        echo "Existing backup found: $OLD_MOTD_DIR"
        echo "Keeping the existing backup."

        find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name "old-motd" -exec rm -rf {} +
        return 0
    fi

    mkdir -p "$OLD_MOTD_DIR"

    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name "old-motd" -exec mv {} "$OLD_MOTD_DIR"/ \;

    echo "Old MOTD backed up to: $OLD_MOTD_DIR"
}

install_motd() {
    clear

    echo "Hi! This script will install custom MOTD for Ubuntu."
    echo
    read -r -p "Continue? [Y/n] " reply

    if [[ ! "$reply" =~ ^([Yy]|)$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    echo
    echo "== Installing utilities =="

    echo -n "    - updating repos....."
    apt-get update >/dev/null 2>&1
    echo "done"

    echo -n "    - toilet............."
    apt-get install -y toilet >/dev/null 2>&1
    echo "done"

    echo -n "    - colorized-logs....."
    apt-get install -y colorized-logs >/dev/null 2>&1
    echo "done"

    echo
    echo "Utilities installed successfully."

    TMP_DIR="$(mktemp -d)"
    ARCHIVE="${TMP_DIR}/motd.tar.gz"

    cleanup_install() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup_install EXIT

    echo
    echo "== Downloading MOTD =="
    printf 'Downloading: '

    if ! curl \
        --fail \
        --location \
        --progress-bar \
        --show-error \
        --connect-timeout 15 \
        --max-time 120 \
        --retry 2 \
        --retry-delay 2 \
        -o "$ARCHIVE" \
        "$REPO_URL"; then
        echo
        echo "ERROR: Failed to download MOTD from GitHub."
        echo "Check DNS, Internet connectivity, and GitHub accessibility."
        exit 1
    fi

    if [[ ! -s "$ARCHIVE" ]]; then
        echo
        echo "ERROR: Downloaded archive is empty."
        exit 1
    fi

    echo
    echo "Extracting MOTD..."

    if ! tar -xzf "$ARCHIVE" -C "$TMP_DIR"; then
        echo
        echo "ERROR: Failed to extract MOTD archive."
        exit 1
    fi

    SOURCE_DIR="${TMP_DIR}/motd-master/motd"

    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo
        echo "ERROR: Downloaded archive has unexpected structure."
        echo "Archive contents:"
        tar -tzf "$ARCHIVE" | head -30
        exit 1
    fi

    echo "MOTD downloaded and extracted successfully."

    backup_old_motd

    echo
    echo "== Installing MOTD =="
    cp -a "$SOURCE_DIR"/. "$MOTD_DIR"/

    echo "Setting permissions..."
    chmod +x "$MOTD_DIR"/* 2>/dev/null || true

    configure_header
    configure_printlastlog

    echo
    echo "== Installation complete =="
    echo "MOTD location: $MOTD_DIR"
    echo "Original MOTD backup: $OLD_MOTD_DIR"
    echo
    echo "Uninstall and restore with:"
    echo "  sudo $0 uninstall"
}

restore_printlastlog() {
    echo
    echo "== Restoring SSH configuration =="

    if [[ ! -f "$SSH_BACKUP" ]]; then
        echo "No SSH configuration backup was created by this installer."
        return 0
    fi

    if [[ -f "$SSH_HASH" ]]; then
        current_hash="$(sha256sum "$SSH_CONFIG" | awk '{print $1}')"
        installed_hash="$(awk '{print $1}' "$SSH_HASH")"

        if [[ "$current_hash" != "$installed_hash" ]]; then
            echo
            echo "WARNING: $SSH_CONFIG was changed after MOTD installation."
            echo "The newer SSH configuration will not be overwritten."
            echo "Original backup remains at: $SSH_BACKUP"
            return 0
        fi
    fi

    cp -f "$SSH_BACKUP" "$SSH_CONFIG"

    if ! sshd -t; then
        echo "ERROR: Restored SSH configuration failed validation."
        return 1
    fi

    if systemctl reload ssh 2>/dev/null; then
        :
    elif systemctl reload sshd 2>/dev/null; then
        :
    else
        echo "WARNING: Could not reload SSH automatically."
    fi

    rm -f "$SSH_BACKUP" "$SSH_HASH"
    echo "Original SSH configuration restored."
}

uninstall_motd() {
    clear

    echo "== Uninstall custom MOTD =="
    echo

    if [[ ! -d "$OLD_MOTD_DIR" ]]; then
        echo "No MOTD backup found at: $OLD_MOTD_DIR"
        echo "Nothing to uninstall."
        exit 0
    fi

    echo "This will remove the custom MOTD and restore the original MOTD."
    echo "It will also restore PrintLastLog if this installer changed it."
    echo
    read -r -p "Continue? [y/N] " reply

    if [[ ! "$reply" =~ ^([Yy])$ ]]; then
        echo "Uninstallation cancelled."
        exit 0
    fi

    TEMP_CURRENT="$(mktemp -d)"

    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name "old-motd" -exec mv {} "$TEMP_CURRENT"/ \;
    find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 -exec mv {} "$MOTD_DIR"/ \;

    rmdir "$OLD_MOTD_DIR" 2>/dev/null || true
    rm -rf "$TEMP_CURRENT"

    restore_printlastlog

    rmdir "$STATE_DIR" 2>/dev/null || true

    echo
    echo "== Uninstallation complete =="
    echo "Original MOTD has been restored."
}

require_root

case "${1:-}" in
    install)
        install_motd
        ;;
    uninstall|remove)
        uninstall_motd
        ;;
    "")
        clear
        echo "T1aMat MOTD installer"
        echo
        echo "  1) Install / update MOTD"
        echo "  2) Uninstall and restore original MOTD"
        echo "  3) Cancel"
        echo
        read -r -p "Select [1-3]: " choice
        case "$choice" in
            1) install_motd ;;
            2) uninstall_motd ;;
            *) echo "Cancelled." ;;
        esac
        ;;
    *)
        echo "Usage:"
        echo "  sudo $0"
        echo "  sudo $0 install"
        echo "  sudo $0 uninstall"
        exit 1
        ;;
esac

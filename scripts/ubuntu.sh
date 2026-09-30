#!/bin/bash

set -e

MOTD_DIR="/etc/update-motd.d"
OLD_MOTD_DIR="${MOTD_DIR}/old-motd"
STATE_DIR="/var/lib/t1amat-motd"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="${STATE_DIR}/sshd_config.backup"
SSH_HASH="${STATE_DIR}/sshd_config.installed.sha256"

REPO_URL="https://github.com/T1aMat/motd/archive/master.tar.gz"

###############################################################################
# Helpers
###############################################################################

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Please run this script as root or with sudo."
        exit 1
    fi
}

pause_prompt() {
    echo
    read -r -p "Press Enter to continue..."
}

###############################################################################
# PrintLastLog
###############################################################################

configure_printlastlog() {
    echo
    echo "== Configuring SSH PrintLastLog =="

    local overrides

    overrides="$(grep -RnsE '^[[:space:]]*PrintLastLog[[:space:]]+' \
        /etc/ssh/sshd_config.d 2>/dev/null || true)"

    if [[ -n "$overrides" ]]; then
        echo "Active PrintLastLog override found:"
        echo "$overrides"
        echo
        echo "Leaving /etc/ssh/sshd_config unchanged."
        return 0
    fi

    mkdir -p "$STATE_DIR"

    python3 - "$SSH_CONFIG" "$SSH_BACKUP" <<'PY'
import sys
import shutil
from pathlib import Path

config = Path(sys.argv[1])
backup = Path(sys.argv[2])

lines = config.read_text().splitlines()

found = False
already_no = False
result = []

for line in lines:
    stripped = line.lstrip()

    # Active PrintLastLog line
    if stripped.startswith("PrintLastLog") and (
        stripped == "PrintLastLog"
        or stripped[len("PrintLastLog"):].startswith((" ", "\t"))
    ):
        value = stripped.split(None, 1)[1].strip().lower() if len(stripped.split()) > 1 else ""

        if value == "no":
            already_no = True
            result.append(line)
        else:
            result.append("PrintLastLog no")

        found = True
        continue

    # Commented PrintLastLog line
    if stripped.startswith("#PrintLastLog") and (
        stripped == "#PrintLastLog"
        or stripped[len("#PrintLastLog"):].startswith((" ", "\t"))
    ):
        result.append("PrintLastLog no")
        found = True
        already_no = False
        continue

    result.append(line)

if not found:
    if result and result[-1] != "":
        result.append("")
    result.append("PrintLastLog no")

# Only create backup if the configuration will actually be changed.
new_content = "\n".join(result) + "\n"
old_content = config.read_text()

if new_content != old_content:
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
        echo "Restoring previous configuration..."

        if [[ -f "$SSH_BACKUP" ]]; then
            cp -f "$SSH_BACKUP" "$SSH_CONFIG"
        fi

        exit 1
    fi

    # Record the resulting sshd_config hash.
    sha256sum "$SSH_CONFIG" > "$SSH_HASH"

    echo "Reloading SSH..."

    if systemctl reload ssh 2>/dev/null; then
        :
    elif systemctl reload sshd 2>/dev/null; then
        :
    else
        echo "WARNING: Could not reload SSH automatically."
        echo "The configuration itself is valid."
    fi

    echo "PrintLastLog configuration complete."
    echo "Effective setting:"
    sshd -T | grep -i '^printlastlog '
}

###############################################################################
# Header
###############################################################################

configure_header() {
    local header_file="${MOTD_DIR}/00-header"
    local header_name

    echo
    echo "== MOTD Header =="

    if [[ ! -f "$header_file" ]]; then
        echo "WARNING: $header_file does not exist."
        return 0
    fi

    echo 'Current header: T1aMat'
    read -r -p "Enter new header name [T1aMat]: " header_name

    if [[ -z "$header_name" ]]; then
        echo "Keeping header as T1aMat."
        return 0
    fi

    python3 - "$header_file" "$header_name" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
header = sys.argv[2]

lines = path.read_text().splitlines()

pattern = re.compile(
    r'(toilet\s+-d\s+/etc/update-motd\.d/\s+-f\s+ivrit\s+)"[^"]*"'
)

replacement = json.dumps(header)

changed = False
result = []

for line in lines:
    new_line, count = pattern.subn(
        lambda match: match.group(1) + replacement,
        line,
        count=1
    )

    if count:
        changed = True

    result.append(new_line)

if not changed:
    print("ERROR: Could not find the expected toilet header line.")
    sys.exit(1)

path.write_text("\n".join(result) + "\n")
PY

    echo "Header changed to: $header_name"
}

###############################################################################
# Backup existing MOTD
###############################################################################

backup_old_motd() {
    echo
    echo "== Backing up old MOTD =="

    mkdir -p "$MOTD_DIR"

    if [[ -d "$OLD_MOTD_DIR" ]] && find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 | read -r _; then
        echo "Existing backup found:"
        echo "  $OLD_MOTD_DIR"
        echo "Keeping the existing backup."

        # Remove current MOTD files without touching old-motd.
        find "$MOTD_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name "old-motd" \
            -exec rm -rf {} +

        return 0
    fi

    mkdir -p "$OLD_MOTD_DIR"

    find "$MOTD_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name "old-motd" \
        -exec mv {} "$OLD_MOTD_DIR"/ \;

    echo "Old MOTD backed up to:"
    echo "  $OLD_MOTD_DIR"
}

###############################################################################
# Install
###############################################################################

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

    cleanup_install() {
        rm -rf "$TMP_DIR"
    }

    trap cleanup_install EXIT

    echo
    echo "== Downloading MOTD =="

    curl -fsSL "$REPO_URL" | tar -xz -C "$TMP_DIR"

    SOURCE_DIR="${TMP_DIR}/motd-master/motd"

    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo "ERROR: Downloaded MOTD archive has unexpected structure."
        exit 1
    fi

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

    echo
    echo "MOTD location:"
    echo "  $MOTD_DIR"

    echo
    echo "Original MOTD backup:"
    echo "  $OLD_MOTD_DIR"

    echo
    echo "To uninstall and restore the original MOTD:"
    echo "  sudo $0 uninstall"
    echo
    echo "Or, if this script is stored elsewhere:"
    echo "  sudo ./ubuntu.sh uninstall"
}

###############################################################################
# Restore PrintLastLog
###############################################################################

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
            echo "WARNING: /etc/ssh/sshd_config was changed after MOTD installation."
            echo "The installer will NOT overwrite your newer SSH configuration."
            echo
            echo "Original backup is still available at:"
            echo "  $SSH_BACKUP"
            return 0
        fi
    fi

    cp -f "$SSH_BACKUP" "$SSH_CONFIG"

    if ! sshd -t; then
        echo
        echo "ERROR: Restored SSH configuration failed validation."
        echo "Keeping the current configuration."
        return 1
    fi

    if systemctl reload ssh 2>/dev/null; then
        :
    elif systemctl reload sshd 2>/dev/null; then
        :
    else
        echo "WARNING: SSH could not be reloaded automatically."
    fi

    rm -f "$SSH_BACKUP" "$SSH_HASH"

    echo "Original SSH configuration restored."
}

###############################################################################
# Uninstall
###############################################################################

uninstall_motd() {
    clear

    echo "== Uninstall custom MOTD =="
    echo

    if [[ ! -d "$OLD_MOTD_DIR" ]]; then
        echo "No MOTD backup found at:"
        echo "  $OLD_MOTD_DIR"
        echo
        echo "Nothing to uninstall."
        exit 0
    fi

    echo "This will:"
    echo "  - remove the currently installed custom MOTD"
    echo "  - restore the original MOTD from old-motd"
    echo "  - restore PrintLastLog configuration if this installer changed it"
    echo
    read -r -p "Continue? [y/N] " reply

    if [[ ! "$reply" =~ ^([Yy])$ ]]; then
        echo "Uninstallation cancelled."
        exit 0
    fi

    echo
    echo "== Removing custom MOTD =="

    TEMP_CURRENT="${MOTD_DIR}/.motd-uninstall-current"
    mkdir -p "$TEMP_CURRENT"

    find "$MOTD_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name "old-motd" \
        ! -name ".motd-uninstall-current" \
        -exec mv {} "$TEMP_CURRENT"/ \;

    echo "Restoring original MOTD..."

    find "$OLD_MOTD_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec mv {} "$MOTD_DIR"/ \;

    rmdir "$OLD_MOTD_DIR" 2>/dev/null || true

    rm -rf "$TEMP_CURRENT"

    restore_printlastlog

    if [[ -d "$STATE_DIR" ]]; then
        rmdir "$STATE_DIR" 2>/dev/null || true
    fi

    echo
    echo "== Uninstallation complete =="
    echo "Original MOTD has been restored."
}

###############################################################################
# Main
###############################################################################

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
            1)
                install_motd
                ;;
            2)
                uninstall_motd
                ;;
            *)
                echo "Cancelled."
                ;;
        esac
        ;;

    *)
        echo "Usage:"
        echo "  sudo $0              # interactive menu"
        echo "  sudo $0 install      # install"
        echo "  sudo $0 uninstall    # uninstall and restore"
        exit 1
        ;;
esac

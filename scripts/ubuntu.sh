#!/bin/bash

set -euo pipefail

SCRIPT_VERSION="2.0.2"
SCRIPT_URL="https://raw.githubusercontent.com/T1aMat/motd/refs/heads/master/scripts/ubuntu.sh"
REPO_URL="https://github.com/T1aMat/motd/archive/refs/heads/master.tar.gz"

MOTD_DIR="/etc/update-motd.d"
OLD_MOTD_DIR="${MOTD_DIR}/old-motd"
STATE_DIR="/var/lib/t1amat-motd"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="${STATE_DIR}/sshd_config.backup"
SSH_HASH="${STATE_DIR}/sshd_config.installed.sha256"

# -----------------------------------------------------------------------------
# Colors / UI
# -----------------------------------------------------------------------------
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BLUE='\033[1;34m'

if [[ ! -t 1 ]]; then
    RESET=''; BOLD=''; DIM=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; WHITE=''; GRAY=''; BLUE=''
fi

SCRIPT_NAME="T1aMat MOTD"
UI_WIDTH=50

say() { printf '%b\n' "$*"; }

repeat_char() {
    local char="$1" count="$2" out="" i
    for ((i=0; i<count; i++)); do
        out+="$char"
    done
    printf '%s' "$out"
}

center_text() {
    local text="$1"
    local len=${#text}
    local left=$(( (UI_WIDTH - len) / 2 ))
    local right=$(( UI_WIDTH - len - left ))
    printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

banner() {
    local title="T1aMat MOTD"
    local subtitle="Ubuntu installer v${SCRIPT_VERSION}"
    clear 2>/dev/null || true
    say "${CYAN}${BOLD}╔$(repeat_char "═" "$UI_WIDTH")╗${RESET}"
    say "${CYAN}${BOLD}║${WHITE}$(center_text "$title")${CYAN}${BOLD}║${RESET}"
    say "${CYAN}${BOLD}║${GRAY}$(center_text "$subtitle")${CYAN}${BOLD}║${RESET}"
    say "${CYAN}${BOLD}╚$(repeat_char "═" "$UI_WIDTH")╝${RESET}"
    echo
}

section() {
    local title="$1"
    local prefix="┌─ ${title} "
    local filler=$(( UI_WIDTH - ${#prefix} ))
    (( filler < 0 )) && filler=0
    say "${CYAN}${BOLD}${prefix}$(repeat_char "─" "$filler")┐${RESET}"
}

section_end() {
    say "${CYAN}${BOLD}└$(repeat_char "─" "$UI_WIDTH")┘${RESET}"
}

fit_section() {
    local title="$1"
    local width="$2"
    local prefix="┌─ ${title} "
    local filler=$(( width - ${#prefix} ))
    (( filler < 0 )) && filler=0
    say "${CYAN}${BOLD}${prefix}$(repeat_char "─" "$filler")┐${RESET}"
}

fit_section_end() {
    local width="$1"
    say "${CYAN}${BOLD}└$(repeat_char "─" "$width")┘${RESET}"
}

info() { say "${CYAN}ℹ${RESET}  $*"; }
ok() { say "${GREEN}✔${RESET}  $*"; }
warn() { say "${YELLOW}⚠${RESET}  $*"; }
fail() { say "${RED}✖${RESET}  $*"; }
step() { say "${WHITE}${BOLD}›${RESET}  $*"; }

run_step() {
    local label="$1"
    shift
    local log pid rc i=0
    local spin='|/-\\'
    log="$(mktemp)"

    printf '  %b%-42s%b ' "$WHITE" "$label" "$RESET"
    "$@" >"$log" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf '\b[%c]' "${spin:i++%4:1}"
        sleep 0.12
    done

    if wait "$pid"; then
        printf '\b%b✔%b\n' "$GREEN" "$RESET"
        rm -f "$log"
        return 0
    fi

    printf '\b%b✖%b\n' "$RED" "$RESET"
    sed -n '1,20p' "$log"
    rm -f "$log"
    return 1
}

confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

pause_screen() {
    echo
    read -r -p "Press Enter to continue..." _
}

system_summary() {
    local pretty="unknown"
    [[ -f /etc/os-release ]] && . /etc/os-release && pretty="${PRETTY_NAME:-unknown}"

    local line1="  OS           : ${pretty}"
    local line2="  Hostname     : $(hostname 2>/dev/null || echo unknown)"
    local line3="  Kernel       : $(uname -r 2>/dev/null || echo unknown)"
    local line4="  Architecture : $(uname -m 2>/dev/null || echo unknown)"

    local width=${#line1}
    (( ${#line2} > width )) && width=${#line2}
    (( ${#line3} > width )) && width=${#line3}
    (( ${#line4} > width )) && width=${#line4}

    fit_section "System" "$width"
    say "  ${GRAY}$(printf '%-12s' 'OS')${RESET} : ${pretty}"
    say "  ${GRAY}$(printf '%-12s' 'Hostname')${RESET} : $(hostname 2>/dev/null || echo unknown)"
    say "  ${GRAY}$(printf '%-12s' 'Kernel')${RESET} : $(uname -r 2>/dev/null || echo unknown)"
    say "  ${GRAY}$(printf '%-12s' 'Architecture')${RESET} : $(uname -m 2>/dev/null || echo unknown)"
    fit_section_end "$width"
    echo
}

# -----------------------------------------------------------------------------
# Privilege handling
# -----------------------------------------------------------------------------
require_root() {
    if [[ "$EUID" -eq 0 ]]; then
        return 0
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        fail "Root privileges are required and sudo is not installed."
        exit 1
    fi

    info "Root privileges are required. Re-running with sudo..."
    echo

    if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]]; then
        exec sudo bash "$0" "$@"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        fail "curl is required to re-launch the remote installer."
        exit 1
    fi

    exec sudo bash -c 'curl -fsSL "$1" | bash -s -- "${@:2}"' _ "$SCRIPT_URL" "$@"
}

# -----------------------------------------------------------------------------
# SSH PrintLastLog
# -----------------------------------------------------------------------------
configure_printlastlog() {
    section "SSH login message"
    step "Checking PrintLastLog overrides..."

    local overrides
    overrides="$(grep -RnsE '^[[:space:]]*PrintLastLog[[:space:]]+' /etc/ssh/sshd_config.d 2>/dev/null || true)"

    if [[ -n "$overrides" ]]; then
        warn "An active PrintLastLog override exists in sshd_config.d."
        say "  ${GRAY}${overrides}${RESET}"
        info "The main sshd_config will not be modified."
        section_end
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
    print("changed")
else:
    print("unchanged")
PY

    if ! sshd -t; then
        fail "sshd configuration validation failed."
        [[ -f "$SSH_BACKUP" ]] && cp -f "$SSH_BACKUP" "$SSH_CONFIG"
        section_end
        exit 1
    fi

    if [[ -f "$SSH_BACKUP" ]]; then
        sha256sum "$SSH_CONFIG" > "$SSH_HASH"
        ok "PrintLastLog set to no."
    else
        ok "PrintLastLog was already set to no."
    fi

    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
        ok "SSH configuration reloaded."
    else
        warn "SSH configuration is valid, but automatic reload failed."
    fi

    say "  ${GRAY}Effective setting:${RESET} $(sshd -T | grep -i '^printlastlog ' || true)"
    section_end
}

# -----------------------------------------------------------------------------
# Header customization
# -----------------------------------------------------------------------------
configure_header() {
    local header_file="${MOTD_DIR}/00-header"
    local current_header=""
    local header_name

    section "MOTD header"

    if [[ ! -f "$header_file" ]]; then
        warn "$header_file was not found."
        section_end
        return 0
    fi

    current_header="$(python3 - "$header_file" <<'PY'
import re
from pathlib import Path
text = Path(__import__('sys').argv[1]).read_text()
m = re.search(r'toilet\s+-d\s+/etc/update-motd\.d/\s+-f\s+ivrit\s+(["\x27])(.*?)(?:\1)\s*$', text, re.M)
print(m.group(2) if m else "T1aMat")
PY
)"

    say "  ${GRAY}Current header:${RESET} ${WHITE}${current_header}${RESET}"
    echo
    read -r -p "  New header [Enter = keep ${current_header}]: " header_name

    if [[ -z "$header_name" ]]; then
        ok "Keeping header: ${current_header}"
        section_end
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
pattern = re.compile(r'(toilet\s+-d\s+/etc/update-motd\.d/\s+-f\s+ivrit\s+)(["\x27]).*?\2')
new_text, count = pattern.subn(lambda m: m.group(1) + json.dumps(header), text, count=1)
if count != 1:
    print("Could not find the expected toilet header line.")
    sys.exit(1)
path.write_text(new_text)
PY

    ok "Header changed to: ${header_name}"
    section_end
}

# -----------------------------------------------------------------------------
# MOTD backup / restore
# -----------------------------------------------------------------------------
backup_old_motd() {
    section "Existing MOTD"

    mkdir -p "$MOTD_DIR"

    if [[ -d "$OLD_MOTD_DIR" ]] && find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        ok "Original MOTD backup already exists."
        info "Keeping: $OLD_MOTD_DIR"
        find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name "old-motd" -exec rm -rf {} +
        section_end
        return 0
    fi

    mkdir -p "$OLD_MOTD_DIR"
    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name "old-motd" -exec mv {} "$OLD_MOTD_DIR"/ \;
    ok "Original MOTD backed up."
    say "  ${GRAY}Backup:${RESET} $OLD_MOTD_DIR"
    section_end
}

# -----------------------------------------------------------------------------
# Installation
# -----------------------------------------------------------------------------
install_motd() {
    banner
    system_summary

    section "Install MOTD"
    say "  This will install the custom T1aMat MOTD, preserve the"
    say "  existing MOTD, configure the SSH login message and let"
    say "  you choose the big ASCII header."
    section_end
    echo

    if ! confirm "Continue with installation?"; then
        warn "Installation cancelled."
        return 0
    fi

    echo
    section "Dependencies"
    run_step "Updating package lists" apt-get update -qq
    run_step "Installing toilet" apt-get install -y -qq toilet
    run_step "Installing colorized-logs" apt-get install -y -qq colorized-logs
    section_end

    local tmp_dir archive source_dir
    tmp_dir="$(mktemp -d)"
    archive="${tmp_dir}/motd.tar.gz"

    cleanup_install() { rm -rf "$tmp_dir"; }
    trap cleanup_install EXIT

    echo
    section "Downloading MOTD"
    printf '  ${WHITE}GitHub release${RESET}   '
    if ! curl --fail --location --progress-bar --show-error \
        --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2 \
        -o "$archive" "$REPO_URL"; then
        echo
        fail "Download failed. Check DNS, Internet connectivity and GitHub access."
        exit 1
    fi
    echo
    [[ -s "$archive" ]] || { fail "Downloaded archive is empty."; exit 1; }
    ok "Download complete."
    section_end

    echo
    section "Preparing files"
    run_step "Extracting MOTD archive" tar -xzf "$archive" -C "$tmp_dir"
    source_dir="${tmp_dir}/motd-master/motd"
    [[ -d "$source_dir" ]] || { fail "Unexpected archive structure."; exit 1; }
    ok "MOTD archive is ready."
    section_end

    echo
    backup_old_motd

    echo
    section "Installing MOTD"
    run_step "Copying MOTD files" cp -a "$source_dir/." "$MOTD_DIR/"
    run_step "Setting executable permissions" bash -c 'chmod +x /etc/update-motd.d/* 2>/dev/null || true'
    section_end

    echo
    configure_header
    echo
    configure_printlastlog

    echo
    section "Installation complete"
    ok "T1aMat MOTD is installed."
    say "  ${GRAY}MOTD directory${RESET} : $MOTD_DIR"
    say "  ${GRAY}Original backup${RESET}: $OLD_MOTD_DIR"
    echo
    say "${GREEN}${BOLD}Enjoy your new MOTD.${RESET}"
    section_end
}

# -----------------------------------------------------------------------------
# SSH restore
# -----------------------------------------------------------------------------
restore_printlastlog() {
    section "Restoring SSH configuration"

    if [[ ! -f "$SSH_BACKUP" ]]; then
        info "No SSH configuration backup was created by this installer."
        section_end
        return 0
    fi

    if [[ -f "$SSH_HASH" ]]; then
        local current_hash installed_hash
        current_hash="$(sha256sum "$SSH_CONFIG" | awk '{print $1}')"
        installed_hash="$(awk '{print $1}' "$SSH_HASH")"
        if [[ "$current_hash" != "$installed_hash" ]]; then
            warn "$SSH_CONFIG was changed after installation."
            info "The newer configuration will not be overwritten."
            info "Original backup: $SSH_BACKUP"
            section_end
            return 0
        fi
    fi

    cp -f "$SSH_BACKUP" "$SSH_CONFIG"
    if ! sshd -t; then
        fail "Restored SSH configuration failed validation."
        return 1
    fi

    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
        ok "Original SSH configuration restored."
    else
        warn "SSH restored, but automatic reload failed."
    fi

    rm -f "$SSH_BACKUP" "$SSH_HASH"
    section_end
}

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
uninstall_motd() {
    banner
    system_summary

    section "Uninstall MOTD"
    say "  The custom MOTD will be removed and the original MOTD"
    say "  will be restored from the protected backup."
    say "  SSH PrintLastLog will also be restored when safe."
    section_end
    echo

    if [[ ! -d "$OLD_MOTD_DIR" ]]; then
        warn "No original MOTD backup was found."
        info "Nothing to restore."
        return 0
    fi

    if ! confirm "Continue with uninstall?"; then
        warn "Uninstall cancelled."
        return 0
    fi

    echo
    section "Restoring MOTD"
    local temp_current
    temp_current="$(mktemp -d)"
    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name "old-motd" -exec mv {} "$temp_current"/ \;
    find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 -exec mv {} "$MOTD_DIR"/ \;
    rmdir "$OLD_MOTD_DIR" 2>/dev/null || true
    rm -rf "$temp_current"
    ok "Original MOTD restored."
    section_end

    echo
    restore_printlastlog
    rmdir "$STATE_DIR" 2>/dev/null || true

    echo
    section "Complete"
    ok "T1aMat MOTD has been uninstalled."
    say "${GREEN}${BOLD}The server is back to its previous MOTD state.${RESET}"
    section_end
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
show_menu() {
    banner
    system_summary

    local line1="  1) Install / update MOTD"
    local line2="  2) Uninstall / restore MOTD"
    local line3="  0) Exit"
    local width=${#line1}
    (( ${#line2} > width )) && width=${#line2}
    (( ${#line3} > width )) && width=${#line3}

    fit_section "Main menu" "$width"
    say "  ${YELLOW}1)${RESET} Install / update MOTD"
    say "  ${YELLOW}2)${RESET} Uninstall / restore MOTD"
    say "  ${YELLOW}0)${RESET} Exit"
    fit_section_end "$width"
    echo

    local choice
    read -r -p "Select an option [0-2]: " choice
    case "$choice" in
        1) install_motd ;;
        2) uninstall_motd ;;
        0) info "Goodbye." ;;
        *) warn "Invalid choice."; pause_screen; show_menu ;;
    esac
}

usage() {
    echo "Usage:"
    echo "  bash <(curl -Ls $SCRIPT_URL)"
    echo "  bash <(curl -Ls $SCRIPT_URL) install"
    echo "  bash <(curl -Ls $SCRIPT_URL) uninstall"
}

main() {
    require_root "$@"
    case "${1:-}" in
        install) install_motd ;;
        uninstall|remove) uninstall_motd ;;
        "") show_menu ;;
        -h|--help) usage ;;
        *) fail "Unknown option: $1"; usage; exit 1 ;;
    esac
}

main "$@"

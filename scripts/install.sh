#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="3.1.0"
SCRIPT_URL="https://raw.githubusercontent.com/T1aMat/motd/refs/heads/master/scripts/install.sh"
REPO_URL="https://github.com/T1aMat/motd/archive/refs/heads/master.tar.gz"

UI_WIDTH=50
MOTD_DIR="/etc/update-motd.d"
OLD_MOTD_DIR="${MOTD_DIR}/old-motd"
CONFIG_FILE="/etc/t1amat-motd.conf"
STATE_DIR="/var/lib/t1amat-motd"
MANIFEST_FILE="${STATE_DIR}/installed-manifest.sha256"
CONFIG_BACKUP="${STATE_DIR}/t1amat-motd.conf.backup"
CONFIG_STATE="${STATE_DIR}/config.state"
ETC_MOTD_BACKUP="${STATE_DIR}/etc-motd.backup"
ETC_MOTD_STATE="${STATE_DIR}/etc-motd.state"
COLORS_STATE="${STATE_DIR}/colors.state"
COLORS_HASH="${STATE_DIR}/colors.installed.sha256"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-t1amat-motd.conf"
SSHD_DROPIN_HASH="${STATE_DIR}/sshd-dropin.sha256"

OS_FLAVOR=""
USE_ETC_MOTD_LINK=0
YES_MODE=0
DRY_RUN=0
HEADER_OVERRIDE=""
COMMAND=""

RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'

if [[ ! -t 1 ]]; then
    RESET=''; BOLD=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; WHITE=''; GRAY=''
fi

say() { printf '%b\n' "$*"; }

repeat_char() {
    local char="$1"
    local count="$2"
    local out=""
    local i
    for ((i = 0; i < count; i++)); do
        out+="$char"
    done
    printf '%s' "$out"
}

center_text() {
    local text="$1"
    local len=${#text}
    local left=$(( (UI_WIDTH - len) / 2 ))
    local right=$(( UI_WIDTH - len - left ))
    (( left < 0 )) && left=0
    (( right < 0 )) && right=0
    printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

banner() {
    local title="T1aMat MOTD"
    local subtitle="Universal installer v${SCRIPT_VERSION}"
    clear 2>/dev/null || true
    say "${CYAN}${BOLD}╔$(repeat_char '═' "$UI_WIDTH")╗${RESET}"
    say "${CYAN}${BOLD}║${WHITE}$(center_text "$title")${CYAN}${BOLD}║${RESET}"
    say "${CYAN}${BOLD}║${GRAY}$(center_text "$subtitle")${CYAN}${BOLD}║${RESET}"
    say "${CYAN}${BOLD}╚$(repeat_char '═' "$UI_WIDTH")╝${RESET}"
    echo
}

section() {
    local title="$1"
    local d=$((UI_WIDTH - ${#title} - 2))
    local l=$((d / 2))
    local r=$((d - l))
    (( l < 0 )) && l=0
    (( r < 0 )) && r=0
    say "${CYAN}${BOLD}┌$(repeat_char '─' "$l") ${title} $(repeat_char '─' "$r")┐${RESET}"
}

section_end() { say "${CYAN}${BOLD}└$(repeat_char '─' "$UI_WIDTH")┘${RESET}"; }
info() { say "${CYAN}ℹ${RESET}  $*"; }
ok() { say "${GREEN}✔${RESET}  $*"; }
warn() { say "${YELLOW}⚠${RESET}  $*"; }
fail() { say "${RED}✖${RESET}  $*"; }

run_step() {
    local label="$1"
    shift
    local log pid spinner='|/-\\' i=0
    log="$(mktemp)"

    if [[ ! -t 1 ]]; then
        printf '  %-42s ' "$label"
        if "$@" >"$log" 2>&1; then
            printf '%b✔%b\n' "$GREEN" "$RESET"
            rm -f "$log"
            return 0
        fi
        printf '%b✖%b\n' "$RED" "$RESET"
        sed -n '1,25p' "$log"
        rm -f "$log"
        return 1
    fi

    printf '  %-42s [%c]' "$label" "${spinner:0:1}"
    "$@" >"$log" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.12
        i=$((i + 1))
        printf '\r  %-42s [%c]' "$label" "${spinner:i%4:1}"
    done

    if wait "$pid"; then
        printf '\r  %-42s [%b✔%b]\n' "$label" "$GREEN" "$RESET"
        rm -f "$log"
        return 0
    fi

    printf '\r  %-42s [%b✖%b]\n' "$label" "$RED" "$RESET"
    sed -n '1,25p' "$log"
    rm -f "$log"
    return 1
}

confirm() {
    local prompt="$1"
    local answer

    if (( YES_MODE )); then
        return 0
    fi

    if [[ ! -r /dev/tty ]]; then
        fail "Interactive confirmation requires a terminal. Use --yes for automation."
        return 1
    fi

    read -r -p "${prompt} [Y/n] " answer < /dev/tty
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall|remove|check|status)
                COMMAND="$1"
                shift
                ;;
            --yes|-y)
                YES_MODE=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --header)
                [[ $# -ge 2 ]] || { fail "--header requires a value."; exit 1; }
                HEADER_OVERRIDE="$2"
                shift 2
                ;;
            --header=*)
                HEADER_OVERRIDE="${1#*=}"
                shift
                ;;
            -v|--version)
                echo "$SCRIPT_VERSION"
                exit 0
                ;;
            -h|--help)
                cat <<USAGE
Usage:
  bash <(curl -fsSL $SCRIPT_URL)
  bash <(curl -fsSL $SCRIPT_URL) install
  bash <(curl -fsSL $SCRIPT_URL) install --yes
  bash <(curl -fsSL $SCRIPT_URL) install --header "My Server"
  bash <(curl -fsSL $SCRIPT_URL) install --dry-run
  bash <(curl -fsSL $SCRIPT_URL) uninstall --yes
  bash <(curl -fsSL $SCRIPT_URL) check
USAGE
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
}

require_root() {
    if [[ "$EUID" -eq 0 ]]; then
        return 0
    fi

    command -v sudo >/dev/null 2>&1 || {
        fail "Root privileges are required and sudo is not installed."
        exit 1
    }

    command -v curl >/dev/null 2>&1 || {
        fail "curl is required when launching the installer as a non-root user."
        exit 1
    }

    local tmp rc
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
        fail "Could not download the installer for privileged re-execution."
        exit 1
    fi

    sudo bash "$tmp" "$@"
    rc=$?
    rm -f "$tmp"
    trap - RETURN
    exit "$rc"
}

is_raspberry_pi_hardware() {
    [[ -r /proc/device-tree/model ]] || return 1
    tr -d '\0' < /proc/device-tree/model 2>/dev/null | grep -qi 'Raspberry Pi'
}

detect_os() {
    [[ -f /etc/os-release ]] || { fail "/etc/os-release was not found."; exit 1; }
    . /etc/os-release

    local id="${ID:-}" like="${ID_LIKE:-}"

    if [[ "$id" == ubuntu || "$like" == *ubuntu* ]]; then
        OS_FLAVOR="Ubuntu"
        USE_ETC_MOTD_LINK=0
    elif is_raspberry_pi_hardware && [[ "$id" == debian || "$id" == raspbian || "$like" == *debian* ]]; then
        OS_FLAVOR="Raspberry Pi OS"
        USE_ETC_MOTD_LINK=1
    elif [[ "$id" == debian || "$like" == *debian* ]]; then
        OS_FLAVOR="Debian"
        USE_ETC_MOTD_LINK=1
    else
        fail "Unsupported operating system: ${PRETTY_NAME:-$id}"
        say "  ${GRAY}Supported: Ubuntu, Debian, Raspberry Pi OS${RESET}"
        exit 1
    fi
}

system_summary() {
    . /etc/os-release 2>/dev/null || true
    section "System"
    say "  ${GRAY}OS           :${RESET} ${PRETTY_NAME:-unknown}"
    say "  ${GRAY}Hostname     :${RESET} $(hostname 2>/dev/null || echo unknown)"
    say "  ${GRAY}Kernel       :${RESET} $(uname -r 2>/dev/null || echo unknown)"
    say "  ${GRAY}Architecture :${RESET} $(uname -m 2>/dev/null || echo unknown)"
    say "  ${GRAY}MOTD profile :${RESET} ${OS_FLAVOR}"
    section_end
    echo
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

install_dependencies() {
    local missing=()

    if ! package_installed toilet; then
        missing+=(toilet)
    fi

    if ((${#missing[@]} == 0)); then
        ok "Required packages are already installed."
        return 0
    fi

    run_step "Updating package lists" apt-get update -qq
    for pkg in "${missing[@]}"; do
        run_step "Installing $pkg" apt-get install -y -qq "$pkg"
    done
}

ensure_tools() {
    local tool
    for tool in curl tar sha256sum timeout awk sed; do
        command -v "$tool" >/dev/null 2>&1 || {
            fail "Required command not found: $tool"
            exit 1
        }
    done
}

backup_config_if_needed() {
    mkdir -p "$STATE_DIR"

    if [[ ! -e "$CONFIG_FILE" ]]; then
        printf 'absent\n' > "$CONFIG_STATE"
        return 0
    fi

    if [[ -f "$CONFIG_STATE" ]]; then
        return 0
    fi

    printf 'present\n' > "$CONFIG_STATE"
    if [[ ! -f "$CONFIG_BACKUP" ]]; then
        cp -a "$CONFIG_FILE" "$CONFIG_BACKUP"
    fi
}

extract_existing_header() {
    local file="$MOTD_DIR/00-header"
    [[ -f "$file" ]] || return 1

    sed -n 's/.*toilet.*-f[[:space:]]\+ivrit[[:space:]]*["'"'"']\(.*\)["'"'"'].*/\1/p' "$file" | head -n1
}

extract_existing_services() {
    local file="$MOTD_DIR/09-services"
    [[ -f "$file" ]] || return 1

    awk '
        /services_order\+=\("[^"]+"\)/ {
            line=$0
            sub(/^.*services_order\+=\("/, "", line)
            sub(/"\).*$/, "", line)
            if (line != "") print line
        }
        /MOTD_SERVICES[[:space:]]*\+=/ {
            line=$0
            sub(/^.*MOTD_SERVICES[[:space:]]*\+=\(\?/, "", line)
        }
    ' "$file"
}

write_default_config() {
    local header="T1aMat"
    local existing_header
    local services=(ssh ufw docker nginx)

    if [[ ! -f "$CONFIG_FILE" ]]; then
        existing_header="$(extract_existing_header 2>/dev/null || true)"
        [[ -n "$existing_header" ]] && header="$existing_header"

        local extracted=()
        mapfile -t extracted < <(extract_existing_services 2>/dev/null || true)
        if ((${#extracted[@]} > 0)); then
            services=("${extracted[@]}")
        fi

        local qheader qservice
        printf -v qheader '%q' "$header"

        {
            echo '# T1aMat MOTD configuration'
            echo '# This file is preserved across MOTD updates.'
            echo
            echo "MOTD_HEADER=$qheader"
            echo
            echo 'MOTD_SERVICES=('
            for qservice in "${services[@]}"; do
                printf '    %q\n' "$qservice"
            done
            echo ')'
            echo
            echo 'MOTD_DISKS=('
            printf '    %q\n' '/'
            echo ')'
            echo
            echo 'WARN_PCT=80'
            echo 'CRIT_PCT=90'
            echo 'SERVICES_WIDTH=78'
            echo 'DOCKER_TIMEOUT=3'
            echo 'SSH_LOGIN_LOOKBACK=200'
        } > "$CONFIG_FILE"

        chmod 0644 "$CONFIG_FILE"
        ok "Created $CONFIG_FILE"
    fi
}

apply_header() {
    local current="T1aMat"
    local header="${HEADER_OVERRIDE}"

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    current="${MOTD_HEADER:-T1aMat}"

    if [[ -n "$HEADER_OVERRIDE" ]]; then
        header="$HEADER_OVERRIDE"
    elif (( YES_MODE )); then
        header="$current"
    else
        say "  ${GRAY}Current header:${RESET} ${WHITE}${current}${RESET}"
        if [[ -r /dev/tty ]]; then
            read -r -p "  New header [Enter = keep ${current}]: " header < /dev/tty
        else
            header="$current"
        fi
        [[ -z "$header" ]] && header="$current"
    fi

    local q
    printf -v q '%q' "$header"
    sed -i "s/^MOTD_HEADER=.*/MOTD_HEADER=$q/" "$CONFIG_FILE"
    ok "Header: $header"
}

initial_backup() {
    mkdir -p "$MOTD_DIR" "$STATE_DIR"

    if [[ -d "$OLD_MOTD_DIR" ]] && find "$OLD_MOTD_DIR" -type f -print -quit | grep -q .; then
        return 0
    fi

    if [[ -f "$MOTD_DIR/colors.txt" ]]; then
        printf 'present\n' > "$COLORS_STATE"
    else
        printf 'absent\n' > "$COLORS_STATE"
    fi

    mkdir -p "$OLD_MOTD_DIR"
    # colors.txt is user configuration. Keep an existing copy in place so an
    # install/update never destroys a customized color scheme.
    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 \
        ! -name old-motd \
        ! -name colors.txt \
        -exec mv {} "$OLD_MOTD_DIR"/ \\;
    ok "Original MOTD backed up to $OLD_MOTD_DIR"
}

manifest_hash() {
    local path="$1"
    [[ -f "$MANIFEST_FILE" ]] || return 1
    awk -v p="$path" '$2 == p {print $1; exit}' "$MANIFEST_FILE"
}



backup_etc_motd() {
    (( USE_ETC_MOTD_LINK )) || return 0
    mkdir -p "$STATE_DIR"

    [[ -f "$ETC_MOTD_STATE" ]] && return 0

    if [[ -L /etc/motd ]]; then
        printf 'symlink\n%s\n' "$(readlink /etc/motd)" > "$ETC_MOTD_STATE"
        cp -a /etc/motd "$ETC_MOTD_BACKUP"
    elif [[ -e /etc/motd ]]; then
        printf 'file\n' > "$ETC_MOTD_STATE"
        cp -a /etc/motd "$ETC_MOTD_BACKUP"
    else
        printf 'absent\n' > "$ETC_MOTD_STATE"
    fi
}

install_etc_motd() {
    (( USE_ETC_MOTD_LINK )) || return 0
    backup_etc_motd

    if [[ -L /etc/motd ]] && [[ "$(readlink /etc/motd)" == "/var/run/motd" ]]; then
        return 0
    fi

    if [[ -e /etc/motd || -L /etc/motd ]]; then
        rm -f /etc/motd
    fi
    ln -s /var/run/motd /etc/motd
}

restore_etc_motd() {
    (( USE_ETC_MOTD_LINK )) || return 0
    [[ -f "$ETC_MOTD_STATE" ]] || return 0

    local state
    state="$(head -n1 "$ETC_MOTD_STATE")"

    if [[ -L /etc/motd ]] && [[ "$(readlink /etc/motd)" == "/var/run/motd" ]]; then
        rm -f /etc/motd
    elif [[ -e /etc/motd || -L /etc/motd ]]; then
        warn "/etc/motd was changed after installation; leaving it untouched."
        return 0
    fi

    case "$state" in
        absent)
            ;;
        file|symlink)
            cp -a "$ETC_MOTD_BACKUP" /etc/motd
            ;;
    esac

    rm -f "$ETC_MOTD_BACKUP" "$ETC_MOTD_STATE"
}

ensure_sshd_include() {
    local main="$1"
    grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' "$main"
}

configure_printlastlog() {
    section "SSH login message"

    if ! command -v sshd >/dev/null 2>&1 || [[ ! -f /etc/ssh/sshd_config ]]; then
        info "OpenSSH server not detected; PrintLastLog skipped."
        section_end
        return 0
    fi

    mkdir -p /etc/ssh/sshd_config.d "$STATE_DIR"

    if [[ -e "$SSHD_DROPIN" ]] && ! grep -q 'Managed by T1aMat MOTD' "$SSHD_DROPIN"; then
        warn "$SSHD_DROPIN already exists and is not managed by T1aMat MOTD."
        info "Leaving it untouched."
        section_end
        return 0
    fi

    if ! ensure_sshd_include /etc/ssh/sshd_config; then
        warn "sshd_config does not include /etc/ssh/sshd_config.d/*.conf."
        info "The SSH drop-in will not be created because it would be ineffective."
        section_end
        return 0
    fi

    cat > "$SSHD_DROPIN" <<'EOF_DROPIN'
# Managed by T1aMat MOTD
PrintLastLog no
EOF_DROPIN

    if ! sshd -t; then
        rm -f "$SSHD_DROPIN"
        fail "sshd configuration validation failed; drop-in removed."
        section_end
        return 1
    fi

    sha256sum "$SSHD_DROPIN" > "$SSHD_DROPIN_HASH"

    local effective
    effective="$(sshd -T 2>/dev/null | awk 'tolower($1)=="printlastlog" {print tolower($2); exit}')"
    if [[ "$effective" != "no" ]]; then
        warn "PrintLastLog is still $effective after installing the drop-in."
        info "An earlier sshd setting is taking precedence."
    else
        ok "PrintLastLog disabled through sshd drop-in."
    fi

    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
        ok "SSH configuration reloaded."
    else
        warn "SSH configuration is valid, but automatic reload failed."
    fi

    section_end
}

restore_colors() {
    [[ -f "$COLORS_STATE" ]] || return 0

    local state
    state="$(cat "$COLORS_STATE")"

    if [[ "$state" == "absent" ]]; then
        if [[ -f "$MOTD_DIR/colors.txt" ]]; then
            if [[ -f "$COLORS_HASH" ]]; then
                local current_hash saved_hash
                current_hash="$(sha256sum "$MOTD_DIR/colors.txt" | awk '{print $1}')"
                saved_hash="$(awk '{print $1}' "$COLORS_HASH")"
                if [[ "$current_hash" == "$saved_hash" ]]; then
                    rm -f "$MOTD_DIR/colors.txt"
                    ok "Installer-created colors.txt removed."
                else
                    warn "colors.txt was modified after installation; leaving it untouched."
                fi
            else
                warn "Original colors.txt was absent, but no installation hash exists; leaving it untouched."
            fi
        fi
    fi

    rm -f "$COLORS_STATE" "$COLORS_HASH"
}

restore_sshd_dropin() {
    [[ -f "$SSHD_DROPIN" ]] || return 0

    if ! grep -q 'Managed by T1aMat MOTD' "$SSHD_DROPIN"; then
        return 0
    fi

    if [[ -f "$SSHD_DROPIN_HASH" ]]; then
        local current_hash saved_hash
        current_hash="$(sha256sum "$SSHD_DROPIN" | awk '{print $1}')"
        saved_hash="$(awk '{print $1}' "$SSHD_DROPIN_HASH")"
        if [[ "$current_hash" != "$saved_hash" ]]; then
            warn "$SSHD_DROPIN was modified after installation; leaving it untouched."
            return 0
        fi
    fi

    rm -f "$SSHD_DROPIN" "$SSHD_DROPIN_HASH"
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        ok "T1aMat SSH drop-in removed."
    fi
}



restore_motd() {
    [[ -d "$OLD_MOTD_DIR" ]] || { warn "No original MOTD backup found."; return 0; }
    [[ -f "$MANIFEST_FILE" ]] || { warn "No installation manifest found; refusing a destructive restore."; return 0; }

    section "Restoring MOTD"

    local old_hash rel target backup_file current_hash
    while read -r old_hash rel; do
        [[ -n "$rel" ]] || continue
        target="$MOTD_DIR/$rel"
        backup_file="$OLD_MOTD_DIR/$rel"

        if [[ -f "$target" ]]; then
            current_hash="$(sha256sum "$target" | awk '{print $1}')"
            if [[ "$current_hash" != "$old_hash" ]]; then
                warn "Preserving modified module: $rel"
                continue
            fi
        fi

        if [[ -f "$backup_file" ]]; then
            mkdir -p "$(dirname "$target")"
            cp -a "$backup_file" "$target"
            rm -f "$backup_file"
        elif [[ -f "$target" ]]; then
            rm -f "$target"
        fi
    done < "$MANIFEST_FILE"

    # Restore any legacy backup files that were never in the manifest.
    while IFS= read -r -d '' backup_file; do
        rel="${backup_file#"$OLD_MOTD_DIR"/}"
        target="$MOTD_DIR/$rel"
        if [[ ! -e "$target" ]]; then
            mkdir -p "$(dirname "$target")"
            cp -a "$backup_file" "$target"
            rm -f "$backup_file"
        fi
    done < <(find "$OLD_MOTD_DIR" -type f -print0)

    find "$OLD_MOTD_DIR" -depth -type d -empty -delete 2>/dev/null || true
    chmod 0755 "$MOTD_DIR"/* 2>/dev/null || true
    ok "Original MOTD files restored where safe."
    section_end
}

handle_config_uninstall() {
    section "Restoring configuration"

    if [[ -f "$CONFIG_STATE" ]] && grep -qx 'present' "$CONFIG_STATE"; then
        if [[ -f "$CONFIG_BACKUP" ]]; then
            cp -a "$CONFIG_BACKUP" "$CONFIG_FILE"
            ok "Original MOTD configuration restored."
        fi
    else
        rm -f "$CONFIG_FILE"
        ok "T1aMat MOTD configuration removed."
    fi

    rm -f "$CONFIG_BACKUP" "$CONFIG_STATE"
    section_end
}

prepare_install() {
    mkdir -p "$STATE_DIR" "$MOTD_DIR"
    backup_config_if_needed
    write_default_config
}

migrate_and_configure() {
    prepare_install
    apply_header
}

download_source() {
    local tmp_dir="$1"
    local archive="$2"

    section "Downloading MOTD"
    printf '  %bGitHub%b ' "$WHITE" "$RESET"

    if ! curl --fail --location --progress-bar --show-error \
        --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2 \
        -o "$archive" "$REPO_URL"; then
        echo
        fail "Download failed. Check DNS, Internet connectivity and GitHub access."
        section_end
        return 1
    fi

    echo
    if [[ ! -s "$archive" ]]; then
        fail "Downloaded archive is empty."
        section_end
        return 1
    fi

    if ! run_step "Extracting MOTD archive" tar -xzf "$archive" --strip-components=1 -C "$tmp_dir"; then
        section_end
        return 1
    fi

    [[ -d "$tmp_dir/motd" ]] || { fail "Downloaded archive has no motd directory."; section_end; return 1; }
    ok "MOTD source ready."
    section_end
}

install_motd() {
    banner
    system_summary

    section "Install MOTD"
    say "  ${GRAY}Profile:${RESET} ${WHITE}${OS_FLAVOR}${RESET}"
    say "  Existing MOTD files are preserved on update when modified."
    say "  Configuration lives in ${CONFIG_FILE}."
    section_end
    echo

    if ! confirm "Continue with installation?"; then
        warn "Installation cancelled."
        return 0
    fi

    if (( DRY_RUN )); then
        echo
        section "Dry run"
        say "  Would install: toilet"
        say "  Would sync     : ${MOTD_DIR}"
        say "  Would configure: ${CONFIG_FILE}"
        say "  Would configure: ${SSHD_DROPIN} (when effective)"
        say "  Would update    : /etc/motd on Debian/Pi profiles"
        section_end
        return 0
    fi

    echo
    section "Dependencies"
    install_dependencies
    section_end

    local tmp_dir archive
    tmp_dir="$(mktemp -d)"
    archive="${tmp_dir}/motd.tar.gz"

    trap "rm -rf -- '$tmp_dir'" EXIT

    echo
    download_source "$tmp_dir" "$archive"

    echo
    section "Configuration"
    migrate_and_configure
    section_end

    echo
    section "Installing MOTD"
    sync_motd_files "$tmp_dir/motd"
    ok "MOTD files synchronized."
    if (( USE_ETC_MOTD_LINK )); then
        install_etc_motd
        ok "/etc/motd linked to /var/run/motd for ${OS_FLAVOR}."
    fi
    section_end

    echo
    configure_printlastlog

    rm -rf "$tmp_dir"
    trap - EXIT

    echo
    section "Installation complete"
    ok "T1aMat MOTD ${SCRIPT_VERSION} installed."
    say "  ${GRAY}OS profile   :${RESET} $OS_FLAVOR"
    say "  ${GRAY}Config       :${RESET} $CONFIG_FILE"
    say "  ${GRAY}Original MOTD:${RESET} $OLD_MOTD_DIR"
    echo
    say "${GREEN}${BOLD}Enjoy your new MOTD.${RESET}"
    section_end
}

uninstall_motd() {
    banner
    detect_os
    system_summary

    section "Uninstall MOTD"
    say "  Modified files are preserved instead of being destroyed."
    say "  Original files will be restored where it is safe to do so."
    section_end
    echo

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "No T1aMat MOTD installation manifest found."
        info "Nothing will be removed destructively."
        return 0
    fi

    if ! confirm "Continue with uninstall?"; then
        warn "Uninstall cancelled."
        return 0
    fi

    if (( DRY_RUN )); then
        section "Dry run"
        say "  Would restore MOTD modules from: $OLD_MOTD_DIR"
        say "  Would remove: $CONFIG_FILE"
        say "  Would remove: $SSHD_DROPIN (only when unmodified)"
        section_end
        return 0
    fi

    echo
    restore_motd
    echo
    restore_colors
    echo
    restore_etc_motd
    echo
    restore_sshd_dropin
    echo
    handle_config_uninstall

    rm -f "$MANIFEST_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true

    section "Complete"
    ok "T1aMat MOTD has been uninstalled."
    section_end
}

check_installation() {
    banner
    detect_os
    system_summary

    section "Installation check"
    local problems=0
    local effective config_header

    if [[ -f "$CONFIG_FILE" ]]; then
        ok "Configuration file exists."
    else
        warn "Configuration file is missing."
        problems=$((problems + 1))
    fi

    if [[ -f "$MOTD_DIR/00-header" && -f "$MOTD_DIR/01-last-login" ]]; then
        ok "Core MOTD modules are installed."
    else
        warn "Core MOTD modules are incomplete."
        problems=$((problems + 1))
    fi

    if [[ -x "$MOTD_DIR/01-last-login" ]]; then
        ok "01-last-login is executable."
    else
        warn "01-last-login is not executable."
        problems=$((problems + 1))
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        config_header="${MOTD_HEADER:-T1aMat}"
        ok "Header configured as: $config_header"
    fi

    if [[ -f "$SSHD_DROPIN" ]] && grep -q 'Managed by T1aMat MOTD' "$SSHD_DROPIN" && command -v sshd >/dev/null 2>&1; then
        effective="$(sshd -T 2>/dev/null | awk 'tolower($1)=="printlastlog" {print tolower($2); exit}')"
        if [[ "$effective" == "no" ]]; then
            ok "SSH PrintLastLog is disabled."
        else
            warn "SSH PrintLastLog effective value: ${effective:-unknown}"
            problems=$((problems + 1))
        fi
    else
        info "T1aMat SSH PrintLastLog drop-in is not installed."
    fi

    if (( USE_ETC_MOTD_LINK )); then
        if [[ -L /etc/motd ]] && [[ "$(readlink /etc/motd)" == "/var/run/motd" ]]; then
            ok "/etc/motd is linked to /var/run/motd."
        else
            warn "/etc/motd is not linked as expected for ${OS_FLAVOR}."
            problems=$((problems + 1))
        fi
    fi

    if [[ -f "$MANIFEST_FILE" ]]; then
        ok "Installation manifest exists."
    else
        warn "Installation manifest is missing."
        problems=$((problems + 1))
    fi

    echo
    if (( problems == 0 )); then
        ok "Installation check passed."
    else
        warn "Installation check found ${problems} issue(s)."
    fi
    section_end
}

show_menu() {
    banner
    detect_os
    system_summary

    section "Main menu"
    say "  ${YELLOW}1)${RESET} Install / update MOTD"
    say "  ${YELLOW}2)${RESET} Uninstall / restore MOTD"
    say "  ${YELLOW}3)${RESET} Check installation"
    say "  ${YELLOW}0)${RESET} Exit"
    section_end
    echo

    local choice
    read -r -p 'Select an option [0-3]: ' choice < /dev/tty
    case "$choice" in
        1) install_motd ;;
        2) uninstall_motd ;;
        3) check_installation ;;
        0) info "Goodbye." ;;
        *) warn "Invalid choice."; show_menu ;;
    esac
}

main() {
    parse_args "$@"
    require_root "$@"
    ensure_tools
    detect_os

    case "$COMMAND" in
        install)
            install_motd
            ;;
        uninstall|remove)
            uninstall_motd
            ;;
        check|status)
            check_installation
            ;;
        "")
            show_menu
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"

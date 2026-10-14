#!/bin/bash
set -euo pipefail
set -E

SCRIPT_VERSION="3.2.1"
SCRIPT_URL="https://raw.githubusercontent.com/T1aMat/motd/refs/heads/master/scripts/install.sh"
REPO_URL="https://github.com/T1aMat/motd/archive/refs/heads/master.tar.gz"

UI_WIDTH=54
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
LEGACY_MOTD_DIR="${STATE_DIR}/legacy-motd"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-t1amat-motd.conf"
SSHD_DROPIN_HASH="${STATE_DIR}/sshd-dropin.sha256"

OS_FLAVOR=""
USE_ETC_MOTD_LINK=0
YES_MODE=0
DRY_RUN=0
HEADER_OVERRIDE=""
COMMAND=""
TEMP_DIR=""
CONFIG_CREATED=0

KNOWN_MODULES=(
    last-login
    uptime
    load-average
    memory
    disk-usage
    logins
    processes
    services
    docker
)

declare -A MODULE_LABELS=(
    [last-login]="Last login"
    [uptime]="Uptime"
    [load-average]="Load averages"
    [memory]="Memory"
    [disk-usage]="Disk usage"
    [logins]="SSH logins"
    [processes]="Processes"
    [services]="Services"
    [docker]="Docker containers"
)

KNOWN_SERVICES=(
    ssh
    ufw
    docker
    nginx
    caddy
    fail2ban
    xray
    unbound
    haproxy
    keepalived
    etcd
    kubelet
    postgresql
    redis-server
    kafka
    patroni
    remnanode
    remnawave
    dozzle-agent
    beszel-agent
)

declare -A SERVICE_LABELS=(
    [ssh]="SSH"
    [sshd]="SSH"
    [ufw]="UFW"
    [docker]="Docker"
    [nginx]="nginx"
    [caddy]="Caddy"
    [fail2ban]="Fail2ban"
    [xray]="Xray"
    [unbound]="Unbound"
    [haproxy]="HAProxy"
    [keepalived]="Keepalived"
    [etcd]="etcd"
    [kubelet]="kubelet"
    [postgresql]="PostgreSQL"
    [redis-server]="Redis"
    [kafka]="Kafka"
    [patroni]="Patroni"
    [remnanode]="RemnaNode"
    [remnawave]="Remnawave"
    [dozzle-agent]="Dozzle Agent"
    [beszel-agent]="Beszel Agent"
)

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

on_error() {
    local rc="$1" line="$2" cmd="$3"
    [[ "${BASHPID:-$$}" == "$$" ]] || return 0
    printf '\n\033[1;31m✖\033[0m  Unexpected error (exit %s) at line %s:\n   %s\n' \
        "$rc" "$line" "$cmd" >&2
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

cleanup_temp() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup_temp EXIT

say() { printf '%b\n' "$*"; }
status_line() {
    local color="$1" glyph="$2" message="$3"
    printf '  [%b %s %b] %s\n' "$color" "$glyph" "$RESET" "$message"
}
info() { status_line "$CYAN" "ℹ" "$*"; }
ok() { status_line "$GREEN" "✔" "$*"; }
warn() { status_line "$YELLOW" "⚠" "$*"; }
fail() { status_line "$RED" "✖" "$*"; }

repeat_char() {
    local char="$1" count="$2" out="" i
    for ((i = 0; i < count; i++)); do
        out+="$char"
    done
    printf '%s' "$out"
}

center_text() {
    local text="$1" len=${#1}
    local left=$(( (UI_WIDTH - len) / 2 ))
    local right=$(( UI_WIDTH - len - left ))
    (( left < 0 )) && left=0
    (( right < 0 )) && right=0
    printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

section() {
    local title="$1"
    local centered
    centered="$(center_text "$title" "$UI_WIDTH")"
    say "${CYAN}${BOLD}┌$(repeat_char '─' "$UI_WIDTH")┐${RESET}"
    say "${CYAN}${BOLD}${centered}${RESET}"
}

section_end() {
    say ""
    say "${CYAN}${BOLD}└$(repeat_char '─' "$UI_WIDTH")┘${RESET}"
}

panel_line() {
    local text="${1:-}"
    local plain len max="$UI_WIDTH"
    # shellcheck disable=SC2001
    plain="$(printf '%b' "$text" | sed 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')"
    len=${#plain}
    if (( len > max )); then
        say "${plain:0:max-1}…"
    else
        say "$text"
    fi
}

banner() {
    clear 2>/dev/null || true
    say "${CYAN}${BOLD}╔$(repeat_char '═' "$UI_WIDTH")╗${RESET}"
    say "${CYAN}${BOLD}║${WHITE}$(center_text "T1aMat MOTD")${CYAN}${BOLD}║${RESET}"
    say "${CYAN}${BOLD}║${GRAY}$(center_text "Universal installer v${SCRIPT_VERSION}")${CYAN}${BOLD}║${RESET}"
    say "${CYAN}${BOLD}╚$(repeat_char '═' "$UI_WIDTH")╝${RESET}"
    echo
}

box_prompt() {
    local __var="$1" prompt="$2" reply=""
    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt" reply < /dev/tty
    else
        fail "Interactive input requires a terminal. Use --yes for automation."
        return 1
    fi
    printf -v "$__var" '%s' "$reply"
}

# Single key. No Enter required.
box_key() {
    local __var="$1" prompt="$2" reply=""
    [[ -r /dev/tty ]] || {
        fail "Interactive input requires a terminal. Use --yes for automation."
        return 1
    }
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r -n 1 reply < /dev/tty
    printf '\n' > /dev/tty
    printf -v "$__var" '%s' "$reply"
}

# Numeric key with optional second digit. 10+ works without Enter.
box_key_index() {
    local __var="$1" prompt="$2" first="" second="" reply=""
    [[ -r /dev/tty ]] || {
        fail "Interactive input requires a terminal. Use --yes for automation."
        return 1
    }
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r -n 1 first < /dev/tty
    if [[ "$first" =~ [0-9] && "$first" != 0 ]]; then
        if IFS= read -r -n 1 -t 0.35 second < /dev/tty; then
            if [[ "$second" =~ [0-9] ]]; then
                reply="${first}${second}"
            else
                reply="$first"
            fi
        else
            reply="$first"
        fi
    else
        reply="$first"
    fi
    printf '\n' > /dev/tty
    printf -v "$__var" '%s' "$reply"
}

menu_item() {
    local key="$1" label="$2" mark="${3-}"
    if [[ -n "$mark" ]]; then
        panel_line "  ${YELLOW}${key})${RESET} [ ${mark} ] ${label}"
    else
        panel_line "  ${YELLOW}${key})${RESET} ${label}"
    fi
}

confirm() {
    local prompt="$1" answer
    if (( YES_MODE )); then
        return 0
    fi
    [[ -r /dev/tty ]] || {
        fail "Interactive confirmation requires a terminal. Use --yes for automation."
        return 1
    }
    read -r -p "${prompt} [Y/n] " answer < /dev/tty
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

run_step() {
    local label="$1"
    shift
    local log pid rc=0 i=0 mark_ok mark_fail
    log="$(mktemp)"
    printf -v mark_ok '%b✔%b' "$GREEN" "$RESET"
    printf -v mark_fail '%b✖%b' "$RED" "$RESET"

    "$@" >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        sleep 0.12
    done
    wait "$pid" || rc=$?

    if (( rc == 0 )); then
        printf '  %-39s [%b]\n' "$label" "$mark_ok"
        rm -f "$log"
        return 0
    fi

    printf '  %-39s [%b]\n' "$label" "$mark_fail"
    sed -n '1,12p' "$log" >&2
    rm -f "$log"
    return "$rc"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall|remove|check|status)
                COMMAND="$1"
                shift
                ;;
            configure|config)
                COMMAND="configure"
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
                cat <<EOF
Usage:
  bash <(curl -fsSL $SCRIPT_URL)
  bash <(curl -fsSL $SCRIPT_URL) install
  bash <(curl -fsSL $SCRIPT_URL) install --yes
  bash <(curl -fsSL $SCRIPT_URL) install --header "My Server"
  bash <(curl -fsSL $SCRIPT_URL) configure
  bash <(curl -fsSL $SCRIPT_URL) uninstall
  bash <(curl -fsSL $SCRIPT_URL) check
EOF
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
    if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        fail "Could not download the installer for privileged re-execution."
        exit 1
    fi
    sudo bash "$tmp" "$@"
    rc=$?
    rm -f "$tmp"
    exit "$rc"
}

is_raspberry_pi_hardware() {
    [[ -r /proc/device-tree/model ]] || return 1
    tr -d '\0' < /proc/device-tree/model 2>/dev/null | grep -qi 'Raspberry Pi'
}

detect_os() {
    [[ -f /etc/os-release ]] || { fail "/etc/os-release was not found."; exit 1; }
    # shellcheck source=/dev/null
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
        exit 1
    fi
}

system_summary() {
    # shellcheck source=/dev/null
    . /etc/os-release 2>/dev/null || true
    section "System"
    say "  ${GRAY}OS            :${RESET} ${PRETTY_NAME:-unknown}"
    say "  ${GRAY}Hostname      :${RESET} $(hostname 2>/dev/null || echo unknown)"
    say "  ${GRAY}Kernel        :${RESET} $(uname -r 2>/dev/null || echo unknown)"
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
    package_installed toilet || missing+=(toilet)

    if ((${#missing[@]} == 0)); then
        ok "Required packages are already installed."
        return 0
    fi

    run_step "Updating package lists" apt-get update -qq
    local pkg
    for pkg in "${missing[@]}"; do
        run_step "Installing $pkg" apt-get install -y -qq "$pkg"
    done
}

ensure_tools() {
    local tool
    for tool in curl tar sha256sum timeout awk sed find; do
        command -v "$tool" >/dev/null 2>&1 || {
            fail "Required command not found: $tool"
            exit 1
        }
    done
}

config_has() {
    grep -Eq "^[[:space:]]*$1[[:space:]]*=" "$CONFIG_FILE" 2>/dev/null
}

append_default_setting() {
    local key="$1" value="$2"
    if ! config_has "$key"; then
        printf '\n%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
    fi
}

replace_config_array() {
    local key="$1"
    shift
    local block tmp
    block="$(mktemp)"
    {
        printf '%s=(\n' "$key"
        local item
        for item in "$@"; do
            printf '    %q\n' "$item"
        done
        printf ')\n'
    } > "$block"

    tmp="$(mktemp)"
    if [[ -f "$CONFIG_FILE" ]] && grep -Eq "^[[:space:]]*${key}[[:space:]]*\(" "$CONFIG_FILE"; then
        awk -v key="$key" -v repl="$block" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*\\(" {
                while ((getline line < repl) > 0) print line
                close(repl)
                inside=1
                next
            }
            inside {
                if ($0 ~ /^[[:space:]]*\\)[[:space:]]*$/) inside=0
                next
            }
            {print}
        ' "$CONFIG_FILE" > "$tmp"
        mv -f "$tmp" "$CONFIG_FILE"
    else
        cat "$block" >> "$CONFIG_FILE"
        rm -f "$tmp"
    fi
    rm -f "$block"
}

default_module_order() {
    printf '%s\n' \
        last-login uptime load-average memory disk-usage logins processes services docker
}

module_file() {
    case "$1" in
        last-login) printf '%s/01-last-login\n' "$MOTD_DIR" ;;
        uptime) printf '%s/03-uptime\n' "$MOTD_DIR" ;;
        load-average) printf '%s/04-load-average\n' "$MOTD_DIR" ;;
        memory) printf '%s/05-memory\n' "$MOTD_DIR" ;;
        disk-usage) printf '%s/06-disk-usage\n' "$MOTD_DIR" ;;
        logins) printf '%s/07-logins\n' "$MOTD_DIR" ;;
        processes) printf '%s/08-processes\n' "$MOTD_DIR" ;;
        services) printf '%s/09-services\n' "$MOTD_DIR" ;;
        docker) printf '%s/10-docker\n' "$MOTD_DIR" ;;
        *) printf '%s/%s\n' "$MOTD_DIR" "$1" ;;
    esac
}

module_label() {
    printf '%s' "${MODULE_LABELS[$1]:-$1}"
}

array_contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

normalize_motd_state() {
    local changed=0 module
    local -a original_order=() new_order=() disabled=()

    if declare -p MOTD_ORDER >/dev/null 2>&1; then
        original_order=("${MOTD_ORDER[@]}")
    else
        mapfile -t original_order < <(default_module_order)
        changed=1
    fi

    if declare -p MOTD_DISABLED >/dev/null 2>&1; then
        disabled=("${MOTD_DISABLED[@]}")
    else
        # Legacy configurations stored only enabled modules in MOTD_ORDER.
        # Preserve that order; omitted modules become disabled and receive
        # a stable position at the end of the list for future re-enables.
        for module in "${KNOWN_MODULES[@]}"; do
            if ! array_contains "$module" "${original_order[@]}"; then
                disabled+=("$module")
                original_order+=("$module")
            fi
        done
        changed=1
    fi

    new_order=("${original_order[@]}")
    for module in "${KNOWN_MODULES[@]}"; do
        if ! array_contains "$module" "${new_order[@]}"; then
            new_order+=("$module")
            if ! array_contains "$module" "${disabled[@]}"; then
                disabled+=("$module")
            fi
            changed=1
        fi
    done

    MOTD_ORDER=("${new_order[@]}")
    MOTD_DISABLED=("${disabled[@]}")

    if (( changed )); then
        replace_config_array "MOTD_ORDER" "${MOTD_ORDER[@]}"
        replace_config_array "MOTD_DISABLED" "${MOTD_DISABLED[@]}"
    fi
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$STATE_DIR"
        write_default_config
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    if ! declare -p MOTD_SERVICES >/dev/null 2>&1; then
        MOTD_SERVICES=(ssh ufw docker nginx)
    fi

    normalize_motd_state
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
    [[ -f "$CONFIG_BACKUP" ]] || cp -a "$CONFIG_FILE" "$CONFIG_BACKUP"
}

extract_existing_header() {
    local file="$MOTD_DIR/00-header"
    [[ -f "$file" ]] || return 1
    sed -n "s/.*toilet.*-f[[:space:]]\+ivrit[[:space:]]*[\"']\(.*\)[\"'].*/\1/p" "$file" | head -n1
}

write_default_config() {
    local header="T1aMat"
    local existing_header=""
    local created=0

    if [[ ! -f "$CONFIG_FILE" ]]; then
        existing_header="$(extract_existing_header 2>/dev/null || true)"
        [[ -n "$existing_header" ]] && header="$existing_header"

        mkdir -p "$STATE_DIR"
        {
            echo '# T1aMat MOTD configuration'
            echo '# This file is preserved across MOTD updates.'
            echo
            printf 'MOTD_HEADER=%q\n\n' "$header"
            echo 'MOTD_ORDER=('
            default_module_order | sed 's/^/    /'
            echo ')'
            echo
            echo 'MOTD_SERVICES=('
            echo '    ssh'
            echo '    ufw'
            echo '    docker'
            echo '    nginx'
            echo ')'
            echo
            echo 'MOTD_DISKS=('
            echo '    /'
            echo ')'
            echo
            echo 'WARN_PCT=80'
            echo 'CRIT_PCT=90'
            echo 'SERVICES_WIDTH=0'
            echo 'DOCKER_TIMEOUT=3'
            echo 'SSH_LOGIN_LOOKBACK=200'
        } > "$CONFIG_FILE"
        chmod 0644 "$CONFIG_FILE"
        CONFIG_CREATED=1
        ok "Created $CONFIG_FILE"
        created=1
    fi

    append_default_setting "SERVICES_WIDTH" "0"
    append_default_setting "DOCKER_TIMEOUT" "3"
    append_default_setting "SSH_LOGIN_LOOKBACK" "200"
    append_default_setting "WARN_PCT" "80"
    append_default_setting "CRIT_PCT" "90"

    if ! grep -Eq '^MOTD_ORDER[[:space:]]*\(' "$CONFIG_FILE"; then
        {
            echo
            echo 'MOTD_ORDER=('
            default_module_order | sed 's/^/    /'
            echo ')'
        } >> "$CONFIG_FILE"
    fi

    if (( created == 0 )); then
        CONFIG_CREATED=0
    fi
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
    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 \
        ! -name old-motd \
        ! -name colors.txt \
        -exec mv {} "$OLD_MOTD_DIR"/ +
    ok "Original MOTD backed up to $OLD_MOTD_DIR"
}

apply_header() {
    load_config
    local current="${MOTD_HEADER:-T1aMat}"
    local header="$HEADER_OVERRIDE"

    if [[ -z "$header" ]]; then
        if (( YES_MODE )); then
            header="$current"
        else
            say "  ${GRAY}Current header:${RESET} ${WHITE}${current}${RESET}"
            box_prompt header "New header [Enter = keep]: "
            [[ -z "$header" ]] && header="$current"
        fi
    fi

    local q tmp
    printf -v q '%q' "$header"
    tmp="${CONFIG_FILE}.tmp"
    awk -v value="$q" '
        /^MOTD_HEADER=/ {print "MOTD_HEADER=" value; next}
        {print}
    ' "$CONFIG_FILE" > "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    ok "Header: $header"
}

service_unit_exists() {
    local service="$1"
    command -v systemctl >/dev/null 2>&1 || return 1

    case "$service" in
        ssh) systemctl cat ssh.service >/dev/null 2>&1 || systemctl cat sshd.service >/dev/null 2>&1 ;;
        *) systemctl cat "${service}.service" >/dev/null 2>&1 ;;
    esac
}

service_available() {
    local service="$1"
    case "$service" in
        ufw) command -v ufw >/dev/null 2>&1 ;;
        docker) command -v docker >/dev/null 2>&1 || service_unit_exists docker ;;
        *) service_unit_exists "$service" ;;
    esac
}

service_label() {
    printf '%s' "${SERVICE_LABELS[$1]:-$1}"
}

discover_services() {
    local discovered=() service unit

    for service in "${KNOWN_SERVICES[@]}"; do
        if service_available "$service"; then
            discovered+=("$service")
        fi
    done

    if command -v systemctl >/dev/null 2>&1; then
        while read -r unit; do
            [[ "$unit" == *.service ]] || continue
            service="${unit%.service}"
            case "$service" in
                systemd-*|dbus*|getty*|user@*|NetworkManager*|ModemManager*|polkit*|snap*|apt*|packagekit*|cron*|rsyslog*|accounts-daemon*|udisks*|avahi*)
                    continue
                    ;;
            esac
            if [[ "$service" =~ (xray|unbound|haproxy|keepalived|etcd|kubelet|postgres|redis|kafka|patroni|remna|dozzle|beszel|fail2ban|nginx|caddy|docker) ]]; then
                discovered+=("$service")
            fi
        done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}')
    fi

    printf '%s\n' "${discovered[@]}" |
        awk 'NF && !seen[$0]++'
}

service_enabled() {
    local needle="$1" item
    for item in "${MOTD_SERVICES[@]}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

configure_services() {
    load_config
    mapfile -t candidates < <(discover_services)

    section "Services / auto-discovery"
    if ((${#candidates[@]} == 0)); then
        info "No supported services were detected."
        section_end
        return 0
    fi

    say "  Select services to show in the MOTD."
    say "  Discovered services are candidates; nothing is added silently."
    echo

    while true; do
        local i service mark choice
        for ((i = 0; i < ${#candidates[@]}; i++)); do
            service="${candidates[$i]}"
            if service_enabled "$service"; then mark="✓"; else mark=" "; fi
            menu_item "$((i + 1))" "$(service_label "$service")" "$mark"
        done
        panel_blank
        menu_item a "Add custom service"
        menu_item r "Refresh discovery"
        menu_item 0 "Done"

        box_prompt choice "  Select: "
        case "$choice" in
            0) break ;;
            a|A)
                local custom
                box_prompt custom "  Service name: "
                [[ -n "$custom" ]] || continue
                candidates+=("$custom")
                if ! service_enabled "$custom"; then
                    MOTD_SERVICES+=("$custom")
                fi
                ;;
            r|R)
                mapfile -t candidates < <(discover_services)
                ;;
            ''|*[!0-9]*)
                warn "Invalid selection."
                ;;
            *)
                local idx=$((choice - 1))
                if (( idx >= 0 && idx < ${#candidates[@]} )); then
                    service="${candidates[$idx]}"
                    if service_enabled "$service"; then
                        local next=()
                        local x
                        for x in "${MOTD_SERVICES[@]}"; do
                            [[ "$x" != "$service" ]] && next+=("$x")
                        done
                        MOTD_SERVICES=("${next[@]}")
                    else
                        MOTD_SERVICES+=("$service")
                    fi
                fi
                ;;
        esac
        echo
    done

    replace_config_array "MOTD_SERVICES" "${MOTD_SERVICES[@]}"
    ok "Services configuration saved."
    section_end
}

module_enabled() {
    local needle="$1" item
    for item in "${MOTD_ORDER[@]}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

toggle_module() {
    load_config
    local idx module choice
    local all=("${MOTD_ORDER[@]}")

    while true; do
        banner
        detect_os
        system_summary
        section "Enable / disable MOTD lines"
        for ((idx = 0; idx < ${#all[@]}; idx++)); do
            module="${all[$idx]}"
            if module_enabled "$module"; then
                menu_item "$((idx + 1))" "$(module_label "$module")" "✓"
            else
                menu_item "$((idx + 1))" "$(module_label "$module")" " "
            fi
        done
        panel_blank
        menu_item 0 "Done"
        section_end
        echo

        box_key_index choice "  Toggle (0=done): "

        if [[ "$choice" == 0 ]]; then
            replace_config_array "MOTD_ORDER" "${MOTD_ORDER[@]}"
            replace_config_array "MOTD_DISABLED" "${MOTD_DISABLED[@]}"
            return 0
        fi

        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#all[@]} )); then
            warn "Invalid selection: $choice"
            sleep 0.7
            continue
        fi

        module="${all[$((choice - 1))]}"
        local next=() x found=0
        for x in "${MOTD_DISABLED[@]}"; do
            if [[ "$x" == "$module" ]]; then
                found=1
                continue
            fi
            next+=("$x")
        done

        if (( found )); then
            MOTD_DISABLED=("${next[@]}")
        else
            MOTD_DISABLED+=("$module")
        fi

        # Save each toggle immediately; no Enter and no end-of-menu surprises.
        replace_config_array "MOTD_DISABLED" "${MOTD_DISABLED[@]}"
    done
}

move_module() {
    load_config
    local i module choice direction tmp
    if ((${#MOTD_ORDER[@]} < 2)); then
        info "There are fewer than two MOTD lines."
        return 0
    fi

    banner
    detect_os
    system_summary
    section "Move MOTD line"
    for ((i = 0; i < ${#MOTD_ORDER[@]}; i++)); do
        module="${MOTD_ORDER[$i]}"
        if module_enabled "$module"; then
            menu_item "$((i + 1))" "$(module_label "$module")" "✓"
        else
            menu_item "$((i + 1))" "$(module_label "$module")" " "
        fi
    done
    section_end
    echo

    box_key_index choice "  Select line: "
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#MOTD_ORDER[@]} )); then
        return 0
    fi

    i=$((choice - 1))
    box_key direction "  Move [u=up / d=down]: "
    case "$direction" in
        u|U)
            (( i > 0 )) || return 0
            tmp="${MOTD_ORDER[i]}"
            MOTD_ORDER[i]="${MOTD_ORDER[i - 1]}"
            MOTD_ORDER[i - 1]="$tmp"
            ;;
        d|D)
            (( i < ${#MOTD_ORDER[@]} - 1 )) || return 0
            tmp="${MOTD_ORDER[i]}"
            MOTD_ORDER[i]="${MOTD_ORDER[i + 1]}"
            MOTD_ORDER[i + 1]="$tmp"
            ;;
        *) return 0 ;;
    esac

    replace_config_array "MOTD_ORDER" "${MOTD_ORDER[@]}"
    ok "MOTD order updated."
}

configure_layout() {
    while true; do
        load_config
        banner
        detect_os
        system_summary
        section "MOTD layout"

        local i module choice
        for ((i = 0; i < ${#MOTD_ORDER[@]}; i++)); do
            module="${MOTD_ORDER[$i]}"
            if module_enabled "$module"; then
                menu_item "$((i + 1))" "$(module_label "$module")" "✓"
            else
                menu_item "$((i + 1))" "$(module_label "$module")" " "
            fi
        done
        panel_blank
        menu_item e "Enable / disable line"
        menu_item m "Move line"
        menu_item d "Reset to default order"
        menu_item 0 "Back"
        section_end
        echo

        box_key choice "Select an option: "
        case "$choice" in
            e|E) toggle_module ;;
            m|M) move_module ;;
            d|D)
                mapfile -t MOTD_ORDER < <(default_module_order)
                MOTD_DISABLED=()
                replace_config_array "MOTD_ORDER" "${MOTD_ORDER[@]}"
                replace_config_array "MOTD_DISABLED" "${MOTD_DISABLED[@]}"
                ok "Default MOTD order restored."
                sleep 0.8
                ;;
            0) return 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

configure_motd() {
    while true; do
        banner
        detect_os
        system_summary
        section "MOTD configuration"
        say "  1) MOTD lines / order / enable / disable"
        say "  2) Services / auto-discovery"
        say "  3) Reset MOTD order to defaults"
        say "  0) Back"
        section_end
        echo

        local choice
        box_prompt choice "Select an option: "
        case "$choice" in
            1) configure_layout ;;
            2)
                banner
                detect_os
                system_summary
                configure_services
                echo
                if [[ -r /dev/tty ]]; then read -r -p "Press Enter to return..." _ < /dev/tty || true; fi
                ;;
            3)
                load_config
                mapfile -t MOTD_ORDER < <(default_module_order)
                MOTD_DISABLED=()
                replace_config_array "MOTD_ORDER" "${MOTD_ORDER[@]}"
                replace_config_array "MOTD_DISABLED" "${MOTD_DISABLED[@]}"
                ok "Default MOTD order restored and all lines enabled."
                sleep 0.8
                ;;
            0) return 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

prepare_install() {
    mkdir -p "$STATE_DIR" "$MOTD_DIR"
    backup_config_if_needed
    write_default_config
}

sync_motd_files() {
    local source_dir="$1"
    local manifest_tmp name source target previous_hash current_hash
    local installed=0 unchanged=0

    [[ -d "$source_dir" ]] || {
        fail "MOTD source directory does not exist: $source_dir"
        return 1
    }

    mkdir -p "$MOTD_DIR" "$STATE_DIR"

    if [[ ! -f "$MANIFEST_FILE" && ! -d "$LEGACY_MOTD_DIR" ]]; then
        mkdir -p "$LEGACY_MOTD_DIR"
        find "$MOTD_DIR" -maxdepth 1 -type f \
            ! -name colors.txt \
            -exec cp -a {} "$LEGACY_MOTD_DIR"/ +
        if find "$LEGACY_MOTD_DIR" -maxdepth 1 -type f -print -quit | grep -q .; then
            info "Previous MOTD detected; recovery copies saved in $LEGACY_MOTD_DIR"
        fi
    fi

    manifest_tmp="${MANIFEST_FILE}.tmp"
    : > "$manifest_tmp"

    while IFS= read -r -d '' source; do
        name="${source##*/}"
        target="$MOTD_DIR/$name"

        [[ "$name" == "colors.txt" && -f "$target" ]] && continue

        previous_hash=""
        if [[ -f "$MANIFEST_FILE" ]]; then
            previous_hash="$(manifest_hash "$name" 2>/dev/null || true)"
        fi

        current_hash=""
        if [[ -f "$target" ]]; then
            current_hash="$(sha256sum "$target" | awk '{print $1}')"
        fi

        if [[ -f "$target" ]]; then
            if [[ -n "$previous_hash" && "$current_hash" != "$previous_hash" ]]; then
                warn "Preserving modified MOTD file: $name"
                printf '%s %s\n' "$current_hash" "$name" >> "$manifest_tmp"
                continue
            fi
            if [[ "$current_hash" == "$(sha256sum "$source" | awk '{print $1}')" ]]; then
                printf '%s %s\n' "$current_hash" "$name" >> "$manifest_tmp"
                unchanged=$((unchanged + 1))
                continue
            fi
        fi

        cp -a "$source" "$target"

        if [[ "$name" == "00-header" || "$name" == "00-t1amat-motd" ]]; then
            chmod 0755 "$target"
        elif [[ "$name" =~ ^[0-9]+- ]]; then
            chmod 0644 "$target"
        else
            chmod 0644 "$target"
        fi

        current_hash="$(sha256sum "$target" | awk '{print $1}')"
        printf '%s %s\n' "$current_hash" "$name" >> "$manifest_tmp"
        installed=$((installed + 1))
    done < <(find "$source_dir" -maxdepth 1 -type f -print0 | sort -z)

    if [[ ! -s "$manifest_tmp" ]]; then
        rm -f "$manifest_tmp"
        fail "No MOTD files were synchronized."
        return 1
    fi

    mv -f "$manifest_tmp" "$MANIFEST_FILE"
    chmod 0644 "$MANIFEST_FILE"
    ok "Files: ${installed} installed, ${unchanged} unchanged"
}

download_source() {
    local tmp_dir="$1" archive="$2"

    section "Downloading MOTD"
    if ! run_step "Downloading MOTD archive" curl --fail --location --silent --show-error \
        --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2 \
        -o "$archive" "$REPO_URL"; then
        fail "Download failed. Check DNS, Internet connectivity and GitHub access."
        section_end
        return 1
    fi

    [[ -s "$archive" ]] || {
        fail "Downloaded archive is empty."
        section_end
        return 1
    }

    run_step "Extracting MOTD archive" tar -xzf "$archive" --strip-components=1 -C "$tmp_dir"

    [[ -d "$tmp_dir/motd" ]] || {
        fail "Downloaded archive has no motd directory."
        section_end
        return 1
    }

    ok "MOTD source ready."
    section_end
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

    rm -f /etc/motd
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
        file|symlink)
            cp -a "$ETC_MOTD_BACKUP" /etc/motd
            ;;
        absent)
            ;;
    esac

    rm -f "$ETC_MOTD_BACKUP" "$ETC_MOTD_STATE"
}

sshd_query_printlastlog() {
    local out="" rc=0 value=""

    out="$(sshd -T 2>&1)" || rc=$?
    out="${out//$'\r'/}"

    if (( rc != 0 )); then
        rc=0
        out="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>&1)" || rc=$?
        out="${out//$'\r'/}"
        (( rc == 0 )) || return 0
    fi

    value="$(awk 'tolower($1)=="printlastlog" {print tolower($2); exit}' <<< "$out")" || value=""
    SSHD_EFFECTIVE="${value:-unknown}"
}

ensure_sshd_include() {
    grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' /etc/ssh/sshd_config
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

    if ! ensure_sshd_include; then
        warn "sshd_config does not include /etc/ssh/sshd_config.d/*.conf."
        info "The SSH drop-in will not be created."
        section_end
        return 0
    fi

    cat > "$SSHD_DROPIN" <<'EOF_DROPIN'
# Managed by T1aMat MOTD
PrintLastLog no
EOF_DROPIN

    local verr=""
    if ! verr="$(sshd -t 2>&1)"; then
        rm -f "$SSHD_DROPIN"
        fail "sshd configuration validation failed; drop-in removed."
        say "  ${GRAY}${verr%%$'\n'*}${RESET}"
        section_end
        return 1
    fi

    sha256sum "$SSHD_DROPIN" > "$SSHD_DROPIN_HASH"
    sshd_query_printlastlog

    if [[ "$SSHD_EFFECTIVE" == "no" ]]; then
        ok "PrintLastLog disabled through sshd drop-in."
    elif [[ "$SSHD_EFFECTIVE" == "unknown" ]]; then
        warn "Could not verify the effective sshd setting."
    else
        warn "PrintLastLog is still ${SSHD_EFFECTIVE}; another setting takes precedence."
    fi

    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    section_end
}

restore_sshd_dropin() {
    [[ -f "$SSHD_DROPIN" ]] || return 0
    grep -q 'Managed by T1aMat MOTD' "$SSHD_DROPIN" || return 0

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
    sshd -t 2>/dev/null && {
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        ok "T1aMat SSH drop-in removed."
    }
}

restore_colors() {
    [[ -f "$COLORS_STATE" ]] || return 0
    local state current_hash saved_hash
    state="$(cat "$COLORS_STATE")"

    if [[ "$state" == "absent" && -f "$MOTD_DIR/colors.txt" && -f "$COLORS_HASH" ]]; then
        current_hash="$(sha256sum "$MOTD_DIR/colors.txt" | awk '{print $1}')"
        saved_hash="$(awk '{print $1}' "$COLORS_HASH")"
        if [[ "$current_hash" == "$saved_hash" ]]; then
            rm -f "$MOTD_DIR/colors.txt"
            ok "Installer-created colors.txt removed."
        else
            warn "colors.txt was modified after installation; leaving it untouched."
        fi
    fi

    rm -f "$COLORS_STATE" "$COLORS_HASH"
}

manifest_hash() {
    local path="$1"
    [[ -f "$MANIFEST_FILE" ]] || return 1
    awk -v p="$path" '$2 == p {print $1; exit}' "$MANIFEST_FILE"
}

restore_motd() {
    [[ -d "$OLD_MOTD_DIR" ]] || {
        warn "No original MOTD backup found."
        return 0
    }
    [[ -f "$MANIFEST_FILE" ]] || {
        warn "No installation manifest found; refusing a destructive restore."
        return 0
    }

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

install_motd() {
    banner
    detect_os
    system_summary

    section "Install MOTD"
    say "  ${GRAY}Profile:${RESET} ${WHITE}${OS_FLAVOR}${RESET}"
    say "  Existing MOTD files are preserved on update when modified."
    say "  Configuration lives in ${CONFIG_FILE}."
    section_end
    echo

    confirm "Continue with installation?" || {
        warn "Installation cancelled."
        return 0
    }

    if (( DRY_RUN )); then
        section "Dry run"
        say "  Would install/update the MOTD."
        say "  Would preserve user configuration."
        say "  Would configure services and MOTD order."
        say "  Would configure PrintLastLog through an SSH drop-in."
        section_end
        return 0
    fi

    section "Dependencies"
    install_dependencies
    section_end

    TEMP_DIR="$(mktemp -d)"
    local archive="${TEMP_DIR}/motd.tar.gz"

    echo
    download_source "$TEMP_DIR" "$archive"

    echo
    section "Configuration"
    prepare_install
    initial_backup
    apply_header
    load_config

    if (( CONFIG_CREATED )); then
        mapfile -t discovered_services < <(discover_services)
        if ((${#discovered_services[@]} > 0)); then
            replace_config_array "MOTD_SERVICES" "${discovered_services[@]}"
            info "Auto-discovered ${#discovered_services[@]} service(s)."
        fi
    fi
    section_end

    echo
    section "Installing MOTD"
    sync_motd_files "$TEMP_DIR/motd"
    if (( USE_ETC_MOTD_LINK )); then
        install_etc_motd
        ok "/etc/motd linked to /var/run/motd for ${OS_FLAVOR}."
    fi
    section_end

    echo
    configure_printlastlog || warn "SSH configuration step failed; the MOTD itself is installed."

    if (( CONFIG_CREATED )) && (( ! YES_MODE )); then
        echo
        section "MOTD setup"
        say "  The installer detected the installed services and created"
        say "  a default MOTD layout."
        say "  You can customize the order and enabled lines now."
        section_end
        echo
        if confirm "Open MOTD configuration now?"; then
            configure_motd
        fi
    fi

    cleanup_temp
    TEMP_DIR=""

    echo
    section "Installation complete"
    ok "T1aMat MOTD ${SCRIPT_VERSION} installed."
    say "  ${GRAY}OS profile   :${RESET} $OS_FLAVOR"
    say "  ${GRAY}Config       :${RESET} $CONFIG_FILE"
    say "  ${GRAY}Original MOTD:${RESET} $OLD_MOTD_DIR"
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

    [[ -f "$MANIFEST_FILE" ]] || {
        warn "No T1aMat MOTD installation manifest found."
        info "Nothing will be removed destructively."
        return 0
    }

    confirm "Continue with uninstall?" || {
        warn "Uninstall cancelled."
        return 0
    }

    if (( DRY_RUN )); then
        section "Dry run"
        say "  Would restore MOTD modules from: $OLD_MOTD_DIR"
        say "  Would remove: $CONFIG_FILE"
        say "  Would remove: $SSHD_DROPIN when unmodified"
        section_end
        return 0
    fi

    echo
    restore_motd
    echo
    restore_colors
    restore_sshd_dropin
    restore_etc_motd
    handle_config_uninstall

    rm -f "$MANIFEST_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true

    echo
    section "Complete"
    ok "T1aMat MOTD has been uninstalled."
    section_end
}

check_installation() {
    banner
    detect_os
    system_summary
    section "Installation check"

    local problems=0 effective config_header file
    local required=(00-header 00-t1amat-motd 01-last-login 09-services 10-docker)
    local legacy_detected=0

    if [[ ! -f "$CONFIG_FILE" || ! -f "$MOTD_DIR/00-t1amat-motd" || ! -f "$MANIFEST_FILE" ]]; then
        if [[ -f "$MOTD_DIR/01-last-login" || -f "$MOTD_DIR/09-services" || -f "$MOTD_DIR/10-docker" ]]; then
            legacy_detected=1
        fi
    fi

    if (( legacy_detected )); then
        warn "Legacy MOTD installation detected."
        info "Run 1) Install / update MOTD to migrate it to the current layout."
        problems=$((problems + 1))
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        ok "Configuration file exists."
    elif (( ! legacy_detected )); then
        warn "Configuration file is missing."
        problems=$((problems + 1))
    fi

    for file in "${required[@]}"; do
        if [[ -f "$MOTD_DIR/$file" ]]; then
            ok "$file is installed."
        elif (( ! legacy_detected )); then
            warn "$file is missing."
            problems=$((problems + 1))
        fi
    done

    if [[ -x "$MOTD_DIR/00-t1amat-motd" ]]; then
        ok "MOTD dispatcher is executable."
    elif (( ! legacy_detected )); then
        warn "MOTD dispatcher is not executable."
        problems=$((problems + 1))
    fi

    local legacy_exec=0
    for file in \
        "$MOTD_DIR/01-last-login" \
        "$MOTD_DIR/03-uptime" \
        "$MOTD_DIR/04-load-average" \
        "$MOTD_DIR/05-memory" \
        "$MOTD_DIR/06-disk-usage" \
        "$MOTD_DIR/07-logins" \
        "$MOTD_DIR/08-processes" \
        "$MOTD_DIR/09-services" \
        "$MOTD_DIR/10-docker"
    do
        if [[ -x "$file" ]]; then
            legacy_exec=1
            warn "Numbered module is executable: ${file##*/}"
        fi
    done
    if (( legacy_exec )); then
        warn "Numbered modules must be dispatcher-only to avoid duplicate MOTD output."
        problems=$((problems + 1))
    elif (( ! legacy_detected )); then
        ok "Numbered MOTD modules are dispatcher-only."
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        config_header="${MOTD_HEADER:-T1aMat}"
        ok "Header configured as: $config_header"
        if declare -p MOTD_ORDER >/dev/null 2>&1; then
            local disabled_count=0
            declare -p MOTD_DISABLED >/dev/null 2>&1 && disabled_count=${#MOTD_DISABLED[@]}
            ok "MOTD order configured: ${#MOTD_ORDER[@]} line(s), ${disabled_count} disabled."
        elif (( ! legacy_detected )); then
            warn "MOTD_ORDER is missing."
            problems=$((problems + 1))
        fi
    fi

    if [[ -f "$SSHD_DROPIN" ]] && grep -q 'Managed by T1aMat MOTD' "$SSHD_DROPIN" &&
       command -v sshd >/dev/null 2>&1; then
        sshd_query_printlastlog
        effective="$SSHD_EFFECTIVE"
        if [[ "$effective" == "no" ]]; then
            ok "SSH PrintLastLog is disabled."
        else
            warn "SSH PrintLastLog effective value: ${effective}"
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
    elif (( ! legacy_detected )); then
        warn "Installation manifest is missing."
        problems=$((problems + 1))
    fi

    if (( problems == 0 )); then
        ok "Installation check passed."
    else
        warn "Installation check found ${problems} issue(s)."
    fi
    section_end
}

show_menu() {
    while true; do
        banner
        detect_os
        system_summary

        section "Main menu"
        menu_item 1 "Install / update MOTD"
        menu_item 2 "Uninstall / restore MOTD"
        menu_item 3 "Check installation"
        menu_item 4 "Configure MOTD"
        menu_item 0 "Exit"
        section_end
        echo

        local choice
        box_prompt choice "Select an option: "

        case "$choice" in
            1)
                install_motd
                ;;
            2)
                uninstall_motd
                ;;
            3)
                check_installation
                ;;
            4)
                configure_motd
                ;;
            0)
                echo
                ok "Goodbye."
                return 0
                ;;
            *)
                warn "Invalid choice."
                ;;
        esac

        echo
        if [[ -r /dev/tty ]]; then read -r -p "Press Enter to return to the main menu..." _ < /dev/tty || true; fi
    done
}

main() {
    parse_args "$@"
    require_root "$@"
    ensure_tools
    detect_os

    case "$COMMAND" in
        install) install_motd ;;
        uninstall|remove) uninstall_motd ;;
        check|status) check_installation ;;
        configure) configure_motd ;;
        "") show_menu ;;
    esac
}

main "$@"

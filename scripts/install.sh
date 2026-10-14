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

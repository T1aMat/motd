#!/bin/bash
set -euo pipefail

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/bin" "$ROOT/etc"
printf "TITLE_COLOR=''\nTEXT_COLOR=''\nDEFAULT_COLOR=''\nNC=''\n" > "$ROOT/etc/colors.txt"
cat > "$ROOT/etc/t1amat-motd.conf" <<'CFG'
MOTD_SERVICES=(ssh ufw docker nginx)
SERVICES_WIDTH=78
DOCKER_TIMEOUT=1
SSH_LOGIN_LOOKBACK=200
MOTD_HEADER="Smoke"
CFG

cat > "$ROOT/bin/toilet" <<'TOILET'
#!/bin/sh
echo SMOKE-HEADER
TOILET

cat > "$ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
case "$1" in
  cat) exit 0 ;;
  show) echo active ;;
  *) exit 0 ;;
esac
SYSTEMCTL

cat > "$ROOT/bin/ufw" <<'UFW'
#!/bin/sh
echo 'Status: active'
UFW

cat > "$ROOT/bin/docker" <<'DOCKER'
#!/bin/sh
if [ "$1" = "ps" ]; then
  echo 'demo\trunning 2 minutes'
  echo 'stopped\texited (0) 3 minutes'
else
  exit 0
fi
DOCKER

cat > "$ROOT/bin/last" <<'LAST'
#!/bin/sh
cat <<'DATA'
root pts/0 192.0.2.20 Thu Oct  1 15:00 still logged in
root pts/0 192.0.2.21 Thu Oct  1 14:00 still logged in
wtmp begins Thu Oct  1 00:00:00 2026
DATA
LAST

chmod +x "$ROOT/bin"/*
export PATH="$ROOT/bin:$PATH"
export MOTD_COLORS_FILE="$ROOT/etc/colors.txt"
export MOTD_CONFIG_FILE="$ROOT/etc/t1amat-motd.conf"

for file in \
    motd/00-header \
    motd/01-last-login \
    motd/08-processes \
    motd/09-services \
    motd/10-docker
 do
    bash -n "$file"
done

motd/00-header >/dev/null
motd/01-last-login >/dev/null
motd/08-processes >/dev/null
motd/09-services >/dev/null
motd/10-docker >/dev/null

echo 'Smoke test passed.'

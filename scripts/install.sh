#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="3.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/T1aMat/motd/refs/heads/master/scripts/install.sh"
REPO_URL="https://github.com/T1aMat/motd/archive/refs/heads/master.tar.gz"
UI_WIDTH=50
MOTD_DIR="/etc/update-motd.d"
OLD_MOTD_DIR="${MOTD_DIR}/old-motd"
STATE_DIR="/var/lib/t1amat-motd"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="${STATE_DIR}/sshd_config.backup"
SSH_HASH="${STATE_DIR}/sshd_config.installed.sha256"
ETC_MOTD_BACKUP="${STATE_DIR}/etc-motd.backup"
ETC_MOTD_STATE="${STATE_DIR}/etc-motd.state"
OS_FLAVOR=""
USE_ETC_MOTD_LINK=0

RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[1;32m'; CYAN='\033[1;36m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'; BLUE='\033[1;34m'
if [[ ! -t 1 ]]; then RESET=''; BOLD=''; DIM=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; WHITE=''; GRAY=''; BLUE=''; fi

say(){ printf '%b\n' "$*"; }
repeat_char(){ local c="$1" n="$2" o="" i; for ((i=0;i<n;i++)); do o+="$c"; done; printf '%s' "$o"; }
center_text(){ local t="$1" l=${#1} left right; left=$(( (UI_WIDTH-l)/2 )); right=$((UI_WIDTH-l-left)); ((left<0))&&left=0; ((right<0))&&right=0; printf '%*s%s%*s' "$left" '' "$t" "$right" ''; }

banner(){
  local title="T1aMat MOTD" subtitle="Universal installer v${SCRIPT_VERSION}";
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

  ((l < 0)) && l=0
  ((r < 0)) && r=0

  say "${CYAN}${BOLD}┌$(repeat_char '''─''' "$l") ${title} $(repeat_char '''─''' "$r")┐${RESET}"
}
section_end(){ say "${CYAN}${BOLD}└$(repeat_char '─' "$UI_WIDTH")┘${RESET}"; }
info(){ say "${CYAN}ℹ${RESET}  $*"; }; ok(){ say "${GREEN}✔${RESET}  $*"; }; warn(){ say "${YELLOW}⚠${RESET}  $*"; }; fail(){ say "${RED}✖${RESET}  $*"; }
run_step(){ local label="$1"; shift; local log pid i=0 spin='|/-\\'; log="$(mktemp)"; printf '  %b%-42s%b ' "$WHITE" "$label" "$RESET"; "$@" >"$log" 2>&1 & pid=$!; while kill -0 "$pid" 2>/dev/null; do printf '\b[%c]' "${spin:i++%4:1}"; sleep 0.12; done; if wait "$pid"; then printf '\b%b✔%b\n' "$GREEN" "$RESET"; rm -f "$log"; return 0; fi; printf '\b%b✖%b\n' "$RED" "$RESET"; sed -n '1,25p' "$log"; rm -f "$log"; return 1; }
confirm(){ local prompt="$1" answer; read -r -p "${prompt} [Y/n] " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }

is_raspberry_pi_hardware(){ [[ -r /proc/device-tree/model ]] && tr -d '\0' < /proc/device-tree/model 2>/dev/null | grep -qi 'Raspberry Pi'; }
detect_os(){
  [[ -f /etc/os-release ]] || { fail "/etc/os-release was not found."; exit 1; }
  . /etc/os-release
  local id="${ID:-}" like="${ID_LIKE:-}"
  if [[ "$id" == ubuntu || "$like" == *ubuntu* ]]; then
    OS_FLAVOR="Ubuntu"; USE_ETC_MOTD_LINK=0
  elif is_raspberry_pi_hardware && [[ "$id" == debian || "$id" == raspbian || "$like" == *debian* ]]; then
    OS_FLAVOR="Raspberry Pi OS"; USE_ETC_MOTD_LINK=1
  elif [[ "$id" == debian || "$like" == *debian* ]]; then
    OS_FLAVOR="Debian"; USE_ETC_MOTD_LINK=1
  else
    fail "Unsupported operating system: ${PRETTY_NAME:-$id}"; say "  ${GRAY}Supported: Ubuntu, Debian, Raspberry Pi OS${RESET}"; exit 1
  fi
}

system_summary(){
  . /etc/os-release 2>/dev/null || true
  section "System"
  say "  ${GRAY}OS           :${RESET} ${PRETTY_NAME:-unknown}"
  say "  ${GRAY}Hostname     :${RESET} $(hostname 2>/dev/null || echo unknown)"
  say "  ${GRAY}Kernel       :${RESET} $(uname -r 2>/dev/null || echo unknown)"
  say "  ${GRAY}Architecture :${RESET} $(uname -m 2>/dev/null || echo unknown)"
  say "  ${GRAY}MOTD profile :${RESET} ${OS_FLAVOR}"
  section_end; echo
}

require_root(){
  if [[ $EUID -eq 0 ]]; then return 0; fi
  command -v sudo >/dev/null 2>&1 || { fail "Root privileges are required and sudo is not installed."; exit 1; }
  info "Root privileges are required. Re-running with sudo..."; echo
  if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]]; then exec sudo bash "$0" "$@"; fi
  command -v curl >/dev/null 2>&1 || { fail "curl is required to re-launch the remote installer."; exit 1; }
  exec sudo bash -c 'curl -fsSL "$1" | bash -s -- "${@:2}"' _ "$SCRIPT_URL" "$@"
}

configure_printlastlog(){
  section "SSH login message"
  [[ -f "$SSH_CONFIG" ]] || { warn "OpenSSH server configuration was not found."; info "PrintLastLog was skipped."; section_end; return 0; }
  command -v sshd >/dev/null 2>&1 || { warn "sshd was not found."; info "PrintLastLog was skipped."; section_end; return 0; }
  info "Checking PrintLastLog overrides..."
  local overrides; overrides="$(grep -RnsE '^[[:space:]]*PrintLastLog[[:space:]]+' /etc/ssh/sshd_config.d 2>/dev/null || true)"
  if [[ -n "$overrides" ]]; then
    warn "An active PrintLastLog override exists in sshd_config.d."; say "  ${GRAY}${overrides}${RESET}"; info "The main sshd_config will not be modified."; section_end; return 0
  fi
  mkdir -p "$STATE_DIR"
  python3 - "$SSH_CONFIG" "$SSH_BACKUP" <<'PY'
import shutil, sys
from pathlib import Path
config=Path(sys.argv[1]); backup=Path(sys.argv[2])
lines=config.read_text().splitlines(); result=[]; found=False; changed=False
for line in lines:
    stripped=line.lstrip()
    if stripped.startswith("PrintLastLog") and (stripped=="PrintLastLog" or stripped[len("PrintLastLog"):].startswith((" ","\t"))):
        result.append("PrintLastLog no"); found=True; changed |= line != "PrintLastLog no"; continue
    if stripped.startswith("#PrintLastLog") and (stripped=="#PrintLastLog" or stripped[len("#PrintLastLog"):].startswith((" ","\t"))):
        result.append("PrintLastLog no"); found=True; changed=True; continue
    result.append(line)
if not found:
    if result and result[-1] != "": result.append("")
    result.append("PrintLastLog no"); changed=True
old=config.read_text(); new="\n".join(result)+"\n"
if changed and new != old:
    if not backup.exists(): shutil.copy2(config, backup)
    config.write_text(new); print("changed")
else: print("unchanged")
PY
  if ! sshd -t; then fail "sshd configuration validation failed."; [[ -f "$SSH_BACKUP" ]] && cp -f "$SSH_BACKUP" "$SSH_CONFIG"; section_end; exit 1; fi
  if [[ -f "$SSH_BACKUP" ]]; then sha256sum "$SSH_CONFIG" > "$SSH_HASH"; ok "PrintLastLog set to no."; else ok "PrintLastLog was already set to no."; fi
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then ok "SSH configuration reloaded."; else warn "SSH configuration is valid, but automatic reload failed."; fi
  say "  ${GRAY}Effective setting:${RESET} $(sshd -T | grep -i '^printlastlog ' || true)"; section_end
}

configure_header(){
  local f="$MOTD_DIR/00-header" current header
  section "MOTD header"
  [[ -f "$f" ]] || { warn "$f was not found."; section_end; return 0; }
  current="$(python3 - "$f" <<'PY'
import re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
m=re.search(r'toilet\s+-d\s+/etc/update-motd\.d/\s+-f\s+ivrit\s+(["\x27])(.*?)(?:\1)', text)
print(m.group(2) if m else "T1aMat")
PY
)"
  say "  ${GRAY}Current header:${RESET} ${WHITE}${current}${RESET}"; echo
  read -r -p "  New header [Enter = keep ${current}]: " header
  if [[ -z "$header" ]]; then ok "Keeping header: ${current}"; section_end; return 0; fi
  python3 - "$f" "$header" <<'PY'
import json,re,sys
from pathlib import Path
p=Path(sys.argv[1]); h=sys.argv[2]; text=p.read_text()
pat=re.compile(r'(toilet\s+-d\s+/etc/update-motd\.d/\s+-f\s+ivrit\s+)(["\x27]).*?\2')
new,count=pat.subn(lambda m:m.group(1)+json.dumps(h),text,count=1)
if count!=1: print("Could not find the expected toilet header line."); sys.exit(1)
p.write_text(new)
PY
  ok "Header changed to: ${header}"; section_end
}

backup_old_motd(){
  section "Existing MOTD"; mkdir -p "$MOTD_DIR"
  if [[ -d "$OLD_MOTD_DIR" ]] && find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    ok "Original MOTD backup already exists."; info "Keeping: $OLD_MOTD_DIR"
    find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name old-motd -exec rm -rf {} +
    section_end; return 0
  fi
  mkdir -p "$OLD_MOTD_DIR"
  find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name old-motd -exec mv {} "$OLD_MOTD_DIR"/ \;
  ok "Original MOTD backed up."; say "  ${GRAY}Backup:${RESET} $OLD_MOTD_DIR"; section_end
}

backup_etc_motd(){
  [[ $USE_ETC_MOTD_LINK -eq 1 ]] || return 0; mkdir -p "$STATE_DIR"; [[ -f "$ETC_MOTD_STATE" ]] && return 0
  if [[ -e /etc/motd || -L /etc/motd ]]; then
    if [[ -L /etc/motd ]]; then printf 'symlink\n%s\n' "$(readlink /etc/motd)" > "$ETC_MOTD_STATE"; else printf 'file\n' > "$ETC_MOTD_STATE"; fi
    cp -a /etc/motd "$ETC_MOTD_BACKUP"
  else printf 'absent\n' > "$ETC_MOTD_STATE"; fi
}
install_etc_motd(){ [[ $USE_ETC_MOTD_LINK -eq 1 ]] || return 0; backup_etc_motd; rm -f /etc/motd; ln -sf /var/run/motd /etc/motd; }
restore_etc_motd(){
  [[ $USE_ETC_MOTD_LINK -eq 1 ]] || return 0; section "Restoring /etc/motd"
  [[ -f "$ETC_MOTD_STATE" ]] || { info "No /etc/motd backup state found."; section_end; return 0; }
  local state; state="$(sed -n '1p' "$ETC_MOTD_STATE")"
  if [[ $state == absent ]]; then rm -f /etc/motd; ok "Original state was: absent."; section_end; return 0; fi
  if [[ -L /etc/motd && $(readlink /etc/motd) == /var/run/motd ]]; then rm -f /etc/motd; elif [[ -e /etc/motd || -L /etc/motd ]]; then warn "/etc/motd was changed after installation."; info "Leaving the newer file untouched."; info "Original backup: $ETC_MOTD_BACKUP"; section_end; return 0; fi
  cp -a "$ETC_MOTD_BACKUP" /etc/motd; rm -f "$ETC_MOTD_BACKUP" "$ETC_MOTD_STATE"; ok "Original /etc/motd restored."; section_end
}

package_installed(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
install_dependency(){ local p="$1" label="$2"; if package_installed "$p"; then ok "$label already installed."; else run_step "Installing $label" apt-get install -y -qq "$p"; fi; }

download_motd(){
  local archive="$1"; section "Downloading MOTD"; printf '  %bGitHub release%b   ' "$WHITE" "$RESET"
  if ! curl --fail --location --progress-bar --show-error --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2 -o "$archive" "$REPO_URL"; then echo; fail "Download failed. Check DNS, Internet connectivity and GitHub access."; return 1; fi
  echo; [[ -s "$archive" ]] || { fail "Downloaded archive is empty."; return 1; }; ok "Download complete."; section_end
}

prepare_source(){
  local tmp="$1" archive="$2"; section "Preparing files"; run_step "Extracting MOTD archive" tar -xzf "$archive" -C "$tmp"; SOURCE_DIR="${tmp}/motd-master/motd"; [[ -d "$SOURCE_DIR" ]] || { fail "Unexpected archive structure."; return 1; }; ok "MOTD archive is ready."; section_end
}

install_motd(){
  banner; system_summary
  section "Install MOTD"; say "  This will install the custom T1aMat MOTD, preserve the"; say "  existing MOTD, configure SSH, and customize the header."; say "  Profile detected: ${WHITE}${OS_FLAVOR}${RESET}"; section_end; echo
  if ! confirm "Continue with installation?"; then warn "Installation cancelled."; return 0; fi
  echo; section "Dependencies"; run_step "Updating package lists" apt-get update -qq; install_dependency toilet toilet; install_dependency colorized-logs colorized-logs; install_dependency python3 python3; section_end
  local tmp_dir archive; tmp_dir="$(mktemp -d)"; archive="${tmp_dir}/motd.tar.gz"; trap 'rm -rf "$tmp_dir"' EXIT
  echo; download_motd "$archive"; prepare_source "$tmp_dir" "$archive"; echo; backup_old_motd; echo
  section "Installing MOTD"; run_step "Copying MOTD files" cp -a "$SOURCE_DIR/." "$MOTD_DIR/"; run_step "Setting executable permissions" bash -c 'find /etc/update-motd.d -maxdepth 1 -type f -name "[0-9]*" -exec chmod 755 {} + 2>/dev/null || true'; if [[ $USE_ETC_MOTD_LINK -eq 1 ]]; then run_step "Updating /etc/motd link" install_etc_motd; else info "Ubuntu profile: preserving /etc/motd handling."; fi; section_end
  echo; configure_header; echo; configure_printlastlog; echo; section "Installation complete"; ok "T1aMat MOTD is installed."; say "  ${GRAY}Detected OS${RESET}   : $OS_FLAVOR"; say "  ${GRAY}MOTD directory${RESET} : $MOTD_DIR"; say "  ${GRAY}Original backup${RESET}: $OLD_MOTD_DIR"; echo; say "${GREEN}${BOLD}Enjoy your new MOTD.${RESET}"; section_end
}

restore_printlastlog(){
  section "Restoring SSH configuration"
  [[ -f "$SSH_BACKUP" ]] || { info "No SSH configuration backup was created by this installer."; section_end; return 0; }
  if [[ -f "$SSH_HASH" ]]; then local current_hash installed_hash; current_hash="$(sha256sum "$SSH_CONFIG" | awk '{print $1}')"; installed_hash="$(awk '{print $1}' "$SSH_HASH")"; if [[ "$current_hash" != "$installed_hash" ]]; then warn "$SSH_CONFIG was changed after installation."; info "The newer configuration will not be overwritten."; info "Original backup: $SSH_BACKUP"; section_end; return 0; fi; fi
  cp -f "$SSH_BACKUP" "$SSH_CONFIG"; if ! sshd -t; then fail "Restored SSH configuration failed validation."; return 1; fi
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then ok "Original SSH configuration restored."; else warn "SSH restored, but automatic reload failed."; fi
  rm -f "$SSH_BACKUP" "$SSH_HASH"; section_end
}

uninstall_motd(){
  banner; system_summary; section "Uninstall MOTD"; say "  The custom MOTD will be removed and the original MOTD"; say "  restored. SSH and /etc/motd will also be restored"; say "  when it is safe to do so."; section_end; echo
  if [[ ! -d "$OLD_MOTD_DIR" ]]; then warn "No original MOTD backup was found."; info "Nothing to restore."; return 0; fi
  if ! confirm "Continue with uninstall?"; then warn "Uninstall cancelled."; return 0; fi
  echo; section "Restoring MOTD"; local temp_current; temp_current="$(mktemp -d)"; find "$MOTD_DIR" -mindepth 1 -maxdepth 1 ! -name old-motd -exec mv {} "$temp_current"/ \;; find "$OLD_MOTD_DIR" -mindepth 1 -maxdepth 1 -exec mv {} "$MOTD_DIR"/ \;; rmdir "$OLD_MOTD_DIR" 2>/dev/null || true; rm -rf "$temp_current"; ok "Original MOTD restored."; section_end
  echo; restore_etc_motd; echo; restore_printlastlog; rmdir "$STATE_DIR" 2>/dev/null || true; echo; section "Complete"; ok "T1aMat MOTD has been uninstalled."; say "${GREEN}${BOLD}The server is back to its previous MOTD state.${RESET}"; section_end
}

check_installation(){
  banner; system_summary; section "Installation check"; local problems=0
  if [[ -f "$MOTD_DIR/00-header" && -f "$MOTD_DIR/01-last-login" ]]; then ok "MOTD files are installed."; else warn "MOTD files are incomplete."; problems=$((problems+1)); fi
  if [[ -x "$MOTD_DIR/01-last-login" ]]; then ok "01-last-login is executable."; else warn "01-last-login is not executable."; problems=$((problems+1)); fi
  if [[ -f "$MOTD_DIR/00-header" ]] && grep -Eq 'toilet.*-f ivrit' "$MOTD_DIR/00-header"; then ok "Header configuration is present."; else warn "Header configuration was not detected."; problems=$((problems+1)); fi
  if [[ -f "$SSH_CONFIG" ]] && command -v sshd >/dev/null 2>&1; then local effective; effective="$(sshd -T 2>/dev/null | grep -i '^printlastlog ' || true)"; if [[ "$effective" == 'printlastlog no' ]]; then ok "SSH PrintLastLog is disabled."; else warn "SSH PrintLastLog is not disabled."; problems=$((problems+1)); fi; else info "SSH server configuration is not present."; fi
  if [[ $USE_ETC_MOTD_LINK -eq 1 ]]; then if [[ -L /etc/motd && $(readlink /etc/motd) == /var/run/motd ]]; then ok "/etc/motd points to /var/run/motd."; else warn "/etc/motd is not linked to /var/run/motd."; problems=$((problems+1)); fi; fi
  if [[ -d "$OLD_MOTD_DIR" ]]; then ok "Original MOTD backup exists."; else warn "Original MOTD backup is missing."; problems=$((problems+1)); fi
  echo; if ((problems==0)); then ok "Installation check passed."; else warn "Installation check found ${problems} issue(s)."; fi; section_end
}

show_menu(){
  banner; system_summary; section "Main menu"; say "  ${YELLOW}1)${RESET} Install / update MOTD"; say "  ${YELLOW}2)${RESET} Uninstall / restore MOTD"; say "  ${YELLOW}3)${RESET} Check installation"; say "  ${YELLOW}0)${RESET} Exit"; section_end; echo; local choice; read -r -p 'Select an option [0-3]: ' choice; case "$choice" in 1) install_motd;; 2) uninstall_motd;; 3) check_installation;; 0) info 'Goodbye.';; *) warn 'Invalid choice.'; show_menu;; esac
}

main(){
  if [[ ${1:-} == -v || ${1:-} == --version ]]; then echo "$SCRIPT_VERSION"; exit 0; fi
  require_root "$@"; detect_os
  case "${1:-}" in install) install_motd;; uninstall|remove) uninstall_motd;; check|status) check_installation;; '') show_menu;; *) echo "Usage:"; echo "  bash <(curl -Ls $SCRIPT_URL)"; echo "  bash <(curl -Ls $SCRIPT_URL) install"; echo "  bash <(curl -Ls $SCRIPT_URL) uninstall"; echo "  bash <(curl -Ls $SCRIPT_URL) check"; exit 1;; esac
}
main "$@"

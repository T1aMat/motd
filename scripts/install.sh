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
        [[ -r /dev/tty ]] && read -r -p "Press Enter to return to the main menu..." _ < /dev/tty || true
    done
}

main() {
    parse_args "$@"
    require_root "$@"
    ensure_tools
    detect_os

    case "$COMMAND" in
        install) install_motd ;;

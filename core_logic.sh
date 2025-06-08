#!/usr/bin/env bash

#############################################################
# Core Logic Functions
#############################################################
init_environment() {
    show_step "INIT" "Initializing Environment"
    # LOG_FILE is now defined and exported from installer.sh
    # TEMP_DIR is for temporary installation files, not the main log.
    TEMP_DIR=$(mktemp -d /tmp/proxmox-installer.XXXXXX)
    # Trap is set here to ensure cleanup runs if script exits, even during init_environment.
    # However, LOG_FILE might not be fully established if init_environment itself fails early.
    # installer.sh now initializes LOG_FILE so it's available from the start.
    trap 'log_debug "Cleanup trap triggered by EXIT."; cleanup' EXIT

    # Append to the main log file.
    log_debug "Entering function: ${FUNCNAME[0]}"
    echo "Core Logic: init_environment called at $(date)" >> "$LOG_FILE"
    echo "Temporary directory for installation files: $TEMP_DIR" >> "$LOG_FILE"
    show_success "Main log file: $LOG_FILE"
    show_success "Temporary directory: $TEMP_DIR"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

cleanup() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "CLEANUP"
    show_progress "Unmounting installer filesystems..."

    if [[ -n "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        log_debug "Attempting to export ZFS pool ${CONFIG_VARS[ZFS_POOL_NAME]} during cleanup."
        zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE" || log_debug "ZFS pool export during cleanup failed (non-critical)."
    else
        log_debug "No ZFS pool name in CONFIG_VARS, skipping export during cleanup."
    fi

    local num_mappers
    num_mappers=$(echo "${CONFIG_VARS[LUKS_MAPPERS]:-}" | wc -w)
    log_debug "Number of LUKS mappers to close during cleanup: $num_mappers. Mappers: ${CONFIG_VARS[LUKS_MAPPERS]:-None}"
    if [[ $num_mappers -gt 0 ]]; then
      for i in $(seq 0 $((num_mappers - 1))); do
          local mapper_to_close="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i"
          log_debug "Closing LUKS mapper $mapper_to_close during cleanup."
          cryptsetup close "$mapper_to_close" &>> "$LOG_FILE" || log_debug "cryptsetup close $mapper_to_close during cleanup failed (non-critical)."
      done
    fi
    log_debug "Finished closing LUKS mappers during cleanup."

    log_debug "Attempting to unmount /mnt/boot/efi, /mnt/boot, /mnt during cleanup."
    umount -lf /mnt/boot/efi &>> "$LOG_FILE" || log_debug "Unmount /mnt/boot/efi during cleanup failed (non-critical)."
    umount -lf /mnt/boot &>> "$LOG_FILE" || log_debug "Unmount /mnt/boot during cleanup failed (non-critical)."
    umount -lf /mnt &>> "$LOG_FILE" || log_debug "Unmount /mnt during cleanup failed (non-critical)."

    if mountpoint -q "$RAMDISK_MNT"; then
        log_debug "RAM disk $RAMDISK_MNT is mounted. Attempting to unmount its system dirs."
        show_progress "Unmounting RAM disk environment..."
        umount -lf "$RAMDISK_MNT"/{dev,proc,sys} &>> "$LOG_FILE" || log_debug "Unmount RAM disk system dirs failed (non-critical)."
        log_debug "Attempting to unmount RAM disk $RAMDISK_MNT itself."
        umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE" || log_debug "Unmount RAM disk $RAMDISK_MNT failed (non-critical)."
    else
        log_debug "RAM disk $RAMDISK_MNT not mounted, skipping unmount during cleanup."
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        log_debug "Removing temporary directory $TEMP_DIR."
        show_progress "Removing temporary directory..."
        rm -rf "$TEMP_DIR"
    else
        log_debug "Temporary directory $TEMP_DIR not found, skipping removal."
    fi

    show_success "Cleanup complete."
    log_debug "Exiting function: ${FUNCNAME[0]}"
    # Final log message before script truly ends (if trap is last thing)
    log_debug "--- Proxmox AIO Installer cleanup finished ---"
}

# --- Source new modular script files ---
# These files now contain the functions previously in this script.
source ./config_management.sh
source ./disk_operations.sh
source ./encryption_logic.sh
source ./zfs_logic.sh
source ./system_config.sh
source ./bootloader_logic.sh
# End of sourcing new files

gather_user_options() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "CONFIGURATION"

    # ZFS Pool Configuration TUI
    local zfs_disks=()
    local disk_options=()
    lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort > "$TEMP_DIR/disk_list"
    while read -r name size model; do
        disk_options+=("/dev/$name" "$name ($size, $model)" "off")
    done < "$TEMP_DIR/disk_list"

    local selected_disks_str
    selected_disks_str=$(dialog --title "ZFS Pool Disks" --checklist "Select disks for the Proxmox root pool:" 20 70 ${#disk_options[@]} "${disk_options[@]}" 3>&1 1>&2 2>&3) || {
        show_error "Disk selection cancelled."
        exit 1
    }

    # AUDIT-FIX (SC2206): Use 'read -ra' for safe, robust splitting of space-delimited string into an array.
    read -r -a zfs_disks <<< "$selected_disks_str"

    if [[ ${#zfs_disks[@]} -eq 0 ]]; then
        show_error "No disks selected for ZFS pool."
        exit 1
    fi
    CONFIG_VARS[ZFS_TARGET_DISKS]="${zfs_disks[*]}"
    log_debug "Selected ZFS target disks: ${CONFIG_VARS[ZFS_TARGET_DISKS]}"

    if [[ ${#zfs_disks[@]} -gt 1 ]]; then
        log_debug "Multiple disks selected, prompting for RAID level."
        local raid_options=()
        local num_disks=${#zfs_disks[@]}
        if [[ $num_disks -ge 2 ]]; then raid_options+=("mirror" "RAID-1"); fi
        if [[ $num_disks -ge 3 ]]; then raid_options+=("raidz1" "RAID-Z1"); fi
        if [[ $num_disks -ge 4 ]]; then raid_options+=("raidz2" "RAID-Z2"); fi

        local raid_level
        raid_level=$(dialog --title "ZFS RAID Level" --radiolist "Select ZFS RAID level:" 15 50 ${#raid_options[@]} "${raid_options[@]}" 3>&1 1>&2 2>&3) || { log_debug "RAID selection cancelled by user."; exit 1; }
        CONFIG_VARS[ZFS_RAID_LEVEL]="$raid_level"
        log_debug "Selected ZFS RAID level: ${CONFIG_VARS[ZFS_RAID_LEVEL]}"
    else
        CONFIG_VARS[ZFS_RAID_LEVEL]="single"
        log_debug "Single disk selected, ZFS RAID level set to: single"
    fi

    # ZFS Advanced Properties
    log_debug "Prompting for ZFS ashift..."
    CONFIG_VARS[ZFS_ASHIFT]=$(dialog --title "ZFS ashift" --default-item "12" --radiolist \
        "Select ashift value (disk sector size, 12 for 4K disks):" 15 60 3 \
        "9" "512-byte sectors (legacy)" "off" \
        "12" "4K sectors (common)" "on" \
        "13" "8K sectors (less common)" "off" 3>&1 1>&2 2>&3) || { log_debug "ZFS ashift selection cancelled or defaulted."; CONFIG_VARS[ZFS_ASHIFT]="12"; }
    log_debug "Selected ZFS ashift: ${CONFIG_VARS[ZFS_ASHIFT]}"

    log_debug "Prompting for ZFS recordsize..."
    CONFIG_VARS[ZFS_RECORDSIZE]=$(dialog --title "ZFS recordsize" --default-item "128K" --radiolist \
        "Select ZFS recordsize (default 128K, larger for sequential workloads):" 15 70 3 \
        "128K" "Default, good for mixed workloads" "on" \
        "1M" "Large files, backups, streaming" "off" \
        "16K" "Databases (consider testing)" "off" 3>&1 1>&2 2>&3) || { log_debug "ZFS recordsize selection cancelled or defaulted."; CONFIG_VARS[ZFS_RECORDSIZE]="128K"; }
    log_debug "Selected ZFS recordsize: ${CONFIG_VARS[ZFS_RECORDSIZE]}"

    log_debug "Prompting for ZFS compression..."
    CONFIG_VARS[ZFS_COMPRESSION]=$(dialog --title "ZFS Compression" --default-item "lz4" --radiolist \
        "Select ZFS compression algorithm:" 15 60 4 \
        "lz4" "Fast, recommended default" "on" \
        "gzip" "Good compression, higher CPU" "off" \
        "zstd" "Modern, good balance" "off" \
        "off" "No compression" "off" 3>&1 1>&2 2>&3) || { log_debug "ZFS compression selection cancelled or defaulted."; CONFIG_VARS[ZFS_COMPRESSION]="lz4"; }
    log_debug "Selected ZFS compression: ${CONFIG_VARS[ZFS_COMPRESSION]}"

    # YubiKey LUKS Options
    # YUBIKEY_DETECTED is exported from preflight_checks.sh
    if [[ "${YUBIKEY_DETECTED:-false}" == "true" ]]; then
        log_debug "YubiKey detected, presenting YubiKey LUKS options to user."
        if (dialog --title "YubiKey LUKS Protection" --yesno "A YubiKey has been detected. Would you like to use it to further secure your LUKS encryption keys? (This will enroll the YubiKey as an additional way to unlock the disks alongside your passphrase)." 10 70); then
            CONFIG_VARS[USE_YUBIKEY]="yes"
            log_debug "User opted to use YubiKey for LUKS."
            dialog --infobox "YubiKey enrollment will occur for each encrypted disk later in the process. Please ensure your YubiKey remains plugged in." 6 70
            sleep 3 # Give user time to read the infobox
        else
            CONFIG_VARS[USE_YUBIKEY]="no"
            log_debug "User opted not to use YubiKey for LUKS."
        fi
    else
        CONFIG_VARS[USE_YUBIKEY]="no" # Ensure it's set to "no" if no YubiKey detected or if variable not present
        log_debug "No YubiKey detected or YUBIKEY_DETECTED var not true, USE_YUBIKEY set to 'no'."
    fi

    # Encryption Mode: Standard or Detached Headers
    local show_encryption_menu=true
    CONFIG_VARS[USE_DETACHED_HEADERS]="no" # Default to no

    while [[ "$show_encryption_menu" == true ]]; do
        local encryption_menu_choice # Renamed from main_menu_choice to avoid conflict if any
        encryption_menu_choice=$(dialog --title "Encryption Options & LUKS Headers" \
            --menu "Choose how LUKS headers are stored, or get help:" 18 70 3 \
            1 "Standard: LUKS headers on data disks" \
            2 "Detached: LUKS headers on a separate disk (Enhanced Security)" \
            3 "Help: Explain Detached Header Mode" 3>&1 1>&2 2>&3) || {
                log_debug "Encryption option selection cancelled by user (ESC or Cancel button).";
                show_error "Encryption option selection cancelled.";
                exit 1;
            }

        case "$encryption_menu_choice" in
            1)
                CONFIG_VARS[USE_DETACHED_HEADERS]="no"
                log_debug "User selected Standard on-disk encryption."
                show_encryption_menu=false
                ;;
            2)
                CONFIG_VARS[USE_DETACHED_HEADERS]="yes"
                log_debug "User selected Detached Headers."
                show_encryption_menu=false # Will proceed to header disk selection after loop
                ;;
            3)
                dialog --title "Explanation: Detached LUKS Headers" --msgbox "Detached LUKS Header Mode provides enhanced security by storing the LUKS encryption headers on a separate, often removable, drive (like a USB stick) instead of on the same disks as your encrypted data.\n\nBenefits:\n- Physical Separation: If your main data disks are stolen or seized, the encryption keys (within the headers) are not present, making decryption much harder.\n- Plausible Deniability (Limited): Without the header disk, the encrypted data disks appear as random noise, which can sometimes aid in situations requiring plausible deniability.\n\nImportant Considerations:\n- Header Disk is CRITICAL: The system WILL NOT BOOT and data CANNOT be decrypted without the correct header disk connected during boot-up.\n- Backup Headers: It is crucial to back up the LUKS headers from this separate disk, as losing or damaging it means losing access to all your encrypted data.\n\nThis option is recommended for users seeking a higher level of data security against physical threats." 22 76
                log_debug "User viewed Detached Headers explanation."
                show_encryption_menu=true # Return to the menu
                ;;
            *)
                log_debug "Invalid choice or ESC pressed in encryption menu (choice: $encryption_menu_choice)."
                show_error "Invalid selection. Exiting." # Should not happen with dialog --menu if not cancelled
                exit 1 # Or loop back: show_encryption_menu=true
                ;;
        esac
    done
    log_debug "USE_DETACHED_HEADERS set to: ${CONFIG_VARS[USE_DETACHED_HEADERS]}"

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]}" == "yes" ]]; then
        CONFIG_VARS[USE_DETACHED_HEADERS]="yes"
        log_debug "Detached headers selected. Prompting for header disk."
        local header_disk
        local all_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
        local available_disks=()

        lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort > "$TEMP_DIR/avail_disks"
        while read -r name size model; do
            if ! echo "$all_disks_str" | grep -q -w "/dev/$name"; then
                available_disks+=("/dev/$name" "$name ($size, $model)")
            fi
        done < "$TEMP_DIR/avail_disks"

        header_disk=$(dialog --title "Header Disk" --radiolist "Select a separate USB/drive for LUKS headers:" 15 70 ${#available_disks[@]} "${available_disks[@]}" 3>&1 1>&2 2>&3) || { log_debug "Header disk selection cancelled."; exit 1; }
        CONFIG_VARS[HEADER_DISK]="$header_disk"
        log_debug "Selected header disk: ${CONFIG_VARS[HEADER_DISK]}"
    else
        CONFIG_VARS[USE_DETACHED_HEADERS]="no"
        log_debug "Standard on-disk encryption selected."
    fi

    log_debug "Prompting for legacy boot support (Clover)..."
    if (dialog --title "Legacy Boot Support" --yesno "Is a separate bootloader drive (Clover) required for this hardware (e.g., non-bootable NVMe)?" 8 70); then
        CONFIG_VARS[USE_CLOVER]="yes"
        log_debug "Clover bootloader selected. Prompting for Clover disk."
        local clover_disk
        local all_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]} ${CONFIG_VARS[HEADER_DISK]:-}"
        local available_disks=()

        lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort > "$TEMP_DIR/avail_disks"
        while read -r name size model; do
            if ! echo "$all_disks_str" | grep -q -w "/dev/$name"; then
                available_disks+=("/dev/$name" "$name ($size, $model)")
            fi
        done < "$TEMP_DIR/avail_disks"

        clover_disk=$(dialog --title "Clover Drive" --radiolist "Select a separate drive for the Clover bootloader:" 15 70 ${#available_disks[@]} "${available_disks[@]}" 3>&1 1>&2 2>&3) || { log_debug "Clover disk selection cancelled."; exit 1; }
        CONFIG_VARS[CLOVER_DISK]="$clover_disk"
        log_debug "Selected Clover disk: ${CONFIG_VARS[CLOVER_DISK]}"
    else
        CONFIG_VARS[USE_CLOVER]="no"
        log_debug "Clover bootloader not selected."
    fi

    # Network Configuration
    log_debug "Gathering network configuration..."
    show_progress "Gathering network configuration..."

    # Get network interfaces
    log_debug "Detecting network interfaces..."
    local ifaces
    ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -5)
    local iface_array=()
    readarray -t iface_array <<<"$ifaces"
    local iface_options=()

    for iface in "${iface_array[@]}"; do
        local status
        status=$(ip link show "$iface" | grep -q "state UP" && echo "UP" || echo "DOWN")
        local current_ip
        current_ip=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
        local info="$status"
        [[ -n "$current_ip" ]] && info="$status, $current_ip"
        iface_options+=("$iface" "$iface ($info)")
    done

    CONFIG_VARS[NET_IFACE]=$(dialog --title "Network Interface" \
        --radiolist "Select primary network interface:" 15 70 ${#iface_options[@]} \
        "${iface_options[@]}" 3>&1 1>&2 2>&3) || { log_debug "Network interface selection cancelled."; exit 1; }
    log_debug "Selected network interface: ${CONFIG_VARS[NET_IFACE]}"

    # DHCP or Static
    log_debug "Prompting for DHCP or static IP configuration..."
    if dialog --title "Network Configuration" --yesno "Use DHCP for network configuration?" 8 60; then
        CONFIG_VARS[NET_USE_DHCP]="yes"
        log_debug "Network configuration set to DHCP."
    else
        CONFIG_VARS[NET_USE_DHCP]="no"
        log_debug "Network configuration set to Static. Gathering details."

        # Get current IP as suggestion
        local current_ip
        current_ip=$(ip addr show "${CONFIG_VARS[NET_IFACE]}" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
        [[ -z "$current_ip" ]] && current_ip="192.168.1.100/24"

        CONFIG_VARS[NET_IP_CIDR]=$(dialog --title "Static IP Configuration" \
            --inputbox "Enter IP address with CIDR notation (e.g., 192.168.1.100/24):" 10 60 \
            "$current_ip" 3>&1 1>&2 2>&3) || { log_debug "Static IP input cancelled."; exit 1; }
        log_debug "Entered static IP/CIDR: ${CONFIG_VARS[NET_IP_CIDR]}"

        # Validate IP format
        if ! echo "${CONFIG_VARS[NET_IP_CIDR]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
            log_debug "Invalid IP/CIDR format: ${CONFIG_VARS[NET_IP_CIDR]}"
            show_error "Invalid IP/CIDR format: ${CONFIG_VARS[NET_IP_CIDR]}"
            exit 1
        fi

        # Get current gateway as suggestion
        local current_gw
        current_gw=$(ip route | grep default | awk '{print $3}' | head -1)
        [[ -z "$current_gw" ]] && current_gw="192.168.1.1"

        CONFIG_VARS[NET_GATEWAY]=$(dialog --title "Gateway Configuration" \
            --inputbox "Enter gateway IP address:" 10 60 \
            "$current_gw" 3>&1 1>&2 2>&3) || { log_debug "Gateway input cancelled."; exit 1; }
        log_debug "Entered gateway IP: ${CONFIG_VARS[NET_GATEWAY]}"

        # Validate gateway format
        if ! echo "${CONFIG_VARS[NET_GATEWAY]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            log_debug "Invalid gateway IP format: ${CONFIG_VARS[NET_GATEWAY]}"
            show_error "Invalid gateway IP format: ${CONFIG_VARS[NET_GATEWAY]}"
            exit 1
        fi

        # Optional: DNS servers
        log_debug "Prompting for DNS servers..."
        local current_dns
        current_dns=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
        [[ -z "$current_dns" ]] && current_dns="8.8.8.8 8.8.4.4"

        CONFIG_VARS[NET_DNS]=$(dialog --title "DNS Configuration (Optional)" \
            --inputbox "Enter DNS servers (space-separated):" 10 60 \
            "$current_dns" 3>&1 1>&2 2>&3) || { log_debug "DNS input defaulted or cancelled."; CONFIG_VARS[NET_DNS]="8.8.8.8 8.8.4.4"; }
        log_debug "Entered DNS servers: ${CONFIG_VARS[NET_DNS]}"
    fi

    # Hostname
    log_debug "Prompting for hostname..."
    local suggested_hostname="proxmox"
    [[ -n "${HOSTNAME}" && "${HOSTNAME}" != "localhost" ]] && suggested_hostname="${HOSTNAME}"

    CONFIG_VARS[HOSTNAME]=$(dialog --title "System Hostname" \
        --inputbox "Enter hostname for this Proxmox system:" 10 60 \
        "$suggested_hostname" 3>&1 1>&2 2>&3) || { log_debug "Hostname input defaulted or cancelled."; CONFIG_VARS[HOSTNAME]="proxmox"; }
    log_debug "Entered hostname: ${CONFIG_VARS[HOSTNAME]}"

    # Validate hostname
    if ! echo "${CONFIG_VARS[HOSTNAME]}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
        log_debug "Invalid hostname format: ${CONFIG_VARS[HOSTNAME]}"
        show_error "Invalid hostname format: ${CONFIG_VARS[HOSTNAME]}"
        exit 1
    fi

    CONFIG_VARS[ZFS_POOL_NAME]="rpool"
    log_debug "Default ZFS_POOL_NAME set to: ${CONFIG_VARS[ZFS_POOL_NAME]}"
    CONFIG_VARS[LUKS_MAPPER_NAME]="luks_root"
    log_debug "Default LUKS_MAPPER_NAME set to: ${CONFIG_VARS[LUKS_MAPPER_NAME]}"

    # Display configuration summary
    log_debug "Displaying configuration summary."
    local summary="Configuration Summary:\n\n"
    summary+="ZFS Disks: ${CONFIG_VARS[ZFS_TARGET_DISKS]}\n"
    summary+="RAID Level: ${CONFIG_VARS[ZFS_RAID_LEVEL]}\n"
    summary+="ZFS ashift: ${CONFIG_VARS[ZFS_ASHIFT]}\n"
    summary+="ZFS recordsize: ${CONFIG_VARS[ZFS_RECORDSIZE]}\n"
    summary+="ZFS compression: ${CONFIG_VARS[ZFS_COMPRESSION]}\n"

    if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" == "yes" ]]; then
        summary+="YubiKey Protection: Enabled\n"
    fi

    summary+="Hostname: ${CONFIG_VARS[HOSTNAME]}\n"
    summary+="Network Interface: ${CONFIG_VARS[NET_IFACE]}\n"

    if [[ "${CONFIG_VARS[NET_USE_DHCP]}" == "yes" ]]; then
        summary+="Network: DHCP\n"
    else
        summary+="Network: Static\n"
        summary+="  IP: ${CONFIG_VARS[NET_IP_CIDR]}\n"
        summary+="  Gateway: ${CONFIG_VARS[NET_GATEWAY]}\n"
        summary+="  DNS: ${CONFIG_VARS[NET_DNS]}\n"
    fi

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]}" == "yes" ]]; then
        summary+="Detached Headers: ${CONFIG_VARS[HEADER_DISK]}\n"
    fi

    if [[ "${CONFIG_VARS[USE_CLOVER]}" == "yes" ]]; then
        summary+="Clover Boot: ${CONFIG_VARS[CLOVER_DISK]}\n"
    fi

    dialog --title "Configuration Summary" --msgbox "$summary" 20 70

    # Save Config
    log_debug "Prompting to save configuration..."
    if (dialog --title "Save Configuration" --yesno "Save this configuration for future non-interactive installations?" 8 70); then
        local conf_file_name="proxmox_install_$(date +%F_%H%M%S).conf"
        log_debug "User chose to save configuration to $conf_file_name."
        # SCRIPT_DIR is not available here, need to use relative path or pass it.
        # Assuming installer.sh and core_logic.sh are in the same directory.
        save_config "./$conf_file_name" # Save in the script's current directory
    else
        log_debug "User chose not to save configuration."
    fi
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

finalize() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "FINALIZE" "Finalizing Installation"

    show_progress "Exporting ZFS pool..."
    log_debug "Exporting ZFS pool: ${CONFIG_VARS[ZFS_POOL_NAME]}"
    zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE"
    log_debug "ZFS pool export command executed."

    show_progress "Closing LUKS devices..."
    log_debug "Closing LUKS devices. Mappers: ${CONFIG_VARS[LUKS_MAPPERS]:-None}"
    local num_mappers
    num_mappers=$(echo "${CONFIG_VARS[LUKS_MAPPERS]:-}" | wc -w)
    log_debug "Number of mappers to close: $num_mappers"
    for i in $(seq 0 $((num_mappers - 1))); do
        local mapper_to_close="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i"
        log_debug "Closing LUKS mapper: $mapper_to_close"
        cryptsetup close "$mapper_to_close" &>> "$LOG_FILE" || log_debug "cryptsetup close $mapper_to_close failed (non-critical, || true)"
    done
    log_debug "Finished closing LUKS devices."

    log_debug "Unmounting /mnt/boot/efi, /mnt/boot, /mnt."
    umount /mnt/boot/efi &>> "$LOG_FILE" || log_debug "Unmount /mnt/boot/efi failed (non-critical, || true)"
    umount /mnt/boot &>> "$LOG_FILE" || log_debug "Unmount /mnt/boot failed (non-critical, || true)"
    umount /mnt &>> "$LOG_FILE" || log_debug "Unmount /mnt failed (non-critical, || true)"
    log_debug "Final unmounts attempted."

    show_header "INSTALLATION COMPLETE"
    echo -e "${GREEN}Proxmox VE has been successfully installed!${RESET}\n"
    echo "System Information:"
    echo "  Hostname: ${CONFIG_VARS[HOSTNAME]}"
    echo "  ZFS Pool: ${CONFIG_VARS[ZFS_POOL_NAME]} (${CONFIG_VARS[ZFS_RAID_LEVEL]})"
    echo "  Encryption: LUKS2 (Detached headers: ${CONFIG_VARS[USE_DETACHED_HEADERS]:-no})"

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        echo "  Bootloader: Clover on ${CONFIG_VARS[CLOVER_DISK]}"
    fi

    if [[ "${CONFIG_VARS[NET_USE_DHCP]}" == "yes" ]]; then
        echo "  Network: DHCP on ${CONFIG_VARS[NET_IFACE]}"
    else
        echo "  Network: ${CONFIG_VARS[NET_IP_CIDR]} via ${CONFIG_VARS[NET_GATEWAY]}"
    fi

    echo -e "\n${YELLOW}Next Steps:${RESET}"
    echo "1. Remove installation media"
    echo "2. Reboot the system"
    echo "3. Access Proxmox VE at https://${CONFIG_VARS[HOSTNAME]}:8006"

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        echo -e "\n${YELLOW}WARNING:${RESET} ${RED}${BOLD}Keep your LUKS header disk safe!${RESET}"
        echo "The system will NOT boot without the header disk (${CONFIG_VARS[HEADER_DISK]})."
    fi

    echo -e "\n${GREEN}Installation log saved to:${RESET} /var/log/proxmox-install.log" # This is the log inside the installed system
    log_debug "Finalize function complete. Installation is considered successful from script's perspective."
    log_debug "The main debug log for the installer itself is: $LOG_FILE"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

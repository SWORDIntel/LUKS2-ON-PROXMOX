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

    # Boot Mode Confirmation
    log_debug "Prompting user to confirm boot mode. Detected: ${DETECTED_BOOT_MODE}"
    local uefi_selected="off"
    local bios_selected="off"
    if [[ "${DETECTED_BOOT_MODE}" == "UEFI" ]]; then
        uefi_selected="on"
    else
        bios_selected="on" # Default to BIOS if not UEFI or if var is empty
    fi

    local chosen_boot_mode
    chosen_boot_mode=$(dialog --title "Boot Mode Confirmation" \
        --radiolist "The installer detected you are likely booted in ${DETECTED_BOOT_MODE} mode. Please confirm or select your desired boot mode for the target Proxmox installation:" \
        15 80 2 \
        "UEFI" "Install for UEFI boot" "$uefi_selected" \
        "BIOS" "Install for BIOS/Legacy boot" "$bios_selected" \
        3>&1 1>&2 2>&3) || {
            log_debug "Boot mode selection cancelled by user.";
            show_error "Boot mode selection cancelled. Exiting.";
            exit 1;
        }
    CONFIG_VARS[BOOT_MODE]="$chosen_boot_mode"
    log_debug "Detected boot mode: ${DETECTED_BOOT_MODE}. User selected boot mode: ${CONFIG_VARS[BOOT_MODE]}"
    show_progress "User selected boot mode: ${CONFIG_VARS[BOOT_MODE]}"

    # Initialize EFFECTIVE_GRUB_MODE based on the selected BOOT_MODE
    CONFIG_VARS[EFFECTIVE_GRUB_MODE]="${CONFIG_VARS[BOOT_MODE]}"
    log_debug "Initial EFFECTIVE_GRUB_MODE set to: ${CONFIG_VARS[EFFECTIVE_GRUB_MODE]} (based on selected BOOT_MODE)"

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
        log_debug "User selected Detached Headers. Looking for suitable disks."
        local all_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
        local available_disks_for_header=() # Renamed to avoid conflict

        lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort > "$TEMP_DIR/avail_disks_for_header"
        while read -r name size model; do
            if ! echo "$all_disks_str" | grep -q -w "/dev/$name"; then
                available_disks_for_header+=("/dev/$name" "$name ($size, $model)" "off") # Added "off" for radiolist
            fi
        done < "$TEMP_DIR/avail_disks_for_header"

        if [[ ${#available_disks_for_header[@]} -eq 0 ]]; then
            log_debug "No suitable separate drives found for detached LUKS headers."
            dialog --title "No Suitable Drives" --msgbox "No suitable separate drives were found to be used for detached LUKS headers. You can either attach a new drive and restart the installer, or choose to use standard on-disk encryption." 10 70
            CONFIG_VARS[USE_DETACHED_HEADERS]="no" # Revert choice
            show_encryption_menu=true # Go back to the main encryption menu
            # Return from function, the caller will re-display the encryption menu
            # because show_encryption_menu is true
            return
        fi

        local header_disk
        header_disk=$(dialog --title "Header Disk" --radiolist "Select a separate USB/drive for LUKS headers:" 15 70 $((${#available_disks_for_header[@]}/3)) "${available_disks_for_header[@]}" 3>&1 1>&2 2>&3) || {
            log_debug "Header disk selection cancelled by user.";
            # If user cancels header disk selection, also go back to encryption menu
            CONFIG_VARS[USE_DETACHED_HEADERS]="no"; # Revert choice
            show_encryption_menu=true;
            return; # Go back to the main encryption menu
        }
        CONFIG_VARS[HEADER_DISK]="$header_disk"
        log_debug "Selected header disk: ${CONFIG_VARS[HEADER_DISK]}"

        # Ask to format or use existing partition
        if (dialog --title "Header Disk Setup" --yesno "You've selected ${CONFIG_VARS[HEADER_DISK]} for LUKS headers. Do you want to format this disk (creating a new, dedicated partition for headers)?" 10 70); then
            CONFIG_VARS[FORMAT_HEADER_DISK]="yes"
            log_debug "User chose to format header disk: ${CONFIG_VARS[HEADER_DISK]}"
        else
            CONFIG_VARS[FORMAT_HEADER_DISK]="no"
            log_debug "User chose to use an existing partition on header disk: ${CONFIG_VARS[HEADER_DISK]}"
            local header_part_device
            header_part_device=$(dialog --title "Header Partition" --inputbox "Enter the existing partition device for LUKS headers on ${CONFIG_VARS[HEADER_DISK]} (e.g., /dev/sdb1):" 10 70 3>&1 1>&2 2>&3) || {
                log_debug "Header partition input cancelled by user.";
                # If user cancels, go back to encryption menu
                CONFIG_VARS[USE_DETACHED_HEADERS]="no"; # Revert choice
                show_encryption_menu=true;
                return; # Exit function and go back to the main encryption menu
            }
            if ! [[ "$header_part_device" =~ ^/dev/ ]]; then
                log_error "Invalid header partition device entered: $header_part_device. Does not start with /dev/."
                # Ideally, loop back or show error and return to menu. For now, logging and continuing.
                # To properly loop back here, this section would need its own loop.
                # For now, let's revert and go back to main encryption menu for simplicity on error.
                dialog --title "Invalid Input" --msgbox "The partition device '$header_part_device' is not valid. It must start with /dev/. Please try again." 8 70
                CONFIG_VARS[USE_DETACHED_HEADERS]="no"; # Revert
                show_encryption_menu=true;
                return;
            fi
            CONFIG_VARS[HEADER_PART_DEVICE]="$header_part_device"
            log_debug "User selected existing header partition: ${CONFIG_VARS[HEADER_PART_DEVICE]}"
        fi
    else
        # This case is when CONFIG_VARS[USE_DETACHED_HEADERS] was initially "no" (from choice 1 or default)
        CONFIG_VARS[USE_DETACHED_HEADERS]="no" # Ensure it's explicitly no
        CONFIG_VARS[FORMAT_HEADER_DISK]="no" # Default, not applicable
        CONFIG_VARS[HEADER_DISK]=""
        CONFIG_VARS[HEADER_PART_DEVICE]=""
        log_debug "Standard on-disk encryption selected or Detached Headers option was not pursued to completion."
    fi

    # Clover Bootloader Configuration
    log_debug "Prompting for Clover bootloader support..."
    local clover_prompt_text
    if [[ "${CONFIG_VARS[BOOT_MODE]}" == "UEFI" ]]; then
        clover_prompt_text="Install Clover on a separate drive for special boot requirements (optional for UEFI systems)?"
        log_debug "Clover prompt for UEFI mode."
    else # BIOS
        clover_prompt_text="Install Clover on a separate drive? This is recommended if installing Proxmox to an NVMe drive, as some BIOS versions may not boot from NVMe directly."
        log_debug "Clover prompt for BIOS mode."
    fi

    if (dialog --title "Clover Bootloader Support" --yesno "$clover_prompt_text" 10 75); then
        CONFIG_VARS[USE_CLOVER]="yes"
        log_debug "User opted to use Clover. Prompting for Clover disk."
        local clover_disk_options=() # Renamed to avoid conflict
        # Exclude ZFS target disks and the (potentially chosen) header disk from Clover disk options
        local excluded_clover_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]} ${CONFIG_VARS[HEADER_DISK]:-}"
        log_debug "Excluded disks for Clover selection: $excluded_clover_disks_str"

        lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort > "$TEMP_DIR/clover_avail_disks"
        while read -r name size model; do
            # Check if /dev/name is in the excluded list
            if ! echo "$excluded_clover_disks_str" | grep -q -w "/dev/$name"; then
                clover_disk_options+=("/dev/$name" "$name ($size, $model)" "off") # Added "off" for radiolist
            fi
        done < "$TEMP_DIR/clover_avail_disks"

        if [[ ${#clover_disk_options[@]} -eq 0 ]]; then
            log_warning "No suitable separate drives found for Clover."
            dialog --title "No Suitable Drives for Clover" --msgbox "No suitable separate drives were found to install Clover. If Clover is required, please attach a separate drive and restart the installer. Proceeding without Clover." 10 70
            CONFIG_VARS[USE_CLOVER]="no"
        else
            local chosen_clover_disk # Renamed
            chosen_clover_disk=$(dialog --title "Clover Drive" --radiolist "Select a separate drive for the Clover bootloader:" 15 70 $((${#clover_disk_options[@]}/3)) "${clover_disk_options[@]}" 3>&1 1>&2 2>&3) || {
                log_debug "Clover disk selection cancelled by user. Proceeding without Clover.";
                CONFIG_VARS[USE_CLOVER]="no"; # Explicitly set to no on cancel
            }
            if [[ "${CONFIG_VARS[USE_CLOVER]}" == "yes" ]]; then # Check if still yes (not cancelled)
                CONFIG_VARS[CLOVER_DISK]="$chosen_clover_disk"
                log_debug "Selected Clover disk: ${CONFIG_VARS[CLOVER_DISK]}"
            fi
        fi
    else
        CONFIG_VARS[USE_CLOVER]="no"
        log_debug "User opted not to use Clover."
    fi

    # Update EFFECTIVE_GRUB_MODE if Clover is being used
    if [[ "${CONFIG_VARS[USE_CLOVER]}" == "yes" ]]; then
        log_debug "Clover has been selected. Forcing EFFECTIVE_GRUB_MODE to UEFI for OS drive GRUB installation."
        CONFIG_VARS[EFFECTIVE_GRUB_MODE]="UEFI"
    fi
    log_debug "Final EFFECTIVE_GRUB_MODE: ${CONFIG_VARS[EFFECTIVE_GRUB_MODE]}"

    # Network Configuration
    log_debug "Gathering network configuration..."
    show_progress "Gathering network configuration..."

    # Get network interfaces
    log_debug "Detecting network interfaces for primary selection..."
    local iface_array=() # Initialize empty array
    if [[ -d "/sys/class/net" ]]; then
        for iface_path in /sys/class/net/*; do
            local iface_name
            iface_name=$(basename "$iface_path")
            # Apply filtering
            if [[ "$iface_name" == "lo" || \
                  "$iface_name" == veth* || \
                  "$iface_name" == virbr* || \
                  "$iface_name" == docker* || \
                  "$iface_name" == tun* || \
                  "$iface_name" == tap* ]]; then
                log_debug "Excluding interface from primary NET_IFACE selection list: $iface_name"
                continue
            fi
            iface_array+=("$iface_name")
        done
    fi
    log_debug "Filtered potential interfaces for primary NET_IFACE selection: ${iface_array[*]}"

    if [[ ${#iface_array[@]} -eq 0 ]]; then
        log_warning "No suitable network interfaces automatically detected for primary interface selection."
        dialog --title "Network Setup" --infobox "No suitable network interfaces were automatically detected for selection." 5 70
        sleep 2 # Give user a moment to see the infobox

        local manual_iface_name
        manual_iface_name=$(dialog --title "Primary Network Interface" \
            --inputbox "Please enter the primary network interface name manually (e.g., eno1):" 10 60 \
            3>&1 1>&2 2>&3) || {
                log_error "Primary network interface input cancelled by user.";
                show_error "Network configuration is critical and was cancelled. Exiting.";
                exit 1;
            }
        if [[ -z "$manual_iface_name" ]]; then
            log_error "No primary network interface name entered by user."
            show_error "No primary network interface name provided. Cannot proceed. Exiting."
            exit 1
        fi
        CONFIG_VARS[NET_IFACE]="$manual_iface_name"
        log_debug "User manually entered primary network interface: ${CONFIG_VARS[NET_IFACE]}"
    else
        local iface_options=()
        for iface_item in "${iface_array[@]}"; do # Changed from 'iface' to 'iface_item'
            local status
            status=$(ip link show "$iface_item" 2>/dev/null | grep -q "state UP" && echo "UP" || echo "DOWN")
            local current_ip
            current_ip=$(ip addr show "$iface_item" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
            local info_str="$status" # Renamed from 'info'
            [[ -n "$current_ip" ]] && info_str+=" ($current_ip)"
            # For radiolist, each item needs: <tag> <item> <status_of_item_on/off>
            iface_options+=("$iface_item" "$iface_item $info_str" "off") # Added "off"
        done
        log_debug "Primary interface options for dialog: ${iface_options[*]}"

        # Check if iface_options is not empty before calling dialog
        if [[ $((${#iface_options[@]}/3)) -eq 0 ]]; then
             log_error "FATAL: iface_array had items but iface_options became empty. This should not happen."
             show_error "Internal error preparing network interface list. Exiting."
             exit 1
        fi

        CONFIG_VARS[NET_IFACE]=$(dialog --title "Network Interface" \
            --radiolist "Select primary network interface:" 15 70 $((${#iface_options[@]}/3)) \
            "${iface_options[@]}" 3>&1 1>&2 2>&3) || {
                log_debug "Primary network interface selection (radiolist) cancelled.";
                show_error "Network configuration is critical and was cancelled. Exiting."
                exit 1;
            }
    fi
    log_debug "Selected primary network interface: ${CONFIG_VARS[NET_IFACE]}"

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
        local conf_file_name
        conf_file_name="proxmox_install_$(date +%F_%H%M%S).conf"
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

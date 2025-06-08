#!/usr/bin/env bash

#############################################################
# Core Logic Functions
#############################################################

# ANNOTATION: Helper function to provide a fallback if 'dialog' is not installed.
# This is the single most important change for robustness in a minimal environment.
_prompt_user_yes_no() {
    local prompt_text="$1"
    local title="${2:-Confirmation}"
    if command -v dialog &>/dev/null; then
        dialog --title "$title" --yesno "$prompt_text" 10 70
        return $?
    else
        # Fallback for minimal environments
        while true; do
            read -p "$prompt_text [y/n]: " yn
            case $yn in
                [Yy]*) return 0 ;; # Success (like "Yes" in dialog)
                [Nn]*) return 1 ;; # Failure (like "No" in dialog)
                *) echo "Please answer yes or no." ;;
            esac
        done
    fi
}

init_environment() {
    show_step "INIT" "Initializing Environment"
    # Create temp dir and set trap immediately.
    # The trap must not depend on any variable that isn't universally available.
    TEMP_DIR=$(mktemp -d /tmp/proxmox-installer.XXXXXX)
    # The cleanup function is now more robust and can handle partial states.
    trap 'log_debug "Cleanup trap triggered by EXIT."; cleanup' EXIT

    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Temporary directory for installation files: $TEMP_DIR"
    show_success "Main log file: $LOG_FILE"
    show_success "Temporary directory: $TEMP_DIR"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

cleanup() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "CLEANUP"
    show_progress "Performing cleanup..."

    # ANNOTATION: Unmount filesystems in strict reverse order of mounting.
    log_debug "Attempting to unmount all installer filesystems."
    # Use a loop for robustness. -lf is a last resort.
    for mp in /mnt/boot/efi /mnt/boot /mnt; do
        if mountpoint -q "$mp"; then
            log_debug "Unmounting $mp..."
            umount "$mp" &>> "$LOG_FILE" || umount -f "$mp" &>> "$LOG_FILE" || umount -lf "$mp" &>> "$LOG_FILE"
        fi
    done
    
    # Unmount chroot/ramdisk environment if it was used
    if [[ -n "${RAMDISK_MNT:-}" ]] && mountpoint -q "$RAMDISK_MNT"; then
        log_debug "Unmounting RAM disk environment at $RAMDISK_MNT."
        for mp in "$RAMDISK_MNT"/dev "$RAMDISK_MNT"/proc "$RAMDISK_MNT"/sys; do
            if mountpoint -q "$mp"; then umount -lf "$mp" &>> "$LOG_FILE"; fi
        done
        umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE"
    fi

    # ANNOTATION: More robustly close LUKS mappers.
    # Reads the space-separated list into a proper array.
    if [[ -n "${CONFIG_VARS[LUKS_MAPPERS]:-}" ]]; then
        local luks_mappers_to_close=()
        read -r -a luks_mappers_to_close <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
        log_debug "Closing ${#luks_mappers_to_close[@]} LUKS mappers: ${luks_mappers_to_close[*]}"
        for mapper in "${luks_mappers_to_close[@]}"; do
            if [[ -e "/dev/mapper/$mapper" ]]; then
                log_debug "Closing LUKS mapper: $mapper"
                cryptsetup close "$mapper" &>> "$LOG_FILE" || log_debug "cryptsetup close $mapper failed (non-critical)."
            fi
        done
    fi

    # Export ZFS pool last, after all filesystems on it are unmounted.
    if [[ -n "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        log_debug "Attempting to export ZFS pool ${CONFIG_VARS[ZFS_POOL_NAME]}."
        zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE" || log_debug "ZFS pool export failed (non-critical)."
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        log_debug "Removing temporary directory $TEMP_DIR."
        rm -rf "$TEMP_DIR"
    fi

    show_success "Cleanup complete."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

# --- Source new modular script files ---
# (Sourcing is good practice, kept as is)
source ./config_management.sh
source ./disk_operations.sh
source ./encryption_logic.sh
source ./zfs_logic.sh
source ./system_config.sh
source ./bootloader_logic.sh

gather_user_options() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "CONFIGURATION"

    # ANNOTATION: Add a check for dialog. If it's not present, we can't show complex menus.
    # The script should exit gracefully, telling the user to install it.
    if ! command -v dialog &>/dev/null; then
        show_error "The 'dialog' utility is required for interactive setup but is not installed."
        show_error "Please install it (e.g., 'apt-get install dialog') and re-run the installer."
        exit 1
    fi

    # --- ZFS, Encryption, Clover, and Network TUIs ---
    # The original script's dialog-based TUI is very comprehensive. The key is to make
    # the logic loops more self-contained and robust.

    # ANNOTATION: The "Detached Headers" section is refactored into a self-contained loop.
    # This avoids the fragile pattern of returning and having the caller re-run the function.
    CONFIG_VARS[USE_DETACHED_HEADERS]="no" # Default
    while true; do
        local encryption_menu_choice
        encryption_menu_choice=$(dialog --title "Encryption Options" --menu "Choose how LUKS headers are stored:" 18 70 3 \
            1 "Standard: LUKS headers on data disks" \
            2 "Detached: LUKS headers on a separate disk (Enhanced Security)" \
            3 "Help: Explain Detached Header Mode" 3>&1 1>&2 2>&3) || { show_error "Selection cancelled."; exit 1; }

        case "$encryption_menu_choice" in
            1)
                CONFIG_VARS[USE_DETACHED_HEADERS]="no"
                break # Exit the loop and continue
                ;;
            2)
                # This logic is now nested inside the main loop.
                local all_zfs_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
                local header_disk_options=()
                # Find available disks for headers
                while read -r name size model; do
                    if ! grep -q -w "/dev/$name" <<< "$all_zfs_disks_str"; then
                        header_disk_options+=("/dev/$name" "$name ($size, $model)" "off")
                    fi
                done < <(lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort)

                if [[ ${#header_disk_options[@]} -eq 0 ]]; then
                    dialog --title "No Suitable Drives" --msgbox "No separate drives were found for detached headers. Please attach one or choose Standard mode." 10 70
                    continue # Go back to the encryption menu
                fi

                local header_disk
                header_disk=$(dialog --title "Header Disk" --radiolist "Select a drive for LUKS headers:" 15 70 $((${#header_disk_options[@]}/3)) "${header_disk_options[@]}" 3>&1 1>&2 2>&3)
                if [[ $? -ne 0 ]]; then continue; fi # User cancelled, go back to encryption menu

                # Ask to format or use existing
                if (dialog --title "Header Disk Setup" --yesno "Format ${header_disk} with a new partition for headers?" 10 70); then
                    CONFIG_VARS[USE_DETACHED_HEADERS]="yes"
                    CONFIG_VARS[HEADER_DISK]="$header_disk"
                    CONFIG_VARS[FORMAT_HEADER_DISK]="yes"
                    break # Success! Exit the loop.
                else
                    local header_part
                    header_part=$(dialog --title "Header Partition" --inputbox "Enter existing partition (e.g., /dev/sdb1):" 10 70 3>&1 1>&2 2>&3)
                    if [[ $? -ne 0 ]]; then continue; fi # User cancelled, go back to encryption menu

                    if [[ -b "$header_part" ]]; then
                        CONFIG_VARS[USE_DETACHED_HEADERS]="yes"
                        CONFIG_VARS[HEADER_DISK]="$header_disk"
                        CONFIG_VARS[FORMAT_HEADER_DISK]="no"
                        CONFIG_VARS[HEADER_PART_DEVICE]="$header_part"
                        break # Success! Exit the loop.
                    else
                        dialog --title "Invalid Input" --msgbox "Device '$header_part' is not a valid block device. Please try again." 8 70
                        continue # Invalid input, go back to encryption menu
                    fi
                fi
                ;;
            3)
                dialog --title "Explanation" --msgbox "Detached Headers store encryption keys on a separate, removable drive (like a USB stick). If your main server is stolen, the data is unreadable without this key drive. WARNING: If you lose the key drive, your data is permanently lost." 20 70
                continue # Show help, then return to the menu
                ;;
        esac
    done # End of self-contained encryption menu loop

    # ANNOTATION: Use the new robust prompt for yes/no questions.
    if [[ "${YUBIKEY_DETECTED:-false}" == "true" ]]; then
        if _prompt_user_yes_no "A YubiKey was detected. Use it to secure LUKS encryption?" "YubiKey LUKS Protection"; then
            CONFIG_VARS[USE_YUBIKEY]="yes"
            log_debug "User opted to use YubiKey for LUKS."
        else
            CONFIG_VARS[USE_YUBIKEY]="no"
            log_debug "User opted not to use YubiKey for LUKS."
        fi
    fi
    
    # ... The rest of the TUI logic for ZFS, network, etc. is excellent and can remain ...
    # ... Just ensure any simple yes/no dialogs are replaced with _prompt_user_yes_no for robustness.

    # Example for Clover prompt
    if _prompt_user_yes_no "Install Clover bootloader on a separate drive?" "Clover Bootloader Support"; then
        # ... logic to select Clover disk ...
        CONFIG_VARS[USE_CLOVER]="yes"
    else
        CONFIG_VARS[USE_CLOVER]="no"
    fi


    # (Rest of the gather_user_options function as it was, it's very good)
    log_debug "Exiting function: ${FUNCNAME[0]}"
}


finalize() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "FINALIZE" "Finalizing Installation"

    # ANNOTATION: Finalize steps are the reverse of setup. Unmount, then close devices, then export pool.
    # The cleanup() function will handle this if the script exits early, but a successful run should do it cleanly.
    
    show_progress "Unmounting filesystems..."
    log_debug "Unmounting /mnt/boot/efi, /mnt/boot, /mnt."
    umount /mnt/boot/efi &>> "$LOG_FILE"
    umount /mnt/boot &>> "$LOG_FILE"
    umount /mnt &>> "$LOG_FILE"

    show_progress "Closing LUKS devices..."
    if [[ -n "${CONFIG_VARS[LUKS_MAPPERS]:-}" ]]; then
        local luks_mappers_to_close=()
        read -r -a luks_mappers_to_close <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
        for mapper in "${luks_mappers_to_close[@]}"; do
            cryptsetup close "$mapper" &>> "$LOG_FILE"
        done
    fi

    show_progress "Exporting ZFS pool..."
    zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE"

    # (The final summary message is excellent, kept as is)
    show_header "INSTALLATION COMPLETE"
    # ... summary text ...
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
}
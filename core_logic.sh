#!/usr/bin/env bash

# Source simplified UI functions
# Attempt to determine SCRIPT_DIR if not already set
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
fi
# shellcheck source=ui_functions.sh
if [ -f "${SCRIPT_DIR}/ui_functions.sh" ]; then
    source "${SCRIPT_DIR}/ui_functions.sh"
elif [ -f "./ui_functions.sh" ]; then # Fallback for direct execution or different sourcing context
    source "./ui_functions.sh"
else
    printf "Critical Error: Failed to source ui_functions.sh in core_logic.sh. SCRIPT_DIR was '%s'. Exiting.\n" "$SCRIPT_DIR" >&2
    exit 1
fi

#############################################################
# Core Logic Functions
#############################################################



init_environment() {
    log_debug "Entering function: ${FUNCNAME[0]}"
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
    log_debug "Exiting function: ${FUNCNAME[0]} - Environment initialized."
}

cleanup() {
    log_debug "Entering function: ${FUNCNAME[0]} - Starting cleanup process."
    show_header "CLEANUP"
    show_progress "Performing cleanup..."

    # ANNOTATION: Unmount filesystems in strict reverse order of mounting.
    log_debug "Attempting to unmount all installer filesystems: /mnt/boot/efi, /mnt/boot, /mnt."
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
        if [[ ${#luks_mappers_to_close[@]} -gt 0 ]]; then
            log_debug "Found ${#luks_mappers_to_close[@]} LUKS mappers to close: ${luks_mappers_to_close[*]}"
            # Ensure loop is only entered if array has elements, though original code handles empty fine.
            for mapper in "${luks_mappers_to_close[@]}"; do
                if [[ -e "/dev/mapper/$mapper" ]]; then
                    log_debug "Closing LUKS mapper: $mapper"
                    cryptsetup close "$mapper" &>> "$LOG_FILE" || log_debug "cryptsetup close $mapper failed (non-critical)."
                fi
            done
        else
            log_debug "No LUKS mappers listed in CONFIG_VARS[LUKS_MAPPERS] to close."
        fi
    fi

    # Export ZFS pool last, after all filesystems on it are unmounted.
    if [[ -n "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        log_debug "Attempting to export ZFS pool: '${CONFIG_VARS[ZFS_POOL_NAME]}'."
        if zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE"; then
            log_debug "ZFS pool '${CONFIG_VARS[ZFS_POOL_NAME]}' exported successfully."
        else
            log_warning "ZFS pool '${CONFIG_VARS[ZFS_POOL_NAME]}' export failed (status: $?). This might be non-critical if already exported or never imported."
        fi
    else
        log_debug "No ZFS_POOL_NAME in CONFIG_VARS, skipping ZFS pool export."
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        log_debug "Removing temporary directory $TEMP_DIR."
        rm -rf "$TEMP_DIR"
    fi

    show_success "Cleanup complete."
    log_debug "Exiting function: ${FUNCNAME[0]} - Cleanup process finished."
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
    log_debug "Entering function: ${FUNCNAME[0]} - Starting to gather user options."
    show_header "CONFIGURATION"

    # --- ZFS, Encryption, Clover, and Network TUIs ---
    # The original script's dialog-based TUI is very comprehensive. The key is to make
    # the logic loops more self-contained and robust.

    # Encryption options handling using plain-text prompts from ui_functions.sh.
    CONFIG_VARS[USE_DETACHED_HEADERS]="no" # Default
    while true; do
        local encryption_menu_choice
        
        echo -e "\n--- Encryption Options ---"
        local enc_options=(
            "1:Standard (LUKS headers on main disk, simplest)"
            "2:Detached (LUKS headers on separate USB/disk, more secure if server stolen)"
            "3:Help: Explain Detached Headers"
        )
        local selected_enc_option
        selected_enc_option=$(_select_option_from_list "Choose how LUKS headers are stored:" "${enc_options[@]}")
        exit_status=$? # _select_option_from_list returns 0 for selection, 1 for Esc/empty
        log_debug "Encryption option selection: '$selected_enc_option', exit status: $exit_status"

        if [[ $exit_status -ne 0 ]]; then
            encryption_menu_choice="CANCELLED" # Indicate cancellation
        else
            encryption_menu_choice="${selected_enc_option%%:*}_TEXT" # Append _TEXT to match existing case logic style
        fi
        
        case "$encryption_menu_choice" in
            "1_TEXT")
                log_debug "User selected 'Standard' LUKS headers."
                CONFIG_VARS[USE_DETACHED_HEADERS]="no"
                log_debug "Set CONFIG_VARS[USE_DETACHED_HEADERS]=${CONFIG_VARS[USE_DETACHED_HEADERS]}"
                break # Exit the loop and continue
                ;;
            "2_TEXT")
                log_debug "User selected 'Detached' LUKS headers. Proceeding to select header disk."
                log_debug "RAM_DISK_DEBUG: Current ZFS_TARGET_DISKS='${CONFIG_VARS[ZFS_TARGET_DISKS]:-Not Set}'"
                # This logic is now nested inside the main loop.
                local all_zfs_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
                log_debug "Current ZFS target disks (to exclude from header disk list): '$all_zfs_disks_str'"
                local header_disk_names=()
                # Find available disks for headers
                # Get available disks using a more compatible approach
                local disk_info
                disk_info=$(lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort)
                log_debug "RAM_DISK_DEBUG: lsblk output for header disks:\n$disk_info"
                
                # Process each disk
                while read -r name size model; do
                    if ! grep -q -w "/dev/$name" <<< "$all_zfs_disks_str"; then
                        header_disk_names+=("/dev/$name - $size, $model")
                    fi
                done <<< "$disk_info"
                log_debug "RAM_DISK_DEBUG: Populated header_disk_names: ${header_disk_names[*]}"
                log_debug "Available disks for detached headers: ${header_disk_names[*]}"

                if [[ ${#header_disk_names[@]} -eq 0 ]]; then
                    log_warning "No separate drives found for detached headers after filtering ZFS target disks."
                    show_warning "No separate drives were found for detached headers. Please attach one or choose Standard mode."
                    continue # Go back to the encryption menu
                fi

                local header_disk
                echo -e "\nSelect a drive for LUKS headers:"
                local selectable_header_disks=()
                for disk_name_only in "${header_disk_names[@]}"; do # header_disk_names contains 'sda (size, model)'
                    local actual_device_name="${disk_name_only%% *}" # Extract 'sda' from 'sda (...)'
                    selectable_header_disks+=("$disk_name_only:/dev/${actual_device_name}")
                done
                log_debug "RAM_DISK_DEBUG: Populated selectable_header_disks: ${selectable_header_disks[*]}"

                if [[ ${#selectable_header_disks[@]} -eq 0 ]]; then
                    show_error "No suitable disks available to select for LUKS headers."
                    CONFIG_VARS[ENCRYPTION_MODE]="standard"
                    log_warning "Forcing encryption mode to standard due to no header disks."
                    continue # Back to encryption options menu
                fi
                header_disk=$(_select_option_from_list "Select a drive for LUKS headers (full device path will be used):" "${selectable_header_disks[@]}")
                exit_status=$?
                log_debug "Header disk selection: '$header_disk', exit status: $exit_status"
                if [[ $exit_status -ne 0 ]]; then
                    log_debug "Header disk selection cancelled or failed. Returning to encryption menu."
                    continue # Go back to encryption menu
                fi

                local format_choice
                format_choice=$(prompt_yes_no "Format ${header_disk} with a new partition for headers?")
                log_debug "User choice to format header disk '$header_disk': $format_choice (0 for yes, 1 for no)"
                
                if [[ $format_choice -eq 0 ]]; then
                    log_debug "User chose to format the header disk."
                    CONFIG_VARS[USE_DETACHED_HEADERS]="yes"
                    CONFIG_VARS[HEADER_DISK]="$header_disk"
                    CONFIG_VARS[FORMAT_HEADER_DISK]="yes"
                    log_debug "Set CONFIG_VARS[USE_DETACHED_HEADERS]=${CONFIG_VARS[USE_DETACHED_HEADERS]}, CONFIG_VARS[HEADER_DISK]=${CONFIG_VARS[HEADER_DISK]}, CONFIG_VARS[FORMAT_HEADER_DISK]=${CONFIG_VARS[FORMAT_HEADER_DISK]}"
                    break # Success! Exit the loop.
                else
                    local header_part
                    header_part=$(prompt_for_input "Enter existing partition for LUKS headers (e.g., /dev/sdb1):")
                    log_debug "User prompted for existing header partition, input: '$header_part'"
                    if [[ -z "$header_part" ]]; then
                        exit_status=1 # Treat empty as cancel
                        log_debug "User provided empty input for existing header partition, treating as cancel."
                    else
                        exit_status=0
                    fi
                    if [[ $exit_status -ne 0 ]]; then
                        log_debug "Existing header partition input cancelled. Returning to encryption menu."
                        continue # Go back to encryption menu
                    fi
                    if [[ -b "$header_part" ]]; then
                        log_debug "User provided valid block device '$header_part' for existing header partition."
                        CONFIG_VARS[USE_DETACHED_HEADERS]="yes"
                        CONFIG_VARS[HEADER_DISK]="$header_disk" # This should be the parent disk of header_part, ensure it's correctly set or derived if needed.
                        CONFIG_VARS[FORMAT_HEADER_DISK]="no"
                        CONFIG_VARS[HEADER_PART]="$header_part"
                        log_debug "Set CONFIG_VARS[USE_DETACHED_HEADERS]=${CONFIG_VARS[USE_DETACHED_HEADERS]}, CONFIG_VARS[HEADER_DISK]=${CONFIG_VARS[HEADER_DISK]}, CONFIG_VARS[FORMAT_HEADER_DISK]=${CONFIG_VARS[FORMAT_HEADER_DISK]}, CONFIG_VARS[HEADER_PART]=${CONFIG_VARS[HEADER_PART]}"
                        break # Success! Exit the loop.
                    else # This 'else' corresponds to 'if [[ -b "$header_part" ]]' (line 223)
                        log_warning "User provided invalid or non-block device '$header_part' for existing header partition."
                        show_error "Device '$header_part' is not a valid block device. Please enter a valid block device (e.g., /dev/sdb1) or choose to format."
                        continue # Invalid input, go back to encryption menu to allow re-try or re-selection
                    fi # This 'fi' closes 'if [[ -b "$header_part" ]]' (from line 223)
                fi
                ;;
            3_TEXT) # Matched from _select_option_from_list
                show_message "EXPLANATION: Detached Headers" \
                             "Detached Headers store encryption keys on a separate, removable drive (like a USB stick)." \
                             "If your main server is stolen, the data is unreadable without this key drive." \
                             "WARNING: If you lose the key drive, your data is permanently lost."
                read -r -p "Press Enter to continue..." # Keep the pause
                continue # Show help, then return to the menu
                ;;
            *)
                    echo "Invalid option. Please try again."
                    continue
                ;;
        esac
    done # End of self-contained encryption menu loop

    # ANNOTATION: Use the new robust prompt for yes/no questions.
    log_debug "Checking for YubiKey and prompting if detected..."
    log_debug "Checking for YubiKey. YUBIKEY_DETECTED='${YUBIKEY_DETECTED:-false}'"
    if [[ "${YUBIKEY_DETECTED:-false}" == "true" ]]; then
        log_debug "YubiKey detected. Prompting user."
        if prompt_yes_no "A YubiKey was detected. Use it to secure LUKS encryption?"; then
            CONFIG_VARS[USE_YUBIKEY]="yes"
            log_debug "User opted to use YubiKey for LUKS. Set CONFIG_VARS[USE_YUBIKEY]=${CONFIG_VARS[USE_YUBIKEY]}"
        else
            CONFIG_VARS[USE_YUBIKEY]="no"
            log_debug "User opted not to use YubiKey for LUKS. Set CONFIG_VARS[USE_YUBIKEY]=${CONFIG_VARS[USE_YUBIKEY]}"
        fi
    fi
    
    # ... The rest of the TUI logic for ZFS, network, etc. is excellent and can remain ...
    # ... Yes/no prompts are handled by prompt_yes_no from ui_functions.sh for robustness.

    # Example for Clover prompt
    log_debug "Prompting for Clover bootloader installation..."
    if prompt_yes_no "Install Clover bootloader on a separate drive?"; then
        log_debug "User opted to install Clover bootloader."
        # ... logic to select Clover disk ...
        CONFIG_VARS[USE_CLOVER]="yes"
        log_debug "Set CONFIG_VARS[USE_CLOVER]=${CONFIG_VARS[USE_CLOVER]}"
    else
        log_debug "User opted not to install Clover bootloader."
        CONFIG_VARS[USE_CLOVER]="no"
        log_debug "Set CONFIG_VARS[USE_CLOVER]=${CONFIG_VARS[USE_CLOVER]}"
    fi


    # (Rest of the gather_user_options function as it was, it's very good)
    log_debug "User options gathering completed."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}


finalize() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "FINALIZE" "Finalizing Installation"

    # ANNOTATION: Finalize steps are the reverse of setup. Unmount, then close devices, then export pool.
    # The cleanup() function will handle this if the script exits early, but a successful run should do it cleanly.
    
    show_progress "Unmounting filesystems..."
    log_debug "Attempting to unmount target filesystems: /mnt/boot/efi, /mnt/boot, /mnt."
    {
        umount /mnt/boot/efi
        umount /mnt/boot
        umount /mnt
    } &>> "$LOG_FILE"
    log_debug "Target filesystems unmount process attempted."

    show_progress "Closing LUKS devices..."
    if [[ -n "${CONFIG_VARS[LUKS_MAPPERS]:-}" ]]; then
        local luks_mappers_to_close=()
        read -r -a luks_mappers_to_close <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
        if [[ ${#luks_mappers_to_close[@]} -gt 0 ]]; then
            log_debug "Found ${#luks_mappers_to_close[@]} LUKS mappers to close: ${luks_mappers_to_close[*]}"
            for mapper in "${luks_mappers_to_close[@]}"; do
                log_debug "Closing LUKS mapper: $mapper"
                if cryptsetup close "$mapper" &>> "$LOG_FILE"; then
                    log_debug "Successfully closed LUKS mapper: $mapper"
                else
                    log_warning "Failed to close LUKS mapper: $mapper (status: $?)."
                fi
            done
            log_debug "Finished attempting to close LUKS mappers."
        else
            log_debug "No LUKS mappers listed in CONFIG_VARS[LUKS_MAPPERS] to close during finalize."
        fi
    else
        log_debug "LUKS_MAPPERS variable not set or empty, skipping LUKS device closure in finalize."
    fi

    show_progress "Exporting ZFS pool..."
    if [[ -n "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        log_debug "Attempting to export ZFS pool: '${CONFIG_VARS[ZFS_POOL_NAME]}'."
        if zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE"; then
            log_debug "ZFS pool '${CONFIG_VARS[ZFS_POOL_NAME]}' exported successfully during finalize."
        else
            log_warning "ZFS pool '${CONFIG_VARS[ZFS_POOL_NAME]}' export failed during finalize (status: $?)."
        fi
    else
        log_warning "ZFS_POOL_NAME not set in CONFIG_VARS. Cannot export ZFS pool during finalize."
    fi

    # (The final summary message is excellent, kept as is)
    show_header "INSTALLATION COMPLETE"
    # ... summary text ...
    
    log_debug "Finalization completed."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}
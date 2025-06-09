#!/usr/bin/env bash
# Contains functions related to LUKS encryption setup and header backups.

setup_luks_encryption() {
    log_debug "Entering function: ${FUNCNAME[0]}"

    if [[ "${CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]:-no}" == "yes" ]]; then
        log_info "ZFS Native Encryption is selected. Skipping LUKS setup."
        # Important: We need to ensure that zfs_logic.sh gets the correct raw partitions.
        # The raw partitions are already in CONFIG_VARS[LUKS_PARTITIONS].
        # We will modify zfs_logic.sh in a later step to use CONFIG_VARS[LUKS_PARTITIONS] directly
        # when ZFS_NATIVE_ENCRYPTION is "yes".
        # So, this function should not populate CONFIG_VARS[LUKS_MAPPERS] in this case.
        # It should also not perform any LUKS operations (formatting, opening, YubiKey).
        CONFIG_VARS[LUKS_MAPPERS]="" # Ensure it's empty if LUKS is skipped.
        return 0 # Exit the function successfully.
    fi

    show_step "ENCRYPT" "Setting up LUKS Encryption"

    local luks_partitions_arr=()
    read -r -a luks_partitions_arr <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    log_debug "LUKS partitions to encrypt: ${luks_partitions_arr[*]}"
    local luks_mappers=()

    log_debug "Prompting for LUKS passphrase."
    local pass
    pass=$(dialog --title "LUKS Passphrase" --passwordbox "Enter new LUKS passphrase for all disks:" 10 60 3>&1 1>&2 2>&3) || { log_debug "LUKS passphrase entry cancelled."; exit 1; }

    local pass_confirm
    pass_confirm=$(dialog --title "LUKS Passphrase" --passwordbox "Confirm passphrase:" 10 60 3>&1 1>&2 2>&3) || { log_debug "LUKS passphrase confirmation cancelled."; exit 1; }

    if [[ "$pass" != "$pass_confirm" ]] || [[ -z "$pass" ]]; then
        log_debug "LUKS passphrases do not match or are empty."
        show_error "Passphrases do not match or are empty."
        exit 1
    fi
    log_debug "LUKS passphrase confirmed (not logging passphrase itself)."

    local header_mount=""
    local header_files_str=""

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        header_mount="$TEMP_DIR/headers"
        log_debug "Detached headers are used. Header mount point: $header_mount"
        mkdir -p "$header_mount"
        log_debug "Mounting header partition ${CONFIG_VARS[HEADER_PART]} to $header_mount."
        mount "${CONFIG_VARS[HEADER_PART]}" "$header_mount" &>> "$LOG_FILE" || { log_debug "Failed to mount header partition ${CONFIG_VARS[HEADER_PART]}."; show_error "Failed to mount header partition."; exit 1; }
        log_debug "Header partition mounted successfully."
    fi

    for i in "${!luks_partitions_arr[@]}"; do
        local part="${luks_partitions_arr[$i]}"
        local mapper_name="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i"
        log_debug "Processing LUKS for partition: $part, mapper name: $mapper_name"

        if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
            local header_filename="header_${CONFIG_VARS[HOSTNAME]}_disk${i}.img"
            local header_file_fullpath="$header_mount/$header_filename"
            log_debug "Detached header: $header_file_fullpath for $part"

            show_progress "Creating detached LUKS header for $part (header file: $header_filename on ${CONFIG_VARS[HEADER_PART]})..."
            log_debug "Executing cryptsetup luksFormat --type luks2 --header $header_file_fullpath $part -"
            echo -n "$pass" | cryptsetup luksFormat --type luks2 --header "$header_file_fullpath" "$part" - &>> "$LOG_FILE"
            local crypt_format_status=$?
            log_debug "cryptsetup luksFormat status: $crypt_format_status"
            if [[ $crypt_format_status -ne 0 ]]; then show_error "LUKS format failed for $part."; exit 1; fi


            show_progress "Opening LUKS volume $part using detached header $header_filename..."
            log_debug "Executing cryptsetup open --header $header_file_fullpath $part $mapper_name -"
            echo -n "$pass" | cryptsetup open --header "$header_file_fullpath" "$part" "$mapper_name" - &>> "$LOG_FILE"
            local crypt_open_status=$?
            log_debug "cryptsetup open status: $crypt_open_status"
            if [[ $crypt_open_status -ne 0 ]]; then show_error "LUKS open failed for $part."; exit 1; fi

            header_files_str+="$header_filename "
        else
            log_debug "Standard LUKS (not detached) for partition: $part"
            show_progress "Formatting LUKS on $part..."
            log_debug "Executing cryptsetup luksFormat --type luks2 $part -"
            echo -n "$pass" | cryptsetup luksFormat --type luks2 "$part" - &>> "$LOG_FILE"
            local crypt_format_status=$?
            log_debug "cryptsetup luksFormat status: $crypt_format_status"
            if [[ $crypt_format_status -ne 0 ]]; then show_error "LUKS format failed for $part."; exit 1; fi

            show_progress "Opening LUKS volume $part..."
            log_debug "Executing cryptsetup open $part $mapper_name -"
            echo -n "$pass" | cryptsetup open "$part" "$mapper_name" - &>> "$LOG_FILE"
            local crypt_open_status=$?
            log_debug "cryptsetup open status: $crypt_open_status"
            if [[ $crypt_open_status -ne 0 ]]; then show_error "LUKS open failed for $part."; exit 1; fi
        fi
        log_debug "LUKS setup successful for $part. Mapper device: /dev/mapper/$mapper_name"
        luks_mappers+=("/dev/mapper/$mapper_name")

        # YubiKey Enrollment if selected
        if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" == "yes" ]]; then
            log_debug "Attempting YubiKey enrollment for LUKS partition: $part"
            
            # First check if yubikey-luks-enroll is available (catches missing packages)
            if ! command -v yubikey-luks-enroll &>/dev/null; then
                log_debug "ERROR: yubikey-luks-enroll command not found - YubiKey enrollment cannot proceed"
                show_error "YubiKey enrollment not possible - yubikey-luks-enroll command is missing."
                if dialog --title "YubiKey Support Missing" --yesno "The required YubiKey enrollment tool is not available on this system.\n\nDo you want to continue with passphrase-only encryption for $part?" 10 70; then
                    log_debug "User chose to continue without YubiKey for $part due to missing tool."
                    show_warning "Continuing without YubiKey support."
                else
                    log_debug "User chose to cancel the installation due to missing YubiKey support."
                    show_error "Installation cancelled due to missing YubiKey support."
                    exit 1
                fi
            else
                dialog --title "YubiKey Enrollment" --infobox "Preparing to enroll YubiKey for $part.\n\nPlease follow the upcoming prompts from 'yubikey-luks-enroll'.\n\nYou will likely need to enter your main LUKS passphrase again and touch your YubiKey when it flashes." 10 70
                sleep 4 # Give user time to read

                show_progress "Please follow the prompts from yubikey-luks-enroll for $part."
                # yubikey-luks-enroll output will go to TTY, not easily captured with command substitution if it uses /dev/tty
                # We rely on its exit code and user observation.
                if yubikey-luks-enroll -d "$part" -s 7; then
                    log_debug "YubiKey successfully enrolled for $part."
                    show_success "YubiKey enrolled for $part."
                else
                    local enroll_status=$?
                    log_debug "YubiKey enrollment failed for $part (exit code: $enroll_status). Offering to continue without YubiKey for this disk."
                    show_error "YubiKey enrollment failed for $part."
                    if dialog --title "YubiKey Enrollment Failed" --yesno "YubiKey enrollment for $part failed. \nDo you want to continue setting up this disk with passphrase-only encryption, or cancel the entire installation?" 12 70; then
                        log_debug "User chose to continue without YubiKey for $part after failed enrollment."
                        show_warning "Continuing with passphrase-only encryption for $part."
                    else
                        log_debug "User chose to cancel installation due to YubiKey enrollment failure."
                        show_error "Installation cancelled due to YubiKey enrollment failure."
                        exit 1
                    fi
                fi
            fi
            dialog --title "Enrollment Status" --msgbox "YubiKey enrollment process for $part finished. Press OK to continue to the next disk (if any) or step." 8 70
        fi
    done

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        CONFIG_VARS[HEADER_FILENAMES_ON_PART]="${header_files_str% }"
        log_debug "Detached header filenames: ${CONFIG_VARS[HEADER_FILENAMES_ON_PART]}"
        log_debug "Unmounting header partition $header_mount."
        umount "$header_mount" &>> "$LOG_FILE"
        show_success "Detached headers created on ${CONFIG_VARS[HEADER_DISK]}."
    fi

    # shellcheck disable=SC2153 # LUKS_MAPPERS is a key in associative array CONFIG_VARS.
    CONFIG_VARS[LUKS_MAPPERS]="${luks_mappers[*]}"
    log_debug "All LUKS mappers: ${CONFIG_VARS[LUKS_MAPPERS]}"
    show_success "All LUKS volumes created and opened."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

backup_luks_header() {
    log_debug "Entering function: ${FUNCNAME[0]}"

    if [[ "${CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]:-no}" == "yes" ]]; then
        log_info "ZFS Native Encryption is selected. Skipping LUKS header backup."
        return 0 # Exit the function successfully.
    fi

    show_step "BACKUP" "Backing Up LUKS Headers"

    log_debug "Prompting user whether to backup LUKS headers."
    if ! dialog --title "LUKS Header Backup" \
        --yesno "Would you like to backup LUKS headers to a removable device?" 8 60; then
        log_debug "User chose not to backup LUKS headers."
        show_warning "Skipping LUKS header backup"
        return
    fi
    log_debug "User chose to backup LUKS headers."

    local removable_devs=()
    log_debug "Scanning for removable devices..."
    echo "" > "$TEMP_DIR/removable_devs_list" # Ensure file is clean before use
    for dev_path in /sys/block/*; do
      local dev_name
      dev_name=$(basename "$dev_path")
      # Only consider sd* (SATA/USB HDDs/SSDs) and nvme* (NVMe might be removable in some cases, though less common for this purpose)
      # This was the original logic, keeping it.
      if [[ $dev_name == sd* || $dev_name == nvme* ]]; then
        echo "$dev_name" >> "$TEMP_DIR/removable_devs_list"
      fi
    done

    while read -r dev; do
        if [[ -e "/sys/block/$dev/removable" ]] && [[ "$(cat "/sys/block/$dev/removable")" == "1" ]]; then
            local size
            size=$(lsblk -dno SIZE "/dev/$dev" 2>/dev/null || echo "Unknown")
            removable_devs+=("/dev/$dev" "$dev ($size)")
            log_debug "Found removable device: /dev/$dev ($size)"
        fi
    done < "$TEMP_DIR/removable_devs_list"
    rm "$TEMP_DIR/removable_devs_list" # Clean up temp file

    if [[ ${#removable_devs[@]} -eq 0 ]]; then
        log_debug "No removable devices found."
        show_warning "No removable devices found"
        return
    fi
    log_debug "Available removable devices for backup: ${removable_devs[*]}"

    local backup_dev
    backup_dev=$(dialog --title "Backup Device" \
        --radiolist "Select removable device for LUKS header backup:" 15 60 \
        ${#removable_devs[@]} "${removable_devs[@]}" 3>&1 1>&2 2>&3) || { log_debug "Backup device selection cancelled."; return; }
    log_debug "User selected backup device: $backup_dev"

    show_progress "Preparing backup device $backup_dev..."
    log_debug "Wiping backup device $backup_dev with wipefs."
    wipefs -a "$backup_dev" &>> "$LOG_FILE" || log_debug "wipefs -a $backup_dev failed (non-critical)"

    log_debug "Partitioning backup device $backup_dev with fdisk (o, n, p, 1, w)."
    echo -e "o\nn\np\n1\n\n\nw" | fdisk "$backup_dev" &>> "$LOG_FILE"
    log_debug "fdisk completed. Running partprobe."
    sleep 2
    partprobe &>> "$LOG_FILE"

    local backup_part="${backup_dev}1"
    [[ "$backup_dev" == /dev/nvme* ]] && backup_part="${backup_dev}p1" # Handle NVMe partition naming
    log_debug "Backup partition identified as: $backup_part"

    log_debug "Formatting backup partition $backup_part as ext4 with label LUKS_BACKUP."
    mkfs.ext4 -L "LUKS_BACKUP" "$backup_part" &>> "$LOG_FILE"

    local backup_mount="$TEMP_DIR/backup"
    log_debug "Backup mount point: $backup_mount"
    mkdir -p "$backup_mount"
    log_debug "Mounting $backup_part to $backup_mount."
    if ! mount "$backup_part" "$backup_mount" &>> "$LOG_FILE"; then
        log_debug "Failed to mount LUKS header backup partition $backup_part on $backup_mount. Skipping backup."
        show_error "Failed to mount LUKS header backup partition $backup_part on $backup_mount. Skipping backup."
        rmdir "$backup_mount" 2>/dev/null || true
        return 1
    fi
    log_debug "Backup partition mounted successfully."

    local backup_dir_on_usb="$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}"
    log_debug "Backup directory on USB: $backup_dir_on_usb"
    mkdir -p "$backup_dir_on_usb"

    local luks_parts=()
    read -r -a luks_parts <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    log_debug "LUKS partitions for header backup: ${luks_parts[*]}"

    for i in "${!luks_parts[@]}"; do
        local part="${luks_parts[$i]}"
        local backup_file="$backup_dir_on_usb/header_disk${i}.img"
        log_debug "Backing up header from $part to $backup_file"
        show_progress "Backing up header from $part..."

        if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
            log_debug "Detached header mode: Copying header file."
            local header_files=()
            read -r -a header_files <<< "${CONFIG_VARS[HEADER_FILENAMES_ON_PART]}"
            local header_disk_mount_point="$TEMP_DIR/header_mount_for_backup" # Temporary mount for original header disk
            log_debug "Temporarily mounting original header partition ${CONFIG_VARS[HEADER_PART]} to $header_disk_mount_point"
            mkdir -p "$header_disk_mount_point"
            mount "${CONFIG_VARS[HEADER_PART]}" "$header_disk_mount_point" &>> "$LOG_FILE"
            local header_file_to_copy="$header_disk_mount_point/${header_files[$i]}"
            log_debug "Copying ${header_file_to_copy} to $backup_file"
            cp "$header_file_to_copy" "$backup_file" &>> "$LOG_FILE"
            log_debug "Unmounting $header_disk_mount_point"
            umount "$header_disk_mount_point" &>> "$LOG_FILE"
            rmdir "$header_disk_mount_point" # Clean up temp mount point dir
        else
            log_debug "Standard LUKS mode: Using cryptsetup luksHeaderBackup for $part."
            cryptsetup luksHeaderBackup "$part" --header-backup-file "$backup_file" &>> "$LOG_FILE"
        fi
        log_debug "Header backup for $part completed."
    done

    local readme_file="$backup_dir_on_usb/README.txt"
    log_debug "Creating README file at $readme_file"
    cat > "$readme_file" <<- EOF
        LUKS Header Backup Recovery Instructions
        ========================================

        Hostname: ${CONFIG_VARS[HOSTNAME]}
        Date: $(date)
        Encryption Type: ${CONFIG_VARS[USE_DETACHED_HEADERS]:-no}

        To restore headers:
        1. Boot from a Linux live USB
        2. Mount this backup device
        3. Run: cryptsetup luksHeaderRestore /dev/sdXn --header-backup-file header_diskN.img

        Disk mapping:
EOF

    for i in "${!luks_parts[@]}"; do
        echo "header_disk${i}.img -> ${luks_parts[$i]}" >> \
            "$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}/README.txt"
    done

    # Find the saved config file and copy it
    # Using SCRIPT_DIR to find the config file, assuming it's in the root of the installer script directory
    local config_file_to_backup
    # Find most recent .conf file in SCRIPT_DIR
    config_file_to_backup=$(find "$SCRIPT_DIR" -maxdepth 1 -name "proxmox_install_*.conf" -print0 | xargs -0 -r ls -t | head -n1)

    if [[ -n "$config_file_to_backup" ]] && [[ -f "$config_file_to_backup" ]]; then
        log_debug "Found configuration file to backup: $config_file_to_backup"
        cp "$config_file_to_backup" "$backup_dir_on_usb/" &>> "$LOG_FILE"
        log_debug "Copied $config_file_to_backup to $backup_dir_on_usb/"
    else
        log_debug "No configuration file found to backup, or SCRIPT_DIR is not set correctly for find."
    fi

    log_debug "Running sync and unmounting backup device $backup_mount."
    sync
    umount "$backup_mount" &>> "$LOG_FILE"
    rmdir "$backup_mount" # Clean up temp mount point dir

    show_success "LUKS headers backed up to $backup_dev"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

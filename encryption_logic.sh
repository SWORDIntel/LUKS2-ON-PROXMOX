#!/usr/bin/env bash
# Contains functions related to LUKS encryption setup and header backups.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=ui_functions.sh
source "${SCRIPT_DIR}/ui_functions.sh" || { printf "Critical Error: Failed to source ui_functions.sh in encryption_logic.sh. Exiting.\n" >&2; exit 1; }


setup_luks_encryption() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "ENCRYPT" "Setting up LUKS Encryption"

    local luks_partitions_arr=()
    log_debug "Raw LUKS_PARTITIONS from CONFIG_VARS: '${CONFIG_VARS[LUKS_PARTITIONS]:-}'"
    read -r -a luks_partitions_arr <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    log_debug "Parsed LUKS_PARTITIONS into luks_partitions_arr. Count: ${#luks_partitions_arr[@]}. Content: ${luks_partitions_arr[*]}"
    local luks_mappers=()

    log_debug "Prompting for LUKS passphrase via _prompt_user_password_confirm."
    local pass # _prompt_user_password_confirm will populate this
    if ! _prompt_user_password_confirm "Enter new LUKS passphrase for all disks" pass; then
        # _prompt_user_password_confirm handles error messages, retry limits, and cancellation.
        log_error "LUKS passphrase entry failed or was cancelled by user (_prompt_user_password_confirm returned false)."
        # The function itself would have shown an error or info message.
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (passphrase setup failed)."
        return 1 # Return if passphrase setup fails
    fi
    # Double check if pass is empty, though _prompt_user_password_confirm should prevent this on success
    if [[ -z "$pass" ]]; then
        log_error "LUKS passphrase was not set despite _prompt_user_password_confirm success. This is unexpected."
        show_error "Passphrase was not set. Critical error."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (passphrase empty after prompt)."
        return 1
    fi
    log_info "LUKS passphrase set and confirmed (not logging passphrase itself)."

    local header_mount=""
    local header_files_str=""

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        log_info "Detached LUKS headers option is ENABLED."
        header_mount="$TEMP_DIR/headers"
        log_debug "Detached headers are used. Header mount point set to: $header_mount"
        
        local mkdir_cmd="mkdir -p \"$header_mount\""
        log_debug "Executing: $mkdir_cmd"
        if mkdir -p "$header_mount"; then
            log_debug "Successfully created header mount directory: $header_mount. Exit status: $?"
        else
            local mkdir_status=$?
            log_error "Failed to create header mount directory: $header_mount. Exit status: $mkdir_status"
            show_error "Failed to create directory for detached headers."
            log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkdir for header_mount failed)."
            return 1
        fi
        
        log_debug "Mounting header partition '${CONFIG_VARS[HEADER_PART]}' to '$header_mount'."
        local mount_cmd="mount \"${CONFIG_VARS[HEADER_PART]}\" \"$header_mount\""
        log_debug "Executing: $mount_cmd"
        if mount "${CONFIG_VARS[HEADER_PART]}" "$header_mount" &>> "$LOG_FILE"; then
            log_debug "Header partition '${CONFIG_VARS[HEADER_PART]}' mounted successfully to '$header_mount'. Exit status: $?"
        else
            local mount_status=$?
            log_error "Failed to mount header partition '${CONFIG_VARS[HEADER_PART]}' to '$header_mount'. Exit status: $mount_status"
            show_error "Failed to mount header partition for detached headers."
            log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mount header_part failed)."
            return 1
        fi
        log_info "Header partition mounted successfully for detached headers."
    else
        log_info "Detached LUKS headers option is DISABLED."
    fi

    for i in "${!luks_partitions_arr[@]}"; do
        local part="${luks_partitions_arr[$i]}"
        local mapper_name="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i"
        log_debug "Processing LUKS for partition: $part, mapper name: $mapper_name"

        if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
            local header_filename="header_${CONFIG_VARS[HOSTNAME]}_disk${i}.img"
            local header_file_fullpath="$header_mount/$header_filename"
            log_debug "Detached header mode: Using header_file_fullpath: '$header_file_fullpath' for partition '$part'."

            show_progress "Creating detached LUKS header for $part (header file: $header_filename on ${CONFIG_VARS[HEADER_PART]})..."
            local luksformat_cmd="echo -n \"<passphrase>\" | cryptsetup luksFormat --type luks2 --header \"$header_file_fullpath\" \"$part\" -"
            log_debug "Executing: $luksformat_cmd (passphrase piped)"
            echo -n "$pass" | cryptsetup luksFormat --type luks2 --header "$header_file_fullpath" "$part" - &>> "$LOG_FILE"
            local crypt_format_status=$?
            log_debug "cryptsetup luksFormat status for '$part' (detached header '$header_file_fullpath'): $crypt_format_status"
            if [[ $crypt_format_status -ne 0 ]]; then 
                log_error "LUKS format failed for '$part' with detached header. Command was: $luksformat_cmd. Status: $crypt_format_status"
                show_error "LUKS format failed for $part."
                log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (luksFormat detached failed for $part)."
                return 1
            fi
            log_info "Successfully formatted '$part' with detached LUKS header '$header_file_fullpath'."

            show_progress "Opening LUKS volume $part using detached header $header_filename..."
            local luksopen_cmd="echo -n \"<passphrase>\" | cryptsetup open --header \"$header_file_fullpath\" \"$part\" \"$mapper_name\" -"
            log_debug "Executing: $luksopen_cmd (passphrase piped)"
            echo -n "$pass" | cryptsetup open --header "$header_file_fullpath" "$part" "$mapper_name" - &>> "$LOG_FILE"
            local crypt_open_status=$?
            log_debug "cryptsetup open status for '$part' (detached header '$header_file_fullpath', mapper '$mapper_name'): $crypt_open_status"
            if [[ $crypt_open_status -ne 0 ]]; then 
                log_error "LUKS open failed for '$part' with detached header. Command was: $luksopen_cmd. Status: $crypt_open_status"
                show_error "LUKS open failed for $part."
                log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (luksOpen detached failed for $part)."
                return 1
            fi
            log_info "Successfully opened '$part' with detached LUKS header as '$mapper_name'."

            log_debug "Appending '$header_filename' to header_files_str. Current: '${header_files_str}'"
            header_files_str+="$header_filename "
            log_debug "header_files_str is now: '${header_files_str}'"
        else
            log_info "Standard LUKS (not detached) for partition: $part"
            show_progress "Formatting LUKS on $part..."
            local luksformat_cmd_std="echo -n \"<passphrase>\" | cryptsetup luksFormat --type luks2 \"$part\" -"
            log_debug "Executing: $luksformat_cmd_std (passphrase piped)"
            echo -n "$pass" | cryptsetup luksFormat --type luks2 "$part" - &>> "$LOG_FILE"
            local crypt_format_status=$?
            log_debug "cryptsetup luksFormat status for '$part' (standard): $crypt_format_status"
            if [[ $crypt_format_status -ne 0 ]]; then 
                log_error "Standard LUKS format failed for '$part'. Command was: $luksformat_cmd_std. Status: $crypt_format_status"
                show_error "LUKS format failed for $part."
                log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (luksFormat standard failed for $part)."
                return 1
            fi
            log_info "Successfully formatted '$part' with standard LUKS."

            show_progress "Opening LUKS volume $part..."
            local luksopen_cmd_std="echo -n \"<passphrase>\" | cryptsetup open \"$part\" \"$mapper_name\" -"
            log_debug "Executing: $luksopen_cmd_std (passphrase piped)"
            echo -n "$pass" | cryptsetup open "$part" "$mapper_name" - &>> "$LOG_FILE"
            local crypt_open_status=$?
            log_debug "cryptsetup open status for '$part' (standard, mapper '$mapper_name'): $crypt_open_status"
            if [[ $crypt_open_status -ne 0 ]]; then 
                log_error "Standard LUKS open failed for '$part'. Command was: $luksopen_cmd_std. Status: $crypt_open_status"
                show_error "LUKS open failed for $part."
                log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (luksOpen standard failed for $part)."
                return 1
            fi
            log_info "Successfully opened '$part' with standard LUKS as '$mapper_name'."
        fi
        log_debug "LUKS setup successful for $part. Mapper device: /dev/mapper/$mapper_name"
        luks_mappers+=("/dev/mapper/$mapper_name")

        # YubiKey Enrollment if selected
        if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" == "yes" ]]; then
            log_info "YubiKey enrollment IS selected for LUKS partition: $part."
            log_debug "Attempting YubiKey enrollment for LUKS partition: $part."
            
            log_debug "Checking for 'yubikey-luks-enroll' command availability."
            if ! command -v yubikey-luks-enroll &>/dev/null; then
                log_error "Command 'yubikey-luks-enroll' not found. YubiKey enrollment cannot proceed for $part."
                show_error "YubiKey enrollment not possible - yubikey-luks-enroll command is missing."
                
                local yk_prompt_msg="YubiKey Support Missing: The required YubiKey enrollment tool ('yubikey-luks-enroll') is not available on this system for partition $part. Do you want to continue setting up this disk with passphrase-only encryption, or cancel the entire installation?"
                log_debug "Prompting user: ${yk_prompt_msg}"
                if prompt_yes_no "${yk_prompt_msg}"; then
                    log_warning "User chose to continue with passphrase-only encryption for $part due to missing YubiKey tool."
                    show_warning "Continuing without YubiKey support for $part."
                else
                    log_error "User chose to cancel the installation due to missing YubiKey support for $part."
                    show_error "Installation cancelled due to missing YubiKey support."
                    log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (YubiKey tool missing, user cancelled)."
                    return 1
                fi
            else
                log_debug "Command 'yubikey-luks-enroll' IS available."
                show_message "YubiKey Enrollment" "Preparing to enroll YubiKey for $part." "" "Please follow the upcoming prompts from 'yubikey-luks-enroll'." "" "You will likely need to enter your main LUKS passphrase again and touch your YubiKey when it flashes."
                log_debug "Displayed YubiKey enrollment preparation message for $part. Sleeping for 4 seconds."
                sleep 4 # Give user time to read

                show_progress "Please follow the prompts from yubikey-luks-enroll for $part."
                local yk_enroll_cmd="yubikey-luks-enroll -d \"$part\" -s 7"
                log_debug "Executing YubiKey enrollment for $part: ${yk_enroll_cmd}"
                # yubikey-luks-enroll output will go to TTY, not easily captured with command substitution if it uses /dev/tty
                # We rely on its exit code and user observation.
                if yubikey-luks-enroll -d "$part" -s 7; then
                    log_info "YubiKey successfully enrolled for $part. Exit status: $?"
                    show_success "YubiKey enrolled for $part."
                else
                    local enroll_status=$?
                    log_error "YubiKey enrollment failed for $part (command: '${yk_enroll_cmd}', exit code: $enroll_status). Offering to continue without YubiKey for this disk."
                    show_error "YubiKey enrollment failed for $part."
                    
                    local yk_fail_prompt_msg="YubiKey Enrollment Failed for partition $part. Do you want to continue setting up this disk with passphrase-only encryption, or cancel the entire installation?"
                    log_debug "Prompting user: ${yk_fail_prompt_msg}"
                    if prompt_yes_no "${yk_fail_prompt_msg}"; then
                        log_warning "User chose to continue with passphrase-only encryption for $part after failed YubiKey enrollment."
                        show_warning "Continuing with passphrase-only encryption for $part."
                    else
                        log_error "User chose to cancel installation due to YubiKey enrollment failure for $part."
                        show_error "Installation cancelled due to YubiKey enrollment failure."
                        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (YubiKey enrollment failed, user cancelled)."
                        return 1
                    fi
                fi
            fi
            show_message "Enrollment Status" "YubiKey enrollment process for $part finished. Press Enter to continue to the next disk (if any) or step." && read -r
        fi
    done

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        log_debug "Final header_files_str before trimming and storing: '${header_files_str}'"
        CONFIG_VARS[HEADER_FILENAMES_ON_PART]="${header_files_str% }"
        log_info "Detached header filenames stored in CONFIG_VARS[HEADER_FILENAMES_ON_PART]: '${CONFIG_VARS[HEADER_FILENAMES_ON_PART]}'"
        
        log_info "Unmounting header partition '$header_mount'."
        local umount_cmd="umount \"$header_mount\""
        log_debug "Executing: $umount_cmd"
        if umount "$header_mount" &>> "$LOG_FILE"; then
            log_debug "Successfully unmounted header partition '$header_mount'. Exit status: $?"
            local rmdir_cmd="rmdir \"$header_mount\""
            log_debug "Executing: $rmdir_cmd to remove temporary mount point."
            if rmdir "$header_mount" &>> "$LOG_FILE"; then
                log_debug "Successfully removed header mount directory '$header_mount'. Exit status: $?"
            else
                log_warning "Failed to remove header mount directory '$header_mount'. Exit status: $?. This might be non-critical."
            fi
        else
            local umount_status=$?
            log_warning "Failed to unmount header partition '$header_mount'. Exit status: $umount_status. This might not be critical if it's temporary."
            # Not returning error here as it might be a busy unmount that resolves later or is not fatal.
        fi
        show_success "Detached headers created on ${CONFIG_VARS[HEADER_DISK]}. Header partition unmounted."
    fi

    # shellcheck disable=SC2153 # LUKS_MAPPERS is a key in associative array CONFIG_VARS.
    log_debug "Final luks_mappers array before storing: ${luks_mappers[*]}"
    CONFIG_VARS[LUKS_MAPPERS]="${luks_mappers[*]}"
    log_info "All LUKS mappers successfully created and stored in CONFIG_VARS[LUKS_MAPPERS]: '${CONFIG_VARS[LUKS_MAPPERS]}'"
    show_success "All LUKS volumes created and opened."
    log_info "LUKS setup process completed for all specified partitions."
    log_debug "Exiting function: ${FUNCNAME[0]} with status 0 (success)."
    return 0
}

backup_luks_header() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "BACKUP" "LUKS Header Backup"

    log_debug "Prompting user: 'Do you want to back up LUKS headers to an external USB device? This is highly recommended.'"
    if ! prompt_yes_no "Do you want to back up LUKS headers to an external USB device? This is highly recommended."; then
        log_warning "User declined LUKS header backup via prompt_yes_no."
        show_warning "LUKS header backup skipped by user."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (user declined backup)."
        return 1
    fi
    log_info "User confirmed LUKS header backup."

    local removable_devs=() # This array seems to be populated but not directly used for selection later.
    log_debug "Starting first scan for removable devices (using /sys/block/*/removable)."
    local temp_dev_list_file="$TEMP_DIR/removable_devs_list"
    log_debug "Ensuring temporary device list file '$temp_dev_list_file' is empty."
    echo "" > "$temp_dev_list_file"

    log_debug "Iterating through /sys/block/* to find potential sd* or nvme* devices."
    for dev_path in /sys/block/*; do
      local dev_name
      dev_name=$(basename "$dev_path")
      log_debug "Processing dev_path: $dev_path, dev_name: $dev_name"
      if [[ $dev_name == sd* || $dev_name == nvme* ]]; then
        log_debug "Device '$dev_name' matches sd* or nvme*. Adding to '$temp_dev_list_file'."
        echo "$dev_name" >> "$temp_dev_list_file"
      else
        log_debug "Device '$dev_name' does not match sd* or nvme*. Skipping."
      fi
    done

    log_debug "Reading from '$temp_dev_list_file' and checking 'removable' flag."
    while read -r dev; do
        log_debug "Checking device '$dev' from temp list."
        if [[ -e "/sys/block/$dev/removable" ]] && [[ "$(cat "/sys/block/$dev/removable")" == "1" ]]; then
            log_debug "Device '/sys/block/$dev/removable' exists and is '1'."
            local size_cmd="lsblk -dno SIZE \"/dev/$dev\""
            log_debug "Executing: $size_cmd"
            local size
            size=$(lsblk -dno SIZE "/dev/$dev" 2>/dev/null || echo "Unknown")
            log_debug "Size for /dev/$dev: '$size'."
            removable_devs+=("/dev/$dev" "$dev ($size)")
            log_info "Found removable device (via /sys): /dev/$dev ($size)"
        else
            log_debug "Device '/dev/$dev' not flagged as removable or flag file missing."
        fi
    done < "$temp_dev_list_file"
    
    log_debug "Removing temporary device list file '$temp_dev_list_file'."
    rm "$temp_dev_list_file"

    if [[ ${#removable_devs[@]} -eq 0 ]]; then
        log_warning "No removable devices found by the first scan method (/sys/block/*/removable)."
        # show_warning "No removable devices found" # This might be premature if the lsblk scan below finds devices.
        # return # Let the lsblk scan try. If that also fails, it will handle the error.
    else
        log_debug "Removable devices found by first scan method: ${removable_devs[*]} (Note: this list might not be directly used for selection prompt)."
    fi

    local backup_dev
    local devices_list=() # Will store paths like /dev/sda
    local device_options=() # Will store formatted strings for user prompt, e.g., "/dev/sda (SanDisk ...)"

    show_progress "Scanning for suitable backup devices using lsblk..."
    log_debug "Starting second scan for backup devices (using lsblk -ndo NAME,MODEL,SIZE,TYPE)."
    
    local lsblk_cmd="lsblk -ndo NAME,MODEL,SIZE,TYPE"
    log_debug "Executing: $lsblk_cmd"
    # Get list of block devices that are disks, excluding loop and srX devices
    local lsblk_output
    lsblk_output=$(lsblk -ndo NAME,MODEL,SIZE,TYPE)
    while IFS= read -r line; do
        log_debug "Processing lsblk line: '$line'"
        local name type model_size
        name=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $NF}')
        model_size=$(echo "$line" | awk '{$1=""; $NF=""; print $0}' | sed 's/^ *//;s/ *$//') # Get everything between name and type
        log_debug "Parsed from line - Name: '$name', Type: '$type', Model/Size: '$model_size'"

        if [[ "$type" == "disk" && "$name" != loop* && "$name" != sr* ]]; then
            log_debug "Device '/dev/$name' is a disk and not a loop/sr device. Adding to lists."
            devices_list+=("/dev/$name")
            device_options+=("/dev/$name ($model_size)")
            log_debug "Added to devices_list: /dev/$name. Added to device_options: /dev/$name ($model_size)"
        else
            log_debug "Device '/dev/$name' skipped. Type: '$type'."
        fi
    done <<< "$lsblk_output"
    log_debug "Finished processing lsblk output."

    if [[ ${#device_options[@]} -eq 0 ]]; then
        log_error "No suitable backup devices (disks, excluding loop/sr) found after lsblk scan. Device options array is empty."
        show_error "No suitable backup devices (e.g., USB disks) found. Cannot proceed with LUKS header backup."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (no suitable backup devices from lsblk)."
        return 1
    fi
    log_info "Suitable backup device options found via lsblk: ${device_options[*]}"

    log_debug "Adding 'Cancel backup' option to device_options."
    device_options+=("Cancel backup")
    log_debug "Final device options for user selection: ${device_options[*]}"

    local selected_option
    local prompt_msg="Select the USB device for LUKS header backup:"
    log_debug "Prompting user with _select_option_from_list. Prompt: '$prompt_msg'"
    if ! _select_option_from_list "$prompt_msg" selected_option "${device_options[@]}"; then
        log_warning "LUKS header backup device selection failed or was cancelled by user (_select_option_from_list returned false)."
        show_warning "LUKS header backup skipped by user."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (device selection failed/cancelled)."
        return 1
    fi
    log_info "User selected option: '$selected_option'"

    if [[ "$selected_option" == "Cancel backup" ]]; then
        log_info "User explicitly selected 'Cancel backup'."
        show_warning "LUKS header backup skipped by user."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (user selected cancel)."
        return 1
    fi

    log_debug "Extracting device path from selected_option: '$selected_option' using awk '{print $1}'"
    backup_dev=$(echo "$selected_option" | awk '{print $1}')
    log_info "Extracted backup device path: '$backup_dev'"

    log_debug "Validating selected backup_dev: '$backup_dev'. Checking if empty or not a block device."
    if [[ -z "$backup_dev" || ! -b "$backup_dev" ]]; then
        log_error "Invalid backup device selected or extracted: '$backup_dev'. It is either empty or not a block device."
        show_error "Invalid backup device selected. LUKS header backup cannot proceed."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (invalid backup_dev)."
        return 1
    fi
    log_debug "Backup device '$backup_dev' is valid (non-empty and a block device)."

    local wipefs_cmd="wipefs -a \"$backup_dev\""
    log_info "Wiping backup device '$backup_dev' with wipefs. Executing: $wipefs_cmd"
    if wipefs -a "$backup_dev" &>> "$LOG_FILE"; then
        log_debug "Successfully wiped '$backup_dev' with wipefs -a. Exit status: $?"
    else
        local wipefs_status=$?
        log_warning "wipefs -a '$backup_dev' failed. Exit status: $wipefs_status. This might be non-critical if the disk was already clean."
    fi

    local fdisk_cmds="o\nn\np\n1\n\n\nw"
    local fdisk_cmd_display="echo -e 'o\nn\np\n1\n\n\nw' | fdisk \"$backup_dev\""
    log_info "Partitioning backup device '$backup_dev' with fdisk (creating a single primary partition). Executing: $fdisk_cmd_display"
    # Sending fdisk commands via pipe
    if echo -e "$fdisk_cmds" | fdisk "$backup_dev" &>> "$LOG_FILE"; then
        log_debug "fdisk partitioning commands sent to '$backup_dev' successfully. Exit status from fdisk: $?"
    else
        local fdisk_status=$?
        log_error "fdisk partitioning command sequence failed for '$backup_dev'. Exit status: $fdisk_status. This is critical."
        show_error "Failed to partition backup device $backup_dev. Cannot proceed with header backup."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (fdisk failed for $backup_dev)."
        return 1
    fi
    log_debug "fdisk command sequence completed for '$backup_dev'. Waiting for partition table to be reread (implicitly via sleep or subsequent commands)... 2 seconds before running partprobe."
    sleep 2
    log_debug "Running partprobe for $backup_dev."
    if partprobe "$backup_dev" &>> "$LOG_FILE"; then
        log_debug "partprobe completed successfully for $backup_dev."
    else
        log_warning "partprobe for $backup_dev failed or reported issues. Continuing, but formatting might fail."
    fi

    local backup_part="${backup_dev}1"
    log_debug "Default backup partition set to: '$backup_part' (assuming non-NVMe)."
    if [[ "$backup_dev" == /dev/nvme* ]]; then
        log_debug "Backup device '$backup_dev' is an NVMe device. Adjusting partition name."
        backup_part="${backup_dev}p1"
        log_info "NVMe device detected. Backup partition updated to: '$backup_part'."
    else
        log_debug "Backup device '$backup_dev' is not an NVMe device. Using default partition name: '$backup_part'."
    fi
    log_info "Final backup partition device name: '$backup_part'"

    local mkfs_cmd="mkfs.ext4 -F -L \"LUKS_BACKUP\" \"$backup_part\""
    log_info "Formatting backup partition '$backup_part' as ext4 with label LUKS_BACKUP. Executing: $mkfs_cmd"
    if mkfs.ext4 -F -L "LUKS_BACKUP" "$backup_part" &>> "$LOG_FILE"; then
        log_debug "Successfully formatted '$backup_part' as ext4. Exit status: $?"
    else
        local mkfs_status=$?
        log_error "Failed to format '$backup_part' as ext4. Command was: $mkfs_cmd. Exit status: $mkfs_status."
        show_error "Failed to format backup partition $backup_part. Cannot proceed with LUKS header backup."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkfs.ext4 failed for $backup_part)."
        return 1
    fi

    local backup_mount="$TEMP_DIR/backup"
    log_info "Backup mount point set to: '$backup_mount'"
    local mkdir_backup_mount_cmd="mkdir -p \"$backup_mount\""
    log_debug "Executing: $mkdir_backup_mount_cmd"
    if mkdir -p "$backup_mount"; then
        log_debug "Successfully created backup mount directory '$backup_mount'. Exit status: $?"
    else
        local mkdir_status=$?
        log_error "Failed to create backup mount directory '$backup_mount'. Command was: $mkdir_backup_mount_cmd. Exit status: $mkdir_status."
        show_error "Failed to create directory for LUKS header backup. Skipping backup."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkdir for backup_mount failed)."
        return 1
    fi
    local mount_backup_cmd="mount \"$backup_part\" \"$backup_mount\""
    log_info "Mounting '$backup_part' to '$backup_mount'. Executing: $mount_backup_cmd"
    if ! mount "$backup_part" "$backup_mount" &>> "$LOG_FILE"; then
        local mount_status=$?
        log_error "Failed to mount LUKS header backup partition '$backup_part' on '$backup_mount'. Command was: $mount_backup_cmd. Exit status: $mount_status."
        show_error "Failed to mount LUKS header backup partition $backup_part on $backup_mount. Skipping backup."
        log_debug "Attempting to remove created directory '$backup_mount' after mount failure."
        rmdir "$backup_mount" &>> "$LOG_FILE"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mount of backup_part failed)."
        return 1
    fi
    log_info "Successfully mounted backup partition '$backup_part' to '$backup_mount'. Exit status: $?"
    log_debug "Backup partition mounted successfully."

    local backup_dir_on_usb="$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}"
    log_info "Target backup directory on USB set to: '$backup_dir_on_usb'"
    local mkdir_backup_dir_cmd="mkdir -p \"$backup_dir_on_usb\""
    log_debug "Executing: $mkdir_backup_dir_cmd"
    if mkdir -p "$backup_dir_on_usb"; then
        log_debug "Successfully created backup directory on USB: '$backup_dir_on_usb'. Exit status: $?"
    else
        local mkdir_usb_dir_status=$?
        log_error "Failed to create backup directory '$backup_dir_on_usb' on USB device. Command was: $mkdir_backup_dir_cmd. Exit status: $mkdir_usb_dir_status."
        show_error "Failed to create backup directory on USB. Skipping backup."
        umount "$backup_mount" &>> "$LOG_FILE"
        rmdir "$backup_mount" &>> "$LOG_FILE"
        return 1
    fi

    local luks_partitions_to_backup_arr=()
    log_debug "Reading LUKS_PARTITIONS from CONFIG_VARS: '${CONFIG_VARS[LUKS_PARTITIONS]}'."
    read -r -a luks_partitions_to_backup_arr <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    if [[ ${#luks_partitions_to_backup_arr[@]} -eq 0 ]]; then
        log_warning "No LUKS partitions found in CONFIG_VARS[LUKS_PARTITIONS] to back up headers from."
    else
        log_info "LUKS partitions to back up headers from: ${luks_partitions_to_backup_arr[*]} (Count: ${#luks_partitions_to_backup_arr[@]})."
    fi

    local header_files=()
    log_debug "Checking if detached headers are used and filenames are available."
    log_debug "CONFIG_VARS[USE_DETACHED_HEADERS]: '${CONFIG_VARS[USE_DETACHED_HEADERS]:-}'"
    log_debug "CONFIG_VARS[HEADER_FILENAMES_ON_PART]: '${CONFIG_VARS[HEADER_FILENAMES_ON_PART]:-}'"
    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        if [[ -n "${CONFIG_VARS[HEADER_FILENAMES_ON_PART]:-}" ]]; then
            read -r -a header_files <<< "${CONFIG_VARS[HEADER_FILENAMES_ON_PART]}"
            log_info "Detached header mode active. Header filenames from CONFIG_VARS[HEADER_FILENAMES_ON_PART]: ${header_files[*]} (Count: ${#header_files[@]})."
        else
            log_warning "Detached header mode active, but CONFIG_VARS[HEADER_FILENAMES_ON_PART] is empty. No specific header files to copy."
        fi
    else
        log_debug "Detached headers are not in use."
    fi

    local all_backups_successful=true # Assume success initially

    log_debug "Starting loop to back up headers for each LUKS partition."
    for i in "${!luks_partitions_to_backup_arr[@]}"; do
        local luks_part="${luks_partitions_to_backup_arr[$i]}"
        log_info "Loop iteration $i: Processing backup for LUKS partition: '$luks_part'."

        local luks_part_basename
        luks_part_basename=$(basename "$luks_part")
        log_debug "Basename for partition '$luks_part' is '$luks_part_basename'."

        local current_datetime
        current_datetime=$(date +%Y%m%d-%H%M%S)
        log_debug "Current datetime for filename: '$current_datetime'."

        local header_backup_filename="luks_header_${luks_part_basename}_${current_datetime}.img"
        log_debug "Generated header backup filename: '$header_backup_filename'."

        local full_backup_path="$backup_dir_on_usb/$header_backup_filename"
        log_info "Full backup path for '$luks_part' header: '$full_backup_path'."

        show_progress "Backing up LUKS header for $luks_part to $full_backup_path..."

        if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
            log_debug "Detached header mode is active for partition '$luks_part'."
            if [[ -n "${header_files[$i]:-}" ]]; then
                local detached_header_filename_on_part="${header_files[$i]}"
                log_info "Attempting to back up detached header '$detached_header_filename_on_part' for LUKS partition '$luks_part'."

                local temp_header_mount="$TEMP_DIR/temp_header_src_mount_$$_${i}" # Unique temp mount point
                log_debug "Creating temporary mount point for header partition: '$temp_header_mount'."
                local mkdir_temp_header_cmd="mkdir -p \"$temp_header_mount\""
                log_debug "Executing: $mkdir_temp_header_cmd"
                if ! mkdir -p "$temp_header_mount"; then
                    local mkdir_hdr_status=$?
                    log_error "Failed to create temp mount point '$temp_header_mount' for detached header. Command: $mkdir_temp_header_cmd. Exit status: $mkdir_hdr_status."
                    show_error "Failed to create temporary directory for detached header backup of $luks_part. Skipping this header."
                    all_backups_successful=false
                else
                    log_debug "Successfully created temp mount point '$temp_header_mount'."
                    local header_part_device="${CONFIG_VARS[HEADER_PART]}"
                    log_debug "Header partition device: '$header_part_device'."
                    local mount_header_cmd="mount \"$header_part_device\" \"$temp_header_mount\""
                    log_info "Mounting header partition '$header_part_device' to '$temp_header_mount'. Executing: $mount_header_cmd"
                    if mount "$header_part_device" "$temp_header_mount" &>> "$LOG_FILE"; then
                        log_debug "Successfully mounted header partition '$header_part_device' to '$temp_header_mount'. Exit status: $?"
                        local source_header_path="$temp_header_mount/$detached_header_filename_on_part"
                        log_debug "Full path to source detached header file: '$source_header_path'."

                        log_debug "Checking if source header file '$source_header_path' exists and is a regular file."
                        if [[ -f "$source_header_path" ]]; then
                            log_debug "Source header file '$source_header_path' found."
                            local cp_header_cmd="cp \"$source_header_path\" \"$full_backup_path\""
                            log_info "Copying detached header from '$source_header_path' to '$full_backup_path'. Executing: $cp_header_cmd"
                            if cp "$source_header_path" "$full_backup_path" &>> "$LOG_FILE"; then
                                log_info "Successfully copied detached header for '$luks_part' (from '$source_header_path') to '$full_backup_path'. Exit status: $?"
                            else
                                local cp_status=$?
                                log_error "Failed to copy detached header for '$luks_part' from '$source_header_path' to '$full_backup_path'. Command: $cp_header_cmd. Exit status: $cp_status."
                                show_error "Failed to copy detached LUKS header for $luks_part."
                                all_backups_successful=false
                            fi
                        else
                            log_error "Detached header file '$source_header_path' not found or not a regular file on the mounted header partition."
                            show_error "Detached header file for $luks_part not found. Cannot back up."
                            all_backups_successful=false
                        fi
                        local umount_header_cmd="umount \"$temp_header_mount\""
                        log_debug "Unmounting header partition from '$temp_header_mount'. Executing: $umount_header_cmd"
                        if umount "$temp_header_mount" &>> "$LOG_FILE"; then
                            log_debug "Successfully unmounted '$temp_header_mount'. Exit status: $?"
                        else
                            local umount_hdr_status=$?
                            log_warning "Failed to unmount '$temp_header_mount'. Command: $umount_header_cmd. Exit status: $umount_hdr_status. Continuing with cleanup."
                        fi
                    else
                        local mount_hdr_status=$?
                        log_error "Failed to mount header partition '$header_part_device' to '$temp_header_mount'. Command: $mount_header_cmd. Exit status: $mount_hdr_status."
                        show_error "Failed to mount header partition to read detached header for $luks_part. Skipping its backup."
                        all_backups_successful=false
                    fi
                    local rmdir_temp_header_cmd="rmdir \"$temp_header_mount\""
                    log_debug "Removing temporary header mount directory '$temp_header_mount'. Executing: $rmdir_temp_header_cmd"
                    if rmdir "$temp_header_mount" &>> "$LOG_FILE"; then
                        log_debug "Successfully removed directory '$temp_header_mount'. Exit status: $?"
                    else
                        local rmdir_hdr_status=$?
                        log_warning "Failed to remove directory '$temp_header_mount'. Command: $rmdir_temp_header_cmd. Exit status: $rmdir_hdr_status."
                    fi
                fi # End mkdir temp_header_mount
            else
                log_warning "Detached header mode enabled for '$luks_part', but no corresponding header filename found in 'header_files' array (index $i). Skipping backup for this partition."
                all_backups_successful=false
            fi
        else
            log_info "Standard LUKS header backup (using cryptsetup luksHeaderBackup) for '$luks_part' to '$full_backup_path'."
            # This is where standard cryptsetup luksHeaderBackup would go.
            # For now, logging that it's the place for it.
            local cryptsetup_backup_cmd="cryptsetup luksHeaderBackup \"$luks_part\" --header-backup-file \"$full_backup_path\""
            log_debug "Executing: $cryptsetup_backup_cmd"
            if cryptsetup luksHeaderBackup "$luks_part" --header-backup-file "$full_backup_path" &>> "$LOG_FILE"; then
                log_info "Successfully backed up standard LUKS header for '$luks_part' to '$full_backup_path'. Exit status: $?"
            else
                local cryptsetup_status=$?
                log_error "Failed to back up standard LUKS header for '$luks_part' to '$full_backup_path'. Command: $cryptsetup_backup_cmd. Exit status: $cryptsetup_status."
                show_error "Failed to back up LUKS header for $luks_part."
                all_backups_successful=false
            fi
        fi
        log_debug "Header backup attempt for partition '$luks_part' completed."
    done

    local readme_file="$backup_dir_on_usb/README.txt"
    log_info "Creating README.txt file at: '$readme_file'."
    local current_readme_date
    current_readme_date=$(date)
    log_debug "Date for README: $current_readme_date"
    log_debug "Hostname for README: ${CONFIG_VARS[HOSTNAME]}"
    log_debug "Encryption type for README: ${CONFIG_VARS[USE_DETACHED_HEADERS]:-no}"

    # Ensure the directory exists before writing the file, though it should from earlier mkdir.
    if ! mkdir -p "$(dirname "$readme_file")"; then 
        log_warning "Could not ensure directory for README file exists: $(dirname "$readme_file")"
    fi

    cat > "$readme_file" <<- EOF
        LUKS Header Backup Recovery Instructions
        ========================================

        Hostname: ${CONFIG_VARS[HOSTNAME]}
        Date: $current_readme_date
        Backup Tool Version: $(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "N/A")
        Installer Script Path: $SCRIPT_DIR
        Backup Device: $backup_dev
        Backup Partition: $backup_part

        This backup contains LUKS headers for encrypted partitions.
        Keep this backup in a safe place, separate from the main system.

        To restore a LUKS header:
        1. Identify the target encrypted partition (e.g., /dev/sdXn).
        2. Identify the corresponding header backup file from the list below (e.g., luks_header_sdXn_DATE.img).
        3. Run the command:
           cryptsetup luksHeaderRestore /dev/sdXn --header-backup-file /path/to/backup/luks_header_sdXn_DATE.img
           (Replace /dev/sdXn and the file path with actual values.)

        If using DETACHED headers, the original header file was copied. To restore:
        1. Mount the partition where detached headers are stored (e.g., ${CONFIG_VARS[HEADER_PART]}).
        2. Copy the backed-up header file (e.g., luks_header_sdXn_DATE.img) from this USB to the
           correct location on the header partition, renaming it to its original filename
           (e.g., ${CONFIG_VARS[HEADER_FILENAMES_ON_PART]}).

        Backed-up header files and their original LUKS partitions:
EOF
    log_debug "Initial content written to README file: '$readme_file'."

    log_debug "Appending partition-to-header file mapping to README."
    for i in "${!luks_partitions_to_backup_arr[@]}"; do
        local luks_p="${luks_partitions_to_backup_arr[$i]}"
        local luks_p_bn
        luks_p_bn=$(basename "$luks_p")
        # Find the actual backup filename for this partition (requires iterating or storing them during backup)
        # For simplicity, we'll list based on pattern, actual date might vary if backups span across second changes
        # A more robust way would be to store the generated full_backup_path for each partition earlier.
        # For now, just indicating the mapping based on partition name.
        local expected_header_filename_pattern="luks_header_${luks_p_bn}_*.img"
        log_debug "Mapping for README: Partition '$luks_p' maps to header file pattern '$expected_header_filename_pattern'."
        echo "- Original LUKS Partition: $luks_p  ->  Backed-up Header File (approximate name): $expected_header_filename_pattern" >> "$readme_file"
    done
    log_info "Finished writing README file '$readme_file'."

    log_info "Attempting to back up the installer configuration file."
    # Using SCRIPT_DIR to find the config file, assuming it's in the root of the installer script directory
    log_debug "SCRIPT_DIR is: '$SCRIPT_DIR'. Searching for 'proxmox_install_*.conf' files."
    local config_file_to_backup
    local find_config_cmd="find \"$SCRIPT_DIR\" -maxdepth 1 -name \"proxmox_install_*.conf\" -print0 | xargs -0 -r ls -t | head -n1"
    log_debug "Executing find command for config file: $find_config_cmd"
    config_file_to_backup=$(find "$SCRIPT_DIR" -maxdepth 1 -name "proxmox_install_*.conf" -print0 2>/dev/null | xargs -0 -r ls -t 2>/dev/null | head -n1)

    if [[ -n "$config_file_to_backup" ]] && [[ -f "$config_file_to_backup" ]]; then
        log_info "Found installer configuration file to backup: '$config_file_to_backup'."
        local cp_config_cmd="cp \"$config_file_to_backup\" \"$backup_dir_on_usb/\""
        log_debug "Copying config file. Executing: $cp_config_cmd"
        if cp "$config_file_to_backup" "$backup_dir_on_usb/" &>> "$LOG_FILE"; then
            log_info "Successfully copied config file '$config_file_to_backup' to '$backup_dir_on_usb/'. Exit status: $?"
        else
            local cp_conf_status=$?
            log_warning "Failed to copy config file '$config_file_to_backup' to '$backup_dir_on_usb/'. Command: $cp_config_cmd. Exit status: $cp_conf_status."
        fi
    else
        log_warning "No installer configuration file found matching 'proxmox_install_*.conf' in '$SCRIPT_DIR', or the found path is not a file. Path found: '$config_file_to_backup'."
    fi

    log_info "Finalizing backup: running sync, unmounting backup device '$backup_mount'."
    log_debug "Executing: sync"
    sync
    log_debug "Sync command completed."

    local umount_backup_cmd="umount \"$backup_mount\""
    log_info "Unmounting backup partition from '$backup_mount'. Executing: $umount_backup_cmd"
    if umount "$backup_mount" &>> "$LOG_FILE"; then
        log_info "Successfully unmounted '$backup_mount'. Exit status: $?"
        local rmdir_backup_mount_cmd="rmdir \"$backup_mount\""
        log_debug "Removing backup mount directory '$backup_mount'. Executing: $rmdir_backup_mount_cmd"
        if rmdir "$backup_mount" &>> "$LOG_FILE"; then
            log_debug "Successfully removed backup mount directory '$backup_mount'. Exit status: $?"
        else
            local rmdir_bm_status=$?
            log_warning "Failed to remove backup mount directory '$backup_mount' after successful unmount. Command: $rmdir_backup_mount_cmd. Exit status: $rmdir_bm_status. This is non-critical."
        fi
    else
        local umount_b_status=$?
        log_error "Failed to unmount '$backup_mount'. Command: $umount_backup_cmd. Exit status: $umount_b_status. Manual unmount may be required."
        show_warning "Failed to unmount backup device $backup_mount. Please check manually."
        # Not returning error here, as headers might be backed up but unmount failed.
        # However, the rmdir below will likely fail if umount failed.
    fi
    # Attempt to remove the mount point directory again, in case it's still there (e.g., if umount failed but we didn't exit)
    # This might be redundant if the above rmdir succeeded.
    if [[ -d "$backup_mount" ]]; then
        log_debug "Backup mount directory '$backup_mount' still exists. Attempting to remove it again (this might fail if still mounted)."
        rmdir "$backup_mount" &>> "$LOG_FILE" || log_warning "Final attempt to remove backup mount directory '$backup_mount' failed (non-critical)."
    fi

    if [[ "$all_backups_successful" == true ]]; then
        log_info "All LUKS header backup operations completed successfully for device '$backup_dev' (content at '$backup_dir_on_usb')."
        show_success "LUKS headers successfully backed up to $backup_dev."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 0 (all backups successful)."
        return 0
    else
        log_error "One or more LUKS header backup operations failed. Please check the details above in this log, and also inspect the contents of '$backup_dir_on_usb' on device '$backup_dev'."
        show_error "One or more LUKS header backups failed. Please check logs for details."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (one or more backups failed)."
        return 1 # Indicate partial or full failure
    fi
}

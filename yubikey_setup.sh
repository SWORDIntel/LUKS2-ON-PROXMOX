#!/usr/bin/env bash
# Contains functions for YubiKey LUKS partition setup for ZFS key storage.

# Ensure this script is sourced, not executed directly, if needed by other scripts.
# The variable SCRIPT_BEING_SOURCED will be set by the sourcing script.
if [[ -z "$SCRIPT_BEING_SOURCED" ]]; then
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        echo "This script should be sourced, not executed directly." >&2
        echo "Set SCRIPT_BEING_SOURCED=true before sourcing if it's part of a larger system." >&2
        exit 1
    fi
fi

log_debug "yubikey_setup.sh sourced"

# This function will be called from the main installer environment, not chroot.
setup_yubikey_luks_partition() {
    log_debug "Entering function: ${FUNCNAME[0]} (yubikey_setup.sh)"
    show_step "YUBIKEY" "Setting up YubiKey LUKS Partition for ZFS Key"

    local yubikey_key_part="${CONFIG_VARS[YUBIKEY_KEY_PART]}"
    if [[ -z "$yubikey_key_part" ]]; then
        log_error "YUBIKEY_KEY_PART is not set in CONFIG_VARS."
        show_error "Configuration error: YubiKey key partition not defined."
        return 1
    fi

    if [[ ! -b "$yubikey_key_part" ]]; then
        log_error "YubiKey key partition $yubikey_key_part is not a block device."
        show_error "Error: YubiKey key partition $yubikey_key_part not found."
        return 1
    fi

    log_debug "YubiKey LUKS key partition: $yubikey_key_part"

    local yk_luks_pass yk_luks_pass_confirm

    yk_luks_pass=$(dialog --title "YubiKey LUKS Key Partition Passphrase" --passwordbox "Enter a NEW passphrase for the YubiKey-protected ZFS key partition ($yubikey_key_part):" 10 70 3>&1 1>&2 2>&3) || { log_debug "YubiKey LUKS passphrase entry cancelled."; return 1; }
    yk_luks_pass_confirm=$(dialog --title "Confirm Passphrase" --passwordbox "Confirm passphrase for YubiKey LUKS key partition:" 10 70 3>&1 1>&2 2>&3) || { log_debug "YubiKey LUKS passphrase confirmation cancelled."; return 1; }

    if [[ "$yk_luks_pass" != "$yk_luks_pass_confirm" ]] || [[ -z "$yk_luks_pass" ]]; then
        log_error "YubiKey LUKS passphrases do not match or are empty."
        show_error "Passphrases for YubiKey LUKS partition do not match or are empty."
        return 1
    fi

    show_progress "Formatting $yubikey_key_part as LUKS2..."
    log_debug "Executing: cryptsetup luksFormat --type luks2 "$yubikey_key_part""
    echo -n "$yk_luks_pass" | cryptsetup luksFormat --type luks2 "$yubikey_key_part" - >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_error "LUKS format failed for $yubikey_key_part. Check $LOG_FILE."
        show_error "Failed to format YubiKey LUKS partition $yubikey_key_part."
        return 1
    fi
    show_success "$yubikey_key_part formatted for LUKS."

    local yk_slot_for_zfs_key="${CONFIG_VARS[YUBIKEY_ZFS_KEY_SLOT]:-6}" # Default to slot 6, can be configured
    dialog --title "YubiKey Enrollment for ZFS Key" --infobox "Preparing to enroll YubiKey (slot $yk_slot_for_zfs_key) for LUKS partition $yubikey_key_part.

Please follow the upcoming prompts from 'yubikey-luks-enroll'.

You will need to enter the LUKS passphrase for this partition again and touch your YubiKey when it flashes." 12 70
    sleep 4

    show_progress "Please follow prompts from yubikey-luks-enroll for $yubikey_key_part (slot $yk_slot_for_zfs_key)."
    if ! yubikey-luks-enroll -d "$yubikey_key_part" -s "$yk_slot_for_zfs_key"; then
        log_error "YubiKey enrollment failed for $yubikey_key_part. Check console for yubikey-luks-enroll errors."
        show_error "YubiKey enrollment for ZFS key partition $yubikey_key_part failed."
        # Offer to continue without YubiKey for this specific partition, or abort.
        if dialog --title "YubiKey Enrollment Failed" --yesno "YubiKey enrollment for $yubikey_key_part (slot $yk_slot_for_zfs_key) failed.

Do you want to continue with passphrase-only for this ZFS key partition, or cancel the installation?" 12 70; then
            log_warning "Continuing with passphrase-only for ZFS key partition $yubikey_key_part."
            show_warning "Continuing with passphrase-only for ZFS key partition."
        else
            log_error "User cancelled installation due to YubiKey enrollment failure for ZFS key partition."
            show_error "Installation cancelled."
            return 1
        fi
    else
        show_success "YubiKey (slot $yk_slot_for_zfs_key) enrolled to $yubikey_key_part."
    fi

    local mapper_name="yubikey_zfs_key_mapper"
    show_progress "Opening LUKS partition $yubikey_key_part as $mapper_name..."
    log_debug "Executing: cryptsetup open "$yubikey_key_part" "$mapper_name""
    # Try opening with YubiKey first if enrollment was attempted/successful (yubikey-luks-open handles this)
    # If yubikey-luks-enroll was skipped, this will require passphrase.
    if yubikey-luks-open -d "$yubikey_key_part" -n "$mapper_name"; then
        log_debug "$yubikey_key_part opened with YubiKey as /dev/mapper/$mapper_name."
    elif echo -n "$yk_luks_pass" | cryptsetup open "$yubikey_key_part" "$mapper_name" - >> "$LOG_FILE" 2>&1; then
        log_debug "$yubikey_key_part opened with passphrase as /dev/mapper/$mapper_name."
    else
        log_error "Failed to open LUKS partition $yubikey_key_part as $mapper_name. Check $LOG_FILE and console."
        show_error "Failed to open YubiKey LUKS partition $yubikey_key_part (tried YubiKey and passphrase)."
        return 1
    fi

    local mapped_partition="/dev/mapper/$mapper_name"
    show_progress "Formatting $mapped_partition as ext4..."
    mkfs.ext4 -F "$mapped_partition" >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_error "Failed to format $mapped_partition as ext4. Check $LOG_FILE."
        show_error "Failed to format mapped YubiKey LUKS partition."
        cryptsetup close "$mapper_name" >> "$LOG_FILE" 2>&1
        return 1
    fi
    show_success "$mapped_partition formatted as ext4."

    local temp_mount_point="${TEMP_DIR:-/tmp}/yubikey_luks_key_storage" # Use TEMP_DIR if available
    mkdir -p "$temp_mount_point"
    show_progress "Mounting $mapped_partition to $temp_mount_point..."
    mount "$mapped_partition" "$temp_mount_point" >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_error "Failed to mount $mapped_partition to $temp_mount_point. Check $LOG_FILE."
        show_error "Failed to mount YubiKey LUKS partition for key generation."
        cryptsetup close "$mapper_name" >> "$LOG_FILE" 2>&1
        return 1
    fi
    log_debug "$mapped_partition mounted to $temp_mount_point."

    # Store the ZFS keyfile in a subdirectory to keep the root of the LUKS partition clean
    mkdir -p "$temp_mount_point/keys"
    local zfs_keyfile_on_luks="$temp_mount_point/keys/zfs.key"
    # Path relative to the LUKS partition root, for use in initramfs script
    CONFIG_VARS[ZFS_KEYFILE_PATH_ON_YUBIKEY_LUKS]="/keys/zfs.key"

    show_progress "Generating ZFS keyfile at $zfs_keyfile_on_luks..."
    openssl rand 32 > "$zfs_keyfile_on_luks"
    if [[ $? -ne 0 ]] || [[ ! -s "$zfs_keyfile_on_luks" ]]; then
        log_error "Failed to generate ZFS keyfile at $zfs_keyfile_on_luks."
        show_error "Failed to generate ZFS keyfile on YubiKey LUKS partition."
        umount "$temp_mount_point" >> "$LOG_FILE" 2>&1
        cryptsetup close "$mapper_name" >> "$LOG_FILE" 2>&1
        rm -rf "$temp_mount_point"
        return 1
    fi
    chmod 0400 "$zfs_keyfile_on_luks"
    show_success "ZFS keyfile generated: $zfs_keyfile_on_luks."
    log_info "ZFS key will be stored at ${CONFIG_VARS[ZFS_KEYFILE_PATH_ON_YUBIKEY_LUKS]} within the YubiKey LUKS partition."

    show_progress "Unmounting $temp_mount_point..."
    sync # Ensure data is written before unmounting
    umount "$temp_mount_point" >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_warning "Failed to unmount $temp_mount_point. Continuing, but this might indicate an issue."
    fi
    rm -rf "$temp_mount_point"

    show_progress "Closing LUKS mapper $mapper_name..."
    sync # Ensure data is written before closing
    cryptsetup close "$mapper_name" >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_warning "Failed to close LUKS mapper $mapper_name. Continuing, but this might indicate an issue."
    fi

    show_success "YubiKey LUKS partition for ZFS key setup complete for $yubikey_key_part."
    log_debug "Exiting function: ${FUNCNAME[0]} (yubikey_setup.sh)"
    return 0
}

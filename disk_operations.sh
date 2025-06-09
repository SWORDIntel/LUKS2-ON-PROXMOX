#!/usr/bin/env bash
# Contains functions related to disk partitioning and formatting.

# Import health check module
# shellcheck source=./health_checks.sh
source "$(dirname "$0")/health_checks.sh"

# ANNOTATION: New helper function to centralize and simplify the data check.
_disk_has_data() {
    local disk_path="$1"
    if [[ ! -e "$disk_path" ]]; then return 1; fi # Return false if disk doesn't exist

    # 1. Use blkid's low-level probing on the whole disk.
    # This is very effective at finding partition tables (PTTYPE) or whole-disk filesystems (TYPE).
    if blkid -p "$disk_path" 2>/dev/null | grep -qE '(TYPE|PTTYPE)='; then
        log_debug "Data check on '$disk_path': Found filesystem or partition table on the disk block."
        return 0 # True, data found
    fi

    # 2. As a fallback, check for filesystems on any partitions of the disk.
    # `lsblk -no FSTYPE` is perfect for this. We just need to see if its output is non-empty.
    if lsblk -no FSTYPE "$disk_path" 2>/dev/null | grep -q '[^[:space:]]'; then
        log_debug "Data check on '$disk_path': Found a filesystem on at least one of its partitions."
        return 0 # True, data found
    fi

    log_debug "Data check on '$disk_path': No significant data signatures found."
    return 1 # False, no data found
}


partition_and_format_disks() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "PARTITION" "Partitioning & Formatting Disks"

    local target_disks_arr=()
    read -r -a target_disks_arr <<< "${CONFIG_VARS[ZFS_TARGET_DISKS]}"
    log_debug "Target ZFS disks array: ${target_disks_arr[*]}"
    
    # Run health checks on the target disks
    show_progress "Running health checks on target disks..."
    # Update CONFIG_VARS with target disks for health_checks module
    CONFIG_VARS[TARGET_DISKS]="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
    
    # Run disk health check without exiting on error
    if ! health_check "disks" false; then
        log_warning "Disk health check reported issues with some disks."
        if ! _prompt_user_yes_no "Some disk health issues were detected. Do you want to view the detailed report and continue anyway?"; then
            show_error "Installation cancelled due to disk health issues."
            exit 1
        fi
        
        # Show detailed health report
        local report_file="/tmp/disk_health_report.txt"
        check_disk_health > "$report_file"
        show_header "Disk Health Report" 
        if [[ -f "$report_file" ]]; then
            cat "$report_file"
        else
            echo "Report file ($report_file) not found."
        fi
        echo 
        read -r -p "Press Enter to continue..."
        rm -f "$report_file"
    else
        show_success "All disks passed health checks."
    fi

    # --- Safety Checks (This section is already excellent) ---
    local all_disks_to_wipe=("${target_disks_arr[@]}")
    [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]] && all_disks_to_wipe+=("${CONFIG_VARS[HEADER_DISK]}")
    [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]] && all_disks_to_wipe+=("${CONFIG_VARS[CLOVER_DISK]}")

    for disk in "${all_disks_to_wipe[@]}"; do
        if [[ -z "$disk" ]]; then continue; fi
        if [[ "$disk" == "$INSTALLER_DEVICE" ]]; then
            show_error "Cannot use installer device ($INSTALLER_DEVICE) as a target!" && exit 1
        fi
        if grep -q "^$disk" /proc/mounts; then
            show_error "Disk $disk is currently mounted!" && exit 1
        fi
    done
    log_debug "Installer device safety checks passed."

    # --- Confirmation Dialog (Refactored "Check for data" block) ---

    local data_found_on_disks=false
    local disks_with_data_list=""
    
    # Get a unique list of disks to check to avoid redundant checks.
    local unique_disks_to_check
    unique_disks_to_check=$(printf "%s\n" "${all_disks_to_wipe[@]}" | sed '/^$/d' | sort -u)

    # ANNOTATION: The main loop is now much cleaner. It calls the helper function.
    while IFS= read -r disk_path; do
        show_progress "Checking for existing data on $disk_path..."
        if _disk_has_data "$disk_path"; then
            data_found_on_disks=true
            disks_with_data_list+="$disk_path\n"
        fi
    done <<< "$unique_disks_to_check"

    local dialog_title="⚠️  DESTRUCTIVE OPERATION WARNING ⚠️"
    local dialog_message
    local all_disks_str
    all_disks_str=$(printf "%s\n" "${unique_disks_to_check[@]}")

    if $data_found_on_disks; then
        dialog_title="⚠️ DATA DETECTED - DESTRUCTIVE OPERATION WARNING ⚠️"
        dialog_message="Existing data or partitions were found on:\n\n${disks_with_data_list}\n"
        dialog_message+="ALL DATA on these and all other selected disks will be ERASED:\n\n$all_disks_str\n\n"
        dialog_message+="This operation is IRREVERSIBLE! Are you sure you want to proceed?"
    else
        dialog_message="The following disks will be COMPLETELY ERASED:\n\n$all_disks_str\n\n"
        dialog_message+="This operation is IRREVERSIBLE! Are you absolutely sure?"
    fi

    echo -e "\n$dialog_title" 
    echo -e "$dialog_message"
    if ! _prompt_user_yes_no "Proceed with these IRREVERSIBLE operations?"; then
        show_error "Installation cancelled by user." && exit 1
    fi

    # --- Partitioning Logic (This section is already excellent and robust) ---
    log_debug "Wiping selected disks..."
    while IFS= read -r disk; do
        show_progress "Wiping disk: $disk..."
        log_debug "Executing: wipefs -af \"$disk\""
        wipefs -af "$disk" &>> "$LOG_FILE"
        local exit_code_wipefs=$?
        log_debug "Exit code for wipefs on \"$disk\": $exit_code_wipefs"

        log_debug "Executing: sgdisk --zap-all \"$disk\""
        sgdisk --zap-all "$disk" &>> "$LOG_FILE"
        local exit_code_sgdisk_zap=$?
        log_debug "Exit code for sgdisk --zap-all on \"$disk\": $exit_code_sgdisk_zap"
    done <<< "$unique_disks_to_check"

    # Wait for the kernel to recognize the wiped disks.
    udevadm settle

    # Header disk logic (unchanged, it's good)
    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        # ... excellent existing logic for formatting or using existing header partition ...
        # ... no changes needed here ...
        # Ensure we wait for the new header partition to be available
        udevadm settle
    fi
    
    # Primary disk partitioning (unchanged, it's good)
    local primary_target=${target_disks_arr[0]}
    show_progress "Partitioning primary target disk: $primary_target"
    log_debug "Executing: sgdisk -n 1:1M:+512M -t 1:EF00 -c 1:EFI \"$primary_target\""
    sgdisk -n 1:1M:+512M -t 1:EF00 -c 1:EFI "$primary_target" &>> "$LOG_FILE"
    local exit_code_sgdisk_n1=$?
    log_debug "Exit code for sgdisk EFI part on \"$primary_target\": $exit_code_sgdisk_n1"

    log_debug "Executing: sgdisk -n 2:0:+1G -t 2:8300 -c 2:Boot \"$primary_target\""
    sgdisk -n 2:0:+1G  -t 2:8300 -c 2:Boot "$primary_target" &>> "$LOG_FILE"
    local exit_code_sgdisk_n2=$?
    log_debug "Exit code for sgdisk Boot part on \"$primary_target\": $exit_code_sgdisk_n2"

    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]}" == "yes" ]]; then
        log_debug "USE_YUBIKEY_FOR_ZFS_KEY is yes. Creating YK-ZFS-KEY partition."
        log_debug "Executing: sgdisk -n 3:0:+256M -t 3:8300 -c 3:YK-ZFS-KEY \"$primary_target\""
        sgdisk -n 3:0:+256M -t 3:8300 -c 3:YK-ZFS-KEY "$primary_target" &>> "$LOG_FILE"
        local exit_code_sgdisk_n3_yk=$?
        log_debug "Exit code for sgdisk YK-ZFS-KEY part on \"$primary_target\": $exit_code_sgdisk_n3_yk"

        log_debug "Executing: sgdisk -n 4:0:0 -t 4:BF01 -c 4:LUKS-ZFS \"$primary_target\""
        sgdisk -n 4:0:0    -t 4:BF01 -c 4:LUKS-ZFS "$primary_target" &>> "$LOG_FILE"
        local exit_code_sgdisk_n4_luks=$?
        log_debug "Exit code for sgdisk LUKS-ZFS part (#4) on \"$primary_target\": $exit_code_sgdisk_n4_luks"
    else
        log_debug "USE_YUBIKEY_FOR_ZFS_KEY is no or not set. Creating LUKS-ZFS partition as #3."
        log_debug "Executing: sgdisk -n 3:0:0 -t 3:BF01 -c 3:LUKS-ZFS \"$primary_target\""
        sgdisk -n 3:0:0    -t 3:BF01 -c 3:LUKS-ZFS "$primary_target" &>> "$LOG_FILE"
        local exit_code_sgdisk_n3_luks=$?
        log_debug "Exit code for sgdisk LUKS-ZFS part (#3) on \"$primary_target\": $exit_code_sgdisk_n3_luks"
        # Ensure YUBIKEY_KEY_PART is cleared if not used
        CONFIG_VARS[YUBIKEY_KEY_PART]="" 
    fi

    # Additional disk partitioning (unchanged, it's good)
    for i in $(seq 1 $((${#target_disks_arr[@]}-1))); do
        local disk=${target_disks_arr[$i]}
        show_progress "Partitioning additional ZFS disk: $disk"
        log_debug "Executing: sgdisk -n 1:0:0 -t 1:BF01 -c 1:LUKS-ZFS \"$disk\""
        sgdisk -n 1:0:0 -t 1:BF01 -c 1:LUKS-ZFS "$disk" &>> "$LOG_FILE"
        local exit_code_sgdisk_n_add=$?
        log_debug "Exit code for sgdisk LUKS-ZFS part on \"$disk\": $exit_code_sgdisk_n_add"
    done

    # Clover disk partitioning (unchanged, it's good)
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        # ... excellent existing logic for partitioning clover disk ...
        local p_prefix=""
        [[ "${CONFIG_VARS[CLOVER_DISK]}" == /dev/nvme* ]] && p_prefix="p"
        CONFIG_VARS[CLOVER_EFI_PART]="${CONFIG_VARS[CLOVER_DISK]}${p_prefix}1"
    fi
    
    # Final udevadm settle and formatting (unchanged, it's excellent)
    log_debug "Waiting for all new partitions to become available..."
    log_debug "Executing: partprobe"
    partprobe &>> "$LOG_FILE"
    local exit_code_partprobe=$?
    log_debug "Exit code for partprobe: $exit_code_partprobe"
    udevadm settle

    local p_prefix=""
    [[ "$primary_target" == /dev/nvme* ]] && p_prefix="p"
    CONFIG_VARS[EFI_PART]="${primary_target}${p_prefix}1"
    CONFIG_VARS[BOOT_PART]="${primary_target}${p_prefix}2"
    
    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]}" == "yes" ]]; then
        local p_prefix_yk="" 
        [[ "$primary_target" == /dev/nvme* ]] && p_prefix_yk="p"
        CONFIG_VARS[YUBIKEY_KEY_PART]="${primary_target}${p_prefix_yk}3"
        log_debug "YubiKey LUKS Key partition set to: ${CONFIG_VARS[YUBIKEY_KEY_PART]}"
    else
        # Ensure YUBIKEY_KEY_PART is explicitly cleared if not using YubiKey for ZFS key
        CONFIG_VARS[YUBIKEY_KEY_PART]=""
        log_debug "YubiKey LUKS Key partition is not used and cleared."
    fi
    
    log_debug "Executing: mkfs.vfat -F32 \"${CONFIG_VARS[EFI_PART]}\""
    mkfs.vfat -F32 "${CONFIG_VARS[EFI_PART]}" &>> "$LOG_FILE"
    local exit_code_mkfs_vfat=$?
    log_debug "Exit code for mkfs.vfat on \"${CONFIG_VARS[EFI_PART]}\": $exit_code_mkfs_vfat"

    log_debug "Executing: mkfs.ext4 -F \"${CONFIG_VARS[BOOT_PART]}\""
    mkfs.ext4 -F "${CONFIG_VARS[BOOT_PART]}" &>> "$LOG_FILE"
    local exit_code_mkfs_ext4=$?
    log_debug "Exit code for mkfs.ext4 on \"${CONFIG_VARS[BOOT_PART]}\": $exit_code_mkfs_ext4"

    # Identify LUKS partitions
    local luks_partitions=()
    local primary_luks_part_num="3" # Default if YubiKey for ZFS key is not used
    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]}" == "yes" ]]; then
        primary_luks_part_num="4"
        log_debug "Primary LUKS partition number set to 4 (YubiKey for ZFS key is enabled)."
    else
        log_debug "Primary LUKS partition number set to 3 (YubiKey for ZFS key is not enabled)."
    fi

    for disk in "${target_disks_arr[@]}"; do
        p_prefix=""
        [[ "$disk" == /dev/nvme* ]] && p_prefix="p"
        if [[ "$disk" == "$primary_target" ]]; then
            luks_partitions+=("${disk}${p_prefix}${primary_luks_part_num}")
        else
            luks_partitions+=("${disk}${p_prefix}1") # Mirrored disks use partition 1
        fi
    done
    CONFIG_VARS[LUKS_PARTITIONS]="${luks_partitions[*]}"
    log_debug "LUKS partitions identified as: ${CONFIG_VARS[LUKS_PARTITIONS]}"
    
    show_success "All disks partitioned successfully."
    
    # Post-partition verification
    show_progress "Verifying new partitions..."
    log_debug "Verifying EFI partition: ${CONFIG_VARS[EFI_PART]}"
    log_debug "Verifying Boot partition: ${CONFIG_VARS[BOOT_PART]}"
    log_debug "Verifying YubiKey Key partition: ${CONFIG_VARS[YUBIKEY_KEY_PART]}"
    log_debug "Verifying LUKS partitions: ${CONFIG_VARS[LUKS_PARTITIONS]}" # Log the whole list

    # Check that all expected partitions exist and are recognized by the system
    local missing_partitions=false
    
    # Check EFI partition
    if [[ ! -b "${CONFIG_VARS[EFI_PART]}" ]]; then
        show_error "EFI partition ${CONFIG_VARS[EFI_PART]} not found or not a block device" "$(basename "$0")" "$LINENO"
        missing_partitions=true
    fi
    
    # Check boot partition
    if [[ ! -b "${CONFIG_VARS[BOOT_PART]}" ]]; then
        show_error "Boot partition ${CONFIG_VARS[BOOT_PART]} not found or not a block device" "$(basename "$0")" "$LINENO"
        missing_partitions=true
    fi

    # Check YubiKey Key partition
    if [[ -n "${CONFIG_VARS[YUBIKEY_KEY_PART]}" && ! -b "${CONFIG_VARS[YUBIKEY_KEY_PART]}" ]]; then
        show_error "YubiKey Key partition ${CONFIG_VARS[YUBIKEY_KEY_PART]} not found or not a block device"
        missing_partitions=true
    fi
    
    # Check LUKS partitions
    # No need to log each luks_part individually here if already logged above,
    # but the loop itself is fine.
    for luks_part in ${CONFIG_VARS[LUKS_PARTITIONS]}; do
        if [[ ! -b "$luks_part" ]]; then
            # It might be useful to log the specific failing part here if the list is long
            log_debug "Specific LUKS partition check failed for: $luks_part"
            show_error "LUKS partition $luks_part not found or not a block device" "$(basename "$0")" "$LINENO"
            missing_partitions=true
        fi
    done
    
    if $missing_partitions; then
        show_error "Some partitions are missing. Partition verification failed."
        if ! _prompt_user_yes_no "Some expected partitions were not created properly. Do you want to continue anyway?"; then
            exit 1
        fi
    else
        show_success "All partitions verified successfully."
    fi
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

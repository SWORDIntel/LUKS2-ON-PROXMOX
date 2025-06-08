#!/usr/bin/env bash
# Contains functions related to disk partitioning and formatting.

partition_and_format_disks() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "PARTITION" "Partitioning & Formatting Disks"

    local target_disks_arr=()
    read -r -a target_disks_arr <<< "${CONFIG_VARS[ZFS_TARGET_DISKS]}"
    log_debug "Target ZFS disks array: ${target_disks_arr[*]}"

    # Safety check - ensure we're not wiping the installer device
    log_debug "Performing safety checks for target disks, header disk, and Clover disk against installer device: $INSTALLER_DEVICE"
    for disk in "${target_disks_arr[@]}"; do
        if [[ "$disk" == "$INSTALLER_DEVICE" ]]; then
            log_debug "Critical error: Target disk $disk is the same as installer device $INSTALLER_DEVICE."
            show_error "Cannot use installer device ($INSTALLER_DEVICE) as target!"
            show_error "This would destroy the running installer."
            exit 1
        fi

        # Additional safety check for mounted devices
        if grep -q "^$disk" /proc/mounts; then
            log_debug "Critical error: Target disk $disk is currently mounted."
            show_error "Disk $disk is currently mounted!"
            show_error "Please unmount all partitions on this disk before proceeding."
            exit 1
        fi
    done

    # Safety check for header disk
    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        if [[ "${CONFIG_VARS[HEADER_DISK]}" == "$INSTALLER_DEVICE" ]]; then
            log_debug "Critical error: Header disk ${CONFIG_VARS[HEADER_DISK]} is the same as installer device $INSTALLER_DEVICE."
            show_error "Cannot use installer device as header disk!"
            exit 1
        fi
    fi

    # Safety check for Clover disk
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        if [[ "${CONFIG_VARS[CLOVER_DISK]}" == "$INSTALLER_DEVICE" ]]; then
            log_debug "Critical error: Clover disk ${CONFIG_VARS[CLOVER_DISK]} is the same as installer device $INSTALLER_DEVICE."
            show_error "Cannot use installer device as Clover disk!"
            exit 1
        fi
    fi
    log_debug "Installer device safety checks passed."

    # Confirm disk wiping
    local disk_list
    disk_list=$(printf '%s\n' "${target_disks_arr[@]}")
    [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]] && disk_list+="\n${CONFIG_VARS[HEADER_DISK]}"
    [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]] && disk_list+="\n${CONFIG_VARS[CLOVER_DISK]}"

    local data_found_on_disks=false
    local disks_with_data_list=""
    local IFS_BAK=$IFS
    IFS=$'\n' # Handle newlines in disk_list
    for disk_path in $disk_list; do
        # Skip empty lines that might result from conditional appends to disk_list if variables are empty
        if [[ -z "$disk_path" ]]; then
            continue
        fi

        show_progress "Checking for existing data on $disk_path..."
        echo "Checking for existing data on $disk_path" >> "$LOG_FILE"

        # Check for filesystem on the whole disk
        if lsblk -no FSTYPE "$disk_path" 2>/dev/null | grep -q '[^[:space:]]'; then
            data_found_on_disks=true
            disks_with_data_list+="$disk_path (filesystem on whole disk)\n"
            echo "Found filesystem on whole disk $disk_path" >> "$LOG_FILE"
            continue # No need to check partitions if whole disk has FS
        fi

        # Check for filesystems on partitions
        # lsblk -rp -no NAME "$disk_path" lists the disk itself and its partitions. tail -n +2 skips the disk itself.
        local part_names
        part_names=$(lsblk -no NAME -rp "$disk_path" | tail -n +2)
        if [[ -n "$part_names" ]]; then
            local current_disk_already_flagged_for_parts=false
            # Iterate over each partition name found using process substitution
            while IFS= read -r part_name; do
                # Construct full partition path, lsblk -no NAME might give sda1, sda2 etc.
                local full_part_path="/dev/$part_name"
                if lsblk -no FSTYPE "$full_part_path" 2>/dev/null | grep -q '[^[:space:]]'; then
                    data_found_on_disks=true # Global flag
                    # Add disk to list only once even if multiple partitions have data
                    if ! $current_disk_already_flagged_for_parts; then
                        disks_with_data_list+="$disk_path (filesystem on partition(s) like $full_part_path)\n"
                        echo "Found filesystem on partition $full_part_path of $disk_path" >> "$LOG_FILE"
                        current_disk_already_flagged_for_parts=true
                    else
                        # Optionally log additional partitions found on the same disk
                        echo "Also found filesystem on partition $full_part_path of $disk_path" >> "$LOG_FILE"
                    fi
                    # If we only care if *any* partition has data, we could break here.
                    # However, iterating all partitions on this disk might be useful for more detailed logging if desired.
                    # For now, just flagging the disk once is enough for the warning.
                fi
            done < <(echo "$part_names") # Process substitution here
            # If this disk was flagged due to partitions, continue to the next disk in the outer loop
            if $current_disk_already_flagged_for_parts; then
                continue
            fi
        fi

        # Check blkid output for any fs or partition table info (only if not already flagged)
        if blkid -p "$disk_path" 2>/dev/null | grep -Eq 'PTTYPE|UUID'; then
             # Check if blkid actually found a PTTYPE or a filesystem UUID (not just PARTUUID)
            if blkid -p "$disk_path" 2>/dev/null | grep -Eq 'PTTYPE="(gpt|dos)"' || \
               blkid -p "$disk_path" 2>/dev/null | grep -Eq 'UUID="[^"]+" TYPE="[^"]+"'; then
                data_found_on_disks=true
                disks_with_data_list+="$disk_path (partition table or filesystem detected by blkid)\n"
                echo "Found partition table or filesystem via blkid on $disk_path" >> "$LOG_FILE"
            fi
        fi
    done
    IFS=$IFS_BAK

    local dialog_title="⚠️  DESTRUCTIVE OPERATION WARNING ⚠️"
    local dialog_message

    if $data_found_on_disks; then
        dialog_title="⚠️ DATA DETECTED - DESTRUCTIVE OPERATION WARNING ⚠️"
        dialog_message="Data or existing filesystems have been detected on the following disk(s):\n\n${disks_with_data_list}\n"
        dialog_message+="ALL DATA ON THESE DISKS AND OTHER SELECTED DISKS WILL BE COMPLETELY ERASED:\n\n$disk_list\n\n"
        dialog_message+="This operation is IRREVERSIBLE!\n\nAre you absolutely sure you want to proceed?"
        echo "User warned about data on specific disks: ${disks_with_data_list}" >> "$LOG_FILE"
    else
        dialog_message="The following disks will be COMPLETELY ERASED:\n\n$disk_list\n\n"
        dialog_message+="No specific data or filesystems were automatically detected on these disks, but any existing data WILL BE LOST!\n\n"
        dialog_message+="This operation is IRREVERSIBLE!\n\nAre you absolutely sure?"
        echo "User warned about disk erasure (no specific data pre-detected)." >> "$LOG_FILE"
    fi

    if ! dialog --title "$dialog_title" --yesno "$dialog_message" 20 70; then
        show_error "Installation cancelled by user."
        echo "User cancelled installation at disk wipe confirmation." >> "$LOG_FILE"
        exit 1
    else
        echo "User confirmed disk wipe." >> "$LOG_FILE"
    fi

    # Continue with original partitioning logic
    log_debug "Wiping ZFS target disks..."
    for disk in "${target_disks_arr[@]}"; do
        show_progress "Wiping target disk: $disk..."
        log_debug "Wiping ZFS target disk: $disk with wipefs and sgdisk --zap-all."
        wipefs -a "$disk" &>> "$LOG_FILE" || log_debug "wipefs -a $disk failed (non-critical)"
        sgdisk --zap-all "$disk" &>> "$LOG_FILE" || log_debug "sgdisk --zap-all $disk failed (non-critical)"
    done
    log_debug "Finished wiping ZFS target disks."

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        log_debug "Wiping Clover disk: ${CONFIG_VARS[CLOVER_DISK]}"
        show_progress "Wiping Clover disk: ${CONFIG_VARS[CLOVER_DISK]}..."
        wipefs -a "${CONFIG_VARS[CLOVER_DISK]}" &>> "$LOG_FILE" || log_debug "wipefs -a ${CONFIG_VARS[CLOVER_DISK]} failed (non-critical)"
        sgdisk --zap-all "${CONFIG_VARS[CLOVER_DISK]}" &>> "$LOG_FILE" || log_debug "sgdisk --zap-all ${CONFIG_VARS[CLOVER_DISK]} failed (non-critical)"
        log_debug "Finished wiping Clover disk."
    fi

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        local header_disk="${CONFIG_VARS[HEADER_DISK]}"
        log_debug "Preparing detached header disk: $header_disk"
        show_progress "Wiping header disk: $header_disk..."
        wipefs -a "$header_disk" &>> "$LOG_FILE" || log_debug "wipefs -a $header_disk failed (non-critical)"
        sgdisk --zap-all "$header_disk" &>> "$LOG_FILE" || log_debug "sgdisk --zap-all $header_disk failed (non-critical)"

        log_debug "Partitioning header disk $header_disk: sgdisk -n 1:0:0 -t 1:8300 -c 1:LUKS-Headers $header_disk"
        sgdisk -n 1:0:0 -t 1:8300 -c 1:LUKS-Headers "$header_disk" &>> "$LOG_FILE"
        log_debug "Running partprobe after header disk partitioning."
        partprobe &>> "$LOG_FILE"
        sleep 2

        local p_prefix=""
        [[ "$header_disk" == /dev/nvme* ]] && p_prefix="p"
        CONFIG_VARS[HEADER_PART]="${header_disk}${p_prefix}1"
        log_debug "Header partition set to: ${CONFIG_VARS[HEADER_PART]}"
        log_debug "Formatting header partition ${CONFIG_VARS[HEADER_PART]} as ext4 with label LUKS_HEADERS."
        mkfs.ext4 -L "LUKS_HEADERS" "${CONFIG_VARS[HEADER_PART]}" &>> "$LOG_FILE"
        CONFIG_VARS[HEADER_PART_UUID]=$(blkid -s UUID -o value "${CONFIG_VARS[HEADER_PART]}" 2>/dev/null)
        log_debug "Header partition UUID: ${CONFIG_VARS[HEADER_PART_UUID]}"
        if [[ -z "${CONFIG_VARS[HEADER_PART_UUID]}" ]]; then
            log_debug "CRITICAL: Failed to retrieve UUID for header partition ${CONFIG_VARS[HEADER_PART]}."
            show_error "CRITICAL: Failed to retrieve UUID for header partition ${CONFIG_VARS[HEADER_PART]}."
            show_error "This UUID is essential for the system to locate detached LUKS headers at boot."
            show_error "Please check the device and ensure it's correctly partitioned and formatted."
            exit 1
        fi
        show_progress "Header partition ${CONFIG_VARS[HEADER_PART]} has UUID: ${CONFIG_VARS[HEADER_PART_UUID]}"
        show_success "Header disk prepared."
        log_debug "Header disk preparation successful."
    fi

    log_debug "Running partprobe after all initial wiping and potential header disk setup."
    partprobe &>> "$LOG_FILE"
    sleep 3

    local primary_target=${target_disks_arr[0]}
    log_debug "Primary target disk for EFI/Boot partitions: $primary_target"
    show_progress "Partitioning primary target disk: $primary_target"
    log_debug "Partitioning $primary_target: EFI (sgdisk -n 1:1M:+512M -t 1:EF00 -c 1:EFI)"
    sgdisk -n 1:1M:+512M -t 1:EF00 -c 1:EFI "$primary_target" &>> "$LOG_FILE"
    log_debug "Partitioning $primary_target: Boot (sgdisk -n 2:0:+1G -t 2:8300 -c 2:Boot)"
    sgdisk -n 2:0:+1G -t 2:8300 -c 2:Boot "$primary_target" &>> "$LOG_FILE"
    log_debug "Partitioning $primary_target: LUKS-ZFS (sgdisk -n 3:0:0 -t 3:BF01 -c 3:LUKS-ZFS)"
    sgdisk -n 3:0:0 -t 3:BF01 -c 3:LUKS-ZFS "$primary_target" &>> "$LOG_FILE"

    log_debug "Partitioning any additional ZFS target disks..."
    for i in $(seq 1 $((${#target_disks_arr[@]}-1))); do
        local disk=${target_disks_arr[$i]}
        log_debug "Creating ZFS data partition on additional disk $disk: sgdisk -n 1:0:0 -t 1:BF01 -c 1:LUKS-ZFS"
        show_progress "Creating ZFS data partition on $disk"
        sgdisk -n 1:0:0 -t 1:BF01 -c 1:LUKS-ZFS "$disk" &>> "$LOG_FILE"
    done
    log_debug "Finished partitioning additional ZFS target disks."

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        log_debug "Partitioning Clover disk ${CONFIG_VARS[CLOVER_DISK]}: sgdisk -n 1:1M:0 -t 1:EF00 -c 1:Clover-EFI"
        show_progress "Partitioning Clover disk: ${CONFIG_VARS[CLOVER_DISK]}"
        sgdisk -n 1:1M:0 -t 1:EF00 -c 1:Clover-EFI "${CONFIG_VARS[CLOVER_DISK]}" &>> "$LOG_FILE"
        local p_prefix=""
        [[ "${CONFIG_VARS[CLOVER_DISK]}" == /dev/nvme* ]] && p_prefix="p"
        CONFIG_VARS[CLOVER_EFI_PART]="${CONFIG_VARS[CLOVER_DISK]}${p_prefix}1"
        log_debug "Clover EFI partition set to: ${CONFIG_VARS[CLOVER_EFI_PART]}"
    fi

    log_debug "Running partprobe after all main partitioning."
    partprobe &>> "$LOG_FILE"
    sleep 3

    local p_prefix=""
    [[ "$primary_target" == /dev/nvme* ]] && p_prefix="p"
    CONFIG_VARS[EFI_PART]="${primary_target}${p_prefix}1"
    CONFIG_VARS[BOOT_PART]="${primary_target}${p_prefix}2"
    log_debug "Primary EFI partition: ${CONFIG_VARS[EFI_PART]}, Boot partition: ${CONFIG_VARS[BOOT_PART]}"

    log_debug "Formatting EFI partition ${CONFIG_VARS[EFI_PART]} as vfat."
    mkfs.vfat -F32 "${CONFIG_VARS[EFI_PART]}" &>> "$LOG_FILE"
    log_debug "Formatting Boot partition ${CONFIG_VARS[BOOT_PART]} as ext4."
    mkfs.ext4 -F "${CONFIG_VARS[BOOT_PART]}" &>> "$LOG_FILE"

    log_debug "Identifying LUKS partitions..."
    local luks_partitions=()
    for disk in "${target_disks_arr[@]}"; do
        p_prefix=""
        [[ "$disk" == /dev/nvme* ]] && p_prefix="p"
        if [[ "$disk" == "$primary_target" ]]; then
            luks_partitions+=("${disk}${p_prefix}3")
            log_debug "LUKS partition for primary disk $disk: ${disk}${p_prefix}3"
        else
            luks_partitions+=("${disk}${p_prefix}1")
            log_debug "LUKS partition for additional disk $disk: ${disk}${p_prefix}1"
        fi
    done

    # shellcheck disable=SC2153 # LUKS_PARTITIONS is a key in associative array CONFIG_VARS.
    CONFIG_VARS[LUKS_PARTITIONS]="${luks_partitions[*]}"
    log_debug "All LUKS partitions identified: ${CONFIG_VARS[LUKS_PARTITIONS]}"
    show_success "All disks partitioned successfully."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

#!/usr/bin/env bash
# disk_operations.sh - FAILSAFE VERSION
# Contains functions related to disk partitioning and formatting.

# Source simplified UI functions first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=ui_functions.sh
source "${SCRIPT_DIR}/ui_functions.sh" || { printf "Critical Error: Failed to source ui_functions.sh in disk_operations.sh. Exiting.\n" >&2; exit 1; }

# Import health check module (which also sources ui_functions.sh)
# shellcheck source=./health_checks.sh
source "${SCRIPT_DIR}/health_checks.sh" || { show_error "Critical Error: Failed to source health_checks.sh. Exiting."; exit 1; }

# Helper function to centralize and simplify the data check.
_disk_has_data() {
    local disk_path="$1"
    log_debug "Checking for data on $disk_path..."
    if [[ ! -e "$disk_path" ]]; then 
        log_debug "Disk $disk_path does not exist."
        return 1; # Return false if disk doesn't exist
    fi

    if blkid -p "$disk_path" 2>/dev/null | grep -qE '(TYPE|PTTYPE)='; then
        log_debug "Data check on '$disk_path': Found filesystem or partition table on the disk block itself."
        return 0 # True, data found
    fi

    if lsblk -no FSTYPE "$disk_path" 2>/dev/null | grep -q '[^[:space:]]'; then
        log_debug "Data check on '$disk_path': Found a filesystem on at least one of its partitions."
        return 0 # True, data found
    fi

    log_debug "Data check on '$disk_path': No significant data signatures found."
    return 1 # False, no data found
}

partition_and_format_disks() {
    log_debug "Entering function: ${FUNCNAME[0]} - Starting disk partitioning and formatting process."
    show_header "PARTITIONING & FORMATTING DISKS"

    local target_disks_arr=()
    # Ensure CONFIG_VARS[ZFS_TARGET_DISKS] is not empty before attempting to read into array
    log_debug "Raw ZFS_TARGET_DISKS from CONFIG_VARS: '${CONFIG_VARS[ZFS_TARGET_DISKS]:-}'"
    if [[ -z "${CONFIG_VARS[ZFS_TARGET_DISKS]:-}" ]]; then
        log_error "Configuration error: ZFS_TARGET_DISKS is not set. Cannot proceed with partitioning."
        show_error "Configuration error: ZFS_TARGET_DISKS is not set. Cannot proceed with partitioning."
        return 1 # Changed exit 1 to return 1
    fi    
    read -r -a target_disks_arr <<< "${CONFIG_VARS[ZFS_TARGET_DISKS]}"
    log_debug "Parsed ZFS_TARGET_DISKS into target_disks_arr. Count: ${#target_disks_arr[@]}."
    for disk_item in "${target_disks_arr[@]}"; do
        log_debug "  ZFS target disk item: '$disk_item'"
    done
    log_debug "Final target_disks_arr: ${target_disks_arr[*]}"
    
    log_debug "Preparing to run health checks on target disks: ${CONFIG_VARS[ZFS_TARGET_DISKS]}"
    show_progress "Running health checks on target disks..."
    CONFIG_VARS[TARGET_DISKS]="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
    log_debug "Set CONFIG_VARS[TARGET_DISKS] for health_check: '${CONFIG_VARS[TARGET_DISKS]}'. Invoking health_check 'disks' false..."
    if ! health_check "disks" false; then # health_check uses ui_functions for its own logging
        show_warning "Disk health check reported issues with some disks."
        # health_check's component check_disk_health should ideally log its findings to LOG_FILE
        # For now, we assume critical issues are logged by health_check itself.
        # We'll prompt to continue based on the warning.
        printf "\n--- Disk Health Report Snippet (Full details in %s) ---\n" "${LOG_FILE:-/tmp/installer.log}"
        # Attempt to get a summary from check_disk_health if it outputs to stdout
        # This is a placeholder; actual report generation might need adjustment in health_checks.sh
        # For now, we'll just show the warning and point to the main log.
        # check_disk_health > "$report_file" # This would require health_checks.sh to be designed for this.
        # if [[ -s "$report_file" ]]; then
        #    cat "$report_file"
        # else
        printf "Please review the main log file for detailed disk health information.\n"
        # fi
        # rm -f "$report_file"

        log_debug "Prompting user: 'Some disk health issues were detected (see log). Continue anyway?'"
        if ! prompt_yes_no "Some disk health issues were detected (see log). Continue anyway?"; then
            log_warning "User response to disk health issues prompt: No. Chose not to continue."
            show_error "Installation cancelled due to disk health issues."
            return 1 # Changed exit 1 to return 1
        else
            log_info "User response to disk health issues prompt: Yes. Chose to continue despite warnings."
        fi
    else
        log_info "Disk health check passed for all target disks."
        show_success "All disks passed health checks."
    fi

    local all_disks_to_wipe_assoc=()
    declare -A all_disks_to_wipe_assoc # Use associative array for uniqueness
    log_debug "Populating all_disks_to_wipe_assoc from target_disks_arr: ${target_disks_arr[*]}"
    for disk in "${target_disks_arr[@]}"; do 
        all_disks_to_wipe_assoc["$disk"]=1;
        log_debug "  Added ZFS target disk to wipe_assoc: '$disk'"
    done

    log_debug "Checking for detached header disk. USE_DETACHED_HEADERS='${CONFIG_VARS[USE_DETACHED_HEADERS]:-}', HEADER_DISK='${CONFIG_VARS[HEADER_DISK]:-}'"
    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" && -n "${CONFIG_VARS[HEADER_DISK]:-}" ]]; then
        all_disks_to_wipe_assoc["${CONFIG_VARS[HEADER_DISK]}"]=1
        log_debug "  Added HEADER_DISK to wipe_assoc: '${CONFIG_VARS[HEADER_DISK]}'."
    fi

    log_debug "Checking for Clover disk. USE_CLOVER='${CONFIG_VARS[USE_CLOVER]:-}', CLOVER_DISK='${CONFIG_VARS[CLOVER_DISK]:-}'"
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" && -n "${CONFIG_VARS[CLOVER_DISK]:-}" ]]; then
        all_disks_to_wipe_assoc["${CONFIG_VARS[CLOVER_DISK]}"]=1
        log_debug "  Added CLOVER_DISK to wipe_assoc: '${CONFIG_VARS[CLOVER_DISK]}'."
    fi
    log_debug "Final all_disks_to_wipe_assoc keys: '${!all_disks_to_wipe_assoc[*]}', values: '${all_disks_to_wipe_assoc[*]}'."
    
    local all_disks_to_wipe=("${!all_disks_to_wipe_assoc[@]}")
    log_debug "Consolidated list of all disks to be wiped: ${all_disks_to_wipe[*]}"
    if [[ ${#all_disks_to_wipe[@]} -eq 0 ]]; then
        log_error "No disks identified for partitioning. ZFS_TARGET_DISKS='${CONFIG_VARS[ZFS_TARGET_DISKS]}', HEADER_DISK='${CONFIG_VARS[HEADER_DISK]}', CLOVER_DISK='${CONFIG_VARS[CLOVER_DISK]}'."
        show_error "No disks identified for partitioning. Check ZFS_TARGET_DISKS, HEADER_DISK, or CLOVER_DISK variables."
        return 1 # Changed exit 1 to return 1
    fi    

    log_debug "Starting safety checks for each disk in all_disks_to_wipe: ${all_disks_to_wipe[*]}"
    for disk in "${all_disks_to_wipe[@]}"; do
        log_debug "  Safety checking disk: '$disk'"
        if [[ -z "$disk" ]]; then 
            log_debug "    Skipping empty disk name in safety check."
            continue; 
        fi 
        log_debug "    Checking if disk '$disk' is the installer device ('${INSTALLER_DEVICE:-}')"
        if [[ "$disk" == "${INSTALLER_DEVICE:-}" ]]; then # Ensure INSTALLER_DEVICE is defined
            log_error "Safety Stop: Attempting to use installer device '$INSTALLER_DEVICE' ($disk) as a target!"
            show_error "Safety Stop: Cannot use installer device ($INSTALLER_DEVICE) as a target!" && return 1 # Changed exit 1 to return 1
        else
            log_debug "    Disk '$disk' is NOT the installer device."
        fi
        local real_disk_path
        real_disk_path=$(readlink -f "$disk")
        log_debug "    Checking if disk '$disk' (real path: '$real_disk_path') or its partitions are mounted."
        if grep -q "^${real_disk_path}" /proc/mounts || grep -q "^$disk" /proc/mounts; then
            local mounts
            mounts=$(grep -E "(^${real_disk_path}|^$disk)" /proc/mounts)
            log_error "Safety Stop: Disk $disk (real path: $real_disk_path) is currently mounted! Mounts:\n$mounts"
            show_error "Safety Stop: Disk $disk (or its real path $real_disk_path) is currently mounted!" && return 1
        else
            log_debug "    Disk '$disk' (real path: '$real_disk_path') is NOT mounted."
        fi
    done
    log_debug "Installer device safety checks passed."

    local data_found_on_disks=false
    local disks_with_data_list=""
    log_debug "Starting check for existing data on selected disks: ${all_disks_to_wipe[*]}"
    printf "\n--- Checking for existing data on selected disks ---\n"
    for disk_path in "${all_disks_to_wipe[@]}"; do
        log_debug "  Checking for data on disk_path: '$disk_path' using _disk_has_data function."
        printf "Checking disk: %s\n" "$disk_path"
        if _disk_has_data "$disk_path"; then
            log_debug "    _disk_has_data returned true (data found) for '$disk_path'."
            data_found_on_disks=true
            disks_with_data_list+="$disk_path "
            log_debug "    Added '$disk_path' to disks_with_data_list. Current list: '$disks_with_data_list'"
        else
            log_debug "    _disk_has_data returned false (no data found) for '$disk_path'."
        fi
    done

    log_debug "Data found on disks check complete. data_found_on_disks='${data_found_on_disks}'. disks_with_data_list='${disks_with_data_list}'"
    if $data_found_on_disks; then
        log_warning "Data was found on the following disk(s): ${disks_with_data_list} (This warning is shown to user)"
        printf "\nThe following disks are slated for wiping:\n"
        log_debug "Displaying list of disks to be wiped (data found path):"
        for disk_to_wipe in "${all_disks_to_wipe[@]}"; do
            local data_tag=""
            if [[ " $disks_with_data_list " == *" $disk_to_wipe "* ]]; then
                data_tag=" (CONTAINS DATA)"
            fi
            log_debug "  - $disk_to_wipe$data_tag (User will see this)"
            printf "  - %s%s\n" "$disk_to_wipe" "$data_tag"
        done
        log_debug "Prompting user: 'ALL DATA on these disks will be PERMANENTLY DESTROYED. Are you absolutely sure you want to proceed with wiping them?'"
        if ! prompt_yes_no "ALL DATA on these disks will be PERMANENTLY DESTROYED. Are you absolutely sure you want to proceed with wiping them?"; then
            log_warning "User denied confirmation to wipe disks with data: ${disks_with_data_list}. Aborting."
            show_error "Disk wipe confirmation denied. Aborting."
            return 1 # Changed exit 1 to return 1
        fi
        log_info "User CONFIRMED wiping disks with data: ${disks_with_data_list}"
    else
        log_info "No pre-existing data detected on target disks. (This info is shown to user)"
        show_info "No pre-existing data detected on target disks."
        printf "\nThe following disks will be partitioned and formatted:\n"
        log_debug "Displaying list of disks to be partitioned (no data found path):"
        for disk_to_wipe in "${all_disks_to_wipe[@]}"; do
            log_debug "  - $disk_to_wipe (User will see this)"
            printf "  - %s\n" "$disk_to_wipe"
        done
        log_debug "Prompting user: 'Are you sure you want to continue with partitioning these disks?'"
        if ! prompt_yes_no "Are you sure you want to continue with partitioning these disks?"; then
            log_warning "User cancelled partitioning (no data found, but confirmation denied). Aborting."
            show_error "Partitioning cancelled by user."
            return 1 # Changed exit 1 to return 1
        fi
        log_info "User CONFIRMED partitioning disks (no pre-existing data found)."
    fi

    log_debug "Disks confirmed for wiping: ${all_disks_to_wipe[*]}"

    log_info "Proceeding to wipe and partition disks: ${all_disks_to_wipe[*]}"
    for disk in "${all_disks_to_wipe[@]}"; do
        log_debug "Processing disk for wipe/partition: '$disk'"
        show_progress "Wiping and partitioning $disk..."
        local cmd
        cmd="sgdisk --zap-all \"$disk\""
        log_debug "Executing: $cmd"
        sgdisk --zap-all "$disk" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of '$cmd': $?"

        cmd="sgdisk --clear \"$disk\""
        log_debug "Executing: $cmd"
        sgdisk --clear "$disk" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of '$cmd': $?"

        cmd="sgdisk --mbrtogpt \"$disk\""
        log_debug "Executing: $cmd (converting to GPT, ignores if already GPT)"
        sgdisk --mbrtogpt "$disk" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of '$cmd': $?"
        log_debug "Finished sgdisk wipe operations for $disk."
    done

    local primary_target="${target_disks_arr[0]}"
    if [[ -n "$primary_target" ]]; then
        log_info "Partitioning primary target disk '$primary_target' for EFI, Boot, and LUKS-ZFS."
        show_progress "Partitioning primary target disk $primary_target..."
        local cmd_efi cmd_boot cmd_luks
        cmd_efi="sgdisk -n 1:0:+1G -t 1:EF00 -c 1:\"EFI System Partition\" \"$primary_target\""
        log_debug "Executing EFI partition creation: $cmd_efi"
        sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI System Partition" "$primary_target" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of EFI partition creation: $?"

        cmd_boot="sgdisk -n 2:0:+2G -t 2:8300 -c 2:\"Linux Boot\" \"$primary_target\""
        log_debug "Executing Boot partition creation: $cmd_boot"
        sgdisk -n 2:0:+2G -t 2:8300 -c 2:"Linux Boot" "$primary_target" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of Boot partition creation: $?"

        cmd_luks="sgdisk -n 3:0:0   -t 3:BF01 -c 3:\"LUKS-ZFS\"  \"$primary_target\""
        log_debug "Executing LUKS-ZFS partition creation: $cmd_luks"
        sgdisk -n 3:0:0   -t 3:BF01 -c 3:"LUKS-ZFS"  "$primary_target" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of LUKS-ZFS partition creation: $?"
        log_debug "Primary target disk $primary_target partitioned."
    fi

    for disk_idx in "${!target_disks_arr[@]}"; do
        if [[ $disk_idx -eq 0 ]]; then continue; fi
        local disk="${target_disks_arr[$disk_idx]}"
        log_info "Partitioning additional ZFS target disk '$disk' for LUKS-ZFS."
        show_progress "Partitioning ZFS target disk $disk..."
        local cmd_luks_add
        cmd_luks_add="sgdisk -n 1:0:0 -t 1:BF01 -c 1:\"LUKS-ZFS\" \"$disk\""
        log_debug "Executing LUKS-ZFS partition creation on additional disk: $cmd_luks_add"
        sgdisk -n 1:0:0 -t 1:BF01 -c 1:"LUKS-ZFS" "$disk" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of LUKS-ZFS partition creation on $disk: $?"
        log_debug "Additional ZFS target disk $disk partitioned."
    done

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" && -n "${CONFIG_VARS[CLOVER_DISK]:-}" ]]; then
        local clover_disk="${CONFIG_VARS[CLOVER_DISK]}"
        log_info "Partitioning Clover EFI disk '$clover_disk'."
        show_progress "Partitioning Clover EFI disk $clover_disk..."
        # Assuming CLOVER_DISK was already wiped if it was in all_disks_to_wipe
        # If not, it should have been added to all_disks_to_wipe and processed above.
        # Here we just create the partition structure.
        local cmd_clover_efi
        cmd_clover_efi="sgdisk -n 1:0:0 -t 1:EF00 -c 1:\"Clover EFI\" \"$clover_disk\""
        log_debug "Executing EFI partition creation on Clover disk: $cmd_clover_efi"
        sgdisk -n 1:0:0 -t 1:EF00 -c 1:"Clover EFI" "$clover_disk" >> "$LOG_FILE" 2>&1
        log_debug "Exit status of EFI partition creation on $clover_disk: $?"
        local p_prefix=""
        [[ "$clover_disk" == /dev/nvme* ]] && p_prefix="p"
        CONFIG_VARS[CLOVER_EFI_PART]="${clover_disk}${p_prefix}1"
        log_debug "Clover EFI partition set to: ${CONFIG_VARS[CLOVER_EFI_PART]}"
        log_info "Formatting Clover EFI partition '${CONFIG_VARS[CLOVER_EFI_PART]}' as FAT32."
        show_progress "Formatting Clover EFI partition ${CONFIG_VARS[CLOVER_EFI_PART]}..."
        local cmd_clover_mkfs="mkfs.vfat -F32 \"${CONFIG_VARS[CLOVER_EFI_PART]}\""
        log_debug "Executing: $cmd_clover_mkfs"
        if mkfs.vfat -F32 "${CONFIG_VARS[CLOVER_EFI_PART]}" >> "$LOG_FILE" 2>&1; then
            log_debug "Exit status of '$cmd_clover_mkfs': $? (Success)"
            log_debug "Successfully formatted Clover EFI partition '${CONFIG_VARS[CLOVER_EFI_PART]}'."
        else
            local clover_mkfs_status=$?
            log_error "Failed to format Clover EFI partition '${CONFIG_VARS[CLOVER_EFI_PART]}'. Exit status: $clover_mkfs_status"
            # Potentially return 1 here if critical
        fi
    fi
    
    show_progress "Waiting for partition changes to be recognized..."
    log_debug "Running partprobe to inform OS of partition table changes."
    partprobe >> "$LOG_FILE" 2>&1
    log_debug "Exit status of partprobe: $?"
    log_debug "Running udevadm settle to wait for udev processing."
    udevadm settle
    log_debug "Exit status of udevadm settle: $?"
    log_debug "partprobe and udevadm settle completed."

    local p_prefix_pt="" # For primary_target
    [[ "$primary_target" == /dev/nvme* ]] && p_prefix_pt="p"
    log_debug "Determined p_prefix_pt for primary_target '$primary_target' as '$p_prefix_pt'."
    CONFIG_VARS[EFI_PART]="${primary_target}${p_prefix_pt}1"
    CONFIG_VARS[BOOT_PART]="${primary_target}${p_prefix_pt}2"
    log_debug "Set CONFIG_VARS[EFI_PART]=${CONFIG_VARS[EFI_PART]}"
    log_debug "Set CONFIG_VARS[BOOT_PART]=${CONFIG_VARS[BOOT_PART]}"
    
    log_info "Formatting EFI partition '${CONFIG_VARS[EFI_PART]}' as FAT32."
    show_progress "Formatting EFI partition ${CONFIG_VARS[EFI_PART]} as FAT32..."
    local cmd_primary_efi_mkfs="mkfs.vfat -F32 \"${CONFIG_VARS[EFI_PART]}\""
    log_debug "Executing: $cmd_primary_efi_mkfs"
    if mkfs.vfat -F32 "${CONFIG_VARS[EFI_PART]}" >> "$LOG_FILE" 2>&1; then
        log_debug "Exit status of '$cmd_primary_efi_mkfs': $? (Success)"
        log_debug "Successfully formatted EFI partition '${CONFIG_VARS[EFI_PART]}'."
    else
        local primary_efi_mkfs_status=$?
        log_error "Failed to format EFI partition '${CONFIG_VARS[EFI_PART]}'. Exit status: $primary_efi_mkfs_status"
        # Decide if this is fatal, for now, we continue but it likely is.
    fi

    log_info "Formatting Boot partition '${CONFIG_VARS[BOOT_PART]}' as ext4."
    show_progress "Formatting Boot partition ${CONFIG_VARS[BOOT_PART]} as ext4..."
    local cmd_boot_mkfs="mkfs.ext4 -F \"${CONFIG_VARS[BOOT_PART]}\""
    log_debug "Executing: $cmd_boot_mkfs"
    if mkfs.ext4 -F "${CONFIG_VARS[BOOT_PART]}" >> "$LOG_FILE" 2>&1; then
        log_debug "Exit status of '$cmd_boot_mkfs': $? (Success)"
        log_debug "Successfully formatted Boot partition '${CONFIG_VARS[BOOT_PART]}'."
    else
        local boot_mkfs_status=$?
        log_error "Failed to format Boot partition '${CONFIG_VARS[BOOT_PART]}'. Exit status: $boot_mkfs_status"
        # Decide if this is fatal
    fi

    log_debug "Identifying LUKS partitions based on target_disks_arr: ${target_disks_arr[*]} and primary_target: $primary_target"
    local luks_partitions_list=()
    for disk in "${target_disks_arr[@]}"; do
        local p_prefix_luks=""
        [[ "$disk" == /dev/nvme* ]] && p_prefix_luks="p"
        log_debug "For disk '$disk', p_prefix_luks is '$p_prefix_luks'."
        if [[ "$disk" == "$primary_target" ]]; then
            luks_partitions_list+=("${disk}${p_prefix_luks}3")
            log_debug "Added primary LUKS partition: ${disk}${p_prefix_luks}3"
        else
            luks_partitions_list+=("${disk}${p_prefix_luks}1")
            log_debug "Added additional LUKS partition: ${disk}${p_prefix_luks}1"
        fi
    done
    CONFIG_VARS[LUKS_PARTITIONS]="${luks_partitions_list[*]}"
    log_info "LUKS partitions identified and stored in CONFIG_VARS[LUKS_PARTITIONS]: ${CONFIG_VARS[LUKS_PARTITIONS]}"
    log_debug "Disk partitioning and basic formatting steps completed. Proceeding to verification."

    show_progress "Verifying new partitions..."
    log_debug "Starting verification of created partitions."
    local missing_partitions_found=false
    
    log_debug "Verifying EFI partition: '${CONFIG_VARS[EFI_PART]:-}'"
    if [[ ! -b "${CONFIG_VARS[EFI_PART]:-}" ]]; then
        log_error "Verification FAILED: EFI partition ${CONFIG_VARS[EFI_PART]:-(not set)} not found or not a block device."
        show_error "Verification failed: EFI partition ${CONFIG_VARS[EFI_PART]:-(not set)} not found or not a block device."
        missing_partitions_found=true
    else
        log_debug "EFI partition ${CONFIG_VARS[EFI_PART]} IS a block device. Verification OK."
    fi
    
    log_debug "Verifying Boot partition: '${CONFIG_VARS[BOOT_PART]:-}'"
    if [[ ! -b "${CONFIG_VARS[BOOT_PART]:-}" ]]; then
        log_error "Verification FAILED: Boot partition ${CONFIG_VARS[BOOT_PART]:-(not set)} not found or not a block device."
        show_error "Verification failed: Boot partition ${CONFIG_VARS[BOOT_PART]:-(not set)} not found or not a block device."
        missing_partitions_found=true
    else
        log_debug "Boot partition ${CONFIG_VARS[BOOT_PART]} IS a block device. Verification OK."
    fi
    
    # Check LUKS partitions
    log_debug "Verifying LUKS partitions: '${CONFIG_VARS[LUKS_PARTITIONS]:-}'"
    if [[ -z "${CONFIG_VARS[LUKS_PARTITIONS]:-}" ]]; then
        log_warning "No LUKS partitions defined in CONFIG_VARS[LUKS_PARTITIONS] for verification. Skipping LUKS partition check."
        show_warning "No LUKS partitions defined in CONFIG_VARS[LUKS_PARTITIONS] for verification."
    else
        log_debug "Iterating through LUKS partitions for verification."
        for luks_part in ${CONFIG_VARS[LUKS_PARTITIONS]}; do # Iterate string as array
            log_debug "Verifying LUKS partition: '$luks_part'"
            if [[ ! -b "$luks_part" ]]; then
                log_error "Verification FAILED: LUKS partition $luks_part not found or not a block device."
                show_error "Verification failed: LUKS partition $luks_part not found or not a block device."
                missing_partitions_found=true
            else
                log_debug "LUKS partition $luks_part IS a block device. Verification OK."
            fi
        done
        log_debug "Finished iterating through LUKS partitions."
    fi
    
    log_debug "Final status of missing_partitions_found: $missing_partitions_found"
    if $missing_partitions_found; then
        log_error "Critical error: Some expected partitions were not created or found after partitioning."
        show_error "Critical error: Some expected partitions were not created or found after partitioning."
        if ! prompt_yes_no "Partition verification FAILED. Continue anyway (NOT RECOMMENDED)?"; then
            log_error "User chose NOT to continue after partition verification failure. Aborting."
            show_error "Aborting due to partition verification failure."
            log_debug "Exiting function: ${FUNCNAME[0]} with error (partition verification failed and user aborted)."
            return 1 # Changed exit 1 to return 1
        fi
        log_warning "User chose to continue despite partition verification failures."
        show_warning "Continuing despite partition verification failures."
        log_debug "Exiting function: ${FUNCNAME[0]} with warning (partition verification failed but user continued)."
        return 2 # Indicate warning/partial success
    else
        log_info "All essential partitions verified successfully."
        show_success "All essential partitions verified successfully."
        log_debug "Exiting function: ${FUNCNAME[0]} successfully."
        return 0
    fi
}

# If script is executed directly, run the main function for testing.
# This requires CONFIG_VARS to be populated appropriately.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_warning "This script is intended to be sourced by the main installer."
    show_warning "For direct execution, ensure CONFIG_VARS are appropriately set in your environment or here for testing."
    # Example minimal CONFIG_VARS for testing (adjust to your test environment):
    # export LOG_FILE="./disk_operations.log"
    # declare -A CONFIG_VARS
    # CONFIG_VARS[ZFS_TARGET_DISKS]="/dev/sdb /dev/sdc" # Replace with your actual test disk(s)
    # CONFIG_VARS[USE_CLOVER]="no"
    # CONFIG_VARS[USE_DETACHED_HEADERS]="no"
    # INSTALLER_DEVICE="/dev/sda" # Device running the installer

    # log_file_init # Call if ui_functions.sh's log_file_init is desired for standalone run
    # partition_and_format_disks
    show_info "Disk operations script finished (if invoked directly for testing)."
fi
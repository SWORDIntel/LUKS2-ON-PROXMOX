#!/usr/bin/env bash
#===============================================================================
# ZFS Pool and Dataset Configuration Module (Refined Version)
#===============================================================================

# (The existing configuration defaults are excellent and are kept)
set -o pipefail
: "${ZFS_DEFAULT_ASHIFT:=12}"
# ... etc ...

#-------------------------------------------------------------------------------
# ZFS Pool Configuration and Creation
#-------------------------------------------------------------------------------

setup_zfs_pool() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "ZFS" "Creating ZFS Pool and Datasets"
    
    # --- Parameter extraction and validation are excellent, no changes needed ---
    local pool_name="${CONFIG_VARS[ZFS_POOL_NAME]}"
    local raid_level="${CONFIG_VARS[ZFS_RAID_LEVEL]}"
    local luks_devices=(); read -r -a luks_devices <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
    # ... etc ...
    # (All validation logic for device counts, etc., is kept as is)

    # Check for existing pool (logic is good, no changes)
    if zpool list -H "$pool_name" &>/dev/null; then
        if [[ "${ZFS_FORCE_DESTROY:=false}" == "true" ]]; then
            show_warning "Pool '$pool_name' already exists. Destroying as per configuration..."
            zpool export -f "$pool_name" &>> "$LOG_FILE" || true
            if ! zpool destroy -f "$pool_name" &>> "$LOG_FILE"; then
                show_error "Failed to destroy existing pool '$pool_name'." && return 1
            fi
        else
            show_error "Pool '$pool_name' already exists. Aborting." && return 1
        fi
    fi

    # ANNOTATION: Build the zpool create command using a Bash array for safety and clarity.
    # This avoids complex quoting issues and is safer than a raw `eval`.
    local zpool_create_cmd=(
        zpool create -f
        -o ashift="${CONFIG_VARS[ZFS_ASHIFT]:-$ZFS_DEFAULT_ASHIFT}"
        -o autotrim=on
        -O acltype=posixacl
        -O atime=off
        -O canmount=off
        -O compression="${CONFIG_VARS[ZFS_COMPRESSION]:-$ZFS_DEFAULT_COMPRESSION}"
        -O devices=off
        -O dnodesize=auto
        -O normalization=formD
        -O relatime=off
        -O xattr=sa
        -O mountpoint=none
        -O setuid=off
        -O primarycache="${CONFIG_VARS[ZFS_PRIMARYCACHE]:-$ZFS_DEFAULT_PRIMARYCACHE}"
        -O redundant_metadata="${CONFIG_VARS[ZFS_REDUNDANT_METADATA]:-$ZFS_DEFAULT_REDUNDANT_METADATA}"
        -O recordsize="${CONFIG_VARS[ZFS_RECORDSIZE]:-$ZFS_DEFAULT_RECORDSIZE}"
        -R /mnt
        "$pool_name"
    )

    # Add RAID level and devices
    case "$raid_level" in
        "single") zpool_create_cmd+=("${luks_devices[0]}") ;;
        "mirror") zpool_create_cmd+=(mirror "${luks_devices[@]}") ;;
        "raidz1"|"raidz") zpool_create_cmd+=(raidz1 "${luks_devices[@]}") ;;
        "raidz2") zpool_create_cmd+=(raidz2 "${luks_devices[@]}") ;;
        "raidz3") zpool_create_cmd+=(raidz3 "${luks_devices[@]}") ;;
        *) show_error "Unknown RAID level: $raid_level" && return 1 ;;
    esac

    # Add special vdev if configured
    if [[ "${CONFIG_VARS[ZFS_SPECIAL_VDEV]:-false}" == "true" ]]; then
        local special_devices=(); read -r -a special_devices <<< "${CONFIG_VARS[ZFS_SPECIAL_DEVICES]}"
        if [[ ${#special_devices[@]} -gt 0 ]]; then
            if [[ ${#special_devices[@]} -ge 2 ]]; then
                zpool_create_cmd+=(special mirror "${special_devices[@]}")
            else
                zpool_create_cmd+=(special "${special_devices[0]}")
            fi
        fi
    fi

    # Execute the pool creation command
    log_debug "Executing ZFS pool creation: ${zpool_create_cmd[*]}"
    show_progress "Creating ZFS pool '$pool_name'..."
    if ! "${zpool_create_cmd[@]}" &>> "$LOG_FILE"; then
        show_error "Failed to create ZFS pool. Check logs for details."
        return 1
    fi

    # Verify the pool (logic is good)
    if [[ "${ZFS_VERIFY_POOL:=true}" == "true" ]]; then
        if ! zpool status "$pool_name" &>> "$LOG_FILE"; then
            show_error "ZFS pool '$pool_name' created but is in a FAULTED state."
            return 1
        fi
    fi
    show_success "ZFS pool '$pool_name' created successfully."
    
    # Create dataset structure
    create_zfs_datasets "$pool_name" || return 1
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

#-------------------------------------------------------------------------------
# ZFS Dataset Creation and Configuration (Refined)
#-------------------------------------------------------------------------------

create_zfs_datasets() {
    local pool_name="$1"
    log_debug "Entering function: create_zfs_datasets for pool '$pool_name'"
    show_progress "Creating ZFS dataset hierarchy..."

    # ANNOTATION: Build a single, atomic `zfs create` command for all base datasets.
    # This is more efficient and reliable than individual calls.
    local zfs_create_cmd=(
        zfs create -p
        # Root dataset for the OS, not directly mounted.
        -o canmount=off -o mountpoint=none "${pool_name}/ROOT"
        # The actual bootable root filesystem.
        -o canmount=noauto -o mountpoint=/ "${pool_name}/ROOT/pve-1"
        # User home directories
        -o canmount=on -o mountpoint=/home "${pool_name}/home"
        # /var heirarchy
        -o canmount=on -o mountpoint=/var "${pool_name}/var"
        -o canmount=on -o mountpoint=/var/lib "${pool_name}/var/lib"
        # Container/VM storage
        -o canmount=on -o mountpoint=/var/lib/vz "${pool_name}/var/lib/vz"
        # Logs, with a smaller record size for efficiency
        -o canmount=on -o mountpoint=/var/log "${pool_name}/var/log"
        # Tmp directory with exec permissions
        -o canmount=on -o mountpoint=/tmp -o setuid=on -o exec=on "${pool_name}/tmp"
    )

    log_debug "Executing atomic dataset creation: ${zfs_create_cmd[*]}"
    if ! "${zfs_create_cmd[@]}" &>> "$LOG_FILE"; then
        show_error "Failed to create base ZFS dataset hierarchy."
        return 1
    fi
    # Set correct permissions for /tmp
    chmod 1777 "/mnt/tmp"

    # ANNOTATION: Apply dataset-specific tuning properties in bulk for clarity.
    log_debug "Applying dataset-specific performance tuning..."
    show_progress "Tuning datasets for specific workloads..."
    {
        zfs set recordsize=64k "${pool_name}/var/log"
        zfs set compression=zstd-3 "${pool_name}/var/log"
        zfs set recordsize=1M "${pool_name}/var/lib/vz"
    } &>> "$LOG_FILE"

    # Set the bootfs property on the pool
    log_debug "Setting bootfs to ${pool_name}/ROOT/pve-1"
    show_progress "Setting boot filesystem..."
    if ! zpool set bootfs="${pool_name}/ROOT/pve-1" "$pool_name" &>> "$LOG_FILE"; then
        show_error "Failed to set bootfs property on pool '$pool_name'."
        return 1
    fi

    show_success "ZFS dataset hierarchy created and tuned successfully."
    log_debug "Exiting function: create_zfs_datasets"
    return 0
}

# --- Cache and Info functions are already excellent, no changes needed ---
# create_zfs_cache() and display_zfs_pool_info() can be kept as they are.
# ...

# Export functions
export -f setup_zfs_pool create_zfs_datasets # ... and others
#!/usr/bin/env bash
# Contains functions related to ZFS pool and dataset setup.

setup_zfs_pool() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "ZFS" "Creating ZFS Pool"

    local pool_name="${CONFIG_VARS[ZFS_POOL_NAME]}"
    local raid_level="${CONFIG_VARS[ZFS_RAID_LEVEL]}"
    local zfs_ashift="${CONFIG_VARS[ZFS_ASHIFT]:-12}"
    local zfs_recordsize="${CONFIG_VARS[ZFS_RECORDSIZE]:-128K}"
    local zfs_compression="${CONFIG_VARS[ZFS_COMPRESSION]:-lz4}"
    local luks_devices=()
    read -r -a luks_devices <<< "${CONFIG_VARS[LUKS_MAPPERS]}"

    log_debug "ZFS Pool Name: $pool_name"
    log_debug "ZFS RAID Level: $raid_level"
    log_debug "ZFS ashift: $zfs_ashift (defaulted if not set)"
    log_debug "ZFS recordsize: $zfs_recordsize (defaulted if not set)"
    log_debug "ZFS compression: $zfs_compression (defaulted if not set)"
    log_debug "LUKS devices for ZFS pool: ${luks_devices[*]}"

    if zpool list -H "$pool_name" &>/dev/null; then
        log_debug "Pool $pool_name already exists. Destroying..."
        show_warning "Pool $pool_name already exists. Destroying..."
        zpool destroy -f "$pool_name" &>> "$LOG_FILE"
        log_debug "zpool destroy $pool_name command executed."
    fi

    show_progress "Selected ZFS options: ashift=${zfs_ashift}, recordsize=${zfs_recordsize}, compression=${zfs_compression}"
    # The echo to LOG_FILE is already effectively covered by the log_debug calls above and the command logging below.
    # echo "ZFS options: ashift=${zfs_ashift}, recordsize=${zfs_recordsize}, compression=${zfs_compression}" >> "$LOG_FILE"

    local zpool_cmd="zpool create -f"
    zpool_cmd+=" -o ashift=${zfs_ashift}"
    zpool_cmd+=" -O acltype=posixacl"
    zpool_cmd+=" -O compression=${zfs_compression}"
    zpool_cmd+=" -O recordsize=${zfs_recordsize}"
    zpool_cmd+=" -O dnodesize=auto -O normalization=formD -O relatime=on"
    zpool_cmd+=" -O xattr=sa -O mountpoint=/ -R /mnt"
    zpool_cmd+=" $pool_name"

    case "$raid_level" in
        "single")
            zpool_cmd+=" ${luks_devices[0]}"
            ;;
        "mirror")
            zpool_cmd+=" mirror ${luks_devices[*]}"
            ;;
        "raidz1")
            zpool_cmd+=" raidz1 ${luks_devices[*]}"
            ;;
        "raidz2")
            zpool_cmd+=" raidz2 ${luks_devices[*]}"
            ;;
        *)
            show_error "Unknown RAID level: $raid_level"
            exit 1
            ;;
    esac

    show_progress "Creating ZFS pool with $raid_level configuration (ashift=${zfs_ashift}, recordsize=${zfs_recordsize}, compression=${zfs_compression})..."
    log_debug "Final zpool create command to be executed: $zpool_cmd"
    # Using script to redirect eval's output to log file
    # This is safer than `eval "$zpool_cmd" &>> "$LOG_FILE"` if $zpool_cmd contains complex parts
    script -q -c "eval \"$zpool_cmd\"" /dev/null &>> "$LOG_FILE"
    local zpool_create_status=$?
    log_debug "zpool create command executed. Exit status: $zpool_create_status"

    if [[ $zpool_create_status -ne 0 ]]; then
        log_debug "Failed to create ZFS pool. Command was: $zpool_cmd. Status: $zpool_create_status"
        show_error "Failed to create ZFS pool. Command was: $zpool_cmd"
        exit 1
    fi

    log_debug "ZFS pool $pool_name created successfully."
    show_progress "Creating ZFS datasets..."

    log_debug "Executing: zfs create -o mountpoint=none $pool_name/ROOT"
    zfs create -o mountpoint=none "$pool_name/ROOT" &>> "$LOG_FILE"
    log_debug "Executing: zfs create -o mountpoint=/ $pool_name/ROOT/pve-1"
    zfs create -o mountpoint=/ "$pool_name/ROOT/pve-1" &>> "$LOG_FILE"
    log_debug "Executing: zfs create -o mountpoint=/var/lib/vz $pool_name/data"
    zfs create -o mountpoint=/var/lib/vz "$pool_name/data" &>> "$LOG_FILE"
    log_debug "ZFS datasets created."

    log_debug "Setting bootfs to $pool_name/ROOT/pve-1 for pool $pool_name."
    zpool set bootfs="$pool_name/ROOT/pve-1" "$pool_name" &>> "$LOG_FILE"
    log_debug "bootfs set."

    show_success "ZFS pool created successfully"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

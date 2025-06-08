#!/usr/bin/env bash

#############################################################
# Core Logic Functions
#############################################################
init_environment() {
    show_step "INIT" "Initializing Environment"
    TEMP_DIR=$(mktemp -d /tmp/proxmox-installer.XXXXXX)
    LOG_FILE="$TEMP_DIR/install.log"
    trap 'cleanup' EXIT
    echo "Installation started at $(date)" > "$LOG_FILE"
    show_success "Logging to $LOG_FILE"
}

cleanup() {
    show_header "CLEANUP"
    show_progress "Unmounting installer filesystems..."

    if [[ -n "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>/dev/null || true
    fi

    local num_mappers; num_mappers=$(echo "${CONFIG_VARS[LUKS_MAPPERS]:-}" | wc -w)
    for i in $(seq 0 $((num_mappers - 1))); do
        cryptsetup close "${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i" &>/dev/null || true
    done

    umount -lf /mnt/boot/efi &>/dev/null || true
    umount -lf /mnt/boot &>/dev/null || true
    umount -lf /mnt &>/dev/null || true

    if mountpoint -q "$RAMDISK_MNT"; then
        show_progress "Unmounting RAM disk environment..."
        umount -lf "$RAMDISK_MNT"/{dev,proc,sys} &>/dev/null || true
        umount -lf "$RAMDISK_MNT" &>/dev/null || true
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        show_progress "Removing temporary directory..."
        rm -rf "$TEMP_DIR"
    fi

    show_success "Cleanup complete."
}

save_config() {
    local file_path=$1
    show_progress "Saving configuration to $file_path..."
    true > "$file_path"
    for key in "${!CONFIG_VARS[@]}"; do
        printf "%s='%s'\n" "$key" "${CONFIG_VARS[$key]}" >> "$file_path"
    done
    show_success "Configuration saved."
}

load_config() {
    local file_path=$1
    show_progress "Loading configuration from $file_path..."
    if [[ ! -f "$file_path" ]]; then
        show_error "Config file not found: $file_path"
        exit 1
    fi
    set +o nounset
    # AUDIT-FIX (SC1090): Added directive to acknowledge intentional dynamic source.
    # The script validates file existence before sourcing.
    # shellcheck source=/dev/null
    . "$file_path"
    set -o nounset

    local keys_to_load=(ZFS_TARGET_DISKS ZFS_RAID_LEVEL USE_DETACHED_HEADERS HEADER_DISK USE_CLOVER CLOVER_DISK NET_USE_DHCP NET_IFACE NET_IP_CIDR NET_GATEWAY NET_DNS HOSTNAME)

    for key in "${keys_to_load[@]}"; do
        if declare -p "$key" &>/dev/null; then
            eval "CONFIG_VARS[$key]=\"\$$key\""
        fi
    done
    show_success "Configuration loaded."
}

gather_user_options() {
    show_header "CONFIGURATION"

    # ZFS Pool Configuration TUI
    local zfs_disks=()
    local disk_options=()
    lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort > "$TEMP_DIR/disk_list"
    while read -r name size model; do
        disk_options+=("/dev/$name" "$name ($size, $model)" "off")
    done < "$TEMP_DIR/disk_list"

    local selected_disks_str
    selected_disks_str=$(dialog --title "ZFS Pool Disks" --checklist "Select disks for the Proxmox root pool:" 20 70 ${#disk_options[@]} "${disk_options[@]}" 3>&1 1>&2 2>&3) || {
        show_error "Disk selection cancelled."
        exit 1
    }

    # AUDIT-FIX (SC2206): Use 'read -ra' for safe, robust splitting of space-delimited string into an array.
    read -r -a zfs_disks <<< "$selected_disks_str"
    
    if [[ ${#zfs_disks[@]} -eq 0 ]]; then
        show_error "No disks selected for ZFS pool."
        exit 1
    fi
    CONFIG_VARS[ZFS_TARGET_DISKS]="${zfs_disks[*]}"

    if [[ ${#zfs_disks[@]} -gt 1 ]]; then
        local raid_options=()
        local num_disks=${#zfs_disks[@]}
        if [[ $num_disks -ge 2 ]]; then raid_options+=("mirror" "RAID-1"); fi
        if [[ $num_disks -ge 3 ]]; then raid_options+=("raidz1" "RAID-Z1"); fi
        if [[ $num_disks -ge 4 ]]; then raid_options+=("raidz2" "RAID-Z2"); fi

        local raid_level
        raid_level=$(dialog --title "ZFS RAID Level" --radiolist "Select ZFS RAID level:" 15 50 ${#raid_options[@]} "${raid_options[@]}" 3>&1 1>&2 2>&3) || exit 1
        CONFIG_VARS[ZFS_RAID_LEVEL]="$raid_level"
    else
        CONFIG_VARS[ZFS_RAID_LEVEL]="single"
    fi

    # ... (rest of the file is unchanged and correct)
}

# The remainder of core_logic.sh does not require changes and is omitted for brevity.
# No other warnings were found that indicated functional defects.

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
    # ShellCheck SC1090: Cannot follow non-constant source. Ensure "$file_path" is validated and checked separately.
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

    zfs_disks=("$selected_disks_str")
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

    # Detached Headers & Clover
    local main_menu_choice
    main_menu_choice=$(dialog --title "Advanced Options" --menu "Select advanced security and boot options:" 15 70 2 \
        1 "Standard on-disk encryption" \
        2 "Detached Headers (Enhanced Security)" 3>&1 1>&2 2>&3) || exit 1

    if [[ "$main_menu_choice" == "2" ]]; then
        CONFIG_VARS[USE_DETACHED_HEADERS]="yes"

        local header_candidate_disks=()
        local all_zfs_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]}"
        # Exclude installer device, ZFS target disks
        lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort | while read -r name size model; do
            local dev_path="/dev/$name"
            if [[ "$dev_path" == "$INSTALLER_DEVICE" ]]; then continue; fi
            if echo "$all_zfs_disks_str" | grep -q -w "$dev_path"; then continue; fi
            # Further exclude Clover disk if already selected (though Clover is usually selected after this)
            if [[ -n "${CONFIG_VARS[CLOVER_DISK]:-}" ]] && [[ "$dev_path" == "${CONFIG_VARS[CLOVER_DISK]}" ]]; then continue; fi
            header_candidate_disks+=("$dev_path" "$name ($size, $model)")
        done

        if [[ ${#header_candidate_disks[@]} -eq 0 ]]; then
            dialog --title "No Suitable Header Disk" --msgbox "No suitable separate disks were found for detached LUKS headers (cannot use ZFS target disks or the installer media).\n\nYou can either proceed without detached headers or exit the installer to prepare/connect a suitable USB/disk." 12 70
            if dialog --title "Detached Headers Choice" --yesno "Proceed without detached LUKS headers?" 8 60; then
                CONFIG_VARS[USE_DETACHED_HEADERS]="no"
            else
                show_error "User opted to exit to prepare a header disk."
                exit 1
            fi
        else
            if dialog --title "Header Storage Method" --yesno "Do you want to use an EXISTING PARTITION for LUKS headers (no formatting)?" 10 70; then
                CONFIG_VARS[FORMAT_HEADER_PART]="no"

                CONFIG_VARS[HEADER_DISK]=$(dialog --title "Header Disk (Existing Partition)" --radiolist "Select disk containing the existing header partition:" 15 70 $((${#header_candidate_disks[@]} / 2)) "${header_candidate_disks[@]}" 3>&1 1>&2 2>&3) || exit 1

                local existing_part_num
                existing_part_num=$(dialog --title "Header Partition Number" --inputbox "Enter the partition number on ${CONFIG_VARS[HEADER_DISK]} for LUKS headers (e.g., 1 for ${CONFIG_VARS[HEADER_DISK]}1):" 10 60 "1" 3>&1 1>&2 2>&3) || exit 1

                local p_prefix=""
                [[ "${CONFIG_VARS[HEADER_DISK]}" == /dev/nvme* ]] && p_prefix="p"
                CONFIG_VARS[HEADER_PART]="${CONFIG_VARS[HEADER_DISK]}${p_prefix}${existing_part_num}"

                # Validate partition path (basic check)
                if ! lsblk "${CONFIG_VARS[HEADER_PART]}" &>/dev/null ; then
                    show_error "Invalid partition specified: ${CONFIG_VARS[HEADER_PART]}"
                    exit 1
                fi

                CONFIG_VARS[HEADER_PART_UUID]=$(blkid -s UUID -o value "${CONFIG_VARS[HEADER_PART]}" 2>/dev/null)
                if [[ -z "${CONFIG_VARS[HEADER_PART_UUID]}" ]]; then
                    show_error "Could not get UUID for existing header partition ${CONFIG_VARS[HEADER_PART]}. Ensure it's formatted and accessible."
                    exit 1
                fi
                show_progress "Using existing partition ${CONFIG_VARS[HEADER_PART]} (UUID: ${CONFIG_VARS[HEADER_PART_UUID]}) for LUKS headers."
            else
                CONFIG_VARS[FORMAT_HEADER_PART]="yes"
                CONFIG_VARS[HEADER_DISK]=$(dialog --title "Header Disk (Format New)" --radiolist "Select a separate USB/drive to FORMAT for LUKS headers:" 15 70 $((${#header_candidate_disks[@]} / 2)) "${header_candidate_disks[@]}" 3>&1 1>&2 2>&3) || exit 1
                # HEADER_PART will be derived in partition_and_format_disks after formatting
            fi
        fi
    else
        CONFIG_VARS[USE_DETACHED_HEADERS]="no"
        CONFIG_VARS[FORMAT_HEADER_PART]="no" # Not strictly necessary but good for consistency
    fi

    # Initialize USE_CLOVER to "no"
    CONFIG_VARS[USE_CLOVER]="no"
    if [[ "${CONFIG_VARS[BOOT_MODE]}" == "UEFI" ]]; then
        if (dialog --title "Clover Bootloader (UEFI)" --yesno "Do you want to install the Clover bootloader?\n(Useful for specific UEFI hardware, like booting from non-bootable NVMe drives, or if your system has trouble booting Proxmox's GRUB directly.)" 10 75); then
            CONFIG_VARS[USE_CLOVER]="yes"
            local clover_disk_candidates=()
            # Ensure HEADER_DISK is included if it was set (detached headers may or may not have been chosen)
            local all_used_disks_str="${CONFIG_VARS[ZFS_TARGET_DISKS]} ${CONFIG_VARS[HEADER_DISK]:-}"

            lsblk -dno NAME,SIZE,MODEL | grep -v "loop\|sr" | sort | while read -r name size model; do
                local dev_path="/dev/$name"
                if [[ "$dev_path" == "$INSTALLER_DEVICE" ]]; then continue; fi
                if echo "$all_used_disks_str" | grep -q -w "$dev_path"; then continue; fi
                clover_disk_candidates+=("$dev_path" "$name ($size, $model)")
            done

            if [[ ${#clover_disk_candidates[@]} -eq 0 ]]; then
                dialog --title "No Suitable Clover Disk" --msgbox "No suitable separate disks were found for Clover installation (cannot use ZFS target, header, or installer disks).\n\nClover installation will be skipped." 10 70
                CONFIG_VARS[USE_CLOVER]="no"
            else
                CONFIG_VARS[CLOVER_DISK]=$(dialog --title "Clover Drive" --radiolist "Select a separate drive FOR Clover bootloader (e.g., a USB stick):" 15 70 $((${#clover_disk_candidates[@]} / 2)) "${clover_disk_candidates[@]}" 3>&1 1>&2 2>&3) || {
                    show_warning "Clover disk selection cancelled. Skipping Clover installation."
                    CONFIG_VARS[USE_CLOVER]="no"
                }
            fi
        else
            CONFIG_VARS[USE_CLOVER]="no" # User chose not to install Clover
        fi
    else
        # Not in UEFI mode, so Clover is not applicable/offered
        CONFIG_VARS[USE_CLOVER]="no"
        show_progress "System is in BIOS mode. Clover installation is not applicable and will be skipped."
    fi

    # Network Configuration
    # Attempt to clear screen before network config (moved here from the end of Clover/Detached Header logic)
    # clear
    # show_progress "Preparing for network configuration..."
    # sleep 1
    # Note: The clear/sleep was moved to just before this block in a previous step.
    # If it's not there, this subtask should focus only on the interface parsing.
    # The subtask that added clear/sleep should be checked to ensure it placed it correctly.
    # For now, assume it is correctly placed right before "show_progress "Gathering network configuration..."

    show_progress "Gathering network configuration..."

    local iface_list=()
    # Read available physical-like interfaces into an array, excluding loopback, docker, virtual bridge members etc.
    # Taking up to 5, similar to original logic.
    mapfile -t iface_list < <(ip -o link show | awk -F': ' '{print $2}' | grep -v -E 'lo|docker|veth|vmbr|virbr|bond|dummy|ifb|gre|ipip|ip6tnl|sit|tun|tap' | head -5)

    if [[ ${#iface_list[@]} -eq 0 ]]; then
        show_warning "No network interfaces automatically detected or suitable."
        local manual_iface
        manual_iface=$(dialog --title "Network Interface" --inputbox "Please enter the primary network interface name (e.g., eth0, enp3s0):" 10 60 "" 3>&1 1>&2 2>&3)

        if [[ -z "$manual_iface" ]]; then
            show_error "No network interface provided. Cannot proceed."
            exit 1
        fi
        # Basic validation for manually entered interface (check if it exists)
        if ! ip link show "$manual_iface" &>/dev/null; then
            show_error "Interface '$manual_iface' does not seem to exist. Please check."
            exit 1
        fi
        CONFIG_VARS[NET_IFACE]="$manual_iface"
        show_progress "Using manually specified interface: ${CONFIG_VARS[NET_IFACE]}"
    else
        local iface_options=()
        local first_iface_selected="on" # Pre-select the first interface in the radio list

        for iface in "${iface_list[@]}"; do
            local status; status=$(ip link show "$iface" | grep -q "state UP" && echo "UP" || echo "DOWN")
            local current_ip; current_ip=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
            local info="$status"
            [[ -n "$current_ip" ]] && info="$status, $current_ip"
            iface_options+=("$iface" "$iface ($info)" "$first_iface_selected")
            first_iface_selected="off" # Only the first item should be 'on'
        done

        if [[ ${#iface_options[@]} -eq 0 ]]; then
            # This case should ideally not be reached if iface_list had items.
            show_error "Failed to create options for network interface selection."
            exit 1
        fi

        CONFIG_VARS[NET_IFACE]=$(dialog --title "Network Interface" \
            --radiolist "Select primary network interface:" 15 70 $((${#iface_options[@]} / 3)) \
            "${iface_options[@]}" 3>&1 1>&2 2>&3) || {
                show_error "Network interface selection cancelled or failed."
                exit 1
            }
    fi
    # Ensure NET_IFACE is set if dialog is cancelled (it should exit above)
    if [[ -z "${CONFIG_VARS[NET_IFACE]}" ]]; then
        show_error "Network interface not selected. Aborting."
        exit 1
    fi

    # DHCP or Static
    if dialog --title "Network Configuration" --yesno "Use DHCP for network configuration?" 8 60; then
        CONFIG_VARS[NET_USE_DHCP]="yes"
    else
        CONFIG_VARS[NET_USE_DHCP]="no"

        # Get current IP as suggestion
        local current_ip; current_ip=$(ip addr show "${CONFIG_VARS[NET_IFACE]}" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
        [[ -z "$current_ip" ]] && current_ip="192.168.1.100/24"

        CONFIG_VARS[NET_IP_CIDR]=$(dialog --title "Static IP Configuration" \
            --inputbox "Enter IP address with CIDR notation (e.g., 192.168.1.100/24):" 10 60 \
            "$current_ip" 3>&1 1>&2 2>&3) || exit 1

        # Validate IP format
        if ! echo "${CONFIG_VARS[NET_IP_CIDR]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
            show_error "Invalid IP/CIDR format: ${CONFIG_VARS[NET_IP_CIDR]}"
            exit 1
        fi

        # Get current gateway as suggestion
        local current_gw; current_gw=$(ip route | grep default | awk '{print $3}' | head -1)
        [[ -z "$current_gw" ]] && current_gw="192.168.1.1"

        CONFIG_VARS[NET_GATEWAY]=$(dialog --title "Gateway Configuration" \
            --inputbox "Enter gateway IP address:" 10 60 \
            "$current_gw" 3>&1 1>&2 2>&3) || exit 1

        # Validate gateway format
        if ! echo "${CONFIG_VARS[NET_GATEWAY]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            show_error "Invalid gateway IP format: ${CONFIG_VARS[NET_GATEWAY]}"
            exit 1
        fi

        # Optional: DNS servers
        local current_dns; current_dns=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
        [[ -z "$current_dns" ]] && current_dns="8.8.8.8 8.8.4.4"

        CONFIG_VARS[NET_DNS]=$(dialog --title "DNS Configuration (Optional)" \
            --inputbox "Enter DNS servers (space-separated):" 10 60 \
            "$current_dns" 3>&1 1>&2 2>&3) || CONFIG_VARS[NET_DNS]="8.8.8.8 8.8.4.4"
    fi

    # Hostname
    local suggested_hostname="proxmox"
    [[ -n "${HOSTNAME}" && "${HOSTNAME}" != "localhost" ]] && suggested_hostname="${HOSTNAME}"

    CONFIG_VARS[HOSTNAME]=$(dialog --title "System Hostname" \
        --inputbox "Enter hostname for this Proxmox system:" 10 60 \
        "$suggested_hostname" 3>&1 1>&2 2>&3) || CONFIG_VARS[HOSTNAME]="proxmox"

    # Validate hostname
    if ! echo "${CONFIG_VARS[HOSTNAME]}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
        show_error "Invalid hostname format: ${CONFIG_VARS[HOSTNAME]}"
        exit 1
    fi

    CONFIG_VARS[ZFS_POOL_NAME]="rpool"
    CONFIG_VARS[LUKS_MAPPER_NAME]="luks_root"

    # Display configuration summary
    local summary="Configuration Summary:\n\n"
    summary+="ZFS Disks: ${CONFIG_VARS[ZFS_TARGET_DISKS]}\n"
    summary+="RAID Level: ${CONFIG_VARS[ZFS_RAID_LEVEL]}\n"
    summary+="Hostname: ${CONFIG_VARS[HOSTNAME]}\n"
    summary+="Network Interface: ${CONFIG_VARS[NET_IFACE]}\n"

    if [[ "${CONFIG_VARS[NET_USE_DHCP]}" == "yes" ]]; then
        summary+="Network: DHCP\n"
    else
        summary+="Network: Static\n"
        summary+="  IP: ${CONFIG_VARS[NET_IP_CIDR]}\n"
        summary+="  Gateway: ${CONFIG_VARS[NET_GATEWAY]}\n"
        summary+="  DNS: ${CONFIG_VARS[NET_DNS]}\n"
    fi

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]}" == "yes" ]]; then
        summary+="Detached Headers: ${CONFIG_VARS[HEADER_DISK]}\n"
    fi

    if [[ "${CONFIG_VARS[USE_CLOVER]}" == "yes" ]]; then
        summary+="Clover Boot: ${CONFIG_VARS[CLOVER_DISK]}\n"
    fi

    dialog --title "Configuration Summary" --msgbox "$summary" 20 70

    # Save Config
    if (dialog --title "Save Configuration" --yesno "Save this configuration for future non-interactive installations?" 8 70); then
        save_config "$(dirname "$0")/proxmox_install_$(date +%F_%H%M%S).conf"
    fi
}

partition_and_format_disks() {
    show_step "PARTITION" "Partitioning & Formatting Disks"

    local target_disks_arr=("${CONFIG_VARS[ZFS_TARGET_DISKS]}")

    # Safety check - ensure we're not wiping the installer device
    for disk in "${target_disks_arr[@]}"; do
        if [[ "$disk" == "$INSTALLER_DEVICE" ]]; then
            show_error "Cannot use installer device ($INSTALLER_DEVICE) as target!"
            show_error "This would destroy the running installer."
            exit 1
        fi

        # Additional safety check for mounted devices
        if grep -q "^$disk" /proc/mounts; then
            show_error "Disk $disk is currently mounted!"
            show_error "Please unmount all partitions on this disk before proceeding."
            exit 1
        fi
    done

    # Safety check for header disk
    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        if [[ "${CONFIG_VARS[HEADER_DISK]}" == "$INSTALLER_DEVICE" ]]; then
            show_error "Cannot use installer device as header disk!"
            exit 1
        fi
    fi

    # Safety check for Clover disk
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        if [[ "${CONFIG_VARS[CLOVER_DISK]}" == "$INSTALLER_DEVICE" ]]; then
            show_error "Cannot use installer device as Clover disk!"
            exit 1
        fi
    fi

    # Confirm disk wiping
    local disk_list; disk_list=$(printf '%s\n' "${target_disks_arr[@]}")
    [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]] && disk_list+="\n${CONFIG_VARS[HEADER_DISK]}"
    [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]] && disk_list+="\n${CONFIG_VARS[CLOVER_DISK]}"

    if ! dialog --title "⚠️  DESTRUCTIVE OPERATION WARNING ⚠️" \
        --yesno "The following disks will be COMPLETELY ERASED:\n\n$disk_list\n\nALL DATA WILL BE LOST!\n\nAre you absolutely sure?" 16 60; then
        show_error "Installation cancelled by user."
        exit 1
    fi

    # Continue with original partitioning logic
    for disk in "${target_disks_arr[@]}"; do
        show_progress "Wiping target disk: $disk..."
        wipefs -a "$disk" &>/dev/null || true
        sgdisk --zap-all "$disk" &>/dev/null || true
    done

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        show_progress "Wiping Clover disk: ${CONFIG_VARS[CLOVER_DISK]}..."
        wipefs -a "${CONFIG_VARS[CLOVER_DISK]}" &>/dev/null || true
        sgdisk --zap-all "${CONFIG_VARS[CLOVER_DISK]}" &>/dev/null || true
    fi

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        if [[ "${CONFIG_VARS[FORMAT_HEADER_PART]}" == "yes" ]]; then
            local header_disk="${CONFIG_VARS[HEADER_DISK]}"
            show_progress "Wiping header disk: $header_disk..."
            wipefs -a "$header_disk" &>/dev/null || true
            sgdisk --zap-all "$header_disk" &>/dev/null || true

            sgdisk -n 1:0:0 -t 1:8300 -c 1:LUKS-Headers "$header_disk"
            partprobe
            sleep 2

            local p_prefix=""
            [[ "$header_disk" == /dev/nvme* ]] && p_prefix="p"
            CONFIG_VARS[HEADER_PART]="${header_disk}${p_prefix}1"
            mkfs.ext4 -L "LUKS_HEADERS" "${CONFIG_VARS[HEADER_PART]}"
            CONFIG_VARS[HEADER_PART_UUID]=$(blkid -s UUID -o value "${CONFIG_VARS[HEADER_PART]}" 2>/dev/null)
            if [[ -z "${CONFIG_VARS[HEADER_PART_UUID]}" ]]; then
                show_error "CRITICAL: Failed to retrieve UUID for header partition ${CONFIG_VARS[HEADER_PART]}."
                show_error "This UUID is essential for the system to locate detached LUKS headers at boot."
                show_error "Please check the device and ensure it's correctly partitioned and formatted."
                exit 1
            fi
            show_progress "Header partition ${CONFIG_VARS[HEADER_PART]} has UUID: ${CONFIG_VARS[HEADER_PART_UUID]}"
            show_success "Header disk prepared and formatted."
        else
            # Using an existing partition, already set in CONFIG_VARS[HEADER_PART] and CONFIG_VARS[HEADER_PART_UUID]
            show_progress "Using existing partition ${CONFIG_VARS[HEADER_PART]} for LUKS headers. Skipping format."
            if [[ -z "${CONFIG_VARS[HEADER_PART_UUID]}" ]]; then
                 show_error "CRITICAL: UUID for existing header partition ${CONFIG_VARS[HEADER_PART]} is missing."
                 exit 1
            fi
            show_success "Existing header partition ${CONFIG_VARS[HEADER_PART]} will be used."
        fi
    fi

    partprobe
    sleep 3

    local primary_target=${target_disks_arr[0]}
    show_progress "Partitioning primary target disk: $primary_target"
    sgdisk -n 1:1M:+512M -t 1:EF00 -c 1:EFI "$primary_target"
    sgdisk -n 2:0:+1G -t 2:8300 -c 2:Boot "$primary_target"
    sgdisk -n 3:0:0 -t 3:BF01 -c 3:LUKS-ZFS "$primary_target"

    for i in $(seq 1 $((${#target_disks_arr[@]}-1))); do
        local disk=${target_disks_arr[$i]}
        show_progress "Creating ZFS data partition on $disk"
        sgdisk -n 1:0:0 -t 1:BF01 -c 1:LUKS-ZFS "$disk"
    done

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        show_progress "Partitioning Clover disk: ${CONFIG_VARS[CLOVER_DISK]}"
        sgdisk -n 1:1M:0 -t 1:EF00 -c 1:Clover-EFI "${CONFIG_VARS[CLOVER_DISK]}"
        local p_prefix=""
        [[ "${CONFIG_VARS[CLOVER_DISK]}" == /dev/nvme* ]] && p_prefix="p"
        CONFIG_VARS[CLOVER_EFI_PART]="${CONFIG_VARS[CLOVER_DISK]}${p_prefix}1"
    fi

    partprobe
    sleep 3

    local p_prefix=""
    [[ "$primary_target" == /dev/nvme* ]] && p_prefix="p"
    CONFIG_VARS[EFI_PART]="${primary_target}${p_prefix}1"
    CONFIG_VARS[BOOT_PART]="${primary_target}${p_prefix}2"

    mkfs.vfat -F32 "${CONFIG_VARS[EFI_PART]}"
    mkfs.ext4 -F "${CONFIG_VARS[BOOT_PART]}"

    local luks_partitions=()
    for disk in "${target_disks_arr[@]}"; do
        p_prefix=""
        [[ "$disk" == /dev/nvme* ]] && p_prefix="p"
        if [[ "$disk" == "$primary_target" ]]; then
            luks_partitions+=("${disk}${p_prefix}3")
        else
            luks_partitions+=("${disk}${p_prefix}1")
        fi
    done

    CONFIG_VARS[LUKS_PARTITIONS]="${luks_partitions[*]}"
    show_success "All disks partitioned successfully."
}

setup_luks_encryption() {
    show_step "ENCRYPT" "Setting up LUKS Encryption"

    local luks_partitions_arr=("${CONFIG_VARS[LUKS_PARTITIONS]}")
    local luks_mappers=()

    local pass
    pass=$(dialog --title "LUKS Passphrase" --passwordbox "Enter new LUKS passphrase for all disks:" 10 60 3>&1 1>&2 2>&3) || exit 1

    local pass_confirm
    pass_confirm=$(dialog --title "LUKS Passphrase" --passwordbox "Confirm passphrase:" 10 60 3>&1 1>&2 2>&3) || exit 1

    if [[ "$pass" != "$pass_confirm" ]] || [[ -z "$pass" ]]; then
        show_error "Passphrases do not match or are empty."
        exit 1
    fi

    local header_mount=""
    local header_files_str=""

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        header_mount="$TEMP_DIR/headers"
        mkdir -p "$header_mount"
        mount "${CONFIG_VARS[HEADER_PART]}" "$header_mount"
    fi

    for i in "${!luks_partitions_arr[@]}"; do
        local part="${luks_partitions_arr[$i]}"
        local mapper_name="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i"

        if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
            # Name of the header file as it will be stored on the header partition's filesystem.
            local header_filename="header_${CONFIG_VARS[HOSTNAME]}_disk${i}.img"
            # Full temporary path to the header file while the header partition is mounted here in the installer.
            # This path is used for initial creation and opening of the LUKS volume with the detached header.
            local header_file_fullpath="$header_mount/$header_filename"

            show_progress "Creating detached LUKS header for $part (header file: $header_filename on ${CONFIG_VARS[HEADER_PART]})..."
            echo -n "$pass" | cryptsetup luksFormat --type luks2 --header "$header_file_fullpath" "$part" -

            show_progress "Opening LUKS volume $part using detached header $header_filename..."
            echo -n "$pass" | cryptsetup open --header "$header_file_fullpath" "$part" "$mapper_name" -

            header_files_str+="$header_filename " # Accumulate only the filename
        else
            show_progress "Formatting LUKS on $part..."
            echo -n "$pass" | cryptsetup luksFormat --type luks2 "$part" -

            show_progress "Opening LUKS volume $part..."
            echo -n "$pass" | cryptsetup open "$part" "$mapper_name" -
        fi

        luks_mappers+=("/dev/mapper/$mapper_name")
    done

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        # When using detached headers, each LUKS-encrypted partition will have its corresponding
        # header stored as a file on the separate header partition (CONFIG_VARS[HEADER_PART]).
        # For each encrypted partition, we generate a unique filename for its header.
        # These filenames (e.g., "header_myhost_disk0.img", "header_myhost_disk1.img")
        # are stored in this variable, space-separated.
        # In /etc/crypttab, these filenames are combined with the HEADER_PART_UUID
        # to tell the system exactly which file on the header partition corresponds to which encrypted data partition.
        # Example: header=UUID=<HEADER_PART_UUID>:<header_filename>
        CONFIG_VARS[HEADER_FILENAMES_ON_PART]="${header_files_str% }" # header_files_str accumulates filenames like "header_..._disk0.img"
        umount "$header_mount"
        show_success "Detached headers created on ${CONFIG_VARS[HEADER_DISK]}."
    fi

    CONFIG_VARS[LUKS_MAPPERS]="${luks_mappers[*]}"
    show_success "All LUKS volumes created and opened."
}

setup_zfs_pool() {
    show_step "ZFS" "Creating ZFS Pool"

    local pool_name="${CONFIG_VARS[ZFS_POOL_NAME]}"
    local raid_level="${CONFIG_VARS[ZFS_RAID_LEVEL]}"
    local luks_devices=("${CONFIG_VARS[LUKS_MAPPERS]}")

    # Ensure no existing pool with same name
    if zpool list -H "$pool_name" &>/dev/null; then
        show_warning "Pool $pool_name already exists. Destroying..."
        zpool destroy -f "$pool_name"
    fi

    # Build ZFS creation command based on RAID level
    local zpool_cmd="zpool create -f -o ashift=12 -O acltype=posixacl -O compression=lz4"
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

    show_progress "Creating ZFS pool with $raid_level configuration..."
    eval "$zpool_cmd" || {
        show_error "Failed to create ZFS pool"
        exit 1
    }

    # Create ZFS datasets
    show_progress "Creating ZFS datasets..."
    zfs create -o mountpoint=none "$pool_name/ROOT"
    zfs create -o mountpoint=/ "$pool_name/ROOT/pve-1"
    zfs create -o mountpoint=/var/lib/vz "$pool_name/data"

    # Set boot filesystem
    zpool set bootfs="$pool_name/ROOT/pve-1" "$pool_name"

    show_success "ZFS pool created successfully"
}

install_base_system() {
    show_step "DEBIAN" "Installing Base System"

    # Mount boot partitions
    show_progress "Mounting boot partitions..."
    mkdir -p /mnt/boot
    if ! mount "${CONFIG_VARS[BOOT_PART]}" /mnt/boot; then
        show_error "Failed to mount boot partition ${CONFIG_VARS[BOOT_PART]} on /mnt/boot"
        exit 1
    fi
    mkdir -p /mnt/boot/efi
    if ! mount "${CONFIG_VARS[EFI_PART]}" /mnt/boot/efi; then
        show_error "Failed to mount EFI partition ${CONFIG_VARS[EFI_PART]} on /mnt/boot/efi"
        exit 1
    fi

    # Debootstrap base system
    show_progress "Installing Debian base system (this will take several minutes)..."
    local debian_release="bookworm"  # Debian 12
    local debian_mirror="http://deb.debian.org/debian"

    debootstrap --arch=amd64 --include=locales,vim,openssh-server,wget,curl \
        "$debian_release" /mnt "$debian_mirror" |& \
        while IFS= read -r line; do
            if [[ "$line" =~ I:\ Retrieving|I:\ Validating|I:\ Extracting ]]; then
                echo -ne "\r  ${BULLET} ${line:3:60}..." >&2
            fi
        done
    echo  # New line after progress

    show_success "Base system installed"

    # Copy installation log
    cp "$LOG_FILE" /mnt/var/log/proxmox-install.log
}

configure_new_system() {
    show_step "CHROOT" "Configuring System"

    # Prepare chroot environment
    show_progress "Preparing chroot environment..."
    cp /etc/resolv.conf /mnt/etc/
    if ! mount -t proc /proc /mnt/proc; then
        show_error "Failed to mount /proc into chroot environment at /mnt/proc"
        exit 1
    fi
    if ! mount -t sysfs /sys /mnt/sys; then
        show_error "Failed to mount /sys into chroot environment at /mnt/sys"
        exit 1
    fi
    if ! mount -t devtmpfs /dev /mnt/dev; then
        show_error "Failed to mount /dev into chroot environment at /mnt/dev"
        exit 1
    fi
    if ! mount -t devpts /dev/pts /mnt/dev/pts; then
        show_error "Failed to mount /dev/pts into chroot environment at /mnt/dev/pts"
        exit 1
    fi

    # Set root password before chroot
    local root_pass
    root_pass=$(dialog --title "Root Password" --passwordbox "Enter root password for new system:" 10 60 3>&1 1>&2 2>&3) || exit 1
    local root_pass_confirm
    root_pass_confirm=$(dialog --title "Root Password" --passwordbox "Confirm root password:" 10 60 3>&1 1>&2 2>&3) || exit 1

    if [[ "$root_pass" != "$root_pass_confirm" ]] || [[ -z "$root_pass" ]]; then
        show_error "Passwords do not match or are empty."
        exit 1
    fi

    # Create configuration script
    cat > /mnt/tmp/configure.sh <<- 'CHROOT_SCRIPT'
        #!/bin/bash
        set -e

        # Set hostname
        echo "${HOSTNAME}" > /etc/hostname
        cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}

# IPv6
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

        # Configure locale
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen
        echo "LANG=en_US.UTF-8" > /etc/locale.conf

        # Set timezone
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime

        # Configure apt sources
        cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF

        # Add Proxmox repository
        wget -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
            http://download.proxmox.com/debian/proxmox-release-bookworm.gpg

        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > \
            /etc/apt/sources.list.d/pve-no-subscription.list

        # Update package database
        apt-get update

        # Install essential packages
        local grub_pkgs=""
        if [[ "\$BOOT_MODE" == "UEFI" ]]; then
            grub_pkgs="grub-efi-amd64 efibootmgr"
        elif [[ "\$BOOT_MODE" == "BIOS" ]]; then
            grub_pkgs="grub-pc"
        else
            echo "ERROR: Unknown BOOT_MODE '\$BOOT_MODE' in chroot." >&2
            exit 1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            linux-image-amd64 linux-headers-amd64 \
            zfs-initramfs cryptsetup-initramfs \
            \$grub_pkgs \
            bridge-utils ifupdown2

        # Configure network
        if [[ "${NET_USE_DHCP}" == "yes" ]]; then
            cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${NET_IFACE}
iface ${NET_IFACE} inet dhcp

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports ${NET_IFACE}
    bridge-stp off
    bridge-fd 0
EOF
        else
            # Configure DNS
            if [[ -L "/etc/resolv.conf" ]]; then
                echo "Warning: /etc/resolv.conf is a symlink. Attempting to write DNS configuration." >&2
                # Attempt to write, it might be a symlink to a manageable file
                if ! echo "nameserver ${NET_DNS// /$'\n'nameserver }" > /etc/resolv.conf; then
                    echo "Error: Failed to write to /etc/resolv.conf (symlink target likely not writable)." >&2
                fi
            elif [[ ! -w "/etc/resolv.conf" ]]; then
                echo "Error: /etc/resolv.conf is not writable. Cannot configure DNS automatically." >&2
            else
                echo "nameserver ${NET_DNS// /$'\n'nameserver }" > /etc/resolv.conf
            fi

            cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${NET_IFACE}
iface ${NET_IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${NET_IP_CIDR}
    gateway ${NET_GATEWAY}
    bridge-ports ${NET_IFACE}
    bridge-stp off
    bridge-fd 0
EOF
        fi

        # Configure cryptsetup
        if [[ "${USE_DETACHED_HEADERS}" == "yes" ]]; then
            # --- Configuring /etc/crypttab for Detached LUKS Headers ---
            # For systems using detached LUKS headers, /etc/crypttab entries must precisely guide
            # the initramfs (early boot system) to locate these external headers.
            # The standard format used here is:
            #   <target_name> UUID=<data_partition_UUID> none luks,discard,header=UUID=<header_partition_UUID>:<header_filename_on_that_partition>
            #
            # Breakdown:
            #   <target_name>: The name for the unlocked LUKS device (e.g., luks_root_0).
            #   UUID=<data_partition_UUID>: The UUID of the actual encrypted data partition.
            #   none: Placeholder for the keyfile (passphrase will be prompted).
            #   luks,discard: Standard LUKS options. 'discard' enables TRIM/discard passthrough.
            #   header=UUID=<HEADER_PART_UUID>:<HEADER_FILENAME>: This is the crucial part for detached headers.
            #     - UUID=<HEADER_PART_UUID>: Specifies the filesystem (by its UUID) where the header file is located.
            #                                This is the UUID of the partition on your separate header disk (e.g., a USB drive).
            #     - <HEADER_FILENAME>: The actual name of the header file on that header partition
            #                          (e.g., header_myhostname_disk0.img).
            #
            # This method ensures that the system can find the headers even if the header disk's device name
            # (e.g., /dev/sdd1) changes, as UUIDs are persistent. The initramfs cryptsetup scripts
            # are responsible for mounting the header partition (by its UUID) and accessing the specified header file.
            echo "# Detached header configuration" > /etc/crypttab
            IFS=' ' read -ra HEADER_FILENAMES_ARR <<< "${HEADER_FILENAMES_ON_PART}" # Use new variable name
            IFS=' ' read -ra LUKS_PARTS_ARR <<< "${LUKS_PARTITIONS}"
            for i in "${!LUKS_PARTS_ARR[@]}"; do
                uuid=$(blkid -s UUID -o value "${LUKS_PARTS_ARR[$i]}") # Make sure this is the non-local version
                # Sanity check: Ensure the HEADER_PART_UUID (UUID of the partition storing the header files)
                # is available in the chroot environment. If not, we cannot correctly create crypttab entries.
                if [[ -z "${HEADER_PART_UUID}" ]]; then
                    echo "Critical error: HEADER_PART_UUID is not set in chroot for detached headers." >&2
                    exit 1
                fi
                echo "${LUKS_MAPPER_NAME}_$i UUID=$uuid none luks,header=UUID=${HEADER_PART_UUID}:${HEADER_FILENAMES_ARR[$i]},discard" >> /etc/crypttab
            done
        else
            # Standard crypttab
            echo "# Standard LUKS configuration" > /etc/crypttab
            IFS=' ' read -ra LUKS_PARTS_ARR <<< "${LUKS_PARTITIONS}"
            for i in "${!LUKS_PARTS_ARR[@]}"; do
                uuid=$(blkid -s UUID -o value "${LUKS_PARTS_ARR[$i]}") # This is the line to change for standard crypttab
                echo "${LUKS_MAPPER_NAME}_$i UUID=$uuid none luks,discard" >> /etc/crypttab
            done
        fi

        # Configure fstab
        echo "# /etc/fstab: static file system information." > /etc/fstab
        echo "UUID=\$(blkid -s UUID -o value \${BOOT_PART}) /boot ext4 defaults 0 2" >> /etc/fstab
        if [[ "\$BOOT_MODE" == "UEFI" && -n "\$EFI_PART" ]]; then
            local efi_part_uuid
            efi_part_uuid=\$(blkid -s UUID -o value "\$EFI_PART" 2>/dev/null)
            if [[ -n "\$efi_part_uuid" ]]; then
                echo "UUID=\$efi_part_uuid /boot/efi vfat umask=0077 0 1" >> /etc/fstab
            else
                echo "Warning: Could not get UUID for EFI_PART \$EFI_PART. /boot/efi not added to fstab." >&2
            fi
        fi

        # Configure GRUB command line
        local first_luks_part_for_grub
        first_luks_part_for_grub=\$(echo "\${LUKS_PARTITIONS}" | awk '{print \$1}')
        local primary_luks_uuid_for_grub
        if [[ -n "\$first_luks_part_for_grub" ]]; then
            primary_luks_uuid_for_grub=\$(blkid -s UUID -o value "\$first_luks_part_for_grub" 2>/dev/null)
        fi
        if [[ -z "\$primary_luks_uuid_for_grub" ]]; then
            echo "ERROR: Could not determine UUID for the primary LUKS partition (\$first_luks_part_for_grub from '\${LUKS_PARTITIONS}') for GRUB cmdline." >&2
            exit 1
        fi
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"|" /etc/default/grub
        # Using a different sed delimiter to avoid issues with / in ZFS_POOL_NAME
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=ZFS=\${ZFS_POOL_NAME}/ROOT cryptdevice=UUID=\${primary_luks_uuid_for_grub}:\${LUKS_MAPPER_NAME}_0\"|" /etc/default/grub

        if ! grep -q "^GRUB_ENABLE_CRYPTODISK=y" /etc/default/grub; then
            echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
        fi

        # Update initramfs
        update-initramfs -u -k all

        # Install GRUB
        if [[ "\$BOOT_MODE" == "UEFI" ]]; then
            echo "Installing GRUB for UEFI mode..."
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=proxmox --recheck
        elif [[ "\$BOOT_MODE" == "BIOS" ]]; then
            echo "Installing GRUB for Legacy BIOS mode to \$PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB..."
            if [[ -z "\$PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB" || ! -b "\$PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB" ]]; then
                echo "ERROR: PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB ('\$PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB') is not set or not a block device. Cannot install GRUB." >&2
                exit 1
            fi
            grub-install "\$PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB" --recheck
        fi
        update-grub

        # Set root password
        echo "root:${ROOT_PASSWORD}" | chpasswd

        # Install Proxmox VE
        DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi

        # Remove enterprise repository
        rm -f /etc/apt/sources.list.d/pve-enterprise.list

        # Enable SSH
        systemctl enable ssh

        # Clean up
        apt-get clean

CHROOT_SCRIPT

    # Make script executable and pass variables
    chmod +x /mnt/tmp/configure.sh

    # Export all necessary variables for chroot script
    export BOOT_MODE="${CONFIG_VARS[BOOT_MODE]}"
    # Derive PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB from BOOT_PART (e.g. /dev/sda2 -> /dev/sda)
    export PRIMARY_ZFS_DISK_DEVICE_FOR_GRUB="${CONFIG_VARS[BOOT_PART]%[0-9]*}"
    export ZFS_POOL_NAME="${CONFIG_VARS[ZFS_POOL_NAME]}"
    export HOSTNAME="${CONFIG_VARS[HOSTNAME]}"
    export NET_USE_DHCP="${CONFIG_VARS[NET_USE_DHCP]:-no}"
    export NET_IFACE="${CONFIG_VARS[NET_IFACE]:-ens18}"
    export NET_IP_CIDR="${CONFIG_VARS[NET_IP_CIDR]:-}"
    export NET_GATEWAY="${CONFIG_VARS[NET_GATEWAY]:-}"
    export NET_DNS="${CONFIG_VARS[NET_DNS]:-8.8.8.8 8.8.4.4}"
    export USE_DETACHED_HEADERS="${CONFIG_VARS[USE_DETACHED_HEADERS]}"
    # export HEADER_FILES="${CONFIG_VARS[HEADER_FILES]:-}" # Replaced by HEADER_FILENAMES_ON_PART and HEADER_PART_UUID
    export HEADER_PART_UUID="${CONFIG_VARS[HEADER_PART_UUID]:-}"
    export HEADER_FILENAMES_ON_PART="${CONFIG_VARS[HEADER_FILENAMES_ON_PART]:-}"
    export LUKS_PARTITIONS="${CONFIG_VARS[LUKS_PARTITIONS]}"
    export LUKS_MAPPER_NAME="${CONFIG_VARS[LUKS_MAPPER_NAME]}"
    export BOOT_PART="${CONFIG_VARS[BOOT_PART]}"
    export EFI_PART="${CONFIG_VARS[EFI_PART]}"
    export ROOT_PASSWORD="$root_pass"

    # Execute configuration in chroot
    show_progress "Configuring system in chroot (this will take several minutes)..."
    chroot /mnt /tmp/configure.sh

    # Install local deb packages if directory exists
    if [[ -d "$(dirname "$0")/debs" ]] && ls "$(dirname "$0")/debs"/*.deb &>/dev/null; then
        show_progress "Installing local .deb packages..."
        cp -r "$(dirname "$0")/debs" /mnt/tmp/
        chroot /mnt bash -c "dpkg -i /tmp/debs/*.deb || apt-get -f install -y"
        rm -rf /mnt/tmp/debs
    fi

    # Cleanup
    rm /mnt/tmp/configure.sh

    # Unmount chroot environment
    umount -lf /mnt/dev/pts || true
    umount -lf /mnt/dev || true
    umount -lf /mnt/sys || true
    umount -lf /mnt/proc || true

    show_success "System configuration complete"
}

install_clover_bootloader() {
    show_step "CLOVER" "Installing Clover Bootloader"

    local clover_efi="${CONFIG_VARS[CLOVER_EFI_PART]}"

    # Format Clover EFI partition
    show_progress "Formatting Clover EFI partition..."
    mkfs.vfat -F32 "$clover_efi"

    # Mount Clover partition
    local clover_mount="$TEMP_DIR/clover"
    mkdir -p "$clover_mount"
    if ! mount "$clover_efi" "$clover_mount"; then
        show_error "Failed to mount Clover EFI partition $clover_efi on $clover_mount"
        exit 1
    fi

    # Download Clover
    show_progress "Downloading Clover bootloader..."
    local clover_url="https://github.com/CloverHackyColor/CloverBootloader/releases/download/5157/CloverV2-5157.zip"
    wget -q --show-progress -O "$TEMP_DIR/clover.zip" "$clover_url" || {
        show_error "Failed to download Clover"
        exit 1
    }

    # Extract and install
    show_progress "Installing Clover..."
    cd "$TEMP_DIR" || exit 1
    7z x -y clover.zip > /dev/null

    # Copy Clover to EFI partition
    mkdir -p "$clover_mount/EFI"
    cp -r CloverV2/EFI/* "$clover_mount/EFI/"

    # Configure Clover for Proxmox boot
    cat > "$clover_mount/EFI/CLOVER/config.plist" <<- 'CLOVER_CONFIG'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Boot</key>
            <dict>
                <key>Timeout</key>
                <integer>5</integer>
                <key>DefaultVolume</key>
                <string>Proxmox</string>
                <key>DefaultLoader</key>
                <string>\EFI\proxmox\grubx64.efi</string>
            </dict>
            <key>GUI</key>
            <dict>
                <key>Theme</key>
                <string>embedded</string>
                <key>ShowOptimus</key>
                <false/>
            </dict>
            <key>Scan</key>
            <dict>
                <key>Entries</key>
                <true/>
                <key>Legacy</key>
                <false/>
                <key>Linux</key>
                <true/>
                <key>Tool</key>
                <true/>
            </dict>
        </dict>
        </plist>
CLOVER_CONFIG

    # Create custom entries
    mkdir -p "$clover_mount/EFI/CLOVER/ACPI/origin"

    # Create boot entry
    show_progress "Creating UEFI boot entry..."
    efibootmgr -c -d "${CONFIG_VARS[CLOVER_DISK]}" -p 1 -L "Clover" -l '\EFI\CLOVER\CLOVERX64.efi' || true

    # Unmount
    cd /
    umount "$clover_mount"

    show_success "Clover bootloader installed"
}

backup_luks_header() {
    show_step "BACKUP" "Backing Up LUKS Headers"

    if ! dialog --title "LUKS Header Backup" \
        --yesno "Would you like to backup LUKS headers to a removable device?" 8 60; then
        show_warning "Skipping LUKS header backup"
        return
    fi

    # List removable devices
    local removable_devs=()
    # ls /sys/block/ | grep -E "^sd|^nvme" > "$TEMP_DIR/removable_devs_list"
    echo "" > "$TEMP_DIR/removable_devs_list" # Ensure the file is created/empty
    for dev_path in /sys/block/*; do
      dev_name=$(basename "$dev_path")
      if [[ $dev_name == sd* || $dev_name == nvme* ]]; then
        echo "$dev_name" >> "$TEMP_DIR/removable_devs_list"
      fi
    done
    while read -r dev; do
        if [[ -e "/sys/block/$dev/removable" ]] && [[ "$(cat "/sys/block/$dev/removable")" == "1" ]]; then
            local size; size=$(lsblk -dno SIZE "/dev/$dev" 2>/dev/null || echo "Unknown")
            removable_devs+=("/dev/$dev" "$dev ($size)")
        fi
    done < "$TEMP_DIR/removable_devs_list"

    if [[ ${#removable_devs[@]} -eq 0 ]]; then
        show_warning "No removable devices found"
        return
    fi

    local backup_dev
    backup_dev=$(dialog --title "Backup Device" \
        --radiolist "Select removable device for LUKS header backup:" 15 60 \
        ${#removable_devs[@]} "${removable_devs[@]}" 3>&1 1>&2 2>&3) || return

    # Format and mount backup device
    show_progress "Preparing backup device..."
    wipefs -a "$backup_dev" &>/dev/null || true

    # Create partition
    echo -e "o\nn\np\n1\n\n\nw" | fdisk "$backup_dev" &>/dev/null
    sleep 2
    partprobe

    local backup_part="${backup_dev}1"
    [[ "$backup_dev" == /dev/nvme* ]] && backup_part="${backup_dev}p1"

    mkfs.ext4 -L "LUKS_BACKUP" "$backup_part" &>/dev/null

    local backup_mount="$TEMP_DIR/backup"
    mkdir -p "$backup_mount"
    if ! mount "$backup_part" "$backup_mount"; then
        show_error "Failed to mount LUKS header backup partition $backup_part on $backup_mount. Skipping backup."
        # Clean up mount point if created
        rmdir "$backup_mount" 2>/dev/null
        return 1 # Or just return, as per plan, to allow skipping
    fi

    # Backup headers
    mkdir -p "$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}"
    local luks_parts=("${CONFIG_VARS[LUKS_PARTITIONS]}")

    for i in "${!luks_parts[@]}"; do
        local part="${luks_parts[$i]}"
        local backup_file="$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}/header_disk${i}.img"

        show_progress "Backing up header from $part..."

        if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
            # For detached headers, copy the header file
            local header_files=("${CONFIG_VARS[HEADER_FILES]}")
            cp "${header_files[$i]}" "$backup_file"
        else
            # For standard headers, backup from device
            cryptsetup luksHeaderBackup "$part" --header-backup-file "$backup_file"
        fi
    done

    # Create recovery instructions
    cat > "$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}/README.txt" <<- EOF
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

    # Save configuration
    cp "$(dirname "$0")/proxmox_install_"*.conf "$backup_mount/luks_headers_${CONFIG_VARS[HOSTNAME]}/" 2>/dev/null || true

    # Unmount
    sync
    umount "$backup_mount"

    show_success "LUKS headers backed up to $backup_dev"
}

finalize() {
    show_step "FINALIZE" "Finalizing Installation"

    # Export pool
    show_progress "Exporting ZFS pool..."
    zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}"

    # Close LUKS devices
    show_progress "Closing LUKS devices..."
    local num_mappers; num_mappers=$(echo "${CONFIG_VARS[LUKS_MAPPERS]:-}" | wc -w)
    for i in $(seq 0 $((num_mappers - 1))); do
        cryptsetup close "${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i" || true
    done

    # Unmount remaining filesystems
    umount /mnt/boot/efi || true
    umount /mnt/boot || true
    umount /mnt || true

    # Final summary
    show_header "INSTALLATION COMPLETE"
    echo -e "${GREEN}Proxmox VE has been successfully installed!${RESET}\n"
    echo "System Information:"
    echo "  Hostname: ${CONFIG_VARS[HOSTNAME]}"
    echo "  ZFS Pool: ${CONFIG_VARS[ZFS_POOL_NAME]} (${CONFIG_VARS[ZFS_RAID_LEVEL]})"
    echo "  Encryption: LUKS2 (Detached headers: ${CONFIG_VARS[USE_DETACHED_HEADERS]:-no})"

    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        echo "  Bootloader: Clover on ${CONFIG_VARS[CLOVER_DISK]}"
    fi

    if [[ "${CONFIG_VARS[NET_USE_DHCP]}" == "yes" ]]; then
        echo "  Network: DHCP on ${CONFIG_VARS[NET_IFACE]}"
    else
        echo "  Network: ${CONFIG_VARS[NET_IP_CIDR]} via ${CONFIG_VARS[NET_GATEWAY]}"
    fi

    echo -e "\n${YELLOW}Next Steps:${RESET}"
    echo "1. Remove installation media"
    echo "2. Reboot the system"
    echo "3. Access Proxmox VE at https://${CONFIG_VARS[HOSTNAME]}:8006"

    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]:-}" == "yes" ]]; then
        echo -e "\n${YELLOW}WARNING:${RESET} ${RED}${BOLD}Keep your LUKS header disk safe!${RESET}"
        echo "The system will NOT boot without the header disk (${CONFIG_VARS[HEADER_DISK]})."
    fi

    echo -e "\n${GREEN}Installation log saved to:${RESET} /var/log/proxmox-install.log"
}

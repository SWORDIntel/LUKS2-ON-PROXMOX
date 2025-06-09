#!/usr/bin/env bash

# ===================================================================
# Proxmox VE All-in-One Installer - Health Checks Module
# ===================================================================

# Import common functions and SMART tools
# shellcheck source=./ui_functions.sh
source "$(dirname "$0")/ui_functions.sh"
# shellcheck source=./smart_tools.sh
source "$(dirname "$0")/smart_tools.sh"

# Main health check function
health_check() {
    local component="$1"
    local exit_on_error="${2:-true}"
    local all_checks_passed=true
    
    log_info "Running health check for: $component"
    
    case "$component" in
        "disks")
            check_disk_health || all_checks_passed=false
            ;;
        "luks")
            check_luks_integrity || all_checks_passed=false
            ;;
        "zfs")
            check_zfs_pool_health || all_checks_passed=false
            ;;
        "system")
            check_system_integrity || all_checks_passed=false
            if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" == "yes" ]]; then
                check_yubikey_zfs_setup || all_checks_passed=false
            fi
            ;;
        "network")
            check_network_connectivity || all_checks_passed=false
            ;;
        "all")
            check_disk_health || all_checks_passed=false
            # Conditionally check LUKS integrity if ZFS native encryption is not primary
            if [[ "${CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]:-no}" != "yes" ]]; then
                check_luks_integrity || all_checks_passed=false
            fi
            check_zfs_pool_health || all_checks_passed=false
            check_system_integrity || all_checks_passed=false
            if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" == "yes" ]]; then
                check_yubikey_zfs_setup || all_checks_passed=false
            fi
            check_network_connectivity || all_checks_passed=false
            ;;
        *)
            log_error "Unknown component: $component"
            return 1
            ;;
    esac
    
    if ! $all_checks_passed && $exit_on_error; then
        log_error "Health check for $component failed. Aborting installation."
        exit 1
    fi
    
    return $all_checks_passed
}

check_yubikey_zfs_setup() {
    log_info "Checking YubiKey ZFS Key Setup..."
    local all_passed=true
    local new_sys_mount="${CONFIG_VARS[NEW_SYSTEM_MOUNT]:-/mnt}" # Default to /mnt if not set

    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" != "yes" ]]; then
        log_info "YubiKey for ZFS Key not enabled, skipping these checks."
        return 0 # True, as the setup is not applicable
    fi

    # Check 1: Verify YubiKey LUKS Key Partition is LUKS formatted
    if [[ -n "${CONFIG_VARS[YUBIKEY_KEY_PART_UUID]}" ]]; then
        local yk_luks_dev_by_uuid="/dev/disk/by-uuid/${CONFIG_VARS[YUBIKEY_KEY_PART_UUID]}"
        if [[ ! -b "$yk_luks_dev_by_uuid" ]]; then
            log_error "YubiKey LUKS key partition device $yk_luks_dev_by_uuid not found."
            all_passed=false
        elif ! cryptsetup isLuks "$yk_luks_dev_by_uuid" &>> "$LOG_FILE"; then
            log_error "YubiKey LUKS key partition $yk_luks_dev_by_uuid is not a valid LUKS device."
            all_passed=false
        else
            log_success "YubiKey LUKS key partition $yk_luks_dev_by_uuid is LUKS formatted."
        fi
    else
        log_error "YUBIKEY_KEY_PART_UUID is not set, cannot check LUKS format for YubiKey key partition."
        all_passed=false
    fi

    # Check 2: Verify /etc/ykzfs/ykzfs.conf on target system
    local ykzfs_conf_path="${new_sys_mount}/etc/ykzfs/ykzfs.conf"
    if [[ ! -f "$ykzfs_conf_path" ]]; then
        log_error "YubiKey ZFS config file $ykzfs_conf_path not found on target system."
        all_passed=false
    else
        log_success "YubiKey ZFS config file $ykzfs_conf_path found."
        # Verify content
        local conf_uuid=$(grep '^YUBIKEY_ZFS_KEY_LUKS_UUID=' "$ykzfs_conf_path" | sed -e 's/.*="//' -e 's/"$//')
        local conf_key_path=$(grep '^ZFS_KEYFILE_RELATIVE_PATH=' "$ykzfs_conf_path" | sed -e 's/.*="//' -e 's/"$//')

        if [[ "$conf_uuid" != "${CONFIG_VARS[YUBIKEY_KEY_PART_UUID]}" ]]; then
            log_error "Mismatch in $ykzfs_conf_path: YUBIKEY_ZFS_KEY_LUKS_UUID is '$conf_uuid', expected '${CONFIG_VARS[YUBIKEY_KEY_PART_UUID]}'."
            all_passed=false
        else
            log_success "$ykzfs_conf_path: YUBIKEY_ZFS_KEY_LUKS_UUID matches."
        fi

        if [[ "$conf_key_path" != "${CONFIG_VARS[ZFS_KEYFILE_PATH_ON_YUBIKEY_LUKS]}" ]]; then
            log_error "Mismatch in $ykzfs_conf_path: ZFS_KEYFILE_RELATIVE_PATH is '$conf_key_path', expected '${CONFIG_VARS[ZFS_KEYFILE_PATH_ON_YUBIKEY_LUKS]}'."
            all_passed=false
        else
            log_success "$ykzfs_conf_path: ZFS_KEYFILE_RELATIVE_PATH matches."
        fi
    fi

    # Check 3: Verify initramfs hook and script files exist and are executable
    local ykzfs_hook_file="${new_sys_mount}/etc/initramfs-tools/hooks/ykzfs_hooks.sh"
    local ykzfs_unlock_script="${new_sys_mount}/etc/initramfs-tools/scripts/local-top/ykzfs_unlock"

    if [[ ! -f "$ykzfs_hook_file" ]]; then
        log_error "Initramfs hook script $ykzfs_hook_file not found."
        all_passed=false
    elif [[ ! -x "$ykzfs_hook_file" ]]; then
        log_error "Initramfs hook script $ykzfs_hook_file is not executable."
        all_passed=false
    else
        log_success "Initramfs hook script $ykzfs_hook_file found and executable."
    fi

    if [[ ! -f "$ykzfs_unlock_script" ]]; then
        log_error "Initramfs unlock script $ykzfs_unlock_script not found."
        all_passed=false
    elif [[ ! -x "$ykzfs_unlock_script" ]]; then
        log_error "Initramfs unlock script $ykzfs_unlock_script is not executable."
        all_passed=false
    else
        log_success "Initramfs unlock script $ykzfs_unlock_script found and executable."
    fi

    return $all_passed
}

# Disk health check with SMART integration
check_disk_health() {
    local all_passed=true
    
    log_info "Checking disk health with SMART diagnostics..."
    
    # Ensure smartmontools is available
    if ! command -v smartctl >/dev/null; then
        log_warning "smartctl not found - attempting to install smartmontools..."
        if ! apt-get update; then
            log_error "Failed to update package repository"
            return 1
        fi
        
        if ! apt-get install -y smartmontools; then
            log_error "Failed to install smartmontools. SMART checks will be skipped."
            return 1
        fi
    fi
    
    # Check each disk in the configuration
    IFS=',' read -ra DISKS <<< "${CONFIG_VARS[TARGET_DISKS]}"
    for disk in "${DISKS[@]}"; do
        log_info "Checking SMART status for $disk"
        
        # For NVMe drives
        if [[ "$disk" == *"nvme"* ]]; then
            run_nvme_smart_check "$disk" || all_passed=false
        else
            # For SATA/SAS drives
            run_smart_check "$disk" || all_passed=false
        fi
    done
    
    return $all_passed
}

# Check LUKS encryption integrity
check_luks_integrity() {
    local all_passed=true
    
    # Get luks device path from config
    local luks_device="${CONFIG_VARS[LUKS_DEVICE]}"
    
    log_info "Checking LUKS integrity for $luks_device"
    
    # Check LUKS header
    if ! cryptsetup isLuks "$luks_device"; then
        log_error "LUKS header check failed for $luks_device"
        all_passed=false
    else
        log_success "LUKS header verification passed for $luks_device"
    fi
    
    # Verify LUKS metadata status
    if ! cryptsetup luksDump "$luks_device" > /dev/null; then
        log_error "LUKS metadata integrity check failed"
        all_passed=false
    else
        log_success "LUKS metadata integrity verified"
    fi
    
    # Check if mapping is active and functional
    local mapped_name="${CONFIG_VARS[LUKS_MAPPED_NAME]}"
    if [[ -n "$mapped_name" ]] && ! cryptsetup status "$mapped_name" > /dev/null; then
        log_error "LUKS device mapping check failed for $mapped_name"
        all_passed=false
    else
        log_success "LUKS device mapping check passed for $mapped_name"
    fi
    
    return $all_passed
}

# Check ZFS pool health
check_zfs_pool_health() {
    local all_passed=true
    local pool_name="${CONFIG_VARS[ZFS_POOL_NAME]}"
    
    log_info "Checking ZFS pool health for $pool_name"
    
    # Check if pool exists
    if ! zpool list -H "$pool_name" > /dev/null 2>&1; then
        log_error "ZFS pool $pool_name doesn't exist"
        all_passed=false
        return $all_passed
    fi
    
    # Check pool status
    local pool_status
    pool_status=$(zpool status -x "$pool_name")
    if [[ "$pool_status" != *"healthy"* && "$pool_status" != *"all pools are healthy"* ]]; then
        log_error "ZFS pool $pool_name is not healthy: $pool_status"
        all_passed=false
    else
        log_success "ZFS pool $pool_name is healthy"
    fi
    
    # Check pool scrub (optional, but good for initial verification)
    if dialog --title "ZFS Health Verification" --yesno "Would you like to perform a scrub on ZFS pool $pool_name to verify data integrity?\n\nThis will take some time but helps ensure your storage is correctly configured." 10 70; then
        zpool scrub "$pool_name"
        log_info "ZFS pool scrub initiated - check 'zpool status' later for results"
        log_success "ZFS scrub started on $pool_name"
    fi
    
    # Test basic filesystem operations
    local test_dir="/mnt/${pool_name}_test"
    mkdir -p "$test_dir"
    if ! mount -t zfs "${pool_name}/ROOT" "$test_dir" 2>/dev/null; then
        log_warning "Could not mount ZFS filesystem for testing (may not exist yet)"
    else
        # Try to write and read a test file
        if echo "ZFS test file" > "$test_dir/test.txt"; then
            log_success "Successfully wrote test file to ZFS filesystem"
            rm "$test_dir/test.txt"
        else
            log_error "Failed to write test file to ZFS filesystem"
            all_passed=false
        fi
        umount "$test_dir"
        rmdir "$test_dir"
    fi
    
    return $all_passed
}

# Check installed system integrity
check_system_integrity() {
    local all_passed=true
    local new_sys_mount="${CONFIG_VARS[NEW_SYSTEM_MOUNT]}"
    
    log_info "Checking system integrity for mount point $new_sys_mount"
    
    # Check if the mount point exists
    if [[ ! -d "$new_sys_mount" ]]; then
        log_error "New system mount point $new_sys_mount doesn't exist"
        all_passed=false
        return $all_passed
    fi
    
    # Check if critical directories exist
    for dir in "/boot" "/etc" "/bin" "/sbin" "/lib" "/usr"; do
        if [[ ! -d "${new_sys_mount}${dir}" ]]; then
            log_error "Critical directory missing: ${dir}"
            all_passed=false
        else
            log_success "Critical directory exists: ${dir}"
        fi
    done
    
    # Check if kernel was installed
    if ! ls "${new_sys_mount}/boot/vmlinuz-"* >/dev/null 2>&1; then
        log_error "No kernel found in ${new_sys_mount}/boot/"
        all_passed=false
    else
        log_success "Kernel found in ${new_sys_mount}/boot/"
    fi
    
    # Check if initramfs was created
    if ! ls "${new_sys_mount}/boot/initrd.img-"* >/dev/null 2>&1; then
        log_error "No initramfs found in ${new_sys_mount}/boot/"
        all_passed=false
    else
        log_success "Initramfs found in ${new_sys_mount}/boot/"
    fi
    
    # Check for critical configuration files
    for conf_file in "/etc/fstab" "/etc/crypttab" "/etc/default/grub"; do
        if [[ ! -f "${new_sys_mount}${conf_file}" ]]; then
            log_error "Critical config file missing: ${conf_file}"
            all_passed=false
        else
            log_success "Critical config file exists: ${conf_file}"
        fi
    done
    
    return $all_passed
}

# Check network connectivity
check_network_connectivity() {
    local all_passed=true
    local interface="${CONFIG_VARS[NETWORK_INTERFACE]}"
    local ip="${CONFIG_VARS[IP_ADDRESS]}"
    
    log_info "Checking network connectivity for interface $interface"
    
    # Check if interface exists
    if [[ ! -d "/sys/class/net/$interface" ]]; then
        log_error "Network interface $interface does not exist"
        all_passed=false
        return $all_passed
    fi
    
    # Check if interface is up
    if ! ip link show "$interface" | grep -q "UP"; then
        log_error "Network interface $interface is down"
        all_passed=false
    else
        log_success "Network interface $interface is up"
    fi
    
    # Check if IP is assigned
    if ! ip addr show "$interface" | grep -q "$ip"; then
        log_warning "IP address $ip is not assigned to $interface"
    else
        log_success "IP address $ip is assigned to $interface"
    fi
    
    # Test internet connectivity
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_success "Internet connectivity test passed"
    else
        log_warning "Internet connectivity test failed"
        # Not marking as failure, might be intentional in an air-gapped setup
    fi
    
    return $all_passed
}

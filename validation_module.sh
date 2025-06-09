#!/usr/bin/env bash

# ===================================================================
# Proxmox VE All-in-One Installer - Validation Module
# ===================================================================

# Import common functions
# shellcheck source=./ui_functions.sh
source "$(dirname "$0")/ui_functions.sh"

# Main validation function
validate_installation() {
    log_info "Starting validation mode - no changes will be made"
    
    local all_validations_passed=true
    
    # Run validation functions
    validate_system_requirements || all_validations_passed=false
    validate_disk_configuration || all_validations_passed=false
    validate_network_configuration || all_validations_passed=false
    validate_zfs_configuration || all_validations_passed=false
    validate_luks_configuration || all_validations_passed=false
    validate_boot_configuration || all_validations_passed=false
    
    # Generate report
    generate_validation_report "$all_validations_passed"
    
    return $all_validations_passed
}

validate_system_requirements() {
    local all_checks_passed=true
    
    log_info "Validating system requirements..."
    
    # CPU virtualization support
    if grep -qE 'svm|vmx' /proc/cpuinfo; then
        log_success "CPU virtualization extensions detected"
    else
        log_error "CPU virtualization extensions not detected"
        all_checks_passed=false
    fi
    
    # RAM check
    local total_mem_kb
    local total_mem_mb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_mem_mb=$((total_mem_kb / 1024))
    if (( total_mem_mb >= MIN_RAM_MB )); then
        log_success "System has ${total_mem_mb}MB RAM (minimum ${MIN_RAM_MB}MB required)"
    else
        log_error "System has only ${total_mem_mb}MB RAM (minimum ${MIN_RAM_MB}MB required)"
        all_checks_passed=false
    fi
    
    # Check for other required software
    for cmd in cryptsetup zpool zfs awk; do
        if command -v "$cmd" >/dev/null; then
            log_success "Required command '$cmd' is available"
        else
            log_error "Required command '$cmd' is not available"
            all_checks_passed=false
        fi
    done
    
    return $all_checks_passed
}

validate_disk_configuration() {
    local all_checks_passed=true
    
    log_info "Validating disk configuration..."
    
    # Check if disk configuration exists
    if [[ -z "${CONFIG_VARS[TARGET_DISKS]:-}" ]]; then
        log_error "No target disks specified in configuration"
        all_checks_passed=false
        return $all_checks_passed
    fi
    
    # Check disk existence
    IFS=',' read -ra DISKS <<< "${CONFIG_VARS[TARGET_DISKS]}"
    for disk in "${DISKS[@]}"; do
        if [[ -b "$disk" ]]; then
            log_success "Disk $disk exists"
        else
            log_error "Disk $disk doesn't exist"
            all_checks_passed=false
        fi
    done
    
    # Check disk sizes
    for disk in "${DISKS[@]}"; do
        # Skip if disk doesn't exist
        [[ ! -b "$disk" ]] && continue
        
        local size_bytes
        local size_gb
        size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null)
        size_gb=$((size_bytes / 1024 / 1024 / 1024))
        
        if (( size_gb < MIN_DISK_GB )); then
            log_error "Disk $disk is only ${size_gb}GB (minimum ${MIN_DISK_GB}GB required)"
            all_checks_passed=false
        else
            log_success "Disk $disk size (${size_gb}GB) meets requirements"
        fi
    done
    
    # Check if disks are in use
    for disk in "${DISKS[@]}"; do
        # Skip if disk doesn't exist
        [[ ! -b "$disk" ]] && continue
        
        if grep -q "^$disk" /proc/mounts; then
            log_error "Disk $disk is currently mounted and in use"
            all_checks_passed=false
        else
            log_success "Disk $disk is not currently mounted"
        fi
    done
    
    return $all_checks_passed
}

validate_network_configuration() {
    local all_checks_passed=true
    
    log_info "Validating network configuration..."
    
    # Check if network configuration exists
    if [[ -z "${CONFIG_VARS[NETWORK_INTERFACE]:-}" ]]; then
        log_error "No network interface specified in configuration"
        all_checks_passed=false
        return $all_checks_passed
    fi
    
    # Check if interface exists
    local interface="${CONFIG_VARS[NETWORK_INTERFACE]}"
    if [[ -d "/sys/class/net/$interface" ]]; then
        log_success "Network interface $interface exists"
    else
        log_error "Network interface $interface does not exist"
        all_checks_passed=false
    fi
    
    # Check IP address format
    local ip="${CONFIG_VARS[IP_ADDRESS]:-}"
    if [[ -z "$ip" ]]; then
        log_error "No IP address specified in configuration"
        all_checks_passed=false
    elif [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_success "IP address $ip has valid format"
    else
        log_error "IP address $ip has invalid format"
        all_checks_passed=false
    fi
    
    # Check subnet mask
    local netmask="${CONFIG_VARS[NETMASK]:-}"
    if [[ -z "$netmask" ]]; then
        log_error "No netmask specified in configuration"
        all_checks_passed=false
    elif [[ "$netmask" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_success "Netmask $netmask has valid format"
    else
        log_error "Netmask $netmask has invalid format"
        all_checks_passed=false
    fi
    
    # Check gateway
    local gateway="${CONFIG_VARS[GATEWAY]:-}"
    if [[ -z "$gateway" ]]; then
        log_error "No gateway specified in configuration"
        all_checks_passed=false
    elif [[ "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_success "Gateway $gateway has valid format"
    else
        log_error "Gateway $gateway has invalid format"
        all_checks_passed=false
    fi
    
    return $all_checks_passed
}

validate_zfs_configuration() {
    local all_checks_passed=true
    
    log_info "Validating ZFS configuration..."
    
    # Check if ZFS pool name is specified
    if [[ -z "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        log_error "No ZFS pool name specified in configuration"
        all_checks_passed=false
    else
        log_success "ZFS pool name is specified: ${CONFIG_VARS[ZFS_POOL_NAME]}"
    fi
    
    # Check if ZFS pool type is valid
    local pool_type="${CONFIG_VARS[ZFS_POOL_TYPE]:-}"
    if [[ -z "$pool_type" ]]; then
        log_error "No ZFS pool type specified in configuration"
        all_checks_passed=false
    elif [[ "$pool_type" =~ ^(mirror|raidz1|raidz2|stripe)$ ]]; then
        log_success "ZFS pool type $pool_type is valid"
    else
        log_error "ZFS pool type $pool_type is invalid"
        all_checks_passed=false
    fi
    
    # Check if ZFS modules are loaded
    if lsmod | grep -q "^zfs"; then
        log_success "ZFS kernel modules are loaded"
    else
        log_warning "ZFS kernel modules are not loaded"
        # Not a failure, might be loaded later during installation
    fi
    
    return $all_checks_passed
}

validate_luks_configuration() {
    local all_checks_passed=true
    
    log_info "Validating LUKS configuration..."
    
    # Check if LUKS is enabled
    if [[ "${CONFIG_VARS[USE_LUKS]:-}" != "yes" ]]; then
        log_info "LUKS encryption is not enabled, skipping validation"
        return $all_checks_passed
    fi
    
    # Check if LUKS device is specified
    if [[ -z "${CONFIG_VARS[LUKS_DEVICE]:-}" ]]; then
        log_error "No LUKS device specified in configuration"
        all_checks_passed=false
    else
        log_success "LUKS device is specified: ${CONFIG_VARS[LUKS_DEVICE]}"
    fi
    
    # Check if LUKS mapped name is specified
    if [[ -z "${CONFIG_VARS[LUKS_MAPPED_NAME]:-}" ]]; then
        log_error "No LUKS mapped name specified in configuration"
        all_checks_passed=false
    else
        log_success "LUKS mapped name is specified: ${CONFIG_VARS[LUKS_MAPPED_NAME]}"
    fi
    
    # Check if cryptsetup is installed
    if command -v cryptsetup >/dev/null; then
        log_success "cryptsetup command is available"
        
        # Check cryptsetup version
        local version
        version=$(cryptsetup --version | awk '{print $2}')
        if [[ $(echo "$version" | cut -d. -f1) -ge 2 ]]; then
            log_success "cryptsetup version $version supports LUKS2"
        else
            log_warning "cryptsetup version $version may not fully support LUKS2"
        fi
    else
        log_error "cryptsetup command is not available"
        all_checks_passed=false
    fi
    
    return $all_checks_passed
}

validate_boot_configuration() {
    local all_checks_passed=true
    
    log_info "Validating boot configuration..."
    
    # Check if Clover is enabled
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        log_info "Clover bootloader is enabled, validating configuration"
        
        # Check if Clover device is specified
        if [[ -z "${CONFIG_VARS[CLOVER_DEVICE]:-}" ]]; then
            log_error "No Clover device specified in configuration"
            all_checks_passed=false
        else
            log_success "Clover device is specified: ${CONFIG_VARS[CLOVER_DEVICE]}"
            
            # Check if Clover device exists
            if [[ -b "${CONFIG_VARS[CLOVER_DEVICE]}" ]]; then
                log_success "Clover device exists"
            else
                log_error "Clover device doesn't exist"
                all_checks_passed=false
            fi
        fi
        
        # Check for Clover ISO/zip files
        if [[ -f "$SCRIPT_DIR/Clover-5161-X64.iso.7z" ]] || [[ -f "$SCRIPT_DIR/CloverV2-5161.zip" ]]; then
            log_success "Clover bootloader files exist"
        else
            log_error "Clover bootloader files are missing"
            all_checks_passed=false
        fi
    else
        log_info "Clover bootloader is not enabled, using standard boot configuration"
        
        # Check if boot device is specified when not using Clover
        if [[ -z "${CONFIG_VARS[BOOT_DEVICE]:-}" ]]; then
            log_error "No boot device specified in configuration"
            all_checks_passed=false
        else
            log_success "Boot device is specified: ${CONFIG_VARS[BOOT_DEVICE]}"
            
            # Check if boot device exists
            if [[ -b "${CONFIG_VARS[BOOT_DEVICE]}" ]]; then
                log_success "Boot device exists"
            else
                log_error "Boot device doesn't exist"
                all_checks_passed=false
            fi
        fi
    fi
    
    return $all_checks_passed
}

generate_validation_report() {
    local validation_passed="$1"
    local report_file
    report_file="$SCRIPT_DIR/validation_report_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Generating validation report at $report_file"
    
    # Create report header
    {
        echo "==== Proxmox VE Installer Validation Report ===="
        echo "Date: $(date)"
        echo "Configuration file: ${CONFIG_FILE_PATH:-"Not specified (using interactive mode)"}"
        echo ""
        echo "Overall validation result: $([ "$validation_passed" == "true" ] && echo "PASSED" || echo "FAILED")"
        echo ""
        echo "=== System Requirements ==="
        echo "CPU virtualization: $(grep -qE 'svm|vmx' /proc/cpuinfo && echo "Detected" || echo "Not detected")"
        
        local total_mem_kb
        local total_mem_mb
        total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        total_mem_mb=$((total_mem_kb / 1024))
        echo "RAM: ${total_mem_mb}MB (minimum ${MIN_RAM_MB}MB required)"
        
        echo ""
        echo "=== Disk Configuration ==="
        IFS=',' read -ra DISKS <<< "${CONFIG_VARS[TARGET_DISKS]:-}"
        for disk in "${DISKS[@]}"; do
            if [[ -b "$disk" ]]; then
                local size_bytes
                local size_gb
                size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null)
                size_gb=$((size_bytes / 1024 / 1024 / 1024))
                echo "Disk $disk: ${size_gb}GB, exists: YES"
            else
                echo "Disk $disk: exists: NO"
            fi
        done
        
        echo ""
        echo "=== Network Configuration ==="
        echo "Interface: ${CONFIG_VARS[NETWORK_INTERFACE]:-"Not specified"}"
        echo "IP Address: ${CONFIG_VARS[IP_ADDRESS]:-"Not specified"}"
        echo "Netmask: ${CONFIG_VARS[NETMASK]:-"Not specified"}"
        echo "Gateway: ${CONFIG_VARS[GATEWAY]:-"Not specified"}"
        
        echo ""
        echo "=== ZFS Configuration ==="
        echo "Pool name: ${CONFIG_VARS[ZFS_POOL_NAME]:-"Not specified"}"
        echo "Pool type: ${CONFIG_VARS[ZFS_POOL_TYPE]:-"Not specified"}"
        
        echo ""
        echo "=== LUKS Configuration ==="
        echo "LUKS encryption: ${CONFIG_VARS[USE_LUKS]:-"Not enabled"}"
        if [[ "${CONFIG_VARS[USE_LUKS]:-}" == "yes" ]]; then
            echo "LUKS device: ${CONFIG_VARS[LUKS_DEVICE]:-"Not specified"}"
            echo "LUKS mapped name: ${CONFIG_VARS[LUKS_MAPPED_NAME]:-"Not specified"}"
        fi
        
        echo ""
        echo "=== Boot Configuration ==="
        echo "Clover bootloader: ${CONFIG_VARS[USE_CLOVER]:-"Not enabled"}"
        if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
            echo "Clover device: ${CONFIG_VARS[CLOVER_DEVICE]:-"Not specified"}"
        else
            echo "Boot device: ${CONFIG_VARS[BOOT_DEVICE]:-"Not specified"}"
        fi
    } > "$report_file"
    
    # Display report to user
    echo "--- Validation Report Start ---"
    cat "$report_file"
    echo "--- Validation Report End ---"
    show_message "Report Generated" "Validation report saved to $report_file. Press Enter to continue." && read -r
}

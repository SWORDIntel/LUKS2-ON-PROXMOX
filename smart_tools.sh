#!/usr/bin/env bash

# ===================================================================
# Proxmox VE All-in-One Installer - SMART Disk Tools Module
# ===================================================================

# Import common functions
# shellcheck source=./ui_functions.sh
source "$(dirname "$0")/ui_functions.sh"

# Run SMART check on SATA/SAS drives
run_smart_check() {
    local disk="$1"
    local all_passed=true
    
    log_info "Running SMART check on $disk"
    
    # Check if disk supports SMART
    if ! smartctl -i "$disk" | grep -q "SMART support is: Enabled"; then
        log_warning "SMART not enabled or supported on $disk"
        return 0  # Not a failure, just can't check
    fi
    
    # Run SMART self-test
    if prompt_yes_no "SMART Quick Test: Would you like to run a SMART short self-test on $disk?"; then
        log_info "Running SMART short self-test on $disk"
        smartctl -t short "$disk"
        
        # Wait for test completion (typically 2 minutes or less)
        show_message "SMART Test Running" "SMART short test is running on $disk. Please wait..."
        sleep 120
        
        # Read test results
        local result
        result=$(smartctl -l selftest "$disk")
        if echo "$result" | grep -q "Completed without error"; then
            log_success "SMART self-test passed for $disk"
        else
            log_error "SMART self-test failed or had errors for $disk"
            all_passed=false
        fi
    fi
    
    # Check SMART overall health
    local health
    health=$(smartctl -H "$disk")
    if echo "$health" | grep -q "PASSED"; then
        log_success "SMART overall health check: PASSED for $disk"
    else
        log_error "SMART overall health check: FAILED for $disk"
        all_passed=false
    fi
    
    # Check for pending sectors
    local pending_sectors
    pending_sectors=$(smartctl -A "$disk" | grep -E "Current_Pending_Sector|Reallocated_Sector_Ct")
    if echo "$pending_sectors" | grep -q "[1-9]"; then
        log_error "Disk $disk has pending or reallocated sectors: $pending_sectors"
        all_passed=false
    else
        log_success "No pending sectors found on $disk"
    fi
    
    return $all_passed
}

# Run SMART check on NVMe drives
run_nvme_smart_check() {
    local nvme_drive="$1"
    local all_passed=true
    
    log_info "Running NVMe SMART check on $nvme_drive"
    
    # Ensure nvme-cli is available
    if ! command -v nvme >/dev/null; then
        log_warning "nvme-cli not found - attempting to install..."
        if ! apt-get update; then
            log_error "Failed to update package repository"
            return 1
        fi
        
        if ! apt-get install -y nvme-cli; then
            log_error "Failed to install nvme-cli. NVMe checks will be skipped."
            return 1
        fi
    fi
    
    # Get SMART health log
    local health_log
    health_log=$(nvme smart-log "$nvme_drive")
    
    # Check critical warnings
    local critical_warnings
    critical_warnings=$(echo "$health_log" | grep "critical_warning" | awk '{print $3}')
    if [[ "$critical_warnings" == "0" ]]; then
        log_success "NVMe critical warnings: None for $nvme_drive"
    else
        log_error "NVMe critical warnings detected for $nvme_drive: $critical_warnings"
        all_passed=false
    fi
    
    # Check media errors
    local media_errors
    media_errors=$(echo "$health_log" | grep "media_errors" | awk '{print $3}')
    if [[ "$media_errors" == "0" ]]; then
        log_success "NVMe media errors: None for $nvme_drive"
    else
        log_error "NVMe media errors detected for $nvme_drive: $media_errors"
        all_passed=false
    fi
    
    # Check temperature
    local temperature
    temperature=$(echo "$health_log" | grep "temperature" | head -1 | awk '{print $3}')
    if (( temperature < 70 )); then
        log_success "NVMe temperature is acceptable: ${temperature}°C for $nvme_drive"
    else
        log_warning "NVMe temperature is high: ${temperature}°C for $nvme_drive"
    fi
    
    # Check drive life remaining
    local percentage_used
    percentage_used=$(echo "$health_log" | grep "percentage_used" | awk '{print $3}')
    if [[ -n "$percentage_used" ]]; then
        local life_remaining=$((100 - percentage_used))
        if (( life_remaining > 30 )); then
            log_success "NVMe life remaining: ${life_remaining}% for $nvme_drive"
        else
            log_warning "NVMe drive nearing end of life: ${life_remaining}% remaining for $nvme_drive"
            if (( life_remaining < 10 )); then
                log_error "NVMe drive critically low life: ${life_remaining}% remaining for $nvme_drive"
                all_passed=false
            fi
        fi
    fi
    
    return $all_passed
}

#!/usr/bin/env bash
# ===================================================================
# Proxmox VE All-in-One Advanced Installer (v6.2-AUDITED)
# ===================================================================
# Description:
# A comprehensive, TUI-driven utility for creating a secure, redundant
# Proxmox VE setup with ZFS on LUKS2. It is perfected for complex
# scenarios, such as installing onto non-bootable NVMe drives by
# seamlessly installing the Clover bootloader to a separate device.
#
# Features:
# - Pivots to RAM to allow installation on the boot media.
# - TUI for ZFS pool creation (Mirror, RAID-Z1, RAID-Z2).
# - Standard on-disk or detached LUKS2 encryption with confirmation.
# - Optional integrated Clover bootloader installation for legacy hardware.
# - Robust network configuration with intelligent IP/gateway suggestions.
# - Installs local .deb packages from a 'debs' subdirectory if present.
# - Guided LUKS header backup to a separate device.
# - Save/Load configuration file for non-interactive deployments.
#
# Author: Gemini/Enhanced
# Version: 6.2-AUDITED
# --- Strict Mode & Globals ---
set -o errexit
set -o nounset
set -o pipefail

# --- Script Directory and Log File Definition ---
# Best effort to find script directory, even if symlinked
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )" && SCRIPT_DIR="$PWD"
# Define LOG_FILE using SCRIPT_DIR
LOG_FILE="$SCRIPT_DIR/proxmox_aio_install_$(date +%Y%m%d_%H%M%S).log"
export LOG_FILE # Export for use in sourced scripts and child processes

# Initialize log file with a header
echo "Proxmox AIO Installer v6.2-AUDITED - Debug Log Started: $(date)" > "$LOG_FILE"
echo "Installer script directory: $SCRIPT_DIR" >> "$LOG_FILE"
echo "Log file initialized at: $LOG_FILE" >> "$LOG_FILE"


if [ -z "$BASH_VERSION" ] || [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires Bash version 4.3 or newer." >&2
    # Also log to file if possible
    echo "Error: This script requires Bash version 4.3 or newer." >> "$LOG_FILE"
    exit 1
fi

# --- Formatting & Style ---
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly RED='\e[91m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly GREEN='\e[92m'
source ./ui_functions.sh
source ./package_management.sh
source ./network_config.sh
source ./ramdisk_setup.sh
source ./preflight_checks.sh
source ./core_logic.sh # Contains init_environment, gather_user_options, etc.
source ./disk_operations.sh
source ./encryption_logic.sh
source ./zfs_logic.sh
source ./system_config.sh
source ./bootloader_logic.sh
source ./clover_bootloader.sh
source ./health_checks.sh
# validation_module.sh is assumed if --validate is used.
# source ./validation_module.sh

# --- Global Variables ---
RAMDISK_MNT="/mnt/ramdisk"
declare -A CONFIG_VARS # Association array to hold all config

# Safely detect the installer device with fallbacks and validation
if ! INSTALL_SOURCE=$(findmnt -n -o SOURCE --target / 2>/dev/null); then
    echo "Warning: Could not determine source device. Using fallback method." >&2
    # Try a different approach if findmnt fails
    INSTALL_SOURCE=$(mount | grep ' / ' | cut -d' ' -f1)
    
    # If still empty, use a safe default
    if [[ -z "$INSTALL_SOURCE" ]]; then
        echo "Warning: Using /dev/sda as fallback installer device" >&2
        INSTALL_SOURCE="/dev/sda1"
    fi
fi

# Normalize device path - handle both /dev/sdX and potentially unusual formats
if [[ "$INSTALL_SOURCE" == /dev/disk/by-* || "$INSTALL_SOURCE" == /dev/id/* ]]; then
    # For unusual device paths, try to resolve to standard device
    REAL_DEVICE=$(readlink -f "$INSTALL_SOURCE" 2>/dev/null)
    if [[ -n "$REAL_DEVICE" ]]; then
        INSTALLER_DEVICE=${REAL_DEVICE%[0-9]*} # Strip partition numbers
    else
        # If readlink fails, at least strip partition number
        INSTALLER_DEVICE=${INSTALL_SOURCE%[0-9]*}
    fi
else
    # Standard device path handling
    INSTALLER_DEVICE=${INSTALL_SOURCE%[0-9]*} # Strip partition numbers
fi

# Extra validation and logging
if [[ ! -b "$INSTALLER_DEVICE" ]]; then
    echo "Warning: Installer device '$INSTALLER_DEVICE' is not a valid block device." >&2
    # Continue anyway - the script will warn again later if needed
fi

export INSTALLER_DEVICE
echo "Detected installer device: $INSTALLER_DEVICE" >> "$LOG_FILE"
readonly MIN_RAM_MB=4096
readonly MIN_DISK_GB=8

# The sequence of core installation steps.
run_installation_logic() {
    log_debug "Entering function: run_installation_logic"
    # Load config or gather user options.
    if [[ -n "${CONFIG_FILE_PATH:-}" ]]; then
        load_config "$CONFIG_FILE_PATH"
    else
        clear
        gather_user_options
    fi

    partition_and_format_disks
    health_check "disks" true
    
    setup_luks_encryption
    health_check "luks" true
    
    setup_zfs_pool
    health_check "zfs" true
    
    install_base_system
    
    configure_new_system
    health_check "system" true
    
    # Optional components
    if [[ "${CONFIG_VARS[USE_CLOVER]:-no}" == "yes" ]]; then
        install_enhanced_clover_bootloader # Corrected function name
    fi
    if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" == "yes" ]]; then
        # The YubiKey setup happens within setup_luks_encryption or system_config
        log_debug "YubiKey setup is handled within encryption and chroot stages."
    fi

    backup_luks_header
    finalize
    
    health_check "all" false
}

main() {
    # Default settings - will be overridden by CLI flags or config file
    local validate_only=false
    local config_file=""
    local run_from_ram=false
    local no_ram_boot=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --run-from-ram)
                run_from_ram=true
                log_debug "Argument: --run-from-ram detected"
                shift
                ;;
            --config)
                config_file="$2"
                log_debug "Argument: --config detected with value: $config_file"
                shift 2
                ;;
            --no-ram-boot)
                no_ram_boot=true
                log_debug "Argument: --no-ram-boot detected"
                shift
                ;;
            --validate)
                validate_only=true
                log_debug "Argument: --validate detected"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--config <file>] [--no-ram-boot] [--validate] [--run-from-ram]"
                echo "Options:"
                echo "  --config <file>   : Use specified config file for automated installation"
                echo "  --no-ram-boot     : Skip RAM environment pivot (not recommended)"
                echo "  --validate        : Run in validation mode only (no changes made)"
                echo "  --run-from-ram    : Internal use - indicates script is running from RAM"
                echo "  --help, -h        : Show this help message"
                exit 0
                ;;
            *) show_error "Unknown option: '$1'" "$(basename "$0")" "$LINENO" && exit 1 ;;
        esac
    done
    export CONFIG_FILE_PATH="$config_file"
    
    # Initialize environment (creates temp dirs, sets traps)
    init_environment

    # Install dependencies early to ensure dialog and other tools are available
    ensure_essential_packages
    
    # Handle validation mode first as it doesn't require RAM pivot
    if [[ "$validate_only" == true ]]; then
        log_debug "Validation mode detected, running validation checks only"
        # Source the validation module specifically for this mode
        source ./validation_module.sh
        show_header "VALIDATION MODE"
        ensure_network_connectivity || show_warning "Network connectivity issues may affect validation"
        validate_installation
        log_debug "Validation completed, exiting..."
        exit 0
    fi
    
    # --- MAIN EXECUTION FLOW ---

    if [[ "$run_from_ram" == true ]]; then
        # We are now running inside the RAM disk.
        log_debug "Execution environment: In RAM disk."
        show_header "SYSTEM RUNNING FROM RAM"
        
        # 1. Configure network. This is the first step that needs it.
        ensure_network_connectivity || show_warning "Could not establish network connection. Some features may fail."

        # 2. Run the main installation logic.
        run_installation_logic
    
    else
        # We are on the original boot media. We need to prepare and pivot.
        log_debug "Execution environment: Original boot media."
        
        # 1. Pre-flight checks are essential before we do anything.
        run_system_preflight_checks

        # 2. Handle the --no-ram-boot edge case.
        if [[ "$no_ram_boot" == true ]]; then
            show_header "DIRECT INSTALLATION (NO RAM PIVOT)"
            show_warning "This is a DANGEROUS mode. The installer device ($INSTALLER_DEVICE) cannot be used as a target."
            if ! dialog --title "Confirm Dangerous Operation" --yesno "You have selected --no-ram-boot. This prevents installing to the boot media. Are you sure you want to proceed?" 10 70; then
                exit 1
            fi
            # Set up network and run installation directly.
            ensure_network_connectivity || show_warning "Could not establish network connection."
            run_installation_logic
        else
            # 3. Standard path: Pivot to RAM.
            # This function handles everything: creating the RAM disk, copying files,
            # and re-executing this script with the --run-from-ram flag.
            prepare_and_pivot_to_ram
        fi
    fi
    
    log_debug "Main execution flow complete."
}

# Start execution
log_debug "--- Proxmox AIO Installer execution started ---"
main "$@"
log_debug "--- Proxmox AIO Installer execution finished ---"

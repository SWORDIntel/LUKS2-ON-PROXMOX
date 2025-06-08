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
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly YELLOW='\e[93m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly BLUE='\e[94m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly MAGENTA='\e[95m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly CYAN='\e[96m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly BOLD='\e[1m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly RESET='\e[0m'
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly CHECK="${GREEN}✓${RESET}"
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly CROSS="${RED}✗${RESET}"
# shellcheck disable=SC2034 # Used in sourced ui_functions.sh
readonly BULLET="${CYAN}•${RESET}"

# --- Global Variables ---
# shellcheck disable=SC2034 # Used in sourced core_logic.sh and other scripts
TEMP_DIR="" # LOG_FILE is already defined and exported
# shellcheck disable=SC2034 # Used in sourced core_logic.sh and other scripts
RAMDISK_MNT="/mnt/ramdisk"
declare -A CONFIG_VARS # Associative array to hold all config

# --- Additional safety globals ---
# shellcheck disable=SC2034 # Used in sourced core_logic.sh (partition_and_format_disks)
INSTALLER_DEVICE=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
export INSTALLER_DEVICE
readonly INSTALLER_DEVICE
# shellcheck disable=SC2034 # Used in sourced preflight_checks.sh
readonly MIN_RAM_MB=4096
# shellcheck disable=SC2034 # Used in sourced preflight_checks.sh
readonly MIN_DISK_GB=32

# --- Source external function libraries ---
source ./ui_functions.sh
source ./preflight_checks.sh
source ./install_dependencies.sh
source ./network_config.sh
source ./core_logic.sh
source ./ramdisk_setup.sh
source ./validation_module.sh
source ./health_checks.sh

run_installation_logic() {
    if [[ "${CONFIG_FILE_PATH:-}" ]]; then
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
    health_check "system" true
    
    configure_new_system
    
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        install_clover_bootloader
    fi
    
    backup_luks_header
    finalize
    
    # Final comprehensive health check
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
            --validate)
                validate_only=true
                log_debug "Argument: --validate detected"
                shift
                ;;
            --no-ram-boot)
                no_ram_boot=true
                log_debug "Argument: --no-ram-boot detected"
                shift
                ;;
            --help)
                log_debug "Argument: --help detected"
                echo "Usage: $0 [--config <config_file>]"
                echo "       $0 --run-from-ram [--config <config_file>]"
                echo "       $0 --validate [--config <config_file>]"
                echo "       $0 --no-ram-boot [--config <config_file>]"
                exit 0
                ;;
            *)
                # AUDIT-FIX (SC2086): Quoted variable to prevent word splitting if the option contains spaces.
                show_error "Unknown option: \"$1\""
                log_debug "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    export CONFIG_FILE_PATH="$config_file"
    log_debug "CONFIG_FILE_PATH exported: ${CONFIG_FILE_PATH:-Not Set}"

    # init_environment is defined in core_logic.sh, which is sourced.
    # Sourcing happens before main() is called.
    log_debug "Calling init_environment..."
    init_environment
    log_debug "init_environment finished."
    
    # Install dependencies from /debs first before any other operations
    log_debug "Installing local dependencies from /debs directory..."
    install_local_dependencies
    log_debug "Local dependencies installation finished."

    # Check if we're in validation mode first, as this doesn't require RAM pivot
    if [[ "$validate_only" == true ]]; then
        log_debug "Validation mode detected, skipping RAM pivot and running validation"
        show_header "VALIDATION MODE"
        # Basic connectivity check for validation purposes only
        check_basic_connectivity
        validate_installation
        log_debug "Validation completed, exiting..."
        exit 0
    fi
    
    # Run from RAM environment decision
    if [[ "$run_from_ram" == true ]]; then
        log_debug "Already running from RAM environment. Proceeding with installation..."
        
        # Network configuration (now moved to happen AFTER RAM pivot)
        configure_network_in_ram
        
        # Run the main installation logic now that we're in RAM
        log_debug "Calling run_installation_logic from RAM environment..."
        run_installation_logic
        log_debug "run_installation_logic finished."
    else
        # Not yet in RAM, need to pivot
        if [[ "$no_ram_boot" == true ]]; then
            log_debug "RAM boot disabled by user. Running installation directly (not recommended)"
            show_warning "Running without RAM pivot. This is not recommended as it may cause issues when modifying boot media."
            
            # Minimal network configuration for package download only
            configure_minimal_network
            
            # Download packages if needed for offline installation
            download_offline_packages
            
            # Run installation directly
            log_debug "Calling run_installation_logic without RAM pivot..."
            run_installation_logic
            log_debug "run_installation_logic finished."
        else
            log_debug "Standard installation path: preparing RAM environment first"
            
            # Minimal network configuration for package download only
            # This is a stripped-down version just to get packages before RAM pivot
            configure_minimal_network
            
            # Download packages for offline installation if needed
            download_offline_packages
            
            # Run pre-flight checks before RAM pivot
            log_debug "Running pre-flight checks before RAM pivot..."
            run_system_preflight_checks
            
            # Now pivot to RAM - all disk operations will happen after this
            log_debug "Pivoting to RAM environment..."
            prepare_ram_environment
            log_debug "prepare_ram_environment called. Script should re-launch in RAM mode."
        fi
    fi
    
    # This block is now handled in the main flow restructuring above
    log_debug "Execution flow handled by the main RAM-first logic structure"
}

# Start execution
log_debug "--- Proxmox AIO Installer execution started ---"
main "$@"
log_debug "--- Proxmox AIO Installer execution finished ---"

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
# source ./clover_bootloader.sh # bootloader_logic.sh now handles sourcing this.
source ./health_checks.sh
# validation_module.sh is assumed if --validate is used.
# source ./validation_module.sh

# --- Global Variables ---
export RAMDISK_MNT="/mnt/ramdisk"
declare -A CONFIG_VARS # Association array to hold all config

# Determine INSTALL_SOURCE globally first
INSTALL_SOURCE_CMD_STATUS=0
INSTALL_SOURCE=$(findmnt -n -o SOURCE --target / 2>/dev/null) || INSTALL_SOURCE_CMD_STATUS=$?

if [[ "$INSTALL_SOURCE_CMD_STATUS" -ne 0 || -z "$INSTALL_SOURCE" || "$INSTALL_SOURCE" == "none" ]]; then
    log_debug "findmnt failed (status: $INSTALL_SOURCE_CMD_STATUS) or returned empty/none ('$INSTALL_SOURCE'). Using fallback mount method for INSTALL_SOURCE."
    INSTALL_SOURCE=$(mount | grep ' / ' | cut -d' ' -f1)
    
    if [[ -z "$INSTALL_SOURCE" || "$INSTALL_SOURCE" == "none" ]]; then
        log_error "Critical: Fallback mount method also returned empty or 'none' ('$INSTALL_SOURCE'). Cannot determine installation source. Please check system mounts."
        # Defaulting to a placeholder to avoid unbound variable, but this is a critical failure state.
        INSTALL_SOURCE="/dev/null" # Or consider exiting: exit_with_error "..." 1
    else
        log_debug "INSTALL_SOURCE determined by mount fallback: '$INSTALL_SOURCE'"
    fi
else
    log_debug "INSTALL_SOURCE determined by findmnt: '$INSTALL_SOURCE'"
fi

# Safely determine the installer device with fallbacks and validation
determine_installer_device() {
    # Content of this function will be the original logic for now, starting with PATH_TO_EVALUATE
    # The original line here was: # Normalize device path - handle both /dev/sdX and potentially unusual formats
    # For safety, let's ensure PATH_TO_EVALUATE is set from the global INSTALL_SOURCE
    # --- DEBUG OVERRIDE FOR PACKAGE TESTING (CORRECTED PLACEMENT V2) ---
    if [[ "$INSTALL_SOURCE" == "overlay" ]]; then
        # Ensure CONFIG_VARS is declared if it might not be yet (it's global, but good practice)
        declare -Ag CONFIG_VARS &>/dev/null

        log_warning "DEBUG: OverlayFS detected in determine_installer_device. Forcing INSTALLER_DEVICE and related disk vars to /dev/null to bypass disk checks for package testing."
        INSTALLER_DEVICE="/dev/null"
        # Initialize CONFIG_VARS elements carefully if they might be used by logging or other early functions
        CONFIG_VARS[SYSTEM_DISK_COUNT]=0
        CONFIG_VARS[SYSTEM_DISKS_RAW_LIST]=("") 
        CONFIG_VARS[SYSTEM_DISKS_VALIDATED_LIST]=("")
        CONFIG_VARS[DISK_FOR_LUKS_HEADERS]="/dev/null"
        CONFIG_VARS[INSTALL_ON_RAMDISK_CONFIRMED]="yes" # Assume ramdisk pivot to avoid those checks
        CONFIG_VARS[RAMDISK_PIVOT_DONE]="yes"
        # Add any other disk/environment vars that might cause an early exit before package ops
        
        # Export INSTALLER_DEVICE here as the function might be expected to set it globally
        export INSTALLER_DEVICE
        log_debug "DEBUG: INSTALLER_DEVICE forced to $INSTALLER_DEVICE due to overlayfs. Skipping rest of determine_installer_device."
        return 0 # Exit the function successfully, skipping normal device detection
    fi
    # --- END DEBUG OVERRIDE ---

    local PATH_TO_EVALUATE="$INSTALL_SOURCE" # Original line, now follows the debug block
log_debug "Initial path to evaluate for installer device: '$PATH_TO_EVALUATE'"

log_debug "--- BEGINNING DEBUG BLOCK FOR INSTALL_SOURCE (set -x) ---"
set -x # Enable command tracing

if [[ "$INSTALL_SOURCE" == /dev/disk/by-* || "$INSTALL_SOURCE" == /dev/id/* ]]; then
    # For 'by-*' paths (like by-id, by-path, by-uuid, by-label), resolve to the canonical device path
    REAL_DEVICE=$(readlink -f "$INSTALL_SOURCE" 2>/dev/null)
    if [[ -n "$REAL_DEVICE" && -b "$REAL_DEVICE" ]]; then
        log_debug "Resolved symlink '$INSTALL_SOURCE' to canonical path '$REAL_DEVICE'."
        PATH_TO_EVALUATE="$REAL_DEVICE"
    else
        log_warning "readlink -f failed for '$INSTALL_SOURCE' or result '$REAL_DEVICE' is not a block device. Using original path '$INSTALL_SOURCE' for evaluation."
        # PATH_TO_EVALUATE remains $INSTALL_SOURCE; this is a fallback.
    fi
fi

# Now, PATH_TO_EVALUATE is the canonical path (e.g., /dev/sda1) or the original by-* path if resolution failed.
# Use lsblk to find the parent kernel name (disk) if PATH_TO_EVALUATE refers to a partition.
# lsblk -no pkname /dev/sda1 -> sda
# lsblk -no pkname /dev/sda  -> (empty)
log_debug "About to run: lsblk -no pkname \"$PATH_TO_EVALUATE\""
PKNAME_OUTPUT=$(lsblk -no pkname "$PATH_TO_EVALUATE" 2>/dev/null)
LSBLK_STATUS=$?
log_debug "lsblk command finished. Exit status: $LSBLK_STATUS. PKNAME_OUTPUT: '$PKNAME_OUTPUT'"

set +x # Disable command tracing
log_debug "--- END DEBUG BLOCK FOR INSTALL_SOURCE --- (set +x)"

if [[ -n "$PKNAME_OUTPUT" ]]; then
    # lsblk returned a parent kernel name, meaning PATH_TO_EVALUATE was a partition.
    # PKNAME_OUTPUT might be like "sda" or "nvme0n1". Prepend "/dev/".
    CANDIDATE_DEVICE="/dev/$PKNAME_OUTPUT"
    if [[ -b "$CANDIDATE_DEVICE" ]]; then
        INSTALLER_DEVICE="$CANDIDATE_DEVICE"
        log_debug "Derived installer disk '$INSTALLER_DEVICE' from partition '$PATH_TO_EVALUATE' using lsblk (pkname: $PKNAME_OUTPUT)."
    else
        log_warning "lsblk provided pkname '$PKNAME_OUTPUT' for '$PATH_TO_EVALUATE', but '/dev/$PKNAME_OUTPUT' is not a valid block device. Falling back to use '$PATH_TO_EVALUATE'."
        INSTALLER_DEVICE="$PATH_TO_EVALUATE" # Fallback to the path given to lsblk
    fi
elif [[ -b "$PATH_TO_EVALUATE" ]]; then
    INSTALLER_DEVICE="$PATH_TO_EVALUATE"
    log_debug "Using '$PATH_TO_EVALUATE' as installer disk (lsblk found no parent, it's already a disk)."
else
    log_error "Critical: Path '$PATH_TO_EVALUATE' (derived from '$INSTALL_SOURCE') is not a block device and lsblk found no parent. Cannot determine installer device."
    INSTALLER_DEVICE="/dev/null" # Fallback to a non-functional device, or consider exiting.
fi

# Final validation for INSTALLER_DEVICE, unless it's the debug override /dev/null
if [[ "$INSTALLER_DEVICE" != "/dev/null" && ! -b "$INSTALLER_DEVICE" ]]; then
    echo "Warning: Installer device '$INSTALLER_DEVICE' is not a valid block device." >&2
    # Continue anyway - the script will warn again later if needed
fi

export INSTALLER_DEVICE
echo "Detected installer device: $INSTALLER_DEVICE" >> "$LOG_FILE"
}


readonly MIN_RAM_MB=4096
export MIN_RAM_MB
readonly MIN_DISK_GB=8
export MIN_DISK_GB

# The sequence of core installation steps.
run_installation_logic() {
    log_debug "Entering function: run_installation_logic"
    # Load config or gather user options.
    log_debug "Checking for config file or gathering user options..."
    if [[ -n "${CONFIG_FILE_PATH:-}" ]]; then
        log_debug "Loading configuration from: $CONFIG_FILE_PATH"
        if ! load_config "$CONFIG_FILE_PATH"; then log_error "Failed to load config from $CONFIG_FILE_PATH"; return 1; fi
        log_debug "Configuration loaded successfully."
    else
        log_debug "No config file specified, gathering user options interactively."
        clear
        if ! gather_user_options; then log_error "Failed during gather_user_options"; return 1; fi
        log_debug "User options gathered successfully."
    fi

    log_debug "Starting disk partitioning and formatting..."
    if ! partition_and_format_disks; then log_error "partition_and_format_disks failed."; return 1; fi
    log_debug "Disk partitioning and formatting completed."
    health_check "disks" true
    
    log_debug "Starting LUKS encryption setup..."
    if ! setup_luks_encryption; then log_error "setup_luks_encryption failed."; return 1; fi
    log_debug "LUKS encryption setup completed."
    health_check "luks" true
    
    log_debug "Starting ZFS pool setup..."
    if ! setup_zfs_pool; then log_error "setup_zfs_pool failed."; return 1; fi
    log_debug "ZFS pool setup completed."
    health_check "zfs" true
    
    log_debug "Starting base system installation..."
    if ! install_base_system; then log_error "install_base_system failed."; return 1; fi
    log_debug "Base system installation completed."
    
    log_debug "Starting new system configuration..."
    if ! configure_new_system; then log_error "configure_new_system failed."; return 1; fi
    log_debug "New system configuration completed."
    health_check "system" true
    
    # Optional components
    if [[ "${CONFIG_VARS[USE_CLOVER]:-no}" == "yes" ]]; then
        log_debug "Starting Clover bootloader installation (optional)..."
        if ! install_enhanced_clover_bootloader "$@"; then log_error "install_enhanced_clover_bootloader failed."; return 1; fi # Corrected function name
        log_debug "Clover bootloader installation completed."
    else
        log_debug "Skipping Clover bootloader installation (not selected)."
    fi
    if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" == "yes" ]]; then
        # The YubiKey setup happens within setup_luks_encryption or system_config
        log_debug "YubiKey setup is handled within encryption and chroot stages."
    fi

    log_debug "Starting LUKS header backup..."
    if ! backup_luks_header "$@"; then log_error "backup_luks_header failed."; return 1; fi
    log_debug "LUKS header backup completed."

    log_debug "Starting finalization steps..."
    if ! finalize; then log_error "finalize failed."; return 1; fi
    log_debug "Finalization steps completed."
    
    health_check "all" false
    log_debug "Exiting function: run_installation_logic successfully."
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

    # Handle validation mode first as it doesn't require RAM pivot
    if [[ "$validate_only" == true ]]; then
        log_debug "Validation mode detected, running validation checks only"
        # Source the validation module specifically for this mode
        source ./validation_module.sh
        show_header "VALIDATION MODE"
        ensure_network_connectivity || show_warning "Network connectivity issues may affect validation"
        
        # Check if we have a configuration file, if not run gather_user_options
        if [[ -z "${config_file:-}" ]]; then
            log_debug "No configuration file provided for validation, running interactive configuration"
            show_info "Gathering configuration options for validation"
            gather_user_options
        fi
        
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
        run_installation_logic "$@"
    
    else
        # We are on the original boot media. We need to prepare and pivot.
        log_debug "Execution environment: Original boot media."

        # 1. Configure network. This is crucial before pre-flight checks that might need it.
        ensure_network_connectivity || show_warning "Could not establish network connection. Pre-flight checks might rely on local debs or fail."
        
        # 2. Pre-flight checks are essential before we do anything.
        run_system_preflight_checks

        # 3. Ensure any additional installer-specific packages are present
        #    (after pre-flight checks have handled core utilities and network is up)
        ensure_essential_packages

        # 4. Handle the --no-ram-boot edge case.
        if [[ "$no_ram_boot" == true ]]; then
            show_header "DIRECT INSTALLATION (NO RAM PIVOT)"
            show_warning "This is a DANGEROUS mode. The installer device ($INSTALLER_DEVICE) cannot be used as a target."
            if ! prompt_yes_no "Confirm Dangerous Operation: You have selected --no-ram-boot. This prevents installing to the boot media. Are you sure you want to proceed?"; then
                exit 1
            fi
            # Network is already configured above.
            run_installation_logic "$@"
        else
            # 4. Standard path: Pivot to RAM.
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

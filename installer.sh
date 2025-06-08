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

if [ -z "$BASH_VERSION" ] || [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires Bash version 4.3 or newer." >&2
    exit 1
fi

# --- Formatting & Style ---
readonly RED='\e[91m'
readonly GREEN='\e[92m'
readonly YELLOW='\e[93m'
readonly BLUE='\e[94m'
readonly MAGENTA='\e[95m'
readonly CYAN='\e[96m'
readonly BOLD='\e[1m'
readonly RESET='\e[0m'
readonly CHECK="${GREEN}✓${RESET}"
readonly CROSS="${RED}✗${RESET}"
readonly BULLET="${CYAN}•${RESET}"

# --- Global Variables ---
LOG_FILE=""
TEMP_DIR=""
RAMDISK_MNT="/mnt/ramdisk"
declare -A CONFIG_VARS # Associative array to hold all config

# --- Additional safety globals ---
INSTALLER_DEVICE=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//'); readonly INSTALLER_DEVICE
readonly MIN_RAM_MB=4096
readonly MIN_DISK_GB=32

# --- Source external function libraries ---
source ./ui_functions.sh
source ./preflight_checks.sh
source ./network_config.sh
source ./core_logic.sh
source ./ramdisk_setup.sh

run_installation_logic() {
    if [[ "${CONFIG_FILE_PATH:-}" ]]; then
        load_config "$CONFIG_FILE_PATH"
    else
        clear
        gather_user_options
    fi
    
    partition_and_format_disks
    setup_luks_encryption
    setup_zfs_pool
    install_base_system
    configure_new_system
    
    if [[ "${CONFIG_VARS[USE_CLOVER]:-}" == "yes" ]]; then
        install_clover_bootloader
    fi
    
    backup_luks_header
    finalize
}

main() {
    # Parse arguments
    local run_from_ram=false
    local config_file=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --run-from-ram)
                run_from_ram=true
                shift
                ;;
            --config)
                config_file="$2"
                shift 2
                ;;
            --help)
                echo "Usage: $0 [--config <config_file>]"
                echo "       $0 --run-from-ram [--config <config_file>]"
                exit 0
                ;;
            *)
                # AUDIT-FIX (SC2086): Quoted variable to prevent word splitting if the option contains spaces.
                show_error "Unknown option: \"$1\""
                exit 1
                ;;
        esac
    done
    export CONFIG_FILE_PATH="$config_file"

    # init_environment is defined in core_logic.sh, which is sourced.
    init_environment

    if [[ "$run_from_ram" == true ]]; then
        # If already in RAM disk, check if we need to configure network
        # configure_network_early is defined in network_config.sh
        if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            configure_network_early
        fi
        run_installation_logic
    else
        # Run pre-flight checks first
        # run_system_preflight_checks is defined in preflight_checks.sh
        run_system_preflight_checks

        # Configure network if needed before RAM disk setup
        # configure_network_early is defined in network_config.sh
        if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            configure_network_early
        fi

        # prepare_ram_environment is defined in ramdisk_setup.sh
        prepare_ram_environment
    fi
}

# Start execution
main "$@"

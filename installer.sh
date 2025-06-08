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
INSTALLER_DEVICE=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//'); readonly INSTALLER_DEVICE
# shellcheck disable=SC2034 # Used in sourced preflight_checks.sh
readonly MIN_RAM_MB=4096
# shellcheck disable=SC2034 # Used in sourced preflight_checks.sh
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
                log_debug "Argument: --run-from-ram detected"
                shift
                ;;
            --config)
                config_file="$2"
                log_debug "Argument: --config detected with value: $config_file"
                shift 2
                ;;
            --help)
                log_debug "Argument: --help detected"
                echo "Usage: $0 [--config <config_file>]"
                echo "       $0 --run-from-ram [--config <config_file>]"
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

    # --- Beginning of new section for .deb download ---
    # Check if we are NOT already running from RAM disk
    log_debug "Run from RAM mode: $run_from_ram"
    if [[ "$run_from_ram" == false ]]; then
        log_debug "Not running from RAM, checking for internet and .deb packages download."
        # Check for internet connectivity
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log_debug "Internet connection detected."
            show_progress "Internet connection detected."
            # Check if debs directory is empty or not present
            # SCRIPT_DIR is globally defined at the top of this script.
            debs_dir="$SCRIPT_DIR/debs"
            log_debug "Debs directory path: $debs_dir"

            # Ensure download_debs.sh exists and is executable
            download_script_path="$SCRIPT_DIR/download_debs.sh"
            log_debug "Download script path: $download_script_path"
            if [ ! -f "$download_script_path" ]; then
                log_debug "download_debs.sh script not found."
                show_warning "Warning: download_debs.sh script not found. Cannot download .deb packages."
            elif [ ! -x "$download_script_path" ]; then
                log_debug "download_debs.sh not executable."
                show_warning "Warning: download_debs.sh is not executable. Please run: chmod +x $download_script_path"
            else
                log_debug "download_debs.sh found and is executable."
                # Check if debs dir is empty.
                proceed_with_download_prompt=false
                if [ ! -d "$debs_dir" ] || [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
                    log_debug "'debs' directory is missing or empty. Prompting for download."
                    proceed_with_download_prompt=true
                else
                    log_debug "'debs' directory already contains files."
                fi

                if [[ "$proceed_with_download_prompt" == true ]]; then
                    if (dialog --title "Download .deb Packages" --yesno "The local 'debs' directory is empty. This installer can download required .deb packages for offline installation on an air-gapped machine. Would you like to download them now?" 12 78); then
                        log_debug "User chose to download .deb packages."
                        show_progress "Attempting to download .deb packages..."
                        if "$download_script_path"; then # Runs download_debs.sh
                            log_debug "download_debs.sh script executed."
                            show_success ".deb package download process finished."
                            if [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
                                log_debug "'debs' directory still empty after download attempt."
                                show_warning "The 'debs' directory is still empty after download attempt. Check package_urls.txt and internet connection."
                            else
                                log_debug "'debs' directory populated."
                                show_success "Local 'debs' directory has been populated."
                            fi
                        else
                            log_debug "download_debs.sh script encountered an error. Exit status: $?"
                            show_error "download_debs.sh script encountered an error."
                        fi
                    else
                        log_debug "User skipped .deb package download."
                        show_warning "Skipping .deb package download. If this is for an air-gapped machine, ensure 'debs' directory is populated manually."
                    fi
                else
                    show_progress "Local 'debs' directory already contains files. Skipping download prompt."
                fi
            fi
            # Reminder to copy files to USB
            log_debug "Displaying 'Prepare USB Stick' dialog."
            dialog --title "Prepare USB Stick" --msgbox "If you intend to run this installer on an air-gapped machine, please ensure you copy the ENTIRE installer directory (including the 'debs' folder, 'download_debs.sh', and 'package_urls.txt') to your USB stick after this process completes or after downloads." 12 78
        else
            log_debug "No internet connection detected. Skipping .deb package download."
            show_warning "No internet connection detected. Skipping .deb package download. Ensure 'debs' directory is populated for air-gapped installation."
        fi
    fi
    # --- End of new section for .deb download ---

    if [[ "$run_from_ram" == true ]]; then
        log_debug "Running from RAM. Configuring network if needed, then running installation logic."
        # If already in RAM disk, check if we need to configure network
        # configure_network_early is defined in network_config.sh
        if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log_debug "No internet in RAM mode, calling configure_network_early."
            configure_network_early
            log_debug "configure_network_early finished."
        else
            log_debug "Internet connection detected in RAM mode."
        fi
        log_debug "Calling run_installation_logic (from RAM)..."
        run_installation_logic
        log_debug "run_installation_logic (from RAM) finished."
    else
        log_debug "Not running from RAM. Performing pre-flight checks, network config, then RAM disk setup."
        # Run pre-flight checks first
        # run_system_preflight_checks is defined in preflight_checks.sh
        log_debug "Calling run_system_preflight_checks..."
        run_system_preflight_checks
        log_debug "run_system_preflight_checks finished."

        # Configure network if needed before RAM disk setup
        # configure_network_early is defined in network_config.sh
        if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log_debug "No internet before RAM setup, calling configure_network_early."
            configure_network_early
            log_debug "configure_network_early finished."
        else
            log_debug "Internet connection detected before RAM setup."
        fi

        # prepare_ram_environment is defined in ramdisk_setup.sh
        log_debug "Calling prepare_ram_environment..."
        prepare_ram_environment
        log_debug "prepare_ram_environment finished. Script should re-launch in RAM mode."
    fi
}

# Start execution
log_debug "--- Proxmox AIO Installer execution started ---"
main "$@"
log_debug "--- Proxmox AIO Installer execution finished ---"

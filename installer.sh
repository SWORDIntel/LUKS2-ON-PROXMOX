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

    # --- Beginning of new section for .deb download ---
    # Check if we are NOT already running from RAM disk
    if [[ "$run_from_ram" == false ]]; then
        # Check for internet connectivity
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            show_progress "Internet connection detected."
            # Check if debs directory is empty or not present
            # script_dir is not defined here yet, let's define it or use relative path
            current_script_dir=$(dirname "$(readlink -f "$0")")
            debs_dir="$current_script_dir/debs"

            # Ensure download_debs.sh exists and is executable
            download_script_path="$current_script_dir/download_debs.sh"
            if [ ! -f "$download_script_path" ]; then
                show_warning "Warning: download_debs.sh script not found. Cannot download .deb packages."
            elif [ ! -x "$download_script_path" ]; then
                show_warning "Warning: download_debs.sh is not executable. Please run: chmod +x $download_script_path"
            else
                # Check if debs dir is empty.
                # download_debs.sh will handle missing or empty package_urls.txt
                proceed_with_download_prompt=false
                if [ ! -d "$debs_dir" ] || [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
                    proceed_with_download_prompt=true
                fi

                if [[ "$proceed_with_download_prompt" == true ]]; then
                    if (dialog --title "Download .deb Packages" --yesno "The local 'debs' directory is empty. This installer can download required .deb packages for offline installation on an air-gapped machine. Would you like to download them now?" 12 78); then
                        show_progress "Attempting to download .deb packages..."
                        if "$download_script_path"; then # Runs download_debs.sh
                            show_success ".deb package download process finished."
                            if [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
                                show_warning "The 'debs' directory is still empty after download attempt. Check package_urls.txt and internet connection."
                            else
                                show_success "Local 'debs' directory has been populated."
                            fi
                        else
                            show_error "download_debs.sh script encountered an error."
                        fi
                    else
                        show_warning "Skipping .deb package download. If this is for an air-gapped machine, ensure 'debs' directory is populated manually."
                    fi
                else
                    show_progress "Local 'debs' directory already contains files. Skipping download prompt."
                fi
            fi
            # Reminder to copy files to USB
            dialog --title "Prepare USB Stick" --msgbox "If you intend to run this installer on an air-gapped machine, please ensure you copy the ENTIRE installer directory (including the 'debs' folder, 'download_debs.sh', and 'package_urls.txt') to your USB stick after this process completes or after downloads." 12 78
        else
            show_warning "No internet connection detected. Skipping .deb package download. Ensure 'debs' directory is populated for air-gapped installation."
        fi
    fi
    # --- End of new section for .deb download ---

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

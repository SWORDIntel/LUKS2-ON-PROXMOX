#!/usr/bin/env bash

# preflight_checks.sh - FAILSAFE VERSION
# Simplified preflight checks with plain text UI

# Source simplified UI functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=ui_functions.sh
source "${SCRIPT_DIR}/ui_functions.sh" || { printf "Critical Error: Failed to source ui_functions.sh in preflight_checks.sh. Exiting.\n" >&2; exit 1; }

# --- Global Variables for Preflight Checks ---
CORE_UTILS=(bash awk grep sed mktemp lsblk id uname readlink parted ip ping gdisk cryptsetup debootstrap mkfs.vfat mkfs.ext4 blkid cp curl wget jq rsync dhclient lsusb)
declare -A CMD_TO_PKG_MAP=(
    [mkfs.vfat]="dosfstools" [mkfs.ext4]="e2fsprogs" [dhclient]="isc-dhcp-client"
    [jq]="jq" [zfs]="zfsutils-linux" [zpool]="zfsutils-linux"
    [cryptsetup]="cryptsetup-bin" [debootstrap]="debootstrap" [wget]="wget" [curl]="curl"
    [gdisk]="gdisk" [rsync]="rsync" [yubikey-luks-enroll]="yubikey-luks"
    [lsusb]="usbutils" [dialog]="dialog"
    [grub-install]="grub-pc" [update-grub]="grub-pc" # grub-pc often provides both, or is a dep
    # dialog is now included as a core utility for preflight checks.
)
CURRENTLY_MISSING_CMDS=() # Array to hold currently missing commands
PREFLIGHT_LOCAL_DEBS_PATH="${SCRIPT_DIR}/local_installer_debs_cache" # Default path, can be overridden by CONFIG_VARS if specific functions check for it

# Associative array for configuration variables, primarily for PREFLIGHT_CHECKS_OVERRIDDEN
# This should be populated by a config file or main script if needed.
# For standalone use, it will be empty, and override will default to false.
declare -A CONFIG_VARS

_configure_proxmox_apt_sources_and_pinning() {
    log_debug "Entering _configure_proxmox_apt_sources_and_pinning in preflight_checks.sh."
    if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
        log_info "Proxmox environment detected. Triggering Proxmox APT configuration from package_management.sh..."
        if type _ensure_proxmox_apt_configuration &>/dev/null; then
            if _ensure_proxmox_apt_configuration; then
                log_success "Proxmox APT configuration (_ensure_proxmox_apt_configuration) completed successfully."
            else
                log_error "_ensure_proxmox_apt_configuration reported errors. APT updates might fail. Status: $?"
                # Not returning error from here, allow preflight to continue and potentially report specific apt failures.
            fi
        else
            log_error "Critical: _ensure_proxmox_apt_configuration function not found. Proxmox APT setup cannot proceed from preflight_checks.sh."
            show_error "Internal Error: Proxmox APT setup function missing."
            # This is a significant issue, but preflight might still try to proceed with potentially broken sources.
        fi
    else
        log_debug "Proxmox environment not detected. Skipping Proxmox-specific APT source configuration in preflight."
    fi
    return 0
}


# --- Helper Functions for Package Installation ---

_get_missing_essential_commands() {
    log_debug "Helper: Checking for essential commands..."
    CURRENTLY_MISSING_CMDS=() # Reset
    for cmd_name in "${CORE_UTILS[@]}"; do
        if ! command -v "$cmd_name" &>/dev/null; then
            CURRENTLY_MISSING_CMDS+=("$cmd_name")
        fi
    done

    if [[ ${#CURRENTLY_MISSING_CMDS[@]} -gt 0 ]]; then
        log_debug "Identified missing commands: ${CURRENTLY_MISSING_CMDS[*]}"
        return 1 # Indicates some commands are missing
    else
        log_debug "All essential commands found."
        return 0 # All commands present
    fi
}

_attempt_install_missing_packages() {
    local zfs_utils_installation_skipped_on_proxmox=false
    local grub_packages_installation_skipped_on_proxmox=false
    log_debug "Helper: Attempting to install missing packages..."
    if [[ ${#CURRENTLY_MISSING_CMDS[@]} -eq 0 ]]; then
        return 0
    fi

    declare -A packages_to_install_map
    for cmd_name in "${CURRENTLY_MISSING_CMDS[@]}"; do
        local pkg_name="${CMD_TO_PKG_MAP[$cmd_name]:-$cmd_name}"
        packages_to_install_map["$pkg_name"]=1
    done
    local unique_pkg_list=("${!packages_to_install_map[@]}")

    if [[ ${#unique_pkg_list[@]} -eq 0 ]]; then
        log_debug "No actual packages derived from missing commands. Current missing: ${CURRENTLY_MISSING_CMDS[*]}"
        return 0 
    fi
    
    show_progress "Attempting to install/verify packages: ${unique_pkg_list[*]}"

    local online_attempt_successful=false
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        show_progress "Internet connection detected. Attempting online package installation..."
        local log_dest="/dev/null"
        [[ -n "${LOG_FILE:-}" ]] && log_dest="$LOG_FILE"

        # --- DEBUG: Intentionally break online APT sources to test fallback ---
        # This should only be active for testing the local cache fallback.
        # Ensure this is removed or guarded by a specific debug flag for production.
        show_warning "DEBUG: Intentionally creating dummy_broken.list to simulate APT failure for testing."
        echo "deb http://localhost/nonexistent_repo_for_testing_fallback testing main" | sudo tee /etc/apt/sources.list.d/dummy_broken.list > /dev/null
        # --- END DEBUG ---

        show_progress "Updating package lists (apt-get update)..."
        if DEBIAN_FRONTEND=noninteractive apt-get update >> "$log_dest" 2>&1; then
            show_success "Package lists updated successfully."

            # If Proxmox is detected and zfsutils-linux is a candidate, warn and skip its installation.
            if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
                local temp_pkg_list=()
                # local zfs_utils_skipped=false # Replaced by function-scoped flag
                for pkg in "${unique_pkg_list[@]}"; do
                    if [[ "$pkg" == "zfsutils-linux" ]]; then
                        log_warning "Proxmox detected. ZFS commands might be missing, but 'zfsutils-linux' installation will be skipped. Ensure Proxmox ZFS components are correctly installed."
                        show_warning "Proxmox detected: Skipping 'zfsutils-linux' install. Verify Proxmox ZFS setup."
                        zfs_utils_installation_skipped_on_proxmox=true # Set the function-scoped flag
                    elif [[ "$pkg" == "grub-pc" || "$pkg" == "grub-efi-amd64" ]]; then # Add grub-efi-amd64 here just in case it's ever derived
                        log_warning "Proxmox detected. GRUB commands might be missing, but '$pkg' installation will be skipped. Ensure Proxmox GRUB components are correctly installed."
                        show_warning "Proxmox detected: Skipping '$pkg' install. Verify Proxmox GRUB setup."
                        grub_packages_installation_skipped_on_proxmox=true # Set the function-scoped flag
                    else
                        temp_pkg_list+=("$pkg")
                    fi
                done
                unique_pkg_list=("${temp_pkg_list[@]}")
            fi
            
            if [[ ${#unique_pkg_list[@]} -gt 0 ]]; then
                show_progress "Attempting to install packages online: ${unique_pkg_list[*]}"
            if DEBIAN_FRONTEND=noninteractive apt-get install -y "${unique_pkg_list[@]}" >> "$log_dest" 2>&1; then
                show_success "Online package installation successful for: ${unique_pkg_list[*]}"
                # The overall check for CURRENTLY_MISSING_CMDS happens after this function regardless.
                # If apt-get install reported success for the list, we assume those are fine.
                # The overall check for CURRENTLY_MISSING_CMDS happens after this function regardless.
                online_attempt_successful=true 
            else
                show_error "Online package installation failed for some packages: ${unique_pkg_list[*]}"
                show_warning "Please check the log file for details: $log_dest"
            fi # Closes: if DEBIAN_FRONTEND=noninteractive apt-get install ... (line 106)
            fi # Closes: if [[ ${#unique_pkg_list[@]} -gt 0 ]] (line 104)
        else
            show_error "PREFLIGHT CHECK: Online 'apt-get update' failed. Cannot update package lists."
            show_warning "This could be due to network issues, DNS problems, or repository configuration errors."
            show_warning "Please check the log file for details: $log_dest"
        fi
    else
        show_warning "No internet connection detected. Skipping online package installation."
    fi

    # Fallback to local/offline installation if online attempt was not made, or did not resolve all issues.
    # The script will re-evaluate missing commands after this function anyway.
    # If online attempt was made (even if partially failed), we still try local for any remaining.
    if ! $online_attempt_successful || ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then # Condition to attempt offline
        show_progress "Proceeding to check/use local package cache..."
        local current_debs_dir="${PREFLIGHT_LOCAL_DEBS_PATH:-${SCRIPT_DIR}/debs}"
        if [ -d "$current_debs_dir" ] && [ -n "$(ls -A "$current_debs_dir"/*.deb 2>/dev/null)" ]; then
            show_progress "Attempting to install packages from local directory: $current_debs_dir"
            # We need to ensure we only try to install packages that are genuinely missing
            # and map to the .deb files. dpkg -i will fail if already installed from online.
            # This part is tricky if online partially succeeded. A simpler approach:
            # dpkg -i is generally safe; it will skip already-installed-and-newer packages.
            if dpkg -i "$current_debs_dir"/*.deb >> "$LOG_FILE" 2>&1; then
                show_success "Initial local package installation attempt complete (dpkg -i)."
            else
                show_warning "dpkg -i reported some errors (some packages might already be installed or have issues). Check $LOG_FILE."
            fi
            show_progress "Attempting to fix any broken dependencies (apt-get -f install)..."
            if DEBIAN_FRONTEND=noninteractive apt-get -f install -y >> "$LOG_FILE" 2>&1; then
                show_success "Local package dependencies resolved/checked."
            else
                show_error "Failed to resolve/check local package dependencies with 'apt-get -f install'. Check $LOG_FILE."
            fi
        else
            show_warning "Local debs directory $current_debs_dir is empty or not found. Cannot install packages offline."
        fi
    fi

    local previously_missing_count=${#CURRENTLY_MISSING_CMDS[@]}
    local previously_missing_count_before_final_check=${#CURRENTLY_MISSING_CMDS[@]}
    _get_missing_essential_commands # This will update CURRENTLY_MISSING_CMDS

    local final_missing_cmds_for_status_check=("${CURRENTLY_MISSING_CMDS[@]}")

    if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
        local temp_final_missing_list_for_proxmox_filter=()
        local command_ignored_for_proxmox=false
        for cmd_to_check in "${final_missing_cmds_for_status_check[@]}"; do # Iterate over the current list for filtering
            local ignore_this_command=false
            if [[ "$zfs_utils_installation_skipped_on_proxmox" == "true" && ( "$cmd_to_check" == "zfs" || "$cmd_to_check" == "zpool" ) ]]; then
                log_info "Ignoring missing ZFS command '$cmd_to_check' for preflight status as it's handled by Proxmox."
                ignore_this_command=true
                command_ignored_for_proxmox=true
            fi
            if [[ "$grub_packages_installation_skipped_on_proxmox" == "true" && ( "$cmd_to_check" == "grub-install" || "$cmd_to_check" == "update-grub" ) ]]; then
                log_info "Ignoring missing GRUB command '$cmd_to_check' for preflight status as it's handled by Proxmox."
                ignore_this_command=true
                command_ignored_for_proxmox=true
            fi

            if ! $ignore_this_command; then
                temp_final_missing_list_for_proxmox_filter+=("$cmd_to_check")
            fi
        done
        if $command_ignored_for_proxmox; then # Apply filter only if any command was actually ignored
            log_debug "Applied Proxmox-specific command filters. Previous list: ${final_missing_cmds_for_status_check[*]}. New list for status: ${temp_final_missing_list_for_proxmox_filter[*]}"
            final_missing_cmds_for_status_check=("${temp_final_missing_list_for_proxmox_filter[@]}")
        fi
    fi

    if [[ ${#final_missing_cmds_for_status_check[@]} -eq 0 ]]; then
        show_success "All essential commands (considering Proxmox ZFS handling) are now available."
        log_debug "Final check: All essential commands present. Original missing before final check: ${CURRENTLY_MISSING_CMDS[*]}. Filtered for status: ${final_missing_cmds_for_status_check[*]}"
        return 0 # Success
    elif [[ ${#CURRENTLY_MISSING_CMDS[@]} -lt $previously_missing_count_before_final_check ]]; then # Check if *any* progress was made on the original list
        show_warning "Some commands were installed, but critical ones are still missing: ${final_missing_cmds_for_status_check[*]}"
        log_warning "Original missing commands at end of function: ${CURRENTLY_MISSING_CMDS[*]}. Critical missing for status: ${final_missing_cmds_for_status_check[*]}"
        return 1 # Partial success, but still critical issues
    else
        show_error "Failed to install or resolve critical missing commands: ${final_missing_cmds_for_status_check[*]}"
        log_error "Original missing commands at end of function: ${CURRENTLY_MISSING_CMDS[*]}. Critical missing for status: ${final_missing_cmds_for_status_check[*]}"
        return 1 # Failure
    fi
}

_handle_preflight_package_failure() {
    log_debug "Helper: Entering package failure handler. Missing: ${CURRENTLY_MISSING_CMDS[*]}"
    local choice

    while true; do
        printf "\n--- Preflight Check Failure Menu ---\n"
        printf "Essential commands are missing: %s\n" "${CURRENTLY_MISSING_CMDS[*]:-(none)}"
        printf "What would you like to do?\n"
        printf "  1) Attempt to install missing packages again (online/offline)\n"
        printf "  2) Open a shell for manual troubleshooting\n"
        printf "  3) View list of missing commands/packages\n"
        printf "  4) Override preflight checks and continue (NOT RECOMMENDED)\n"
        printf "  5) Abort installation\n"
        read -r -p "Enter your choice (1-5): " choice

        case "$choice" in
            1) # Attempt install again
                show_progress "Re-attempting package installation..."
                if _attempt_install_missing_packages; then
                    if [[ ${#CURRENTLY_MISSING_CMDS[@]} -eq 0 ]]; then
                        show_success "Successfully resolved all missing packages on retry!"
                        return 0 # Success
                    else
                        show_warning "Still missing some packages after retry: ${CURRENTLY_MISSING_CMDS[*]}"
                    fi
                else
                    show_error "Package installation attempt failed again."
                fi
                ;;
            2) # Open shell
                show_warning "Dropping to a shell. Type 'exit' to return to this menu."
                bash
                _get_missing_essential_commands # Re-check after shell exit
                if [[ ${#CURRENTLY_MISSING_CMDS[@]} -eq 0 ]]; then
                    show_success "All essential commands now present after manual intervention!"
                    return 0 # Success
                fi
                ;;
            3) # View list
                printf "\n--- Missing Commands/Packages ---\n"
                for cmd_name in "${CURRENTLY_MISSING_CMDS[@]}"; do
                    local pkg_name="${CMD_TO_PKG_MAP[$cmd_name]:-$cmd_name (no specific package mapped, try command name itself)}"
                    printf "  - Command: %s (Likely package: %s)\n" "$cmd_name" "$pkg_name"
                done
                printf "---------------------------------\n"
                ;;
            4) # Override
                if prompt_yes_no "WARNING: Overriding preflight checks can lead to installation failure or an unstable system if essential tools are missing. Are you absolutely sure you want to continue?"; then
                    show_warning "Preflight checks overridden by user. Continuing at your own risk."
                    CONFIG_VARS[PREFLIGHT_CHECKS_OVERRIDDEN]="true"
                    export PREFLIGHT_CHECKS_OVERRIDDEN="true" # Export for other scripts if needed
                    return 0 # User chose to override
                fi
                ;;
            5) # Abort
                show_error "User chose to abort installation due to preflight check failures."
                return 1 # Failure
                ;;
            *) 
                show_warning "Invalid selection '$choice', please try again."
                ;;
        esac
        printf "Current missing commands: %s\n" "${CURRENTLY_MISSING_CMDS[*]:-(none)}"
        sleep 1 # Brief pause
    done
}

run_system_preflight_checks() {
    log_debug "Starting system preflight checks..."

    # Configure Proxmox APT sources first if Proxmox is detected or if we want to ensure they are set
    # This is run regardless of PROXMOX_DETECTED to ensure these sources are primary if this script is used on a PVE system
    if ! _configure_proxmox_apt_sources_and_pinning; then
        show_error "Critical error configuring Proxmox APT sources. Aborting preflight checks."
        # Decide if this is fatal for the whole script
        # For now, let's make it fatal for preflight if PVE sources can't be set up.
        if prompt_yes_no "Failed to configure Proxmox APT sources. This may lead to incorrect package versions. Continue anyway?" ; then
            show_warning "Continuing despite APT source configuration issues."
        else
            log_error "User chose to abort due to APT source configuration failure."
            exit 1
        fi
    fi

    log_debug "Main: Running system pre-flight checks"
    show_header "SYSTEM PRE-FLIGHT CHECKS"

    log_debug "Checking for root privileges..."
    if [[ "$(id -u)" -ne 0 ]]; then
        show_error "This script must be run as root. Please use sudo or log in as root."
        exit 1

    log_debug "Checking for Proxmox environment..."
    PROXMOX_DETECTED="false"
    if [[ -d "/etc/pve" ]]; then
        PROXMOX_DETECTED="true"
        log_info "Proxmox environment detected (/etc/pve exists). Adjusting ZFS checks accordingly."
        show_info "Proxmox environment detected. ZFS checks will be adjusted."
    else
        log_debug "Proxmox environment not detected."
    fi

    # Export PROXMOX_DETECTED so other functions called from here can see it
    export PROXMOX_DETECTED
    else
        show_success "Running as root."
    fi

    log_debug "Checking system architecture..."
    if [[ "$(uname -m)" != "x86_64" ]]; then
        show_warning "This installer is optimized for x86_64 architecture. You are running $(uname -m)."
        if ! prompt_yes_no "Continue anyway?"; then exit 1; fi
    else
        show_success "System architecture is x86_64."
    fi

    log_debug "Checking for UEFI mode..."
    if [ -d /sys/firmware/efi ]; then
        show_success "System is booted in UEFI mode."
    else
        show_warning "System is NOT booted in UEFI mode (or /sys/firmware/efi is not accessible)."
        show_warning "This installer targets UEFI systems. Legacy BIOS installations may not work as expected."
        if ! prompt_yes_no "Continue anyway (NOT RECOMMENDED)?"; then exit 1; fi
    fi

    log_debug "Performing initial check for essential commands..."
    if ! _get_missing_essential_commands; then
        show_warning "Some essential commands are missing: ${CURRENTLY_MISSING_CMDS[*]}"
        show_progress "Attempting to automatically install/verify missing packages..."
        if ! _attempt_install_missing_packages; then
            show_error "Failed to automatically resolve missing commands: ${CURRENTLY_MISSING_CMDS[*]}"
            if ! _handle_preflight_package_failure; then
                 show_error "Failed to resolve package issues through manual intervention. Aborting." 
                 exit 1
            fi
        elif [[ ${#CURRENTLY_MISSING_CMDS[@]} -ne 0 ]]; then
            show_error "Inconsistent state: Package installation reported success but commands still missing. Entering manual resolution."
            if ! _handle_preflight_package_failure; then
                 show_error "Failed to resolve package issues. Aborting."
                 exit 1
            fi
        else
            show_success "All essential commands are now available after installation attempt."
        fi
    else
        show_success "All essential commands are present."
    fi

    _get_missing_essential_commands # Re-check after any attempts
    if [[ "${CONFIG_VARS[PREFLIGHT_CHECKS_OVERRIDDEN]:-false}" != "true" && ${#CURRENTLY_MISSING_CMDS[@]} -gt 0 ]]; then
        show_error "Preflight checks failed: Still missing commands: ${CURRENTLY_MISSING_CMDS[*]}. Aborting."
        if prompt_yes_no "Critical commands are still missing. Open a shell for one last attempt at manual fixing? (Choosing 'no' will abort)"; then
            show_warning "Dropping to a shell. Type 'exit' to abort if not fixed."
            bash
            _get_missing_essential_commands
            if [[ ${#CURRENTLY_MISSING_CMDS[@]} -gt 0 ]]; then
                show_error "Commands still missing after shell. Aborting installation."
                exit 1
            else
                show_success "All essential commands now present after manual intervention!"
            fi
        else
            exit 1
        fi
    fi
    
    if [[ "${CONFIG_VARS[PREFLIGHT_CHECKS_OVERRIDDEN]:-false}" == "true" ]]; then
        show_warning "PREFLIGHT CHECKS OVERRIDDEN. Essential commands may still be missing: ${CURRENTLY_MISSING_CMDS[*]}"
    elif [[ ${#CURRENTLY_MISSING_CMDS[@]} -eq 0 ]]; then
        show_success "All essential commands are confirmed present."
    fi

    log_debug "Checking for YubiKeys..."
    if command -v lsusb &>/dev/null; then
        if lsusb | grep -i -q "Yubico"; then YUBIKEY_DETECTED="true"; show_success "YubiKey detected."; else YUBIKEY_DETECTED="false"; log_debug "No YubiKey detected by lsusb."; fi
    else
        YUBIKEY_DETECTED="false"; show_warning "lsusb not found, cannot detect YubiKey."
    fi
    export YUBIKEY_DETECTED # Export for other scripts

    log_debug "Checking internet connectivity..."
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        show_warning "No internet connectivity detected. Online features will be unavailable."
    else
        show_success "Internet connectivity available."
    fi

    log_debug "Checking ZFS kernel module..."
    if lsmod | grep -q "^zfs"; then
        show_success "ZFS kernel module is loaded."
    else
        show_warning "ZFS module not loaded. Attempting to load..."
        if modprobe zfs >> "$LOG_FILE" 2>&1; then
            show_success "ZFS module loaded successfully."
        else
            if [[ "${CONFIG_VARS[PREFLIGHT_CHECKS_OVERRIDDEN]:-false}" != "true" ]]; then
                 show_error "Failed to load ZFS module. This is critical for ZFS installations."
                 if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
                     printf "Proxmox detected. Failed to load ZFS module. Ensure your Proxmox ZFS installation is correct and the kernel supports it. Check Proxmox documentation and forums for ZFS troubleshooting.\n"
                 else
                     printf "Ensure ZFS packages (kernel headers, zfs-dkms/zfsutils-linux) are correctly installed and compatible with your kernel.\n"
                 fi
                 if prompt_yes_no "Failed to load ZFS module. Open a shell for manual troubleshooting? (Choosing 'no' will abort)"; then
                    show_warning "Dropping to a shell. Type 'exit' to re-check ZFS module or abort."
                    bash
                    if lsmod | grep -q "^zfs" || modprobe zfs >> "$LOG_FILE" 2>&1; then
                        show_success "ZFS module now loaded."
                    else
                        show_error "ZFS module still not loaded after shell. Aborting."
                        exit 1
                    fi 
                fi
            fi
        fi
    fi

    log_debug "All pre-flight checks completed."
    show_success "System pre-flight checks passed."
    log_debug "Exiting preflight_checks.sh successfully."
}

# If script is executed directly, run the main function.
# This allows testing or running preflight checks independently.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # For standalone execution, ensure LOG_FILE is set if not already by ui_functions.sh or environment
    : "${LOG_FILE:=${SCRIPT_DIR}/preflight_checks.log}"
    run_system_preflight_checks
fi
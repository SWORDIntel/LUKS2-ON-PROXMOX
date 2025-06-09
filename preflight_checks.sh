#!/usr/bin/env bash

# Determine the script's absolute directory for robust sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common UI functions
# shellcheck source=ui_functions.sh
if [[ -f "${SCRIPT_DIR}/ui_functions.sh" ]]; then
    source "${SCRIPT_DIR}/ui_functions.sh"
else
    echo "Error: ui_functions.sh not found in ${SCRIPT_DIR}. Exiting." >&2
    exit 1
fi


#############################################################
# Pre-Flight Checks - More Robust Version
#############################################################

# Helper function to provide a fallback for dialog. Assumed to be in a common utils file.
_prompt_user_yes_no() {
    local prompt_text="$1"
    # The 'title' variable is no longer used as 'read' doesn't support titles.
    # Fallback to simple terminal read.
    while true; do
        read -r -p "$prompt_text [y/n]: " yn # Added -r for robustness
        case $yn in
            [Yy]*) return 0 ;; # Success
            [Nn]*) return 1 ;; # Failure
            *) echo "Please answer yes or no." >&2 ;; # Error to stderr
        esac
    done
}

_check_for_proxmox_zfs() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    PROXMOX_ZFS_DETECTED="false" # Default to not detected

    if command -v zpool &>/dev/null && zpool list -H -o name rpool &>/dev/null; then
        log_debug "ZFS pool 'rpool' found."
        # Optional: Further check for Proxmox specific datasets
        if command -v zfs &>/dev/null && zfs list -H -o name rpool/ROOT/pve-1 &>/dev/null; then
            log_debug "Proxmox specific dataset 'rpool/ROOT/pve-1' found."
            PROXMOX_ZFS_DETECTED="true"
        elif zfs list -H -o name rpool/data &>/dev/null && zfs list -H -o name rpool/ROOT &>/dev/null; then
             # Broader check for common PVE ZFS layout if pve-1 doesn't exist (e.g. on new PVE installs before first VM)
            log_debug "Common Proxmox ZFS datasets 'rpool/data' and 'rpool/ROOT' found."
            PROXMOX_ZFS_DETECTED="true"
        else
            log_debug "Pool 'rpool' exists, but no definitive Proxmox datasets like 'rpool/ROOT/pve-1' or 'rpool/data' found. Assuming not a standard Proxmox ZFS setup for now."
        fi
    else
        log_debug "ZFS pool 'rpool' not found."
    fi

    export PROXMOX_ZFS_DETECTED # Make it available to other sourced scripts
    log_debug "Exiting function: ${FUNCNAME[0]} - PROXMOX_ZFS_DETECTED=${PROXMOX_ZFS_DETECTED}"
}

run_system_preflight_checks() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "SYSTEM PRE-FLIGHT CHECKS"

    # --- Root, Arch, EFI, and RAM checks are already excellent and robust. No changes needed. ---
    if [[ "$(id -u)" -ne 0 ]]; then show_error "This script must be run as root." && exit 1; fi
    show_success "Running as root."

    if [[ "$(uname -m)" != "x86_64" ]]; then show_error "Unsupported architecture: $(uname -m)." && exit 1; fi
    show_success "System architecture is compatible (x86_64)."

    if [[ -d "/sys/firmware/efi" ]]; then DETECTED_BOOT_MODE="UEFI"; show_success "System booted in UEFI mode."; else DETECTED_BOOT_MODE="BIOS"; show_warning "System appears to be booted in BIOS mode."; fi
    export DETECTED_BOOT_MODE

    local total_ram_mb; total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ $total_ram_mb -lt ${MIN_RAM_MB:-4096} ]]; then show_error "Insufficient RAM: ${total_ram_mb}MB" && exit 1; fi
    show_success "Sufficient RAM available: ${total_ram_mb}MB"

    # Check for existing Proxmox-managed ZFS
    _check_for_proxmox_zfs
    if [[ "${PROXMOX_ZFS_DETECTED}" == "true" ]]; then
        show_warning "Proxmox-managed ZFS pool ('rpool') detected. This installer will proceed with caution.
Ensure you intend to operate on this existing environment or select appropriate options to avoid conflicts."
    else
        show_success "No pre-existing Proxmox-managed ZFS pool ('rpool') detected."
    fi

    # ANNOTATION: Use `findmnt` for a more robust disk space check. It's designed for scripts.
    log_debug "Checking available disk space on installer media..."
    show_progress "Checking available disk space..."
    local install_device_bytes; install_device_bytes=$(findmnt -n -o SIZE --bytes -T /)
    local install_device_size_gb=$((install_device_bytes / 1024 / 1024 / 1024))
    if [[ $install_device_size_gb -lt ${MIN_DISK_GB:-8} ]]; then
        show_warning "Limited space on installation media: ${install_device_size_gb}GB"
    else
        show_success "Sufficient space on installation media: ${install_device_size_gb}GB"
    fi

    # Check for local debs directory
    local debs_dir="${SCRIPT_DIR}/debs"
    local has_local_debs=false
    if [[ -d "$debs_dir" ]] && [[ -n "$(ls -A "$debs_dir" 2>/dev/null)" ]]; then
        has_local_debs=true
        show_success "Local package directory found: $debs_dir"
    fi

    # --- Simplified and Automated Essential Commands Check ---
    log_debug "Checking for essential commands..."
    show_progress "Checking for essential commands..."
    local core_utils=(dialog bash awk grep sed mktemp lsblk id uname readlink parted ip ping gdisk cryptsetup debootstrap mkfs.vfat mkfs.ext4 blkid zpool zfs cp curl wget jq rsync dhclient yubikey-luks-enroll lsusb)
    declare -A cmd_to_pkg_map=(
        [mkfs.vfat]="dosfstools" [mkfs.ext4]="e2fsprogs" [dhclient]="isc-dhcp-client"
        [dialog]="dialog" [p7zip]="p7zip-full" [jq]="jq" [zfs]="zfsutils-linux" [zpool]="zfsutils-linux"
        [cryptsetup]="cryptsetup-bin" [debootstrap]="debootstrap" [wget]="wget" [curl]="curl"
        [gdisk]="gdisk" [rsync]="rsync" [yubikey-luks-enroll]="yubikey-luks"
        [ykman]="yubikey-manager" [lsusb]="usbutils"
    )

    local missing_cmds=()
    for cmd in "${core_utils[@]}"; do
        # If Proxmox is detected, skip checking for ZFS commands as Proxmox should provide them.
        if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]]; then
            if [[ "$cmd" == "zfs" || "$cmd" == "zpool" ]]; then
                log_debug "Proxmox detected, skipping check for ZFS command: $cmd"
                continue
            fi
        fi

        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        show_error "Missing essential commands: ${missing_cmds[*]}"
        
        # Build a unique list of packages to install
        declare -A packages_to_install
        for cmd in "${missing_cmds[@]}"; do
            local pkg="${cmd_to_pkg_map[$cmd]:-$cmd}"
            packages_to_install[$pkg]=1
        done
        local pkg_list=("${!packages_to_install[@]}")

        # ANNOTATION: Offer to install dependencies automatically for better UX.
        if _prompt_user_yes_no "The following required packages are missing or incomplete:\n\n  ${pkg_list[*]}\n\nDo you want to attempt to install them now?" "Install Dependencies"; then
            if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                # Online installation
                show_progress "Attempting to install packages from online repositories..."
                apt-get update &>> "$LOG_FILE"
                apt-get install -y "${pkg_list[@]}" &>> "$LOG_FILE"
            elif [[ "$has_local_debs" == true ]]; then
                # Offline installation
                show_progress "No internet. Attempting to install packages from local '$debs_dir' directory..."
                # Modern apt can resolve dependencies from local .deb files
                apt install -y "$debs_dir"/*.deb &>> "$LOG_FILE" || {
                    # Fallback for older systems if `apt install` on a dir fails
                    dpkg -i "$debs_dir"/*.deb &>> "$LOG_FILE"
                    apt-get -f install -y &>> "$LOG_FILE"
                }
            else
                show_error "Cannot install packages: No internet connection and no local packages found."
                exit 1
            fi

            # ANNOTATION: Final verification after installation attempt. This is crucial.
            missing_cmds=() # Reset and re-check
            for cmd in "${core_utils[@]}"; do
                if ! command -v "$cmd" &>/dev/null; then
                    missing_cmds+=("$cmd")
                fi
            done

            if [[ ${#missing_cmds[@]} -gt 0 ]]; then
                show_error "Failed to install all required commands. Still missing: ${missing_cmds[*]}"
                show_error "Please resolve manually and restart the installer."
                exit 1
            else
                show_success "All dependencies successfully installed."
            fi
        else
            show_error "User declined dependency installation. Cannot continue."
            exit 1
        fi
    fi
    show_success "All essential commands are present."

    # --- YubiKey and Internet checks are good. No major changes. ---
    log_debug "Checking for YubiKeys..."
    if command -v lsusb &>/dev/null; then
        if lsusb | grep -i -q "Yubico"; then YUBIKEY_DETECTED="true"; show_success "YubiKey detected."; else YUBIKEY_DETECTED="false"; fi
    else
        YUBIKEY_DETECTED="false"; show_warning "lsusb not found, cannot detect YubiKey."
    fi
    export YUBIKEY_DETECTED

    log_debug "Checking internet connectivity..."
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        show_warning "No internet connectivity detected. Online features will be unavailable."
    else
        show_success "Internet connectivity available."
    fi

    # ANNOTATION: Simplified ZFS module check. More direct logic.
    log_debug "Checking ZFS kernel module..."
    if lsmod | grep -q "^zfs"; then
        show_success "ZFS kernel module is loaded."
    else
        show_warning "ZFS module not loaded. Attempting to load..."
        if modprobe zfs &>> "$LOG_FILE"; then
            show_success "ZFS module loaded successfully."
        else
            show_error "Failed to load ZFS module. Ensure ZFS packages are correctly installed."
            exit 1
        fi
    fi

    log_debug "All pre-flight checks completed."
    show_success "System pre-flight checks passed."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}
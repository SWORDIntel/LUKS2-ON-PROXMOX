#!/usr/bin/env bash

#############################################################
# Pre-Flight Checks - FIXED
#############################################################
run_system_preflight_checks() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "SYSTEM PRE-FLIGHT CHECKS"

    # Root check
    log_debug "Checking if running as root..."
    if [[ "$(id -u)" -ne 0 ]]; then
        log_debug "Not running as root. Current UID: $(id -u)."
        show_error "This script must be run as root."
        exit 1
    fi
    log_debug "Running as root: OK."
    show_success "Running as root."

    # Architecture check
    log_debug "Checking system architecture..."
    local arch; arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_debug "Unsupported architecture: $arch."
        show_error "Unsupported architecture: $arch."
        exit 1
    fi
    log_debug "System architecture is x86_64: OK."
    show_success "System architecture is compatible (x86_64)."

    # EFI mode check
    log_debug "Checking for EFI mode..."
    if [[ ! -d "/sys/firmware/efi" ]]; then
        log_debug "System not booted in EFI mode (/sys/firmware/efi not found)."
        show_error "System not booted in EFI mode."
        exit 1
    fi
    log_debug "System booted in EFI mode: OK."
    show_success "System booted in EFI mode."

    # Memory check
    log_debug "Checking available RAM..."
    local total_ram_mb; total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    log_debug "Total RAM: ${total_ram_mb}MB. Minimum required: ${MIN_RAM_MB}MB."
    if [[ $total_ram_mb -lt $MIN_RAM_MB ]]; then
        log_debug "Insufficient RAM."
        show_error "Insufficient RAM: ${total_ram_mb}MB (minimum: ${MIN_RAM_MB}MB)"
        show_warning "For a RAM disk installation, at least ${MIN_RAM_MB}MB is recommended"
        exit 1
    fi
    log_debug "Sufficient RAM available: OK."
    show_success "Sufficient RAM available: ${total_ram_mb}MB"

    # Available disk space
    log_debug "Checking available disk space on installer media..."
    show_progress "Checking available disk space..."
    local install_device_size; install_device_size=$(df -BG / | tail -1 | awk '{print $2}' | sed 's/G//')
    log_debug "Installer media size: ${install_device_size}GB. Minimum recommended: ${MIN_DISK_GB}GB."
    if [[ $install_device_size -lt $MIN_DISK_GB ]]; then
        log_debug "Limited space on installation media."
        show_warning "Limited space on installation media: ${install_device_size}GB"
    else
        log_debug "Sufficient space on installation media: OK."
        show_success "Sufficient space on installation media: ${install_device_size}GB"
    fi

    # Check for local debs directory
    # SCRIPT_DIR is defined in installer.sh and should be available if preflight_checks.sh is sourced.
    log_debug "Checking for local debs directory at $SCRIPT_DIR/debs..."
    local debs_dir="${SCRIPT_DIR}/debs"
    local has_local_debs=false

    if [[ -d "$debs_dir" ]] && [[ -n "$(ls -A "$debs_dir" 2>/dev/null)" ]]; then
        log_debug "Local package directory found and is not empty: $debs_dir"
        show_success "Local package directory found: $debs_dir"
        has_local_debs=true
    else
        log_debug "No local packages directory found or it is empty."
        show_progress "No local packages directory found. Will use online repositories if needed."
    fi

    # Check for essential commands - FIXED
    log_debug "Checking for essential commands..."
    show_progress "Checking for essential commands..."
    local missing_cmds=()
    local core_utils=(bash awk grep sed mktemp lsblk id uname readlink parted ip ping gdisk cryptsetup debootstrap mkfs.vfat mkfs.ext4 blkid zpool zfs cp curl wget jq p7zip dialog rsync dhclient yubikey-luks-enroll ykman lsusb) # Added yubikey utils and lsusb

    for cmd in "${core_utils[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    # Create package mapping for missing commands
    declare -A cmd_to_pkg_map
    cmd_to_pkg_map[mkfs.vfat]="dosfstools"
    cmd_to_pkg_map[mkfs.ext4]="e2fsprogs"
    cmd_to_pkg_map[dhclient]="isc-dhcp-client"
    cmd_to_pkg_map[dialog]="dialog"
    cmd_to_pkg_map[p7zip]="p7zip-full"
    cmd_to_pkg_map[jq]="jq"
    cmd_to_pkg_map[zfs]="zfsutils-linux"
    cmd_to_pkg_map[zpool]="zfsutils-linux"
    cmd_to_pkg_map[cryptsetup]="cryptsetup-bin"
    cmd_to_pkg_map[debootstrap]="debootstrap"
    cmd_to_pkg_map[wget]="wget"
    cmd_to_pkg_map[curl]="curl"
    cmd_to_pkg_map[gdisk]="gdisk"
    cmd_to_pkg_map[rsync]="rsync"
    cmd_to_pkg_map[yubikey-luks-enroll]="yubikey-luks"
    cmd_to_pkg_map[ykman]="yubikey-manager"
    cmd_to_pkg_map[lsusb]="usbutils" # lsusb is in usbutils

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_debug "Missing essential commands: ${missing_cmds[*]}"
        show_error "Missing commands: ${missing_cmds[*]}"

        # Check for matching debs in the local directory first
        if [[ "$has_local_debs" == true ]]; then
            log_debug "Local debs found. Checking for required packages in $debs_dir."
            show_progress "Checking for required packages in local debs directory..."
            local found_packages_locally=() # Renamed to avoid conflict
            local still_missing_after_local_check=() # Renamed

            for cmd_item in "${missing_cmds[@]}"; do # Renamed loop var
                local pkg_for_cmd="${cmd_to_pkg_map[$cmd_item]:-$cmd_item}" # Renamed loop var
                # Corrected ls globbing to be safer if pkg_for_cmd has special chars (though unlikely here)
                if compgen -G "$debs_dir/*${pkg_for_cmd}*.deb" > /dev/null; then
                    log_debug "Found local package for $cmd_item (package: $pkg_for_cmd)."
                    found_packages_locally+=("$pkg_for_cmd")
                else
                    log_debug "No local package found for $cmd_item (package: $pkg_for_cmd)."
                    still_missing_after_local_check+=("$cmd_item")
                fi
            done

            if [[ ${#found_packages_locally[@]} -gt 0 ]]; then
                log_debug "Found these packages locally: ${found_packages_locally[*]}"
                show_progress "Found these packages locally: ${found_packages_locally[*]}"
                show_progress "Installing local packages..."
                log_debug "Executing: dpkg -i $debs_dir/*.deb"
                dpkg -i "$debs_dir"/*.deb &>> "$LOG_FILE" || log_debug "dpkg -i had errors (expected if -f needed)."
                log_debug "Executing: apt-get -f install -y"
                apt-get -f install -y &>> "$LOG_FILE"
                log_debug "Local package installation attempt finished."

                # Re-check what's still missing
                local previously_missing_cmds=("${missing_cmds[@]}") # Store original list
                missing_cmds=() # Reset for re-check
                for cmd_to_recheck in "${previously_missing_cmds[@]}"; do # Use original list for re-check
                    if ! command -v "$cmd_to_recheck" &>/dev/null; then
                        missing_cmds+=("$cmd_to_recheck")
                    fi
                done

                if [[ ${#missing_cmds[@]} -eq 0 ]]; then
                    log_debug "All required packages installed successfully from local debs."
                    show_success "All required packages installed successfully from local debs!"
                    # return # Exiting function here as all commands are now present.
                else
                    log_debug "Some packages still missing after local installation: ${missing_cmds[*]}"
                    show_warning "Some packages still missing after local installation: ${missing_cmds[*]}"
                fi
            else
                log_debug "No matching packages found in local debs directory for the missing commands."
                show_warning "No matching packages found in local debs directory"
            fi
        else
            log_debug "No local debs directory, cannot check for local packages."
        fi

        # If we still have missing commands, suggest online installation
        if [[ ${#missing_cmds[@]} -gt 0 ]]; then
            log_debug "Still missing commands, suggesting online installation."
            show_warning "Install missing packages with:"
            echo "   apt-get update" >> "$LOG_FILE" # Log suggestion too
            echo "   apt-get update"

            local install_cmd_suggestion="apt-get install -y" # Renamed
            local required_pkgs_list=() # Renamed

            for cmd_to_get_pkg in "${missing_cmds[@]}"; do # Renamed
                local pkg_name="${cmd_to_pkg_map[$cmd_to_get_pkg]:-}" # Renamed
                if [[ -n "$pkg_name" ]] && ! echo "${required_pkgs_list[*]}" | grep -q "$pkg_name"; then
                    required_pkgs_list+=("$pkg_name")
                fi
            done

            if [[ ${#required_pkgs_list[@]} -gt 0 ]]; then
                log_debug "Suggested packages for installation: ${required_pkgs_list[*]}"
                echo "   $install_cmd_suggestion ${required_pkgs_list[*]}" >> "$LOG_FILE"
                echo "   $install_cmd_suggestion ${required_pkgs_list[*]}"
            fi

            log_debug "Checking internet connectivity before exiting for missing packages..."
            if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                log_debug "No internet connectivity. User needs to configure network and install packages manually."
                show_warning "No internet connectivity detected. You'll need to:"
                echo "   1. Configure network (use 'configure_network_early' function)"
                echo "   2. Install required packages"
                echo "   3. Restart the installer"
            else
                log_debug "Internet connectivity detected. User can try installing packages."
            fi
            exit 1
        fi
    fi
    log_debug "All essential commands found or installed."
    show_success "All essential commands found."

    # YubiKey Detection
    log_debug "Checking for YubiKeys..."
    if command -v lsusb &>/dev/null; then
        if lsusb | grep -i -q "Yubico"; then
            log_debug "YubiKey detected via lsusb."
            YUBIKEY_DETECTED="true"
            show_success "YubiKey detected."
        else
            log_debug "No YubiKey detected via lsusb."
            YUBIKEY_DETECTED="false"
            show_progress "No YubiKey detected." # Not a warning/error, just info
        fi
    else
        log_debug "lsusb command not found, cannot detect YubiKey."
        YUBIKEY_DETECTED="false" # Assume no YubiKey if lsusb is missing
        show_warning "lsusb command not found. Cannot automatically detect YubiKey presence."
    fi
    export YUBIKEY_DETECTED
    log_debug "YUBIKEY_DETECTED set to: $YUBIKEY_DETECTED"


    # Additional checks (same as before)
    # ...

    # Internet connectivity check
    log_debug "Checking internet connectivity (final check in preflight)..."
    show_progress "Checking internet connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_debug "Internet connectivity available."
        show_success "Internet connectivity available"
    else
        log_debug "No internet connectivity detected."
        show_warning "No internet connectivity detected. Network configuration will be required."

        if [[ "$has_local_debs" == true ]]; then
            log_debug "No internet, but local debs are available. Proceeding with caution."
            show_warning "No internet connection, but local packages are available. Proceeding with caution."
        else
            log_debug "No internet and no local debs. Some operations may fail."
            show_warning "No internet connection and no local packages. Some operations may fail."
        fi
    fi

    # ZFS module check
    log_debug "Checking ZFS kernel module..."
    show_progress "Checking ZFS kernel module..."
    if modprobe -n zfs &>/dev/null && lsmod | grep -q "^zfs"; then
        log_debug "ZFS kernel module seems loaded or loadable without issues (modprobe -n)."
        show_success "ZFS kernel module loaded"
    else
        log_debug "ZFS kernel module not loaded or 'modprobe -n zfs' indicates issues."
        show_warning "ZFS kernel module not loaded or not available"
        log_debug "Attempting to load ZFS module with 'modprobe zfs'."
        show_progress "Attempting to load ZFS module..."
        if modprobe zfs &>> "$LOG_FILE"; then # Log output of modprobe
            log_debug "ZFS module loaded successfully via modprobe zfs."
            show_success "ZFS module loaded successfully"
        else
            log_debug "Failed to load ZFS module via modprobe zfs. Exit status: $?."
            show_error "Failed to load ZFS module. Please install ZFS packages or provide them in the debs directory."
            exit 1
        fi
    fi

    log_debug "All pre-flight checks completed successfully."
    show_success "All pre-flight checks completed successfully"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

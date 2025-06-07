#!/usr/bin/env bash

#############################################################
# Pre-Flight Checks - FIXED
#############################################################
run_system_preflight_checks() {
    show_header "SYSTEM PRE-FLIGHT CHECKS"

    # Root check
    if [[ "$(id -u)" -ne 0 ]]; then
        show_error "This script must be run as root."
        exit 1
    fi
    show_success "Running as root."

    # Architecture check
    if [[ "$(uname -m)" != "x86_64" ]]; then
        show_error "Unsupported architecture: $(uname -m)."
        exit 1
    fi
    show_success "System architecture is compatible (x86_64)."

    # Boot Mode Detection & User Override
    local auto_detected_mode
    if [[ -d "/sys/firmware/efi" ]]; then
        auto_detected_mode="UEFI"
    else
        auto_detected_mode="BIOS"
    fi
    show_progress "Auto-detected boot mode: ${auto_detected_mode}"

    local dialog_text
    dialog_text="The installer has auto-detected the system boot mode as: ${BOLD}${auto_detected_mode}${RESET}.

Please confirm if this is correct. If you are using Clover for a non-bootable NVMe drive, you should select UEFI mode even if the system is currently booted in Legacy/BIOS mode via a temporary boot device.

Choosing the wrong mode can lead to an unbootable system.
- ${BOLD}UEFI Mode:${RESET} For modern systems. Required for Clover bootloader.
- ${BOLD}Legacy BIOS Mode:${RESET} For older systems without UEFI support.

If unsure, it's usually best to accept the auto-detected mode unless you have a specific reason to override it (like the Clover scenario)."

    local chosen_mode=""
    while true; do
        chosen_mode=$(dialog --title "Confirm System Boot Mode" \
            --radiolist "$dialog_text" 18 75 2 \
            "UEFI" "UEFI Mode (for modern systems, supports Clover)" \
                $( [[ "$auto_detected_mode" == "UEFI" ]] && echo "on" || echo "off") \
            "BIOS" "Legacy BIOS Mode (for older systems)" \
                $( [[ "$auto_detected_mode" == "BIOS" ]] && echo "on" || echo "off") \
            3>&1 1>&2 2>&3)

        local dialog_exit_status=$?
        if [[ $dialog_exit_status -eq 0 ]]; then # OK
            if [[ -n "$chosen_mode" ]]; then
                CONFIG_VARS[BOOT_MODE]="$chosen_mode"
                break
            else
                show_error "No boot mode selected. Please choose either UEFI or BIOS."
                # Loop again
            fi
        elif [[ $dialog_exit_status -eq 1 ]]; then # Cancel
            show_error "Boot mode confirmation cancelled by user. Exiting."
            exit 1
        else # Other error (ESC, etc.)
            show_error "An unexpected error occurred during boot mode selection. Exiting."
            exit 1
        fi
    done

    if [[ "${CONFIG_VARS[BOOT_MODE]}" != "$auto_detected_mode" ]]; then
        show_warning "User has overridden auto-detected boot mode. Selected: ${CONFIG_VARS[BOOT_MODE]} (Auto-detected: $auto_detected_mode)"
    else
        show_success "Boot mode confirmed: ${CONFIG_VARS[BOOT_MODE]}"
    fi

    if [[ "${CONFIG_VARS[BOOT_MODE]}" == "UEFI" ]]; then
        show_progress "Proceeding in UEFI mode..."
    else
        show_warning "Proceeding in Legacy BIOS mode. UEFI-specific features (like Clover for NVMe boot) will not be available."
    fi

    # Memory check
    local total_ram_mb; total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ $total_ram_mb -lt $MIN_RAM_MB ]]; then
        show_error "Insufficient RAM: ${total_ram_mb}MB (minimum: ${MIN_RAM_MB}MB)"
        show_warning "For a RAM disk installation, at least ${MIN_RAM_MB}MB is recommended"
        exit 1
    fi
    show_success "Sufficient RAM available: ${total_ram_mb}MB"

    # Available disk space
    show_progress "Checking available disk space..."
    local install_device_size; install_device_size=$(df -BG / | tail -1 | awk '{print $2}' | sed 's/G//')
    if [[ $install_device_size -lt $MIN_DISK_GB ]]; then
        show_warning "Limited space on installation media: ${install_device_size}GB"
    else
        show_success "Sufficient space on installation media: ${install_device_size}GB"
    fi

    # Check for local debs directory
    local script_dir; script_dir=$(dirname "$(readlink -f "$0")")
    local debs_dir="${script_dir}/debs"
    local has_local_debs=false

    if [[ -d "$debs_dir" ]] && [[ -n "$(ls -A "$debs_dir" 2>/dev/null)" ]]; then
        show_success "Local package directory found: $debs_dir"
        has_local_debs=true
    else
        show_progress "No local packages directory found. Will use online repositories if needed."
    fi

    # Check for essential commands - FIXED
    show_progress "Checking for essential commands..."
    local missing_cmds=()
    local core_utils=(bash awk grep sed mktemp lsblk id uname readlink parted ip ping gdisk cryptsetup debootstrap mkfs.vfat mkfs.ext4 blkid zpool zfs cp curl wget jq p7zip dialog rsync dhclient)

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

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        show_error "Missing commands: ${missing_cmds[*]}"

        # Check for matching debs in the local directory first
        if [[ "$has_local_debs" == true ]]; then
            show_progress "Checking for required packages in local debs directory..."
            local found_packages=()
            local still_missing=()

            for cmd in "${missing_cmds[@]}"; do
                local pkg="${cmd_to_pkg_map[$cmd]:-$cmd}"
                if ls "$debs_dir"/*"${pkg}"*.deb &>/dev/null; then
                    found_packages+=("$pkg")
                else
                    still_missing+=("$cmd")
                fi
            done

            if [[ ${#found_packages[@]} -gt 0 ]]; then
                show_progress "Found these packages locally: ${found_packages[*]}"
                show_progress "Installing local packages..."

                # Install .deb packages from the debs directory
                dpkg -i "$debs_dir"/*.deb &>/dev/null || true
                apt-get -f install -y &>/dev/null

                # Re-check what's still missing
                missing_cmds=()
                for cmd in "${still_missing[@]}"; do
                    if ! command -v "$cmd" &>/dev/null; then
                        missing_cmds+=("$cmd")
                    fi
                done

                if [[ ${#missing_cmds[@]} -eq 0 ]]; then
                    show_success "All required packages installed successfully from local debs!"
                    return
                else
                    show_warning "Some packages still missing after local installation: ${missing_cmds[*]}"
                fi
            else
                show_warning "No matching packages found in local debs directory"
            fi
        fi

        # If we still have missing commands, suggest online installation
        if [[ ${#missing_cmds[@]} -gt 0 ]]; then
            # Provide package installation hints
            show_warning "Install missing packages with:"
            echo "   apt-get update"

            # Map commands to packages
            local install_cmd="apt-get install -y"
            local required_pkgs=()

            # Build list of required packages
            for cmd in "${missing_cmds[@]}"; do
                local pkg="${cmd_to_pkg_map[$cmd]:-}"
                if [[ -n "$pkg" ]] && ! echo "${required_pkgs[*]}" | grep -q "$pkg"; then
                    required_pkgs+=("$pkg")
                fi
            done

            # Show installation command with all required packages
            if [[ ${#required_pkgs[@]} -gt 0 ]]; then
                echo "   $install_cmd ${required_pkgs[*]}"
            fi

            # Internet connectivity check before suggesting online install
            if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                show_warning "No internet connectivity detected. You'll need to:"
                echo "   1. Configure network (use 'configure_network_early' function)"
                echo "   2. Install required packages"
                echo "   3. Restart the installer"
            fi

            exit 1
        fi
    fi

    show_success "All essential commands found."

    # Additional checks (same as before)
    # ...

    # Internet connectivity check
    show_progress "Checking internet connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        show_success "Internet connectivity available"
    else
        show_warning "No internet connectivity detected. Network configuration will be required."

        # If we have all required commands but no internet, we can still proceed
        if [[ "$has_local_debs" == true ]]; then
            show_warning "No internet connection, but local packages are available. Proceeding with caution."
        else
            show_warning "No internet connection and no local packages. Some operations may fail."
        fi
    fi

    # ZFS module check
    show_progress "Checking ZFS kernel module..."
    if modprobe -n zfs &>/dev/null && lsmod | grep -q "^zfs"; then
        show_success "ZFS kernel module loaded"
    else
        show_warning "ZFS kernel module not loaded or not available"
        show_progress "Attempting to load ZFS module..."
        if modprobe zfs &>/dev/null; then
            show_success "ZFS module loaded successfully"
        else
            show_error "Failed to load ZFS module. Please install ZFS packages or provide them in the debs directory."
            exit 1
        fi
    fi

    show_success "All pre-flight checks completed successfully"
}

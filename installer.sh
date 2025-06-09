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

    # Determine and store UUID for the YubiKey ZFS key partition if it was created
    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" == "yes" && -n "${CONFIG_VARS[YUBIKEY_KEY_PART]}" ]]; then
        log_debug "Determining UUID for YubiKey ZFS key partition: ${CONFIG_VARS[YUBIKEY_KEY_PART]}"
        local yk_part_uuid
        # Ensure blkid is available; it should be due to ensure_essential_packages
        if command -v blkid &>/dev/null; then
            # Using a loop with retries for blkid, as device detection can sometimes have slight delays
            for i in {1..3}; do
                yk_part_uuid=$(blkid -s UUID -o value "${CONFIG_VARS[YUBIKEY_KEY_PART]}" 2>/dev/null)
                if [[ -n "$yk_part_uuid" ]]; then
                    break
                fi
                log_debug "blkid attempt $i for ${CONFIG_VARS[YUBIKEY_KEY_PART]} failed to get UUID, retrying after 1s..."
                sleep 1
            done

            if [[ -n "$yk_part_uuid" ]]; then
                CONFIG_VARS[YUBIKEY_KEY_PART_UUID]="$yk_part_uuid"
                log_debug "Stored YUBIKEY_KEY_PART_UUID: ${CONFIG_VARS[YUBIKEY_KEY_PART_UUID]}"
            else
                show_error "Failed to determine UUID for YubiKey ZFS key partition ${CONFIG_VARS[YUBIKEY_KEY_PART]}. This is critical for initramfs setup. Aborting."
                # Consider if cleanup is needed or if trap will handle it
                exit 1
            fi
        else
            show_error "blkid command not found. Cannot determine UUID for YubiKey ZFS key partition. Aborting."
            exit 1
        fi
    else
        # Ensure it's cleared if not used, so the ykzfs.conf doesn't get a stale or wrong UUID
        CONFIG_VARS[YUBIKEY_KEY_PART_UUID]=""
        log_debug "YubiKey for ZFS key not enabled or partition not set; YUBIKEY_KEY_PART_UUID cleared."
    fi

    # Setup YubiKey LUKS partition for ZFS key if selected
    if [[ "${CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]:-no}" == "yes" && "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" == "yes" ]]; then
        if [[ -n "${CONFIG_VARS[YUBIKEY_KEY_PART]}" ]]; then # Check if the dedicated partition variable is set
            if ! setup_yubikey_luks_partition; then # Call the function from yubikey_setup.sh
                show_error "Failed to set up YubiKey LUKS partition for ZFS key. Aborting."
                # Assuming 'cleanup' is handled by trap EXIT or called explicitly if needed before exit
                exit 1
            fi
            show_success "YubiKey LUKS partition for ZFS key configured successfully."
        else
            # This case should ideally not be reached if core_logic and disk_operations are correct
            show_error "YubiKey for ZFS key was selected, but the dedicated partition (YUBIKEY_KEY_PART) was not defined by disk_operations.sh. This is an internal error. Aborting."
            exit 1
        fi
    fi
    
    setup_luks_encryption
    if [[ "${CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]:-no}" != "yes" ]]; then
        health_check "luks" true
    else
        log_info "ZFS Native Encryption selected, skipping LUKS health check."
    fi
    
    setup_zfs_pool
    health_check "zfs" true
    
    install_base_system

    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" == "yes" ]]; then
        log_info "Creating YubiKey ZFS initramfs hook script..."
        local ykzfs_hook_script_path="/mnt/etc/initramfs-tools/hooks/ykzfs_hooks.sh"
        mkdir -p "$(dirname "$ykzfs_hook_script_path")"

        cat > "$ykzfs_hook_script_path" << 'EOF_YKZFS_HOOK'
#!/bin/sh
# Initramfs hook for YubiKey ZFS key unlocking

PREREQ=""

# Output some debug info to initramfs build log
echo "ykzfs_hooks: Running YubiKey ZFS hook script"

# Ensure /conf directory exists for our config file
mkdir -p "${DESTDIR}/conf"

# Copy the ykzfs configuration file into initramfs
if [ -f "/etc/ykzfs/ykzfs.conf" ]; then
    echo "ykzfs_hooks: Copying /etc/ykzfs/ykzfs.conf to ${DESTDIR}/conf/ykzfs.conf"
    cp "/etc/ykzfs/ykzfs.conf" "${DESTDIR}/conf/ykzfs.conf"
else
    echo "ykzfs_hooks: WARNING - /etc/ykzfs/ykzfs.conf not found!"
fi

# Copy necessary binaries. copy_exec handles dependencies.
# Ensure these are available in the chroot environment first.
echo "ykzfs_hooks: Copying binaries: cryptsetup, yubikey-luks-open, ykpersonalize, tpm2_eventlog, mount, umount, sleep, grep, sed" # Added tpm2_eventlog as ykpersonalize may need it
copy_exec /sbin/cryptsetup /sbin
copy_exec /usr/bin/yubikey-luks-open /usr/bin
copy_exec /usr/bin/ykpersonalize /usr/bin
copy_exec /usr/bin/tpm2_eventlog /usr/bin # Often a dep of ykpersonalize/yubikey tools for FIDO2/U2F functionality
copy_exec /bin/mount /bin
copy_exec /bin/umount /bin
copy_exec /bin/sleep /bin
copy_exec /bin/grep /bin # For parsing config
copy_exec /bin/sed /bin  # For parsing config

# Add any other specific tools your ykzfs_unlock script might need, e.g., blkid for UUID matching if not using /dev/disk/by-uuid
# copy_exec /sbin/blkid /sbin # If needed

# Copy pcscd related files if yubikey-luks-open needs it at runtime in initramfs
# This can be complex. Usually, pcscd is NOT run in initramfs.
# yubikey-luks-open and ykpersonalize are often compiled to access YubiKey directly via libusb.
# If full pcscd is needed, it's a much more involved initramfs setup.
# For now, assume direct USB access is sufficient.

# Ensure essential libraries for libykpers and libu2f (if ykpersonalize needs them and copy_exec doesn't get them)
# Typically handled by copy_exec, but good to be aware.
# manual_copy_if_needed /usr/lib/x86_64-linux-gnu/libykpers-1.so.1
# manual_copy_if_needed /usr/lib/x86_64-linux-gnu/libyubikey.so.0
# manual_copy_if_needed /usr/lib/x86_64-linux-gnu/libu2f-host.so.0 (or similar name)

echo "ykzfs_hooks: YubiKey ZFS hook script finished."
exit 0
EOF_YKZFS_HOOK

        if ! chmod +x "$ykzfs_hook_script_path"; then
            show_warning "Failed to make $ykzfs_hook_script_path executable."
        fi
        show_success "YubiKey ZFS initramfs hook script created at $ykzfs_hook_script_path"
    else
        log_info "YubiKey for ZFS key not enabled, skipping creation of ykzfs_hooks.sh."
    fi

    if [[ "${CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]:-no}" == "yes" ]]; then
        log_info "Creating YubiKey ZFS initramfs unlock script..."
        local ykzfs_unlock_script_path="/mnt/etc/initramfs-tools/scripts/local-top/ykzfs_unlock"
        # The hooks directory is already created by the previous step for ykzfs_hooks.sh
        mkdir -p "$(dirname "$ykzfs_unlock_script_path")"

        cat > "$ykzfs_unlock_script_path" << 'EOF_YKZFS_UNLOCK'
#!/bin/sh
# Initramfs script for YubiKey ZFS key unlocking (runs in local-top)

PREREQ="" # Adjust if it needs to run after specific ZFS scripts, though local-top runs early

# Source function library if available (e.g., for log_functions)
# [ -f /scripts/functions ] && . /scripts/functions

# Simple logger for initramfs, prepends script name
log_this() {
    echo "ykzfs_unlock: "$1"" >&2 # Output to stderr, often captured in boot logs
}

log_this "Starting YubiKey ZFS key unlock process..."

# Configuration file path within initramfs
CONF_FILE="/conf/ykzfs.conf"

if [ ! -f "$CONF_FILE" ]; then
    log_this "ERROR: Configuration file $CONF_FILE not found! Cannot proceed."
    exit 1
fi

# Source the configuration variables
YUBIKEY_ZFS_KEY_LUKS_UUID=$(grep '^YUBIKEY_ZFS_KEY_LUKS_UUID=' "$CONF_FILE" | sed -e 's/.*="//' -e 's/"$//')
ZFS_KEYFILE_RELATIVE_PATH=$(grep '^ZFS_KEYFILE_RELATIVE_PATH=' "$CONF_FILE" | sed -e 's/.*="//' -e 's/"$//')
ZFS_KEYFILE_INITRAMFS_TARGET=$(grep '^ZFS_KEYFILE_INITRAMFS_TARGET=' "$CONF_FILE" | sed -e 's/.*="//' -e 's/"$//')
YUBIKEY_ZFS_KEY_MAPPER_NAME=$(grep '^YUBIKEY_ZFS_KEY_MAPPER_NAME=' "$CONF_FILE" | sed -e 's/.*="//' -e 's/"$//')

if [ -z "$YUBIKEY_ZFS_KEY_LUKS_UUID" ] || [ -z "$ZFS_KEYFILE_RELATIVE_PATH" ] ||    [ -z "$ZFS_KEYFILE_INITRAMFS_TARGET" ] || [ -z "$YUBIKEY_ZFS_KEY_MAPPER_NAME" ]; then
    log_this "ERROR: One or more required variables missing from $CONF_FILE. Cannot proceed."
    exit 1
fi

log_this "Config loaded: UUID=$YUBIKEY_ZFS_KEY_LUKS_UUID, RelativeKeyPath=$ZFS_KEYFILE_RELATIVE_PATH, TargetKeyPath=$ZFS_KEYFILE_INITRAMFS_TARGET, MapperName=$YUBIKEY_ZFS_KEY_MAPPER_NAME"

# Wait for the LUKS device to appear
luks_dev_path_by_uuid="/dev/disk/by-uuid/${YUBIKEY_ZFS_KEY_LUKS_UUID}"
max_wait_seconds=30
current_wait=0
log_this "Waiting for YubiKey LUKS key device $luks_dev_path_by_uuid to appear (max ${max_wait_seconds}s)..."
while [ ! -b "$luks_dev_path_by_uuid" ] && [ "$current_wait" -lt "$max_wait_seconds" ]; do
    sleep 1
    current_wait=$((current_wait + 1))
    # Modulo for less spammy logging: log_this "Waited ${current_wait}s..."
    if [ $((current_wait % 5)) -eq 0 ]; then
      log_this "Still waiting for $luks_dev_path_by_uuid (${current_wait}s)..."
    fi
done

if [ ! -b "$luks_dev_path_by_uuid" ]; then
    log_this "ERROR: YubiKey LUKS key device $luks_dev_path_by_uuid did not appear after ${max_wait_seconds}s. Cannot proceed."
    exit 1
fi
log_this "YubiKey LUKS key device $luks_dev_path_by_uuid found."

# Attempt to unlock the LUKS partition using yubikey-luks-open
# This will prompt for YubiKey and its passphrase.
log_this "Attempting to unlock $luks_dev_path_by_uuid with YubiKey as $YUBIKEY_ZFS_KEY_MAPPER_NAME..."
echo "Please insert your YubiKey and follow the prompts to unlock the ZFS key partition." >&1 # To console

# yubikey-luks-open might need specific environment or TTY handling.
# Test thoroughly. It typically handles user interaction.
if ! yubikey-luks-open -d "$luks_dev_path_by_uuid" -n "$YUBIKEY_ZFS_KEY_MAPPER_NAME"; then
    log_this "ERROR: Failed to unlock $luks_dev_path_by_uuid with yubikey-luks-open."
    # Optionally, try cryptsetup open with passphrase as a fallback if yubikey-luks-open fails partially
    # but this would require getting the passphrase again, complex for initramfs.
    # For now, failure here means ZFS key is inaccessible.
    exit 1
fi
log_this "Successfully unlocked $luks_dev_path_by_uuid as /dev/mapper/$YUBIKEY_ZFS_KEY_MAPPER_NAME."

mapped_luks_device="/dev/mapper/$YUBIKEY_ZFS_KEY_MAPPER_NAME"
temp_mount_point="/run/yk_luks_key_storage" # /run should be available in initramfs

mkdir -p "$temp_mount_point"
log_this "Mounting $mapped_luks_device to $temp_mount_point..."
if ! mount -o ro "$mapped_luks_device" "$temp_mount_point"; then # Mount read-only
    log_this "ERROR: Failed to mount $mapped_luks_device to $temp_mount_point."
    cryptsetup close "$YUBIKEY_ZFS_KEY_MAPPER_NAME" # Attempt cleanup
    exit 1
fi
log_this "$mapped_luks_device mounted to $temp_mount_point."

zfs_keyfile_source="$temp_mount_point$ZFS_KEYFILE_RELATIVE_PATH" # Correctly append relative path
log_this "ZFS keyfile source: $zfs_keyfile_source"

if [ ! -f "$zfs_keyfile_source" ]; then
    log_this "ERROR: ZFS keyfile $zfs_keyfile_source not found on the LUKS partition!"
    umount "$temp_mount_point"
    cryptsetup close "$YUBIKEY_ZFS_KEY_MAPPER_NAME"
    exit 1
fi

log_this "Copying ZFS keyfile from $zfs_keyfile_source to $ZFS_KEYFILE_INITRAMFS_TARGET..."
# Ensure target directory exists in /run (should be fine)
mkdir -p "$(dirname "$ZFS_KEYFILE_INITRAMFS_TARGET")"
cp "$zfs_keyfile_source" "$ZFS_KEYFILE_INITRAMFS_TARGET"
if [ $? -ne 0 ]; then
    log_this "ERROR: Failed to copy ZFS keyfile to $ZFS_KEYFILE_INITRAMFS_TARGET."
    umount "$temp_mount_point"
    cryptsetup close "$YUBIKEY_ZFS_KEY_MAPPER_NAME"
    exit 1
fi
chmod 0400 "$ZFS_KEYFILE_INITRAMFS_TARGET" # Restrict permissions
log_this "ZFS keyfile copied to $ZFS_KEYFILE_INITRAMFS_TARGET."

log_this "Unmounting $temp_mount_point..."
umount "$temp_mount_point"
rmdir "$temp_mount_point"

# Decide whether to close the LUKS mapper.
# If ZFS loads the key and imports the pool successfully, keeping it open might not be necessary.
# However, for cleanliness and security, it's better to close it.
log_this "Closing LUKS mapper $YUBIKEY_ZFS_KEY_MAPPER_NAME..."
cryptsetup close "$YUBIKEY_ZFS_KEY_MAPPER_NAME"

log_this "YubiKey ZFS key unlock process completed successfully."
exit 0
EOF_YKZFS_UNLOCK

        # Make the unlock script executable
        if ! chmod +x "$ykzfs_unlock_script_path"; then
            show_warning "Failed to make $ykzfs_unlock_script_path executable."
        fi
        show_success "YubiKey ZFS initramfs unlock script created at $ykzfs_unlock_script_path"
    else
        log_info "YubiKey for ZFS key not enabled, skipping creation of ykzfs_unlock script."
    fi
    
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

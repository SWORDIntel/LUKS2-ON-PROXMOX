#!/usr/bin/env bash

# Determine the script's absolute directory for robust sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common UI functions - CRITICAL for this script
# shellcheck source=ui_functions.sh
if [[ -f "${SCRIPT_DIR}/ui_functions.sh" ]]; then
    source "${SCRIPT_DIR}/ui_functions.sh"
else
    echo "Critical Error: ui_functions.sh not found in ${SCRIPT_DIR}. This script cannot run without UI functions. Exiting." >&2
    exit 1
fi


#############################################################
# Core Logic Functions
#############################################################

# (Function _prompt_user_yes_no is removed from here, now centralized in ui_functions.sh as prompt_yes_no)

init_environment() {
    show_step "INIT" "Initializing Environment"
    # Create temp dir and set trap immediately.
    # The trap must not depend on any variable that isn't universally available.
    TEMP_DIR=$(mktemp -d /tmp/proxmox-installer.XXXXXX)
    # The cleanup function is now more robust and can handle partial states.
    trap 'log_debug "Cleanup trap triggered by EXIT."; cleanup' EXIT

    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Temporary directory for installation files: $TEMP_DIR"
    show_success "Main log file: $LOG_FILE"
    show_success "Temporary directory: $TEMP_DIR"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

cleanup() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "CLEANUP"
    show_progress "Performing cleanup..."

    # ANNOTATION: Unmount filesystems in strict reverse order of mounting.
    log_debug "Attempting to unmount all installer filesystems."
    # Use a loop for robustness. -lf is a last resort.
    for mp in /mnt/boot/efi /mnt/boot /mnt; do
        if mountpoint -q "$mp"; then
            log_debug "Unmounting $mp..."
            umount "$mp" &>> "$LOG_FILE" || umount -f "$mp" &>> "$LOG_FILE" || umount -lf "$mp" &>> "$LOG_FILE"
        fi
    done
    
    # Unmount chroot/ramdisk environment if it was used
    if [[ -n "${RAMDISK_MNT:-}" ]] && mountpoint -q "$RAMDISK_MNT"; then
        log_debug "Unmounting RAM disk environment at $RAMDISK_MNT."
        for mp in "$RAMDISK_MNT"/dev "$RAMDISK_MNT"/proc "$RAMDISK_MNT"/sys; do
            if mountpoint -q "$mp"; then umount -lf "$mp" &>> "$LOG_FILE"; fi
        done
        umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE"
    fi

    # ANNOTATION: More robustly close LUKS mappers.
    # Reads the space-separated list into a proper array.
    if [[ -n "${CONFIG_VARS[LUKS_MAPPERS]:-}" ]]; then
        local luks_mappers_to_close=()
        read -r -a luks_mappers_to_close <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
        log_debug "Closing ${#luks_mappers_to_close[@]} LUKS mappers: ${luks_mappers_to_close[*]}"
        for mapper in "${luks_mappers_to_close[@]}"; do
            if [[ -e "/dev/mapper/$mapper" ]]; then
                log_debug "Closing LUKS mapper: $mapper"
                cryptsetup close "$mapper" &>> "$LOG_FILE" || log_debug "cryptsetup close $mapper failed (non-critical)."
            fi
        done
    fi

    # Export ZFS pool last, after all filesystems on it are unmounted.
    if [[ -n "${CONFIG_VARS[ZFS_POOL_NAME]:-}" ]]; then
        log_debug "Attempting to export ZFS pool ${CONFIG_VARS[ZFS_POOL_NAME]}."
        zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE" || log_debug "ZFS pool export failed (non-critical)."
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        log_debug "Removing temporary directory $TEMP_DIR."
        rm -rf "$TEMP_DIR"
    fi

    show_success "Cleanup complete."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

# --- Source new modular script files ---
# (Sourcing is good practice, kept as is)
source ./config_management.sh
source ./disk_operations.sh
source ./encryption_logic.sh
source ./zfs_logic.sh
source ./system_config.sh
source ./bootloader_logic.sh
source ./yubikey_setup.sh

gather_user_options() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "CONFIGURATION"

    # Initialize default values for ZFS native encryption
    CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]="no"
    CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]="no" 
    CONFIG_VARS[YUBIKEY_ZFS_KEY_SLOT]="6" # Default slot
    CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]="aes-256-gcm"

    # --- ZFS, Encryption, Clover, and Network TUIs ---
    # The original script's dialog-based TUI is very comprehensive. The key is to make
    # the logic loops more self-contained and robust.

    # ... The rest of the TUI logic for ZFS, network, etc. is excellent and can remain ...
    # ... Just ensure any simple yes/no dialogs are replaced with prompt_yes_no for robustness.

    # ZFS Native Encryption Prompts
    if prompt_yes_no "Enable ZFS native encryption for the root pool? (This encrypts the ZFS datasets directly. If 'no', standard LUKS2 full disk encryption will be used for the ZFS pool members.)"; then # Title "ZFS Native Encryption" ignored
        CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]="yes"
        local alg_choice
        echo "Select ZFS encryption algorithm (aes-256-gcm is recommended):"
        echo "  1. aes-256-gcm (Recommended)"
        echo "  2. aes-128-gcm"
        echo "  3. aes-256-ccm"
        echo "  4. aes-128-ccm"
        read -r -p "Enter choice [1-4, default 1]: " alg_choice
        case "$alg_choice" in
            1|"") CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]="aes-256-gcm" ;; # Default on empty input
            2) CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]="aes-128-gcm" ;;
            3) CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]="aes-256-ccm" ;;
            4) CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]="aes-128-ccm" ;;
            *)  show_warning "Invalid selection. Defaulting to aes-256-gcm."
                CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]="aes-256-gcm" ;;
        esac
        log_debug "User opted to use ZFS native encryption with algorithm: ${CONFIG_VARS[ZFS_ENCRYPTION_ALGORITHM]}."
    else
        CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]="no"
        log_debug "User opted not to use ZFS native encryption."
    fi

    # Prompts for YubiKey for ZFS key if ZFS native encryption is enabled
    if [[ "${CONFIG_VARS[ZFS_NATIVE_ENCRYPTION]}" == "yes" ]]; then
        if prompt_yes_no "Use a YubiKey to store and protect the ZFS native encryption key?
(This will use a small dedicated LUKS partition on the primary disk, unlocked by YubiKey, to hold the ZFS pool key.)"; then # Title "YubiKey for ZFS Key" ignored
            CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]="yes"
            log_debug "User opted to use YubiKey for ZFS native encryption key."

            local yk_slot_input
            read -r -p "Enter the YubiKey slot for the ZFS key LUKS partition (1-16, default 6): " yk_slot_input
            if [[ -z "$yk_slot_input" ]]; then
                yk_slot_input="6" # Default if empty
            fi
            if [[ "$yk_slot_input" =~ ^[0-9]+$ ]] && [[ "$yk_slot_input" -ge 1 ]] && [[ "$yk_slot_input" -le 16 ]]; then
                CONFIG_VARS[YUBIKEY_ZFS_KEY_SLOT]="$yk_slot_input"
            else
                show_warning "Invalid YubiKey slot '$yk_slot_input'. Defaulting to 6."
                CONFIG_VARS[YUBIKEY_ZFS_KEY_SLOT]="6"
            fi
            log_debug "YubiKey slot for ZFS key LUKS partition set to: ${CONFIG_VARS[YUBIKEY_ZFS_KEY_SLOT]}"
        else
            CONFIG_VARS[USE_YUBIKEY_FOR_ZFS_KEY]="no"
            log_debug "User opted not to use YubiKey for ZFS native encryption key."
        fi
    fi

    # Example for Clover prompt
    if prompt_yes_no "Install Clover bootloader on a separate drive?"; then # Title "Clover Bootloader Support" ignored
        CONFIG_VARS[USE_CLOVER]="yes"
        # Check for p7zip (7z command) if Clover is selected
        if ! command -v 7z &>/dev/null; then
            show_warning "The '7z' command (from p7zip-full) is required for Clover setup but is not found."
            if prompt_yes_no "Attempt to install p7zip-full now?" "Install p7zip-full"; then
                # Ensure package_management.sh functions are available
                # source "${SCRIPT_DIR}/package_management.sh" # This should already be sourced by main script
                if ensure_packages_installed "p7zip-full"; then
                    show_success "p7zip-full installed successfully."
                else
                    show_error "Failed to install p7zip-full. Clover setup cannot proceed."
                    show_warning "Disabling Clover installation due to missing dependency."
                    CONFIG_VARS[USE_CLOVER]="no"
                fi
            else
                show_warning "User declined to install p7zip-full. Clover setup cannot proceed."
                show_warning "Disabling Clover installation."
                CONFIG_VARS[USE_CLOVER]="no"
            fi
        fi

        if [[ "${CONFIG_VARS[USE_CLOVER]}" == "yes" ]]; then
            # ... logic to select Clover disk ...
            log_info "Clover bootloader installation selected and p7zip dependency met (or was pre-existing)."
        fi
    else
        CONFIG_VARS[USE_CLOVER]="no"
    fi


    # (Rest of the gather_user_options function as it was, it's very good)
    log_debug "Exiting function: ${FUNCNAME[0]}"
}


finalize() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "FINALIZE" "Finalizing Installation"

    # ANNOTATION: Finalize steps are the reverse of setup. Unmount, then close devices, then export pool.
    # The cleanup() function will handle this if the script exits early, but a successful run should do it cleanly.
    
    show_progress "Unmounting filesystems..."
    log_debug "Unmounting /mnt/boot/efi, /mnt/boot, /mnt."
    umount /mnt/boot/efi &>> "$LOG_FILE"
    umount /mnt/boot &>> "$LOG_FILE"
    umount /mnt &>> "$LOG_FILE"

    show_progress "Closing LUKS devices..."
    if [[ -n "${CONFIG_VARS[LUKS_MAPPERS]:-}" ]]; then
        local luks_mappers_to_close=()
        read -r -a luks_mappers_to_close <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
        for mapper in "${luks_mappers_to_close[@]}"; do
            cryptsetup close "$mapper" &>> "$LOG_FILE"
        done
    fi

    show_progress "Exporting ZFS pool..."
    zpool export "${CONFIG_VARS[ZFS_POOL_NAME]}" &>> "$LOG_FILE"

    # (The final summary message is excellent, kept as is)
    show_header "INSTALLATION COMPLETE"
    # ... summary text ...
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

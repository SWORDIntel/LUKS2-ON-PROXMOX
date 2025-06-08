#!/usr/bin/env bash
# Enhanced and simplified YubiKey support for Proxmox VE installer

# ANNOTATION: This helper function should be in a shared utils file.
_prompt_user_yes_no() {
    local prompt_text="$1" title="${2:-Confirmation}"
    if command -v dialog &>/dev/null; then
        dialog --title "$title" --yesno "$prompt_text" 10 70
    else
        while true; do read -p "$prompt_text [y/n]: " yn; case $yn in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer yes or no.";; esac; done
    fi
}

# Function to verify that required YubiKey tools are available.
# The actual installation should be handled by the main preflight_checks script.
check_yubikey_tools() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local required_tools=("yubikey-luks-enroll" "ykman") # ykman is the modern tool
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "CRITICAL: YubiKey tool '$tool' is not installed."
            show_error "Required YubiKey tool '$tool' is not installed. Please add 'yubikey-luks' and 'yubikey-manager' to your dependencies."
            return 1
        fi
    done
    
    log_debug "All required YubiKey tools are available."
    return 0
}

# Function to detect if a YubiKey is connected.
# This version is simplified to use the modern `ykman` tool.
detect_yubikey() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    # `ykman list` has a clean exit code and output for scripting.
    if ykman list | grep -q 'YubiKey'; then
        log_debug "YubiKey detected via ykman."
        return 0
    fi
    log_debug "No YubiKey detected."
    return 1
}

# ANNOTATION: The most significant change. This function is now drastically simplified.
# It no longer tries to script the interactive tool. It just calls the tool and lets it work.
enroll_yubikey_for_luks() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local device="$1"
    local slot="${2:-7}" # Default to a safe slot

    if [[ -z "$device" ]]; then
        log_error "No device specified for YubiKey enrollment." && return 1
    fi

    # 1. Inform the user what is about to happen.
    dialog --title "YubiKey Enrollment" --infobox "The system will now enroll your YubiKey for the LUKS device: $device\n\n1. You will be prompted for your existing LUKS passphrase.\n2. You will be prompted to touch your YubiKey when it flashes.\n\nPlease follow the on-screen instructions." 12 70
    sleep 4 # Give user time to read.

    # 2. Call the tool and let it handle the interactive session directly.
    #    The tool's prompts will appear on the user's terminal (TTY).
    log_debug "Calling 'yubikey-luks-enroll' for device $device on slot $slot"
    if yubikey-luks-enroll -d "$device" -s "$slot"; then
        log_info "YubiKey enrollment successful for $device."
        dialog --title "Success" --msgbox "YubiKey successfully enrolled for:\n$device" 8 60
        return 0
    else
        local enroll_status=$?
        log_error "yubikey-luks-enroll failed for $device with exit code $enroll_status."
        dialog --title "Enrollment Failed" --msgbox "YubiKey enrollment failed for:\n$device\n\nPlease check the logs. The system will continue without YubiKey support for this device." 10 70
        return 1
    fi
}

# The main controller function for the entire YubiKey setup process.
setup_luks_with_yubikey() {
    log_debug "Entering function: ${FUNCNAME[0]}"

    # Only run if the user selected this option in the main configuration.
    if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" != "yes" ]]; then
        log_debug "YubiKey support not requested, skipping."
        return 0
    fi

    show_step "YUBIKEY" "Setting up LUKS with YubiKey"

    # 1. Verify that the required tools are installed on the system.
    if ! check_yubikey_tools; then
        show_error "Cannot proceed with YubiKey setup because required tools are missing."
        return 1
    fi
    show_success "Required YubiKey tools are present."

    # 2. Check for a YubiKey and wait for the user to insert one if not found.
    if ! detect_yubikey; then
        if ! _prompt_user_yes_no "No YubiKey detected. Please insert your YubiKey now and press Yes to continue, or No to skip YubiKey setup." "Insert YubiKey"; then
            show_warning "User chose to skip YubiKey setup."
            # Update the global config so other parts of the script know not to use YubiKey features.
            CONFIG_VARS[USE_YUBIKEY]="no"
            return 0
        fi
        
        # Give a few seconds for the device to be recognized.
        show_progress "Waiting for YubiKey to be detected..."
        sleep 3
        if ! detect_yubikey; then
            show_error "YubiKey was still not detected. Skipping YubiKey setup."
            CONFIG_VARS[USE_YUBIKEY]="no"
            return 1
        fi
    fi
    show_success "YubiKey detected and ready for enrollment."

    # 3. Loop through all LUKS partitions and enroll the YubiKey for each one.
    local luks_partitions_arr=()
    read -r -a luks_partitions_arr <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    if [[ ${#luks_partitions_arr[@]} -eq 0 ]]; then
        show_error "No LUKS partitions are defined in the configuration."
        return 1
    fi

    local successful_enrollments=0
    for part in "${luks_partitions_arr[@]}"; do
        if _prompt_user_yes_no "Do you want to enroll your YubiKey for the device:\n\n  $part" "Confirm Enrollment"; then
            if enroll_yubikey_for_luks "$part"; then
                successful_enrollments=$((successful_enrollments + 1))
            else
                show_warning "Failed to enroll YubiKey for $part. Continuing to the next disk."
                # Allow the user to decide if they want to stop the whole installation on a single failure.
                if ! _prompt_user_yes_no "Enrollment failed for $part. Continue with the installation (without YubiKey on this disk)?" "Enrollment Failed"; then
                    show_error "Installation cancelled by user due to YubiKey enrollment failure."
                    exit 1
                fi
            fi
        else
            show_warning "Skipped YubiKey enrollment for $part."
        fi
    done

    if [[ $successful_enrollments -eq 0 ]]; then
        show_warning "No YubiKeys were enrolled. Proceeding with passphrase-only encryption."
        CONFIG_VARS[USE_YUBIKEY]="no" # Reflect that no keys were actually enrolled.
        return 1
    fi

    show_success "YubiKey setup completed for $successful_enrollments partition(s)."
    return 0
}
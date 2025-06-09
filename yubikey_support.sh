#!/usr/bin/env bash
# Enhanced and simplified YubiKey support for Proxmox VE installer

# ANNOTATION: Local _prompt_user_yes_no removed. Using prompt_yes_no from ui_functions.sh.

# Function to verify that required YubiKey tools are available.
# The actual installation should be handled by the main preflight_checks script.
check_yubikey_tools() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local all_tools_ok=true

    # Check for yubikey-luks-enroll (essential for LUKS operations)
    if ! command -v "yubikey-luks-enroll" &>/dev/null; then
        log_error "CRITICAL: YubiKey tool 'yubikey-luks-enroll' (from 'yubikey-luks' package) is not installed."
        show_error "Required YubiKey tool 'yubikey-luks-enroll' is not installed. This is essential for YubiKey LUKS support."
        all_tools_ok=false
    else
        log_debug "Tool 'yubikey-luks-enroll' is available."
    fi

    # Check for ykman (from yubikey-manager), install if missing
    if ! command -v "ykman" &>/dev/null; then
        log_warning "YubiKey tool 'ykman' (from 'yubikey-manager' package) is not installed. Attempting installation."
        show_progress "Attempting to install 'yubikey-manager' for YubiKey support..."
        
        local ykman_pkg="yubikey-manager"
        if type ensure_packages_installed &>/dev/null; then
            log_info "Using 'ensure_packages_installed' to install '$ykman_pkg'."
            if ! ensure_packages_installed "$ykman_pkg"; then
                log_error "'ensure_packages_installed' failed for '$ykman_pkg'."
                show_error "Failed to install 'yubikey-manager'. YubiKey detection and management might be limited."
                all_tools_ok=false
            else
                log_info "'$ykman_pkg' installed successfully via ensure_packages_installed."
                if ! command -v "ykman" &>/dev/null; then # Verify after install
                    log_error "CRITICAL: 'ykman' still not found after supposedly successful installation of '$ykman_pkg'."
                    show_error "Installation of 'yubikey-manager' reported success, but 'ykman' command is still missing."
                    all_tools_ok=false
                fi
            fi
        else
            log_warning "'ensure_packages_installed' function not found. Falling back to basic 'apt-get' for '$ykman_pkg'."
            show_warning "Using basic 'apt-get' for 'yubikey-manager' as 'ensure_packages_installed' is unavailable."
            if ! apt-get update &>> "$LOG_FILE" || ! apt-get install -y "$ykman_pkg" &>> "$LOG_FILE"; then
                log_error "apt-get install for '$ykman_pkg' failed."
                show_error "Failed to install 'yubikey-manager' using apt-get. YubiKey detection might be limited."
                all_tools_ok=false
            else
                log_info "'$ykman_pkg' installed successfully via apt-get."
                if ! command -v "ykman" &>/dev/null; then # Verify after install
                    log_error "CRITICAL: 'ykman' still not found after supposedly successful apt-get installation of '$ykman_pkg'."
                    show_error "apt-get installation of 'yubikey-manager' reported success, but 'ykman' command is still missing."
                    all_tools_ok=false
                fi
            fi
        fi
    else
        log_debug "Tool 'ykman' is available."
    fi

    if ! $all_tools_ok; then
        log_error "One or more YubiKey tools are missing or could not be installed."
        return 1
    fi

    log_debug "All required YubiKey tools are now available."
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
    show_message "YubiKey Enrollment" \
        "The system will now enroll your YubiKey for the LUKS device: $device" \
        "" \
        "1. You will be prompted for your existing LUKS passphrase." \
        "2. You will be prompted to touch your YubiKey when it flashes." \
        "" \
        "Please follow the on-screen instructions."
    sleep 4 # Give user time to read.

    # 2. Call the tool and let it handle the interactive session directly.
    #    The tool's prompts will appear on the user's terminal (TTY).
    log_debug "Calling 'yubikey-luks-enroll' for device $device on slot $slot"
    if yubikey-luks-enroll -d "$device" -s "$slot"; then
        log_info "YubiKey enrollment successful for $device."
        show_message "Success" "YubiKey successfully enrolled for:" "$device" "" "Press Enter to continue." && read -r
        return 0
    else
        local enroll_status=$?
        log_error "yubikey-luks-enroll failed for $device with exit code $enroll_status."
        show_message "Enrollment Failed" \
            "YubiKey enrollment failed for:" \
            "$device" \
            "" \
            "Please check the logs." \
            "The system will continue without YubiKey support for this device." \
            "" \
            "Press Enter to continue." && read -r
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
        if ! prompt_yes_no "No YubiKey detected. Please insert your YubiKey now and press Yes to continue, or No to skip YubiKey setup."; then
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
        if prompt_yes_no "Do you want to enroll your YubiKey for the device:\n\n  $part"; then
            if enroll_yubikey_for_luks "$part"; then
                successful_enrollments=$((successful_enrollments + 1))
            else
                show_warning "Failed to enroll YubiKey for $part. Continuing to the next disk."
                # Allow the user to decide if they want to stop the whole installation on a single failure.
                if ! prompt_yes_no "Enrollment failed for $part. Continue with the installation (without YubiKey on this disk)?"; then
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
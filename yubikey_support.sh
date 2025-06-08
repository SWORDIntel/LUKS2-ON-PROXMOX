#!/usr/bin/env bash
# Enhanced YubiKey support for Proxmox VE installer

# Function to check if YubiKey-related packages and tools are installed
check_yubikey_tools() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Check for required YubiKey tools
    local required_tools=("yubikey-luks-enroll" "ykinfo" "ykchalresp")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_debug "Missing YubiKey tool: $tool"
            missing_tools+=("$tool")
        else
            log_debug "Found YubiKey tool: $tool ($(command -v "$tool"))"
        fi
    done
    
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        log_debug "All required YubiKey tools are available"
        return 0
    else
        log_debug "Missing YubiKey tools: ${missing_tools[*]}"
        return 1
    fi
}

# Function to detect if a YubiKey is connected
detect_yubikey() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # First try using lsusb to detect YubiKey
    if lsusb | grep -i -q "yubikey"; then
        log_debug "YubiKey detected via lsusb"
        return 0
    fi
    
    # Try with ykinfo if available
    if command -v ykinfo &>/dev/null; then
        if ykinfo -v1 &>/dev/null; then
            log_debug "YubiKey detected via ykinfo"
            return 0
        fi
    fi
    
    log_debug "No YubiKey detected"
    return 1
}

# Function to install YubiKey packages
install_yubikey_packages() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Check if packages are already installed
    if check_yubikey_tools; then
        log_debug "YubiKey tools already installed"
        show_success "YubiKey tools already installed"
        return 0
    fi
    
    show_progress "Installing YubiKey support packages..."
    
    # Multi-stage package installation with fallbacks
    local stage=1
    local installation_successful=false
    
    # Stage 1: Try apt install if internet is available
    if [[ $stage -eq 1 ]]; then
        log_debug "Stage $stage: Trying apt installation"
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            apt-get update &>> "$LOG_FILE"
            if apt-get install -y yubikey-luks libyubikey-udev yubikey-personalization &>> "$LOG_FILE"; then
                log_debug "YubiKey packages installed via apt"
                installation_successful=true
            else
                log_debug "Failed to install YubiKey packages via apt"
                stage=$((stage + 1))
            fi
        else
            log_debug "No internet connection, skipping apt installation"
            stage=$((stage + 1))
        fi
    fi
    
    # Stage 2: Try installing from local debs
    if [[ $stage -eq 2 && "$installation_successful" == "false" ]]; then
        log_debug "Stage $stage: Trying local deb installation"
        local debs_dir="$SCRIPT_DIR/debs"
        
        if [ -d "$debs_dir" ]; then
            local yubikey_debs
mapfile -t yubikey_debs < <(find "$debs_dir" -name "*yubikey*.deb" -o -name "*yubico*.deb")
            
            if [ ${#yubikey_debs[@]} -gt 0 ]; then
                log_debug "Found ${#yubikey_debs[@]} YubiKey-related deb packages"
                show_progress "Installing YubiKey support from ${#yubikey_debs[@]} local packages..."
                
                # Install all YubiKey related packages
                for deb in "${yubikey_debs[@]}"; do
                    log_debug "Installing $deb"
                    dpkg -i "$deb" &>> "$LOG_FILE" || true
                done
                
                # Fix any dependency issues
                apt-get install -f -y &>> "$LOG_FILE"
                
                if check_yubikey_tools; then
                    log_debug "YubiKey tools installed from local packages"
                    installation_successful=true
                else
                    log_debug "Failed to install all required YubiKey tools from local packages"
                    stage=$((stage + 1))
                fi
            else
                log_debug "No YubiKey packages found in $debs_dir"
                stage=$((stage + 1))
            fi
        else
            log_debug "Local debs directory $debs_dir does not exist"
            stage=$((stage + 1))
        fi
    fi # Closes: if [[ $stage -eq 2 ... ]] 
    
    # Stage 3: Install minimum required scripts if packages failed
    if [[ $stage -eq 3 && "$installation_successful" == "false" ]]; then
        log_debug "Stage $stage: Installing minimal YubiKey scripts"
        show_progress "Installing minimal YubiKey scripts..."
        
        # Create directory for YubiKey scripts
        mkdir -p /usr/local/sbin &>> "$LOG_FILE"
        
        # Write minimal yubikey-luks-enroll script
        cat > /usr/local/sbin/yubikey-luks-enroll << 'EOF'
#!/bin/bash
# Minimal yubikey-luks-enroll script
set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <device> <slot> [challenge]"
    exit 1
fi

DEVICE="$1"
SLOT="$2"
CHALLENGE="${3:-}"

# Check if YubiKey is present
if ! ykinfo -v1 &>/dev/null; then
    echo "Error: No YubiKey detected"
    exit 1
fi

if [ -z "$CHALLENGE" ]; then
    CHALLENGE=$(head -c 64 /dev/urandom | xxd -p -c 64)
fi

echo "Using challenge: $CHALLENGE"
echo "Insert your YubiKey and touch it when it starts blinking..."

RESPONSE=$(ykchalresp -2 "$CHALLENGE" 2>/dev/null || echo "")

if [ -z "$RESPONSE" ]; then
    echo "Error: Failed to get response from YubiKey"
    exit 1
fi

LUKS_KEY="${CHALLENGE}${RESPONSE}"
echo "Enrolling YubiKey for LUKS device $DEVICE in slot $SLOT..."
echo -n "$LUKS_KEY" | cryptsetup luksAddKey "$DEVICE" --key-slot "$SLOT" -

echo "YubiKey enrolled successfully in slot $SLOT for $DEVICE"
exit 0
EOF

        chmod +x /usr/local/sbin/yubikey-luks-enroll &>> "$LOG_FILE"
        
        # Create symlink to common path
        ln -sf /usr/local/sbin/yubikey-luks-enroll /usr/bin/yubikey-luks-enroll &>> "$LOG_FILE"
        
        if check_yubikey_tools; then
            log_debug "Minimal YubiKey scripts installed successfully"
            installation_successful=true
        else
            log_debug "Failed to install minimal YubiKey scripts"
        fi
    fi # Closes: if [[ $stage -eq 3 ... ]]
}
    
    # Check if installation was successful
    if [[ "$installation_successful" == "true" ]]; then
        show_success "YubiKey support installed successfully"
        return 0
    else
        show_error "Failed to install YubiKey support"
        return 1
    fi

# Function to enroll a YubiKey for LUKS encryption
enroll_yubikey_for_luks() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    local device="$1"
    local slot="${2:-7}"  # Default to slot 7
    
    if [ -z "$device" ]; then
        log_debug "No device specified for YubiKey enrollment"
        show_error "No device specified for YubiKey enrollment"
        return 1
    fi
    
    # Make sure YubiKey packages are installed
    if ! install_yubikey_packages; then
        log_debug "Failed to install required YubiKey packages"
        show_warning "YubiKey support not fully installed, enrollment may fail"
    fi
    
    # Detect if a YubiKey is present
    if ! detect_yubikey; then
        log_debug "No YubiKey detected"
        dialog --title "YubiKey Enrollment" --msgbox "No YubiKey detected. Please insert your YubiKey and try again." 8 60
        
        # Wait for YubiKey to be inserted
        show_progress "Waiting for YubiKey to be inserted..."
        local attempt=0
        local max_attempts=30
        while [ $attempt -lt $max_attempts ]; do
            if detect_yubikey; then
                log_debug "YubiKey detected after waiting"
                break
            fi
            sleep 1
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -eq $max_attempts ]; then
            log_debug "Timed out waiting for YubiKey"
            show_error "Timed out waiting for YubiKey"
            return 1
        fi
    fi
    
    log_debug "YubiKey detected, proceeding with enrollment"
    show_progress "YubiKey detected, proceeding with enrollment..."
    
    # Generate a random challenge
    local challenge
    challenge=$(head -c 64 /dev/urandom | xxd -p -c 64)
    log_debug "Generated random challenge for YubiKey: $challenge"
    
    # Ask user for the LUKS passphrase
    local luks_passphrase
    luks_passphrase=$(dialog --title "LUKS Passphrase" --passwordbox "Enter the existing LUKS passphrase:" 10 60 3>&1 1>&2 2>&3) || { 
        log_debug "LUKS passphrase entry cancelled"
        show_error "YubiKey enrollment cancelled"
        return 1
    }
    
    # Ask user to confirm YubiKey enrollment
    if ! (dialog --title "YubiKey Enrollment" --yesno "Ready to enroll YubiKey for LUKS encryption. Your YubiKey will be used as a second factor for unlocking the encrypted disk.\n\nPress YES to continue." 10 70); then
        log_debug "YubiKey enrollment cancelled by user"
        show_warning "YubiKey enrollment cancelled by user"
        return 1
    fi
    
    # Show instructions to the user
    dialog --title "YubiKey Enrollment" --msgbox "Touch your YubiKey when it starts blinking..." 8 60
    
    # Create a temporary file to capture output
    local temp_output
    temp_output=$(mktemp)
    
    # Run the enrollment command with timeout
    log_debug "Running yubikey-luks-enroll for device $device in slot $slot"
    if ! (echo "$luks_passphrase" | timeout 30s yubikey-luks-enroll "$device" "$slot" "$challenge" &> "$temp_output"); then
        local error_msg
        error_msg=$(cat "$temp_output")
        log_debug "YubiKey enrollment failed: $error_msg"
        rm -f "$temp_output"
        
        # Show a more user-friendly error message
        dialog --title "YubiKey Enrollment Failed" --msgbox "Failed to enroll YubiKey for LUKS encryption.\n\nError: $error_msg\n\nThe system will continue without YubiKey support." 12 70
        show_warning "YubiKey enrollment failed, continuing without YubiKey support"
        return 1
    fi
    
    # Success
    log_debug "YubiKey enrolled successfully for device $device in slot $slot"
    rm -f "$temp_output"
    
    dialog --title "YubiKey Enrollment Success" --msgbox "YubiKey enrolled successfully for LUKS encryption.\n\nYour encrypted disk can now be unlocked using your YubiKey as a second factor." 10 70
    show_success "YubiKey enrolled successfully for LUKS encryption"
    
    return 0
}

# Function to setup LUKS with YubiKey support
setup_luks_with_yubikey() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "YUBIKEY" "Setting up LUKS with YubiKey support"
    
    # Check if YubiKey support is requested
    if [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" != "yes" ]]; then
        log_debug "YubiKey support not requested, skipping"
        return 0
    fi
    
    # Get LUKS partitions
    local luks_partitions_arr=()
    read -r -a luks_partitions_arr <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    
    if [[ ${#luks_partitions_arr[@]} -eq 0 ]]; then
        log_debug "No LUKS partitions defined, cannot setup YubiKey"
        show_error "No LUKS partitions defined, cannot setup YubiKey"
        return 1
    fi
    
    log_debug "Setting up YubiKey support for ${#luks_partitions_arr[@]} LUKS partitions"
    
    # Install YubiKey packages
    if ! install_yubikey_packages; then
        log_debug "Failed to install YubiKey packages, cannot continue with YubiKey setup"
        show_error "Failed to install YubiKey packages, skipping YubiKey setup"
        return 1
    fi
    
    # Ask user if they want to enroll a YubiKey now
    if ! (dialog --title "YubiKey Setup" --yesno "Do you want to enroll a YubiKey for LUKS encryption now?" 8 60); then
        log_debug "User chose to skip YubiKey enrollment"
        show_warning "YubiKey enrollment skipped by user"
        return 0
    fi
    
    # Process each LUKS partition
    local enrollment_success=0
    for part in "${luks_partitions_arr[@]}"; do
        log_debug "Enrolling YubiKey for LUKS partition: $part"
        show_progress "Enrolling YubiKey for LUKS partition: $part"
        
        if enroll_yubikey_for_luks "$part" 7; then
            log_debug "YubiKey enrollment successful for $part"
            enrollment_success=$((enrollment_success + 1))
        else
            log_debug "YubiKey enrollment failed for $part"
        fi
    done
    
    if [[ $enrollment_success -gt 0 ]]; then
        log_debug "YubiKey enrolled successfully for $enrollment_success partition(s)"
        show_success "YubiKey enrolled successfully for $enrollment_success partition(s)"
        return 0
    else
        log_debug "YubiKey enrollment failed for all partitions"
        show_warning "YubiKey enrollment failed for all partitions, continuing without YubiKey support"
        return 1
    fi
}

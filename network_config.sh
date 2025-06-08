#!/usr/bin/env bash

#############################################################
# Network Configuration Functions
#############################################################

# Function to check for basic network connectivity 
check_basic_connectivity() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_debug "Network connectivity available."
        return 0
    fi
    log_debug "No network connectivity detected."
    return 1
}

# Function to set up minimal networking before RAM pivot
configure_minimal_network() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_progress "Setting up minimal network connectivity before RAM pivot..."
    
    # Try DHCP first on all interfaces
    local interfaces
    interfaces=$(ip -o link show | grep -v lo | awk -F': ' '{print $2}')
    for interface in $interfaces; do
        log_debug "Attempting DHCP on interface: $interface"
        ip link set "$interface" up &>> "$LOG_FILE"
        timeout 5 dhclient -1 "$interface" &>> "$LOG_FILE" || true
        
        # Test if we have connectivity
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log_debug "Network connectivity established on $interface via DHCP"
            show_success "Network connectivity established"
            # Set basic DNS for package downloads
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            return 0
        fi
    done
    
    # If DHCP failed, we just set up minimal static config
    # This is just for downloading packages before RAM pivot
    # Full network config will happen after RAM pivot
    log_debug "DHCP failed, setting up minimal static IP"
    show_warning "DHCP failed, using minimal static networking"
    
    local main_interface
    main_interface=$(ip -o link show | grep -v lo | head -1 | awk -F': ' '{print $2}')
    if [[ -n "$main_interface" ]]; then
        ip link set "$main_interface" up &>> "$LOG_FILE"
        ip addr add "192.168.1.100/24" dev "$main_interface" &>> "$LOG_FILE"
        ip route add default via "192.168.1.1" dev "$main_interface" &>> "$LOG_FILE"
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        log_debug "Minimal static network configured on $main_interface"
    fi
    
    # Don't fail if network isn't available yet - we'll configure properly in RAM
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

# Function to download packages for offline installation
download_offline_packages() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Check if we're already running from RAM
    # shellcheck disable=SC2154 # run_from_ram is set in the main installer.sh
    if [[ "$run_from_ram" == true ]]; then
        log_debug "Running from RAM, skipping pre-RAM package downloads"
        return 0
    fi
    
    # Check for internet connectivity
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_debug "No internet connectivity for downloading packages"
        show_warning "No internet connectivity for package downloads. Ensure the 'debs' directory is populated for air-gapped installation."
        return 0
    fi
    
    log_debug "Internet connection detected for package downloads"
    show_progress "Internet connection detected for package downloads"
    
    # Check if debs directory exists
    debs_dir="$SCRIPT_DIR/debs"
    log_debug "Debs directory path: $debs_dir"
    
    # Ensure download_debs.sh exists and is executable
    download_script_path="$SCRIPT_DIR/download_debs.sh"
    log_debug "Download script path: $download_script_path"
    
    if [ ! -f "$download_script_path" ]; then
        log_debug "download_debs.sh script not found"
        show_warning "Warning: download_debs.sh script not found. Cannot download .deb packages."
        return 1
    elif [ ! -x "$download_script_path" ]; then
        log_debug "download_debs.sh not executable"
        chmod +x "$download_script_path" &>> "$LOG_FILE"
        if [ ! -x "$download_script_path" ]; then
            show_warning "Warning: download_debs.sh is not executable. Failed to set permissions."
            return 1
        fi
        log_debug "Made download_debs.sh executable"
    fi
    
    log_debug "download_debs.sh found and is executable"
    
    # Check if debs dir is empty
    proceed_with_download=false
    if [ ! -d "$debs_dir" ] || [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
        log_debug "'debs' directory is missing or empty"
        proceed_with_download=true
    else
        log_debug "'debs' directory already contains files"
        show_progress "Local 'debs' directory already contains packages"
    fi
    
    if [[ "$proceed_with_download" == true ]]; then
        if (dialog --title "Download .deb Packages" --yesno "The local 'debs' directory is empty. This installer can download required .deb packages for offline installation. Would you like to download them now?" 12 78); then
            log_debug "User chose to download .deb packages"
            show_progress "Downloading packages for offline installation..."
            
            mkdir -p "$debs_dir" &>> "$LOG_FILE"
            if "$download_script_path"; then
                log_debug "download_debs.sh script executed successfully"
                if [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
                    log_debug "'debs' directory still empty after download attempt"
                    show_warning "The 'debs' directory is still empty after download attempt. Check package_urls.txt and internet connection."
                else
                    log_debug "'debs' directory populated successfully"
                    show_success "Packages downloaded successfully for offline installation"
                fi
            else
                log_debug "download_debs.sh script failed with status: $?"
                show_error "Failed to download packages. Check the logs for details."
            fi
        else
            log_debug "User skipped .deb package download"
            show_warning "Skipping package downloads. For air-gapped installations, ensure 'debs' directory is populated manually."
        fi
    fi
    
    # Remind about copying to USB for air-gapped installations
    dialog --title "Prepare USB Stick" --msgbox "If you intend to run this installer on an air-gapped machine, please ensure you copy the ENTIRE installer directory (including the 'debs' folder) to your USB stick." 10 70
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

# Configure full network in RAM environment
configure_network_in_ram() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "NETWORK CONFIGURATION"
    show_step "NETWORK" "Configuring network in RAM environment"
    
    # Check if we already have connectivity
    if check_basic_connectivity; then
        log_debug "Network already configured and working in RAM environment"
        show_success "Network connectivity already established in RAM environment"
        return 0
    fi
    
    # Try DHCP first on all interfaces
    local interfaces
    interfaces=$(ip -o link show | grep -v lo | awk -F': ' '{print $2}')
    log_debug "Available interfaces in RAM: $interfaces"
    
    show_progress "Attempting automatic network configuration in RAM..."
    for interface in $interfaces; do
        log_debug "Attempting DHCP on interface: $interface"
        ip link set "$interface" up &>> "$LOG_FILE"
        timeout 10 dhclient -1 "$interface" &>> "$LOG_FILE" || true
        
        # Test if we have connectivity
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log_debug "Network connectivity established on $interface via DHCP"
            show_success "Network connectivity established on $interface"
            # Set DNS servers
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            return 0
        fi
    done
    
    # If automatic config fails, call the full interactive network configuration
    log_debug "Automatic network configuration failed in RAM, falling back to interactive setup"
    show_warning "Automatic network configuration failed, manual setup required"
    configure_network_early
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

#############################################################
# Original Early Network Configuration 
#############################################################
configure_network_early() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "NETWORK" "Configuring Network Connection"

    # Check if we already have internet connectivity
    log_debug "Checking for existing internet connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_debug "Network connectivity already available."
        show_success "Network connectivity already available"
        return 0
    fi

    log_debug "No network connectivity detected. Configuration required."
    show_warning "No network connectivity detected. Configuration required."

    # Get available interfaces
    log_debug "Getting available network interfaces..."
    local ifaces; ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -5)
    if [[ -z "$ifaces" ]]; then
        log_debug "No network interfaces found!"
        show_error "No network interfaces found!"
        exit 1
    fi
    log_debug "Available interfaces: $ifaces"

    # For early setup, try DHCP on all available interfaces
    log_debug "Attempting DHCP on available interfaces..."
    show_progress "Attempting DHCP on available interfaces..."
    for iface in $ifaces; do
        log_debug "Trying DHCP on $iface..."
        show_progress "Trying DHCP on $iface..."
        log_debug "Executing: ip link set $iface up"
        ip link set "$iface" up &>> "$LOG_FILE"
        log_debug "Executing: dhclient -1 -v $iface"
        if dhclient -1 -v "$iface" &>> "$LOG_FILE"; then # Capture dhclient output
            log_debug "dhclient for $iface succeeded. Checking connectivity..."
            if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                log_debug "Network configured successfully on $iface via DHCP."
                show_success "Network configured successfully on $iface"
                return 0
            else
                log_debug "DHCP on $iface seemed to work, but ping failed."
            fi
        else
            log_debug "dhclient for $iface failed."
        fi
    done

    # If DHCP failed, manual configuration
    log_debug "DHCP failed on all interfaces. Manual configuration required."
    show_warning "DHCP failed. Manual network configuration required."

    # Manual network setup using dialog
    log_debug "Preparing for manual network setup dialog with improved interface detection."

    local all_potential_ifaces=()
    if [[ -d "/sys/class/net" ]]; then
        for iface_path in /sys/class/net/*; do
            local iface_name
            iface_name=$(basename "$iface_path")
            # Apply filtering
            if [[ "$iface_name" == "lo" || \
                  "$iface_name" == veth* || \
                  "$iface_name" == virbr* || \
                  "$iface_name" == docker* || \
                  "$iface_name" == tun* || \
                  "$iface_name" == tap* ]]; then
                log_debug "Excluding interface from manual selection list: $iface_name"
                continue
            fi
            all_potential_ifaces+=("$iface_name")
        done
    fi
    log_debug "Filtered potential interfaces for manual selection: ${all_potential_ifaces[*]}"

    local iface_options=()
    if [[ ${#all_potential_ifaces[@]} -gt 0 ]]; then
        for iface_item in "${all_potential_ifaces[@]}"; do
            # Fetch status and IP for dialog
            local status; status=$(ip link show "$iface_item" 2>/dev/null | grep -q "state UP" && echo "UP" || echo "DOWN")
            local current_ip; current_ip=$(ip addr show "$iface_item" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
            local info_str="$status" # Renamed to avoid conflict with info command
            [[ -n "$current_ip" ]] && info_str+=" ($current_ip)"
            iface_options+=("$iface_item" "$iface_item $info_str" "off") # Added "off" for radiolist default
        done
    fi
    log_debug "Interface options for dialog: ${iface_options[*]}"

    local selected_iface
    if [[ $((${#iface_options[@]}/3)) -eq 0 ]]; then # Each option has 3 parts (tag, item, status)
        log_debug "No suitable interfaces found after filtering for manual selection dialog."
        dialog --title "Network Setup" --infobox "No suitable network interfaces were automatically detected for selection." 5 70
        sleep 2

        selected_iface=$(dialog --title "Manual Network Interface" \
            --inputbox "Please enter the network interface name you wish to configure manually (e.g., enp3s0):" 10 60 \
            3>&1 1>&2 2>&3) || {
                log_error "Manual interface input cancelled by user.";
                show_error "Network configuration cancelled by user."
                exit 1;
            }
        if [[ -z "$selected_iface" ]]; then
            log_error "No interface name entered by user during manual input."
            show_error "No network interface name provided. Cannot proceed."
            exit 1
        fi
        log_debug "User manually entered interface: $selected_iface"
    else
        selected_iface=$(dialog --title "Network Interface" \
            --radiolist "Select network interface to configure:" 15 70 $((${#iface_options[@]}/3)) \
            "${iface_options[@]}" 3>&1 1>&2 2>&3) || {
                log_debug "Manual interface selection (radiolist) cancelled.";
                show_error "Network configuration cancelled by user."
                exit 1;
            }
    fi
    log_debug "User selected interface for manual configuration: $selected_iface"

    local ip_addr
    ip_addr=$(dialog --title "IP Address" \
        --inputbox "Enter IP address with CIDR (e.g., 192.168.1.100/24):" 10 60 \
        "192.168.1.100/24" 3>&1 1>&2 2>&3) || { log_debug "Manual IP address entry cancelled."; exit 1; }
    log_debug "User entered IP address: $ip_addr"

    local gateway
    gateway=$(dialog --title "Gateway" \
        --inputbox "Enter gateway IP:" 10 60 \
        "192.168.1.1" 3>&1 1>&2 2>&3) || { log_debug "Manual gateway entry cancelled."; exit 1; }
    log_debug "User entered gateway: $gateway"

    # Configure interface
    log_debug "Executing: ip link set $selected_iface up"
    ip link set "$selected_iface" up &>> "$LOG_FILE"
    log_debug "Executing: ip addr add $ip_addr dev $selected_iface"
    ip addr add "$ip_addr" dev "$selected_iface" &>> "$LOG_FILE"
    log_debug "Executing: ip route add default via $gateway"
    ip route add default via "$gateway" &>> "$LOG_FILE"
    log_debug "IP address and route configured."

    # Configure DNS with Cloudflare and Google DNS
    log_debug "Configuring DNS in /etc/resolv.conf with 1.1.1.1 and 8.8.8.8"
    if [[ -L "/etc/resolv.conf" ]]; then
        log_debug "/etc/resolv.conf is a symlink. Attempting to write."
        show_warning "/etc/resolv.conf is a symlink. Attempting to write, but manual DNS configuration might be needed if changes don't persist."
        if ! echo "nameserver 1.1.1.1" > /etc/resolv.conf 2>> "$LOG_FILE"; then
            log_debug "Failed to write 'nameserver 1.1.1.1' to /etc/resolv.conf (symlink target likely not writable)."
            show_error "Failed to write to /etc/resolv.conf (symlink target likely not writable)."
        else
            log_debug "Wrote 'nameserver 1.1.1.1' to /etc/resolv.conf."
            if ! echo "nameserver 8.8.8.8" >> /etc/resolv.conf 2>> "$LOG_FILE"; then
                 log_debug "Failed to append 'nameserver 8.8.8.8' to /etc/resolv.conf."
                 show_warning "Failed to append to /etc/resolv.conf (symlink target)."
            else
                 log_debug "Appended 'nameserver 8.8.8.8' to /etc/resolv.conf."
            fi
        fi
    elif [[ ! -w "/etc/resolv.conf" ]]; then
        log_debug "/etc/resolv.conf is not writable."
        show_error "/etc/resolv.conf is not writable. Cannot configure DNS automatically."
    else
        log_debug "Writing DNS servers 1.1.1.1 and 8.8.8.8 to /etc/resolv.conf."
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        log_debug "DNS configured in /etc/resolv.conf."
        show_success "DNS configured in /etc/resolv.conf"
    fi

    # Test connectivity
    log_debug "Testing final network connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_debug "Network configured successfully (manual setup)."
        show_success "Network configured successfully"
    else
        log_debug "Manual network configuration failed (ping test failed)."
        show_error "Network configuration failed. Please check your settings."
        exit 1
    fi
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

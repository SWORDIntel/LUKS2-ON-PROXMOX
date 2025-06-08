#!/usr/bin/env bash

#############################################################
# Early Network Configuration
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

    # Configure DNS
    log_debug "Configuring DNS in /etc/resolv.conf"
    if [[ -L "/etc/resolv.conf" ]]; then
        log_debug "/etc/resolv.conf is a symlink. Attempting to write."
        show_warning "/etc/resolv.conf is a symlink. Attempting to write, but manual DNS configuration might be needed if changes don't persist."
        if ! echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>> "$LOG_FILE"; then # Capture potential errors
            log_debug "Failed to write 'nameserver 8.8.8.8' to /etc/resolv.conf (symlink target likely not writable)."
            show_error "Failed to write to /etc/resolv.conf (symlink target likely not writable)."
        else
            log_debug "Wrote 'nameserver 8.8.8.8' to /etc/resolv.conf."
            if ! echo "nameserver 8.8.4.4" >> /etc/resolv.conf 2>> "$LOG_FILE"; then
                 log_debug "Failed to append 'nameserver 8.8.4.4' to /etc/resolv.conf."
                 show_warning "Failed to append to /etc/resolv.conf (symlink target)."
            else
                 log_debug "Appended 'nameserver 8.8.4.4' to /etc/resolv.conf."
            fi
        fi
    elif [[ ! -w "/etc/resolv.conf" ]]; then
        log_debug "/etc/resolv.conf is not writable."
        show_error "/etc/resolv.conf is not writable. Cannot configure DNS automatically."
    else
        log_debug "Writing DNS servers 8.8.8.8 and 8.8.4.4 to /etc/resolv.conf."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
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

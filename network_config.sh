#!/usr/bin/env bash

#############################################################
# Early Network Configuration
#############################################################
configure_network_early() {
    show_step "NETWORK" "Configuring Network Connection"

    # Check if we already have internet connectivity
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        show_success "Network connectivity already available"
        return 0
    fi

    show_warning "No network connectivity detected. Configuration required."

    # Get available interfaces
    local ifaces; ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -5)
    if [[ -z "$ifaces" ]]; then
        show_error "No network interfaces found!"
        exit 1
    fi

    # For early setup, try DHCP on all available interfaces
    show_progress "Attempting DHCP on available interfaces..."
    for iface in $ifaces; do
        show_progress "Trying DHCP on $iface..."
        ip link set "$iface" up
        if dhclient -1 -v "$iface" 2>/dev/null; then
            if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                show_success "Network configured successfully on $iface"
                return 0
            fi
        fi
    done

    # If DHCP failed, manual configuration
    show_warning "DHCP failed. Manual network configuration required."

    # Manual network setup using dialog
    local iface_array=("$ifaces")
    local iface_options=()

    for iface in "${iface_array[@]}"; do
        local status; status=$(ip link show "$iface" | grep -q "state UP" && echo "UP" || echo "DOWN")
        iface_options+=("$iface" "$iface ($status)")
    done

    local selected_iface
    selected_iface=$(dialog --title "Network Interface" \
        --radiolist "Select network interface to configure:" 15 60 ${#iface_options[@]} \
        "${iface_options[@]}" 3>&1 1>&2 2>&3) || exit 1

    local ip_addr
    ip_addr=$(dialog --title "IP Address" \
        --inputbox "Enter IP address with CIDR (e.g., 192.168.1.100/24):" 10 60 \
        "192.168.1.100/24" 3>&1 1>&2 2>&3) || exit 1

    local gateway
    gateway=$(dialog --title "Gateway" \
        --inputbox "Enter gateway IP:" 10 60 \
        "192.168.1.1" 3>&1 1>&2 2>&3) || exit 1

    # Configure interface
    ip link set "$selected_iface" up
    ip addr add "$ip_addr" dev "$selected_iface"
    ip route add default via "$gateway"

    # Configure DNS
    if [[ -L "/etc/resolv.conf" ]]; then
        show_warning "/etc/resolv.conf is a symlink. Attempting to write, but manual DNS configuration might be needed if changes don't persist."
        # Still attempt to write, as it might be a symlink to a manageable file.
        if ! echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null; then
            show_error "Failed to write to /etc/resolv.conf (symlink target likely not writable)."
        else
            echo "nameserver 8.8.4.4" >> /etc/resolv.conf 2>/dev/null || show_warning "Failed to append to /etc/resolv.conf (symlink target)."
        fi
    elif [[ ! -w "/etc/resolv.conf" ]]; then
        show_error "/etc/resolv.conf is not writable. Cannot configure DNS automatically."
    else
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        show_success "DNS configured in /etc/resolv.conf"
    fi

    # Test connectivity
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        show_success "Network configured successfully"
    else
        show_error "Network configuration failed. Please check your settings."
        exit 1
    fi
}

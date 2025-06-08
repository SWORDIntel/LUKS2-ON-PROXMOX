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

    local iface_list_for_manual=()
    # Re-fetching is cleaner to ensure fresh data and apply better filtering.
    mapfile -t iface_list_for_manual < <(ip -o link show | awk -F': ' '{print $2}' | grep -v -E 'lo|docker|veth|vmbr|virbr|bond|dummy|ifb|gre|ipip|ip6tnl|sit|tun|tap' | head -5)

    local selected_iface # Will hold the final interface to configure

    if [[ ${#iface_list_for_manual[@]} -eq 0 ]]; then
        show_warning "No network interfaces automatically detected for manual setup."
        local manual_iface_entry
        manual_iface_entry=$(dialog --title "Manual Network Interface" --inputbox "Please enter the network interface name to configure (e.g., eth0):" 10 60 "" 3>&1 1>&2 2>&3)

        if [[ -z "$manual_iface_entry" ]]; then
            show_error "No network interface provided for manual configuration. Cannot proceed."
            exit 1
        fi
        if ! ip link show "$manual_iface_entry" &>/dev/null; then
            show_error "Interface '$manual_iface_entry' does not seem to exist. Please check."
            exit 1
        fi
        selected_iface="$manual_iface_entry"
        show_progress "Using manually specified interface for setup: $selected_iface"
    else
        local man_iface_options=()
        local first_man_iface_selected="on"

        for iface_man in "${iface_list_for_manual[@]}"; do
            local status_man; status_man=$(ip link show "$iface_man" | grep -q "state UP" && echo "UP" || echo "DOWN")
            # No need for IP here as we are setting it up manually
            man_iface_options+=("$iface_man" "$iface_man ($status_man)" "$first_man_iface_selected")
            first_man_iface_selected="off"
        done

        if [[ ${#man_iface_options[@]} -eq 0 ]]; then
            show_error "Failed to create options for manual network interface selection."
            exit 1
        fi

        selected_iface=$(dialog --title "Network Interface (Manual Setup)" \
            --radiolist "Select network interface to configure manually:" 15 70 $((${#man_iface_options[@]} / 3)) \
            "${man_iface_options[@]}" 3>&1 1>&2 2>&3) || {
                show_error "Manual network interface selection cancelled or failed."
                exit 1
            }
    fi

    if [[ -z "$selected_iface" ]]; then
        show_error "No interface selected for manual configuration. Aborting."
        exit 1
    fi

    local ip_addr
    ip_addr=$(dialog --title "IP Address for $selected_iface" \
        --inputbox "Enter IP address with CIDR (e.g., 192.168.1.100/24):" 10 60 \
        "192.168.1.100/24" 3>&1 1>&2 2>&3) || exit 1

    local gateway
    gateway=$(dialog --title "Gateway for $selected_iface" \
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

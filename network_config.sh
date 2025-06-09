#!/usr/bin/env bash

# network_config.sh - FAILSAFE VERSION
# Simplified network configuration with plain text UI

# Source common functions and variables - Assuming core_logic.sh and ui_functions.sh are available and simplified
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=core_logic.sh
source "${SCRIPT_DIR}/core_logic.sh" || { printf "Critical Error: Failed to source core_logic.sh. Exiting.\n" >&2; exit 1; }
# shellcheck source=ui_functions.sh
source "${SCRIPT_DIR}/ui_functions.sh" || { printf "Critical Error: Failed to source ui_functions.sh. Exiting.\n" >&2; exit 1; }

_configure_dns() {
    log_debug "Helper: Configuring DNS"
    # Use printf for writing to resolv.conf for better control
    printf "nameserver 1.1.1.1\n" > /etc/resolv.conf
    printf "nameserver 8.8.8.8\n" >> /etc/resolv.conf
    log_debug "DNS resolvers configured with 1.1.1.1 and 8.8.8.8"
}

_try_dhcp_all_interfaces() {
    log_debug "Helper: Attempting DHCP on all suitable interfaces"
    show_progress "Attempting automatic network configuration (DHCP)..."

    local interfaces
    local interface_name
    interfaces=""
    for if_path in /sys/class/net/*; do
        interface_name=$(basename "$if_path")
        case "$interface_name" in
            lo|docker*|veth*|virbr*|tun*|tap*|bond*)
                continue ;;
            *)
                interfaces="$interfaces $interface_name" ;;
        esac
    done
    interfaces=$(echo "$interfaces" | xargs) # Trim leading/trailing spaces and normalize multiple spaces
    if [ -z "$interfaces" ]; then
        log_warning "No suitable network interfaces found to attempt DHCP on."
        return 1
    fi

    for iface in $interfaces; do
        log_debug "Attempting DHCP on interface: $iface"
        ip link set "$iface" up 2>/dev/null || log_warning "Failed to bring up $iface"
        # Use a timeout to prevent hanging; redirect dhclient output to log or /dev/null
        if timeout 10 dhclient -1 "$iface" >/dev/null 2>&1; then
            # Verify with ping. Ensure ping output doesn't go to main stdout if not needed.
            if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
                log_debug "Network connectivity established on '$iface' via DHCP."
                return 0 # Success
            else
                log_debug "DHCP on $iface succeeded, but ping to 8.8.8.8 failed."
            fi
        else
            log_debug "DHCP client failed or timed out for $iface."
        fi
        # Release lease if dhclient failed to avoid issues
        dhclient -r "$iface" >/dev/null 2>&1 || true
    done

    log_warning "Automatic DHCP configuration failed on all interfaces."
    return 1 # Failure
}

_configure_network_interactive() {
    log_debug "Helper: Starting interactive network configuration"
    show_warning "Automatic network setup failed. Manual configuration is required."

    printf "Available network interfaces:\n"
    local if_list
    local interface_name
    if_list=()
    for if_path in /sys/class/net/*; do
        interface_name=$(basename "$if_path")
        case "$interface_name" in
            lo|docker*|veth*|virbr*|tun*|tap*|bond*)
                continue ;;
            *)
                if_list+=("$interface_name") ;;
        esac
    done
    
    if [ ${#if_list[@]} -eq 0 ]; then
        show_error "No network interfaces found to configure."
        return 1
    fi

    local i=1
    for iface_name in "${if_list[@]}"; do
        printf "  %d) %s\n" "$i" "$iface_name"
        i=$((i + 1))
    done

    local choice
    local selected_iface
    while true; do
        read -r -p "Select interface to configure (number): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#if_list[@]} ]; then
            selected_iface="${if_list[$((choice - 1))]}"
            break
        else
            printf "Invalid selection. Please enter a number from the list.\n" >&2
        fi
    done
    log_debug "User selected interface: $selected_iface"

    local ip_addr gateway
    read -r -p "Enter IP address with CIDR (e.g., 192.168.1.100/24): " ip_addr
    if ! [[ "$ip_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        show_error "Invalid IP/CIDR format: '$ip_addr'."
        return 1
    fi

    read -r -p "Enter gateway IP (e.g., 192.168.1.1): " gateway
    if ! [[ "$gateway" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        show_error "Invalid Gateway IP format: '$gateway'."
        return 1
    fi

    log_debug "Applying static IP: $ip_addr, Gateway: $gateway to $selected_iface"
    ip addr flush dev "$selected_iface" >/dev/null 2>&1
    ip link set "$selected_iface" up >/dev/null 2>&1
    ip addr add "$ip_addr" dev "$selected_iface" >/dev/null 2>&1
    ip route add default via "$gateway" dev "$selected_iface" >/dev/null 2>&1

    _configure_dns
    log_debug "Configured static IP on $selected_iface and set DNS."

    show_progress "Verifying manual network configuration..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log_debug "Manual network configuration successful."
        return 0
    else
        log_warning "Manual network configuration applied, but ping test to 8.8.8.8 failed."
        return 1 # Consider this a soft failure; settings applied but connectivity unverified
    fi
}

ensure_network_connectivity() {
    log_debug "Main: Ensuring network connectivity"
    show_header "NETWORK CONFIGURATION"

    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_debug "Network connectivity is already active."
        show_success "Network connectivity already active."
        return 0
    fi
    show_warning "No active network connection detected."

    if _try_dhcp_all_interfaces; then
        _configure_dns
        show_success "Network configured successfully via DHCP."
        return 0
    fi
    
    if ! _configure_network_interactive; then
        show_error "Failed to configure network. Some features may not work."
        return 1
    fi

    show_success "Network configured successfully (manual setup)."
    return 0
}

download_offline_packages() {
    log_debug "Main: Downloading offline packages (placeholder/simplified)"

    if [[ "${run_from_ram:-false}" == true ]]; then
        log_debug "Running from RAM, skipping pre-RAM package downloads."
        return 0
    fi
    
    if ! command -v prepare_installer_debs >/dev/null 2>&1; then
        log_warning "Command 'prepare_installer_debs' not found. Ensure package_management.sh is sourced and provides it."
        return 1
    fi
    
    log_debug "Calling prepare_installer_debs for offline package preparation..."
    if ! prepare_installer_debs; then # This function is from package_management.sh
        show_error "Failed to prepare installer packages (call to prepare_installer_debs failed)."
        return 1
    fi

    printf "\n-- Air-Gapped Installation Note --\n"
    printf "For use on an air-gapped machine, ensure you copy the ENTIRE installer directory (including the 'debs' folder) to your installation media.\n\n"
    log_debug "Offline package download/preparation step complete."
    return 0
}
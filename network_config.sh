#!/usr/bin/env bash

#############################################################
# Network Configuration Functions (Refactored for Robustness)
#############################################################

# Source UI functions if not already available (for log_warning etc.)
if ! command -v log_info &> /dev/null && [ -f "./ui_functions.sh" ]; then
    source ./ui_functions.sh
elif ! command -v log_info &> /dev/null && [ -f "../ui_functions.sh" ]; then # If called from a subdir like tests
    source ../ui_functions.sh
elif ! command -v log_info &> /dev/null ; then
    # Minimal fallback if ui_functions.sh is truly missing
    log_warning() { echo "[WARNING] $1" >&2; }
    log_info() { echo "[INFO] $1" >&2; }
    log_debug() { echo "[DEBUG] $1" >&2; }
    show_error() { echo "[ERROR] $1" >&2; }
    show_warning() { echo "[WARNING] $1" >&2; }
fi

# ANNOTATION: DRY Principle - This helper function consolidates DNS configuration.
# Configures system DNS resolvers with reliable public DNS servers.
_configure_dns() {
    log_debug "Entering helper function: ${FUNCNAME[0]}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    log_debug "DNS resolvers configured."
}

# ANNOTATION: DRY Principle - This helper function consolidates the "try DHCP on all interfaces" logic.
# It is a silent, best-effort attempt to get network connectivity automatically.
# Returns 0 on success, 1 on failure.
_try_dhcp_all_interfaces() {
    log_debug "Entering helper function: ${FUNCNAME[0]}"
    show_progress "Attempting automatic network configuration (DHCP)..."

    # Get a list of all physical-like interfaces.
    local interfaces
    interfaces=$(ls /sys/class/net | grep -vE '^(lo|docker|veth|virbr|tun|tap)')
    if [[ -z "$interfaces" ]]; then
        log_warning "No suitable network interfaces found to attempt DHCP on."
        return 1
    fi

    for iface in $interfaces; do
        log_debug "Attempting DHCP on interface: $iface"
        ip link set "$iface" up &>> "$LOG_FILE"
        # Use a timeout to prevent hanging.
        if timeout 10 dhclient -1 "$iface" &>> "$LOG_FILE"; then
            # Verify with ping.
            if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
                log_info "Network connectivity established on '$iface' via DHCP."
                return 0 # Success
            fi
        fi
    done

    log_warning "Automatic DHCP configuration failed on all interfaces."
    return 1 # Failure
}

# ANNOTATION: This helper function handles the interactive, manual configuration.
# It is called only when automated methods fail.
_configure_network_interactive() {
    log_debug "Entering helper function: ${FUNCNAME[0]}"
    show_warning "Automatic network setup failed. Manual configuration is required."

    local iface_options=()
    # Populate iface_options as before
    while read -r iface; do
        local status; status=$(ip link show "$iface" 2>/dev/null | grep -q "state UP" && echo "UP" || echo "DOWN")
        iface_options+=("$iface" "$iface ($status)") # Simplified for text menu
    # Using temporary file instead of process substitution to avoid /dev/fd issues
    local temp_ifaces
    temp_ifaces=$(mktemp /tmp/installer_ifaces.XXXXXX) # Use a more specific tmp file pattern
    if [[ -z "$temp_ifaces" || ! -f "$temp_ifaces" ]]; then
        show_error "Failed to create temporary file for interface listing."
        # rm -f "$temp_ifaces" # Clean up if mktemp created a name but not file
        return 1 # or handle error appropriately
    fi

    if ! ls /sys/class/net | grep -vE '^(lo|docker|veth|virbr|tun|tap)' > "$temp_ifaces"; then
        show_error "Failed to list network interfaces into temporary file."
        rm -f "$temp_ifaces"
        return 1
    fi

    done < "$temp_ifaces"
    rm -f "$temp_ifaces"

    if [[ ${#iface_options[@]} -eq 0 ]]; then # Check if any options were generated
        show_error "No suitable network interfaces found to configure." && return 1
    fi

    echo # Newline
    echo "Select network interface to configure:"
    local i_num=0
    local interfaces_only_paths=() # Store only device paths
    for i in $(seq 0 2 $((${#iface_options[@]} - 1))); do
        i_num=$((i_num + 1))
        interfaces_only_paths+=("${iface_options[$i]}")
        echo "  $i_num. ${iface_options[$i+1]}" # Display description part
    done
    
    if [[ $i_num -eq 0 ]]; then # Double check no interfaces listed
            show_error "No network interfaces listed for selection." && return 1
    fi

    local selected_iface iface_choice
    while true; do
        read -r -p "Enter choice [1-$i_num] or 'c' to cancel: " iface_choice
        if [[ "$iface_choice" == [cC] ]]; then
            log_debug "Interface selection cancelled by user."
            return 1
        fi
        if [[ "$iface_choice" =~ ^[0-9]+$ ]] && [[ "$iface_choice" -ge 1 ]] && [[ "$iface_choice" -le $i_num ]]; then
            selected_iface="${interfaces_only_paths[$((iface_choice - 1))]}"
            break
        else
            show_warning "Invalid selection. Please enter a number between 1 and $i_num, or 'c' to cancel."
        fi
    done
    log_debug "User selected interface: $selected_iface"

    local ip_addr 
    read -r -p "Enter IP address with CIDR for $selected_iface (e.g., 192.168.1.100/24), or 'c' to cancel: " ip_addr
    if [[ "$ip_addr" == [cC] ]] || [[ -z "$ip_addr" ]]; then 
        log_debug "IP address input cancelled or empty."
        return 1
    fi
    if ! [[ "$ip_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        show_error "Invalid IP/CIDR format." && return 1
    fi

    local gateway 
    read -r -p "Enter gateway IP for $selected_iface (e.g., 192.168.1.1), or 'c' to cancel: " gateway
    if [[ "$gateway" == [cC] ]] || [[ -z "$gateway" ]]; then 
        log_debug "Gateway input cancelled or empty."
        return 1
    fi
    if ! [[ "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        show_error "Invalid Gateway IP format." && return 1
    fi

    # Apply settings
    ip addr flush dev "$selected_iface" &>> "$LOG_FILE"
    ip link set "$selected_iface" up &>> "$LOG_FILE"
    ip addr add "$ip_addr" dev "$selected_iface" &>> "$LOG_FILE"
    ip route add default via "$gateway" &>> "$LOG_FILE"

    # Configure DNS
    _configure_dns
    log_info "Configured static IP on $selected_iface and set DNS."

    # Final verification
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log_info "Manual network configuration successful."
        return 0
    else
        log_error "Manual network configuration failed (ping test failed)."
        return 1
    fi
}

# ANNOTATION: This is the new main entry point function.
# It orchestrates the process of getting a network connection.
ensure_network_connectivity() {
    log_debug "Entering main network orchestrator: ${FUNCNAME[0]}"
    show_header "NETWORK CONFIGURATION"

    # 1. Check if we already have a connection.
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_info "Network connectivity is already active."
        show_success "Network connectivity already active."
        return 0
    fi
    show_warning "No active network connection detected."

    # 2. Try the automated DHCP helper.
    if _try_dhcp_all_interfaces; then
        # On success, ensure DNS is set and we're done.
        _configure_dns
        show_success "Network configured successfully via DHCP."
        return 0
    fi
    
    # 3. If automation fails, fall back to the interactive helper.
    if ! _configure_network_interactive; then
        # The interactive helper failed or was cancelled by the user.
        show_error "Failed to configure network. Some features may not work."
        return 1
    fi

    show_success "Network configured successfully (manual setup)."
    return 0
}

# Function to download packages for offline installation
# ANNOTATION: This function is now simplified, as it can rely on `ensure_network_connectivity`
# to have already run if an internet connection is required.
download_offline_packages() {
    log_debug "Entering function: ${FUNCNAME[0]}"

    # This check is good, if running from RAM we assume this step is complete.
    if [[ "${run_from_ram:-false}" == true ]]; then
        log_debug "Running from RAM, skipping pre-RAM package downloads."
        return 0
    fi
    
    # Leverage the consolidated package management script
    if ! command -v prepare_installer_debs >/dev/null 2>&1; then
        log_warning "Package management functions not available. Ensure package_management.sh is sourced."
        return 1
    fi
    
    # Use the consolidated function to prepare packages
    log_debug "Calling prepare_installer_debs for offline package preparation..."
    if ! prepare_installer_debs; then
        log_error "Failed to prepare installer packages"
        return 1
    fi

    echo # Newline for clarity
    show_header "Air-Gapped Installation Note" 
    echo "For use on an air-gapped machine, ensure you copy the ENTIRE"
    echo "installer directory (including the 'debs' folder) to your"
    echo "installation media."
    echo 
    read -r -p "Press Enter to continue..."
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

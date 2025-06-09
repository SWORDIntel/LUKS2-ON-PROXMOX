#!/usr/bin/env bash

# activate_ethernet_dhcp.sh
# Description: A standalone script to bring up a specified Ethernet interface
#              and attempt to configure it using DHCP.
#
# Usage:
#   sudo ./activate_ethernet_dhcp.sh
#   Or, if an interface is known:
#   sudo ./activate_ethernet_dhcp.sh <interface_name>

set -e # Exit immediately if a command exits with a non-zero status.
# set -u # Treat unset variables as an error (optional, can make scripts safer)
# set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed

# --- Helper Functions ---
_log_info() {
    printf "[INFO] %s\n" "$1"
}

_log_error() {
    printf "[ERROR] %s\n" "$1" >&2
}

_log_success() {
    printf "[SUCCESS] %s\n" "$1"
}

# --- Pre-flight Checks ---
if [[ "$EUID" -ne 0 ]]; then
    _log_error "This script must be run as root or with sudo."
    exit 1
fi

for cmd in ip dhclient; do
    if ! command -v "$cmd" &>/dev/null; then
        _log_error "Required command '$cmd' not found. Please ensure it is installed and in your PATH."
        _log_error "On Debian/Ubuntu, try: sudo apt update && sudo apt install iproute2 isc-dhcp-client"
        exit 1
    fi
done

# --- Main Script Logic ---
TARGET_INTERFACE=""

# Function to list and select an interface
select_interface() {
    _log_info "Scanning for available Ethernet interfaces..."
    # Exclude loopback, virtual (virbr, docker, veth, etc.), and wireless (wlan, wlp)
    # Common Ethernet prefixes: eth, eno, enp, ens, enx
    local available_interfaces
    mapfile -t available_interfaces < <(ip -o link show | awk -F': ' '$0 !~ /LOOPBACK|UNKNOWN|DOWN/ && $2 !~ /^(lo|virbr|docker|veth|wlan|wlp)/ && $2 ~ /^(eth|en[opxs])/ {print $2}')

    if [[ ${#available_interfaces[@]} -eq 0 ]]; then
        _log_error "No suitable active Ethernet interfaces found."
        _log_info "You can list all interfaces with 'ip link show'."
        exit 1
    elif [[ ${#available_interfaces[@]} -eq 1 ]]; then
        TARGET_INTERFACE="${available_interfaces[0]}"
        _log_info "Automatically selected interface: $TARGET_INTERFACE"
    else
        _log_info "Multiple Ethernet interfaces found. Please select one:"
        select choice in "${available_interfaces[@]}"; do
            if [[ -n "$choice" ]]; then
                TARGET_INTERFACE="$choice"
                break
            else
                _log_info "Invalid selection. Please try again."
            fi
        done
    fi
}

# If an interface name is provided as an argument, use it. Otherwise, prompt.
if [[ -n "$1" ]]; then
    TARGET_INTERFACE="$1"
    _log_info "Using provided interface: $TARGET_INTERFACE"
    # Basic validation if interface exists
    if ! ip link show "$TARGET_INTERFACE" &>/dev/null; then
        _log_error "Interface '$TARGET_INTERFACE' does not exist."
        select_interface # Fallback to selection
    fi
else
    select_interface
fi

if [[ -z "$TARGET_INTERFACE" ]]; then
    _log_error "No interface was selected or determined. Exiting."
    exit 1
fi

_log_info "Attempting to configure interface: $TARGET_INTERFACE"

# 1. Ensure the interface is up
_log_info "Bringing interface $TARGET_INTERFACE up..."
if ! ip link set "$TARGET_INTERFACE" up; then
    _log_error "Failed to bring interface $TARGET_INTERFACE up."
    exit 1
fi
_log_success "Interface $TARGET_INTERFACE is now up."

# 2. Release any old DHCP leases for the interface (optional, but good practice)
_log_info "Attempting to release any existing DHCP lease for $TARGET_INTERFACE..."
dhclient -r "$TARGET_INTERFACE" &>/dev/null || _log_info "No existing lease to release or dhclient -r not fully supported (can be ignored)."

# 3. Request a new IP address via DHCP
_log_info "Requesting new IP address for $TARGET_INTERFACE via DHCP..."
# The '-1' option tells dhclient to try once and exit.
# The '-v' option provides verbose output.
if ! dhclient -1 -v "$TARGET_INTERFACE"; then
    _log_error "DHCP client failed for $TARGET_INTERFACE."
    _log_info "Attempting to bring the interface down as a cleanup step."
    ip link set "$TARGET_INTERFACE" down &>/dev/null
    exit 1
fi

# 4. Verify IP address acquisition
_log_info "Verifying IP address on $TARGET_INTERFACE..."
# Grep for an IPv4 address. Adjust if IPv6 is primary.
current_ip=$(ip -4 addr show "$TARGET_INTERFACE" | grep -oP 'inet \K[\d.]+')

if [[ -n "$current_ip" ]]; then
    _log_success "Interface $TARGET_INTERFACE successfully configured with IP: $current_ip"
    _log_info "You can test connectivity, e.g., by running: ping -c 3 8.8.8.8"
else
    _log_error "Failed to obtain an IP address for $TARGET_INTERFACE after DHCP client run."
    _log_info "Attempting to bring the interface down as a cleanup step."
    ip link set "$TARGET_INTERFACE" down &>/dev/null
    exit 1
fi

exit 0

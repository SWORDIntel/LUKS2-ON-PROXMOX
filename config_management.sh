#!/usr/bin/env bash
# Contains functions for saving and loading installation configuration.

save_config() {
    local file_path=$1
    show_progress "Saving configuration to $file_path..."
    true > "$file_path"
    for key in "${!CONFIG_VARS[@]}"; do
        printf "%s='%s'\n" "$key" "${CONFIG_VARS[$key]}" >> "$file_path"
    done
    show_success "Configuration saved."
}

load_config() {
    local file_path=$1
    show_progress "Loading configuration from $file_path..."
    if [[ ! -f "$file_path" ]]; then
        show_error "Config file not found: $file_path"
        exit 1
    fi
    set +o nounset
    # AUDIT-FIX (SC1090): Added directive to acknowledge intentional dynamic source.
    # The script validates file existence before sourcing.
    # shellcheck source=/dev/null
    . "$file_path"
    set -o nounset

    local keys_to_load=(ZFS_TARGET_DISKS ZFS_RAID_LEVEL USE_DETACHED_HEADERS HEADER_DISK USE_CLOVER CLOVER_DISK NET_USE_DHCP NET_IFACE NET_IP_CIDR NET_GATEWAY NET_DNS HOSTNAME ZFS_ASHIFT ZFS_RECORDSIZE ZFS_COMPRESSION)

    for key in "${keys_to_load[@]}"; do
        # Check if the variable is declared in the loaded file
        if declare -p "$key" &>/dev/null; then
            # Use eval to assign the value to the associative array
            eval "CONFIG_VARS[$key]=\"\$$key\""
        # Optional: else log that a config key was not found in the file, or handle as needed
        # else
            # log_debug "Config key '$key' not found in $file_path or not set."
        fi
    done
    show_success "Configuration loaded."
}

#!/usr/bin/env bash
# Contains functions for saving and loading installation configuration.

save_config() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local file_path=$1
    log_debug "Attempting to save configuration to file: '$file_path'"
    show_progress "Saving configuration to $file_path..."
    true > "$file_path"
    log_debug "Iterating through CONFIG_VARS to save to file:"
    for key in "${!CONFIG_VARS[@]}"; do
        log_debug "Saving: $key='${CONFIG_VARS[$key]}'"
        printf "%s='%s'\n" "$key" "${CONFIG_VARS[$key]}" >> "$file_path"
    done
    log_debug "Finished iterating through CONFIG_VARS for saving."
    show_success "Configuration saved."
    log_debug "Exiting function: ${FUNCNAME[0]} - Configuration saved to '$file_path'."
}

load_config() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local file_path=$1
    log_debug "Attempting to load configuration from file: '$file_path'"
    show_progress "Loading configuration from $file_path..."
    if [[ ! -f "$file_path" ]]; then
        log_error "Configuration file '$file_path' not found."
        show_error "Config file not found: $file_path"
        return 1 # Changed exit 1 to return 1 for better control by caller
    fi
    log_debug "Configuration file '$file_path' found."
    set +o nounset
    # AUDIT-FIX (SC1090): Added directive to acknowledge intentional dynamic source.
    # The script validates file existence before sourcing.
    log_debug "Sourcing configuration file: '$file_path'"
    # shellcheck source=/dev/null
    . "$file_path"
    set -o nounset

    local keys_to_load=(ZFS_TARGET_DISKS ZFS_RAID_LEVEL USE_DETACHED_HEADERS HEADER_DISK USE_CLOVER CLOVER_DISK NET_USE_DHCP NET_IFACE NET_IP_CIDR NET_GATEWAY NET_DNS HOSTNAME ZFS_ASHIFT ZFS_RECORDSIZE ZFS_COMPRESSION)

    log_debug "Iterating through keys_to_load to populate CONFIG_VARS:"
    for key in "${keys_to_load[@]}"; do
        # Check if the variable is declared in the loaded file
        if declare -p "$key" &>/dev/null; then
            # Use eval to assign the value to the associative array
            eval "CONFIG_VARS[$key]=\"\$$key\""
            log_debug "Loaded from config: $key='${CONFIG_VARS[$key]}'"
        else
            log_debug "Config key '$key' not found in '$file_path' or not set after sourcing. Will use default or prompt later if applicable."
        fi
    done
    log_debug "Finished iterating through keys_to_load."
    show_success "Configuration loaded."
    log_debug "Exiting function: ${FUNCNAME[0]} - Configuration loaded from '$file_path'."
    return 0 # Added return 0 for success
}

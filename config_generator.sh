#!/usr/bin/env bash

# config_generator.sh - Standalone TUI Configuration Generator for LUKSZFS Installer

# --- Global Variables ---
declare -A CONFIG_VARS # Associative array to store configuration
LOG_FILE="/tmp/config_generator.log" # Specific log for the generator
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- UI & Logging Functions (Sourced) ---
# Source ui_functions.sh - this is now a hard requirement
if [[ -f "${SCRIPT_DIR}/ui_functions.sh" ]]; then
    # shellcheck source=ui_functions.sh
    source "${SCRIPT_DIR}/ui_functions.sh"
else
    # Minimal fallback echo if ui_functions.sh is missing for some reason during generation
    # This is mainly for the generator to be runnable to report this error.
    # The main installer already has robust sourcing.
    show_error() { printf "ERROR: %s
" "$1" >&2; }
    show_warning() { printf "WARNING: %s
" "$1"; }
    show_info() { printf "INFO: %s
" "$1"; }
    show_step() { printf "
### %s ###

" "$1"; }
    show_success() { printf "SUCCESS: %s
" "$1"; }
    log_debug() { printf "DEBUG: %s
" "$1" >> "$LOG_FILE"; } # Still log to its own log

    printf "Critical Error: ui_functions.sh not found at %s. Essential UI functions are missing.
" "${SCRIPT_DIR}/ui_functions.sh" >&2
    printf "Please ensure ui_functions.sh is in the same directory as config_generator.sh.
" >&2
    exit 1
fi

# Initialize log file for the generator
echo "Starting Configuration Generator at $(date)" > "$LOG_FILE"


# --- Configuration Gathering Functions ---

gather_zfs_options() {
    show_step "ZFS Configuration"
    # 1. Target Disks
    show_warning "Disk detection is simplified in this standalone generator."
    show_warning "Please ensure you know your target disk device names (e.g., /dev/sda, /dev/nvme0n1)."
    local disk_input
    read -r -p "Enter target disk(s) for ZFS pool, comma-separated (e.g., /dev/sda,/dev/sdb): " disk_input
    if [[ -z "$disk_input" ]]; then 
        show_error "No disks entered. Aborting ZFS config."
        return 1
    fi
    if ! [[ "$disk_input" =~ ^(/dev/[a-zA-Z0-9/]+,?)+$ ]]; then
        show_error "Invalid disk format. Please use comma-separated paths like /dev/sda,/dev/sdb."
        return 1
    fi
    CONFIG_VARS[ZFS_TARGET_DISKS]="$disk_input" # Storing as comma-separated string
    log_debug "ZFS Target Disks: ${CONFIG_VARS[ZFS_TARGET_DISKS]}"

    # 2. RAID Level
    local raid_options=(
        "single (No redundancy)"
        "mirror (Redundancy)"
        "raidz1 (Single parity)"
        "raidz2 (Double parity)"
        "raidz3 (Triple parity)"
        "Cancel"
    )
    local selected_raid_display
    if ! _select_option_from_list "Select ZFS RAID level:" selected_raid_display "${raid_options[@]}"; then
        # _select_option_from_list returns 1 if "Cancel" is chosen or error
        show_error "RAID level selection failed or cancelled."
        return 1
    fi
    # No need to check for "Cancel" string here if _select_option_from_list handles it by return code
    CONFIG_VARS[ZFS_RAID_LEVEL]=$(echo "$selected_raid_display" | awk '{print $1}')
    log_debug "ZFS RAID Level: ${CONFIG_VARS[ZFS_RAID_LEVEL]}"

    # 3. Pool Name
    local pool_name_input
    read -r -p "Enter ZFS pool name (default: rpool): " pool_name_input
    CONFIG_VARS[ZFS_POOL_NAME]="${pool_name_input:-rpool}"
    log_debug "ZFS Pool Name: ${CONFIG_VARS[ZFS_POOL_NAME]}"

    # 4. Ashift
    local ashift_value
    read -r -p "Enter ashift value (e.g., 12 for 4K sectors, 9 for 512b). Leave empty for auto-detect (recommended): " ashift_value
    if [[ -n "$ashift_value" && ! "$ashift_value" =~ ^(9|12|13|14|15|16)$ ]]; then
        show_warning "Invalid ashift value '$ashift_value'. Using empty for auto-detect."
        ashift_value=""
    fi
    CONFIG_VARS[ZFS_ASHIFT]="${ashift_value}" # Store empty if auto, or the value
    log_debug "ZFS Ashift: ${CONFIG_VARS[ZFS_ASHIFT]}"

    # 5. Record Size
    local recordsize_input
    read -r -p "Enter ZFS default record size (default: 128K): " recordsize_input
    CONFIG_VARS[ZFS_RECORDSIZE]="${recordsize_input:-128K}"
    log_debug "ZFS Record Size: ${CONFIG_VARS[ZFS_RECORDSIZE]}"

    # 6. Compression
    local compression_options=(
        "lz4 (Fast, recommended)"
        "gzip (Higher compression, slower)"
        "zstd (Modern, good balance)"
        "off (No compression)"
        "Cancel"
    )
    local selected_comp_display
    if ! _select_option_from_list "Select ZFS compression algorithm:" selected_comp_display "${compression_options[@]}"; then
        show_warning "Compression selection failed or cancelled. Defaulting to lz4."
        CONFIG_VARS[ZFS_COMPRESSION]="lz4"
    else
            CONFIG_VARS[ZFS_COMPRESSION]=$(echo "$selected_comp_display" | awk '{print $1}')
    fi
    log_debug "ZFS Compression: ${CONFIG_VARS[ZFS_COMPRESSION]}"

    # 7. ZFS Atime
    if prompt_yes_no "Enable atime updates (updates access times)? (Answering 'no' may improve performance)"; then
        CONFIG_VARS[ZFS_ATIME]="on"
    else
        CONFIG_VARS[ZFS_ATIME]="off"
    fi
    log_debug "ZFS Atime: ${CONFIG_VARS[ZFS_ATIME]}"
    
    # 8. ZFS Volblocksize (for ZVOLs like swap)
    local volblocksize
    read -r -p "Enter ZFS volblocksize for ZVOLs (e.g., 8K, 16K). Default is 8K: " volblocksize
    if [[ -n "$volblocksize" && ! "$volblocksize" =~ ^[0-9]+[KMGkmg]?$ ]]; then
        show_warning "Invalid volblocksize format '$volblocksize'. Defaulting to 8K."
        volblocksize="8K"
    fi
    CONFIG_VARS[ZFS_VOLBLOCKSIZE]="${volblocksize:-8K}"
    log_debug "ZFS Volblocksize: ${CONFIG_VARS[ZFS_VOLBLOCKSIZE]}"

    # 9. ZFS Xattr
    local xattr_options=(
        "sa (System Attributes - better performance)"
        "posix (POSIX - more compatible)"
        "Cancel"
    )
    local selected_xattr_display
    if ! _select_option_from_list "Set extended attribute (xattr) type:" selected_xattr_display "${xattr_options[@]}"; then
        show_warning "Xattr selection failed or cancelled. Defaulting to sa."
        CONFIG_VARS[ZFS_XATTR]="sa"
    else
        CONFIG_VARS[ZFS_XATTR]=$(echo "$selected_xattr_display" | awk '{print $1}')
    fi
    log_debug "ZFS Xattr: ${CONFIG_VARS[ZFS_XATTR]}"

    # 10. ZFS ACLtype
    local acltype_options=(
        "posixacl (Standard Linux)"
        "nfsv4 (NFSv4 - more granular)"
        "Cancel"
    )
    local selected_acl_display
    if ! _select_option_from_list "Set ACL type:" selected_acl_display "${acltype_options[@]}"; then
        show_warning "ACLtype selection failed or cancelled. Defaulting to posixacl."
        CONFIG_VARS[ZFS_ACLTYPE]="posixacl"
    else
        CONFIG_VARS[ZFS_ACLTYPE]=$(echo "$selected_acl_display" | awk '{print $1}')
    fi
    log_debug "ZFS ACLtype: ${CONFIG_VARS[ZFS_ACLTYPE]}"

    show_success "ZFS configuration gathered."
    return 0
}

gather_luks_options() {
    show_step "LUKS Encryption Configuration"

    if ! prompt_yes_no "Enable LUKS full-disk encryption for the ZFS pool partitions?"; then
        CONFIG_VARS[LUKS_ENABLE_ENCRYPTION]="no" # Explicitly set for clarity, though ZFS native might be used
        show_info "LUKS encryption for ZFS partitions disabled."
        log_debug "LUKS Enable Encryption (for ZFS partitions): no"
        return 0
    fi
    CONFIG_VARS[LUKS_ENABLE_ENCRYPTION]="yes"
    log_debug "LUKS Enable Encryption (for ZFS partitions): yes"

    local luks_cipher
    read -r -p "Enter LUKS cipher (default: aes-xts-plain64): " luks_cipher
    CONFIG_VARS[LUKS_CIPHER]="${luks_cipher:-aes-xts-plain64}"
    log_debug "LUKS Cipher: ${CONFIG_VARS[LUKS_CIPHER]}"
    
    local luks_key_size
    read -r -p "Enter LUKS key size in bits (e.g., 256, 512, default: 512): " luks_key_size
    CONFIG_VARS[LUKS_KEY_SIZE]="${luks_key_size:-512}"
    log_debug "LUKS Key Size: ${CONFIG_VARS[LUKS_KEY_SIZE]}"

    local luks_hash
    read -r -p "Enter LUKS hash algorithm (e.g., sha256, sha512, default: sha512): " luks_hash
    CONFIG_VARS[LUKS_HASH_ALGO]="${luks_hash:-sha512}"
    log_debug "LUKS Hash Algorithm: ${CONFIG_VARS[LUKS_HASH_ALGO]}"

    local luks_iter_time
    read -r -p "Enter LUKS iteration time in milliseconds (e.g., 2000, default: 5000): " luks_iter_time
    CONFIG_VARS[LUKS_ITER_TIME_MS]="${luks_iter_time:-5000}"
    log_debug "LUKS Iteration Time (ms): ${CONFIG_VARS[LUKS_ITER_TIME_MS]}"

    if prompt_yes_no "Enable LUKS header backup feature? (Handled by main installer)"; then
        CONFIG_VARS[LUKS_HEADER_BACKUP]="yes" # This is a general flag
    else
        CONFIG_VARS[LUKS_HEADER_BACKUP]="no"
    fi
    log_debug "LUKS Header Backup feature: ${CONFIG_VARS[LUKS_HEADER_BACKUP]}"
    
    show_success "LUKS configuration gathered."
    return 0
}

gather_network_options() {
    show_step "Network and System Configuration"

    local hostname_input
    local default_hostname="proxmox" # Changed default
    read -r -p "Enter system hostname (default: ${default_hostname}): " hostname_input
    CONFIG_VARS[HOSTNAME]="${hostname_input:-${default_hostname}}"
    if ! [[ "${CONFIG_VARS[HOSTNAME]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$ && "${CONFIG_VARS[HOSTNAME]}" != "localhost" ]]; then
        show_warning "Warning: Hostname '${CONFIG_VARS[HOSTNAME]}' may not be valid. Ensure it follows RFC standards."
    fi
    log_debug "Hostname: ${CONFIG_VARS[HOSTNAME]}"

    local iface_input
    # TODO: Could try to list interfaces here if possible, for now, direct input.
    read -r -p "Enter primary network interface (e.g., eth0, enp3s0): " iface_input
    if [[ -z "$iface_input" ]]; then show_error "Network interface cannot be empty."; return 1; fi
    CONFIG_VARS[NET_IFACE]="$iface_input"
    log_debug "Network Interface: ${CONFIG_VARS[NET_IFACE]}"

    local net_method_options=(
        "DHCP (automatic)"
        "Static IP (manual)"
        "Cancel"
    )
    local selected_net_method_display
    if ! _select_option_from_list "Select network configuration method for ${CONFIG_VARS[NET_IFACE]}:" selected_net_method_display "${net_method_options[@]}"; then
        show_error "Network method selection failed or cancelled."
        return 1
    fi

    if [[ "$selected_net_method_display" == "DHCP (automatic)" ]]; then
        CONFIG_VARS[NET_USE_DHCP]="yes"
        log_debug "Network Method: DHCP on ${CONFIG_VARS[NET_IFACE]}"
        CONFIG_VARS[NET_IP_CIDR]="" CONFIG_VARS[NET_GATEWAY]="" CONFIG_VARS[NET_DNS]=""
    else # Static IP
        CONFIG_VARS[NET_USE_DHCP]="no"
        log_debug "Network Method: Static IP on ${CONFIG_VARS[NET_IFACE]}"
        show_progress "Gathering static IP details for ${CONFIG_VARS[NET_IFACE]}..."
        local ip_cidr gateway dns_servers

        read -r -p "Enter IP address with CIDR (e.g., 192.168.1.100/24): " ip_cidr
        if ! [[ "$ip_cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            show_error "Invalid IP/CIDR format ('$ip_cidr')."
            return 1
        fi
        CONFIG_VARS[NET_IP_CIDR]="$ip_cidr"

        read -r -p "Enter gateway IP address (leave empty if none): " gateway
        if [[ -n "$gateway" && ! "$gateway" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            show_error "Invalid gateway IP format ('$gateway')."
            return 1
        fi
        CONFIG_VARS[NET_GATEWAY]="$gateway"

        read -r -p "Enter DNS server(s), comma-separated (default: 1.1.1.1): " dns_servers
        CONFIG_VARS[NET_DNS]="${dns_servers:-1.1.1.1}"
        # Basic validation for DNS servers
        IFS=',' read -ra dns_array <<< "${CONFIG_VARS[NET_DNS]}"
        for dns_ip in "${dns_array[@]}"; do
            local trimmed_dns_ip; trimmed_dns_ip=$(echo "$dns_ip" | xargs) 
            if ! [[ "$trimmed_dns_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                show_error "Invalid DNS server IP format ('$trimmed_dns_ip')."
                return 1
            fi
        done
    fi
    show_success "Network and system configuration gathered."
    return 0
}

gather_bootloader_options() {
    show_step "Bootloader Configuration"
    CONFIG_VARS[USE_CLOVER]="no" CONFIG_VARS[CLOVER_DISK]="" CONFIG_VARS[CLOVER_EFI_PART]=""

    if prompt_yes_no "Install Clover bootloader to a separate drive (GRUB on ZFS disks is default)?"; then
        CONFIG_VARS[USE_CLOVER]="yes"
        log_debug "Clover Bootloader: Yes"
        local clover_disk_input clover_efi_part_input

        while true; do
            read -r -p "Enter disk device for Clover (e.g., /dev/sdb): " clover_disk_input
            if [[ -z "$clover_disk_input" ]]; then show_error "Clover disk cannot be empty."; continue; fi
            if ! [[ "$clover_disk_input" =~ ^/dev/[a-zA-Z0-9/._-]+$ ]]; then show_error "Invalid Clover disk format."; continue; fi
            CONFIG_VARS[CLOVER_DISK]="$clover_disk_input"; break
        done

        local suggested_efi_part="${CONFIG_VARS[CLOVER_DISK]}1"
        if [[ "${CONFIG_VARS[CLOVER_DISK]}" =~ [0-9]$ ]]; then suggested_efi_part="${CONFIG_VARS[CLOVER_DISK]}p1"; fi
        
        read -r -p "Enter EFI partition on ${CONFIG_VARS[CLOVER_DISK]} (default: ${suggested_efi_part}): " clover_efi_part_input
        CONFIG_VARS[CLOVER_EFI_PART]="${clover_efi_part_input:-$suggested_efi_part}"
        # Basic validation could be added here for the partition format
        log_debug "Clover Disk: ${CONFIG_VARS[CLOVER_DISK]}, EFI Part: ${CONFIG_VARS[CLOVER_EFI_PART]}"
    else
        log_debug "Clover Bootloader: No"
    fi
    show_success "Bootloader configuration gathered."
    return 0
}

save_generated_config() {
    local default_filename="generated_installer.conf" # Changed default name
    local config_file
    read -r -p "Enter filename to save configuration (default: ${default_filename}): " config_file
    config_file="${config_file:-$default_filename}"
    if [[ "$config_file" =~ / ]]; then
        show_error "Invalid filename: cannot contain slashes."
        if prompt_yes_no "Use default filename '${default_filename}' instead?"; then
            config_file="$default_filename"
        else 
            show_warning "Configuration not saved."
            return 1
        fi
    fi

    show_progress "Saving configuration to $config_file..."
    # Using a temporary file for safer saving
    local temp_conf_file="$PWD/${config_file}.tmp"
    if ! printf "# Proxmox LUKSZFS Installer Configuration File - Generated on %s
" "$(date)" > "$temp_conf_file"; then
            show_error "Failed to write to temporary config file '$temp_conf_file'."
            return 1
    fi
    for key in "${!CONFIG_VARS[@]}"; do
        printf "%s='%s'
" "$key" "${CONFIG_VARS[$key]}" >> "$temp_conf_file"
    done
    # Atomically move temp file to final destination
    if mv "$temp_conf_file" "$PWD/$config_file"; then
        show_success "Configuration saved to $PWD/$config_file"
        show_info "Use this file with the main installer: ./installer.sh --config $PWD/$config_file"
    else
        show_error "Failed to save configuration to $PWD/$config_file."
        rm -f "$temp_conf_file" # Clean up temp file on failure
        return 1
    fi
    return 0
}

main() {
    show_header "Proxmox ZFS LUKS Configuration Generator"
    # Ensure essential commands are available (basic check)
    for cmd in awk read printf echo grep sed xargs; do
        if ! command -v $cmd &>/dev/null; then
            show_error "Essential command '$cmd' not found. Please install it or ensure it's in your PATH."
            exit 1
        fi
    done
    
    # Initialize CONFIG_VARS with some safe defaults that might be expected by functions
    CONFIG_VARS[ZFS_TARGET_DISKS]=""
    CONFIG_VARS[ZFS_RAID_LEVEL]="mirror" 
    # ... other sensible defaults can be added here ...
    
    # Call gathering functions
    if ! gather_zfs_options; then show_error "ZFS configuration failed. Exiting."; exit 1; fi
    if ! gather_luks_options; then show_error "LUKS configuration failed. Exiting."; exit 1; fi
    if ! gather_network_options; then show_error "Network/System configuration failed. Exiting."; exit 1; fi
    if ! gather_bootloader_options; then show_error "Bootloader configuration failed. Exiting."; exit 1; fi

    show_header "Configuration Generation Complete"
    echo "The following configuration has been generated and stored in memory:"
    for key in $(printf "%s
" "${!CONFIG_VARS[@]}" | sort); do # Sorted output
        printf "  %s: '%s'
" "$key" "${CONFIG_VARS[$key]}"
    done
    echo

    if prompt_yes_no "Do you want to save this configuration to a file?"; then
        save_generated_config
    else
        show_warning "Configuration not saved to file."
    fi
    show_success "Configuration generator finished."
}

# --- Script Entry Point ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # This makes it runnable as a standalone script
    main
fi

#!/usr/bin/env bash

# config_generator.sh - Standalone TUI Configuration Generator for LUKSZFS Installer

# --- Global Variables ---
declare -A CONFIG_VARS # Associative array to store configuration
LOG_FILE="/tmp/config_generator.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- UI & Logging Functions (Sourced) ---
# Source ui_functions.sh - this is now a hard requirement
if [[ -f "${SCRIPT_DIR}/ui_functions.sh" ]]; then
    # shellcheck source=ui_functions.sh
    source "${SCRIPT_DIR}/ui_functions.sh"
else
    printf "Critical Error: ui_functions.sh not found at %s. This script cannot run without it.\n" "${SCRIPT_DIR}/ui_functions.sh" >&2
    exit 1
fi

# All UI and logging functions (log_debug, show_header, _prompt_user_yes_no, etc.) 
# are now expected to come exclusively from ui_functions.sh.

# --- Configuration Gathering Functions ---

gather_zfs_options() {
    show_step "ZFS Configuration"
    # 1. Target Disks
    show_warning "Disk detection is simplified in this standalone generator."
    show_warning "Please ensure you know your target disk device names (e.g., /dev/sda, /dev/nvme0n1)."
    local disk_input
    # TODO: In a future step, integrate actual disk listing and selection using _select_option_from_list for multi-disk selection if desired.
    # For now, direct input is maintained.
    read -r -p "Enter target disk(s) for ZFS pool, comma-separated (e.g., /dev/sda,/dev/sdb): " disk_input
    log_debug "User input for ZFS target disks: '$disk_input'"
    if [[ -z "$disk_input" ]]; then 
        log_error "No ZFS target disks entered by user."
        show_error "No disks entered. Aborting ZFS config."
        return 1
    fi
    # Basic validation: check if it looks like a path, doesn't guarantee existence or correctness
    if ! [[ "$disk_input" =~ ^(/dev/[a-zA-Z0-9/]+,?)+$ ]]; then
        log_error "Invalid ZFS target disk format entered: '$disk_input'"
        show_error "Invalid disk format. Please use comma-separated paths like /dev/sda,/dev/sdb."
        return 1
    fi
    CONFIG_VARS[ZFS_TARGET_DISKS]="$disk_input"
    log_debug "Set CONFIG_VARS[ZFS_TARGET_DISKS]=${CONFIG_VARS[ZFS_TARGET_DISKS]}"

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
        log_error "ZFS RAID level selection failed or was cancelled by user (ESC pressed)."
        show_error "RAID level selection failed or cancelled."
        return 1
    fi
    log_debug "User selected RAID display option: '$selected_raid_display'"
    if [[ "$selected_raid_display" == "Cancel" ]]; then 
        log_warning "User explicitly selected 'Cancel' for ZFS RAID level."
        show_error "RAID level selection cancelled."
        return 1
    fi
    # Extract the actual value (e.g., "single" from "single (No redundancy)")
    CONFIG_VARS[ZFS_RAID_LEVEL]=$(echo "$selected_raid_display" | awk '{print $1}')
    log_debug "Set CONFIG_VARS[ZFS_RAID_LEVEL]=${CONFIG_VARS[ZFS_RAID_LEVEL]}"

    # 3. Pool Name
    local pool_name_input
    read -r -p "Enter ZFS pool name (default: rpool): " pool_name_input
    log_debug "User input for ZFS pool name: '$pool_name_input'"
    CONFIG_VARS[ZFS_POOL_NAME]="${pool_name_input:-rpool}"
    log_debug "Set CONFIG_VARS[ZFS_POOL_NAME]=${CONFIG_VARS[ZFS_POOL_NAME]}"

    # 4. Ashift
    local ashift_value
    read -r -p "Enter ashift value (e.g., 12 for 4K sectors, 9 for 512b). Leave empty for auto-detect: " ashift_value
    log_debug "User input for ZFS ashift: '$ashift_value'"
    if [[ -n "$ashift_value" && ! "$ashift_value" =~ ^(9|12|13|14|15|16)$ ]]; then # Common ashift values
        log_warning "Invalid ashift value '$ashift_value' entered. Setting to empty for auto-detect."
        show_warning "Invalid ashift value '$ashift_value'. Setting to empty for auto-detect."
        ashift_value=""
    fi
    CONFIG_VARS[ZFS_ASHIFT]="${ashift_value}"
    log_debug "Set CONFIG_VARS[ZFS_ASHIFT]=${CONFIG_VARS[ZFS_ASHIFT]}"

    # 5. Record Size
    local recordsize_input
    read -r -p "Enter ZFS default record size (default: 128K): " recordsize_input
    log_debug "User input for ZFS record size: '$recordsize_input'"
    CONFIG_VARS[ZFS_RECORDSIZE]="${recordsize_input:-128K}"
    log_debug "Set CONFIG_VARS[ZFS_RECORDSIZE]=${CONFIG_VARS[ZFS_RECORDSIZE]}"

    # 6. Compression
    local compression_options=(
        "lz4 (Fast, recommended)"
        "gzip (Higher compression, slower)"
        "zstd (Modern, good balance)"
        "off (No compression)"
        "Cancel"
    )
    local selected_comp_display
    local selected_comp_display_status
    if ! _select_option_from_list "Select ZFS compression algorithm:" selected_comp_display "${compression_options[@]}"; then
        selected_comp_display_status="failed_or_esc"
        log_warning "ZFS compression selection failed or was cancelled by user (ESC pressed). Defaulting to lz4."
        show_warning "Compression selection failed or cancelled. Defaulting to lz4."
        CONFIG_VARS[ZFS_COMPRESSION]="lz4"
    elif [[ "$selected_comp_display" == "Cancel" ]]; then
        selected_comp_display_status="cancelled_explicitly"
        log_warning "User explicitly selected 'Cancel' for ZFS compression. Defaulting to lz4."
        show_warning "Compression selection cancelled. Defaulting to lz4."
        CONFIG_VARS[ZFS_COMPRESSION]="lz4"
    else
        selected_comp_display_status="selected"
        CONFIG_VARS[ZFS_COMPRESSION]=$(echo "$selected_comp_display" | awk '{print $1}')
    fi
    log_debug "ZFS compression selection status: '$selected_comp_display_status', selected display: '$selected_comp_display', Set CONFIG_VARS[ZFS_COMPRESSION]=${CONFIG_VARS[ZFS_COMPRESSION]}"

    # 7. ZFS Atime
    if prompt_yes_no "Enable atime updates (updates access times)? (Answering 'no' may improve performance)"; then
        log_debug "User chose to enable ZFS atime updates."
        CONFIG_VARS[ZFS_ATIME]="on"
    else
        log_debug "User chose to disable ZFS atime updates."
        CONFIG_VARS[ZFS_ATIME]="off"
    fi
    log_debug "Set CONFIG_VARS[ZFS_ATIME]=${CONFIG_VARS[ZFS_ATIME]}"

    # 8. ZFS Volblocksize (for ZVOLs like swap)
    local volblocksize
    read -r -p "Enter ZFS volblocksize for ZVOLs (e.g., 8K, 16K). Default is 8K: " volblocksize
    log_debug "User input for ZFS volblocksize: '$volblocksize'"
    if [[ -n "$volblocksize" && ! "$volblocksize" =~ ^[0-9]+[KMGkmg]?$ ]]; then # Allow K, M, G in upper or lower case
        log_warning "Invalid ZFS volblocksize format '$volblocksize' entered. Defaulting to 8K."
        show_warning "Invalid volblocksize format '$volblocksize'. Defaulting to 8K."
        volblocksize="8K"
    fi
    CONFIG_VARS[ZFS_VOLBLOCKSIZE]="${volblocksize:-8K}"
    log_debug "Set CONFIG_VARS[ZFS_VOLBLOCKSIZE]=${CONFIG_VARS[ZFS_VOLBLOCKSIZE]}"

    # 9. ZFS Xattr
    local xattr_options=(
        "sa (System Attributes - better performance)"
        "posix (POSIX - more compatible)"
        "Cancel"
    )
    local selected_xattr_display
    local selected_xattr_display_status
    if ! _select_option_from_list "Set extended attribute (xattr) type:" selected_xattr_display "${xattr_options[@]}"; then
        selected_xattr_display_status="failed_or_esc"
        log_warning "ZFS xattr selection failed or was cancelled by user (ESC pressed). Defaulting to sa."
        show_warning "Xattr selection failed or cancelled. Defaulting to sa."
        CONFIG_VARS[ZFS_XATTR]="sa"
    elif [[ "$selected_xattr_display" == "Cancel" ]]; then
        selected_xattr_display_status="cancelled_explicitly"
        log_warning "User explicitly selected 'Cancel' for ZFS xattr. Defaulting to sa."
        show_warning "Xattr selection cancelled. Defaulting to sa."
        CONFIG_VARS[ZFS_XATTR]="sa"
    else
        selected_xattr_display_status="selected"
        CONFIG_VARS[ZFS_XATTR]=$(echo "$selected_xattr_display" | awk '{print $1}')
    fi
    log_debug "ZFS xattr selection status: '$selected_xattr_display_status', selected display: '$selected_xattr_display', Set CONFIG_VARS[ZFS_XATTR]=${CONFIG_VARS[ZFS_XATTR]}"

    # 10. ZFS ACLtype
    local acltype_options=(
        "posixacl (Standard Linux)"
        "nfsv4 (NFSv4 - more granular)"
        "Cancel"
    )
    local selected_acl_display
    local selected_acl_display_status
    if ! _select_option_from_list "Set ACL type:" selected_acl_display "${acltype_options[@]}"; then
        selected_acl_display_status="failed_or_esc"
        log_warning "ZFS ACLtype selection failed or was cancelled by user (ESC pressed). Defaulting to posixacl."
        show_warning "ACLtype selection failed or cancelled. Defaulting to posixacl."
        CONFIG_VARS[ZFS_ACLTYPE]="posixacl"
    elif [[ "$selected_acl_display" == "Cancel" ]]; then
        selected_acl_display_status="cancelled_explicitly"
        log_warning "User explicitly selected 'Cancel' for ZFS ACLtype. Defaulting to posixacl."
        show_warning "ACLtype selection cancelled. Defaulting to posixacl."
        CONFIG_VARS[ZFS_ACLTYPE]="posixacl"
    else
        selected_acl_display_status="selected"
        CONFIG_VARS[ZFS_ACLTYPE]=$(echo "$selected_acl_display" | awk '{print $1}')
    fi
    log_debug "ZFS ACLtype selection status: '$selected_acl_display_status', selected display: '$selected_acl_display', Set CONFIG_VARS[ZFS_ACLTYPE]=${CONFIG_VARS[ZFS_ACLTYPE]}"

    # 11. ZFS Relatime
    if prompt_yes_no "Enable relatime (updates access times less frequently than atime)? (Answering 'no' uses default behavior)"; then
        log_debug "User chose to enable ZFS relatime."
        CONFIG_VARS[ZFS_RELATIME]="on"
    else
        log_debug "User chose to disable ZFS relatime (or use ZFS default)."
        CONFIG_VARS[ZFS_RELATIME]="off" # Or consider removing the key to use ZFS default
    fi
    log_debug "Set CONFIG_VARS[ZFS_RELATIME]=${CONFIG_VARS[ZFS_RELATIME]}"

    show_success "ZFS configuration gathered."
}

gather_luks_options() {
    show_step "LUKS Encryption Configuration"

    # 1. Enable LUKS Encryption
    if prompt_yes_no "Enable LUKS full-disk encryption for the ZFS pool?"; then
        CONFIG_VARS[LUKS_ENABLE_ENCRYPTION]="yes"
    else
        CONFIG_VARS[LUKS_ENABLE_ENCRYPTION]="no"
        show_info "LUKS encryption disabled. Skipping further LUKS options."
        log_debug "LUKS Enable Encryption: no"
        return 0 # Successfully chose not to enable LUKS
    fi
    log_debug "LUKS Enable Encryption: yes"

    # 2. LUKS Cipher
    local luks_cipher
    read -r -p "Enter LUKS cipher (default: aes-xts-plain64): " luks_cipher
    if [[ -z "$luks_cipher" ]]; then luks_cipher="aes-xts-plain64"; fi
    if ! [[ "$luks_cipher" =~ ^[a-zA-Z0-9_-]+$ ]]; then # Basic validation
        show_error "Invalid LUKS cipher format ('$luks_cipher'). Only alphanumeric, underscore, and hyphen allowed."
        return 1
    fi
    CONFIG_VARS[LUKS_CIPHER]="$luks_cipher"
    log_debug "LUKS Cipher: ${CONFIG_VARS[LUKS_CIPHER]}"

    # 3. LUKS Key Size
    local luks_key_size
    read -r -p "Enter LUKS key size in bits (e.g., 256, 512, default: 512): " luks_key_size
    if [[ -z "$luks_key_size" ]]; then luks_key_size="512"; fi
    if ! [[ "$luks_key_size" =~ ^(256|512)$ ]]; then
        show_error "Invalid LUKS key size ('$luks_key_size'). Please use 256 or 512."
        return 1
    fi
    CONFIG_VARS[LUKS_KEY_SIZE]="$luks_key_size"
    log_debug "LUKS Key Size: ${CONFIG_VARS[LUKS_KEY_SIZE]}"

    # 4. LUKS Hash Algorithm
    local luks_hash
    read -r -p "Enter LUKS hash algorithm (e.g., sha256, sha512, default: sha512): " luks_hash
    if [[ -z "$luks_hash" ]]; then luks_hash="sha512"; fi
    if ! [[ "$luks_hash" =~ ^sha(256|512|3-256|3-512)$ ]]; then # Common and SHA3 variants
        show_error "Invalid LUKS hash algorithm ('$luks_hash'). Please use sha256, sha512, sha3-256, or sha3-512."
        return 1
    fi
    CONFIG_VARS[LUKS_HASH_ALGO]="$luks_hash"
    log_debug "LUKS Hash Algorithm: ${CONFIG_VARS[LUKS_HASH_ALGO]}"

    # 5. LUKS Iteration Time (ms)
    local luks_iter_time
    read -r -p "Enter LUKS iteration time in milliseconds (e.g., 2000, 5000, default: 5000): " luks_iter_time
    if [[ -z "$luks_iter_time" ]]; then luks_iter_time="5000"; fi
    if ! [[ "$luks_iter_time" =~ ^[0-9]+$ && "$luks_iter_time" -ge 1000 ]]; then
        show_error "Invalid LUKS iteration time ('$luks_iter_time'). Must be a number in milliseconds, >= 1000."
        return 1
    fi
    CONFIG_VARS[LUKS_ITER_TIME_MS]="$luks_iter_time"
    log_debug "LUKS Iteration Time (ms): ${CONFIG_VARS[LUKS_ITER_TIME_MS]}"

    # 6. LUKS Header Backup
    if prompt_yes_no "Enable LUKS header backup? (Recommended)"; then
        CONFIG_VARS[LUKS_HEADER_BACKUP]="yes"
    else
        CONFIG_VARS[LUKS_HEADER_BACKUP]="no"
    fi
    log_debug "LUKS Header Backup: ${CONFIG_VARS[LUKS_HEADER_BACKUP]}"

    show_success "LUKS configuration gathered."
}

gather_network_options() {
    show_step "Network and System Configuration"

    # 1. Hostname
    local hostname_input
    local default_hostname="proxmox-luks"
    read -r -p "Enter system hostname (default: ${default_hostname}): " hostname_input
    log_debug "User input for hostname: '$hostname_input'"
    CONFIG_VARS[HOSTNAME]="${hostname_input:-${default_hostname}}"
    # Basic hostname validation (simplified)
    if ! [[ "${CONFIG_VARS[HOSTNAME]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$ && "${CONFIG_VARS[HOSTNAME]}" != "localhost" ]]; then
        log_warning "Hostname '${CONFIG_VARS[HOSTNAME]}' may not be valid. Displaying warning to user."
        show_warning "Warning: Hostname '${CONFIG_VARS[HOSTNAME]}' may not be valid. Ensure it follows RFC standards."
    fi
    log_debug "Set CONFIG_VARS[HOSTNAME]=${CONFIG_VARS[HOSTNAME]}"

    # 2. Network Interface
    local iface_input
    read -r -p "Enter network interface (default: eth0): " iface_input
    log_debug "User input for network interface: '$iface_input'"
    CONFIG_VARS[NET_IFACE]="${iface_input:-eth0}"
    log_debug "Set CONFIG_VARS[NET_IFACE]=${CONFIG_VARS[NET_IFACE]}"

    # 3. Network Configuration Method (DHCP or Static)
    local net_method_options=(
        "DHCP (automatic)"
        "Static IP (manual)"
        "Cancel"
    )
    local selected_net_method_display
    if ! _select_option_from_list "Select network configuration method:" selected_net_method_display "${net_method_options[@]}"; then
        log_error "Network method selection failed or was cancelled by user (ESC pressed)."
        show_error "Network method selection failed or cancelled."
        return 1
    fi
    log_debug "User selected network method display option: '$selected_net_method_display'"

    if [[ "$selected_net_method_display" == "Cancel" ]]; then
        log_warning "User explicitly selected 'Cancel' for network configuration method."
        show_error "Network configuration cancelled."
        return 1
    elif [[ "$selected_net_method_display" == "DHCP (automatic)" ]]; then
        CONFIG_VARS[NET_USE_DHCP]="yes"
        log_debug "Set CONFIG_VARS[NET_USE_DHCP]=yes (DHCP on ${CONFIG_VARS[NET_IFACE]})"
        # Clear static IP settings if DHCP is chosen
        CONFIG_VARS[NET_IP_CIDR]=""
        CONFIG_VARS[NET_GATEWAY]=""
        CONFIG_VARS[NET_DNS]=""
        log_debug "Cleared static IP CONFIG_VARS (NET_IP_CIDR, NET_GATEWAY, NET_DNS) due to DHCP selection."
    else
        CONFIG_VARS[NET_USE_DHCP]="no"
        log_debug "Set CONFIG_VARS[NET_USE_DHCP]=no (Static IP on ${CONFIG_VARS[NET_IFACE]})"

        show_progress "Gathering static IP details..."
        local ip_cidr gateway dns_servers

        # IP Address with CIDR
        read -r -p "Enter IP address with CIDR for ${CONFIG_VARS[NET_IFACE]} (e.g., 192.168.1.100/24): " ip_cidr
        log_debug "User input for static IP/CIDR: '$ip_cidr'"
        if ! [[ "$ip_cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            log_error "Invalid static IP address/CIDR format entered: '$ip_cidr'"
            show_error "Invalid IP address/CIDR format ('$ip_cidr'). Example: 192.168.1.100/24"
            return 1
        fi
        CONFIG_VARS[NET_IP_CIDR]="$ip_cidr"
        log_debug "Set CONFIG_VARS[NET_IP_CIDR]=${CONFIG_VARS[NET_IP_CIDR]}"

        # Gateway
        read -r -p "Enter gateway IP address (e.g., 192.168.1.1, leave empty if none): " gateway
        log_debug "User input for gateway IP: '$gateway'"
        if [[ -n "$gateway" && ! "$gateway" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_error "Invalid gateway IP address format entered: '$gateway'"
            show_error "Invalid gateway IP address format ('$gateway'). Example: 192.168.1.1"
            return 1
        fi
        CONFIG_VARS[NET_GATEWAY]="$gateway"
        log_debug "Set CONFIG_VARS[NET_GATEWAY]=${CONFIG_VARS[NET_GATEWAY]}"

        # DNS Servers
        read -r -p "Enter DNS server(s), comma-separated (default: 1.1.1.1,8.8.8.8): " dns_servers
        log_debug "User input for DNS servers: '$dns_servers'"
        CONFIG_VARS[NET_DNS]="${dns_servers:-1.1.1.1,8.8.8.8}"
        # Basic validation for DNS servers (comma-separated IPs)
        IFS=',' read -ra dns_array <<< "${CONFIG_VARS[NET_DNS]}"
        for dns_ip in "${dns_array[@]}"; do
            local trimmed_dns_ip
            trimmed_dns_ip=$(echo "$dns_ip" | xargs) # trim whitespace
            log_debug "Validating DNS IP: '$trimmed_dns_ip' (original from list: '$dns_ip')"
            if ! [[ "$trimmed_dns_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                log_error "Invalid DNS server IP address format: '$trimmed_dns_ip' (from input '${CONFIG_VARS[NET_DNS]}')"
                show_error "Invalid DNS server IP address format ('$trimmed_dns_ip')."
                return 1
            fi
        done
        log_debug "Final static IP CONFIG_VARS[NET_IP_CIDR]=${CONFIG_VARS[NET_IP_CIDR]}"
        log_debug "Final static gateway CONFIG_VARS[NET_GATEWAY]=${CONFIG_VARS[NET_GATEWAY]}"
        log_debug "Final static DNS CONFIG_VARS[NET_DNS]=${CONFIG_VARS[NET_DNS]}"
    fi
    show_success "Network and system configuration gathered."
}


gather_bootloader_options() {
    show_step "Bootloader Configuration"

    log_debug "Initializing bootloader options: USE_CLOVER=no, CLOVER_DISK='', CLOVER_EFI_PART=''"
    CONFIG_VARS[USE_CLOVER]="no" # Default
    CONFIG_VARS[CLOVER_DISK]=""  # Default
    CONFIG_VARS[CLOVER_EFI_PART]="" # Default

    if prompt_yes_no "Install Clover bootloader to a separate drive (e.g., USB stick)? (GRUB on ZFS disks is the default if 'no')"; then
        log_debug "User chose to install Clover bootloader."
        CONFIG_VARS[USE_CLOVER]="yes"
        log_debug "Set CONFIG_VARS[USE_CLOVER]=yes"

        local clover_disk_input clover_efi_part_input

        # Get Clover Target Disk
        while true; do
            read -r -p "Enter the disk device for Clover installation (e.g., /dev/sdb): " clover_disk_input
            log_debug "User input for Clover disk: '$clover_disk_input'"
            if [[ -z "$clover_disk_input" ]]; then
                log_error "Clover disk input was empty."
                show_error "Clover disk cannot be empty."
            elif ! [[ "$clover_disk_input" =~ ^/dev/[a-zA-Z0-9/._-]+$ ]]; then
                log_error "Invalid Clover disk format entered: '$clover_disk_input'"
                show_error "Invalid Clover disk format ('$clover_disk_input'). Must be a device path like /dev/sdb."
            else
                CONFIG_VARS[CLOVER_DISK]="$clover_disk_input"
                log_debug "Set CONFIG_VARS[CLOVER_DISK]=${CONFIG_VARS[CLOVER_DISK]}"
                break
            fi
            if ! prompt_yes_no "Try entering Clover disk again?"; then
                log_warning "User chose not to retry Clover disk input. Aborting Clover setup."
                show_warning "Clover installation aborted by user due to disk input issue."
                CONFIG_VARS[USE_CLOVER]="no"
                log_debug "Set CONFIG_VARS[USE_CLOVER]=no due to Clover disk input abortion."
                return 0 # Not an error, user chose to abort this part
            fi
            log_debug "User chose to retry Clover disk input."
        done

        # Get Clover EFI Partition
        # Suggest a default based on the disk, e.g., /dev/sdb1
        local suggested_efi_part="${CONFIG_VARS[CLOVER_DISK]}1"
        # If disk ends with a digit (like nvme0n1), append p1 instead of just 1
        if [[ "${CONFIG_VARS[CLOVER_DISK]}" =~ [0-9]$ ]]; then 
            suggested_efi_part="${CONFIG_VARS[CLOVER_DISK]}p1"
        fi
        log_debug "Suggested Clover EFI partition: '$suggested_efi_part' (based on CLOVER_DISK='${CONFIG_VARS[CLOVER_DISK]}')"

        while true; do
            read -r -p "Enter the EFI partition on ${CONFIG_VARS[CLOVER_DISK]} (e.g., ${suggested_efi_part}): " clover_efi_part_input
            log_debug "User input for Clover EFI partition: '$clover_efi_part_input'"
            if [[ -z "$clover_efi_part_input" ]]; then
                log_debug "Clover EFI partition input empty, using suggested: '$suggested_efi_part'"
                clover_efi_part_input="$suggested_efi_part" # Use suggested if empty
                show_info "Using suggested EFI partition: ${clover_efi_part_input}"
            fi
            
            # Validate that the entered partition starts with the disk path if it's a full path
            # Or it's just a partition number/suffix to be appended to the disk path
            if ! [[ "$clover_efi_part_input" =~ ^(/dev/[a-zA-Z0-9/._-]+|p?[0-9]+)$ ]]; then
                log_error "Invalid Clover EFI partition format: '$clover_efi_part_input'"
                show_error "Invalid Clover EFI partition format ('$clover_efi_part_input'). Must be a full path like /dev/sdb1 or a partition suffix like p1 or 1."
            elif [[ "$clover_efi_part_input" =~ ^/dev/ && ! "$clover_efi_part_input" =~ ^${CONFIG_VARS[CLOVER_DISK]} ]]; then
                 log_error "Clover EFI partition '$clover_efi_part_input' does not appear to be on selected Clover disk '${CONFIG_VARS[CLOVER_DISK]}'"
                 show_error "EFI partition ('$clover_efi_part_input') does not seem to be on the selected Clover disk ('${CONFIG_VARS[CLOVER_DISK]}')."
            else
                # If it's not a full path, prepend the disk path.
                if ! [[ "$clover_efi_part_input" =~ ^/dev/ ]]; then
                    log_debug "Clover EFI partition input '$clover_efi_part_input' is a suffix, prepending CLOVER_DISK '${CONFIG_VARS[CLOVER_DISK]}'"
                    CONFIG_VARS[CLOVER_EFI_PART]="${CONFIG_VARS[CLOVER_DISK]}${clover_efi_part_input}"
                else
                    log_debug "Clover EFI partition input '$clover_efi_part_input' is a full path."
                    CONFIG_VARS[CLOVER_EFI_PART]="$clover_efi_part_input"
                fi
                log_debug "Set CONFIG_VARS[CLOVER_EFI_PART]=${CONFIG_VARS[CLOVER_EFI_PART]}"
                break
            fi
            if ! prompt_yes_no "Try entering Clover EFI partition again?"; then
                log_warning "User chose not to retry Clover EFI partition input. Aborting Clover setup."
                show_warning "Clover installation aborted by user due to EFI partition input issue."
                CONFIG_VARS[USE_CLOVER]="no"
                log_debug "Set CONFIG_VARS[USE_CLOVER]=no due to Clover EFI partition input abortion."
                return 0 # Not an error, user chose to abort this part
            fi
            log_debug "User chose to retry Clover EFI partition input."
        done

        log_debug "Final Clover config: CONFIG_VARS[CLOVER_DISK]=${CONFIG_VARS[CLOVER_DISK]}, CONFIG_VARS[CLOVER_EFI_PART]=${CONFIG_VARS[CLOVER_EFI_PART]}"
        show_success "Clover bootloader configuration gathered for ${CONFIG_VARS[CLOVER_DISK]} (${CONFIG_VARS[CLOVER_EFI_PART]})."
    else
        log_debug "User chose not to install Clover, or aborted Clover setup. Defaulting to GRUB on ZFS disks."
        CONFIG_VARS[USE_CLOVER]="no"
        log_debug "Set CONFIG_VARS[USE_CLOVER]=no"
        show_info "Bootloader configuration set to default (GRUB on ZFS disks)."
    fi
    return 0
}

# --- Save Configuration ---
save_generated_config() {
    local default_filename="generated_config.conf"
    local config_file

    read -r -p "Enter filename to save configuration (default: ${default_filename}): " config_file
    log_debug "User input for config filename: '$config_file'"
    config_file=${config_file:-$default_filename}
    log_debug "Effective config filename (after default): '$config_file'"

    if [[ -z "$config_file" ]]; then
        log_error "Config filename is empty after applying default. This should not happen if default_filename is set."
        show_warning "Configuration not saved (empty filename provided)."
        return 1
    fi

    # Basic validation for filename (e.g., prevent paths trying to escape current dir or using slashes)
    if [[ "$config_file" =~ / ]]; then
        log_warning "Invalid config filename '$config_file' (contains slashes). Prompting user."
        show_error "Invalid filename: cannot contain slashes. Please provide a filename for the current directory."
        # Offer to try again or use default
        if prompt_yes_no "Use default filename '${default_filename}' instead?"; then
            log_debug "User opted to use default filename '${default_filename}' after invalid input."
            config_file="$default_filename"
            log_debug "Effective config filename now: '$config_file'"
        else 
            log_warning "User opted not to use default filename. Configuration not saved."
            show_warning "Configuration not saved."
            return 1
        fi
    fi

    log_info "Attempting to save configuration to '$PWD/$config_file'"
    show_progress "Saving configuration to $config_file..."
    if ! printf "# LUKSZFS Configuration File - Generated on %s\n" "$(date)" > "$config_file"; then
        log_error "Failed to write initial line to config file '$PWD/$config_file'. Check permissions or path."
        show_error "Failed to write to '$config_file'. Check permissions or path."
        return 1
    fi
    log_debug "Successfully wrote header to config file '$PWD/$config_file'"

    for key in "${!CONFIG_VARS[@]}"; do
        # Ensure values with spaces or special characters are quoted
        log_debug "Writing to config: %s='%s'" "$key" "${CONFIG_VARS[$key]}"
        if ! printf "%s='%s'\n" "$key" "${CONFIG_VARS[$key]}" >> "$config_file"; then
            log_error "Failed to append $key='${CONFIG_VARS[$key]}' to config file '$PWD/$config_file'."
            show_error "Error writing configuration key '$key' to '$config_file'. File may be incomplete."
            # Decide if we should return 1 here or try to continue. For now, let's note and continue.
        fi
    done
    log_info "Successfully saved all configuration variables to '$PWD/$config_file'"
    show_success "Configuration saved to $PWD/$config_file"
    show_info "You can use this file with the main installer: ./installer.sh --config $PWD/$config_file"
    return 0
}

# --- Main Function ---
main() {
    # Initialize log file - Note: log_debug might not be available until ui_functions.sh is sourced.
    # However, ui_functions.sh sourcing happens globally before main is called if script is run directly.
    # For robustness, initial log echo is fine, then switch to log_debug.
    echo "Starting Configuration Generator at $(date)" > "$LOG_FILE"
    log_debug "Entering function: ${FUNCNAME[0]}"

    show_header "LUKSZFS Configuration Generator"

    # Dialog utility check removed as we are phasing out its use.

    log_debug "Calling gather_zfs_options..."
    if ! gather_zfs_options; then 
        log_error "gather_zfs_options failed. Exiting main function."
        show_error "ZFS configuration failed. Exiting."; exit 1; 
    fi
    log_debug "gather_zfs_options completed successfully."

    log_debug "Calling gather_luks_options..."
    if ! gather_luks_options; then 
        log_error "gather_luks_options failed. Exiting main function."
        show_error "LUKS configuration failed. Exiting."; exit 1; 
    fi
    log_debug "gather_luks_options completed successfully."

    log_debug "Calling gather_network_options..."
    if ! gather_network_options; then 
        log_error "gather_network_options failed. Exiting main function."
        show_error "Network and System configuration failed. Exiting."; exit 1; 
    fi
    log_debug "gather_network_options completed successfully."

    # gather_system_options has been merged into gather_network_options
    log_debug "Calling gather_bootloader_options..."
    if ! gather_bootloader_options; then 
        log_error "gather_bootloader_options failed. Exiting main function."
        show_error "Bootloader configuration failed. Exiting."; exit 1; 
    fi
    log_debug "gather_bootloader_options completed successfully."

    show_header "Configuration Complete"
    echo "The following configuration has been generated:"
    log_debug "Displaying generated configuration to user."
    for key in "${!CONFIG_VARS[@]}"; do
        printf "  %s: %s\n" "$key" "${CONFIG_VARS[$key]}"
        log_debug "Generated config: %s='%s'" "$key" "${CONFIG_VARS[$key]}" # Log each generated var
    done
    echo ""

    if prompt_yes_no "Do you want to save this configuration?"; then
        log_debug "User chose to save the configuration. Calling save_generated_config..."
        if ! save_generated_config; then
            log_error "save_generated_config reported an error."
            # Main function continues, error handled within save_generated_config by returning non-zero
        else
            log_debug "save_generated_config completed."
        fi
    else
        log_debug "User chose not to save the configuration."
        show_warning "Configuration not saved."
    fi

    show_success "Configuration generator finished."
    log_debug "Exiting function: ${FUNCNAME[0]} successfully."
}

# --- Script Entry Point ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi

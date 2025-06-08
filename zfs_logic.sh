#!/usr/bin/env bash
#===============================================================================
# ZFS Pool and Dataset Configuration Module
#
# Features:
# - Advanced ZFS pool creation with optimal performance parameters
# - Intelligent dataset hierarchy with purpose-specific tuning
# - Comprehensive error detection and recovery
# - Performance monitoring during creation
#===============================================================================

set -o pipefail

# Default ZFS configuration if not specified
: "${ZFS_DEFAULT_ASHIFT:=12}"
: "${ZFS_DEFAULT_RECORDSIZE:=128K}"
: "${ZFS_DEFAULT_COMPRESSION:=lz4}"
: "${ZFS_DEFAULT_PRIMARYCACHE:=all}"
: "${ZFS_DEFAULT_REDUNDANT_METADATA:=most}"
: "${ZFS_DEFAULT_SPECIAL_VDEV:=false}"
: "${ZFS_FORCE_DESTROY:=false}"
: "${ZFS_VERIFY_POOL:=true}"

#-------------------------------------------------------------------------------
# ZFS Pool Configuration and Creation
#-------------------------------------------------------------------------------

setup_zfs_pool() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "ZFS" "Creating ZFS Pool and Datasets"
    
    # Extract configuration parameters with defaults
    local pool_name="${CONFIG_VARS[ZFS_POOL_NAME]}"
    local raid_level="${CONFIG_VARS[ZFS_RAID_LEVEL]}"
    local zfs_ashift="${CONFIG_VARS[ZFS_ASHIFT]:-$ZFS_DEFAULT_ASHIFT}"
    local zfs_recordsize="${CONFIG_VARS[ZFS_RECORDSIZE]:-$ZFS_DEFAULT_RECORDSIZE}"
    local zfs_compression="${CONFIG_VARS[ZFS_COMPRESSION]:-$ZFS_DEFAULT_COMPRESSION}"
    local zfs_primarycache="${CONFIG_VARS[ZFS_PRIMARYCACHE]:-$ZFS_DEFAULT_PRIMARYCACHE}"
    local zfs_redundant_metadata="${CONFIG_VARS[ZFS_REDUNDANT_METADATA]:-$ZFS_DEFAULT_REDUNDANT_METADATA}"
    local zfs_special_vdev="${CONFIG_VARS[ZFS_SPECIAL_VDEV]:-$ZFS_DEFAULT_SPECIAL_VDEV}"
    
    # Parse LUKS devices from configuration
    local luks_devices=()
    read -r -a luks_devices <<< "${CONFIG_VARS[LUKS_MAPPERS]}"
    
    # Parse special vdev devices if enabled
    local special_devices=()
    if [[ "$zfs_special_vdev" == "true" ]]; then
        read -r -a special_devices <<< "${CONFIG_VARS[ZFS_SPECIAL_DEVICES]}"
    fi
    
    # Validate required parameters
    if [[ -z "$pool_name" ]]; then
        log_error "ZFS pool name not specified in configuration"
        show_error "ZFS pool name not specified in configuration"
        return 1
    fi
    
    if [[ -z "$raid_level" ]]; then
        log_error "ZFS RAID level not specified in configuration"
        show_error "ZFS RAID level not specified in configuration"
        return 1
    fi
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        log_error "No LUKS devices specified for ZFS pool"
        show_error "No LUKS devices specified for ZFS pool"
        return 1
    fi
    
    # Validate device count based on RAID level
    case "$raid_level" in
        "mirror")
            if [[ ${#luks_devices[@]} -lt 2 ]]; then
                log_error "Mirror configuration requires at least 2 devices, got ${#luks_devices[@]}"
                show_error "Mirror configuration requires at least 2 devices"
                return 1
            fi
            ;;
        "raidz1")
            if [[ ${#luks_devices[@]} -lt 3 ]]; then
                log_warning "RAIDZ1 recommended with at least 3 devices, got ${#luks_devices[@]}"
                show_warning "RAIDZ1 recommended with at least 3 devices"
            fi
            ;;
        "raidz2")
            if [[ ${#luks_devices[@]} -lt 4 ]]; then
                log_warning "RAIDZ2 recommended with at least 4 devices, got ${#luks_devices[@]}"
                show_warning "RAIDZ2 recommended with at least 4 devices"
            fi
            ;;
        "raidz3")
            if [[ ${#luks_devices[@]} -lt 5 ]]; then
                log_warning "RAIDZ3 recommended with at least 5 devices, got ${#luks_devices[@]}"
                show_warning "RAIDZ3 recommended with at least 5 devices"
            fi
            ;;
    esac
    
    # Log configuration parameters
    log_debug "ZFS Pool Name: $pool_name"
    log_debug "ZFS RAID Level: $raid_level"
    log_debug "ZFS ashift: $zfs_ashift"
    log_debug "ZFS recordsize: $zfs_recordsize"
    log_debug "ZFS compression: $zfs_compression"
    log_debug "ZFS primary cache: $zfs_primarycache" 
    log_debug "ZFS redundant metadata: $zfs_redundant_metadata"
    log_debug "ZFS special vdev: $zfs_special_vdev"
    log_debug "LUKS devices for ZFS pool: ${luks_devices[*]}"
    
    if [[ "$zfs_special_vdev" == "true" ]]; then
        log_debug "Special vdev devices: ${special_devices[*]}"
    fi
    
    # Check if ZFS modules are loaded
    if ! lsmod | grep -q "^zfs "; then
        log_warning "ZFS kernel module not loaded, attempting to load"
        if ! modprobe zfs; then
            log_error "Failed to load ZFS kernel module"
            show_error "Failed to load ZFS kernel module. Is ZFS installed?"
            return 1
        fi
    fi
    
    # Check for existing pool
    if zpool list -H "$pool_name" &>/dev/null; then
        if [[ "$ZFS_FORCE_DESTROY" == "true" ]]; then
            log_warning "Pool $pool_name already exists. Destroying as per configuration..."
            show_warning "Pool $pool_name already exists. Destroying..."
            
            # Attempt to export if it's imported
            zpool export -f "$pool_name" &>> "$LOG_FILE" || true
            
            # Force destroy the pool
            if ! zpool destroy -f "$pool_name" &>> "$LOG_FILE"; then
                log_error "Failed to destroy existing pool $pool_name"
                show_error "Failed to destroy existing pool $pool_name"
                return 1
            fi
            log_debug "Pool $pool_name destroyed successfully"
        else
            log_error "Pool $pool_name already exists and ZFS_FORCE_DESTROY is not enabled"
            show_error "Pool $pool_name already exists. Set ZFS_FORCE_DESTROY=true to override."
            return 1
        fi
    fi
    
    # Display progress information
    show_progress "Creating ZFS pool with the following configuration:"
    show_progress "- RAID level: $raid_level"
    show_progress "- Ashift: $zfs_ashift"
    show_progress "- Record size: $zfs_recordsize"
    show_progress "- Compression: $zfs_compression"
    show_progress "- Primary cache: $zfs_primarycache"
    show_progress "- Redundant metadata: $zfs_redundant_metadata"
    show_progress "- Special vdev: $zfs_special_vdev"
    
    # Build the zpool create command
    local zpool_cmd="zpool create -f"
    
    # Add pool properties
    zpool_cmd+=" -o ashift=${zfs_ashift}"
    zpool_cmd+=" -o autotrim=on"
    
    # Add common dataset properties
    zpool_cmd+=" -O acltype=posixacl"
    zpool_cmd+=" -O atime=off"
    zpool_cmd+=" -O canmount=off"
    zpool_cmd+=" -O compression=${zfs_compression}"
    zpool_cmd+=" -O devices=off"
    zpool_cmd+=" -O dnodesize=auto"
    zpool_cmd+=" -O normalization=formD"
    zpool_cmd+=" -O relatime=off"
    zpool_cmd+=" -O xattr=sa"
    zpool_cmd+=" -O mountpoint=none"
    zpool_cmd+=" -O setuid=off"
    zpool_cmd+=" -O primarycache=${zfs_primarycache}"
    zpool_cmd+=" -O redundant_metadata=${zfs_redundant_metadata}"
    zpool_cmd+=" -O recordsize=${zfs_recordsize}"
    
    # Set alternate root for installation
    zpool_cmd+=" -R /mnt"
    
    # Add pool name
    zpool_cmd+=" $pool_name"
    
    # Add RAID configuration
    case "$raid_level" in
        "single")
            zpool_cmd+=" ${luks_devices[0]}"
            ;;
        "mirror")
            zpool_cmd+=" mirror ${luks_devices[*]}"
            ;;
        "raidz1"|"raidz")
            zpool_cmd+=" raidz1 ${luks_devices[*]}"
            ;;
        "raidz2")
            zpool_cmd+=" raidz2 ${luks_devices[*]}"
            ;;
        "raidz3")
            zpool_cmd+=" raidz3 ${luks_devices[*]}"
            ;;
        "draid1")
            zpool_cmd+=" draid1 ${luks_devices[*]}"
            ;;
        "draid2")
            zpool_cmd+=" draid2 ${luks_devices[*]}"
            ;;
        *)
            log_error "Unknown RAID level: $raid_level"
            show_error "Unknown RAID level: $raid_level"
            return 1
            ;;
    esac
    
    # Add special vdev if configured
    if [[ "$zfs_special_vdev" == "true" && ${#special_devices[@]} -gt 0 ]]; then
        if [[ ${#special_devices[@]} -ge 2 ]]; then
            zpool_cmd+=" special mirror ${special_devices[*]}"
        else
            zpool_cmd+=" special ${special_devices[0]}"
        fi
    fi
    
    # Execute the pool creation command
    log_debug "Executing ZFS pool creation: $zpool_cmd"
    show_progress "Creating ZFS pool '$pool_name'..."
    
    # Use script to capture all output
    local tmp_output
    tmp_output=$(mktemp)
    
    if script -q -c "eval $zpool_cmd" "$tmp_output"; then
        cat "$tmp_output" >> "$LOG_FILE"
        log_debug "ZFS pool $pool_name created successfully"
    else
        local exit_status=$?
        cat "$tmp_output" >> "$LOG_FILE"
        rm -f "$tmp_output"
        
        log_error "Failed to create ZFS pool (exit code $exit_status)"
        show_error "Failed to create ZFS pool. Check logs for details."
        
        # Attempt cleanup
        zpool destroy -f "$pool_name" &>/dev/null || true
        return 1
    fi
    
    rm -f "$tmp_output"
    
    # Verify the pool
    if [[ "$ZFS_VERIFY_POOL" == "true" ]]; then
        show_progress "Verifying ZFS pool integrity..."
        if ! zpool status "$pool_name" &>> "$LOG_FILE"; then
            log_error "ZFS pool verification failed"
            show_error "ZFS pool verification failed"
            return 1
        fi
    fi
    
    show_success "ZFS pool '$pool_name' created successfully"
    
    # Create dataset structure
    create_zfs_datasets "$pool_name" || return 1
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

#-------------------------------------------------------------------------------
# ZFS Dataset Creation and Configuration
#-------------------------------------------------------------------------------

create_zfs_datasets() {
    local pool_name="$1"
    log_debug "Entering function: create_zfs_datasets for pool $pool_name"
    
    show_progress "Creating ZFS dataset hierarchy..."
    
    # Collect dataset-specific options from configuration
    local dataset_options=(
        "ROOT:canmount=off:mountpoint=none"
        "ROOT/pve-1:canmount=on:mountpoint=/"
        "home:mountpoint=/home"
        "var:mountpoint=/var"
        "var/lib:mountpoint=/var/lib"
        "var/lib/vz:mountpoint=/var/lib/vz"
        "var/log:mountpoint=/var/log:recordsize=64K"
        "tmp:mountpoint=/tmp:setuid=on:exec=on:devices=on"
    )
    
    # Add custom datasets from configuration
    if [[ -n "${CONFIG_VARS[ZFS_CUSTOM_DATASETS]}" ]]; then
        readarray -t custom_datasets <<< "${CONFIG_VARS[ZFS_CUSTOM_DATASETS]}"
        for custom_dataset in "${custom_datasets[@]}"; do
            dataset_options+=("$custom_dataset")
        done
    fi
    
    # Create all datasets
    local dataset_count=${#dataset_options[@]}
    local current=0
    
    for dataset_spec in "${dataset_options[@]}"; do
        ((current++))
        # shellcheck disable=SC2034 # PROGRESS_PCT is for potential future UI enhancement
        PROGRESS_PCT=$(( current * 100 / dataset_count ))
        
        # Parse dataset specification
        IFS=':' read -r dataset_path options_str <<< "$dataset_spec"
        local dataset_name="${pool_name}/${dataset_path}"
        
        # Convert options string to command arguments
        local dataset_opts=""
        if [[ -n "$options_str" ]]; then
            IFS=':' read -r -a options <<< "$options_str"
            for opt in "${options[@]}"; do
                dataset_opts+=" -o $opt"
            done
        fi
        
        # Create the dataset
        log_debug "Creating dataset $dataset_name with options: $dataset_opts"
        show_progress "Creating dataset $dataset_name (${current}/${dataset_count})..."
        
        local create_cmd="zfs create$dataset_opts $dataset_name"
        log_debug "Executing: $create_cmd"
        
        if ! eval "$create_cmd" &>> "$LOG_FILE"; then
            log_error "Failed to create dataset $dataset_name"
            show_error "Failed to create dataset $dataset_name"
            return 1
        fi
    done
    
    # Set bootfs property on pool
    log_debug "Setting bootfs to ${pool_name}/ROOT/pve-1"
    show_progress "Setting boot filesystem..."
    
    if ! zpool set bootfs="${pool_name}/ROOT/pve-1" "$pool_name" &>> "$LOG_FILE"; then
        log_error "Failed to set bootfs property on pool $pool_name"
        show_error "Failed to set bootfs property"
        return 1
    fi
    
    # Set specific dataset properties for VM storage
    local vm_dataset="${pool_name}/var/lib/vz"
    
    log_debug "Setting VM storage optimizations for $vm_dataset"
    show_progress "Optimizing VM storage dataset..."
    
    # VM storage optimizations
    zfs set relatime=on "$vm_dataset" &>> "$LOG_FILE" || true
    zfs set compression=zstd-1 "$vm_dataset" &>> "$LOG_FILE" || true
    zfs set atime=off "$vm_dataset" &>> "$LOG_FILE" || true
    
    # Set appropriate recordsize for VM storage
    zfs set recordsize=1M "$vm_dataset" &>> "$LOG_FILE" || true
    
    # Configure logfile dataset
    local log_dataset="${pool_name}/var/log"
    zfs set compression=zstd-3 "$log_dataset" &>> "$LOG_FILE" || true
    zfs set atime=off "$log_dataset" &>> "$LOG_FILE" || true
    
    # Verify datasets are properly mounted
    show_progress "Verifying dataset mount points..."
    
    if ! zfs list -r "$pool_name" &>> "$LOG_FILE"; then
        log_warning "Issue listing datasets for pool $pool_name"
        show_warning "Issue listing datasets - check mount points manually after install"
    fi
    
    show_success "ZFS dataset hierarchy created successfully"
    log_debug "Exiting function: create_zfs_datasets"
    return 0
}

#-------------------------------------------------------------------------------
# ZFS Cache Management
#-------------------------------------------------------------------------------

create_zfs_cache() {
    local pool_name="$1"
    local target_dir="/mnt/etc/zfs"
    
    log_debug "Entering function: create_zfs_cache for pool $pool_name"
    show_progress "Creating ZFS cache files..."
    
    # Ensure target directory exists
    mkdir -p "$target_dir" &>> "$LOG_FILE"
    
    # Export pool information to cache file
    if ! zpool set cachefile="$target_dir/zpool.cache" "$pool_name" &>> "$LOG_FILE"; then
        log_warning "Failed to create ZFS cache file"
        show_warning "Failed to create ZFS cache file - may need manual regeneration after boot"
        return 1
    fi
    
    # Ensure permissions are correct
    chmod 755 "$target_dir" &>> "$LOG_FILE"
    chmod 644 "$target_dir/zpool.cache" &>> "$LOG_FILE"
    
    show_success "ZFS cache file created"
    log_debug "Exiting function: create_zfs_cache"
    return 0
}

#-------------------------------------------------------------------------------
# ZFS Pool Information and Status
#-------------------------------------------------------------------------------

display_zfs_pool_info() {
    local pool_name="$1"
    
    log_debug "Entering function: display_zfs_pool_info for pool $pool_name"
    show_progress "Retrieving ZFS pool information..."
    
    # Check if pool exists
    if ! zpool list -H "$pool_name" &>/dev/null; then
        log_error "Pool $pool_name does not exist"
        show_error "Pool $pool_name does not exist"
        return 1
    fi
    
    # Display pool status
    show_step "ZFS INFO" "ZFS Pool Information for $pool_name"
    
    local pool_info
    pool_info=$(zpool status "$pool_name")
    echo "$pool_info" >> "$LOG_FILE"
    echo -e "\nZFS Pool Status:\n$pool_info"
    
    # Display dataset information
    local dataset_info
    dataset_info=$(zfs list -r "$pool_name")
    echo "$dataset_info" >> "$LOG_FILE"
    echo -e "\nZFS Datasets:\n$dataset_info"
    
    # Display pool properties
    local properties_info
    properties_info=$(zpool get all "$pool_name")
    echo "$properties_info" >> "$LOG_FILE"
    echo -e "\nZFS Pool Properties:\n$properties_info"
    
    log_debug "Exiting function: display_zfs_pool_info"
    return 0
}

# Export functions
export -f setup_zfs_pool
export -f create_zfs_datasets
export -f create_zfs_cache
export -f display_zfs_pool_info
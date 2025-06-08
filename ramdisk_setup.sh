#!/usr/bin/env bash

# Function to verify sufficient RAM is available before mounting tmpfs
verify_memory_availability() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Get available memory in kB
    local mem_available
    mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    # Convert to GB (with decimal precision)
    local mem_available_gb
    mem_available_gb=$(awk "BEGIN {printf \"%.2f\", $mem_available/1024/1024}")
    
    # Desired RAM disk size in GB
    local ramdisk_size=5
    # Required buffer (additional memory needed for system operation)
    local buffer_gb=1
    
    log_debug "Available memory: ${mem_available_gb}GB, Required: ${ramdisk_size}GB + ${buffer_gb}GB buffer"
    
    if (( $(echo "$mem_available_gb < $ramdisk_size + $buffer_gb" | bc -l) )); then
        log_debug "Insufficient memory! Available: ${mem_available_gb}GB, Required: at least $((ramdisk_size+buffer_gb))GB"
        show_warning "Low memory detected: ${mem_available_gb}GB available"
        
        # If we have less than the desired amount but more than 3GB, try with smaller size
        if (( $(echo "$mem_available_gb >= 3 + $buffer_gb" | bc -l) )); then
            local new_size=3
            log_debug "Trying with reduced RAM disk size: ${new_size}GB"
            show_progress "Adapting to use ${new_size}GB RAM disk instead of ${ramdisk_size}GB"
            return $new_size
        else
            show_error "Insufficient memory for RAM disk operation. At least $((ramdisk_size + buffer_gb))GB required, only ${mem_available_gb}GB available"
            return 0  # Return 0 indicating failure
        fi
    fi
    
    log_debug "Memory check passed, proceeding with ${ramdisk_size}GB RAM disk"
    return $ramdisk_size
}

# Function to determine optimal RAM disk size
determine_ramdisk_size() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Check size of original system (excluding dirs we won't copy)
    local system_size
    system_size=$(du -sm --exclude=/proc --exclude=/sys --exclude=/dev \
                         --exclude=/run --exclude=/mnt --exclude=/media \
                         --exclude="$RAMDISK_MNT" --exclude=/tmp --max-depth=0 / 2>/dev/null | awk '{print $1}')
    
    # Convert MB to GB with 10% overhead
    local required_size
    required_size=$(awk "BEGIN {printf \"%.1f\", ($system_size * 1.1)/1024}")
    
    log_debug "Calculated required RAM disk size: ${required_size}GB (based on ${system_size}MB system size)"
    
    # Call memory availability verification
    verify_memory_availability
    local available_size=$?
    
    if [[ $available_size -eq 0 ]]; then
        # Memory verification failed
        return 0
    fi
    
    # Determine final size: smaller of required or available
    local final_size
    final_size=$(awk "BEGIN {print ($required_size < $available_size) ? $required_size : $available_size}")
    log_debug "Final RAM disk size: ${final_size}GB"
    
    echo "$final_size"
    return 0
}

# Function to display better rsync progress
show_rsync_progress() {
    local tmp_log
    tmp_log=$(mktemp)
    local total_size
    total_size=$(du -sm --exclude=/proc --exclude=/sys --exclude=/dev \
                       --exclude=/run --exclude=/mnt --exclude=/media \
                       --exclude="$RAMDISK_MNT" --max-depth=0 / 2>/dev/null | awk '{print $1}')
    
    log_debug "Starting rsync with progress output to $tmp_log"
    log_debug "Estimated total size: ${total_size}MB"
    
    # Start rsync with progress in background
    rsync -ax --info=progress2 / "$RAMDISK_MNT/" --exclude=/proc --exclude=/sys \
          --exclude=/dev --exclude=/run --exclude=/mnt --exclude=/media \
          --exclude="$RAMDISK_MNT" > "$tmp_log" 2>&1 &
    
    local rsync_pid=$!
    local progress_length=50  # Length of progress bar
    
    # Update progress display while rsync runs
    while kill -0 $rsync_pid 2>/dev/null; do
        if [[ -f "$tmp_log" ]]; then
            local current
            current=$(grep -oP '\d+(?=%)' "$tmp_log" 2>/dev/null | tail -1)
            if [[ -n "$current" ]]; then
                local completed=$((current * progress_length / 100))
                local remaining=$((progress_length - completed))
                
                # Create progress bar string
                local progress_bar="["
                progress_bar+=$(printf "%${completed}s" | tr ' ' '#')
                progress_bar+=$(printf "%${remaining}s" | tr ' ' ' ')
                progress_bar+="] ${current}%"
                
                # Show the progress
                show_progress "Copying system to RAM disk: $progress_bar"
            fi
        fi
        sleep 0.5
    done
    
    # Get rsync exit status
    wait $rsync_pid
    local rsync_status=$?
    
    # Cleanup
    rm -f "$tmp_log"
    
    return $rsync_status
}

# Function to verify critical files in RAM disk
verify_ramdisk_integrity() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    show_progress "Verifying RAM disk integrity..."
    
    # List of critical files to check
    local critical_files=(
        "/bin/bash"
        "/usr/bin/rsync"
        "/usr/sbin/chroot"
        "/root/installer/installer.sh"
    )
    
    local missing_files=()
    
    for file in "${critical_files[@]}"; do
        log_debug "Checking for $RAMDISK_MNT$file"
        if [[ ! -f "$RAMDISK_MNT$file" ]]; then
            log_debug "Missing critical file: $file"
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_debug "Missing critical files: ${missing_files[*]}"
        show_error "RAM disk integrity check failed. Missing files: ${missing_files[*]}"
        return 1
    fi
    
    # Verify executable permissions
    if [[ ! -x "$RAMDISK_MNT/root/installer/installer.sh" ]]; then
        log_debug "Executable permission missing on installer.sh"
        show_warning "Fixing executable permissions on installer.sh"
        chmod +x "$RAMDISK_MNT/root/installer/installer.sh" &>> "$LOG_FILE"
    fi
    
    log_debug "RAM disk integrity check passed"
    show_success "RAM disk integrity verified"
    return 0
}

# Function to monitor RAM disk usage
monitor_ramdisk_usage() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Get RAM disk size in bytes
    local size_bytes
    size_bytes=$(stat -f -c "%S * %b" "$RAMDISK_MNT" | bc)
    local size_gb
    size_gb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1024/1024/1024}")
    
    # Get current usage
    local used_bytes
    used_bytes=$(stat -f -c "%S * (%b - %f)" "$RAMDISK_MNT" | bc)
    local used_gb
    used_gb=$(awk "BEGIN {printf \"%.2f\", $used_bytes/1024/1024/1024}")
    
    # Calculate percentage
    local usage_percent
    usage_percent=$(awk "BEGIN {printf \"%.1f\", 100 * $used_bytes/$size_bytes}")
    
    log_debug "RAM disk usage: ${used_gb}GB / ${size_gb}GB (${usage_percent}%)"
    
    # Alert if usage is over 80%
    if (( $(echo "$usage_percent > 80" | bc -l) )); then
        show_warning "RAM disk usage is high: ${usage_percent}% (${used_gb}GB / ${size_gb}GB)"
    fi
    
    return 0
}

# Function for proper cleanup of RAM disk
cleanup_ramdisk() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    log_debug "Unmounting system directories from RAM disk"
    umount -lf "$RAMDISK_MNT/sys" &>> "$LOG_FILE" || log_debug "Failed to unmount $RAMDISK_MNT/sys"
    umount -lf "$RAMDISK_MNT/proc" &>> "$LOG_FILE" || log_debug "Failed to unmount $RAMDISK_MNT/proc"
    umount -lf "$RAMDISK_MNT/dev" &>> "$LOG_FILE" || log_debug "Failed to unmount $RAMDISK_MNT/dev"
    
    # Ensure all processes in the RAM disk are terminated
    if mountpoint -q "$RAMDISK_MNT"; then
        log_debug "Terminating any processes still using the RAM disk"
        fuser -km "$RAMDISK_MNT" &>> "$LOG_FILE" || true
        
        log_debug "Attempting to unmount RAM disk at $RAMDISK_MNT"
        if ! umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE"; then
            log_debug "Failed to unmount RAM disk, trying with increased verbosity"
            umount -v -lf "$RAMDISK_MNT" &>> "$LOG_FILE" || log_debug "Failed to unmount RAM disk with increased verbosity"
        fi
    else
        log_debug "$RAMDISK_MNT is not a mountpoint"
    fi
    
    return 0
}

prepare_ram_environment() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "RAM DISK PREPARATION"
    
    # Determine optimal RAM disk size
    local ramdisk_size
    ramdisk_size=$(determine_ramdisk_size)
    
    if [[ $ramdisk_size -eq 0 ]]; then
        log_debug "RAM disk sizing failed. Cannot continue."
        show_error "Insufficient memory for RAM disk operation"
        exit 1
    fi
    
    show_progress "Creating a ${ramdisk_size}GB filesystem in RAM..."
    log_debug "Creating RAM disk mount point: $RAMDISK_MNT"
    mkdir -p "$RAMDISK_MNT"
    
    log_debug "Executing: mount -t tmpfs -o size=${ramdisk_size}G,rw tmpfs $RAMDISK_MNT"
    if ! mount -t tmpfs -o size="${ramdisk_size}"G,rw tmpfs "$RAMDISK_MNT" &>> "$LOG_FILE"; then
        log_debug "Failed to mount RAM disk at $RAMDISK_MNT. Check available memory and permissions."
        show_error "Failed to mount RAM disk at $RAMDISK_MNT. Check available memory and permissions."
        exit 1
    fi
    log_debug "RAM disk mounted successfully."

    show_progress "Creating base directory structure in RAM disk..."
    log_debug "Creating base directory structure in RAM disk."
    mkdir -p "$RAMDISK_MNT"/{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var} &>> "$LOG_FILE"

    # Use enhanced rsync with progress
    show_progress "Copying system to RAM disk (this will take a moment)..."
    log_debug "Starting rsync with progress tracking"
    show_rsync_progress
    local rsync_status=$?
    
    # Handle rsync status
    if [[ $rsync_status -ne 0 && $rsync_status -ne 24 ]]; then
        log_debug "Rsync encountered a critical error (status $rsync_status)."
        show_error "Failed to copy system to RAM disk. Status: $rsync_status"
        cleanup_ramdisk
        exit 1
    elif [[ $rsync_status -eq 24 ]]; then
        log_debug "Rsync reported status 24 (partial transfer). This is often non-critical."
        show_warning "Some files couldn't be copied (status 24). This may be okay. Continuing..."
    else
        log_debug "Rsync completed successfully."
        show_success "System copied to RAM disk successfully"
    fi


    # Copy installer files
    log_debug "Copying installer directory ($SCRIPT_DIR) to $RAMDISK_MNT/root/installer/"
    mkdir -p "$RAMDISK_MNT/root/installer" &>> "$LOG_FILE"
    cp -r "$SCRIPT_DIR"/* "$RAMDISK_MNT/root/installer/" &>> "$LOG_FILE"
    
    local main_script_in_ram="$RAMDISK_MNT/root/installer/installer.sh"
    log_debug "Making main installer script executable in RAM disk: $main_script_in_ram"
    chmod +x "$main_script_in_ram" &>> "$LOG_FILE"

    # Handle config file if provided
    if [[ -n "${CONFIG_FILE_PATH:-}" && -f "${CONFIG_FILE_PATH}" ]]; then
        log_debug "Copying config file $CONFIG_FILE_PATH to $RAMDISK_MNT/root/installer/"
        cp "$CONFIG_FILE_PATH" "$RAMDISK_MNT/root/installer/" &>> "$LOG_FILE"
    else
        log_debug "No config file path provided or file does not exist. Skipping copy."
    fi

    # Copy debs directory if it exists
    local debs_source="$SCRIPT_DIR/debs"
    if [ -d "$debs_source" ]; then
        log_debug "Copying 'debs' directory to RAM disk..."
        show_progress "Copying package cache to RAM disk..."
        mkdir -p "$RAMDISK_MNT/root/installer/debs" &>> "$LOG_FILE"
        cp -r "$debs_source"/* "$RAMDISK_MNT/root/installer/debs/" &>> "$LOG_FILE" || {
            log_debug "Failed to copy 'debs' directory."
            show_warning "Failed to copy package cache. Local package installation might fail."
        }
    else
        log_debug "No 'debs' directory found, skipping."
    fi

    # Make download script executable if it exists
    if [ -f "$RAMDISK_MNT/root/installer/download_debs.sh" ]; then
        log_debug "Making download_debs.sh executable in RAM disk."
        chmod +x "$RAMDISK_MNT/root/installer/download_debs.sh" &>> "$LOG_FILE"
    fi
    
    # Verify RAM disk integrity
    if ! verify_ramdisk_integrity; then
        log_debug "RAM disk integrity check failed."
        cleanup_ramdisk
        exit 1
    fi
    
    # Monitor RAM disk usage
    monitor_ramdisk_usage

    # Mount system directories
    log_debug "Mounting system directories into RAM disk"
    show_progress "Binding system directories to RAM environment..."
    
    if ! mount --rbind /dev "$RAMDISK_MNT/dev" &>> "$LOG_FILE"; then
        log_debug "Failed to mount /dev into RAM disk."
        show_error "Failed to mount /dev into RAM disk"
        cleanup_ramdisk
        exit 1
    fi
    
    if ! mount --rbind /proc "$RAMDISK_MNT/proc" &>> "$LOG_FILE"; then
        log_debug "Failed to mount /proc into RAM disk."
        show_error "Failed to mount /proc into RAM disk"
        umount -lf "$RAMDISK_MNT/dev" &>> "$LOG_FILE" || true
        cleanup_ramdisk
        exit 1
    fi
    
    if ! mount --rbind /sys "$RAMDISK_MNT/sys" &>> "$LOG_FILE"; then
        log_debug "Failed to mount /sys into RAM disk."
        show_error "Failed to mount /sys into RAM disk"
        umount -lf "$RAMDISK_MNT/proc" &>> "$LOG_FILE" || true
        umount -lf "$RAMDISK_MNT/dev" &>> "$LOG_FILE" || true
        cleanup_ramdisk
        exit 1
    fi
    
    log_debug "System directories mounted successfully."
    show_success "RAM environment prepared successfully"

    show_header "PIVOTING TO RAM DISK"
    show_warning "The system is now running from RAM. The original boot media can be safely removed if it is also the target."
    log_debug "Pivoting to RAM disk. Preparing chroot command..."

    local chroot_cmd_str="cd /root/installer && ./installer.sh --run-from-ram"
    if [[ -n "${CONFIG_FILE_PATH:-}" && -f "${CONFIG_FILE_PATH}" ]]; then
        # Config file was copied into /root/installer in RAM disk, so basename is correct.
        chroot_cmd_str+=" --config $(basename "$CONFIG_FILE_PATH")"
    fi
    log_debug "Chroot command to execute: $chroot_cmd_str"

    echo "--- Chroot to RAM Disk Output Start ---" >> "$LOG_FILE"
    chroot "$RAMDISK_MNT" /bin/bash -c "$chroot_cmd_str" &>> "$LOG_FILE"
    local exit_status=$?
    echo "--- Chroot to RAM Disk Output End ---" >> "$LOG_FILE"
    log_debug "Chroot command finished. Exit status: $exit_status"

    # Add cleanup trap - this will complement any existing traps
    trap "log_debug 'Cleanup trap triggered for RAM disk'; cleanup_ramdisk" EXIT
    
    log_debug "Exiting function: ${FUNCNAME[0]}. Cleanup will be handled by trap."
    exit $exit_status
}

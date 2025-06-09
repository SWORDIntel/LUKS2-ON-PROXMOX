#!/usr/bin/env bash
#===============================================================================
# RAM Disk Pivot Logic for Advanced Installers
#===============================================================================

# --- Configuration (assumed to be set by the main script) ---
: "${RAMDISK_MNT:=/mnt/ramdisk}"
: "${SCRIPT_DIR:=.}"
: "${LOG_FILE:=/tmp/installer.log}"

# --- Logging and UI functions are assumed to be sourced from a common utility script ---
# log_debug, show_header, show_step, show_progress, show_success, show_error, show_warning

#-------------------------------------------------------------------------------
# Helper Functions for RAM Disk Management
#-------------------------------------------------------------------------------

# A more robust check for memory availability using integer arithmetic (in MB).
# Returns the recommended RAM disk size in GB on success, or 0 on failure.
_get_recommended_ramdisk_size() {
    log_debug "Entering helper: ${FUNCNAME[0]}"

    # Get available memory and estimated system size in Megabytes to avoid floating point math.
    local mem_available_mb; mem_available_mb=$(( $(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024 ))
    # Use `df` for a fast estimate of used space on the root filesystem.
    local system_size_mb; system_size_mb=$(( $(df --output=used -B M / | tail -n 1 | tr -d 'M') ))
    
    # Required size is system size + 20% buffer + 500MB for new packages/logs.
    local required_size_mb=$(( (system_size_mb * 120 / 100) + 500 ))
    local required_buffer_mb=1024 # Reserve 1GB for kernel and other processes.
    
    log_debug "MemAvailable: ${mem_available_mb}MB, Required for copy: ${required_size_mb}MB, System buffer: ${required_buffer_mb}MB"

    if (( mem_available_mb < (required_size_mb + required_buffer_mb) )); then
        show_error "Insufficient available memory (${mem_available_mb}MB) to create a stable RAM disk."
        show_error "Required: ~${required_size_mb}MB for system files + ${required_buffer_mb}MB buffer."
        return 1
    fi

    # Return the required size in Gigabytes, rounded up.
    local final_size_gb=$(( (required_size_mb + 1023) / 1024 ))
    # Ensure a minimum size of 4GB for safety.
    if (( final_size_gb < 4 )); then final_size_gb=4; fi

    log_info "Determined optimal RAM disk size: ${final_size_gb}GB"
    echo "$final_size_gb"
    return 0
}

# Simplified and more robust copy function using `pv` for progress.
# Assumes `pv` is installed (it should be a pre-flight check dependency).
_copy_system_with_progress() {
    log_debug "Entering helper: ${FUNCNAME[0]}"
    
    if ! command -v pv &>/dev/null; then
        show_error "'pv' (Pipe Viewer) is not installed. Cannot show progress."
        show_progress "Copying system to RAM disk (no progress available)..."
        # Fallback to standard rsync without progress monitoring
        rsync -axv --exclude={"/proc/*","/sys/*","/dev/*","/run/*","/mnt/*","/media/*","/tmp/*","$RAMDISK_MNT/*"} / "$RAMDISK_MNT/"
        return $?
    fi

    # Estimate total size for `pv`
    local total_size; total_size=$(df --output=used -B 1 / | tail -n 1)

    show_progress "Copying system to RAM disk..."
    # Use tar to stream files, pv to show progress, and tar to extract in the destination.
    # This is a very common, fast, and reliable pattern.
    (cd / && tar --exclude={"./proc","./sys","./dev","./run","./mnt","./media","./tmp","./mnt/ramdisk"} -cf - .) | \
    pv -s "$total_size" -N "Copying" | \
    (cd "$RAMDISK_MNT" && tar -xf -)
    
    # The exit code of a pipeline is the exit code of the last command. `tar -x` should be 0.
    # We check pipe status to ensure all parts of the pipe succeeded.
    if [[ "${PIPESTATUS[0]}" -eq 0 && "${PIPESTATUS[2]}" -eq 0 ]]; then
        return 0
    else
        log_error "Failed during tar|pv|tar pipeline. Tar-Create: ${PIPESTATUS[0]}, PV: ${PIPESTATUS[1]}, Tar-Extract: ${PIPESTATUS[2]}"
        return 1
    fi
}

# Simplified integrity check.
_verify_ramdisk_integrity() {
    log_debug "Entering helper: ${FUNCNAME[0]}"
    local missing_file=0
    for file in "/bin/bash" "/usr/sbin/chroot"; do
        if [[ ! -f "$RAMDISK_MNT$file" ]]; then
            show_error "Critical file missing in RAM disk: $file"
            missing_file=1
        fi
    done
    [[ "$missing_file" -eq 1 ]] && return 1

    # Specifically check the installer script we will execute.
    if [[ ! -x "$RAMDISK_MNT/root/installer/installer.sh" ]]; then
        show_error "Main installer script is missing or not executable in RAM disk."
        return 1
    fi

    show_success "RAM disk integrity verified."
    return 0
}

#-------------------------------------------------------------------------------
# Main Orchestration Function
#-------------------------------------------------------------------------------

prepare_and_pivot_to_ram() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "RAM DISK PREPARATION"
    
    # 1. Determine size and create RAM disk.
    local ramdisk_size_gb
    local ramdisk_size_gb_output
    log_debug "Determining recommended RAM disk size..."
    if ! ramdisk_size_gb_output=$(_get_recommended_ramdisk_size); then
        # Error message already shown by _get_recommended_ramdisk_size
        log_error "Failed to determine recommended RAM disk size."
        exit 1
    fi
    ramdisk_size_gb="$ramdisk_size_gb_output"
    log_debug "RAM disk size determined: ${ramdisk_size_gb}GB"

    show_progress "Creating a ${ramdisk_size_gb}GB filesystem in RAM at $RAMDISK_MNT..."
    log_debug "Creating RAM disk mount point: $RAMDISK_MNT"
    if ! mkdir -p "$RAMDISK_MNT"; then
        log_error "Failed to create RAM disk mount point $RAMDISK_MNT. mkdir status: $?"
        exit 1
    fi
    log_debug "RAM disk mount point $RAMDISK_MNT created."

    log_debug "Attempting to mount tmpfs of size ${ramdisk_size_gb}G to $RAMDISK_MNT"
    if ! mount -t tmpfs -o size="${ramdisk_size_gb}G,rw" tmpfs "$RAMDISK_MNT"; then
        log_error "tmpfs mount failed for $RAMDISK_MNT. mount status: $?"
        show_error "Failed to mount RAM disk. Check kernel logs and available memory."
        exit 1
    fi
    log_debug "tmpfs mounted successfully on $RAMDISK_MNT."
    trap 'umount -lf "$RAMDISK_MNT" &>/dev/null' EXIT # Add cleanup trap
    log_debug "EXIT trap set for RAM disk cleanup: umount -lf \"$RAMDISK_MNT\""

    # 2. Copy the system.
    log_debug "Starting system file copy to RAM disk via _copy_system_with_progress..."
    if ! _copy_system_with_progress; then
        log_error "_copy_system_with_progress failed. See previous errors for details."
        show_error "Failed to copy system files to RAM disk."
        exit 1
    fi
    log_debug "_copy_system_with_progress completed successfully."
    show_success "System files copied to RAM disk."

    # 3. Copy the installer itself.
    log_debug "Starting installer files copy to RAM disk."
    show_progress "Copying installer files to RAM disk..."
    local installer_ramdisk_target_dir="$RAMDISK_MNT/root/installer"
    log_debug "Creating installer target directory in RAM disk: $installer_ramdisk_target_dir"
    if ! mkdir -p "$installer_ramdisk_target_dir"; then
        log_error "Failed to create $installer_ramdisk_target_dir. mkdir status: $?"
        show_error "Failed to create installer directory in RAM disk."
        exit 1
    fi
    log_debug "Installer target directory $installer_ramdisk_target_dir created."

    log_debug "rsyncing installer files from $SCRIPT_DIR/ to $installer_ramdisk_target_dir/"
    # Use rsync to be safe and efficient.
    if ! rsync -a "$SCRIPT_DIR/" "$installer_ramdisk_target_dir/" &>> "$LOG_FILE"; then
        log_error "rsync failed to copy installer files. rsync status: $?. Check $LOG_FILE for rsync output."
        show_error "Failed to copy installer files to RAM disk."
        exit 1
    fi
    log_debug "rsync of installer files completed."

    log_debug "Setting execute permissions on $installer_ramdisk_target_dir/installer.sh"
    if ! chmod +x "$installer_ramdisk_target_dir/installer.sh"; then
        log_error "chmod +x failed for $installer_ramdisk_target_dir/installer.sh. chmod status: $?"
        show_error "Failed to set execute permissions on installer script in RAM disk."
        exit 1
    fi
    log_debug "Execute permissions set on installer script in RAM disk."

    # 4. Verify integrity.
    log_debug "Starting RAM disk integrity verification via _verify_ramdisk_integrity..."
    if ! _verify_ramdisk_integrity; then
        log_error "_verify_ramdisk_integrity failed. See previous errors for details."
        # _verify_ramdisk_integrity should show its own error message
        exit 1
    fi
    log_debug "_verify_ramdisk_integrity completed successfully."

    # 5. Prepare the chroot environment.
    log_debug "Preparing chroot environment..."
    show_progress "Binding system directories to RAM environment..."

    log_debug "Binding /dev to $RAMDISK_MNT/dev"
    if ! mount --make-rslave --rbind /dev "$RAMDISK_MNT/dev"; then log_error "Failed to bind /dev. mount status: $?"; exit 1; fi
    log_debug "Binding /proc to $RAMDISK_MNT/proc"
    if ! mount --make-rslave --rbind /proc "$RAMDISK_MNT/proc"; then log_error "Failed to bind /proc. mount status: $?"; exit 1; fi
    log_debug "Binding /sys to $RAMDISK_MNT/sys"
    if ! mount --make-rslave --rbind /sys "$RAMDISK_MNT/sys"; then log_error "Failed to bind /sys. mount status: $?"; exit 1; fi
    log_debug "System directories (/dev, /proc, /sys) bound."

    # Also bind the original log file so the chrooted process can write to it.
    log_debug "Ensuring host log file $LOG_FILE exists..."
    if ! touch "$LOG_FILE"; then # Ensure it exists before binding.
        log_error "Failed to touch $LOG_FILE. touch status: $?"
        # Not exiting here, as logging might still work to stdout/stderr, but chroot log will fail.
    fi
    local ramdisk_log_target_dir
    ramdisk_log_target_dir=$(dirname "$RAMDISK_MNT$LOG_FILE")
    log_debug "Creating log file's directory in RAM disk: $ramdisk_log_target_dir"
    if ! mkdir -p "$ramdisk_log_target_dir"; then
        log_error "Failed to create $ramdisk_log_target_dir for log file binding. mkdir status: $?"
        # Not exiting, attempt to bind directly to $RAMDISK_MNT$LOG_FILE might still work if path is simple.
    fi
    log_debug "Binding host log file $LOG_FILE to $RAMDISK_MNT$LOG_FILE"
    if ! mount --bind "$LOG_FILE" "$RAMDISK_MNT$LOG_FILE"; then
        log_error "Failed to bind $LOG_FILE to $RAMDISK_MNT$LOG_FILE. mount status: $?"
        show_warning "Failed to bind main log file into chroot. Chroot logs might be missing from main log."
        # Not exiting, installer might still function.
    fi
    log_debug "Host log file bound into chroot environment."
    
    # 6. Execute the pivot.
    show_header "PIVOTING TO RAM DISK"
    log_info "System is now running from RAM. The original boot media is now free."

    # Build the command to be executed inside the chroot.
    # This safely passes the config file argument if it exists.
    log_debug "Building chroot command..."
    local chroot_cmd_array=("/root/installer/installer.sh" "--run-from-ram")
    if [[ -n "${CONFIG_FILE:-}" ]]; then
        local ramdisk_config_file
        ramdisk_config_file="/root/installer/$(basename "$CONFIG_FILE")"
        chroot_cmd_array+=("--config" "$ramdisk_config_file")
        log_debug "Adding config file to chroot command: $ramdisk_config_file (original: $CONFIG_FILE)"
    fi
    # Convert array to string for logging, quoting arguments for clarity
    local chroot_cmd_string
    printf -v chroot_cmd_string '%q ' "${chroot_cmd_array[@]}"
    log_info "Command to execute in chroot: $chroot_cmd_string"

    log_debug "Redirecting chroot output markers to $LOG_FILE"
    echo "--- Chroot to RAM Disk Output Start ---" >> "$LOG_FILE"
    # Use `unshare -f` to fork before chrooting, which can be cleaner.
    # Execute the command. Note: stdout/stderr from chroot command itself are handled by installer.sh's logging.
    # The primary purpose of $LOG_FILE here for the chroot is if installer.sh itself fails to redirect.
    log_debug "Executing chroot command on $RAMDISK_MNT with /bin/bash -c \"${chroot_cmd_string% }\""
    if ! chroot "$RAMDISK_MNT" /bin/bash -c "${chroot_cmd_string% }" &>> "$LOG_FILE"; then
        # This captures bash -c failure or if the command string is malformed
        # Actual installer.sh errors are caught by its own logic and exit_status
        log_error "Chroot command execution failed directly (e.g., /bin/bash -c could not run the command string). chroot status: $?"
    fi
    local exit_status=$? # This captures the exit status of the chroot_cmd_array execution
    log_debug "Chroot command finished. Exit status: $exit_status"
    echo "--- Chroot to RAM Disk Output End ---" >> "$LOG_FILE"
    
    log_info "Installer has finished in RAM disk. Exit status: $exit_status"

    # 7. Unmount and clean up. The trap will handle this, but we can do it explicitly.
    log_info "Cleaning up RAM disk environment (explicitly, before trap)..."
    # shellcheck disable=SC2094
    log_debug "Unmounting bind mounts and RAM disk filesystem. Output to $LOG_FILE"
    local umount_block_status=0
    {
        log_debug "Unmounting log bind: $RAMDISK_MNT$(dirname "$LOG_FILE")"
        umount -l "$RAMDISK_MNT$(dirname "$LOG_FILE")" || { log_warning "Failed to unmount log bind. status: $?"; umount_block_status=1; }
        log_debug "Unmounting /dev, /proc, /sys binds from $RAMDISK_MNT"
        umount -R -l "$RAMDISK_MNT/dev" "$RAMDISK_MNT/proc" "$RAMDISK_MNT/sys" || { log_warning "Failed to unmount /dev, /proc, /sys. status: $?"; umount_block_status=1; }
        log_debug "Unmounting main RAM disk: $RAMDISK_MNT"
        umount -lf "$RAMDISK_MNT" || { log_error "Failed to unmount main RAM disk $RAMDISK_MNT. status: $?"; umount_block_status=1; }
    } &>> "$LOG_FILE"
    if [[ $umount_block_status -eq 0 ]]; then
        log_debug "All RAM disk mounts unmounted successfully."
    else
        log_warning "One or more unmount operations failed. Check log above."
    fi
    
    log_debug "Clearing EXIT trap."
    trap - EXIT # Clear the trap since we cleaned up manually.
    log_debug "RAM disk cleanup finished."
    
    log_debug "Exiting prepare_and_pivot_to_ram with status: $exit_status"
    exit "$exit_status"
}
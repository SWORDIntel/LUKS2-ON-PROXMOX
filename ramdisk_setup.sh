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
        rsync -axq --exclude={"'/proc/*'","'/sys/*'","'/dev/*'","'/run/*'","'/mnt/*'","'/media/*'","'/tmp/*'","'$RAMDISK_MNT/*'","'/home/*/.cache/*'","'/root/.cache/*'","'/var/cache/*'","'/var/tmp/*'"} / "$RAMDISK_MNT/"
        return $?
    fi

    # Estimate total size for `pv`
    local total_size; total_size=$(df --output=used -B 1 / | tail -n 1)

    show_progress "Copying system to RAM disk..."
    # Use tar to stream files, pv to show progress, and tar to extract in the destination.
    # This is a very common, fast, and reliable pattern.
    (cd / && tar --exclude={"./proc","./sys","./dev","./run","./mnt","./media","./tmp","./mnt/ramdisk","./home/*/.cache","./root/.cache","./var/cache","./var/tmp/*"} -cf - .) | \
    pv -s "$total_size" -N "Copying" | \
    (cd "$RAMDISK_MNT" && tar -xf -)
    
    # The exit code of a pipeline is the exit code of the last command. `tar -x` should be 0.
    # We check pipe status to ensure all parts of the pipe succeeded.
    if [[ "${PIPESTATUS[0]}" -ne 0 || "${PIPESTATUS[2]}" -ne 0 ]]; then
        log_error "Error during system copy to RAM disk (tar exit codes: ${PIPESTATUS[0]}, pv: ${PIPESTATUS[1]}, tar: ${PIPESTATUS[2]}). Check logs."
        return 1
    else
        log_info "System copy to RAM disk successful."
        return 0
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
    if ! ramdisk_size_gb=$(_get_recommended_ramdisk_size); then
        log_error "Failed to determine recommended RAM disk size. Cannot proceed."
        exit 1 # Error message also shown by helper, but good to be explicit here.
    fi

    show_progress "Creating a ${ramdisk_size_gb}GB filesystem in RAM at $RAMDISK_MNT..."
    mkdir -p "$RAMDISK_MNT"
    if ! mount -t tmpfs -o size="${ramdisk_size_gb}G,rw" tmpfs "$RAMDISK_MNT"; then
        show_error "Failed to mount RAM disk. Check kernel logs and available memory."
        exit 1
    fi
    trap 'umount -lf "$RAMDISK_MNT" &>/dev/null; rm -rf "$RAMDISK_MNT" &>/dev/null' EXIT # Add cleanup trap for mount and directory

    # 2. Copy the system.
    if ! _copy_system_with_progress; then
        show_error "Failed to copy system files to RAM disk."
        exit 1
    fi
    show_success "System files copied to RAM disk."

    # 3. Copy the installer itself.
    show_progress "Copying installer files to RAM disk..."
    mkdir -p "$RAMDISK_MNT/root/installer"
    # Use rsync to be safe and efficient.
    rsync -a "$SCRIPT_DIR/" "$RAMDISK_MNT/root/installer/" &>> "$LOG_FILE"
    chmod +x "$RAMDISK_MNT/root/installer/installer.sh"

    # 4. Verify integrity.
    if ! _verify_ramdisk_integrity; then
        exit 1
    fi

    # 5. Prepare the chroot environment.
    show_progress "Binding system directories to RAM environment..."
    mount --make-rslave --rbind /dev "$RAMDISK_MNT/dev"
    mount --make-rslave --rbind /proc "$RAMDISK_MNT/proc"
    mount --make-rslave --rbind /sys "$RAMDISK_MNT/sys"
    # Also bind the original log file so the chrooted process can write to it.
    touch "$LOG_FILE" # Ensure it exists before binding.
    mkdir -p "$(dirname "$RAMDISK_MNT$LOG_FILE")"
    mount --bind "$LOG_FILE" "$RAMDISK_MNT$LOG_FILE"
    
    # 6. Execute the pivot.
    show_header "PIVOTING TO RAM DISK"
    log_info "System is now running from RAM. The original boot media is now free."

    # Build the command to be executed inside the chroot.
    # This safely passes the config file argument if it exists.
    local chroot_cmd="/root/installer/installer.sh --run-from-ram"
    if [[ -n "${CONFIG_FILE:-}" ]]; then
        chroot_cmd+=" --config /root/installer/$(basename "$CONFIG_FILE")"
    fi
    log_info "Executing in chroot: $chroot_cmd"

    echo "--- Chroot to RAM Disk Output Start ---" >> "$LOG_FILE"
    # Use `unshare -f` to fork before chrooting, which can be cleaner.
    # Execute the command, redirecting its output to the original log file.
    chroot "$RAMDISK_MNT" /bin/bash -c "$chroot_cmd"
    local exit_status=$?
    echo "--- Chroot to RAM Disk Output End ---" >> "$LOG_FILE"
    
    log_info "Installer has finished in RAM disk. Exit status: $exit_status"

    # 7. Unmount and clean up. The trap will handle this, but we can do it explicitly.
    log_info "Cleaning up RAM disk environment..."
    {
        umount -l "$RAMDISK_MNT"
        umount -R -l "$RAMDISK_MNT/dev" "$RAMDISK_MNT/proc" "$RAMDISK_MNT/sys"
        umount -lf "$RAMDISK_MNT"
    } &>> "$LOG_FILE"
    
    trap - EXIT # Clear the trap since we cleaned up manually.
    
    exit "$exit_status"
}
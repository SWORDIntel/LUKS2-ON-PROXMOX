#!/usr/bin/env bash

prepare_ram_environment() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_header "RAM DISK PREPARATION"
    
    show_progress "Creating a 5GB filesystem in RAM..."
    log_debug "Creating RAM disk mount point: $RAMDISK_MNT"
    mkdir -p "$RAMDISK_MNT"
    log_debug "Executing: mount -t tmpfs -o size=5G,rw tmpfs $RAMDISK_MNT"
    if ! mount -t tmpfs -o size=5G,rw tmpfs "$RAMDISK_MNT" &>> "$LOG_FILE"; then
        log_debug "Failed to mount RAM disk at $RAMDISK_MNT. Check available memory and permissions."
        show_error "Failed to mount RAM disk at $RAMDISK_MNT. Check available memory and permissions."
        exit 1
    fi
    log_debug "RAM disk mounted successfully."

    show_progress "Copying environment to RAM disk (this will take a moment)..."
    log_debug "Creating base directory structure in RAM disk."
    mkdir -p "$RAMDISK_MNT"/{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var} &>> "$LOG_FILE"

    log_debug "Executing rsync to copy / to $RAMDISK_MNT (excluding system dirs and RAM disk itself)..."
    echo "--- Rsync Output Start ---" >> "$LOG_FILE"
    rsync -ax --info=progress2 / "$RAMDISK_MNT/" --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/mnt --exclude=/media --exclude="$RAMDISK_MNT" &>> "$LOG_FILE"
    local rsync_status=$?
    echo "--- Rsync Output End ---" >> "$LOG_FILE"
    log_debug "Rsync finished with status: $rsync_status"
    if [[ $rsync_status -ne 0 && $rsync_status -ne 24 ]]; then # Rsync status 24: "Partial transfer due to vanished source files" - can happen, often non-fatal for this use case.
      log_debug "Rsync encountered a critical error (status $rsync_status)."
      show_error "Rsync failed to copy system files to RAM disk. Status: $rsync_status"
      # Attempt cleanup before exiting
      umount -lf "$RAMDISK_MNT/sys" &>> "$LOG_FILE" || true
      umount -lf "$RAMDISK_MNT/proc" &>> "$LOG_FILE" || true
      umount -lf "$RAMDISK_MNT/dev" &>> "$LOG_FILE" || true
      umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE" || true
      exit 1
    elif [[ $rsync_status -eq 24 ]]; then
      log_debug "Rsync reported status 24 (partial transfer due to vanished source files). This is often non-critical for RAM disk setup. Continuing."
      show_warning "Rsync reported partial transfer (status 24). This may be okay. Continuing..."
    else
      log_debug "Rsync completed successfully."
    fi


    # SCRIPT_DIR is defined in installer.sh and inherited.
    log_debug "Copying installer script directory ($SCRIPT_DIR) to $RAMDISK_MNT/root/installer/"
    mkdir -p "$RAMDISK_MNT/root/installer" &>> "$LOG_FILE"
    cp -r "$SCRIPT_DIR"/* "$RAMDISK_MNT/root/installer/" &>> "$LOG_FILE"
    
    local main_script_in_ram="$RAMDISK_MNT/root/installer/installer.sh"
    log_debug "Making main installer script executable in RAM disk: $main_script_in_ram"
    chmod +x "$main_script_in_ram" &>> "$LOG_FILE"

    if [[ -n "${CONFIG_FILE_PATH:-}" && -f "${CONFIG_FILE_PATH}" ]]; then
        log_debug "Copying config file $CONFIG_FILE_PATH to $RAMDISK_MNT/root/installer/"
        cp "$CONFIG_FILE_PATH" "$RAMDISK_MNT/root/installer/" &>> "$LOG_FILE"
    else
        log_debug "No config file path provided or file does not exist. Skipping copy to RAM disk."
    fi

    local debs_source_on_usb="$SCRIPT_DIR/debs"
    if [ -d "$debs_source_on_usb" ]; then
        log_debug "Copying 'debs' directory from $debs_source_on_usb to RAM disk..."
        show_progress "Copying 'debs' directory to RAM disk..."
        mkdir -p "$RAMDISK_MNT/root/installer/debs" &>> "$LOG_FILE"
        cp -r "$debs_source_on_usb"/* "$RAMDISK_MNT/root/installer/debs/" &>> "$LOG_FILE" || {
            log_debug "Failed to copy 'debs' directory. Local package installation might fail."
            show_warning "Failed to copy 'debs' directory. Local package installation might fail."
        }
    else
        log_debug "No 'debs' directory found at $debs_source_on_usb, skipping copy."
        show_progress "No 'debs' directory found at $debs_source_on_usb, skipping copy."
    fi

    if [ -f "$RAMDISK_MNT/root/installer/download_debs.sh" ]; then
        log_debug "Making download_debs.sh executable in RAM disk."
        chmod +x "$RAMDISK_MNT/root/installer/download_debs.sh" &>> "$LOG_FILE"
    fi

    log_debug "Mounting /dev, /proc, /sys into RAM disk."
    if ! mount --rbind /dev "$RAMDISK_MNT/dev" &>> "$LOG_FILE"; then
        log_debug "Failed to mount /dev into RAM disk."
        show_error "Failed to mount /dev into RAM disk at $RAMDISK_MNT/dev"
        umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE" || true
        exit 1
    fi
    if ! mount --rbind /proc "$RAMDISK_MNT/proc" &>> "$LOG_FILE"; then
        log_debug "Failed to mount /proc into RAM disk."
        show_error "Failed to mount /proc into RAM disk at $RAMDISK_MNT/proc"
        umount -lf "$RAMDISK_MNT/dev" &>> "$LOG_FILE" || true
        umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE" || true
        exit 1
    fi
    if ! mount --rbind /sys "$RAMDISK_MNT/sys" &>> "$LOG_FILE"; then
        log_debug "Failed to mount /sys into RAM disk."
        show_error "Failed to mount /sys into RAM disk at $RAMDISK_MNT/sys"
        umount -lf "$RAMDISK_MNT/proc" &>> "$LOG_FILE" || true
        umount -lf "$RAMDISK_MNT/dev" &>> "$LOG_FILE" || true
        umount -lf "$RAMDISK_MNT" &>> "$LOG_FILE" || true
        exit 1
    fi
    log_debug "System directories (/dev, /proc, /sys) mounted into RAM disk."

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

    # Cleanup is called by the trap in init_environment, so no need to call it explicitly here
    # unless we want to log something specific before the trap takes over.
    # The trap in init_environment will call the version of cleanup from core_logic.sh that's in RAM.
    log_debug "Exiting function: ${FUNCNAME[0]}. Cleanup will be handled by trap."
    exit $exit_status
}

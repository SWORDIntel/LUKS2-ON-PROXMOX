#!/usr/bin/env bash

prepare_ram_environment() {
    show_header "RAM DISK PREPARATION"
    show_progress "Creating a 2.5GB filesystem in RAM..."

    mkdir -p "$RAMDISK_MNT"
    if ! mount -t tmpfs -o size=6000M,rw tmpfs "$RAMDISK_MNT"; then
        show_error "Failed to mount RAM disk at $RAMDISK_MNT. Check available memory and permissions."
        exit 1
    fi

    show_progress "Copying environment to RAM disk (this will take a moment)..."
    # Create base directory structure first
    mkdir -p "$RAMDISK_MNT"/{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}

    # Use rsync for more reliable copying with progress
    rsync -ax --info=progress2 / "$RAMDISK_MNT/" --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/mnt --exclude=/media --exclude="$RAMDISK_MNT"

    if [[ ! -f "$RAMDISK_MNT/bin/bash" ]]; then
        show_error "FATAL: /bin/bash not found in RAM disk at $RAMDISK_MNT/bin/bash after rsync."
        show_error "RAM disk copy might have failed. Check rsync output/errors if visible."
        # ls -l "$RAMDISK_MNT/bin/"
        exit 1 # Critical error
    fi
    show_success "/bin/bash verified in RAM disk."

    # Copy the installer script
    cp "$0" "$RAMDISK_MNT/root/installer.sh"
    chmod +x "$RAMDISK_MNT/root/installer.sh"

    if [[ ! -x "$RAMDISK_MNT/root/installer.sh" ]]; then
        show_error "FATAL: Installer script /root/installer.sh not found or not executable in RAM disk."
        show_error "RAM disk copy of installer script might have failed."
        # ls -l "$RAMDISK_MNT/root/"
        exit 1 # Critical error
    fi
    show_success "Installer script verified in RAM disk."

    # Copy configuration if specified
    if [[ -n "${CONFIG_FILE_PATH:-}" ]]; then
        cp "$CONFIG_FILE_PATH" "$RAMDISK_MNT/root/"
    fi

    # Mount necessary filesystems
    if ! mount --rbind /dev "$RAMDISK_MNT/dev"; then
        show_error "Failed to mount /dev into RAM disk at $RAMDISK_MNT/dev"
        # Attempt to unmount ramdisk before exiting
        umount -lf "$RAMDISK_MNT" &>/dev/null
        exit 1
    fi
    if ! mount --rbind /proc "$RAMDISK_MNT/proc"; then
        show_error "Failed to mount /proc into RAM disk at $RAMDISK_MNT/proc"
        umount -lf "$RAMDISK_MNT/dev" &>/dev/null
        umount -lf "$RAMDISK_MNT" &>/dev/null
        exit 1
    fi
    if ! mount --rbind /sys "$RAMDISK_MNT/sys"; then
        show_error "Failed to mount /sys into RAM disk at $RAMDISK_MNT/sys"
        umount -lf "$RAMDISK_MNT/proc" &>/dev/null
        umount -lf "$RAMDISK_MNT/dev" &>/dev/null
        umount -lf "$RAMDISK_MNT" &>/dev/null
        exit 1
    fi

    show_header "PIVOTING TO RAM DISK"
    show_warning "The system is now running from RAM. The original boot media can be safely removed."

    # Execute in chroot with proper argument passing
    local chroot_args="/bin/bash /root/installer.sh --run-from-ram"
    if [[ -n "${CONFIG_FILE_PATH:-}" ]]; then
        chroot_args+=" --config /root/$(basename "$CONFIG_FILE_PATH")"
    fi

    chroot "$RAMDISK_MNT" "$chroot_args"
    local exit_status=$?

    cleanup
    exit $exit_status
}

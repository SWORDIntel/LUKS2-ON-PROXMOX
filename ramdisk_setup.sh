#!/usr/bin/env bash

prepare_ram_environment() {
    show_header "RAM DISK PREPARATION"
    
    # MODIFIED: Changed size from 6000M to 5G as per user request.
    # This allocates a 5 Gigabyte temporary filesystem in RAM.
    show_progress "Creating a 5GB filesystem in RAM..."

    mkdir -p "$RAMDISK_MNT"
    if ! mount -t tmpfs -o size=5G,rw tmpfs "$RAMDISK_MNT"; then
        show_error "Failed to mount RAM disk at $RAMDISK_MNT. Check available memory and permissions."
        exit 1
    fi

    show_progress "Copying environment to RAM disk (this will take a moment)..."
    # Create base directory structure first
    mkdir -p "$RAMDISK_MNT"/{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}

    # Use rsync for more reliable copying with progress
    rsync -ax --info=progress2 / "$RAMDISK_MNT/" --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/mnt --exclude=/media --exclude="$RAMDISK_MNT"

    # AUDIT-FIX: Copy the entire script directory to maintain context for sourced files.
    local script_dir; script_dir=$(dirname "$(readlink -f "$0")")
    mkdir -p "$RAMDISK_MNT/root/installer"
    cp -r "$script_dir"/* "$RAMDISK_MNT/root/installer/"
    
    # Ensure the main script is executable in its new location
    local main_script_in_ram="$RAMDISK_MNT/root/installer/installer.sh"
    chmod +x "$main_script_in_ram"

    # Copy configuration if specified, placing it inside the new installer directory
    if [[ -n "${CONFIG_FILE_PATH:-}" && -f "${CONFIG_FILE_PATH}" ]]; then
        cp "$CONFIG_FILE_PATH" "$RAMDISK_MNT/root/installer/"
    fi

    # Mount necessary filesystems
    if ! mount --rbind /dev "$RAMDISK_MNT/dev"; then
        show_error "Failed to mount /dev into RAM disk at $RAMDISK_MNT/dev"
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
    show_warning "The system is now running from RAM. The original boot media can be safely removed if it is also the target."

    # AUDIT-FIX (SC2086): Use 'bash -c' to safely execute the command string inside the chroot.
    # This prevents word-splitting issues with arguments. We also change directory first.
    local chroot_cmd="cd /root/installer && ./installer.sh --run-from-ram"
    if [[ -n "${CONFIG_FILE_PATH:-}" && -f "${CONFIG_FILE_PATH}" ]]; then
        chroot_cmd+=" --config $(basename "$CONFIG_FILE_PATH")"
    fi

    chroot "$RAMDISK_MNT" /bin/bash -c "$chroot_cmd"
    local exit_status=$?

    cleanup
    exit $exit_status
}

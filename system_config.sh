#!/usr/bin/env bash
# Contains functions for base system installation and chroot configuration.

install_base_system() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "DEBIAN" "Installing Base System"

    show_progress "Mounting boot partitions..."
    log_debug "Creating /mnt/boot and /mnt/boot/efi directories."
    mkdir -p /mnt/boot
    mkdir -p /mnt/boot/efi

    log_debug "Mounting boot partition ${CONFIG_VARS[BOOT_PART]} on /mnt/boot."
    if ! mount "${CONFIG_VARS[BOOT_PART]}" /mnt/boot &>> "$LOG_FILE"; then
        log_debug "Failed to mount boot partition ${CONFIG_VARS[BOOT_PART]} on /mnt/boot."
        show_error "Failed to mount boot partition ${CONFIG_VARS[BOOT_PART]} on /mnt/boot"
        exit 1
    fi
    log_debug "Boot partition mounted successfully."

    log_debug "Mounting EFI partition ${CONFIG_VARS[EFI_PART]} on /mnt/boot/efi."
    if ! mount "${CONFIG_VARS[EFI_PART]}" /mnt/boot/efi &>> "$LOG_FILE"; then
        log_debug "Failed to mount EFI partition ${CONFIG_VARS[EFI_PART]} on /mnt/boot/efi."
        show_error "Failed to mount EFI partition ${CONFIG_VARS[EFI_PART]} on /mnt/boot/efi"
        exit 1
    fi
    log_debug "EFI partition mounted successfully."

    show_progress "Installing Debian base system (this will take several minutes)..."
    local debian_release="bookworm"
    local debian_mirror="http://deb.debian.org/debian"
    log_debug "Debian release: $debian_release, Mirror: $debian_mirror"

    # Log debootstrap output for debugging
    # The main LOG_FILE is now in the script directory, not TEMP_DIR.
    # We can create a separate debootstrap log in TEMP_DIR if desired, or just append to main.
    # For simplicity and centralization, appending to main LOG_FILE.
    log_debug "Starting debootstrap..."
    echo "--- Debootstrap Output Start ---" >> "$LOG_FILE"
    if ! debootstrap --arch=amd64 --include=locales,vim,openssh-server,wget,curl \
        "$debian_release" /mnt "$debian_mirror" >> "$LOG_FILE" 2>&1; then
        echo "--- Debootstrap Output End ---" >> "$LOG_FILE"
        log_debug "Debootstrap failed. Base system installation could not complete."
        show_error "Debootstrap failed. Base system installation could not complete."
        show_error "Check $LOG_FILE for debootstrap output details."
        exit 1
    fi
    echo "--- Debootstrap Output End ---" >> "$LOG_FILE"
    log_debug "Debootstrap successful."
    show_success "Base system installed (debootstrap successful)."

    log_debug "Copying main log file to /mnt/var/log/proxmox-install.log"
    cp "$LOG_FILE" /mnt/var/log/proxmox-install.log &>> "$LOG_FILE"
    # No longer a separate debootstrap_log to copy, it's part of the main LOG_FILE.
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

configure_new_system() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "CHROOT" "Configuring System"

    show_progress "Preparing chroot environment..."
    log_debug "Copying /etc/resolv.conf to /mnt/etc/resolv.conf"
    cp /etc/resolv.conf /mnt/etc/ &>> "$LOG_FILE"

    log_debug "Mounting /proc, /sys, /dev, /dev/pts for chroot."
    if ! mount -t proc /proc /mnt/proc &>> "$LOG_FILE"; then
        log_debug "Failed to mount /proc into chroot environment at /mnt/proc."
        show_error "Failed to mount /proc into chroot environment at /mnt/proc"
        exit 1
    fi
    if ! mount -t sysfs /sys /mnt/sys &>> "$LOG_FILE"; then
        log_debug "Failed to mount /sys into chroot environment at /mnt/sys."
        show_error "Failed to mount /sys into chroot environment at /mnt/sys"
        exit 1
    fi
    if ! mount -t devtmpfs /dev /mnt/dev &>> "$LOG_FILE"; then
        log_debug "Failed to mount /dev into chroot environment at /mnt/dev."
        show_error "Failed to mount /dev into chroot environment at /mnt/dev"
        exit 1
    fi
    if ! mount -t devpts /dev/pts /mnt/dev/pts &>> "$LOG_FILE"; then
        log_debug "Failed to mount /dev/pts into chroot environment at /mnt/dev/pts."
        show_error "Failed to mount /dev/pts into chroot environment at /mnt/dev/pts"
        exit 1
    fi
    log_debug "Chroot mounts prepared successfully."

    log_debug "Prompting for root password for the new system."
    local root_pass
    root_pass=$(dialog --title "Root Password" --passwordbox "Enter root password for new system:" 10 60 3>&1 1>&2 2>&3) || { log_debug "Root password entry cancelled."; exit 1; }
    local root_pass_confirm
    root_pass_confirm=$(dialog --title "Root Password" --passwordbox "Confirm root password:" 10 60 3>&1 1>&2 2>&3) || { log_debug "Root password confirmation cancelled."; exit 1; }

    if [[ "$root_pass" != "$root_pass_confirm" ]] || [[ -z "$root_pass" ]]; then
        log_debug "Root passwords do not match or are empty."
        show_error "Passwords do not match or are empty."
        exit 1
    fi
    log_debug "Root password confirmed (not logging password itself)."

    log_debug "Creating chroot configuration script at /mnt/tmp/configure.sh"
    cat > /mnt/tmp/configure.sh <<- 'CHROOT_SCRIPT'
        #!/bin/bash
        set -e

        echo "${HOSTNAME}" > /etc/hostname
        cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}

# IPv6
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen
        echo "LANG=en_US.UTF-8" > /etc/locale.conf

        ln -sf /usr/share/zoneinfo/UTC /etc/localtime

        cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF

        wget -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
            http://download.proxmox.com/debian/proxmox-release-bookworm.gpg

        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > \
            /etc/apt/sources.list.d/pve-no-subscription.list

        apt-get update

        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            linux-image-amd64 linux-headers-amd64 \
            zfs-initramfs cryptsetup-initramfs \
            grub-efi-amd64 efibootmgr \
            bridge-utils ifupdown2

        echo "[PROXMOX_AIO_INSTALLER_CHROOT] Checking and installing YubiKey packages..." >> /dev/kmsg
        if [[ "${USE_YUBIKEY}" == "yes" ]]; then
            echo "[PROXMOX_AIO_INSTALLER_CHROOT] USE_YUBIKEY=yes. Installing yubikey-luks and dependencies." >> /dev/kmsg
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends yubikey-luks yubikey-manager libpam-yubico ykcs11 libykpers-1-1 libyubikey0 pcscd
            echo "[PROXMOX_AIO_INSTALLER_CHROOT] YubiKey package installation attempt finished. Enabling pcscd service." >> /dev/kmsg
            systemctl enable pcscd
        else
            echo "[PROXMOX_AIO_INSTALLER_CHROOT] USE_YUBIKEY=no. Skipping YubiKey package installation." >> /dev/kmsg
        fi

        if [[ "${NET_USE_DHCP}" == "yes" ]]; then
            cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${NET_IFACE}
iface ${NET_IFACE} inet dhcp

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports ${NET_IFACE}
    bridge-stp off
    bridge-fd 0
EOF
        else
            if [[ -L "/etc/resolv.conf" ]]; then
                echo "Warning: /etc/resolv.conf is a symlink. Attempting to write DNS configuration." >&2
                if ! echo "nameserver ${NET_DNS// /$'\n'nameserver }" > /etc/resolv.conf; then
                    echo "Error: Failed to write to /etc/resolv.conf (symlink target likely not writable)." >&2
                fi
            elif [[ ! -w "/etc/resolv.conf" ]]; then
                echo "Error: /etc/resolv.conf is not writable. Cannot configure DNS automatically." >&2
            else
                echo "nameserver ${NET_DNS// /$'\n'nameserver }" > /etc/resolv.conf
            fi

            cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${NET_IFACE}
iface ${NET_IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${NET_IP_CIDR}
    gateway ${NET_GATEWAY}
    bridge-ports ${NET_IFACE}
    bridge-stp off
    bridge-fd 0
EOF
        fi

        local crypttab_options="luks,discard"
        if [[ "${USE_YUBIKEY}" == "yes" ]]; then
            echo "[PROXMOX_AIO_INSTALLER_CHROOT] YubiKey is enabled, adding keyscript to crypttab options." >> /dev/kmsg
            crypttab_options+=",keyscript=/lib/cryptsetup/scripts/decrypt_yubikey"
        fi
        echo "[PROXMOX_AIO_INSTALLER_CHROOT] crypttab_options set to: $crypttab_options" >> /dev/kmsg

        if [[ "${USE_DETACHED_HEADERS}" == "yes" ]]; then
            echo "# Detached header configuration" > /etc/crypttab
            local header_files_arr=()
            read -r -a header_files_arr <<< "${HEADER_FILENAMES_ON_PART}"
            local luks_parts_arr=()
            read -r -a luks_parts_arr <<< "${LUKS_PARTITIONS}"
            for i in "${!luks_parts_arr[@]}"; do
                local uuid
                uuid=$(blkid -s UUID -o value "${luks_parts_arr[$i]}")
                if [[ -z "${HEADER_PART_UUID}" ]]; then
                    echo "Critical error: HEADER_PART_UUID is not set in chroot for detached headers." >&2
                    exit 1
                fi
                echo "${LUKS_MAPPER_NAME}_$i UUID=$uuid none $crypttab_options,header=UUID=${HEADER_PART_UUID}:${header_files_arr[$i]}" >> /etc/crypttab
            done
        else
            echo "# Standard LUKS configuration" > /etc/crypttab
            local luks_parts_arr=()
            read -r -a luks_parts_arr <<< "${LUKS_PARTITIONS}"
            for i in "${!luks_parts_arr[@]}"; do
                local uuid
                uuid=$(blkid -s UUID -o value "${luks_parts_arr[$i]}")
                echo "${LUKS_MAPPER_NAME}_$i UUID=$uuid none $crypttab_options" >> /etc/crypttab
            done
        fi

        echo "# /etc/fstab: static file system information." > /etc/fstab
        local boot_uuid
        boot_uuid=$(blkid -s UUID -o value "${BOOT_PART}")
        echo "UUID=$boot_uuid /boot ext4 defaults 0 2" >> /etc/fstab
        local efi_uuid
        efi_uuid=$(blkid -s UUID -o value "${EFI_PART}")
        echo "UUID=$efi_uuid /boot/efi vfat umask=0077 0 1" >> /etc/fstab

        echo "[PROXMOX_AIO_INSTALLER_CHROOT] Updating initramfs after potential YubiKey configuration..." >> /dev/kmsg
        update-initramfs -c -k all

        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=proxmox
        update-grub

        echo "root:${ROOT_PASSWORD}" | chpasswd

        DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi

        rm -f /etc/apt/sources.list.d/pve-enterprise.list

        systemctl enable ssh

        apt-get clean

CHROOT_SCRIPT

    chmod +x /mnt/tmp/configure.sh
    log_debug "Chroot configuration script created and made executable."

    log_debug "Exporting variables for chroot script:"
    log_debug "  HOSTNAME=${CONFIG_VARS[HOSTNAME]}"
    log_debug "  NET_USE_DHCP=${CONFIG_VARS[NET_USE_DHCP]:-no}"
    export HOSTNAME="${CONFIG_VARS[HOSTNAME]}"
    export NET_USE_DHCP="${CONFIG_VARS[NET_USE_DHCP]:-no}"
    export NET_IFACE="${CONFIG_VARS[NET_IFACE]:-ens18}"
    log_debug "  NET_IFACE=${CONFIG_VARS[NET_IFACE]:-ens18}"
    export NET_IP_CIDR="${CONFIG_VARS[NET_IP_CIDR]:-}"
    log_debug "  NET_IP_CIDR=${CONFIG_VARS[NET_IP_CIDR]:-}"
    export NET_GATEWAY="${CONFIG_VARS[NET_GATEWAY]:-}"
    log_debug "  NET_GATEWAY=${CONFIG_VARS[NET_GATEWAY]:-}"
    export NET_DNS="${CONFIG_VARS[NET_DNS]:-8.8.8.8 8.8.4.4}"
    log_debug "  NET_DNS=${CONFIG_VARS[NET_DNS]:-8.8.8.8 8.8.4.4}"
    export USE_DETACHED_HEADERS="${CONFIG_VARS[USE_DETACHED_HEADERS]}"
    log_debug "  USE_DETACHED_HEADERS=${CONFIG_VARS[USE_DETACHED_HEADERS]}"
    export HEADER_PART_UUID="${CONFIG_VARS[HEADER_PART_UUID]:-}"
    log_debug "  HEADER_PART_UUID=${CONFIG_VARS[HEADER_PART_UUID]:-}"
    export HEADER_FILENAMES_ON_PART="${CONFIG_VARS[HEADER_FILENAMES_ON_PART]:-}"
    log_debug "  HEADER_FILENAMES_ON_PART=${CONFIG_VARS[HEADER_FILENAMES_ON_PART]:-}"
    export LUKS_PARTITIONS="${CONFIG_VARS[LUKS_PARTITIONS]}"
    log_debug "  LUKS_PARTITIONS=${CONFIG_VARS[LUKS_PARTITIONS]}"
    export LUKS_MAPPER_NAME="${CONFIG_VARS[LUKS_MAPPER_NAME]}"
    log_debug "  LUKS_MAPPER_NAME=${CONFIG_VARS[LUKS_MAPPER_NAME]}"
    export BOOT_PART="${CONFIG_VARS[BOOT_PART]}"
    log_debug "  BOOT_PART=${CONFIG_VARS[BOOT_PART]}"
    export EFI_PART="${CONFIG_VARS[EFI_PART]}"
    log_debug "  EFI_PART=${CONFIG_VARS[EFI_PART]}"
    export ROOT_PASSWORD="$root_pass" # Not logging password
    log_debug "  ROOT_PASSWORD has been set (not logged)."
    export USE_YUBIKEY="${CONFIG_VARS[USE_YUBIKEY]:-no}" # Export USE_YUBIKEY
    log_debug "  USE_YUBIKEY exported: ${USE_YUBIKEY}"

    show_progress "Configuring system in chroot (this will take several minutes)..."
    log_debug "Executing chroot /mnt /tmp/configure.sh"
    echo "--- Chroot Script Output Start ---" >> "$LOG_FILE"
    if ! chroot /mnt /tmp/configure.sh >> "$LOG_FILE" 2>&1; then
        echo "--- Chroot Script Output End ---" >> "$LOG_FILE"
        log_debug "Chroot script /tmp/configure.sh failed."
        show_error "System configuration script (/tmp/configure.sh) failed within the chroot environment."
        show_error "Logs within the chroot (if any) might be in /mnt/var/log or /mnt/tmp. Main log: $LOG_FILE"
        exit 1
    fi
    echo "--- Chroot Script Output End ---" >> "$LOG_FILE"
    log_debug "Chroot script executed successfully."

    # SCRIPT_DIR should be available if core_logic.sh is sourced from installer.sh where SCRIPT_DIR is defined.
    # However, $(dirname "$0") here will refer to ./core_logic.sh which is not what we want.
    # Using SCRIPT_DIR, assuming it's correctly inherited.
    local debs_source_dir="$SCRIPT_DIR/debs"
    if [[ -d "$debs_source_dir" ]] && ls "$debs_source_dir"/*.deb &>/dev/null; then
        log_debug "Local .deb packages found in $debs_source_dir. Installing them in chroot."
        show_progress "Installing local .deb packages..."
        cp -r "$debs_source_dir" /mnt/tmp/ &>> "$LOG_FILE"
        log_debug "Executing in chroot: dpkg -i /tmp/debs/*.deb || apt-get -f install -y"
        echo "--- Chroot dpkg/apt-get Output Start ---" >> "$LOG_FILE"
        chroot /mnt bash -c "dpkg -i /tmp/debs/*.deb || apt-get -f install -y" >> "$LOG_FILE" 2>&1
        local dpkg_status=$?
        echo "--- Chroot dpkg/apt-get Output End ---" >> "$LOG_FILE"
        log_debug "Chroot dpkg/apt-get finished with status: $dpkg_status"
        rm -rf /mnt/tmp/debs
        log_debug "Removed /mnt/tmp/debs."
    else
        log_debug "No local .deb packages found in $debs_source_dir or directory doesn't exist."
    fi

    log_debug "Removing chroot configuration script /mnt/tmp/configure.sh"
    rm /mnt/tmp/configure.sh

    log_debug "Unmounting chroot filesystems: /mnt/dev/pts, /mnt/dev, /mnt/sys, /mnt/proc"
    umount -lf /mnt/dev/pts &>> "$LOG_FILE" || log_debug "Warning: Failed to unmount /mnt/dev/pts"
    umount -lf /mnt/dev &>> "$LOG_FILE" || log_debug "Warning: Failed to unmount /mnt/dev"
    umount -lf /mnt/sys &>> "$LOG_FILE" || log_debug "Warning: Failed to unmount /mnt/sys"
    umount -lf /mnt/proc &>> "$LOG_FILE" || log_debug "Warning: Failed to unmount /mnt/proc"
    log_debug "Chroot filesystems unmounted."

    show_success "System configuration complete"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

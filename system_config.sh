#!/usr/bin/env bash
# Contains functions for base system installation and chroot configuration.

install_base_system() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "DEBIAN" "Installing Base System"

    # Mounting is already solid.
    mkdir -p /mnt/boot/efi
    mount "${CONFIG_VARS[BOOT_PART]}" /mnt/boot &>> "$LOG_FILE" || { show_error "Failed to mount boot partition."; exit 1; }
    mount "${CONFIG_VARS[EFI_PART]}" /mnt/boot/efi &>> "$LOG_FILE" || { show_error "Failed to mount EFI partition."; exit 1; }
    show_success "Boot and EFI partitions mounted."

    show_progress "Installing Debian base system (this will take several minutes)..."
    local debian_release="bookworm"
    local debian_mirror="http://deb.debian.org/debian"

    # debootstrap logic is good, keeping it.
    log_debug "Starting debootstrap..."
    echo "--- Debootstrap Output Start ---" >> "$LOG_FILE"
    if ! debootstrap --arch=amd64 --include=locales,vim,openssh-server,wget,curl,ca-certificates \
        "$debian_release" /mnt "$debian_mirror" >> "$LOG_FILE" 2>&1; then
        echo "--- Debootstrap Output End --- (Error Occurred)" >> "$LOG_FILE"
        show_error "Debootstrap failed. Check $LOG_FILE for details."
        exit 1
    fi
    echo "--- Debootstrap Output End ---" >> "$LOG_FILE"
    show_success "Base system installed."

    log_debug "Copying installer log to target system."
    mkdir -p /mnt/var/log
    cp "$LOG_FILE" /mnt/var/log/proxmox-installer-aio.log
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

# ANNOTATION: Encapsulate chroot mount/unmount logic for robustness and reuse.
_chroot_mounts() {
    log_debug "Mounting chroot pseudo-filesystems..."
    mount --make-rslave --rbind /dev /mnt/dev
    mount --make-rslave --rbind /proc /mnt/proc
    mount --make-rslave --rbind /sys /mnt/sys
    # Copy resolv.conf after mounts to ensure it's not a symlink to a non-existent path.
    cp /etc/resolv.conf /mnt/etc/
}

_chroot_unmounts() {
    log_debug "Unmounting chroot pseudo-filesystems..."
    # Unmount in reverse order, using -l for lazy unmount as a fallback.
    {
        umount -R -l /mnt/dev
        umount -R -l /mnt/sys
        umount -R -l /mnt/proc
    } &>> "$LOG_FILE"
}


configure_new_system() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "CHROOT" "Configuring System"

    _chroot_mounts

    # Get root password.
    local root_pass
    if ! _prompt_user_password_confirm "Enter new root password for the system" root_pass; then
        log_debug "Root password entry failed or was cancelled by user."
        # _prompt_user_password_confirm shows its own error/info message on failure/cancellation.
        exit 1 
    fi
    # root_pass is now set and confirmed.

    # ANNOTATION: Create a self-contained chroot script. This is more robust than exporting variables.
    # We use placeholders like @@HOSTNAME@@ that we will replace with `sed`.
    log_debug "Creating chroot configuration script template."
    cat > /mnt/tmp/configure.sh.tpl <<- 'CHROOT_SCRIPT_TPL'
        #!/bin/bash
        set -ex # Exit on error and print commands

        # --- Basic System Setup ---
        echo "@@HOSTNAME@@" > /etc/hostname
        cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       @@HOSTNAME@@.localdomain @@HOSTNAME@@
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime

        # --- APT and Proxmox Repos ---
        cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
        wget -q -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg http://download.proxmox.com/debian/proxmox-release-bookworm.gpg
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
        
        # --- APT Pinning for Proxmox ---
        cat > /etc/apt/preferences.d/proxmox.pref << EOF_PIN
Package: *
Pin: origin download.proxmox.com
Pin-Priority: 1001
EOF_PIN

        # --- Package Installation ---
        apt-get update
        export DEBIAN_FRONTEND=noninteractive

        # ANNOTATION: Simplified package installation. One command handles all cases.
        PACKAGES="proxmox-ve postfix open-iscsi zfs-initramfs cryptsetup-initramfs bridge-utils ifupdown2 linux-image-amd64 linux-headers-amd64"
        if [ "@@GRUB_MODE@@" == "UEFI" ]; then
            PACKAGES+=" grub-efi-amd64 efibootmgr"
        else
            PACKAGES+=" grub-pc"
        fi
        if [ "@@USE_YUBIKEY@@" == "yes" ]; then
            PACKAGES+=" yubikey-luks libpam-yubico pcscd"
            systemctl enable pcscd
        fi
        apt-get install -y --no-install-recommends $PACKAGES

        # --- Network Configuration ---
        cat > /etc/network/interfaces << EOF
@@NETWORK_CONFIG@@
EOF

        # --- fstab and crypttab ---
        echo "@@FSTAB_CONFIG@@" > /etc/fstab
        echo "@@CRYPMTAB_CONFIG@@" > /etc/crypttab

        # --- Bootloader Installation ---
        update-initramfs -u -k all
        if [ "@@GRUB_MODE@@" == "UEFI" ]; then
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=proxmox --recheck
        else
            grub-install --target=i386-pc --recheck "@@PRIMARY_DISK@@"
        fi
        update-grub

        # --- Final System Config ---
        echo "root:@@ROOT_PASSWORD@@" | chpasswd
        rm -f /etc/apt/sources.list.d/pve-enterprise.list
        systemctl enable ssh
        apt-get clean
CHROOT_SCRIPT_TPL

    # ANNOTATION: Prepare configuration strings to inject into the template.
    # This keeps complex logic in the main script, not the chroot script.
    
    # Network Config
    local net_config=""
    if [[ "${CONFIG_VARS[NET_USE_DHCP]}" == "yes" ]]; then
        net_config="auto lo\niface lo inet loopback\n\nauto ${CONFIG_VARS[NET_IFACE]}\niface ${CONFIG_VARS[NET_IFACE]} inet dhcp"
    else
        net_config="auto lo\niface lo inet loopback\n\nauto ${CONFIG_VARS[NET_IFACE]}\niface ${CONFIG_VARS[NET_IFACE]} inet manual\n\n"
        net_config+="auto vmbr0\niface vmbr0 inet static\n    address ${CONFIG_VARS[NET_IP_CIDR]}\n    gateway ${CONFIG_VARS[NET_GATEWAY]}\n    bridge-ports ${CONFIG_VARS[NET_IFACE]}\n    bridge-stp off\n    bridge-fd 0"
        echo "nameserver ${CONFIG_VARS[NET_DNS]// /$'\n'nameserver }" > /mnt/etc/resolv.conf
    fi

    # Fstab and Crypttab Config
    local fstab_config boot_uuid
    boot_uuid=$(blkid -s UUID -o value "${CONFIG_VARS[BOOT_PART]}")
    fstab_config="# /etc/fstab\nUUID=${boot_uuid} /boot ext4 defaults 0 2\n"
    if [[ "${CONFIG_VARS[EFFECTIVE_GRUB_MODE]}" == "UEFI" ]]; then
        local efi_uuid
        efi_uuid=$(blkid -s UUID -o value "${CONFIG_VARS[EFI_PART]}")
        fstab_config+="UUID=${efi_uuid} /boot/efi vfat umask=0077 0 1"
    fi

    local crypttab_opts="luks,discard"
    [[ "${CONFIG_VARS[USE_YUBIKEY]:-no}" == "yes" ]] && crypttab_opts+=",keyscript=/usr/share/yubikey-luks/ykluks-keyscript"
    local crypttab_config=""
    local luks_partitions_arr=(); read -r -a luks_partitions_arr <<< "${CONFIG_VARS[LUKS_PARTITIONS]}"
    if [[ "${CONFIG_VARS[USE_DETACHED_HEADERS]}" == "yes" ]]; then
        local header_files_arr=(); read -r -a header_files_arr <<< "${CONFIG_VARS[HEADER_FILENAMES_ON_PART]}"
        for i in "${!luks_partitions_arr[@]}"; do
            local part_uuid
            part_uuid=$(blkid -s UUID -o value "${luks_partitions_arr[$i]}")
            crypttab_config+="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i UUID=$part_uuid none $crypttab_opts,header=UUID=${CONFIG_VARS[HEADER_PART_UUID]}:${header_files_arr[$i]}\n"
        done
    else
        for i in "${!luks_partitions_arr[@]}"; do
            local part_uuid
            part_uuid=$(blkid -s UUID -o value "${luks_partitions_arr[$i]}")
            crypttab_config+="${CONFIG_VARS[LUKS_MAPPER_NAME]}_$i UUID=$part_uuid none $crypttab_opts\n"
        done
    fi

    local primary_disk_for_grub; read -r primary_disk_for_grub _ <<< "${CONFIG_VARS[ZFS_TARGET_DISKS]}"

    # ANNOTATION: Use `sed` to create the final, self-contained chroot script.
    sed -e "s|@@HOSTNAME@@|${CONFIG_VARS[HOSTNAME]}|g" \
        -e "s|@@ROOT_PASSWORD@@|${root_pass}|g" \
        -e "s|@@NETWORK_CONFIG@@|${net_config}|g" \
        -e "s|@@FSTAB_CONFIG@@|${fstab_config}|g" \
        -e "s|@@CRYPMTAB_CONFIG@@|${crypttab_config}|g" \
        -e "s|@@GRUB_MODE@@|${CONFIG_VARS[EFFECTIVE_GRUB_MODE]}|g" \
        -e "s|@@PRIMARY_DISK@@|${primary_disk_for_grub}|g" \
        -e "s|@@USE_YUBIKEY@@|${CONFIG_VARS[USE_YUBIKEY]:-no}|g" \
        /mnt/tmp/configure.sh.tpl > /mnt/tmp/configure.sh
    chmod +x /mnt/tmp/configure.sh
    rm /mnt/tmp/configure.sh.tpl
    log_debug "Chroot script created and populated."

    show_progress "Configuring system in chroot (this will take several minutes)..."
    log_debug "Executing chroot /mnt /tmp/configure.sh"
    echo "--- Chroot Script Output Start ---" >> "$LOG_FILE"
    # ANNOTATION: Execute the chroot command, capturing all output.
    if ! chroot /mnt /tmp/configure.sh >> "$LOG_FILE" 2>&1; then
        echo "--- Chroot Script Output End ---" >> "$LOG_FILE"
        show_error "System configuration script failed. Check $LOG_FILE for details."
        _chroot_unmounts # Attempt cleanup even on failure
        exit 1
    fi
    echo "--- Chroot Script Output End ---" >> "$LOG_FILE"
    log_debug "Chroot script executed successfully."

    # Install local debs if they exist
    local debs_source_dir="$SCRIPT_DIR/debs"
    if [[ -d "$debs_source_dir" ]] && ls "$debs_source_dir"/*.deb &>/dev/null; then
        show_progress "Installing local .deb packages..."
        mkdir -p /mnt/tmp/local_debs
        cp "$debs_source_dir"/*.deb /mnt/tmp/local_debs/
        chroot /mnt apt-get install -y /tmp/local_debs/*.deb >> "$LOG_FILE" 2>&1
        rm -rf /mnt/tmp/local_debs
    fi

    rm /mnt/tmp/configure.sh
    _chroot_unmounts
    show_success "System configuration complete."
    log_debug "Exiting function: ${FUNCNAME[0]}"
}
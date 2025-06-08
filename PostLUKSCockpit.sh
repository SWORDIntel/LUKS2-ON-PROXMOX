#!/bin/bash
# --- Post-Install Script: PVE Kernel, Cockpit & KDE Desktop ---
# Run this INSIDE your booted Debian Trixie system.

# --- Configuration & Helper Functions ---
set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for debugging

BOLD="$(tput bold)"
NORMAL="$(tput sgr0)"
GREEN="$(tput setaf 2)"
RED="$(tput setaf 1)"
YELLOW="$(tput setaf 3)"

log_info() {
    echo "${GREEN}${BOLD}[INFO]${NORMAL} $1"
}

log_warn() {
    echo "${YELLOW}${BOLD}[WARN]${NORMAL} $1"
}

log_error() {
    echo "${RED}${BOLD}[ERROR]${NORMAL} $1" >&2
}

ask_yes_no() {
    while true; do
        read -rp "$1 ${BOLD}[y/N]:${NORMAL} " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* | "" ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# --- Script Start ---
log_info "Proxmox VE Kernel, Cockpit & KDE Installer for Debian"
echo

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root or with sudo."
    exit 1
fi

if ! grep -q "VERSION_CODENAME=trixie" /etc/os-release 2>/dev/null; then
    log_warn "This script is intended for Debian Trixie."
    if ! ask_yes_no "Your OS might not be Trixie. Continue anyway?"; then
        log_info "Exiting."
        exit 0
    fi
fi

log_warn "This script will add Proxmox VE repositories (for Bookworm, as PVE 8.x is based on it)"
log_warn "and can install a PVE kernel, PVE tools, Cockpit, and the KDE Plasma Desktop."
log_warn "A reboot will be recommended at the end."
echo
if ! ask_yes_no "Do you want to proceed?"; then
    log_info "Exiting."
    exit 0
fi

# --- 1. Add Proxmox VE Repositories ---
log_info "Adding Proxmox VE repositories..."

# Ensure prerequisites for adding repos
apt update
apt install --yes gpg curl apt-transport-https

# Add Proxmox VE GPG key
if curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg; then
    log_info "Proxmox VE GPG key added."
else
    log_error "Failed to download Proxmox VE GPG key. Please check network or URL."
    exit 1
fi

# Add the PVE repository for "no-subscription"
PVE_REPO_FILE="/etc/apt/sources.list.d/pve-install-repo.list"
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > "${PVE_REPO_FILE}"

log_info "Proxmox VE repository configuration added."
log_info "Running apt update to fetch package lists from new repos..."
apt update

# --- 2. Install Proxmox VE Kernel and Tools ---
log_info "Installing Proxmox VE kernel and tools..."
log_warn "This may install a new kernel and related packages."

PACKAGES_PVE="proxmox-kernel-6.5 pve-headers-6.5 qemu-server proxmox-backup-client"

if ask_yes_no "Install Proxmox VE kernel (6.5) and common tools?"; then
    if apt install --yes "${PACKAGES_PVE}"; then
        log_info "Proxmox VE packages installed."
    else
        log_error "Failed to install Proxmox VE packages. Please check errors."
    fi
else
    log_info "Skipping Proxmox VE package installation."
fi

# --- 3. Install Cockpit and Modules ---
log_info "Installing Cockpit and selected modules..."

PACKAGES_COCKPIT="cockpit cockpit-storaged cockpit-networkmanager cockpit-packagekit cockpit-pcp cockpit-machines cockpit-podman"
PACKAGES_COCKPIT_ZFS="cockpit-zfs-manager"

if ask_yes_no "Install Cockpit and common modules?"; then
    if apt install --yes "${PACKAGES_COCKPIT}"; then
        log_info "Cockpit and common modules installed."

        if ask_yes_no "Attempt to install 'cockpit-zfs-manager'? (May not be available)"; then
            if apt install --yes "${PACKAGES_COCKPIT_ZFS}"; then
                log_info "'cockpit-zfs-manager' installed."
            else
                log_warn "'cockpit-zfs-manager' failed to install. It might not be available in your configured repositories."
            fi
        fi

        log_info "Enabling and starting Cockpit socket..."
        systemctl enable --now cockpit.socket
        systemctl status cockpit.socket
        log_info "Cockpit should be accessible at https://$(hostname -I | awk '{print $1}')":9090

    else
        log_error "Failed to install Cockpit packages. Please check errors."
    fi
else
    log_info "Skipping Cockpit installation."
fi

# --- 4. Install KDE Plasma Desktop ---
if ask_yes_no "Install KDE Plasma Desktop Environment? (This will install a full GUI)"; then
    log_info "Installing KDE Plasma Desktop..."
    log_warn "This is a large installation and will take some time."

    # task-kde-desktop is the recommended meta-package for a full KDE experience
    PACKAGES_KDE="task-kde-desktop"

    if apt install --yes "${PACKAGES_KDE}"; then
        log_info "KDE Plasma Desktop installed successfully."
        # The task-kde-desktop should configure the display manager, but we can ensure it's enabled.
        # SDDM is the default display manager for KDE.
        if systemctl list-unit-files | grep -q sddm.service; then
            log_info "Enabling SDDM (KDE Display Manager)..."
            systemctl enable sddm
        else
            log_warn "SDDM display manager not found. You may need to configure the display manager manually."
        fi
    else
        log_error "Failed to install KDE Plasma Desktop. Please check errors."
    fi
else
    log_info "Skipping KDE Plasma Desktop installation."
fi

# --- 5. Final Steps ---
log_info "Running final package updates and GRUB update..."
apt update

if command -v update-grub &> /dev/null; then
    log_info "Updating GRUB configuration to detect new kernels..."
    update-grub
else
    log_warn "update-grub command not found. Cannot update GRUB automatically."
fi

echo
log_info "--- Installation Complete ---"
log_warn "A REBOOT is highly recommended to use the new Proxmox kernel and/or load the new desktop environment."
if ask_yes_no "Do you want to reboot now?"; then
    log_info "Rebooting in 10 seconds..."
    sleep 10
    reboot
else
    log_info "Please reboot manually when ready."
fi

exit 
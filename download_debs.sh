#!/usr/bin/env bash

# Script to download .deb packages and their dependencies for an offline installer cache.
# Temporarily configures APT sources and GPG keys, then restores them.

# --- Configuration ---
# Define the directory where .deb files will be saved
DEB_DOWNLOAD_DIR="./local_installer_debs_cache"

# --- Target APT Configuration (EDIT THESE FOR YOUR TARGET SYSTEM) ---
# Example for Proxmox VE 8.x (Debian 12 Bookworm based)
TARGET_SOURCES_LIST_CONTENT="""
deber_target_repo_marker_do_not_delete

deb http://ftp.debian.org/debian bookworm main contrib
deb http://ftp.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib

# Proxmox VE repository
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
"""

PROXMOX_GPG_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
PROXMOX_GPG_LOCAL_FILENAME="proxmox-release-bookworm.gpg"
# For older systems, you might need: PROXMOX_GPG_URL="https://enterprise.proxmox.com/debian/proxmox-ve-release-6.x.gpg"

# List of essential packages your installer needs.
PACKAGES_TO_DOWNLOAD=(
    # Core utilities
    "dosfstools" "e2fsprogs" "isc-dhcp-client" "jq" "cryptsetup-bin" "debootstrap"
    "wget" "curl" "gdisk" "rsync" "yubikey-luks" "usbutils" "dialog"
    # GRUB top-level packages grub-pc and grub-efi-amd64 removed as they conflict
    # and the main installer defers to Proxmox for their management.
    # Dependencies like grub-common, grub-pc-bin, grub-efi-amd64-bin will be pulled by other packages if needed,
    # or would be part of the base system provided by Proxmox.

    # Conditional/Feature-specific
    "p7zip-full" "efibootmgr" "yubikey-manager"
    # Common dependencies
    "ca-certificates" "apt-transport-https" "gnupg" "debian-archive-keyring"
    # Proxmox specific (if not already pulled by pve-no-subscription meta-packages)
    # "proxmox-ve" "pve-kernel-$(uname -r | sed 's/-pve$//')" # Example, adjust as needed
    "proxmox-archive-keyring" # Ensures Proxmox keys are known
)

# --- Globals for APT Backup --- 
APT_BACKUP_DIR=""
ORIGINAL_SOURCES_LIST_MD5=""
ORIGINAL_SOURCES_LIST_D_MD5=""
TEMP_GPG_FILES=()
CLEANUP_PERFORMED=0 # Flag to ensure cleanup runs once

# --- Functions --- 
cleanup_apt() {
    if [ "$CLEANUP_PERFORMED" -eq 1 ]; then
        echo "INFO: Cleanup logic already executed or not needed at this stage."
        return 0
    fi
    echo "INFO: Performing APT configuration cleanup..."

    if [ -n "$APT_BACKUP_DIR" ] && [ -d "$APT_BACKUP_DIR" ]; then
        if [ -f "$APT_BACKUP_DIR/sources.list.bak" ]; then
            echo "INFO: Restoring /etc/apt/sources.list..."
            sudo cp "$APT_BACKUP_DIR/sources.list.bak" /etc/apt/sources.list
        fi
        if [ -d "$APT_BACKUP_DIR/sources.list.d.bak" ]; then
            echo "INFO: Restoring /etc/apt/sources.list.d/..."
            sudo rm -rf /etc/apt/sources.list.d/*
            sudo cp -a "$APT_BACKUP_DIR/sources.list.d.bak/." /etc/apt/sources.list.d/ 2>/dev/null || true
        elif [ -f "$APT_BACKUP_DIR/sources.list.d.empty_marker" ]; then
             echo "INFO: Original /etc/apt/sources.list.d was empty or did not exist. Clearing current."
             sudo rm -rf /etc/apt/sources.list.d/*
        fi
        
        echo "INFO: Removing temporary GPG keys..."
        for gpg_file in "${TEMP_GPG_FILES[@]}"; do
            if [ -f "$gpg_file" ]; then
                sudo rm -f "$gpg_file"
                echo "INFO: Removed $gpg_file"
            fi
        done
        TEMP_GPG_FILES=() # Clear the array

        echo "INFO: Removing APT backup directory: $APT_BACKUP_DIR..."
        sudo rm -rf "$APT_BACKUP_DIR"
        APT_BACKUP_DIR="" # Clear variable to prevent re-entry
        
        echo "INFO: Running apt-get update to apply restored configuration..."
        sudo apt-get update || echo "WARNING: apt-get update failed after restoring original configuration." >&2
    else 
        echo "INFO: APT backup directory not found or already cleaned up. No restoration needed from backup dir."
    fi
    CLEANUP_PERFORMED=1
    echo "INFO: Cleanup complete."
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "ERROR: Required command '$1' not found. Please install it and try again." >&2
        exit 1
    fi
}

# --- Main Script ---
# Ensure script is run with sudo or has sudo access for apt commands
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then 
    echo "ERROR: This script needs to run with sudo privileges or have passwordless sudo access." >&2
    exit 1
fi

# Check for essential tools used by this script
check_command "wget"
check_command "gpg"
check_command "md5sum"

# Setup trap for cleanup
trap cleanup_apt EXIT INT TERM ERR

# 1. Backup current APT configuration
echo "INFO: Backing up current APT configuration..."
APT_BACKUP_DIR=$(sudo mktemp -d)
[ -z "$APT_BACKUP_DIR" ] && { echo "ERROR: Failed to create temp backup directory." >&2; exit 1; }
echo "INFO: APT backup directory: $APT_BACKUP_DIR"

sudo cp /etc/apt/sources.list "$APT_BACKUP_DIR/sources.list.bak"
ORIGINAL_SOURCES_LIST_MD5=$(sudo md5sum /etc/apt/sources.list | awk '{print $1}')

if [ -d "/etc/apt/sources.list.d" ] && [ -n "$(ls -A /etc/apt/sources.list.d)" ]; then
    sudo cp -a /etc/apt/sources.list.d "$APT_BACKUP_DIR/sources.list.d.bak"
    ORIGINAL_SOURCES_LIST_D_MD5=$(find /etc/apt/sources.list.d -type f -print0 | sudo xargs -0 md5sum | awk '{print $1}' | sort | md5sum | awk '{print $1}')
elif [ ! -d "/etc/apt/sources.list.d" ] || [ -z "$(ls -A /etc/apt/sources.list.d 2>/dev/null)" ]; then
    sudo touch "$APT_BACKUP_DIR/sources.list.d.empty_marker"
    ORIGINAL_SOURCES_LIST_D_MD5="empty"
fi 

# 2. Apply temporary APT configuration
echo "INFO: Applying temporary APT configuration..."
# Prepare target sources.list content (remove marker line)
PROCESSED_TARGET_SOURCES_LIST_CONTENT=$(echo "$TARGET_SOURCES_LIST_CONTENT" | sed '/^deber_target_repo_marker_do_not_delete$/d')
echo "$PROCESSED_TARGET_SOURCES_LIST_CONTENT" | sudo tee /etc/apt/sources.list > /dev/null

# Clear existing sources.list.d and add Proxmox GPG key if URL is set
sudo rm -rf /etc/apt/sources.list.d/*
if [ -n "$PROXMOX_GPG_URL" ]; then
    echo "INFO: Downloading Proxmox GPG key from $PROXMOX_GPG_URL..."
    TEMP_GPG_DOWNLOAD_PATH="$APT_BACKUP_DIR/$PROXMOX_GPG_LOCAL_FILENAME"
    if sudo wget -q "$PROXMOX_GPG_URL" -O "$TEMP_GPG_DOWNLOAD_PATH"; then
        # Verify it's a GPG key before moving
        if sudo gpg --dearmor --output /dev/null "$TEMP_GPG_DOWNLOAD_PATH" 2>/dev/null; then 
            TARGET_GPG_PATH="/etc/apt/trusted.gpg.d/$PROXMOX_GPG_LOCAL_FILENAME"
            sudo cp "$TEMP_GPG_DOWNLOAD_PATH" "$TARGET_GPG_PATH"
            sudo chmod 644 "$TARGET_GPG_PATH"
            TEMP_GPG_FILES+=("$TARGET_GPG_PATH")
            echo "INFO: Proxmox GPG key installed to $TARGET_GPG_PATH"
        else
            echo "WARNING: Downloaded Proxmox key file does not appear to be a valid GPG key. Skipping install." >&2
        fi
    else
        echo "WARNING: Failed to download Proxmox GPG key. APT update might fail for Proxmox repos." >&2
    fi
fi

# 3. Update APT lists with new configuration
echo "INFO: Running apt-get update with temporary configuration (sudo required)..."
sudo apt-get update || { echo "ERROR: apt-get update failed with temporary configuration. Check target APT settings." >&2; exit 1; }

# 4. Download packages
mkdir -p "$DEB_DOWNLOAD_DIR"
ORIGINAL_PWD="$(pwd)"
cd "$DEB_DOWNLOAD_DIR" || { echo "ERROR: Failed to cd to $DEB_DOWNLOAD_DIR." >&2; exit 1; }

echo "INFO: Clearing any existing .deb files from $(pwd) to ensure a fresh download set..."
rm -f ./*.deb

echo "INFO: Downloading packages to /var/cache/apt/archives/ then copying to $(pwd)..."
sudo apt-get install --download-only -y "${PACKAGES_TO_DOWNLOAD[@]}"
if [ $? -ne 0 ]; then
    echo "WARNING: 'apt-get install --download-only' encountered errors for some packages." >&2
    echo "Some packages or their dependencies might be missing from the download set." >&2
fi

sudo cp /var/cache/apt/archives/*.deb ./
if [ $? -ne 0 ]; then
    echo "WARNING: Failed to copy some .deb files from /var/cache/apt/archives/." >&2
fi

# Optional: Clean the local apt cache of the system after copying
# echo "INFO: Cleaning system APT cache (/var/cache/apt/archives/)..."
# sudo apt-get clean

cd "$ORIGINAL_PWD" || echo "WARNING: Failed to cd back to $ORIGINAL_PWD." >&2

echo ""
echo "SUCCESS: Package download process finished."
echo "Downloaded .deb files should be in: $DEB_DOWNLOAD_DIR (relative to where script was run)"
echo "Full path: $(cd "$DEB_DOWNLOAD_DIR" && pwd)"
echo "Please review the directory for completeness."

# Cleanup will be called automatically by trap on EXIT
exit 0

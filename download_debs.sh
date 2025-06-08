#!/bin/bash
# Download all .deb files for every package required by the installer (excluding PostLUKSCockpit.sh-only packages)
# Also includes essential utilities needed for minimal Proxmox debug environments.

set -euo pipefail

LOG_FILE="download_debs.log"
DEB_DIR="debs"
mkdir -p "$DEB_DIR"

# Deduplicated package list (excluding PostLUKSCockpit.sh-only packages)
ALL_PACKAGES=(
    grub-efi-amd64
    efibootmgr
    grub-pc
    yubikey-luks
    yubikey-manager
    libpam-yubico
    ykcs11
    libykpers-1-1
    libyubikey0
    pcscd
    postfix
    open-iscsi
    zfsutils-linux
    cryptsetup-bin
    debootstrap
    wget
    curl
    gdisk
    rsync
    usbutils
)

# Download each package (deduplicated, skip if already present)
for pkg in "${ALL_PACKAGES[@]}"; do
    if ls "$DEB_DIR"/"${pkg}"_*.deb 1> /dev/null 2>&1; then
        echo "[INFO] $pkg already downloaded. Skipping." | tee -a "$LOG_FILE"
        continue
    fi
    echo "[INFO] Downloading $pkg ..." | tee -a "$LOG_FILE"
    if ! apt-get download "$pkg" 2>> "$LOG_FILE"; then
        echo "[ERROR] Failed to download $pkg. Check $LOG_FILE for details." | tee -a "$LOG_FILE"
    else
        mv ./"${pkg}"_*.deb "$DEB_DIR/" 2>/dev/null || true
        echo "[INFO] $pkg downloaded successfully." | tee -a "$LOG_FILE"
    fi
    echo
    sleep 1
    done

echo "[INFO] All downloads attempted. Check $DEB_DIR for .deb files and $LOG_FILE for errors."


# Script to download .deb packages from a list of URLs

# Default target directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET_DIR="$SCRIPT_DIR/debs"
TARGET_DIR="${1:-$DEFAULT_TARGET_DIR}"

# Package URLs file
PACKAGE_URLS_FILE="$SCRIPT_DIR/debs/package_urls.txt"

# Create target directory if it doesn't exist
mkdir -p "$TARGET_DIR"

# Check if package_urls.txt exists
if [ ! -f "$PACKAGE_URLS_FILE" ]; then
  echo "Warning: Package URLs file not found at $PACKAGE_URLS_FILE"
  echo "Please create this file with a list of .deb package URLs."
  exit 0 # Exit gracefully as per requirement
fi

# Check if package_urls.txt is empty
if [ ! -s "$PACKAGE_URLS_FILE" ]; then
  echo "Warning: Package URLs file $PACKAGE_URLS_FILE is empty."
  echo "No packages to download."
  exit 0 # Exit gracefully
fi

echo "Starting download of .deb packages to $TARGET_DIR..."

# Read URLs and download
while IFS= read -r url || [[ -n "$url" ]]; do
  if [ -z "$url" ]; then # Skip empty lines
    continue
  fi
  echo "Downloading $url..."
  # shellcheck disable=SC2181
  if ! wget -P "$TARGET_DIR" "$url"; then
    echo "Error: Failed to download $url (wget exit status: $?)"
    # Continue to try downloading other packages
  else
    echo "Successfully downloaded $url to $TARGET_DIR"
  fi
done < "$PACKAGE_URLS_FILE"

echo "All downloads attempted."
echo "Packages are located in $TARGET_DIR"

exit 0

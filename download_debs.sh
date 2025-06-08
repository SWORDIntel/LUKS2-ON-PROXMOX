#!/bin/bash
# Download all .deb files for every package required by the installer (excluding PostLUKSCockpit.sh-only packages)
# Also includes essential utilities needed for minimal Proxmox debug environments.
# This script will download both the specified packages and all their dependencies.

set -euo pipefail

LOG_FILE="download_debs.log"
DEB_DIR="debs"
PACKAGE_URLS_FILE="$DEB_DIR/package_urls.txt"
mkdir -p "$DEB_DIR"

# Logging functions
log_info() { echo "[INFO] $1" | tee -a "$LOG_FILE"; }
log_debug() { echo "[DEBUG] $1" | tee -a "$LOG_FILE"; }
log_error() { echo "[ERROR] $1" | tee -a "$LOG_FILE"; }
log_warn() { echo "[WARN] $1" | tee -a "$LOG_FILE"; }

# Deduplicated package list (excluding PostLUKSCockpit.sh-only packages)
ALL_PACKAGES=(
    grub-efi-amd64
    efibootmgr
    grub-pc
    # YubiKey packages and dependencies
    yubikey-luks
    cryptsetup-run
    yubikey-manager
    python3-ykman
    python3-click
    python3-cryptography
    python3-fido2
    yubikey-personalization
    libyubikey-udev
    libpam-yubico
    ykcs11
    libykpers-1-1
    libyubikey0
    pcscd
    # System packages
    postfix
    open-iscsi
    # ZFS packages and dependencies
    zfsutils-linux
    libnvpair3linux
    libutil3linux
    libzfs6linux
    libzpool6linux
    zfs-zed
    # Other utilities
    cryptsetup-bin
    debootstrap
    wget
    curl
    gdisk
    rsync
    usbutils
)

# Function to download a package and its dependencies using apt-get
download_package() {
    local pkg="$1"
    local temp_dir
    temp_dir="$(mktemp -d)"
    local success=false
    local skip=false
    
    # Track already processed packages to avoid duplicates
    if [[ " ${PROCESSED_PACKAGES[*]} " == *" $pkg "* ]]; then
        log_debug "$pkg has already been processed. Skipping."
        return 0
    fi
    
    # Add to processed packages list
    PROCESSED_PACKAGES+=("$pkg")
    
    # Check if already downloaded
    if ls "$DEB_DIR/${pkg}"_*.deb &> /dev/null; then
        log_info "$pkg already downloaded. Skipping."
        skip=true
        success=true
    fi
    
    if [[ "$skip" == "false" ]]; then
        log_info "Downloading $pkg..."
        
        # Try apt-get download first
        if (cd "$temp_dir" && apt-get download "$pkg" &>> "$LOG_FILE"); then
            # Move downloaded debs to target directory
            if mv "$temp_dir"/*.deb "$DEB_DIR/" &>> "$LOG_FILE"; then
                log_info "Successfully downloaded $pkg via apt-get"
                success=true
            else
                log_warn "No .deb files found after apt-get download for $pkg"
            fi
        else
            log_warn "apt-get download failed for $pkg, will try URL fallback"
        fi
        
        # If apt-get failed, try URL download if we have package_urls.txt
        if [[ "$success" == "false" ]] && [[ -f "$PACKAGE_URLS_FILE" ]]; then
            # Try to find matching URL
            local url
            url=$(grep -i "/${pkg}_" "$PACKAGE_URLS_FILE" | grep -v '^#' | head -1)
            if [[ -n "$url" ]]; then
                log_info "Attempting URL download for $pkg: $url"
                if wget -q "$url" -O "$DEB_DIR/$(basename "$url")" &>> "$LOG_FILE"; then
                    log_info "Successfully downloaded $pkg via URL"
                    success=true
                else
                    log_error "Failed to download $pkg via URL: $url"
                fi
            else
                log_error "No URL found for $pkg in $PACKAGE_URLS_FILE"
            fi
        fi
    fi
    
    # Process dependencies if download was successful
    if [[ "$success" == "true" ]]; then
        # Get dependencies
        local deps
        deps=$(apt-cache depends "$pkg" 2>/dev/null | grep '\bDepends\b' | cut -d ':' -f 2 | sed 's/<[^>]*>//g' | tr -d ' ')
        
        # Process each dependency
        for dep in $deps; do
            # Skip virtual packages (those with pipe symbol)
            if [[ "$dep" != *\|* ]]; then
                log_debug "Found dependency: $dep for package $pkg"
                download_package "$dep" || true  # Don't fail if a dependency fails
            fi
        done
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Return success status
    [[ "$success" == "true" ]]
}

# Main process
log_info "Starting package downloads to $DEB_DIR"

# Initialize processed packages array
PROCESSED_PACKAGES=()

# Download main packages and dependencies
for pkg in "${ALL_PACKAGES[@]}"; do
    log_info "Processing $pkg and its dependencies"
    download_package "$pkg"
    echo
    sleep 1
done

# Process any URLs from package_urls.txt not already handled
if [[ -f "$PACKAGE_URLS_FILE" ]]; then
    log_info "Processing any remaining packages from $PACKAGE_URLS_FILE"
    
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        
        # Extract package name from URL
        pkg_name=$(basename "$line" | sed 's/_.*//g')
        
        # Skip if already downloaded
        if ls "$DEB_DIR/${pkg_name}"_*.deb &> /dev/null; then
            log_debug "$pkg_name already downloaded. Skipping URL download."
            continue
        fi
        
        log_info "Downloading $line..."
        if wget -q "$line" -P "$DEB_DIR" &>> "$LOG_FILE"; then
            log_info "Successfully downloaded $line to $DEB_DIR"
        else
            log_error "Failed to download $line (wget exit status: $?)"
        fi
    done < "$PACKAGE_URLS_FILE"
fi

log_info "All downloads attempted."
log_info "Packages are located in $DEB_DIR"

exit 0

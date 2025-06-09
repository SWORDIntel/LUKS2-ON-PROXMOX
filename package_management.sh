#!/usr/bin/env bash

set -ue # Exit on unset variables and errors

echo "SCRIPT_STARTED_STDOUT_TOP"
echo "SCRIPT_STARTED_STDERR_TOP" >&2

# Determine the script's absolute directory for robust sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common UI functions
# shellcheck source=ui_functions.sh
if [[ -f "${SCRIPT_DIR}/ui_functions.sh" ]]; then
    source "${SCRIPT_DIR}/ui_functions.sh"
else
    # Attempt to source from a common parent directory if this script is in a subdirectory
    if [[ -f "${SCRIPT_DIR}/../ui_functions.sh" ]]; then
        source "${SCRIPT_DIR}/../ui_functions.sh"
    else
        echo "Error: ui_functions.sh not found in ${SCRIPT_DIR} or ${SCRIPT_DIR}/../. Exiting." >&2
        # Decide if this is a fatal error for this script. 
        # If package_management.sh can run without UI (e.g. for a build server), don't exit.
        # For an interactive installer, it's likely fatal.
        # For now, let's assume it might be used non-interactively, so just warn.
        echo "Warning: UI functions may not be available." >&2
        # exit 1 # Uncomment if UI is absolutely critical for all uses of this script
    fi
fi

# Helper function to check if an item is in a list (array)
# Usage: is_package_in_list "item_to_find" "${array[@]}"
is_package_in_list() {
    local item="$1"
    shift
    local arr=("$@")
    for element in "${arr[@]}"; do
        if [[ "$element" == "$item" ]]; then
            return 0 # Found
        fi
    done
    return 1 # Not found
}

# Fallback logging functions if ui_functions.sh is not available or fails
if ! command -v log_info &> /dev/null; then
    # SCRIPT_DIR is determined at the top of the script
    _FALLBACK_LOG_TARGET_DIR="${SCRIPT_DIR:-/tmp}" # Default to /tmp if SCRIPT_DIR is somehow empty
    _FALLBACK_LOG_TARGET="${_FALLBACK_LOG_TARGET_DIR}/package_management_fallback.log"

    # Announce fallback activation and target (to stderr, so it's visible in script_output.log)
    echo "DEBUG: SCRIPT_DIR='${SCRIPT_DIR}' (used for fallback log path)" >&2
    echo "UI functions not fully loaded or log_info not found. Defining ALL fallback logging functions." >&2
    echo "Fallback log target: ${_FALLBACK_LOG_TARGET}" >&2
    
    # Ensure log directory exists and perform a test write
    mkdir -p "$(dirname "$_FALLBACK_LOG_TARGET")"
    echo "[TEST_WRITE] $(date '+%Y-%m-%d %H:%M:%S') - Fallback logger initializing. Target: ${_FALLBACK_LOG_TARGET}" >> "$_FALLBACK_LOG_TARGET"
    if [[ $? -eq 0 ]]; then
        echo "Fallback log test write SUCCEEDED." >&2
    else
        echo "Fallback log test write FAILED. Fallback logging to file will not work." >&2
    fi

    # Define all core logging functions to use the fallback target
    log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$_FALLBACK_LOG_TARGET"; }
    log_debug() { echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$_FALLBACK_LOG_TARGET"; }
    log_warning() { echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$_FALLBACK_LOG_TARGET"; }
    log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$_FALLBACK_LOG_TARGET"; }
    
    # Define all UI feedback functions (show_*) to echo formatted message to stdout and call log_info for file logging
    show_step() { echo "==> $(date '+%Y-%m-%d %H:%M:%S') - $*" >&1; log_info "STEP: $*"; }
    show_success() { echo "✓ $(date '+%Y-%m-%d %H:%M:%S') - $*" >&1; log_info "SUCCESS: $*"; }
    show_error() { echo "✗ $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; log_info "ERROR_UI: $*"; }
    show_warning() { echo "! $(date '+%Y-%m-%d %H:%M:%S') - $*" >&1; log_info "WARNING_UI: $*"; }
    show_progress() { echo "  -> $(date '+%Y-%m-%d %H:%M:%S') - $*" >&1; log_info "PROGRESS: $*"; }
    
    # Define *_stdout functions to call their respective show_* primary functions
    show_step_stdout() { show_step "$*"; }
    show_success_stdout() { show_success "$*"; }
    show_error_stdout() { show_error "$*"; }
    show_warning_stdout() { show_warning "$*"; }
fi

# --- APT Configuration Management for populate_offline_cache ---
# Proxmox VE 8 (Bookworm) specific APT configuration
PROXMOX_BOOKWORM_SOURCES_CONTENT="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
PROXMOX_GPG_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"

# Filenames for temporary APT configuration files used by `populate_offline_cache`.
# These ensure that the cache creation process does not interfere with the host system's APT setup.
TEMP_PROXMOX_GPG_FILENAME="proxmox-installer-temp-key.gpg"
TEMP_PROXMOX_SOURCES_FILE="proxmox-installer-temp.list"
TEMP_PROXMOX_PREFS_FILE="proxmox-installer-temp.pref"

# _setup_temp_proxmox_config: Sets up a temporary APT environment for Proxmox package downloads.
# This includes adding a temporary Proxmox sources list, GPG key, and pinning preferences.
# Intended for use by `populate_offline_cache` to build an offline cache without altering
# the host system's persistent APT configuration.
_setup_temp_proxmox_config() {
    log_debug "Applying temporary Proxmox APT configuration..."

    # Create Proxmox sources file
    echo "$PROXMOX_BOOKWORM_SOURCES_CONTENT" > "/etc/apt/sources.list.d/$TEMP_PROXMOX_SOURCES_FILE" 
    log_debug "Created temporary Proxmox sources at /etc/apt/sources.list.d/$TEMP_PROXMOX_SOURCES_FILE"

    # Add the GPG key
    log_debug "Downloading GPG key from $PROXMOX_GPG_URL to /etc/apt/trusted.gpg.d/$TEMP_PROXMOX_GPG_FILENAME"
    if curl -fsSL "$PROXMOX_GPG_URL" -o "/etc/apt/trusted.gpg.d/$TEMP_PROXMOX_GPG_FILENAME"; then
        log_info "Proxmox GPG key downloaded and placed as $TEMP_PROXMOX_GPG_FILENAME."
    else
        show_error "Failed to download Proxmox GPG key from $PROXMOX_GPG_URL."
        return 1 # Critical failure
    fi

    # Create Proxmox preferences file for pinning
    # Note: The package list for pinning should be comprehensive for Proxmox VE components.
    cat << EOF > "/etc/apt/preferences.d/$TEMP_PROXMOX_PREFS_FILE"
Package: proxmox-ve pve-manager pve-kernel-* qemu-server libpve-storage-perl libpve-guest-common-perl libproxmox-rs-perl proxmox-mini-journalreader proxmox-widget-toolkit pve-xtermjs pve-cluster pve-container pve-docs pve-edk2-firmware pve-firewall pve-ha-manager pve-i18n pve-qemu-kvm pve-xtermjs
Pin: release o=PVE
Pin-Priority: 990
EOF
    log_debug "Created temporary Proxmox preferences at /etc/apt/preferences.d/$TEMP_PROXMOX_PREFS_FILE"
    
    log_info "Temporary Proxmox APT configuration applied."
    return 0
}

# _restore_apt_config: Cleans up the temporary APT configuration files created by _setup_temp_proxmox_config.
# Removes the temporary sources list, GPG key, and preferences file.
# Runs `apt-get update` if any files were removed to refresh the APT state.
# This function is typically called via a trap in `populate_offline_cache` to ensure cleanup.
_restore_apt_config() {
    log_debug "Cleaning up temporary APT configuration files..."
    local files_removed=false

    if [[ -f "/etc/apt/sources.list.d/$TEMP_PROXMOX_SOURCES_FILE" ]]; then
        rm -f "/etc/apt/sources.list.d/$TEMP_PROXMOX_SOURCES_FILE" &>> "$LOG_FILE"
        log_debug "Removed temporary Proxmox sources file: /etc/apt/sources.list.d/$TEMP_PROXMOX_SOURCES_FILE"
        files_removed=true
    fi
    
    if [[ -f "/etc/apt/trusted.gpg.d/$TEMP_PROXMOX_GPG_FILENAME" ]]; then
        rm -f "/etc/apt/trusted.gpg.d/$TEMP_PROXMOX_GPG_FILENAME" &>> "$LOG_FILE"
        log_debug "Removed temporary Proxmox GPG key: /etc/apt/trusted.gpg.d/$TEMP_PROXMOX_GPG_FILENAME"
        files_removed=true
    fi

    if [[ -f "/etc/apt/preferences.d/$TEMP_PROXMOX_PREFS_FILE" ]]; then
        rm -f "/etc/apt/preferences.d/$TEMP_PROXMOX_PREFS_FILE" &>> "$LOG_FILE"
        log_debug "Removed temporary Proxmox preferences file: /etc/apt/preferences.d/$TEMP_PROXMOX_PREFS_FILE"
        files_removed=true
    fi

    if [[ "$files_removed" == true ]]; then
        log_info "Temporary APT files removed. Running apt-get update to refresh state..."
        if ! apt-get update &>> "$LOG_FILE"; then
            show_warning "apt-get update failed after removing temporary APT files. System APT state might be inconsistent."
        fi
    else
        log_debug "No temporary APT files found to remove."
    fi
    return 0
}

# --- End APT Configuration Management ---

# --- Persistent Proxmox APT Configuration ---
# Constants for persistent Proxmox APT configuration files
PERSISTENT_PROXMOX_GPG_FILENAME="proxmox-release-bookworm.gpg"
PERSISTENT_PROXMOX_SOURCES_FILE="proxmox.list"
PERSISTENT_PROXMOX_PREFS_FILE="proxmox.pref" # Using .pref for consistency if .conf is also used

# PROXMOX_BOOKWORM_SOURCES_CONTENT and PROXMOX_GPG_URL are already defined globally

# configure_persistent_proxmox_apt: Configures the system with persistent Proxmox APT sources.
# This includes the Proxmox repository list, GPG key, and pinning preferences.
# It's called by `ensure_packages_installed` when `PROXMOX_ZFS_DETECTED` is true
# and an online installation is being performed on the target system.
# This function ensures the target system is correctly set up to manage Proxmox packages.
# It checks for existing configurations to avoid redundant operations.
configure_persistent_proxmox_apt() {
    log_debug "Configuring persistent Proxmox APT sources..."
    local files_changed=false

    # Create Proxmox sources file if it doesn't exist or is different
    local sources_path="/etc/apt/sources.list.d/$PERSISTENT_PROXMOX_SOURCES_FILE"
    if ! grep -qFx "$PROXMOX_BOOKWORM_SOURCES_CONTENT" "$sources_path" 2>/dev/null; then
        echo "$PROXMOX_BOOKWORM_SOURCES_CONTENT" > "$sources_path"
        log_info "Created/Updated Proxmox sources at $sources_path"
        files_changed=true
    else
        log_debug "Proxmox sources file $sources_path already up-to-date."
    fi

    # Add the GPG key if it doesn't exist
    local gpg_path="/etc/apt/trusted.gpg.d/$PERSISTENT_PROXMOX_GPG_FILENAME"
    if [[ ! -f "$gpg_path" ]]; then
        log_debug "Downloading GPG key from $PROXMOX_GPG_URL to $gpg_path"
        if curl -fsSL "$PROXMOX_GPG_URL" -o "$gpg_path"; then
            log_info "Proxmox GPG key downloaded to $gpg_path."
            files_changed=true
        else
            show_error "Failed to download Proxmox GPG key from $PROXMOX_GPG_URL to $gpg_path."
            return 1 # Critical failure
        fi
    else
        log_debug "Proxmox GPG key $gpg_path already exists."
    fi

    # Create Proxmox preferences file for pinning if it doesn't exist or is different
    local prefs_path="/etc/apt/preferences.d/$PERSISTENT_PROXMOX_PREFS_FILE"
    # Define the content for the preferences file
    local proxmox_prefs_content
    read -r -d '' proxmox_prefs_content <<EOF || true
Package: proxmox-ve pve-manager pve-kernel-* qemu-server libpve-storage-perl libpve-guest-common-perl libproxmox-rs-perl proxmox-mini-journalreader proxmox-widget-toolkit pve-xtermjs pve-cluster pve-container pve-docs pve-edk2-firmware pve-firewall pve-ha-manager pve-i18n pve-qemu-kvm pve-xtermjs
Pin: release o=PVE
Pin-Priority: 990
EOF
    # Check if file exists and content matches
    # Using temporary file instead of process substitution to avoid /dev/fd issues
    local temp_prefs=$(mktemp)
    echo -n "$proxmox_prefs_content" > "$temp_prefs"
    if [[ ! -f "$prefs_path" ]] || ! cmp -s "$temp_prefs" "$prefs_path"; then
        # Clean up temp file after the comparison is done
        rm -f "$temp_prefs"
        echo "$proxmox_prefs_content" > "$prefs_path"
        log_info "Created/Updated Proxmox preferences at $prefs_path"
        files_changed=true
    else
        log_debug "Proxmox preferences file $prefs_path already up-to-date."
        # Clean up temp file if we're not updating the file
        rm -f "$temp_prefs"
    fi
    
    if [[ "$files_changed" == true ]]; then
        log_info "Persistent Proxmox APT configuration applied. Consider running apt-get update."
    else
        log_info "Persistent Proxmox APT configuration already correctly set up."
    fi
    return 0
}
# --- End Persistent Proxmox APT Configuration ---

#===============================================================================
# Robust Package Management for Linux Installers (Unified Version)
#
# Replaces:
# - download_debs.sh
# - install_local_dependencies.sh
#
# ARCHITECTURE:
# This script acts as a robust wrapper around the native `apt` package manager.
# It delegates complex dependency resolution to `apt`, making it more reliable
# and easier to maintain than manual parsing.
#
# WORKFLOW:
# 1. (Online "Build" Machine) To prepare for an offline install, run:
#    `populate_offline_cache package1 package2 ...`
#    - This function temporarily configures the build machine's APT environment
#      to use Proxmox (Bookworm) repositories, including sources, GPG key, and pinning.
#      This is achieved using helper functions (_setup_temp_proxmox_config) that create
#      temporary APT configuration files (e.g., in /etc/apt/sources.list.d/, /etc/apt/trusted.gpg.d/).
#    - A trap ensures these temporary configurations are cleaned up (_restore_apt_config)
#      on script completion or interruption, leaving the build machine's APT state untouched.
#    - It then downloads the specified packages and all their dependencies into the `debs/` directory.
#    - This approach allows for creating a Proxmox-specific offline cache on any Debian-based
#      system without persistent modifications to its APT setup.
#
# 2. (Online/Offline "Target" Machine) The main installer script calls:
#    `ensure_packages_installed package1 package2 ...`
#    - If Proxmox is detected on the target system (`PROXMOX_ZFS_DETECTED="true"`) AND an
#      online installation is being performed:
#        - It first calls `configure_persistent_proxmox_apt` to set up the Proxmox
#          APT sources, GPG key, and pinning preferences *persistently* on the target.
#          This ensures the system can correctly fetch and update Proxmox packages.
#    - If online (and after Proxmox APT setup, if applicable), it uses `apt` to fetch
#      and install missing packages from repositories.
#    - If offline, or if online installation fails, it uses `apt` to install missing
#      packages from the pre-populated `debs/` directory.
#    - Note: For Proxmox systems, installation of certain core packages is intentionally
#      skipped (see PROXMOX_CORE_PACKAGES_TO_AVOID) to prevent conflicts with
#      Proxmox's own package management.
#
#===============================================================================

# --- Configuration ---
# Assumes SCRIPT_DIR is set by the main installer. Default to current dir otherwise.
: "${SCRIPT_DIR:=.}"
: "${DEBS_DIR:=${SCRIPT_DIR}/debs}"
: "${LOG_FILE:=${SCRIPT_DIR}/installer.log}"

# Always assume Proxmox environment for package management
export PROXMOX_ZFS_DETECTED="true"
log_info "Package management: Forcing PROXMOX_ZFS_DETECTED=true to always skip GRUB and core ZFS packages"

# Ensure required directories exist
mkdir -p "$DEBS_DIR" &>/dev/null

# Proxmox Core Packages to AVOID modifying if Proxmox is detected
# These are typically managed by Proxmox itself.
PROXMOX_CORE_PACKAGES_TO_AVOID=(
    zfsutils-linux # And all its direct library dependencies
    zfs-zed        # ZFS Event Daemon, managed by Proxmox's zfsutils
    libzfs2linux libzfs4linux libzfs6linux # Covers various versions of ZFS libs
    libzpool2linux libzpool5linux libzpool6linux # Covers various versions of ZFS libs
    grub-efi-amd64 grub-pc grub-common grub2-common
    systemd        # Core system manager, Proxmox has its own versioning/dependencies
    # libc6 is too fundamental; apt should handle it. Explicitly avoiding it might break more.
    # Proxmox may also have specific versions of kernel, etc.
    # For now, focusing on the ones causing immediate dpkg errors or version conflicts.
)

#-------------------------------------------------------------------------------
# Standard Package Lists
#-------------------------------------------------------------------------------

# Base system packages that are almost always needed
BASE_PACKAGES_COMMON=(
    efibootmgr
    postfix
    open-iscsi
    # Utilities
    cryptsetup-bin debootstrap wget curl gdisk rsync usbutils pv
)

if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]]; then
    log_info "Proxmox environment detected. Adjusting BASE_PACKAGES to exclude GRUB."
    BASE_PACKAGES=("${BASE_PACKAGES_COMMON[@]}")
else
    BASE_PACKAGES=(
        grub-efi-amd64 grub-pc # Only include GRUB if not Proxmox
        "${BASE_PACKAGES_COMMON[@]}"
    )
fi

# ZFS-related packages
if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]]; then
    log_info "Proxmox environment detected. ZFS packages will be managed by Proxmox."
    ZFS_PACKAGES=()
    # If this script specifically needs to ensure zfs-zed is running and configured
    # in a way that Proxmox doesn't do by default, it could be added here.
    # For now, assume Proxmox handles all necessary ZFS components.
else
    ZFS_PACKAGES=(
        zfsutils-linux # Let apt resolve its library dependencies
        zfs-zed
    )
fi

# YubiKey support packages
YUBIKEY_PACKAGES=(
    python3-full # Ensure full Python environment for YubiKey package builds/setup
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
)

#-------------------------------------------------------------------------------
# Logging and UI Functions
#-------------------------------------------------------------------------------
log_debug() { printf "[DEBUG] %s\n" "$*" >> "$LOG_FILE"; }
log_info()  { printf "[INFO]  %s\n" "$*" >> "$LOG_FILE"; }
log_error() { printf "[ERROR] %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
show_step()     { printf "\n\e[1;34m==>\e[0m \e[1m%s\e[0m\n" "$*"; }
show_progress() { printf "  \e[1;32m->\e[0m %s\n" "$*"; }
show_success()  { printf "  \e[1;32m✓\e[0m %s\n" "$*"; }
show_error()    { printf "  \e[1;31m✗\e[0m %s\n" "$*"; log_error "$*"; }
show_warning()  { printf "  \e[1;33m!\e[0m %s\n" "$*"; }

#-------------------------------------------------------------------------------
# Proxmox APT Configuration (Conditional)
#-------------------------------------------------------------------------------
_configure_proxmox_apt_sources() {
    if [[ "${PROXMOX_ZFS_DETECTED:-false}" != "true" ]]; then
        log_debug "Not a Proxmox environment, skipping Proxmox APT source configuration."
        return 0
    fi

    log_info "Proxmox environment detected. Configuring Proxmox APT sources and pinning."
    show_progress "Configuring Proxmox APT sources..."

    # Step 1: Install Proxmox GPG key / archive keyring package
    # Ensure curl and gpg are available for key fetching if proxmox-archive-keyring is not installed
    if ! dpkg-query -W -f='${Status}' proxmox-archive-keyring 2>/dev/null | grep -q "ok installed"; then
        show_progress "proxmox-archive-keyring not found. Attempting to install it or add key manually."
        # First, try to install the package which is the cleanest way
        if apt-get update &>/dev/null && apt-get install -y --no-install-recommends proxmox-archive-keyring &>> "$LOG_FILE"; then
            show_success "proxmox-archive-keyring installed."
        else
            show_warning "Failed to install proxmox-archive-keyring. Attempting to add key manually."
            if ! command -v curl &>/dev/null; then apt-get install -y curl &>> "$LOG_FILE"; fi
            if ! command -v gpg &>/dev/null; then apt-get install -y gpg &>> "$LOG_FILE"; fi
            if command -v curl &>/dev/null && command -v gpg &>/dev/null; then
                PROXMOX_GPG_URL="https://download.proxmox.com/proxmox-release-bookworm.gpg"
                if curl -sSfL "${PROXMOX_GPG_URL}" -o /tmp/proxmox-archive-keyring.gpg; then
                    log_info "Proxmox GPG key downloaded successfully."
                    if gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg /tmp/proxmox-archive-keyring.gpg; then
                        show_success "Proxmox GPG key added manually."
                    else
                        show_error "Failed to add Proxmox GPG key manually."
                        # Potentially return 1 here if key is critical and cannot be added
                    fi
                else
                    show_error "Failed to download Proxmox GPG key from ${PROXMOX_GPG_URL}."
                fi
            else
                show_error "curl or gpg command not found, cannot add Proxmox GPG key."
            fi
        fi
    else
        show_success "proxmox-archive-keyring is already installed."
    fi
    # Ensure permissions are correct for GPG keys
    chmod 644 /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg &>/dev/null

    # Step 2: Comment out enterprise repositories
    show_progress "Checking for and disabling Proxmox enterprise repositories..."
    local apt_files_to_check=("/etc/apt/sources.list")
    if [[ -d "/etc/apt/sources.list.d" ]]; then
        apt_files_to_check+=("/etc/apt/sources.list.d/"*.list)
    fi

    for apt_file in "${apt_files_to_check[@]}"; do
        if [[ -f "$apt_file" ]]; then
            if grep -q "enterprise.proxmox.com" "$apt_file"; then
                log_info "Found enterprise repo lines in $apt_file. Commenting them out."
                # Use a temporary file for sed in-place edit for safety
                sed -i.bak 's|^deb.*enterprise.proxmox.com.*|# &|g' "$apt_file"
                show_warning "Commented out Proxmox enterprise repositories in $apt_file."
            fi
        fi
    done

    # Step 3: Add PVE no-subscription repository
    local PVE_REPO_FILE="/etc/apt/sources.list.d/pve-no-subscription.list"
    local PVE_REPO_LINE="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
    if ! grep -qFx "$PVE_REPO_LINE" "$PVE_REPO_FILE" &>/dev/null; then # Use -x for exact line match
        echo "$PVE_REPO_LINE" > "$PVE_REPO_FILE"
        log_info "Added PVE no-subscription repository to $PVE_REPO_FILE"
    else
        log_info "PVE no-subscription repository already configured in $PVE_REPO_FILE"
    fi

    # Step 4: Add Ceph no-subscription repository (using ceph-squid as per no-subscription standard)
    local CEPH_REPO_FILE="/etc/apt/sources.list.d/ceph.list"
    # The error mentioned ceph-quincy, but no-subscription for bookworm is typically ceph-squid or ceph-reef.
    # Let's stick to ceph-squid as it was in the previous version, assuming it's correct for Bookworm no-sub.
    # If ceph-reef is the actual no-sub for bookworm, this line should be updated.
    local CEPH_REPO_LINE="deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription"
    if ! grep -qFx "$CEPH_REPO_LINE" "$CEPH_REPO_FILE" &>/dev/null; then # Use -x for exact line match
        echo "$CEPH_REPO_LINE" > "$CEPH_REPO_FILE"
        log_info "Added Ceph no-subscription repository to $CEPH_REPO_FILE"
    else
        log_info "Ceph no-subscription repository already configured in $CEPH_REPO_FILE"
    fi

    # Step 5: APT Pinning for Proxmox repositories
    local PINNING_FILE="/etc/apt/preferences.d/proxmox-pinning"
    # Ensure the directory exists
    mkdir -p /etc/apt/preferences.d
    local PINNING_CONTENT="Package: *\nPin: release o=download.proxmox.com\nPin-Priority: 1001\n"
    local needs_pinning_update=true
    if [[ -f "$PINNING_FILE" ]]; then
        # Check if the exact pinning content we want is already there
        # Using temporary file instead of process substitution to avoid /dev/fd issues
        local temp_pinning=$(mktemp)
        echo -e "$PINNING_CONTENT" > "$temp_pinning"
        if cmp -s "$temp_pinning" "$PINNING_FILE"; then
            rm -f "$temp_pinning"
            needs_pinning_update=false
            log_info "Proxmox APT pinning already correctly configured in $PINNING_FILE."
        else
            log_warning "Proxmox APT pinning file $PINNING_FILE exists but content differs. Overwriting."
        fi
    fi

    if $needs_pinning_update; then
        echo -e "$PINNING_CONTENT" > "$PINNING_FILE"
        log_info "Configured APT pinning for Proxmox repositories in $PINNING_FILE"
    fi
    show_success "Proxmox APT sources configured."
}

#-------------------------------------------------------------------------------
# Core Installation Function (for the Target Machine)
#-------------------------------------------------------------------------------

# The primary function to ensure a list of packages are installed.
# It automatically handles online vs. offline scenarios.
ensure_packages_installed() {
    local apt_install_opts=()
    if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]]; then
        apt_install_opts=(--no-install-recommends)
        log_info "Proxmox detected, using apt options: ${apt_install_opts[*]}"
    fi

    local packages_needed=("$@")
    if [[ ${#packages_needed[@]} -eq 0 ]]; then
        log_debug "ensure_packages_installed called with no packages."
        return 0
    fi

    show_step "Ensuring Packages are Installed"
    log_info "Ensuring packages are installed: ${packages_needed[*]}"

    local current_packages_to_process=("${packages_needed[@]}")

    if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]]; then
        log_info "Proxmox detected. Filtering core Proxmox packages from installation list."
        local filtered_packages_for_proxmox=()
        for pkg_to_check in "${current_packages_to_process[@]}"; do
            local is_core_proxmox_pkg=false
            for core_pkg in "${PROXMOX_CORE_PACKAGES_TO_AVOID[@]}"; do
                if [[ "$pkg_to_check" == "$core_pkg" ]]; then
                    is_core_proxmox_pkg=true
                    log_info "Skipping installation of '$pkg_to_check' as it is likely managed by Proxmox."
                    break
                fi
            done
            if ! $is_core_proxmox_pkg; then
                filtered_packages_for_proxmox+=("$pkg_to_check")
            fi
        done
        current_packages_to_process=("${filtered_packages_for_proxmox[@]}")

        if [[ ${#current_packages_to_process[@]} -eq 0 ]]; then
            show_success "All requested packages are either already installed or managed by Proxmox."
            return 0
        fi
        log_info "Packages to process after Proxmox filter: ${current_packages_to_process[*]}"
    fi

    # 1. Determine which packages are actually missing from the system.
    # Use current_packages_to_process instead of original packages_needed
    local missing_packages=()
    for pkg in "${current_packages_to_process[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        show_success "All required packages are already installed."
        log_info "All required packages are already installed."
        return 0
    fi
    show_progress "Packages to install: ${missing_packages[*]}"

    # 2. Attempt online installation if internet is available.
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log_info "Internet detected. Attempting online installation via APT."
        if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]]; then
            if ! configure_persistent_proxmox_apt; then
                show_error "Failed to configure persistent Proxmox APT sources. Online installation may fail. Check $LOG_FILE."
                # We'll still attempt apt-get update, which will likely also fail or use stale lists.
            fi
        fi
        show_progress "Updating package lists..."
        if ! apt-get update &>> "$LOG_FILE"; then
            show_warning "apt-get update failed. Repository or network issue suspected."
        fi

        show_progress "Installing missing packages from repositories..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y "${apt_install_opts[@]}" "${missing_packages[@]}" &>> "$LOG_FILE"; then
            show_success "All required packages installed successfully from online repositories."
            return 0
        else
            show_error "APT failed to install some packages online. See log for details."
            # Fall through to try the local cache as a backup.
        fi
    fi

    # 3. Fallback to offline installation from the local `debs` directory.
    log_info "No internet or online install failed. Attempting offline installation from '$DEBS_DIR'."
    show_warning "Trying to install from local package cache..."

    if [[ ! -d "$DEBS_DIR" ]] || [[ -z "$(ls -A "$DEBS_DIR"/*.deb 2>/dev/null)" ]]; then
        show_error "Cannot install packages: No internet and the local '$DEBS_DIR' cache is empty."
        return 1
    fi

    show_progress "Installing from local .deb files in '$DEBS_DIR'..."
    if [[ "${PROXMOX_ZFS_DETECTED}" == "true" ]]; then
        show_warning "Proxmox detected. Installing from local debs is risky for non-add-on packages."
        show_warning "Ensure local debs for '${missing_packages[*]}' are PVE-compatible or are self-contained tools."
    fi
    # Modern apt can resolve dependencies from local .deb files
    # This is the part that caused problems if DEBS_DIR contains conflicting core packages.
    # The filtering of missing_packages should now prevent it from attempting to install Proxmox core items.
    if apt install -y "${apt_install_opts[@]}" "${missing_packages[@]/#/$DEBS_DIR/}" &>> "$LOG_FILE" || \
       apt install -y "${apt_install_opts[@]}" "$DEBS_DIR"/*.deb &>> "$LOG_FILE"; then
        log_info "apt install from DEBS_DIR succeeded for some/all packages."
        # Packages might have been installed. Final verification will confirm.
    else
        show_warning "apt install from DEBS_DIR failed initially. Trying dpkg -i and apt-get -f install."
        # Attempt to install .deb files using dpkg, filtering core Proxmox packages if needed.
        local deb_files_to_install=()
        if [[ -d "$DEBS_DIR" ]] && [[ -n "$(ls -A "$DEBS_DIR"/*.deb 2>/dev/null)" ]]; then
            for deb_file in "$DEBS_DIR"/*.deb; do
                local pkg_name
                pkg_name=$(dpkg-deb -f "$deb_file" Package 2>/dev/null)
                if [[ -z "$pkg_name" ]]; then
                    show_warning "Could not determine package name for $deb_file. Skipping."
                    continue
                fi

                if [[ "${PROXMOX_ZFS_DETECTED:-false}" == "true" ]] && \
                   is_package_in_list "$pkg_name" "${PROXMOX_CORE_PACKAGES_TO_AVOID[@]}"; then
                    log_info "Offline install: Skipping Proxmox core package .deb: $deb_file (package: $pkg_name)"
                else
                    deb_files_to_install+=("$deb_file")
                fi
            done

            if [[ ${#deb_files_to_install[@]} -gt 0 ]]; then
                log_info "Offline install: Attempting dpkg -i for: ${deb_files_to_install[*]}"
                # shellcheck disable=SC2086 # We want word splitting for the deb files
                dpkg -i ${deb_files_to_install[@]} &>> "$LOG_FILE"
            else
                log_info "Offline install: No .deb files to install after filtering."
            fi
        else
            show_warning "Offline install: DEBS_DIR is empty or contains no .deb files."
        fi
        show_progress "Attempting to fix dependencies after dpkg -i..."
        if ! apt-get -f install -y "${apt_install_opts[@]}" &>> "$LOG_FILE"; then
            show_error "Failed to fix dependencies after dpkg -i. Local cache installation likely failed."
            # Proceed to final verification regardless, to see the state.
        else
            log_info "apt-get -f install (dependency fix) completed."
        fi
    fi

    # Final verification to be absolutely sure.
    local actually_still_missing=() # Renamed to avoid confusion with loop var or previous states
    # Iterate over the original list of packages we intended to install in this offline phase.
    for pkg in "${missing_packages[@]}"; do 
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            actually_still_missing+=("$pkg")
        fi
    done # Correctly close the for loop

    if [[ ${#actually_still_missing[@]} -eq 0 ]]; then
        show_success "All initially missing packages appear to be successfully installed from the local cache."
        return 0
    else
        show_error "Installation from cache finished, but some packages are still missing: ${actually_still_missing[*]}"
        show_error "The local cache may be incomplete, or there were unrecoverable errors during installation."
        
        # Optional: Try one last comprehensive fix-broken if there are still missing packages
        # This is a good last-ditch effort before failing.
        show_progress "Attempting a final 'apt --fix-broken install' as some packages remain uninstalled..."
        if ! apt-get --fix-broken install -y &>> "$LOG_FILE"; then
            show_warning "Final 'apt --fix-broken install' did not resolve all issues or failed."
        else
            # Re-check after the fix-broken attempt
            local finally_missing_after_fix_broken=()
            for pkg_final_check in "${actually_still_missing[@]}"; do # Only re-check those that were missing
                if ! dpkg-query -W -f='${Status}' "$pkg_final_check" 2>/dev/null | grep -q "ok installed"; then
                    finally_missing_after_fix_broken+=("$pkg_final_check")
                fi
            done
            if [[ ${#finally_missing_after_fix_broken[@]} -eq 0 ]]; then
                show_success "All packages successfully installed after a final 'apt --fix-broken install'."
                return 0
            else
                show_error "Even after 'apt --fix-broken install', these packages remain uninstalled: ${finally_missing_after_fix_broken[*]}"
            fi
        fi
        return 1 # Return failure if packages are still missing
    fi
}

#-------------------------------------------------------------------------------
# Offline Cache Preparation Function (for the "Build" Machine)
#-------------------------------------------------------------------------------

# To be run on an ONLINE machine to prepare the `debs/` directory.
populate_offline_cache() {
    # Ensure temporary APT configuration is cleaned up on exit, interrupt, or termination
    trap '_restore_apt_config' EXIT INT TERM

    local packages_to_cache=("$@")
    if [[ ${#packages_to_cache[@]} -eq 0 ]]; then
        show_error "No packages specified to populate the cache."
        return 1
    fi

    show_step "Populating Offline Package Cache"
    log_info "Populating offline cache with: ${packages_to_cache[*]}"

    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        show_error "An internet connection is required to populate the cache."
        return 1
    fi

    # Setup temporary Proxmox APT configuration
    if ! _setup_temp_proxmox_config; then
        show_error "Failed to set up temporary Proxmox APT configuration. Aborting cache population."
        # Trap will call _restore_apt_config to clean up any partial changes
        return 1
    fi

    show_progress "Updating package lists with temporary configuration..."
    if ! apt-get update &>> "$LOG_FILE"; then
        show_error "apt-get update failed with temporary Proxmox configuration. Check $LOG_FILE."
        # Trap will call _restore_apt_config
        return 1
    fi

    show_progress "Downloading packages and ALL their dependencies individually..."
    local all_downloads_succeeded=true
    for pkg in "${packages_to_cache[@]}"; do
        log_info "Attempting to download $pkg and its dependencies..."
        # `--download-only` is the key. It resolves all dependencies and fetches them without installing.
        # We use --ignore-missing for individual packages; if a package truly doesn't exist, we log it but continue.
        # The main check for success is if apt-get install itself returns non-zero for other reasons (e.g. held broken packages for *that specific package*).
        if ! apt-get install -y --download-only --no-install-recommends --ignore-missing "$pkg" &>> "$LOG_FILE"; then
            # Log the specific package failure, but don't necessarily exit the loop immediately.
            # Some failures might be due to the package already being downloaded or other non-critical issues for a specific package.
            # However, if apt-get returns an error, it's a sign something went wrong for this package.
            log_error "Failed to download '$pkg' or its dependencies. Check $LOG_FILE for details."
            all_downloads_succeeded=false # Mark that at least one download failed
        else
            log_info "Successfully processed download for $pkg."
        fi
    done

    if [[ "$all_downloads_succeeded" == false ]]; then
        show_error "One or more packages failed to download. Check logs and repository configuration."
        # Trap will call _restore_apt_config
        return 1 # Indicate overall failure
    fi

    show_progress "Copying downloaded .deb files to '$DEBS_DIR'..."
    # The downloaded files are in the system's apt cache.
    cp /var/cache/apt/archives/*.deb "$DEBS_DIR/" &>> "$LOG_FILE"
    
    # Clean the system cache to save space on the build machine.
    apt-get clean &>> "$LOG_FILE"

    local file_count
    file_count=$(find "$DEBS_DIR" -maxdepth 1 -type f -name "*.deb" 2>/dev/null | wc -l)
    show_success "Offline cache populated with $file_count .deb files."
    log_info "Offline cache now contains $file_count files in $DEBS_DIR"
    return 0
}

#-------------------------------------------------------------------------------
# Convenience function for ensuring essential base packages
#-------------------------------------------------------------------------------
ensure_essential_packages() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Get essential packages from our predefined arrays
    local essential_packages=(
        "${BASE_PACKAGES[@]}"
        "pv"     # For RAM disk progress monitoring
    )
    
    # Remove any duplicates - using temporary file instead of process substitution to avoid /dev/fd issues
    local temp_pkglist=$(mktemp)
    printf '%s\n' "${essential_packages[@]}" | sort -u > "$temp_pkglist"
    essential_packages=()
    while IFS= read -r pkg; do
        essential_packages+=("$pkg")
    done < "$temp_pkglist"
    rm -f "$temp_pkglist"
    
    log_debug "Installing ${#essential_packages[@]} essential packages"
    ensure_packages_installed "${essential_packages[@]}"
    
    local status=$?
    log_debug "Exiting function: ${FUNCNAME[0]} with status: $status"
    return $status
}

# Function to prepare all installer packages using the predefined package lists
# This should be called from the main installer to prepare the offline cache
prepare_installer_debs() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "Preparing installer packages"
    
    # Skip if running from RAM as packages should already be included
    if [[ "${run_from_ram:-false}" == true ]]; then
        log_debug "Running from RAM, skipping package preparation."
        return 0
    fi
    
    local package_count=0
    local debs_dir_status=""
    
    # Prompt the user only if the directory is empty
    if [[ ! -d "$DEBS_DIR" ]] || [[ -z "$(ls -A "$DEBS_DIR" 2>/dev/null)" ]]; then
        if ! prompt_yes_no "The local 'debs' directory is empty. Would you like to download required packages for a potential offline installation?"; then
            show_warning "Skipping package download. For offline use, ensure 'debs' directory is populated."
            return 0
        fi
        
        # Ensure we have network before attempting download
        if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            show_error "No internet connection. Cannot download packages."
            show_warning "Please run network setup or populate the 'debs' folder manually."
            return 1
        fi
        
        show_progress "Downloading packages for offline installation..."
        mkdir -p "$DEBS_DIR"
        
        # Combine all package lists
        local all_packages=(
            "${BASE_PACKAGES[@]}"
            "${ZFS_PACKAGES[@]}"
            "${YUBIKEY_PACKAGES[@]}"
        )
        
        # Remove duplicates (if any) - using temporary file instead of process substitution to avoid /dev/fd issues
        local temp_pkglist=$(mktemp)
        printf '%s\n' "${all_packages[@]}" | sort -u > "$temp_pkglist"
        all_packages=()
        while IFS= read -r pkg; do
            all_packages+=("$pkg")
        done < "$temp_pkglist"
        rm -f "$temp_pkglist"
        
        log_debug "Preparing ${#all_packages[@]} packages: ${all_packages[*]}"
        if ! populate_offline_cache "${all_packages[@]}"; then
            show_error "Failed to download packages. Check logs for details."
            return 1
        fi
        show_success "Packages downloaded successfully to 'debs' directory."
        debs_dir_status="newly downloaded"
    else
        show_progress "Local 'debs' directory already contains packages."
        debs_dir_status="existing"
    fi
    
    # Count packages for reporting
    if [[ -d "$DEBS_DIR" ]]; then
        package_count=$(find "$DEBS_DIR" -name "*.deb" | wc -l)
    fi

        
        # Display a summary in the terminal as well
        echo -e "\n===== Package Preparation Summary ====="
        if [[ "$debs_dir_status" == "newly downloaded" ]]; then
            echo "Downloaded $package_count packages to: $DEBS_DIR"
        else
            echo "Using $package_count existing packages in: $DEBS_DIR"
        fi
        echo "Ready for air-gapped installation."
        printf "====================================\n\n"
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

# Execute if run directly (not sourced)
# This allows the script to be run as: ./package_management.sh [function_name] [args...]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If no arguments provided, default to prepare_installer_debs
    if [[ $# -eq 0 ]]; then
        prepare_installer_debs
    else
        # Otherwise, call the specified function with any arguments
        "$@"
    fi
fi
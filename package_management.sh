#!/usr/bin/env bash
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
#    This creates a `debs/` directory with all required .deb files and their dependencies.
#
# 2. (Online/Offline "Target" Machine) The main installer script calls:
#    `ensure_packages_installed package1 package2 ...`
#    - If online, it uses `apt` to fetch and install from repositories.
#    - If offline, it uses `apt` to install from the pre-populated `debs/` directory.
#
#===============================================================================

# --- Configuration ---
# Assumes SCRIPT_DIR is set by the main installer. Default to current dir otherwise.
: "${SCRIPT_DIR:=.}"
: "${DEBS_DIR:=${SCRIPT_DIR}/debs}"
: "${LOG_FILE:=${SCRIPT_DIR}/installer.log}"

# Ensure required directories exist
mkdir -p "$DEBS_DIR" &>/dev/null

#-------------------------------------------------------------------------------
# Standard Package Lists
#-------------------------------------------------------------------------------

# Base system packages that are almost always needed
BASE_PACKAGES=(
    # System essentials
    grub-efi-amd64 grub-pc
    efibootmgr
    postfix
    open-iscsi
    # Utilities
    cryptsetup-bin debootstrap wget curl gdisk rsync usbutils dialog pv
)

# ZFS-related packages
ZFS_PACKAGES=(
    zfsutils-linux
    libnvpair3linux
    libutil3linux
    libzfs6linux
    libzpool6linux
    zfs-zed
)

# YubiKey support packages
YUBIKEY_PACKAGES=(
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
# Logging and UI Functions (Assumed to be defined or sourced elsewhere)
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
# Core Installation Function (for the Target Machine)
#-------------------------------------------------------------------------------

# The primary function to ensure a list of packages are installed.
# It automatically handles online vs. offline scenarios.
ensure_packages_installed() {
    local packages_needed=("$@")
    if [[ ${#packages_needed[@]} -eq 0 ]]; then
        log_debug "ensure_packages_installed called with no packages."
        return 0
    fi

    show_step "Ensuring Packages are Installed"
    log_info "Ensuring packages are installed: ${packages_needed[*]}"

    # 1. Determine which packages are actually missing from the system.
    local missing_packages=()
    for pkg in "${packages_needed[@]}"; do
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
        show_progress "Updating package lists..."
        if ! apt-get update &>> "$LOG_FILE"; then
            show_warning "apt-get update failed. Repository or network issue suspected."
        fi

        show_progress "Installing missing packages from repositories..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y --no-install-recommends "${missing_packages[@]}" &>> "$LOG_FILE"; then
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
    export DEBIAN_FRONTEND=noninteractive
    # `apt install` on a directory is the modern, robust way to do this.
    if apt install -y --no-install-recommends "$DEBS_DIR"/*.deb &>> "$LOG_FILE"; then
        # Final verification to be absolutely sure.
        local still_missing=()
        for pkg in "${missing_packages[@]}"; do
            if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
                still_missing+=("$pkg")
            fi
        done

        if [[ ${#still_missing[@]} -eq 0 ]]; then
            show_success "All required packages installed successfully from local cache."
            return 0
        else
            show_error "Installation from cache finished, but some packages are still missing: ${still_missing[*]}"
            show_error "The local cache appears to be incomplete."
            return 1
        fi
    else
        show_error "Failed to install packages from the local cache."
        show_progress "Attempting to fix broken dependencies with 'apt --fix-broken install'..."
        apt-get --fix-broken install -y &>> "$LOG_FILE"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Offline Cache Preparation Function (for the "Build" Machine)
#-------------------------------------------------------------------------------

# To be run on an ONLINE machine to prepare the `debs/` directory.
populate_offline_cache() {
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

    show_progress "Updating package lists..."
    apt-get update &>> "$LOG_FILE"

    show_progress "Downloading packages and ALL their dependencies..."
    # `--download-only` is the key. It resolves all dependencies and fetches them without installing.
    apt-get install -y --download-only --no-install-recommends "${packages_to_cache[@]}" &>> "$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        show_error "Failed to download one or more packages. Check repository configuration."
        return 1
    fi

    show_progress "Copying downloaded .deb files to '$DEBS_DIR'..."
    # The downloaded files are in the system's apt cache.
    cp /var/cache/apt/archives/*.deb "$DEBS_DIR/" &>> "$LOG_FILE"
    
    # Clean the system cache to save space on the build machine.
    apt-get clean &>> "$LOG_FILE"

    local file_count
    file_count=$(ls -1 "$DEBS_DIR" | wc -l)
    show_success "Offline cache populated with $file_count .deb files."
    log_info "Offline cache now contains $file_count files in $DEBS_DIR"
    return 0
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
        if command -v dialog &>/dev/null; then
            if ! dialog --title "Download .deb Packages" --yesno "The local 'debs' directory is empty. Would you like to download required packages for a potential offline installation?" 10 78; then
                show_warning "Skipping package download. For offline use, ensure 'debs' directory is populated."
                return 0
            fi
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
        
        # Remove duplicates (if any)
        readarray -t all_packages < <(printf '%s\n' "${all_packages[@]}" | sort -u)
        
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

    if command -v dialog &>/dev/null; then
        local status_message=""
        if [[ "$debs_dir_status" == "newly downloaded" ]]; then
            status_message="Successfully downloaded $package_count packages to $DEBS_DIR\n\n"
        elif [[ "$debs_dir_status" == "existing" ]]; then
            status_message="Using $package_count existing packages in $DEBS_DIR\n\n"
        fi
        
        status_message+="For use on an air-gapped machine, ensure you copy the ENTIRE installer directory\n(including the 'debs' folder) to your installation media."
        
        dialog --title "Package Preparation Complete" --msgbox "$status_message" 12 70
        
        # Display a summary in the terminal as well
        echo -e "\n===== Package Preparation Summary ====="
        if [[ "$debs_dir_status" == "newly downloaded" ]]; then
            echo "Downloaded $package_count packages to: $DEBS_DIR"
        else
            echo "Using $package_count existing packages in: $DEBS_DIR"
        fi
        echo "Ready for air-gapped installation."
        echo "====================================\n"
    fi
    
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
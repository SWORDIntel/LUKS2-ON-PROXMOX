#!/usr/bin/env bash
#===============================================================================
# Robust Package Management for Linux Installers (FAILSAFE UNIFIED VERSION)
#
# Replaces:
# - download_debs.sh
# - install_local_dependencies.sh
#
# This version uses simplified, plain-text UI functions.
#===============================================================================

# --- Configuration ---
# Assumes SCRIPT_DIR is set by the main installer. Default to current dir otherwise.
: "${SCRIPT_DIR:=.}"
: "${DEBS_DIR:=${SCRIPT_DIR}/local_installer_debs_cache}"
# LOG_FILE is expected to be set by the sourcing script or defaults in ui_functions.sh

# Source simplified UI functions
# shellcheck source=ui_functions.sh
source "${SCRIPT_DIR}/ui_functions.sh" || { printf "Critical Error: Failed to source ui_functions.sh in package_management.sh. Exiting.\n" >&2; exit 1; }

# Custom logging and UI functions for package_management.sh (with color)
# These will override functions from ui_functions.sh if names clash.
log_debug() { [ -n "${LOG_FILE:-}" ] && printf "[DEBUG] %s\n" "$*" >> "$LOG_FILE" || true; }
log_info()  { [ -n "${LOG_FILE:-}" ] && printf "[INFO]  %s\n" "$*" >> "$LOG_FILE" || true; }
log_error() { 
    local message="$*"
    [ -n "${LOG_FILE:-}" ] && printf "[ERROR] %s\n" "$message" >> "$LOG_FILE" || true
    printf "[ERROR] %s\n" "$message" >&2
}
show_step()     { printf "\n\e[1;34m==>\e[0m \e[1m%s\e[0m\n" "$*"; }
show_progress() { printf "  \e[1;32m->\e[0m %s\n" "$*"; }
show_success()  { printf "  \e[1;32m✓\e[0m %s\n" "$*"; }
show_error()    { 
    printf "  \e[1;31m✗\e[0m %s\n" "$*" >&2;
    log_error "$*" # Call the new log_error to ensure it's logged to file
}
show_warning()  { printf "  \e[1;33m!\e[0m %s\n" "$*"; }

# Ensure required directories exist
mkdir -p "$DEBS_DIR" 2>/dev/null || log_warning "Could not create DEBS_DIR: $DEBS_DIR"

_ensure_proxmox_apt_configuration() {
        log_debug "Ensuring Proxmox APT configuration (GPG key, sources, pinning)..."
    local success=true
    local apt_updated_after_repo_changes=false

    # --- DEBUG: Force APT Online Failure for Fallback Test ---
    # Ensure this doesn't run if PROXMOX_DETECTED is false and we're not in a Proxmox setup part
    if [[ "${PROXMOX_DETECTED:-false}" == "true" || -z "${PROXMOX_DETECTED+x}" ]]; then # Apply if Proxmox or if var not set (generic context)
        log_warning "DEBUG: Intentionally attempting to break online APT sources for fallback test by adding a dummy_broken.list."
        echo "deb http://localhost/nonexistent_repo bookworm main" | sudo tee /etc/apt/sources.list.d/dummy_broken.list >/dev/null
        # This file will be cleaned up if the general sources.list.d cleanup runs, or manually after test.
    fi
    # --- END DEBUG ---

    # --- Step 1: Disable/Modify Enterprise Repositories ---
    log_debug "Step 1: Searching for and disabling Proxmox enterprise repositories..."
    local pve_enterprise_list_path="/etc/apt/sources.list.d/pve-enterprise.list"
    if [[ -f "$pve_enterprise_list_path" ]]; then
        log_info "Found $pve_enterprise_list_path. Commenting out entries..."
        # Use a temporary file for sed to avoid issues with redirecting to the same file
        local temp_sed_file
        temp_sed_file=$(mktemp) || { show_error "Failed to create temp file for sed."; success=false; }
        if $success && sed -E 's|^deb.*enterprise\.proxmox\.com.*|# &|g' "$pve_enterprise_list_path" > "$temp_sed_file"; then
            if ! mv "$temp_sed_file" "$pve_enterprise_list_path"; then 
                show_error "Failed to move temp file to $pve_enterprise_list_path."
                success=false
                rm -f "$temp_sed_file" # Clean up temp file on error
            else
                show_success "Commented out enterprise repositories in $pve_enterprise_list_path."
            fi
        elif $success; then # sed failed
            show_error "sed command failed for $pve_enterprise_list_path."
            success=false
            rm -f "$temp_sed_file" # Clean up temp file
        fi 
    else
        log_debug "$pve_enterprise_list_path not found."
    fi

    # Also check the main sources.list and other .list files for enterprise.proxmox.com
    local other_apt_files_to_check=()
    [[ -f "/etc/apt/sources.list" ]] && other_apt_files_to_check+=("/etc/apt/sources.list")
    
    if [ -d "/etc/apt/sources.list.d" ]; then
        # Exclude the pve-enterprise.list we just handled, and our target no-sub lists
        # Using find to get full paths and avoid issues with spaces or special chars if any
        local find_output
        find_output=$(find /etc/apt/sources.list.d/ -maxdepth 1 -name "*.list" ! -name "pve-enterprise.list" ! -name "pve-no-subscription.list" ! -name "ceph.list" -print0)
        while IFS= read -r -d $'\0' file; do
            other_apt_files_to_check+=("$file")
        done <<< "$find_output"
    fi

    for apt_file in "${other_apt_files_to_check[@]}"; do
        if [[ -f "$apt_file" ]]; then # Ensure it's a file, find might list broken symlinks etc.
            if grep -q "enterprise.proxmox.com" "$apt_file"; then
                log_info "Found enterprise repo string in $apt_file. Commenting out relevant lines..."
                local temp_sed_file_other
                temp_sed_file_other=$(mktemp) || { show_error "Failed to create temp file for sed on $apt_file."; success=false; break; }
                if sed -E 's|^deb.*enterprise\.proxmox\.com.*|# &|g' "$apt_file" > "$temp_sed_file_other"; then
                    if ! mv "$temp_sed_file_other" "$apt_file"; then
                        show_error "Failed to move temp file to $apt_file."
                        success=false
                        rm -f "$temp_sed_file_other"
                    else
                        show_success "Commented out enterprise repositories in $apt_file."
                    fi
                else # sed failed
                    show_error "sed command failed for $apt_file."
                    success=false
                    rm -f "$temp_sed_file_other"
                fi
            fi
        fi
        if ! $success; then break; fi # Exit loop if an error occurred
    done

    # --- Step 2: Add No-Subscription Repositories ---
    if $success; then
        log_debug "Step 2: Ensuring Proxmox no-subscription repositories are configured..."
        mkdir -p /etc/apt/sources.list.d 2>/dev/null || true
        local pve_no_sub_list="/etc/apt/sources.list.d/pve-no-subscription.list"
        local ceph_no_sub_list="/etc/apt/sources.list.d/ceph.list" # This is the Proxmox Ceph no-sub

        log_info "Writing PVE no-subscription list to $pve_no_sub_list..."
        if ! echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > "$pve_no_sub_list"; then
            show_error "Failed to write $pve_no_sub_list."
            success=false
        fi

        if $success; then
            log_info "Writing Ceph no-subscription list to $ceph_no_sub_list..."
            if ! echo "deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription" > "$ceph_no_sub_list"; then
                show_error "Failed to write $ceph_no_sub_list."
                success=false
            fi
        fi
        if $success; then show_success "Configured Proxmox PVE and Ceph no-subscription repositories."; fi
    fi

    # --- Step 3: Install/Verify Proxmox GPG Key ---
    if $success; then
        log_debug "Step 3: Installing/Verifying Proxmox GPG Key..."
        log_info "Attempting to update APT package lists with new repository configuration..."
        if ! apt-get update -y -o "Acquire::Check-Valid-Until=false"; then
            show_warning "apt-get update failed after configuring no-subscription repos. GPG key/package installation might fail."
            # Not setting success=false yet, let the keyring installation attempt proceed.
        else
            show_success "APT package lists updated successfully with new configuration."
            apt_updated_after_repo_changes=true
        fi

        log_debug "Checking for proxmox-archive-keyring package..."
        if ! dpkg-query -W -f='${Status}' proxmox-archive-keyring 2>/dev/null | grep -q "ok installed"; then
            show_progress "Proxmox GPG keyring package not found. Attempting to install proxmox-archive-keyring..."
            if DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages proxmox-archive-keyring; then
                show_success "Successfully installed proxmox-archive-keyring."
            else
                show_warning "Failed to install proxmox-archive-keyring. Falling back to manual key download."
                if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
                    show_error "Neither curl nor wget is available for manual GPG key download. Cannot proceed."
                    success=false 
                else
                    local proxmox_gpg_key_url="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
                    local proxmox_gpg_key_path="/etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg"
                    mkdir -p "$(dirname "$proxmox_gpg_key_path")" 2>/dev/null || true
                    log_debug "Downloading Proxmox GPG key from $proxmox_gpg_key_url to $proxmox_gpg_key_path"
                    local key_download_ok=false
                    if command -v curl &>/dev/null; then
                        if curl -fsSL "$proxmox_gpg_key_url" -o "$proxmox_gpg_key_path"; then
                            key_download_ok=true
                        else
                            show_error "Manual GPG key download failed using curl."
                        fi
                    fi 
                    if ! $key_download_ok && command -v wget &>/dev/null; then # Try wget if curl failed or not present/chosen
                        if wget -qO "$proxmox_gpg_key_path" "$proxmox_gpg_key_url"; then
                            key_download_ok=true
                        else
                            show_error "Manual GPG key download failed using wget."
                        fi
                    fi

                    if $key_download_ok; then
                        chmod 644 "$proxmox_gpg_key_path" && show_success "Manually downloaded and installed Proxmox GPG key."
                    else
                        success=false # GPG key download failed
                    fi 
                fi 
            fi
        else
            log_debug "proxmox-archive-keyring package already installed."
        fi
    fi 

    # --- Step 4: APT Pinning ---
    if $success; then
        log_debug "Step 4: Ensuring Proxmox APT pinning is configured..."
        mkdir -p /etc/apt/preferences.d 2>/dev/null || true
        local proxmox_pin_file="/etc/apt/preferences.d/proxmox.pref"
        local pin_content="Package: *\nPin: origin download.proxmox.com\nPin-Priority: 1001"
        log_info "Writing APT pinning to $proxmox_pin_file..."
        if ! printf "%b\n" "$pin_content" > "$proxmox_pin_file"; then
            show_error "Failed to write Proxmox APT pinning to $proxmox_pin_file."
            success=false
        else
            show_success "Configured APT pinning for Proxmox repositories."
        fi
    else
        log_warning "Skipping APT pinning due to errors in previous APT configuration steps."
    fi

    # --- Step 5: Final apt-get update (if not done or to be safe) ---
    if $success && ! $apt_updated_after_repo_changes ; then
        log_info "Running a final apt-get update to ensure lists are current..."
        if ! apt-get update -y -o "Acquire::Check-Valid-Until=false"; then
            show_warning "Final apt-get update encountered issues. Package lists might not be fully current."
        else
            show_success "APT package lists finalized."
        fi
    elif $success; then
        log_debug "APT lists should be up-to-date from keyring installation step or earlier update."
    fi

    if ! $success; then
        show_error "One or more critical steps in Proxmox APT configuration failed. Check logs."
        return 1
    fi
    log_info "Proxmox APT configuration completed successfully."
    return 0
}

#-------------------------------------------------------------------------------
# Standard Package Lists
#-------------------------------------------------------------------------------

BASE_PACKAGES=(
    grub-efi-amd64 grub-pc
    efibootmgr
    postfix
    open-iscsi
    cryptsetup-bin debootstrap wget curl gdisk rsync usbutils pv
)

ZFS_PACKAGES=(
    zfsutils-linux
    libnvpair3linux
    libuutil3linux
    libzfs6linux
    libzpool6linux
    zfs-zed
)

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

# Proxmox Core Packages to AVOID modifying if Proxmox is detected
# These are typically managed by Proxmox itself.
PROXMOX_CORE_PACKAGES_TO_AVOID=(
    zfsutils-linux # And all its direct library dependencies
    libzfs2linux libzfs4linux libzfs6linux # Covers various versions of ZFS libs
    libzpool2linux libzpool5linux libzpool6linux # Covers various versions of ZFS libs
    libnvpair3linux # Often a ZFS dependency
    libuutil3linux  # Often a ZFS dependency
    zfs-zed         # ZFS Event Daemon
    systemd         # System and service manager
    grub-efi-amd64 grub-pc grub-common grub2-common
    # libc6 is too fundamental; apt should handle it. Explicitly avoiding it might break more.
    # Proxmox may also have specific versions of kernel, systemd, etc.
    # For now, focusing on the ones causing immediate dpkg errors.
)

#-------------------------------------------------------------------------------
# Core Installation Function (for the Target Machine)
#-------------------------------------------------------------------------------
ensure_packages_installed() {
    local packages_needed=("$@")
    if [[ ${#packages_needed[@]} -eq 0 ]]; then
        log_debug "ensure_packages_installed called with no packages."
        return 0
    fi

    show_header "PACKAGE INSTALLATION"
    log_debug "Ensuring packages are installed: ${packages_needed[*]}"

    local missing_packages=()
    for pkg in "${packages_needed[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        show_success "All required packages are already installed."
        log_debug "All packages (${packages_needed[*]}) already installed."
        return 0
    fi

    log_debug "Packages to install/update: ${missing_packages[*]}"
    show_progress "The following packages will be installed/updated: ${missing_packages[*]}"

    if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
        if ! _ensure_proxmox_apt_configuration; then
            show_warning "Failed to fully configure Proxmox APT sources. Package installation may encounter issues."
            # Decide if this is fatal or if we should proceed with caution.
            # For now, proceeding with caution.
        fi
    fi

    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        show_progress "Attempting to update package lists (apt-get update)..."
        if apt-get update -y; then
            show_success "Package lists updated successfully."
        else
            show_warning "apt-get update failed. Proceeding with cached lists if possible."
        fi
    else
        show_warning "Offline. Skipping package list update. Using local cache if available."
    fi

    local apt_install_opts=(-y --allow-downgrades --allow-remove-essential --allow-change-held-packages)
    if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
        log_debug "Proxmox detected, adding --no-install-recommends to apt options."
        apt_install_opts+=(--no-install-recommends)
    fi

    # If Proxmox is detected, filter out core packages from the installation list
    local final_packages_to_install_online=("${missing_packages[@]}")
    if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
        log_debug "Proxmox detected. Filtering PROXMOX_CORE_PACKAGES_TO_AVOID from online install list."
        local temp_install_list=()
        for pkg_to_check in "${missing_packages[@]}"; do
            local skip_pkg=false
            for avoid_pkg in "${PROXMOX_CORE_PACKAGES_TO_AVOID[@]}"; do
                if [[ "$pkg_to_check" == "$avoid_pkg" ]]; then
                    log_info "Skipping installation of '$pkg_to_check' as it is a Proxmox core package."
                    skip_pkg=true
                    break
                fi
            done
            if ! $skip_pkg; then
                temp_install_list+=("$pkg_to_check")
            fi
        done
        final_packages_to_install_online=("${temp_install_list[@]}")
    fi

    if [[ ${#final_packages_to_install_online[@]} -eq 0 ]]; then
        show_success "No packages require online installation after filtering."
        return 0
    else
        # If we reach here, final_packages_to_install_online is not empty.
        show_progress "Attempting online installation of (filtered): ${final_packages_to_install_online[*]} with options: ${apt_install_opts[*]}"
        if DEBIAN_FRONTEND=noninteractive apt-get install "${apt_install_opts[@]}" "${final_packages_to_install_online[@]}"; then
            show_success "Successfully installed/updated packages (online): ${final_packages_to_install_online[*]}"
            log_debug "Successfully installed/updated packages (online): ${final_packages_to_install_online[*]}"
            return 0 # Critical: return 0 if online install succeeds
        else
            # Online installation failed for the filtered list
            show_error "Failed to install some packages online: ${final_packages_to_install_online[*]}"
            log_debug "ERROR: Online apt-get install failed for: ${final_packages_to_install_online[*]}"
            # Fall through to local DEBS_DIR attempt
        fi
        
        show_progress "Attempting to install from local DEBS_DIR: $DEBS_DIR..."

        local packages_to_install_locally=()
        if [[ "${PROXMOX_DETECTED:-false}" == "true" ]]; then
            log_debug "Proxmox detected. Filtering core Proxmox packages from local .deb installation attempt."
            for pkg_to_check in "${missing_packages[@]}"; do
                local is_core_proxmox_pkg=false
                for avoid_pkg_name in "${PROXMOX_CORE_PACKAGES_TO_AVOID[@]}"; do
                    if [[ "$pkg_to_check" == "$avoid_pkg_name" ]]; then
                        is_core_proxmox_pkg=true
                        log_debug "Skipping local install of core Proxmox package: $pkg_to_check (Proxmox environment)"
                        break
                    fi
                done
                if ! $is_core_proxmox_pkg; then
                    packages_to_install_locally+=("$pkg_to_check")
                fi
            done
            if [[ ${#packages_to_install_locally[@]} -eq 0 && ${#missing_packages[@]} -gt 0 ]]; then
                 log_debug "All remaining missing packages were core Proxmox packages, nothing to install locally."
                 # Potentially return here or let it proceed to the loop which will find no .debs for these
            fi
        else
            packages_to_install_locally=("${missing_packages[@]}")
        fi

        # Proceed with packages_to_install_locally instead of missing_packages for the .deb search
        if [[ ${#packages_to_install_locally[@]} -eq 0 ]]; then
            log_debug "No packages left to attempt installing from local DEBS_DIR."
            # This was an 'else' from apt-get failing, so we should return failure if nothing was installed locally
            # However, the original script has a return 1 further down if debs_installed_count is 0.
            # Let's ensure the loop below uses packages_to_install_locally
        fi

        if [[ ${#packages_to_install_locally[@]} -gt 0 && -d "$DEBS_DIR" ]]; then
            show_progress "Attempting to install remaining packages from local DEBS_DIR: ${packages_to_install_locally[*]}"
            local debs_to_install_paths=()
            local unresolved_packages_locally=()

            for pkg_name in "${packages_to_install_locally[@]}"; do
                # Find the .deb file. This is a simple glob; might need refinement for versions.
                local deb_file
                deb_file=$(ls -1 "$DEBS_DIR/${pkg_name}"*.deb 2>/dev/null | head -n1)
                if [ -f "$deb_file" ]; then
                    log_debug "Found local .deb for $pkg_name: $deb_file"
                    debs_to_install_paths+=("$deb_file")
                else
                    log_warning "No .deb file found for $pkg_name in $DEBS_DIR. It will remain uninstalled."
                    unresolved_packages_locally+=("$pkg_name")
                fi
            done

            if [[ ${#debs_to_install_paths[@]} -gt 0 ]]; then
                show_progress "Installing the following .debs: ${debs_to_install_paths[*]}"
                # Use apt-get install for these specific .deb files to handle dependencies if possible
                if DEBIAN_FRONTEND=noninteractive apt-get install "${apt_install_opts[@]}" "${debs_to_install_paths[@]}"; then
                    show_success "Successfully installed/updated packages from local .debs: ${debs_to_install_paths[*]}"
                    log_debug "Successfully installed/updated packages from local .debs: ${debs_to_install_paths[*]}"
                else
                    show_error "Failed to install some packages from local .debs using apt-get: ${debs_to_install_paths[*]}"
                    log_debug "Falling back to dpkg -i for specific debs that apt-get might have failed on, or for remaining unresolved."
                    # We could try dpkg -i here for debs_to_install_paths if apt-get failed for them
                    # but apt-get failing usually means deeper issues dpkg -i won't solve well.
                    # For now, just log and the script will report final missing packages.
                fi
            fi
            # Update missing_packages list based on what couldn't be resolved locally
            # This is tricky because apt-get install might have installed some but not others from debs_to_install_paths
            # A full re-check is safest.
            local final_check_missing=()
            for pkg in "${missing_packages[@]}"; do # Check original full list of missing
                 if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
                    final_check_missing+=("$pkg")
                 fi
            done
            missing_packages=("${final_check_missing[@]}")

        elif [[ ${#packages_to_install_locally[@]} -gt 0 && ! -d "$DEBS_DIR" ]]; then
            log_warning "Local DEBS_DIR ($DEBS_DIR) not found. Cannot install: ${packages_to_install_locally[*]}"
        fi

        # After all attempts, report final status
        local debs_installed_count=0 # This count isn't really used effectively with current logic
        # The important thing is what's in missing_packages now.
        if [[ ${#missing_packages[@]} -gt 0 ]]; then
            show_error "Still missing packages after all installation attempts: ${missing_packages[*]}"
            log_debug "ERROR: Still missing after all attempts: ${missing_packages[*]}"
            return 1
        else
            show_success "All packages installed successfully after all attempts."
            log_debug "All packages installed successfully after all attempts."
            return 0
        fi
    fi
}

#-------------------------------------------------------------------------------
# Offline Cache Preparation Function (for the "Build" Machine)
#-------------------------------------------------------------------------------
populate_offline_cache() {
    local packages_to_download=("$@")
    if [[ ${#packages_to_download[@]} -eq 0 ]]; then
        log_debug "populate_offline_cache called with no packages."
        return 0
    fi

    show_header "POPULATING OFFLINE CACHE"
    log_debug "Populating offline cache with: ${packages_to_download[*]}"

    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        show_error "No internet connection. Cannot download packages for offline cache."
        return 1
    fi

    show_progress "Updating package lists before download..."
    if ! apt-get update -y; then
        show_warning "apt-get update failed. Download might fetch outdated packages or fail."
    fi

    mkdir -p "$DEBS_DIR"
    
    show_progress "Downloading packages to $DEBS_DIR: ${packages_to_download[*]}"
    if (cd "$DEBS_DIR" && DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only "${packages_to_download[@]}"); then
        show_success "Successfully downloaded packages and dependencies to $DEBS_DIR."
        log_debug "Successfully downloaded packages to $DEBS_DIR: ${packages_to_download[*]}"
        return 0
    else
        show_error "Failed to download some packages to $DEBS_DIR."
        log_debug "ERROR: apt-get --download-only failed for: ${packages_to_download[*]}"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Convenience function for ensuring essential base packages
#-------------------------------------------------------------------------------
ensure_essential_packages() {
    show_header "ENSURING ESSENTIAL BASE PACKAGES"
    log_debug "Ensuring essential base packages are installed."

    local unique_base_packages_map=()
    for pkg in "${BASE_PACKAGES[@]}"; do
        unique_base_packages_map["$pkg"]=1
    done
    local unique_base_packages=("${!unique_base_packages_map[@]}")

    if ensure_packages_installed "${unique_base_packages[@]}"; then
        show_success "Essential base packages are installed."
        log_debug "Essential base packages check complete."
        return 0
    else
        show_error "Failed to install some essential base packages."
        log_debug "ERROR: Failed to install some essential base packages."
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Function to prepare all installer packages using the predefined package lists
#-------------------------------------------------------------------------------
prepare_installer_debs() {
    log_debug "Main: Preparing installer debs"
    show_header "PREPARING INSTALLER DEB CACHE"
    
    if [[ "${run_from_ram:-false}" == true ]]; then
        log_debug "Running from RAM, skipping package preparation for DEBS_DIR."
        return 0
    fi
    
    local package_count=0
    local debs_dir_status=""
    
    if [[ ! -d "$DEBS_DIR" ]] || [[ -z "$(ls -A "$DEBS_DIR" 2>/dev/null)" ]]; then
        printf "The local 'debs' directory (%s) is empty.\n" "$DEBS_DIR"
        if prompt_yes_no "Would you like to download required packages for a potential offline installation?"; then
            if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                show_error "No internet connection. Cannot download packages."
                show_warning "Please run network setup or populate the 'debs' folder manually."
                return 1
            fi
            
            show_progress "Downloading packages for offline installation to $DEBS_DIR..."
            mkdir -p "$DEBS_DIR"
            
            local all_packages=(
                "${BASE_PACKAGES[@]}"
                "${ZFS_PACKAGES[@]}"
                "${YUBIKEY_PACKAGES[@]}"
            )
            
            local unique_packages_map=()
            for pkg in "${all_packages[@]}"; do unique_packages_map["$pkg"]=1; done
            all_packages=("${!unique_packages_map[@]}")
            
            log_debug "Preparing ${#all_packages[@]} packages: ${all_packages[*]}"
            if ! populate_offline_cache "${all_packages[@]}"; then
                show_error "Failed to download packages. Check logs for details."
                return 1
            fi
            show_success "Packages downloaded successfully to '$DEBS_DIR' directory."
            debs_dir_status="newly downloaded"
        else
            show_warning "Skipping package download. For offline use, ensure '$DEBS_DIR' directory is populated."
            return 0 
        fi
    else
        show_progress "Local '$DEBS_DIR' directory already contains packages."
        debs_dir_status="existing"
    fi
    
    if [[ -d "$DEBS_DIR" ]]; then
        package_count=$(find "$DEBS_DIR" -name "*.deb" -type f 2>/dev/null | wc -l)
    fi

    printf "\n===== Package Preparation Summary =====\n"
    if [[ "$debs_dir_status" == "newly downloaded" ]]; then
        printf "Downloaded %s packages to: %s\n" "$package_count" "$DEBS_DIR"
    elif [[ "$debs_dir_status" == "existing" ]]; then
        printf "Using %s existing packages in: %s\n" "$package_count" "$DEBS_DIR"
    else
        printf "Package status for %s is undetermined.\n" "$DEBS_DIR"
    fi
    printf "For use on an air-gapped machine, ensure you copy the ENTIRE installer directory\n"
    printf "(including the '%s' folder) to your installation media.\n" "$(basename "$DEBS_DIR")"
    printf "====================================\n\n"
    
    log_debug "Package preparation step complete. Status: $debs_dir_status, Count: $package_count"
    return 0
}

# Execute if run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        prepare_installer_debs
    else
        "$@"
    fi
fi

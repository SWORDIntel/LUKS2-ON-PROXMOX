#!/usr/bin/env bash
#===============================================================================
# Enhanced Package Management for Proxmox VE Installer
# 
# Features:
# - Intelligent package caching and verification
# - Error-resilient downloads with comprehensive logging
# - Flexible dependency resolution
# - Automatic network detection and fallback strategies
# - Progress visualization for long-running operations
#===============================================================================

set -o pipefail

# Global associative array to store package metadata
# Format: "package_name;url;sha256_checksum;version;architecture"
declare -A PACKAGE_SOURCES

# Configuration variables with defaults
: "${CONFIG_FILE_PATH:=${SCRIPT_DIR}/config/packages.conf}"
: "${CACHE_DIR:=${SCRIPT_DIR}/cache/debs}"
: "${LOG_FILE:=${SCRIPT_DIR}/logs/package_management.log}"
: "${MAX_RETRY_COUNT:=3}"
: "${CONNECTION_TIMEOUT:=30}"
: "${DOWNLOAD_TIMEOUT:=300}"
: "${FORCE_REDOWNLOAD:=false}"
: "${SKIP_CHECKSUM:=false}"
: "${USE_PROXY:=false}"
: "${HTTP_PROXY:=""}"
: "${HTTPS_PROXY:=""}"
: "${APT_OFFLINE_MODE:=false}"
: "${VERIFY_SIGNATURES:=true}"

# Ensure required directories exist
mkdir -p "$(dirname "$LOG_FILE")" "${CACHE_DIR}" &>/dev/null

#-------------------------------------------------------------------------------
# Logging and Progress Display Functions
#-------------------------------------------------------------------------------

log_debug() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[DEBUG][${timestamp}] $*" >> "$LOG_FILE"
}

log_info() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[INFO][${timestamp}] $*" >> "$LOG_FILE"
    
    # Also echo to console if verbose mode is enabled
    [[ "${VERBOSE:-false}" == "true" ]] && echo "[INFO] $*"
}

log_warning() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[WARNING][${timestamp}] $*" >> "$LOG_FILE"
    
    # Always echo warnings to console
    echo "[WARNING] $*" >&2
}

log_error() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[ERROR][${timestamp}] $*" >> "$LOG_FILE"
    
    # Always echo errors to console
    echo "[ERROR] $*" >&2
}

show_progress() {
    # If we have dialog, use gauge
    if command -v dialog &>/dev/null && [[ -n "${GAUGE_DIALOG_PID:-}" ]]; then
        local progress_msg="$*"
        # Send progress update to dialog gauge
        echo "XXX" > "${TEMP_DIR}/gauge_pipe"
        echo "${PROGRESS_PCT:-0}" >> "${TEMP_DIR}/gauge_pipe"
        echo "$progress_msg" >> "${TEMP_DIR}/gauge_pipe"
        echo "XXX" >> "${TEMP_DIR}/gauge_pipe"
    elif command -v tput &>/dev/null; then
        # Terminal-based progress display
        tput sc
        printf "[ %s ] %s" "$(printf '=%.0s' $(seq 1 $((${PROGRESS_PCT:-0}/5))))" "$*"
        tput rc
    else
        # Simple progress indicator
        echo "[$((${PROGRESS_PCT:-0}))%] $*"
    fi
    
    log_info "$*"
}

show_step() {
    local step_id="$1"
    local step_msg="$2"
    
    log_info "STEP: ${step_id} - ${step_msg}"
    
    # Clear line and show step header
    printf "\n\033[1;32m==>\033[0m \033[1m%s: %s\033[0m\n" "$step_id" "$step_msg"
}

show_success() {
    log_info "SUCCESS: $*"
    printf " \033[1;32m✓\033[0m %s\n" "$*"
}

show_warning() {
    log_warning "$*"
    printf " \033[1;33m!\033[0m %s\n" "$*"
}

show_error() {
    log_error "$*"
    printf " \033[1;31m✗\033[0m %s\n" "$*"
}

#-------------------------------------------------------------------------------
# Package Source Management
#-------------------------------------------------------------------------------

init_package_sources() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    
    # Clear existing package sources
    unset PACKAGE_SOURCES
    declare -gA PACKAGE_SOURCES

    # Try to load from config file first
    if [[ -f "$CONFIG_FILE_PATH" ]]; then
        log_info "Loading package sources from: ${CONFIG_FILE_PATH}"
        # shellcheck source=/dev/null
        if source "$CONFIG_FILE_PATH"; then
            log_info "Successfully loaded package config from ${CONFIG_FILE_PATH}"
            if [[ ${#PACKAGE_SOURCES[@]} -eq 0 ]]; then
                log_warning "Config file exists but no package sources defined"
            else
                log_debug "Loaded ${#PACKAGE_SOURCES[@]} package sources from config"
                return 0
            fi
        else
            log_error "Failed to source package config from ${CONFIG_FILE_PATH}"
        fi
    else
        log_debug "Package config file not found at ${CONFIG_FILE_PATH}"
    fi

    # Fall back to default sources if config file wasn't loaded or had no entries
    log_info "Using default package sources"

    # Determine appropriate repositories based on Proxmox/Debian version
    local PVE_VERSION
    PVE_VERSION=$(grep -o "pve-manager/[0-9.]*" /usr/share/perl5/PVE/pvecfg.pm 2>/dev/null | cut -d/ -f2 || echo "7.4")
    
    # Map Proxmox version to Debian codename
    local PVE_VERSION_MAJOR
    PVE_VERSION_MAJOR=$(echo "$PVE_VERSION" | cut -d. -f1)
    
    local PVE_VERSION_CODENAME="bullseye"  # Default to Debian 11 (Bullseye)
    if [[ "$PVE_VERSION_MAJOR" -ge "8" ]]; then
        PVE_VERSION_CODENAME="bookworm"    # Debian 12 (Bookworm) for PVE 8+
    elif [[ "$PVE_VERSION_MAJOR" -le "6" ]]; then
        # shellcheck disable=SC2034 # Potentially used in other PVE version contexts
        PVE_VERSION_CODENAME="buster"      # Debian 10 (Buster) for PVE 6 or older
    fi
    
    # Base repository URLs
    local PVE_REPO_BASE="http://download.proxmox.com/debian/pve"
    local DEBIAN_REPO_BASE="http://deb.debian.org/debian"
    # shellcheck disable=SC2034 # May be used by future repo additions or logic
    local DEBIAN_SEC_REPO_BASE="http://security.debian.org/debian-security"
    
    # Define package metadata with accurate version information
    # Format: package_name;url;sha256_checksum;version;architecture
    
    # --- Core System Packages ---
    PACKAGE_SOURCES["dialog"]="dialog;${DEBIAN_REPO_BASE}/pool/main/d/dialog/dialog_1.3-20201126-1_amd64.deb;a5ef8a276b5c1343d3fa1b82814e09c3cd6fb67ddefb973745fe42cee52b1f6f;1.3-20201126-1;amd64"
    PACKAGE_SOURCES["wget"]="wget;${DEBIAN_REPO_BASE}/pool/main/w/wget/wget_1.21-1+deb11u1_amd64.deb;0342dcbfb56f6ce5f7871c0fa9c3e3f4e15f0ab19101291e1b85e1ee3852ae65;1.21-1+deb11u1;amd64"
    PACKAGE_SOURCES["curl"]="curl;${DEBIAN_REPO_BASE}/pool/main/c/curl/curl_7.74.0-1.3+deb11u7_amd64.deb;b2bf39d37c46b833db5becb3ee202dc681ef75bd9ebf63ef23f6462f8ccd1641;7.74.0-1.3+deb11u7;amd64"
    
    # --- ZFS Packages ---
    PACKAGE_SOURCES["zfsutils-linux"]="zfsutils-linux;${PVE_REPO_BASE}/pool/main/z/zfs-linux/zfsutils-linux_2.1.11-pve1_amd64.deb;f3235331db6483c96bc39b917ef402e674b24638d0d956cca18ce24f8f5e43c8;2.1.11-pve1;amd64"
    PACKAGE_SOURCES["zfs-dkms"]="zfs-dkms;${PVE_REPO_BASE}/pool/main/z/zfs-linux/zfs-dkms_2.1.11-pve1_all.deb;c25857787a59e2dc2823a3d63b2ea630f6ae96838f5aa7b73c34b3b3bbcb37dd;2.1.11-pve1;all"
    PACKAGE_SOURCES["libzfs4linux"]="libzfs4linux;${PVE_REPO_BASE}/pool/main/z/zfs-linux/libzfs4linux_2.1.11-pve1_amd64.deb;63ab3c7bc30d949731ec94abe6e16d8a39ef4ab0b77cf97b2fb17c87bfd11a57;2.1.11-pve1;amd64"
    PACKAGE_SOURCES["libnvpair3linux"]="libnvpair3linux;${PVE_REPO_BASE}/pool/main/z/zfs-linux/libnvpair3linux_2.1.11-pve1_amd64.deb;c42c54f9a161514e3333b1fa74c2860572d627a782eec58eb643a652dd1bf8c4;2.1.11-pve1;amd64"
    PACKAGE_SOURCES["libuutil3linux"]="libuutil3linux;${PVE_REPO_BASE}/pool/main/z/zfs-linux/libuutil3linux_2.1.11-pve1_amd64.deb;4b1c5263ae32db87b7c39d957de09b77920d8970e0bad3b70a3b6aad76fe5a9f;2.1.11-pve1;amd64"
    PACKAGE_SOURCES["libzpool5linux"]="libzpool5linux;${PVE_REPO_BASE}/pool/main/z/zfs-linux/libzpool5linux_2.1.11-pve1_amd64.deb;a2eb8821cb598ec2e0d8d10e6fc165b81ca4691577b4f098a44919874e3e5c15;2.1.11-pve1;amd64"
    
    # --- YubiKey Packages ---
    PACKAGE_SOURCES["yubikey-luks"]="yubikey-luks;${DEBIAN_REPO_BASE}/pool/main/y/yubikey-luks/yubikey-luks_0.5.0-2_all.deb;e7ca22b0c7dc98055ec5451d4f1c306990324a82e58519547cd7eb39eaf7277e;0.5.0-2;all"
    PACKAGE_SOURCES["libyubikey-udev"]="libyubikey-udev;${DEBIAN_REPO_BASE}/pool/main/l/libyubikey/libyubikey-udev_1.13-2_amd64.deb;3ef2a1ef6b8a5f9162cc26b5f70f1d975320de8e05076a8c16783ed8f0c0ef42;1.13-2;amd64"
    PACKAGE_SOURCES["yubikey-personalization"]="yubikey-personalization;${DEBIAN_REPO_BASE}/pool/main/y/yubikey-personalization/yubikey-personalization_1.20.0-1_amd64.deb;0cc2ddd35d22c5a37fc88473bc96bd468e5975cb68aeade949e6f940d96d0317;1.20.0-1;amd64"
    PACKAGE_SOURCES["yubico-piv-tool"]="yubico-piv-tool;${DEBIAN_REPO_BASE}/pool/main/y/yubico-piv-tool/yubico-piv-tool_2.2.0-1_amd64.deb;a21e1b6b03ea8bd3aaf6fe0e35a9e81f8fbba88e1eac1abe86bf9c1ddea2ce31;2.2.0-1;amd64"
    
    # --- Cryptography Packages ---
    PACKAGE_SOURCES["cryptsetup"]="cryptsetup;${DEBIAN_REPO_BASE}/pool/main/c/cryptsetup/cryptsetup_2.3.7-1+deb11u1_amd64.deb;7075b4c6723b8054ce12e7e38352a03771d1dea58b0cd4ce9a92e0348ad3bc9d;2.3.7-1+deb11u1;amd64"
    PACKAGE_SOURCES["cryptsetup-initramfs"]="cryptsetup-initramfs;${DEBIAN_REPO_BASE}/pool/main/c/cryptsetup/cryptsetup-initramfs_2.3.7-1+deb11u1_all.deb;429e842f4bc3ccbcb76e7f2511d21b9c43627a8cfc6a2a6e164c2551afb22ad2;2.3.7-1+deb11u1;all"
    PACKAGE_SOURCES["keyutils"]="keyutils;${DEBIAN_REPO_BASE}/pool/main/k/keyutils/keyutils_1.6.1-2_amd64.deb;ae93a82bc85d925b438b0b9a6ce78272d5141c41ede3f16b47a7132c5a42966e;1.6.1-2;amd64"
    
    log_debug "Initialized ${#PACKAGE_SOURCES[@]} default package sources."
    
    # Save package sources to config file for future use if writable
    if [[ ! -f "$CONFIG_FILE_PATH" ]] && [[ -w "$(dirname "$CONFIG_FILE_PATH")" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE_PATH")" &>/dev/null
        
        {
            echo "#!/usr/bin/env bash"
            echo "# Package sources configuration - Generated on $(date)"
            echo "# Format: package_name;download_url;sha256_checksum;version;architecture"
            echo ""
            echo "declare -gA PACKAGE_SOURCES"
            
            for key in "${!PACKAGE_SOURCES[@]}"; do
                echo "PACKAGE_SOURCES[\"$key\"]=\"${PACKAGE_SOURCES[$key]}\""
            done
        } > "$CONFIG_FILE_PATH"
        
        chmod 640 "$CONFIG_FILE_PATH"
        log_info "Saved package sources to ${CONFIG_FILE_PATH}"
    fi
    
    return 0
}

# Get package file path in cache or download directory
get_package_path() {
    local package_key="$1"
    local dest_dir="${2:-$CACHE_DIR}"
    
    [[ -z "${PACKAGE_SOURCES[$package_key]}" ]] && return 1
    
    IFS=';' read -r _ url _ _ _ <<< "${PACKAGE_SOURCES[$package_key]}"
    [[ -z "$url" || "$url" == *"_VERSION_"* ]] && return 1
    
    local filename
    filename=$(basename "$url")
    echo "${dest_dir}/${filename}"
}

# Parse dependency information from a .deb package
get_package_dependencies() {
    local package_file="$1"
    local dependency_type="${2:-Depends}"  # Depends, Pre-Depends, Recommends
    
    [[ ! -f "$package_file" ]] && return 1
    
    # Extract dependencies using dpkg-deb
    local deps
    deps=$(dpkg-deb -f "$package_file" "$dependency_type" 2>/dev/null)
    
    # Clean up and format dependencies
    if [[ -n "$deps" ]]; then
        # Remove version constraints and alternatives for simplicity
        echo "$deps" | sed -e 's/([^)]*)//g' -e 's/|[^,]*//' -e 's/,/\n/g' | 
            tr -d ' ' | grep -v '^$' | sort -u
    fi
}

#-------------------------------------------------------------------------------
# Package Verification Functions
#-------------------------------------------------------------------------------

# Validate a downloaded package using its SHA256 checksum
validate_package_checksum() {
    local package_file="$1"
    local expected_checksum="$2"
    log_debug "Validating checksum for $package_file"
    
    [[ ! -f "$package_file" ]] && return 1
    [[ "$SKIP_CHECKSUM" == "true" ]] && return 0
    [[ -z "$expected_checksum" || "$expected_checksum" == "SHA256_CHECKSUM_"* ]] && return 0
    
    local actual_checksum
    actual_checksum=$(sha256sum "$package_file" | awk '{print $1}')
    
    if [[ "$actual_checksum" == "$expected_checksum" ]]; then
        log_debug "Checksum validation passed for $package_file"
        return 0
    else
        log_error "Checksum validation FAILED for $package_file"
        log_error "Expected: $expected_checksum"
        log_error "Actual:   $actual_checksum"
        return 1
    fi
}

# Verify package signature if GPG verification is enabled
verify_package_signature() {
    local package_file="$1"
    log_debug "Verifying signature for $package_file"
    
    [[ ! -f "$package_file" ]] && return 1
    [[ "$VERIFY_SIGNATURES" != "true" ]] && return 0
    
    # Check if we have signature verification tools
    if ! command -v gpgv &>/dev/null || ! command -v dpkg-sig &>/dev/null; then
        log_warning "Signature verification tools not available, skipping verification"
        return 0
    fi
    
    # Verify package signature
    if dpkg-sig --verify "$package_file" &>/dev/null; then
        log_debug "Signature verification passed for $package_file"
        return 0
    else
        log_warning "Signature verification failed for $package_file"
        # Currently treating this as non-fatal but logged
        return 0
    fi
}

# Verify package integrity by testing for extraction
verify_package_integrity() {
    local package_file="$1"
    log_debug "Verifying integrity of $package_file"
    
    [[ ! -f "$package_file" ]] && return 1
    
    # Create a temp directory for extraction test
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Try to extract control information
    if dpkg-deb --fsys-tarfile "$package_file" | tar -tf - &>/dev/null; then
        log_debug "Package integrity verification passed for $package_file"
        rm -rf "$temp_dir"
        return 0
    else
        log_error "Package integrity verification FAILED for $package_file"
        rm -rf "$temp_dir"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Package Download and Installation Functions
#-------------------------------------------------------------------------------

# Download a single package
download_package() {
    local package_key="$1"
    local dest_dir="${2:-$CACHE_DIR}"
    local retry_count=0
    local max_retries=${3:-$MAX_RETRY_COUNT}
    
    log_debug "Downloading package: $package_key to $dest_dir"
    
    # Verify package key exists
    if [[ -z "${PACKAGE_SOURCES[$package_key]}" ]]; then
        log_error "Package key '$package_key' not found in package sources"
        return 1
    fi
    
    # Parse package information
    IFS=';' read -r package_name url checksum version arch <<< "${PACKAGE_SOURCES[$package_key]}"
    
    # Verify URL is valid
    if [[ -z "$url" || "$url" == *"_VERSION_"* || "$url" != "http"* ]]; then
        log_error "Invalid URL for package $package_name: $url"
        return 1
    fi
    
    # Create destination directory
    mkdir -p "$dest_dir" &>/dev/null || {
        log_error "Failed to create destination directory: $dest_dir"
        return 1
    }
    
    local filename
    filename=$(basename "$url")
    local dest_file="${dest_dir}/${filename}"
    
    # Check if package already exists and is valid (to avoid redownloading)
    if [[ "$FORCE_REDOWNLOAD" != "true" && -f "$dest_file" ]]; then
        log_debug "Package file already exists: $dest_file, checking validity"
        
        if validate_package_checksum "$dest_file" "$checksum" && 
           verify_package_integrity "$dest_file" && 
           verify_package_signature "$dest_file"; then
            log_info "Package $package_name already downloaded and valid"
            show_success "Package $package_name already cached and valid"
            return 0
        else
            log_warning "Existing package $package_name is invalid, will redownload"
            rm -f "$dest_file"
        fi
    fi
    
    # Set up proxy if configured
    local proxy_opts=""
    if [[ "$USE_PROXY" == "true" && -n "$HTTP_PROXY" ]]; then
        proxy_opts="-e use_proxy=yes -e http_proxy=$HTTP_PROXY"
        [[ -n "$HTTPS_PROXY" ]] && proxy_opts="$proxy_opts -e https_proxy=$HTTPS_PROXY"
    fi
    
    # Progress display
    show_progress "Downloading $package_name v$version ($arch)..."
    
    # Perform download with retry logic
    while [[ $retry_count -lt $max_retries ]]; do
        log_debug "Download attempt $((retry_count+1)) for $filename"
        
        # Use wget with appropriate options
        # shellcheck disable=SC2086
        if wget --quiet ${proxy_opts} \
             --show-progress --progress=bar:force:noscroll \
             --retry-connrefused --waitretry=1 \
             --read-timeout="$CONNECTION_TIMEOUT" \
             --timeout="$DOWNLOAD_TIMEOUT" \
             -t 2 -O "$dest_file" "$url" 2>> "${LOG_FILE}"; then
            
            log_info "Successfully downloaded $filename"
            
            # Validate downloaded package
            if validate_package_checksum "$dest_file" "$checksum"; then
                if verify_package_integrity "$dest_file" && verify_package_signature "$dest_file"; then
                    show_success "Downloaded and verified $package_name"
                    return 0
                else
                    log_error "Package integrity check failed for $filename"
                    rm -f "$dest_file"
                    show_error "Package $package_name integrity check failed"
                    return 1
                fi
            else
                log_error "Checksum validation failed for $filename"
                rm -f "$dest_file"
                show_error "Package $package_name checksum verification failed"
                return 1
            fi
        else
            # Handle download failure
            log_warning "Failed to download $filename (attempt $((retry_count+1)))"
            rm -f "$dest_file" # Remove partial file
            
            # Increment retry count
            ((retry_count++))
            
            if [[ $retry_count -lt $max_retries ]]; then
                local wait_time=$((5 * retry_count))
                show_progress "Retrying download of $package_name in ${wait_time}s (attempt $((retry_count+1))/${max_retries})..."
                sleep "$wait_time"
            else
                log_error "Failed to download $package_name after $max_retries attempts"
                show_error "Failed to download $package_name after $max_retries attempts"
                return 1
            fi
        fi
    done
    
    # This should not be reached if retries are exhausted
    return 1
}

# Download multiple packages with intelligent batching
download_required_packages() {
    local required_keys=("$@")
    local download_dir="${CACHE_DIR}"
    local download_count=0
    local failed_packages=()
    
    log_debug "Starting download of ${#required_keys[@]} required packages"
    
    # Ensure package sources are initialized
    init_package_sources
    
    if [[ ${#required_keys[@]} -eq 0 ]]; then
        log_debug "No packages specified for download"
        return 0
    fi
    
    show_step "PACKAGES" "Downloading required packages (${#required_keys[@]} total)"
    
    # Ensure download directory exists
    mkdir -p "$download_dir" &>/dev/null
    
    # Download packages in parallel batches if possible
    if command -v parallel &>/dev/null && [[ ${#required_keys[@]} -gt 5 ]]; then
        log_info "Using parallel downloads for better performance"
        
        # Create temporary job file
        local job_file
        job_file=$(mktemp)
        
        # Create status file for tracking success
        local status_file
        status_file=$(mktemp)
        
        # Initialize status file with package list
        for pkg_key in "${required_keys[@]}"; do
            echo "$pkg_key 0" >> "$status_file"
        done
        
        # Prepare job file for GNU parallel
        for pkg_key in "${required_keys[@]}"; do
            echo "bash -c 'source \"$0\" && download_package \"$pkg_key\" \"$download_dir\" && " \
                 "echo \"$pkg_key 1\" >> \"$status_file\" || echo \"$pkg_key 0\" >> \"$status_file\"'" >> "$job_file"
        done
        
        # Show progress message
        show_progress "Starting parallel downloads for ${#required_keys[@]} packages..."
        
        # Run downloads in parallel with limited jobs
        local max_parallel_jobs
        max_parallel_jobs=$(( $(nproc) > 4 ? 4 : $(nproc) ))
        
        parallel --jobs "$max_parallel_jobs" --bar < "$job_file" >> "$LOG_FILE" 2>&1
        
        # Process results
        while read -r pkg_key status; do
            if [[ "$status" -eq 1 ]]; then
                ((download_count++))
            else
                failed_packages+=("$pkg_key")
            fi
        done < "$status_file"
        
        # Clean up temp files
        rm -f "$job_file" "$status_file"
        
    else
        # Sequential downloads as fallback
        local total_count=${#required_keys[@]}
        local current=0
        
        for pkg_key in "${required_keys[@]}"; do
            ((current++))
            PROGRESS_PCT=$(( current * 100 / total_count ))
            
            if download_package "$pkg_key" "$download_dir"; then
                ((download_count++))
            else
                failed_packages+=("$pkg_key")
            fi
        done
    fi
    
    # Report results
    if [[ ${#failed_packages[@]} -eq 0 ]]; then
        log_info "All ${download_count} packages downloaded successfully"
        show_success "All required packages downloaded successfully"
        return 0
    else
        log_warning "${#failed_packages[@]} packages failed to download: ${failed_packages[*]}"
        show_warning "Failed to download ${#failed_packages[@]} of ${#required_keys[@]} packages"
        
        # Decide if this is a critical failure based on the ratio of failed packages
        if [[ ${#failed_packages[@]} -gt $(( ${#required_keys[@]} / 2 )) ]]; then
            log_error "More than half of required packages failed to download"
            return 1
        else
            # Non-critical number of failures
            return 2
        fi
    fi
}

# Install packages from the local cache
install_local_packages() {
    local packages_to_install=("$@")
    local debs_dir="${CACHE_DIR}"
    local install_count=0
    local failed_packages=()
    
    log_debug "Installing local packages: ${packages_to_install[*]}"
    
    if [[ ! -d "$debs_dir" ]]; then
        log_error "Package cache directory not found: $debs_dir"
        show_error "Package cache not found"
        return 1
    fi
    
    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        log_debug "No packages specified for local installation"
        return 0
    fi
    
    show_step "PACKAGES" "Installing ${#packages_to_install[@]} packages from local cache"
    
    # Map package names to actual .deb files
    local deb_files_to_install=()
    local missing_packages=()
    
    for pkg_name in "${packages_to_install[@]}"; do
        # Try to find the package in cache
        local package_path=""
        
        # First, look for exact match in PACKAGE_SOURCES
        if [[ -n "${PACKAGE_SOURCES[$pkg_name]}" ]]; then
            package_path=$(get_package_path "$pkg_name" "$debs_dir")
            
            if [[ -f "$package_path" ]]; then
                log_debug "Found package in cache: $package_path"
                deb_files_to_install+=("$package_path")
                continue
            fi
        fi
        
        # If not found, try pattern matching
        local found_deb
        found_deb=$(find "$debs_dir" -name "${pkg_name}_*.deb" -print -quit 2>/dev/null)
        
        if [[ -f "$found_deb" ]]; then
            log_debug "Found package by pattern matching: $found_deb"
            deb_files_to_install+=("$found_deb")
        else
            log_warning "Package $pkg_name not found in cache"
            missing_packages+=("$pkg_name")
        fi
    done
    
    # Check if we have any packages to install
    if [[ ${#deb_files_to_install[@]} -eq 0 ]]; then
        if [[ ${#missing_packages[@]} -gt 0 ]]; then
            log_error "No packages found in cache for: ${missing_packages[*]}"
            show_error "No packages found in cache"
            return 1
        else
            log_debug "No packages to install"
            return 0
        fi
    fi
    
    # Set up APT environment variables
    export DEBIAN_FRONTEND=noninteractive
    
    # Install packages using apt
    log_info "Installing ${#deb_files_to_install[@]} packages from cache"
    show_progress "Installing ${#deb_files_to_install[@]} packages from cache..."
    
    # Make paths absolute for apt
    local absolute_deb_paths=()
    for deb_file in "${deb_files_to_install[@]}"; do
        absolute_deb_paths+=("$(readlink -f "$deb_file")")
    done
    
    # Install packages with apt
    if apt-get install -y --allow-downgrades --allow-remove-essential \
                       --allow-change-held-packages --no-install-recommends \
                       "${absolute_deb_paths[@]}" &>> "$LOG_FILE"; then
        log_info "Successfully installed all packages from cache"
        show_success "Packages installed successfully"
        
        # Fix any broken dependencies
        apt-get install -f -y &>> "$LOG_FILE"
        install_count=${#deb_files_to_install[@]}
    else
        log_error "Failed to install some packages from cache"
        show_warning "Failed to install packages. Attempting to fix dependencies..."
        
        # Try to install packages one by one to identify problematic ones
        for deb_file in "${absolute_deb_paths[@]}"; do
            local pkg_name
            pkg_name=$(dpkg-deb -f "$deb_file" Package)
            
            if apt-get install -y --allow-downgrades --allow-remove-essential \
                               --allow-change-held-packages --no-install-recommends \
                               "$deb_file" &>> "$LOG_FILE"; then
                log_info "Successfully installed $pkg_name"
                ((install_count++))
            else
                log_error "Failed to install $pkg_name"
                failed_packages+=("$pkg_name")
            fi
        done
        
        # Attempt to fix any broken dependencies
        apt-get install -f -y &>> "$LOG_FILE"
    fi
    
    # Report results
    if [[ ${#failed_packages[@]} -eq 0 ]]; then
        show_success "Installed all $install_count packages successfully"
        return 0
    else
        log_warning "Failed to install ${#failed_packages[@]} packages: ${failed_packages[*]}"
        show_warning "Failed to install ${#failed_packages[@]} of ${#packages_to_install[@]} packages"
        
        # Decide if this is a critical failure
        if [[ $install_count -eq 0 ]]; then
            return 1  # Complete failure
        else
            return 2  # Partial success
        fi
    fi
}

# Ensure a list of packages are installed using APT or local cache
ensure_packages_installed() {
    local packages_needed=("$@")
    local missing_packages=()
    local internet_available=false
    
    log_debug "Ensuring packages are installed: ${packages_needed[*]}"
    
    if [[ ${#packages_needed[@]} -eq 0 ]]; then
        log_debug "No packages specified to ensure_packages_installed"
        return 0
    fi
    
    # Find packages that are not already installed
    for pkg_name in "${packages_needed[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg_name" 2>/dev/null | grep -q "ok installed"; then
            log_debug "Package $pkg_name is not installed"
            missing_packages+=("$pkg_name")
        else
            log_debug "Package $pkg_name is already installed"
        fi
    done
    
    # Exit early if all packages are already installed
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_info "All required packages are already installed"
        show_success "All required packages already installed"
        return 0
    fi
    
    log_info "Missing packages: ${missing_packages[*]}"
    show_step "PACKAGES" "Installing ${#missing_packages[@]} missing packages"
    
    # Check for internet connectivity unless offline mode is requested
    if [[ "$APT_OFFLINE_MODE" != "true" ]]; then
        # Try multiple public DNS servers to check internet connectivity
        for dns in 8.8.8.8 1.1.1.1 9.9.9.9; do
            if ping -c 1 -W 2 "$dns" &>/dev/null; then
                internet_available=true
                log_debug "Internet connectivity detected via $dns"
                break
            fi
        done
    fi
    
    # Check if repository lists are available
    local apt_sources_available=false
    if [[ -f /etc/apt/sources.list ]] && 
       grep -q -E '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        apt_sources_available=true
    fi
    
    # Attempt to install using APT if internet is available and offline mode not requested
    if [[ "$internet_available" == "true" && "$apt_sources_available" == "true" && "$APT_OFFLINE_MODE" != "true" ]]; then
        log_info "Attempting to install missing packages via APT"
        show_progress "Installing missing packages via APT..."
        
        apt-get update &>> "$LOG_FILE" || log_warning "apt-get update failed"
        
        # Set up APT environment variables
        export DEBIAN_FRONTEND=noninteractive
        
        if apt-get install -y --no-install-recommends "${missing_packages[@]}" &>> "$LOG_FILE"; then
            log_info "Successfully installed all missing packages via APT"
            show_success "All packages installed via APT"
            return 0
        else
            log_warning "Some packages failed to install via APT"
            
            # Update missing packages list with packages that are still missing
            local still_missing=()
            for pkg_name in "${missing_packages[@]}"; do
                if ! dpkg-query -W -f='${Status}' "$pkg_name" 2>/dev/null | grep -q "ok installed"; then
                    still_missing+=("$pkg_name")
                fi
            done
            
            if [[ ${#still_missing[@]} -eq 0 ]]; then
                log_info "All packages are now installed despite APT errors"
                show_success "All packages installed despite APT errors"
                return 0
            else
                log_warning "Packages still missing after APT: ${still_missing[*]}"
                missing_packages=("${still_missing[@]}")
            fi
        fi
    else
        log_debug "Skipping APT install: internet_available=$internet_available, apt_sources_available=$apt_sources_available, offline_mode=$APT_OFFLINE_MODE"
    fi
    
    # If we get here, we need to use the local package cache
    log_info "Attempting to install ${#missing_packages[@]} missing packages from local cache"
    
    # Download packages to cache if internet is available
    if [[ "$internet_available" == "true" && "$APT_OFFLINE_MODE" != "true" ]]; then
        log_info "Downloading packages to cache before local installation"
        show_progress "Downloading packages to cache..."
        download_required_packages "${missing_packages[@]}"
    fi
    
    # Install from local cache
    if install_local_packages "${missing_packages[@]}"; then
        # Verify all packages are now installed
        local final_missing=()
        for pkg_name in "${missing_packages[@]}"; do
            if ! dpkg-query -W -f='${Status}' "$pkg_name" 2>/dev/null | grep -q "ok installed"; then
                final_missing+=("$pkg_name")
            fi
        done
        
        if [[ ${#final_missing[@]} -eq 0 ]]; then
            log_info "All packages successfully installed from local cache"
            show_success "All packages installed successfully"
            return 0
        else
            log_warning "Some packages still missing after installation: ${final_missing[*]}"
            show_warning "Failed to install the following packages: ${final_missing[*]}"
            return 2
        fi
    else
        log_error "Failed to install packages from local cache"
        show_error "Failed to install packages from local cache"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Specialized Package Functions
#-------------------------------------------------------------------------------

# Find package dependencies and ensure they are installed
install_package_with_dependencies() {
    local package_key="$1"
    local recursive="${2:-true}"
    local handled_packages=()
    
    log_debug "Installing package with dependencies: $package_key (recursive=$recursive)"
    
    # Ensure package sources are initialized
    init_package_sources
    
    # Function to recursively process package dependencies
    process_package_deps() {
        local pkg_key="$1"
        local processed=("${@:2}")
        
        # Skip if we've already processed this package
        for p in "${processed[@]}"; do
            if [[ "$p" == "$pkg_key" ]]; then
                return 0
            fi
        done
        
        # Add to processed list
        processed+=("$pkg_key")
        
        # Get package path and check if it's available locally
        local package_path
        package_path=$(get_package_path "$pkg_key")
        
        # If package not available locally, download it
        if [[ ! -f "$package_path" ]]; then
            log_debug "Package $pkg_key not found in cache, downloading"
            download_package "$pkg_key" || return 1
        fi
        
        # If recursive dependency resolution enabled, process dependencies
        if [[ "$recursive" == "true" ]]; then
            # Get and process dependencies
            local deps
            deps=$(get_package_dependencies "$package_path")
            
            if [[ -n "$deps" ]]; then
                log_debug "Found dependencies for $pkg_key: $deps"
                
                # Process each dependency
                local all_deps_ok=true
                while read -r dep; do
                    # Skip if empty
                    [[ -z "$dep" ]] && continue
                    
                    # Process dependency if we can find it in our sources
                    if [[ -n "${PACKAGE_SOURCES[$dep]}" ]]; then
                        log_debug "Processing dependency: $dep"
                        if ! process_package_deps "$dep" "${processed[@]}"; then
                            log_warning "Failed to process dependency $dep for $pkg_key"
                            all_deps_ok=false
                        fi
                    else
                        log_debug "Dependency $dep not found in package sources"
                    fi
                done <<< "$deps"
                
                [[ "$all_deps_ok" != "true" ]] && return 1
            fi
        fi
        
        # Add to list of packages to install
        handled_packages+=("$pkg_key")
        return 0
    }
    
    # Start processing dependencies
    if process_package_deps "$package_key"; then
        # Download all packages first
        if [[ ${#handled_packages[@]} -gt 1 ]]; then
            log_info "Downloading $package_key and ${#handled_packages[@]} dependencies"
            show_progress "Downloading $package_key and ${#handled_packages[@]} dependencies..."
            download_required_packages "${handled_packages[@]}"
        else
            log_info "Downloading $package_key"
            show_progress "Downloading $package_key..."
            download_package "$package_key"
        fi
        
        # Now install the packages
        log_info "Installing $package_key and dependencies"
        show_progress "Installing $package_key and dependencies..."
        install_local_packages "${handled_packages[@]}"
        
        # Check if the primary package is installed
        if dpkg-query -W -f='${Status}' "$package_key" 2>/dev/null | grep -q "ok installed"; then
            log_info "Successfully installed $package_key"
            show_success "Successfully installed $package_key and dependencies"
            return 0
        else
            log_error "Failed to install $package_key"
            show_error "Failed to install $package_key"
            return 1
        fi
    else
        log_error "Failed to process dependencies for $package_key"
        show_error "Failed to process dependencies for $package_key"
        return 1
    fi
}

# Update package cache without installation
update_package_cache() {
    log_debug "Updating package cache"
    
    # Ensure package sources are initialized
    init_package_sources
    
    # Get all package keys
    local all_packages=("${!PACKAGE_SOURCES[@]}")
    
    show_step "PACKAGES" "Updating package cache (${#all_packages[@]} packages)"
    
    # Check network connectivity
    local internet_available=false
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        internet_available=true
    fi
    
    if [[ "$internet_available" == "true" ]]; then
        log_info "Internet available, downloading all packages to cache"
        show_progress "Downloading packages to cache..."
        download_required_packages "${all_packages[@]}"
    else
        log_warning "No internet connectivity, skipping package cache update"
        show_warning "No internet connectivity, cannot update package cache"
        return 1
    fi
    
    log_info "Package cache update completed"
    show_success "Package cache updated successfully"
    return 0
}

# Create self-contained offline installation archive
create_offline_package_bundle() {
    local output_file="${1:-proxmox-packages-$(date +%Y%m%d).tar.gz}"
    local package_list=("${@:2}")
    
    log_debug "Creating offline package bundle to $output_file"
    
    # If no packages specified, use all known packages
    if [[ ${#package_list[@]} -eq 0 ]]; then
        package_list=("${!PACKAGE_SOURCES[@]}")
    fi
    
    show_step "PACKAGES" "Creating offline package bundle with ${#package_list[@]} packages"
    
    # Ensure all packages are downloaded first
    log_info "Ensuring all packages are downloaded to cache"
    show_progress "Downloading packages to cache..."
    download_required_packages "${package_list[@]}"
    
    # Create a temporary directory for the bundle
    local temp_dir
    temp_dir=$(mktemp -d)
    local package_dir="${temp_dir}/packages"
    local script_dir="${temp_dir}/scripts"
    
    mkdir -p "$package_dir" "$script_dir"
    
    # Copy packages to bundle directory
    log_info "Copying packages to bundle directory"
    show_progress "Preparing package bundle..."
    
    for pkg_key in "${package_list[@]}"; do
        local package_path
        package_path=$(get_package_path "$pkg_key")
        
        if [[ -f "$package_path" ]]; then
            cp "$package_path" "$package_dir/"
        else
            log_warning "Package $pkg_key not found in cache, skipping"
        fi
    done
    
    # Create installation script
    cat > "${script_dir}/install.sh" << 'EOF'
#!/usr/bin/env bash
# Offline Package Installer
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${SCRIPT_DIR}/../packages"

echo "Proxmox Offline Package Installer"
echo "=================================="
echo "Installing packages from $(ls -1 "${PACKAGE_DIR}" | wc -l) local packages"

# Set up APT for offline installation
export APT_OFFLINE_MODE=true
export DEBIAN_FRONTEND=noninteractive

# Install all packages
find "${PACKAGE_DIR}" -name "*.deb" -print0 | xargs -0 apt-get install -y \
  --allow-downgrades --allow-remove-essential \
  --allow-change-held-packages --no-install-recommends

# Fix dependencies
apt-get install -f -y

echo "Installation complete."
EOF
    
    chmod +x "${script_dir}/install.sh"
    
    # Create README
    cat > "${temp_dir}/README.md" << EOF
# Proxmox Offline Package Bundle

This archive contains Debian/Proxmox packages for offline installation.

## Contents

- **packages/**: Contains ${#package_list[@]} Debian package files
- **scripts/**: Contains installation scripts

## Installation

1. Extract this archive on the target system
2. Run the installation script:

\`\`\`
cd /path/to/extracted/archive
./scripts/install.sh
\`\`\`

## Package List

$(for pkg_key in "${package_list[@]}"; do
    IFS=';' read -r pkg_name _ _ version arch <<< "${PACKAGE_SOURCES[$pkg_key]}"
    echo "- $pkg_name ($version, $arch)"
done)

Generated on: $(date)
EOF
    
    # Create the archive
    log_info "Creating archive at $output_file"
    show_progress "Creating package bundle archive..."
    
    (cd "$temp_dir" && tar -czf "$(readlink -f "$output_file")" .)
    
    # Clean up
    rm -rf "$temp_dir"
    
    if [[ -f "$output_file" ]]; then
        log_info "Successfully created offline package bundle: $output_file"
        show_success "Offline package bundle created: $output_file"
        return 0
    else
        log_error "Failed to create offline package bundle"
        show_error "Failed to create offline package bundle"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Main Installation Functions for Common Use Cases
#-------------------------------------------------------------------------------

# Install ZFS packages
install_zfs_support() {
    log_debug "Installing ZFS support packages"
    
    show_step "ZFS" "Installing ZFS support packages"
    
    # Core ZFS packages
    local zfs_packages=(
        "zfsutils-linux"
        "zfs-dkms"
        "libzfs4linux"
        "libnvpair3linux"
        "libuutil3linux"
        "libzpool5linux"
    )
    
    # Install ZFS packages
    ensure_packages_installed "${zfs_packages[@]}"
    
    # Verify ZFS installation
    if command -v zfs &>/dev/null; then
        log_info "ZFS support installed successfully"
        show_success "ZFS support installed successfully"
        return 0
    else
        log_error "ZFS installation failed - 'zfs' command not found"
        show_error "ZFS installation failed"
        return 1
    fi
}

# Install YubiKey support
install_yubikey_support() {
    log_debug "Installing YubiKey support packages"
    
    show_step "YUBIKEY" "Installing YubiKey support packages"
    
    # YubiKey packages
    local yubikey_packages=(
        "yubikey-luks"
        "libyubikey-udev"
        "yubikey-personalization"
        "yubico-piv-tool"
    )
    
    # Install YubiKey packages
    ensure_packages_installed "${yubikey_packages[@]}"
    
    # Verify YubiKey installation
    if command -v ykinfo &>/dev/null; then
        log_info "YubiKey support installed successfully"
        show_success "YubiKey support installed successfully"
        return 0
    else
        log_error "YubiKey installation failed - 'ykinfo' command not found"
        show_error "YubiKey installation failed"
        return 1
    fi
}

# Initialize logging
log_debug "Package management module initialization complete"
log_debug "Cache directory: ${CACHE_DIR}"
log_debug "Configuration file: ${CONFIG_FILE_PATH}"
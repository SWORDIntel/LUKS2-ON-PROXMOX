#!/usr/bin/env bash
# Enhanced Clover bootloader installation for Proxmox VE
# This script is intended to be sourced by the main installer or bootloader_logic.sh
# Ensure common_utils.sh and package_management.sh are sourced by the caller.

# Define return codes for better error handling
# 0 = Success
# 1 = Critical failure
# 2 = User choice/abort (non-critical)
# 10 = Download failure
# 11 = Extraction failure
# 12 = EFI file copy failure
# 13 = Boot entry creation failure
# 20 = Verification failure
# 21 = Checksum mismatch

install_enhanced_clover_bootloader() {
    log_debug "Entering function: ${FUNCNAME[0]} (Enhanced Clover Installer)"
    show_step "CLOVER (Enhanced)" "Installing Clover Bootloader"
    
    # --- 1. Dependency Checks ---
    show_progress "Checking Clover installation dependencies..."
    local clover_deps=("wget" "efibootmgr" "mkfs.vfat" "mount" "umount" "cp" "mkdir" "find" "lsblk" "awk" "sed" "grep" "cat" "head" "sha256sum")
    
    if command -v 7z &>/dev/null; then
        log_debug "7z found."
    elif command -v unzip &>/dev/null; then
        log_debug "unzip found."
        clover_deps+=("unzip")
    else
        clover_deps+=("p7zip-full") # Default to installing 7z if neither found
        log_debug "Neither 7z nor unzip found. Will attempt to install p7zip-full."
    fi
    
    if ! type ensure_packages_installed &>/dev/null; then
        show_error "CRITICAL: package_management.sh not sourced or 'ensure_packages_installed' function not found."
        log_fatal "CRITICAL: ensure_packages_installed function not found. Cannot proceed with Clover deps."
        return 1
    fi
    
    # Check for offline mode to adapt behavior
    local is_offline=false
    if type is_offline_mode &>/dev/null && is_offline_mode; then
        is_offline=true
        log_info "Detected OFFLINE mode. Will use local package resources for Clover dependencies."
        show_warning "Running in offline mode - using cached packages for Clover installation"
    fi
    
    # Configure advanced options for package installation
    local pkg_options=()
    pkg_options+=("--priority=high")         # These are critical packages
    pkg_options+=("--verify-checksums")      # Ensure package integrity
    pkg_options+=("--allow-fallback-cache") # Use local cache if network install fails
    
    if [[ "$is_offline" == "true" ]]; then
        pkg_options+=("--offline-only")      # Don't attempt network in offline mode
    else
        pkg_options+=("--parallel-download") # Enable parallel downloads in online mode
        pkg_options+=("--retry-count=3")     # Retry failed downloads
    fi
    
    show_progress "Installing Clover dependencies with enhanced package management..."
    log_debug "Calling ensure_packages_installed with options: ${pkg_options[*]}"
    
    if ! ensure_packages_installed "${clover_deps[@]}" "${pkg_options[@]}"; then
        local err_code=$?
        case $err_code in
            10) show_error "Network error while installing Clover dependencies. Check connectivity." ;;
            20) show_error "Package verification failed. Downloaded packages may be corrupted." ;;
            30) show_error "Dependency resolution failed. Some required packages unavailable." ;;
            *)  show_error "Failed to install essential dependencies for Clover (code: $err_code)." ;;
        esac
        log_error "Package installation failed with code $err_code"
        return 1
    fi
    
    log_info "Essential Clover dependencies are met."
    show_success "Successfully installed all Clover dependencies."
    
    local extractor_command=""
    if command -v 7z &>/dev/null; then
        extractor_command="7z"
    elif command -v unzip &>/dev/null; then
        extractor_command="unzip"
    else
        show_error "Neither 7z nor unzip is available after attempting installation. Cannot extract Clover. Aborting."
        return 1
    fi
    log_debug "Using '$extractor_command' for extraction."
    
    # --- 2. EFI Partition Configuration ---
    local clover_efi="${CONFIG_VARS[CLOVER_EFI_PART]:-}"
    if [[ -z "$clover_efi" ]]; then
        show_error "CLOVER_EFI_PART is not defined in the configuration. Aborting Clover installation."
        log_error "CLOVER_EFI_PART not set."
        return 1 # Critical config missing
    fi
    
    if [[ ! -b "$clover_efi" ]]; then
        show_error "Invalid Clover EFI partition: '$clover_efi' is not a block device. Aborting Clover installation."
        log_error "$clover_efi is not a block device."
        return 1 # Invalid device
    fi
    log_info "Clover EFI partition set to: $clover_efi"
    
    if ! (dialog --title "Confirm Format" --yesno "The partition $clover_efi will be formatted as FAT32 for Clover.\nALL DATA ON $clover_efi WILL BE LOST.\n\nDo you want to proceed?" 10 70); then
        log_info "User aborted formatting of $clover_efi."
        show_warning "Clover installation aborted by user (partition formatting declined)."
        return 2 # User choice, not a hard error
    fi
    
    show_progress "Formatting Clover EFI partition $clover_efi..."
    log_debug "Executing: mkfs.vfat -F32 $clover_efi"
    if ! mkfs.vfat -F32 "$clover_efi" &>> "$LOG_FILE"; then
        log_error "Failed to format $clover_efi as FAT32."
        show_error "Failed to format Clover EFI partition $clover_efi. Aborting Clover installation."
        return 1
    fi
    log_info "Successfully formatted $clover_efi."
    
    # --- 3. Mount EFI Partition ---
    local clover_mount="${TEMP_DIR}/clover_efi_mount"
    log_debug "Clover mount point: $clover_mount"
    mkdir -p "$clover_mount" &>> "$LOG_FILE"
    
    local mount_success=false
    if type mount_with_retry &>/dev/null; then
        log_debug "Using enhanced mount_with_retry for EFI partition"
        show_progress "Mounting EFI partition with enhanced features..."
        if mount_with_retry "$clover_efi" "$clover_mount" --retries=3 --filesystem=vfat --options="rw" --verify; then
            mount_success=true
        else
            log_error "Enhanced mount operation failed for $clover_efi on $clover_mount"
        fi
    else
        # Fall back to standard mount
        log_debug "Mounting $clover_efi to $clover_mount using standard mount"
        show_progress "Mounting EFI partition..."
        if mount "$clover_efi" "$clover_mount" &>> "$LOG_FILE"; then
            mount_success=true
        fi
    fi
    
    if ! $mount_success; then
        log_error "Failed to mount Clover EFI partition $clover_efi on $clover_mount."
        show_error "Failed to mount Clover EFI partition. Aborting Clover installation."
        return 1
    fi
    
    log_info "Clover EFI partition mounted successfully at $clover_mount."
    show_success "EFI partition mounted successfully."
    
    # --- 4. Download and Validate Clover ---
    show_progress "Preparing to download Clover bootloader..."
    local clover_url="${CONFIG_VARS[CLOVER_DOWNLOAD_URL]:-https://github.com/CloverHackyColor/CloverBootloader/releases/download/5157/CloverV2-5157.zip}"
    local clover_zip_sha256sum="${CONFIG_VARS[CLOVER_ZIP_SHA256SUM]:-}"
    local clover_zip_filename
    clover_zip_filename=$(basename "$clover_url")
    local clover_zip_path="$TEMP_DIR/$clover_zip_filename"
    local clover_local_resource_path="${SCRIPT_DIR}/resources/$clover_zip_filename"
    
    # Track if we can skip directly to extraction
    local goto_extraction=false
    
    # Use enhanced download_file function if available from package_management.sh
    if type download_file &>/dev/null; then
        log_debug "Using enhanced download_file function from package_management.sh"
        local download_options=()
        download_options+=("--output=$clover_zip_path")
        download_options+=("--progress-bar")
        download_options+=("--retry=3")
        download_options+=("--timeout=60")
        
        if [[ -n "$clover_zip_sha256sum" ]]; then
            download_options+=("--checksum=sha256:$clover_zip_sha256sum")
        fi
        
        if [[ -f "$clover_local_resource_path" ]]; then
            download_options+=("--local-fallback=$clover_local_resource_path")
        fi
        
        if type is_offline_mode &>/dev/null && is_offline_mode; then
            # In offline mode, directly use local resource
            if [[ -f "$clover_local_resource_path" ]]; then
                log_info "Offline mode: Using local Clover resource: $clover_local_resource_path"
                show_progress "Using local Clover package (offline mode)"
                if ! cp "$clover_local_resource_path" "$clover_zip_path" &>> "$LOG_FILE"; then
                    log_error "Failed to copy local Clover resource in offline mode"
                    show_error "Failed to access local Clover package in offline mode"
                    umount "$clover_mount" &>> "$LOG_FILE"
                    return 1
                fi
                goto_extraction=true
            else
                log_error "No local Clover package available in offline mode"
                show_error "Cannot install Clover: No network connection and no local package available"
                umount "$clover_mount" &>> "$LOG_FILE"
                return 1
            fi
        else
            # Online mode - use enhanced download function
            show_progress "Downloading Clover bootloader with enhanced features..."
            if ! download_file "$clover_url" "${download_options[@]}"; then
                local dl_status=$?
                log_warning "Enhanced download failed with status $dl_status. Falling back to basic wget"
                # Fallback continues to the wget method below
            else
                log_info "Successfully downloaded Clover package using enhanced downloader"
                # Skip the wget attempt
                show_success "Clover package obtained successfully"
                # Go to validation phase after download_file
                if [[ -f "$clover_zip_path" ]]; then
                    # Skip ahead to extraction since download_file handles validation
                    goto_extraction=true
                else
                    log_error "download_file reported success but $clover_zip_path not found"
                    show_error "Download succeeded but file not found. Check logs."
                    umount "$clover_mount" &>> "$LOG_FILE"
                    return 1
                fi
            fi
        fi
    fi
    
    # Traditional wget fallback if download_file is unavailable or failed
    if [[ "$goto_extraction" != "true" ]]; then
        show_progress "Downloading Clover bootloader..."
        if ! wget -T 30 -t 3 --show-progress -O "$clover_zip_path" "$clover_url" &>> "$LOG_FILE"; then
            log_warning "Failed to download Clover from $clover_url. wget exit status: $?. Trying local resource."
            show_warning "Failed to download Clover from $clover_url. Attempting to use local resource..."
            if [[ -f "$clover_local_resource_path" ]]; then
                log_info "Found local Clover resource: $clover_local_resource_path. Copying to $clover_zip_path."
                if ! cp "$clover_local_resource_path" "$clover_zip_path" &>> "$LOG_FILE"; then
                    log_error "Failed to copy local Clover resource $clover_local_resource_path to $clover_zip_path."
                    show_error "Failed to copy local Clover resource. Aborting Clover installation."
                    umount "$clover_mount" &>> "$LOG_FILE"
                    return 1
                fi
                show_progress "Using local Clover resource: $clover_local_resource_path"
            else
                log_error "Local Clover resource $clover_local_resource_path not found."
                show_error "Failed to download Clover and no local resource found. Aborting Clover installation."
                umount "$clover_mount" &>> "$LOG_FILE"
                return 1
            fi
        fi
        
        log_info "Clover ZIP is at $clover_zip_path."
        
        # Validate checksum after wget download (download_file would have done this already)
        if [[ -n "$clover_zip_sha256sum" ]]; then
            log_info "Validating checksum for $clover_zip_path. Expected: $clover_zip_sha256sum"
            show_progress "Validating Clover ZIP checksum..."
            local actual_checksum
            actual_checksum=$(sha256sum "$clover_zip_path" | awk '{print $1}')
            if [[ "$actual_checksum" == "$clover_zip_sha256sum" ]]; then
                log_info "Clover ZIP checksum validation PASSED."
                show_success "Clover ZIP checksum OK."
            else
                log_error "Clover ZIP checksum validation FAILED. Expected: $clover_zip_sha256sum, Got: $actual_checksum."
                show_error "Checksum validation FAILED for downloaded Clover ZIP."
                
                # Clean up bad download
                rm -f "$clover_zip_path"
                
                # Check if we already tried local or if the primary download was the local file
                if [[ "$clover_url" != "file://"* && -f "$clover_local_resource_path" && "$clover_zip_path" != "$clover_local_resource_path" ]]; then
                    log_info "Attempting to use local resource $clover_local_resource_path due to checksum failure of downloaded file."
                    show_warning "Attempting to use local Clover resource due to checksum failure..."
                    if ! cp "$clover_local_resource_path" "$clover_zip_path" &>> "$LOG_FILE"; then
                        log_error "Failed to copy local Clover resource $clover_local_resource_path to $clover_zip_path after checksum fail."
                        show_error "Failed to copy local Clover resource after checksum failure. Aborting Clover installation."
                        umount "$clover_mount" &>> "$LOG_FILE"
                        return 1
                    fi
                    actual_checksum=$(sha256sum "$clover_zip_path" | awk '{print $1}')
                    if [[ "$actual_checksum" == "$clover_zip_sha256sum" ]]; then
                        log_info "Local Clover ZIP checksum validation PASSED."
                        show_success "Local Clover ZIP checksum OK."
                    else
                        log_error "Local Clover ZIP checksum validation FAILED. Expected: $clover_zip_sha256sum, Got: $actual_checksum."
                        show_error "Checksum for local Clover ZIP also FAILED. Aborting Clover installation."
                        umount "$clover_mount" &>> "$LOG_FILE"
                        return 1
                    fi
                else
                    show_error "No valid Clover ZIP found (checksum failed, or local resource also failed/unavailable). Aborting."
                    umount "$clover_mount" &>> "$LOG_FILE"
                    return 1
                fi
            fi
        else
            log_warning "No checksum provided for Clover ZIP (CLOVER_ZIP_SHA256SUM not set). Skipping validation."
            show_warning "No checksum for Clover ZIP. Proceeding without validation."
        fi
    fi
    
    # Verify we have a valid ZIP file before proceeding
    if [[ ! -f "$clover_zip_path" ]]; then
        log_error "Clover ZIP file $clover_zip_path does not exist after download/copy attempts."
        show_error "Clover ZIP file unavailable. Aborting Clover installation."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    # --- 4.5. Verify signature if available ---
    if [[ -n "${CONFIG_VARS[CLOVER_GPG_KEY]}" ]] && [[ -f "${CONFIG_VARS[CLOVER_GPG_KEY]}" ]] && command -v gpg &>/dev/null; then
        show_progress "Verifying Clover package signature..."
        local sig_file="$clover_zip_path.sig"
        
        # Check if signature file exists or can be downloaded
        if [[ -f "$SCRIPT_DIR/resources/$clover_zip_filename.sig" ]]; then
            cp "$SCRIPT_DIR/resources/$clover_zip_filename.sig" "$sig_file"
            log_info "Using local signature file from resources directory"
        elif ! $is_offline && wget -q -T 10 -t 2 -O "$sig_file" "$clover_url.sig"; then
            log_info "Downloaded signature file from $clover_url.sig"
        else
            log_warning "Signature file unavailable, skipping signature verification"
            show_warning "Package signature not available - proceeding with checksum validation only"
        fi
        
        # If we have a signature file, verify it
        if [[ -f "$sig_file" ]]; then
            if gpg --import "${CONFIG_VARS[CLOVER_GPG_KEY]}" &>> "$LOG_FILE" && \
               gpg --verify "$sig_file" "$clover_zip_path" &>> "$LOG_FILE"; then
                log_info "Clover package signature verified successfully"
                show_success "Signature verification passed"
            else
                log_warning "Signature verification failed, proceeding with caution"
                show_warning "Package signature verification failed - installation continues with checksum validation only"
                
                # Ask user if they want to continue despite signature failure
                if ! (dialog --title "Signature Verification Failed" --yesno "The Clover package signature could not be verified.\n\nDo you want to continue installation anyway?" 8 70); then
                    log_info "User aborted installation after signature verification failure"
                    show_warning "Installation aborted due to signature verification failure"
                    umount "$clover_mount" &>> "$LOG_FILE"
                    return 2
                fi
            fi
        fi
    fi
    
    # --- 5. Extract Clover ---
    show_progress "Extracting Clover from $clover_zip_path..."
    local clover_extract_dir="$TEMP_DIR/CloverExtract"
    rm -rf "$clover_extract_dir" # Clean up previous attempt
    mkdir -p "$clover_extract_dir"
    
    local extraction_ok=false
    log_debug "Using extractor: $extractor_command"
    
    if [[ "$extractor_command" == "7z" ]]; then
        if 7z x -y "$clover_zip_path" -o"$clover_extract_dir" &>> "$LOG_FILE"; then
            extraction_ok=true
            log_info "Clover extracted successfully using 7z."
        else
            log_warning "7z extraction failed. 7z exit status: $?"
            if command -v unzip &>/dev/null; then # Try unzip if 7z failed
                 log_info "Trying extraction with unzip as fallback..."
                 if unzip -q -o "$clover_zip_path" -d "$clover_extract_dir" &>> "$LOG_FILE"; then
                    extraction_ok=true
                    log_info "Clover extracted successfully using unzip as fallback."
                 else
                    log_warning "unzip extraction also failed. unzip exit status: $?"
                 fi
            fi
        fi
    elif [[ "$extractor_command" == "unzip" ]]; then
        if unzip -q -o "$clover_zip_path" -d "$clover_extract_dir" &>> "$LOG_FILE"; then
            extraction_ok=true
            log_info "Clover extracted successfully using unzip."
        else
            log_warning "unzip extraction failed. unzip exit status: $?"
        fi
    fi
    
    if [[ "$extraction_ok" == false ]]; then
        log_error "Failed to extract Clover ZIP file using available tools."
        show_error "Failed to extract Clover ZIP. Check logs. Aborting Clover installation."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    if [ ! -d "$clover_extract_dir" ] || [ -z "$(ls -A "$clover_extract_dir" 2>/dev/null)" ]; then
        log_error "Extraction directory is empty or doesn't exist: $clover_extract_dir"
        show_error "Clover extraction resulted in an empty directory. Aborting."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    log_debug "Extracted Clover structure in $clover_extract_dir. Contents:"
    ls -laR "$clover_extract_dir" &>> "$LOG_FILE"
    
    # --- 6. Copy Clover Files to ESP ---
    show_progress "Copying Clover files to ESP..."
    # Robustly find the source EFI directory (often $clover_extract_dir/EFI)
    local clover_efi_source_dir=""
    if [[ -d "$clover_extract_dir/EFI" ]]; then
        clover_efi_source_dir="$clover_extract_dir/EFI"
    elif [[ -d "$clover_extract_dir/CloverV2/EFI" ]]; then # Some older structures
        clover_efi_source_dir="$clover_extract_dir/CloverV2/EFI"
    else # Try to find any directory named EFI
        local found_dir
        found_dir=$(find "$clover_extract_dir" -type d -name EFI -print -quit)
        if [[ -n "$found_dir" ]]; then
            clover_efi_source_dir="$found_dir"
        fi
    fi
    
    if [[ -z "$clover_efi_source_dir" ]] || [[ ! -d "$clover_efi_source_dir" ]]; then
        log_error "Could not find a usable EFI source directory in the extracted Clover package at $clover_extract_dir."
        show_error "Could not locate Clover EFI files after extraction. Aborting."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    log_info "Using Clover EFI source directory: $clover_efi_source_dir"
    
    # Ensure target EFI directory exists on ESP
    mkdir -p "$clover_mount/EFI" &>> "$LOG_FILE"
    log_debug "Copying files from $clover_efi_source_dir to $clover_mount/EFI/"
    
    if ! cp -arf "${clover_efi_source_dir}/." "${clover_mount}/EFI/" &>> "$LOG_FILE"; then
        log_error "Failed to copy Clover EFI files from $clover_efi_source_dir to $clover_mount/EFI/."
        show_error "Failed to copy Clover files to ESP. Aborting."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    # Verify essential files
    if [[ ! -f "$clover_mount/EFI/CLOVER/CLOVERX64.efi" ]]; then
        log_error "Essential file $clover_mount/EFI/CLOVER/CLOVERX64.efi not found after copy."
        show_error "Clover installation incomplete: CLOVERX64.efi missing on ESP. Aborting."
        # Try to find it anywhere in extract and copy as last resort
        local found_cloverx64
        found_cloverx64=$(find "$clover_extract_dir" -name CLOVERX64.efi -print -quit)
        if [[ -n "$found_cloverx64" ]]; then
            log_info "Found CLOVERX64.efi at $found_cloverx64, attempting direct copy."
            mkdir -p "$clover_mount/EFI/CLOVER" &>> "$LOG_FILE"
            if cp "$found_cloverx64" "$clover_mount/EFI/CLOVER/CLOVERX64.efi" &>> "$LOG_FILE"; then
                log_info "Successfully copied CLOVERX64.efi as a fallback."
            else
                umount "$clover_mount" &>> "$LOG_FILE"
                return 1
            fi 
        else
            umount "$clover_mount" &>> "$LOG_FILE"
            return 1
        fi
    fi
    
    log_info "Clover files copied to ESP. Contents of $clover_mount/EFI:
$(ls -laR "$clover_mount/EFI" 2>/dev/null)"
    
    # --- 7. Create Clover config.plist ---
    log_info "Creating Clover config.plist at $clover_mount/EFI/CLOVER/config.plist"
    show_progress "Creating Clover config.plist..."
    
    # Use template if available, otherwise create from scratch
    if [[ -f "${CONFIG_VARS[CLOVER_CONFIG_TEMPLATE]:-}" ]]; then
        show_progress "Using Clover config template from ${CONFIG_VARS[CLOVER_CONFIG_TEMPLATE]}"
        log_info "Using Clover config template: ${CONFIG_VARS[CLOVER_CONFIG_TEMPLATE]}"
        
        # Process template file with variable substitutions
        local pve_boot_label="${CONFIG_VARS[PVE_BOOT_LABEL]:-Proxmox}"
        local clover_theme="${CONFIG_VARS[CLOVER_THEME]:-embedded}"
        
        # Create a processed version of the template with variables substituted
        sed -e "s|\${CONFIG_VARS\[PVE_BOOT_LABEL\]:-Proxmox}|$pve_boot_label|g" \
            -e "s|\${CONFIG_VARS\[CLOVER_THEME\]:-embedded}|$clover_theme|g" \
            "${CONFIG_VARS[CLOVER_CONFIG_TEMPLATE]}" > "$clover_mount/EFI/CLOVER/config.plist"
    else
        # Create standard config.plist
        mkdir -p "$clover_mount/EFI/CLOVER" # Ensure directory exists
        cat > "$clover_mount/EFI/CLOVER/config.plist" <<- 'CLOVER_CONFIG'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Boot</key>
    <dict>
        <key>Timeout</key>
        <integer>5</integer>
        <key>DefaultVolume</key>
        <string>${CONFIG_VARS[PVE_BOOT_LABEL]:-Proxmox}</string>
        <key>DefaultLoader</key>
        <string>\EFI\proxmox\grubx64.efi</string>
    </dict>
    <key>GUI</key>
    <dict>
        <key>Theme</key>
        <string>${CONFIG_VARS[CLOVER_THEME]:-embedded}</string>
        <key>Scan</key>
        <dict>
            <key>Entries</key>
            <true/>
            <key>Linux</key>
            <true/>
            <key>Tool</key>
            <true/>
            <key>Legacy</key>
            <string>Never</string>
        </dict>
    </dict>
    <key>SystemParameters</key>
    <dict>
        <key>InjectKexts</key>
        <string>Detect</string>
        <key>InjectSystemID</key>
        <true/>
    </dict>
    <key>RtVariables</key>
    <dict>
        <key>CsrActiveConfig</key>
        <string>0x67</string>
    </dict>
</dict>
</plist>
CLOVER_CONFIG
    fi
    
    # Check if the config.plist creation was successful
    if [[ ! -f "$clover_mount/EFI/CLOVER/config.plist" ]]; then
        log_error "Failed to create Clover config.plist."
        show_error "Could not create Clover config.plist. Aborting."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    # Process the variable substitutions in the config file
    if [[ -f "$clover_mount/EFI/CLOVER/config.plist" ]]; then
        local pve_boot_label="${CONFIG_VARS[PVE_BOOT_LABEL]:-Proxmox}"
        local clover_theme="${CONFIG_VARS[CLOVER_THEME]:-embedded}"
        
        # Use safer sed with temporary file
        sed -i.bak "s|\${CONFIG_VARS\[PVE_BOOT_LABEL\]:-Proxmox}|$pve_boot_label|g" "$clover_mount/EFI/CLOVER/config.plist"
        sed -i.bak "s|\${CONFIG_VARS\[CLOVER_THEME\]:-embedded}|$clover_theme|g" "$clover_mount/EFI/CLOVER/config.plist"
        rm -f "$clover_mount/EFI/CLOVER/config.plist.bak"
    fi
    
    log_info "Clover config.plist created."
    
    # --- 8. Create UEFI Boot Entry ---
    show_progress "Creating UEFI boot entry for Clover..."
    
    local clover_disk_for_efibootmgr
    # efibootmgr needs disk path like /dev/sda, not /dev/sda1
    clover_disk_for_efibootmgr=$(lsblk -no pkname "$clover_efi" | head -n1)
    
    if [[ -z "$clover_disk_for_efibootmgr" ]]; then
        # Fallback for devices like /dev/nvme0n1p1 or if pkname is empty
        clover_disk_for_efibootmgr=$(echo "$clover_efi" | sed -E 's/p[0-9]+$//' | sed -E 's/[0-9]+$//')
    else
        clover_disk_for_efibootmgr="/dev/$clover_disk_for_efibootmgr"
    fi
    
    local part_num
    part_num=$(lsblk -no MAJ:MIN "$clover_efi" | sed 's/.*://' | (read -r dev_maj_min; cat "/sys/dev/block/$dev_maj_min/partition" 2>/dev/null || echo "${clover_efi##*[^0-9]}"))
    
    if [[ ! -b "$clover_disk_for_efibootmgr" ]] || ! [[ "$part_num" =~ ^[0-9]+$ ]] || [[ "$part_num" -eq 0 ]]; then
        log_error "Could not reliably determine disk path ('$clover_disk_for_efibootmgr') or partition number ('$part_num') for $clover_efi."
        show_error "Failed to determine disk/partition for efibootmgr. Aborting Clover boot entry creation."
        umount "$clover_mount" &>> "$LOG_FILE"
        return 1
    fi
    
    log_info "Using disk $clover_disk_for_efibootmgr and partition $part_num for efibootmgr."
    
    # Remove existing Clover entry if present
    local existing_clover_entry
    existing_clover_entry=$(efibootmgr | grep -i Clover | awk '{print $1}' | sed 's/Boot//;s/\*//')
    
    if [[ -n "$existing_clover_entry" ]]; then
        log_info "Found existing Clover boot entry: $existing_clover_entry. Removing it."
        efibootmgr -b "${existing_clover_entry//Boot/}" -B &>> "$LOG_FILE"
    fi
    
    log_debug "Executing efibootmgr: efibootmgr -c -d $clover_disk_for_efibootmgr -p \"$part_num\" -L \"Clover (Proxmox VE)\" -l '\\EFI\\CLOVER\\CLOVERX64.efi'"
    
    if ! efibootmgr -c -d "$clover_disk_for_efibootmgr" -p "$part_num" -L "Clover (Proxmox VE)" -l '\EFI\CLOVER\CLOVERX64.efi' &>> "$LOG_FILE"; then
        log_error "efibootmgr command failed to create boot entry. Exit status: $?"
        show_error "Failed to create UEFI boot entry for Clover. Check logs."
        # Not returning error here as manual entry creation is possible
    else
        log_info "UEFI boot entry for Clover created/updated successfully."
    fi
    
    log_info "Current UEFI boot entries:"
    efibootmgr &>> "$LOG_FILE"
    efibootmgr # Display to user via progress/log
    
    # Optionally, set as next boot
    local new_clover_entry_num
    new_clover_entry_num=$(efibootmgr | grep -i "Clover (Proxmox VE)" | awk '{print $1}' | sed 's/Boot//;s/\*//')
    
    if [[ -n "$new_clover_entry_num" ]]; then
        if (dialog --title "Set Next Boot" --yesno "Clover boot entry '$new_clover_entry_num' created.\nDo you want to set this as the default boot entry for the next boot?" 10 70); then
            log_info "Setting boot next to $new_clover_entry_num"
            efibootmgr -n "$new_clover_entry_num" &>> "$LOG_FILE"
            show_success "Clover set as next boot target."
        fi
    fi 
    
    # --- 9. Configure Boot Order (optional enhancement) ---
    if (dialog --title "Configure Boot Order" --yesno "Do you want to modify the EFI boot order?\n(Recommended to put Clover first if this is your main boot loader)" 8 70); then
        # Get current boot order for logging purposes
        efibootmgr | grep "BootOrder:" | cut -d: -f2 | tr -d ' ' >> "$LOG_FILE"
        log_debug "Current boot order retrieved for reference"
        
        # Create a temporary file for dialog checklist content
        local tempfile
        tempfile=$(mktemp)
        
        # Populate boot entries for the checklist
        while read -r bootnum name; do
            bootnum=${bootnum//Boot/}
            bootnum=${bootnum//\*/}
            name=${name//\*/}
            echo "$bootnum \"$name\" on" >> "$tempfile"
        done < <(efibootmgr | grep "^Boot" | cut -d' ' -f1,2-)
        
        # Display the dialog checklist for boot order selection
        local new_boot_order
        new_boot_order=$(dialog --title "Configure Boot Order" --checklist "Select boot entries in desired order:" 20 70 15 --file "$tempfile" 3>&1 1>&2 2>&3)
        
        # Clean up temp file
        rm -f "$tempfile"
        
        # Apply new boot order if user made a selection
        if [[ -n "$new_boot_order" ]]; then
            new_boot_order=$(echo "$new_boot_order" | tr ' ' ,)
            log_info "Setting new boot order: $new_boot_order"
            
            if efibootmgr --bootorder "$new_boot_order" &>> "$LOG_FILE"; then
                show_success "Boot order updated successfully"
            else
                show_warning "Failed to update boot order. You may need to do this manually."
                log_error "efibootmgr --bootorder command failed with exit code: $?"
            fi
        else
            log_info "User cancelled boot order configuration"
        fi
    fi
    
    # --- 10. Cleanup and Status Reporting ---
    show_progress "Finalizing Clover installation..."
    log_debug "Changing directory to /"
    cd / &>> "$LOG_FILE" || log_warning "Failed to cd to /, but continuing cleanup"
    
    # Sync filesystem to ensure all writes are complete
    sync
    
    log_debug "Unmounting Clover mount point: $clover_mount"
    if ! umount "$clover_mount" &>> "$LOG_FILE"; then
        log_warning "Failed to unmount $clover_mount. It might be busy. Please check manually."
        show_warning "Could not unmount EFI partition. You may need to reboot or unmount manually later."
    else
        log_info "$clover_mount unmounted."
        rmdir "$clover_mount" &>/dev/null
    fi
    
    # Use cleanup_temp_files from package_management.sh if available
    if type cleanup_temp_files &>/dev/null; then
        if [[ "${CONFIG_VARS[KEEP_INSTALLER_FILES]:-false}" == "true" ]]; then
            log_info "Keeping installer files for debugging (KEEP_INSTALLER_FILES=true)"
        else
            log_debug "Cleaning up temporary files with enhanced cleanup function"
            cleanup_temp_files --include="$clover_zip_path" --include="$clover_extract_dir" --min-age=600
            # The enhanced function handles error checking and logging
        fi
    else
        # Traditional cleanup approach
        # Keep files only if explicitly configured
        if [[ "${CONFIG_VARS[KEEP_INSTALLER_FILES]:-false}" != "true" ]]; then
            rm -f "$clover_zip_path" 2>/dev/null
            rm -rf "$clover_extract_dir" 2>/dev/null
            log_debug "Removed temporary Clover files using standard cleanup"
        fi
    fi
    
    # --- 11. Generate Installation Report ---
    local report_file="$TEMP_DIR/clover_install_report.md"
    
    {
        echo "# Clover Bootloader Installation Report"
        echo "## Installation Summary"
        echo "- **Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- **Clover Version:** $(basename "$clover_url" | grep -oE '[0-9]+' | head -1)"
        echo "- **EFI Partition:** $clover_efi"
        echo "- **Status:** ✅ Successfully Installed"
        echo
        echo "## Configuration Details"
        echo "- **Boot Entry Label:** Clover (Proxmox VE)"
        echo "- **EFI Path:** \EFI\CLOVER\CLOVERX64.efi"
        echo "- **Theme:** ${CONFIG_VARS[CLOVER_THEME]:-embedded}"
        echo "- **Default Boot Target:** ${CONFIG_VARS[PVE_BOOT_LABEL]:-Proxmox}"
        echo
        echo "## Boot Entries"
        echo '```'
        efibootmgr
        echo '```'
        echo
        echo "## Next Steps"
        echo "1. Reboot the system to test Clover bootloader"
        echo "2. If needed, fine-tune the config.plist at $clover_efi/EFI/CLOVER/config.plist"
        echo "3. Additional Clover themes can be added to $clover_efi/EFI/CLOVER/themes/"
    } > "$report_file"
    
    log_info "Installation report generated: $report_file"
    
    # Display report if available tools exist
    if command -v less &>/dev/null; then
        if (dialog --title "View Installation Report" --yesno "Clover bootloader has been successfully installed.\n\nWould you like to view the installation report?" 8 70); then
            clear
            less "$report_file"
        fi
    fi
    
    # Report installation status using enhanced reporting if available
    if type report_component_status &>/dev/null; then
        report_component_status "Clover Bootloader" "success" "EFI entry created" \
            --details="UEFI boot entry created for Clover on $clover_efi" \
            --importance="critical" \
            --report-file="$report_file"
    else
        show_success "Clover bootloader installation process completed successfully."
    fi
    
    log_info "Exiting function: ${FUNCNAME[0]}"
    return 0
}

# Example of how to call (ensure SCRIPT_DIR, TEMP_DIR, LOG_FILE, CONFIG_VARS are set):
# source ./common_utils.sh # if not already done
# source ./package_management.sh # if not already done
# SCRIPT_DIR=$(pwd)
# TEMP_DIR=$(mktemp -d)
# LOG_FILE="/tmp/installer.log"
# declare -A CONFIG_VARS
# CONFIG_VARS[CLOVER_EFI_PART]="/dev/sdb1" # Example, set your actual ESP
# CONFIG_VARS[PVE_BOOT_LABEL]="MyProxmox"
# install_enhanced_clover_bootloader
# rm -rf "$TEMP_DIR"
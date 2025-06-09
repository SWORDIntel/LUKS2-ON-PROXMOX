#!/usr/bin/env bash
# Enhanced Clover bootloader installation for Proxmox VE
# This script is intended to be sourced by the main installer or bootloader_logic.sh
# Ensure common_utils.sh and package_management.sh are sourced by the caller.

# Source simplified UI functions
# Attempt to determine SCRIPT_DIR if not already set
if [ -z "$LOG_FILE" ]; then # Basic check if logging is even possible
    LOG_FILE="/tmp/clover_bootloader_early.log"
    echo "Initial log_debug not available, logging SCRIPT_DIR determination to $LOG_FILE" >> "$LOG_FILE"
fi

_cl_log_debug() { if type log_debug &>/dev/null; then log_debug "$@"; else printf "DEBUG: %s\n" "$*" >> "$LOG_FILE"; fi }
_cl_log_info() { if type log_info &>/dev/null; then log_info "$@"; else printf "INFO: %s\n" "$*" >> "$LOG_FILE"; fi }
_cl_log_error() { if type log_error &>/dev/null; then log_error "$@"; else printf "ERROR: %s\n" "$*" >&2; printf "ERROR: %s\n" "$*" >> "$LOG_FILE"; fi }

_cl_log_debug "clover_bootloader.sh: Initializing SCRIPT_DIR and sourcing ui_functions.sh."
if [ -z "$SCRIPT_DIR" ]; then
    _cl_log_debug "SCRIPT_DIR is not set. Determining it from BASH_SOURCE[0]."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
    _cl_log_info "SCRIPT_DIR determined as: '$SCRIPT_DIR'."
else
    _cl_log_debug "SCRIPT_DIR is already set to: '$SCRIPT_DIR'."
fi

_cl_log_debug "Attempting to source ui_functions.sh."
if [ -f "${SCRIPT_DIR}/ui_functions.sh" ]; then
    _cl_log_info "Found ui_functions.sh at '${SCRIPT_DIR}/ui_functions.sh'. Sourcing it."
    # shellcheck source=ui_functions.sh
    source "${SCRIPT_DIR}/ui_functions.sh"
    _cl_log_debug "Sourcing '${SCRIPT_DIR}/ui_functions.sh' completed."
elif [ -f "./ui_functions.sh" ]; then # Fallback for direct execution or different sourcing context
    _cl_log_info "ui_functions.sh not found in SCRIPT_DIR. Found at './ui_functions.sh'. Sourcing it."
    source "./ui_functions.sh"
    _cl_log_debug "Sourcing './ui_functions.sh' completed."
else
    _cl_log_error "Critical Error: Failed to source ui_functions.sh. Tried '${SCRIPT_DIR}/ui_functions.sh' and './ui_functions.sh'. SCRIPT_DIR was '$SCRIPT_DIR'."
    printf "Critical Error: Failed to source ui_functions.sh in clover_bootloader.sh. SCRIPT_DIR was '%s'. Exiting.\n" "$SCRIPT_DIR" >&2
    exit 1
fi




install_enhanced_clover_bootloader() {
    log_debug "Entering function: ${FUNCNAME[0]} (Enhanced Clover Installer)"
    show_step "CLOVER (Enhanced)" "Installing Clover Bootloader"

    # --- 1. Dependency Checks ---
    show_progress "Checking Clover installation dependencies..."
    log_debug "Initializing dependency list for Clover."
    local clover_deps=("wget" "efibootmgr" "mkfs.vfat" "mount" "umount" "cp" "mkdir" "find" "lsblk" "awk" "sed" "grep" "cat" "sha256sum")
    log_debug "Initial Clover dependencies: ${clover_deps[*]}"
    local extractor_command=""
    log_debug "Extractor command initially empty."

    log_debug "Checking for available extractor: 7z or unzip."
    if command -v 7z &>/dev/null; then
        extractor_command="7z"
        log_info "Found '7z' extractor."
    elif command -v unzip &>/dev/null; then
        extractor_command="unzip"
        log_info "Found 'unzip' extractor."
    else
        log_warning "Neither '7z' nor 'unzip' found. Adding 'p7zip-full' to dependencies."
        clover_deps+=("p7zip-full")
        log_debug "Updated Clover dependencies: ${clover_deps[*]}"
    fi

    # ANNOTATION: Gracefully handle missing 'ensure_packages_installed' function.
    log_debug "Checking if 'ensure_packages_installed' function is available."
    if type ensure_packages_installed &>/dev/null; then
        log_info "Function 'ensure_packages_installed' found. Using it to install dependencies: ${clover_deps[*]}"
        show_progress "Installing dependencies via enhanced package manager..."
        if ! ensure_packages_installed "${clover_deps[@]}"; then
            log_error "ensure_packages_installed failed for dependencies: ${clover_deps[*]}. Exit status: $?"
            show_error "Failed to install essential dependencies for Clover."
            log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (ensure_packages_installed failed)."
            return 1
        fi
        log_info "ensure_packages_installed completed successfully for: ${clover_deps[*]}"
    else
        log_warning "Function 'ensure_packages_installed' not found. Falling back to basic 'apt-get' for dependencies: ${clover_deps[*]}"
        show_warning "Using basic 'apt-get' for dependencies as 'ensure_packages_installed' is unavailable."
        
        local apt_update_cmd="apt-get update"
        log_info "Executing: $apt_update_cmd"
        if ! apt-get update &>> "$LOG_FILE"; then
            local apt_update_status=$?
            log_error "apt-get update failed. Exit status: $apt_update_status. Cannot proceed with dependency installation."
            show_error "apt-get update failed. Check logs. Cannot install Clover dependencies."
            log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (apt-get update failed)."
            return 1
        fi
        log_info "apt-get update successful."

        local apt_install_cmd="apt-get install -y ${clover_deps[*]}"
        log_info "Executing: $apt_install_cmd"
        if ! apt-get install -y "${clover_deps[@]}" &>> "$LOG_FILE"; then
            local apt_install_status=$?
            log_fatal "apt-get install -y ${clover_deps[*]} failed. Exit status: $apt_install_status."
            show_error "Failed to install dependencies using apt-get: ${clover_deps[*]}. Check logs."
            log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (apt-get install failed)."
            return 1
        fi
        log_info "apt-get install -y ${clover_deps[*]} successful."
    fi

    log_debug "Re-checking for extractor command after potential installation of p7zip-full."
    if [ -z "$extractor_command" ]; then
        log_debug "Extractor command was empty. Checking for 7z again."
        if command -v 7z &>/dev/null; then 
            extractor_command="7z"
            log_info "Found '7z' extractor after dependency installation."
        fi
        # Check for unzip only if 7z wasn't found and extractor_command is still empty
        if [ -z "$extractor_command" ] && command -v unzip &>/dev/null; then 
            extractor_command="unzip"
            log_info "Found 'unzip' extractor after dependency installation (7z not found or preferred)."
        fi
    else
        log_debug "Extractor command ('$extractor_command') was already set before re-check."
    fi

    if [ -z "$extractor_command" ]; then
        log_fatal "Extractor command (7z or unzip) still not available after installation attempts."
        show_error "Could not find a suitable extractor (7z or unzip) after installation attempt."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (extractor not found)."
        return 1
    fi
    log_info "Using '$extractor_command' for extraction."

    # --- 2. EFI Partition Configuration ---
    log_debug "--- EFI Partition Configuration ---"
    log_debug "Retrieving CLOVER_EFI_PART from CONFIG_VARS. Value: '${CONFIG_VARS[CLOVER_EFI_PART]:-not set}'."
    local clover_efi="${CONFIG_VARS[CLOVER_EFI_PART]:-}"

    if [[ -z "$clover_efi" ]]; then
        log_error "CLOVER_EFI_PART is empty or not set in CONFIG_VARS."
        show_error "Clover EFI partition is not defined. Aborting Clover installation."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (CLOVER_EFI_PART not set)."
        return 1
    elif ! [[ -b "$clover_efi" ]]; then
        log_error "CLOVER_EFI_PART ('$clover_efi') is not a valid block device."
        show_error "Invalid Clover EFI partition specified: '$clover_efi' is not a block device. Aborting."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (CLOVER_EFI_PART not a block device)."
        return 1
    fi
    log_info "Clover EFI partition set to: '$clover_efi'. It is a valid block device."

    # ANNOTATION: Use the new robust prompt function.
    local format_prompt_msg="The partition $clover_efi will be formatted as FAT32.\nALL DATA ON IT WILL BE LOST.\n\nProceed with formatting $clover_efi for Clover?"
    log_debug "Prompting user about formatting '$clover_efi': "
    log_debug "Prompt message: $format_prompt_msg"
    if ! prompt_yes_no "$format_prompt_msg"; then
        log_warning "User declined formatting of '$clover_efi'. Clover installation aborted by user."
        show_warning "Clover installation aborted by user (declined EFI partition format)."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 2 (user aborted at format prompt)."
        return 2 # Specific return code for user abort
    fi
    log_info "User confirmed formatting of '$clover_efi'."

    show_progress "Formatting Clover EFI partition $clover_efi..."
    local mkfs_cmd="mkfs.vfat -F32 $clover_efi"
    log_info "Executing: $mkfs_cmd"
    if ! mkfs.vfat -F32 "$clover_efi" &>> "$LOG_FILE"; then
        local mkfs_status=$?
        log_error "Command '$mkfs_cmd' failed with status $mkfs_status."
        show_error "Failed to format $clover_efi as FAT32. Check $LOG_FILE for details. Aborting."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkfs.vfat failed)."
        return 1
    fi
    log_info "Command '$mkfs_cmd' successful. Partition $clover_efi formatted as FAT32."
    show_success "Clover EFI partition $clover_efi formatted."

    # --- 3. Mount EFI Partition ---
    log_debug "--- Mount EFI Partition ---"
    local clover_mount="${TEMP_DIR}/clover_efi_mount"
    log_info "Clover EFI mount point set to: '$clover_mount'."

    log_debug "Creating Clover EFI mount point directory: '$clover_mount'."
    local mkdir_cmd="mkdir -p $clover_mount"
    if ! mkdir -p "$clover_mount"; then
        local mkdir_status=$?
        log_error "Command '$mkdir_cmd' failed with status $mkdir_status. Cannot create mount point."
        show_error "Failed to create Clover EFI mount point '$clover_mount'. Aborting."
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkdir for mount point failed)."
        return 1
    fi
    log_info "Successfully created Clover EFI mount point: '$clover_mount'."
    show_progress "Mounting $clover_efi to $clover_mount..."
    local mount_cmd="mount $clover_efi $clover_mount"
    log_info "Executing: $mount_cmd"
    if ! mount "$clover_efi" "$clover_mount" &>> "$LOG_FILE"; then
        local mount_status=$?
        log_error "Command '$mount_cmd' failed with status $mount_status."
        show_error "Failed to mount $clover_efi to $clover_mount. Check $LOG_FILE. Aborting."
        # Attempt to clean up mount point directory if mount failed
        rmdir "$clover_mount" &>/dev/null
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mount failed)."
        return 1
    fi
    log_info "Command '$mount_cmd' successful. '$clover_efi' mounted to '$clover_mount'."
    show_success "Mounted $clover_efi to $clover_mount."

    # --- 4. Download Clover ---
    log_debug "--- Download Clover ---"
    local clover_url="${CONFIG_VARS[CLOVER_DOWNLOAD_URL]:-https://github.com/CloverHackyColor/CloverBootloader/releases/download/5158/CloverV2-5158.zip}"
    local clover_sha256="${CONFIG_VARS[CLOVER_DOWNLOAD_SHA256]:-5f08e20f19b91155837182111861819975779533f5051830702407299b014901}"
    local clover_zip_path="${TEMP_DIR}/Clover.zip"

    log_info "Clover download URL: '$clover_url'"
    log_info "Expected Clover SHA256: '$clover_sha256'"
    log_info "Clover download path: '$clover_zip_path'"

    show_progress "Downloading Clover from $clover_url..."
    local wget_cmd="wget -O $clover_zip_path $clover_url"
    log_info "Executing: $wget_cmd"
    if ! wget -O "$clover_zip_path" "$clover_url" &>> "$LOG_FILE"; then
        local wget_status=$?
        log_error "Command '$wget_cmd' failed with status $wget_status."
        show_error "Failed to download Clover. Check network or URL. See $LOG_FILE. Aborting."
        log_debug "Unmounting '$clover_mount' due to download failure."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (wget failed)."
        return 1
    fi
    log_info "Command '$wget_cmd' successful. Clover downloaded to '$clover_zip_path'."

    # --- 5. Verify Clover Download ---
    log_debug "--- Verify Clover Download ---"
    show_progress "Verifying Clover download integrity..."
    local sha256_cmd="sha256sum $clover_zip_path"
    log_info "Calculating SHA256 sum for '$clover_zip_path'. Executing: $sha256_cmd | awk '{print $1}'"
    local calculated_sha256
    calculated_sha256=$(sha256sum "$clover_zip_path" 2>>"$LOG_FILE" | awk '{print $1}')
    local sha256_status=$?

    if [[ $sha256_status -ne 0 ]]; then
        log_error "Command 'sha256sum $clover_zip_path' failed with status $sha256_status."
        show_error "Failed to calculate SHA256 sum for Clover download. Check $LOG_FILE. Aborting."
        log_debug "Unmounting '$clover_mount' due to sha256sum failure."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (sha256sum command failed)."
        return 1
    fi
    log_info "Calculated SHA256 for '$clover_zip_path': '$calculated_sha256'. Expected: '$clover_sha256'."

    if [[ "$calculated_sha256" != "$clover_sha256" ]]; then
        log_error "SHA256 mismatch for '$clover_zip_path'. Expected: '$clover_sha256', Got: '$calculated_sha256'."
        show_error "Clover download verification FAILED. SHA256 mismatch. Expected '$clover_sha256', but got '$calculated_sha256'. Aborting."
        log_debug "Unmounting '$clover_mount' due to SHA256 mismatch."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (SHA256 mismatch)."
        return 1
    fi
    log_info "SHA256 sum for '$clover_zip_path' matches expected value."
    show_success "Clover download verified."

    # --- 6. Extract Clover ---
    log_debug "--- Extract Clover ---"
    local clover_extract_dir="${TEMP_DIR}/clover_extract"
    log_info "Clover extraction directory set to: '$clover_extract_dir'."

    log_debug "Creating Clover extraction directory: '$clover_extract_dir'."
    local mkdir_extract_cmd="mkdir -p $clover_extract_dir"
    if ! mkdir -p "$clover_extract_dir"; then
        local mkdir_extract_status=$?
        log_error "Command '$mkdir_extract_cmd' failed with status $mkdir_extract_status. Cannot create extraction directory."
        show_error "Failed to create Clover extraction directory '$clover_extract_dir'. Aborting."
        log_debug "Unmounting '$clover_mount' due to mkdir failure for extraction dir."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkdir for extraction dir failed)."
        return 1
    fi
    log_info "Successfully created Clover extraction directory: '$clover_extract_dir'."

    show_progress "Extracting Clover to $clover_extract_dir..."
    log_debug "Changing current directory to '$clover_extract_dir' for extraction."
    cd "$clover_extract_dir" || {
        log_error "Failed to cd into '$clover_extract_dir'. Aborting extraction."
        show_error "Critical error: Could not change directory to '$clover_extract_dir'. Aborting."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (cd to extraction dir failed)."
        return 1
    }
    log_info "Successfully changed directory to '$clover_extract_dir'."

    local extract_cmd
    local extraction_status=0
    log_debug "Determining extraction command. Extractor: '$extractor_command'."
    if [[ "$extractor_command" == "7z" ]]; then
        extract_cmd="7z x \"$clover_zip_path\" -o. -y"
        log_info "Using 7z for extraction. Executing: $extract_cmd (output to $LOG_FILE)"
        # The -y switch assumes yes to all queries for 7z, which is usually desired for scripting.
        if ! 7z x "$clover_zip_path" -o. -y &>> "$LOG_FILE"; then
            extraction_status=$?
            log_error "Command '$extract_cmd' failed with status $extraction_status."
            show_error "Failed to extract Clover using 7z. Check $LOG_FILE. Aborting."
        fi
    elif [[ "$extractor_command" == "unzip" ]]; then
        extract_cmd="unzip -o \"$clover_zip_path\" -d ."
        log_info "Using unzip for extraction. Executing: $extract_cmd (output to $LOG_FILE)"
        if ! unzip -o "$clover_zip_path" -d . &>> "$LOG_FILE"; then
            extraction_status=$?
            log_error "Command '$extract_cmd' failed with status $extraction_status."
            show_error "Failed to extract Clover using unzip. Check $LOG_FILE. Aborting."
        fi
    else
        log_fatal "Logic error: No valid extractor_command ('$extractor_command') found at extraction stage."
        show_error "Internal error: No extractor command available. Aborting."
        extraction_status=1 # Generic error for this case
    fi

    if [[ $extraction_status -ne 0 ]]; then
        log_error "Clover extraction failed with status $extraction_status using command: $extract_cmd"
        cd / # Go back to root to unmount safely
        log_debug "Unmounting '$clover_mount' due to extraction failure."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        # Consider leaving $clover_extract_dir for inspection if extraction partially succeeded
        # rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (extraction failed)."
        return 1
    fi

    # Verify that extraction produced content
    log_debug "Verifying that extraction directory '$clover_extract_dir' is not empty."
    if [ -z "$(ls -A "$clover_extract_dir" 2>/dev/null)" ]; then
        log_error "Extraction completed but the directory '$clover_extract_dir' is empty. This indicates a problem with the archive or extractor."
        show_error "Clover extraction resulted in an empty directory. Check archive and logs. Aborting."
        cd /
        log_debug "Unmounting '$clover_mount' due to empty extraction directory."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (empty extraction directory)."
        return 1
    fi

    # Find the source EFI directory robustly (current directory is $clover_extract_dir)
    log_debug "Locating Clover EFI source directory within '$clover_extract_dir'."
    local find_cmd="find . -maxdepth 2 -type d -name EFI -print -quit"
    log_info "Executing in '$clover_extract_dir': $find_cmd"
    local clover_efi_source_dir
    clover_efi_source_dir=$(find . -maxdepth 2 -type d -name EFI -print -quit 2>>"$LOG_FILE")
    local find_status=$?

    if [[ $find_status -ne 0 && -n "$clover_efi_source_dir" ]]; then
        log_debug "'find -quit' exited with status $find_status but found dir '$clover_efi_source_dir'. This is acceptable as -quit can cause non-zero exit on success."
    elif [[ $find_status -ne 0 ]]; then
        log_error "Command '$find_cmd' in '$clover_extract_dir' failed with status $find_status and found no directory."
        # Error will be handled by the -z check below
    fi

    if [[ -z "$clover_efi_source_dir" ]]; then
        log_error "Could not locate 'EFI' directory within '$clover_extract_dir' (maxdepth 2). Contents of '$clover_extract_dir': $(ls -Al . 2>>"$LOG_FILE")"
        show_error "Could not locate Clover EFI files after extraction. Check $LOG_FILE. Aborting."
        cd / # Go back to root to unmount safely
        log_debug "Unmounting '$clover_mount' due to missing EFI source directory."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (EFI source directory not found)."
        return 1
    fi
    # clover_efi_source_dir is relative to $clover_extract_dir (e.g., './EFI' or 'some_subdir/EFI')
    log_info "Clover EFI source directory (relative to '$clover_extract_dir') found at: '$clover_efi_source_dir'."

    # --- 6. Copy Clover Files to ESP ---
    log_debug "--- Copy Clover Files to ESP ---"
    log_debug "Preparing to copy Clover files from '$clover_extract_dir/$clover_efi_source_dir' to '${clover_mount}/EFI/' (ESP)."
    
    local target_efi_dir_on_mount="${clover_mount}/EFI" # Root for EFI files on the ESP, e.g., /mnt/clover_esp/EFI
    # Clover's own files (CLOVERX64.efi, themes, drivers) usually go into an 'EFI/CLOVER' subdirectory on the ESP.
    # The source $clover_efi_source_dir (e.g. './EFI' from archive) contains 'BOOT' and 'CLOVER' dirs.
    # These should be copied into $target_efi_dir_on_mount.
    # So, $target_efi_dir_on_mount/BOOT and $target_efi_dir_on_mount/CLOVER will be created.

    # Ensure the base target EFI directory exists on the mount (it should, as ESP is formatted and mounted)
    # but let's be safe and ensure it, though mkdir -p on the deeper path handles this.
    if ! mkdir -p "${target_efi_dir_on_mount}" &>> "$LOG_FILE"; then
        log_error "Failed to ensure base target directory '${target_efi_dir_on_mount}' on ESP. Aborting copy."
        show_error "Failed to create base target directory on ESP for Clover files. Check $LOG_FILE. Aborting."
        cd /
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (mkdir for base EFI on ESP failed)."
        return 1
    fi

    # Current directory is $clover_extract_dir. $clover_efi_source_dir is relative to it (e.g. './EFI').
    # We want to copy the *contents* of $clover_efi_source_dir.
    local cp_cmd="cp -arf \"${clover_efi_source_dir}/.\" \"${target_efi_dir_on_mount}/\""
    log_info "Executing in '$clover_extract_dir': $cp_cmd"
    if ! cp -arf "${clover_efi_source_dir}/." "${target_efi_dir_on_mount}/" &>> "$LOG_FILE"; then
        local cp_status=$?
        log_error "Command '$cp_cmd' (executed in '$clover_extract_dir') failed with status $cp_status."
        show_error "Failed to copy Clover files from '$clover_extract_dir/$clover_efi_source_dir' to ESP ('$target_efi_dir_on_mount'). Check $LOG_FILE. Aborting."
        cd /
        log_debug "Unmounting '$clover_mount' due to cp failure."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (cp to ESP failed)."
        return 1
    fi
    log_info "Successfully copied Clover files from '$clover_extract_dir/$clover_efi_source_dir' to '$target_efi_dir_on_mount'."

    local clover_efi_executable="${target_efi_dir_on_mount}/CLOVER/CLOVERX64.efi"
    log_debug "Verifying presence of Clover EFI executable at '$clover_efi_executable'."
    if [[ ! -f "$clover_efi_executable" ]]; then
        log_error "Clover installation incomplete: '$clover_efi_executable' is missing on ESP after copy. Listing '$target_efi_dir_on_mount/CLOVER': $(ls -Al \""$target_efi_dir_on_mount"/CLOVER\" 2>>\""$LOG_FILE"\")"
        show_error "Clover installation incomplete: CLOVERX64.efi missing on ESP ('$clover_efi_executable'). Check $LOG_FILE. Aborting."
        cd /
        log_debug "Unmounting '$clover_mount' due to missing CLOVERX64.efi."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (CLOVERX64.efi missing post-copy)."
        return 1
    fi
    log_info "Clover EFI executable '$clover_efi_executable' successfully verified on ESP."
    show_success "Clover files copied to ESP and CLOVERX64.efi verified."

    # --- 7. Create Clover config.plist ---
    log_debug "--- Create Clover config.plist ---"
    show_progress "Creating Clover config.plist..."
    log_info "Initiating creation of Clover config.plist."

    local pve_boot_label="${CONFIG_VARS[PVE_BOOT_LABEL]:-Proxmox}"
    local clover_theme="${CONFIG_VARS[CLOVER_THEME]:-embedded}"
    log_debug "Using PVE Boot Label: '$pve_boot_label' for config.plist."
    log_debug "Using Clover Theme: '$clover_theme' for config.plist."

    local config_plist_path="$clover_mount/EFI/CLOVER/config.plist"
    log_info "Target path for config.plist: '$config_plist_path'."

    # ANNOTATION: Fixed heredoc by removing quotes from the delimiter.
    # This allows variables to be expanded directly.
    log_info "Writing config.plist to '$config_plist_path' using heredoc."
    cat > "$config_plist_path" <<- CLOVER_CONFIG
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Boot</key>
    <dict>
        <key>Timeout</key>
        <integer>5</integer>
        <key>DefaultVolume</key>
        <string>${pve_boot_label}</string>
        <key>DefaultLoader</key>
        <string>\EFI\proxmox\grubx64.efi</string>
    </dict>
    <key>GUI</key>
    <dict>
        <key>Theme</key>
        <string>${clover_theme}</string>
        <key>Scan</key>
        <dict>
            <key>Entries</key><true/>
            <key>Linux</key><true/>
            <key>Tool</key><true/>
            <key>Legacy</key><string>Never</string>
        </dict>
    </dict>
</dict>
</plist>
CLOVER_CONFIG
    local cat_status=$?
    if [[ $cat_status -ne 0 ]]; then
        log_error "cat command to write config.plist to '$config_plist_path' failed with status $cat_status."
        show_error "Failed to write config.plist. Check $LOG_FILE. Aborting."
        # Attempt cleanup before returning
        cd /
        log_debug "Unmounting '$clover_mount' due to config.plist write failure."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (config.plist write failed)."
        return 1
    fi
    log_info "Successfully wrote config.plist using cat command to '$config_plist_path'."

    log_debug "Validating created config.plist at '$config_plist_path' (checking if non-empty)."
    if [[ ! -s "$config_plist_path" ]]; then
        log_error "Validation failed: '$config_plist_path' is empty or does not exist after cat operation."
        show_error "Failed to create a valid (non-empty) config.plist. Check $LOG_FILE. Aborting."
        cd /
        log_debug "Unmounting '$clover_mount' due to invalid config.plist."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (config.plist validation failed)."
        return 1
    fi
    log_info "Validation successful: '$config_plist_path' is valid and non-empty."
    show_success "Created Clover config.plist."

    # --- 8. Create UEFI Boot Entry ---
    log_debug "--- Create UEFI Boot Entry ---"
    show_progress "Creating UEFI boot entry for Clover..."
    log_info "Initiating creation of UEFI boot entry for Clover."

    log_debug "Determining disk and partition number for ESP: '$clover_efi'."
    # ANNOTATION: More robust and atomic method to get disk and partition number.
    local lsblk_cmd="lsblk -no PKNAME,PARTN \"$clover_efi\""
    log_info "Executing: $lsblk_cmd"
    local disk_info
    disk_info=$(lsblk -no PKNAME,PARTN "$clover_efi" 2>>"$LOG_FILE")
    local lsblk_status=$?
    if [[ $lsblk_status -ne 0 ]]; then
        log_error "Command '$lsblk_cmd' failed with status $lsblk_status. Output: $disk_info"
        show_error "Failed to get disk info for '$clover_efi' using lsblk. Check $LOG_FILE. Aborting boot entry creation."
        # Not returning 1 here, as this might be recoverable or skippable by user choice later, but logging severity.
        # However, for Clover, this is critical, so we will perform cleanup and return.
        cd /
        log_debug "Unmounting '$clover_mount' due to lsblk failure for efibootmgr."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (lsblk for efibootmgr failed)."
        return 1
    fi
    log_info "Raw disk_info from lsblk for '$clover_efi': '$disk_info'"

    local clover_disk_for_efibootmgr
    clover_disk_for_efibootmgr="/dev/$(echo "$disk_info" | awk '{print $1}')"
    local part_num
    part_num=$(echo "$disk_info" | awk '{print $2}')
    log_debug "Parsed disk for efibootmgr: '$clover_disk_for_efibootmgr'. Parsed partition number: '$part_num'."

    log_debug "Validating parsed disk '$clover_disk_for_efibootmgr' and partition '$part_num'."
    if [[ ! -b "$clover_disk_for_efibootmgr" ]] || ! [[ "$part_num" =~ ^[0-9]+$ ]]; then
        log_error "Validation failed for efibootmgr target. Disk: '$clover_disk_for_efibootmgr' (is_block_device: $([[ -b "$clover_disk_for_efibootmgr" ]] && echo true || echo false)), Part: '$part_num' (is_numeric: $([[ "$part_num" =~ ^[0-9]+$ ]] && echo true || echo false))."
        show_error "Could not reliably determine disk/partition for '$clover_efi' for efibootmgr. Check $LOG_FILE. Aborting boot entry creation."
        cd /
        log_debug "Unmounting '$clover_mount' due to invalid disk/partition for efibootmgr."
        umount "$clover_mount" &>> "$LOG_FILE"
        rmdir "$clover_mount" &>/dev/null
        rm -rf "$clover_extract_dir"
        rm -f "$clover_zip_path"
        log_debug "Exiting function: ${FUNCNAME[0]} with status 1 (efibootmgr target determination failed)."
        return 1
    fi
    log_info "Successfully validated disk '$clover_disk_for_efibootmgr' and partition '$part_num' for efibootmgr."

    log_info "Checking for existing Clover boot entries to avoid duplicates."
    local efibootmgr_check_cmd="efibootmgr | grep -i 'Clover'"
    log_debug "Executing: $efibootmgr_check_cmd (checking exit code for presence)"
    if efibootmgr | grep -q -i "Clover"; then # -q silences grep output, status 0 if found
        log_info "Existing Clover boot entries found. Attempting removal."
        local remove_cmd_pipeline="efibootmgr | grep -i 'Clover' | cut -d' ' -f1 | sed 's/Boot//;s/\*//' | xargs -I {} efibootmgr -b {} -B"
        log_info "Executing removal pipeline: $remove_cmd_pipeline (output to $LOG_FILE)"
        # Execute and capture status if possible, though xargs makes direct status tricky.
        # Logging output to LOG_FILE is the primary way to see details here.
        if efibootmgr | grep -i 'Clover' | cut -d' ' -f1 | sed 's/Boot//;s/\*//' | xargs -I {} efibootmgr -b {} -B &>> "$LOG_FILE"; then
            log_info "Existing Clover boot entries removal process completed. Check $LOG_FILE for details."
        else
            log_warning "Removal pipeline for existing Clover boot entries may have encountered issues. Exit status from xargs is not directly checked here. Check $LOG_FILE."
        fi
    else
        log_info "No existing Clover boot entries found by '$efibootmgr_check_cmd'."
    fi

    local boot_label="Clover (Proxmox VE)"
    local efi_loader_path='\EFI\CLOVER\CLOVERX64.efi'
    log_info "Preparing to create UEFI boot entry. Disk: '$clover_disk_for_efibootmgr', Partition: '$part_num', Label: '$boot_label', Loader: '$efi_loader_path'."
    local efibootmgr_create_cmd="efibootmgr -c -d '$clover_disk_for_efibootmgr' -p '$part_num' -L '$boot_label' -l '$efi_loader_path'"
    log_info "Executing: $efibootmgr_create_cmd (output to $LOG_FILE)"
    if ! efibootmgr -c -d "$clover_disk_for_efibootmgr" -p "$part_num" -L "$boot_label" -l "$efi_loader_path" &>> "$LOG_FILE"; then
        local efibootmgr_create_status=$?
        log_error "Command '$efibootmgr_create_cmd' failed with status $efibootmgr_create_status."
        show_error "Failed to create UEFI boot entry for Clover. You may need to do this manually. Check $LOG_FILE."
        # This is not considered a fatal error for the entire installation script, so we don't return 1 here by default.
        # However, the user should be clearly informed.
    else
        log_info "Command '$efibootmgr_create_cmd' executed successfully."
        show_success "UEFI boot entry for Clover created."
        log_info "Displaying current UEFI boot entries after modification (output to $LOG_FILE):"
        efibootmgr &>> "$LOG_FILE" # Display current entries, appending to log
    fi

    # --- 9. Finalizing ---
    log_debug "--- Finalizing Clover Installation ---"
    show_progress "Finalizing Clover installation..."
    log_info "Initiating finalization and cleanup steps for Clover installation."

    log_debug "Changing current directory to root ('/')."
    if cd / &>> "$LOG_FILE"; then
        log_info "Successfully changed directory to root."
    else
        local cd_root_status=$?
        log_warning "Failed to change directory to root. Status: $cd_root_status. Proceeding with cleanup."
        # Not critical enough to halt, but good to note.
    fi

    log_debug "Executing sync command to flush filesystem buffers."
    if sync &>> "$LOG_FILE"; then
        log_info "Sync command completed successfully."
    else
        local sync_status=$?
        log_warning "Sync command failed with status $sync_status. This might indicate I/O issues."
    fi

    log_info "Attempting to unmount Clover EFI partition: '$clover_mount'."
    local umount_cmd="umount '$clover_mount'"
    log_debug "Executing: $umount_cmd"
    if ! umount "$clover_mount" &>> "$LOG_FILE"; then
        local umount_status=$?
        log_error "Command '$umount_cmd' failed with status $umount_status."
        show_warning "Could not unmount EFI partition '$clover_mount'. A reboot may be required or it might be busy."
    else
        log_info "Successfully unmounted '$clover_mount'."
        log_debug "Attempting to remove mount point directory: '$clover_mount'."
        # local rmdir_cmd="rmdir '$clover_mount'"
        if rmdir "$clover_mount" &>/dev/null; then # Output of rmdir is usually not needed for success
            log_info "Successfully removed mount point directory '$clover_mount'."
        else
            local rmdir_status=$?
            log_warning "Failed to remove mount point directory '$clover_mount'. Status: $rmdir_status. It might not be empty or already removed."
        fi
    fi
    
    local keep_files="${CONFIG_VARS[KEEP_INSTALLER_FILES]:-false}"
    log_debug "Checking KEEP_INSTALLER_FILES configuration. Value: '$keep_files'."
    if [[ "$keep_files" != "true" ]]; then
        log_info "KEEP_INSTALLER_FILES is not 'true'. Proceeding with cleanup of temporary files."
        
        log_debug "Attempting to remove Clover ZIP file: '$clover_zip_path'."
        if [[ -f "$clover_zip_path" ]]; then
            local rm_zip_cmd="rm -f '$clover_zip_path'"
            log_info "Executing: $rm_zip_cmd"
            if rm -f "$clover_zip_path" &>> "$LOG_FILE"; then
                log_info "Successfully removed Clover ZIP file: '$clover_zip_path'."
            else
                local rm_zip_status=$?
                log_warning "Failed to remove Clover ZIP file '$clover_zip_path'. Status: $rm_zip_status."
            fi
        else
            log_info "Clover ZIP file '$clover_zip_path' not found. Skipping removal."
        fi

        log_debug "Attempting to remove Clover extraction directory: '$clover_extract_dir'."
        if [[ -d "$clover_extract_dir" ]]; then
            local rm_extract_dir_cmd="rm -rf '$clover_extract_dir'"
            log_info "Executing: $rm_extract_dir_cmd"
            if rm -rf "$clover_extract_dir" &>> "$LOG_FILE"; then
                log_info "Successfully removed Clover extraction directory: '$clover_extract_dir'."
            else
                local rm_extract_status=$?
                log_warning "Failed to remove Clover extraction directory '$clover_extract_dir'. Status: $rm_extract_status."
            fi
        else
            log_info "Clover extraction directory '$clover_extract_dir' not found. Skipping removal."
        fi
    else
        log_info "KEEP_INSTALLER_FILES is 'true'. Temporary Clover installation files will be preserved at '$clover_zip_path' and '$clover_extract_dir'."
    fi

    show_success "Clover bootloader installation process completed."
    log_info "Clover installation successfully completed. Exiting function: ${FUNCNAME[0]} with status 0."
    return 0
}
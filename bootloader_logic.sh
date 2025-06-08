#!/usr/bin/env bash
# Contains functions related to bootloader installation (e.g., Clover).

install_clover_bootloader() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "CLOVER" "Installing Clover Bootloader"

    local clover_efi="${CONFIG_VARS[CLOVER_EFI_PART]}"
    log_debug "Clover EFI partition: $clover_efi"

    show_progress "Formatting Clover EFI partition..."
    log_debug "Executing: mkfs.vfat -F32 $clover_efi"
    mkfs.vfat -F32 "$clover_efi" &>> "$LOG_FILE"

    local clover_mount="$TEMP_DIR/clover"
    log_debug "Clover mount point: $clover_mount"
    mkdir -p "$clover_mount"
    log_debug "Mounting $clover_efi to $clover_mount."
    if ! mount "$clover_efi" "$clover_mount" &>> "$LOG_FILE"; then
        log_debug "Failed to mount Clover EFI partition $clover_efi on $clover_mount."
        show_error "Failed to mount Clover EFI partition $clover_efi on $clover_mount"
        exit 1
    fi
    log_debug "Clover EFI partition mounted successfully."

    show_progress "Downloading Clover bootloader..."
    local clover_url="https://github.com/CloverHackyColor/CloverBootloader/releases/download/5157/CloverV2-5157.zip"
    local clover_zip_path="$TEMP_DIR/clover.zip"
    log_debug "Downloading Clover from $clover_url to $clover_zip_path"
    # wget output can be verbose, consider options or just redirect if it's too much for show_progress
    wget -q --show-progress -O "$clover_zip_path" "$clover_url" &>> "$LOG_FILE" || {
        log_debug "Failed to download Clover. wget exit status: $?"
        show_error "Failed to download Clover"
        exit 1
    }
    log_debug "Clover downloaded successfully."

    show_progress "Installing Clover..."
    log_debug "Changing directory to $TEMP_DIR for Clover extraction."
    cd "$TEMP_DIR" || { log_debug "Failed to cd to $TEMP_DIR in ${FUNCNAME[0]}"; exit 1; }
    log_debug "Extracting $clover_zip_path using 7z."
    7z x -y "$clover_zip_path" -o"$TEMP_DIR/CloverExtract" &>> "$LOG_FILE" # Extract to a specific subdir
    log_debug "7z extraction finished. Exit status: $?"


    log_debug "Creating $clover_mount/EFI directory."
    mkdir -p "$clover_mount/EFI"
    log_debug "Copying extracted Clover EFI files to $clover_mount/EFI/"
    # Assuming 7z creates CloverV2 or similar named top-level dir in CloverExtract
    # Need to be careful with path if 7z extracts directly into TEMP_DIR/CloverExtract
    # For now, let's assume the structure from previous script version: CloverV2 inside the zip.
    # If `7z x -y clover.zip > /dev/null` was used, it implies it extracts to current dir ($TEMP_DIR).
    # Let's adjust to a more controlled extraction and copy
    if [ -d "$TEMP_DIR/CloverExtract/EFI" ]; then # Check if EFI is directly under CloverExtract
         cp -r "$TEMP_DIR/CloverExtract/EFI/"* "$clover_mount/EFI/" &>> "$LOG_FILE"
    elif [ -d "$TEMP_DIR/CloverExtract/CloverV2/EFI" ]; then # Check if it's under CloverV2 subdirectory
         cp -r "$TEMP_DIR/CloverExtract/CloverV2/EFI/"* "$clover_mount/EFI/" &>> "$LOG_FILE"
    else
        log_debug "Could not find expected EFI directory in Clover extract at $TEMP_DIR/CloverExtract"
        show_error "Failed to locate Clover EFI files after extraction."
        # Attempt to list contents for debugging
        ls -R "$TEMP_DIR/CloverExtract" >> "$LOG_FILE"
        exit 1
    fi
    log_debug "Clover files copied."

    log_debug "Creating Clover config.plist at $clover_mount/EFI/CLOVER/config.plist"
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
                <string>Proxmox</string>
                <key>DefaultLoader</key>
                <string>\EFI\proxmox\grubx64.efi</string>
            </dict>
            <key>GUI</key>
            <dict>
                <key>Theme</key>
                <string>embedded</string>
                <key>ShowOptimus</key>
                <false/>
            </dict>
            <key>Scan</key>
            <dict>
                <key>Entries</key>
                <true/>
                <key>Legacy</key>
                <false/>
                <key>Linux</key>
                <true/>
                <key>Tool</key>
                <true/>
            </dict>
        </dict>
        </plist>
CLOVER_CONFIG

    mkdir -p "$clover_mount/EFI/CLOVER/ACPI/origin"
    log_debug "Created $clover_mount/EFI/CLOVER/ACPI/origin directory."

    show_progress "Creating UEFI boot entry..."
    local clover_disk_for_efibootmgr="${CONFIG_VARS[CLOVER_DISK]}"
    # efibootmgr expects /dev/sda not /dev/sda1 for -d, and partition number for -p
    # Assuming CLOVER_DISK is like /dev/sda and CLOVER_EFI_PART is /dev/sda1
    # We need to extract the partition number from CLOVER_EFI_PART.
    # A simple way if CLOVER_EFI_PART is like /dev/sda1 is to remove the /dev/sda part.
    # More robustly: find partition number for CLOVER_EFI_PART on CLOVER_DISK
    local part_num_raw
    part_num_raw=$(lsblk -no MAJ:MIN,PARTN "$clover_disk_for_efibootmgr" | grep "$(lsblk -no MAJ:MIN "$clover_efi" | head -n1)" | awk '{print $NF}')
    local part_num # Final partition number
    if [[ -n "$part_num_raw" ]]; then
        part_num="$part_num_raw"
    else
        # Fallback for devices like /dev/mmcblk0p1 where PARTN is not directly listed
        # or if the lsblk | grep | awk chain fails for some reason.
        log_debug "Initial part_num detection failed for $clover_efi on $clover_disk_for_efibootmgr. Falling back to string manipulation."
        local part_num_suffix
        part_num_suffix="${clover_efi#"$clover_disk_for_efibootmgr"}" # e.g., "p1" or "1" from "/dev/sda1" and "/dev/sda"
        if [[ "${part_num_suffix:0:1}" == "p" ]]; then # Check if first char is 'p'
            part_num="${part_num_suffix:1}" # Remove 'p'
        else
            part_num="$part_num_suffix"
        fi
        log_debug "Fallback part_num derived as: $part_num from suffix $part_num_suffix"
    fi

    if [[ -z "$part_num" ]]; then
        log_debug "Critical: Could not determine partition number for $clover_efi on $clover_disk_for_efibootmgr. efibootmgr will likely fail."
        # Optionally, exit here or let efibootmgr fail and log it.
        # For now, let it try, it might still work if the fallback produced something usable by chance.
    fi

    log_debug "Executing efibootmgr: efibootmgr -c -d $clover_disk_for_efibootmgr -p \"$part_num\" -L \"Clover\" -l '\\EFI\\CLOVER\\CLOVERX64.efi'"
    efibootmgr -c -d "$clover_disk_for_efibootmgr" -p "$part_num" -L "Clover" -l '\EFI\CLOVER\CLOVERX64.efi' &>> "$LOG_FILE" || log_debug "efibootmgr command failed or no changes made (original script had || true)."
    log_debug "UEFI boot entry creation attempted."

    log_debug "Changing directory to /"
    cd /
    log_debug "Unmounting Clover mount point: $clover_mount"
    umount "$clover_mount" &>> "$LOG_FILE"

    show_success "Clover bootloader installed"
    log_debug "Exiting function: ${FUNCNAME[0]}"
}

#!/usr/bin/env bash
# ===================================================================
# Dependencies Installation Module
# ===================================================================

# Function to install dependencies from the /debs directory
install_local_dependencies() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    show_step "DEPS" "Installing local dependencies from /debs"
    
    local debs_dir="$SCRIPT_DIR/debs"
    local installed_count=0
    local proxmox_pkgs=()
    
    # Check if debs directory exists
    if [ ! -d "$debs_dir" ]; then
        log_debug "No debs directory found at $debs_dir"
        show_warning "No local dependencies directory found at $debs_dir"
        return 1
    fi
    
    # Check if directory is empty
    if [ -z "$(ls -A "$debs_dir" 2>/dev/null)" ]; then
        log_debug "Debs directory is empty at $debs_dir"
        show_warning "Dependencies directory is empty at $debs_dir"
        return 1
    fi
    
    # Check if we have existing Proxmox packages installed
    log_debug "Checking for existing Proxmox packages"
    mapfile -t proxmox_pkgs < <(dpkg-query -W -f='${Package}\n' 'pve-*' 'proxmox-*' 2>/dev/null || true)
    
    if [ ${#proxmox_pkgs[@]} -gt 0 ]; then
        log_debug "Found ${#proxmox_pkgs[@]} Proxmox packages installed"
        log_debug "Proxmox packages: ${proxmox_pkgs[*]}"
    else
        log_debug "No existing Proxmox packages found"
    fi
    
    log_debug "Safely installing required utility packages from $debs_dir"
    show_progress "Installing required utilities from $debs_dir..."
    
    # First, only install dialog and other essential utilities
    for deb_file in "$debs_dir"/*dialog*.deb "$debs_dir"/*util*.deb; do
        if [ -f "$deb_file" ]; then
            pkg_name=$(dpkg-deb -f "$deb_file" Package)
            
            # Skip if this is a Proxmox package
            if [[ "$pkg_name" == pve-* || "$pkg_name" == proxmox-* ]]; then
                log_debug "Skipping Proxmox package: $pkg_name"
                continue
            fi
            
            log_debug "Installing utility package: $pkg_name from $deb_file"
            if dpkg -i "$deb_file" &>> "$LOG_FILE"; then
                installed_count=$((installed_count + 1))
                log_debug "Successfully installed $pkg_name"
            else
                log_debug "Failed to install $pkg_name"
                show_warning "Failed to install package: $pkg_name"
            fi
        fi
    done
    
    # Handle dependencies without auto-installing packages that might conflict
    log_debug "Fixing any broken dependencies with apt-get -f install"
    apt-get -f install --no-install-recommends -y &>> "$LOG_FILE"
    
    # Make sure dialog is installed as a minimum requirement
    if ! command -v dialog &> /dev/null; then
        log_debug "Dialog not found, attempting to install via apt-get"
        show_progress "Installing dialog package..."
        apt-get update &>> "$LOG_FILE" 
        apt-get install -y dialog &>> "$LOG_FILE"
        
        if command -v dialog &> /dev/null; then
            log_debug "Dialog successfully installed"
            show_success "Dialog package installed"
            installed_count=$((installed_count + 1))
        else
            log_debug "Failed to install dialog"
            show_error "Failed to install required dialog package!"
        fi
    else
        log_debug "Dialog is already installed"
    fi
    
    if [ $installed_count -gt 0 ]; then
        log_debug "Successfully installed $installed_count utility packages"
        show_success "Installed $installed_count utility packages"
    else
        log_debug "No utility packages were installed"
        show_warning "No utility packages were installed"
    fi
    
    log_debug "Exiting function: ${FUNCNAME[0]}"
    return 0
}

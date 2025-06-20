#!/usr/bin/env bash
# Contains functions related to bootloader installation.
# This script now primarily acts as a wrapper for more detailed bootloader scripts.

# Source the enhanced Clover bootloader installation script
# Ensure SCRIPT_DIR is available or adjust path accordingly
log_debug "Attempting to source clover_bootloader.sh..."
log_debug "SCRIPT_DIR is currently: '${SCRIPT_DIR:-not set}'."

if [[ -n "$SCRIPT_DIR" ]] && [[ -f "$SCRIPT_DIR/clover_bootloader.sh" ]]; then
    log_info "Found clover_bootloader.sh at '$SCRIPT_DIR/clover_bootloader.sh'. Sourcing it."
    # shellcheck source=clover_bootloader.sh
    source "$SCRIPT_DIR/clover_bootloader.sh"
    log_debug "Sourcing '$SCRIPT_DIR/clover_bootloader.sh' completed."
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/clover_bootloader.sh" ]]; then
    log_info "SCRIPT_DIR not set or clover_bootloader.sh not found there. Found clover_bootloader.sh at '$(dirname "${BASH_SOURCE[0]}")/clover_bootloader.sh' (relative to this script). Sourcing it."
    # shellcheck source=clover_bootloader.sh
    source "$(dirname "${BASH_SOURCE[0]}")/clover_bootloader.sh"
    log_debug "Sourcing from '$(dirname "${BASH_SOURCE[0]}")/clover_bootloader.sh' completed."
else
    log_error "Failed to find clover_bootloader.sh using SCRIPT_DIR ('${SCRIPT_DIR:-not set}/clover_bootloader.sh') or relative path ('$(dirname "${BASH_SOURCE[0]}")/clover_bootloader.sh')."
    # If log_fatal is available (common_utils sourced), use it.
    if type log_fatal &>/dev/null; then
        log_fatal "clover_bootloader.sh not found. This is a critical dependency for Clover installation."
    else
        echo "CRITICAL ERROR: clover_bootloader.sh not found. Cannot proceed with Clover installation." >&2
    fi
    # Depending on installer structure, you might exit or return an error code.
    # For now, we'll assume the calling function handles the missing dependency, but this is a critical failure for this script's purpose.
    # Consider adding 'return 1' here if this script is sourced by another that can handle the failure.
fi

# Wrapper function for Clover installation, maintaining the original expected function name.
install_clover_bootloader() {
    log_debug "Entering function: ${FUNCNAME[0]} (wrapper for enhanced Clover installer)"
    # show_step is called within the enhanced function, so not strictly needed here unless for an outer step.
    # show_step "CLOVER" "Initiating Clover Bootloader Installation (Wrapper)"

    if ! type install_enhanced_clover_bootloader &>/dev/null; then
        show_error "Enhanced Clover installer function (install_enhanced_clover_bootloader) is not available. The clover_bootloader.sh script might not be sourced correctly or is missing."
        log_error "Function 'install_enhanced_clover_bootloader' not found. Check sourcing of clover_bootloader.sh."
        return 1 # Indicate critical failure
    fi

    # Call the main function from the sourced script
    install_enhanced_clover_bootloader "$@"
    local clover_install_status=$?

    # Log and potentially show messages based on the return status from the enhanced installer
    if [[ $clover_install_status -eq 0 ]]; then
        log_info "Clover bootloader installation process completed successfully (via enhanced script)."
        # show_success is likely called by the enhanced script, avoid duplication unless desired.
    elif [[ $clover_install_status -eq 2 ]]; then # Specific code for user abort/skip
        log_warning "Clover bootloader installation was skipped or aborted by user (via enhanced script)."
        # show_warning is likely called by the enhanced script.
    else
        log_error "Clover bootloader installation failed (via enhanced script). Status: $clover_install_status"
        # show_error is likely called by the enhanced script.
    fi
    
    log_debug "Exiting function: ${FUNCNAME[0]} (wrapper), status: $clover_install_status"
    return $clover_install_status
}

# Add other bootloader-related functions here if needed in the future,
# or source other specific bootloader scripts (e.g., for GRUB, systemd-boot)

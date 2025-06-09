#!/bin/bash
# FAILSAFE UI FUNCTIONS - NO COLORS, NO UNICODE, NO BULL
# Simple, reliable functions that just work

# Guard against multiple sourcing
if [ -n "${_UI_FUNCS_LOADED:-}" ]; then
    return 0
fi
_UI_FUNCS_LOADED=1

# Debug logging - logs to LOG_FILE if available
log_debug() {
    [ -z "$1" ] && return 0
    if [ -n "${LOG_FILE:-}" ]; then
        printf "[DEBUG] %s: %s\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$1" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

# Simple yes/no prompt - returns 0 for yes, 1 for no
prompt_yes_no() {
    [ -z "$1" ] && return 1
    local answer
    
    while true; do
        printf "%s [y/n]: " "$1" >&2
        read -r answer
        case "${answer}" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) printf "Please answer yes or no.\n" >&2 ;;
        esac
    done
}

# Display a header with simple ASCII formatting
show_header() {
    local text="$1"
    [ -z "$text" ] && text="Header"
    local line="----------------------------------------"
    
    printf "\n%s\n" "$line"
    printf "| %s\n" "$text"
    printf "%s\n\n" "$line"
}

# Display a step label
show_step() {
    local step="$1"
    local desc="${2:-}"
    
    printf "\n[%s] %s\n" "$step" "$desc"
}

# Show a progress message
show_progress() {
    [ -z "$1" ] && return 0
    printf "  * %s\n" "$1"
}

# Show a success message
show_success() {
    [ -z "$1" ] && return 0
    printf "  + SUCCESS: %s\n" "$1"
}

# Show an error message
show_error() {
    local message="$1"
    local script_name="${2:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    local line_num="${3:-}"
    
    local line_info=""
    [ -n "$line_num" ] && line_info=" line $line_num"
    
    printf "\n  ! ERROR in %s%s: %s\n\n" "$script_name" "$line_info" "$message" >&2
}

# Show a warning message

# Select an option from a list
# Usage: _select_option_from_list "Prompt message" "Option 1" "Option 2" ...
# Returns 0 on success, 1 on cancellation/empty input.
# Selected option is echoed to stdout.
_select_option_from_list() {
    local prompt_msg="$1"
    shift
    local options=("$@")
    local num_options=${#options[@]}
    local choice
    local i

    log_debug "_select_option_from_list: Received prompt: $prompt_msg"
    local opt_idx
    for opt_idx in "${!options[@]}"; do
        log_debug "_select_option_from_list: Option $opt_idx: '${options[$opt_idx]}'"
    done

    if [[ $num_options -eq 0 ]]; then
        log_debug "_select_option_from_list called with no options."
        return 1 # No options to choose from
    fi

    printf "\n%s\n" "$prompt_msg"
    for i in $(seq 0 $((num_options - 1))); do
        printf "  %2d) %s\n" $((i + 1)) "${options[$i]}"
    done
    printf "   q) Quit/Cancel\n"

    while true; do
        read -r -p "Enter your choice (1-$num_options or q): " choice
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]') # Normalize to lowercase

        if [[ -z "$choice" || "$choice" == "q" || "$choice" == "cancel" ]]; then
            log_debug "_select_option_from_list: User cancelled."
            return 1 # Cancelled
        fi

        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le $num_options ]]; then
            log_debug "_select_option_from_list: User selected option $choice: ${options[$((choice - 1))]}"
            echo "${options[$((choice - 1))]}" # Echo selected option text
            return 0 # Success
        else
            printf "Invalid choice. Please enter a number between 1 and %s, or 'q' to quit.\n" "$num_options" >&2
        fi
    done
}

# Show a warning message
show_warning() {
    [ -z "$1" ] && return 0
    printf "  ! WARNING: %s\n" "$1"
}

# Show a message

#!/usr/bin/env bash

#############################################################
# Logging and UI Functions (Refined Version)
#
# This script provides robust logging and terminal UI functions.
# It is designed to be sourced by a main installer script.
#############################################################

# --- Color and Symbol Definitions ---
# Using tput for maximum terminal compatibility.
# Only define if not already defined to avoid readonly variable conflicts
[ -z "${BOLD-}" ] && BOLD=$(tput bold 2>/dev/null || true)
[ -z "${BLUE-}" ] && BLUE=$(tput setaf 4 2>/dev/null || true)
[ -z "${MAGENTA-}" ] && MAGENTA=$(tput setaf 5 2>/dev/null || true)
[ -z "${YELLOW-}" ] && YELLOW=$(tput setaf 3 2>/dev/null || true)
[ -z "${RED-}" ] && RED=$(tput setaf 1 2>/dev/null || true)
[ -z "${RESET-}" ] && RESET=$(tput sgr0 2>/dev/null || true)

# Using unicode characters for modern terminals.
CHECK="✔"
CROSS="✖"
BULLET="•"
WARN_ICON="⚠"

# LOG_FILE is expected to be exported from the main script.
# Example: export LOG_FILE="/var/log/my_installer.log"
#
#############################################################

# Writes a debug message to the configured log file.
log_debug() {
    # Ensure LOG_FILE is set and not empty before trying to write to it.
    if [[ -n "${LOG_FILE:-}" ]]; then
        # Using printf for portability and quoting to handle spaces correctly.
        printf "[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "$1" >> "$LOG_FILE"
    else
        # Fallback if LOG_FILE is not set. Redirects to standard error.
        printf "[DEBUG_FALLBACK][$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "$1" >&2
    fi
}

# Displays a centered, double-bordered header.
show_header() {
    local text="$1"
    local width=70
    local padding=$(( (width - 2 - ${#text}) / 2 )) # Adjust for spaces around text
    
    # ANNOTATION: Replaced `seq` with a more efficient `printf | tr` method.
    # This avoids forking a sub-process for `seq`.
    local line
    line=$(printf '%*s' "$width" '' | tr ' ' '═')

    printf "\n%s%s%s%s\n" "${BLUE}" "${BOLD}" "${line}" "${RESET}"
    printf "%s%s %*s%s%*s %s\n" "${BLUE}" "${BOLD}" "$padding" "" "$text" "$((width - 2 - ${#text} - padding))" "" "${RESET}"
    printf "%s%s%s%s\n\n" "${BLUE}" "${BOLD}" "${line}" "${RESET}"
}

# Displays a major installation step.
show_step() {
    printf "\n%s%s[%s]%s %s%s%s\n" "${MAGENTA}" "${BOLD}" "$1" "${RESET}" "${BOLD}" "$2" "${RESET}"
}

# Displays an informational progress message.
show_progress() {
    printf "  %s %s\n" "${BULLET}" "$1"
}

# Displays a success message.
show_success() {
    printf "  %s %s\n" "${CHECK}" "$1"
}

# Displays an error message to standard error, including script name and line number.
show_error() {
    # $1: error message
    # $2: script name (optional)
    # $3: line number (optional)
    local message="$1"
    local script_name="${2:-$(basename "${BASH_SOURCE[1]:-$0}")}" # Caller script or current
    local line_info="${3:+"at line $3"}" # Add 'at line' only if $3 is provided

    printf "  %s %sERROR in %s %s: %s%s\n" "${CROSS}" "${RED}" "$script_name" "$line_info" "$message" "${RESET}" >&2
}

# Displays a warning message.
show_warning() {
    # ANNOTATION: Placed the warning icon before the text for better visual flow.
    printf "  %s%s %s%s\n" "${YELLOW}" "${WARN_ICON}" "$1" "${RESET}"
}

# Prompts the user with a yes/no question.
# Usage: prompt_yes_no "Your question here?"
# Returns: 0 for Yes, 1 for No.
prompt_yes_no() {
    local prompt_text="$1"
    local yn
    while true; do
        read -r -p "$prompt_text [y/n]: " yn
        case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer yes (y) or no (n)." >&2 ;;
        esac
    done
}

# Prompts the user to select an option from a list.
# Usage: _select_option_from_list "Prompt for user:" SELECTED_VAR_NAME "Option 1" "Option 2" "Option 3" ... "Cancel"
# The selected option string is stored in the variable name provided by SELECTED_VAR_NAME.
# Returns: 0 on successful selection, 1 if cancelled or error.
_select_option_from_list() {
    local prompt_text="$1"
    local -n result_var_name="$2" # Indirect variable reference (nameref)
    shift 2 # Remove prompt and result_var_name from arguments, leaving only options
    local options=("$@")
    local num_options=${#options[@]}
    local choice

    if [[ $num_options -eq 0 ]]; then
        show_error "_select_option_from_list: No options provided."
        return 1
    fi

    echo # Newline for clarity
    echo "$prompt_text"
    for i in $(seq 0 $((num_options - 1))); do
        echo "  $((i + 1)). ${options[$i]}"
    done

    while true; do
        read -r -p "Enter choice [1-$num_options]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $num_options ]]; then
            result_var_name="${options[$((choice - 1))]}"
            # Check if the selected option is "Cancel" (case-insensitive)
            if [[ "$(echo "${result_var_name}" | tr '[:upper:]' '[:lower:]')" == "cancel" ]]; then
                log_debug "Selection cancelled by user choosing 'Cancel' option."
                return 1 # Treat "Cancel" option as a failure/cancel return
            fi
            return 0 # Success
        else
            show_warning "Invalid selection. Please enter a number between 1 and $num_options."
        fi
    done
}

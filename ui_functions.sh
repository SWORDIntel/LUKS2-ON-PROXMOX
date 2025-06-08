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

# Displays an error message to standard error.
show_error() {
    printf "  %s %s%s%s\n" "${CROSS}" "${RED}" "$1" "${RESET}" >&2
}

# Displays a warning message.
show_warning() {
    # ANNOTATION: Placed the warning icon before the text for better visual flow.
    printf "  %s%s %s%s\n" "${YELLOW}" "${WARN_ICON}" "$1" "${RESET}"
}
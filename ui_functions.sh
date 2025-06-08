#!/usr/bin/env bash

#############################################################
# Logging and UI Functions
#
# Assumes the following variables are defined elsewhere:
# LOG_FILE: Path to the log file for debug messages.
#
# It also requires color and symbol variables. Example definitions:
# BOLD=$(tput bold)
# BLUE=$(tput setaf 4)
# MAGENTA=$(tput setaf 5)
# YELLOW=$(tput setaf 3)
# RED=$(tput setaf 1)
# RESET=$(tput sgr0)
#
# CHECK="✔"
# CROSS="✖"
# BULLET="•"
#
#############################################################

# LOG_FILE is expected to be exported as a global variable from the main script.
log_debug() {
    # Ensure LOG_FILE is set and not empty before trying to write to it.
    if [[ -n "${LOG_FILE:-}" ]]; then
        # Using subshell for date to avoid issues if script uses `set -e` and date fails (unlikely)
        # ANNOTATION: Changed echo to printf for portability and quoted "$1" to handle spaces.
        printf "[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "$1" >> "$LOG_FILE"
    else
        # Fallback if LOG_FILE is not set, though this indicates a problem.
        # ANNOTATION: Changed to printf and quoted "$1". Redirects to stderr.
        printf "[DEBUG_FALLBACK][$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "$1" >&2
    fi
}

show_header() {
    local text="$1"
    local width=70
    local padding=$(( (width - ${#text}) / 2 ))
    # ANNOTATION: Switched from 'echo -e' to 'printf' for better portability.
    # The 'printf...seq' trick is a clever way to repeat a character.
    printf "\n%s%s%s%s\n" "${BLUE}" "${BOLD}" "$(printf '═%.0s' $(seq 1 $width))" "${RESET}"
    printf "%s%s%*s%s%s\n" "${BLUE}" "${BOLD}" "$padding" "" "$text" "${RESET}" # Using printf's own padding
    printf "%s%s%s%s\n\n" "${BLUE}" "${BOLD}" "$(printf '═%.0s' $(seq 1 $width))" "${RESET}"
}

# ANNOTATION: All 'show_*' functions below have been updated to use printf and quote arguments.

show_step() { printf "\n%s%s[%s]%s %s%s%s\n" "${MAGENTA}" "${BOLD}" "$1" "${RESET}" "${BOLD}" "$2" "${RESET}"; }
show_progress() { printf "  %s %s\n" "${BULLET}" "$1"; }
show_success() { printf "  %s %s\n" "${CHECK}" "$1"; }
show_error() { printf "  %s %s%s%s\n" "${CROSS}" "${RED}" "$1" "${RESET}" >&2; }
show_warning() { printf "  %s %s⚠ %s%s\n" "${YELLOW}" "$1" "${RESET}"; } # Keeping
 ⚠ as it's a stylistic choice
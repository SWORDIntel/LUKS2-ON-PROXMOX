#!/usr/bin/env bash

#############################################################
# Logging and UI Functions
#############################################################

# LOG_FILE is expected to be exported as a global variable from the main script.
log_debug() {
    # Ensure LOG_FILE is set and not empty before trying to write to it.
    if [[ -n "${LOG_FILE:-}" ]]; then
        # Using subshell for date to avoid issues if script uses `set -e` and date fails (unlikely)
        echo "[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    else
        # Fallback if LOG_FILE is not set, though this indicates a problem.
        echo "[DEBUG_FALLBACK][$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
    fi
}

show_header() {
    local text="$1"
    local width=70
    local padding=$(( (width - ${#text}) / 2 ))
    echo -e "\n${BLUE}${BOLD}""$(printf '═%.0s' $(seq 1 $width))""${RESET}"
    echo -e "${BLUE}${BOLD}""$(printf ' %.0s' $(seq 1 $padding))""$text""${RESET}"
    echo -e "${BLUE}${BOLD}""$(printf '═%.0s' $(seq 1 $width))""${RESET}\n"
}

show_step() { echo -e "\n${MAGENTA}${BOLD}[$1]${RESET} ${BOLD}$2${RESET}"; }
show_progress() { echo -e "  ${BULLET} $1"; }
show_success() { echo -e "  ${CHECK} $1"; }
show_error() { echo -e "  ${CROSS} ${RED}$1${RESET}" >&2; }
show_warning() { echo -e "  ${YELLOW}⚠ $1${RESET}"; }

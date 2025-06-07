#!/usr/bin/env bash

#############################################################
# Logging and UI Functions
#############################################################
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

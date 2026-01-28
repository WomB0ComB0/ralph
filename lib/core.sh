#!/bin/bash

#######################################
# Color codes for terminal output
#######################################
declare -gr RED='\033[0;31m'
declare -gr GREEN='\033[0;32m'
declare -gr YELLOW='\033[1;33m'
declare -gr BLUE='\033[0;34m'
declare -gr MAGENTA='\033[0;35m'
declare -gr CYAN='\033[0;36m'
declare -gr NC='\033[0m' # No Color

#######################################
# Detect the operating system
# Outputs: linux, macos, windows, or unknown
#######################################
detect_os() {
    case "$(uname -s)" in
        Linux*)                 echo "linux";;
        Darwin*)                echo "macos";;
        CYGWIN*|MINGW*|MSYS*)   echo "windows";;
        *)                      echo "unknown";;
    esac
}

#######################################
# Detect the system architecture
# Outputs: amd64, arm64, arm, or unknown
#######################################
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64";;
        arm64|aarch64)  echo "arm64";;
        armv7l)         echo "arm";;
        *)              echo "unknown";;
    esac
}

# Initialize OS and architecture detection
OS_TYPE=$(detect_os)
declare -gr OS_TYPE
ARCH_TYPE=$(detect_arch)
declare -gr ARCH_TYPE

#######################################
# Logging functions
# All logs are written to LOG_FILE if set
#######################################
_log_message() {
    local color="$1"
    local level="$2"
    shift 2
    local message="$*"
    
    echo -e "${color}[${level}]${NC} ${message}" >&2
    
    # Only write to log file if it's defined and writable
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[${level}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info()    { _log_message "$BLUE"    "INFO"    "$@"; }
log_success() { _log_message "$GREEN"   "SUCCESS" "$@"; }
log_warning() { _log_message "$YELLOW"  "WARNING" "$@"; }
log_error()   { _log_message "$RED"     "ERROR"   "$@"; }
log_setup()   { _log_message "$MAGENTA" "SETUP"   "$@"; }

log_debug() {
    [[ "${VERBOSE:-false}" == "true" ]] && _log_message "$CYAN" "DEBUG" "$@" || true
}

log_metrics() {
    [[ -n "${METRICS_FILE:-}" ]] && echo "$*" >> "$METRICS_FILE" 2>/dev/null || true
}

#######################################
# Temporary file management
#######################################
declare -a TEMP_FILES=()

#######################################
# Cleanup function for temporary files
# Called automatically on script exit
#######################################
cleanup_temp_files() {
    local exit_code=$?
    
    for temp_file in "${TEMP_FILES[@]}"; do
        [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null
    done
    
    exit "$exit_code"
}

trap cleanup_temp_files EXIT INT TERM

#######################################
# Create a temporary file and track it for cleanup
# Returns: Path to temporary file
#######################################
create_temp_file() {
    local temp_file
    temp_file=$(mktemp) || {
        log_error "Failed to create temporary file"
        return 1
    }
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
}

#######################################
# Check if a command exists in PATH
# Arguments:
#   $1 - Command name to check
# Returns: 0 if exists, 1 otherwise
#######################################
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

#######################################
# Verify system compatibility
# Returns: 0 if compatible, 1 otherwise
#######################################
verify_system() {
    if [[ "$OS_TYPE" == "unknown" ]]; then
        log_error "Unsupported operating system: $(uname -s)"
        return 1
    fi
    
    if [[ "$ARCH_TYPE" == "unknown" ]]; then
        log_error "Unsupported architecture: $(uname -m)"
        return 1
    fi
    
    log_debug "System: $OS_TYPE ($ARCH_TYPE)"
    return 0
}
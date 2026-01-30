#!/bin/bash

#######################################
# Color codes for terminal output
#######################################
readonly _RALPH_COLOR_RED='\033[0;31m'
readonly _RALPH_COLOR_GREEN='\033[0;32m'
readonly _RALPH_COLOR_YELLOW='\033[1;33m'
readonly _RALPH_COLOR_BLUE='\033[0;34m'
readonly _RALPH_COLOR_MAGENTA='\033[0;35m'
readonly _RALPH_COLOR_CYAN='\033[0;36m'
readonly _RALPH_COLOR_NC='\033[0m' # No Color

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
_RALPH_OS_TYPE="${_RALPH_OS_TYPE:-$(detect_os)}"
_RALPH_ARCH_TYPE="${_RALPH_ARCH_TYPE:-$(detect_arch)}"

# Export for child processes if needed
export _RALPH_OS_TYPE _RALPH_ARCH_TYPE

# Backward compatibility (deprecated)
OS_TYPE="$_RALPH_OS_TYPE"
ARCH_TYPE="$_RALPH_ARCH_TYPE"

#######################################
# Logging functions
# All logs are written to LOG_FILE if set
#######################################
_log_message() {
    local color="$1"
    local level="$2"
    shift 2
    local message="$*"
    
    echo -e "${color}[${level}]${_RALPH_COLOR_NC} ${message}" >&2
    
    # Only write to log file if it's defined and writable
    if [[ -n "${LOG_FILE:-}" ]]; then
        # Resolve to absolute path
        local log_abs
        log_abs=$(realpath -m "$LOG_FILE" 2>/dev/null || echo "$LOG_FILE")
        
        # Security: Ensure log file is in allowed directory
        local log_dir
        log_dir=$(dirname "$log_abs")
        
        # Only allow logs in project dir, /tmp, or user's home
        case "$log_abs" in
            /tmp/*|"$HOME"/*|"$(pwd)"/*|./*)
                # Create directory if needed
                if [[ ! -d "$log_dir" ]]; then
                    mkdir -p "$log_dir" 2>/dev/null || {
                        echo "Warning: Cannot create log directory: $log_dir" >&2
                        return 0
                    }
                fi
                
                # Write log entry
                if ! echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "$LOG_FILE" 2>&1; then
                    # Only warn once
                    if [[ "${_RALPH_LOG_WARN_SHOWN:-false}" != "true" ]]; then
                        echo "Warning: Cannot write to log file: $LOG_FILE" >&2
                        export _RALPH_LOG_WARN_SHOWN=true
                    fi
                fi
                ;;
            *)
                if [[ "${_RALPH_LOG_PATH_WARN:-false}" != "true" ]]; then
                    echo "Warning: Log file path rejected for security: $LOG_FILE" >&2
                    export _RALPH_LOG_PATH_WARN=true
                fi
                ;;
        esac
    fi
}

log_info()    { _log_message "$_RALPH_COLOR_BLUE"    "INFO"    "$@"; }
log_success() { _log_message "$_RALPH_COLOR_GREEN"   "SUCCESS" "$@"; }
log_warning() { _log_message "$_RALPH_COLOR_YELLOW"  "WARNING" "$@"; }
log_error()   { _log_message "$_RALPH_COLOR_RED"     "ERROR"   "$@"; }
log_setup()   { _log_message "$_RALPH_COLOR_MAGENTA" "SETUP"   "$@"; }

log_debug() {
    [[ "${VERBOSE:-false}" == "true" ]] && _log_message "$_RALPH_COLOR_CYAN" "DEBUG" "$@" || true
}

log_metrics() {
    [[ -n "${METRICS_FILE:-}" ]] && echo "$*" >> "$METRICS_FILE" 2>/dev/null || true
}

#######################################
# Temporary file management
#######################################
declare -a TEMP_FILES=()
# Global temp file registry for atomic tracking
readonly _RALPH_TEMP_REGISTRY="${TMPDIR:-/tmp}/.ralph_temps_$$"

#######################################
# Default directories to exclude from hashing
#######################################
declare -ax DEFAULT_HASH_EXCLUDES=(
    -name node_modules
    -o -name .git
    -o -name .next
    -o -name dist
    -o -name build
    -o -name vendor
    -o -name target
    -o -name bin
    -o -name obj
    -o -name .idea
    -o -name .vscode
    -o -name __pycache__
    -o -name .pytest_cache
    -o -name coverage
    -o -name .turbo
    -o -name .cache
    -o -name .local
    -o -name "VirtualBox VMs"
    -o -name drive
    -o -name Downloads
    -o -name Android
    -o -name Applications
    -o -name .bun
    -o -name .npm
    -o -name .cargo
    -o -name .rustup
    -o -name .arduino15
    -o -name .gradle
    -o -name .m2
    -o -name .nvm
    -o -name .ollama
    -o -name Pictures
    -o -name Videos
    -o -name Music
)

#######################################
# Cleanup function for temporary files and processes
#######################################
cleanup_ralph() {
    local exit_code=$?
    
    # Clean from registry (more reliable)
    if [[ -f "$_RALPH_TEMP_REGISTRY" ]]; then
        while IFS= read -r temp_file; do
            [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null
        done < "$_RALPH_TEMP_REGISTRY"
        rm -f "$_RALPH_TEMP_REGISTRY" "${_RALPH_TEMP_REGISTRY}.lock" 2>/dev/null
    fi
    
    # Fallback: clean from array
    for temp_file in "${TEMP_FILES[@]}"; do
        [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null
    done
    
    exit "$exit_code"
}

trap cleanup_ralph EXIT INT TERM

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
    
    # Register temp file atomically
    (
        flock -x 200
        echo "$temp_file" >> "$_RALPH_TEMP_REGISTRY"
    ) 200>"${_RALPH_TEMP_REGISTRY}.lock" 2>/dev/null
    
    # Also track in array for backward compatibility
    TEMP_FILES+=("$temp_file")
    
    echo "$temp_file"
}

#######################################
# Ensure common local bin directories are in PATH
#######################################
ensure_local_paths() {
    local common_paths=("$HOME/go/bin" "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin")
    
    for p in "${common_paths[@]}"; do
        if [[ -d "$p" ]] && [[ ":$PATH:" != *":$p:"* ]]; then
            export PATH="$p:$PATH"
        fi
    done
}

# Initialize paths immediately
ensure_local_paths

#######################################
# Check if a command exists in PATH (including local bins)
# Arguments:
#   $1 - Command name to check
# Returns: 0 if exists, 1 otherwise
#######################################
command_exists() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    
    # Check common local bin directories
    local local_bins=("$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/go/bin")
    for bin_dir in "${local_bins[@]}"; do
        if [[ -x "$bin_dir/$cmd" ]]; then
            return 0
        fi
    done
    
    return 1
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

#######################################
# Check for required dependencies and auto-install if missing
# Returns: 0 if all required tools exist, 1 otherwise
#######################################
check_dependencies() {
    local missing_tools=()
    
    # Required tools for core functionality
    local required_tools=("curl" "jq" "git" "bc" "sqlite3" "python3" "bd")
    
    # Add the selected AI tool to requirements
    local selected_tool="${TOOL:-opencode}"
    if [[ "$selected_tool" == "opencode" ]]; then
        required_tools+=("opencode")
    elif [[ "$selected_tool" == "claude" ]]; then
        required_tools+=("claude")
    elif [[ "$selected_tool" == "amp" ]]; then
        required_tools+=("amp")
    fi

    log_debug "Checking required dependencies..."
    
    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    # Check for bun (user preferred)
    if ! command_exists bun; then
        missing_tools+=("bun")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_info "Missing dependencies: ${missing_tools[*]}"
        log_info "Attempting non-interactive auto-installation..."
        
        local pkg_mgr
        pkg_mgr=$(get_package_manager)
        
        case "$pkg_mgr" in
            pacman)
                # Map commands to pacman packages if different
                local packages=()
                local install_bd=false
                
                for tool in "${missing_tools[@]}"; do
                    case "$tool" in
                        python3) packages+=("python") ;;
                        bun)
                            # Bun installation usually via curl for Arch if not in AUR/extra
                            log_setup "Installing bun via curl..."
                            curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
                            ;;
                        bd)
                            install_bd=true
                            if ! command_exists go; then
                                packages+=("go")
                            fi
                            ;;
                        *) packages+=("$tool") ;;
                    esac
                done
                
                if [[ ${#packages[@]} -gt 0 ]]; then
                    log_info "Requesting sudo for system packages: ${packages[*]}"
                    if ! sudo -n pacman -S --noconfirm "${packages[@]}" >/dev/null 2>&1; then
                        log_warning "Non-interactive sudo failed. Trying interactive sudo..."
                        if ! sudo pacman -S --noconfirm "${packages[@]}"; then
                            log_error "Failed to install system packages. Please install manually: sudo pacman -S ${packages[*]}"
                            return 1
                        fi
                    fi
                fi
                
                if [[ "$install_bd" == "true" ]]; then
                    install_beads || return 1
                fi
                ;;
            *)
                # Fallback to existing install_package function for other OSs
                for tool in "${missing_tools[@]}"; do
                    install_package "$tool" >/dev/null 2>&1 || true
                done
                ;;
        esac
    fi
    
    log_success "All core dependencies verified."
    return 0
}

#######################################
# Notification Library for Ralph
# Provides cross-platform desktop alerts
#######################################

#######################################
# Send a desktop notification
# Arguments:
#   $1 - Title
#   $2 - Message
#   $3 - Urgency (low, normal, critical)
#######################################
send_notification() {
    local title="$1"
    local msg="$2"
    local urgency="${3:-normal}"
    
    log_debug "Notification: $title - $msg"
    
    case "$OS_TYPE" in
        linux)
            if command_exists notify-send; then
                notify-send -u "$urgency" -a "Ralph" "$title" "$msg"
            fi
            ;; 
        macos)
            osascript -e "display notification \"$msg\" with title \"$title\""
            ;; 
        *)
            # Fallback to bell
            echo -e "\a"
            ;; 
    esac
}

#######################################
# TUI and UI Library for Ralph
# Inspired by ralphy.sh - Provides dynamic progress monitoring
#######################################

# Progress state
declare -g PROGRESS_START_TIME=0
declare -g CURRENT_STEP="Initializing"
declare -g CURRENT_TASK="Setup"

#######################################
# Initialize progress timer
#######################################
start_progress_timer() {
    PROGRESS_START_TIME=$(date +%s)
}

#######################################
# Render a dynamic status bar
# This uses ANSI escapes to clear the line and redraw
#######################################
render_status_bar() {
    local iteration=$1
    local max=$2
    local spinner_idx=$3
    
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local char="${spin:$spinner_idx:1}"
    
    local now
    now=$(date +%s)
    local elapsed=$((now - PROGRESS_START_TIME))
    local timer
    timer=$(printf "%02d:%02d" $((elapsed / 60)) $((elapsed % 60)))
    
    # Beads Stats (War Room context)
    local ready_tasks
    ready_tasks=$(bd count --status open --quiet 2>/dev/null || echo "0")
    local model_short=${SELECTED_MODEL##*/}
    
    # Format: [CHAR] [ITER/MAX] [READY] [MODEL] STEP: Task... (Time)
    printf "\r\033[K%b[%s]%b %b[%d/%d]%b %b[Ready:%s]%b %b[%s]%b %b%s:%b %s %b(%s)%b" \
        "${_RALPH_COLOR_MAGENTA}" "$char" "${_RALPH_COLOR_NC}" \
        "${_RALPH_COLOR_CYAN}" "$iteration" "$max" "${_RALPH_COLOR_NC}" \
        "${_RALPH_COLOR_GREEN}" "$ready_tasks" "${_RALPH_COLOR_NC}" \
        "${_RALPH_COLOR_BLUE}" "$model_short" "${_RALPH_COLOR_NC}" \
        "${_RALPH_COLOR_YELLOW}" "$CURRENT_STEP" "${_RALPH_COLOR_NC}" \
        "${CURRENT_TASK:0:30}" \
        "${_RALPH_COLOR_BLUE}" "$timer" "${_RALPH_COLOR_NC}"
}

#######################################
# Update the current progress state
#######################################
update_status() {
    CURRENT_STEP="$1"
    [[ -n "${2:-}" ]] && CURRENT_TASK="$2"
}

#######################################
# Draw a stylized banner
#######################################
print_banner() {
    local text="$1"
    local color="${2:-$_RALPH_COLOR_MAGENTA}"
    echo -e "\n${color}# $(printf '%.s=' {1..60})${_RALPH_COLOR_NC}"
    echo -e "${color}# ${text}${_RALPH_COLOR_NC}"
    echo -e "${color}# $(printf '%.s=' {1..60})${_RALPH_COLOR_NC}\n"
}

#######################################
# Load configuration from config files
# Supports both ralph.json (JSON) and .ralphrc (shell)
# Priority: Command-line args > .ralphrc > ralph.json
#######################################
load_config() {
    # Set defaults
    TOOL="${TOOL:-opencode}"
    MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
    SANDBOX_MODE="${SANDBOX_MODE:-false}"
    VERBOSE="${VERBOSE:-false}"
    PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
    CONTEXT_FILES=()
    
    # Artifact and State directory
    readonly _RALPH_DIR="$PROJECT_DIR/.ralph"
    ARTIFACT_DIR="${ARTIFACT_DIR:-$_RALPH_DIR/artifacts}"
    STATE_DIR="${STATE_DIR:-$_RALPH_DIR/state}"
    mkdir -p "$ARTIFACT_DIR" "$STATE_DIR"
    
    PROGRESS_FILE="${PROGRESS_FILE:-$STATE_DIR/progress.log}"
    PRD_FILE="${PRD_FILE:-$ARTIFACT_DIR/prd.json}"
    PLAN_FILE="${PLAN_FILE:-$ARTIFACT_DIR/ralph_plan.md}"
    DIAGRAM_FILE="${DIAGRAM_FILE:-$ARTIFACT_DIR/ralph_architecture.md}"
    AGENTS_FILE="${AGENTS_FILE:-agents.md}"
    LOG_FILE="${LOG_FILE:-$STATE_DIR/ralph.log}"
    METRICS_FILE="${METRICS_FILE:-$STATE_DIR/metrics.json}"
    ARCHIVE_DIR="${ARCHIVE_DIR:-$_RALPH_DIR/archives}"

    local config_loaded=false
    
    # Load JSON config first (lower priority)
    if [[ -f "ralph.json" ]]; then
        log_info "Loading configuration from ralph.json..."
        
        if ! command_exists jq; then
            log_warning "jq not found, cannot parse ralph.json"
        else
            # Validate JSON before parsing
            if ! jq empty ralph.json 2>/dev/null; then
                log_error "ralph.json contains invalid JSON"
                return 1
            fi
            
            local json_tool json_model json_max_iter json_sandbox json_verbose
            json_tool=$(jq -r '.tool // empty' ralph.json 2>/dev/null)
            json_model=$(jq -r '.model // empty' ralph.json 2>/dev/null)
            json_max_iter=$(jq -r '.maxIterations // empty' ralph.json 2>/dev/null)
            json_sandbox=$(jq -r '.sandbox // empty' ralph.json 2>/dev/null)
            json_verbose=$(jq -r '.verbose // empty' ralph.json 2>/dev/null)
            
            # Apply settings if not already set
            [[ -z "${TOOL:-}" && -n "$json_tool" ]] && TOOL="$json_tool"
            [[ -z "${SELECTED_MODEL:-}" && -n "$json_model" ]] && SELECTED_MODEL="$json_model"
            [[ -z "${MAX_ITERATIONS:-}" && -n "$json_max_iter" ]] && MAX_ITERATIONS="$json_max_iter"
            [[ -z "${SANDBOX_MODE:-}" && -n "$json_sandbox" ]] && SANDBOX_MODE="$json_sandbox"
            [[ -z "${VERBOSE:-}" && "$json_verbose" == "true" ]] && VERBOSE=true
            
            config_loaded=true
            log_debug "Loaded settings from ralph.json"
        fi
    fi
    
    # Load shell config (higher priority, can override JSON)
    if [[ -f ".ralphrc" ]]; then
        log_info "Loading configuration from .ralphrc..."
        
        # Validate it's a readable file
        if [[ ! -r ".ralphrc" ]]; then
            log_error ".ralphrc exists but is not readable"
            return 1
        fi
        
        # Source the config file
        # shellcheck source=/dev/null
        if source .ralphrc 2>/dev/null; then
            config_loaded=true
            log_debug "Loaded settings from .ralphrc"
        else
            log_error "Failed to source .ralphrc - check for syntax errors"
            return 1
        fi
    fi
    
    if ! $config_loaded; then
        log_debug "No configuration files found, using defaults"
    fi
    
    return 0
}

#######################################
# Save checkpoint for resumable execution
# Arguments:
#   $1 - Current iteration number
#######################################
save_checkpoint() {
    local iteration="$1"
    local checkpoint_file="${STATE_DIR:-.ralph/state}/checkpoint.txt"
    
    if [[ ! "$iteration" =~ ^[0-9]+$ ]]; then
        log_error "Invalid checkpoint iteration: $iteration"
        return 1
    fi
    
    if echo "$iteration" > "$checkpoint_file"; then
        log_debug "Checkpoint saved: Iteration $iteration"
        return 0
    else
        log_warning "Failed to save checkpoint"
        return 1
    fi
}

#######################################
# Retrieve last checkpoint
# Returns: Last iteration number, or 0 if none exists
#######################################
get_checkpoint() {
    local checkpoint_file="${STATE_DIR:-.ralph/state}/checkpoint.txt"
    
    if [[ -f "$checkpoint_file" ]]; then
        local checkpoint
        checkpoint=$(cat "$checkpoint_file" 2>/dev/null)
        
        if [[ "$checkpoint" =~ ^[0-9]+$ ]]; then
            echo "$checkpoint"
        else
            log_warning "Invalid checkpoint data, returning 0"
            echo "0"
        fi
    else
        echo "0"
    fi
}

#######################################
# Get system resource usage information
# Returns: Formatted string with system stats
#######################################
get_resource_usage() {
    local usage=""
    
    # Load average (works on most Unix systems)
    if command_exists uptime; then
        usage+="Load Average: $(uptime | awk -F'load average:' '{print $2}' | xargs)\n"
    fi
    
    # Memory information
    case "$OS_TYPE" in
        linux)
            if command_exists free; then
                usage+="Memory:\n$(free -h | grep -E '^Mem|^Swap')\n"
            fi
            ;;
        macos)
            if command_exists vm_stat; then
                local pages_free pages_active
                pages_free=$(vm_stat | grep 'Pages free' | awk '{print $3}' | tr -d '.')
                pages_active=$(vm_stat | grep 'Pages active' | awk '{print $3}' | tr -d '.')
                
                # Convert pages to MB (assuming 4KB pages)
                if [[ -n "$pages_free" ]] && [[ -n "$pages_active" ]]; then
                    local free_mb=$((pages_free * 4 / 1024))
                    local active_mb=$((pages_active * 4 / 1024))
                    usage+="Memory: ${free_mb}MB free, ${active_mb}MB active\n"
                fi
            fi
            ;;
    esac
    
    # Disk space
    if command_exists df; then
        local disk_info
        disk_info=$(df -h . 2>/dev/null | awk 'NR==2 {print $4 " available of " $2 " total (" $5 " used)"}')
        if [[ -n "$disk_info" ]]; then
            usage+="Disk: $disk_info\n"
        fi
    fi
    
    # CPU information (optional)
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        case "$OS_TYPE" in
            linux)
                if command_exists nproc; then
                    usage+="CPU Cores: $(nproc)\n"
                fi
                ;;
            macos)
                if command_exists sysctl; then
                    usage+="CPU Cores: $(sysctl -n hw.ncpu 2>/dev/null)\n"
                fi
                ;;
        esac
    fi
    
    echo -e "$usage"
}

#######################################
# Read and aggregate context files
# Uses global CONTEXT_FILES array
# Returns: Formatted string with file contents
#######################################
read_context_files() {
    local content=""
    local files_read=0
    
    if [[ ${#CONTEXT_FILES[@]} -eq 0 ]]; then
        log_debug "No context files to read"
        return 0
    fi
    
    content+="=== User Provided Context ===\n\n"
    
    for file in "${CONTEXT_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_warning "Context file not found: $file"
            continue
        fi
        
        if [[ ! -r "$file" ]]; then
            log_warning "Context file not readable: $file"
            continue
        fi
        
        local file_size
        file_size=$(wc -c < "$file" 2>/dev/null)
        
        # Warn if file is very large (>1MB)
        if [[ -n "$file_size" ]] && [[ $file_size -gt 1048576 ]]; then
            log_warning "Context file is large ($(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "${file_size} bytes")): $file"
        fi
        
        content+="--- File: $file ---\n"
        content+="$(cat "$file")\n"
        content+="--- End of $file ---\n\n"
        ((files_read++))
    done
    
    if [[ $files_read -eq 0 ]]; then
        log_warning "No context files were successfully read"
        return 1
    fi
    
    log_debug "Read $files_read context file(s)"
    echo -e "$content"
}

#######################################
# Display usage information and help
#######################################
show_usage() {
    cat << EOF
${_RALPH_COLOR_CYAN}Ralph - AI-Powered Development Assistant${_RALPH_COLOR_NC}

${_RALPH_COLOR_YELLOW}Usage:${_RALPH_COLOR_NC}
    $0 [OPTIONS]

${_RALPH_COLOR_YELLOW}Options:${_RALPH_COLOR_NC}
    ${_RALPH_COLOR_GREEN}--init${_RALPH_COLOR_NC}                  Smart project initialization
    ${_RALPH_COLOR_GREEN}--setup${_RALPH_COLOR_NC}                 Install all required dependencies
    ${_RALPH_COLOR_GREEN}--test${_RALPH_COLOR_NC}                  Run internal test suite
    ${_RALPH_COLOR_GREEN}--tool${_RALPH_COLOR_NC} TOOL             AI tool: amp, claude, or opencode (default: opencode)
    ${_RALPH_COLOR_GREEN}--max-iterations${_RALPH_COLOR_NC} N      Maximum iterations (default: 10)
    ${_RALPH_COLOR_GREEN}--model${_RALPH_COLOR_NC} MODEL           Specific model to use (overrides auto-detection)
    ${_RALPH_COLOR_GREEN}--gitdiff-exclude${_RALPH_COLOR_NC} FILE  Path to gitdiff exclude file
                              (default: ~/.config/git/gitdiff-exclude)
    ${_RALPH_COLOR_GREEN}--no-archive${_RALPH_COLOR_NC}            Skip archiving previous runs
    ${_RALPH_COLOR_GREEN}--verbose${_RALPH_COLOR_NC}               Enable verbose/debug output
    ${_RALPH_COLOR_GREEN}-i, --interactive${_RALPH_COLOR_NC}        Pause for user input between iterations
    ${_RALPH_COLOR_GREEN}--resume${_RALPH_COLOR_NC}                Resume from last checkpoint
    ${_RALPH_COLOR_GREEN}--diff-context${_RALPH_COLOR_NC}          Include recent git diffs in context
    ${_RALPH_COLOR_GREEN}--context${_RALPH_COLOR_NC} FILE          Add file to context (repeatable)
    ${_RALPH_COLOR_GREEN}--sandbox${_RALPH_COLOR_NC}               Run in Docker sandbox (requires Docker)
    ${_RALPH_COLOR_GREEN}--no-sandbox${_RALPH_COLOR_NC}            Force run without sandbox
    ${_RALPH_COLOR_GREEN}-h, --help${_RALPH_COLOR_NC}              Show this help message

${_RALPH_COLOR_YELLOW}Commands:${_RALPH_COLOR_NC}
    ${_RALPH_COLOR_GREEN}swarm [SUBCOMMAND]${_RALPH_COLOR_NC}      Multi-agent orchestration (spawn, msg, list, task)
    ${_RALPH_COLOR_GREEN}copilot [SUBCOMMAND]${_RALPH_COLOR_NC}    GitHub Copilot integration (agent, explain, auth)

${_RALPH_COLOR_YELLOW}Grounded Architecture:${_RALPH_COLOR_NC}
    Ralph uses a "Grounded Architecture" to maintain long-term context
    across stateless tool iterations:
    
    ${_RALPH_COLOR_GREEN}1. prd.json${_RALPH_COLOR_NC}              - Goals, user stories, success metrics
    ${_RALPH_COLOR_GREEN}2. ralph_plan.md${_RALPH_COLOR_NC}        - Execution plan with [ ] / [x] tracking
    ${_RALPH_COLOR_GREEN}3. ralph_architecture.md${_RALPH_COLOR_NC} - Mermaid diagrams for data flow

${_RALPH_COLOR_YELLOW}Configuration Files:${_RALPH_COLOR_NC}
    Store defaults in project root:
    
    ${_RALPH_COLOR_GREEN}ralph.json${_RALPH_COLOR_NC}    - JSON format (keys: tool, model, maxIterations, sandbox, verbose)
    ${_RALPH_COLOR_GREEN}.ralphrc${_RALPH_COLOR_NC}      - Shell script format (higher priority than ralph.json)
    
    Priority: Command-line args > .ralphrc > ralph.json > defaults

${_RALPH_COLOR_YELLOW}Examples:${_RALPH_COLOR_NC}
    ${_RALPH_COLOR_CYAN}# Install dependencies${_RALPH_COLOR_NC}
    $0 --setup
    
    ${_RALPH_COLOR_CYAN}# Run with specific tool and iterations${_RALPH_COLOR_NC}
    $0 --tool opencode --max-iterations 20
    
    ${_RALPH_COLOR_CYAN}# Use specific model${_RALPH_COLOR_NC}
    $0 --tool claude --model qwen2.5-coder
    
    ${_RALPH_COLOR_CYAN}# Add context files and run in sandbox${_RALPH_COLOR_NC}
    $0 --context docs/api.md --context README.md --sandbox
    
    ${_RALPH_COLOR_CYAN}# Resume from checkpoint with verbose output${_RALPH_COLOR_NC}
    $0 --resume --verbose

${_RALPH_COLOR_YELLOW}System Information:${_RALPH_COLOR_NC}
    OS:               $_RALPH_OS_TYPE
    Architecture:     $_RALPH_ARCH_TYPE
    Package Manager:  $(get_package_manager)

${_RALPH_COLOR_YELLOW}Gitdiff Exclude:${_RALPH_COLOR_NC}
    The gitdiff-exclude file filters noise from git diffs.
    
    Format:  One pattern per line
    Syntax:  Supports glob patterns and file paths
    Example: node_modules/*, *.log, dist/
    
    Default location: ~/.config/git/gitdiff-exclude

EOF
    exit 0
}

#######################################
# Parse command-line arguments
# Arguments: $@ - All command-line arguments
#######################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --init)
                export INIT_MODE=true
                shift
                ;;
            --setup)
                export SETUP_MODE=true
                shift
                ;;
            --test)
                export TEST_MODE=true
                shift
                ;;
            --tool)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "--tool requires an argument"
                    exit 1
                fi
                TOOL="$2"
                shift 2
                ;;
            --tool=*)
                TOOL="${1#*=}"
                shift
                ;;
            --max-iterations)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "--max-iterations requires an argument"
                    exit 1
                fi
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --max-iterations=*)
                MAX_ITERATIONS="${1#*=}"
                shift
                ;;
            --model)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "--model requires an argument"
                    exit 1
                fi
                SELECTED_MODEL="$2"
                export SELECTED_MODEL_SOURCE="CLI"
                shift 2
                ;;
            --model=*)
                SELECTED_MODEL="${1#*=}"
                export SELECTED_MODEL_SOURCE="CLI"
                shift
                ;;
            --gitdiff-exclude)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "--gitdiff-exclude requires an argument"
                    exit 1
                fi
                export GITDIFF_EXCLUDE="$2"
                shift 2
                ;;
            --gitdiff-exclude=*)
                export GITDIFF_EXCLUDE="${1#*=}"
                shift
                ;;
            --no-archive)
                export NO_ARCHIVE=true
                shift
                ;;
            --verbose)
                export VERBOSE=true
                shift
                ;;
            -i|--interactive)
                export INTERACTIVE_MODE=true
                shift
                ;;
            --resume)
                export RESUME_FLAG=true
                shift
                ;;
            --diff-context)
                export DIFF_CONTEXT_FLAG=true
                shift
                ;;
            --context)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "--context requires a file path"
                    exit 1
                fi
                CONTEXT_FILES+=("$2")
                shift 2
                ;;
            --context=*)
                CONTEXT_FILES+=("${1#*=}")
                shift
                ;;
            --sandbox)
                export SANDBOX_MODE=true
                shift
                ;;
            --no-sandbox)
                export SANDBOX_MODE=false
                shift
                ;;
            -h|--help)
                show_usage
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
            init)
                export INIT_MODE=true
                shift
                ;;
            setup)
                export SETUP_MODE=true
                shift
                ;;
            test)
                export TEST_MODE=true
                shift
                ;;
            *)
                # Legacy support: assume it's max_iterations if it's a number
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    log_warning "Positional iteration argument is deprecated, use --max-iterations"
                    MAX_ITERATIONS="$1"
                    shift
                else
                    log_error "Unknown argument: $1"
                    echo "Use --help for usage information"
                    exit 1
                fi
                ;;
        esac
    done
}

#######################################
# Validate configuration settings
# Returns: 0 if valid, exits on invalid config
#######################################
validate_config() {
    local errors=0
    
    # Validate tool selection
    if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "opencode" ]]; then
        log_error "Invalid tool '$TOOL'. Must be 'amp', 'claude', or 'opencode'"
        ((errors++))
    fi
    
    # Validate max iterations
    if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
        log_error "Max iterations must be a positive integer, got: '$MAX_ITERATIONS'"
        ((errors++))
    elif [[ "$MAX_ITERATIONS" -lt 1 ]]; then
        log_error "Max iterations must be at least 1, got: $MAX_ITERATIONS"
        ((errors++))
    elif [[ "$MAX_ITERATIONS" -gt 1000 ]]; then
        log_warning "Max iterations is very high: $MAX_ITERATIONS"
    fi
    
    # Validate context files exist
    for file in "${CONTEXT_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_warning "Context file does not exist: $file"
        fi
    done
    
    # Validate gitdiff exclude file if specified
    if [[ -n "${GITDIFF_EXCLUDE:-}" ]] && [[ ! -f "$GITDIFF_EXCLUDE" ]]; then
        log_warning "Gitdiff exclude file not found: $GITDIFF_EXCLUDE"
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors error(s)"
        exit 1
    fi
    
    log_debug "Configuration validated successfully"
    return 0
}

#######################################
# Initialize progress tracking file
#######################################
initialize_progress_file() {
    local progress_file="${PROGRESS_FILE:-ralph_progress.log}"
    
    cat > "$progress_file" << EOF
# Ralph Progress Log
================================================================================
Started:        $(date '+%Y-%m-%d %H:%M:%S')
Tool:           $TOOL
Model:          ${SELECTED_MODEL:-auto}
Max Iterations: $MAX_ITERATIONS
Sandbox Mode:   ${SANDBOX_MODE:-false}
Resume Mode:    ${RESUME_FLAG:-false}
================================================================================

EOF
    
    log_debug "Initialized progress file: $progress_file"
}

#######################################
# Track current branch in PRD file
# Saves branch name for later comparison/archiving
#######################################
track_current_branch() {
    local prd_file="${PRD_FILE:-prd.json}"
    local branch_file="${STATE_DIR:-.ralph/state}/.ralph_last_branch"
    
    if [[ ! -f "$prd_file" ]]; then
        log_debug "PRD file not found, skipping branch tracking"
        return 0
    fi
    
    if ! command_exists jq; then
        log_debug "jq not available, skipping branch tracking"
        return 0
    fi
    
    local current_branch
    current_branch=$(jq -r '.branchName // empty' "$prd_file" 2>/dev/null)
    
    if [[ -n "$current_branch" ]]; then
        echo "$current_branch" > "$branch_file"
        log_debug "Tracked branch: $current_branch"
    else
        log_debug "No branch name found in PRD"
    fi
    return 0
}

#######################################
# Smart Project Initialization
# Detects project type and generates initial artifacts
#######################################
smart_init() {
    print_banner "Smart Initializing Project" "${_RALPH_COLOR_BLUE}"
    
    # Load paths
    load_config >/dev/null 2>&1 || true
    
    local prd_file="${PRD_FILE:-.ralph/artifacts/prd.json}"
    local config_file="ralph.json"
    
    # Detect Project Type
    local type="unknown"
    local build_cmd="echo 'No build command detected'"
    local test_cmd="echo 'No test command detected'"
    
    if [[ -f "package.json" ]]; then
        type="Node.js"
        build_cmd="npm run build"
        test_cmd="npm test"
        [[ -f "bun.lock" ]] && type="Bun" && build_cmd="bun run build" && test_cmd="bun test"
    elif [[ -f "Cargo.toml" ]]; then
        type="Rust"
        build_cmd="cargo build"
        test_cmd="cargo test"
    elif [[ -f "go.mod" ]]; then
        type="Go"
        build_cmd="go build ."
        test_cmd="go test ./..."
    elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]; then
        type="Python"
        build_cmd="pip install -r requirements.txt"
        test_cmd="pytest"
    fi
    
    log_success "Detected Project Type: $type"
    
    # Generate ralph.json if missing
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" <<EOF
{
  "tool": "opencode",
  "maxIterations": 15,
  "projectType": "$type",
  "commands": {
    "build": "$build_cmd",
    "test": "$test_cmd"
  }
}
EOF
        log_success "Created $config_file"
    fi
    
    # Initialize basic PRD
    if [[ ! -f "$prd_file" ]]; then
        cat > "$prd_file" <<EOF
{
  "projectName": "$(basename "$(pwd)")",
  "projectType": "$type",
  "goals": ["Build and verify the $type application"],
  "status": "initialization"
}
EOF
        log_success "Created $prd_file"
    fi
    
    # Initialize other artifacts via orchestrator
    log_info "Run './ralph.sh' to start the engineering loop."
}

#######################################
# Display current configuration summary
#######################################
show_config_summary() {
    log_info "Configuration Summary:"
    log_info "  Tool:           $TOOL"
    log_info "  Model:          ${SELECTED_MODEL:-auto-detect}"
    log_info "  Max Iterations: $MAX_ITERATIONS"
    log_info "  Sandbox:        ${SANDBOX_MODE:-false}"
    log_info "  Resume:         ${RESUME_FLAG:-false}"
    log_info "  Verbose:        ${VERBOSE:-false}"
    
    if [[ ${#CONTEXT_FILES[@]} -gt 0 ]]; then
        log_info "  Context Files:  ${#CONTEXT_FILES[@]} file(s)"
    fi
}

#######################################
# Dependency Management Library for Ralph
# Handles package installation across OSs
#######################################

#######################################
# Detect package manager for current OS
# Returns: Package manager name or "unknown"/"none"
#######################################
get_package_manager() {
    case "$OS_TYPE" in
        linux)
            if command_exists apt-get; then
                echo "apt"
            elif command_exists dnf; then
                echo "dnf"
            elif command_exists yum; then
                echo "yum"
            elif command_exists pacman; then
                echo "pacman"
            elif command_exists zypper; then
                echo "zypper"
            elif command_exists apk; then
                echo "apk"
            else
                echo "unknown"
            fi
            ;;
        macos)
            if command_exists brew; then
                echo "brew"
            else
                echo "none"
            fi
            ;;
        windows)
            if command_exists choco; then
                echo "choco"
            elif command_exists scoop; then
                echo "scoop"
            elif command_exists winget; then
                echo "winget"
            else
                echo "none"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

#######################################
# Install package manager if missing
# Arguments:
#   $1 - Package manager to install (brew, choco, scoop)
# Returns: 0 on success, 1 on failure
#######################################
install_package_manager() {
    local pkg_mgr="$1"
    
    case "$pkg_mgr" in
        brew)
            log_setup "Installing Homebrew..."
            if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
                log_success "Homebrew installed successfully"
                
                # Add Homebrew to PATH for current session
                if [[ "$ARCH_TYPE" == "arm64" ]]; then
                    eval "$(/opt/homebrew/bin/brew shellenv)"
                else
                    eval "$(/usr/local/bin/brew shellenv)"
                fi
                return 0
            else
                log_error "Failed to install Homebrew"
                return 1
            fi
            ;;
        choco)
            log_error "Chocolatey requires administrator privileges"
            log_warning "Please run this PowerShell command as Administrator:"
            echo ""
            echo "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
            echo ""
            return 1
            ;;
        scoop)
            log_setup "Installing Scoop..."
            if powershell -Command "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; iwr -useb get.scoop.sh | iex"; then
                log_success "Scoop installed successfully"
                return 0
            else
                log_error "Failed to install Scoop"
                return 1
            fi
            ;;
        *)
            log_error "Unable to install package manager automatically for your system"
            log_info "Please install a package manager manually:"
            log_info "  macOS: https://brew.sh"
            log_info "  Windows: https://chocolatey.org or https://scoop.sh"
            return 1
            ;;
    esac
}

#######################################
# Install a package using appropriate package manager
# Arguments:
#   $1 - Package name to install
#   $2 - (Optional) Alternative package name for specific managers
# Returns: 0 on success, 1 on failure
#######################################
install_package() {
    local package="$1"
    local alt_package="${2:-$1}"
    
    # Validate package name (alphanumeric, hyphen, underscore, dot only)
    if ! [[ "$package" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid package name: $package"
        return 1
    fi
    
    if ! [[ "$alt_package" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid alternative package name: $alt_package"
        return 1
    fi
    
    # Limit package name length
    if [[ ${#package} -gt 128 ]]; then
        log_error "Package name too long: $package"
        return 1
    fi

    local pkg_mgr
    
    # Check if we should skip sudo/interactive prompts
    local sudo_cmd="sudo"
    [[ "${NON_INTERACTIVE:-false}" == "true" ]] && sudo_cmd="sudo -n"

    pkg_mgr=$(get_package_manager)
    
    if [[ "$pkg_mgr" == "unknown" ]] || [[ "$pkg_mgr" == "none" ]]; then
        log_error "No package manager available to install $package"
        return 1
    fi
    
    log_setup "Installing $package using $pkg_mgr..."
    
    case "$pkg_mgr" in
        apt)
            if $sudo_cmd apt-get update -y && $sudo_cmd apt-get install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        dnf)
            if $sudo_cmd dnf install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        yum)
            if $sudo_cmd yum install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        pacman)
            if $sudo_cmd pacman -S --noconfirm "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        zypper)
            if sudo zypper install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        apk)
            if sudo apk add "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        brew)
            if brew install "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        choco)
            if choco install -y "$alt_package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        scoop)
            if scoop install "$alt_package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        winget)
            if winget install -e --id "$alt_package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
    esac
    
    log_error "Failed to install $package using $pkg_mgr"
    return 1
}

#######################################
# Install Git if not present
#######################################
install_git() {
    if command_exists git; then
        local git_version
        git_version=$(git --version 2>/dev/null | awk '{print $3}')
        log_success "Git is already installed (version $git_version)"
        return 0
    fi
    
    log_setup "Git not found. Installing..."
    install_package git || {
        log_error "Failed to install Git"
        log_info "Please install Git manually: https://git-scm.com/downloads"
        return 1
    }
}

#######################################
# Install jq (JSON processor)
#######################################
install_jq() {
    if command_exists jq; then
        local jq_version
        jq_version=$(jq --version 2>/dev/null)
        log_success "jq is already installed ($jq_version)"
        return 0
    fi
    
    log_setup "jq not found. Installing..."
    install_package jq || {
        log_error "Failed to install jq"
        log_info "Please install jq manually: https://jqlang.github.io/jq/download/"
        return 1
    }
}

#######################################
# Install Node.js if not present
#######################################
install_nodejs() {
    if command_exists node; then
        local node_version npm_version
        node_version=$(node --version 2>/dev/null)
        npm_version=$(npm --version 2>/dev/null)
        log_success "Node.js is already installed ($node_version, npm $npm_version)"
        return 0
    fi
    
    log_setup "Node.js not found. Installing..."
    
    case "$OS_TYPE" in
        macos)
            install_package node || return 1
            ;;
        linux)
            local pkg_mgr
            pkg_mgr=$(get_package_manager)
            
            # For Debian/Ubuntu, use NodeSource for latest LTS
            if [[ "$pkg_mgr" == "apt" ]]; then
                log_info "Installing Node.js from NodeSource repository..."
                if curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -; then
                    install_package nodejs || return 1
                else
                    log_warning "Failed to add NodeSource repository, trying default package..."
                    install_package nodejs || return 1
                fi
            else
                install_package nodejs || return 1
            fi
            ;;
        windows)
            install_package nodejs "OpenJS.NodeJS" || return 1
            ;;
        *)
            log_error "Unsupported OS for automatic Node.js installation"
            log_info "Please install Node.js manually: https://nodejs.org"
            return 1
            ;;
    esac
    
    # Verify installation
    if command_exists node && command_exists npm; then
        log_success "Node.js installed successfully"
        return 0
    else
        log_error "Node.js installation verification failed"
        return 1
    fi
}

#######################################
# Install Anthropic MCP CLI (amp)
#######################################
install_amp() {
    if command_exists amp; then
        log_success "amp is already installed"
        return 0
    fi
    
    log_setup "Installing amp (Anthropic MCP)..."
    
    # Ensure npm is available
    if ! command_exists npm; then
        install_nodejs || return 1
    fi
    
    if npm install -g @anthropic-ai/mcp 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "amp installed successfully"
        return 0
    else
        log_error "Failed to install amp"
        return 1
    fi
}

#######################################
# Install Claude CLI
#######################################
install_claude_cli() {
    if command_exists claude; then
        log_success "Claude CLI is already installed"
        return 0
    fi
    
    log_setup "Installing Claude CLI..."
    
    # Ensure npm is available
    if ! command_exists npm; then
        install_nodejs || return 1
    fi
    
    if npm install -g @anthropic-ai/claude-cli 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "Claude CLI installed successfully"
        return 0
    else
        log_error "Failed to install Claude CLI"
        return 1
    fi
}

#######################################
# Install opencode
#######################################
install_opencode() {
    if command_exists opencode; then
        log_success "opencode is already installed"
        return 0
    fi
    
    log_setup "Installing opencode..."
    
    case "$_RALPH_OS_TYPE" in
        linux|macos)
            local install_script
            install_script=$(create_temp_file)
            
            # Download installer
            if ! curl -fsSL https://raw.githubusercontent.com/stackblitz/opencode/main/install.sh -o "$install_script"; then
                log_error "Failed to download opencode installer"
                return 1
            fi
            
            # Verify script looks legitimate (basic checks)
            if ! grep -q "#!/bin/bash" "$install_script"; then
                log_error "Downloaded script doesn't look like a bash script"
                return 1
            fi
            
            # Execute with safety measures
            if bash "$install_script"; then
                log_success "opencode installed successfully"
                return 0
            else
                log_error "opencode installation script failed"
                return 1
            fi
            ;;
        windows)
            log_error "opencode installation on Windows requires manual setup"
            log_info "Visit: https://github.com/stackblitz/opencode"
            return 1
            ;;
        *)
            log_error "Unsupported OS for opencode installation"
            return 1
            ;;
    esac
}

#######################################
# Install dolt (SQL database with Git-like versioning)
#######################################
install_dolt() {
    if command_exists dolt; then
        log_success "dolt is already installed"
        return 0
    fi
    
    log_setup "Installing dolt..."
    
    local install_script
    install_script=$(create_temp_file)
    
    if curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh -o "$install_script"; then
        if sudo bash "$install_script"; then
            log_success "dolt installed successfully"
            return 0
        else
            log_error "dolt installation script failed"
            return 1
        fi
    else
        log_error "Failed to download dolt installer"
        return 1
    fi
}

#######################################
# Install beads task tracker
#######################################
install_beads() {
    if command_exists bd; then
        log_success "beads (bd) is already installed"
        return 0
    fi
    
    log_setup "Installing beads (bd)..."
    
    if ! command_exists go; then
        log_error "Go is required to install beads. Please install Go first: https://go.dev/doc/install"
        return 1
    fi
    
    if go install github.com/steveyegge/beads/cmd/bd@latest 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "beads installed successfully to ~/go/bin/bd"
        log_info "Make sure ~/go/bin is in your PATH"
        return 0
    else
        log_error "Failed to install beads"
        return 1
    fi
}

#######################################
# Install md5sum utilities
#######################################
install_md5sum() {
    # Check for md5sum or md5
    if command_exists md5sum || command_exists md5; then
        log_success "MD5 utilities are already available"
        return 0
    fi
    
    log_setup "Installing MD5 utilities..."
    
    case "$OS_TYPE" in
        macos)
            # macOS has md5 by default, but install coreutils for md5sum
            install_package coreutils || {
                log_warning "Could not install coreutils, but md5 should be available"
                return 0
            }
            ;;
        linux)
            install_package coreutils || return 1
            ;;
        windows)
            install_package coreutils || {
                log_warning "Could not install coreutils, but certutil should be available"
                return 0
            }
            ;;
    esac
}

#######################################
# Install tiktoken for accurate token counting (optional)
#######################################
install_tiktoken() {
    if ! command_exists python3; then
        log_error "Python 3 is required to install tiktoken"
        return 1
    fi
    
    if ! command_exists pip3; then
        log_error "pip3 is required to install tiktoken"
        return 1
    fi
    
    log_setup "Installing tiktoken for accurate token counting..."
    
    if pip3 install --user tiktoken 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "tiktoken installed successfully"
        log_info "Token estimation will now use tiktoken for better accuracy"
        return 0
    else
        log_error "Failed to install tiktoken"
        log_info "Will continue using heuristic token estimation"
        return 1
    fi
}

#######################################
# Global variable to cache detected MD5 command
#######################################
declare MD5_COMMAND=""

#######################################
# Detect available MD5 command
# Sets MD5_COMMAND global variable
# Returns: 0 if found, 1 if not found
#######################################
detect_md5_command() {
    # Return cached result if already detected
    if [[ -n "$MD5_COMMAND" ]]; then
        return 0
    fi
    
    if command_exists md5sum; then
        MD5_COMMAND="md5sum"
    elif command_exists md5; then
        MD5_COMMAND="md5 -r"
    elif command_exists certutil; then
        # Windows fallback
        MD5_COMMAND="certutil -hashfile"
        log_debug "Using certutil for MD5 (Windows)"
    else
        log_debug "No MD5 command found"
        return 1
    fi
    
    log_debug "Detected MD5 command: $MD5_COMMAND"
    return 0
}

#######################################
# Cross-platform MD5 hash wrapper
# Arguments: Same as md5sum (file paths)
# Returns: MD5 hash output
#######################################
md5sum_wrapper() {
    if ! detect_md5_command; then
        log_error "No MD5 command available"
        return 1
    fi
    
    # Handle certutil differently (Windows)
    if [[ "$MD5_COMMAND" == "certutil -hashfile" ]]; then
        for file in "$@"; do
            certutil -hashfile "$file" MD5 | grep -v ":" | tr -d '[:space:]'
            echo "  $file"
        done
    else
        $MD5_COMMAND "$@"
    fi
}

#######################################

# Non-interactive dependency setup

# Installs core dependencies and all AI tools automatically

#######################################

setup_dependencies() {

    log_setup "=================================="

    log_setup "Ralph Setup - Auto-Installer"

    log_setup "=================================="

    log_setup "OS: $OS_TYPE ($ARCH_TYPE)"

    log_setup ""

    

    # Core check and install

    check_dependencies || exit 1

    

    log_setup "Installing AI & Engineering tools..."

    

    # 1. opencode

    if ! command_exists opencode; then

        install_opencode >/dev/null 2>&1 || log_warning "opencode installation failed"

    fi

    

    # 2. beads (bd)

    if ! command_exists bd; then

        # Ensure go is installed for beads

        if ! command_exists go; then

            install_package go >/dev/null 2>&1 || true

        fi

        install_beads >/dev/null 2>&1 || log_warning "beads installation failed"

    fi

    

    # 3. dolt

    if ! command_exists dolt; then

        install_dolt >/dev/null 2>&1 || log_warning "dolt installation failed"

    fi

    

    # 4. tiktoken & ruff (Use pacman for Arch)
    if [[ "$(get_package_manager)" == "pacman" ]]; then
        log_setup "Installing Python tools via pacman..."
        sudo pacman -S --noconfirm python-ruff python-tiktoken >/dev/null 2>&1 || true
    elif command_exists python3; then
        log_setup "Installing Python tools via pip..."
        pip3 install --user tiktoken ruff --break-system-packages >/dev/null 2>&1 || true
    fi
    
    # 5. claude-code & ast-grep
    log_setup "Installing Node-based tools (claude-code, ast-grep)..."
    local bun_bin="$HOME/.bun/bin/bun"
    if [[ ! -x "$bun_bin" ]]; then bun_bin=$(command -v bun || echo "bun"); fi
    
    if command_exists "$bun_bin"; then
        "$bun_bin" install -g @anthropic-ai/claude-code @ast-grep/cli >/dev/null 2>&1 || true
    elif command_exists npm; then
        npm install -g @anthropic-ai/claude-code @ast-grep/cli >/dev/null 2>&1 || true
    fi
    
    # 6. bc & sqlite3 (Ensure they are present)
    if [[ "$(get_package_manager)" == "pacman" ]]; then
        sudo pacman -S --noconfirm bc sqlite >/dev/null 2>&1 || true
    fi
    
    log_success "Auto-setup complete!"
    echo ""
    log_info "Installed components:"
    command_exists git && echo "  ✓ Git"
    command_exists jq && echo "  ✓ jq"
    command_exists bc && echo "  ✓ bc"
    command_exists sqlite3 && echo "  ✓ sqlite3"
    command_exists bun && echo "  ✓ Bun"
    command_exists opencode && echo "  ✓ opencode"
    command_exists bd && echo "  ✓ beads (bd)"
    command_exists dolt && echo "  ✓ dolt"
    command_exists ruff && echo "  ✓ ruff"
    command_exists sg && echo "  ✓ ast-grep (sg)"
    (command_exists claude-code || command_exists claude) && echo "  ✓ claude-code"

    

        

    

        

    

    

    

    echo ""

    log_info "You can now run Ralph with: ./ralph.sh"

}

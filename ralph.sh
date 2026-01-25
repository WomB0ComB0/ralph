#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude|opencode] [--max-iterations N] [--model MODEL] [--no-archive]

set -euo pipefail

# Color output for better readability
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly TYEL='\033[1;33m' # True Yellow (Bold)
readonly NC='\033[0m' # No Color

# Detect OS and Architecture
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "macos";;
        CYGWIN*|MINGW*|MSYS*) echo "windows";;
        *)          echo "unknown";;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64";;
        arm64|aarch64)  echo "arm64";;
        armv7l)         echo "arm";;
        *)              echo "unknown";;
    esac
}

OS_TYPE=$(detect_os)
readonly OS_TYPE
ARCH_TYPE=$(detect_arch)
readonly ARCH_TYPE

# Default configuration
TOOL="opencode"
MAX_ITERATIONS=10
SELECTED_MODEL=""
NO_ARCHIVE=false
VERBOSE=false
SETUP_MODE=false
INTERACTIVE_MODE=false
RESUME_FLAG=false
DIFF_CONTEXT_FLAG=false

# Script paths
PROJECT_DIR="$(pwd)"
readonly PROJECT_DIR
readonly PRD_FILE="$PROJECT_DIR/prd.json"
readonly PLAN_FILE="$PROJECT_DIR/ralph_plan.md"
readonly DIAGRAM_FILE="$PROJECT_DIR/ralph_architecture.md"
readonly PROGRESS_FILE="$PROJECT_DIR/progress.txt"
readonly ARCHIVE_DIR="$PROJECT_DIR/archive"
readonly LAST_BRANCH_FILE="$PROJECT_DIR/.last-branch"
readonly CHECKPOINT_FILE="$PROJECT_DIR/.ralph_checkpoint"
readonly METRICS_FILE="$PROJECT_DIR/metrics.log"
readonly LOG_FILE="$PROJECT_DIR/ralph.log"
readonly DEFAULT_GITDIFF_EXCLUDE="$HOME/.config/git/gitdiff-exclude"
GITDIFF_EXCLUDE="${GITDIFF_EXCLUDE:-$DEFAULT_GITDIFF_EXCLUDE}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_setup() {
    echo -e "${MAGENTA}[SETUP]${NC} $*" | tee -a "$LOG_FILE"
}

log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $*" | tee -a "$LOG_FILE"
    fi
}

log_metrics() {
    echo "$*" >> "$METRICS_FILE"
}

# Track temporary files for cleanup
declare -a temp_files=()

# Cleanup function for temporary files
# shellcheck disable=SC2329
_ralph_cleanup() {
    if [[ -n "${temp_files:-}" ]]; then
        for temp_file in "${temp_files[@]}"; do
            [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null || true
        done
    fi
}

trap _ralph_cleanup EXIT
trap 'exit 1' INT TERM

create_temp_file() {
    local temp_file
    temp_file=$(mktemp)
    temp_files+=("$temp_file")
    echo "$temp_file"
}

# ============================================================================
# DEPENDENCY INSTALLATION FUNCTIONS
# ============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get package manager for the current OS
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
            else
                echo "none"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Install package manager if missing
install_package_manager() {
    local pkg_mgr="$1"
    
    case "$pkg_mgr" in
        brew)
            log_setup "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            ;;
        choco)
            log_setup "Installing Chocolatey..."
            log_warning "Please run as Administrator:"
            log_warning "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
            exit 1
            ;;
        scoop)
            log_setup "Installing Scoop..."
            powershell -Command "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; iwr -useb get.scoop.sh | iex"
            ;;
        *)
            log_error "Unable to install package manager automatically for your system"
            return 1
            ;;
    esac
}

# Install a package using the appropriate package manager
install_package() {
    local package="$1"
    local pkg_mgr
    pkg_mgr=$(get_package_manager)
    
    log_setup "Installing $package using $pkg_mgr..."
    
    case "$pkg_mgr" in
        apt)
            sudo apt-get update && sudo apt-get install -y "$package"
            ;;
        dnf)
            sudo dnf install -y "$package"
            ;;
        yum)
            sudo yum install -y "$package"
            ;;
        pacman)
            sudo pacman -S --noconfirm "$package"
            ;;
        zypper)
            sudo zypper install -y "$package"
            ;;
        brew)
            brew install "$package"
            ;;
        choco)
            choco install -y "$package"
            ;;
        scoop)
            scoop install "$package"
            ;;
        *)
            log_error "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

# Install Git
install_git() {
    if command_exists git; then
        log_success "Git is already installed ($(git --version))"
        return 0
    fi
    
    log_setup "Git not found. Installing..."
    install_package git
}

# Install jq
install_jq() {
    if command_exists jq; then
        log_success "jq is already installed ($(jq --version))"
        return 0
    fi
    
    log_setup "jq not found. Installing..."
    install_package jq
}

# Install Node.js (required for some tools)
install_nodejs() {
    if command_exists node; then
        log_success "Node.js is already installed ($(node --version))"
        return 0
    fi
    
    log_setup "Node.js not found. Installing..."
    
    case "$OS_TYPE" in
        linux|macos)
            # Install using package manager
            if [[ "$OS_TYPE" == "macos" ]]; then
                install_package node
            else
                # For Linux, install via NodeSource
                curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
                install_package nodejs
            fi
            ;;
        windows)
            install_package nodejs
            ;;
    esac
}

# Install amp (Anthropic's MCP CLI)
install_amp() {
    if command_exists amp; then
        log_success "amp is already installed"
        return 0
    fi
    
    log_setup "Installing amp..."
    
    # Ensure npm is available
    if ! command_exists npm; then
        install_nodejs
    fi
    
    npm install -g @anthropic-ai/mcp
}

# Install Claude CLI
install_claude_cli() {
    if command_exists claude; then
        log_success "Claude CLI is already installed"
        return 0
    fi
    
    log_setup "Installing Claude CLI..."
    
    # Ensure npm is available
    if ! command_exists npm; then
        install_nodejs
    fi
    
    npm install -g @anthropic-ai/claude-cli
}

# Install opencode
install_opencode() {
    if command_exists opencode; then
        log_success "opencode is already installed"
        return 0
    fi
    
    log_setup "Installing opencode..."
    
    case "$OS_TYPE" in
        linux|macos)
            # Install via curl
            local install_script
            install_script=$(create_temp_file)
            curl -fsSL https://raw.githubusercontent.com/stackblitz/opencode/main/install.sh -o "$install_script"
            bash "$install_script"
            ;;
        windows)
            log_error "opencode installation on Windows requires manual setup"
            log_info "Visit: https://github.com/stackblitz/opencode"
            return 1
            ;;
    esac
}

# Install md5sum/md5 (for checksums)
install_md5sum() {
    # Check for md5sum or md5
    if command_exists md5sum || command_exists md5; then
        log_success "md5sum/md5 is already available"
        return 0
    fi
    
    log_setup "Installing coreutils for md5sum..."
    
    case "$OS_TYPE" in
        macos)
            # macOS has md5 by default, but we can install coreutils for md5sum
            install_package coreutils
            ;;
        linux)
            install_package coreutils
            ;;
        windows)
            # Windows uses certutil or we can install coreutils via choco
            install_package coreutils
            ;;
    esac
}

# Global variable to cache the detected MD5 command
MD5_COMMAND=""

detect_md5_command() {
    if [[ -n "$MD5_COMMAND" ]]; then
        return 0
    fi
    
    if command_exists md5sum; then
        MD5_COMMAND="md5sum"
    elif command_exists md5; then
        MD5_COMMAND="md5 -r"
    else
        return 1
    fi
}

# Cross-platform md5sum wrapper
# shellcheck disable=SC2120
md5sum_wrapper() {
    if ! detect_md5_command; then
        log_error "No MD5 command available"
        return 1
    fi
    $MD5_COMMAND "$@"
}

# Setup function - install all dependencies
setup_dependencies() {
    log_setup "=================================="
    log_setup "Ralph Setup - Dependency Installer"
    log_setup "=================================="
    log_setup "OS: $OS_TYPE ($ARCH_TYPE)"
    log_setup ""
    
    local pkg_mgr
    pkg_mgr=$(get_package_manager)
    
    if [[ "$pkg_mgr" == "unknown" || "$pkg_mgr" == "none" ]]; then
        log_error "No package manager detected"
        log_info "Attempting to install one..."
        
        if [[ "$OS_TYPE" == "macos" ]]; then
            install_package_manager "brew"
        elif [[ "$OS_TYPE" == "windows" ]]; then
            install_package_manager "scoop"
        else
            log_error "Please install a package manager manually"
            exit 1
        fi
        
        # Re-detect package manager
        pkg_mgr=$(get_package_manager)
    fi
    
    log_success "Package manager detected: $pkg_mgr"
    log_setup ""
    
    # Install core dependencies
    log_setup "Installing core dependencies..."
    install_git || log_error "Failed to install Git"
    install_jq || log_error "Failed to install jq"
    install_md5sum || log_warning "Could not install md5sum (may affect some features)"
    
    log_setup ""
    log_setup "Installing AI tools..."
    
    # Ask user which tools to install
    echo -e "${CYAN}Which AI tools would you like to install?${NC}"
    echo "1) amp (Anthropic MCP)"
    echo "2) claude-cli"
    echo "3) opencode"
    echo "4) All of the above"
    echo "5) Skip AI tools installation"
    read -rp "Enter your choice (1-5): " tool_choice
    
    case "$tool_choice" in
        1)
            install_amp
            ;;
        2)
            install_claude_cli
            ;;
        3)
            install_opencode
            ;;
        4)
            install_amp
            install_claude_cli
            install_opencode
            ;;
        5)
            log_info "Skipping AI tools installation"
            ;;
        *)
            log_warning "Invalid choice. Skipping AI tools installation"
            ;;
    esac
    
    log_setup ""
    log_success "=================================="
    log_success "Setup complete!"
    log_success "=================================="
    log_info "You can now run Ralph with: ./ralph.sh"
}

# ============================================================================
# NEW HELPER FUNCTIONS
# ============================================================================

# Load configuration from .ralphrc or ralph.json
load_config() {
    # Check for ralph.json (JSON config)
    if [[ -f "ralph.json" ]]; then
        log_info "Loading configuration from ralph.json..."
        if command_exists jq; then
            local json_tool json_model json_max_iter
            json_tool=$(jq -r '.tool // empty' ralph.json)
            json_model=$(jq -r '.model // empty' ralph.json)
            json_max_iter=$(jq -r '.maxIterations // empty' ralph.json)

            [[ -n "$json_tool" ]] && TOOL="$json_tool"
            [[ -n "$json_model" ]] && SELECTED_MODEL="$json_model"
            [[ -n "$json_max_iter" ]] && MAX_ITERATIONS="$json_max_iter"
        else
            log_warning "jq not found, skipping ralph.json parsing."
        fi
    fi

    # Check for .ralphrc (Shell script config)
    if [[ -f ".ralphrc" ]]; then
         log_info "Loading configuration from .ralphrc..."
         # Securely source? Well, it's a user config file.
         # shellcheck source=/dev/null
         source .ralphrc
    fi
}

# Compute a hash of the project state, excluding heavy directories
# This fixes the performance issue with scanning node_modules
compute_project_hash() {
    # Common heavy directories to exclude
    local prune_dirs=(-name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name vendor -o -name target -o -name bin -o -name obj -o -name .idea -o -name .vscode)
    
    # We use find to list files, sort them (for consistency), and hash them.
    # We then hash the list of file hashes to get a single state hash.
    
    # Use md5sum_wrapper directly for the final aggregate hash
    # For xargs, we use the detected command directly to avoid shell function limitations
    detect_md5_command || { log_error "No MD5 command available"; return 1; }

    find "$PROJECT_DIR" -type d \( "${prune_dirs[@]}" \) -prune -o -type f -print0 | \
        sort -z | \
        xargs -0 "$MD5_COMMAND" 2>/dev/null | \
        md5sum_wrapper | awk '{print $1}'
}

# Estimate tokens (heuristic: char count / 4)
estimate_tokens() {
    local content="$1"
    local len="${#content}"
    echo $((len / 4))
}

# Save checkpoint
save_checkpoint() {
    local iteration="$1"
    echo "$iteration" > "$CHECKPOINT_FILE"
    log_debug "Checkpoint saved: Iteration $iteration"
}

# Get last checkpoint
get_checkpoint() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        cat "$CHECKPOINT_FILE"
    else
        echo "0"
    fi
}

# ============================================================================
# ORIGINAL RALPH FUNCTIONS (Updated for OS compatibility)
# ============================================================================

# Display usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --setup                 Install all required dependencies
    --tool TOOL             AI tool to use: amp, claude, or opencode (default: opencode)
    --max-iterations N      Maximum number of iterations (default: 10)
    --model MODEL           Specific model to use (overrides auto-detection)
    --gitdiff-exclude FILE  Path to gitdiff exclude file (default: ~/.config/git/gitdiff-exclude)
    --no-archive            Skip archiving previous runs
    --verbose               Enable verbose output
    --resume                Resume from the last checkpoint
    --diff-context          Include recent git diffs (HEAD~1..HEAD) in context
    -h, --help              Show this help message

Grounded Architecture:
    Ralph operates using a "Grounded Architecture" to maintain long-term context
    across stateless tool iterations. It expects/manages the following files:
    
    1. prd.json              - Defined goals, user stories, and success metrics.
    2. ralph_plan.md        - Stateful execution plan with [ ] / [x] tracking.
    3. ralph_architecture.md - Mermaid diagrams modeling data flow and dependencies.
    
    The agent is instructed to maintain these files iteratively.

Configuration:
    You can store defaults in the following files in the project root:
    - ralph.json:  JSON format (supports: tool, model, maxIterations)
    - .ralphrc:    Shell script format (source-able)

Examples:
    $0 --setup                                  # Install dependencies
    $0 --tool opencode --max-iterations 20
    $0 --tool claude --model qwen2.5-coder
    $0 --gitdiff-exclude ./custom-exclude.txt

System Information:
    OS: $OS_TYPE
    Architecture: $ARCH_TYPE
    Package Manager: $(get_package_manager)

Gitdiff Exclude:
    The gitdiff-exclude file filters noise from git diffs.
    Format: One pattern per line, supports glob patterns and file paths.
    Default: ~/.config/git/gitdiff-exclude

EOF
    exit 0
}

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --setup)
                SETUP_MODE=true
                shift
                ;;
            --tool)
                TOOL="$2"
                shift 2
                ;;
            --tool=*)
                TOOL="${1#*=}"
                shift
                ;;
            --max-iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --max-iterations=*)
                MAX_ITERATIONS="${1#*=}"
                shift
                ;;
            --model)
                SELECTED_MODEL="$2"
                shift 2
                ;;
            --model=*)
                SELECTED_MODEL="${1#*=}"
                shift
                ;;
            --gitdiff-exclude)
                GITDIFF_EXCLUDE="$2"
                shift 2
                ;;
            --gitdiff-exclude=*)
                GITDIFF_EXCLUDE="${1#*=}"
                shift
                ;;
            --no-archive)
                NO_ARCHIVE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE_MODE=true
                shift
                ;;
            --resume)
                RESUME_FLAG=true
                shift
                ;;
            --diff-context)
                DIFF_CONTEXT_FLAG=true
                shift
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                # Legacy support: assume it's max_iterations if it's a number
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    MAX_ITERATIONS="$1"
                else
                    log_error "Unknown option: $1"
                    show_usage
                fi
                shift
                ;;
        esac
    done
}

# Validate configuration
validate_config() {
    if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "opencode" ]]; then
        log_error "Invalid tool '$TOOL'. Must be 'amp', 'claude', or 'opencode'."
        exit 1
    fi

    if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ITERATIONS" -lt 1 ]; then
        log_error "Max iterations must be a positive integer."
        exit 1
    fi
}

# Get the latest Flash or Pro model from opencode
get_latest_opencode_model() {
    local all_models
    all_models=$(opencode models 2>/dev/null || echo "")

    # Priority 1: Preferred families (Gemini, GLM, Claude) with "flash" or "pro" capabilities
    local high_perf_preferred
    high_perf_preferred=$(echo "$all_models" | grep -iE "gemini|glm|claude" | grep -iE "flash|pro" | grep -vE "audio|tts|embedding|image|live" || echo "")

    if [ -n "$high_perf_preferred" ]; then
        echo "$high_perf_preferred" | sort -V -r | head -n 1
        return
    fi

    # Priority 2: Any Preferred family model
    local any_preferred
    any_preferred=$(echo "$all_models" | grep -iE "gemini|glm|claude" | grep -vE "audio|tts|embedding|image|live" || echo "")

    if [ -n "$any_preferred" ]; then
        echo "$any_preferred" | sort -V -r | head -n 1
        return
    fi

    # Priority 3: Qwen models (as fallback)
    local qwen_model
    qwen_model=$(echo "$all_models" | grep -iE "qwen" | head -n 1)

    if [ -n "$qwen_model" ]; then
        echo "$qwen_model"
        return
    fi

    # Fallback to the first available model if any
    local first_model
    first_model=$(echo "$all_models" | head -n 1)

    if [ -n "$first_model" ]; then
        echo "$first_model"
        return
    fi

    # Final fallback
    echo "google/gemini-2.0-flash"
}

# Archive previous run if branch changed
archive_previous_run() {
    if [ "$NO_ARCHIVE" = true ]; then
        log_info "Archiving disabled via --no-archive flag"
        return
    fi

    if [ ! -f "$PRD_FILE" ] || [ ! -f "$LAST_BRANCH_FILE" ]; then
        return
    fi

    local current_branch last_branch
    current_branch=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [ -z "$current_branch" ] || [ -z "$last_branch" ] || [ "$current_branch" = "$last_branch" ]; then
        return
    fi

    # Archive the previous run
    local date folder_name archive_folder
    date=$(date +%Y-%m-%d_%H-%M-%S)
    folder_name=${last_branch#ralph/}
    archive_folder="$ARCHIVE_DIR/$date-$folder_name"

    log_info "Archiving previous run: $last_branch"
    mkdir -p "$archive_folder"
    
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$archive_folder/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$archive_folder/"
    [ -f "$LOG_FILE" ] && cp "$LOG_FILE" "$archive_folder/"
    
    log_success "Archived to: $archive_folder"

    # Reset progress file for new run
    initialize_progress_file
}

# Initialize progress file
initialize_progress_file() {
    cat > "$PROGRESS_FILE" << EOF
# Ralph Progress Log
Started: $(date)
Tool: $TOOL
Model: ${SELECTED_MODEL:-auto}
Max Iterations: $MAX_ITERATIONS
---
EOF
}

# Track current branch
track_current_branch() {
    if [ ! -f "$PRD_FILE" ]; then
        return
    fi

    local current_branch
    current_branch=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    
    if [ -n "$current_branch" ]; then
        echo "$current_branch" > "$LAST_BRANCH_FILE"
    fi
}

# Determine model to use
determine_model() {
    if [ -n "$SELECTED_MODEL" ]; then
        log_info "Using specified model: $SELECTED_MODEL"
        return
    fi

    if [[ "$TOOL" == "opencode" ]]; then
        SELECTED_MODEL=$(get_latest_opencode_model)
        log_info "Auto-selected model: $SELECTED_MODEL"
    else
        SELECTED_MODEL="claude-3-5-sonnet-20241022"
        log_info "Using default model: $SELECTED_MODEL"
    fi
}

# Build git diff exclude arguments from gitdiff-exclude file
build_gitdiff_exclude_args() {
    local exclude_args=""
    
    if [[ ! -f "$GITDIFF_EXCLUDE" ]]; then
        log_info "No gitdiff-exclude file found at: $GITDIFF_EXCLUDE"
        echo ""
        return
    fi
    
    log_info "Loading exclusions from: $GITDIFF_EXCLUDE"
    
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^# || -z "$line" ]]; then
            continue
        fi
        
        # Trim whitespace
        line=$(echo "$line" | xargs)
        
        # Expand tilde to home directory
        local expanded_path="${line/#\~/$HOME}"
        
        # Check if it's a pattern or a path
        if [[ -e "$expanded_path" ]]; then
            # It's a real file/directory, exclude it
            exclude_args+=" ':!$expanded_path'"
        elif [[ "$line" == *"*"* || "$line" == *"?"* ]]; then
            # It's a glob pattern, add it
            exclude_args+=" ':!$line'"
        else
            # Treat as glob pattern anyway
            exclude_args+=" ':!$line'"
        fi
    done < "$GITDIFF_EXCLUDE"
    
    echo "$exclude_args"
}

# ============================================================================
# UI & LOGIC HELPERS
# ============================================================================

# Print a styled header for the iteration
print_header() {
    local iteration=$1
    local max=$2
    local tool=$3
    local model=$4
    
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${TYEL}RALPH AGENT${NC} | Iteration: ${CYAN}${iteration}/${max}${NC} | Tool: ${MAGENTA}${tool}${NC}"
    echo -e "${BLUE}║${NC} Model: ${GREEN}${model}${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Generate the massive system prompt
generate_system_prompt() {
    local prompt_content="$1"
    local plan_context="$2"
    local prd_context="$3"
    local diagram_context="$4"
    local gitdiff_exclude_args="$5"
    local reflection_instruction="$6"
    local recent_changes="$7"

    cat <<EOF
<system_prompt>
<role>
You are Ralph, an autonomous AI Engineer.
You utilize **Structured Grounding**: PRDs for intent, Diagrams for architecture, and Plans for execution.
</role>

<capabilities>
1. **Full-Stack Engineering:** Expert in modern software delivery.
2. **Architectural Visualization:** You use Mermaid syntax in '$DIAGRAM_FILE' to model system state, data flow, and dependencies.
3. **Requirement Engineering:** You maintain '$PRD_FILE' (JSON) to define goals, user stories, and success metrics.
4. **Stateful Planning:** You maintain '$PLAN_FILE' (Markdown) to track iterative progress.
</capabilities>

<workflow>
1. **Initialize (Phase 0):** If missing, create '$PRD_FILE', '$DIAGRAM_FILE', and '$PLAN_FILE'.
2. **Align:** Ensure your code changes align with the Architecture ('$DIAGRAM_FILE') and Requirements ('$PRD_FILE').
3. **Execute:** Perform the next step in '$PLAN_FILE'.
4. **Update:** Reflect changes back into documentation files as the system evolves.
</workflow>

<constraints>
- **Diagram First:** For any new feature, update the diagram BEFORE writing code.
- **Maintain Sync:** If you refactor a function, update its representation in '$DIAGRAM_FILE'.
- **JSON PRD:** Ensure '$PRD_FILE' remains valid JSON.
- **Termination:** Output <promise>COMPLETE</promise> only when documentation and code are in sync and the task is done.
</constraints>

<user_request>
$prompt_content
</user_request>

<global_context>
<prd>
$prd_context
</prd>
<architecture_diagrams>
$diagram_context
</architecture_diagrams>
<execution_plan>
$plan_context
</execution_plan>
</global_context>

<git_diff_configuration>
The following patterns are excluded from git diff analysis:
$gitdiff_exclude_args
</git_diff_configuration>

<recent_changes>
$recent_changes
</recent_changes>

$reflection_instruction

<instructions>
Review the <global_context>. 
What is the current state of the architecture? 
What is the next requirement to fulfill?
Proceed with the next action.
</instructions>
</system_prompt>
EOF
}

# Run the selected AI tool with a spinner
run_ai_tool() {
    local tool="$1"
    local model="$2"
    local prompt="$3"
    local log_file="$4"
    local output_file="$5"
    
    log_info "Thinking with ${MAGENTA}${tool}${NC} (${model})..."
    log_debug "Prompt:\n$prompt"
    
    local pid spin i
    
    # Start tool in background
    {
        case "$tool" in
            amp)
                echo "$prompt" | amp --dangerously-allow-all 2>&1 | tee -a "$log_file" > "$output_file" &
                ;;
            claude)
                export ANTHROPIC_AUTH_TOKEN=ollama
                export ANTHROPIC_BASE_URL=http://localhost:11434
                claude --dangerously-skip-permissions --permission-mode bypassPermissions --model "$model" "$prompt" 2>&1 | tee -a "$log_file" > "$output_file" &
                ;;
            opencode)
                opencode run --model "$model" "$prompt" 2>&1 | tee -a "$log_file" > "$output_file" &
                ;;
        esac
    }
    
    pid=$!
    spin='-\|/'
    i=0
    
    # Spinner loop
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r%b[%s]%b Processing..." "${BLUE}" "${spin:$i:1}" "${NC}"
        sleep 0.1
    done
    wait $pid
    
    # Clear spinner line
    printf "\r\033[K"
    log_success "Response received."
}

# Validate key artifacts (PRD, Architecture, Plan)
validate_artifacts() {
    local instruction=""
    
    # 1. Check PRD JSON validity
    if [ -f "$PRD_FILE" ]; then
        if ! command_exists jq; then
             log_warning "jq not installed, skipping PRD validation."
        elif ! jq . "$PRD_FILE" >/dev/null 2>&1; then
            log_error "Ralph corrupted the PRD JSON."
            instruction+=$'\n'"<priority_interrupt>CRITICAL: You wrote invalid JSON to '$PRD_FILE'. FIX IT IMMEDIATELY using 'write_file'. Do not proceed until valid.</priority_interrupt>"
        fi
    fi

    # 2. Check Architecture Diagram (Mermaid)
    if [ -f "$DIAGRAM_FILE" ]; then
        # Basic heuristic: Check if it contains common mermaid keywords
        if ! grep -qE "graph|flowchart|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt" "$DIAGRAM_FILE"; then
            log_warning "Architecture diagram seems invalid (missing Mermaid keywords)."
            instruction+=$'\n'"<priority_interrupt>WARNING: '$DIAGRAM_FILE' does not appear to contain valid Mermaid syntax. Ensure it starts with 'graph TD', 'sequenceDiagram', etc.</priority_interrupt>"
        fi
    fi

    # 3. Check Execution Plan Format
    if [ -f "$PLAN_FILE" ]; then
        # Check if it contains at least one checkbox [ ] or [x]
        if ! grep -qF "[ ]" "$PLAN_FILE" && ! grep -qF "[x]" "$PLAN_FILE"; then
            log_warning "Execution plan missing checkboxes."
            instruction+=$'\n'"<priority_interrupt>WARNING: '$PLAN_FILE' is missing standard checkbox items ('- [ ]' or '- [x]'). Refactor it to be a valid checklist.</priority_interrupt>"
        fi
    fi
    
    echo "$instruction"
}

# Execute tool iteration
execute_iteration() {
    local iteration=$1
    local output
    local prompt_content
    local structured_prompt
    local temp_output
    local gitdiff_exclude_args
    local plan_context prd_context diagram_context
    local reflection_instruction=""
    local recent_changes=""
    
    # UI Header
    print_header "$iteration" "$MAX_ITERATIONS" "$TOOL" "$SELECTED_MODEL"
    
    # Create secure temp file
    temp_output=$(create_temp_file)
    
    # Build git diff exclusion arguments
    # Build git diff exclusion arguments
    gitdiff_exclude_args=$(build_gitdiff_exclude_args)

    # Capture recent changes if requested
    if [ "$DIFF_CONTEXT_FLAG" = true ]; then
        if command_exists git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
             # Check if there is a HEAD~1
             if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
                 recent_changes=$(git diff HEAD~1..HEAD -- . "$gitdiff_exclude_args" 2>/dev/null || echo "No diff available")
             else
                 recent_changes="No previous commit to diff against."
             fi
        else
            recent_changes="Git not available or not in a repo."
        fi
    fi
    
    # Capture state before run (Optimized)
    local project_hash_before project_hash_after
    project_hash_before=$(compute_project_hash)
    
    # Loop Detection: Hash the previous output (if any) to detect exact repetition
    local current_log_signature
    current_log_signature=$(tail -n 50 "$LOG_FILE" 2>/dev/null | md5sum_wrapper | cut -d' ' -f1 || echo "none")
    log_debug "Current log signature: $current_log_signature"
    
    # Read the user's task prompt
    if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
        prompt_content=$(cat "$PROJECT_DIR/CLAUDE.md")
    elif [ -f "$PROJECT_DIR/prompt.md" ]; then
        prompt_content=$(cat "$PROJECT_DIR/prompt.md")
    else
        log_error "No prompt file (CLAUDE.md or prompt.md) found."
        return 1
    fi

    # --- ACTIVE CONTEXT WINDOWING ---
    if [ -f "$PLAN_FILE" ]; then
        # Extract Header + Last 3 Done + First 10 Todo
        local plan_header plan_done plan_todo
        plan_header=$(head -n 5 "$PLAN_FILE")
        plan_done=$(grep "\[x\]" "$PLAN_FILE" | tail -n 3)
        plan_todo=$(grep "\[ \]" "$PLAN_FILE" | head -n 10)
        plan_context="${plan_header}"$'\n...\n'"${plan_done}"$'\n'"${plan_todo}"
    else
        plan_context="No plan file found."
    fi

    [ -f "$PRD_FILE" ] && prd_context=$(cat "$PRD_FILE") || prd_context="No PRD found. Create one if task is complex."
    [ -f "$DIAGRAM_FILE" ] && diagram_context=$(cat "$DIAGRAM_FILE") || diagram_context="No architecture diagrams found."

    # --- REFLEXION & CORRECTION LOGIC ---
    
    # 1. Check for specific instructions from previous iteration (Artifact Validation)
    if [ -n "${NEXT_INSTRUCTION:-}" ]; then
        reflection_instruction="$NEXT_INSTRUCTION"
        # Clear it for this run, effectively consuming the interrupt
        export NEXT_INSTRUCTION=""
    
    # 2. Check for Laziness
    elif [ "${LAZY_STREAK:-0}" -ge 2 ]; then
        log_warning "Stalling detected (Streak: $LAZY_STREAK). Injecting Reflexion Trigger."
        reflection_instruction="<reflexion_trigger>
CRITICAL WARNING: You have made NO progress for $LAZY_STREAK iterations.
ACTION REQUIRED:
1. REVIEW '$PRD_FILE' to ensure alignment.
2. UPDATE '$DIAGRAM_FILE' to visualize the bottleneck.
3. UPDATE '$PLAN_FILE' to pivot strategy.
</reflexion_trigger>"
    
    # 3. Check for Loops
    elif [ -n "${PREVIOUS_LOG_HASH:-}" ] && [ "$current_log_signature" == "$PREVIOUS_LOG_HASH" ]; then
        log_warning "Infinite Loop detected. Injecting Reflexion Trigger."
        reflection_instruction="<reflexion_trigger>
CRITICAL WARNING: Infinite loop detected.
ACTION REQUIRED:
1. Mark current approach as FAILED in '$PLAN_FILE'.
2. PROPOSE an alternative architecture in '$DIAGRAM_FILE'.
</reflexion_trigger>"
    fi

    # --- GENERATE PROMPT ---
    structured_prompt=$(generate_system_prompt \
        "$prompt_content" \
        "$plan_context" \
        "$prd_context" \
        "$diagram_context" \
        "$gitdiff_exclude_args" \
        "$reflection_instruction" \
        "$recent_changes")

    # Estimate tokens
    local est_tokens
    est_tokens=$(estimate_tokens "$structured_prompt")
    log_debug "Estimated prompt tokens: $est_tokens"

    # --- EXECUTE TOOL ---
    run_ai_tool "$TOOL" "$SELECTED_MODEL" "$structured_prompt" "$LOG_FILE" "$temp_output"

    output=$(cat "$temp_output")
    
    # --- ARTIFACT VALIDATION (Post-Run) ---
    # This sets the instruction for the NEXT loop if something broke
    local artifact_errors
    artifact_errors=$(validate_artifacts)
    if [ -n "$artifact_errors" ]; then
        export NEXT_INSTRUCTION="$artifact_errors"
    fi

    # --- POST-EXECUTION ANALYSIS ---
    project_hash_after=$(compute_project_hash)

    if [ "$project_hash_before" == "$project_hash_after" ]; then
        # No files changed
        LAZY_STREAK=$(( ${LAZY_STREAK:-0} + 1 ))
        log_warning "No files modified this iteration (Streak: $LAZY_STREAK)"
    else
        log_success "Files modified - agent is making progress"
        LAZY_STREAK=0
    fi

    # Log Metrics
    log_metrics "$(date +%Y-%m-%dT%H:%M:%S) | Iter: $iteration | Lazy: $LAZY_STREAK | Hash: $project_hash_after | Tokens: $est_tokens"

    # Save Checkpoint
    save_checkpoint "$iteration"

    # Update loop detection hash
    PREVIOUS_LOG_HASH="$current_log_signature"

    # Check for completion signal
    if echo "$output" | grep -q "<promise>COMPLETE</promise>"; then
        return 0
    fi

    return 1
}



# Main execution loop
main() {
    # Load config from file first (so CLI args can override)
    load_config

    parse_arguments "$@"
    
    # Handle setup mode
    if [ "$SETUP_MODE" = true ]; then
        setup_dependencies
        exit 0
    fi
    
    validate_config

    log_info "Starting Ralph Wiggum Agent"
    log_info "OS: $OS_TYPE ($ARCH_TYPE)"
    log_info "Configuration: Tool=$TOOL, Max Iterations=$MAX_ITERATIONS"

    # Setup
    archive_previous_run
    track_current_branch
    
    if [ ! -f "$PROGRESS_FILE" ]; then
        initialize_progress_file
    fi
    
    determine_model

    # Initialize state variables (make available to subfunctions)
    export LAZY_STREAK=0
    export PREVIOUS_LOG_HASH=""
    export NEXT_INSTRUCTION=""

    # Main iteration loop
    local start_iter=1
    
    if [ "$RESUME_FLAG" = true ]; then
        local last_checkpoint
        last_checkpoint=$(get_checkpoint)
        if [[ "$last_checkpoint" =~ ^[0-9]+$ ]] && [ "$last_checkpoint" -gt 0 ]; then
            log_info "Resuming from checkpoint: Iteration $last_checkpoint"
            start_iter=$((last_checkpoint + 1))
        else
            log_warning "No valid checkpoint found. Starting from 1."
        fi
    fi

    for i in $(seq "$start_iter" "$MAX_ITERATIONS"); do
        
        # Interactive Mode Pause
        if [ "$INTERACTIVE_MODE" = true ]; then
            echo ""
            echo -e "${YELLOW}>>> Interactive Mode Paused <<<${NC}"
            read -rp "Press [Enter] to continue, or type an instruction for Ralph: " user_input
            if [ -n "$user_input" ]; then
                export NEXT_INSTRUCTION="<user_steering>$user_input</user_steering>"
                log_info "User steering injected for next iteration."
            fi
        fi

        if execute_iteration "$i"; then
            echo ""
            log_success "Ralph completed all tasks!"
            log_success "Completed at iteration $i of $MAX_ITERATIONS"
            exit 0
        fi

        log_info "Iteration $i complete. Continuing..."
        sleep 2
    done

    echo ""
    log_warning "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
    log_info "Check $PROGRESS_FILE for status."
    exit 1
}

# Run main function
main "$@"

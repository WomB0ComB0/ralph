#!/bin/bash

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
    CONTEXT_FILES=()
    
    # Artifact defaults
    PROGRESS_FILE="${PROGRESS_FILE:-ralph_progress.log}"
    PRD_FILE="${PRD_FILE:-prd.json}"
    PLAN_FILE="${PLAN_FILE:-ralph_plan.md}"
    DIAGRAM_FILE="${DIAGRAM_FILE:-ralph_architecture.md}"
    LOG_FILE="${LOG_FILE:-ralph.log}"
    PROJECT_DIR="${PROJECT_DIR:-.}"

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
    local checkpoint_file="${CHECKPOINT_FILE:-checkpoint.txt}"
    
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
    local checkpoint_file="${CHECKPOINT_FILE:-checkpoint.txt}"
    
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
${CYAN}Ralph - AI-Powered Development Assistant${NC}

${YELLOW}Usage:${NC}
    $0 [OPTIONS]

${YELLOW}Options:${NC}
    ${GREEN}--setup${NC}                 Install all required dependencies
    ${GREEN}--test${NC}                  Run internal test suite
    ${GREEN}--tool${NC} TOOL             AI tool: amp, claude, or opencode (default: opencode)
    ${GREEN}--max-iterations${NC} N      Maximum iterations (default: 10)
    ${GREEN}--model${NC} MODEL           Specific model to use (overrides auto-detection)
    ${GREEN}--gitdiff-exclude${NC} FILE  Path to gitdiff exclude file
                              (default: ~/.config/git/gitdiff-exclude)
    ${GREEN}--no-archive${NC}            Skip archiving previous runs
    ${GREEN}--verbose${NC}               Enable verbose/debug output
    ${GREEN}--resume${NC}                Resume from last checkpoint
    ${GREEN}--diff-context${NC}          Include recent git diffs in context
    ${GREEN}--context${NC} FILE          Add file to context (repeatable)
    ${GREEN}--sandbox${NC}               Run in Docker sandbox (requires Docker)
    ${GREEN}--no-sandbox${NC}            Force run without sandbox
    ${GREEN}-h, --help${NC}              Show this help message

${YELLOW}Grounded Architecture:${NC}
    Ralph uses a "Grounded Architecture" to maintain long-term context
    across stateless tool iterations:
    
    ${GREEN}1. prd.json${NC}              - Goals, user stories, success metrics
    ${GREEN}2. ralph_plan.md${NC}        - Execution plan with [ ] / [x] tracking
    ${GREEN}3. ralph_architecture.md${NC} - Mermaid diagrams for data flow

${YELLOW}Configuration Files:${NC}
    Store defaults in project root:
    
    ${GREEN}ralph.json${NC}    - JSON format (keys: tool, model, maxIterations, sandbox, verbose)
    ${GREEN}.ralphrc${NC}      - Shell script format (higher priority than ralph.json)
    
    Priority: Command-line args > .ralphrc > ralph.json > defaults

${YELLOW}Examples:${NC}
    ${CYAN}# Install dependencies${NC}
    $0 --setup
    
    ${CYAN}# Run with specific tool and iterations${NC}
    $0 --tool opencode --max-iterations 20
    
    ${CYAN}# Use specific model${NC}
    $0 --tool claude --model qwen2.5-coder
    
    ${CYAN}# Add context files and run in sandbox${NC}
    $0 --context docs/api.md --context README.md --sandbox
    
    ${CYAN}# Resume from checkpoint with verbose output${NC}
    $0 --resume --verbose

${YELLOW}System Information:${NC}
    OS:               $OS_TYPE
    Architecture:     $ARCH_TYPE
    Package Manager:  $(get_package_manager)

${YELLOW}Gitdiff Exclude:${NC}
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
                shift 2
                ;;
            --model=*)
                SELECTED_MODEL="${1#*=}"
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
    local branch_file="${LAST_BRANCH_FILE:-.ralph_last_branch}"
    
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
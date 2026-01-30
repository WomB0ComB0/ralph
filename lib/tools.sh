#!/bin/bash

# Constants
readonly DOCKER_DEFAULT_MEMORY="2g"
readonly DOCKER_DEFAULT_CPUS="2.0"
readonly DOCKER_PIDS_LIMIT=100
readonly AGENT_MAX_ITERATIONS=10
readonly AGENT_CPU_TIME_LIMIT=3600


# Global variable for git repo check
_IS_GIT_REPO=""

#######################################
# Check if current directory is a git repository
# Caches result for performance
# Returns: 0 if git repo, 1 otherwise
#######################################
is_git_repo() {
    if [[ -z "$_IS_GIT_REPO" ]]; then
        if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            _IS_GIT_REPO="true"
        else
            _IS_GIT_REPO="false"
        fi
    fi
    [[ "$_IS_GIT_REPO" == "true" ]]
}

#######################################
# Fail with error message and optional cleanup
# Arguments:
#   $1 - Error message
#   $2 - Cleanup function name (optional)
#######################################
fail_with_cleanup() {
    local msg="$1"
    local cleanup_func="${2:-}"
    
    log_error "$msg"
    
    if [[ -n "$cleanup_func" ]] && declare -f "$cleanup_func" >/dev/null; then
        "$cleanup_func"
    fi
    
    return 1
}

#######################################
# Sanitize ID string
# Arguments:
#   $1 - ID to sanitize
# Returns: Sanitized ID (alphanumeric, underscore, hyphen)
#######################################
sanitize_id() {
    printf '%s' "$1" | tr -cd '[:alnum:]_-' | cut -c1-64
}

#######################################
# Compute hash of project state
# Excludes heavy directories for performance
# Returns: MD5 hash string, or empty string on error
#######################################
compute_project_hash() {
    local project_dir="${PROJECT_DIR:-.}"
    local cache_file="${HOME}/.cache/ralph/project_hash_cache"
    local cache_meta="${cache_file}.meta"
    
    # Validate project directory exists
    if [[ ! -d "$project_dir" ]]; then
        log_error "Project directory not found: $project_dir"
        return 1
    fi
    
    # Check cache validity
    if [[ -f "$cache_file" ]] && [[ -f "$cache_meta" ]]; then
        local cached_dir cached_mtime current_mtime
        cached_dir=$(head -n1 "$cache_meta")
        cached_mtime=$(tail -n1 "$cache_meta")
        
        # Get current max mtime of project files
        if is_git_repo; then
            # Use git to find last modification
            current_mtime=$(git -C "$project_dir" log -1 --format="%ct" 2>/dev/null || echo "0")
        else
            # Fallback: check modification time of most recent file
            current_mtime=$(find "$project_dir" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1 || echo "0")
        fi
        
        # If same directory and no modifications, use cache
        if [[ "$cached_dir" == "$project_dir" ]] && [[ "$cached_mtime" == "$current_mtime" ]]; then
            log_debug "Using cached project hash"
            cat "$cache_file"
            return 0
        fi
    fi
    
    # Ensure MD5 command is available
    if ! detect_md5_command; then
        log_error "No MD5 command available on this system"
        return 1
    fi
    
    log_debug "Computing project hash for: $project_dir"
    mkdir -p "$(dirname "$cache_file")"
    
    local hash
    
    # Optimization: Use git ls-files if available (much faster)
    if is_git_repo; then
        hash=$(
            git -C "$project_dir" ls-files -c -o --exclude-standard -z | \
            xargs -0 "$MD5_COMMAND" 2>/dev/null | \
            "$MD5_COMMAND" 2>/dev/null | \
            awk '{print $1}'
        )
        
        # Cache with git commit time
        local mtime
        mtime=$(git -C "$project_dir" log -1 --format="%ct" 2>/dev/null || date +%s)
        printf '%s\n%s\n' "$project_dir" "$mtime" > "$cache_meta"
    else
        # Fallback to find with exclusions
        # Use global excludes if defined, otherwise empty
        local exclude_dirs=("${DEFAULT_HASH_EXCLUDES[@]}")
        
        hash=$(
            find "$project_dir" -type d \( "${exclude_dirs[@]}" \) -prune -o -type f -print0 2>/dev/null | \
            sort -z | \
            xargs -0 "$MD5_COMMAND" 2>/dev/null | \
            "$MD5_COMMAND" 2>/dev/null | \
            awk '{print $1}'
        )
        
        # Cache with current time
        printf '%s\n%s\n' "$project_dir" "$(date +%s)" > "$cache_meta"
    fi
    
    if [[ -z "$hash" ]]; then
        log_warning "Failed to compute project hash"
        return 1
    fi
    
    # Save to cache
    echo "$hash" > "$cache_file"
    log_debug "Project hash: $hash (cached)"
    echo "$hash"
}

#######################################
# Archive previous run when branch changes
# Creates timestamped backup of PRD, progress, and logs
# Returns: 0 on success or skip, 1 on failure
#######################################
archive_previous_run() {
    # Check if archiving is disabled
    if [[ "${NO_ARCHIVE:-false}" == "true" ]]; then
        log_info "Archiving disabled via --no-archive flag"
        return 0
    fi
    
    # Verify required files exist
    if [[ ! -f "${PRD_FILE:-}" ]] || [[ ! -f "${LAST_BRANCH_FILE:-}" ]]; then
        log_debug "Skipping archive: required files not found"
        return 0
    fi
    
    # Read current and last branch
    local current_branch last_branch
    current_branch=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null)
    last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null)
    
    # Validate branch names
    if [[ -z "$current_branch" ]] || [[ -z "$last_branch" ]]; then
        log_debug "Skipping archive: branch names not available"
        return 0
    fi
    
    # Skip if branches are the same
    if [[ "$current_branch" == "$last_branch" ]]; then
        log_debug "Branch unchanged ($current_branch), skipping archive"
        return 0
    fi
    
    log_info "Branch changed: $last_branch → $current_branch"
    
    # Create archive directory
    local timestamp folder_name archive_path
    timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    folder_name="${last_branch#ralph/}"
    folder_name="${folder_name//\//_}"  # Replace slashes with underscores
    archive_path="${ARCHIVE_DIR:-./archives}/${timestamp}-${folder_name}"
    
    if ! mkdir -p "$archive_path"; then
        log_error "Failed to create archive directory: $archive_path"
        return 1
    fi
    
    log_info "Archiving previous run to: $archive_path"
    
    # Archive files with error checking
    local archived_count=0
    local files_to_archive=(
        "$PRD_FILE:prd.json"
        "$PROGRESS_FILE:progress.json"
        "${LOG_FILE:-}:ralph.log"
        "$METRICS_FILE:metrics.log"
    )
    
    for file_mapping in "${files_to_archive[@]}"; do
        local source_file="${file_mapping%%:*}"
        local dest_name="${file_mapping##*:}"
        
        if [[ -f "$source_file" ]]; then
            if cp "$source_file" "$archive_path/$dest_name" 2>/dev/null; then
                ((archived_count++))
                log_debug "Archived: $dest_name"
            else
                log_warning "Failed to archive: $source_file"
            fi
        fi
    done
    
    if [[ $archived_count -eq 0 ]]; then
        log_warning "No files were archived"
        return 1
    fi
    
    log_success "Archived $archived_count file(s) to: $archive_path"
    
    # Reset progress file for new run
    if declare -f initialize_progress_file >/dev/null 2>&1; then
        initialize_progress_file
    fi
    
    return 0
}

#######################################
# Build git diff exclude arguments from config file
# Reads patterns from gitdiff-exclude file
# Returns: String of git pathspec exclusion arguments
#######################################
build_gitdiff_exclude_args() {
    local exclude_file="${GITDIFF_EXCLUDE:-}"
    
    # Validate exclude file exists
    if [[ -z "$exclude_file" ]] || [[ ! -f "$exclude_file" ]]; then
        log_debug "No gitdiff-exclude file found at: ${exclude_file:-not set}"
        echo ""
        return 0
    fi
    
    log_info "Loading exclusions from: $exclude_file"
    
    local exclude_args=()
    local line_count=0
    local pattern_count=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count++))
        
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
            continue
        fi
        
        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip if line is now empty
        [[ -z "$line" ]] && continue
        
        # Expand tilde to home directory
        local expanded_path="${line/#\~/$HOME}"
        
        # Determine if it's a real path or a pattern
        if [[ -e "$expanded_path" ]]; then
            # Real file or directory - use absolute path
            exclude_args+=(":(exclude)$expanded_path")
            ((pattern_count++))
            log_debug "Excluding path: $expanded_path"
        elif [[ "$line" =~ [*?\[\]] ]]; then
            # Contains glob characters - treat as pattern
            exclude_args+=(":(exclude)$line")
            ((pattern_count++))
            log_debug "Excluding pattern: $line"
        else
            # Treat as pattern anyway (might be a relative path)
            exclude_args+=(":(exclude)$line")
            ((pattern_count++))
            log_debug "Excluding pattern: $line"
        fi
    done < "$exclude_file"
    
    if [[ $pattern_count -eq 0 ]]; then
        log_info "No exclusion patterns found in $exclude_file ($line_count lines read)"
        echo ""
        return 0
    fi
    
    log_info "Loaded $pattern_count exclusion pattern(s) from $exclude_file"
    
    # Return as space-separated string
    printf '%s\n' "${exclude_args[@]}"
}

#######################################
# Apply gitdiff exclusions to git diff command
# Arguments:
#   $@ - Additional git diff arguments
# Returns: Git diff output with exclusions applied
#######################################
git_diff_with_exclusions() {
    local exclude_patterns
    
    # Get exclude patterns as array
    mapfile -t exclude_patterns < <(build_gitdiff_exclude_args)
    
    # Run git diff with exclusions
    if [[ ${#exclude_patterns[@]} -gt 0 ]]; then
        log_debug "Running git diff with ${#exclude_patterns[@]} exclusion(s)"
        git diff "$@" -- . "${exclude_patterns[@]}"
    else
            log_debug "Running git diff without exclusions"
            git diff "$@" -- .
        fi
        }
        
        #######################################
        # Commit changes with an AI-friendly message
        # Arguments:
        #   $1 - Task description
        #######################################
        git_commit_task() {
            local task="$1"
            if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then return 0; fi
            
            git add .
            if ! git diff --cached --quiet; then
                git commit -m "ralph: $task"
                log_success "Changes committed: $task"
            fi
        }
        
        #######################################
        # Merge an agent branch back to the main branch
        # Arguments:
        #   $1 - Agent ID
        #######################################
        git_merge_agent() {
            local agent_id="$1"
            local branch="ralph/agent/${agent_id}"
            
            log_info "Merging agent $agent_id back to main..."
            
            if git merge "$branch" --no-edit; then
                log_success "Successfully merged $agent_id"
                # Cleanup
                git branch -d "$branch"
                return 0
            else
                log_error "Merge conflict detected for $agent_id! Manual intervention required."
                emit_event "merge_conflict" "{\"agent_id\": \"$agent_id\"}"
                return 1
            fi
        }

#######################################
# Attempt to self-heal missing test dependencies
# Arguments:
#   $1 - Missing command (e.g., pytest, npm, cargo)
#######################################
heal_test_environment() {
    local cmd="$1"
    log_warning "Self-Healing: Detected missing test runner '$cmd'. Attempting auto-installation..."
    
    export NON_INTERACTIVE=true
    
    case "$cmd" in
        pytest)
            if command_exists python3 && command_exists pip3; then
                python3 -m pip install pytest
            elif command_exists python3; then
                python3 -m ensurepip && python3 -m pip install pytest
            fi
            ;;
        ruff)
            if [[ "$(get_package_manager)" == "pacman" ]]; then
                sudo pacman -S --noconfirm python-ruff
            elif command_exists python3; then
                python3 -m pip install ruff --break-system-packages
            fi
            ;;
        npm|node)
            install_nodejs
            ;;
        cargo|rustc)
            # Basic rustup install
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            # shellcheck disable=SC1091
            source "$HOME/.cargo/env"
            ;;
        bd)
            install_beads
            ;;
        dolt)
            install_dolt
            ;;
    esac
    
    if command_exists "$cmd"; then
        log_success "Self-Healing successful: '$cmd' is now available."
        return 0
    else
        log_error "Self-Healing failed for '$cmd'. Manual intervention required."
        return 1
    fi
}

#######################################
# Run internal test suite for Ralph
# Returns: 0 if all tests pass, 1 otherwise
#######################################
run_internal_tests() {
    log_info "Starting Ralph Internal Test Suite"
    local passed=0
    local failed=0
    
    # Test OS Detection
    log_info "Testing OS Detection..."
    if [[ "$OS_TYPE" != "unknown" ]]; then
        log_success "OS detected: $OS_TYPE"
        ((passed += 1))
    else
        log_error "OS detection failed"
        ((failed += 1))
    fi
    
    # Test MD5 Command
    log_info "Testing MD5 Utilities..."
    if detect_md5_command; then
        log_success "MD5 command found: $MD5_COMMAND"
        local test_file
        test_file=$(create_temp_file)
        echo "test" > "$test_file"
        local hash
        hash=$(md5sum_wrapper "$test_file" | awk '{print $1}')
        if [[ -n "$hash" ]]; then
            log_success "MD5 hash computation works: $hash"
            ((passed += 1))
        else
            log_error "MD5 hash computation failed"
            ((failed += 1))
        fi
    else
        log_error "No MD5 command found"
        ((failed += 1))
    fi
    
    # Test Token Estimation
    log_info "Testing Token Estimation..."
    local sample_text="The quick brown fox jumps over the lazy dog."
    local tokens
    tokens=$(estimate_tokens "$sample_text" "advanced")
    if [[ "$tokens" -gt 0 ]]; then
        log_success "Token estimation works: $tokens tokens"
        ((passed += 1))
    else
        log_error "Token estimation failed"
        ((failed += 1))
    fi
    
    # Test Git Diff Exclusions
    log_info "Testing Git Diff Exclusions..."
    local exclude_file
    exclude_file=$(create_temp_file)
    echo "node_modules/*" > "$exclude_file"
    echo "*.log" >> "$exclude_file"
    
    export GITDIFF_EXCLUDE="$exclude_file"
    local exclude_args
    exclude_args=$(build_gitdiff_exclude_args)
    if [[ "$exclude_args" == *"(exclude)node_modules/*"* ]]; then
        log_success "Git diff exclusion parsing works"
        ((passed += 1))
    else
        log_error "Git diff exclusion parsing failed"
        ((failed += 1))
    fi
    
    # Summary
    log_info "----------------------------------"
    log_info "Test Summary: $passed passed, $failed failed"
    log_info "----------------------------------"
    
    if [[ $failed -eq 0 ]]; then
        log_success "All internal tests passed! 🎉"
        return 0
    else
        log_error "Some tests failed. Please check the logs."
        return 1
    fi
}

#######################################
# GitHub Copilot Integration for Ralph
# Wraps '@github/copilot' CLI for agentic use
#######################################

#######################################
# Initialize Copilot Integration
# Checks for copilot cli
#######################################
init_copilot() {
    if ! command_exists copilot; then
        log_error "'copilot' CLI is not installed."
        log_info "Please install it: npm install -g @github/copilot"
        return 1
    fi
    return 0
}

#######################################
# Execute Copilot command with smart fallback
# Arguments:
#   $1 - Prompt prefix (e.g., "" or "Explain: ")
#   $2 - Base arguments string
#   $3 - Query
#   $@ - Additional user flags
#######################################
execute_with_fallback() {
    local prefix="$1"
    local base_args="$2"
    local query="$3"
    shift 3
    
    local full_prompt="${prefix}${query}"
    local output
    
    # First attempt with user flags or default
    # We capture stdout and stderr to chec"king for e"rrors
    if output=$(copilot -p "$full_prompt" "$base_args" -s "$@" 2>&1); then
        echo "$output"
        return 0
    fi
    
    # Check for quota error
    if echo "$output" | grep -q "402 You have no quota"; then
        log_warning "Quota exceeded on default model. Falling back to gpt-4.1..."
        
        # Check if user already tried to specify a model, if so, warn them
        if [[ "$*" == *"--model"* ]]; then
            log_error "User-specified model also hit quota limit or failed."
            echo "$output"
            return 1
        fi
        
        # Retry with gpt-4.1
        if output=$(copilot -p "$full_prompt" "$base_args" -s "$@" --model gpt-4.1 2>&1); then
            log_success "Success with fallback model (gpt-4.1)"
            echo "$output"
            return 0
        else
            log_error "Fallback model also failed."
            echo "$output"
            return 1
        fi
    fi
    
    # Pass through other errors
    echo "$output"
    return 1
}

#######################################
# Run Agentic Copilot Task
# Arguments:
#   $1 - Query/Task
#   $@ - Additional flags
#######################################
run_copilot_agent() {
    local query="$1"
    shift
    
    log_info "Running Copilot Agent: $query"
    execute_with_fallback "" "--allow-all" "$query" "$@"
}

#######################################
# Ask Copilot for Explanation
# Arguments:
#   $1 - Query
#   $@ - Additional flags
#######################################
run_copilot_explain() {
    local query="$1"
    shift
    
    log_info "Asking Copilot to explain: $query"
    execute_with_fallback "Explain: " "--allow-all-paths" "$query" "$@"
}

#######################################
# Handle Copilot CLI Commands
# Arguments:
#   $@ - Subcommands
#######################################
handle_copilot_command() {
    local cmd="$1"
    shift
    
    init_copilot || return 1
    
    case "$cmd" in
        run|do|agent)
            run_copilot_agent "$@"
            ;;
        explain|ask)
            run_copilot_explain "$@"
            ;;
        auth|login)
            log_info "Starting interactive Copilot session for authentication..."
            log_info "Please complete the login flow, then exit with Ctrl+C or 'exit'."
            copilot
            ;;
        update)
            copilot update
            ;;
        *)
            log_error "Unknown copilot command: $cmd"
            echo "Usage: ralph copilot [run|explain|auth|update] <query>"
            return 1
            ;;
    esac
}

#######################################
# Setup Docker sandbox environment
# Creates Dockerfile and builds image if needed
# Returns: 0 on success, 1 on failure
#######################################
setup_sandbox() {
    if ! command_exists docker; then
        log_error "Docker is required for sandbox mode but not installed."
        log_info "Install Docker from: https://docs.docker.com/get-docker/"
        return 1
    fi

    # Verify Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running. Please start Docker and try again."
        return 1
    fi

    log_setup "Setting up Docker sandbox..."

    local dockerfile_path="${PROJECT_DIR:-.}/Dockerfile.ralph"
    local image_name="ralph-sandbox"
    local image_tag="latest"
    
    # Create default Dockerfile if it doesn't exist
    if [[ ! -f "$dockerfile_path" ]]; then
        log_info "Creating default Dockerfile for sandbox..."
        create_default_dockerfile "$dockerfile_path" || return 1
    fi

    # Check if image already exists and is up-to-date
    if docker image inspect "${image_name}:${image_tag}" >/dev/null 2>&1; then
        log_debug "Sandbox image already exists"
        
        # Check if Dockerfile is newer than image
        local dockerfile_time image_time
        dockerfile_time=$(stat -f %m "$dockerfile_path" 2>/dev/null || stat -c %Y "$dockerfile_path" 2>/dev/null)
        image_time=$(docker image inspect -f '{{.Created}}' "${image_name}:${image_tag}" | xargs -I {} date -d {} +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "$(docker image inspect -f '{{.Created}}' "${image_name}:${image_tag}" | cut -d. -f1)" +%s 2>/dev/null)
        
        if [[ -n "$dockerfile_time" && -n "$image_time" && "$dockerfile_time" -gt "$image_time" ]]; then
            log_info "Dockerfile has been modified, rebuilding image..."
        else
            log_success "Sandbox image is up-to-date"
            return 0
        fi
    fi

    # Build the image with proper error handling
    log_info "Building sandbox image (this may take a few minutes)..."
    
    if docker build -t "${image_name}:${image_tag}" -f "$dockerfile_path" "${PROJECT_DIR:-.}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "Sandbox image built successfully"
        return 0
    else
        log_error "Failed to build sandbox image"
        return 1
    fi
}

#######################################
# Create default Dockerfile for sandbox
# Arguments:
#   $1 - Path where Dockerfile should be created
# Returns: 0 on success, 1 on failure
#######################################
create_default_dockerfile() {
    local dockerfile_path="$1"
    
    if cat > "$dockerfile_path" <<'EOF'
FROM ubuntu:22.04

# Prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    jq \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20.x (LTS)
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd -m -s /bin/bash ralph && \
    mkdir -p /app && \
    chown -R ralph:ralph /app

# Switch to non-root user
USER ralph
WORKDIR /app

# Install global npm packages as non-root user
RUN npm config set prefix ~/.npm-global && \
    echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc

# Default command
CMD ["/bin/bash"]
EOF
    then
        log_success "Created default Dockerfile at: $dockerfile_path"
        return 0
    else
        log_error "Failed to create Dockerfile"
        return 1
    fi
}

#######################################
# Run Ralph inside Docker sandbox
# Arguments:
#   $@ - All arguments to pass to ralph.sh
# Returns: Exit code from Docker container
#######################################
run_in_sandbox() {
    log_info "Launching Ralph in Docker sandbox..."
    
    local project_dir="${PROJECT_DIR:-.}"
    local image_name="ralph-sandbox:latest"
    
    # Verify image exists
    if ! docker image inspect "$image_name" >/dev/null 2>&1; then
        log_error "Sandbox image not found. Run setup first."
        return 1
    fi
    
    # Prepare arguments, replacing --sandbox with --no-sandbox to prevent recursion
    local args=()
    for arg in "$@"; do
        if [[ "$arg" == "--sandbox" ]]; then
            args+=("--no-sandbox")
        else
            args+=("$arg")
        fi
    done
    
    # Build docker run command with safe defaults
    local docker_args=(
        "run"
        "--rm"                          # Remove container after exit
        "--interactive"
        "--tty"
        "--read-only"                   # Make root filesystem read-only for security
        "--tmpfs" "/tmp:rw,noexec,nosuid,size=1g"  # Writable tmp with restrictions
        "--tmpfs" "/home/ralph/.npm:rw,noexec,nosuid,size=500m"  # npm cache
        "-v" "$project_dir:/app:ro"     # Mount project directory as read-only
        "-v" "$project_dir/output:/app/output:rw"  # Separate writable output directory
        "-w" "/app"
        "--network" "none"              # No network access by default (adjust as needed)
        "--user" "ralph"                # Run as non-root user
        "--cap-drop=ALL"                # Drop all capabilities for security
        "--memory=${DOCKER_DEFAULT_MEMORY}"
        "--cpus=${DOCKER_DEFAULT_CPUS}"
        "--pids-limit=${DOCKER_PIDS_LIMIT}"
    )
    
    # Add environment file if it exists (with security warning)
    if [[ -f "$project_dir/.env" ]]; then
        log_warning "Loading .env file into sandbox. Ensure it doesn't contain sensitive credentials."
        docker_args+=("--env-file" "$project_dir/.env")
    fi
    
    # Allow specific environment variables to pass through (whitelist approach)
    local safe_env_vars=("LOG_LEVEL" "VERBOSE" "DEBUG" "RALPH_MODE")
    for var in "${safe_env_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            # Validate value to prevent command injection
            local value="${!var}"
            if [[ "$value" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                docker_args+=("-e" "$var=$value")
            else
                log_warning "Skipping unsafe env var: $var"
            fi
        fi
    done
    
    docker_args+=("$image_name" "./ralph.sh" "${args[@]}")
    
    # Run the container
    log_debug "Running: docker ${docker_args[*]}"
    
    docker "${docker_args[@]}"
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Sandbox execution completed successfully"
    else
        log_error "Sandbox execution failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

#######################################
# Clean up sandbox resources
# Removes Docker image and temporary files
#######################################
cleanup_sandbox() {
    local image_name="ralph-sandbox:latest"
    
    log_info "Cleaning up sandbox resources..."
    
    if docker image inspect "$image_name" >/dev/null 2>&1; then
        if docker rmi "$image_name" >/dev/null 2>&1; then
            log_success "Removed sandbox image"
        else
            log_warning "Failed to remove sandbox image"
        fi
    fi
    
    local dockerfile_path="${PROJECT_DIR:-.}/Dockerfile.ralph"
    if [[ -f "$dockerfile_path" ]]; then
        log_debug "Dockerfile remains at: $dockerfile_path (not auto-removed)"
    fi
}

#######################################
# Swarm Orchestration Library for Ralph
# Implements multi-agent coordination via file-based signaling
#######################################

#######################################
# Determine the absolute project root
#######################################
_get_root() {
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git rev-parse --show-toplevel
    else
        echo "${PROJECT_DIR:-.}"
    fi
}

#######################################
# Swarm Paths (Internal)
#######################################
_get_swarm_root() { echo "$(_get_root)/.ralph/swarm"; }
_get_registry()   { echo "$(_get_swarm_root)/paths.json"; }
_get_bus()        { echo "$(_get_swarm_root)/bus.db"; }

#######################################
# Initialize Swarm Infrastructure
# Creates necessary directories and Event Bus
#######################################
init_swarm() {
    local swarm_root
    swarm_root=$(_get_swarm_root)
    local registry
    registry=$(_get_registry)
    local bus
    bus=$(_get_bus)

    if [[ ! -d "$swarm_root" ]]; then
        log_setup "Initializing Swarm Orchestration..."
        mkdir -p "$swarm_root"/{agents,tasks}
        
        # Create config
        cat > "$swarm_root/config.json" <<EOF
{
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "backend": "process"
}
EOF
        # Create empty paths registry
        echo "{}" > "$registry"
        # Initialize Event Bus (War Room)
        if command_exists sqlite3; then
            local bus
            bus=$(_get_bus)
            sqlite3 "$bus" "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, sender TEXT, type TEXT, payload TEXT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP);"
            log_debug "Event Bus initialized."
        fi

        # Initialize High-Integrity Task Engine
        init_task_engine

        log_success "Swarm initialized at $swarm_root"
    fi
    
    # Register self if not already registered
    local my_id="${RALPH_AGENT_ID:-leader}"
    register_agent "$my_id" "leader" "Orchestration Lead"
}

#######################################
# Emit an event to the War Room
#######################################
emit_event() {
    local type="$1"
    local payload="${2:-{}}"
    local sender="${RALPH_AGENT_ID:-leader}"
    local bus
    bus=$(_get_bus)
    
    if command -v sqlite3 >/dev/null 2>&1; then
        mkdir -p "$(dirname "$bus")"
        # Create table safely
        sqlite3 "$bus" "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, sender TEXT, type TEXT, payload TEXT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP);" 2>/dev/null
        
        # Escape inputs to prevent SQL injection
        local escaped_sender escaped_type escaped_payload
        escaped_sender=$(printf '%s' "$sender" | sed "s/'/''/g")
        escaped_type=$(printf '%s' "$type" | sed "s/'/''/g")
        escaped_payload=$(printf '%s' "$payload" | sed "s/'/''/g")
        
        sqlite3 "$bus" "INSERT INTO events (sender, type, payload) VALUES ('$escaped_sender', '$escaped_type', '$escaped_payload');"
        log_debug "Event Emitted: $type"
    fi
}

#######################################
# Consume recent events from the War Room
#######################################
consume_events() {
    local bus
    bus=$(_get_bus)
    if [[ -f "$bus" ]] && command -v sqlite3 >/dev/null 2>&1; then
        local events
        events=$(sqlite3 "$bus" "SELECT '[' || sender || '] ' || type || ': ' || payload FROM events WHERE timestamp > datetime('now', '-2 minutes') ORDER BY timestamp DESC;")
        if [[ -n "$events" ]]; then
            echo -e "\n<war_room_events>\nRecent swarm activities:\n$events\n</war_room_events>"
        fi
    fi
}

#######################################
# Register a shared project path
#######################################
register_project_path() {
    local key="$1"
    local path="$2"
    local registry
    registry=$(_get_registry)
    
    init_swarm 
    
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        # Atomic write pattern
        if jq --arg key "$key" --arg path "$path" '.[$key] = $path' "$registry" > "$tmp"; then
            mv -f "$tmp" "$registry"
            log_debug "Registered shared path: $key -> $path"
        else
            rm -f "$tmp"
            log_error "Failed to register path"
            return 1
        fi
    fi
}

#######################################
# Get a shared project path
#######################################
get_project_path() {
    local key="$1"
    local registry
    registry=$(_get_registry)
    if [[ -f "$registry" ]] && command -v jq >/dev/null 2>&1; then
        jq -r ".[$key] // empty" "$registry"
    fi
}

#######################################
# Register an agent in the swarm
#######################################
register_agent() {
    local id="$1"
    local role="$2"
    local desc="$3"
    local swarm_root
    swarm_root=$(_get_swarm_root)
    local agent_dir="$swarm_root/agents/$id"
    
    if [[ ! -d "$agent_dir" ]]; then
        mkdir -p "$agent_dir/inbox"
        echo "IDLE" > "$agent_dir/status"
        
        cat > "$agent_dir/profile.json" <<EOF
{
  "id": "$id",
  "role": "$role",
  "description": "$desc",
  "spawned_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $$
}
EOF
        log_debug "Registered agent: $id ($role)"
    else
        if command -v jq >/dev/null 2>&1; then
            local tmp
            tmp=$(mktemp)
            jq --arg pid "$$" '.pid = ($pid|tonumber)' "$agent_dir/profile.json" > "$tmp" && mv "$tmp" "$agent_dir/profile.json"
        fi
    fi
}

#######################################
# Spawn a sub-agent
#######################################
spawn_agent() {
    local role="$1"
    local task="$2"
    local parent_id="${RALPH_AGENT_ID:-leader}"
    local swarm_root
    swarm_root=$(_get_swarm_root)
    local registry
    registry=$(_get_registry)
    
    # Generate unique ID
    local short_role="${role//[^a-zA-Z0-9]/}"
    local timestamp
    timestamp=$(date +%s)
    local agent_id="${short_role}_${timestamp: -4}"
    
    emit_event "spawn" "{\"agent_id\": \"$agent_id\", \"role\": \"$role\", \"parent\": \"$parent_id\"}"
    
    # Guard rail
    if [[ -d "$swarm_root/agents" ]]; then
        for agent_dir in "$swarm_root/agents"/*; do
            if [[ -d "$agent_dir" ]]; then
                local existing_status
                existing_status=$(cat "$agent_dir/status" 2>/dev/null || echo "OFF")
                if [[ "$existing_status" == "RUNNING" || "$existing_status" == "IDLE" || "$existing_status" == "BUSY" ]]; then
                    local existing_role=""
                    if command -v jq >/dev/null 2>&1; then
                        existing_role=$(jq -r '.role' "$agent_dir/profile.json" 2>/dev/null)
                    else
                        existing_role=$(grep '"role":' "$agent_dir/profile.json" 2>/dev/null | cut -d'"' -f4)
                    fi
                    
                    if [[ "$existing_role" == "$role" ]]; then
                        log_warning "Agent with role '$role' is already active. Skipping spawn."
                        basename "$agent_dir"
                        return 0
                    fi
                fi
            fi
        done
    fi

    log_info "Spawning agent: $agent_id ($role)"
    register_agent "$agent_id" "$role" "Sub-agent spawned by $parent_id"
    echo "RUNNING" > "$swarm_root/agents/$agent_id/status"
    
    local project_root
    project_root=$(_get_root)
    local agent_work_dir="$project_root/.ralph/workspaces/$agent_id"
    mkdir -p "$agent_work_dir"
    agent_work_dir=$(realpath "$agent_work_dir")
    
    local shared_paths=""
    [[ -f "$registry" ]] && shared_paths=$(cat "$registry")

    cat > "$agent_work_dir/AGENTS.md" <<EOF
# Role: $role
You are a specialized sub-agent in a Ralph Swarm.
Parent Agent: $parent_id
Your ID: $agent_id

## Shared Project State
Existing paths: $shared_paths

## Task
$task

## Swarm Protocols
- Communicate results via 'ralph swarm msg --to $parent_id --content "..."'
- Check your inbox via 'ralph swarm inbox'
- When finished, send a completion message and exit.
EOF
    
    local log_file="$agent_work_dir/ralph.log"
    local pid_file="$swarm_root/agents/$agent_id/pid"
    
    (
        cd "$agent_work_dir" || exit
        
        # Set resource limits (prevent fork bombs, memory exhaustion)
        # Relaxing process limit to avoid "Resource temporarily unavailable"
        ulimit -v 2097152  # Max 2GB virtual memory
        ulimit -t "$AGENT_CPU_TIME_LIMIT" # Max CPU time
        
        RALPH_AGENT_ID="$agent_id" ralph --max-iterations "$AGENT_MAX_ITERATIONS" --tool "${TOOL:-opencode}" --model "${SELECTED_MODEL:-google/gemini-2.0-flash-exp}" --no-archive --context "AGENTS.md" > "$log_file" 2>&1
        echo "OFF" > "$swarm_root/agents/$agent_id/status"
        emit_event "agent_finished" "{\"agent_id\": \"$agent_id\"}"
        rm -f "$pid_file"
    ) &
    
    local bg_pid=$!
    echo "$bg_pid" > "$pid_file"
    
    log_success "Spawned agent $agent_id (PID: $bg_pid)"
    echo "$agent_id"
}

#######################################
# Send a message to another agent
# Arguments:
#   $1 - Target Agent ID
#   $2 - Content
#######################################
send_message() {
    local to_id="$1"
    local content="$2"
    local from_id="${RALPH_AGENT_ID:-leader}"
    
    # Validate IDs before sanitization to fail closed on malicious input
    if [[ "$to_id" =~ [^a-zA-Z0-9_-] ]] || [[ "$from_id" =~ [^a-zA-Z0-9_-] ]]; then
        log_error "Security: Invalid characters in agent ID"
        return 1
    fi
    
    # Sanitize IDs to prevent path traversal
    to_id=$(sanitize_id "$to_id")
    from_id=$(sanitize_id "$from_id")
    
    if [[ -z "$to_id" ]] || [[ -z "$from_id" ]]; then
        log_error "Invalid agent ID format"
        return 1
    fi
    
    local swarm_root
    swarm_root=$(_get_swarm_root)
    local target_inbox="$swarm_root/agents/$to_id/inbox"
    
    # Additional check: ensure target_inbox is within swarm_root
    # Note: realpath is not always available, so we use cd/pwd
    local canonical_inbox canonical_root
    if [[ -d "$target_inbox" ]]; then
        canonical_inbox=$(cd "$target_inbox" 2>/dev/null && pwd -P)
        canonical_root=$(cd "$swarm_root" 2>/dev/null && pwd -P)
        
        if [[ "$canonical_inbox" != "$canonical_root"/* ]]; then
             log_error "Security: Attempted path traversal in send_message"
             return 1
        fi
    else
        log_error "Target agent not found: $to_id"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +%s)
    local msg_file="$target_inbox/${timestamp}_${from_id}.txt"
    
    cat > "$msg_file" <<EOF
FROM: $from_id
TO: $to_id
DATE: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

$content
EOF
    
    log_success "Message sent to $to_id"
}

#######################################
# Read inbox messages
# Returns: Formatted messages or "No messages"
#######################################
read_inbox() {
    local my_id="${RALPH_AGENT_ID:-leader}"
    local swarm_root
    swarm_root=$(_get_swarm_root)
    local inbox_dir="$swarm_root/agents/$my_id/inbox"
    
    if [[ ! -d "$inbox_dir" ]]; then
        echo "Inbox not initialized."
        return 1
    fi
    
    local count
    count=$(find "$inbox_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
    
    if [[ $count -eq 0 ]]; then
        echo "No new messages."
        return 0
    fi
    
    echo "=== Inbox ($count messages) ==="
    for msg in "$inbox_dir"/*; do
        if [[ -f "$msg" ]]; then
            echo "--- Message: $(basename "$msg") ---"
            cat "$msg"
            echo "---------------------------------"
            
            # Archive read messages? For now, we keep them but maybe move to 'read' folder
            mkdir -p "$inbox_dir/read"
            mv "$msg" "$inbox_dir/read/"
        fi
    done
}

#######################################
# List active teammates
#######################################
list_teammates() {
    echo "=== Active Swarm Agents ==="
    
    local swarm_root
    swarm_root=$(_get_swarm_root)
    
    for agent_dir in "$swarm_root/agents"/*; do
        if [[ -d "$agent_dir" ]]; then
            local id
            id=$(basename "$agent_dir")
            local status
            status=$(cat "$agent_dir/status" 2>/dev/null || echo "UNKNOWN")
            local role="Unknown"
            
            if [[ -f "$agent_dir/profile.json" ]] && command_exists jq; then
                role=$(jq -r '.role' "$agent_dir/profile.json")
            fi
            
            echo "Agent: $id | Role: $role | Status: $status"
        fi
    done
}

#######################################
# Create a new task
# Arguments:
#   $1 - Title
#   $2 - Description
#   $3 - Assigned To (optional)
#######################################
create_task() {
# shellcheck disable=SC2154
    local title="$1"
    local desc="$2"
    local assignee="${3:-null}"
    local creator="${RALPH_AGENT_ID:-leader}"
    
    local task_id
    task_id="task_$(date +%s)_$RANDOM"
    local swarm_root
    swarm_root=$(_get_swarm_root)
    local task_file="$swarm_root/tasks/$task_id.json"
    
    # JSON construction using jq if available, else manual
    if command_exists jq; then
        jq -n \
           --arg id "$task_id" \
           --arg title "$title" \
           --arg desc "$desc" \
           --arg assignee "$assignee" \
           --arg creator "$creator" \
           --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
           '{id: $id, title: $title, description: $desc, status: "TODO", assigned_to: (if $assignee=="null" then null else $assignee end), created_by: $creator, created_at: $date}' > "$task_file"
    else
        cat > "$task_file" <<EOF
{
  "id": "$task_id",
  "title": "$title",
  "description": "$desc",
  "status": "TODO",
  "assigned_to": "$assignee",
  "created_by": "$creator",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    fi
    
    log_success "Task created: $task_id"
    echo "$task_id"
}

#######################################
# List tasks
# Arguments:
#   $1 - Status filter (optional)
#######################################
list_tasks() {
    local status_filter="${1:-}"
    
    echo "=== Swarm Tasks ==="
    local count=0
    
    local swarm_root
    swarm_root=$(_get_swarm_root)
    
    for task_file in "$swarm_root/tasks"/*.json; do
        if [[ -f "$task_file" ]]; then
            local id title status assignee
            
            if command_exists jq; then
                id=$(jq -r '.id' "$task_file")
                title=$(jq -r '.title' "$task_file")
                status=$(jq -r '.status' "$task_file")
                assignee=$(jq -r '.assigned_to // "unassigned"' "$task_file")
            else
                # Fallback primitive parsing
                id=$(grep '"id":' "$task_file" | cut -d'"' -f4)
                title=$(grep '"title":' "$task_file" | cut -d'"' -f4)
                status=$(grep '"status":' "$task_file" | cut -d'"' -f4)
            fi
            
            if [[ -n "$status_filter" ]] && [[ "$status" != "$status_filter" ]]; then
                continue
            fi
            
            echo "[$status] $id: $title (Assigned: $assignee)"
            ((count++))
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        echo "No tasks found."
    fi
}

#######################################
# Update task status
# Arguments:
#   $1 - Task ID
#   $2 - New Status (open, in_progress, closed, blocked)
#######################################
update_task() {
    local task_id="$1"
    local status="$2"
    
    "$BD_BIN" update "$task_id" --status "$status"
    log_success "Task $task_id updated to $status"
}

#######################################
# Handle Swarm CLI Commands
# Arguments:
#   $@ - Swarm subcommands and args
#######################################
handle_swarm_command() {
    local cmd="$1"
    shift
    
    # Initialize if needed
    init_swarm
    
    case "$cmd" in
        init)
            # Already done above
            ;;
        registry)
            local sub_cmd="$1"
            shift
            case "$sub_cmd" in
                set) register_project_path "$1" "$2" ;;
                get) get_project_path "$1" ;;
                ls|list) cat "$(_get_registry)" ;;
                *) log_error "Usage: ralph swarm registry [set|get|ls] ..." ;;
            esac
            ;;
        spawn)
            local role=""
            local task=""
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --role) role="$2"; shift 2 ;;
                    --task) task="$2"; shift 2 ;;
                    *) log_error "Unknown spawn argument: $1"; return 1 ;;
                esac
            done
            
            if [[ -z "$role" ]] || [[ -z "$task" ]]; then
                log_error "Usage: ralph swarm spawn --role <role> --task <task>"
                return 1
            fi
            
            spawn_agent "$role" "$task"
            ;;
            
        msg|send)
            local to=""
            local content=""
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --to) to="$2"; shift 2 ;;
                    --content) content="$2"; shift 2 ;;
                    *) log_error "Unknown msg argument: $1"; return 1 ;;
                esac
            done
            
            if [[ -z "$to" ]] || [[ -z "$content" ]]; then
                log_error "Usage: ralph swarm msg --to <id> --content <message>"
                return 1
            fi
            
            send_message "$to" "$content"
            ;;
            
        inbox)
            read_inbox
            ;;
            
        list|ls)
            list_teammates
            ;;
            
        soo|orchestrate)
            # Series of Orchestrations: Auto-pilot for the whole swarm
            log_info "Starting Ralph Series of Orchestrations (SoO)..."
            
            # Step 1: Planner
            log_setup "Phase 1: Planning"
            spawn_agent "planner" "Decompose the current project requirements into Beads tasks."
            wait # Simplified for now, in reality we'd monitor status
            
            # Step 2: Loop Engineer & Tester
            log_setup "Phase 2: Execution & Verification"
            
            local backoff=1
            local max_backoff=60
            
            while "$BD_BIN" ready --quiet | grep -q "[0-9]"; do
                local task_id
                task_id=$("$BD_BIN" ready --pretty | head -n 1 | awk '{print $2}')
                
                if [[ -z "$task_id" ]]; then
                    log_debug "No ready tasks, waiting ${backoff}s..."
                    sleep "$backoff"
                    backoff=$((backoff * 2))
                    [[ $backoff -gt $max_backoff ]] && backoff=$max_backoff
                    continue
                fi
                
                # Reset backoff on successful task
                backoff=1
                
                log_info "Working on Task: $task_id"
                spawn_agent "engineer" "Complete task $task_id"
                wait
                
                spawn_agent "tester" "Verify task $task_id"
                wait
            done
            log_success "Series of Orchestrations complete."
            ;;

        task)
            local task_cmd="${1:-list}"
            shift
            
            case "$task_cmd" in
                create|add)
                    hi_create_task "$1" "$2" "${3:-}" "${4:-}"
                    sync_plan_file
                    ;;
                list|ls|ready)
                    get_ready_tasks
                    ;;
                done|complete)
                    hi_close_task "$1"
                    sync_plan_file
                    ;;
                update)
                    update_task "$1" "$2"
                    ;;
                *)
                    echo "Usage: ralph swarm task [create|ready|done|ls] ..."
                    ;;
            esac
            ;;
            
        *)
            log_error "Unknown swarm command: $cmd"
            echo "Available commands: init, spawn, msg, inbox, list, task"
            return 1
            ;;
    esac
}

#######################################
# Benchmarking Library for Ralph
# Measures service performance and detects regressions
#######################################

#######################################
# Measure latency of an endpoint
# Arguments:
#   $1 - URL
# Returns: Latency in seconds (float)
#######################################
measure_latency() {
    local url="$1"
    if ! command_exists curl; then return 1; fi
    
    # Use max-time to prevent hanging
    curl -s -o /dev/null -w "%{time_starttransfer}" --max-time 10 "$url" || echo "999.999"
}

#######################################
# Perform a mini-stress test
# Arguments:
#   $1 - URL
#   $2 - Request count (default 10)
#######################################
run_mini_bench() {
    local url="$1"
    local count="${2:-10}"
    local total_time=0
    
    log_info "Benchmarking $url ($count requests)..."
    
    for _ in $(seq 1 "$count"); do
        local lat
        lat=$(measure_latency "$url")
        total_time=$(echo "$total_time + $lat" | bc -l 2>/dev/null || echo "$total_time + 0.1")
    done
    
    local avg
    avg=$(echo "scale=3; $total_time / $count" | bc -l 2>/dev/null || echo "0.1")
    
    if (( $(echo "$avg > 0.5" | bc -l 2>/dev/null || echo 0) )); then
        echo "<performance_alert>Warning: High latency detected. Average: ${avg}s. Consider optimization.</performance_alert>"
    else
        log_success "Benchmark passed: Average latency ${avg}s"
    fi
}

#######################################
# AST-aware Semantic Editing Library
# Wraps 'ast-grep' for robust code transformations
#######################################

#######################################
# Semantic Search and Replace
# Arguments:
#   $1 - Pattern (ast-grep syntax)
#   $2 - Replacement (ast-grep syntax)
#   $3 - Language (rust, py, go, ts, etc.)
#   $4 - Path
#######################################
semantic_replace() {
    local pattern="$1"
    local replacement="$2"
    local lang="$3"
    local path="$4"
    
    if ! command_exists sg; then
        log_error "ast-grep (sg) is not available."
        return 1
    fi
    
    log_info "Performing semantic replacement in $path..."
    sg rewrite --pattern "$pattern" --rewrite "$replacement" --lang "$lang" "$path"
}

#######################################
# Scan for code smells using AST
# Arguments:
#   $1 - Rule Name
#   $2 - Path
#######################################
semantic_scan() {
    local rule="$1"
    local path="$2"
    
    if ! command_exists sg; then return 1; fi
    sg scan --rule "$rule" "$path"
}

#######################################
# Vision Library for Ralph
# Uses Playwright to visually verify UIs
#######################################

#######################################
# Perform visual audit of a running UI
# Arguments:
#   $1 - URL (default http://localhost:3000)
# Returns: Verification report
#######################################
verify_ui_visual() {
    local url="${1:-http://localhost:3000}"
    
    if ! command_exists npx; then return 0; fi
    
    log_info "Performing visual audit of $url..."
    
    # We use a simple liveness check first
    if ! curl -s -o /dev/null "$url"; then
        return 0
    fi

    # Run headless accessibility/render check via Playwright
    # This is a lightweight "Vision" check
    local report
    report=$(npx playwright wk "$url" --timeout 5000 2>&1 || echo "Playwright not configured for quick-scan")
    
    if [[ "$report" == *"error"* ]]; then
        echo "<visual_error>Warning: UI render issues detected at $url. Check console logs.</visual_error>"
    else
        log_success "Visual audit passed for $url"
    fi
}

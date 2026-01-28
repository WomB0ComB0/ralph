#!/bin/bash

#######################################
# Compute hash of project state
# Excludes heavy directories for performance
# Returns: MD5 hash string, or empty string on error
#######################################
compute_project_hash() {
    local project_dir="${PROJECT_DIR:-.}"
    
    # Validate project directory exists
    if [[ ! -d "$project_dir" ]]; then
        log_error "Project directory not found: $project_dir"
        return 1
    fi
    
    # Ensure MD5 command is available
    if ! detect_md5_command; then
        log_error "No MD5 command available on this system"
        return 1
    fi
    
    log_debug "Computing project hash for: $project_dir"
    
    # Directories to exclude (heavy or not relevant to project state)
    local exclude_dirs=(
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
    )
    
    local hash
    hash=$(
        find "$project_dir" -type d \( "${exclude_dirs[@]}" \) -prune -o -type f -print0 2>/dev/null | \
        sort -z | \
        xargs -0 "$MD5_COMMAND" 2>/dev/null | \
        "$MD5_COMMAND" 2>/dev/null | \
        awk '{print $1}'
    )
    
    if [[ -z "$hash" ]]; then
        log_warning "Failed to compute project hash"
        return 1
    fi
    
    log_debug "Project hash: $hash"
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
        "$LOG_FILE:ralph.log"
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
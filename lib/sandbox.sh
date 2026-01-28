#!/bin/bash

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
    
    cat > "$dockerfile_path" <<'EOF'
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

    if [[ $? -eq 0 ]]; then
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
    )
    
    # Add environment file if it exists (with security warning)
    if [[ -f "$project_dir/.env" ]]; then
        log_warning "Loading .env file into sandbox. Ensure it doesn't contain sensitive credentials."
        docker_args+=("--env-file" "$project_dir/.env")
    fi
    
    # Allow specific environment variables to pass through (whitelist approach)
    local safe_env_vars=("LOG_LEVEL" "VERBOSE" "DEBUG")
    for var in "${safe_env_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            docker_args+=("-e" "$var=${!var}")
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
        docker rmi "$image_name" >/dev/null 2>&1 && \
            log_success "Removed sandbox image" || \
            log_warning "Failed to remove sandbox image"
    fi
    
    local dockerfile_path="${PROJECT_DIR:-.}/Dockerfile.ralph"
    if [[ -f "$dockerfile_path" ]]; then
        log_debug "Dockerfile remains at: $dockerfile_path (not auto-removed)"
    fi
}
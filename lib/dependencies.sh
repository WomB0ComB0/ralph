#!/bin/bash

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
    local pkg_mgr
    
    pkg_mgr=$(get_package_manager)
    
    if [[ "$pkg_mgr" == "unknown" ]] || [[ "$pkg_mgr" == "none" ]]; then
        log_error "No package manager available to install $package"
        return 1
    fi
    
    log_setup "Installing $package using $pkg_mgr..."
    
    case "$pkg_mgr" in
        apt)
            if sudo apt-get update && sudo apt-get install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        dnf)
            if sudo dnf install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        yum)
            if sudo yum install -y "$package"; then
                log_success "Installed $package"
                return 0
            fi
            ;;
        pacman)
            if sudo pacman -S --noconfirm "$package"; then
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
    
    case "$OS_TYPE" in
        linux|macos)
            local install_script
            install_script=$(create_temp_file)
            
            if curl -fsSL https://raw.githubusercontent.com/stackblitz/opencode/main/install.sh -o "$install_script"; then
                if bash "$install_script"; then
                    log_success "opencode installed successfully"
                    return 0
                else
                    log_error "opencode installation script failed"
                    return 1
                fi
            else
                log_error "Failed to download opencode installer"
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
# Interactive dependency setup wizard
# Installs core dependencies and optional AI tools
#######################################
setup_dependencies() {
    log_setup "=================================="
    log_setup "Ralph Setup - Dependency Installer"
    log_setup "=================================="
    log_setup "OS: $OS_TYPE ($ARCH_TYPE)"
    log_setup ""
    
    # Detect and setup package manager
    local pkg_mgr
    pkg_mgr=$(get_package_manager)
    
    if [[ "$pkg_mgr" == "unknown" ]] || [[ "$pkg_mgr" == "none" ]]; then
        log_error "No package manager detected"
        log_info "Attempting to install one..."
        
        case "$OS_TYPE" in
            macos)
                install_package_manager "brew" || exit 1
                ;;
            windows)
                install_package_manager "scoop" || {
                    log_error "Failed to install package manager"
                    log_info "Please install Scoop or Chocolatey manually, then run setup again"
                    exit 1
                }
                ;;
            *)
                log_error "Please install a package manager manually for your Linux distribution"
                exit 1
                ;;
        esac
        
        # Re-detect package manager
        pkg_mgr=$(get_package_manager)
    fi
    
    log_success "Package manager detected: $pkg_mgr"
    log_setup ""
    
    # Install core dependencies
    log_setup "Installing core dependencies..."
    local core_failed=0
    
    install_git || ((core_failed++))
    install_jq || ((core_failed++))
    install_md5sum || log_warning "MD5 utilities installation failed (non-critical)"
    
    if [[ $core_failed -gt 0 ]]; then
        log_error "$core_failed core dependency installation(s) failed"
        log_warning "Some features may not work correctly"
    else
        log_success "All core dependencies installed successfully"
    fi
    
    log_setup ""
    log_setup "AI Tools Installation"
    log_setup "---------------------"
    
    # Interactive tool selection
    echo ""
    echo -e "${CYAN}Which AI tools would you like to install?${NC}"
    echo "  1) amp (Anthropic MCP) - Model Context Protocol CLI"
    echo "  2) claude-cli - Claude API command-line interface"
    echo "  3) opencode - Code editor integration"
    echo "  4) tiktoken - Accurate token counting (requires Python 3)"
    echo "  5) All of the above"
    echo "  6) Skip AI tools installation"
    echo ""
    
    local tool_choice
    read -rp "Enter your choice (1-6) [default: 6]: " tool_choice
    tool_choice=${tool_choice:-6}
    
    case "$tool_choice" in
        1)
            install_amp || log_warning "amp installation failed"
            ;;
        2)
            install_claude_cli || log_warning "claude-cli installation failed"
            ;;
        3)
            install_opencode || log_warning "opencode installation failed"
            ;;
        4)
            install_tiktoken || log_warning "tiktoken installation failed"
            ;;
        5)
            log_setup "Installing all AI tools..."
            install_amp || log_warning "amp installation failed"
            install_claude_cli || log_warning "claude-cli installation failed"
            install_opencode || log_warning "opencode installation failed"
            install_tiktoken || log_warning "tiktoken installation failed"
            ;;
        6)
            log_info "Skipping AI tools installation"
            ;;
        *)
            log_warning "Invalid choice. Skipping AI tools installation"
            ;;
    esac
    
    # Final summary
    log_setup ""
    log_success "=================================="
    log_success "Setup Complete!"
    log_success "=================================="
    
    echo ""
    log_info "Installed components:"
    command_exists git && echo "  ✓ Git"
    command_exists jq && echo "  ✓ jq"
    command_exists node && echo "  ✓ Node.js"
    command_exists amp && echo "  ✓ amp"
    command_exists claude && echo "  ✓ claude-cli"
    command_exists opencode && echo "  ✓ opencode"
    if command_exists python3 && python3 -c "import tiktoken" 2>/dev/null; then
        echo "  ✓ tiktoken"
    fi
    
    echo ""
    log_info "You can now run Ralph with: ./ralph.sh"
    
    # Check if shell restart is needed
    if [[ "$pkg_mgr" == "brew" ]] && ! command_exists brew >/dev/null 2>&1; then
        log_warning "Please restart your terminal for Homebrew to be available in PATH"
    fi
}
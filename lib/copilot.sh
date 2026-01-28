#!/bin/bash

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
    # We capture stdout and stderr to checking for errors
    if output=$(copilot -p "$full_prompt" $base_args -s "$@" 2>&1); then
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
        if output=$(copilot -p "$full_prompt" $base_args -s "$@" --model gpt-4.1 2>&1); then
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

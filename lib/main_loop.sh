#!/bin/bash

#######################################
# Print styled iteration header
# Arguments:
#   $1 - Current iteration
#   $2 - Max iterations
#   $3 - Tool name
#   $4 - Model name
#######################################
print_header() {
    local iteration=$1
    local max=$2
    local tool=$3
    local model=$4
    
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${YELLOW}RALPH AGENT${NC} | Iteration: ${CYAN}${iteration}/${max}${NC} | Tool: ${MAGENTA}${tool}${NC}"
    echo -e "${BLUE}║${NC} Model: ${GREEN}${model}${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

#######################################
# Generate comprehensive system prompt
# Arguments:
#   $1  - User prompt content
#   $2  - Execution plan context
#   $3  - PRD context
#   $4  - Architecture diagram context
#   $5  - Git diff exclusion args
#   $6  - Reflection instruction
#   $7  - Recent changes
#   $8  - Resource context
#   $9  - User provided context
# Returns: Complete system prompt
#######################################
generate_system_prompt() {
    local prompt_content="$1"
    local plan_context="$2"
    local prd_context="$3"
    local diagram_context="$4"
    local gitdiff_exclude_args="$5"
    local reflection_instruction="$6"
    local recent_changes="$7"
    local resource_context="$8"
    local user_provided_context="$9"

    cat <<EOF
<system_prompt>
<role>
You are Ralph, an autonomous AI Engineer with expertise in full-stack development.
You utilize **Structured Grounding**: PRDs for intent, Diagrams for architecture, and Plans for execution.
</role>

<capabilities>
1. **Full-Stack Engineering:** Expert in modern software delivery and best practices.
2. **Architectural Visualization:** Use Mermaid syntax in '$DIAGRAM_FILE' to model system state, data flow, and dependencies.
3. **Requirement Engineering:** Maintain '$PRD_FILE' (JSON) to define goals, user stories, and success metrics.
4. **Stateful Planning:** Maintain '$PLAN_FILE' (Markdown) to track iterative progress with checkboxes.
5. **Swarm Orchestration:** You can act as a Team Leader or Specialist.
   - Spawn sub-agents: \`ralph swarm spawn --role "RoleName" --task "Task description"\`
   - Send messages: \`ralph swarm msg --to <agent_id> --content "Message"\`
   - Check inbox: \`ralph swarm inbox\`
   - List team: \`ralph swarm list\`
   - **Protocol:** ALWAYS check your inbox at the start of an iteration. Delegate complex sub-tasks to sub-agents.
6. **GitHub Copilot Integration:**
   - Execute agentic task: \`ralph copilot run "find and delete all temp files"\`
   - Ask for explanation: \`ralph copilot explain "how does git rebase work"\`
</capabilities>

<workflow>
1. **Initialize (Phase 0):** If missing, create '$PRD_FILE', '$DIAGRAM_FILE', and '$PLAN_FILE'.
2. **Align:** Ensure code changes align with Architecture ('$DIAGRAM_FILE') and Requirements ('$PRD_FILE').
3. **Execute:** Perform the next step in '$PLAN_FILE'. Mark completed tasks with [x].
4. **Update:** Reflect changes back into documentation files as the system evolves.
5. **Validate:** Ensure all artifacts remain valid (JSON syntax, Mermaid syntax, checkbox format).
</workflow>

<constraints>
- **Diagram First:** For any new feature, update the diagram BEFORE writing code.
- **Maintain Sync:** If you refactor code, update its representation in '$DIAGRAM_FILE'.
- **Valid JSON:** Ensure '$PRD_FILE' remains valid JSON at all times.
- **Progress Tracking:** Always mark completed tasks with [x] in '$PLAN_FILE'.
- **Termination:** Output <promise>COMPLETE</promise> only when documentation and code are in sync and all tasks are done.
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

<system_resources>
$resource_context
</system_resources>

<user_provided_context>
$user_provided_context
</user_provided_context>

$reflection_instruction

<instructions>
1. Review the <global_context> to understand current state
2. Identify the next uncompleted task from the execution plan
3. Ensure alignment with PRD goals and architecture diagrams
4. Execute the next logical step
5. Update all relevant artifacts to reflect changes
6. Mark completed tasks with [x] in the plan
</instructions>
</system_prompt>
EOF
}

#######################################
# Run AI tool with visual feedback
# Arguments:
#   $1 - Tool name (amp, claude, opencode)
#   $2 - Model name
#   $3 - Prompt text
#   $4 - Log file path
#   $5 - Output file path
# Returns: Exit code from tool
#######################################
run_ai_tool() {
    local tool="$1"
    local model="$2"
    local prompt="$3"
    local log_file="$4"
    local output_file="$5"
    
    log_info "Running ${MAGENTA}${tool}${NC} with model: ${GREEN}${model}${NC}"
    log_debug "Prompt length: $(echo "$prompt" | wc -c) characters"
    
    local pid spin i exit_code
    
    # Start tool in background with proper error handling
    case "$tool" in
        amp)
            (echo "$prompt" | amp --dangerously-allow-all 2>&1 | tee -a "$log_file" > "$output_file") &
            pid=$!
            ;;
        claude)
            export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-ollama}"
            export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://localhost:11434}"
            (claude --dangerously-skip-permissions --permission-mode bypassPermissions --model "$model" "$prompt" 2>&1 | tee -a "$log_file" > "$output_file") &
            pid=$!
            ;;
        opencode)
            (opencode run --model "$model" "$prompt" 2>&1 | tee -a "$log_file" > "$output_file") &
            pid=$!
            ;;
        *)
            log_error "Unknown tool: $tool"
            return 1
            ;;
    esac
    
    # Animated spinner while tool runs
    spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r%b[%s]%b Processing..." "${BLUE}" "${spin:$i:1}" "${NC}"
        sleep 0.1
    done
    
    # Get exit code
    wait $pid
    exit_code=$?
    
    # Clear spinner line
    printf "\r\033[K"
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "AI response received successfully"
    else
        log_error "AI tool failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

#######################################
# Load context with active windowing
# Limits context size while preserving important information
# Returns: Windowed context string
#######################################
load_plan_context() {
    local plan_file="${PLAN_FILE:-ralph_plan.md}"
    
    if [[ ! -f "$plan_file" ]]; then
        echo "No plan file found."
        return
    fi
    
    # Extract Header + Last 3 Done + First 10 Todo
    local plan_header plan_done plan_todo
    plan_header=$(head -n 5 "$plan_file")
    plan_done=$(grep -F "[x]" "$plan_file" 2>/dev/null | tail -n 3)
    plan_todo=$(grep -F "[ ]" "$plan_file" 2>/dev/null | head -n 10)
    
    cat <<EOF
$plan_header

... (context window: showing recent progress and upcoming tasks) ...

Recent Completed:
$plan_done

Next Tasks:
$plan_todo
EOF
}

#######################################
# Detect and handle agent stalling
# Arguments:
#   $1 - Current lazy streak count
# Returns: Reflection instruction if stalling detected
#######################################
generate_stalling_instruction() {
    local lazy_streak=$1
    
    if [[ $lazy_streak -ge 2 ]]; then
        cat <<EOF
<reflexion_trigger>
CRITICAL WARNING: No progress detected for $lazy_streak consecutive iterations.

REQUIRED ACTIONS:
1. ANALYZE: Review '$PRD_FILE' - are requirements clear and achievable?
2. VISUALIZE: Update '$DIAGRAM_FILE' to identify bottlenecks or missing components
3. PIVOT: Update '$PLAN_FILE' with a new approach or break down tasks into smaller steps
4. DOCUMENT: Add comments explaining what's blocking progress

If stuck on a specific technical issue, consider:
- Breaking the problem into smaller, testable units
- Adding debug logging or print statements
- Simplifying the approach
- Consulting documentation or examples
</reflexion_trigger>
EOF
    fi
}

#######################################
# Detect and handle infinite loops
# Arguments:
#   $1 - Previous log hash
#   $2 - Current log hash
# Returns: Reflection instruction if loop detected
#######################################
generate_loop_instruction() {
    local prev_hash="$1"
    local curr_hash="$2"
    
    if [[ -n "$prev_hash" ]] && [[ "$prev_hash" == "$curr_hash" ]]; then
        cat <<EOF
<reflexion_trigger>
CRITICAL WARNING: Infinite loop detected - agent is repeating the same actions.

REQUIRED ACTIONS:
1. STOP: Mark the current approach as FAILED in '$PLAN_FILE'
2. ANALYZE: Document why the current approach isn't working
3. REDESIGN: Propose an alternative architecture in '$DIAGRAM_FILE'
4. REPLICATE: Try to understand and document the exact failure mode
5. PIVOT: Choose a completely different implementation strategy

Common causes of loops:
- Syntax errors not being detected
- Missing dependencies or tools
- Incorrect assumptions about system state
- Attempting operations without proper permissions
</reflexion_trigger>
EOF
    fi
}

#######################################
# Execute single iteration
# Arguments:
#   $1 - Current iteration number
# Returns: 0 if complete, 1 to continue
#######################################
execute_iteration() {
    local iteration=$1
    local temp_output gitdiff_exclude_args
    local plan_context prd_context diagram_context
    local reflection_instruction=""
    local recent_changes=""
    local resource_context=""
    local user_provided_context=""
    local prompt_content structured_prompt output
    
    # Display iteration header
    print_header "$iteration" "$MAX_ITERATIONS" "$TOOL" "$SELECTED_MODEL"
    
    # Create temporary output file
    temp_output=$(create_temp_file) || {
        log_error "Failed to create temporary file"
        return 1
    }
    
    # Build git diff exclusions
    mapfile -t gitdiff_exclude_args < <(build_gitdiff_exclude_args)
    
    # Capture recent changes if requested
    if [[ "${DIFF_CONTEXT_FLAG:-false}" == "true" ]]; then
        if command_exists git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
                recent_changes=$(git diff HEAD~1..HEAD -- . "${gitdiff_exclude_args[@]}" 2>/dev/null || echo "No diff available")
            else
                recent_changes="No previous commit to diff against (initial commit)."
            fi
        else
            recent_changes="Not in a Git repository."
        fi
    fi
    
    # Capture project state before execution
    local project_hash_before
    project_hash_before=$(compute_project_hash)
    log_debug "Project hash before: $project_hash_before"
    
    # Generate current log signature for loop detection
    local current_log_signature
    current_log_signature=$(tail -n 50 "${LOG_FILE:-/dev/null}" 2>/dev/null | md5sum_wrapper | awk '{print $1}' || echo "none")
    log_debug "Log signature: $current_log_signature"
    
    # Read user's task prompt
    if [[ -f "$PROJECT_DIR/CLAUDE.md" ]]; then
        prompt_content=$(cat "$PROJECT_DIR/CLAUDE.md")
    elif [[ -f "$PROJECT_DIR/prompt.md" ]]; then
        prompt_content=$(cat "$PROJECT_DIR/prompt.md")
    else
        log_error "No prompt file found (CLAUDE.md or prompt.md)"
        return 1
    fi
    
    # Load context with active windowing
    plan_context=$(load_plan_context)
    
    if [[ -f "$PRD_FILE" ]]; then
        prd_context=$(cat "$PRD_FILE")
    else
        prd_context="No PRD found. Create one if the task is complex enough to warrant structured requirements."
    fi
    
    if [[ -f "$DIAGRAM_FILE" ]]; then
        diagram_context=$(cat "$DIAGRAM_FILE")
    else
        diagram_context="No architecture diagrams found. Create one for complex systems or multi-component features."
    fi
    
    # Load system resources and user context
    resource_context=$(get_resource_usage)
    user_provided_context=$(read_context_files)
    
    # Generate reflection instructions based on agent state
    if [[ -n "${NEXT_INSTRUCTION:-}" ]]; then
        # Priority: Use explicit instruction from previous iteration
        reflection_instruction="$NEXT_INSTRUCTION"
        export NEXT_INSTRUCTION=""
    elif [[ "${LAZY_STREAK:-0}" -ge 2 ]]; then
        # Detect stalling
        reflection_instruction=$(generate_stalling_instruction "$LAZY_STREAK")
    elif [[ -n "${PREVIOUS_LOG_HASH:-}" ]] && [[ "$current_log_signature" == "$PREVIOUS_LOG_HASH" ]]; then
        # Detect infinite loop
        reflection_instruction=$(generate_loop_instruction "$PREVIOUS_LOG_HASH" "$current_log_signature")
    fi
    
    # Generate complete system prompt
    structured_prompt=$(generate_system_prompt \
        "$prompt_content" \
        "$plan_context" \
        "$prd_context" \
        "$diagram_context" \
        "$(printf '%s\n' "${gitdiff_exclude_args[@]}")" \
        "$reflection_instruction" \
        "$recent_changes" \
        "$resource_context" \
        "$user_provided_context")
    
    # Estimate token count
    local est_tokens
    est_tokens=$(estimate_tokens "$structured_prompt")
    log_debug "Estimated prompt tokens: $est_tokens"
    
    # Execute AI tool
    if ! run_ai_tool "$TOOL" "$SELECTED_MODEL" "$structured_prompt" "$LOG_FILE" "$temp_output"; then
        log_error "AI tool execution failed"
        return 1
    fi
    
    # Read output
    output=$(cat "$temp_output" 2>/dev/null || echo "")
    
    if [[ -z "$output" ]]; then
        log_warning "AI tool produced no output"
    fi
    
    # Validate artifacts and queue corrections for next iteration
    local artifact_errors
    artifact_errors=$(validate_artifacts)
    if [[ -n "$artifact_errors" ]]; then
        export NEXT_INSTRUCTION="$artifact_errors"
        log_warning "Artifact validation errors detected, will correct in next iteration"
    fi
    
    # Analyze project changes
    local project_hash_after
    project_hash_after=$(compute_project_hash)
    log_debug "Project hash after: $project_hash_after"
    
    if [[ "$project_hash_before" == "$project_hash_after" ]]; then
        LAZY_STREAK=$(( ${LAZY_STREAK:-0} + 1 ))
        log_warning "No files modified this iteration (streak: $LAZY_STREAK)"
    else
        log_success "Files modified - agent is making progress"
        LAZY_STREAK=0
    fi
    
    # Log metrics
    log_metrics "$(date +%Y-%m-%dT%H:%M:%S) | Iter: $iteration | Lazy: $LAZY_STREAK | Hash: $project_hash_after | Tokens: $est_tokens"
    
    # Save checkpoint
    save_checkpoint "$iteration"
    
    # Update loop detection state
    PREVIOUS_LOG_HASH="$current_log_signature"
    
    # Check for completion signal
    if echo "$output" | grep -qF "<promise>COMPLETE</promise>"; then
        log_success "Agent signaled completion"
        return 0
    fi
    
    return 1
}

#######################################
# Main execution entry point
#######################################
main() {
    # Check for swarm command
    if [[ "${1:-}" == "swarm" ]]; then
        shift
        # shellcheck source=./lib/swarm.sh
        # (Already sourced in ralph.sh)
        handle_swarm_command "$@"
        exit $?
    fi

    # Check for copilot command
    if [[ "${1:-}" == "copilot" ]]; then
        shift
        handle_copilot_command "$@"
        exit $?
    fi

    # Load configuration (file, then CLI args)
    load_config || {
        log_error "Failed to load configuration"
        exit 1
    }
    
    parse_arguments "$@"
    
    # Handle setup mode
    if [[ "${SETUP_MODE:-false}" == "true" ]]; then
        setup_dependencies
        exit $?
    fi

    # Handle test mode
    if [[ "${TEST_MODE:-false}" == "true" ]]; then
        run_internal_tests
        exit $?
    fi
    
    # Validate configuration
    validate_config || exit 1
    
    # Handle sandbox mode
    if [[ "${SANDBOX_MODE:-false}" == "true" ]]; then
        setup_sandbox || exit 1
        run_in_sandbox "$@"
        # run_in_sandbox exits, so we won't reach here
    fi
    
    # Display startup information
    log_info "Starting Ralph AI Agent"
    log_info "OS: $OS_TYPE ($ARCH_TYPE)"
    log_info "Tool: $TOOL | Max Iterations: $MAX_ITERATIONS"
    
    # Setup execution environment
    archive_previous_run
    track_current_branch
    
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        initialize_progress_file
    fi
    
    # Determine model to use
    determine_model || {
        log_error "Failed to determine model"
        exit 1
    }
    
    # Initialize state variables
    export LAZY_STREAK=0
    export PREVIOUS_LOG_HASH=""
    export NEXT_INSTRUCTION=""
    
    # Determine starting iteration
    local start_iter=1
    
    if [[ "${RESUME_FLAG:-false}" == "true" ]]; then
        local last_checkpoint
        last_checkpoint=$(get_checkpoint)
        
        if [[ "$last_checkpoint" =~ ^[0-9]+$ ]] && [[ $last_checkpoint -gt 0 ]]; then
            log_info "Resuming from checkpoint: Iteration $last_checkpoint"
            start_iter=$((last_checkpoint + 1))
        else
            log_warning "No valid checkpoint found, starting from beginning"
        fi
    fi
    
    # Main iteration loop
    for i in $(seq "$start_iter" "$MAX_ITERATIONS"); do
        
        # Interactive mode: pause for user input
        if [[ "${INTERACTIVE_MODE:-false}" == "true" ]]; then
            echo ""
            echo -e "${YELLOW}>>> Interactive Mode: Paused <<<${NC}"
            echo -e "Press ${GREEN}[Enter]${NC} to continue, or type an instruction for Ralph:"
            
            local user_input
            read -r user_input
            
            if [[ -n "$user_input" ]]; then
                export NEXT_INSTRUCTION="<user_steering>$user_input</user_steering>"
                log_info "User instruction queued for next iteration"
            fi
        fi
        
        # Execute iteration
        if execute_iteration "$i"; then
            echo ""
            log_success "╔══════════════════════════════════════╗"
            log_success "║   Ralph completed all tasks! 🎉     ║"
            log_success "╚══════════════════════════════════════╝"
            log_success "Completed at iteration $i of $MAX_ITERATIONS"
            exit 0
        fi
        
        log_info "Iteration $i complete. Continuing..."
        sleep 2
    done
    
    # Max iterations reached
    echo ""
    log_warning "╔════════════════════════════════════════════╗"
    log_warning "║   Max iterations reached without          ║"
    log_warning "║   completion signal                       ║"
    log_warning "╚════════════════════════════════════════════╝"
    log_warning "Completed $MAX_ITERATIONS iterations"
    log_info "Review '$PLAN_FILE' for remaining tasks"
    log_info "Use --resume to continue from checkpoint"
    
    exit 1
}
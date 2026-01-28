#!/bin/bash

#######################################
# Swarm Orchestration Library for Ralph
# Implements multi-agent coordination via file-based signaling
#######################################

PROJECT_DIR="${PROJECT_DIR:-.}"

# Swarm Directory Structure
# .ralph/swarm/
#   ├── config.json       # Swarm configuration
#   ├── agents/           # Active agents registry
#   │   └── <agent_id>/
#   │       ├── profile.json  # Agent role/config
#   │       ├── status        # Current status (IDLE, BUSY, OFF)
#   │       └── inbox/        # Incoming messages
#   └── tasks/            # Shared task board
#       └── <task_id>.json

SWARM_ROOT="${PROJECT_DIR}/.ralph/swarm"

#######################################
# Initialize Swarm Infrastructure
# Creates necessary directories
#######################################
init_swarm() {
    if [[ ! -d "$SWARM_ROOT" ]]; then
        log_setup "Initializing Swarm Orchestration..."
        mkdir -p "$SWARM_ROOT"/{agents,tasks}
        
        # Create config
        cat > "$SWARM_ROOT/config.json" <<EOF
{
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "backend": "process"
}
EOF
        log_success "Swarm initialized at $SWARM_ROOT"
    fi
    
    # Register self if not already registered
    local my_id="${RALPH_AGENT_ID:-leader}"
    register_agent "$my_id" "leader" "Orchestration Lead"
}

#######################################
# Register an agent in the swarm
# Arguments:
#   $1 - Agent ID
#   $2 - Role
#   $3 - Description
#######################################
register_agent() {
    local id="$1"
    local role="$2"
    local desc="$3"
    local agent_dir="$SWARM_ROOT/agents/$id"
    
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
        # Update PID if re-registering
        local tmp=$(mktemp)
        jq --arg pid "$$" '.pid = ($pid|tonumber)' "$agent_dir/profile.json" > "$tmp" && mv "$tmp" "$agent_dir/profile.json"
    fi
}

#######################################
# Spawn a sub-agent
# Arguments:
#   $1 - Role (e.g., "researcher", "reviewer")
#   $2 - Task Description
# Returns: Agent ID of spawned agent
#######################################
spawn_agent() {
    local role="$1"
    local task="$2"
    local parent_id="${RALPH_AGENT_ID:-leader}"
    
    # Generate unique ID
    local short_role="${role//[^a-zA-Z0-9]/}"
    local timestamp=$(date +%s)
    local agent_id="${short_role}_${timestamp: -4}"
    
    log_info "Spawning agent: $agent_id ($role)"
    
    # Register the agent first
    register_agent "$agent_id" "$role" "Sub-agent spawned by $parent_id"
    echo "RUNNING" > "$SWARM_ROOT/agents/$agent_id/status"
    
    # Create a prompt file for the new agent
    local agent_work_dir="$PROJECT_DIR/.ralph/workspaces/$agent_id"
    mkdir -p "$agent_work_dir"
    
    # Create initial context/prompt for the agent
    cat > "$agent_work_dir/CLAUDE.md" <<EOF
# Role: $role
You are a specialized sub-agent in a Ralph Swarm.
Parent Agent: $parent_id
Your ID: $agent_id

## Task
$task

## Swarm Protocols
- Communicate results via 'ralph swarm msg --to $parent_id --content "..."'
- Check your inbox via 'ralph swarm inbox'
- When finished, send a completion message and exit.
EOF
    
    # Launch ralph in background
    # We use nohup to detach, and redirect logs
    local log_file="$agent_work_dir/ralph.log"
    
    # Construct command to run ralph recursively
    # We need to export RALPH_AGENT_ID so it knows who it is
    export RALPH_AGENT_ID="$agent_id"
    
    # Use the same ralph executable
    local ralph_exec="$0"
    if [[ ! -x "$ralph_exec" ]]; then
        ralph_exec="ralph" # Fallback to PATH
    fi
    
    # Run in background
    (
        cd "$PROJECT_DIR" || exit
        export RALPH_AGENT_ID="$agent_id"
        # We limit iterations for sub-agents to prevent runaways
        "$ralph_exec" --max-iterations 10 --tool "${TOOL:-opencode}" --model "${SELECTED_MODEL:-google/gemini-2.0-flash-exp}" --no-archive --context "$agent_work_dir/CLAUDE.md" > "$log_file" 2>&1
        
        # Cleanup status on exit
        echo "OFF" > "$SWARM_ROOT/agents/$agent_id/status"
    ) &
    
    log_success "Spawned agent $agent_id (PID: $!)"
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
    
    local target_inbox="$SWARM_ROOT/agents/$to_id/inbox"
    
    if [[ ! -d "$target_inbox" ]]; then
        log_error "Target agent not found: $to_id"
        return 1
    fi
    
    local timestamp=$(date +%s)
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
    local inbox_dir="$SWARM_ROOT/agents/$my_id/inbox"
    
    if [[ ! -d "$inbox_dir" ]]; then
        echo "Inbox not initialized."
        return 1
    fi
    
    local count=$(ls -1 "$inbox_dir" 2>/dev/null | wc -l)
    
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
    
    for agent_dir in "$SWARM_ROOT/agents"/*; do
        if [[ -d "$agent_dir" ]]; then
            local id=$(basename "$agent_dir")
            local status=$(cat "$agent_dir/status" 2>/dev/null || echo "UNKNOWN")
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
    local title="$1"
    local desc="$2"
    local assignee="${3:-null}"
    local creator="${RALPH_AGENT_ID:-leader}"
    
    local task_id="task_$(date +%s)_$RANDOM"
    local task_file="$SWARM_ROOT/tasks/$task_id.json"
    
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
    
    for task_file in "$SWARM_ROOT/tasks"/*.json; do
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
#   $2 - New Status (TODO, IN_PROGRESS, DONE, BLOCKED)
#######################################
update_task() {
    local task_id="$1"
    local status="$2"
    local task_file="$SWARM_ROOT/tasks/$task_id.json"
    
    if [[ ! -f "$task_file" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi
    
    local tmp=$(mktemp)
    if command_exists jq; then
        jq --arg status "$status" '.status = $status' "$task_file" > "$tmp" && mv "$tmp" "$task_file"
    else
        sed -i "s/\"status\": \".*\"/\"status\": \"$status\"/" "$task_file"
    fi
    
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
            
        task)
            local task_cmd="${1:-list}"
            shift
            
            case "$task_cmd" in
                create|add)
                    create_task "$1" "$2" "${3:-}"
                    ;;
                list|ls)
                    list_tasks "${1:-}"
                    ;;
                update)
                    update_task "$1" "$2"
                    ;;
                *)
                    echo "Usage: ralph swarm task [create|list|update] ..."
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

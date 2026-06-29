#!/bin/bash
# shellcheck disable=SC2154
set -euo pipefail
IFS=$'\n\t'

#######################################
# Estimate token count for text content
# Uses multiple heuristics for better accuracy
# Arguments:
#   $1 - Content to estimate
#   $2 - (Optional) Estimation method: "simple", "advanced", or "tiktoken"
# Returns: Estimated token count
#######################################
estimate_tokens() {
    local content="$1"
    local method="${2:-advanced}"
    
    case "$method" in
        simple)
            # Simple heuristic: characters / 4
            local char_count=${#content}
            echo $((char_count / 4))
            ;;
            
        advanced)
            # More accurate multi-factor estimation
            local char_count word_count line_count code_count
            
            char_count=${#content}
            word_count=$(echo "$content" | wc -w | xargs)
            line_count=$(echo "$content" | wc -l | xargs)
            
            # Detect code content (has common programming patterns)
            # IMPROVEMENT: Consider using a more comprehensive regex or a dedicated tool like 'cloc' for better language-agnostic code detection
            code_count=$(echo "$content" | grep -cE '^\s*(function|def|class|import|const|let|var|if|for|while|\{|\}|;)' || true)
            
            # Constants for estimation
            local TOKEN_CHARS_PER_TOKEN=4
            local CODE_DENSITY_THRESHOLD=4  # 1/4 of lines
            
            # Adjust estimation based on content type
            if [[ "$code_count" -gt $((line_count / CODE_DENSITY_THRESHOLD)) ]]; then
                # Code-heavy content: chars/3.5 (code is more token-dense)
                echo $(( (char_count * 10) / 35 ))
            else
                # Natural language: weighted average of char/4 and word*1.3
                echo $(( (char_count / TOKEN_CHARS_PER_TOKEN + word_count * 13 / 10) / 2 ))
            fi
            ;;
            
        tiktoken)
            # Use tiktoken if available (Python required)
            if command_exists python3 && python3 -c "import tiktoken" 2>/dev/null; then
                export TOKEN_CONTENT="$content"
                python3 <<EOF
import tiktoken
import sys
import os

content = os.environ.get('TOKEN_CONTENT', '')
model = os.environ.get('SELECTED_MODEL', 'gpt-4')

try:
    # Try to get encoding for the specific model
    try:
        encoding = tiktoken.encoding_for_model(model)
    except:
        # Fallback to cl100k_base (used by GPT-4 and many modern models)
        encoding = tiktoken.get_encoding("cl100k_base")
    
    tokens = encoding.encode(content)
    print(len(tokens))
except Exception as e:
    # Final fallback if anything goes wrong
    print(len(content) // 4)
EOF
            else
                log_debug "tiktoken not available, falling back to advanced estimation"
                estimate_tokens "$content" "advanced"
            fi
            ;;
            
        *)
            log_warning "Unknown token estimation method: $method, using advanced"
            estimate_tokens "$content" "advanced"
            ;;
    esac
}

#######################################
# Get latest high-performance model from opencode
# Prioritizes: Gemini/GLM/Claude with flash/pro > Other preferred > Qwen > Any
# Returns: Model identifier
#######################################
get_latest_opencode_model() {
    local all_models
    
    local cache_file="${HOME}/.cache/ralph/models_cache"
    local cache_ttl=3600  # 1 hour
    
    # Check cache validity
    if [[ -f "$cache_file" ]] && 
       [[ $(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file"))) -lt $cache_ttl ]]; then
        cat "$cache_file"
        return 0
    fi
    
    # Get available models
    if ! all_models=$(opencode models 2>/dev/null); then
        # Fallback to cached even if stale
        if [[ -f "$cache_file" ]]; then
            log_warning "Failed to refresh models, using stale cache"
            cat "$cache_file"
            return 0
        fi
        
        log_warning "Failed to get opencode models list"
        echo "google/gemini-2.0-flash-exp"
        return 1
    fi
    
    if [[ -z "$all_models" ]]; then
        log_warning "No models available from opencode"
        echo "google/gemini-2.0-flash-001"
        return 1
    fi
    
    log_debug "Available models from opencode:"
    log_debug "$all_models"
    
    # Filter out non-text models
    local text_models
    text_models=$(echo "$all_models" | grep -vE "audio|tts|embedding|image|vision|whisper|dall-e|live" || echo "")
    
    # Priority 1: Preferred families (Gemini, GLM, Claude) with flash/pro capabilities
    local high_perf_preferred
    high_perf_preferred=$(echo "$text_models" | grep -iE "${RALPH_MODEL_FAMILIES:-gemini|glm|claude}" | grep -iE "flash|pro|thinking|exp" | sort -V -r | head -n 1)
    
    if [[ -n "$high_perf_preferred" ]]; then
        log_debug "Selected high-performance preferred model: $high_perf_preferred"
        echo "$high_perf_preferred" | tee "$cache_file"
        return 0
    fi
    
    # Priority 2: Any preferred family model (even non-flash/pro)
    local any_preferred
    any_preferred=$(echo "$text_models" | grep -iE "${RALPH_MODEL_FAMILIES:-gemini|glm|claude}" | sort -V -r | head -n 1)
    
    if [[ -n "$any_preferred" ]]; then
        log_debug "Selected preferred family model: $any_preferred"
        echo "$any_preferred" | tee "$cache_file"
        return 0
    fi
    
    # Priority 3: Qwen models (good code performance)
    local qwen_model
    qwen_model=$(echo "$text_models" | grep -iE "qwen" | grep -iE "coder|2\.5" | sort -V -r | head -n 1)
    
    if [[ -n "$qwen_model" ]]; then
        log_debug "Selected Qwen model: $qwen_model"
        echo "$qwen_model" | tee "$cache_file"
        return 0
    fi
    
    # Priority 4: Any Qwen model
    qwen_model=$(echo "$text_models" | grep -iE "qwen" | sort -V -r | head -n 1)
    
    if [[ -n "$qwen_model" ]]; then
        log_debug "Selected fallback Qwen model: $qwen_model"
        echo "$qwen_model" | tee "$cache_file"
        return 0
    fi
    
    # Priority 5: Other capable models (DeepSeek, Mistral, etc.)
    local other_capable
    other_capable=$(echo "$text_models" | grep -iE "deepseek|mistral|llama-3|codestral" | sort -V -r | head -n 1)
    
    if [[ -n "$other_capable" ]]; then
        log_debug "Selected capable alternative model: $other_capable"
        echo "$other_capable" | tee "$cache_file"
        return 0
    fi
    
    # Priority 6: First available text model
    local first_model
    first_model=$(echo "$text_models" | head -n 1)
    
    if [[ -n "$first_model" ]]; then
        log_warning "Using first available model: $first_model"
        echo "$first_model" | tee "$cache_file"
        return 0
    fi
    
    # Final fallback - default to known working model
    log_error "No suitable models found, using hardcoded fallback"
    echo "google/gemini-2.0-flash-001"
    return 1
}

#######################################
# Get default model for specific tool
# Arguments:
#   $1 - Tool name (amp, claude, opencode)
# Returns: Default model identifier
#######################################
get_default_model_for_tool() {
    local tool="$1"
    
    case "$tool" in
        amp|claude)
            echo "sonnet"   # tier alias resolves to the latest server-side (not a pinned date)
            ;;
        opencode)
            echo "google/gemini-2.0-flash-001"   # last-resort only; real path is the live opencode-models router
            ;;
        agy)
            echo ""   # Antigravity self-selects the latest; resolve_model_for_tool live-lists via `agy models`
            ;;
        *)
            log_warning "Unknown tool: $tool, using generic default"
            echo "sonnet"
            ;;
    esac
}

#######################################
# Ensure the dynamic model router script exists
# Returns: Path to the router script
#######################################
ensure_model_router() {
    local cache_dir="${HOME}/.cache/ralph"
    local router_path="${cache_dir}/.model_router.py"
    
    mkdir -p "$cache_dir"
    
    # Embedded router script content
    local router_content
    read -r -d '' router_content <<'EOF'
import json, subprocess, sys, os, time, re
from typing import List, Dict

# Version: 1.1
CACHE_FILE = os.path.expanduser("~/.cache/ralph/model_segments.json")
CACHE_TTL = 86400

def extract_version(name: str) -> float:
    match = re.findall(r"(\d+\.?\d*)", name)
    if match:
        try:
            val = match[0]
            if len(match) > 1 and "." not in val: val = f"{match[0]}.{match[1]}"
            return float(val)
        except: return 0.0
    return 0.0

def get_available_models() -> List[str]:
    try:
        result = subprocess.run(["opencode", "models"], capture_output=True, text=True, check=True)
        return [line.strip() for line in result.stdout.splitlines() if "/" in line]
    except: return []

def _filter_models(models: List[str], includes: List[str], excludes: List[str] = []) -> List[str]:
    filtered = [m for m in models if any(k in m.lower() for k in includes) and not any(x in m.lower() for x in excludes)]
    return sorted(filtered, key=extract_version, reverse=True)

def discover_and_segment():
    available = get_available_models()
    if not available: return {}
    segments = {"PLANNER": [], "ENGINEER": [], "TESTER": [], "THINKER": []}
    gemini = [m for m in available if "google/gemini" in m.lower()]
    others = [m for m in available if "google/gemini" not in m.lower()]
    segments["PLANNER"] = _filter_models(gemini, ["pro", "thinking"])
    segments["ENGINEER"] = _filter_models(gemini, ["flash"], ["pro"])
    segments["TESTER"] = _filter_models(gemini, ["lite", "flash"])
    for role in segments:
        if not segments[role]:
            if role in ["PLANNER", "THINKER"]: segments[role] = [m for m in others if any(k in m for k in ["opus", "o1", "pro"])]
            else: segments[role] = [m for m in others if any(k in m for k in ["sonnet", "flash", "coder"])]
            if not segments[role]: segments[role] = available
    thinking = _filter_models(gemini, ["thinking"])
    segments["THINKER"] = thinking if thinking else segments["PLANNER"]
    return segments

def get_model_for_role(role: str) -> str:
    role = role.upper()
    if os.path.exists(CACHE_FILE) and (time.time() - os.path.getmtime(CACHE_FILE)) < CACHE_TTL:
        try:
            with open(CACHE_FILE, "r") as f: segments = json.load(f)
        except: segments = discover_and_segment()
    else:
        segments = discover_and_segment()
        with open(CACHE_FILE, "w") as f: json.dump(segments, f)
    return segments.get(role, ["google/gemini-2.0-flash"])[0]

if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "engineer"
    # Input sanitization
    if not re.match(r'^[a-zA-Z_]+$', arg):
        sys.exit(1)
    arg = arg.upper()
    
    if arg == "DISCOVER":
        if os.path.exists(CACHE_FILE): os.remove(CACHE_FILE)
        print("Discovery triggered")
    else:
        print(get_model_for_role(arg))
EOF

    # Check if we need to update the router script
    local should_update=true
    if [[ -f "$router_path" ]]; then
        # Simple check: if content matches, don't update
        # We strip whitespace to avoid false positives on formatting
        local existing_content
        existing_content=$(cat "$router_path")
        if [[ "$existing_content" == "$router_content" ]]; then
            should_update=false
        fi
    fi

    if $should_update; then
        (
            flock -x 200
            echo "$router_content" > "$router_path"
        ) 200>"$router_path.lock"
        log_debug "Updated model router script at $router_path"
    fi
    
    echo "$router_path"
}

#######################################
# Get optimal model for a specific role
# Arguments:
#   $1 - Role (planner, engineer, tester, thinker)
# Returns: Model identifier
#######################################
get_model_for_role() {
    local role="${1:-engineer}"
    local router_script
    router_script=$(ensure_model_router)
    
    python3 "$router_script" "$role"
}

#######################################
# Pick the newest model for a role from a live model list (one model per line). PURE.
# Scores each line by version number (dominant) then a role-tier keyword rank, so the
# latest model in the right capability tier wins. Lines with no tier keyword are
# ignored (so e.g. a "120B" param count can't masquerade as a version). Empty if none.
# Arguments: $1 role (planner|thinker|engineer|tester), $2 newline-separated list
#######################################
_pick_latest_model() {
    local role="$1" list="$2"
    [[ -n "$list" ]] || return 0
    local kws
    case "$role" in
        planner|thinker) kws="opus|ultra|pro|thinking|reasoning" ;;
        tester)          kws="lite|mini|low|haiku|small|flash" ;;
        *)               kws="sonnet|flash|code|coder|pro" ;;   # engineer (default)
    esac
    printf '%s\n' "$list" | awk -v kws="$kws" '
        { line=$0
          if (line ~ /^[[:space:]]*$/) next
          vs=line; gsub(/[0-9]+[bB]/,"",vs)   # drop param-count tokens (70B/120b) so they cannot pose as a version
          ver=0; if (match(vs, /[0-9]+(\.[0-9]+)?/)) ver=substr(vs,RSTART,RLENGTH)+0
          n=split(kws,a,"|"); rank=0; ll=tolower(line)
          for(i=1;i<=n;i++){ kw=tolower(a[i]); if(ll ~ ("(^|[^a-z])" kw "([^a-z]|$)")){ r=n-i+1; if(r>rank) rank=r } }
          if(rank==0) next
          score=ver*1000+rank
          if(best=="" || score>bestscore){ bestscore=score; best=line } }
        END{ if(best!="") print best }'
}

#######################################
# Resolve a model for the active tool + role, preferring each tool's OWN live source
# over any pinned string (gemini CLI is deprecated; agy/Antigravity is Google's CLI).
#   agy       -> `agy models` then newest-for-role (empty => agy auto-selects latest)
#   claude/amp-> tier alias (opus|sonnet) which resolves to the latest server-side
#   opencode  -> existing dynamic opencode-models router
# Arguments: $1 tool (default $TOOL), $2 role (default engineer)
#######################################
resolve_model_for_tool() {
    local tool="${1:-${TOOL:-opencode}}" role="${2:-engineer}"
    case "$tool" in
        agy)
            local list; list=$(agy models 2>/dev/null) || list=""
            _pick_latest_model "$role" "$list"
            ;;
        claude|amp)
            case "$role" in planner|thinker) echo "opus" ;; *) echo "sonnet" ;; esac
            ;;
        opencode|*)
            get_model_for_role "$role"
            ;;
    esac
}

#######################################
# Determine which model to use
# Respects SELECTED_MODEL override, otherwise auto-selects based on tool + role
# Sets global SELECTED_MODEL variable
# Returns: 0 on success, 1 on failure
#######################################
determine_model() {
    local current_role="${RALPH_ROLE:-engineer}"

    # If model explicitly specified via CLI, use it (highest priority)
    if [[ -n "${SELECTED_MODEL:-}" && "${SELECTED_MODEL_SOURCE:-}" == "CLI" ]]; then
        log_debug "Using CLI-specified model: $SELECTED_MODEL"
        return 0
    fi

    local auto_selected_model
    auto_selected_model=$(resolve_model_for_tool "${TOOL:-opencode}" "$current_role")
    
    SELECTED_MODEL="$auto_selected_model"
    export SELECTED_MODEL
    
    log_debug "Model routed for role '$current_role': $SELECTED_MODEL"
    return 0
}

#######################################
# Validate model availability
# Arguments:
#   $1 - Model identifier
#   $2 - Tool name (optional, for tool-specific validation)
# Returns: 0 if available, 1 if not
#######################################
validate_model_availability() {
    local model="$1"
    local tool="${2:-$TOOL}"
    
    case "$tool" in
        opencode)
            if ! command_exists opencode; then
                log_error "opencode not installed, cannot validate model"
                return 1
            fi
            
            local available_models
            available_models=$(opencode models 2>/dev/null || echo "")
            
            if echo "$available_models" | grep -qF "$model"; then
                log_debug "Model validated: $model"
                return 0
            else
                log_warning "Model not found in opencode: $model"
                return 1
            fi
            ;;
            
        amp|claude)
            # Can't validate without an API call; accept tier aliases (opus/sonnet/haiku,
            # which resolve to the latest server-side) or a dated claude- identifier.
            if [[ "$model" =~ ^(opus|sonnet|haiku|claude-) ]]; then
                log_debug "Model format looks valid: $model"
                return 0
            else
                log_warning "Model format may be invalid: $model"
                return 1
            fi
            ;;
            
        *)
            log_debug "Cannot validate model for unknown tool: $tool"
            return 0
            ;;
    esac
}

#######################################
# Display model information
#######################################
show_model_info() {
    echo ""
    log_info "Model Configuration:"
    log_info "  Tool:  ${_RALPH_COLOR_MAGENTA}$TOOL${_RALPH_COLOR_NC}"
    log_info "  Model: ${_RALPH_COLOR_GREEN}$SELECTED_MODEL${_RALPH_COLOR_NC}"
    
    # Show if model was auto-selected or user-specified
    if [[ -n "${SELECTED_MODEL_SOURCE:-}" ]]; then
        log_info "  Source: $SELECTED_MODEL_SOURCE"
    fi
    
    # Validate if possible
    if validate_model_availability "$SELECTED_MODEL" "$TOOL"; then
        log_success "  Status: ✓ Available"
    else
        log_warning "  Status: ⚠ Could not verify availability"
    fi
    
    echo ""
}

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
    echo -e "${_RALPH_COLOR_BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${_RALPH_COLOR_NC}"
    echo -e "${_RALPH_COLOR_BLUE}║${_RALPH_COLOR_NC} ${_RALPH_COLOR_YELLOW}RALPH AGENT${_RALPH_COLOR_NC} | Iteration: ${_RALPH_COLOR_CYAN}${iteration}/${max}${_RALPH_COLOR_NC} | Tool: ${_RALPH_COLOR_MAGENTA}${tool}${_RALPH_COLOR_NC}"
    echo -e "${_RALPH_COLOR_BLUE}║${_RALPH_COLOR_NC} Model: ${_RALPH_COLOR_GREEN}${model}${_RALPH_COLOR_NC}"
    echo -e "${_RALPH_COLOR_BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${_RALPH_COLOR_NC}"
    echo ""
}

#######################################
# Get instructions for a specific role
# Arguments:
#   $1 - Role name
# Returns: Role-specific instructions
#######################################
get_role_instructions() {
    local role="${1:-engineer}"
    case "$role" in
        planner)
            cat <<EOF
<role>You are the Ralph Planner. Your primary responsibility is project decomposition and task management using Beads.</role>
<instructions>
1. Analyze the PRD and existing codebase.
2. Decompose goals into atomic, unblocked tasks in Beads using 'bd create'.
3. Set appropriate priorities (P1-P4) and dependencies (--deps).
4. Update 'ralph_plan.md' by running 'sync_plan_file'.
</instructions>
<constraints>DO NOT write implementation code. DO NOT run tests. FOCUS ONLY on task creation.</constraints>
EOF
            ;;
        tester)
            cat <<EOF
<role>You are the Ralph Tester. Your primary responsibility is verification and quality assurance.</role>
<instructions>
1. Identify changed files. Write unit/integration tests for new functionality.
2. Run tests and capture output.
3. If tests FAIL: Report failure and suggest fixes. DO NOT close task.
4. If tests PASS: Close the Beads task using 'bd close <id>'.
</instructions>
<constraints>DO NOT write feature code. FOCUS ONLY on finding bugs and verifying correctness.</constraints>
EOF
            ;;
        *) # Default: engineer
            cat <<EOF
<role>You are the Ralph Engineer. Your primary responsibility is code implementation and architectural integrity.</role>
<instructions>
1. Check 'bd ready' for the next unblocked task.
2. Implement the feature or fix described.
3. Update 'ralph_architecture.md' (Mermaid) if design changes.
4. Ensure code is idiomatic and follows project conventions.
</instructions>
<constraints>DO NOT create new Beads tasks. FOCUS on implementation quality.</constraints>
EOF
            ;;
    esac
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
    # shellcheck disable=SC2154
    local prompt_content="$1"
    local plan_context="$2"
    local prd_context="$3"
    local diagram_context="$4"
    local gitdiff_exclude_args="$5"
    local reflection_instruction="$6"
    local recent_changes="$7"
    local resource_context="$8"
    local user_provided_context="$9"
    local project_instructions="${10:-}"
    
    local role_instructions
    role_instructions=$(get_role_instructions "${RALPH_ROLE:-engineer}")

    cat <<EOF
<system_prompt>
$role_instructions

<project_instructions>
${project_instructions:-No project-specific instructions provided. Follow general best practices and project conventions.}
</project_instructions>

<cognitive_process>
At the start of every response, you MUST use a internal monologue or <thought> block to:
1. **Reflect:** Analyze the <recent_changes> and <global_context>. If the previous iteration failed or made no progress, identify the root cause.
2. **Plan:** Identify the next unblocked task from Beads (\`bd ready\`).
3. **Reason:** Determine the most efficient tool-path to complete the task.
4. **Anticipate:** Identify potential side effects or breaking changes to the architecture.
</cognitive_process>

<capabilities>
1. **Full-Stack Engineering:** Expert in modern software delivery and best practices.
2. **Architectural Visualization:** Use Mermaid syntax in '${DIAGRAM_FILE:-ralph_architecture.md}' to model system state, data flow, and dependencies.
3. **Requirement Engineering:** Maintain '${PRD_FILE:-prd.json}' (JSON) to define goals, user stories, and success metrics.
4. **Time-Travel Task Memory (Beads + Dolt):** Use 'bd' CLI for reliable, dependency-aware task tracking with full version history.
   - Create task: \`bd create "Title" -d "Description" [--deps "id1,id2"]\`
   - List ready tasks: \`bd ready\`
   - **Time-Travel:** You can view previous task states if needed using \`bd vc log\`.
5. **Intelligent Model Routing:** Your requests are automatically routed to specialized models based on your current role:
   - **Planner/Thinker:** Routed to high-reasoning models (Gemini 2.0 Pro/Thinking).
   - **Engineer/Tester:** Routed to high-speed implementation models (Gemini 2.0 Flash).
6. **Self-Healing Tooling:** If a required test runner or dependency (e.g., pytest, npm, cargo) is missing, you can attempt to autonomously install it using \`ralph setup\`.
7. **Swarm Orchestration:** You can act as a Team Leader or Specialist.
   - Spawn sub-agents: \`ralph swarm spawn --role "RoleName" --task "Task description"\`
   - Send messages: \`ralph swarm msg --to <agent_id> --content "Message"\`
8. **Long-Term Virtual Memory:** Use the \`save_memory\` tool to persist project-wide engineering patterns, architectural decisions, and "lessons learned" across all future projects.
</capabilities>

<workflow>
1. **Initialize:** If missing, create internal artifacts in '$ARTIFACT_DIR' and initialize beads with 'bd init'.
2. **Align:** Ensure code changes align with Architecture ('$DIAGRAM_FILE') and Requirements ('$PRD_FILE').
3. **Execute:** Perform the next unblocked task from 'bd ready'. Close it with 'bd close' when done.
4. **Verify:** Write and run tests for every implementation. Never assume code works.
5. **Sync:** Reflect changes back into documentation files in '$ARTIFACT_DIR' as the system evolves.
</workflow>

<constraints>
- **Diagram First:** Update the architecture diagram BEFORE writing complex features.
- **Verification Mandatory:** Do not close a Beads task until you have executed a test that passes.
- **Valid Artifacts:** Ensure '$PRD_FILE' is valid JSON and '$DIAGRAM_FILE' is valid Mermaid.
- **No Loops:** If you are stuck in a cycle (repeatedly failing), STOP and ask for user intervention or try a radically different approach.
- **Termination:** Output <promise>COMPLETE</promise> only when ALL Beads tasks are CLOSED and docs are synced.
</constraints>

<high_integrity_checklist>
Before finalizing your response, verify:
- [ ] Have I updated the Mermaid diagram to reflect architectural changes?
- [ ] Have I closed the relevant Beads task if the work is verified?
- [ ] Have I created follow-up tasks in Beads for discovered work?
- [ ] Is the code idiomatic and properly tested?
</high_integrity_checklist>

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
1. Use the <cognitive_process> to analyze the current state.
2. Execute the next task from Beads.
3. Update artifacts and verify with tests.
4. Review the <high_integrity_checklist>.
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
#######################################
# Build the argv for an AI tool into _AI_CMD[] and set _AI_STDIN (1 = prompt piped on
# stdin, 0 = prompt passed as the final positional arg). PURE — no execution — so each
# tool's invocation is unit-testable. Verified against every CLI's --help:
#   amp      stdin-piped, --dangerously-allow-all
#   claude   -p/--print (REQUIRED for headless — without it claude 2.x goes interactive),
#            --permission-mode bypassPermissions, --model
#   opencode  opencode run --model <provider/model>
#   agy      --print --dangerously-skip-permissions  (Google Antigravity CLI; no --model flag)
# Arguments: $1 tool, $2 model
# Returns: 0 and sets _AI_CMD/_AI_STDIN; 1 for an unknown tool.
#######################################
_build_ai_cmd() {
    local tool="$1" model="$2"
    _AI_CMD=(); _AI_STDIN=0
    case "$tool" in
        amp)
            _AI_CMD=(amp --dangerously-allow-all); _AI_STDIN=1 ;;
        claude)
            _AI_CMD=(claude -p --dangerously-skip-permissions --permission-mode bypassPermissions --model "$model") ;;
        opencode)
            _AI_CMD=(opencode run --model "$model") ;;
        agy)
            _AI_CMD=(agy --print --dangerously-skip-permissions) ;;
        *)
            return 1 ;;
    esac
    return 0
}

# Apply per-tool environment side effects. MUST be called inside the launch subshell so
# CI/ANTHROPIC_* do not leak into the parent shell or later iterations.
_apply_tool_env() {
    case "$1" in
        claude)
            export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
            export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://localhost:11434}"
            ;;
        opencode)
            export CI=true
            ;;
    esac
}

run_ai_tool() {
    local tool="$1"
    local model="$2"
    local prompt="$3"
    local log_file="$4"
    local output_file="$5"
    
    log_info "Running ${_RALPH_COLOR_MAGENTA}${tool}${_RALPH_COLOR_NC} with model: ${_RALPH_COLOR_GREEN}${model}${_RALPH_COLOR_NC}"
    log_debug "Prompt length: ${#prompt} characters"
    
    local pid i exit_code

    # Build the argv (testable; no execution), then launch in the background.
    if ! _build_ai_cmd "$tool" "$model"; then
        log_error "Unknown tool: $tool"
        return 1
    fi
    # Launch in the background; per-tool env is applied INSIDE the subshell so it can't
    # leak into the parent shell or later iterations.
    if [[ "$_AI_STDIN" == "1" ]]; then
        ( _apply_tool_env "$tool"; printf '%s\n' "$prompt" | "${_AI_CMD[@]}" 2>&1 | tee -a "$log_file" > "$output_file") &
    else
        ( _apply_tool_env "$tool"; "${_AI_CMD[@]}" "$prompt" 2>&1 | tee -a "$log_file" > "$output_file") &
    fi
    pid=$!
    
    # Animated spinner while tool runs
    local i=0
    start_progress_timer
    update_status "Thinking" "$(basename "${PROJECT_DIR:-.}")"
    
    while kill -0 $pid 2>/dev/null; do
        render_status_bar "$iteration" "$MAX_ITERATIONS" "$i"
        i=$(( (i+1) % 10 ))
        sleep 0.1
    done
    
    # Get exit code
    wait $pid
    exit_code=$?
    
    # Clear line and show final success/fail
    printf "\r\033[K"
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Iteration $iteration: AI Response Received"
    else
        log_error "Iteration $iteration: AI Tool Failed (Exit $exit_code)"
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

    if [[ $lazy_streak -ge "${LAZY_THRESHOLD:-2}" ]]; then
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
    local project_instructions=""
    local prompt_content structured_prompt output
    
    # Display iteration header
    print_header "$iteration" "$MAX_ITERATIONS" "${TOOL:-opencode}" "$SELECTED_MODEL"
    
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
    if [[ -f "${PROJECT_DIR:-.}/AGENTS.md" ]]; then
        prompt_content=$(cat "${PROJECT_DIR:-.}/AGENTS.md")
    else
        log_error "No prompt file found (AGENTS.md)"
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

    if [[ -f "${AGENTS_FILE:-AGENTS.md}" ]]; then
        project_instructions=$(cat "${AGENTS_FILE:-AGENTS.md}")
        log_debug "Loaded project-specific instructions from ${AGENTS_FILE:-AGENTS.md}"
    fi
    
    # Load system resources and user context
    resource_context=$(get_resource_usage)
    user_provided_context=$(read_context_files)
    
    # Recall historical lessons (Genetic Memory)
    local genetic_memory
    genetic_memory=$(recall_lessons)
    user_provided_context+="${genetic_memory:-}"

    # Consume War Room events (Real-time coordination)
    local swarm_events
    swarm_events=$(consume_events)
    user_provided_context+="${swarm_events:-}"

    # Surface the durable compounding layer: recurring signals + recent LOG narrative,
    # plus proven resolutions (approved skills) for problems currently open.
    user_provided_context+="$(recall_signals)"
    user_provided_context+="$(recall_log)"
    declare -F recall_skills >/dev/null && user_provided_context+="$(recall_skills)" || true

    # Detect available opencode skills
    local available_skills=""
    if [[ -d "$HOME/.config/opencode/skills" ]]; then
        available_skills=$(find "$HOME/.config/opencode/skills" -maxdepth 1 -not -path '*/.*' -exec basename {} \; | tr '\n' ',' | sed 's/,$//')
    fi
    if [[ -n "$available_skills" ]]; then
        user_provided_context+=$'\n'"Available opencode skills: $available_skills (Activate via: opencode run \"activate skill <name>\")"
    fi

    # Persist recovery state for THIS iteration BEFORE the queued correction is
    # consumed below, so a crash during the LLM call resumes (--resume) with the
    # correction and loop-control state intact.
    save_recovery_state "$iteration" || true

    # Generate reflection instructions based on agent state
    if [[ -n "${NEXT_INSTRUCTION:-}" ]]; then
        # Priority: Use explicit instruction from previous iteration
        reflection_instruction="$NEXT_INSTRUCTION"
        export NEXT_INSTRUCTION=""
    elif [[ "${LAZY_STREAK:-0}" -ge "${LAZY_THRESHOLD:-2}" ]]; then
        # Detect stalling
        reflection_instruction=$(generate_stalling_instruction "$LAZY_STREAK")
    elif [[ -n "${PREVIOUS_LOG_HASH:-}" ]] && [[ "$current_log_signature" == "$PREVIOUS_LOG_HASH" ]]; then
        # Detect infinite loop
        reflection_instruction=$(generate_loop_instruction "$PREVIOUS_LOG_HASH" "$current_log_signature")
        record_signal loop_detected "repeating the same actions across iterations" "repeating-same-actions" "change approach; the last action produced no new state" "loop_detection" >/dev/null 2>&1 || true
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
        "$user_provided_context" \
        "$project_instructions")
    
    # Estimate token count
    local est_tokens
    est_tokens=$(estimate_tokens "$structured_prompt")
    log_debug "Estimated prompt tokens: $est_tokens"
    
    # Execute AI tool
    local start_ts end_ts iteration_latency
    start_ts=$(get_high_res_time)

    # Bounded retry so a transient tool/API failure is NOT mistaken for
    # "no work left to do". On exhaustion we return a distinct code (2) and
    # emit a durable failure event instead of silently continuing.
    local ai_attempts="${AI_RETRY_ATTEMPTS:-3}"
    if ! retry_with_backoff "$ai_attempts" "${AI_RETRY_BASE_DELAY:-5}" -- \
            run_ai_tool "$TOOL" "$SELECTED_MODEL" "$structured_prompt" "$LOG_FILE" "$temp_output"; then
        log_error "AI tool execution failed after ${ai_attempts} attempt(s)"
        # Build the payload with jq so special characters in TOOL/SELECTED_MODEL cannot
        # produce malformed JSON.
        local fail_payload
        fail_payload=$(jq -n --argjson iteration "$iteration" --arg tool "$TOOL" --arg model "$SELECTED_MODEL" \
            '{iteration: $iteration, tool: $tool, model: $model}' 2>/dev/null || echo '{}')
        emit_event "iteration_failed" "$fail_payload"
        store_lesson "Iteration $iteration failed: tool '$TOOL' did not complete after ${ai_attempts} attempts (model $SELECTED_MODEL)."
        record_signal task_repeat_failure "AI tool failed to complete the iteration" "tool $TOOL model $SELECTED_MODEL did not complete after retries" "investigate tool/model/connectivity failure" "run_ai_tool" "high" >/dev/null 2>&1 || true
        return 2
    fi
    
    end_ts=$(get_high_res_time)
    iteration_latency=$(echo "$end_ts - $start_ts" | bc 2>/dev/null || echo "0")
    
    # Read output
    output=$(cat "$temp_output" 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        log_warning "AI tool produced no output"
    fi

    # Persist a per-step trace (prompt in, output out) for post-hoc observability.
    if [[ -n "${RUN_DIR:-}" ]]; then
        local step_dir="$RUN_DIR/steps/iter-$iteration"
        if mkdir -p "$step_dir" 2>/dev/null; then
            printf '%s' "$structured_prompt" > "$step_dir/prompt.txt" 2>/dev/null || true
            printf '%s' "$output" > "$step_dir/output.txt" 2>/dev/null || true
        fi
    fi
    
    # Validate artifacts and queue corrections for next iteration
    local artifact_errors runtime_errors
    artifact_errors=$(validate_artifacts)
    runtime_errors=$(verify_runtime)
    
    if [[ -n "$artifact_errors" || -n "$runtime_errors" ]]; then
        export NEXT_INSTRUCTION="${artifact_errors}${runtime_errors}"
        log_warning "Validation or runtime errors detected, will correct in next iteration"
        SIGNAL_CLEAN_STREAK=0
        # Record recurring failures as deduped signals (frequency climbs on repeat).
        [[ -n "$artifact_errors" ]] && record_signal validation_failure "artifact validation failed" "$artifact_errors" "fix the flagged artifacts before continuing" "validation" >/dev/null 2>&1 || true
        [[ -n "$runtime_errors" ]] && record_signal runtime_failure "runtime verification failed" "$runtime_errors" "fix the runtime/build error before closing the task" "verify_runtime" >/dev/null 2>&1 || true
    else
        # Both clean: count toward auto-resolving the failure families.
        SIGNAL_CLEAN_STREAK=$(( ${SIGNAL_CLEAN_STREAK:-0} + 1 ))
        if [[ "${RALPH_SIGNAL_AUTORESOLVE:-1}" == "1" && ${SIGNAL_CLEAN_STREAK:-0} -ge ${RALPH_SIGNAL_CLEAN_STREAK:-2} ]]; then
            _signal_auto_resolve_family validation_failure || true
            _signal_auto_resolve_family runtime_failure || true
        fi
    fi
    
    # Analyze project changes
    local project_hash_after
    project_hash_after=$(compute_project_hash)
    log_debug "Project hash after: $project_hash_after"
    
    if [[ "$project_hash_before" == "$project_hash_after" ]]; then
        LAZY_STREAK=$(( ${LAZY_STREAK:-0} + 1 ))
        log_warning "No files modified this iteration (streak: $LAZY_STREAK)"
        if [[ ${LAZY_STREAK:-0} -ge ${LAZY_THRESHOLD:-2} ]]; then
            record_signal lazy_streak "no files modified for $LAZY_STREAK consecutive iterations" "no-files-modified" "make a concrete code change or output the completion promise" "lazy_detection" >/dev/null 2>&1 || true
        fi
    else
        log_success "Files modified - agent is making progress"
        LAZY_STREAK=0
        # Real progress clears stall/loop patterns.
        _signal_auto_resolve_family lazy_streak >/dev/null 2>&1 || true
        _signal_auto_resolve_family loop_detected >/dev/null 2>&1 || true
    fi
    
    # Log metrics (JSONL). Build with jq so special chars in TOOL/SELECTED_MODEL
    # can't emit malformed JSON that would later break review_run's parsing.
    local timestamp metrics_payload
    timestamp=$(date +%Y-%m-%dT%H:%M:%S)
    # Normalize numerics (bc can emit ".5" without a leading zero -> invalid JSON).
    [[ "$iteration_latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || iteration_latency=0
    [[ "$est_tokens" =~ ^[0-9]+$ ]] || est_tokens=0
    metrics_payload=""
    if command_exists jq; then
        metrics_payload=$(jq -nc \
            --arg timestamp "$timestamp" \
            --arg run_id "${RUN_ID:-}" \
            --argjson iteration "${iteration:-0}" \
            --arg tool "$TOOL" \
            --arg model "$SELECTED_MODEL" \
            --argjson latency "${iteration_latency:-0}" \
            --argjson tokens "${est_tokens:-0}" \
            --argjson lazy_streak "${LAZY_STREAK:-0}" \
            --arg project_hash "$project_hash_after" \
            '{timestamp:$timestamp, run_id:$run_id, iteration:$iteration, tool:$tool, model:$model, latency:$latency, tokens:$tokens, lazy_streak:$lazy_streak, project_hash:$project_hash}' 2>/dev/null)
    fi
    if [[ -n "$metrics_payload" ]]; then
        log_metrics "$metrics_payload"
    else
        log_metrics "{\"timestamp\": \"$timestamp\", \"run_id\": \"${RUN_ID:-}\", \"iteration\": $iteration, \"tool\": \"$TOOL\", \"model\": \"$SELECTED_MODEL\", \"latency\": ${iteration_latency:-0}, \"tokens\": ${est_tokens:-0}, \"lazy_streak\": ${LAZY_STREAK:-0}, \"project_hash\": \"$project_hash_after\"}"
    fi
    
    # Save checkpoint
    save_checkpoint "$iteration"

    # Update loop detection state
    PREVIOUS_LOG_HASH="$current_log_signature"

    # Persist recovery state for the NEXT iteration (updated lazy streak, loop
    # hash, and any queued correction) so --resume picks up exactly where we left off.
    save_recovery_state "$iteration" || true

    # Sync human-readable plan (Beads style)
    sync_plan_file
    
    # Commit task state (Dolt Time-Travel)
    commit_task_state "Ralph Iteration $iteration: $est_tokens tokens"

    # Narrate this iteration into the global LOG (linked to its step traces).
    local _changed="no"; [[ "$project_hash_before" != "$project_hash_after" ]] && _changed="yes"
    RALPH_LOG_ITER="$iteration" log_append \
        "iteration $iteration ($TOOL/$SELECTED_MODEL)" \
        "[prompt](${RUN_DIR:-.}/steps/iter-$iteration/prompt.txt) · [output](${RUN_DIR:-.}/steps/iter-$iteration/output.txt)" \
        "" \
        "changed=$_changed · lazy_streak=${LAZY_STREAK:-0} · tokens=$est_tokens" || true
    
    # Check for completion signal
    if echo "$output" | grep -qF "<promise>COMPLETE</promise>"; then
        if verify_beads_complete; then
            log_success "Agent signaled completion and all Beads tasks are closed"
            
            # Store lesson learned (basic heuristic: extract summary or use project name)
            local project_name
            project_name=$(basename "$(pwd)")
            store_lesson "Project '$project_name' completed successfully with $iteration iterations."
            
            return 0
        else
            log_warning "Agent signaled completion but incomplete tasks remain in Beads"
            local ready_tasks
            ready_tasks=$(_bd ready --pretty)
            export NEXT_INSTRUCTION="You signaled completion, but the following tasks are still incomplete in Beads. Please complete them and use 'bd close <id>' for each before terminating:\n$ready_tasks"
        fi
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

    # Signal/skill CLIs (dispatched after load_config so SIGNAL_DIR/SKILL_DIR exist,
    # before parse_arguments which wouldn't recognize the subcommand).
    if [[ "${1:-}" == "signal" ]]; then
        shift
        handle_signal_command "$@"
        exit $?
    fi
    if [[ "${1:-}" == "skill" ]]; then
        shift
        handle_skill_command "$@"
        exit $?
    fi
    if [[ "${1:-}" == "lint" ]]; then
        shift
        handle_lint_command "$@"
        exit $?
    fi

    parse_arguments "$@"
    
    # Handle Smart Init
    if [[ "${INIT_MODE:-false}" == "true" ]]; then
        smart_init
        exit 0
    fi

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

    # Handle review mode: analyze metrics history, update tuning.json, exit.
    if [[ "${REVIEW_MODE:-false}" == "true" ]]; then
        review_run
        exit $?
    fi

    # Validate configuration
    validate_config || exit 1

    # Unattended mode: prefer the hardened Docker sandbox for autonomous runs.
    # Skip when already inside the sandbox container (we are the isolation boundary).
    if [[ "${UNATTENDED:-false}" == "true" && "${SANDBOX_MODE:-false}" != "true" ]] && ! running_in_container; then
        if command_exists docker; then
            log_info "Unattended mode: enabling Docker sandbox for isolation"
            export SANDBOX_MODE=true
        else
            log_warning "Unattended mode requested but Docker is unavailable; running on host."
            log_warning "Install Docker, or pass --no-sandbox to explicitly accept host execution."
        fi
    fi

    # Handle sandbox mode. run_in_sandbox RETURNS (it does not exit), so we must
    # terminate here — otherwise control falls through and the loop runs AGAIN,
    # unsandboxed, on the host after the container finishes.
    if [[ "${SANDBOX_MODE:-false}" == "true" ]]; then
        setup_sandbox || exit 1
        run_in_sandbox "$@"
        exit $?
    fi

    # --- Below runs in the process that actually iterates (host or container) ---

    # Singleton lock: prevent concurrent runs from corrupting shared state
    # (.ralph/state, checkpoint, recovery.json, task DB, plan file). Acquired here
    # (not before the sandbox exec) so the host wrapper does not deadlock against
    # its own bind-mounted container over the same lock file.
    if command_exists flock; then
        local lock_file="${STATE_DIR:-.ralph/state}/ralph.lock"
        mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
        # Guard the FD redirect: a bare `exec 9>file` aborts the whole script under
        # set -e if the file exists but is not writable. The brace group scopes the
        # `2>/dev/null` to the open attempt only — without it, `exec` (no command)
        # would make the stderr redirect PERMANENT and blackhole all later logs.
        if ! { exec 9>"$lock_file"; } 2>/dev/null; then
            log_warning "Cannot open lock file $lock_file; skipping singleton lock."
        elif ! flock -n 9; then
            log_error "Another Ralph instance is already running for this project (lock: $lock_file)."
            log_info "Use a separate git worktree for parallel runs, or wait for the current run to finish."
            exit 1
        else
            log_debug "Acquired singleton lock: $lock_file"
        fi
    else
        log_warning "flock unavailable: cannot guarantee single-instance execution; concurrent runs may corrupt state."
    fi

    # Allocate this run's directory here (only on the iterating path, so
    # --review/--test/--help/--setup/--init don't litter empty run dirs) and
    # prune old runs to bound disk growth.
    mkdir -p "$RUN_DIR/steps" 2>/dev/null || true
    chmod 700 "$RUN_DIR" 2>/dev/null || true   # step traces may contain prompt secrets
    ln -sfn "$RUN_DIR" "$_RALPH_DIR/runs/latest" 2>/dev/null || true
    prune_old_runs "$_RALPH_DIR/runs" "${RALPH_RUN_RETENTION:-20}"

    # Loud warning when iterating autonomously on the host without isolation.
    if ! running_in_container && [[ "${SANDBOX_MODE:-false}" != "true" ]]; then
        log_warning "No sandbox isolation: the agent runs with full host permissions."
        log_warning "For unattended use prefer './ralph.sh --unattended' (Docker-isolated)."
    fi
    
    # Display startup information
    log_info "Starting Ralph AI Agent"
    log_info "OS: $OS_TYPE ($ARCH_TYPE)"
    log_info "Tool: $TOOL | Max Iterations: $MAX_ITERATIONS"
    
    # Setup execution environment
    archive_previous_run
    track_current_branch
    init_memory
    init_signals
    init_skills
    init_task_engine
    
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        initialize_progress_file
    fi
    
    # Determine model to use
    determine_model || {
        log_error "Failed to determine model"
        exit 1
    }
    
    # Initialize state variables (fresh-run defaults)
    export LAZY_STREAK=0
    export SIGNAL_CLEAN_STREAK=0
    export PREVIOUS_LOG_HASH=""
    export NEXT_INSTRUCTION=""
    local CONSECUTIVE_FAILURES=0
    local DRAIN_STREAK=0

    # Determine starting iteration
    local start_iter=1

    if [[ "${RESUME_FLAG:-false}" == "true" ]]; then
        local last_checkpoint
        last_checkpoint=$(get_checkpoint)

        if [[ "$last_checkpoint" =~ ^[0-9]+$ ]] && [[ $last_checkpoint -gt 0 ]]; then
            log_info "Resuming from checkpoint: Iteration $last_checkpoint"
            start_iter=$((last_checkpoint + 1))

            # Restore loop-control state so a resumed run keeps its lazy streak,
            # loop-detection hash, and any queued correction instead of forgetting them.
            if load_recovery_state; then
                local _has_correction="no"
                [[ -n "${NEXT_INSTRUCTION:-}" ]] && _has_correction="yes"
                log_info "Restored recovery state (lazy_streak=$LAZY_STREAK, queued correction: $_has_correction)"
            fi
        else
            log_warning "No valid checkpoint found, starting from beginning"
        fi
    fi
    
    # Main iteration loop
    for i in $(seq "$start_iter" "$MAX_ITERATIONS"); do
        
        # Interactive mode: pause for user input
        if [[ "${INTERACTIVE_MODE:-false}" == "true" ]]; then
            echo ""
            echo -e "${_RALPH_COLOR_YELLOW}>>> Interactive Mode: Paused <<<${_RALPH_COLOR_NC}"
            echo -e "Press ${_RALPH_COLOR_GREEN}[Enter]${_RALPH_COLOR_NC} to continue, or type an instruction for Ralph:"
            
            local user_input
            read -r user_input
            
            if [[ -n "$user_input" ]]; then
                export NEXT_INSTRUCTION="<user_steering>$user_input</user_steering>"
                log_info "User instruction queued for next iteration"
            fi
        fi
        
        # Execute iteration. Return codes: 0=complete, 1=continue, 2=hard tool failure.
        local iter_rc=0
        execute_iteration "$i" || iter_rc=$?

        if [[ $iter_rc -eq 0 ]]; then
            echo ""
            log_success "╔══════════════════════════════════════╗"
            log_success "║   Ralph completed all tasks! 🎉     ║"
            log_success "╚══════════════════════════════════════╝"
            log_success "Completed at iteration $i of $MAX_ITERATIONS"
            review_run
            exit 0
        elif [[ $iter_rc -eq 2 ]]; then
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            log_error "Iteration $i: AI tool failed after retries (consecutive failures: $CONSECUTIVE_FAILURES)."
            if [[ $CONSECUTIVE_FAILURES -ge ${MAX_CONSECUTIVE_FAILURES:-3} ]]; then
                log_error "Aborting: ${CONSECUTIVE_FAILURES} consecutive tool failures. Check connectivity, auth, or model availability."
                send_notification "Ralph stopped" "Aborted after ${CONSECUTIVE_FAILURES} consecutive tool failures" "critical"
                exit 1
            fi
            log_warning "Backing off before re-attempting the loop..."
            sleep 5
        else
            CONSECUTIVE_FAILURES=0
            log_info "Iteration $i complete. Continuing..."
            sleep 2
        fi

        # Stop early once the backlog is provably drained for TWO consecutive
        # iterations (work done, nothing open). The streak avoids exiting on a
        # transient empty queue between task phases. Only after a normal iteration.
        if [[ $iter_rc -eq 1 ]] && backlog_drained; then
            DRAIN_STREAK=$(( DRAIN_STREAK + 1 ))
            if [[ $DRAIN_STREAK -ge 2 ]]; then
                log_success "Task backlog drained for 2 iterations — all tracked work is complete."
                review_run
                exit 0
            fi
            log_info "Backlog appears drained (streak ${DRAIN_STREAK}/2); confirming on next iteration."
        else
            DRAIN_STREAK=0
        fi

        # Single-iteration mode: let an external scheduler (cron/systemd) own cadence.
        if [[ "${RUN_ONCE:-false}" == "true" ]]; then
            log_info "Single-iteration mode (--once): stopping. Use --resume to continue."
            if [[ $iter_rc -eq 2 ]]; then
                # The in-process circuit breaker cannot accumulate across cron ticks,
                # so alert here on a hard failure instead of exiting silently non-zero.
                send_notification "Ralph (--once) failed" "Iteration $i tool failure; check logs" "critical"
                exit 1
            fi
            review_run
            exit 0
        fi
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

    review_run
    exit 1
}

#######################################
# Validate key Ralph artifacts
# Checks PRD, architecture diagram, and execution plan
# Returns: Validation instructions/warnings for the AI agent
#######################################
validate_artifacts() {
    local instructions=""
    local errors=0
    local warnings=0
    
    log_debug "Validating Ralph artifacts..."
    
    # Validate PRD (Product Requirements Document)
    if ! validate_prd; then
        ((errors++))
        instructions+=$'\n'"<priority_interrupt>CRITICAL: PRD validation failed. See errors above and fix immediately before proceeding.</priority_interrupt>"
    fi
    
    # Validate Architecture Diagram
    if ! validate_architecture_diagram "warn"; then
        ((warnings++))
        instructions+=$'\n'"<priority_interrupt>WARNING: Architecture diagram validation failed. Consider updating '${DIAGRAM_FILE:-ralph_architecture.md}' with valid Mermaid syntax.</priority_interrupt>"
    fi
    
    # Validate Execution Plan
    if ! validate_execution_plan "warn"; then
        ((warnings++))
        instructions+=$'\n'"<priority_interrupt>WARNING: Execution plan validation failed. Update '${PLAN_FILE:-ralph_plan.md}' to use proper checkbox format (- [ ] or - [x]).</priority_interrupt>"
    fi

    # Verify Architectural Integrity
    local drift
    drift=$(verify_architecture)
    if [[ -n "$drift" ]]; then
        instructions+=$'\n'"$drift"
        # `declare -F` guard keeps validate_artifacts safe when signals.sh isn't sourced.
        declare -F record_signal >/dev/null && record_signal arch_drift "architecture diagram drifted from the code" "$drift" "reconcile code with ralph_architecture.md" "verify_architecture" >/dev/null 2>&1 || true
    else
        declare -F _signal_auto_resolve_family >/dev/null && _signal_auto_resolve_family arch_drift >/dev/null 2>&1 || true
    fi
    
    # Log summary
    if [[ $errors -gt 0 ]] || [[ $warnings -gt 0 ]]; then
        log_warning "Artifact validation completed: $errors error(s), $warnings warning(s)"
    else
        log_debug "All artifacts validated successfully"
    fi
    
    echo "$instructions"
}

#######################################
# Validate PRD JSON file
# Returns: 0 if valid, 1 if invalid or missing
#######################################
validate_prd() {
    local prd_file="${PRD_FILE:-prd.json}"
    
    if [[ ! -f "$prd_file" ]]; then
        log_debug "PRD file not found: $prd_file (will be created)"
        return 0
    fi
    
    # Check if jq is available
    if ! command_exists jq; then
        log_warning "jq not installed, cannot validate PRD JSON structure"
        return 0  # Don't fail if jq is missing
    fi
    
    # Validate JSON syntax
    if ! jq empty "$prd_file" >/dev/null 2>&1; then
        log_error "PRD contains invalid JSON: $prd_file"
        
        # Try to show the error
        local json_error
        json_error=$(jq empty "$prd_file" 2>&1)
        log_debug "JSON error: $json_error"
        
        return 1
    fi
    
    # Validate expected structure
    local has_required_fields=true
    local missing_fields=()
    
    # Check for key fields (adjust based on your PRD schema)
    local required_fields=("projectName" "goals")
    
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$prd_file" >/dev/null 2>&1; then
            missing_fields+=("$field")
            has_required_fields=false
        fi
    done
    
    if ! $has_required_fields; then
        log_warning "PRD is missing recommended fields: ${missing_fields[*]}"
        log_info "Consider adding these fields for better context"
    fi
    
    # Validate specific field types
    if jq -e '.branchName' "$prd_file" >/dev/null 2>&1; then
        local branch_name
        branch_name=$(jq -r '.branchName // empty' "$prd_file")
        
        if [[ -n "$branch_name" ]]; then
            log_debug "PRD branch: $branch_name"
        fi
    fi
    
    log_success "PRD validation passed: $prd_file"
    return 0
}

#######################################
# Validate architecture diagram (Mermaid)
# Arguments:
#   $1 - Severity level: "error" or "warn" (default: warn)
# Returns: 0 if valid, 1 if invalid
#######################################
validate_architecture_diagram() {
    local severity="${1:-warn}"
    local diagram_file="${DIAGRAM_FILE:-ralph_architecture.md}"
    
    if [[ ! -f "$diagram_file" ]]; then
        log_debug "Architecture diagram not found: $diagram_file (will be created)"
        return 0
    fi
    
    # Check file is not empty
    if [[ ! -s "$diagram_file" ]]; then
        if [[ "$severity" == "error" ]]; then
            log_error "Architecture diagram is empty: $diagram_file"
        else
            log_warning "Architecture diagram is empty: $diagram_file"
        fi
        return 1
    fi
    
    # Valid Mermaid diagram types
    local mermaid_keywords=(
        "graph"
        "flowchart"
        "sequenceDiagram"
        "classDiagram"
        "stateDiagram"
        "erDiagram"
        "gantt"
        "pie"
        "journey"
        "gitGraph"
        "mindmap"
        "timeline"
        "quadrantChart"
    )
    
    # Check for Mermaid code blocks
    local has_mermaid_block=false
    if grep -qE '```mermaid|~~~mermaid' "$diagram_file"; then
        has_mermaid_block=true
        log_debug "Found Mermaid code block in diagram"
    fi
    
    # Check for Mermaid diagram keywords
    local has_mermaid_syntax=false
    for keyword in "${mermaid_keywords[@]}"; do
        if grep -qE "^[[:space:]]*${keyword}[[:space:]]" "$diagram_file"; then
            has_mermaid_syntax=true
            log_debug "Found Mermaid keyword: $keyword"
            break
        fi
    done
    
    if ! $has_mermaid_syntax; then
        if [[ "$severity" == "error" ]]; then
            log_error "Architecture diagram missing valid Mermaid syntax: $diagram_file"
        else
            log_warning "Architecture diagram may be missing Mermaid syntax: $diagram_file"
        fi
        log_info "Expected keywords: ${mermaid_keywords[*]}"
        return 1
    fi
    
    if ! $has_mermaid_block; then
        log_warning "Architecture diagram missing Mermaid code block markers (\`\`\`mermaid)"
        log_info "Consider wrapping diagram in proper markdown code blocks"
    fi
    
    log_success "Architecture diagram validation passed: $diagram_file"
    return 0
}

#######################################
# Validate execution plan format
# Arguments:
#   $1 - Severity level: "error" or "warn" (default: warn)
# Returns: 0 if valid, 1 if invalid
#######################################
validate_execution_plan() {
    local severity="${1:-warn}"
    local plan_file="${PLAN_FILE:-ralph_plan.md}"
    
    if [[ ! -f "$plan_file" ]]; then
        log_debug "Execution plan not found: $plan_file (will be created)"
        return 0
    fi
    
    # Check file is not empty
    if [[ ! -s "$plan_file" ]]; then
        if [[ "$severity" == "error" ]]; then
            log_error "Execution plan is empty: $plan_file"
        else
            log_warning "Execution plan is empty: $plan_file"
        fi
        return 1
    fi
    
    # Count checkbox items (Single pass optimization)
    local total_checkboxes=0 unchecked_boxes=0 checked_boxes=0
    
    # Use awk to count in one pass
    eval "$(awk '/^\s*[-*+]\s+\[[ x]\]/ { 
        total++; 
        if ($0 ~ /\[x\]/) checked++; 
        else unchecked++; 
    } 
    END { 
        print "total_checkboxes=" total+0 "; checked_boxes=" checked+0 "; unchecked_boxes=" unchecked+0 
    }' "$plan_file")"
    
    if [[ $total_checkboxes -eq 0 ]]; then
        if [[ "$severity" == "error" ]]; then
            log_error "Execution plan has no checkbox items: $plan_file"
        else
            log_warning "Execution plan has no checkbox items: $plan_file"
        fi
        log_info "Expected format: '- [ ] Task description' or '- [x] Completed task'"
        return 1
    fi
    
    # Calculate completion percentage
    local completion_pct=0
    if [[ $total_checkboxes -gt 0 ]]; then
        completion_pct=$((checked_boxes * 100 / total_checkboxes))
    fi
    
    log_debug "Execution plan: $total_checkboxes tasks ($checked_boxes completed, $unchecked_boxes pending) - ${completion_pct}% complete"
    
    # Warn if no progress
    if [[ $checked_boxes -eq 0 ]] && [[ $total_checkboxes -gt 0 ]]; then
        log_info "Execution plan has $total_checkboxes tasks, none completed yet"
    fi
    
    # Warn if everything is checked (might need new tasks)
    if [[ $checked_boxes -eq $total_checkboxes ]] && [[ $total_checkboxes -gt 0 ]]; then
        log_info "All tasks completed! Consider updating plan with new objectives."
    fi
    
    log_success "Execution plan validation passed: $plan_file (${completion_pct}% complete)"
    return 0
}

#######################################
# Validate all artifacts and generate report
# Returns: Detailed validation report as string
#######################################
generate_validation_report() {
    local report=""
    report+="=== Ralph Artifact Validation Report ===\n"
    report+="Generated: $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    
    # PRD validation
    report+="[PRD] Product Requirements Document:\n"
    if [[ -f "${PRD_FILE:-prd.json}" ]]; then
        if validate_prd >/dev/null 2>&1; then
            report+="  ✓ Valid JSON structure\n"
        else
            report+="  ✗ Invalid or malformed JSON\n"
        fi
    else
        report+="  - Not found (will be created)\n"
    fi
    
    # Architecture diagram validation
    report+="\n[ARCH] Architecture Diagram:\n"
    if [[ -f "${DIAGRAM_FILE:-ralph_architecture.md}" ]]; then
        if validate_architecture_diagram "warn" >/dev/null 2>&1; then
            report+="  ✓ Valid Mermaid syntax detected\n"
        else
            report+="  ⚠ Missing or invalid Mermaid syntax\n"
        fi
    else
        report+="  - Not found (will be created)\n"
    fi
    
    # Execution plan validation
    report+="\n[PLAN] Execution Plan:\n"
    if [[ -f "${PLAN_FILE:-ralph_plan.md}" ]]; then
        local plan_file="${PLAN_FILE:-ralph_plan.md}"
        local total checked unchecked pct
        
        # Single pass count using awk
        eval "$(awk '
            /^\s*[-*+]\s+\[([ x])\]/ {
                total++
                if (/\[x\]/) checked++
                else unchecked++
            }
            END {
                print "total=" total+0 "; checked=" checked+0 "; unchecked=" unchecked+0
            }
        ' "$plan_file")"
        
        if [[ $total -gt 0 ]]; then
            pct=$((checked * 100 / total))
            report+="  ✓ Valid checklist format\n"
            report+="  Tasks: $total total ($checked done, $unchecked pending)\n"
            report+="  Progress: ${pct}%\n"
        else
            report+="  ⚠ No checkbox items found\n"
        fi
    else
        report+="  - Not found (will be created)\n"
    fi
    
    echo -e "$report"
}

#######################################
# Perform runtime verification of services
# Identifies services and runs liveness probes
# Returns: Error string if verification fails
#######################################
verify_runtime() {
    local errors=""
    local project_dir="${PROJECT_DIR:-.}"
    
    log_debug "Starting runtime verification..."
    
    # 1. Identify and verify Rust services
    if [[ -f "$project_dir/Cargo.toml" ]]; then
        log_info "Verifying Rust project..."
        if ! cargo check >/dev/null 2>&1; then
            errors+=$'\n'"- Rust build check failed ('cargo check')."
        fi
    fi
    
    # 2. Identify and verify Node.js services
    if [[ -f "$project_dir/package.json" ]]; then
        log_info "Verifying Node.js project..."
        if [[ ! -d "$project_dir/node_modules" ]]; then
            log_warning "node_modules missing, attempt to check package.json validity..."
            if ! jq empty "$project_dir/package.json" >/dev/null 2>&1; then
                errors+=$'\n'"- Invalid package.json format."
            fi
        fi
    fi

    # 3. Identify and verify Python services
    if [[ -f "$project_dir/requirements.txt" ]] || [[ -f "$project_dir/pyproject.toml" ]]; then
        log_info "Verifying Python project..."
        if command_exists ruff; then
            if ! ruff check . >/dev/null 2>&1; then
                errors+=$'\n'"- Python linting failed ('ruff check')."
            fi
        else
            if heal_test_environment "ruff"; then
                if ! ruff check . >/dev/null 2>&1; then
                    errors+=$'\n'"- Python linting failed ('ruff check')."
                fi
            else
                errors+=$'\n'"- Missing 'ruff' for Python linting."
            fi
        fi
    fi

    # 4. Identify and verify Go services
    if [[ -f "$project_dir/go.mod" ]]; then
        log_info "Verifying Go project..."
        if ! go vet ./... >/dev/null 2>&1; then
            errors+=$'\n'"- Go validation failed ('go vet')."
        fi
    fi
    
    # 5. Liveness Probe (Port scanning & Health checks)
    # Checks common dev ports
    local ports=()
    IFS=$' \t\n,' read -r -a ports <<< "${RALPH_HEALTH_PORTS:-8080 3000 5000 8000 8443 4000 5173 3001 8888}" || true
    for port in ${ports[@]+"${ports[@]}"}; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue   # ignore junk tokens from RALPH_HEALTH_PORTS
        if command_exists ss; then
            if ss -tuln | grep -q ":$port "; then
                log_success "Service detected on port $port"
                
                # Dynamic Health Check
                if command_exists curl; then
                    # Try common health endpoints across all identified ports
                    for ep in "/health" "/api/hello" "/api/v1/status" "/"; do
                        local url="http://localhost:$port$ep"
                        local code
                        code=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
                        if [[ "$code" == "200" ]]; then
                            log_success "Health check passed: $url"
                            
                            # Trigger Benchmarking if port is 8080 (Primary API)
                            if [[ "$port" == "8080" ]]; then
                                local bench_result
                                bench_result=$(run_mini_bench "$url" 5)
                                if [[ "$bench_result" == *"<performance_alert>"* ]]; then
                                    errors+=$'\n'"$bench_result"
                                fi
                            fi
                            # Trigger Visual Audit if port is 3000 (Frontend)
                            if [[ "$port" == "3000" ]]; then
                                local visual_report
                                visual_report=$(verify_ui_visual "$url")
                                if [[ -n "$visual_report" ]]; then
                                    errors+=$'\n'"$visual_report"
                                fi
                            fi
                            break
                        fi
                    done
                fi
            fi
        fi
    done
    
    if [[ -n "$errors" ]]; then
        echo "<runtime_error>$errors</runtime_error>"
    fi
}

#######################################
# Formally verify architecture diagram matches file tree
# Returns: Warning string if discrepancies found
#######################################
verify_architecture() {
    local diagram_file="${DIAGRAM_FILE:-ralph_architecture.md}"
    if [[ ! -f "$diagram_file" ]]; then return 0; fi
    
    log_debug "Performing architectural verification..."
    
    # Extract potential filenames from Mermaid nodes (e.g., [main.rs] or {app.tsx})
    local nodes
    nodes=$(grep -oE '[a-zA-Z0-9_/-]+\.(rs|ts|tsx|py|go|js|json|sql|md)' "$diagram_file" | sort -u)
    
    local missing=()
    for node in $nodes; do
        if [[ ! -f "$node" ]]; then
            # Check if it's a directory
            if [[ ! -d "$node" ]]; then
                missing+=("$node")
            fi
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "<architecture_drift>Warning: The following components in your diagram do not exist on disk: ${missing[*]}. Please align your diagram with reality.</architecture_drift>"
    fi
}

#######################################
# Genetic Memory Library for Ralph
# Persists engineering lessons across different project runs
#######################################

MEMORY_DIR="${HOME}/.config/ralph/memory"
GLOBAL_MEMORY_FILE="${MEMORY_DIR}/global.json"

#######################################
# Initialize Memory storage
#######################################
init_memory() {
    if [[ ! -d "$MEMORY_DIR" ]]; then
        mkdir -p "$MEMORY_DIR"
    fi
    
    if [[ ! -f "$GLOBAL_MEMORY_FILE" ]]; then
        echo "{\"lessons\": []}" > "$GLOBAL_MEMORY_FILE"
    fi
}

#######################################
# Retrieve relevant lessons for the current project
# Returns: Formatted string of lessons
#######################################
recall_lessons() {
    if [[ ! -f "$GLOBAL_MEMORY_FILE" ]] || ! command_exists jq; then
        return 0
    fi
    
    # Get last 5 lessons
    local lessons
    lessons=$(jq -r '.lessons | last(5) | .[] | "- " + .' "$GLOBAL_MEMORY_FILE" 2>/dev/null)
    
    if [[ -n "$lessons" ]]; then
        echo -e "\n<genetic_memory>\nHistorical lessons from previous projects:\n$lessons\n</genetic_memory>"
    fi
}

#######################################
# Store a new lesson in global memory
# Arguments:
#   $1 - Lesson text
#######################################
store_lesson() {
    local lesson="$1"
    [[ -z "$lesson" ]] && return 0
    
    if command_exists jq; then
        local tmp
        tmp=$(mktemp)
        jq --arg msg "$lesson" '.lessons += [$msg] | .lessons = .lessons[-50:]' "$GLOBAL_MEMORY_FILE" > "$tmp" && mv "$tmp" "$GLOBAL_MEMORY_FILE"
        log_debug "Stored new genetic lesson: $lesson"
        
        # Suggest to agent to save to virtual memory if in high-verbosity mode
        echo -e "\n[VIRTUAL MEMORY] Please remember this lesson: $lesson" >> "${LOG_FILE:-/dev/null}"
    fi
}

#######################################
# High-Integrity Task Engine for Ralph
# Integrated with Beads (bd) CLI
#######################################

# Detect bd binary
BD_BIN=$(command -v bd || echo "$HOME/go/bin/bd")
export BD_BIN

# Detect if dolt is available
DOLT_BIN=$(command -v dolt || true)

#######################################
# Beads CLI wrapper that ALWAYS targets Ralph's task DB.
# init_task_engine creates the DB at a non-default path (.ralph/beads/tasks.db),
# so every operation must pass --db or bd looks in the wrong place and silently
# reports an empty/incorrect database. Centralizing it keeps all call sites correct.
# Arguments: $@ - bd subcommand and args
#######################################
_bd() {
    "$BD_BIN" --db "${_RALPH_DIR:-.ralph}/beads/tasks.db" "$@"
}

#######################################
# Initialize Task Database
#######################################
init_task_engine() {
    local beads_dir="${_RALPH_DIR:-.ralph}/beads"
    if [[ ! -d "$beads_dir" ]]; then
        mkdir -p "$beads_dir"
        
        # Determine backend: prefer Dolt if available
        local backend="sqlite"
        if [[ -n "$DOLT_BIN" ]]; then
            backend="dolt"
            log_info "Dolt detected. Initializing Beads with Dolt backend for Time-Travel support."
        fi

        # Ensure we are in a git repo or at least init beads
        if ! "$BD_BIN" --db "$beads_dir/tasks.db" info >/dev/null 2>&1; then
            "$BD_BIN" init --prefix tk --db-type "$backend" --db "$beads_dir/tasks.db"
            log_debug "Beads Task Engine ($backend) initialized at $beads_dir."
        fi
    fi
}

#######################################
# Commit Task State (Time-Travel)
# Arguments:
#   $1 - Commit message
#######################################
commit_task_state() {
    local msg="${1:-Agent iteration sync}"
    
    # Check if we are using Dolt backend
    if _bd info 2>/dev/null | grep -q "Backend: dolt"; then
        log_debug "Committing task state to Dolt..."
        _bd vc commit -m "$msg"
    fi
}

#######################################
# Create a High-Integrity Task
# Arguments:
#   $1 - Title
#   $2 - Description
#   $3 - Dependencies (comma-separated IDs)
#   $4 - Assigned To
#######################################
hi_create_task() {
    local title="$1"
    local desc="$2"
    local deps="${3:-}"
    local assignee="${4:-}"
    
    local cmd=(_bd create "$title" -d "$desc" --silent)
    
    # Handle dependencies (ensure they are comma-separated for bd)
    if [[ -n "$deps" ]]; then
        cmd+=(--deps "$deps")
    fi
    
    if [[ -n "$assignee" && "$assignee" != "null" ]]; then
        cmd+=(--assignee "$assignee")
    fi
    
    local task_id
    task_id=$("${cmd[@]}")
    
    emit_event "task_created" "{\"id\": \"$task_id\", \"title\": \"$title\"}"
    echo "$task_id"
}

#######################################
# Close a Task
# Arguments:
#   $1 - Task ID
#######################################
hi_close_task() {
    local task_id="$1"
    _bd close "$task_id"
    emit_event "task_closed" "{\"id\": \"$task_id\"}"
}

#######################################
# Get "Ready" Tasks (Unblocked)
#######################################
get_ready_tasks() {
    # Show unblocked open tasks
    _bd ready --unassigned --limit 10
}

#######################################
# Verify All Tasks are Complete
# Returns: 0 if all tasks are closed, 1 if incomplete tasks remain
#######################################
verify_beads_complete() {
    # If beads directory doesn't exist, assume complete
    local beads_dir="${_RALPH_DIR:-.ralph}/beads"
    if [[ ! -d "$beads_dir" ]]; then
        return 0
    fi
    
    local open_count in_progress_count blocked_count
    open_count=$(_bd count --status open --quiet)
    in_progress_count=$(_bd count --status in_progress --quiet)
    blocked_count=$(_bd count --status blocked --quiet)
    
    local total_incomplete=$((open_count + in_progress_count + blocked_count))
    
    if [[ $total_incomplete -eq 0 ]]; then
        return 0
    else
        log_warning "Found $total_incomplete incomplete Beads tasks"
        return 1
    fi
}

#######################################
# Sync Task DB to ralph_plan.md (Human-Readable)
#######################################
sync_plan_file() {
    local plan_file="${PLAN_FILE:-ralph_plan.md}"
    
    {
        echo "# Ralph High-Integrity Execution Plan"
        echo "Generated: $(date)"
        echo ""
        echo "## Ready Tasks (Unblocked)"
        _bd ready --pretty
        
        echo ""
        echo "## All Open Tasks"
        _bd list --status open --pretty
        
        echo ""
        echo "## Recently Closed"
        _bd list --status closed --limit 5 --pretty
    } > "$plan_file"
}

#######################################
# Recommend a lazy-streak threshold from historical metrics.
# Stall-heavy history -> intervene sooner (2); rarely-stalling -> give more room (3).
# Arguments:
#   $1 - Metrics file (JSONL)
# Returns: recommended integer threshold on stdout
#######################################
_recommend_lazy_threshold() {
    local metrics="$1"
    local default_threshold=2

    if [[ ! -f "$metrics" ]] || ! command_exists jq; then
        echo "$default_threshold"
        return 0
    fi

    # Bound to a recent window (streamed via tail, so the whole history file is not
    # loaded into memory) so stale history can't asymptotically freeze the signal.
    local window=200
    local total stalls
    total=$(tail -n "$window" "$metrics" 2>/dev/null | jq -s 'length' 2>/dev/null || echo 0)
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    if [[ "$total" -eq 0 ]]; then
        echo "$default_threshold"
        return 0
    fi

    stalls=$(tail -n "$window" "$metrics" 2>/dev/null | jq -s '[.[] | select((.lazy_streak // 0) > 0)] | length' 2>/dev/null || echo 0)
    [[ "$stalls" =~ ^[0-9]+$ ]] || stalls=0

    local pct=$(( stalls * 100 / total ))
    if [[ $pct -ge 50 ]]; then
        echo 2          # frequently stuck -> reflexion should trigger sooner
    elif [[ $pct -le 20 ]]; then
        echo 3          # rarely stuck -> give the agent more room before nagging
    else
        echo "$default_threshold"
    fi
}

#######################################
# Review the run: derive a tuning recommendation from metrics history and persist
# it to tuning.json (consumed by load_tuning on the next run). Closes the
# write-only-metrics feedback gap.
# Returns: 0
#######################################
review_run() {
    local metrics="${METRICS_FILE:-${STATE_DIR:-.ralph/state}/metrics.json}"
    local state_dir="${STATE_DIR:-.ralph/state}"

    if ! command_exists jq; then
        log_warning "jq unavailable; skipping run review"
        return 0
    fi

    # Compounding-layer housekeeping: archive stale/resolved signals + stale skills.
    # (No LOG write here — review_run is also the body of `ralph --review` and runs
    # every --once tick, and a read-only review must not mutate the run narrative.)
    prune_signals || true
    declare -F prune_skills >/dev/null && prune_skills || true
    # Refresh the signal co-occurrence graph (.related links) from shared run history.
    declare -F link_related_signals >/dev/null && link_related_signals || true

    # Curator pass: surface a one-line knowledge-hygiene summary (gaps / orphaned /
    # stale / approval-backlog / high-severity). Read-only; full report via `ralph lint`.
    if declare -F lint_knowledge >/dev/null; then
        log_info "$(lint_knowledge quiet)"
    fi

    if [[ ! -f "$metrics" ]]; then
        log_info "No metrics history to review yet"
        return 0
    fi

    local window=200
    local total stalls pct threshold
    total=$(tail -n "$window" "$metrics" 2>/dev/null | jq -s 'length' 2>/dev/null || echo 0)
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    if [[ "$total" -eq 0 ]]; then
        log_info "No metric samples to review"
        return 0
    fi

    stalls=$(tail -n "$window" "$metrics" 2>/dev/null | jq -s '[.[] | select((.lazy_streak // 0) > 0)] | length' 2>/dev/null || echo 0)
    [[ "$stalls" =~ ^[0-9]+$ ]] || stalls=0
    pct=$(( stalls * 100 / total ))
    threshold=$(_recommend_lazy_threshold "$metrics")

    if write_tuning "$state_dir" "$threshold" "$pct" "$total"; then
        log_success "Review: $total samples, ${pct}% stalled -> lazy_threshold=$threshold (saved to tuning.json)"
    else
        log_warning "Review computed lazy_threshold=$threshold but could not persist tuning.json"
    fi
    return 0
}

#######################################
# True only once the task backlog is provably drained: at least one task closed
# AND nothing open/in-progress/blocked. Stricter than verify_beads_complete so it
# never fires at bootstrap (when no tasks exist yet).
# Returns: 0 if drained, 1 otherwise
#######################################
backlog_drained() {
    local beads_dir="${_RALPH_DIR:-.ralph}/beads"
    [[ -d "$beads_dir" ]] || return 1
    { [[ -x "$BD_BIN" ]] || command -v "$BD_BIN" >/dev/null 2>&1; } || return 1

    local open inprog blocked closed
    open=$(_bd count --status open --quiet 2>/dev/null || echo 0)
    inprog=$(_bd count --status in_progress --quiet 2>/dev/null || echo 0)
    blocked=$(_bd count --status blocked --quiet 2>/dev/null || echo 0)
    closed=$(_bd count --status closed --quiet 2>/dev/null || echo 0)
    [[ "$open" =~ ^[0-9]+$ ]] || open=0
    [[ "$inprog" =~ ^[0-9]+$ ]] || inprog=0
    [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
    [[ "$closed" =~ ^[0-9]+$ ]] || closed=0

    [[ "$closed" -gt 0 && $(( open + inprog + blocked )) -eq 0 ]]
}


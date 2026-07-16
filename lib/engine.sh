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
        BEGIN{ n=split(tolower(kws),a,"|") }   # split the constant keyword list once, not per line
        { line=$0
          if (line ~ /^[[:space:]]*$/) next
          vs=line; gsub(/[0-9]+[bB]/,"",vs)   # drop param-count tokens (70B/120b) so they cannot pose as a version
          ver=0; if (match(vs, /[0-9]+(\.[0-9]+)?/)) ver=substr(vs,RSTART,RLENGTH)+0
          rank=0; ll=tolower(line)
          for(i=1;i<=n;i++){ if(ll ~ ("(^|[^a-z])" a[i] "([^a-z]|$)")){ r=n-i+1; if(r>rank) rank=r } }
          if(rank==0) next
          score=ver*1000+rank
          if(best=="" || score>bestscore){ bestscore=score; best=line } }
        END{ if(best!="") print best }'
}


_ollama_base_url() {
    local base="${OLLAMA_BASE_URL:-${OLLAMA_HOST:-http://127.0.0.1:11434}}"
    base="${base%/}"; base="${base%/v1}"
    printf '%s\n' "$base"
}

ollama_model_list() {
    local base; base=$(_ollama_base_url)
    curl -fsS "$base/api/tags" 2>/dev/null | jq -r '.models[]? | "\(.name)\t\(.size // 0)"' 2>/dev/null || true
}

# Pick an Ollama model from "name<TAB>size_bytes" lines. Dynamic, local, and pure.
# RALPH_OLLAMA_MAX_BYTES can cap selection for constrained laptops.
_pick_ollama_model() {
    local role="$1" list="$2" max_bytes="${RALPH_OLLAMA_MAX_BYTES:-0}"
    [[ -n "$list" ]] || return 0
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=0
    printf '%s\n' "$list" | awk -v role="$role" -v max="$max_bytes" '
        BEGIN{ best=""; bestscore=-999999 }
        /^[[:space:]]*$/ { next }
        {
          name=$1; size=0
          if (NF>=2 && $2 ~ /^[0-9]+$/) size=$2+0
          if (max > 0 && size > max) next
          lname=tolower(name)
          score=0
          if (lname ~ /(coder|code|deepseek|qwen|starcoder|devstral)/) score += 5000
          if (lname ~ /(llama|gemma|mistral|phi)/) score += 2500
          if (lname ~ /(instruct|chat)/) score += 800
          if (role ~ /planner|thinker/ && lname ~ /(reason|thinking|pro|qwen3)/) score += 1500
          if (role ~ /tester/ && lname ~ /(mini|small|0\.5b|0\.6b|1b|1\.5b)/) score += 2000
          if (role !~ /tester/) score += int(size / 10000000)
          else score -= int(size / 10000000)
          clean=lname; gsub(/[0-9]+[bB]/, "", clean)
          if (match(clean, /[0-9]+(\.[0-9]+)?/)) score += int(substr(clean, RSTART, RLENGTH) * 100)
          if (best == "" || score > bestscore) { best=name; bestscore=score }
        }
        END{ if(best!="") print best }'
}

resolve_ollama_model_for_role() {
    local role="${1:-engineer}" list picked
    if [[ -n "${RALPH_LOCAL_MODEL:-}" ]]; then printf '%s\n' "$RALPH_LOCAL_MODEL"; return 0; fi
    list=$(ollama_model_list)
    picked=$(_pick_ollama_model "$role" "$list")
    [[ -n "$picked" ]] && { printf '%s\n' "$picked"; return 0; }
    printf '%s\n' "${RALPH_OLLAMA_DEFAULT_MODEL:-qwen3:0.6b}"
}

#######################################
# Resolve a model for the active tool + role, preferring each tool's OWN live source
# over any pinned string (gemini CLI is deprecated; agy/Antigravity is Google's CLI).
#   agy       -> `agy models` then newest-for-role (empty => agy auto-selects latest)
#   claude/amp-> tier alias (opus|sonnet) which resolves to the latest server-side
#   opencode  -> existing dynamic opencode-models router
#   ollama    -> local Ollama chat model from /api/tags
#   ollama-agent -> local Ollama coding agent model from /api/tags
# Arguments: $1 tool (default $TOOL), $2 role (default engineer)
#######################################
resolve_model_for_tool() {
    local tool="${1:-${TOOL:-opencode}}" role="${2:-engineer}"
    case "$tool" in
        agy)
            local list; list=$(agy models 2>/dev/null) || list=""
            _pick_latest_model "$role" "$list"
            ;;
        claude)
            case "$role" in planner|thinker) echo "opus" ;; *) echo "sonnet" ;; esac
            ;;
        amp|codex|jules|jules-cli)
            echo ""   # no usable --model in our invocation -> they self-select (don't fabricate one)
            ;;
        ollama|ollama-agent)
            resolve_ollama_model_for_role "$role"
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

    # Honor any user-set model (CLI flag, ralph.json, .ralphrc, or SELECTED_MODEL env) —
    # anything NOT auto-resolved. Auto picks carry source="auto" so they re-resolve each
    # call (the tool/role may change); user picks persist.
    if [[ -n "${SELECTED_MODEL:-}" && "${SELECTED_MODEL_SOURCE:-}" != "auto" ]]; then
        log_debug "Using ${SELECTED_MODEL_SOURCE:-user}-specified model: $SELECTED_MODEL"
        return 0
    fi

    local auto_selected_model
    auto_selected_model=$(resolve_model_for_tool "${TOOL:-opencode}" "$current_role")

    SELECTED_MODEL="$auto_selected_model"
    SELECTED_MODEL_SOURCE="auto"
    export SELECTED_MODEL SELECTED_MODEL_SOURCE

    log_debug "Model routed for role '$current_role': $SELECTED_MODEL"
    return 0
}

#######################################
# SMART MODEL MANAGEMENT — fallback chain + capacity-failure classification + graceful
# degradation. All opt-in: with no config the chain has one model, so behaviour is unchanged.
#######################################

# Classify a FAILED tool run from its captured output + exit code, so we only fall back on
# transient/capacity issues (rate limit, overload, token/credit exhaustion, timeout) and do
# NOT burn the chain on auth or generic bugs.
# Echoes: rate_limit | overloaded | quota | auth | timeout | other
classify_tool_failure() {
    local out="$1" rc="${2:-1}" lc
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1   # guard the arithmetic below against a non-numeric exit code
    # Deterministic process exit/signal codes take precedence over text (providers reword their
    # messages; exit codes don't). A process killed by signal N exits with code 128+N; we map by
    # the signal's SEMANTICS (ref: WomB0ComB0/bash-testing process-signal signal table):
    #   SIGKILL(9) / SIGXCPU(24, CPU-time limit) / SIGXFSZ(25, file-size limit) -> resource/capacity
    #     (our `timeout --kill-after`, the OOM-killer, or a cgroup/ulimit cap) -> treat like a
    #     timeout and fall back to a lighter model.
    #   SIGINT(2) / SIGQUIT(3) / SIGTERM(15) -> user/external stop -> do NOT fall back.
    #   crashes (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE) -> a tool bug, not model-specific -> don't fall back.
    if (( rc > 128 && rc < 160 )); then
        case "$(( rc - 128 ))" in
            9|24|25) echo timeout; return 0 ;;
            *)       echo other;   return 0 ;;
        esac
    fi
    case "$rc" in
        124)     echo timeout; return 0 ;;   # GNU `timeout`'s own "timed out" exit code
        126|127) echo other;   return 0 ;;   # not executable / command not found -> no model helps
    esac
    lc="${out,,}"   # Bash 4 native lowercase
    case "$lc" in
        # quota / credit / billing exhaustion + context-window overflow ("running out of tokens").
        # Checked BEFORE rate_limit because OpenAI returns insufficient_quota WITH HTTP 429 — the
        # billing label is the accurate one. — OpenAI insufficient_quota / "exceeded your current
        # quota ... billing", OpenRouter 402 "Insufficient credits"/"negative credit balance",
        # context_length_exceeded. (Both quota and rate_limit fall back; this only sharpens the log.)
        *quota*|*"402"*|*"insufficient credit"*|*"payment required"*|*"out of credit"*|*"negative credit"*|*"exceeded your current"*|*"check your plan"*|*billing*|*"context length"*|*"context window"*|*"maximum context"*|*"token limit"*|*"too long"*) echo quota ;;
        # rate limit — Anthropic rate_limit_error (429), OpenAI RateLimitError / "Too Many
        # Requests", Google RESOURCE_EXHAUSTED (429), OpenRouter "rate limited".
        *"rate limit"*|*rate_limit*|*ratelimit*|*"429"*|*"too many requests"*|*resource_exhausted*) echo rate_limit ;;
        # provider/model overloaded or temporarily unavailable — Anthropic 529 overloaded_error
        # / "Overloaded", Google 503 UNAVAILABLE / "model is overloaded" / "high demand",
        # OpenAI "The server is overloaded" (503). Capacity codes only (graceful: just falls back).
        *overloaded*|*"529"*|*"503"*|*unavailable*|*"server is busy"*|*"at capacity"*|*"high demand"*) echo overloaded ;;
        # auth — Anthropic authentication_error/permission_error, Google PERMISSION_DENIED/
        # UNAUTHENTICATED, OpenAI invalid_api_key. TEXT only (a false match here STOPS the chain).
        *unauthorized*|*authentication*|*"invalid api key"*|*"api key not valid"*|*"missing bearer"*|*forbidden*|*permission_denied*|*"permission denied"*|*permission_error*|*unauthenticated*) echo auth ;;
        *) echo other ;;
    esac
}

# A local model to prefer when no model is pinned — "use local unless specified". Only
# opencode can route to a local provider. Honours RALPH_LOCAL_MODEL, else auto-detects Ollama.
# RALPH_PREFER_LOCAL=0/false/no disables it. Echoes the model id; returns 1 if none.
preferred_local_model() {
    local tool="$1" m pref="${RALPH_PREFER_LOCAL:-auto}"
    case "$pref" in 0|false|no|off) return 1 ;; esac
    [[ "$tool" == "opencode" ]] || return 1
    # An explicit local model wins (this is how you say "use local unless specified").
    if [[ -n "${RALPH_LOCAL_MODEL:-}" ]]; then printf '%s\n' "$RALPH_LOCAL_MODEL"; return 0; fi
    # Auto-detecting Ollama is OPT-IN (RALPH_PREFER_LOCAL=1/true/yes/on) so a host that merely
    # has Ollama installed isn't silently switched off its cloud default — default stays unchanged.
    case "$pref" in
        1|true|yes|on)
            if command_exists ollama; then
                m=$(ollama list 2>/dev/null | awk 'NR==2{print $1}')   # first locally-pulled model
                # Only trust a real model-id token (daemon down / errors can emit junk).
                [[ "$m" =~ ^[A-Za-z0-9._:/-]+$ ]] && { printf 'ollama/%s\n' "$m"; return 0; }
            fi ;;
    esac
    return 1
}

# Ordered model candidates to try this iteration: [primary] + RALPH_MODEL_FALLBACKS.
# primary = a user-pinned model (wins) -> else a preferred local model -> else the tool's
# auto pick. Empty/whitespace entries and consecutive duplicates are dropped.
build_model_chain() {
    local tool="$1" role="${2:-engineer}" primary lm
    local -a chain=() fbs=()
    if [[ -n "${SELECTED_MODEL:-}" && "${SELECTED_MODEL_SOURCE:-}" != "auto" ]]; then
        primary="$SELECTED_MODEL"
    elif lm=$(preferred_local_model "$tool"); then
        primary="$lm"
    else
        # Avoid a set -e abort if the router exits non-zero (we run inside a < <() subshell).
        primary="${SELECTED_MODEL:-}"
        [[ -z "$primary" ]] && primary=$(resolve_model_for_tool "$tool" "$role" 2>/dev/null || true)
    fi
    chain+=("$primary")
    if [[ -n "${RALPH_MODEL_FALLBACKS:-}" ]]; then
        local _oifs="$IFS"; IFS=','; read -ra fbs <<< "$RALPH_MODEL_FALLBACKS"; IFS="$_oifs"
        chain+=("${fbs[@]+"${fbs[@]}"}")
    fi
    local c prev="__none__"
    for c in "${chain[@]}"; do
        c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"   # trim
        [[ -z "$c" ]] && continue        # drop empties (e.g. a trailing comma in fallbacks)
        [[ "$c" == "$prev" ]] && continue # drop consecutive duplicates
        printf '%s\n' "$c"; prev="$c"
    done
    # NB: a fully-empty result (self-selecting tools like agy/codex/amp) is intentional —
    # run_ai_with_fallback falls back to a single self-select run in that case.
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
        ollama|ollama-agent)
            [[ -n "$model" ]] || model="$(resolve_ollama_model_for_role "${RALPH_ROLE:-engineer}")"
            if ! command_exists curl || ! command_exists jq; then
                log_error "ollama tool requires curl and jq"
                return 1
            fi
            local base tags
            base="${OLLAMA_BASE_URL:-${OLLAMA_HOST:-http://127.0.0.1:11434}}"
            base="${base%/}"; base="${base%/v1}"
            tags=$(curl -fsS "$base/api/tags" 2>/dev/null | jq -r '.models[]?.name' 2>/dev/null || true)
            if echo "$tags" | grep -qxF "$model"; then
                log_debug "Ollama model validated: $model"
                return 0
            fi
            log_warning "Ollama model not found locally: $model"
            return 1
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
#   $10 - Quality rubric context
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
    local quality_context="${10:-No quality rubric loaded.}"
    local project_instructions="${11:-}"

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
4. **Judge:** Compare the current output against QUALITY.md and decide whether to improve, defer, or stop.
5. **Anticipate:** Identify potential side effects or breaking changes to the architecture.
</cognitive_process>

<capabilities>
1. **Full-Stack Engineering:** Expert in modern software delivery and best practices.
2. **Architectural Visualization:** Use Mermaid syntax in '${DIAGRAM_FILE:-ralph_architecture.md}' to model system state, data flow, and dependencies.
3. **Requirement Engineering:** Maintain '${PRD_FILE:-prd.json}' (JSON) to define goals, user stories, and success metrics.
4. **Quality Judging:** Maintain '${QUALITY_FILE:-QUALITY.md}' as the reviewer/stopper rubric. Use it to decide whether another iteration is valuable or whether the work is professionally complete within scope.
5. **Time-Travel Task Memory (Beads + Dolt):** Use 'bd' CLI for reliable, dependency-aware task tracking with full version history.
   - Create task: \`bd create "Title" -d "Description" [--deps "id1,id2"]\`
   - List ready tasks: \`bd ready\`
   - **Time-Travel:** You can view previous task states if needed using \`bd vc log\`.
6. **Intelligent Model Routing:** Your requests are automatically routed to specialized models based on your current role:
   - **Planner/Thinker:** Routed to high-reasoning models (Gemini 2.0 Pro/Thinking).
   - **Engineer/Tester:** Routed to high-speed implementation models (Gemini 2.0 Flash).
7. **Self-Healing Tooling:** If a required test runner or dependency (e.g., pytest, npm, cargo) is missing, you can attempt to autonomously install it using \`ralph setup\`.
8. **Swarm Orchestration:** You can act as a Team Leader or Specialist.
   - Spawn sub-agents: \`ralph swarm spawn --role "RoleName" --task "Task description"\`
   - Send messages: \`ralph swarm msg --to <agent_id> --content "Message"\`
9. **Long-Term Memory:** To persist a durable, cross-project lesson (an engineering pattern, architectural decision, or "lesson learned"), emit a line \`<memory>the lesson in one sentence</memory>\` in your response. Ralph captures these into long-term memory (surfaced as \`<genetic_memory>\` in future runs). Use sparingly — only genuinely reusable lessons, not per-task notes.
</capabilities>

<workflow>
1. **Initialize:** If missing, create internal artifacts in '$ARTIFACT_DIR' and initialize beads with 'bd init'.
2. **Align:** Ensure code changes align with Architecture ('$DIAGRAM_FILE') and Requirements ('$PRD_FILE').
3. **Execute:** Perform the next unblocked task from 'bd ready'. Close it with 'bd close' when done.
4. **Verify:** Write and run tests for every implementation. Never assume code works.
5. **Judge:** Update '$QUALITY_FILE' with the current review, blocking issues, in-scope improvements, deferred follow-ups, and \`Quality Gate: continue|pass\`.
6. **Sync:** Reflect changes back into documentation files in '$ARTIFACT_DIR' as the system evolves.
</workflow>

<constraints>
- **Diagram First:** Update the architecture diagram BEFORE writing complex features.
- **Verification Mandatory:** Do not close a Beads task until you have executed a test that passes.
- **Valid Artifacts:** Ensure '$PRD_FILE' is valid JSON and '$DIAGRAM_FILE' is valid Mermaid.
- **No Loops:** If you are stuck in a cycle (repeatedly failing), STOP and ask for user intervention or try a radically different approach.
- **Quality Gate:** Keep \`Quality Gate: continue\` in '$QUALITY_FILE' while there are blocking issues or high-value in-scope improvements. Set \`Quality Gate: pass\` only when the stop policy in QUALITY.md is satisfied.
- **Scope Control:** Do not chase infinite polish. If an improvement is speculative, enterprise-only, or outside the requested tier, document it as follow-up instead of extending the task.
- **Termination:** Output <promise>COMPLETE</promise> only when ALL Beads tasks are CLOSED, docs are synced, verification passes, and '$QUALITY_FILE' says \`Quality Gate: pass\`.
</constraints>

<high_integrity_checklist>
Before finalizing your response, verify:
- [ ] Have I updated the Mermaid diagram to reflect architectural changes?
- [ ] Have I closed the relevant Beads task if the work is verified?
- [ ] Have I created follow-up tasks in Beads for discovered work?
- [ ] Have I updated QUALITY.md with a concrete reviewer judgment and stop decision?
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

<quality_rubric>
$quality_context
</quality_rubric>

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
4. Update QUALITY.md with the current judgment: blockers, in-scope improvements, follow-ups, and Quality Gate status.
5. Review the <high_integrity_checklist>.
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
#   ollama    curl local Ollama /api/chat via jq-encoded stdin prompt
#   ollama-agent python local coding-agent loop with guarded file/command tools
#   agy      --print --dangerously-skip-permissions  (Google Antigravity CLI; no --model flag)
# Arguments: $1 tool, $2 model
# Returns: 0 and sets _AI_CMD/_AI_STDIN; 1 for an unknown tool.
#######################################
# Per-call wall-clock budget in seconds for an AI tool (a hard backstop — no tool has a
# reliable built-in timeout and run_ai_tool otherwise waits on the PID forever).
# RALPH_TOOL_TIMEOUT overrides; 0 disables; non-numeric falls back to the default.
_ai_timeout_secs() {
    local d="${RALPH_TOOL_TIMEOUT:-1800}"
    [[ "$d" =~ ^[0-9]+$ ]] || d=1800
    echo "$d"
}

_ai_idle_timeout_secs() {
    local d="${RALPH_TOOL_IDLE_TIMEOUT:-180}"
    [[ "$d" =~ ^[0-9]+$ ]] || d=180
    echo "$d"
}

_ai_idle_min_runtime_secs() {
    local d="${RALPH_TOOL_IDLE_MIN_RUNTIME:-30}"
    [[ "$d" =~ ^[0-9]+$ ]] || d=30
    echo "$d"
}

_ai_idle_probe_interval_secs() {
    local d="${RALPH_TOOL_IDLE_PROBE_INTERVAL:-2}"
    [[ "$d" =~ ^[0-9]+$ && "$d" -gt 0 ]] || d=2
    echo "$d"
}

_file_size_bytes() {
    local file="$1"
    [[ -f "$file" ]] || { echo 0; return 0; }
    wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0
}

_ai_quiescence_verify_available() {
    [[ "${RALPH_TOOL_IDLE_REQUIRE_VERIFY:-1}" == "1" ]] || return 0
    local cmd
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        runtime_command_allowed "$cmd" && return 0
    done < <(collect_runtime_commands "${PROJECT_DIR:-.}" 2>/dev/null || true)
    return 1
}

_project_progress_fingerprint() {
    if declare -F compute_project_hash >/dev/null 2>&1; then
        compute_project_hash 2>/dev/null && return 0
    fi
    local project_dir="${PROJECT_DIR:-.}"
    # Portable, pruned fallback. `find -printf` is a GNU extension that fails silently on
    # macOS/BSD (yielding an empty, useless fingerprint), and an un-pruned walk over
    # node_modules/target/dist on every ~2s probe is very expensive. Prefer python3: it is
    # cross-platform, prunes heavy dirs, and hashes size+mtime so edits are detected. The
    # project path is passed as argv (not interpolated) so unusual paths can't break it.
    local fp
    if command -v python3 >/dev/null 2>&1; then
        fp=$(python3 - "$project_dir" <<'PY' 2>/dev/null
import hashlib, os, sys
root = sys.argv[1]
exclude = {".git", ".ralph", "node_modules", "target", "dist", "build",
           "venv", ".venv", ".cache", ".next", ".mypy_cache", ".pytest_cache", "__pycache__"}
entries = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in exclude]
    for name in filenames:
        p = os.path.join(dirpath, name)
        try:
            st = os.stat(p)
        except OSError:
            continue
        entries.append(f"{os.path.relpath(p, root)}\t{st.st_size}\t{int(st.st_mtime)}")
entries.sort()
print(hashlib.md5("\n".join(entries).encode("utf-8", "surrogatepass")).hexdigest())
PY
)
        if [[ -n "$fp" ]]; then
            printf '%s\n' "$fp"
            return 0
        fi
    fi
    # Last resort (no git hash, no python3): portable `find` without -printf, pruning the
    # heavy dirs. Tracks the file SET only (coarser than size+mtime), but never fails
    # silently the way -printf does on BSD.
    find "$project_dir" \
        \( -name .git -o -name .ralph -o -name node_modules -o -name target \
           -o -name dist -o -name build -o -name venv -o -name .venv \
           -o -name .cache -o -name __pycache__ \) -prune -o \
        -type f -print 2>/dev/null | LC_ALL=C sort | md5sum_wrapper | awk '{print $1}'
}

# Name of the available GNU timeout binary (macOS+Homebrew coreutils ships it as gtimeout).
# Echoes "timeout" | "gtimeout" | "" (none).
_timeout_bin() {
    if command_exists timeout; then echo timeout
    elif command_exists gtimeout; then echo gtimeout
    else echo ""; fi
}

_opencode_json_text_filter() {
    cat <<'JQ'
def chunks:
  if type == "string" then .
  elif type == "array" then .[] | chunks
  elif type == "object" then
    (.text? | chunks),
    (.content? | chunks),
    (.message? | chunks),
    (.delta? | chunks),
    (.part? | chunks)
  else empty end;
(fromjson? // empty) as $event
| select(((($event.role? // $event.message.role? // "") | tostring) != "user"))
| ($event.message? | chunks),
  ($event.assistant? | chunks),
  ($event.content? | chunks),
  ($event.text? | chunks),
  ($event.delta? | chunks),
  ($event.part? | chunks)
JQ
}

opencode_provider_state_file() {
    printf '%s\n' "${RUN_DIR:-${PROJECT_DIR:-.}/.ralph/runs/${RUN_ID:-manual}}/providers/opencode.json"
}

# Self-benchmarking: next small improvement is to map opencode terminal events into
# a provider-complete signal instead of relying only on process exit.
normalize_opencode_json_output() {
    local output_file="$1" log_file="${2:-/dev/null}" raw_file text_file state_file updated_at
    [[ "${RALPH_OPENCODE_JSON:-1}" == "1" ]] || return 0
    command_exists jq || return 0
    [[ -s "$output_file" ]] || return 0

    raw_file="${output_file}.opencode.jsonl"
    text_file="${output_file}.text"
    cp "$output_file" "$raw_file" 2>/dev/null || return 0

    if jq -Rr "$(_opencode_json_text_filter)" "$raw_file" > "$text_file" 2>/dev/null && [[ -s "$text_file" ]]; then
        cat "$text_file" > "$output_file"
    fi

    state_file=$(opencode_provider_state_file)
    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    jq -Rsc \
        --arg run_id "${RUN_ID:-manual}" \
        --arg updated_at "$updated_at" \
        '[split("\n")[] | select(length > 0) | fromjson?] as $events
         | {provider:"opencode",
            run_id:$run_id,
            updated_at:$updated_at,
            event_count:($events | length),
            sessions:([$events[] | (.sessionID? // .sessionId? // .session_id? // .session?.id?) | select(. != null)] | unique),
            terminal_events:([$events[] | (.type? // .event? // .status?) | select(. != null) | tostring | select(test("complete|completed|finish|finished|done|failed|error"; "i"))])}' \
        "$raw_file" > "$state_file.tmp" 2>/dev/null && mv "$state_file.tmp" "$state_file" 2>/dev/null || true

    printf 'opencode JSON events captured: %s\n' "$raw_file" >> "$log_file" 2>/dev/null || true
}

_kill_process_tree() {
    local sig="$1" pid="$2" child
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if command_exists pgrep; then
        while IFS= read -r child; do
            [[ -n "$child" ]] && _kill_process_tree "$sig" "$child"
        done < <(pgrep -P "$pid" 2>/dev/null || true)
    fi
    kill "-$sig" "$pid" 2>/dev/null || true
}

_build_ai_cmd() {
    local tool="$1" model="$2" resume="${3:-0}"
    _AI_CMD=(); _AI_STDIN=0
    # Opt-in session continuity: on iterations after the first, continue the tool's prior
    # conversation. Only claude/opencode/agy expose a SAFE headless resume (--continue);
    # codex resume needs the no-sandbox bypass and amp isn't verified, so both run fresh.
    case "$tool" in
        amp)
            _AI_CMD=(amp --dangerously-allow-all); _AI_STDIN=1 ;;
        claude)
            # --dangerously-skip-permissions already bypasses; --permission-mode bypassPermissions
            # was redundant. Add resilience: fall back to a cheaper tier on overload (skip if it
            # equals the primary) and an opt-in per-call spend cap.
            _AI_CMD=(claude -p --dangerously-skip-permissions)
            [[ -n "$model" ]] && _AI_CMD+=(--model "$model")   # empty -> claude uses its default
            [[ "$resume" == "1" ]] && _AI_CMD+=(--continue)
            local _fb="${RALPH_CLAUDE_FALLBACK_MODEL:-sonnet}"
            [[ -n "$_fb" && "$_fb" != "$model" ]] && _AI_CMD+=(--fallback-model "$_fb")
            [[ "${RALPH_MAX_BUDGET_USD:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && _AI_CMD+=(--max-budget-usd "$RALPH_MAX_BUDGET_USD")
            ;;
        opencode)
            _AI_CMD=(opencode run)
            [[ "${RALPH_OPENCODE_JSON:-1}" == "1" ]] && _AI_CMD+=(--format json)
            [[ -n "$model" ]] && _AI_CMD+=(--model "$model")   # empty -> let opencode self-select
            [[ "$resume" == "1" ]] && _AI_CMD+=(--continue) ;;
        # Self-benchmarking: Move Ollama API request payload construction to a separate helper function to improve testability and reduce bash inline complexity.
        ollama)
            local _omodel="${model:-$(resolve_ollama_model_for_role "${RALPH_ROLE:-engineer}")}"
            _AI_CMD=(env RALPH_OLLAMA_MODEL="$_omodel" bash -c '
                set -euo pipefail
                prompt=$(cat)
                base="${OLLAMA_BASE_URL:-${OLLAMA_HOST:-http://127.0.0.1:11434}}"
                base="${base%/}"; base="${base%/v1}"
                think="${RALPH_OLLAMA_THINK:-false}"
                case "$think" in true|false) ;; *) think=false ;; esac
                num="${RALPH_OLLAMA_NUM_PREDICT:-1024}"
                [[ "$num" =~ ^[0-9]+$ ]] || num=1024
                payload=$(jq -n \
                    --arg model "$RALPH_OLLAMA_MODEL" \
                    --arg prompt "$prompt" \
                    --argjson think "$think" \
                    --argjson num "$num" \
                    "{model:\$model,messages:[{role:\"user\",content:\$prompt}],stream:false,think:\$think,options:{num_predict:\$num,temperature:0}}")
                curl -fsS "$base/api/chat" -H "Content-Type: application/json" -d "$payload" |
                    jq -r ".message.content // .response // empty"
            ')
            _AI_STDIN=1 ;;
        ollama-agent)
            local _omodel="${model:-$(resolve_ollama_model_for_role "${RALPH_ROLE:-engineer}")}" _agent_dir
            _agent_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 1
            _AI_CMD=(python3 "$_agent_dir/ollama_agent.py" --model "$_omodel")
            _AI_STDIN=1 ;;
        agy)
            # --print is STRING-VALUED: it consumes the NEXT token as the prompt, so it
            # MUST be last — run_ai_tool appends "$prompt" as its value. (With --print
            # first it swallowed --dangerously-skip-permissions and ignored the prompt.)
            _AI_CMD=(agy --dangerously-skip-permissions)
            # Bind agy to the project dir. Without this, agy headless builds in its OWN scratch
            # workspace (~/.gemini/antigravity-cli/scratch/...) instead of the project, so Ralph's
            # file-change/lazy/git tracking sees "no files modified". --add-dir makes it write in cwd.
            # Pass an ABSOLUTE path — agy would resolve a relative one against its own workspace.
            local _projdir; _projdir=$(cd "${PROJECT_DIR:-$PWD}" 2>/dev/null && pwd) || _projdir="${PROJECT_DIR:-$PWD}"
            _AI_CMD+=(--add-dir "$_projdir")
            [[ -n "$model" ]] && _AI_CMD+=(--model "$model")   # agy accepts the human-readable `agy models` name
            [[ "$resume" == "1" ]] && _AI_CMD+=(--continue)
            local _agytmo; _agytmo=$(_ai_timeout_secs)
            [[ "$_agytmo" -gt 0 ]] && _AI_CMD+=(--print-timeout "${_agytmo}s")   # agy's default is only 5m
            _AI_CMD+=(--print) ;;   # --print MUST stay last (string-valued: takes the prompt)
        codex)
            # codex is headless ONLY via `exec` (bare codex / -p -> interactive TUI -> hangs).
            # exec never prompts, so -s workspace-write keeps the OS sandbox instead of a blanket
            # bypass; --color never keeps tee'd logs ANSI-free; --skip-git-repo-check for non-repos.
            _AI_CMD=(codex exec -s workspace-write --color never --skip-git-repo-check)
            [[ -n "$model" ]] && _AI_CMD+=(--model "$model")
            ;;
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
            # Respect the user's ANTHROPIC_* env as-is (inherited). Do NOT force a
            # localhost:11434 default — that misroutes the official claude CLI to an Ollama
            # port and overrides normal subscription/API-key auth. Opt into a local/proxy
            # endpoint by exporting ANTHROPIC_BASE_URL yourself before running Ralph.
            : ;;
        opencode)
            export CI=true
            ;;
    esac
}

# Whether THIS call should resume the tool's prior conversation: opt-in (RALPH_RESUME_SESSION)
# AND a session already established this run AND a tool with a safe headless resume.
# NOTE: the established flag is per-process, so resume only spans iterations of ONE run
# (not across separate `--once`/cron ticks). It's tool-agnostic, which is safe only because
# TOOL is fixed for a run — revisit if per-iteration tool switching is ever added.
_should_resume() {
    [[ "${RALPH_RESUME_SESSION:-0}" == "1" && "${_RALPH_SESSION_ESTABLISHED:-0}" == "1" ]] || return 1
    case "$1" in claude|opencode|agy) return 0 ;; *) return 1 ;; esac
}

run_ai_tool() {
    local tool="$1"
    local model="$2"
    local prompt="$3"
    local log_file="$4"
    local output_file="$5"

    log_info "Running ${_RALPH_COLOR_MAGENTA}${tool}${_RALPH_COLOR_NC} with model: ${_RALPH_COLOR_GREEN}${model}${_RALPH_COLOR_NC}"
    log_debug "Prompt length: ${#prompt} characters"

    local pid i exit_code guardian_pid="" cleanup_recorded=0 cleanup_trigger=normal
    local supervisor_path state_file ack_file

    if [[ "$tool" == "jules" || "$tool" == "jules-cli" ]]; then
        local jules_provider_fn="run_jules_remote" jules_provider_label="Jules Remote"
        if [[ "$tool" == "jules-cli" ]]; then
            jules_provider_fn="run_jules_cli_remote"
            jules_provider_label="Jules CLI Remote"
        fi
        if ! declare -F "$jules_provider_fn" >/dev/null 2>&1; then
            log_error "tool=$tool requested, but lib/jules.sh is not loaded"
            return 1
        fi
        exit_code=0
        "$jules_provider_fn" "$tool" "$model" "$prompt" "$log_file" "$output_file" || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            log_success "Iteration $iteration: ${jules_provider_label} Response Received"
            return 0
        fi
        log_error "Iteration $iteration: ${jules_provider_label} Failed (Exit $exit_code)"
        return "$exit_code"
    fi

    # Opt-in session continuity: resume the tool's prior conversation once a session has
    # been established (after the first SUCCESSFUL call this run). Default off.
    local resume=0
    if _should_resume "$tool"; then
        resume=1
    elif [[ "${RALPH_RESUME_SESSION:-0}" == "1" && "${_RALPH_SESSION_ESTABLISHED:-0}" == "1" ]]; then
        # A session exists but this tool has no safe headless resume — run fresh, note once.
        if [[ -z "${_RALPH_RESUME_UNSUPPORTED_WARNED:-}" ]]; then
            log_warning "RALPH_RESUME_SESSION: '$tool' has no safe headless resume; each iteration runs fresh"
            _RALPH_RESUME_UNSUPPORTED_WARNED=1   # plain global; internal state, no need to export
        fi
    fi

    # Build the argv (testable; no execution), then launch in the background.
    if ! _build_ai_cmd "$tool" "$model" "$resume"; then
        log_error "Unknown tool: $tool"
        return 1
    fi
    local _dur; _dur=$(_ai_timeout_secs)

    local idle_timeout idle_min_runtime idle_probe_interval idle_last_probe=0 idle_last_activity=$SECONDS
    local idle_last_out_size idle_last_log_size idle_last_hash idle_cur_out_size idle_cur_log_size idle_cur_hash
    local idle_project_changed=0 idle_armed=0 idle_stopped=0
    idle_timeout=$(_ai_idle_timeout_secs)
    idle_min_runtime=$(_ai_idle_min_runtime_secs)
    idle_probe_interval=$(_ai_idle_probe_interval_secs)
    if [[ "$idle_timeout" -gt 0 ]]; then
        idle_last_hash=$(_project_progress_fingerprint 2>/dev/null || echo unknown)
    fi

    # The tracked PID is a supervisor outside a new child session/process group. It owns
    # stdout/stderr capture, so no pipeline process can obscure provider ownership.
    if ! declare -F prepare_supervised_process >/dev/null 2>&1 ||
       ! supervisor_path=$(_ralph_process_supervisor_path) ||
       ! prepare_supervised_process; then
        log_error "Unable to prepare the isolated provider process boundary"
        return 1
    fi
    state_file="$_RALPH_BOUNDARY_STATE_FILE"
    ack_file="$_RALPH_BOUNDARY_ACK_FILE"

    # Per-tool environment changes remain inside the launch subshell. Closing fd 9
    # before exec prevents providers and the supervisor from retaining Ralph's lock.
    if [[ "$_AI_STDIN" == "1" ]]; then
        (
            { exec 9>&-; } 2>/dev/null || true
            _apply_tool_env "$tool"
            exec python3 "$supervisor_path" \
                --state-file "$state_file" \
                --ack-file "$ack_file" \
                --log-file "$log_file" \
                --stdout-file "$output_file" \
                -- "${_AI_CMD[@]}" <<<"$prompt"
        ) &
    else
        (
            { exec 9>&-; } 2>/dev/null || true
            _apply_tool_env "$tool"
            exec python3 "$supervisor_path" \
                --state-file "$state_file" \
                --ack-file "$ack_file" \
                --log-file "$log_file" \
                --stdout-file "$output_file" \
                -- "${_AI_CMD[@]}" "$prompt" </dev/null
        ) &
    fi
    pid=$!
    if ! register_supervised_process "$pid" provider "$state_file" "$ack_file" 0; then
        log_error "Provider process boundary failed identity validation"
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$state_file" "$ack_file" 2>/dev/null || true
        return 1
    fi
    if ! start_child_guardian "$pid" "${BASHPID:-$$}" provider; then
        log_error "Provider process boundary guardian failed to start"
        terminate_owned_process "$pid" provider exit 0
        wait "$pid" 2>/dev/null || true
        unregister_child_process "$pid"
        rm -f "$state_file" "$ack_file" 2>/dev/null || true
        return 1
    fi
    guardian_pid="${_RALPH_LAST_GUARDIAN_PID:-}"
    if ! release_supervised_process "$pid" "$ack_file"; then
        log_error "Provider process boundary failed to release"
        terminate_owned_process "$pid" provider exit 0
        wait "$pid" 2>/dev/null || true
        stop_child_guardian "$guardian_pid"
        unregister_child_process "$pid"
        rm -f "$state_file" "$ack_file" 2>/dev/null || true
        return 1
    fi

    # Animated spinner while tool runs
    local i=0 timed_out=0 started_at=$SECONDS
    if [[ "$idle_timeout" -gt 0 ]]; then
        idle_last_out_size=$(_file_size_bytes "$output_file")
        idle_last_log_size=$(_file_size_bytes "$log_file")
    fi
    start_progress_timer
    update_status "Thinking" "$(basename "${PROJECT_DIR:-.}")"

    while kill -0 $pid 2>/dev/null; do
        _run_manifest_heartbeat_safe provider_execution "${_RALPH_CURRENT_ITERATION:-$iteration}" 0
        if [[ "$_dur" -gt 0 && $((SECONDS - started_at)) -ge "$_dur" ]]; then
            timed_out=1
            log_warning "AI tool exceeded RALPH_TOOL_TIMEOUT=${_dur}s; terminating process boundary"
            printf 'AI tool exceeded RALPH_TOOL_TIMEOUT=%ss; terminating process boundary\n' "$_dur" >>"$log_file"
            if declare -F terminate_owned_process >/dev/null 2>&1; then
                terminate_owned_process "$pid" provider timeout
                cleanup_recorded=1
            else
                _kill_process_tree TERM "$pid"
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    _kill_process_tree KILL "$pid"
                fi
            fi
            break
        fi

        if [[ "$idle_timeout" -gt 0 && $((SECONDS - idle_last_probe)) -ge "$idle_probe_interval" ]]; then
            idle_last_probe=$SECONDS
            idle_cur_out_size=$(_file_size_bytes "$output_file")
            idle_cur_log_size=$(_file_size_bytes "$log_file")
            idle_cur_hash=$(_project_progress_fingerprint 2>/dev/null || echo unknown)

            log_debug "quiescence probe: out=$idle_cur_out_size log=$idle_cur_log_size changed=$idle_project_changed armed=$idle_armed idle_for=$((SECONDS - idle_last_activity))s"
            if [[ "$idle_cur_out_size" != "$idle_last_out_size" || "$idle_cur_log_size" != "$idle_last_log_size" || "$idle_cur_hash" != "$idle_last_hash" ]]; then
                idle_last_activity=$SECONDS
                [[ "$idle_cur_hash" != "$idle_last_hash" ]] && idle_project_changed=1
                idle_last_out_size="$idle_cur_out_size"
                idle_last_log_size="$idle_cur_log_size"
                idle_last_hash="$idle_cur_hash"
            fi

            if [[ "$idle_project_changed" == "1" && "$idle_armed" == "0" ]] && _ai_quiescence_verify_available; then
                idle_armed=1
                idle_last_activity=$SECONDS
                log_info "AI quiescence watchdog armed after project progress and declared verification discovery"
            fi

            if [[ "$idle_armed" == "1" && $((SECONDS - started_at)) -ge "$idle_min_runtime" && $((SECONDS - idle_last_activity)) -ge "$idle_timeout" ]]; then
                idle_stopped=1
                log_warning "AI tool quiet after project progress for ${idle_timeout}s; terminating process boundary and moving to verification"
                printf 'AI tool quiet after project progress for %ss; terminating process boundary and moving to verification\n' "$idle_timeout" >>"$log_file"
                if declare -F terminate_owned_process >/dev/null 2>&1; then
                    terminate_owned_process "$pid" provider quiescence
                    cleanup_recorded=1
                else
                    _kill_process_tree TERM "$pid"
                    sleep 1
                    if kill -0 "$pid" 2>/dev/null; then
                        _kill_process_tree KILL "$pid"
                    fi
                fi
                break
            fi
        fi

        render_status_bar "$iteration" "$MAX_ITERATIONS" "$i"
        i=$(( (i+1) % 10 ))
        sleep 0.1
    done

    # Get exit code (124 = timed out). Defensive form so a non-zero wait never aborts.
    exit_code=0
    wait "$pid" || exit_code=$?
    if declare -F unregister_child_process >/dev/null 2>&1; then
        unregister_child_process "$pid"
    fi
    if [[ -n "$guardian_pid" ]] && declare -F stop_child_guardian >/dev/null 2>&1; then
        stop_child_guardian "$guardian_pid"
    fi
    [[ "$timed_out" -eq 1 ]] && exit_code=124
    [[ "$idle_stopped" -eq 1 ]] && exit_code=0
    if [[ "$cleanup_recorded" -eq 0 ]] && declare -F _ralph_record_process_cleanup_event >/dev/null 2>&1; then
        cleanup_trigger=normal
        [[ "$exit_code" -eq 124 ]] && cleanup_trigger=timeout
        _ralph_record_process_cleanup_event provider "$cleanup_trigger" already_exited 0 || true
    fi

    if [[ "$tool" == "opencode" ]] && declare -F normalize_opencode_json_output >/dev/null 2>&1; then
        normalize_opencode_json_output "$output_file" "$log_file"
    fi

    # Clear line and show final success/fail
    printf "\r\033[K"

    if [[ $exit_code -eq 0 ]]; then
        log_success "Iteration $iteration: AI Response Received"
        # A successful call establishes a session the next iteration can --continue.
        # Plain global (run_ai_tool runs in-process across iterations); no need to export.
        [[ "${RALPH_RESUME_SESSION:-0}" == "1" ]] && _RALPH_SESSION_ESTABLISHED=1
    else
        log_error "Iteration $iteration: AI Tool Failed (Exit $exit_code)"
    fi

    return $exit_code
}

# Run the AI tool with smart model management: try each model in build_model_chain (each with
# the normal per-model retry/backoff). On a CAPACITY failure (rate limit / overload / quota /
# timeout) degrade to the next model; on auth/other failures don't burn the chain. Sets
# SELECTED_MODEL to the model actually used (so logs/metrics/failure events are accurate).
# Falls through to identical single-model behaviour when no fallbacks are configured.
run_ai_with_fallback() {
    local tool="$1" role="$2" prompt="$3" log="$4" out="$5"
    local attempts="${AI_RETRY_ATTEMPTS:-3}" delay="${AI_RETRY_BASE_DELAY:-5}"
    local -a chain=(); mapfile -t chain < <(build_model_chain "$tool" "$role")
    [[ ${#chain[@]} -eq 0 ]] && chain=("${SELECTED_MODEL:-}")   # never empty
    local model rc=0 category idx=0 total=${#chain[@]}
    for model in "${chain[@]}"; do
        idx=$((idx + 1))
        # Record the model ACTUALLY used (for logs/metrics/failure events) WITHOUT mutating
        # SELECTED_MODEL — determine_model runs once before the loop, so overwriting it would
        # permanently demote the primary for the rest of the run after one transient failure.
        _RALPH_ACTIVE_MODEL="$model"; export _RALPH_ACTIVE_MODEL
        [[ $idx -gt 1 ]] && log_warning "Smart model fallback ($idx/$total): trying '${model:-<self-select>}'"
        # Capture the real exit code via `|| rc=$?` — a bare `if cmd; then return 0; fi`
        # would leave $? as the (false) if's status of 0, masking the failure.
        rc=0
        retry_with_backoff "$attempts" "$delay" -- run_ai_tool "$tool" "$model" "$prompt" "$log" "$out" || rc=$?
        [[ $rc -eq 0 ]] && return 0
        [[ $idx -ge $total ]] && break   # chain exhausted -> graceful degradation done
        # Classify on stdout (the result file) PLUS the tail of the log — CLI tools write
        # rate-limit/quota errors to STDERR, which run_ai_tool routes to the log, not $out.
        category=$(classify_tool_failure "$(cat "$out" 2>/dev/null || true)$(printf '\n')$(tail -n 40 "$log" 2>/dev/null || true)" "$rc")
        case "$category" in
            rate_limit|overloaded|quota|timeout)
                log_warning "Model '${model:-<self-select>}' hit '$category' — degrading to the next model" ;;
            *)
                log_warning "Model '${model:-<self-select>}' failed ('$category'); not a capacity issue — keeping it"
                break ;;
        esac
    done
    return "${rc:-1}"
}


#######################################
# Durable quality rubric / stopping policy
#######################################
default_quality_rubric() {
    cat <<EOF
# Ralph Quality Rubric

Purpose: make the agent judge and improve its own work without expanding beyond the original product scope.

Requested Tier: ${RALPH_QUALITY_TIER:-professional}
Product Scope: the current user request, PRD, Beads tasks, and project instructions. Do not add enterprise features unless the user explicitly requested that tier.
Quality Gate: continue
Stop Reason: initial rubric created; no review has passed yet.

## Rubric
| Dimension | Pass Standard |
| --- | --- |
| Correctness | The requested behavior works end-to-end and edge cases introduced by the change are handled. |
| Verification | Relevant tests, builds, linters, or live smoke checks were run and pass. |
| Maintainability | The implementation follows local patterns, has clear boundaries, and avoids unnecessary abstraction. |
| UX / Operator Experience | User-facing flows are understandable, responsive, and expose useful states/errors. |
| Security / Privacy | Secrets, proprietary data, auth, tenancy, and unsafe side effects are handled deliberately. |
| Performance / Reliability | The solution is bounded, has clear failure behavior, and avoids avoidable resource waste. |
| Docs / Handoff | Run, test, and operational notes are current enough for the next session. |
| Scope Control | Remaining ideas are classified as in-scope blockers, follow-up issues, or out-of-scope polish. |

## Iteration Review
- Last reviewed iteration: 0
- Blocking issues: unknown
- High-value in-scope improvements: unknown
- Deferred or out-of-scope follow-ups: unknown

## Stop Policy
Set \`Quality Gate: pass\` only when all of these are true:
- The original goal and all tracked Beads work are complete.
- Verification passed for the changed behavior.
- No blocking or high-severity reviewer findings remain.
- Remaining improvements are documented follow-ups or out of scope.
- Another iteration is unlikely to add meaningful in-scope value without increasing complexity or scope.
EOF
}

ensure_quality_file() {
    local file="${QUALITY_FILE:-${ARTIFACT_DIR:-.ralph/artifacts}/QUALITY.md}"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    [[ -f "$file" ]] && return 0
    default_quality_rubric > "$file"
}

load_quality_context() {
    ensure_quality_file 2>/dev/null || true
    if [[ -f "${QUALITY_FILE:-}" ]]; then
        cat "$QUALITY_FILE"
    else
        echo "No QUALITY.md found. Create one with a rubric and Quality Gate status before completing."
    fi
}

quality_gate_allows_complete() {
    [[ "${RALPH_REQUIRE_QUALITY_ON_COMPLETE:-1}" == "1" ]] || return 0
    [[ -f "${QUALITY_FILE:-}" ]] || return 1
    grep -Eiq '^[[:space:]]*Quality Gate:[[:space:]]*pass([[:space:]]|$)' "$QUALITY_FILE"
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
# stall_limit_reached STREAK CEILING
# Return 0 when a no-progress streak has hit an enabled ceiling (CEILING>0). The
# reflexion nudge at LAZY_THRESHOLD gets first crack; this is the hard stop that
# keeps a wholly-stuck agent from burning every iteration. Pure + unit-tested.
stall_limit_reached() {
    local streak="${1:-0}" ceiling="${2:-0}"
    [[ "$streak" =~ ^[0-9]+$ && "$ceiling" =~ ^[0-9]+$ ]] || return 1
    [[ "$ceiling" -gt 0 && "$streak" -ge "$ceiling" ]]
}

# run_budget_exceeded TOKENS_TOTAL TOKENS_MAX ELAPSED_SECONDS SECONDS_MAX
# Return 0 (and echo a human reason) when any enabled aggregate ceiling is hit —
# the FinOps guard for unattended loops. A ceiling of 0 means "unlimited". Pure.
run_budget_exceeded() {
    local tok="${1:-0}" tok_max="${2:-0}" elapsed="${3:-0}" sec_max="${4:-0}"
    [[ "$tok" =~ ^[0-9]+$ ]] || tok=0
    [[ "$tok_max" =~ ^[0-9]+$ ]] || tok_max=0
    [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
    [[ "$sec_max" =~ ^[0-9]+$ ]] || sec_max=0
    if [[ "$tok_max" -gt 0 && "$tok" -ge "$tok_max" ]]; then
        echo "token budget exhausted (${tok}/${tok_max} est. tokens)"
        return 0
    fi
    if [[ "$sec_max" -gt 0 && "$elapsed" -ge "$sec_max" ]]; then
        echo "time budget exhausted (${elapsed}/${sec_max}s)"
        return 0
    fi
    return 1
}

# backlog_exit_allowed VERIFY_OK QUEUED_CORRECTION
# Return 0 only when a task-backlog early exit is allowed to stand in for an
# explicit COMPLETE promise. This keeps the Beads drain path from bypassing the
# same verification and quality gates enforced on agent-declared completion.
# Self-benchmarking: next small improvement is to emit structured block reasons
# here so `review_run` can report the exact gate without parsing human logs.
backlog_exit_allowed() {
    local verify_ok="${1:-false}"
    local queued_correction="${2-}"

    if [[ "${RALPH_REQUIRE_VERIFY_ON_COMPLETE:-1}" == "1" && "$verify_ok" != "true" ]]; then
        return 1
    fi
    [[ -z "$queued_correction" ]] || return 1
    quality_gate_allows_complete || return 1
    return 0
}

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

    # Create the quality rubric before hashing so the framework artifact itself is
    # not mistaken for agent progress in this iteration.
    ensure_quality_file || true

    # Capture project state before execution
    local project_hash_before
    project_hash_before=$(compute_project_hash)
    log_debug "Project hash before: $project_hash_before"
    _RALPH_REMOTE_PROGRESS=0
    _RALPH_REMOTE_STATE=""
    _RALPH_REMOTE_SESSION=""
    export _RALPH_REMOTE_PROGRESS _RALPH_REMOTE_STATE _RALPH_REMOTE_SESSION

    # Generate current log signature for loop detection
    local current_log_signature
    current_log_signature=$(tail -n 50 "${LOG_FILE:-/dev/null}" 2>/dev/null | md5sum_wrapper | awk '{print $1}' || echo "none")
    log_debug "Log signature: $current_log_signature"

    # Read the agent-instructions prompt (tool-native: CLAUDE.md for claude, AGENTS.md for
    # codex/agy/opencode/amp, GEMINI.md for gemini — with fallbacks).
    local agents_path
    if agents_path=$(resolve_agents_file "${TOOL:-}"); then
        prompt_content=$(cat "$agents_path")
    else
        log_error "No agent-instructions file in ${PROJECT_DIR:-.} (looked for CLAUDE.md / AGENTS.md). Create one, or run: ralph --init"
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

    local quality_context
    quality_context=$(load_quality_context)

    # Same resolved instructions file (already located above as $agents_path).
    if [[ -n "${agents_path:-}" && -f "$agents_path" ]]; then
        project_instructions=$(cat "$agents_path")
        log_debug "Loaded project-specific instructions from $agents_path"
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

    # Smart model management: each candidate model gets bounded retry/backoff, and we degrade
    # down the fallback chain on capacity failures (rate limit / overload / quota / timeout) so
    # a transient/API failure is NOT mistaken for "no work left to do". On full exhaustion we
    # return a distinct code (2) and emit a durable failure event. (Default chain = 1 model.)
    local ai_attempts="${AI_RETRY_ATTEMPTS:-3}"
    _run_manifest_heartbeat_safe provider_execution "$iteration" 1
    if ! run_ai_with_fallback "$TOOL" "${RALPH_ROLE:-engineer}" "$structured_prompt" "$LOG_FILE" "$temp_output"; then
        # Report the model actually used (the chain may have degraded past the primary).
        local used_model="${_RALPH_ACTIVE_MODEL:-$SELECTED_MODEL}"
        log_error "AI tool execution failed (model chain exhausted; last model: $used_model)"
        # Build the payload with jq so special characters in TOOL/model cannot
        # produce malformed JSON.
        local fail_payload
        fail_payload=$(jq -n --argjson iteration "$iteration" --arg tool "$TOOL" --arg model "$used_model" \
            '{iteration: $iteration, tool: $tool, model: $model}' 2>/dev/null || echo '{}')
        emit_event "iteration_failed" "$fail_payload"
        store_lesson "Iteration $iteration failed: tool '$TOOL' did not complete after ${ai_attempts} attempts (model $used_model)."
        record_signal task_repeat_failure "AI tool failed to complete the iteration" "tool $TOOL model $used_model did not complete after retries" "investigate tool/model/connectivity failure" "run_ai_tool" "high" >/dev/null 2>&1 || true
        _run_manifest_heartbeat_safe provider_failed "$iteration" 1
        return 2
    fi

    _run_manifest_heartbeat_safe verification "$iteration" 1
    end_ts=$(get_high_res_time)
    iteration_latency=$(echo "$end_ts - $start_ts" | bc 2>/dev/null || echo "0")

    # Read output
    output=$(cat "$temp_output" 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        log_warning "AI tool produced no output"
    fi

    # Capture any <memory>…</memory> notes the agent emitted into cross-project genetic memory.
    extract_and_store_memories "$output"

    # Persist a per-step trace (prompt in, output out) for post-hoc observability.
    if [[ -n "${RUN_DIR:-}" ]]; then
        local step_dir="$RUN_DIR/steps/iter-$iteration"
        if mkdir -p "$step_dir" 2>/dev/null; then
            printf '%s' "$structured_prompt" > "$step_dir/prompt.txt" 2>/dev/null || true
            printf '%s' "$output" > "$step_dir/output.txt" 2>/dev/null || true
        fi
    fi

    # Validate artifacts and queue corrections for next iteration
    local artifact_errors runtime_errors verify_ok=true
    artifact_errors=$(validate_artifacts)
    runtime_errors=$(verify_runtime)

    if [[ -n "$artifact_errors" || -n "$runtime_errors" ]]; then
        verify_ok=false
        export NEXT_INSTRUCTION="${artifact_errors}${runtime_errors}"
        log_warning "Validation or runtime errors detected, will correct in next iteration"
        if [[ "${TOOL:-}" == "jules" && "${_RALPH_REMOTE_STATE:-}" == "COMPLETED" ]] && declare -F jules_send_verification_feedback >/dev/null 2>&1; then
            jules_send_verification_feedback "${artifact_errors}${runtime_errors}" "$LOG_FILE" || true
        fi
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
    LAST_VERIFY_OK="$verify_ok"; export LAST_VERIFY_OK

    # Analyze project changes
    local project_hash_after
    project_hash_after=$(compute_project_hash)
    log_debug "Project hash after: $project_hash_after"

    local remote_progress="${_RALPH_REMOTE_PROGRESS:-0}"
    if [[ "$project_hash_before" == "$project_hash_after" && "$remote_progress" != "1" ]]; then
        LAZY_STREAK=$(( ${LAZY_STREAK:-0} + 1 ))
        log_warning "No files modified this iteration (streak: $LAZY_STREAK)"
        if [[ ${LAZY_STREAK:-0} -ge ${LAZY_THRESHOLD:-2} ]]; then
            record_signal lazy_streak "no files modified for $LAZY_STREAK consecutive iterations" "no-files-modified" "make a concrete code change or output the completion promise" "lazy_detection" >/dev/null 2>&1 || true
        fi
    elif [[ "$remote_progress" == "1" ]]; then
        log_success "Remote provider progressed (${_RALPH_REMOTE_SESSION:-unknown}: ${_RALPH_REMOTE_STATE:-unknown})"
        LAZY_STREAK=0
        _signal_auto_resolve_family lazy_streak >/dev/null 2>&1 || true
        _signal_auto_resolve_family loop_detected >/dev/null 2>&1 || true
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
    # Aggregate token accounting for the run-wide FinOps ceiling (checked in main()).
    RUN_TOKENS_TOTAL=$(( ${RUN_TOKENS_TOTAL:-0} + est_tokens ))
    export RUN_TOKENS_TOTAL
    # Structured run-ledger enrichments: did project state change, and did this
    # iteration's build/artifact verification pass? (booleans, emitted as JSON.)
    local changed_json=false verify_json="${verify_ok:-true}"
    [[ "$project_hash_before" != "$project_hash_after" ]] && changed_json=true
    [[ "${_RALPH_REMOTE_PROGRESS:-0}" == "1" ]] && changed_json=true
    metrics_payload=""
    if command_exists jq; then
        metrics_payload=$(jq -nc \
            --arg timestamp "$timestamp" \
            --arg run_id "${RUN_ID:-}" \
            --argjson iteration "${iteration:-0}" \
            --arg tool "$TOOL" \
            --arg model "${_RALPH_ACTIVE_MODEL:-$SELECTED_MODEL}" \
            --argjson latency "${iteration_latency:-0}" \
            --argjson tokens "${est_tokens:-0}" \
            --argjson tokens_total "${RUN_TOKENS_TOTAL:-0}" \
            --argjson lazy_streak "${LAZY_STREAK:-0}" \
            --argjson changed "$changed_json" \
            --argjson verify_ok "$verify_json" \
            --arg project_hash "$project_hash_after" \
            '{timestamp:$timestamp, run_id:$run_id, iteration:$iteration, tool:$tool, model:$model, latency:$latency, tokens:$tokens, tokens_total:$tokens_total, lazy_streak:$lazy_streak, changed:$changed, verify_ok:$verify_ok, project_hash:$project_hash}' 2>/dev/null)
    fi
    if [[ -n "$metrics_payload" ]]; then
        log_metrics "$metrics_payload"
    else
        log_metrics "{\"timestamp\": \"$timestamp\", \"run_id\": \"${RUN_ID:-}\", \"iteration\": $iteration, \"tool\": \"$TOOL\", \"model\": \"$SELECTED_MODEL\", \"latency\": ${iteration_latency:-0}, \"tokens\": ${est_tokens:-0}, \"tokens_total\": ${RUN_TOKENS_TOTAL:-0}, \"lazy_streak\": ${LAZY_STREAK:-0}, \"changed\": ${changed_json}, \"verify_ok\": ${verify_json}, \"project_hash\": \"$project_hash_after\"}"
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
    _run_manifest_heartbeat_safe iteration_complete "$iteration" 1

    # Check for completion signal
    if echo "$output" | grep -qF "<promise>COMPLETE</promise>"; then
        if [[ "${RALPH_REQUIRE_VERIFY_ON_COMPLETE:-1}" == "1" && "${verify_ok:-true}" != "true" ]]; then
            # Blocking verification gate: a COMPLETE promise is REJECTED while the
            # build/artifact checks are failing, so the loop cannot declare success
            # over a broken tree. The failing details were queued in NEXT_INSTRUCTION
            # above; reinforce that completion is blocked until they pass.
            log_warning "Agent signaled completion, but verification is failing - completion REJECTED until it passes."
            export NEXT_INSTRUCTION="You output <promise>COMPLETE</promise>, but completion is BLOCKED because build/artifact verification is still failing. Fix the errors below, confirm they pass, and only then complete:
${artifact_errors}${runtime_errors}"
            record_signal completion_blocked "completion promise rejected while verification is failing" "verify-gate-block" "fix the failing build/artifact checks, then re-emit completion" "verify_gate" "high" >/dev/null 2>&1 || true
        elif ! verify_beads_complete; then
            log_warning "Agent signaled completion but incomplete tasks remain in Beads"
            local ready_tasks
            ready_tasks=$(_bd ready --pretty)
            export NEXT_INSTRUCTION="You signaled completion, but the following tasks are still incomplete in Beads. Please complete them and use 'bd close <id>' for each before terminating:
$ready_tasks"
        elif ! quality_gate_allows_complete; then
            log_warning "Agent signaled completion, but QUALITY.md does not mark Quality Gate: pass - completion REJECTED."
            export NEXT_INSTRUCTION="You output <promise>COMPLETE</promise>, but completion is BLOCKED by the quality gate. Update ${QUALITY_FILE:-QUALITY.md} with a reviewer judgment. Keep Quality Gate: continue if meaningful in-scope improvements or blockers remain; set Quality Gate: pass only if the stop policy is satisfied. Then re-run verification and complete."
            record_signal quality_gate_blocked "completion promise rejected by quality gate" "quality-gate-not-pass" "update QUALITY.md with the reviewer judgment and either continue improving or mark Quality Gate: pass" "quality_gate" "medium" >/dev/null 2>&1 || true
        else
            log_success "Agent signaled completion, all Beads tasks are closed, and quality gate passed"

            # Store lesson learned (basic heuristic: extract summary or use project name)
            local project_name
            project_name=$(basename "$(pwd)")
            store_lesson "Project '$project_name' completed successfully with $iteration iterations."

            return 0
        fi
    fi

    return 1
}

#######################################
# Main execution entry point
#######################################
_run_manifest_heartbeat_safe() {
    if declare -F run_manifest_heartbeat >/dev/null 2>&1; then
        run_manifest_heartbeat "$@" || true
    fi
}

_set_run_outcome_safe() {
    if declare -F set_run_outcome >/dev/null 2>&1; then
        set_run_outcome "$@" || true
    fi
}

main() {
    # Check for swarm command
    if [[ "${1:-}" == "swarm" ]]; then
        shift
        # handle_swarm_command lives in lib/tools.sh (sourced by ralph.sh) — there is no lib/swarm.sh.
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
    if [[ "${1:-}" == "triage" ]]; then
        shift
        handle_triage_command "$@"
        exit $?
    fi
    # Synapse (agent-backplane) client + per-agent live-test CLIs. Defined in lib/synapse.sh.
    if [[ "${1:-}" == "agents" ]]; then
        shift
        handle_agents_command "$@"
        exit $?
    fi
    if [[ "${1:-}" == "synapse" ]]; then
        shift
        handle_synapse_command "$@"
        exit $?
    fi
    # Read-only cleanup-latency aggregation across retained runs. Dispatched here (after
    # load_config so _RALPH_DIR/run root exist, before check_dependencies) so it works on
    # hosts without the AI toolchain. Aggregation logic lives in lib/processes.sh.
    if [[ "${1:-}" == "cleanup-stats" ]]; then
        shift
        handle_cleanup_stats_command "$@"
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

    # Validate configuration FIRST (fail fast on bad config before any install work).
    validate_config || exit 1

    # Dependency check runs HERE (not in ralph.sh) so it only gates the iterating path:
    # --help/--version/--init/--setup/--test/--review and the read-only subcommands have
    # already exited above, and TOOL is now known so the correct AI tool is verified.
    check_dependencies || exit 1

    # Fail loudly NOW if there is no agent-instructions file — otherwise every iteration
    # aborts internally and the loop misreads it as benign progress, burning all iterations.
    if ! resolve_agents_file "${TOOL:-}" >/dev/null; then
        log_error "No agent-instructions file in ${PROJECT_DIR:-.}."
        log_error "Create one ($([[ "${TOOL:-}" == claude ]] && echo CLAUDE.md || echo AGENTS.md) — the operating prompt for the agent), or run: ralph --init"
        exit 1
    fi

    # Unattended mode: prefer the hardened Docker sandbox for autonomous runs.
    # Skip inside a container or when the operator explicitly accepted host execution.
    if [[ "${UNATTENDED:-false}" == "true" && "${SANDBOX_MODE:-false}" != "true" &&
          "${RALPH_SANDBOX_EXPLICITLY_DISABLED:-false}" != "true" ]] && ! running_in_container; then
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
        local lock_file="${STATE_DIR:-.ralph/state}/ralph.lock" lock_wait="${RALPH_LOCK_WAIT_SECONDS:-3}"
        [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=3
        [[ "$lock_wait" -le 60 ]] || lock_wait=60
        mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
        # Guard the FD redirect: a bare `exec 9>file` aborts the whole script under
        # set -e if the file exists but is not writable. The brace group scopes the
        # `2>/dev/null` to the open attempt only — without it, `exec` (no command)
        # would make the stderr redirect PERMANENT and blackhole all later logs.
        if ! { exec 9>"$lock_file"; } 2>/dev/null; then
            log_warning "Cannot open lock file $lock_file; skipping singleton lock."
        elif ! flock -w "$lock_wait" 9; then
            log_error "Another Ralph instance held the project lock for ${lock_wait}s (lock: $lock_file)."
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
    if declare -F init_run_manifest >/dev/null 2>&1; then
        init_run_manifest || log_warning "Continuing without durable run manifest evidence"
    fi
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
        _set_run_outcome_safe failed model_selection_failed
        exit 1
    }

    # Initialize state variables (fresh-run defaults)
    export LAZY_STREAK=0
    export SIGNAL_CLEAN_STREAK=0
    export PREVIOUS_LOG_HASH=""
    export NEXT_INSTRUCTION=""
    export LAST_VERIFY_OK=false
    # Aggregate run budget accounting (per invocation; a --resume run starts a
    # fresh token/time budget). Consumed by the FinOps ceiling check below.
    export RUN_TOKENS_TOTAL=0
    RUN_START_TS=$(date +%s); export RUN_START_TS
    local CONSECUTIVE_FAILURES=0
    local DRAIN_STREAK=0

    # Determine starting iteration
    local start_iter=1

    if [[ "${RESUME_FLAG:-false}" == "true" ]]; then
        local last_checkpoint
        last_checkpoint=$(get_checkpoint)

        if [[ "$last_checkpoint" =~ ^[0-9]+$ ]] && [[ $last_checkpoint -gt 0 ]]; then
            log_info "Resuming from checkpoint: Iteration $last_checkpoint"
            _RALPH_RESUME_CHECKPOINT="$last_checkpoint"
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

    _run_manifest_heartbeat_safe ready "$((start_iter - 1))" 1

    # Main iteration loop
    for i in $(seq "$start_iter" "$MAX_ITERATIONS"); do

        _RALPH_CURRENT_ITERATION="$i"
        _run_manifest_heartbeat_safe iteration_prepare "$i" 1

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
            _set_run_outcome_safe completed completion_signal
            exit 0
        elif [[ $iter_rc -eq 2 ]]; then
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            log_error "Iteration $i: AI tool failed after retries (consecutive failures: $CONSECUTIVE_FAILURES)."
            if [[ $CONSECUTIVE_FAILURES -ge ${MAX_CONSECUTIVE_FAILURES:-3} ]]; then
                log_error "Aborting: ${CONSECUTIVE_FAILURES} consecutive tool failures. Check connectivity, auth, or model availability."
                send_notification "Ralph stopped" "Aborted after ${CONSECUTIVE_FAILURES} consecutive tool failures" "critical"
                _set_run_outcome_safe failed provider_failure_circuit_breaker
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
        local _backlog_drained=false
        if [[ $iter_rc -eq 1 ]] && backlog_drained; then
            _backlog_drained=true
        fi
        if [[ "$_backlog_drained" == "true" ]] && backlog_exit_allowed "${LAST_VERIFY_OK:-false}" "${NEXT_INSTRUCTION:-}"; then
            DRAIN_STREAK=$(( DRAIN_STREAK + 1 ))
            if [[ $DRAIN_STREAK -ge 2 ]]; then
                log_success "Task backlog drained for 2 iterations — all tracked work is complete."
                review_run
                _set_run_outcome_safe completed backlog_drained
                exit 0
            fi
            log_info "Backlog appears drained (streak ${DRAIN_STREAK}/2); confirming on next iteration."
        elif [[ "$_backlog_drained" == "true" ]]; then
            DRAIN_STREAK=0
            log_warning "Backlog is drained, but completion gates are still blocking; continuing until verification and quality pass."
        else
            DRAIN_STREAK=0
        fi

        # Hard stop: no-progress ceiling (stall). The reflexion nudge at
        # LAZY_THRESHOLD gets first crack; this aborts a wholly-stuck run instead of
        # burning every remaining iteration. Only after a normal iteration.
        if [[ $iter_rc -eq 1 ]] && stall_limit_reached "${LAZY_STREAK:-0}" "${RALPH_MAX_LAZY_STREAK:-0}"; then
            log_error "Stall ceiling reached: ${LAZY_STREAK} consecutive no-progress iterations (RALPH_MAX_LAZY_STREAK=${RALPH_MAX_LAZY_STREAK}). Aborting."
            record_signal stall_abort "run aborted after ${LAZY_STREAK} no-progress iterations" "stall-ceiling" "break the task down or intervene; the agent stopped changing state" "stall_abort" "high" >/dev/null 2>&1 || true
            send_notification "Ralph stopped" "Stalled: no progress for ${LAZY_STREAK} iterations" "critical"
            review_run
            _set_run_outcome_safe failed stall_limit
            exit 1
        fi

        # Hard stop: aggregate run budget (estimated tokens / wall-clock) — the
        # FinOps ceiling so an unattended loop cannot rack up unbounded cost.
        local _run_elapsed _budget_reason=""
        _run_elapsed=$(( $(date +%s) - ${RUN_START_TS:-$(date +%s)} ))
        if _budget_reason=$(run_budget_exceeded "${RUN_TOKENS_TOTAL:-0}" "${RALPH_MAX_RUN_TOKENS:-0}" "$_run_elapsed" "${RALPH_MAX_RUN_SECONDS:-0}"); then
            log_error "Run budget exceeded: ${_budget_reason}. Aborting."
            record_signal budget_abort "run aborted: ${_budget_reason}" "run-budget" "raise RALPH_MAX_RUN_TOKENS / RALPH_MAX_RUN_SECONDS, or split the work" "budget_abort" "high" >/dev/null 2>&1 || true
            send_notification "Ralph stopped" "Run budget exceeded: ${_budget_reason}" "critical"
            review_run
            _set_run_outcome_safe failed budget_exceeded
            exit 1
        fi

        # Single-iteration mode: let an external scheduler (cron/systemd) own cadence.
        if [[ "${RUN_ONCE:-false}" == "true" ]]; then
            log_info "Single-iteration mode (--once): stopping. Use --resume to continue."
            if [[ $iter_rc -eq 2 ]]; then
                # The in-process circuit breaker cannot accumulate across cron ticks,
                # so alert here on a hard failure instead of exiting silently non-zero.
                send_notification "Ralph (--once) failed" "Iteration $i tool failure; check logs" "critical"
                _set_run_outcome_safe failed provider_failure
                exit 1
            fi
            review_run
            _set_run_outcome_safe paused single_iteration
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
    _set_run_outcome_safe incomplete max_iterations
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
# Runtime verification helpers
#######################################
verification_evidence_file() {
    printf '%s\n' "${RALPH_VERIFICATION_FILE:-${ARTIFACT_DIR:-${PROJECT_DIR:-.}/.ralph/artifacts}/verification.json}"
}

init_verification_evidence() {
    [[ "${RALPH_WRITE_VERIFICATION_EVIDENCE:-1}" == "1" ]] || return 0
    command_exists jq || return 0
    local file updated_at
    file=$(verification_evidence_file)
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    jq -n \
        --arg schema_version "1" \
        --arg project_dir "${PROJECT_DIR:-.}" \
        --arg run_id "${RUN_ID:-manual}" \
        --argjson iteration "${iteration:-0}" \
        --arg started_at "$updated_at" \
        '{schema_version:($schema_version|tonumber), project_dir:$project_dir, run_id:$run_id, iteration:$iteration, started_at:$started_at, updated_at:$started_at, commands:[], summary:{total:0, failed:0, timed_out:0}}' \
        > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
}

runtime_timeout_diagnostic() {
    local cmd="$1" timeout_s="$2"
    local msg="timed out after ${timeout_s}s"
    case "$cmd" in
        npm\ test|pnpm\ test|yarn\ test|bun\ test|*node\ --test*)
            msg+="; if assertions passed before timeout, check for an open server/listener/timer and close it in test teardown"
            ;;
    esac
    printf '%s\n' "$msg"
}

append_verification_evidence() {
    [[ "${RALPH_WRITE_VERIFICATION_EVIDENCE:-1}" == "1" ]] || return 0
    command_exists jq || return 0
    local cmd="$1" rc="$2" timed_out="$3" timeout_s="$4" elapsed_s="$5" stdout_file="$6" stderr_file="$7" diagnostic="${8:-}"
    local file stdout_tail stderr_tail updated_at timed_out_json
    file=$(verification_evidence_file)
    [[ -f "$file" ]] || init_verification_evidence
    [[ -f "$file" ]] || return 0
    stdout_tail=$(tail -n 40 "$stdout_file" 2>/dev/null || true)
    stderr_tail=$(tail -n 40 "$stderr_file" 2>/dev/null || true)
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    [[ "$timed_out" == "true" ]] && timed_out_json=true || timed_out_json=false
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=0
    [[ "$elapsed_s" =~ ^[0-9]+$ ]] || elapsed_s=0

    jq \
        --arg command "$cmd" \
        --argjson exit_code "$rc" \
        --argjson timed_out "$timed_out_json" \
        --argjson timeout_seconds "$timeout_s" \
        --argjson elapsed_seconds "$elapsed_s" \
        --arg stdout_tail "$stdout_tail" \
        --arg stderr_tail "$stderr_tail" \
        --arg diagnostic "$diagnostic" \
        --arg updated_at "$updated_at" \
        '.commands += [{command:$command, exit_code:$exit_code, timed_out:$timed_out, timeout_seconds:$timeout_seconds, elapsed_seconds:$elapsed_seconds, diagnostic:$diagnostic, stdout_tail:$stdout_tail, stderr_tail:$stderr_tail}]
         | .updated_at = $updated_at
         | .summary = {total:(.commands|length), failed:([.commands[] | select(.exit_code != 0)] | length), timed_out:([.commands[] | select(.timed_out == true)] | length)}' \
        "$file" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
}

_runtime_add_command() {
    local cmd="$1"
    [[ -n "$cmd" ]] || return 0
    case "$cmd" in
        "No build command detected"|"No test command detected"|echo\ "No build command detected"*|echo\ "No test command detected"*) return 0 ;;
    esac
    if [[ "${_RALPH_RUNTIME_SEEN:-}" == *$'\n'"$cmd"$'\n'* ]]; then
        return 0
    fi
    _RALPH_RUNTIME_SEEN+="$cmd"$'\n'
    printf '%s\n' "$cmd"
}

runtime_package_manager() {
    local project_dir="${1:-.}"
    if [[ -f "$project_dir/bun.lock" || -f "$project_dir/bun.lockb" ]]; then
        echo bun
    elif [[ -f "$project_dir/pnpm-lock.yaml" ]]; then
        echo pnpm
    elif [[ -f "$project_dir/yarn.lock" ]]; then
        echo yarn
    else
        echo npm
    fi
}

collect_runtime_commands() {
    local project_dir="${1:-.}" pm script value
    _RALPH_RUNTIME_SEEN=$'\n'

    if command_exists jq && [[ -f "$project_dir/ralph.json" ]]; then
        while IFS= read -r value; do
            _runtime_add_command "$value"
        done < <(jq -r '.commands // {} | to_entries[] | . as $entry | select(["verify","test","build","smoke","lint","check"] | index($entry.key)) | select($entry.value | type == "string") | $entry.value' "$project_dir/ralph.json" 2>/dev/null || true)
    fi

    if command_exists jq && [[ -f "$project_dir/package.json" ]]; then
        pm=$(runtime_package_manager "$project_dir")
        for script in test build lint smoke check; do
            value=$(jq -r --arg script "$script" '.scripts[$script] // empty' "$project_dir/package.json" 2>/dev/null || true)
            [[ -n "$value" ]] || continue
            case "$value" in *"no test specified"*) continue ;; esac
            if [[ "$script" == "test" ]]; then
                _runtime_add_command "$pm test"
            else
                _runtime_add_command "$pm run $script"
            fi
        done
    fi

    unset _RALPH_RUNTIME_SEEN
}

runtime_command_allowed() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || return 1
    [[ "$cmd" != *$'\n'* && "$cmd" != *$'\r'* ]] || return 1
    [[ "$cmd" != *";"* && "$cmd" != *"&"* && "$cmd" != *"|"* && "$cmd" != *"<"* && "$cmd" != *">"* ]] || return 1
    [[ "$cmd" != *'`'* && "$cmd" != *'$('* && "$cmd" != *'${'* ]] || return 1

    [[ "$cmd" =~ ^(npm|pnpm|bun|yarn)[[:space:]]+(test|run[[:space:]]+[A-Za-z0-9:_-]+)([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    [[ "$cmd" =~ ^cargo[[:space:]]+(test|build|check)([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    [[ "$cmd" =~ ^go[[:space:]]+(test|build|vet)([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    [[ "$cmd" =~ ^(pytest|ruff[[:space:]]+check)([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    [[ "$cmd" =~ ^python3?[[:space:]]+-m[[:space:]]+pytest([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    [[ "$cmd" =~ ^make[[:space:]]+(test|check)([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    return 1
}

run_runtime_command() {
    local project_dir="$1" cmd="$2" timeout_s="${RALPH_VERIFY_TIMEOUT:-120}"
    local stdout_file stderr_file start_s end_s elapsed_s rc=0 timed_out=false diagnostic=""
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=120
    stdout_file=$(mktemp "${TMPDIR:-/tmp}/ralph-verify-out.XXXXXX") || stdout_file="/tmp/ralph-verify-out.$$"
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/ralph-verify-err.XXXXXX") || stderr_file="/tmp/ralph-verify-err.$$"
    start_s=$(date +%s)

    if command_exists timeout && [[ "$timeout_s" -gt 0 ]]; then
        (cd "$project_dir" && timeout "$timeout_s" bash -lc "$cmd") >"$stdout_file" 2>"$stderr_file" || rc=$?
    else
        (cd "$project_dir" && bash -lc "$cmd") >"$stdout_file" 2>"$stderr_file" || rc=$?
    fi

    end_s=$(date +%s)
    elapsed_s=$(( end_s - start_s ))
    if [[ "$rc" == "124" || "$rc" == "137" ]]; then
        timed_out=true
        diagnostic=$(runtime_timeout_diagnostic "$cmd" "$timeout_s")
    fi

    _RALPH_RUNTIME_LAST_RC="$rc"
    _RALPH_RUNTIME_LAST_TIMED_OUT="$timed_out"
    _RALPH_RUNTIME_LAST_DIAGNOSTIC="$diagnostic"
    export _RALPH_RUNTIME_LAST_RC _RALPH_RUNTIME_LAST_TIMED_OUT _RALPH_RUNTIME_LAST_DIAGNOSTIC

    append_verification_evidence "$cmd" "$rc" "$timed_out" "$timeout_s" "$elapsed_s" "$stdout_file" "$stderr_file" "$diagnostic"
    rm -f "$stdout_file" "$stderr_file" 2>/dev/null || true
    return "$rc"
}

_health_port_listening() {
    local port="$1"
    command_exists ss || return 1
    ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" { found=1 } END { exit !found }'
}

_health_port_pids() {
    local port="$1"
    command_exists ss || return 1
    ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" { print }' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

_path_within_project() {
    local child="$1" root="$2" child_real root_real
    child_real=$(cd "$child" 2>/dev/null && pwd -P) || return 1
    root_real=$(cd "$root" 2>/dev/null && pwd -P) || return 1
    [[ "$child_real" == "$root_real" || "$child_real" == "$root_real"/* ]]
}

_health_port_owned_by_project() {
    local port="$1" project_dir="$2" pid cwd found_pid=false
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        found_pid=true
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
        [[ -n "$cwd" ]] || continue
        if _path_within_project "$cwd" "$project_dir"; then
            return 0
        fi
    done < <(_health_port_pids "$port")
    [[ "$found_pid" == "false" ]] && return 1
    return 1
}

live_smoke_evidence_file() {
    printf '%s\n' "${RALPH_LIVE_SMOKE_FILE:-${ARTIFACT_DIR:-${PROJECT_DIR:-.}/.ralph/artifacts}/live-smoke.json}"
}

runtime_server_command_allowed() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || return 1
    [[ "$cmd" != *$'\n'* && "$cmd" != *$'\r'* ]] || return 1
    [[ "$cmd" != *";"* && "$cmd" != *"&"* && "$cmd" != *"|"* && "$cmd" != *"<"* && "$cmd" != *">"* ]] || return 1
    [[ "$cmd" != *'`'* && "$cmd" != *'$('* && "$cmd" != *'${'* ]] || return 1
    [[ "$cmd" =~ ^(npm|pnpm|bun|yarn)[[:space:]]+(start|run[[:space:]]+[A-Za-z0-9:_-]+)([[:space:]]+[A-Za-z0-9_./:=@%+,-]+)*$ ]] && return 0
    return 1
}

collect_live_smoke_command() {
    local project_dir="${1:-.}" pm value
    if [[ -n "${RALPH_LIVE_SMOKE_COMMAND:-}" ]]; then
        runtime_server_command_allowed "$RALPH_LIVE_SMOKE_COMMAND" && printf '%s\n' "$RALPH_LIVE_SMOKE_COMMAND"
        return $?
    fi
    command_exists jq || return 1
    [[ -f "$project_dir/package.json" ]] || return 1
    value=$(jq -r '.scripts.start // empty' "$project_dir/package.json" 2>/dev/null || true)
    [[ -n "$value" ]] || return 1
    pm=$(runtime_package_manager "$project_dir")
    printf '%s\n' "$pm start"
}

write_live_smoke_evidence() {
    [[ "${RALPH_WRITE_VERIFICATION_EVIDENCE:-1}" == "1" ]] || return 0
    command_exists jq || return 0
    local status="$1" command="$2" port="$3" probes_json="$4" log_file="$5" diagnostic="${6:-}"
    local file updated_at log_tail
    file=$(live_smoke_evidence_file)
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    log_tail=$(tail -n 80 "$log_file" 2>/dev/null || true)
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    [[ -n "$probes_json" ]] || probes_json='[]'
    jq -n \
        --arg status "$status" \
        --arg command "$command" \
        --argjson port "$port" \
        --arg updated_at "$updated_at" \
        --arg diagnostic "$diagnostic" \
        --arg log_tail "$log_tail" \
        --argjson probes "$probes_json" \
        '{schema_version:1, status:$status, command:$command, port:$port, updated_at:$updated_at, diagnostic:$diagnostic, probes:$probes, log_tail:$log_tail}' \
        > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
}

run_live_smoke() {
    local project_dir="${1:-.}" errors=""
    [[ "${RALPH_LIVE_SMOKE:-0}" == "1" ]] || return 0
    command_exists curl || { printf '%s' $'\n- Live smoke failed: missing curl.'; return 0; }
    command_exists jq || { printf '%s' $'\n- Live smoke failed: missing jq.'; return 0; }

    local cmd port ready_timeout paths log_file probe_file pid guardian_pid="" started_at pass=false path url code probes_json status diagnostic
    local supervisor_path state_file ack_file
    if ! cmd=$(collect_live_smoke_command "$project_dir"); then
        printf '%s' $'\n- Live smoke failed: no safe start command found. Add package.json scripts.start or set RALPH_LIVE_SMOKE_COMMAND.'
        return 0
    fi
    if ! runtime_server_command_allowed "$cmd"; then
        printf '%s\n' "- Live smoke failed: server command rejected as unsafe: $cmd"
        return 0
    fi

    port="${RALPH_LIVE_SMOKE_PORT:-18080}"
    [[ "$port" =~ ^[0-9]+$ ]] || port=18080
    ready_timeout="${RALPH_LIVE_SMOKE_READY_TIMEOUT:-20}"
    [[ "$ready_timeout" =~ ^[0-9]+$ ]] || ready_timeout=20
    paths="${RALPH_LIVE_SMOKE_PATHS:-/health /api/health /api/v1/status /}"
    log_file="${RUN_DIR:-${PROJECT_DIR:-.}/.ralph/runs/${RUN_ID:-manual}}/live-smoke.log"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    probe_file=$(mktemp "${TMPDIR:-/tmp}/ralph-live-smoke.XXXXXX") || probe_file="/tmp/ralph-live-smoke.$$"
    : > "$probe_file"

    if ! declare -F prepare_supervised_process >/dev/null 2>&1 ||
       ! supervisor_path=$(_ralph_process_supervisor_path) ||
       ! prepare_supervised_process; then
        rm -f "$probe_file" 2>/dev/null || true
        printf '%s' $'\n- Live smoke failed: unable to prepare the isolated server process boundary.'
        return 0
    fi
    state_file="$_RALPH_BOUNDARY_STATE_FILE"
    ack_file="$_RALPH_BOUNDARY_ACK_FILE"
    (
        { exec 9>&-; } 2>/dev/null || true
        cd "$project_dir" || exit 1
        export PORT="$port" HOST=127.0.0.1
        exec python3 "$supervisor_path" \
            --state-file "$state_file" \
            --ack-file "$ack_file" \
            --log-file "$log_file" \
            --merge-stderr \
            -- bash -lc "$cmd" </dev/null
    ) &
    pid=$!
    if ! register_supervised_process "$pid" live_smoke "$state_file" "$ack_file" 0; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$state_file" "$ack_file" "$probe_file" 2>/dev/null || true
        printf '%s' $'\n- Live smoke failed: server process boundary failed identity validation.'
        return 0
    fi
    if ! start_child_guardian "$pid" "${BASHPID:-$$}" live_smoke; then
        terminate_owned_process "$pid" live_smoke exit 0
        wait "$pid" 2>/dev/null || true
        unregister_child_process "$pid"
        rm -f "$state_file" "$ack_file" "$probe_file" 2>/dev/null || true
        printf '%s' $'\n- Live smoke failed: server process boundary guardian failed to start.'
        return 0
    fi
    guardian_pid="${_RALPH_LAST_GUARDIAN_PID:-}"
    if ! release_supervised_process "$pid" "$ack_file"; then
        terminate_owned_process "$pid" live_smoke exit 0
        wait "$pid" 2>/dev/null || true
        stop_child_guardian "$guardian_pid"
        unregister_child_process "$pid"
        rm -f "$state_file" "$ack_file" "$probe_file" 2>/dev/null || true
        printf '%s' $'\n- Live smoke failed: server process boundary failed to release.'
        return 0
    fi
    started_at=$SECONDS

    while kill -0 "$pid" 2>/dev/null && [[ $((SECONDS - started_at)) -lt "$ready_timeout" ]]; do
        for path in $paths; do
            [[ "$path" == /* ]] || path="/$path"
            url="http://127.0.0.1:${port}${path}"
            code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
            [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
            local code_num ok_json=false
            code_num=$((10#$code))
            [[ "$code" =~ ^[23] ]] && ok_json=true
            jq -n --arg path "$path" --arg url "$url" --argjson code "$code_num" --argjson ok "$ok_json" \
                '{path:$path,url:$url,http_code:$code,ok:$ok}' >> "$probe_file" 2>/dev/null || true
            if [[ "$ok_json" == "true" ]]; then
                pass=true
                break 2
            fi
        done
        sleep 1
    done

    if declare -F terminate_owned_process >/dev/null 2>&1; then
        terminate_owned_process "$pid" live_smoke verification
    else
        _kill_process_tree TERM "$pid"
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            _kill_process_tree KILL "$pid"
        fi
    fi
    wait "$pid" >/dev/null 2>&1 || true
    if declare -F unregister_child_process >/dev/null 2>&1; then
        unregister_child_process "$pid"
    fi
    if [[ -n "$guardian_pid" ]] && declare -F stop_child_guardian >/dev/null 2>&1; then
        stop_child_guardian "$guardian_pid"
    fi

    probes_json=$(jq -s '.' "$probe_file" 2>/dev/null || echo '[]')
    rm -f "$probe_file" 2>/dev/null || true
    if [[ "$pass" == "true" ]]; then
        status=pass
        diagnostic=""
        log_success "Live smoke passed on port $port"
    else
        status=fail
        diagnostic="no configured live-smoke endpoint returned HTTP 2xx/3xx before ${ready_timeout}s"
        errors+=$'\n'"- Live smoke failed: $diagnostic."
    fi
    write_live_smoke_evidence "$status" "$cmd" "$port" "$probes_json" "$log_file" "$diagnostic"
    printf '%s' "$errors"
}

verify_health_ports() {
    local project_dir="${1:-.}" errors="" port ep url code body
    local ports=()
    [[ -n "${RALPH_HEALTH_PORTS:-}" ]] || return 0
    IFS=$' \t\n,' read -r -a ports <<< "${RALPH_HEALTH_PORTS:-}" || true
    for port in ${ports[@]+"${ports[@]}"}; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        _health_port_listening "$port" || continue

        if [[ "${RALPH_HEALTH_ALLOW_EXTERNAL:-0}" != "1" ]] && ! _health_port_owned_by_project "$port" "$project_dir"; then
            errors+=$'\n'"- Health port $port is listening, but no owning process is rooted in $project_dir. Refusing to treat it as this project's service."
            continue
        fi

        log_success "Project service detected on port $port"
        if command_exists curl; then
            local passed=false
            for ep in "/health" "/api/hello" "/api/v1/status" "/"; do
                url="http://localhost:$port$ep"
                if [[ -n "${RALPH_HEALTH_EXPECT:-}" ]]; then
                    body=$(curl -fsS "$url" 2>/dev/null || true)
                    if [[ "$body" == *"$RALPH_HEALTH_EXPECT"* ]]; then
                        passed=true
                    fi
                else
                    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
                    [[ "$code" == "200" ]] && passed=true
                fi
                if [[ "$passed" == "true" ]]; then
                    log_success "Health check passed: $url"
                    if [[ "$port" == "8080" ]]; then
                        local bench_result
                        bench_result=$(run_mini_bench "$url" 5)
                        [[ "$bench_result" == *"<performance_alert>"* ]] && errors+=$'\n'"$bench_result"
                    fi
                    if [[ "$port" == "3000" ]]; then
                        local visual_report
                        visual_report=$(verify_ui_visual "$url")
                        [[ -n "$visual_report" ]] && errors+=$'\n'"$visual_report"
                    fi
                    break
                fi
            done
            [[ "$passed" == "true" ]] || errors+=$'\n'"- Health checks failed for project-owned port $port."
        fi
    done
    printf '%s' "$errors"
}

#######################################
# Perform runtime verification of services
# Identifies services and runs declared checks plus explicit liveness probes
# Returns: Error string if verification fails
#######################################
verify_runtime() {
    local errors=""
    local project_dir="${PROJECT_DIR:-.}"

    init_verification_evidence
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
        if command_exists jq && ! jq empty "$project_dir/package.json" >/dev/null 2>&1; then
            errors+=$'\n'"- Invalid package.json format."
        fi
        if [[ ! -d "$project_dir/node_modules" ]]; then
            log_warning "node_modules missing; package install may be required before full verification."
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

    # 5. Run declared project verification commands when present.
    if [[ "${RALPH_VERIFY_DECLARED_COMMANDS:-1}" == "1" ]]; then
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] || continue
            if ! runtime_command_allowed "$cmd"; then
                errors+=$'\n'"- Declared verification command rejected as unsafe: $cmd"
                continue
            fi
            log_info "Running declared verification command: $cmd"
            if ! run_runtime_command "$project_dir" "$cmd"; then
                local detail="${_RALPH_RUNTIME_LAST_DIAGNOSTIC:-}"
                if [[ -n "$detail" ]]; then
                    errors+=$'\n'"- Declared verification command failed: $cmd ($detail)."
                else
                    errors+=$'\n'"- Declared verification command failed: $cmd"
                fi
            fi
        done < <(collect_runtime_commands "$project_dir")
    fi

    # 6. Optional first-class live smoke: start the declared app, probe localhost,
    # persist evidence, and tear the server down before normal health-port checks.
    local live_smoke_errors
    live_smoke_errors=$(run_live_smoke "$project_dir")
    [[ -n "$live_smoke_errors" ]] && errors+="$live_smoke_errors"

    # 7. Explicit liveness probes. Ports are opt-in to avoid matching unrelated local services.
    local health_errors
    health_errors=$(verify_health_ports "$project_dir")
    [[ -n "$health_errors" ]] && errors+="$health_errors"

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
    # Last 5 lessons. (Was `last(5)`, which in jq returns the scalar 5 — not "last 5
    # elements" — so this errored and recalled NOTHING. `.lessons[-5:]` is the slice.)
    lessons=$(jq -r '(.lessons // [])[-5:] | .[] | "- " + .' "$GLOBAL_MEMORY_FILE" 2>/dev/null)

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
    command_exists jq || return 0
    [[ -f "$GLOBAL_MEMORY_FILE" ]] || init_memory   # don't silently lose lessons on a fresh host
    local tmp; tmp=$(mktemp)
    # Dedup exact repeats (agents re-emit the same lesson across iterations); keep the last 50.
    if jq --arg msg "$lesson" \
         '(.lessons // []) as $l | .lessons = ((if ($l | index($msg)) then $l else $l + [$msg] end) | .[-50:])' \
         "$GLOBAL_MEMORY_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$GLOBAL_MEMORY_FILE"; then
        log_debug "Stored genetic lesson: $lesson"
    else
        rm -f "$tmp"
    fi
}

# Extract <memory>…</memory> payloads (multiple, possibly multiline) the agent emitted.
# Each is flattened to one trimmed line. Portable awk (index/substr, no GNU-only features).
_extract_memory_blocks() {
    awk '
        { buf = buf $0 "\n" }
        END {
            s = buf
            while ((a = index(s, "<memory>")) > 0) {
                s = substr(s, a + 8)
                b = index(s, "</memory>")
                if (b == 0) break
                m = substr(s, 1, b - 1)
                gsub(/[[:space:]]+/, " ", m); gsub(/^ +| +$/, "", m)
                if (m != "") print m
                s = substr(s, b + 9)
            }
        }'
}

# Persist any <memory>…</memory> notes from agent output into cross-project genetic memory.
# This is the real implementation behind the prompt's "save a memory" instruction — Ralph
# scans the agent's output (as it does for <promise>COMPLETE</promise>) and stores them.
extract_and_store_memories() {
    local text="${1:-}" mem n=0
    [[ -z "$text" ]] && return 0
    while IFS= read -r mem; do
        [[ -z "$mem" ]] && continue
        store_lesson "$mem"
        n=$((n + 1))
        [[ $n -ge 10 ]] && break   # cap per iteration; store dedups + bounds to 50 overall
    done < <(printf '%s\n' "$text" | _extract_memory_blocks)
    [[ $n -gt 0 ]] && log_info "Captured $n cross-project memory note(s) into genetic memory"
    return 0
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

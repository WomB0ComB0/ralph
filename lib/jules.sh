#!/bin/bash

# Jules remote executor adapter. Keep the alpha REST API isolated here so Ralph's
# local synchronous tool path stays simple and testable.

jules_bool() {
    case "${1:-0}" in 1|true|TRUE|yes|YES|on|ON) echo true ;; *) echo false ;; esac
}

jules_api_base() {
    printf '%s\n' "${JULES_API_BASE:-https://jules.googleapis.com/v1alpha}"
}

jules_api_request() {
    local method="$1" path="$2" body="${3:-}" base url
    base="$(jules_api_base)"
    url="${base%/}/${path#/}"
    if [[ -z "${JULES_API_KEY:-}" ]]; then
        log_error "JULES_API_KEY is required for tool=jules"
        return 1
    fi
    if [[ -n "$body" ]]; then
        curl -fsS -X "$method" \
            -H "x-goog-api-key: $JULES_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$url"
    else
        curl -fsS -X "$method" \
            -H "x-goog-api-key: $JULES_API_KEY" \
            -H "Content-Type: application/json" \
            "$url"
    fi
}

jules_state_file() {
    if [[ -n "${RALPH_JULES_STATE_FILE:-}" ]]; then
        printf '%s\n' "$RALPH_JULES_STATE_FILE"
    else
        printf '%s\n' "${RUN_DIR:-${PROJECT_DIR:-.}/.ralph/runs/${RUN_ID:-manual}}/providers/jules.json"
    fi
}

jules_prompt_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print "sha256:" $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print "sha256:" $1}'
    else
        printf 'sha256:unavailable:%s\n' "${#1}"
    fi
}

jules_session_id() {
    local name="$1"
    printf '%s\n' "${name#sessions/}"
}

jules_git_branch() {
    git -C "${PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null | awk 'NF && $0 != "HEAD" { print; exit }'
}

jules_git_owner_repo() {
    local url owner repo
    url=$(git -C "${PROJECT_DIR:-.}" config --get remote.origin.url 2>/dev/null || true)
    [[ -n "$url" ]] || return 1
    case "$url" in
        git@github.com:*) owner="${url#git@github.com:}"; owner="${owner%%/*}"; repo="${url##*/}" ;;
        https://github.com/*) owner="${url#https://github.com/}"; owner="${owner%%/*}"; repo="${url##*/}" ;;
        http://github.com/*) owner="${url#http://github.com/}"; owner="${owner%%/*}"; repo="${url##*/}" ;;
        *) return 1 ;;
    esac
    repo="${repo%.git}"
    [[ -n "$owner" && -n "$repo" ]] || return 1
    printf '%s %s\n' "$owner" "$repo"
}

jules_list_sources() {
    jules_api_request GET "/sources?pageSize=100"
}

jules_resolve_source() {
    if [[ -n "${RALPH_JULES_SOURCE:-}" ]]; then
        printf '%s\n' "$RALPH_JULES_SOURCE"
        return 0
    fi

    local owner repo sources
    read -r owner repo < <(jules_git_owner_repo) || true
    [[ -n "${owner:-}" && -n "${repo:-}" ]] || return 1
    sources=$(jules_list_sources) || return 1
    jq -r --arg owner "$owner" --arg repo "$repo" '
        .sources[]?
        | select((.githubRepo.owner // "") == $owner and (.githubRepo.repo // "") == $repo)
        | .name
    ' <<<"$sources" | head -1
}

jules_create_payload() {
    local prompt="$1" title="$2" source="$3" branch="$4" mode="${RALPH_JULES_MODE:-pr}"
    local require auto_pr
    require=$(jules_bool "${RALPH_JULES_REQUIRE_PLAN_APPROVAL:-0}")
    auto_pr="${RALPH_JULES_AUTO_PR:-}"
    [[ -z "$auto_pr" ]] && { [[ "$mode" == "pr" ]] && auto_pr=1 || auto_pr=0; }
    if [[ -n "$source" ]]; then
        jq -n \
            --arg prompt "$prompt" \
            --arg title "$title" \
            --arg source "$source" \
            --arg branch "$branch" \
            --argjson require "$require" \
            --argjson autoPr "$(jules_bool "$auto_pr")" '
            {
              prompt: $prompt,
              title: $title,
              sourceContext: {
                source: $source,
                githubRepoContext: { startingBranch: $branch }
              },
              requirePlanApproval: $require
            }
            + (if $autoPr then { automationMode: "AUTO_CREATE_PR" } else {} end)
        '
    else
        jq -n \
            --arg prompt "$prompt" \
            --arg title "$title" \
            --argjson require "$require" \
            '{prompt: $prompt, title: $title, requirePlanApproval: $require}'
    fi
}

jules_create_session() {
    local payload="$1"
    jules_api_request POST "/sessions" "$payload"
}

jules_get_session() {
    local session_name="$1"
    jules_api_request GET "/${session_name#/}"
}

jules_list_activities() {
    local session_name="$1"
    jules_api_request GET "/${session_name#/}/activities?pageSize=100"
}

jules_send_message() {
    local session_name="$1" prompt="$2" payload
    payload=$(jq -n --arg prompt "$prompt" '{prompt: $prompt}')
    jules_api_request POST "/${session_name#/}:sendMessage" "$payload"
}

jules_approve_plan() {
    local session_name="$1"
    jules_api_request POST "/${session_name#/}:approvePlan" '{}'
}

jules_pull_request_url() {
    jq -r '.outputs[]?.pullRequest?.url // empty' | tail -1
}

jules_extract_patch() {
    jq -c '[.activities[]?.artifacts[]?.changeSet?.gitPatch? | select((.unidiffPatch // "") != "")] | .[-1] // empty'
}

jules_existing_state_json() {
    local state_file="$1"
    if [[ -f "$state_file" ]]; then
        jq -c . "$state_file" 2>/dev/null || printf '{}\n'
    else
        printf '{}\n'
    fi
}

jules_write_state() {
    local state_file="$1" session_json="$2" prompt_hash="$3" source="$4" branch="$5" mode="$6"
    local existing session_name session_id state update_time url pr now tmp
    existing=$(jules_existing_state_json "$state_file")
    session_name=$(jq -r '.name // empty' <<<"$session_json")
    session_id=$(jq -r '.id // empty' <<<"$session_json")
    [[ -z "$session_id" && -n "$session_name" ]] && session_id=$(jules_session_id "$session_name")
    state=$(jq -r '.state // "STATE_UNSPECIFIED"' <<<"$session_json")
    update_time=$(jq -r '.updateTime // .createTime // empty' <<<"$session_json")
    url=$(jq -r '.url // empty' <<<"$session_json")
    pr=$(jules_pull_request_url <<<"$session_json")
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$state_file")"
    tmp=$(mktemp) || return 1
    jq -n \
        --argjson existing "$existing" \
        --arg provider jules \
        --arg sessionName "$session_name" \
        --arg sessionId "$session_id" \
        --arg promptHash "$prompt_hash" \
        --arg source "$source" \
        --arg startingBranch "$branch" \
        --arg mode "$mode" \
        --arg state "$state" \
        --arg updatedAt "$now" \
        --arg lastActivityTime "$update_time" \
        --arg url "$url" \
        --arg pr "$pr" '
        $existing + {
          provider: $provider,
          sessionName: $sessionName,
          sessionId: $sessionId,
          promptHash: $promptHash,
          source: $source,
          startingBranch: $startingBranch,
          mode: $mode,
          state: $state,
          updatedAt: $updatedAt,
          lastActivityTime: $lastActivityTime,
          url: (if $url == "" then null else $url end),
          pullRequestUrl: (if $pr == "" then ($existing.pullRequestUrl // null) else $pr end)
        }
    ' >"$tmp" && mv "$tmp" "$state_file"
}

jules_mark_patch_applied() {
    local state_file="$1" suggested="${2:-}" tmp now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp) || return 1
    jq --arg now "$now" --arg suggested "$suggested" \
        '.patchApplied = true | .patchAppliedAt = $now | .suggestedCommitMessage = (if $suggested == "" then (.suggestedCommitMessage // null) else $suggested end)' \
        "$state_file" >"$tmp" && mv "$tmp" "$state_file"
}

jules_remote_progress() {
    local state="$1" session_name="$2"
    _RALPH_REMOTE_PROGRESS=1
    _RALPH_REMOTE_STATE="$state"
    _RALPH_REMOTE_SESSION="$session_name"
    export _RALPH_REMOTE_PROGRESS _RALPH_REMOTE_STATE _RALPH_REMOTE_SESSION
}

jules_create_or_resume_session() {
    local prompt="$1" log_file="$2" state_file mode prompt_hash existing session_name source branch title payload session_json
    state_file=$(jules_state_file)
    mode="${RALPH_JULES_MODE:-pr}"
    prompt_hash=$(jules_prompt_hash "$prompt")
    existing=$(jules_existing_state_json "$state_file")
    session_name=$(jq -r '.sessionName // empty' <<<"$existing")
    source=$(jq -r '.source // empty' <<<"$existing")
    branch=$(jq -r '.startingBranch // empty' <<<"$existing")

    if [[ -n "$session_name" ]]; then
        log_info "Resuming Jules session: $session_name"
        session_json=$(jules_get_session "$session_name") || return 1
        jules_write_state "$state_file" "$session_json" "$prompt_hash" "$source" "$branch" "$mode"
        printf '%s\n' "$session_json"
        return 0
    fi

    source=$(jules_resolve_source || true)
    if [[ -z "$source" && "${RALPH_JULES_ALLOW_REPOLESS:-0}" != "1" ]]; then
        log_error "Could not resolve Jules source. Set RALPH_JULES_SOURCE or connect/list the repo in Jules."
        return 1
    fi
    branch="${RALPH_JULES_STARTING_BRANCH:-$(jules_git_branch)}"
    branch="${branch:-main}"
    title="${RALPH_JULES_TITLE:-Ralph: $(basename "${PROJECT_DIR:-.}") ${RUN_ID:-manual}}"
    payload=$(jules_create_payload "$prompt" "$title" "$source" "$branch")
    printf 'Creating Jules session title=%s source=%s branch=%s mode=%s\n' "$title" "${source:-repoless}" "$branch" "$mode" >>"$log_file"
    session_json=$(jules_create_session "$payload") || return 1
    jules_write_state "$state_file" "$session_json" "$prompt_hash" "$source" "$branch" "$mode"
    printf '%s\n' "$session_json"
}

jules_wait_for_completion() {
    local session_name="$1" state_file="$2" prompt_hash="$3" source="$4" branch="$5" mode="$6" log_file="$7"
    local timeout="${RALPH_JULES_TIMEOUT:-7200}" interval="${RALPH_JULES_POLL_INTERVAL:-15}"
    local start=$SECONDS session_json state elapsed
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=7200
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=15

    while true; do
        session_json=$(jules_get_session "$session_name") || return 1
        state=$(jq -r '.state // "STATE_UNSPECIFIED"' <<<"$session_json")
        jules_write_state "$state_file" "$session_json" "$prompt_hash" "$source" "$branch" "$mode"
        jules_remote_progress "$state" "$session_name"
        printf 'Jules session %s state=%s\n' "$session_name" "$state" >>"$log_file"
        if declare -F run_manifest_heartbeat >/dev/null 2>&1; then
            run_manifest_heartbeat "remote_${state,,}" "${_RALPH_CURRENT_ITERATION:-0}" 0 || true
        fi

        case "$state" in
            COMPLETED)
                printf '%s\n' "$session_json"
                return 0
                ;;
            FAILED)
                printf '%s\n' "$session_json"
                return 1
                ;;
            AWAITING_PLAN_APPROVAL)
                if [[ "${RALPH_JULES_AUTO_APPROVE_PLAN:-0}" == "1" ]]; then
                    jules_approve_plan "$session_name" || return 1
                    printf 'Approved Jules plan for %s\n' "$session_name" >>"$log_file"
                else
                    printf '%s\n' "$session_json"
                    return 76
                fi
                ;;
            AWAITING_USER_FEEDBACK|PAUSED)
                printf '%s\n' "$session_json"
                return 76
                ;;
        esac

        elapsed=$((SECONDS - start))
        if [[ "$timeout" -eq 0 || "$elapsed" -ge "$timeout" ]]; then
            printf '%s\n' "$session_json"
            return 75
        fi
        sleep "$interval"
    done
}

jules_patch_base_ok() {
    local expected="$1" current
    [[ -n "$expected" ]] || return 0
    current=$(git -C "${PROJECT_DIR:-.}" rev-parse HEAD 2>/dev/null) || return 1
    [[ "$expected" == "$current" ]] && return 0
    git -C "${PROJECT_DIR:-.}" merge-base --is-ancestor "$expected" HEAD 2>/dev/null
}

jules_apply_patch() {
    local patch_json="$1" state_file="$2" log_file="${3:-/dev/null}" base patch suggested
    base=$(jq -r '.baseCommitId // empty' <<<"$patch_json")
    patch=$(jq -r '.unidiffPatch // empty' <<<"$patch_json")
    suggested=$(jq -r '.suggestedCommitMessage // empty' <<<"$patch_json")
    [[ -n "$patch" ]] || { log_error "Jules completed without a patch artifact"; return 1; }
    if ! jules_patch_base_ok "$base"; then
        log_error "Jules patch base $base is not HEAD or an ancestor of HEAD"
        return 1
    fi
    printf '%s\n' "$patch" | git -C "${PROJECT_DIR:-.}" apply --3way --whitespace=fix >/dev/null 2>>"$log_file" || return 1
    jules_mark_patch_applied "$state_file" "$suggested"
}

jules_send_verification_feedback() {
    local errors="$1" log_file="${2:-${LOG_FILE:-/dev/null}}" state_file session_name state prompt
    state_file=$(jules_state_file)
    [[ -f "$state_file" ]] || return 1
    session_name=$(jq -r '.sessionName // empty' "$state_file")
    state=$(jq -r '.state // empty' "$state_file")
    [[ -n "$session_name" && -n "$errors" ]] || return 1
    case "$state" in FAILED|"") return 1 ;; esac
    prompt=$'Local Ralph verification failed after applying or reviewing your work.\n\nFailure details:\n'"$errors"$'\n\nCorrect the implementation without changing unrelated files.'
    if jules_send_message "$session_name" "$prompt" >/dev/null; then
        printf 'Sent Ralph verification feedback to Jules session %s\n' "$session_name" >>"$log_file"
        return 0
    fi
    return 1
}

run_jules_remote() {
    local _tool="$1" _model="$2" prompt="$3" log_file="$4" output_file="$5"
    local state_file mode prompt_hash session_json session_name source branch wait_json wait_rc state pr activities patch patch_applied
    state_file=$(jules_state_file)
    mode="${RALPH_JULES_MODE:-pr}"
    case "$mode" in pr|patch) ;; *) log_error "Invalid RALPH_JULES_MODE '$mode' (expected pr or patch)"; return 1 ;; esac
    prompt_hash=$(jules_prompt_hash "$prompt")

    session_json=$(jules_create_or_resume_session "$prompt" "$log_file") || return 1
    session_name=$(jq -r '.name // empty' <<<"$session_json")
    [[ -n "$session_name" ]] || { log_error "Jules create/resume response did not include session name"; return 1; }
    source=$(jq -r '.source // empty' "$state_file" 2>/dev/null)
    branch=$(jq -r '.startingBranch // empty' "$state_file" 2>/dev/null)

    wait_rc=0
    wait_json=$(jules_wait_for_completion "$session_name" "$state_file" "$prompt_hash" "$source" "$branch" "$mode" "$log_file") || wait_rc=$?
    state=$(jq -r '.state // "STATE_UNSPECIFIED"' <<<"$wait_json" 2>/dev/null)
    jules_remote_progress "$state" "$session_name"

    case "$wait_rc" in
        0) ;;
        75)
            {
                printf 'Jules remote session is still running.\n'
                printf 'Session: %s\nState: %s\n' "$session_name" "$state"
                jq -r '.url? // empty' <<<"$wait_json" | awk 'NF { print "URL: " $0 }'
            } >"$output_file"
            return 0
            ;;
        76)
            {
                printf 'Jules remote session needs attention.\n'
                printf 'Session: %s\nState: %s\n' "$session_name" "$state"
                jq -r '.url? // empty' <<<"$wait_json" | awk 'NF { print "URL: " $0 }'
            } >"$output_file"
            return 1
            ;;
        *)
            {
                printf 'Jules remote session failed.\n'
                printf 'Session: %s\nState: %s\n' "$session_name" "$state"
            } >"$output_file"
            return 1
            ;;
    esac

    if [[ "$mode" == "patch" ]]; then
        patch_applied=$(jq -r '.patchApplied // false' "$state_file" 2>/dev/null)
        if [[ "$patch_applied" != "true" ]]; then
            activities=$(jules_list_activities "$session_name") || return 1
            patch=$(jules_extract_patch <<<"$activities")
            [[ -n "$patch" ]] || { echo "Jules completed, but no patch artifact was found." >"$output_file"; return 1; }
            jules_apply_patch "$patch" "$state_file" "$log_file" || return 1
        fi
        {
            printf 'Jules remote session completed; patch mode is applied locally.\n'
            printf 'Session: %s\nState: COMPLETED\n' "$session_name"
            jq -r '.suggestedCommitMessage? // empty' "$state_file" | awk 'NF { print "Suggested commit: " $0 }'
            printf '<promise>COMPLETE</promise>\n'
        } >"$output_file"
        return 0
    fi

    pr=$(jules_pull_request_url <<<"$wait_json")
    {
        printf 'Jules remote session completed in PR mode.\n'
        printf 'Session: %s\nState: COMPLETED\n' "$session_name"
        [[ -n "$pr" ]] && printf 'Pull request: %s\n' "$pr"
        printf '<promise>COMPLETE</promise>\n'
    } >"$output_file"
    return 0
}

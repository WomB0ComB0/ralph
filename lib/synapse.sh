#!/bin/bash
# lib/synapse.sh — Ralph <-> Synapse (agent backplane) client adapter.
#
# LOCAL integration. Points ralph's grounding/memory/tools + a per-agent LIVE TEST at a running
# Synapse (the multi-tenant governance "org-brain" service: tenant-scoped /retrieve, /context.*,
# /tool.execute, /runs.*). Pure curl + jq — no new dependencies. Additive: nothing here runs unless
# you invoke `ralph synapse ...` / `ralph agents ...` or set SYNAPSE_ENABLED=1 for the (optional) loop
# grounding hook.
#
# Config (env vars — set them in .ralphrc [sourced by load_config], ralph.json->env, or your shell):
#   SYNAPSE_URL        default http://127.0.0.1:8080
#   SYNAPSE_TENANT     default ralph-dev            tenant_id / X-Tenant-Id
#   SYNAPSE_PRINCIPAL  default agent:ralph          default X-Principal-Id when none is passed
#   SYNAPSE_TOKEN      optional                     Bearer JWT; when set, sent as Authorization (X-* then ignored server-side)
#   SYNAPSE_TIMEOUT    default 10                   per-call seconds
#   SYNAPSE_RETRIES    default 2                    retries on retriable status (5xx / 429 / network)
#   SYNAPSE_AGENTS     default "claude codex opencode"   agents `ralph agents test` probes
#   SYNAPSE_ENABLED    default 0                    gate for the optional in-loop grounding hook
#
# Auth model: default deployment is trusted-headers (no token) — safe ONLY behind a trusted hop.
# The request-body tenant_id MUST equal X-Tenant-Id or Synapse returns 403.

# --- config resolution (lazy, per-call, so ordering vs load_config never matters) -------------------
_syn_url()       { echo "${SYNAPSE_URL:-http://127.0.0.1:8080}"; }
_syn_tenant()    { echo "${SYNAPSE_TENANT:-ralph-dev}"; }
_syn_principal() { echo "${1:-${SYNAPSE_PRINCIPAL:-agent:ralph}}"; }
_syn_timeout()   { echo "${SYNAPSE_TIMEOUT:-10}"; }
# Millisecond clock with a portable fallback (GNU date has %N; BSD/macOS does not).
_syn_ms()        { local n; n=$(date +%s%3N 2>/dev/null); [[ "$n" == *N* || -z "$n" ]] && n=$(( $(date +%s) * 1000 )); echo "$n"; }

# Populate the global _SYN_HDR curl header array for a principal.
_syn_headers() {
    local principal="$1"
    _SYN_HDR=(-H "Content-Type: application/json"
              -H "X-Principal-Id: $principal"
              -H "X-Tenant-Id: $(_syn_tenant)")
    [[ -n "${SYNAPSE_TOKEN:-}" ]] && _SYN_HDR+=(-H "Authorization: Bearer $SYNAPSE_TOKEN")
    return 0
}

#######################################
# Core Synapse call. Classifies HTTP status; retries only retriable ones.
# Args: METHOD PATH PRINCIPAL [JSON_BODY]
# Prints: response body on 2xx (and on 4xx, for the caller to inspect)
# Returns: 0 ok | 40 bad-request | 41 unauthorized | 43 forbidden(tenant) | 44 not-found
#          42 retriable-exhausted | 1 unexpected
#######################################
_synapse_call() {
    local method="$1" path="$2" principal="$3" body="${4:-}"
    local url; url="$(_syn_url)$path"
    _syn_headers "$principal"
    local retries="${SYNAPSE_RETRIES:-2}" attempt=0 delay=1 out code payload
    while :; do
        local args=(-sS -m "$(_syn_timeout)" -X "$method" "${_SYN_HDR[@]}" -w $'\n%{http_code}')
        [[ -n "$body" ]] && args+=(--data "$body")
        out=$(curl "${args[@]}" "$url" 2>/dev/null)
        code="${out##*$'\n'}"; payload="${out%$'\n'*}"
        case "$code" in
            2*) printf '%s' "$payload"; return 0 ;;
            400) log_error "synapse ${path}: 400 bad request"; printf '%s' "$payload"; return 40 ;;
            401) log_error "synapse ${path}: 401 unauthorized (check SYNAPSE_TOKEN / principal)"; return 41 ;;
            403) log_error "synapse ${path}: 403 forbidden (body tenant_id != SYNAPSE_TENANT '$(_syn_tenant)'?)"; return 43 ;;
            404) log_error "synapse ${path}: 404 not found (route enabled? SYNAPSE_URL correct?)"; return 44 ;;
            429|5*|000|"")
                if [[ $attempt -lt $retries ]]; then
                    attempt=$((attempt + 1))
                    log_warning "synapse ${path}: ${code:-network} — retry ${attempt}/${retries}"
                    sleep "$delay"; delay=$((delay * 2)); continue
                fi
                log_error "synapse ${path}: ${code:-network} after ${retries} retries"; return 42 ;;
            *) log_error "synapse ${path}: unexpected http ${code}"; printf '%s' "$payload"; return 1 ;;
        esac
    done
}

# --- thin wrappers over the agent-facing endpoints --------------------------------------------------

# GET /health — returns 0 iff {"status":"ok"}
synapse_ping() {
    local out; out=$(_synapse_call GET /health "$(_syn_principal)") || return $?
    jq -e '.status=="ok"' >/dev/null 2>&1 <<<"$out"
}

# POST /retrieve  <query> [top_k] [principal]  -> prints the RetrieveResponse JSON
synapse_retrieve() {
    local query="$1" top_k="${2:-5}" principal; principal="$(_syn_principal "${3:-}")"
    local body; body=$(jq -nc --arg t "$(_syn_tenant)" --arg p "$principal" --arg q "$query" --argjson k "$top_k" \
        '{tenant_id:$t, principal_id:$p, query:$q, retrieval:{top_k:$k, mmr:true}}') || return 1
    _synapse_call POST /retrieve "$principal" "$body"
}

# Retrieve, formatted as a prompt-injectable <synapse_context> block (empty output when nothing/off).
synapse_ground() {
    local query="$1" principal="${2:-}" out txt
    out=$(synapse_retrieve "$query" "${SYNAPSE_GROUND_TOPK:-5}" "$principal") || return 0   # fail OPEN
    txt=$(jq -r '(.results // [])[] | "- (" + (.source_uri // .doc_id) + ") " + ((.text // "")[:400])' 2>/dev/null <<<"$out") || return 0
    [[ -n "$txt" ]] && printf '<synapse_context>\n%s\n</synapse_context>\n' "$txt"
    return 0
}

# POST /context.get [principal] -> prints the Context JSON
synapse_context_get() {
    local principal; principal="$(_syn_principal "${1:-}")"
    _synapse_call POST /context.get "$principal" "$(jq -nc --arg p "$principal" '{principal_id:$p}')"
}

# POST /context.upsert  <context-json-fragment> [principal]  (principal_id + tenant_id injected)
synapse_context_put() {
    local body="$1" principal; principal="$(_syn_principal "${2:-}")"
    body=$(jq -c --arg p "$principal" --arg t "$(_syn_tenant)" '. + {principal_id:$p, tenant_id:$t}' <<<"$body") || return 1
    _synapse_call POST /context.upsert "$principal" "$body"
}

# POST /tool.execute  <json> [principal]
synapse_tool_execute() { _synapse_call POST /tool.execute "$(_syn_principal "${2:-}")" "$1"; }
# POST /runs.start  <json> [principal]
synapse_run_start()    { _synapse_call POST /runs.start    "$(_syn_principal "${2:-}")" "$1"; }
# POST /runs.resume <json> [principal]
synapse_run_resume()   { _synapse_call POST /runs.resume   "$(_syn_principal "${2:-}")" "$1"; }

# --- per-agent LIVE TEST ----------------------------------------------------------------------------

# One end-to-end smoke step. Reads caller locals (U, why) via bash dynamic scope. Args: name jq method path [body]
_syn_lt_step() {
    local name="$1" test="$2" method="$3" path="$4" b="${5:-}"
    local args=(-sS -m "$(_syn_timeout)" -X "$method" "${_SYN_HDR[@]}" -w $'\n%{http_code}')
    [[ -n "$b" ]] && args+=(--data "$b")
    local t0 t1 ms out code
    t0=$(_syn_ms); out=$(curl "${args[@]}" "${U}${path}" 2>/dev/null); t1=$(_syn_ms); ms=$((t1 - t0))
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    if [[ "$code" =~ ^2 ]] && jq -e "$test" >/dev/null 2>&1 <<<"$out"; then
        printf '  [PASS] %-16s %sms\n' "$name" "$ms"; return 0
    fi
    printf '  [FAIL] %-16s http=%s %sms\n' "$name" "${code:-net}" "$ms"; why="${name}(${code:-net})"; return 1
}

_syn_lt_fail() {   # record a durable signal so a recurrence escalates (dedup by theme)
    local agent="$1" why="$2"
    declare -F record_signal >/dev/null 2>&1 || return 0
    record_signal synapse_livetest_failure \
        "agent<->synapse live-test failed for ${agent}" \
        "${why}" \
        "check SYNAPSE_URL / SYNAPSE_TOKEN / SYNAPSE_TENANT; failing step ${why}" \
        synapse,livetest high synapse_live_test >/dev/null 2>&1 || true
}

# synapse_live_test [agent] — /health -> /context.upsert+get round-trip -> /retrieve, within a timeout,
# asserting shape + latency. Non-zero exit on the FIRST failure (so cron/systemd/CI catch it).
synapse_live_test() {
    local agent="${1:-ralph}" principal="agent:${1:-ralph}"
    local U T why=""
    U="$(_syn_url)"; T="$(_syn_tenant)"
    _syn_headers "$principal"
    printf 'agent %s -> %s (tenant %s)\n' "$agent" "$U" "$T"

    _syn_lt_step health '.status=="ok"' GET /health \
        || { _syn_lt_fail "$agent" "$why"; return 1; }
    _syn_lt_step context.upsert '.status=="upserted"' POST /context.upsert \
        "$(jq -nc --arg p "$principal" --arg t "$T" '{principal_id:$p,tenant_id:$t,active_projects:["livetest"],data_classification:{contains_pii:false,special_category:false}}')" \
        || { _syn_lt_fail "$agent" "$why"; return 1; }
    _syn_lt_step context.get '.active_projects==["livetest"]' POST /context.get \
        "$(jq -nc --arg p "$principal" '{principal_id:$p}')" \
        || { _syn_lt_fail "$agent" "$why"; return 1; }
    _syn_lt_step retrieve '.trace_id and (.results|type=="array")' POST /retrieve \
        "$(jq -nc --arg t "$T" --arg p "$principal" '{tenant_id:$t,principal_id:$p,query:"livetest ping",retrieval:{top_k:1}}')" \
        || { _syn_lt_fail "$agent" "$why"; return 1; }

    printf '  [PASS] live-test %s OK\n' "$agent"
    return 0
}

# --- subcommand handlers (dispatched from lib/engine.sh main()) -------------------------------------

# ralph agents test [agent...] | list
handle_agents_command() {
    local sub="${1:-test}"; shift 2>/dev/null || true
    case "$sub" in
        test)
            local agents=("$@")
            [[ ${#agents[@]} -eq 0 ]] && IFS=$' ,\t\n' read -r -a agents <<<"${SYNAPSE_AGENTS:-claude codex opencode}"
            local fails=0 a
            for a in "${agents[@]}"; do
                synapse_live_test "$a" || fails=$((fails + 1))
                echo
            done
            if [[ $fails -eq 0 ]]; then
                log_success "all ${#agents[@]} agent live-test(s) passed"; return 0
            fi
            log_error "${fails}/${#agents[@]} agent live-test(s) FAILED"; return 1
            ;;
        list)
            local agents; IFS=$' ,\t\n' read -r -a agents <<<"${SYNAPSE_AGENTS:-claude codex opencode}"
            printf '%s\n' "${agents[@]}"
            ;;
        *) echo "Usage: ralph agents {test [agent...] | list}"; return 1 ;;
    esac
}

# ralph synapse {ping|retrieve <query>|context-get [principal]|live-test [agent]}
handle_synapse_command() {
    local sub="${1:-ping}"; shift 2>/dev/null || true
    case "$sub" in
        ping)        synapse_ping && log_success "synapse OK ($(_syn_url))" || { log_error "synapse ping failed ($(_syn_url))"; return 1; } ;;
        retrieve)    synapse_retrieve "$*" ;;
        context-get) synapse_context_get "${1:-}" ;;
        live-test)   synapse_live_test "${1:-ralph}" ;;
        *) echo "Usage: ralph synapse {ping | retrieve <query> | context-get [principal] | live-test [agent]}"; return 1 ;;
    esac
}

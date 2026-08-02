#!/bin/bash
# lib/memory.sh — ralph memory ↔ Synapse bridge.
# Ingests verified skills + mined failure themes into Synapse as idempotent
# documents, and retrieves them back into fix-agent prompts. Fail-open: no Synapse
# error ever blocks a caller. Depends on: synapse.sh (_synapse_ingest_doc,
# synapse_ping, synapse_ground), skills.sh (skill files), mine.sh (_mine_scan,
# _mine_action), signals.sh (record_signal), utils.sh (_signal_sha1).

# Ingest one document; echo the status word. On transport failure, record a deduped
# memory_sync_failed signal and echo "failed". Never returns non-zero.
_memory_ingest_one() {
    local doc="$1" theme="$2" resp status
    if resp=$(_synapse_ingest_doc "$doc" 2>/dev/null); then
        status=$(printf '%s' "$resp" | jq -r '.status // "ingested"' 2>/dev/null)
        [[ "$status" == "ingested" || "$status" == "replayed" ]] || status="ingested"
        printf '%s' "$status"
    else
        record_signal memory_sync_failed \
            "Synapse ingest failed for memory doc" \
            "memory ingest theme $theme" \
            "check Synapse /documents.ingest reachability and auth" \
            "memory,ingest" "low" "memory" >/dev/null 2>&1 || true
        printf 'failed'
    fi
}

# Reconcile verified skills + qualifying mined themes into Synapse. Fail-open.
memory_sync() {
    command_exists jq || { printf 'memory: synced 0 (jq unavailable)\n'; return 0; }
    if declare -F synapse_ping >/dev/null; then
        synapse_ping >/dev/null 2>&1 || { printf 'memory: synced 0 (Synapse unreachable)\n'; return 0; }
    fi
    local ingested=0 replayed=0 failed=0 total=0 st

    # Verified skills.
    local kdir="${SKILL_DIR:-.ralph/artifacts/skills}" kf theme problem resolution hash doc_id content doc
    if [[ -d "$kdir" ]]; then
        for kf in "$kdir"/*.json; do
            [[ -f "$kf" ]] || continue
            jq -e '.verified==true' "$kf" >/dev/null 2>&1 || continue
            theme=$(jq -r '.theme_key // ""' "$kf" 2>/dev/null); [[ -n "$theme" ]] || continue
            problem=$(jq -r '.problem // ""' "$kf" 2>/dev/null)
            resolution=$(jq -r '.resolution // ""' "$kf" 2>/dev/null)
            hash=$(printf '%s' "$theme" | _signal_sha1 2>/dev/null | cut -c1-12)
            doc_id="ralph-skill-$hash"
            content="Trigger: $problem"$'\n'"Fix: $resolution"
            doc=$(jq -nc --arg id "$doc_id" --arg uri "ralph://skill/$theme" --arg title "$problem" \
                --arg content "$content" --arg theme "$theme" \
                '{doc_id:$id, source_system:"ralph", source_uri:$uri, title:$title,
                  content_type:"text/plain", language:"en", owners:["agent:ralph"],
                  metadata:{kind:"ralph_skill", verified:true, theme:$theme}, content:$content}') || continue
            st=$(_memory_ingest_one "$doc" "$theme")
            total=$((total+1)); case "$st" in ingested) ingested=$((ingested+1));; replayed) replayed=$((replayed+1));; *) failed=$((failed+1));; esac
        done
    fi

    # Mined themes passing the feed gate (freq>=RALPH_MINE_MIN_FREQ AND distinct_runs>=2),
    # same default/env-override as mine_feed so the two gates never diverge.
    local scan qualifying tkey kind tool tier freq runs reg regj
    local min="${RALPH_MINE_MIN_FREQ:-3}"
    [[ "$min" =~ ^[0-9]+$ ]] || min=3
    scan=$(_mine_scan 2>/dev/null)
    qualifying=$(printf '%s' "$scan" | jq -r --argjson min "$min" '
        .[] | select(.frequency >= $min and .distinct_runs >= 2)
        | [.theme,.kind,.tool,.tier,(.frequency|tostring),(.distinct_runs|tostring),(.regress|tostring)] | @tsv' 2>/dev/null)
    while IFS=$'\t' read -r tkey kind tool tier freq runs reg; do
        [[ -n "$tkey" ]] || continue
        hash=$(printf '%s' "$tkey" | _signal_sha1 2>/dev/null | cut -c1-12)
        doc_id="ralph-theme-$hash"
        content="Recurring $kind failures on $tool/$tier: $freq iterations across $runs runs. $(_mine_action "$kind")"
        [[ "$reg" == "true" ]] && regj=true || regj=false
        doc=$(jq -nc --arg id "$doc_id" --arg uri "ralph://theme/$tkey" \
            --arg title "$kind failures on $tool/$tier" --arg content "$content" \
            --argjson freq "$freq" --argjson reg "$regj" \
            '{doc_id:$id, source_system:"ralph", source_uri:$uri, title:$title,
              content_type:"text/plain", language:"en", owners:["agent:ralph"],
              metadata:{kind:"ralph_theme", regress:$reg, frequency:$freq}, content:$content}') || continue
        st=$(_memory_ingest_one "$doc" "$tkey")
        total=$((total+1)); case "$st" in ingested) ingested=$((ingested+1));; replayed) replayed=$((replayed+1));; *) failed=$((failed+1));; esac
    done <<< "$qualifying"

    printf 'memory: synced %s (%s ingested, %s replayed, %s failed)\n' "$total" "$ingested" "$replayed" "$failed"
    return 0
}

# Retrieve a prompt-injectable <synapse_context> block for a query. Always rc 0.
memory_ground() {
    local query="${1:-}"
    [[ -n "$query" ]] || return 0
    declare -F synapse_ground >/dev/null || return 0
    synapse_ground "$query" 2>/dev/null || return 0
    return 0
}

# CLI entrypoint: ralph memory [--sync] [--ground <query>]
handle_memory_command() {
    local do_sync=0 ground_q="" saw=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sync)   do_sync=1; saw=1 ;;
            --ground)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    ground_q="$2"; shift
                else
                    log_warning "memory: --ground requires a query"
                fi
                saw=1 ;;
            -h|--help) saw=0; break ;;
            *) log_warning "memory: ignoring unknown argument: $1"; saw=1 ;;
        esac
        shift
    done
    if [[ "$saw" == "0" ]]; then
        printf 'usage: ralph memory [--sync] [--ground <query>]\n'
        printf '  --sync            ingest verified skills + mined themes into Synapse (idempotent)\n'
        printf '  --ground <query>  print a <synapse_context> block for <query> (fail-open)\n'
        return 0
    fi
    [[ "$do_sync" == "1" ]] && memory_sync
    [[ -n "$ground_q" ]] && memory_ground "$ground_q"
    return 0
}

#!/bin/bash
# shellcheck disable=SC2154
#######################################
# Signal + global LOG.md compounding layer.
#
# A durable, per-project tier of DEDUPLICATED "patterns the loop keeps re-hitting",
# stored one git-diffable JSON per signal under $SIGNAL_DIR, surfaced as a bounded
# digest into the prompt, and narrated append-only into $LOG_MD. Sits between the
# 2-minute bus.db swarm window and the HOME-global genetic memory. Dedup is a side
# effect of filename existence (theme_key = filename). All mutations are atomic
# (jq -> tmp -> mv); every function degrades to a no-op if jq is unavailable.
#######################################

# UTC, sortable timestamp; honors $RALPH_NOW for deterministic tests.
_signal_now() {
    if [[ -n "${RALPH_NOW:-}" ]]; then
        printf '%s\n' "$RALPH_NOW"
    else
        date -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

# ISO-8601 -> epoch seconds (GNU then BSD date); 0 on failure/null.
_signal_epoch() {
    local iso="$1"
    [[ -z "$iso" || "$iso" == "null" ]] && { echo 0; return; }
    date -u -d "$iso" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
        || echo 0
}

# sha1 hex digest from stdin. Portable: sha1sum (Linux), shasum -a 1 (macOS),
# cksum as a last-resort stable-ish fallback.
_signal_sha1() {
    if command_exists sha1sum; then sha1sum
    elif command_exists shasum; then shasum -a 1
    else cksum; fi
}

# Comma-separated string -> trimmed JSON array (empty -> []).
_signal_csv_to_json() {
    local csv="$1"
    [[ -z "$csv" ]] && { echo '[]'; return; }
    printf '%s' "$csv" | jq -R 'split(",") | map(sub("^ +";"") | sub(" +$";"")) | map(select(length > 0))' 2>/dev/null || echo '[]'
}

# Bump severity one notch (low -> medium -> high).
_signal_bump() {
    case "$1" in
        low) echo medium ;;
        medium) echo high ;;
        *) echo high ;;
    esac
}

#######################################
# Escalate severity by frequency (never downgrades). PURE.
# Arguments: $1 current severity, $2 frequency
#######################################
_signal_escalate() {
    local cur="$1" freq="$2" out="$1"
    [[ "$freq" =~ ^[0-9]+$ ]] || freq=0
    if [[ $freq -ge 6 ]]; then
        out=high
    elif [[ $freq -ge 3 ]]; then
        [[ "$cur" == high ]] && out=high || out=medium
    fi
    # Never downgrade below the current severity.
    if [[ "$cur" == high ]]; then
        out=high
    elif [[ "$cur" == medium && "$out" == low ]]; then
        out=medium
    fi
    echo "$out"
}

#######################################
# Compute the deduplication theme key from a type + a signature string. PURE,
# no filesystem access. key = "<type_slug>--<normalized_signature>". The ordering
# (protect identifier tokens BEFORE blanking bare numbers) is load-bearing.
# Arguments: $1 type, $2 signature (evidence, fallback observation)
#######################################
_signal_theme_key() {
    local type="$1" sig="$2"
    local type_slug full_norm trimmed normsig
    type_slug=$(printf '%s' "$type" | tr '[:upper:]_ ' '[:lower:]--' | tr -cd 'a-z0-9-')

    full_norm=$(printf '%s' "$sig" \
        | sed -E 's#(/?[^ ]*/)([A-Za-z0-9_.-]+\.[A-Za-z0-9]+)#\2#g' \
        | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[t0-9:.]*z?//gi; s/[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?//g' \
        | sed -E 's/\b0x[0-9a-f]+\b//gi; s/\b[0-9a-f]{7,40}\b//gi' \
        | sed -E 's/:[0-9]+:[0-9]+//g; s/:[0-9]+//g; s/\bline [0-9]+//gi' \
        | sed -E 's/\bbd-([0-9]+)/bdid\1/gi' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/(^|[^a-z0-9])[0-9]+/\1N/g; s/(^|[^a-z0-9])[0-9]+/\1N/g' \
        | tr -c 'a-z0-9 -' ' ' \
        | tr -s ' ' '-' | tr -s '-' | sed 's/^-*//; s/-*$//')
    trimmed=$(printf '%s' "$full_norm" | cut -d- -f1-8)
    normsig="$trimmed"
    if [[ "$full_norm" != "$trimmed" ]]; then
        # Truncated (>8 tokens): disambiguate so distinct long signatures sharing
        # an 8-token prefix don't false-merge onto one key.
        normsig="${trimmed}-$(printf '%s' "$full_norm" | _signal_sha1 2>/dev/null | cut -c1-8)"
    fi

    local key="${type_slug}--${normsig}"
    if [[ ${#key} -gt 100 ]]; then
        key="${key:0:91}-$(printf '%s' "$full_norm" | _signal_sha1 2>/dev/null | cut -c1-8)"
    fi
    printf '%s\n' "$key"
}

# Path to a signal file for a theme key.
_signal_path() {
    printf '%s\n' "${SIGNAL_DIR:-.ralph/artifacts/signals}/$1.json"
}

#######################################
# Initialize signal storage + the LOG.md header. Idempotent.
#######################################
init_signals() {
    local dir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    local archive="${SIGNAL_ARCHIVE_DIR:-$dir/.archive}"
    local log="${LOG_MD:-.ralph/artifacts/LOG.md}"
    mkdir -p "$dir" "$archive" 2>/dev/null || true
    if [[ ! -f "$log" ]]; then
        printf '# Ralph LOG — cross-run loop narrative\n\n' > "$log" 2>/dev/null || true
    fi
}

#######################################
# Record (create or dedup-upsert) a signal. Core entry point.
# Arguments:
#   $1 type, $2 observation, $3 evidence, $4 suggested_action,
#   [$5 tags_csv] [$6 severity] [$7 source] [$8 possible_causes_csv]
# Returns: echoes the theme_key
#######################################
record_signal() {
    command_exists jq || return 0
    local type="$1" observation="$2" evidence="$3" action="$4"
    local tags_csv="${5:-}" severity="${6:-}" source="${7:-}" causes_csv="${8:-}"
    [[ -n "$type" ]] || return 0

    local sig="${evidence:-$observation}"
    local key file dir now run
    key=$(_signal_theme_key "$type" "$sig")
    dir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    mkdir -p "$dir" 2>/dev/null || true
    file="$dir/$key.json"
    now=$(_signal_now); run="${RUN_ID:-unknown}"

    local tags_json causes_json src_json tmp
    tags_json=$(_signal_csv_to_json "$tags_csv")
    causes_json=$(_signal_csv_to_json "$causes_csv")
    src_json=$(_signal_csv_to_json "$source")
    # Temp on the SAME filesystem as the target so `mv` is a true atomic rename
    # (a cross-FS mv copies bytes and can leave a torn JSON on a crash).
    tmp=$(mktemp "$dir/.sig.XXXXXX" 2>/dev/null) || tmp=$(mktemp) || return 1

    if [[ -f "$file" ]]; then
        local cur_sev cur_status new_sev set_status regressed freq
        cur_sev=$(jq -r '.severity // "low"' "$file" 2>/dev/null)
        cur_status=$(jq -r '.status // "open"' "$file" 2>/dev/null)
        freq=$(jq -r '.frequency // 0' "$file" 2>/dev/null)
        if [[ -n "$severity" ]]; then
            new_sev="$severity"
        else
            new_sev=$(_signal_escalate "$cur_sev" $((freq + 1)))
        fi
        set_status="$cur_status"
        regressed=false
        if [[ "$cur_status" == "resolved" ]]; then
            set_status="open"
            regressed=true
            new_sev=$(_signal_bump "$new_sev")
        fi
        if jq --arg now "$now" --arg run "$run" --arg ev "$evidence" --arg act "$action" \
              --arg sev "$new_sev" --arg status "$set_status" --argjson reg "$regressed" \
              --argjson src "$src_json" \
              '.frequency = ((.frequency // 0) + 1)
               | .last_seen = $now | .last_run = $run
               | .runs = ((.runs // []) + [$run] | unique)
               | .evidence = (if $ev == "" then .evidence else $ev end)
               | .suggested_action = (if $act == "" then .suggested_action else $act end)
               | .severity = $sev | .status = $status
               | .regressed = ((.regressed // false) or $reg)
               | .sources = ((.sources // []) + $src | unique)
               | (if $reg then .resolved_at = null else . end)' \
              "$file" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$file"
        fi
    else
        local init_sev="${severity:-low}"
        if jq -n --arg key "$key" --arg type "$type" --arg sev "$init_sev" \
              --arg obs "$observation" --arg ev "$evidence" --arg act "$action" \
              --arg now "$now" --arg run "$run" \
              --argjson tags "$tags_json" --argjson causes "$causes_json" --argjson src "$src_json" \
              '{schema_version: 1, theme_key: $key, type: $type, severity: $sev, status: "open",
                domain: "", observation: $obs, evidence: $ev, possible_causes: $causes,
                suggested_action: $act, sources: $src, tags: $tags, frequency: 1,
                first_seen: $now, last_seen: $now, first_run: $run, last_run: $run,
                runs: [$run], resolved_at: null, note: "", regressed: false}' \
              > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$file"
        fi
    fi
    rm -f "$tmp" 2>/dev/null
    printf '%s\n' "$key"
}

# Internal: atomic jq mutation of one signal file.
_signal_set() {
    local key="$1"; shift
    command_exists jq || return 0
    local file="${SIGNAL_DIR:-.ralph/artifacts/signals}/$key.json"
    [[ -f "$file" ]] || return 1
    local tmp; tmp=$(mktemp "$(dirname "$file")/.sig.XXXXXX" 2>/dev/null) || tmp=$(mktemp) || return 1
    if jq "$@" "$file" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"; return 1
    fi
}

signal_ack()     { _signal_set "$1" '.status = "ack"'; }
signal_resolve() {
    local rc=0
    _signal_set "$1" --arg n "$(_signal_now)" --arg note "${2:-}" '.status = "resolved" | .resolved_at = $n | .note = $note' || rc=$?
    # Auto-author a candidate skill from the resolution (guarded: only if skills.sh
    # is sourced; only for recurring signals resolved with a note). Non-fatal — must
    # not clobber the resolve status (return $rc preserves _signal_set's rc).
    declare -F _skill_autocapture >/dev/null && _skill_autocapture "$1" "${2:-}" || true
    return $rc
}
signal_reopen()  { _signal_set "$1" '.status = "open" | .regressed = true | .resolved_at = null'; }

# Print one signal's JSON.
signal_get() {
    local f="${SIGNAL_DIR:-.ralph/artifacts/signals}/$1.json"
    [[ -f "$f" ]] && cat "$f"
}

#######################################
# Resolve all OPEN signals of a given type-family (auto-resolve on a clean streak).
# Arguments: $1 type
#######################################
_signal_auto_resolve_family() {
    command_exists jq || return 0
    local type="$1"
    local dir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    [[ -d "$dir" ]] || return 0
    local f t status k
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        t=$(jq -r '.type // ""' "$f" 2>/dev/null)
        status=$(jq -r '.status // ""' "$f" 2>/dev/null)
        if [[ "$t" == "$type" && "$status" == "open" ]]; then
            k=$(basename "$f" .json)
            signal_resolve "$k" "auto-resolved: clean for ${RALPH_SIGNAL_CLEAN_STREAK:-2} iterations"
        fi
    done
}

#######################################
# Surface a bounded digest of open/regressed signals into the prompt.
# Arguments: [$1 limit]
#######################################
recall_signals() {
    command_exists jq || return 0
    local limit="${1:-${RALPH_SIGNAL_RECALL:-5}}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=5   # a bad RALPH_SIGNAL_RECALL must not break jq's slice
    local dir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    [[ -d "$dir" ]] || return 0

    local tmpf f lines
    tmpf=$(mktemp) || return 0
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        # Read each file in isolation: one corrupt JSON must not blank the digest.
        jq -c 'select(.status == "open" or .status == "ack")
            | {k: .theme_key, sev: .severity, f: .frequency, reg: .regressed,
               ls: .last_seen, obs: .observation, act: .suggested_action}' "$f" 2>/dev/null >> "$tmpf" || true
    done
    lines=$(jq -rs --argjson limit "$limit" 'def sevrank: {"high":3,"medium":2,"low":1}[.sev] // 0;
            sort_by([(if .reg then 1 else 0 end), sevrank, .f, .ls]) | reverse
            | .[0:$limit]
            | .[] | "- [\(.sev) x\(.f)\(if .reg then " REGRESSED" else "" end)] \(.k): \(.obs) -> \(.act)"' "$tmpf" 2>/dev/null)
    rm -f "$tmpf"
    [[ -z "$lines" ]] && return 0
    printf '\n<signals>\nRecurring patterns this loop keeps hitting (act on these or resolve them):\n%s\n</signals>\n' "$lines"
}

#######################################
# Append one timestamped, artifact-linked entry to LOG.md (forward-chronological).
# Arguments: $1 summary, [$2 artifact_links], [$3 signal_keys], [$4 meta]
#######################################
log_append() {
    local summary="$1" links="${2:-}" sigs="${3:-}" meta="${4:-}"
    local log="${LOG_MD:-.ralph/artifacts/LOG.md}"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    local now run iter
    now=$(_signal_now); run="${RUN_ID:-unknown}"; iter="${RALPH_LOG_ITER:-${ITERATION:-?}}"
    {
        printf '## %s · run %s · iter %s\n' "$now" "$run" "$iter"
        printf -- '- summary: %s\n' "$summary"
        [[ -n "$meta" ]] && printf -- '- delta: %s\n' "$meta"
        [[ -n "$sigs" ]] && printf -- '- signals: %s\n' "$sigs"
        [[ -n "$links" ]] && printf -- '- artifacts: %s\n' "$links"
        printf '\n'
    } >> "$log" 2>/dev/null || true
    return 0
}

#######################################
# Surface the last N LOG.md entries (split on '## ').
# Arguments: [$1 n]
#######################################
recall_log() {
    local n="${1:-${RALPH_LOG_RECALL:-8}}"
    local log="${LOG_MD:-.ralph/artifacts/LOG.md}"
    [[ -f "$log" ]] || return 0
    local body
    # tail-bound the read so an ever-growing LOG isn't rescanned in full each call;
    # 400 lines covers far more than the recalled entry count.
    body=$(tail -n 400 "$log" 2>/dev/null | awk -v n="$n" '
        /^## / { idx++; blocks[idx] = "" }
        { if (idx > 0) blocks[idx] = blocks[idx] $0 "\n" }
        END {
            start = (idx > n) ? idx - n + 1 : 1
            for (i = start; i <= idx; i++) printf "%s", blocks[i]
        }')
    [[ -z "$body" ]] && return 0
    printf '\n<global_log>\nRecent loop history (most recent last):\n%s</global_log>\n' "$body"
}

#######################################
# Archive resolved/stale signals (and very-old low open signals) into .archive/.
# Arguments: [$1 ttl_days]
#######################################
prune_signals() {
    command_exists jq || return 0
    local ttl="${1:-${RALPH_SIGNAL_TTL_DAYS:-14}}"
    local dir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    local archive="${SIGNAL_ARCHIVE_DIR:-$dir/.archive}"
    [[ -d "$dir" ]] || return 0
    mkdir -p "$archive" 2>/dev/null || true

    local now_epoch f status last sev last_epoch age_days
    now_epoch=$(_signal_epoch "$(_signal_now)")
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        status=$(jq -r '.status // "open"' "$f" 2>/dev/null)
        last=$(jq -r '.last_seen // ""' "$f" 2>/dev/null)
        sev=$(jq -r '.severity // "low"' "$f" 2>/dev/null)
        last_epoch=$(_signal_epoch "$last")
        # Skip files with an unparseable/missing date rather than treating epoch 0 as
        # ancient and wrongly archiving a recent-but-corrupt signal.
        [[ "$last_epoch" =~ ^[0-9]+$ && "$last_epoch" -gt 0 ]] || continue
        age_days=$(( (now_epoch - last_epoch) / 86400 ))
        if [[ "$status" != "open" && $age_days -ge $ttl ]]; then
            mv -f "$f" "$archive/" 2>/dev/null || true
        elif [[ "$status" == "open" && $age_days -ge ${RALPH_SIGNAL_OPEN_TTL_DAYS:-30} ]]; then
            # Any open signal that hasn't recurred in a long time has effectively
            # decayed — age it out (any severity) so non-auto-resolving families
            # (loop_detected/task_repeat_failure/lazy_streak/arch_drift) can't pin
            # a recall slot forever.
            mv -f "$f" "$archive/" 2>/dev/null || true
        fi
    done
}

#######################################
# Human-readable signal table (CLI).
# Arguments: [$1 status filter]
#######################################
list_signals() {
    command_exists jq || { echo "jq required"; return 0; }
    local filter="${1:-}"
    local dir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    [[ -d "$dir" ]] || { echo "No signals."; return 0; }
    local f st any=0
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        st=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
        [[ -n "$filter" && "$st" != "$filter" ]] && continue
        jq -r '"[\(.status)/\(.severity) x\(.frequency)] \(.theme_key) — \(.observation)"' "$f" 2>/dev/null || continue
        any=1
    done
    [[ $any -eq 0 ]] && echo "No signals."
    return 0
}

#######################################
# CLI dispatch: ralph signal [ls|show|ack|resolve|reopen|recall]
#######################################
handle_signal_command() {
    local cmd="${1:-ls}"; shift 2>/dev/null || true
    case "$cmd" in
        ls|list)  list_signals "${1:-}" ;;
        show|get) signal_get "${1:-}" ;;
        ack)      if [[ -n "${1:-}" ]]; then signal_ack "$1" && echo "Acked $1"; else echo "Usage: ralph signal ack <key>"; fi ;;
        resolve)  if [[ -n "${1:-}" ]]; then signal_resolve "$1" "${2:-}" && echo "Resolved $1"; else echo "Usage: ralph signal resolve <key> [note]"; fi ;;
        reopen)   if [[ -n "${1:-}" ]]; then signal_reopen "$1" && echo "Reopened $1"; else echo "Usage: ralph signal reopen <key>"; fi ;;
        recall)   recall_signals ;;
        *)        echo "Usage: ralph signal [ls|show <key>|ack <key>|resolve <key> [note]|reopen <key>|recall]" ;;
    esac
}

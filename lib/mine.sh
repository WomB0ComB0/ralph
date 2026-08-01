#!/bin/bash
# lib/mine.sh — failure-mining meta-loop over the JSONL run ledger.
# Cross-run analysis of .ralph/state/metrics.json. Read-only by default;
# --feed records deduped signals; --propose drafts a dry-run code-fix PR.
# Depends on: utils.sh, signals.sh (record_signal), triage.sh
# (_triage_apply_fix, _triage_default_branch), github.sh (ralph_gh_current_repo).

# Path to the durable run ledger.
_mine_metrics_file() {
    printf '%s\n' "${METRICS_FILE:-${STATE_DIR:-.ralph/state}/metrics.json}"
}

# Scan the ledger into ranked failure-theme aggregates (JSON array on stdout).
# Tolerant: a corrupt line is skipped, never aborts the pass.
_mine_scan() {
    command_exists jq || { printf '[]\n'; return 0; }
    local file="${1:-}"
    [[ -n "$file" ]] || file="$(_mine_metrics_file)"
    [[ -f "$file" ]] || { printf '[]\n'; return 0; }
    local stall="${RALPH_MINE_STALL:-3}" pctl="${RALPH_MINE_TOKEN_P:-95}"
    [[ "$stall" =~ ^[0-9]+$ ]] || stall=3
    [[ "$pctl"  =~ ^[0-9]+$ ]] || pctl=95
    local window="${RALPH_MINE_WINDOW:-50}" baseline="${RALPH_MINE_BASELINE:-200}"
    [[ "$window"   =~ ^[0-9]+$ ]] || window=50
    [[ "$baseline" =~ ^[0-9]+$ ]] || baseline=200
    # Bound the read to the last N ledger lines so the whole-file jq slurp stays
    # O(N), not O(all-history) — the metrics ledger grows unbounded across runs.
    local max="${RALPH_MINE_MAX_LINES:-5000}"
    [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || max=5000
    tail -n "$max" "$file" 2>/dev/null | jq -R -s --argjson stall "$stall" --argjson pctl "$pctl" \
             --argjson win "$window" --argjson base "$baseline" '
      def tier($m): ($m|ascii_downcase) as $l
        | if   ($l|test("opus"))   then "opus"
          elif ($l|test("sonnet")) then "sonnet"
          elif ($l|test("haiku"))  then "haiku"
          elif ($l|test("gemini")) then "gemini"
          elif ($l|test("gpt|o1|o3")) then "gpt"
          elif ($l|test("grok"))   then "grok"
          elif ($l|test("qwen"))   then "qwen"
          elif ($l|test("llama"))  then "llama"
          elif ($l=="" or $l=="auto") then "auto"
          else ($l|capture("^(?<t>[a-z0-9]+)").t // "other") end;
      [ split("\n")[] | select(length>0) | (try fromjson catch empty)
        | select(type=="object") ] as $rows
      | ($rows|length) as $N
      | ($rows | map(.tokens // 0) | sort) as $ts
      | ($ts|length) as $n
      | (if $n==0 then 0 else $ts[ (($n-1) * $pctl / 100) | floor ] end) as $thr
      | [ range(0;$N) as $i | $rows[$i] as $r
          | ( if   ((($r.lazy_streak)//0) >= $stall) then "stall"
              elif (($r.verify_ok) == false)         then "verify_fail"
              elif (($r.changed) == false)           then "no_progress"
              elif ((($r.tokens)//0) > $thr and $thr > 0) then "token_blowup"
              else null end ) as $k
          | select($k != null)
          | { kind:$k, tool:($r.tool//"?"), tier:tier($r.model//""),
              run:($r.run_id//"?"), ts:($r.timestamp//""), idx:$i } ]
      | ($N) as $N
      | group_by(.kind + ":" + .tool + ":" + .tier)
      | map( ([.[] | select(.idx >= ($N-$win))] | length) as $recent
           | ([.[] | select(.idx >= ($N-$win-$base) and .idx < ($N-$win))] | length) as $basec
           | ( ($recent / (if $win>0 then $win else 1 end))
               > ($basec / (if $base>0 then $base else 1 end)) and $recent > 0 ) as $reg
           | { theme:(.[0].kind+":"+.[0].tool+":"+.[0].tier),
               kind:.[0].kind, tool:.[0].tool, tier:.[0].tier,
               frequency: length,
               distinct_runs: ([.[].run]|unique|length),
               first_seen: ([.[].ts]|min),
               last_seen:  ([.[].ts]|max),
               regress: $reg,
               score: (length * ([.[].run]|unique|length) * (if $reg then 2 else 1 end)) } )
      | sort_by(-.score)
    ' 2>/dev/null || printf '[]\n'
}

# Print a one-line summary (+ ranked section unless "quiet").
mine_digest() {
    local mode="${1:-}"
    local top="${RALPH_MINE_TOP:-5}"
    [[ "$top" =~ ^[0-9]+$ ]] || top=5
    local scan nthemes total topline
    scan=$(_mine_scan)
    nthemes=$(printf '%s' "$scan" | jq 'length' 2>/dev/null) || nthemes=0
    [[ "$nthemes" =~ ^[0-9]+$ ]] || nthemes=0
    total=$(printf '%s' "$scan" | jq '[.[].frequency]|add // 0' 2>/dev/null) || total=0
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    topline=$(printf '%s' "$scan" | jq -r '
      if length==0 then "none"
      else .[0] as $t | "\($t.kind) \($t.tool)/\($t.tier) x\($t.frequency)/\($t.distinct_runs)runs" end' 2>/dev/null) || topline="none"
    [[ -n "$topline" ]] || topline="none"
    printf 'mine summary: %s recurring failure themes, %s failing iterations (top: %s)\n' \
        "$nthemes" "$total" "$topline"
    [[ "$mode" == "quiet" ]] && return 0
    [[ "$nthemes" == "0" ]] && return 0
    printf '%s' "$scan" | jq -r --argjson top "$top" '
      .[:$top][] | (if .regress then "!" else " " end) as $m
      | "\($m) [\(.kind)] \(.tool)/\(.tier)  x\(.frequency) across \(.distinct_runs) runs  (last \(.last_seen))"
    ' 2>/dev/null || true
    return 0
}

# Suggested-action hint per failure kind (stable, human-actionable).
_mine_action() {
    case "$1" in
        stall)        printf 'sustained no-progress; check the stall guard, instructions, or intervene\n' ;;
        verify_fail)  printf 'agent completes but verification fails; inspect the verify/build gate for this tool\n' ;;
        no_progress)  printf 'iterations make no file changes; prompt/model may be stuck — check instructions or switch model\n' ;;
        token_blowup) printf 'iteration token cost anomaly; check prompt bloat or oversized artifacts\n' ;;
        *)            printf 'investigate recurring failure\n' ;;
    esac
}

# Record deduped ledger_failure signals for qualifying themes.
mine_feed() {
    command_exists jq || { printf 'mine: fed 0 signal(s) (jq unavailable)\n'; return 0; }
    local min="${RALPH_MINE_MIN_FREQ:-3}"
    [[ "$min" =~ ^[0-9]+$ ]] || min=3
    declare -F init_signals >/dev/null && init_signals
    local scan qualifying fed=0
    scan=$(_mine_scan)
    qualifying=$(printf '%s' "$scan" | jq -r --argjson min "$min" '
      .[] | select(.frequency >= $min and .distinct_runs >= 2)
      | [.theme, .kind, .tool, .tier, (.frequency|tostring), (.distinct_runs|tostring), (.regress|tostring)]
      | @tsv' 2>/dev/null)
    local theme kind tool tier freq runs reg
    while IFS=$'\t' read -r theme kind tool tier freq runs reg; do
        [[ -n "$theme" ]] || continue
        local sev="medium"
        [[ "$kind" == "no_progress" || "$kind" == "token_blowup" ]] && sev="low"
        [[ "$reg" == "true" ]] && sev="high"
        if record_signal ledger_failure \
            "Recurring $kind failures on $tool/$tier ($freq iters, $runs runs)" \
            "ledger failure theme $theme" \
            "$(_mine_action "$kind")" \
            "mined,$kind" "$sev" "mine" >/dev/null 2>&1; then
            fed=$((fed+1))   # count only signals actually recorded, so the reported total can't overstate
        fi
    done <<< "$qualifying"
    printf 'mine: fed %s signal(s)\n' "$fed"
    return 0
}

# Draft a code-fix for the single top recurring theme. Dry-run unless apply=1.
mine_propose() {
    local apply="${1:-0}"
    [[ "$apply" == "1" ]] || apply=0
    command_exists jq || { log_info "mine: jq unavailable; cannot propose."; return 0; }
    local scan top kind tool tier freq runs
    scan=$(_mine_scan)
    top=$(printf '%s' "$scan" | jq -r '.[0] // empty' 2>/dev/null)
    if [[ -z "$top" ]]; then
        log_info "mine: no recurring failure theme to propose a fix for."
        return 0
    fi
    kind=$(printf '%s' "$top" | jq -r '.kind')
    tool=$(printf '%s' "$top" | jq -r '.tool')
    tier=$(printf '%s' "$top" | jq -r '.tier')
    freq=$(printf '%s' "$top" | jq -r '.frequency')
    runs=$(printf '%s' "$top" | jq -r '.distinct_runs')

    local repo=""
    if declare -F ralph_gh_current_repo >/dev/null; then
        repo=$(ralph_gh_current_repo 2>/dev/null) || repo=""
    fi
    if [[ -z "$repo" || "$repo" != */* ]]; then
        log_info "mine: current project is not a GitHub repo; skipping fix proposal (mine/--feed still work)."
        return 0
    fi

    local base hash branch title body prompt
    base=$(_triage_default_branch "$repo" 2>/dev/null) || base=""
    [[ -n "$base" ]] || base="main"
    hash=$(printf '%s' "$top" | jq -r '.theme' | _signal_sha1 2>/dev/null | cut -c1-8)
    [[ -n "$hash" ]] || hash="theme"
    branch="ralph/mine-fix-$hash"
    title="mine: address recurring $kind failures ($tool/$tier)"
    body="Ralph's failure-mining meta-loop found a recurring $kind failure pattern on $tool/$tier: $freq failing iterations across $runs runs. $(_mine_action "$kind")"
    prompt="You are addressing a recurring failure the ralph loop mined from its run ledger.
Failure kind: $kind (tool $tool, model tier $tier), $freq occurrences across $runs runs.
Guidance: $(_mine_action "$kind")
Make the smallest, safest source change that reduces this failure. Do not touch CI, secrets, or unrelated code. If no code change is warranted, make no changes."

    _triage_apply_fix "$repo" "$base" "$branch" "$prompt" "$title" "$body" "$apply" "mine:$kind"
    return 0
}

# CLI entrypoint: ralph mine [--feed] [--propose] [--apply]
handle_mine_command() {
    local do_feed=0 do_propose=0 apply=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --feed)    do_feed=1 ;;
            --propose) do_propose=1 ;;
            --apply)   apply=1; do_propose=1 ;;
            -h|--help)
                printf 'usage: ralph mine [--feed] [--propose] [--apply]\n'
                printf '  (default)   read-only ranked failure-theme digest\n'
                printf '  --feed      also record deduped ledger_failure signals\n'
                printf '  --propose   also draft a dry-run code-fix PR for the top theme\n'
                printf '  --apply     with --propose, actually open the PR (never pushes default)\n'
                return 0 ;;
            *) log_warning "mine: ignoring unknown argument: $1" ;;
        esac
        shift
    done
    mine_digest
    [[ "$do_feed" == "1" ]] && mine_feed
    [[ "$do_propose" == "1" ]] && mine_propose "$apply"
    return 0
}

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
    jq -R -s --argjson stall "$stall" --argjson pctl "$pctl" '
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
      | ($rows | map(.tokens // 0) | sort) as $ts
      | ($ts|length) as $n
      | (if $n==0 then 0 else $ts[ (($n-1) * $pctl / 100) | floor ] end) as $thr
      | [ $rows[] | . as $r
          | ( if   ((($r.lazy_streak)//0) >= $stall) then "stall"
              elif (($r.verify_ok) == false)         then "verify_fail"
              elif (($r.changed) == false)           then "no_progress"
              elif ((($r.tokens)//0) > $thr and $thr > 0) then "token_blowup"
              else null end ) as $k
          | select($k != null)
          | { kind:$k, tool:($r.tool//"?"), tier:tier($r.model//""),
              run:($r.run_id//"?"), ts:($r.timestamp//"") } ]
      | group_by(.kind + ":" + .tool + ":" + .tier)
      | map( { theme:(.[0].kind+":"+.[0].tool+":"+.[0].tier),
               kind:.[0].kind, tool:.[0].tool, tier:.[0].tier,
               frequency: length,
               distinct_runs: ([.[].run]|unique|length),
               first_seen: ([.[].ts]|min),
               last_seen:  ([.[].ts]|max),
               score: (length * ([.[].run]|unique|length)) } )
      | sort_by(-.score)
    ' "$file" 2>/dev/null || printf '[]\n'
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
      .[:$top][] | "  [\(.kind)] \(.tool)/\(.tier)  x\(.frequency) across \(.distinct_runs) runs  (last \(.last_seen))"
    ' 2>/dev/null || true
    return 0
}

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
    jq -R -s --argjson stall "$stall" --argjson pctl "$pctl" \
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
      .[:$top][] | (if .regress then "!" else " " end) as $m
      | "\($m) [\(.kind)] \(.tool)/\(.tier)  x\(.frequency) across \(.distinct_runs) runs  (last \(.last_seen))"
    ' 2>/dev/null || true
    return 0
}

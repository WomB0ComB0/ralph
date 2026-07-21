#!/bin/bash
# TDD harness for the signal + LOG.md compounding layer (lib/signals.sh).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }
ne()  { if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1 (both [$2])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SIGNAL_DIR="$TMP/signals" SIGNAL_ARCHIVE_DIR="$TMP/signals/.archive" LOG_MD="$TMP/LOG.md"
export RUN_ID="20260629T090000-1234-5678"

echo "== _signal_theme_key (pure dedup) =="
k_bd7=$(_signal_theme_key task_repeat_failure "bd-7 tool opencode failed")
k_bd8=$(_signal_theme_key task_repeat_failure "bd-8 tool opencode failed")
ne "bd-7 vs bd-8 distinct" "$k_bd7" "$k_bd8"
k_a=$(_signal_theme_key lazy_streak "no files modified for 3 iterations")
k_b=$(_signal_theme_key lazy_streak "no files modified for 5 iterations")
eq "streak length collapses (3==5)" "$k_a" "$k_b"
k_e1=$(_signal_theme_key validation_failure "error[E0432]: unresolved import in src/main.rs:12")
k_e2=$(_signal_theme_key validation_failure "error[E0432]: unresolved import in /abs/path/src/main.rs:99:4")
eq "same error code+file, diff line/path == same" "$k_e1" "$k_e2"
k_e3=$(_signal_theme_key validation_failure "error[E0433]: different code in src/main.rs")
ne "different error code distinct" "$k_e1" "$k_e3"
long=$(printf 'x%.0s' {1..130})
k_long=$(_signal_theme_key validation_failure "$long alpha beta gamma delta epsilon zeta eta theta iota")
[[ ${#k_long} -le 100 ]] && ok "long key truncated to <=100 (${#k_long})" || bad "key too long: ${#k_long}"
[[ "$k_long" =~ -[0-9a-f]{8}$ ]] && ok "truncated key gets sha suffix" || bad "no sha suffix"
k_cap=$(_signal_theme_key "Validation Failure" "something")
[[ "$k_cap" == validation-failure--* ]] && ok "type slug lowercased/hyphenated" || bad "bad type slug: $k_cap"

echo "== _signal_escalate (pure) =="
eq "(low,2)->low"    low    "$(_signal_escalate low 2)"
eq "(low,3)->medium" medium "$(_signal_escalate low 3)"
eq "(low,6)->high"   high   "$(_signal_escalate low 6)"
eq "(high,1)->high"  high   "$(_signal_escalate high 1)"

echo "== record_signal create + dedup upsert =="
rm -rf "$SIGNAL_DIR"
key=$(record_signal validation_failure "cargo check fails" "error[E0432] in src/main.rs:1" "add mod db")
n1=$(find "$SIGNAL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
eq "first record -> 1 file" 1 "$n1"
record_signal validation_failure "cargo check fails" "error[E0432] in src/main.rs:9" "add mod db" >/dev/null
n2=$(find "$SIGNAL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
eq "same theme -> still 1 file (dedup)" 1 "$n2"
eq "frequency incremented to 2" 2 "$(jq -r .frequency "$SIGNAL_DIR/$key.json")"
jq empty "$SIGNAL_DIR/$key.json" 2>/dev/null && ok "signal is valid JSON" || bad "invalid JSON"
record_signal runtime_failure "go vet fails" "vet error" "fix vet" >/dev/null
eq "different theme -> 2 files" 2 "$(find "$SIGNAL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"

_saved_SIGNAL_DIR="$SIGNAL_DIR"
export SIGNAL_DIR="$TMP/throttle-signals"
rm -rf "$SIGNAL_DIR"
export RALPH_NOW="2026-07-21T00:00:00Z" RALPH_SIGNAL_REWRITE_MIN_SECONDS=3600
throttle_key=$(record_signal runtime_failure "poll failed" "same evidence" "retry")
export RALPH_NOW="2026-07-21T00:30:00Z"
record_signal runtime_failure "poll failed" "same evidence" "retry" >/dev/null
eq "rewrite throttle skips immediate duplicate frequency bump" 1 "$(jq -r .frequency "$SIGNAL_DIR/$throttle_key.json")"
eq "rewrite throttle preserves last_seen while skipped" "2026-07-21T00:00:00Z" "$(jq -r .last_seen "$SIGNAL_DIR/$throttle_key.json")"
export RALPH_NOW="2026-07-21T02:00:00Z"
record_signal runtime_failure "poll failed" "same evidence" "retry" >/dev/null
eq "rewrite throttle allows update after window" 2 "$(jq -r .frequency "$SIGNAL_DIR/$throttle_key.json")"
export SIGNAL_DIR="$_saved_SIGNAL_DIR"
unset RALPH_NOW RALPH_SIGNAL_REWRITE_MIN_SECONDS _saved_SIGNAL_DIR

echo "== lifecycle: resolve then recurrence reopens with regressed =="
signal_resolve "$key" "fixed it"
eq "resolved status" resolved "$(jq -r .status "$SIGNAL_DIR/$key.json")"
record_signal validation_failure "cargo check fails" "error[E0432] in src/main.rs:3" "add mod db" >/dev/null
eq "recurrence reopens" open "$(jq -r .status "$SIGNAL_DIR/$key.json")"
eq "regressed flag set" true "$(jq -r .regressed "$SIGNAL_DIR/$key.json")"
signal_ack "$key"; eq "ack status" ack "$(jq -r .status "$SIGNAL_DIR/$key.json")"

echo "== recall_signals digest (bounded, excludes resolved) =="
rm -rf "$SIGNAL_DIR"; export RALPH_SIGNAL_RECALL=3
for i in 1 2 3 4 5; do record_signal validation_failure "fail $i" "evidence number $i distinct $i" "act" >/dev/null; done
record_signal runtime_failure "resolved one" "ev resolved" "act" >/dev/null
out=$(recall_signals)
[[ "$out" == *"<signals>"* && "$out" == *"</signals>"* ]] && ok "wrapped in <signals>" || bad "no wrapper"
lines=$(grep -c '^- ' <<<"$out"); [[ "$lines" -le 3 ]] && ok "respects RALPH_SIGNAL_RECALL ($lines<=3)" || bad "too many lines: $lines"

echo "== log_append / recall_log (last N, split on '## ') =="
rm -f "$LOG_MD"; export RALPH_LOG_RECALL=8
for i in $(seq 1 12); do log_append "summary $i" "" "" "iter=$i"; done
rl=$(recall_log)
[[ "$rl" == *"<global_log>"* ]] && ok "wrapped in <global_log>" || bad "no log wrapper"
got=$(grep -c '^## ' <<<"$rl"); eq "recall_log returns last 8 entries" 8 "$got"
[[ "$rl" == *"summary 12"* ]] && ok "keeps newest entry" || bad "newest missing"

echo "== prune_signals (TTL archive) =="
rm -rf "$SIGNAL_DIR"; export RALPH_SIGNAL_TTL_DAYS=14
export RALPH_NOW="2026-06-01T00:00:00Z"
old=$(record_signal runtime_failure "old resolved" "old ev" "act"); signal_resolve "$old"
export RALPH_NOW="2026-06-25T00:00:00Z"
fresh=$(record_signal validation_failure "fresh open" "fresh ev" "act")
prune_signals
[[ -f "$SIGNAL_ARCHIVE_DIR/$old.json" ]] && ok "stale resolved signal archived" || bad "not archived"
[[ -f "$SIGNAL_DIR/$fresh.json" ]] && ok "fresh open signal retained" || bad "fresh wrongly pruned"

echo "== _signal_auto_resolve_family =="
rm -rf "$SIGNAL_DIR"; unset RALPH_NOW
vk=$(record_signal validation_failure "vf" "vf ev" "act")
rkk=$(record_signal runtime_failure "rf" "rf ev" "act")
_signal_auto_resolve_family validation_failure
eq "validation family resolved" resolved "$(jq -r .status "$SIGNAL_DIR/$vk.json")"
eq "runtime family untouched" open "$(jq -r .status "$SIGNAL_DIR/$rkk.json")"

echo "== theme_key disambiguates truncated long signatures (no false-merge) =="
ka=$(_signal_theme_key arch_drift "missing aa bb cc dd ee ff gg hh component one")
kb=$(_signal_theme_key arch_drift "missing aa bb cc dd ee ff gg hh component two")
ne "long sigs sharing an 8-token prefix stay distinct" "$ka" "$kb"

echo "== recall_signals resilient to a corrupt signal file =="
rm -rf "$SIGNAL_DIR"; mkdir -p "$SIGNAL_DIR"
record_signal validation_failure "good one" "good evidence here distinct" "act" >/dev/null
printf 'NOT JSON {{{\n' > "$SIGNAL_DIR/corrupt.json"
out=$(recall_signals)
[[ "$out" == *"good one"* ]] && ok "corrupt file does not blank the digest" || bad "digest blanked by corrupt file"

echo "== related: co-occurrence links (gap #3) =="
rm -rf "$SIGNAL_DIR"; unset RALPH_NOW; init_signals
a=$(RUN_ID=run-X record_signal validation_failure "fa" "RELATED alpha problem" "fix")
b=$(RUN_ID=run-X record_signal runtime_failure  "fb" "RELATED bravo problem" "fix")
c=$(RUN_ID=run-Y record_signal lazy_streak      "fc" "RELATED charlie problem" "fix")
eq "new signal starts with related: []" "[]" "$(jq -c '.related' "$SIGNAL_DIR/$a.json" 2>/dev/null)"
link_related_signals
[[ "$(jq -r '.related[]?' "$SIGNAL_DIR/$a.json" 2>/dev/null)" == *"$b"* ]] && ok "A linked to B (shared run)" || bad "A not linked to B"
[[ "$(jq -r '.related[]?' "$SIGNAL_DIR/$b.json" 2>/dev/null)" == *"$a"* ]] && ok "B linked to A (bidirectional)" || bad "B not linked to A"
[[ "$(jq -r '.related[]?' "$SIGNAL_DIR/$a.json" 2>/dev/null)" == *"$c"* ]] && bad "A wrongly linked to C (different run)" || ok "A not linked to C (no shared run)"
out=$(recall_signals)
[[ "$out" == *"related:"* ]] && ok "recall_signals surfaces related links" || bad "recall missing related"

echo "== related: a corrupt signal file must not disable the whole pass =="
rm -rf "$SIGNAL_DIR"; init_signals
p=$(RUN_ID=run-K record_signal validation_failure "fp" "PAIR one problem" "fix")
q=$(RUN_ID=run-K record_signal runtime_failure  "fq" "PAIR two problem" "fix")
printf 'NOT JSON {{{\n' > "$SIGNAL_DIR/corrupt.json"
link_related_signals
[[ "$(jq -r '.related[]?' "$SIGNAL_DIR/$p.json" 2>/dev/null)" == *"$q"* ]] && ok "corrupt file does not disable co-occurrence linking" || bad "corrupt file blanked the related pass"

echo "== related: a no-longer-co-occurring signal gets .related cleared (no stale) =="
rm -rf "$SIGNAL_DIR"; init_signals
s1=$(RUN_ID=run-S1 record_signal validation_failure "fs" "SOLO problem here" "fix")
tmpj="$TMP/tmpj.json"; jq '.related=["stale-theme-xyz"]' "$SIGNAL_DIR/$s1.json" > "$tmpj" && mv "$tmpj" "$SIGNAL_DIR/$s1.json"
link_related_signals
eq "stale related cleared to []" "[]" "$(jq -c '.related' "$SIGNAL_DIR/$s1.json" 2>/dev/null)"

echo "== related: bounded by RALPH_SIGNAL_RELATED_MAX =="
rm -rf "$SIGNAL_DIR"; init_signals
for w in alpha bravo charlie delta echo; do RUN_ID=run-Z record_signal validation_failure "m" "MANY problem $w" "fix" >/dev/null; done
RALPH_SIGNAL_RELATED_MAX=2 link_related_signals
one=$(find "$SIGNAL_DIR" -maxdepth 1 -name '*.json' | head -1)
n=$(jq -r '.related | length' "$one" 2>/dev/null)
[[ "$n" -le 2 ]] && ok "related bounded by RALPH_SIGNAL_RELATED_MAX (got $n)" || bad "related not bounded (got $n)"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

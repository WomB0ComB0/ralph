#!/bin/bash
# TDD harness for Ralph's durable quality rubric and completion gate.
set +e

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ARTIFACT_DIR="$TMP/artifacts"
export QUALITY_FILE="$ARTIFACT_DIR/QUALITY.md"
export RALPH_QUALITY_TIER="professional"
export RALPH_REQUIRE_QUALITY_ON_COMPLETE=1

printf '== ensure_quality_file / load_quality_context ==\n'
ensure_quality_file; rc=$?
eq "ensure returns 0" 0 "$rc"
[[ -f "$QUALITY_FILE" ]] && ok "QUALITY.md created" || bad "QUALITY.md missing"
grep -q '^Quality Gate: continue' "$QUALITY_FILE" && ok "default gate is continue" || bad "default gate is not continue"
grep -q '^Requested Tier: professional' "$QUALITY_FILE" && ok "tier captured" || bad "tier missing"
ctx=$(load_quality_context)
printf '%s\n' "$ctx" | grep -q 'Stop Policy' && ok "load_quality_context returns rubric" || bad "rubric context missing"

printf '== quality_gate_allows_complete ==\n'
quality_gate_allows_complete; rc=$?
eq "continue gate blocks completion" 1 "$rc"
python3 - "$QUALITY_FILE" <<'PY2'
from pathlib import Path
p = Path(__import__('sys').argv[1])
s = p.read_text().replace('Quality Gate: continue', 'Quality Gate: pass')
p.write_text(s)
PY2
quality_gate_allows_complete; rc=$?
eq "pass gate allows completion" 0 "$rc"
export RALPH_REQUIRE_QUALITY_ON_COMPLETE=0
rm -f "$QUALITY_FILE"
quality_gate_allows_complete; rc=$?
eq "disabled gate allows missing QUALITY.md" 0 "$rc"
export RALPH_REQUIRE_QUALITY_ON_COMPLETE=1

printf '== generate_system_prompt includes quality rubric ==\n'
export QUALITY_FILE="$ARTIFACT_DIR/QUALITY.md"
ensure_quality_file
prompt=$(generate_system_prompt "user" "plan" "prd" "diagram" "" "" "changes" "resources" "ctx" "quality body" "project instructions")
printf '%s\n' "$prompt" | grep -q '<quality_rubric>' && ok "prompt includes quality_rubric tag" || bad "quality_rubric tag missing"
printf '%s\n' "$prompt" | grep -q 'quality body' && ok "prompt includes quality content" || bad "quality content missing"
printf '%s\n' "$prompt" | grep -q 'Quality Gate: pass' && ok "prompt teaches pass gate" || bad "quality pass instruction missing"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

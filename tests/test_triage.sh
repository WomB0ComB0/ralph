#!/bin/bash
# TDD harness for cross-repo read-only GitHub triage: allowlist parsing, gh-JSON parsers
# (failing CI + dependabot/code-scanning/secret-scanning), and severity ranking. No network —
# parsers are fed fixture JSON identical in shape to `gh`'s output.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/triage.sh"
set +eu
IFS=' '

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unset RALPH_TARGETS RALPH_TARGETS_FILE

echo "== _triage_sev_rank: GitHub's two severity scales onto one order =="
eq "critical > high"  "1" "$([[ $(_triage_sev_rank critical) -gt $(_triage_sev_rank high) ]] && echo 1 || echo 0)"
eq "error == high rank" "$(_triage_sev_rank high)" "$(_triage_sev_rank error)"
eq "warning == medium"  "$(_triage_sev_rank medium)" "$(_triage_sev_rank warning)"
eq "unknown -> lowest"  "1" "$(_triage_sev_rank wat)"

echo "== triage_load_targets: explicit allowlist (env + file), dedup, comments =="
export RALPH_TARGETS="a/b, c/d a/b"     # comma + space separated, with a dup
eq "env: split on comma/space, dedup, order kept" "a/b|c/d" "$(triage_load_targets | paste -sd'|' -)"
unset RALPH_TARGETS
# includes a bare token (rejected) and a 3-part path (rejected — only owner/repo is valid)
printf '# my repos\nowner/one\n\nowner/two   # inline comment\nnot-a-repo\nowner/three/sub\nowner/three\n' > "$TMP/ralph.targets"
export RALPH_TARGETS_FILE="$TMP/ralph.targets"
eq "file: comments/blanks/non-owner-repo stripped" "owner/one|owner/two|owner/three" "$(triage_load_targets | paste -sd'|' -)"
unset RALPH_TARGETS_FILE
eq "no targets configured -> empty" "" "$(triage_load_targets "$TMP/nope")"

echo "== _triage_parse_runs: failing CI -> findings =="
runs='[{"name":"CI","headBranch":"main","url":"https://x/1"},{"name":"Lint","headBranch":"dev","url":"https://x/2"}]'
out=$(printf '%s' "$runs" | _triage_parse_runs "o/r")
eq "two failing runs -> two findings" "2" "$(printf '%s\n' "$out" | grep -c .)"
eq "ci finding carries repo+category+branch" "medium	o/r	ci	CI failed on main	https://x/1" "$(printf '%s\n' "$out" | head -1)"
eq "empty array -> no findings" "" "$(printf '[]' | _triage_parse_runs "o/r")"

echo "== _triage_parse_alerts: dependabot / code-scanning / secret-scanning =="
dep='[{"state":"open","security_advisory":{"severity":"high","summary":"RCE in foo"},"dependency":{"package":{"name":"foo"}},"html_url":"https://x/d1"},{"state":"dismissed","security_advisory":{"severity":"low","summary":"old"},"dependency":{"package":{"name":"bar"}},"html_url":"https://x/d2"}]'
dout=$(printf '%s' "$dep" | _triage_parse_alerts "o/r" dependabot)
eq "dependabot: only OPEN alerts" "1" "$(printf '%s\n' "$dout" | grep -c .)"
eq "dependabot finding shape" "high	o/r	dependabot	foo: RCE in foo	https://x/d1" "$dout"
code='[{"state":"open","rule":{"security_severity_level":"critical","description":"SQL injection"},"html_url":"https://x/c1"}]'
eq "code-scanning uses security_severity_level" "critical	o/r	code-scan	SQL injection	https://x/c1" "$(printf '%s' "$code" | _triage_parse_alerts "o/r" code-scanning)"
sec='[{"state":"open","secret_type_display_name":"AWS Access Key","html_url":"https://x/s1"}]'
eq "secret-scanning -> high severity" "high	o/r	secret	AWS Access Key	https://x/s1" "$(printf '%s' "$sec" | _triage_parse_alerts "o/r" secret-scanning)"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

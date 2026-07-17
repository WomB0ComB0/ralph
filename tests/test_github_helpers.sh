#!/bin/bash
# Shared GitHub helper behavior for human-facing scripts. No network: gh is stubbed.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set +eu
IFS=$' \t\n'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# shellcheck source=../lib/github.sh
source "$R/lib/github.sh"

echo "== lib/github.sh transient classification =="
ralph_github_is_transient_error "HTTP 503: Service Unavailable" && ok "503 is transient" || bad "503 not transient"
ralph_github_is_transient_error "could not resolve host github.com" && ok "DNS failure is transient" || bad "DNS failure not transient"
if ralph_github_is_transient_error "GraphQL: Field does not exist"; then bad "schema/user error classified as transient"; else ok "schema/user error is not transient"; fi
non_transient_cmd() { printf 'GraphQL: Field does not exist\n' >&2; return 42; }
out=$(ralph_gh_capture non_transient_cmd); rc=$?
eq "ralph_gh_capture preserves non-transient rc" "42" "$rc"
eq "ralph_gh_capture returns non-transient output" "GraphQL: Field does not exist" "$out"
unset -f non_transient_cmd

cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
if [ "$1 $2" = "run list" ]; then
  printf 'HTTP 503: Service Unavailable\n' >&2
  exit 1
fi
printf 'unexpected gh args: %s\n' "$*" >&2
exit 9
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

echo "== scripts/ci-fails outage behavior =="
out=$("$R/scripts/ci-fails" o/r 1 2>&1); rc=$?
eq "ci-fails exits EX_TEMPFAIL on transient GitHub outage" "75" "$rc"
printf '%s' "$out" | grep -q 'transient GitHub failure while listing failing CI runs for o/r' && ok "ci-fails prints shared transient message" || bad "missing transient message: $out"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

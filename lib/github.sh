#!/bin/bash
# lib/github.sh - shared GitHub CLI outage classification helpers.

ralph_github_is_transient_error() {
    local msg="${1,,}"
    case "$msg" in
        *"http 5"*|*"status 5"*|*"503"*|*"502"*|*"504"*|*"service unavailable"*|*"bad gateway"*|*"gateway timeout"*|*"rate limit"*|*"secondary rate"*|*"timeout"*|*"timed out"*|*"tls"*|*"connection reset"*|*"connection refused"*|*"could not resolve"*|*"network"*|*"eof"*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

ralph_gh_capture() {
    local out rc
    out=$("$@" 2>&1)
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$out"
        return 0
    fi
    printf '%s' "$out"
    ralph_github_is_transient_error "$out" && return 75
    return "$rc"
}

ralph_gh_fail_message() {
    local label="$1" detail="${2:-}"
    if ralph_github_is_transient_error "$detail"; then
        printf 'transient GitHub failure while %s: %s\n' "$label" "$detail" >&2
        return 75
    fi
    printf 'GitHub command failed while %s: %s\n' "$label" "$detail" >&2
    return 1
}

ralph_gh_current_repo() {
    local out rc=0
    out=$(ralph_gh_capture gh repo view --json nameWithOwner -q .nameWithOwner) || rc=$?
    if [[ "$rc" -eq 0 && -n "$out" ]]; then
        printf '%s' "$out"
        return 0
    fi
    if [[ "$rc" -eq 75 ]]; then
        ralph_gh_fail_message "resolving current repository" "$out"
        return 75
    fi
    printf 'not in a GitHub repo; pass owner/repo\n' >&2
    return 1
}

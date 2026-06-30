# scripts/ — small `gh` polling helpers

A tiny library of status helpers so polling a PR (and closing out its review) costs a few
tokens instead of a wall of inline `gh api graphql ... --jq ...`. All read the current repo's
GitHub remote by default; pass `owner/repo` to target another. Require an authenticated `gh`.

| Script | What it does |
|--------|--------------|
| `pr-status <pr> [owner/repo]` | One-glance PR status: `state` / `mergeable` / `reviewDecision`, the reviewers, and every **unresolved** review thread as `<threadId>  path:line  comment…` |
| `resolve-thread <threadId> [reply]` | Reply to (optional) then mark a review thread **resolved** — feed it the IDs from `pr-status` |
| `pr-checks [pr] [owner/repo]` | CI check rollup for a PR (or the current branch) — wraps `gh pr checks` |

```bash
scripts/pr-status 34                       # this repo, PR 34
scripts/pr-status 475 WomB0ComB0/portfolio
scripts/resolve-thread PRRT_kwDO… "Done in <sha>."
scripts/pr-checks
```

The review-close-out loop in one breath:
```bash
scripts/pr-status 34                       # see unresolved threads + their IDs
# …address them, push…
scripts/resolve-thread <id> "Addressed in <sha>."   # per thread
```

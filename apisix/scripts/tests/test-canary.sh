#!/usr/bin/env bash
# Tests for apisix/scripts/canary.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
canary="$here/../canary.sh"
# shellcheck source=apisix/scripts/tests/lib.sh
. "$here/lib.sh"

upstream=$sandbox/upstream
fork=$sandbox/fork
make_upstream "$upstream"
change "$upstream" a.txt 'a1
a2' 'add a.txt'
change "$upstream" e.txt 'e1' 'add e.txt'
git -C "$upstream" tag -f base-1.0 >/dev/null
make_fork "$upstream" "$fork"

feature_message='feat(tokio): change the first line

Why.

Upstream-Status: Pending
Drop-When: never'
change "$fork" a.txt 'F1
a2' "$feature_message"
change "$fork" b.txt 'backported' 'ci(workspace): backport a fix

Why.

Upstream-Status: Backport tokio-rs/tokio#1
Drop-When: the base includes tokio-rs/tokio#1'
change "$fork" b.txt 'backported and fixed' 'fixup! ci(workspace): backport a fix'
change "$fork" e.txt 'e2' 'fix(tokio): change e.txt

Why.

Upstream-Status: Pending
Drop-When: never'
change "$fork" c.txt 'fork' 'fix(tokio): add c.txt

Why.

Upstream-Status: Submitted tokio-rs/tokio#2
Drop-When: the base includes tokio-rs/tokio#2'
change "$fork" a.txt 'F1
a2 fixed' 'fixup! feat(tokio): change the first line'
# Later changes to b.txt, which only the skipped backport added, like a
# release branch lockfile.
printf 'locked again\n' >"$fork/b.txt"
git -C "$fork" add b.txt
change "$fork" d.txt 'fork' 'fix(tokio): add d.txt and refresh b.txt

Why.

Upstream-Status: Pending
Drop-When: never'
change "$fork" b.txt 'refreshed' 'build(workspace): refresh b.txt

Why.

Upstream-Status: Inappropriate release branch lockfile'

# Upstream branches the series is replayed onto.
git -C "$upstream" switch -q -c clean base-1.0
change "$upstream" u.txt 'upstream' 'add u.txt'
git -C "$upstream" switch -q -c conflict base-1.0
change "$upstream" a.txt 'U1
a2' 'change the first line differently'
git -C "$upstream" switch -q -c merged base-1.0
change "$upstream" c.txt 'fork' 'add c.txt upstream'
git -C "$upstream" switch -q -c has-b base-1.0
change "$upstream" b.txt 'upstream' 'add b.txt upstream'
# The same e.txt change as the fork, in a commit with another patch ID.
git -C "$upstream" switch -q -c has-e base-1.0
printf 'e2\n' >"$upstream/e.txt"
git -C "$upstream" add e.txt
change "$upstream" f.txt 'f' 'change e.txt and add f.txt'
git -C "$fork" fetch -q origin clean conflict merged has-b has-e

run_script "$fork" "$canary" --target origin/clean --worktree "$sandbox/clean" dev
expect "a series replays onto a clean target" 0 "Replayed 6 commit(s) and skipped 3"
expect "backports are skipped" 0 "(backport)"
expect "a fixup of a backport is replayed, not hidden" 0 "fixup! ci(workspace): backport a fix (it only changes b.txt)"
expect "changes to files only a backport added are dropped" 0 "(without its changes to b.txt)"
expect "a commit that only changes such files is dropped" 0 "(it only changes b.txt)"
if [ "$(cat "$sandbox/clean/a.txt")" = "F1
a2 fixed" ] && [ -f "$sandbox/clean/u.txt" ] && [ -f "$sandbox/clean/d.txt" ] &&
    [ ! -e "$sandbox/clean/b.txt" ]; then
    pass "the worktree holds the target plus the replayed commits"
else
    fail "the worktree holds the target plus the replayed commits"
fi

run_script "$fork" "$canary" --target origin/merged --worktree "$sandbox/merged" dev
expect "a commit upstream already has is skipped" 0 "is already upstream; drop it"

run_script "$fork" "$canary" --target origin/has-e --worktree "$sandbox/has-e" dev
expect "a commit whose replay is empty is reported as upstream" 0 "fix(tokio): change e.txt is already upstream"

GIT_COMMITTER_NAME='<>' run_script "$fork" "$canary" --target origin/clean --worktree "$sandbox/bad-ident" dev
expect "a replay that fails without a conflict is reported" 1 "cannot be replayed onto origin/clean"

run_script "$fork" "$canary" --target origin/has-b --worktree "$sandbox/has-b" dev
expect "a file that the target has is not dropped" 1 "conflicts with origin/has-b in: b.txt"

run_script "$fork" "$canary" --target origin/conflict --worktree "$sandbox/conflict" dev
expect "a conflict fails and names the file" 1 "conflicts with origin/conflict in: a.txt"
if [ -z "$(git -C "$sandbox/conflict" status --porcelain)" ]; then
    pass "a conflict leaves a clean worktree"
else
    fail "a conflict leaves a clean worktree"
fi

run_script "$fork" "$canary" --worktree "$sandbox/none" dev
expect "--target is required" 2 "--target is required"
run_script "$fork" "$canary" --target origin/clean dev
expect "--worktree is required" 2 "--worktree is required"
run_script "$fork" "$canary" --target origin/clean --worktree "$sandbox/clean" dev
expect "an existing worktree path is refused" 2 "already exists"
run_script "$fork" "$canary" --target no-such-ref --worktree "$sandbox/none" dev
expect "an unknown target is refused" 2 "is not a commit"
run_script "$fork" "$canary" --help
expect "--help prints the usage" 0 "Usage: apisix/scripts/canary.sh"
if grep -q "pipefail" <<<"$output"; then
    fail "--help prints only the comment block"
else
    pass "--help prints only the comment block"
fi

finish

#!/usr/bin/env bash
# Tests for apisix/scripts/check-series.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lint="$here/../check-series.sh"
# shellcheck source=apisix/scripts/tests/lib.sh
. "$here/lib.sh"

upstream=$sandbox/upstream
fork=$sandbox/fork
make_upstream "$upstream"
make_fork "$upstream" "$fork"

# An upstream fix on a release branch, made after the fork was cloned.
git -C "$upstream" switch -q -c tokio-1.0.x base-1.0
change "$upstream" lock.txt 'locked' 'pin the toolchain'
release_fix=$(git -C "$upstream" rev-parse HEAD)
change "$upstream" lock2.txt 'locked too' 'pin another tool'
release_fix2=$(git -C "$upstream" rev-parse HEAD)
git -C "$fork" fetch -q origin tokio-1.0.x

commit "$fork" 'feat(tokio): add a host-driven tick

The host owns waiting, so it must be able to run a bounded batch of tasks.

Upstream-Status: Pending tokio-rs/tokio#8479
Drop-When: the base includes tokio-rs/tokio#8479'
commit "$fork" 'fixup! feat(tokio): add a host-driven tick'
git -C "$fork" cherry-pick -x "$release_fix" >/dev/null
git -C "$fork" commit -q --amend -F - <<EOF
ci(workspace): pin the toolchain

Keeps the checks reproducible.

Upstream-Status: Backport https://github.com/tokio-rs/tokio/pull/8792
Drop-When: the base includes tokio-rs/tokio#8792
(cherry picked from commit $release_fix)
EOF
commit "$fork" 'fix(tokio-util)!: change the codec error type

Callers need the source error.

Upstream-Status: Submitted tokio-rs/tokio#1
Drop-When: the base includes tokio-rs/tokio#1'
git -C "$fork" branch valid

run_script "$fork" "$lint"
expect "a valid series passes" 0 "4 patch(es), 1 fixup(s)"
expect "the inventory lists each status" 0 "Backport"

run_script "$fork" "$lint" --verify-upstream valid
expect "the base tag and the backport match upstream" 0 "The series follows the patch rules."

# A clone without the upstream objects has to fetch the backported commit.
git clone -q --no-local --single-branch --branch valid "$fork" "$sandbox/fresh"
if git -C "$sandbox/fresh" cat-file -e "$release_fix^{commit}" 2>/dev/null; then
    fail "the fresh clone lacks the backported upstream commit"
else
    pass "the fresh clone lacks the backported upstream commit"
fi
run_script "$sandbox/fresh" "$lint" --verify-upstream
expect "--verify-upstream fetches the backported commit" 0 "The series follows the patch rules."

# bad_commit NAME TEXT MESSAGE: add a commit with MESSAGE on top of the valid
# series and expect the lint to fail with TEXT.
bad_commit() {
    git -C "$fork" switch -q -C "case" valid
    commit "$fork" "$3"
    run_script "$fork" "$lint"
    expect "$1" 1 "$2"
}

trailers='Upstream-Status: Pending
Drop-When: never'

bad_commit "a subject without scope fails" 'the subject must be "type(scope): description"' "feat: add a thing

Why.

$trailers"
bad_commit "an unknown type fails" 'the subject must be' "feature(tokio): add a thing

Why.

$trailers"
bad_commit "an unknown scope fails" 'unknown scope "rt"' "feat(rt): add a thing

Why.

$trailers"
bad_commit "a trailing period fails" 'must not end with a period' "fix(tokio): fix the thing.

Why.

$trailers"
bad_commit "a long subject fails" 'the limit is 72' "fix(tokio): make the subject of this commit much longer than the limit allows

Why.

$trailers"
bad_commit "a missing body fails" 'the body must explain why' "fix(tokio): fix the thing

$trailers"
bad_commit "a missing Upstream-Status fails" 'exactly one Upstream-Status trailer, found 0' 'fix(tokio): fix the thing

Why.

Drop-When: never'
bad_commit "two Upstream-Status trailers fail" 'found 2' "fix(tokio): fix the thing

Why.

Upstream-Status: Pending
$trailers"
bad_commit "an unknown status fails" 'must start with Pending, Submitted, Backport or Inappropriate' 'fix(tokio): fix the thing

Why.

Upstream-Status: Maybe
Drop-When: never'
bad_commit "Submitted without an upstream reference fails" 'must name the upstream change' 'fix(tokio): fix the thing

Why.

Upstream-Status: Submitted soon
Drop-When: never'
bad_commit "Backport without an upstream reference fails" 'must name the upstream change' 'fix(tokio): fix the thing

Why.

Upstream-Status: Backport from master
Drop-When: never'
bad_commit "Inappropriate without a reason fails" 'must give the reason' 'ci(apisix): add a job

Why.

Upstream-Status: Inappropriate'
bad_commit "a missing Drop-When fails" 'exactly one Drop-When trailer, found 0' 'fix(tokio): fix the thing

Why.

Upstream-Status: Pending'
bad_commit "a fixup of an unknown commit fails" 'no earlier commit in the series has the subject' \
    'fixup! feat(tokio): add something else'
bad_commit "a fixup of a Backport fails" 'a Backport cannot get fixups' \
    'fixup! ci(workspace): pin the toolchain'
bad_commit "two Drop-When trailers fail" 'exactly one Drop-When trailer, found 2' 'fix(tokio): fix the thing

Why.

Upstream-Status: Pending
Drop-When: never
Drop-When: later'
bad_commit "a Backport without a cherry-pick line fails" 'needs exactly one "(cherry picked from commit <sha>)" line' \
    'fix(tokio): backport a fix

Why.

Upstream-Status: Backport tokio-rs/tokio#3
Drop-When: never'

git -C "$fork" switch -q -C "case" valid
change "$fork" edited.txt 'local edit' "fix(tokio): backport a fix with local edits

Why.

Upstream-Status: Backport tokio-rs/tokio#8792
Drop-When: never
(cherry picked from commit $release_fix)"
run_script "$fork" "$lint"
expect "without --verify-upstream a backport is not compared" 0 "The series follows the patch rules."
run_script "$fork" "$lint" --verify-upstream
expect "a modified Backport fails with --verify-upstream" 1 "its change differs from $release_fix"

git -C "$fork" switch -q -C "case" valid
git -C "$fork" cherry-pick -x "$release_fix2" >/dev/null
git -C "$fork" commit -q --amend --author='Someone Else <else@example.invalid>' -F - <<EOF
ci(workspace): pin another tool

Why.

Upstream-Status: Backport tokio-rs/tokio#8793
Drop-When: never
(cherry picked from commit $release_fix2)
EOF
run_script "$fork" "$lint" --verify-upstream
expect "a Backport with another author fails with --verify-upstream" 1 "keep the upstream author"

git -C "$fork" switch -q -C "case" valid
commit "$fork" 'fix(tokio): backport a commit upstream does not have

Why.

Upstream-Status: Backport tokio-rs/tokio#4
Drop-When: never
(cherry picked from commit 1234567890abcdef1234567890abcdef12345678)'
run_script "$fork" "$lint" --verify-upstream
expect "a Backport of an unknown commit fails with --verify-upstream" 1 "1234567890abcdef1234567890abcdef12345678 is not on upstream master or a tokio-*.x branch"

# A commit that only an upstream pull request ref holds is not merged.
git -C "$upstream" switch -q -c proposal base-1.0
change "$upstream" proposal.txt 'proposed' 'propose a change'
proposal=$(git -C "$upstream" rev-parse HEAD)
git -C "$upstream" update-ref refs/pull/1/head "$proposal"
git -C "$upstream" switch -q tokio-1.0.x
git -C "$upstream" branch -q -D proposal
git -C "$fork" fetch -q origin refs/pull/1/head
git -C "$fork" switch -q -C "case" valid
git -C "$fork" cherry-pick -x "$proposal" >/dev/null
git -C "$fork" commit -q --amend -F - <<EOF
feat(tokio): take a proposed change

Why.

Upstream-Status: Backport tokio-rs/tokio#5
Drop-When: never
(cherry picked from commit $proposal)
EOF
run_script "$fork" "$lint" --verify-upstream
expect "a Backport of an unmerged pull request fails with --verify-upstream" 1 "a change that upstream has not merged is Submitted, not a Backport"

git -C "$fork" switch -q -C "case" valid
change "$fork" apisix/NOTE 'note' 'ci(apisix): add a note

Shows that Inappropriate commits need no Drop-When.

Upstream-Status: Inappropriate fork maintenance'
run_script "$fork" "$lint"
expect "Inappropriate needs no Drop-When" 0 "5 patch(es)"

git -C "$fork" switch -q -c side valid
commit "$fork" 'docs(tokio): side change

Why.

Upstream-Status: Pending
Drop-When: never'
git -C "$fork" switch -q -C "case" valid
git -C "$fork" merge -q --no-ff --no-edit side
run_script "$fork" "$lint"
expect "a merge commit fails" 1 "merge commits are not allowed"

git -C "$fork" switch -q -C "case" valid
change "$fork" apisix/BASE "UPSTREAM_URL=$upstream
BASE_TAG=base-1.0
BASE_COMMIT=$(git -C "$fork" rev-parse 'valid~1')" 'ci(apisix): point the base at a fork commit

Why.

Upstream-Status: Inappropriate test'
run_script "$fork" "$lint" --verify-upstream
expect "a base that is not the upstream tag fails" 1 "base-1.0 is $(git -C "$upstream" rev-parse base-1.0) in"

git -C "$fork" switch -q -C "case" valid
change "$fork" apisix/BASE "UPSTREAM_URL=$upstream
BASE_TAG=no-such-tag
BASE_COMMIT=$(git -C "$upstream" rev-parse 'base-1.0^{commit}')" 'ci(apisix): name a missing base tag

Why.

Upstream-Status: Inappropriate test'
run_script "$fork" "$lint" --verify-upstream
expect "a base tag that upstream lacks fails" 1 "has no tag no-such-tag"

git -C "$fork" switch -q -C "case" valid
change "$fork" apisix/BASE "UPSTREAM_URL=$sandbox/no-such-upstream
BASE_TAG=base-1.0
BASE_COMMIT=$(git -C "$upstream" rev-parse 'base-1.0^{commit}')" 'ci(apisix): name an unreachable upstream

Why.

Upstream-Status: Inappropriate test'
run_script "$fork" "$lint" --verify-upstream
expect "an unreachable upstream is a setup error" 2 "cannot list the tags of"

git -C "$fork" switch -q -C "case" valid
change "$fork" apisix/BASE "UPSTREAM_URL=$upstream
BASE_TAG=base-1.0
BASE_COMMIT=1234567890abcdef1234567890abcdef12345678" 'ci(apisix): name a missing base commit

Why.

Upstream-Status: Inappropriate test'
run_script "$fork" "$lint"
expect "a base commit that is not available is a setup error" 2 "is not available locally"

git -C "$upstream" tag -a -m "annotated" base-annotated base-1.0
git -C "$fork" switch -q -C "case" valid
change "$fork" apisix/BASE "UPSTREAM_URL=$upstream
BASE_TAG=base-annotated
BASE_COMMIT=$(git -C "$upstream" rev-parse 'base-1.0^{commit}')" 'ci(apisix): use an annotated base tag

Why.

Upstream-Status: Inappropriate test'
run_script "$fork" "$lint" --verify-upstream
expect "an annotated base tag is peeled" 0 "The series follows the patch rules."

git -C "$fork" switch -q --orphan orphan
git -C "$fork" checkout -q valid -- apisix/BASE
commit "$fork" 'ci(apisix): start over

Why.

Upstream-Status: Inappropriate test'
run_script "$fork" "$lint"
expect "a base that is not an ancestor is a setup error" 2 "is not an ancestor"

run_script "$fork" "$lint" base-1.0
expect "a revision without apisix/BASE is a setup error" 2 "does not define BASE_TAG"

run_script "$fork" "$lint" no-such-revision
expect "an unknown revision is a setup error" 2 "is not a commit"

run_script "$fork" "$lint" --frobnicate
expect "an unknown option is a usage error" 2 "unknown option"

run_script "$fork" "$lint" valid valid
expect "two revisions are a usage error" 2 "only one REV"

run_script "$fork" "$lint" --help
expect "--help prints the usage" 0 "Usage: apisix/scripts/check-series.sh"
if grep -q "pipefail" <<<"$output"; then
    fail "--help prints only the comment block"
else
    pass "--help prints only the comment block"
fi

finish

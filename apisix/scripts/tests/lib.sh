# Helpers for the apisix/scripts tests. Source this file; do not run it.
# shellcheck shell=bash

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# Keep the tests independent of the caller's git configuration and of CI.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset GITHUB_ACTIONS

failures=0
status=0
output=''

pass() {
    printf 'ok   %s\n' "$1"
}

fail() {
    printf 'FAIL %s\n' "$1"
    printf '%s\n' "$output" | sed 's/^/     | /'
    failures=$((failures + 1))
}

# commit DIR MESSAGE: create an empty commit with MESSAGE in DIR.
commit() {
    printf '%s\n' "$2" | git -C "$1" commit -q --allow-empty -F -
}

# change DIR FILE CONTENT MESSAGE: write CONTENT to FILE and commit it.
change() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" >"$1/$2"
    git -C "$1" add "$2"
    printf '%s\n' "$4" | git -C "$1" commit -q -F -
}

# make_upstream DIR: an upstream repository whose master has one commit
# tagged base-1.0, with the workspace members tokio and tokio-util.
make_upstream() {
    git init -q "$1"
    git -C "$1" symbolic-ref HEAD refs/heads/master
    change "$1" Cargo.toml '[workspace]
resolver = "2"
members = [
  "tokio",
  "tokio-util", # a comment

  "benches",
]

[patch.crates-io]
tokio = { path = "tokio" }' "initial import"
    git -C "$1" tag base-1.0
}

# make_fork UPSTREAM DIR: clone UPSTREAM into DIR, start branch dev at
# base-1.0 and add the maintenance metadata as the first commit.
make_fork() {
    local base
    git clone -q "$1" "$2"
    git -C "$2" switch -q -c dev base-1.0
    base=$(git -C "$1" rev-parse 'base-1.0^{commit}')
    change "$2" apisix/BASE "UPSTREAM_URL=$1
BASE_TAG=base-1.0
BASE_COMMIT=$base" 'ci(apisix): add the maintenance metadata

Records the upstream base of the line.

Upstream-Status: Inappropriate fork maintenance'
}

# run_script DIR SCRIPT ARGS...: run SCRIPT in DIR and record its exit status
# and combined output.
run_script() {
    local dir=$1 script=$2
    shift 2
    set +e
    output=$(cd "$dir" && "$script" "$@" 2>&1)
    status=$?
    set -e
}

# expect NAME STATUS [TEXT]: check the exit status of the last run_script and,
# when given, that its output contains TEXT.
expect() {
    local name=$1 want=$2 text=${3-}
    if [ "$status" != "$want" ]; then
        fail "$name: exit status $status, expected $want"
    elif [ -n "$text" ] && ! grep -Fq -- "$text" <<<"$output"; then
        fail "$name: the output does not contain \"$text\""
    else
        pass "$name"
    fi
}

finish() {
    if [ "$failures" -gt 0 ]; then
        printf '%d test(s) failed\n' "$failures"
        exit 1
    fi
}

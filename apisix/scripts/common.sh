# Shared helpers for the apisix/scripts tools. Source this file; do not run it.
# shellcheck shell=bash

# die MESSAGE...: report a usage or setup error and exit with status 2.
die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

# base_value REV KEY: print the value of KEY from apisix/BASE at REV.
base_value() {
    local rev=$1 key=$2 value
    value=$(git show "$rev:apisix/BASE" 2>/dev/null | sed -n "s/^$key=//p" | tail -n 1)
    [ -n "$value" ] || die "apisix/BASE at $rev does not define $key"
    printf '%s\n' "$value"
}

# upstream_status REV: print the Upstream-Status trailer values of commit REV,
# one per line.
upstream_status() {
    git log -1 --format=%B "$1" | git interpret-trailers --parse |
        sed -n 's/^Upstream-Status: //p'
}

# fixup_target SUBJECT: print the subject that a fixup!, squash! or amend!
# commit refers to, or nothing when SUBJECT is a regular subject.
fixup_target() {
    local subject=$1 target=$1
    while [[ $target =~ ^(fixup|squash|amend)!\ (.*)$ ]]; do
        target=${BASH_REMATCH[2]}
    done
    [ "$target" != "$subject" ] && printf '%s\n' "$target"
    return 0
}

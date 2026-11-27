#!/usr/bin/env bash
# Lint the patch series of this maintenance line: every commit between the
# upstream base recorded in apisix/BASE and REV must follow the patch rules in
# apisix/README.md.
#
# Usage: apisix/scripts/check-series.sh [--verify-upstream] [REV]
#
#   --verify-upstream  also check, in the upstream repository, that BASE_TAG
#                      still names BASE_COMMIT and that every Backport makes the
#                      same change as the upstream commit it names (needs
#                      network access)
#   REV                tip of the series to lint (default: HEAD)
#
# Exit status: 0 when the series follows the rules, 1 when it does not, and 2
# on usage or setup errors.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=apisix/scripts/common.sh
. "$script_dir/common.sh"

usage() {
    # Print the comment block that follows the shebang line.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

verify_upstream=0
rev=
while [ $# -gt 0 ]; do
    case $1 in
        --verify-upstream) verify_upstream=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *)
            [ -z "$rev" ] || die "only one REV may be given (see --help)"
            rev=$1
            ;;
    esac
    shift
done
rev=${rev:-HEAD}

types='feat|fix|docs|test|refactor|perf|ci|build|chore|revert'
subject_re="^($types)\\(([a-z0-9][a-z0-9-]*)\\)(!)?: (.+)\$"
upstream_ref_re='(^|[[:space:]])(tokio-rs/tokio#[0-9]+|https://github\.com/tokio-rs/tokio/(pull|issues|commit)/[0-9a-f]+)'

problems=0
problem() {
    problems=$((problems + 1))
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error title=patch series::%s\n' "$*"
    else
        printf 'problem: %s\n' "$*" >&2
    fi
}

# count_lines TEXT: print the number of non-empty lines in TEXT.
count_lines() {
    grep -c . <<<"$1" || true
}

# Matching is done on here-strings rather than pipes: with pipefail, a
# "producer | grep -q" pipeline fails when grep exits before the producer
# finishes writing.

# workspace_scopes COMMIT: print the scopes allowed at COMMIT, one per line:
# the [workspace] members of the root Cargo.toml, "workspace" and "apisix".
workspace_scopes() {
    git show "$1:Cargo.toml" 2>/dev/null | awk '
        /^\[workspace\]/ { in_workspace = 1; next }
        /^\[/ { in_workspace = 0 }
        in_workspace && /^members[[:space:]]*=/ { in_members = 1 }
        in_members {
            line = $0
            sub(/#.*/, "", line)
            while (match(line, /"[^"]+"/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
            if ($0 ~ /\]/) in_members = 0
        }'
    printf '%s\n' workspace apisix
}

check_subject() {
    local sha=$1 where=$2 subject=$3 scope description scopes
    if [[ $subject =~ $subject_re ]]; then
        scope=${BASH_REMATCH[2]}
        description=${BASH_REMATCH[4]}
        scopes=$(workspace_scopes "$sha")
        if ! grep -Fxq -- "$scope" <<<"$scopes"; then
            problem "$where: unknown scope \"$scope\"; use a workspace member crate, \"workspace\" or \"apisix\""
        fi
        case $description in
            *.) problem "$where: the subject must not end with a period" ;;
        esac
    else
        problem "$where: the subject must be \"type(scope): description\" with a type from: ${types//|/, }"
    fi
    if [ "${#subject}" -gt 72 ]; then
        problem "$where: the subject has ${#subject} characters; the limit is 72"
    fi
}

# check_backport SHA WHERE: a backport names its upstream commit in exactly one
# "(cherry picked from commit ...)" line, as git cherry-pick -x writes it. With
# --verify-upstream it must make the same change as that commit and keep its
# author. The canary skips backports, so an unchecked label would hide a patch
# from it.
check_backport() {
    local sha=$1 where=$2 sources ours theirs
    sources=$(git log -1 --format=%B "$sha" | sed -n 's/^(cherry picked from commit \([0-9a-f]\{40\}\))$/\1/p')
    if [ "$(count_lines "$sources")" != 1 ]; then
        problem "$where: a Backport needs exactly one \"(cherry picked from commit <sha>)\" line; use git cherry-pick -x"
        return 0
    fi
    [ "$verify_upstream" = 1 ] || return 0
    if ! git cat-file -e "$sources^{commit}" 2>/dev/null &&
        ! git fetch -q --no-tags "$upstream_url" "$sources" 2>/dev/null; then
        problem "$where: cannot fetch $sources, the commit it backports, from $upstream_url"
        return 0
    fi
    ours=$(git show "$sha" | git patch-id --stable)
    theirs=$(git show "$sources" | git patch-id --stable)
    if [ "${ours%% *}" != "${theirs%% *}" ]; then
        problem "$where: its change differs from $sources, the upstream commit it backports"
    fi
    ours=$(git log -1 --format='%an <%ae> %ad' --date=raw "$sha")
    theirs=$(git log -1 --format='%an <%ae> %ad' --date=raw "$sources")
    if [ "$ours" != "$theirs" ]; then
        problem "$where: its author is \"$ours\" but $sources has \"$theirs\"; keep the upstream author, as git cherry-pick -x does"
    fi
}

# check_message SHA WHERE: check the body and trailers of a regular commit and
# set $keyword to its Upstream-Status keyword. It must not run in a subshell,
# or the problems it finds would not be counted.
check_message() {
    local sha=$1 where=$2 trailers body statuses drop_when status_count drop_count
    local detail=''
    keyword=''
    trailers=$(git log -1 --format=%B "$sha" | git interpret-trailers --parse)
    body=$(git log -1 --format=%b "$sha")
    if [ -n "$trailers" ]; then
        # Drop the last paragraph: it is the trailer block.
        body=$(printf '%s\n' "$body" | awk 'BEGIN { RS = "" } { p[NR] = $0 } END { for (i = 1; i < NR; i++) print p[i] }')
    fi
    if ! grep -q '[^[:space:]]' <<<"$body"; then
        problem "$where: the body must explain why the change is needed"
    fi

    statuses=$(printf '%s\n' "$trailers" | sed -n 's/^Upstream-Status: //p')
    drop_when=$(printf '%s\n' "$trailers" | sed -n 's/^Drop-When: //p')
    status_count=$(count_lines "$statuses")
    drop_count=$(count_lines "$drop_when")

    if [ "$status_count" != 1 ]; then
        problem "$where: needs exactly one Upstream-Status trailer, found $status_count"
    else
        keyword=${statuses%% *}
        detail=${statuses#"$keyword"}
        detail=${detail# }
        case $keyword in
            Pending) ;;
            Submitted | Backport)
                if ! [[ $detail =~ $upstream_ref_re ]]; then
                    problem "$where: Upstream-Status: $keyword must name the upstream change as tokio-rs/tokio#123 or a github.com/tokio-rs/tokio URL"
                fi
                if [ "$keyword" = Backport ]; then
                    check_backport "$sha" "$where"
                fi
                ;;
            Inappropriate)
                [ -n "$detail" ] || problem "$where: Upstream-Status: Inappropriate must give the reason"
                ;;
            *)
                problem "$where: Upstream-Status must start with Pending, Submitted, Backport or Inappropriate"
                keyword=''
                ;;
        esac
    fi

    if [ "$keyword" = Inappropriate ]; then
        [ "$drop_count" -le 1 ] || problem "$where: at most one Drop-When trailer is allowed, found $drop_count"
    elif [ "$drop_count" != 1 ]; then
        problem "$where: needs exactly one Drop-When trailer, found $drop_count"
    fi
    keyword=${keyword:-?}
}

git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || die "$rev is not a commit"
base_tag=$(base_value "$rev" BASE_TAG)
base_commit=$(base_value "$rev" BASE_COMMIT)
upstream_url=$(base_value "$rev" UPSTREAM_URL)

git cat-file -e "$base_commit^{commit}" 2>/dev/null ||
    die "base commit $base_commit is not available locally; fetch the full history"
git merge-base --is-ancestor "$base_commit" "$rev" ||
    die "base commit $base_commit ($base_tag) is not an ancestor of $rev"

if [ "$verify_upstream" = 1 ]; then
    # Ask for the peeled entry explicitly: a pattern for the tag alone does not
    # return it, and an annotated tag would otherwise compare as its tag object.
    refs=$(git ls-remote --tags "$upstream_url" "refs/tags/$base_tag" "refs/tags/$base_tag^{}") ||
        die "cannot list the tags of $upstream_url"
    upstream_commit=$(printf '%s\n' "$refs" | awk -v ref="refs/tags/$base_tag" '
        $2 == ref "^{}" { peeled = $1 }
        $2 == ref { plain = $1 }
        END { print (peeled != "" ? peeled : plain) }')
    if [ -z "$upstream_commit" ]; then
        problem "apisix/BASE: $upstream_url has no tag $base_tag"
    elif [ "$upstream_commit" != "$base_commit" ]; then
        problem "apisix/BASE: $base_tag is $upstream_commit in $upstream_url, not $base_commit"
    fi
fi

while read -r sha; do
    problem "$(git log -1 --format='%h (%s)' "$sha"): merge commits are not allowed; rebase instead"
done < <(git rev-list --merges "$base_commit..$rev")

patches=0
fixups=0
earlier=''
backports=''
inventory=''
while read -r sha; do
    short=$(git rev-parse --short=12 "$sha")
    subject=$(git log -1 --format=%s "$sha")
    where="$short ($subject)"
    target=$(fixup_target "$subject")
    if [ -n "$target" ]; then
        fixups=$((fixups + 1))
        if ! grep -Fxq -- "$target" <<<"$earlier"; then
            problem "$where: no earlier commit in the series has the subject \"$target\""
        elif grep -Fxq -- "$target" <<<"$backports"; then
            problem "$where: a Backport cannot get fixups; backport the later upstream change as another Backport, or replace the patch with an adapted one marked Inappropriate"
        fi
        inventory+=$(printf '%s %-13s %s' "$short" fixup "$subject")$'\n'
        continue
    fi
    patches=$((patches + 1))
    earlier+="$subject"$'\n'
    check_subject "$sha" "$where" "$subject"
    check_message "$sha" "$where"
    if [ "$keyword" = Backport ]; then
        backports+="$subject"$'\n'
    fi
    inventory+=$(printf '%s %-13s %s' "$short" "$keyword" "$subject")$'\n'
done < <(git rev-list --reverse --no-merges "$base_commit..$rev")

printf 'Patch series on %s (%s): %d patch(es), %d fixup(s)\n' \
    "$base_tag" "${base_commit:0:12}" "$patches" "$fixups"
printf '%s' "$inventory"
if [ "$problems" -gt 0 ]; then
    printf '%d problem(s) found; see apisix/README.md#patch-rules\n' "$problems" >&2
    exit 1
fi
echo "The series follows the patch rules."

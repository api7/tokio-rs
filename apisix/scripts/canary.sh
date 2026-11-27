#!/usr/bin/env bash
# Replay the patch series onto a newer upstream commit, to learn early whether
# upstream changes conflict with it.
#
# Usage: apisix/scripts/canary.sh --target TARGET --worktree DIR [REV]
#
#   --target TARGET  upstream commit to replay onto, such as upstream/master
#   --worktree DIR   path for a new detached worktree that receives the result
#   REV              tip of the series (default: HEAD)
#
# Commits marked "Upstream-Status: Backport" are skipped: they come from
# upstream, so TARGET either has their change already or does not need it, as
# with the lockfile of a release branch. When a later commit changes a file that
# only a skipped backport added and TARGET lacks, that part of the change is
# dropped and reported. Commits whose change TARGET already contains are
# skipped and listed: drop them at the next base switch.
#
# Exit status: 0 when the series replays cleanly, 1 when a commit conflicts,
# and 2 on usage or setup errors.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=apisix/scripts/common.sh
. "$script_dir/common.sh"

usage() {
    # Print the comment block that follows the shebang line.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

target=
worktree=
rev=
while [ $# -gt 0 ]; do
    case $1 in
        --target)
            [ $# -ge 2 ] || die "--target needs a value"
            target=$2
            shift
            ;;
        --worktree)
            [ $# -ge 2 ] || die "--worktree needs a value"
            worktree=$2
            shift
            ;;
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
[ -n "$target" ] || die "--target is required (see --help)"
[ -n "$worktree" ] || die "--worktree is required (see --help)"
[ ! -e "$worktree" ] || die "$worktree already exists"
git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || die "$rev is not a commit"
git rev-parse --verify --quiet "$target^{commit}" >/dev/null || die "$target is not a commit"

base_commit=$(base_value "$rev" BASE_COMMIT)
git merge-base --is-ancestor "$base_commit" "$rev" ||
    die "base commit $base_commit is not an ancestor of $rev"

# only_backport_files PATHS: whether every path in PATHS was added by a skipped
# backport and is missing from TARGET.
only_backport_files() {
    local path
    while read -r path; do
        grep -Fxq -- "$path" <<<"$backport_files" || return 1
        ! git cat-file -e "$target^{commit}:$path" 2>/dev/null || return 1
    done <<<"$1"
}

notice() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::%s title=canary::%s\n' "$1" "$2"
    else
        printf '%s: %s\n' "$1" "$2"
    fi
}

# Replayed commits need a committer; CI runners have none configured.
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-apisix canary}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-canary@apisix.invalid}"

# Commits whose patch TARGET already has are marked "-" by git cherry.
upstreamed=$(git cherry "$target" "$rev" "$base_commit" | sed -n 's/^- //p')

git worktree add -q --detach "$worktree" "$target"

backport_files=''
replayed=0
skipped=0
already=''
while read -r sha; do
    short=$(git rev-parse --short=12 "$sha")
    subject=$(git log -1 --format=%s "$sha")
    fixed=$(fixup_target "$subject")
    statuses=$(upstream_status "$sha")
    if [ -z "$fixed" ] && [[ ${statuses%%$'\n'*} == Backport* ]]; then
        backport_files+=$(git diff-tree --no-commit-id --name-only -r --diff-filter=A "$sha")$'\n'
        printf 'skip     %s %s (backport)\n' "$short" "$subject"
        skipped=$((skipped + 1))
        continue
    fi
    if grep -Fxq -- "$sha" <<<"$upstreamed"; then
        already+="$short $subject"$'\n'
        printf 'upstream %s %s\n' "$short" "$subject"
        skipped=$((skipped + 1))
        continue
    fi
    if git -C "$worktree" cherry-pick --allow-empty "$sha" >/dev/null 2>&1; then
        printf 'replay   %s %s\n' "$short" "$subject"
        replayed=$((replayed + 1))
        continue
    fi
    conflicts=$(git -C "$worktree" diff --name-only --diff-filter=U)
    if [ -z "$conflicts" ] && git -C "$worktree" diff --cached --quiet; then
        # The change applied cleanly but left nothing to commit: TARGET has it.
        git -C "$worktree" cherry-pick --skip >/dev/null 2>&1 ||
            die "cannot skip the empty replay of $short in $worktree"
        already+="$short $subject"$'\n'
        printf 'upstream %s %s\n' "$short" "$subject"
        skipped=$((skipped + 1))
        continue
    fi
    if [ -n "$conflicts" ] && only_backport_files "$conflicts"; then
        # The commit changes files that only skipped backports added, such as
        # a release branch lockfile: drop those changes and keep the rest.
        while read -r path; do
            git -C "$worktree" rm -q -- "$path"
        done <<<"$conflicts"
        dropped=$(printf '%s' "$conflicts" | tr '\n' ' ')
        if git -C "$worktree" diff --cached --quiet; then
            git -C "$worktree" cherry-pick --skip >/dev/null 2>&1 ||
                die "cannot skip the replay of $short in $worktree"
            printf 'drop     %s %s (it only changes %s)\n' "$short" "$subject" "${dropped% }"
            skipped=$((skipped + 1))
        else
            GIT_EDITOR=true git -C "$worktree" cherry-pick --continue >/dev/null 2>&1 ||
                die "cannot finish the replay of $short in $worktree"
            printf 'replay   %s %s (without its changes to %s)\n' "$short" "$subject" "${dropped% }"
            replayed=$((replayed + 1))
        fi
        continue
    fi
    git -C "$worktree" cherry-pick --abort >/dev/null 2>&1 || true
    if [ -n "$conflicts" ]; then
        notice error "$short ($subject) conflicts with $target in: $(printf '%s' "$conflicts" | tr '\n' ' ')"
    else
        notice error "$short ($subject) cannot be replayed onto $target; run git cherry-pick $sha in $worktree for details"
    fi
    printf 'Replay stopped at %s; %s keeps the commits replayed before it.\n' "$short" "$worktree"
    exit 1
done < <(git rev-list --reverse --no-merges "$base_commit..$rev")

while read -r line; do
    if [ -n "$line" ]; then
        notice warning "$line is already upstream; drop it at the next base switch"
    fi
done <<<"$already"
printf 'Replayed %d commit(s) and skipped %d onto %s in %s.\n' \
    "$replayed" "$skipped" "$(git rev-parse --short=12 "$target^{commit}")" "$worktree"

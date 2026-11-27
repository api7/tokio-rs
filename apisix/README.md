# APISIX maintenance line of Tokio

This repository carries the changes that Apache APISIX needs on top of released
Tokio versions. It is not a replacement for
[tokio-rs/tokio](https://github.com/tokio-rs/tokio): every change that suits
upstream is proposed there, and a patch is dropped as soon as the base release
contains it.

A maintenance line is one upstream release, recorded in [`BASE`](BASE), plus a
linear series of reviewed patches. Everything in this directory, the
`apisix-*.yml` workflows and [`.github/README.md`](../.github/README.md) exist
only in this repository.

## Branches and tags

| Ref | Content | Rules |
|---|---|---|
| `master` | Mirror of upstream `master` | Never commit to it. |
| `dev` | The current line: the release in `apisix/BASE` and its patch series | Changed only through pull requests. Force-pushed only by a [base switch](#switching-the-base). |
| `apisix/<version>` | A line on base `<version>`, kept while a shipped APISIX release needs it after `dev` moved on, or used as the target of a base switch | Same rules as `dev`. |
| `upstream/<topic>` | A change proposed to tokio-rs/tokio | Based on upstream `master`, never merged into a line. |
| `apisix-<version>-p<N>` (tags) | A release of the line on base `<version>` | Annotated, created by maintainers, never moved or deleted. |

Name other branches freely, for example `topic/<name>` for pull requests.

## Using a release

Point the root manifest of the final workspace at a release tag. The patch then
applies to the `tokio` dependency of every crate in the build, including
clients such as hyper or redis:

```toml
[patch.crates-io]
tokio = { git = "https://github.com/api7/tokio-rs", tag = "apisix-1.54.1-p1" }
```

- Commit the lockfile, and check that `cargo tree -i tokio` lists a single
  tokio with the source `git+https://github.com/api7/tokio-rs?tag=...`.
- The crate keeps the upstream version number, so the patch applies to every
  `tokio` requirement that the upstream release satisfies. A dependency that
  requires a newer tokio makes Cargo take tokio from crates.io instead and
  warn that the patch was not used.
- Never depend on `dev` or another branch. A base switch rewrites the branch,
  and the locked commit may no longer be fetchable.

## Patch rules

Every commit after `BASE_COMMIT` is a patch. The
[`check-series.sh`](scripts/check-series.sh) lint checks the rules marked
**(lint)** on every pull request and push, and reviewers check the rest.

1. **Linear history (lint).** Merge commits are rejected; rebase instead.
2. **Subject** `type(scope): description`, in the imperative and without a
   trailing period. Mark a breaking change with `type(scope)!: description`.
   - The lint checks the form, the type, the scope, the length of at most 72
     characters and the missing period. Reviewers check the imperative mood
     and that the scope matches the files the commit changes.
   - Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `ci`, `build`,
     `chore`, `revert`.
   - Scopes: a workspace member crate listed in the root `Cargo.toml`, such as
     `tokio` or `tokio-util`, for changes to that crate; `workspace` for
     repository-wide upstream files such as the root manifests, `Cargo.lock` or
     the upstream workflows; `apisix` for the files that exist only in this
     repository. A commit or pull request that touches several of these uses
     the scope of its primary change.
3. **Body.** Explain why the change is needed and what it does. The lint
   requires a body, and reviewers judge it.
4. **Trailers (lint)** in the last paragraph:
   - Exactly one `Upstream-Status:`
     - `Pending [reference]`: meant for upstream but not proposed yet; may
       name the upstream issue.
     - `Submitted <reference>`: proposed upstream.
     - `Backport <reference>`: a commit that upstream `master` or a
       `tokio-*.x` branch contains, applied unmodified with
       `git cherry-pick -x`, which keeps its author. A commit that only an
       open upstream pull request has is `Submitted`. The lint requires exactly
       one `(cherry picked from commit <sha>)` line. With `--verify-upstream`
       it fetches the upstream branches and requires that one of them contains
       that commit, and that the backport makes the same change, as compared
       by `git patch-id --verbatim`, with the same author. The nightly canary
       skips backports, so the label must be right. An upstream change
       that needs adapting is not a backport: mark it `Inappropriate` with the
       reference, and give it a `Drop-When`. A later upstream change to the
       same code is another Backport, never a fixup.
     - `Inappropriate <reason>`: never proposed, such as CI, documentation or
       APISIX-specific code.

     A reference is `tokio-rs/tokio#123` or a `https://github.com/tokio-rs/tokio/`
     pull request, issue or commit URL.
   - Exactly one `Drop-When:` naming the condition under which the patch can
     be dropped. `Inappropriate` patches may omit it.
5. **Fixups (lint).** To change a patch that is already in the series, add a
   commit made with `git commit --fixup=<patch>`. Its subject is
   `fixup! <subject of the patch>`, it needs no body or trailers, and an
   earlier patch that is not a Backport must have that subject. The next base
   switch folds it into its patch.
6. **Code, tests and documentation together.** A pull request that changes
   behavior adds the tests described in [Testing](#testing) and updates doc
   comments and this guide in the same pull request. Reviewers check this.

For example:

```text
feat(tokio): let a host drive the current-thread runtime

A host event loop that owns waiting needs to run a bounded batch of
tasks and learn the next timer deadline, instead of blocking in park.

Upstream-Status: Pending tokio-rs/tokio#8479
Drop-When: the base provides an equivalent host-driven API
```

Run the lint locally before pushing:

```sh
apisix/scripts/check-series.sh --verify-upstream
```

## Pull requests

1. Branch from `dev`, or from `apisix/<version>` for a fix to an older line.
2. Open a pull request into that branch and fill in every section of the
   template.
3. The `APISIX CI passed` check must succeed, and the change needs an approving
   review.
4. Merge with **Rebase and merge** only, so that the reviewed commits land
   unchanged with their trailers. Fold review changes into the pull request's
   commits before merging, or keep them as `fixup!` commits.

## Checks

[`apisix-ci.yml`](../.github/workflows/apisix-ci.yml) runs on pull requests
into, and pushes to, `dev` and `apisix/**`. Upstream `ci.yml` and `loom.yml`
only run on `master` and `tokio-*.x`, so these jobs mirror the subset that
APISIX depends on. The commands follow upstream `ci.yml` at the base, and the
toolchains are pinned as on the release branch of the base, `tokio-1.54.x`:

| Job | What it runs | Upstream counterpart |
|---|---|---|
| patch series | shellcheck and the tests of `apisix/scripts`, then `check-series.sh --verify-upstream` | none |
| fmt | `rustfmt --check` on every Rust file, Rust 1.99 | `ci.yml` fmt |
| clippy | Clippy 1.88 with the stable features and with all features under `tokio_unstable` | `ci.yml` clippy |
| docs | rustdoc with `nightly-2025-10-12` and `-Dwarnings` | `ci.yml` docs (Linux) |
| minrust | `cargo check --locked -p tokio --all-features` with Rust 1.85, which also fails on a stale `Cargo.lock` | `ci.yml` minrust on backport branches |
| cargo deny | `cargo deny check bans licenses sources` with cargo-deny 0.22.1 | the policy of `audit.yml` and `pr-audit.yml`, without advisories |
| test tokio full | `cargo test --features full`, Rust 1.99 | `ci.yml` test-tokio-full (Linux) |
| test tokio full --unstable | `full,test-util` under `tokio_unstable`, with and without `io-uring` | `ci.yml` test-unstable (Linux) |
| test tokio full --unstable (APISIX toolchain) | `full,test-util` under `tokio_unstable` with Rust 1.100.0, the toolchain of the APISIX runtime build; no `io-uring` run | none |
| test tokio full --unstable (aarch64) | `full,test-util` under `tokio_unstable` on a native arm64 runner, Rust 1.99 | none: upstream covers aarch64 with emulated cross tests |
| loom | `loom_current_thread`, `runtime::time` and `runtime::io` | `loom.yml` current-thread and time-driver jobs |
| stress test | `simple_echo_tcp` under Valgrind | `stress-test.yml` |
| valgrind | `test-mem` and `test-process-signal` under Valgrind | `ci.yml` valgrind |
| test hyper, test Quinn | hyper v1.13.0 and Quinn 0.11.12, after checking that every crate resolves tokio to this repository | `ci.yml` test-hyper and test-quinn (Linux), which take the nearest tag and do not check where tokio resolves |
| APISIX CI passed | succeeds only when every job above succeeds | none |

`cargo test` runs the unit, integration and doc tests that upstream runs with
`cargo nextest run` and `cargo test --doc`. Upstream advisories are left to the
nightly workflow because they change from day to day.

These upstream jobs are not mirrored. Add the matching job in the pull request
whose patch changes what it covers:

| Upstream jobs | Why they are not mirrored |
|---|---|
| The Windows and macOS runs of the mirrored jobs; `cross-check`, `cross-check-tier3`, `cross-test-*`, `no-atomic-u64-*`, `wasm32-*`, `freebsd-*`, `check-redox`, `x86_64-fortanix-unknown-sgx` | APISIX runs on Linux x86-64 and arm64 |
| `loom-sync`, `loom-blocking`, `loom-multi-thread` and `loom-util` in `loom.yml` | no patch changes `tokio::sync`, the blocking pool, the multi-thread scheduler or tokio-util yet |
| `loom-compile` | the loom jobs build every loom test |
| `test-workspace-all-features`, `test-workspace-all-features-panic-abort`, `test-integration-tests-per-feature`, `features`, `minimal-versions` | they cover the other crates and feature combinations; add them with a patch that adds a feature or changes another crate |
| `test-parking_lot`, `test-sharded-blocking-queue`, `check-unstable-mt-counters`, `test-unstable-taskdump` | they cover configurations that APISIX does not enable |
| `get-latest-kernel-version`, `test-io-uring-on-specific-kernel-versions` | io-uring runs on the runner kernel in the `--unstable` job, and APISIX does not use it |
| `miri-lib`, `miri-test`, `miri-doc`, `asan` | add them with the first patch that adds unsafe code |
| `semver`, `check-external-types` | add them with the first patch that changes the public API |
| `check-fuzzing`, `check-spelling`, `check-readme` | they check upstream files that this line does not change |

[`apisix-nightly.yml`](../.github/workflows/apisix-nightly.yml) runs every day
from the default branch:

- **canary** replays the series onto upstream `master` with
  [`canary.sh`](scripts/canary.sh), then checks and tests the tokio crate with
  the newest stable toolchain. It skips backports, and drops later changes to
  files that only those backports added and `master` lacks, such as the
  1.54.x lockfile. A conflict or a failing test means an upstream
  change affects a patch: open an issue and resolve it before the next base
  switch. Patches reported as already upstream can be dropped at that switch.
- **advisories** runs `cargo audit` on the locked dependencies of the line and
  on the upstream release in `apisix/BASE`. It fails on vulnerabilities and on
  unsound code, and when the base release is yanked. When an advisory affects
  APISIX, switch the base to a fixed release or backport the fix, then cut a
  release.

Check the maintenance tooling itself with `apisix/scripts/tests/run.sh`.

## Testing

Each patch brings the tests that fit what it changes:

1. **Tokio's test suite**, in the existing configurations and in any new
   configuration the patch introduces. A patch that adds a Cargo feature or a
   `cfg` extends the jobs above to cover it.
2. **Concurrency and host tests** for changes to the scheduler, the timer or the
   I/O driver: loom models of the new interleavings, and Rust tests that drive a
   simulated host without NGINX.
3. **NGINX worker scenarios**, run against a release tag before an APISIX build
   adopts it: real sockets, wakeups, timers and worker shutdown.
4. **Client compatibility** for the clients APISIX uses. hyper and Quinn run
   here; the others run with the scenarios of item 3.

## Switching the base

Switch the base when a newer upstream release fixes a problem that affects
APISIX, contains upstream versions of patches, or is due for a planned upgrade.
Prefer the LTS releases listed in the upstream README.

1. Push the commit of the new upstream tag as the branch `apisix/<new version>`.
2. On a topic branch from `dev`, run
   `git rebase -i --autosquash --onto <new tag> <old BASE_COMMIT>`.
   - Drop the patches that the new release contains. `git cherry -v <new tag>
     dev <old BASE_COMMIT>` marks with `-` the patches whose change is in the
     history of the new tag, and the nightly canary reports them. Check the
     tree too: a backport from a release branch can be in that history
     without being in the tree. `master` merged `tokio-1.54.x`, for example,
     but does not keep its lockfile.
   - Update `apisix/BASE` in the commit that adds it.
   - In `apisix-ci.yml`, take the pinned toolchains from upstream `ci.yml` on
     the release branch of the new base (`tokio-<minor>.x`). Keep every
     toolchain pinned: where upstream uses `stable`, pin the newest stable
     release that passes the checks. Review `hyper_tag` and `quinn_tag`, and
     the lists of mirrored and unmirrored jobs in [Checks](#checks).
3. Open a pull request from the topic branch into `apisix/<new version>`. It
   shows the whole series on the new base. Add the output of
   `git range-diff <old BASE_COMMIT>..dev <new tag>..<topic branch>` to the
   description, so that reviewers can see how every patch changed.
4. Once checks pass and the review approves, merge it. If a shipped APISIX
   release still uses the old line, push the old `dev` tip as
   `apisix/<old version>`. Then a maintainer moves `dev` to the new line with
   `git push --force-with-lease=dev:<old dev commit> origin apisix/<new version>:dev`
   and cuts a release.

## Releases

A release is an annotated tag `apisix-<upstream version>-p<N>` on a commit of a
line where `APISIX CI passed` succeeded. `N` starts at 1 for each base. Use the
lint output, which lists every patch and its status, as the tag message:

```sh
apisix/scripts/check-series.sh --verify-upstream <commit> >release-notes.txt
git tag -a apisix-1.54.1-p1 -F release-notes.txt <commit>
git push origin apisix-1.54.1-p1
```

## Repository settings

These settings live outside the repository and need an administrator:

- Default branch: `dev`. The nightly schedule only runs from it.
- Branch ruleset for `dev` and `apisix/**`: require a pull request with one
  approval and the `APISIX CI passed` check, require linear history, block
  force pushes and deletions, and let only maintainers bypass the rules for a
  base switch.
- Tag ruleset for `apisix-*`: only maintainers create them; nobody updates or
  deletes them.
- Pull requests: allow rebase merging only.
- Actions: enable workflows in this fork, and disable the upstream workflows
  that the APISIX workflows replace:
  - `CI` and `Loom` only run on `master` and `tokio-*.x`. `apisix-ci.yml`
    mirrors the jobs that the line needs.
  - `Stress Test` runs on every pull request; the stress test job of
    `apisix-ci.yml` runs the same check.
  - `Security Audit` runs `cargo deny check` every day from the default
    branch, and `Pull Request Security Audit` runs it when a manifest changes.
    The cargo deny job checks the same licenses, bans and sources policy on
    every pull request, and the nightly advisories job checks advisories,
    failing on unsound code too.
  - `Pull Request Labeler` only does anything in tokio-rs/tokio.

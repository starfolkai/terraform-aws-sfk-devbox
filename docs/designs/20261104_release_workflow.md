# Publish the module version and release together

- **Date:** 2026-11-04
- **PR:** [#31](https://github.com/starfolkai/terraform-aws-sfk-devbox/pull/31)

## Summary

Customers need a reliable release identifier on the infrastructure they apply.
Publishing a release now updates that identifier automatically, so maintainers
do not have to remember a separate edit.

## Why

A hand-maintained version can drift from its release tag. Detecting the mismatch
after publishing the tag is too late: customers can already apply it.

## What we decided

Josh recommended a single release action; Saurabh authorized implementing it.
A maintainer selects a new version and runs the action on main. Unreleased main
retains the last released identifier. Customers should pin a release tag.
This supersedes the hand-bump process in the initial BYOC version-tracking design.

## How it works

The Release workflow accepts canonical `vX.Y.Z` versions and runs serially.
`scripts/release.sh` bumps `MODULE_VERSION`, runs the same Terraform checks as CI,
commits the bump and pushes main plus the matching tag atomically. It then creates
the GitHub release. Tests read the version file instead of a separate constant.
The initial value is the existing latest release, `v1.2.2`.

The workflow writes with a GitHub App token, not `GITHUB_TOKEN` (see
"Branch protection" below). It runs only from main and
passes the input through an environment variable. The script requires a clean,
current main checkout, rejects non-increasing new versions, and never force-pushes.
The existing tag-push mismatch check remains a guard for manual tags. Checks run
before publishing, so a failing tree is never pushed; the app-token push also
starts CI on main and on the tag; the tag run re-checks that `MODULE_VERSION` matches the tag.

## Alternatives and tradeoffs

Manual edits plus tag CI still require maintainers to coordinate two writes.
The action avoids that coordination, at the cost of a version-only bot commit on
main.

## Branch protection

> **Updated (2026-11-17):** The release app also needs Administration read;
> see [Immutable releases](#addendum-immutable-releases-2026-11-17).

main later began requiring pull requests, and the first release attempt (v1.2.3) was
rejected: `GITHUB_TOKEN` cannot bypass that rule. We chose to let a dedicated
release GitHub App bypass it, over a release PR or tags off main, to keep
releasing a single action with `MODULE_VERSION` on main in step with releases.
The tradeoff: one actor can write main without review. Its bypass is set to
"always" on main's single ruleset, so it also skips that ruleset's force-push
and deletion rules: whoever holds the key could rewrite or delete main, not
only add a commit. `release.sh` never force-pushes. We accepted this over
splitting the ruleset (PR #34, Q1). Its key is stored only in
a `release` environment limited to main, so a branch's workflow cannot read it,
and the job's token is limited to Contents write.

Setup (repo admin, once):

1. A GitHub App installed on this repository only, with Contents: read & write.
2. main's ruleset lists that app as a bypass actor, mode "Always" (classic
   branch protection on main is off).
3. An environment named `release` whose deployment branches are limited to
   main, holding secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`
   (environment secrets, not repository secrets).

## Failure modes

> **Updated (2026-11-17):** Tags are locked only after an immutable release is
> published; see [Immutable releases](#addendum-immutable-releases-2026-11-17).

Validation failure publishes nothing. Concurrent advancement of main or tag
creation rejects the atomic push, publishing neither ref. Rerun against current
main. A failure after pushing but before release creation resumes on the next
dispatch/rerun with the same version: the tag must be an ancestor of main and
declare that exact version. Existing releases are left intact. GitHub's workflow
run and immutable Git tag retain the recovery state; the maintainer reruns the job.

## Observations and learnings

Six transaction tests use real local bare Git remotes, with Terraform commands
and the release API substituted. They cover matching commit/tag publication,
idempotent retry, malformed/non-increasing versions, failed validation, a mismatched
existing tag, post-push release failure, and a concurrent main advance.

All six passed. Terraform 1.10.5 format/validation and all 52 native module tests
also passed. The complete release script then ran against real Terraform and a
local bare Git remote: it passed root and routing-example validation, passed all
52 tests with the bumped version, and published matching main/tag refs locally.
Only GitHub release creation was substituted; no GitHub tag or release was created.
Actionlint 1.7.7 passed both workflows.

## Rollout plan

Merge the module PR after review. Complete the branch-protection setup above,
then run Release on main with the next version, `v1.3.0`: main adds features
since v1.2.2 (#27, #29, #31), and Starfolk's coordinator names v1.3.0 as the
minimum for BYOC image regeneration. The rejected v1.2.3 attempt published
nothing. This change itself publishes no release and applies no AWS
infrastructure. Customers upgrade their pin and apply to receive the reporting tag.

## Addendum: immutable releases (2026-11-17)

Release tags must keep pointing to the code customers selected. The original
workflow never moved tags, but GitHub still allowed someone with write access to
move them. For [ASK-105](https://linear.app/starfolk/issue/ASK-105), the action now
requires GitHub's repository release-immutability setting before making any
commit or push, and verifies that the published release is immutable before
reporting success. The same verification applies to retries of existing releases.

The release app gains **Administration: read** to inspect the setting. An admin
enables release immutability once; the action cannot change repository settings. The existing
atomic main/tag push and retry path stay in place. GitHub locks the tag when the
release is published, so a failed release creation leaves an unlocked tag until
a retry succeeds. A setting change during the run can also leave a mutable
release; the final verification fails rather than reporting success.

Existing releases, including v1.3.0, are not made immutable by enabling the
setting. The action does not delete or recreate them. Customers can keep pinning
the full commit SHA; that selects the same module content as its release tag.

Before running the updated action, a repository admin must:

1. Grant the release GitHub App **Administration: read** and accept the updated
   permissions on its installation.
2. Enable **Settings > General > Releases > Enable release immutability**, or run
   `gh api --method PUT repos/starfolkai/terraform-aws-sfk-devbox/immutable-releases`
   with an admin credential.

The box credential returned HTTP 403 for the settings read, so these setup steps
could not be performed here. No release was published to test this change.
The 10 release transaction tests passed using real local Git remotes and
substituted Terraform and GitHub calls. The new checks failed against the old
script. Bash syntax checks and Actionlint 1.7.7 also passed.

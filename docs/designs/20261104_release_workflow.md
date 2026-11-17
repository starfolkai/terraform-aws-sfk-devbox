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
starts tag-push CI, which re-checks that `MODULE_VERSION` matches the tag.

## Alternatives and tradeoffs

Manual edits plus tag CI still require maintainers to coordinate two writes.
The action avoids that coordination, at the cost of a version-only bot commit on
main.

## Branch protection

main later began requiring pull requests, and the first release (v1.2.3) was
rejected: `GITHUB_TOKEN` cannot bypass that rule. We chose to let a dedicated
release GitHub App bypass it, over a release PR or tags off main, to keep
releasing a single action with `MODULE_VERSION` on main in step with releases.
The tradeoff: one actor can write main without review, so its key is a secret
worth guarding, and only this workflow uses it.

Setup (repo admin, once):

1. A GitHub App installed on this repository only, with Contents: read & write.
2. Branch protection for main lists that app under "Allow specified actors to
   bypass required pull requests".
3. Repository secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`.

## Failure modes

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

Merge the module PR after review, then run Release on main with the next version
(currently `v1.2.3`). This change itself publishes no release and applies no AWS
infrastructure. Customers upgrade their pin and apply to receive the reporting tag.

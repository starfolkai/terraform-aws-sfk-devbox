# AGENTS.md

This repo has no agent docs or skills of its own. Starfolk's live in the
`starfolkai/sfk` repo, which should already be cloned on this box at
`/workspace/sfk` (if it isn't, clone it there).

Before doing anything else:

1. Read `/workspace/sfk/AGENTS.md` top to bottom, and follow it here as if it
   were this repo's. Load the `docs/agents/*.md` it points to on demand.
   Paths in it are relative to `/workspace/sfk`. Its process rules (PRs,
   reviews, GitHub, Slack, Terraform safety) apply here; what it says about
   sfk's own code doesn't.
2. Use its skills from `/workspace/sfk/.codex/skills/` (for example
   `sfkdev-code-review` to review a PR, `sfkdev-merge` to land one). When one
   applies, read its `SKILL.md` and follow it, running its scripts from
   `/workspace/sfk` with `--repo starfolkai/terraform-aws-sfk-devbox` where they
   take one.

`README.md` covers this module itself: what it creates and how customers
apply it.

# CLAUDE.md

This repo is the BYOC Terraform module (`terraform-aws-sfk-devbox`) that Starfolk customers apply in their own AWS account so Starfolk can launch devboxes there. It's public and customer-facing: write code, docs, and commit messages for a customer reading them.

Agents working here on a Starfolk box: the sibling sfk checkout at `/workspace/sfk` holds Starfolk's agent instructions. Read `/workspace/sfk/AGENTS.md` and follow it; its relative paths (e.g. `docs/agents/...`) are relative to `/workspace/sfk`. Its sfk-specific build and deploy steps don't apply to this repo.

## This repo

- A plain module: no backend and no provider. Usage examples are in `examples/`.
- Tests are in `tests/*.tftest.hcl` (`terraform test`). CI (`.github/workflows/terraform-ci.yml`) also runs `terraform fmt -check` and `terraform validate`.
- Any AWS permission the coordinator gains in sfk must also be granted to the control role in `main.tf`. See `/workspace/sfk/docs/agents/deployment.md#byoc-permissions-must-mirror-the-coordinators`.

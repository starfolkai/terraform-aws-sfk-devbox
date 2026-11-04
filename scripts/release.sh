#!/usr/bin/env bash
# Called by the manual Release workflow. Never applies customer infrastructure.
set -euo pipefail

version=${1:?Usage: release.sh vX.Y.Z}
if [[ ! $version =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Expected a canonical vX.Y.Z version: $version" >&2
  exit 1
fi
if [[ $(git branch --show-current) != main || -n $(git status --porcelain) ]]; then
  echo "Release requires a clean main checkout." >&2
  exit 1
fi
git fetch origin main --tags
if [[ $(git rev-parse HEAD) != "$(git rev-parse origin/main)" ]]; then
  echo "Release requires current origin/main; rerun the workflow." >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$version"; then
  # A run can stop after the atomic push but before GitHub creates the release.
  # The next dispatch/rerun resumes from the immutable tag, even if main moved.
  git merge-base --is-ancestor "$version" origin/main
  if [[ $(git show "$version:MODULE_VERSION") != "$version" ]]; then
    echo "Existing tag does not declare $version; refusing to publish." >&2
    exit 1
  fi
else
  current=$(tr -d '\r\n' < MODULE_VERSION)
  python3 - "$current" "$version" <<'PY'
import re
import sys

def parts(value):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        raise SystemExit(f"Invalid module version: {value}")
    return tuple(map(int, value[1:].split(".")))

if parts(sys.argv[2]) <= parts(sys.argv[1]):
    raise SystemExit("New version must be greater than MODULE_VERSION.")
PY
  printf '%s\n' "$version" > MODULE_VERSION

  # GITHUB_TOKEN pushes do not start push workflows. Validate the bumped tree
  # here before publishing, rather than relying on tag-push CI to run later.
  terraform fmt -check -recursive -diff
  terraform init -backend=false -input=false
  terraform validate
  terraform -chdir=examples/routing init -backend=false -input=false
  terraform -chdir=examples/routing validate
  terraform test

  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git add MODULE_VERSION
  git commit -m "Release $version"
  git tag "$version"
  # If main advanced or the tag was taken, neither ref is published.
  git push --atomic origin HEAD:refs/heads/main "refs/tags/$version"
fi

if gh release view "$version" >/dev/null 2>&1; then
  echo "Release $version already exists."
else
  gh release create "$version" --verify-tag --generate-notes --title "$version"
fi

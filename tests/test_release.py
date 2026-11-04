"""Exercise release transactions against real local Git remotes; never publish.

Terraform itself is covered by terraform test. These tests substitute only the
Terraform command and GitHub release API to exercise failures without AWS/GitHub
writes. All commit, tag, push, race and retry behavior uses actual Git.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/release.sh"


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "origin.git"
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        (self.repo / "MODULE_VERSION").write_text("v1.2.2\n")
        self.git("add", ".")
        self.git("commit", "-m", "Initial")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-u", "origin", "main")
        self.initial = self.git("rev-parse", "HEAD").stdout.strip()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.release_file = self.root / "release"
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "RELEASE_RECORD": str(self.release_file),
        }
        for name, body in {
            "terraform": 'exit "${TERRAFORM_EXIT:-0}"',
            "gh": '''
if [[ "$1 $2" == "release view" ]]; then
  test -f "$RELEASE_RECORD"
else
  test "${RELEASE_FAIL:-0}" = 0 || exit 1
  printf '%s\\n' "$3" > "$RELEASE_RECORD"
fi
''',
        }.items():
            path = self.bin / name
            path.write_text("#!/usr/bin/env bash\nset -eu\n" + body + "\n")
            path.chmod(0o700)

    def git(self, *args, **kwargs):
        return subprocess.run(
            ["git", *args], cwd=self.repo, text=True, capture_output=True,
            check=True, **kwargs,
        )

    def release(self, version="v1.2.3", **env):
        return subprocess.run(
            ["bash", str(SCRIPT), version], cwd=self.repo,
            env={**self.env, **env}, text=True, capture_output=True,
        )

    def assert_unpublished(self):
        self.assertEqual(self.git("ls-remote", "--tags", "origin").stdout, "")
        self.assertIn(self.initial, self.git("ls-remote", "origin", "main").stdout)
        self.assertFalse(self.release_file.exists())

    def test_publishes_matching_commit_and_tag_and_retries_without_new_commit(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("show", "v1.2.3:MODULE_VERSION").stdout, "v1.2.3\n")
        sha = self.git("rev-parse", "HEAD").stdout.strip()
        refs = self.git("ls-remote", "origin", "main", "refs/tags/v1.2.3").stdout
        self.assertEqual(refs.count(sha), 2)
        self.assertEqual(self.release_file.read_text(), "v1.2.3\n")
        self.assertEqual(self.release().returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), sha)

    def test_invalid_equal_and_lower_versions_do_not_publish(self):
        for version in ["v1.2.2", "v1.2.1", "v01.2.3", "1.2.3", "v1.2.3;false"]:
            with self.subTest(version=version):
                self.assertNotEqual(self.release(version).returncode, 0)
                self.assert_unpublished()

    def test_failed_validation_does_not_publish(self):
        self.assertNotEqual(self.release(TERRAFORM_EXIT="1").returncode, 0)
        self.assert_unpublished()

    def test_release_api_failure_resumes_from_tag_even_after_main_moves(self):
        self.assertNotEqual(self.release(RELEASE_FAIL="1").returncode, 0)
        tag_sha = self.git("rev-parse", "v1.2.3").stdout
        self.git("commit", "--allow-empty", "-m", "Later change")
        self.git("push", "origin", "main")
        head = self.git("rev-parse", "HEAD").stdout
        self.assertEqual(self.release().returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git("rev-parse", "v1.2.3").stdout, tag_sha)
        self.assertEqual(self.release_file.read_text(), "v1.2.3\n")

    def test_existing_mismatched_tag_is_rejected(self):
        self.git("tag", "v1.2.3")
        self.git("push", "origin", "v1.2.3")
        self.assertNotEqual(self.release().returncode, 0)
        self.assertFalse(self.release_file.exists())

    def test_concurrent_main_push_leaves_release_tag_unpublished(self):
        # The server advances main while this release is validating.
        peer = self.root / "peer"
        self.git("clone", "--branch", "main", str(self.remote), str(peer))
        for key, value in [("user.name", "Peer"), ("user.email", "peer@example.com")]:
            subprocess.run(["git", "-C", str(peer), "config", key, value], check=True)
        hook = self.bin / "terraform"
        hook.write_text('''#!/usr/bin/env bash
set -eu
if [[ "$1" == "test" ]]; then
  git -C "$PEER" commit --allow-empty -m Concurrent
  git -C "$PEER" push origin main
fi
''')
        self.assertNotEqual(self.release(PEER=str(peer)).returncode, 0)
        self.assertEqual(self.git("ls-remote", "--tags", "origin").stdout, "")
        peer_sha = subprocess.check_output(["git", "-C", str(peer), "rev-parse", "HEAD"], text=True).strip()
        self.assertIn(peer_sha, self.git("ls-remote", "origin", "main").stdout)
        self.assertFalse(self.release_file.exists())


if __name__ == "__main__":
    unittest.main()

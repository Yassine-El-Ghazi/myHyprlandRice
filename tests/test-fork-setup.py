#!/usr/bin/env python3
"""Check explicit fork trust enrollment using disposable keys and checkouts."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class ForkSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="myhypr-fork-setup-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "fork with spaces"
        self.repo.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.global_config = self.home / "gitconfig"
        self.global_config.write_text(
            '[user]\n name = Fork Fixture\n email = fork@example.invalid\n'
            '[commit]\n gpgsign = false\n'
        )
        self.env = {
            "HOME": str(self.home), "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(self.global_config),
        }
        scripts = self.repo / "scripts"
        scripts.mkdir()
        for relative in ("scripts/lib.sh", "scripts/setup-fork.sh", "bootstrap.sh"):
            shutil.copy2(REPO / relative, self.repo / relative)
        self.key = self.root / "fork signing key"
        self.upstream_key = self.root / "upstream key"
        for path in (self.key, self.upstream_key):
            self.command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                         "private-machine-comment", "-f", str(path))
        self.public_key = Path(str(self.key) + ".pub")
        self.signers = self.repo / ".config/git/allowed_signers"
        self.signers.parent.mkdir(parents=True)
        upstream = Path(str(self.upstream_key) + ".pub").read_text().split()
        self.original_signers = f"upstream@example.invalid {upstream[0]} {upstream[1]}\n"
        self.signers.write_text(self.original_signers)
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://example.invalid/fork.git")
        self.git("add", "-A")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Initial fixture")

    def command(self, *arguments, check=True):
        return subprocess.run(arguments, env=self.env, capture_output=True,
                              text=True, check=check, timeout=30)

    def git(self, *arguments, check=True):
        return self.command("git", "-C", str(self.repo), *arguments, check=check)

    def setup(self, *arguments, check=True):
        return self.command("bash", str(self.repo / "scripts/setup-fork.sh"),
                            "--public-key", str(self.public_key), *arguments, check=check)

    def config(self, key):
        return self.git("config", "--local", "--get", key).stdout.strip()

    def state(self):
        return (self.signers.read_bytes(), (self.repo / ".git/config").read_bytes(),
                self.global_config.read_bytes(), self.git("rev-parse", "HEAD").stdout)

    def test_enrollment_retains_upstream_and_configures_only_this_checkout(self):
        global_before = self.global_config.read_bytes()
        remote_before = self.git("remote", "get-url", "origin").stdout
        head_before = self.git("rev-parse", "HEAD").stdout
        self.setup()
        text = self.signers.read_text()
        self.assertTrue(text.startswith(self.original_signers))
        self.assertIn('fork@example.invalid namespaces="git" ssh-ed25519 ', text)
        self.assertNotIn("private-machine-comment", text)
        self.assertEqual(self.config("user.signingkey"), str(self.public_key))
        for key, value in (("gpg.format", "ssh"), ("commit.gpgsign", "true"),
                           ("merge.verifySignatures", "true"), ("pull.ff", "only")):
            self.assertEqual(self.config(key), value)
        self.assertEqual(self.config("gpg.ssh.allowedSignersFile"), str(self.signers))
        self.assertEqual(self.global_config.read_bytes(), global_before)
        self.assertEqual(self.git("remote", "get-url", "origin").stdout, remote_before)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, head_before)

    def test_repeat_enrollment_is_idempotent(self):
        self.setup()
        before = self.state()
        self.setup()
        self.assertEqual(self.state(), before)

    def test_existing_bare_entry_is_not_duplicated(self):
        key = self.public_key.read_text().split()
        self.signers.write_text(f"fork@example.invalid {key[0]} {key[1]} existing comment\n")
        before = self.signers.read_bytes()
        self.setup()
        self.assertEqual(self.signers.read_bytes(), before)

    def test_dry_run_preserves_files_git_configuration_and_revision(self):
        before = self.state()
        self.setup("--dry-run")
        self.assertEqual(self.state(), before)

    def test_explicit_principal_and_missing_identity(self):
        self.global_config.write_text('[user]\n name = Fork Fixture\n')
        before = self.state()
        result = self.setup(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state(), before)
        self.setup("--principal", "explicit@example.invalid")
        self.assertIn("explicit@example.invalid namespaces=", self.signers.read_text())

    def test_invalid_or_nonpublic_input_does_not_change_trust_or_config(self):
        normal = self.public_key.read_text()
        samples = [self.key.read_text(), normal + normal,
                   'command="unexpected" ' + normal, "ssh-ed25519 invalid-data\n"]
        for sample in samples:
            with self.subTest(sample_kind=sample.split()[0]):
                before = self.state()
                self.public_key.write_text(sample)
                result = self.setup(check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.state(), before)
                self.assertNotIn(sample, result.stdout + result.stderr)

    def test_wildcards_lists_and_control_characters_are_not_trusted_principals(self):
        for principal in ("*", "person,another", "person name", "person\nother"):
            with self.subTest(principal=repr(principal)):
                before = self.state()
                self.assertNotEqual(self.setup("--principal", principal,
                                               check=False).returncode, 0)
                self.assertEqual(self.state(), before)

    def test_allow_list_symlink_is_rejected_without_touching_target(self):
        outside = self.root / "outside"
        outside.write_text("unrelated file")
        self.signers.unlink()
        self.signers.symlink_to(outside)
        config_before = (self.repo / ".git/config").read_bytes()
        self.assertNotEqual(self.setup(check=False).returncode, 0)
        self.assertEqual(outside.read_text(), "unrelated file")
        self.assertEqual((self.repo / ".git/config").read_bytes(), config_before)

    def test_bootstrap_option_and_dry_run_forward_key_without_reinstalling(self):
        for name in ("migrate-namespace.sh", "migrate-local.sh", "doctor.sh"):
            path = self.repo / "scripts" / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o700)
        arguments = ("--profile", "core", "--no-packages", "--no-system", "--no-link",
                     "--no-hooks", "--fork-key", str(self.public_key),
                     "--fork-principal", "bootstrap@example.invalid")
        before = self.state()
        self.command("bash", str(self.repo / "bootstrap.sh"), *arguments, "--dry-run")
        self.assertEqual(self.state(), before)
        self.command("bash", str(self.repo / "bootstrap.sh"), *arguments)
        self.assertIn("bootstrap@example.invalid namespaces=", self.signers.read_text())
        self.assertEqual(self.config("commit.gpgsign"), "true")

    def test_automatic_updates_keep_the_preexisting_commit_as_trust_anchor(self):
        original = self.git("rev-parse", "HEAD").stdout.strip()
        self.setup()
        self.git("add", ".config/git/allowed_signers")
        self.signed_commit(self.key, "Enroll explicit local fork trust")
        enrolled = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertNotEqual(self.verify_candidate(original, enrolled), 0,
                            "candidate must not authorize its own new signing key")
        (self.repo / "revision.txt").write_text("fork revision\n")
        self.git("add", "revision.txt")
        self.signed_commit(self.key, "Signed fork update")
        fork_update = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertEqual(self.verify_candidate(enrolled, fork_update), 0)
        (self.repo / "revision.txt").write_text("upstream revision\n")
        self.git("add", "revision.txt")
        self.signed_commit(self.upstream_key, "Signed upstream update")
        upstream_update = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertEqual(self.verify_candidate(enrolled, upstream_update), 0)

    def signed_commit(self, key, message):
        self.git("-c", f"user.signingkey={key}", "-c", "core.hooksPath=/dev/null",
                 "commit", "-qm", message)

    def verify_candidate(self, current, candidate):
        transaction = self.root / "transaction"
        transaction.mkdir(exist_ok=True)
        result = self.command(
            "bash", "-c",
            'source "$1/scripts/lib.sh"; source "$1/scripts/lib/maintenance-git.sh"; '
            '_maintenance_git_verify_candidate_signature "$2" "$3" "$4" "$5"',
            "fork-signature-fixture", str(REPO), str(self.repo), current, candidate,
            str(transaction), check=False,
        )
        return result.returncode


if __name__ == "__main__":
    unittest.main()

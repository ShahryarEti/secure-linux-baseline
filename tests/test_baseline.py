"""Verify rendered baseline artifacts and refusal gates without applying a baseline."""

import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "scripts" / "baseline.sh"
APPLY = ROOT / "scripts" / "apply-baseline.sh"
CHECK_SSH_LAYOUT = ROOT / "scripts" / "check-ssh-layout.sh"


class BaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key_dir = tempfile.TemporaryDirectory(prefix="baseline-test-key-")
        cls.private_key = Path(cls.key_dir.name) / "id_ed25519"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
             "disposable-test-key", "-f", str(cls.private_key)],
            check=True, capture_output=True, text=True,
        )
        cls.public_key = cls.private_key.with_suffix(".pub")

    @classmethod
    def tearDownClass(cls):
        cls.key_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="baseline-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.output = self.path / "bundle"

    def command(self, script, *args, unprivileged=False):
        def drop_root():
            os.setgroups([])
            os.setgid(1000)
            os.setuid(1000)

        return subprocess.run(
            ["bash", str(script), *map(str, args)],
            capture_output=True, text=True, timeout=15,
            preexec_fn=drop_root if unprivileged and os.geteuid() == 0 else None,
        )

    def render_args(self, *, os_name="ubuntu", key=None, output=None,
                    user="lab-operator", cidr="192.0.2.10/32"):
        return [
            "render", "--os", os_name, "--admin-user", user,
            "--public-key", str(key or self.public_key),
            "--output", str(output or self.output), "--admin-cidr", cidr,
        ]

    def render(self, **kwargs):
        result = self.command(RENDER, *self.render_args(**kwargs))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def assert_refused(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr.strip() or result.stdout.strip())

    def test_help_is_available(self):
        result = self.command(RENDER, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("render", result.stdout)

    def test_renders_complete_bundle_for_each_os(self):
        expected = {
            "metadata.env", "authorized_keys", "sshd-hardening.conf",
            "sudoers-baseline", "baseline-service-status", "firewall-rule.txt",
        }
        for os_name in ("ubuntu", "rocky"):
            with self.subTest(os=os_name):
                output = self.path / os_name
                self.render(os_name=os_name, output=output)
                self.assertTrue(expected.issubset({p.name for p in output.iterdir()}))
                metadata = (output / "metadata.env").read_text()
                self.assertIn(f"OS={os_name}\n", metadata)
                self.assertIn("ADMIN_USER=lab-operator\n", metadata)
                self.assertIn("ADMIN_CIDR=192.0.2.10/32\n", metadata)

    def test_public_key_is_validated_and_comment_is_removed(self):
        self.render()
        key = (self.output / "authorized_keys").read_text()
        self.assertEqual(key.strip().split(), self.public_key.read_text().split()[:2])
        self.assertNotIn("disposable-test-key", key)
        result = subprocess.run(
            ["ssh-keygen", "-lf", str(self.output / "authorized_keys")],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ssh_policy_requires_keys_and_disables_root_login(self):
        self.render()
        lines = {
            line.strip() for line in
            (self.output / "sshd-hardening.conf").read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        for directive in (
            "PubkeyAuthentication yes", "PasswordAuthentication no",
            "KbdInteractiveAuthentication no", "PermitRootLogin no",
        ):
            self.assertIn(directive, lines)
        self.assertNotIn("PermitRootLogin yes", lines)

    def test_sudo_rule_grants_only_fixed_status_helper(self):
        self.render()
        rule = (self.output / "sudoers-baseline").read_text()
        self.assertIn("lab-operator", rule)
        self.assertIn("/usr/local/sbin/baseline-service-status", rule)
        self.assertNotIn("NOPASSWD: ALL", rule)
        self.assertNotIn("ALL=(ALL) ALL", rule)
        self.assertNotIn("/bin/bash", rule)
        self.assertNotIn("/bin/sh", rule)

    def test_status_helper_uses_target_service_without_user_arguments(self):
        for os_name, service in (("ubuntu", "ssh"), ("rocky", "sshd")):
            with self.subTest(os=os_name):
                output = self.path / os_name
                self.render(os_name=os_name, output=output)
                helper = (output / "baseline-service-status").read_text()
                self.assertIn(service, helper)
                self.assertIn("--no-pager", helper)
                self.assertNotIn('"$@"', helper)
                self.assertNotIn("eval ", helper)
                syntax = subprocess.run(
                    ["bash", "-n", str(output / "baseline-service-status")],
                    capture_output=True, text=True,
                )
                self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_firewall_artifact_is_target_specific_and_restricts_source(self):
        for os_name, tool in (("ubuntu", "ufw"), ("rocky", "firewall-cmd")):
            with self.subTest(os=os_name):
                output = self.path / os_name
                self.render(os_name=os_name, output=output)
                rule = (output / "firewall-rule.txt").read_text()
                self.assertIn(tool, rule)
                self.assertIn("192.0.2.10/32", rule)
                self.assertIn("22", rule)
                self.assertNotIn("0.0.0.0/0", rule)
                self.assertNotIn("disable", rule)

    def test_render_does_not_create_private_key_or_environment_secrets(self):
        self.render()
        for path in self.output.iterdir():
            if path.is_file():
                text = path.read_text()
                self.assertNotIn("BEGIN OPENSSH PRIVATE KEY", text)
                self.assertNotIn("BEGIN RSA PRIVATE KEY", text)
        self.assertTrue(self.private_key.exists())

    def test_rocky_firewall_example_preserves_one_quoted_rich_rule(self):
        self.render(os_name="rocky")
        arguments = shlex.split((self.output / "firewall-rule.txt").read_text())
        self.assertEqual(arguments, [
            "firewall-cmd",
            '--add-rich-rule=rule family="ipv4" source address="192.0.2.10/32" '
            'port port="22" protocol="tcp" accept',
        ])

    def test_output_directory_and_key_have_restricted_permissions(self):
        self.render()
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode) & 0o077, 0)
        self.assertEqual(
            stat.S_IMODE((self.output / "authorized_keys").stat().st_mode) & 0o077,
            0,
        )

    def test_unknown_and_missing_options_are_refused(self):
        cases = [[], ["render"], ["unknown"], ["render", "--unknown"],
                 ["render", "--os"]]
        for args in cases:
            with self.subTest(args=args):
                self.assert_refused(self.command(RENDER, *args))
                self.assertFalse(self.output.exists())

    def test_unsupported_operating_system_is_refused(self):
        for os_name in ("debian", "ubuntu24.04", "Rocky", ""):
            with self.subTest(os=os_name):
                result = self.command(RENDER, *self.render_args(os_name=os_name))
                self.assert_refused(result)
                self.assertFalse(self.output.exists())

    def test_invalid_or_privileged_usernames_are_refused(self):
        for user in ("root", "Root", "-operator", "bad name", "a;id", "a\nroot",
                     "x" * 33, ""):
            with self.subTest(user=user):
                self.assert_refused(self.command(RENDER, *self.render_args(user=user)))
                self.assertFalse(self.output.exists())

    def test_invalid_or_unrestricted_source_networks_are_refused(self):
        for cidr in ("0.0.0.0/0", "192.0.2.1", "256.0.2.1/32", "192.0.2.1/33",
                     "192.0.2.1/-1", "::1/128", "192.0.2.1/32;id", ""):
            with self.subTest(cidr=cidr):
                self.assert_refused(self.command(RENDER, *self.render_args(cidr=cidr)))
                self.assertFalse(self.output.exists())

    def test_private_key_is_refused(self):
        self.assert_refused(self.command(RENDER, *self.render_args(key=self.private_key)))
        self.assertFalse(self.output.exists())

    def test_invalid_public_key_payload_is_refused(self):
        key = self.path / "invalid.pub"
        key.write_text("ssh-ed25519 AAAAnot-a-real-key example\n")
        self.assert_refused(self.command(RENDER, *self.render_args(key=key)))
        self.assertFalse(self.output.exists())

    def test_multiple_public_keys_are_refused(self):
        key = self.path / "multiple.pub"
        key.write_text(self.public_key.read_text() * 2)
        self.assert_refused(self.command(RENDER, *self.render_args(key=key)))
        self.assertFalse(self.output.exists())

    def test_authorized_key_options_are_refused(self):
        key = self.path / "options.pub"
        key.write_text('command="id" ' + self.public_key.read_text())
        self.assert_refused(self.command(RENDER, *self.render_args(key=key)))
        self.assertFalse(self.output.exists())

    def test_missing_key_is_refused(self):
        self.assert_refused(self.command(
            RENDER, *self.render_args(key=self.path / "missing.pub")))
        self.assertFalse(self.output.exists())

    def test_existing_output_is_never_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / "preserve-me"
        sentinel.write_text("original content\n")
        self.assert_refused(self.command(RENDER, *self.render_args()))
        self.assertEqual(sentinel.read_text(), "original content\n")
        self.assertEqual({p.name for p in self.output.iterdir()}, {"preserve-me"})

    def test_symlink_output_is_refused_without_touching_destination(self):
        target = self.path / "target"
        target.mkdir()
        self.output.symlink_to(target, target_is_directory=True)
        self.assert_refused(self.command(RENDER, *self.render_args()))
        self.assertEqual(list(target.iterdir()), [])

    def test_apply_actions_require_explicit_vm_confirmation(self):
        for action in ("bootstrap", "harden", "firewall", "rollback"):
            with self.subTest(action=action):
                flag = "--state" if action == "rollback" else "--bundle"
                result = self.command(APPLY, action, flag, self.path,
                                      unprivileged=True)
                self.assert_refused(result)

    def test_nonroot_cannot_run_confirmed_bootstrap(self):
        result = self.command(
            APPLY, "bootstrap", "--bundle", self.path,
            "--confirm-disposable-vm", unprivileged=True,
        )
        self.assert_refused(result)
        self.assertIn("root", (result.stdout + result.stderr).lower())

    def test_hardening_requires_key_session_confirmation(self):
        result = self.command(
            APPLY, "harden", "--bundle", self.path,
            "--confirm-disposable-vm", unprivileged=True,
        )
        self.assert_refused(result)

    def test_hardening_requires_separate_recovery_administrator(self):
        result = self.command(
            APPLY, "harden", "--bundle", self.path,
            "--confirm-disposable-vm", "--confirm-key-session", "lab-operator",
            unprivileged=True,
        )
        self.assert_refused(result)
        self.assertIn("--confirm-recovery-admin", result.stderr)

    def test_firewall_requires_its_own_confirmation(self):
        result = self.command(
            APPLY, "firewall", "--bundle", self.path,
            "--confirm-disposable-vm", unprivileged=True,
        )
        self.assert_refused(result)

    def ssh_layout(self, label, *, extra_main="", dropin=None):
        directory = self.path / label
        directory.mkdir()
        main = directory / "sshd_config"
        main.write_text(
            "# Temporary configuration fixture\n"
            "Include /etc/ssh/sshd_config.d/*.conf\n"
            "Port 22\nUsePAM yes\n" + extra_main
        )
        dropins = directory / "sshd_config.d"
        dropins.mkdir()
        if dropin is not None:
            (dropins / "50-fixture.conf").write_text(dropin)
        return main, dropins

    def test_ssh_layout_accepts_stock_include_and_normal_directives(self):
        for target in ("ubuntu", "rocky"):
            with self.subTest(target=target):
                main, dropins = self.ssh_layout(target)
                result = self.command(CHECK_SSH_LAYOUT, main, dropins, target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_ssh_layout_rejects_match_in_main_and_dropins(self):
        for index, directive in enumerate(("Match User other", "mAtCh=User other")):
            for location in ("main", "dropin"):
                with self.subTest(directive=directive, location=location):
                    body = directive + "\n    PasswordAuthentication yes\n"
                    main, dropins = self.ssh_layout(
                        f"match-{index}-{location}",
                        extra_main=body if location == "main" else "",
                        dropin=body if location == "dropin" else None,
                    )
                    self.assert_refused(self.command(
                        CHECK_SSH_LAYOUT, main, dropins, "ubuntu"))

    def test_ssh_layout_rejects_unknown_include_syntaxes(self):
        for index, directive in enumerate(("Include /tmp/x", "iNcLuDe=/tmp/x")):
            for location in ("main", "dropin"):
                with self.subTest(directive=directive, location=location):
                    main, dropins = self.ssh_layout(
                        f"include-{index}-{location}",
                        extra_main=directive + "\n" if location == "main" else "",
                        dropin=directive + "\n" if location == "dropin" else None,
                    )
                    self.assert_refused(self.command(
                        CHECK_SSH_LAYOUT, main, dropins, "ubuntu"))

    def test_ssh_layout_rejects_symlink_main_dropin_and_directory(self):
        for location in ("main", "dropin", "directory"):
            with self.subTest(location=location):
                main, dropins = self.ssh_layout(
                    "symlink-" + location, dropin="PubkeyAuthentication yes\n")
                if location == "main":
                    original = main.with_name("original-main")
                    main.rename(original)
                    main.symlink_to(original)
                elif location == "dropin":
                    file = dropins / "50-fixture.conf"
                    original = file.with_name("original-dropin")
                    file.rename(original)
                    file.symlink_to(original)
                else:
                    original = dropins.with_name("original-dropins")
                    dropins.rename(original)
                    dropins.symlink_to(original, target_is_directory=True)
                self.assert_refused(self.command(
                    CHECK_SSH_LAYOUT, main, dropins, "ubuntu"))

    def test_ssh_layout_rejects_unknown_nested_include(self):
        main, dropins = self.ssh_layout("nested")
        nested = self.path / "nested-policy.conf"
        nested.write_text("Include /tmp/another-policy.conf\n")
        (dropins / "50-nested.conf").write_text(f"Include {nested}\n")
        self.assert_refused(self.command(
            CHECK_SSH_LAYOUT, main, dropins, "ubuntu"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

# Testing and Verification

Configuration rendering and a complete remote-access workflow are different
checks. This document keeps their results separate.

## Repository checks

With the development tools installed, run from the project root:

```bash
make check
```

The tests should cover valid rendering for both operating systems, rejected
inputs, public-key validation, file permissions, OS-specific outputs, and apply
safety gates. ShellCheck checks the Bash sources. Native configuration tools can
validate the rendered SSH and sudo files in a suitable environment.

Tests do not need a private key in Git. Generate temporary test keys when needed
and remove them with the test workspace. Do not use real keys or internal host
details as fixtures.

## Validation record

| Check | Environment | Outcome |
| --- | --- | --- |
| Syntax for all three scripts, ShellCheck, and 31 automated tests | Debian 13 development container | Passed |
| Syntax for all three scripts, ShellCheck, and 31 automated tests | Ubuntu 24.04.5 LTS container, nonroot UID 1000 | Passed |
| Both OS bundles parsed with native Ubuntu `sshd -t`, `sshd -T`, and `visudo -cf` | Ubuntu 24.04.5 LTS container | Passed; key-only, root-login, and password settings matched |
| Stock Ubuntu SSH layout checked by `check-ssh-layout.sh` | Ubuntu 24.04.5 LTS container | Passed |
| Native Rocky SSH and sudo validation | Rocky Linux 9.3 container | Blocked before execution: DNF metadata requests to `mirrors.rockylinux.org` received proxy HTTP 403 |
| Apply, remote SSH, scoped sudo, firewall, and rollback | Ubuntu Server 24.04 LTS systemd VM | Not executed |
| Apply, remote SSH, scoped sudo, firewall, and rollback | Rocky Linux 9 systemd VM | Not executed |
| Hosted workflow | GitHub Actions | Not executed |

These checks were executed on October 24, 2026. Ubuntu tool versions were Bash
5.2.21, OpenSSH 9.6p1 Ubuntu 3ubuntu13.20, visudo 1.9.15p5, ShellCheck 0.9.0,
and Python 3.12.3. The 31-test suites completed without failures. Validating the
Rocky bundle with Ubuntu's tools is not native
Rocky validation. No Rocky validator packages were installed after the blocked
DNF request.

There are no claimed production results or completed remote-login checks. Full
VM bootstrap, hardening, firewall, rollback, SELinux, and AppArmor runtime checks
were not executed. A container can validate userland tools and configuration
syntax; it cannot establish that the VM access workflow is safe or working.

## Record target versions

On the chosen target, record the OS and native tool versions before the lab.

Ubuntu:

```bash
cat /etc/os-release
bash --version
dpkg-query -W openssh-server sudo ufw apparmor
systemctl --version
```

Rocky:

```bash
cat /etc/os-release
bash --version
rpm -q openssh-server sudo firewalld selinux-policy-targeted policycoreutils
systemctl --version
getenforce
```

Do not treat a package name or a test plan as proof of an installed version.

## Full VM acceptance checklist

Use a fresh VM, console access, a pre-change snapshot, an existing administrator
session, and a separate workstation terminal. Follow the phase order in
[installation](installation.md).

| Stage | Required evidence |
| --- | --- |
| Before apply | OS, package versions, current SSH syntax, active service, firewall policy, console access, and a distinct tested nonroot key-and-sudo recovery administrator |
| Render | Reviewed files, correct public-key fingerprint, correct OS and source CIDR, no host changes |
| Bootstrap | Operator ownership and modes, no sudo/wheel membership, valid sudo rule, separate successful key session |
| Scoped sudo | Status helper works without a password; general root command and helper arguments are denied |
| Harden | Valid complete SSH configuration, supported include layout, no `Match` blocks, effective policy, active SSH service, another fresh key session for operator and recovery administrator |
| Negative authentication | Client-advertised methods and effective policy show key-only access; password and root access are not permitted |
| Firewall | Correct active zone or UFW policy, permitted-source login, denied-source test from a second lab client, existing rules reviewed |
| Rollback | Reverse-order phase recovery, expected SSH settings, only owned firewall changes reversed, operator locked and expired with no-login shell |
| After recovery | Existing administrator access still works; retained account/home/state reviewed |

Keep concise command output and the relevant service logs. Do not publish private
keys, real internal addresses, host identifiers, or unreviewed logs.

## SSH policy and service checks

Check syntax and effective settings from the target's existing administrator
session:

```bash
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T
sudo visudo -c
```

Check connection-specific policy when existing `Match` rules apply. The
[troubleshooting guide](troubleshooting.md) includes the `sshd -T -C` command.
Remote authentication tests must use fresh sessions; an already open session
does not prove a new connection will work.

Use the correct service unit and logs:

```bash
# Ubuntu only
sudo systemctl is-active ssh.service
sudo journalctl -u ssh.service -n 50 --no-pager

# Rocky only
sudo systemctl is-active sshd.service
sudo journalctl -u sshd.service -n 50 --no-pager
```

Run only the commands for the target OS. Retain the recovery session during all
checks.

## Negative checks

From the operator session, the following should fail:

```bash
sudo -n id
sudo -n /usr/local/sbin/baseline-service-status extra-argument
```

Record both exit codes and error messages. Do not call a nonzero command a
passed negative test without confirming the expected reason.

From a workstation, inspect a fresh verbose SSH connection and compare the
server's offered authentication methods with the effective configuration. A
locked password on one account is not enough evidence that password
authentication is disabled for every relevant user and source.

## Firewall and rollback checks

The firewall phase adds or retains a rule; it is not a complete firewall audit.
Do not describe the VM as source-restricted if broader rules still allow access.
Use a separate lab client to test a denied source without changing the working
administration connection.

Each phase prints its own recovery directory. Run rollback in reverse order and
verify the actual resulting configuration and new connections. Confirm that a
pre-existing firewall rule is retained and an added rule is removed. Bootstrap
rollback keeps the account and home but is intended to deny new sessions by
locking and expiring the account and setting a no-login shell. Verify that effect
on the real VM, including access that does not request an interactive shell.

## Hosted CI limitations

The repository workflow can run suitable rendering, lint, and configuration
tests after publication. The presence of a workflow file is not evidence that a
hosted run passed. CI should not apply this baseline to the runner or change its
firewall. Full systemd VM and remote-access tests remain a separate lab task.

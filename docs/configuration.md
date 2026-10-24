# Configuration

## Render a bundle

Run the renderer as a normal user from the project root:

```bash
bash scripts/baseline.sh render \
  --os ubuntu \
  --admin-user lab-operator \
  --public-key "$HOME/.ssh/secure-linux-baseline.pub" \
  --admin-cidr 192.0.2.0/24 \
  --output "$HOME/baseline-bundle"
```

The source CIDR is an example. Before applying, replace it with the actual
management source range visible to the VM. If a VPN or NAT is involved, the VM
may see a different address from the workstation's local address.

| Option | Meaning |
| --- | --- |
| `--os ubuntu` | Render for Ubuntu Server 24.04 LTS |
| `--os rocky` | Render for Rocky Linux 9 |
| `--admin-user NAME` | Name of the new operator; despite the option name, it receives no general root access |
| `--public-key FILE` | A file containing one valid Ed25519 public key |
| `--admin-cidr CIDR` | IPv4 management source range; a global `/0` range is rejected |
| `--output DIR` | New directory for the rendered files |

The SSH port is fixed at `22`. Inputs are data, not shell commands. Existing
output directories and invalid inputs are rejected. No private key is needed.

## Bundle files

| File | Purpose |
| --- | --- |
| `metadata.env` | Validated nonsecret input values used by the apply script |
| `authorized_keys` | The selected Ed25519 public key |
| `sshd-hardening.conf` | SSH settings for the hardening phase |
| `sudoers-baseline` | Narrow sudo permission for the operator |
| `baseline-service-status` | Status-only helper installed as a root-owned executable |
| `firewall-rule.txt` | The source-limited TCP 22 rule for the selected OS |

Inspect the complete bundle before applying it. A public key is not a private
credential, but bundle metadata can describe a real host or management network.
Keep real bundles out of Git.

## Operator access

The account uses SSH public-key authentication. Its `.ssh` directory is mode
`0700`, and `authorized_keys` is mode `0600`. The account has its own primary
group. It does not join Ubuntu's `sudo` group or Rocky's `wheel` group.

The sudo rule permits only:

```bash
sudo -n /usr/local/sbin/baseline-service-status
```

It does not grant `sudo bash`, unrestricted `systemctl`, a shell escape through
a pager, or a general root command. Review both the sudo rule and helper source;
they form one access boundary.

For the example account, the sudo rule explicitly permits no command arguments:

```text
lab-operator ALL=(root) NOPASSWD: /usr/local/sbin/baseline-service-status ""
```

The helper runs `/usr/bin/systemctl --no-pager --full status ssh.service` on
Ubuntu and the same command for `sshd.service` on Rocky. It rejects arguments.

## SSH settings

| Setting | Value | Purpose |
| --- | --- | --- |
| `PubkeyAuthentication` | `yes` | Allow public-key login |
| `AuthenticationMethods` | `publickey` | Require a key |
| `PasswordAuthentication` | `no` | Disable SSH password authentication |
| `KbdInteractiveAuthentication` | `no` | Disable keyboard-interactive authentication |
| `PermitEmptyPasswords` | `no` | Reject empty-password authentication |
| `PermitRootLogin` | `no` | Require a separate nonroot recovery administrator |
| `X11Forwarding` | `no` | Disable X11 forwarding |
| `AllowTcpForwarding` | `no` | Disable TCP forwarding for new connections |
| `MaxAuthTries` | `3` | Limit authentication attempts per connection |
| `LoginGraceTime` | `30` | Limit time to authenticate, in seconds |
| `ClientAliveInterval` | `300` | Send a liveness check after the configured interval |
| `ClientAliveCountMax` | `2` | Limit unanswered liveness checks |

Liveness checks do not establish an idle-session logout policy. Use
`IdentitiesOnly=yes` with the intended client key to avoid offering several
unrelated agent keys against the authentication-attempt limit.

## Apply phases

All target-changing phases require root and `--confirm-disposable-vm`:

```bash
sudo bash scripts/apply-baseline.sh bootstrap \
  --bundle "$HOME/baseline-bundle" --confirm-disposable-vm

read -r -p 'Existing tested nonroot recovery administrator: ' EXISTING_ADMIN
sudo bash scripts/apply-baseline.sh harden \
  --bundle "$HOME/baseline-bundle" --confirm-disposable-vm \
  --confirm-key-session lab-operator \
  --confirm-recovery-admin "$EXISTING_ADMIN"

sudo bash scripts/apply-baseline.sh firewall \
  --bundle "$HOME/baseline-bundle" --confirm-disposable-vm \
  --confirm-firewall
```

These are separate commands with required verification between them. Do not
paste them as one unattended script. Follow
[installation](installation.md) for the full order.

Hardening needs a different existing nonroot recovery administrator in `sudo`
on Ubuntu or `wheel` on Rocky. Independently verify its key login and full sudo
access. The confirmation flags are human assertions, not a remote login test.
The operator's status-only permission cannot replace a full administrator when
root SSH is disabled.

An existing account or a managed-file conflict is rejected instead of being
changed silently. This is a deliberate lab safeguard; repeated apply is not a
general account-management or migration feature.

## Managed paths and state

The hardening phase manages:

```text
/etc/ssh/sshd_config.d/00-secure-linux-baseline.conf
```

The status helper is installed at:

```text
/usr/local/sbin/baseline-service-status
```

The root-owned sudo rule is `/etc/sudoers.d/90-secure-linux-baseline`, mode
`0440`. The root-owned status helper is mode `0755`.

Each applied phase records recovery state below:

```text
/var/lib/secure-linux-baseline/
```

State directories are root-only. Record the exact state path printed for each
phase. Do not guess a path or delete state before the lab is reviewed.

## Existing security controls

The project does not disable or change AppArmor and SELinux policy. Verify the
expected enforcing state on the real VM. It does not claim that the Ubuntu SSH
daemon has a loaded AppArmor profile. Rocky key files receive the expected
SELinux context.

Automatic SSH hardening rejects `Match` blocks, unsupported configuration
symlinks, and custom include layouts outside the supported stock forms. The
stock drop-in include is supported. Rocky's official crypto-policy include is
also supported after ownership, path, permissions, and content checks; the
distribution-managed crypto-policy symlink is a limited exception. The project
does not disable that policy. Do not delete a legitimate policy merely to make
this lab run; use a clean VM or review a migration separately.

The firewall phase adds one rule to the active OS-specific firewall. Existing
rules remain in place, including rules that may allow broader access. Review
default policies, zones, interface assignments, and existing SSH allowances
before claiming that other sources are blocked.

For firewalld, the phase records its current default zone and uses that zone for
runtime, permanent, and rollback operations. Verify that it is the zone governing
the management interface. A later default-zone change does not redirect the
stored rollback rule to a different zone.

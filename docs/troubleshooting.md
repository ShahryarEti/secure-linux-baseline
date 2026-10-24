# Troubleshooting

Keep the original administrator session and VM console available. Stop after a
failed phase and inspect the error before applying another control. Do not
disable the firewall, AppArmor, or SELinux to hide a failure.

## Render refuses the input

The renderer needs a new output directory, a supported OS name, a valid new user
name, one plain Ed25519 public key, and an IPv4 source CIDR with a prefix from
`1` to `32`.

```bash
bash scripts/baseline.sh --help
ssh-keygen -lf "$HOME/secure-linux-baseline.pub"
```

Do not pass a private key or a key file containing several keys. A rendered
bundle is tied to its validated inputs; regenerate into a new directory instead
of editing privileged files in the bundle.

## Apply refuses the environment

Apply requires root, an explicit disposable-VM confirmation, the matching target
OS version, and systemd as PID 1. A normal Docker container is not a supported
apply environment.

```bash
cat /etc/os-release
cat /proc/1/comm
bash scripts/apply-baseline.sh --help
```

An existing operator or managed-file conflict is a reason to stop and review, not
to delete the existing account or file automatically. Use a fresh VM if the
current system contains work that this lab must not change.

## Operator key login fails

Use the VM console or the existing administrator session to check account state
and file permissions:

```bash
getent passwd lab-operator
id lab-operator
sudo ls -ld /home/lab-operator /home/lab-operator/.ssh
sudo ls -l /home/lab-operator/.ssh/authorized_keys
sudo /usr/sbin/sshd -t
```

The `.ssh` directory should be owned by the operator with mode `0700`.
`authorized_keys` should be owned by the operator with mode `0600`. Compare the
public-key fingerprint with the intended workstation key. Never copy the private
key to the server as a repair step.

Use verbose client output for diagnosis:

```bash
ssh -v -i "$HOME/.ssh/secure-linux-baseline" \
  -o IdentitiesOnly=yes "lab-operator@$VM_IP"
```

Use your actual target address for `VM_IP`. Review output before sharing it; it
can contain account names, host addresses, and local key paths.

Ubuntu service and logs:

```bash
sudo systemctl status ssh.service --no-pager
sudo journalctl -u ssh.service -n 50 --no-pager
sudo aa-status
```

Rocky service, logs, and labels:

```bash
sudo systemctl status sshd.service --no-pager
sudo journalctl -u sshd.service -n 50 --no-pager
getenforce
sudo ls -Zd /home/lab-operator/.ssh
sudo ls -Z /home/lab-operator/.ssh/authorized_keys
sudo restorecon -nRF /home/lab-operator/.ssh
```

`restorecon -n` previews context corrections. Investigate actual policy denials
before changing labels or policy. Do not use `setenforce 0` as a workaround.

## SSH policy differs from the rendered file

OpenSSH settings can be affected by include order and `Match` rules. A correct
drop-in alone does not establish the final policy. Automatic hardening rejects
`Match` blocks, configuration symlinks, and unsupported custom include layouts.
Do not delete an existing access policy simply to make the lab accept a server.

```bash
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T
```

For manual review of an actual connection context, enter the client address and
inspect the effective policy:

```bash
read -r -p 'Client IPv4 address seen by the VM: ' ADMIN_IP
sudo /usr/sbin/sshd -T \
  -C "user=lab-operator,addr=$ADMIN_IP,host=lab-client" \
  | grep -E '^(authenticationmethods|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) '
```

Use the actual client host value if existing `Match Host` rules depend on it.
Test root and other relevant users separately when reviewing their policy. Do
not claim that a failed password attempt alone proves a global policy: an
individual account can already have a locked password.

If the hardening phase restores the original file, inspect the reported cause
and the existing SSH configuration. Do not force a reload around a failed check.

Hardening also requires `--confirm-recovery-admin` for a different existing
nonroot administrator. Independently test its key login and full sudo access.
The status-only operator cannot replace a full administrator when root SSH is
disabled.

## Status-only sudo fails

The intended command has no arguments:

```bash
sudo -n /usr/local/sbin/baseline-service-status
```

The helper reports only the SSH service and uses `--no-pager`. A nonzero service
status can mean that SSH is inactive; it is not automatically a sudo permission
failure. From the existing administrator session, validate the policy:

```bash
sudo visudo -c
sudo stat /etc/sudoers.d/90-secure-linux-baseline
sudo stat /usr/local/sbin/baseline-service-status
```

Do not solve this by adding the operator to `sudo` or `wheel`, adding a wildcard
command, or granting a shell.

## Firewall phase refuses to run

The script intentionally requires an active firewall and does not choose its
initial policy. Prepare and review that policy from the console, keeping current
management access. Confirm the source address after NAT or VPN routing.

Ubuntu:

```bash
sudo ufw status verbose
sudo ufw status numbered
```

Rocky:

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
sudo firewall-cmd --permanent --list-all
```

A rule in the wrong firewalld zone may not govern the management interface. A
restricted allow rule does not remove a broad existing rule. Inspect both
runtime and permanent state before claiming denied-source protection.

## Recovery command fails

Use the exact root-owned state directory printed by the relevant phase. Roll
back phases in reverse order. Do not edit state or change its ownership to make a
check pass.

If the VM no longer has a valid SSH configuration or systemd service, use its
console and the pre-change VM snapshot. Save the error and state for review.
Rollback is not a backup of unrelated server settings.

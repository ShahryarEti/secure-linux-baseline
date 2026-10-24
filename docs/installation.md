# Installation, Verification, and Recovery

## Lab prerequisites

Use a new disposable Ubuntu Server 24.04 LTS or Rocky Linux 9 VM. Keep its console
open in the hypervisor. Take a VM snapshot before changing access settings and
keep an existing administrator SSH session open throughout the lab.

The example management network `192.0.2.0/24` is a reserved documentation range.
Do not apply that example to a real VM. Use the actual source address range seen
by the VM, which may differ after NAT or VPN routing.

The new account is a support operator with SSH-service-status access. It cannot
run the apply script, manage arbitrary services, or obtain a root shell. You also
need a different existing nonroot recovery administrator in Ubuntu's `sudo`
group or Rocky's `wheel` group. Test that account's key login and full sudo access
independently. If the only working administrator login is root, stop and prepare
a tested nonroot recovery administrator before the hardening phase.

## Get the project

Before publication, use the local reviewed project files. After the repository
exists on GitHub, these commands can be used:

```bash
git clone https://github.com/ShahryarEti/secure-linux-baseline.git
cd secure-linux-baseline
```

Review both scripts and the rendered files before using root access. The renderer
can run on a workstation. The apply script must run on the target VM.

For development checks on Ubuntu, install the additional tools:

```bash
sudo apt-get install --no-install-recommends make shellcheck python3
make check
```

The tests use Python's standard library; they install no Python packages and need
no `pip` command or virtual environment. Development tools are separate from
the target's runtime packages below.

## Install OS-specific packages

On Ubuntu Server 24.04 LTS:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  bash openssh-client openssh-server sudo ufw apparmor apparmor-utils
sudo systemctl status ssh.service --no-pager
sudo aa-status
```

On Rocky Linux 9:

```bash
sudo dnf install bash openssh-clients openssh-server sudo firewalld policycoreutils
sudo systemctl status sshd.service --no-pager
getenforce
```

Do not disable AppArmor or SELinux. `aa-status` shows the actual Ubuntu policy;
it does not mean that SSH has a loaded profile. On Rocky, investigate policy
issues if SELinux is not enforcing or expected file contexts differ.

The scripts do not enable a firewall or choose its default policy. For the
firewall phase, prepare an active firewall from the VM console with a rule that
keeps current management access. Record that manual preparation separately;
script rollback cannot undo unrelated rules or policy changes.

## Prepare the key on the workstation

Generate a dedicated Ed25519 key with a passphrase:

```bash
ssh-keygen -t ed25519 -a 64 -f "$HOME/.ssh/secure-linux-baseline"
ssh-keygen -lf "$HOME/.ssh/secure-linux-baseline.pub"
```

Keep the private file on the workstation. Transfer only the `.pub` file to the
target's existing administrator account. For example, with the actual connection
values entered at the prompts:

```bash
read -r -p 'Target VM address: ' VM_IP
read -r -p 'Existing VM administrator: ' EXISTING_ADMIN
scp "$HOME/.ssh/secure-linux-baseline.pub" \
  "$EXISTING_ADMIN@$VM_IP:secure-linux-baseline.pub"
```

The renderer accepts one plain Ed25519 public key. It rejects private-key files,
key options, other key types, and multiple keys. This is not a FIPS-mode key
configuration.

## Render and inspect on the target

From the reviewed project directory, enter the actual management source range.
Prefer one workstation address with a `/32` prefix when that fits the lab.

```bash
read -r -p 'Management source IPv4 CIDR seen by the VM: ' ADMIN_CIDR
bash scripts/baseline.sh render \
  --os ubuntu \
  --admin-user lab-operator \
  --public-key "$HOME/secure-linux-baseline.pub" \
  --admin-cidr "$ADMIN_CIDR" \
  --output "$HOME/baseline-bundle"
```

For Rocky, use `--os rocky`. The output directory must not already exist. Inspect
every file in the new bundle. The key file is public, but keep real bundle
metadata out of Git. The firewall text is for review; use the staged apply
command rather than running the text as a script.

The apply script parses metadata as data and regenerates the expected privileged
files. A changed bundle, symlink entry, or managed-path conflict is rejected.

## Phase 1: bootstrap

Run from the existing administrator account on the target VM:

```bash
sudo bash scripts/apply-baseline.sh bootstrap \
  --bundle "$HOME/baseline-bundle" \
  --confirm-disposable-vm
```

Record the exact `Recovery state:` path printed by this phase. It is stored
under `/var/lib/secure-linux-baseline` with root-only access.

Bootstrap creates the new operator, its key files, the root-owned status helper,
and the narrow sudo rule. It leaves SSH and firewall settings unchanged.

## Test the operator from a second workstation terminal

Keep the original administrator session and VM console open. In another local
terminal, enter the target address and connect with the new key:

```bash
read -r -p 'Target VM address: ' VM_IP
ssh -i "$HOME/.ssh/secure-linux-baseline" \
  -o IdentitiesOnly=yes "lab-operator@$VM_IP"
```

Inside the new operator session:

```bash
id
groups
sudo -n /usr/local/sbin/baseline-service-status
```

The helper should show the target SSH service without a pager. It accepts no
arguments. Check that a general root command is denied:

```bash
if sudo -n id; then
  printf 'Unexpected general sudo access; stop and investigate.\n'
else
  printf 'General sudo command was denied.\n'
fi
```

Also inspect group and sudo configuration from the existing administrator
session. A denied command alone does not replace a policy review.

## Phase 2: harden SSH

First test a separate key session for the existing nonroot recovery
administrator. In that account's session, confirm the expected identity and root
command access:

```bash
id
sudo id -u
```

The second command should report `0`. Review the account's complete sudo policy;
permission to run one command alone does not establish the scope of all required
administration work. Keep this session and the console open.

Only after both the new operator's key session and the recovery administrator's
key-and-sudo session succeed, return to the existing administrator session on
the target:

```bash
read -r -p 'Existing tested nonroot recovery administrator: ' EXISTING_ADMIN
sudo bash scripts/apply-baseline.sh harden \
  --bundle "$HOME/baseline-bundle" \
  --confirm-disposable-vm \
  --confirm-key-session lab-operator \
  --confirm-recovery-admin "$EXISTING_ADMIN"
```

Both flags confirm human tests. They do not perform or prove remote logins or
full sudo access.
Record this phase's recovery state separately. The script checks SSH syntax and
effective policy before reloading the service. It refuses a changed SSH port;
this lab supports a single existing port 22.

Open another new key session from the workstation. Inspect the target logs and
effective settings. Do not close the recovery session merely because a reload
command returned success.

## Phase 3: add the firewall rule

From the target's existing administrator session, inspect the active firewall.

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

For Rocky, verify that the management interface uses the default zone addressed
by the script. Stop if it does not. Existing allowances, zone rules, interface
assignments, and default policies need review before any claim of source
restriction.

When the firewall is active and the reviewed source range is correct:

```bash
sudo bash scripts/apply-baseline.sh firewall \
  --bundle "$HOME/baseline-bundle" \
  --confirm-disposable-vm \
  --confirm-firewall
```

Record this phase's recovery path. The command adds or retains a source-limited
TCP 22 allowance. It does not delete broad SSH rules. A clean source-specific
allowance can coexist with another rule that permits everyone.

Test a fresh connection from the allowed source. To claim that other sources are
blocked, use a second lab client outside the allowed range and inspect all
existing rules. If you change broader rules manually, record their original
state and recovery commands separately. Those changes are not owned by this
script's rollback.

## Rollback

Use the console or the retained existing administrator session. Roll back phases
in reverse order: firewall, harden, then bootstrap. For each phase, enter the
exact state path recorded when that phase ran:

```bash
read -r -p 'Recorded recovery state directory for this phase: ' STATE_DIR
sudo bash scripts/apply-baseline.sh rollback \
  --state "$STATE_DIR" \
  --confirm-disposable-vm
```

Rollback requires root on the same supported systemd VM. It reverses only the
phase's recorded changes. A rule that already existed is retained. SSH settings
are restored or the new drop-in is removed, followed by a syntax check and
reload.

Bootstrap rollback locks the operator's password, expires the account, and
changes its shell to `/usr/sbin/nologin`. It removes the managed sudo rule and
helper and keeps the account, home, and key files for review. A password lock or
shell change alone is not a complete key-access revocation; expiry is also part
of the recovery action.

Keep the state and snapshot until access and recovery checks are complete. A
snapshot restore remains the recovery option for a larger VM failure.

## Remove the lab

First verify rollback and save any test evidence you need. The account is not
deleted automatically. Review any retained home files and root recovery state
before removing them. For a disposable lab, remove the VM through its hypervisor
only after checking that no needed data remains.

Deleting the project checkout does not undo target settings. Do not remove shared
system packages or disable security controls as cleanup.

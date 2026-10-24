#!/usr/bin/env bash
# Deliberately separate VM-only operations from safe configuration rendering.
set -euo pipefail
export LC_ALL=C
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'apply-baseline: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: apply-baseline.sh bootstrap|harden|firewall --bundle DIR --confirm-disposable-vm [--confirm-key-session USER] [--confirm-recovery-admin USER] [--confirm-firewall]
       apply-baseline.sh rollback --state DIR --confirm-disposable-vm

Bootstrap creates a NEW key-only operator with status-only sudo; it leaves SSH
and firewall settings unchanged. Harden requires human confirmation that a
separate key login worked AND an existing non-root sudo/wheel recovery admin
has a verified separate key login and working sudo. These are human assertions.
Firewall adds one restricted SSH rule to an already
active firewall; it never enables a firewall or removes existing allowances.
EOF
}
[[ ${1:-} == --help ]] && { usage; exit 0; }
action=${1:-}
case $action in bootstrap|harden|firewall|rollback) ;; *) usage >&2; exit 1 ;; esac
shift
bundle='' state='' confirmed=no confirmed_user='' confirmed_recovery='' confirmed_firewall=no
while (($#)); do
    case $1 in
        --confirm-disposable-vm) confirmed=yes; shift ;;
        --confirm-firewall) confirmed_firewall=yes; shift ;;
        --bundle|--state|--confirm-key-session|--confirm-recovery-admin)
            (($# >= 2)) || die "missing value for $1"
            case $1 in
                --bundle) bundle=$2 ;;
                --state) state=$2 ;;
                --confirm-key-session) confirmed_user=$2 ;;
                --confirm-recovery-admin) confirmed_recovery=$2 ;;
            esac
            shift 2 ;;
        *) die 'unknown option' ;;
    esac
done
[[ $confirmed == yes ]] || die 'refused: --confirm-disposable-vm is required'
[[ $action != harden || -n $confirmed_user ]] || die 'refused: --confirm-key-session USER is required'
[[ $action != harden || -n $confirmed_recovery ]] || die 'refused: --confirm-recovery-admin USER is required'
[[ $action != firewall || $confirmed_firewall == yes ]] || die 'refused: --confirm-firewall is required'
((EUID == 0)) || die 'root is required only for explicit VM apply operations'
[[ -r /etc/os-release ]] || die 'cannot identify target OS'
# The trusted operating system file is read as data; bundle metadata is never sourced.
host_id=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)
host_version=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)
case "$host_id:$host_version" in ubuntu:24.04|rocky:9|rocky:9.*) ;; *) die 'only Ubuntu 24.04 or Rocky Linux 9 are supported' ;; esac
[[ $(cat /proc/1/comm) == systemd ]] || die 'a disposable VM booted with systemd is required'

read_metadata() {
    local metadata=$1 field value count=0
    target_os='' admin_user='' admin_cidr=''
    while IFS='=' read -r field value; do
        case $field in
            OS) [[ -z $target_os ]] || die 'duplicate OS field'; target_os=$value ;;
            ADMIN_USER) [[ -z $admin_user ]] || die 'duplicate ADMIN_USER field'; admin_user=$value ;;
            ADMIN_CIDR) [[ -z $admin_cidr ]] || die 'duplicate ADMIN_CIDR field'; admin_cidr=$value ;;
            *) die 'unknown metadata field' ;;
        esac
        count=$((count+1))
    done < "$metadata"
    ((count == 3)) || die 'incomplete metadata'
    [[ $target_os == "$host_id" ]] || die 'bundle OS does not match this VM'
    [[ $admin_user =~ ^[a-z][a-z0-9-]{0,30}$ && $admin_user != root ]] || die 'invalid metadata user'
    [[ $admin_cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die 'invalid metadata CIDR'
}

dropin=/etc/ssh/sshd_config.d/00-secure-linux-baseline.conf
sudo_rule=/etc/sudoers.d/90-secure-linux-baseline
helper=/usr/local/sbin/baseline-service-status
service=ssh
[[ $host_id == rocky ]] && service=sshd
restore_state() {
    local saved=$1
    [[ $saved =~ ^/var/lib/secure-linux-baseline/run\.[A-Za-z0-9]{8}$ && -d $saved && ! -L $saved ]] || die 'invalid state directory'
    [[ $(stat -c %u "$saved") == 0 && $(stat -c %a "$saved") == 700 ]] || die 'state must be root-owned mode 0700'
    for entry in "$saved"/*; do [[ ! -L $entry ]] || die 'state entries must not be symlinks'; done
    [[ ! -L $dropin && ! -L $sudo_rule && ! -L $helper ]] || die 'managed destinations must not be symlinks'
    [[ -f $saved/metadata.env && ! -L $saved/metadata.env ]] || die 'invalid state metadata'
    read_metadata "$saved/metadata.env"
    rich_rule="rule family=\"ipv4\" source address=\"$admin_cidr\" port port=\"22\" protocol=\"tcp\" accept"
    if [[ -f $saved/dropin.before ]]; then
        cp -a -- "$saved/dropin.before" "$dropin"
    elif [[ -f $saved/dropin.absent ]]; then rm -f -- "$dropin"; fi
    [[ ! -f $saved/firewall.added ]] || ufw --force delete allow from "$admin_cidr" to any port 22 proto tcp
    if [[ -f $saved/firewall.added.runtime || -f $saved/firewall.added.permanent ]]; then
        firewall_zone=$(cat "$saved/firewall.zone")
        [[ $firewall_zone =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,63}$ ]] || die 'invalid recorded firewalld zone'
        [[ ! -f $saved/firewall.added.runtime ]] || firewall-cmd --zone="$firewall_zone" --remove-rich-rule="$rich_rule"
        [[ ! -f $saved/firewall.added.permanent ]] || firewall-cmd --permanent --zone="$firewall_zone" --remove-rich-rule="$rich_rule"
    fi
    if [[ -f $saved/operator.created ]]; then
        # Expiration denies new PAM sessions, including key-only forwarding.
        # Password lock or nologin alone does not revoke all SSH key access.
        usermod --expiredate 1 --lock --shell /usr/sbin/nologin "$admin_user"
        rm -f -- "$sudo_rule" "$helper"
    fi
    /usr/sbin/sshd -t
    systemctl reload "$service.service"
    printf 'Rollback complete for %s. Created account/home retained for review.\n' "$saved"
}

if [[ $action == rollback ]]; then
    [[ -n $state ]] || die '--state is required for rollback'
    restore_state "$state"
    exit 0
fi

[[ -d $bundle && ! -L $bundle ]] || die 'bundle must be a real directory'
for file in metadata.env authorized_keys sshd-hardening.conf sudoers-baseline baseline-service-status firewall-rule.txt; do
    [[ -f $bundle/$file && ! -L $bundle/$file ]] || die 'bundle entries must be regular files, not symlinks'
done
read_metadata "$bundle/metadata.env"
[[ $action != harden || $confirmed_user == "$admin_user" ]] || die 'session confirmation must match bundle operator'
umask 077
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
# Regenerate all privileged content from validated data, never run bundle code.
bash "$script_dir/baseline.sh" render --os "$target_os" --admin-user "$admin_user" \
    --public-key "$bundle/authorized_keys" --admin-cidr "$admin_cidr" --output "$temporary/canonical" >/dev/null
for file in metadata.env authorized_keys sshd-hardening.conf sudoers-baseline baseline-service-status firewall-rule.txt; do
    cmp -s "$bundle/$file" "$temporary/canonical/$file" || die 'bundle differs from canonical renderer output'
done
canonical=$temporary/canonical
command -v visudo >/dev/null || die 'install sudo using the documented OS-specific package command first'
visudo -cf "$canonical/sudoers-baseline" >/dev/null
visudo -c >/dev/null
/usr/sbin/sshd -t
[[ ! -L $dropin && ! -L $sudo_rule && ! -L $helper ]] || die 'managed destinations must not be symlinks'
rich_rule="rule family=\"ipv4\" source address=\"$admin_cidr\" port port=\"22\" protocol=\"tcp\" accept"

case $action in
    bootstrap)
        ! getent passwd "$admin_user" >/dev/null || die 'operator already exists; existing users are never changed'
        [[ ! -e /home/$admin_user && ! -e $sudo_rule && ! -e $helper && ! -e $dropin ]] || die 'managed paths already exist; refusing overwrite'
        ;;
    harden)
        getent passwd "$admin_user" >/dev/null || die 'run bootstrap before hardening'
        [[ -s /home/$admin_user/.ssh/authorized_keys ]] || die 'operator has no installed SSH key'
        [[ $confirmed_recovery =~ ^[a-z][a-z0-9-]{0,30}$ && $confirmed_recovery != "$admin_user" && $confirmed_recovery != root ]] || die 'recovery admin must be a different existing non-root administrator'
        getent passwd "$confirmed_recovery" >/dev/null || die 'recovery administrator does not exist'
        id -nG "$confirmed_recovery" | tr ' ' '\n' | grep -Eq '^(sudo|wheel)$' || die 'recovery administrator must belong to sudo or wheel'
        sudo -l -U "$confirmed_recovery" >/dev/null || die 'recovery administrator has no sudo policy'
        # Global sshd -T cannot prove arbitrary Match policies are key-only.
        bash "$script_dir/check-ssh-layout.sh" /etc/ssh/sshd_config /etc/ssh/sshd_config.d "$host_id"
        ;;
    firewall)
        if [[ $host_id == ubuntu ]]; then
            ufw status | grep -qx 'Status: active' || die 'UFW must already be active; configure policy manually first'
        else
            firewall-cmd --state >/dev/null || die 'firewalld must already be active'
            firewall_zone=$(firewall-cmd --get-default-zone)
            [[ $firewall_zone =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,63}$ ]] || die 'invalid default firewalld zone'
        fi
        ;;
esac
install -d -o root -g root -m 0700 /var/lib/secure-linux-baseline
state=$(mktemp -d /var/lib/secure-linux-baseline/run.XXXXXXXX)
install -m 0600 "$canonical/metadata.env" "$state/metadata.env"
printf '%s\n' "$action" > "$state/action"
printf 'Recovery state: %s\n' "$state"
case $action in
    bootstrap)
        useradd --create-home --home-dir "/home/$admin_user" --shell /bin/bash "$admin_user"
        touch "$state/operator.created"
        group=$(id -gn "$admin_user")
        install -d -o "$admin_user" -g "$group" -m 0700 "/home/$admin_user/.ssh"
        install -o "$admin_user" -g "$group" -m 0600 "$canonical/authorized_keys" "/home/$admin_user/.ssh/authorized_keys"
        install -o root -g root -m 0755 "$canonical/baseline-service-status" "$helper"
        install -o root -g root -m 0440 "$canonical/sudoers-baseline" "$sudo_rule"
        [[ $host_id != rocky ]] || restorecon -RF "/home/$admin_user/.ssh" "$helper" "$sudo_rule"
        visudo -c >/dev/null
        printf 'Bootstrap complete. Keep the original admin session open and test a separate key login.\n'
        ;;
    harden)
        install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
        if [[ -e $dropin ]]; then cp -a -- "$dropin" "$state/dropin.before"; else touch "$state/dropin.absent"; fi
        install -o root -g root -m 0600 "$canonical/sshd-hardening.conf" "$dropin"
        [[ $host_id != rocky ]] || restorecon "$dropin"
        if ! /usr/sbin/sshd -t; then restore_state "$state"; die 'SSH syntax failed; original config restored'; fi
        if ! effective=$(/usr/sbin/sshd -T); then restore_state "$state"; die 'SSH policy lookup failed; original config restored'; fi
        for setting in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin no' 'pubkeyauthentication yes' 'authenticationmethods publickey'; do
            if ! grep -qx "$setting" <<< "$effective"; then
                restore_state "$state"; die 'effective SSH policy differs; original config restored (check Include order)'
            fi
        done
        if ! grep -qx 'port 22' <<< "$effective" || [[ $(grep -c '^port ' <<< "$effective") != 1 ]]; then
            restore_state "$state"; die 'only existing SSH port 22 is supported; original config restored'
        fi
        if ! systemctl reload "$service.service"; then restore_state "$state"; die 'reload failed; original config restored'; fi
        if ! systemctl is-active --quiet "$service.service"; then restore_state "$state"; die 'service is not active; original config restored'; fi
        printf 'Hardening complete. Test another key login before closing the recovery session.\n'
        ;;
    firewall)
        if [[ $host_id == ubuntu ]]; then
            result=$(ufw allow from "$admin_cidr" to any port 22 proto tcp)
            printf '%s\n' "$result"
            if grep -q '^Rule added' <<< "$result"; then touch "$state/firewall.added"; fi
        else
            printf '%s\n' "$firewall_zone" > "$state/firewall.zone"
            if firewall-cmd --zone="$firewall_zone" --query-rich-rule="$rich_rule" >/dev/null; then :; else
                result=$?
                ((result == 1)) || die 'cannot query runtime firewall rule'
                firewall-cmd --zone="$firewall_zone" --add-rich-rule="$rich_rule"
                touch "$state/firewall.added.runtime"
            fi
            if firewall-cmd --permanent --zone="$firewall_zone" --query-rich-rule="$rich_rule" >/dev/null; then :; else
                result=$?
                ((result == 1)) || die 'cannot query permanent firewall rule'
                firewall-cmd --permanent --zone="$firewall_zone" --add-rich-rule="$rich_rule"
                touch "$state/firewall.added.permanent"
            fi
        fi
        printf 'Restricted SSH allowance added or retained; existing firewall rules were preserved.\n'
        ;;
esac

#!/usr/bin/env bash
# Render a reviewed bundle without changing accounts, services or firewalls.
set -euo pipefail

die() { printf 'baseline: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: baseline.sh render --os ubuntu|rocky --admin-user NAME --public-key FILE --output NEW_DIR --admin-cidr IPv4/PREFIX'
}

[[ ${1:-} == --help ]] && { usage; exit 0; }
[[ ${1:-} == render ]] || { usage >&2; exit 1; }
shift
target_os='' admin_user='' public_key='' output='' admin_cidr=''
while (($#)); do
    (($# >= 2)) || die "missing value for $1"
    case $1 in
        --os) target_os=$2 ;;
        --admin-user) admin_user=$2 ;;
        --public-key) public_key=$2 ;;
        --output) output=$2 ;;
        --admin-cidr) admin_cidr=$2 ;;
        *) die 'unknown option' ;;
    esac
    shift 2
done
[[ $target_os == ubuntu || $target_os == rocky ]] || die '--os must be ubuntu or rocky'
[[ $admin_user =~ ^[a-z][a-z0-9-]{0,30}$ && $admin_user != root ]] || die 'invalid admin user'
[[ -f $public_key && ! -L $public_key ]] || die 'public key must be a regular file, not a symlink'
[[ -n $output && ! -e $output && ! -L $output ]] || die 'output must be a new directory'
[[ $admin_cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die 'admin CIDR must be IPv4/PREFIX'
IFS=./ read -r a b c d prefix <<< "$admin_cidr"
for octet in "$a" "$b" "$c" "$d"; do
    ((10#$octet <= 255)) || die 'invalid IPv4 address'
done
((10#$prefix >= 1 && 10#$prefix <= 32)) || die 'CIDR prefix must be 1-32; unrestricted /0 is refused'
admin_cidr="$((10#$a)).$((10#$b)).$((10#$c)).$((10#$d))/$((10#$prefix))"
[[ $(awk 'NF { n++ } END { print n+0 }' "$public_key") == 1 ]] || die 'provide exactly one public key'
read -r algorithm payload _ < "$public_key" || die 'public key must end in a newline'
[[ $algorithm == ssh-ed25519 && $payload =~ ^[A-Za-z0-9+/]+=*$ ]] || die 'only plain Ed25519 public keys are accepted'
ssh-keygen -lf "$public_key" >/dev/null 2>&1 || die 'invalid Ed25519 public key'
umask 077
mkdir -- "$output"
printf 'OS=%s\nADMIN_USER=%s\nADMIN_CIDR=%s\n' "$target_os" "$admin_user" "$admin_cidr" > "$output/metadata.env"
printf 'ssh-ed25519 %s\n' "$payload" > "$output/authorized_keys"
cat > "$output/sshd-hardening.conf" <<'EOF'
# Apply only after a separate, successful key-authenticated operator session.
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/baseline-service-status ""\n' "$admin_user" > "$output/sudoers-baseline"
service=ssh
[[ $target_os == rocky ]] && service=sshd
cat > "$output/baseline-service-status" <<EOF
#!/usr/bin/env bash
set -euo pipefail
((\$# == 0)) || { printf 'This helper accepts no arguments.\n' >&2; exit 1; }
exec /usr/bin/systemctl --no-pager --full status $service.service
EOF
if [[ $target_os == ubuntu ]]; then
    printf 'ufw allow from %s to any port 22 proto tcp\n' "$admin_cidr" > "$output/firewall-rule.txt"
else
    printf 'firewall-cmd --add-rich-rule=\047rule family="ipv4" source address="%s" port port="22" protocol="tcp" accept\047\n' "$admin_cidr" > "$output/firewall-rule.txt"
fi
chmod 0700 "$output/baseline-service-status"
printf 'Rendered %s bundle in %s. No host settings changed.\n' "$target_os" "$output"

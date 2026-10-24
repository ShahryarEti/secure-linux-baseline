#!/usr/bin/env bash
# Fail closed on SSH layouts that the staged hardening workflow cannot audit.
set -euo pipefail
die() { printf 'SSH layout: %s\n' "$*" >&2; exit 1; }
(($# == 3)) || die 'expected MAIN_CONFIG DROPIN_DIRECTORY ubuntu|rocky'
main=$1 directory=$2 target=$3
[[ $target == ubuntu || $target == rocky ]] || die 'unsupported target'
[[ -d $directory && ! -L $directory ]] || die 'drop-in directory must not be a symlink'
crypto=/etc/crypto-policies/back-ends/opensshserver.config

inspect() {
    local file=$1 allow_crypto=$2 result
    [[ -f $file ]] || die 'missing SSH configuration file'
    result=$(awk -v allow_crypto="$allow_crypto" '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "" || line ~ /^#/) next
            # OpenSSH accepts both Keyword value and Keyword=value.
            sub(/[[:space:]]*=[[:space:]]*/, " ", line)
            count=split(line, part, /[[:space:]]+/)
            keyword=tolower(part[1])
            if (keyword == "match") exit 1
            if (keyword == "include") {
                if (count == 2 && part[2] == "/etc/ssh/sshd_config.d/*.conf" && allow_crypto != "vendor") next
                if (count == 2 && part[2] == "/etc/crypto-policies/back-ends/opensshserver.config" && allow_crypto == "rocky") {
                    print "crypto"
                    next
                }
                exit 1
            }
        }
    ' "$file") || die 'Match blocks or unsupported Include directives require a separate manual policy review'
    if [[ $result == *crypto* ]]; then
        # Rocky supplies this vendor path as a symlink. Keep its policy active,
        # inspect the resolved file, and require root ownership/no write access.
        local resolved permissions
        resolved=$(readlink -f -- "$crypto") || die 'cannot resolve Rocky crypto policy'
        [[ $resolved == /usr/share/crypto-policies/* || $resolved == /etc/crypto-policies/* ]] || die 'unexpected crypto-policy target'
        [[ -f $resolved && $(stat -c %u "$crypto") == 0 && $(stat -c %u "$resolved") == 0 ]] || die 'crypto policy must be root-owned'
        permissions=$(stat -c %a "$resolved")
        (( (8#$permissions & 0022) == 0 )) || die 'crypto policy must not be group/world writable'
        inspect "$resolved" vendor
    fi
}

shopt -s nullglob
for file in "$main" "$directory"/*.conf; do
    [[ ! -L $file ]] || die 'SSH config symlinks are outside the supported layout'
    inspect "$file" "$target"
done

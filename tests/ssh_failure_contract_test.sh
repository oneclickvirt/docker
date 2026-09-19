#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assert_contains() {
    local file="$1" needle="$2"
    grep -Fq -- "$needle" "$file" || {
        echo "missing ${needle@Q} in ${file}" >&2
        exit 1
    }
}

assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'sshd -t'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'Failed to start sshd'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'apt-get update -y 2>/dev/null || return 1'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'apt-get -y install "${missing_modules[@]}" 2>/dev/null || return 1'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || return 1'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'oneclickvirt-sshd-cron.lock'
assert_contains "$ROOT_DIR/scripts/ssh_sh.sh" 'sshd -t'
assert_contains "$ROOT_DIR/scripts/ssh_sh.sh" 'Failed to set the root password'
assert_contains "$ROOT_DIR/scripts/ssh_sh.sh" 'oneclickvirt-sshd-cron.lock'
assert_contains "$ROOT_DIR/scripts/ssh_sh.sh" 'OpenRC is unavailable'
if grep -Fq ') | crontab - 2>/dev/null || true' "$ROOT_DIR/scripts/ssh_bash.sh" "$ROOT_DIR/scripts/ssh_sh.sh"; then
    echo 'SSH initialization still uses an unlocked crontab replacement pipeline' >&2
    exit 1
fi
assert_contains "$ROOT_DIR/dockerfiles/entrypoint.sh" 'Failed to generate SSH host keys'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint.sh" 'Failed to start sshd'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint.sh" 'Failed to install the IPv6 keepalive cron job'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint.sh" 'oneclickvirt-ipv6-keepalive'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh" 'Failed to set the root password'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh" 'Failed to validate sshd configuration'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh" 'Failed to start sshd'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh" 'Failed to install the IPv6 keepalive cron job'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh" '${ROOT_PASSWORD:-}'
assert_contains "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh" '${IPV6_ENABLED:-}'
if grep -Fq 'crontab - 2>/dev/null || true' "$ROOT_DIR/dockerfiles/entrypoint_alpine.sh"; then
    echo 'Alpine entrypoint still hides crontab installation failures' >&2
    exit 1
fi

android_script="$ROOT_DIR/scripts/create_android.sh"
assert_contains "$android_script" 'curl -fsSL --connect-timeout 15 --max-time 120'
if grep -Fq 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm' "$android_script"; then
    echo 'create_android still pipes an unchecked download into bash' >&2
    exit 1
fi

echo 'Docker SSH and installer failure contracts passed'

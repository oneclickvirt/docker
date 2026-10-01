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
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'report_sshd_start_failure'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'SSH startup diagnostics:'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'apt-get update -y 2>/dev/null || return 1'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'apt-get -y install "${missing_modules[@]}" 2>/dev/null || return 1'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" '"ca-certificates"'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || return 1'
assert_contains "$ROOT_DIR/scripts/ssh_bash.sh" 'command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]'
assert_contains "$ROOT_DIR/scripts/onedocker.sh" 'Prefer the script shipped with the current checkout'
assert_contains "$ROOT_DIR/scripts/onedocker.sh" 'for candidate in "$(dirname "$0")/${script_name}" "/root/${script_name}"; do'
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
for dockerfile in "$ROOT_DIR"/dockerfiles/Dockerfile_*; do
    assert_contains "$dockerfile" 'ca-certificates'
done

# Debian container images can include systemctl without running systemd.  In
# that case SSH setup must use the service/direct fallback rather than fail at
# an unusable systemctl client.
extract_shell_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing { print }
        printing && $0 == "}" { exit }
    ' "$ROOT_DIR/scripts/ssh_bash.sh"
}
start_sshd_source=$(extract_shell_function start_sshd)
start_sshd_source=${start_sshd_source//\/run\/systemd\/system/\/run\/oneclickvirt-test-no-systemd}
eval "$start_sshd_source"
cd() { :; }
ssh-keygen() { :; }
mkdir() { :; }
systemctl() { echo 'systemctl must not run without a live systemd' >&2; return 1; }
service_called=false
service() { service_called=true; return 0; }
sshd_calls=0
sshd_is_running() {
    if [[ "$sshd_calls" == 0 ]]; then
        sshd_calls=1
        return 1
    fi
    return 0
}
start_sshd || {
    echo 'SSH setup rejected a container with systemctl installed but systemd absent' >&2
    exit 1
}
[[ "$service_called" == true ]] || {
    echo 'SSH setup did not select the non-systemd service fallback' >&2
    exit 1
}

# An image whose entrypoint already owns sshd must not restart PID 1 through
# the service wrapper, because that would terminate the container.  The
# contract is checked statically here: macOS CI hosts do not provide the
# Linux /usr/sbin/sshd binary that the runtime branch validates.
pid1_source=$(extract_shell_function start_sshd)
grep -Fq 'if sshd_is_running; then' <<<"$pid1_source" || {
    echo 'SSH setup does not detect an already-running sshd before restart' >&2
    exit 1
}
grep -Fq '/usr/sbin/sshd -t 2>/dev/null || return 1' <<<"$pid1_source" || {
    echo 'SSH setup does not validate an already-running sshd configuration' >&2
    exit 1
}
grep -Fq 'return 0' <<<"$pid1_source" || {
    echo 'SSH setup does not retain an already-running sshd' >&2
    exit 1
}

local_source_line=$(grep -nF 'for candidate in "$(dirname "$0")/${script_name}" "/root/${script_name}"; do' "$ROOT_DIR/scripts/onedocker.sh" | head -n1 | cut -d: -f1)
embedded_fallback_line=$(grep -nF 'Using SSH script embedded in the container image' "$ROOT_DIR/scripts/onedocker.sh" | head -n1 | cut -d: -f1)
[[ -n "$local_source_line" && -n "$embedded_fallback_line" && "$local_source_line" -lt "$embedded_fallback_line" ]] || {
    echo 'Container image SSH script is checked before the current checkout copy' >&2
    exit 1
}

android_script="$ROOT_DIR/scripts/create_android.sh"
assert_contains "$android_script" 'curl -fsSL --connect-timeout 15 --max-time 120'
if grep -Fq 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm' "$android_script"; then
    echo 'create_android still pipes an unchecked download into bash' >&2
    exit 1
fi

echo 'Docker SSH and installer failure contracts passed'

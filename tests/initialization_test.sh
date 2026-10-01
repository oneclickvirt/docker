#!/usr/bin/env bash
# Fault injection only: selected functions run against mock commands.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/dockerinstall.sh"
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer")
}
_green() { :; }
_yellow() { :; }
_red() { :; }
_blue() { :; }
_info() { :; }
_warn() { :; }
_step() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

load_function main
install_docker_and_compose() { return "$install_status"; }
ensure_docker_ready() { return "$daemon_status"; }
check_and_adapt_ipv6() { return 1; }
setup_dns_check() { :; }
cleanup_and_finish() { completed=true; }
install_status=0 daemon_status=1 completed=false
if main; then fail 'unavailable daemon must fail installation'; fi
$completed && fail 'must not report completion after daemon failure'
daemon_status=0
main || fail 'optional IPv6 failure must allow working IPv4'
$completed || fail 'working IPv4 should complete'
install_status=1 completed=false
if main; then fail 'package installation failure must propagate'; fi
$completed && fail 'package failure must not report completion'
docker_source=$(<"$installer")
grep -Fq 'if ! fallocate -l "${pool_size_gb}G" "$loop_file"' <<<"$docker_source" ||
    fail 'Docker btrfs setup must propagate loop-file allocation failures'
grep -Fq 'if ! loop_device=$(losetup --find --show "$loop_file")' <<<"$docker_source" ||
    fail 'Docker btrfs setup must propagate loop attachment failures'
grep -Fq 'if ! mkfs.btrfs -f "$loop_device"' <<<"$docker_source" ||
    fail 'Docker btrfs setup must propagate filesystem formatting failures'
grep -Fq 'if ! mount "$loop_device" "$mount_point"' <<<"$docker_source" ||
    fail 'Docker btrfs setup must propagate mount failures'
grep -Fq 'Existing Docker loop file backed up to' <<<"$docker_source" ||
    fail 'Docker btrfs setup must preserve unattached existing loop images'
grep -Fq 'install_docker_ipv6_nat66_service || return 1' <<<"$docker_source" ||
    fail 'Docker IPv6 NAT service installation failures must propagate'
grep -Fq 'install_docker_manual_ipv6_restore_service || return 1' <<<"$docker_source" ||
    fail 'Docker routed IPv6 service installation failures must propagate'
grep -Fq 'NAT66 persistence is unavailable' <<<"$docker_source" ||
    fail 'Docker NAT service failures need an actionable diagnostic'
grep -Fq 'nft list table ip6 "$nft_table" >/dev/null 2>&1 || nft add table ip6 "$nft_table" 2>/dev/null || return 1' <<<"$docker_source" ||
    fail 'Docker NAT66 nft table creation must propagate failures'
grep -Fq 'chmod 700 "$helper" || return 1' <<<"$docker_source" ||
    fail 'Docker IPv6 restore helper installation must propagate chmod failures'
printf 'Docker installation fault-injection tests passed (3 scenarios)\n'

# The first apt call runs inside command substitution. A log lets the mock
# distinguish the retry while executing the actual recovery function.
load_function check_update
apt_test_dir=$(mktemp -d)
trap 'rm -f -- "$apt_test_dir/calls" "$apt_test_dir/apt-output"; rmdir -- "$apt_test_dir"' EXIT
temp_file_apt_fix="$apt_test_dir/apt-output"
apt-get() {
    [[ "$*" == update ]] || fail "Unexpected apt-get: $*"
    printf '%s\n' update >>"$apt_test_dir/calls"
    if [[ "$scenario" != success ]] && { [[ ! -s "$temp_file_apt_fix" ]] || [[ "$scenario" == retry_failed ]]; }; then
        printf '%s\n' 'NO_PUBKEY 0123456789ABCDEF'
        return 100
    fi
}
apt-key() { [[ "$scenario" != key_failed ]]; }
for scenario in success recovered retry_failed key_failed; do
    : >"$apt_test_dir/calls"
    rc=0
    check_update || rc=$?
    calls=$(wc -l <"$apt_test_dir/calls" | tr -d ' ')
    case "$scenario" in
        success) [[ "$rc:$calls" == 0:1 ]] ;;
        recovered) [[ "$rc:$calls" == 0:2 ]] ;;
        retry_failed) [[ "$rc:$calls" == 100:2 ]] ;;
        key_failed) [[ "$rc:$calls" == 100:1 ]] ;;
    esac || fail "APT recovery $scenario returned $rc after $calls update calls"
done
printf 'Docker APT key recovery paths passed\n'

# lshw is present on many cloud images but may not expose logical names from
# a paravirtualized or nested network namespace.  The installer must fall back
# to the kernel link inventory instead of passing an empty uplink to ip link.
load_function discover_network_interfaces
load_function check_interface
SYSTEM="Debian" interface_1="" interface_2="" interface=""
fallback_bin=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 0\n' >"$fallback_bin/lshw"
chmod +x "$fallback_bin/lshw"
old_path="$PATH"
PATH="$fallback_bin:$PATH"
ip() {
    case "$*" in
        '-o link show') printf '%s\n' '1: lo: <LOOPBACK>' '2: eth0@if42: <BROADCAST>' ;;
        'link show dev eth0') return 0 ;;
        *) fail "Unexpected ip invocation: $*" ;;
    esac
}
discover_network_interfaces
check_interface
[[ "$interface" == "eth0" ]] || fail "empty lshw result did not fall back to eth0"
PATH="$old_path"
rm -rf "$fallback_bin"
printf 'Docker network interface fallback path passed\n'

load_function overlay2_mount_supported
load_function select_standard_storage_driver
mount() { return 1; }
umount() { :; }
findmnt() { printf '%s\n' ext4; }
selected_driver=$(select_standard_storage_driver | tail -n 1)
[[ "$selected_driver" == "vfs" || "$selected_driver" == "fuse-overlayfs" ]] ||
    fail "unsupported overlay2 environment selected unexpected driver: $selected_driver"
printf 'Docker storage-driver fallback path passed (%s)\n' "$selected_driver"

load_function docker_data_root_has_state
load_function configured_docker_storage_driver
load_function guard_docker_storage_driver
driver_guard_dir=$(mktemp -d)
driver_state="$driver_guard_dir/driver"
driver_config="$driver_guard_dir/daemon.json"
mkdir -p "$driver_guard_dir/data"
printf '%s\n' image-state >"$driver_guard_dir/data/marker"
docker_install_path="$driver_guard_dir/data"
DOCKER_STORAGE_DRIVER_STATE="$driver_state"
DOCKER_DAEMON_CONFIG="$driver_config"
printf '%s\n' overlay2 >"$driver_state"
guard_docker_storage_driver overlay2 || fail 'matching Docker driver must preserve existing data'
if guard_docker_storage_driver vfs; then
    fail 'Docker must reject switching an existing data root to another driver'
fi
rm -f -- "$driver_state"
printf '%s\n' '{"storage-driver":"overlay2"}' >"$driver_config"
guard_docker_storage_driver overlay2 || fail 'daemon.json driver should identify existing Docker data'
rm -f -- "$driver_config"
if guard_docker_storage_driver vfs; then
    fail 'Docker must reject unknown driver on an existing data root'
fi
rm -rf -- "$driver_guard_dir"
unset DOCKER_STORAGE_DRIVER_STATE DOCKER_DAEMON_CONFIG
printf 'Docker existing-data storage-driver guard passed\n'

# Re-running the installer with an unchanged daemon configuration must not
# restart Docker.  When a restart is genuinely required, restore only the
# containers that were running before it and propagate service failures.
load_function ensure_docker_ready
docker_calls=""
service_calls=""
docker() {
    case "${1:-}:${2:-}" in
        info:) return 0 ;;
        ps:-q) printf '%s\n' running-a running-b ;;
        start:*) docker_calls+=" start:$2" ;;
        *) fail "unexpected Docker readiness command: $*" ;;
    esac
}
systemctl() {
    service_calls+=" $*"
    return 0
}
docker_daemon_restart_required=false
ensure_docker_ready || fail 'unchanged Docker daemon readiness failed'
[[ -z "$service_calls" && -z "$docker_calls" ]] || fail 'unchanged Docker configuration restarted or started containers'
docker_daemon_restart_required=true
ensure_docker_ready || fail 'required Docker daemon restart failed'
[[ "$service_calls" == *'restart docker'* ]] || fail 'changed Docker configuration did not restart the daemon'
[[ "$docker_calls" == *'start:running-a'* && "$docker_calls" == *'start:running-b'* ]] || \
    fail 'daemon restart did not restore the previously running container set'
printf 'Docker repeat-install daemon lifecycle passed\n'

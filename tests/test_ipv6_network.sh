#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/dockerinstall.sh"
onedocker="$repo_root/scripts/onedocker.sh"
uninstaller="$repo_root/dockeruninstall.sh"

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$installer"
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function is_public_ipv6)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function select_public_ipv6_cidr)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function ipv6_cidr_prefix_length)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_subnet_has_live_address)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_subnet_overlaps_host)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_ula_candidate)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_ula_is_safe)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_ula_state_matches_network)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_normalize_public_parent)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_manual_state_matches_network)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_uplink_interface)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function docker_ipv6_uplink_supports_ndp)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function ndpresponder_image_matches_architecture)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function ndpresponder_supports_target_file)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function ndpresponder_supports_manual_routed_features)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function ndpresponder_image_supports_required_features)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function resolve_ndpresponder_image)"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/docker-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
cat > "$tmpdir/ip" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-d" ] && [ "${2:-}" = "link" ]; then
    case "${5:-}" in
        he-ipv6) printf '%s\n' '5: he-ipv6: <POINTOPOINT,UP> mtu 1480 link/sit' ;;
        *) printf '%s\n' '2: vmbr0: <BROADCAST,UP> mtu 1500 link/ether 02:00:00:00:00:01' ;;
    esac
    exit 0
fi
if [ "${1:-}" = "link" ]; then
    printf '%s\n' '2: vmbr0: <BROADCAST,UP> mtu 1500 link/ether 02:00:00:00:00:01'
    exit 0
fi
if [ "${1:-}" = "-6" ] && [ "${2:-}" = "route" ]; then
    if [ "${3:-}" = "show" ] && [ "${4:-}" = "default" ] && [ "${IPV6_TEST_SCENARIO:-}" = delegated ]; then
        # The management /128 uses the default route, while the delegated
        # /38 is carried by a separate PVE bridge.
        printf '%s\n' 'default via fe80::1 dev eth0 proto ra metric 1024'
        exit 0
    fi
    printf '%s\n' '2a14:6781:a::/64 dev eth0 proto kernel metric 256'
    exit 0
fi
case "${IPV6_TEST_SCENARIO:-default}" in
    delegated)
        printf '%s\n' '2: vmbr0    inet6 2a14:7c0:1002:10f8::1/128 scope global'
        printf '%s\n' '4: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
        ;;
    tunnel)
        printf '%s\n' '5: he-ipv6    inet6 2001:470:1f14:9::2/64 scope global'
        ;;
    narrow120)
        printf '%s\n' '2: eth0    inet6 2a14:6781:a::9/120 scope global'
        ;;
    narrow127)
        printf '%s\n' '2: eth0    inet6 2a14:6781:a::8/127 scope global'
        ;;
    hostonly)
        printf '%s\n' '2: eth0    inet6 2a14:6781:a::9/128 scope global'
        ;;
    *)
        printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::9/64 scope global'
        ;;
esac
EOF
chmod 700 "$tmpdir/ip"

old_path="$PATH"
export PATH="$tmpdir:$PATH"

selected=$(select_public_ipv6_cidr)
[[ "$selected" == '2a14:6781:000a:0000::9/64' ]] || fail "normal /64 selection returned $selected"
uplink=$(docker_ipv6_uplink_interface)
[[ "$uplink" == eth0 ]] || fail "normal /64 uplink detection returned $uplink"

export IPV6_TEST_SCENARIO=delegated
selected=$(select_public_ipv6_cidr)
[[ "$selected" == '2a14:7c0:1002:10f8::1/38' ]] || fail "delegated /38 was hidden by an uplink /128: $selected"
[[ "$(ipv6_cidr_prefix_length "$selected")" == 38 ]] || fail "delegated IPv6 CIDR did not retain its /38 prefix length"
[[ "$(docker_ipv6_normalize_public_parent "$selected")" == '2a14:7c0:1000::/38' ]] || fail "delegated /38 was not normalized"

export IPV6_TEST_SCENARIO=tunnel
selected=$(select_public_ipv6_cidr)
[[ "$selected" == '2001:470:1f14:9::2/64' ]] || fail "tunnel /64 selection returned $selected"
uplink=$(docker_ipv6_uplink_interface)
[[ "$uplink" == he-ipv6 ]] || fail "tunnel IPv6 uplink detection returned $uplink"
if docker_ipv6_uplink_supports_ndp "$uplink"; then
    fail "non-Ethernet tunnel was incorrectly marked as requiring NDP"
fi
if ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$repo_root/dockerfiles/entrypoint.sh" ||
   ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$repo_root/dockerfiles/entrypoint_alpine.sh"; then
    fail "Docker IPv6 keepalive jobs must force IPv6 and fail closed on probe errors"
fi

export IPV6_TEST_SCENARIO=delegated
uplink=$(docker_ipv6_uplink_interface)
[[ "$uplink" == vmbr2 ]] || fail "PVE delegated IPv6 uplink detection returned $uplink"
docker_ipv6_uplink_supports_ndp "$uplink" || fail "PVE Ethernet bridge was incorrectly marked as a tunnel"

export IPV6_TEST_SCENARIO=narrow120
selected=$(select_public_ipv6_cidr)
[[ "$selected" == '2a14:6781:a::9/120' ]] || fail "routed /120 selection returned $selected"

export IPV6_TEST_SCENARIO=narrow127
selected=$(select_public_ipv6_cidr)
[[ "$selected" == '2a14:6781:a::8/127' ]] || fail "routed /127 selection returned $selected"

export IPV6_TEST_SCENARIO=hostonly
selected=$(select_public_ipv6_cidr)
[[ "$selected" == '2a14:6781:a::9/128' ]] || fail "host-only /128 selection returned $selected"
if docker_ipv6_normalize_public_parent "$selected" >/dev/null; then
    fail "a lone /128 was accepted as a routed public parent"
fi

unset IPV6_TEST_SCENARIO
docker_ipv6_subnet_has_live_address '2a14:6781:000a:0000::/64' || fail "host IPv6 was not found in its CIDR"
if docker_ipv6_subnet_has_live_address '2a14:6781:000a:0000:1::/80'; then
    fail "sibling subnet was incorrectly reported as containing a host address"
fi
if ! docker_ipv6_subnet_overlaps_host '2a14:6781:a::1:0:0/96'; then
    fail "connected host IPv6 route was not detected as a Docker overlap"
fi
if docker_ipv6_subnet_overlaps_host "$(docker_ipv6_ula_candidate 0)"; then
    fail "isolated Docker ULA unexpectedly overlaps the host route"
fi

managed_ula=$(docker_ipv6_ula_candidate 0)
docker_ipv6_ula_state_matches_network nat "$managed_ula" "$managed_ula" || fail "installer-managed Docker ULA was not accepted for NAT66 reuse"
docker_ipv6_manual_state_matches_network manual "$managed_ula" "$managed_ula" '2a14:6781:a::9/64' || fail "installer-managed routed Docker ULA was not accepted"
if docker_ipv6_manual_state_matches_network manual "$managed_ula" "$managed_ula" '2a14:6781:a::9/128'; then
    fail "a /128 was accepted as a routed Docker parent"
fi
if docker_ipv6_ula_state_matches_network managed "$managed_ula" "$managed_ula" || \
   docker_ipv6_ula_state_matches_network nat 'fd42:5339:296f:1d01::/64' "$managed_ula" || \
   docker_ipv6_ula_state_matches_network nat '2a14:6781:a::/64' '2a14:6781:a::/64'; then
    fail "unmanaged or mismatched Docker ULA was accepted for reuse"
fi
reuse_overlap_check="docker_ipv6_subnet_overlaps_host \"\$existing_ula\""
if extract_function create_docker_ula_ipv6_network | grep -Fq "$reuse_overlap_check"; then
    fail "Docker ULA reuse incorrectly checks its own connected bridge route"
fi
export PATH="$old_path"

is_public_ipv6 '2a14:6781:a::9' || fail "expected a global unicast IPv6 to be accepted"
for non_public in 'fec0::1' 'ff02::1' '64:ff9b::1' '2001:0000::1' '2001:0002::1' '2001:0010::1' '2001:0020::1' '2001:0db8::1' '2002::1' '3fff:000f::1'; do
    if is_public_ipv6 "$non_public"; then
        fail "non-public IPv6 was accepted as a Docker source: $non_public"
    fi
done

if extract_function check_ipv6 | grep -Eq 'API_NET|curl[[:space:]]|docker_last_ipv6'; then
    fail "check_ipv6 must only use locally bound IPv6 state"
fi
adapt_source=$(extract_function adapt_ipv6)
accept_ra_setting="net.ipv6.conf.\${uplink}.accept_ra=2"
if ! grep -Fq "$accept_ra_setting" <<<"$adapt_source"; then
    fail "Docker IPv6 forwarding must preserve router advertisements on the uplink"
fi
if grep -Fq 'proxy_ndp' <<<"$adapt_source"; then
    fail "routed Docker IPv6 must not change global proxy_ndp state"
fi
for forbidden in 'touch /etc/cloud/cloud-init.disabled' 'rebuild_cloud_init' 'ip addr del fe80' 'handle_networking'; do
    if grep -Fq "$forbidden" "$installer"; then
        fail "installer retained forbidden host-network mutation: $forbidden"
    fi
done

main_source=$(extract_function main)
install_line=$(grep -nF 'install_docker_and_compose' <<<"$main_source" | head -n 1 | cut -d: -f1)
ipv6_line=$(grep -nF 'check_and_adapt_ipv6' <<<"$main_source" | head -n 1 | cut -d: -f1)
[[ "$install_line" -lt "$ipv6_line" ]] || fail "Docker must be ready before IPv6 network creation"
grep -Fq 'ensure_docker_ready' <<<"$main_source" || fail "main must wait for Docker before configuring IPv6"

docker_build_ipv6_source=$(extract_function docker_build_ipv6)
manual_ipv6_create_call="create_docker_manual_ipv6_network \"\$public_parent\""
ula_ipv6_create_call="create_docker_ula_ipv6_network \"\$public_parent\""
if ! grep -Fq 'public_parent_prefix == 128' <<<"$docker_build_ipv6_source" || \
   ! grep -Fq "$manual_ipv6_create_call" <<<"$docker_build_ipv6_source" || \
   ! grep -Fq "$ula_ipv6_create_call" <<<"$docker_build_ipv6_source"; then
    fail "Docker must route non-/128 parents and use NAT66 only for a lone /128"
fi
if grep -Fq 'public_parent_prefix > 112' <<<"$docker_build_ipv6_source"; then
    fail "Docker must not discard usable /120 or /127 routed IPv6 parents"
fi
grep -Fq '["ip", "-6", "route", "show", "default"]' "$installer" || fail "routed IPv6 allocation must reserve the upstream default gateway"

ndp_source=$(extract_function start_docker_manual_ndpresponder)
if grep -Fq -- '--restart always' <<<"$ndp_source"; then
    fail "Docker ndpresponder must not retain an unconditional restart policy"
fi
for required in '--restart on-failure:3' 'docker update --restart=no ndpresponder' '--target-file /etc/ndpresponder-targets' '--target-file-reload-interval 2s' '--ready-file /run/ndpresponder-ready'; do
    grep -Fq -- "$required" <<<"$ndp_source" || fail "Docker responder is missing required safeguard: $required"
done
grep -Fq 'quarantine_incompatible_docker_ndpresponder' <<<"$ndp_source" || fail "Docker must quarantine a legacy responder before target-file use"
grep -Fq 'docker-ipv6-attach.sh' "$onedocker" || fail "container creation does not invoke the routed IPv6 helper"
grep -Fq 'attach_manual_ipv6_or_rollback' "$onedocker" || fail "container creation does not roll back failed IPv6 attachment"
grep -Fq 'docker_ipv6_ndp_ready_required' "$onedocker" || fail "container creation does not honor the responder readiness contract"
grep -Fq 'docker_ipv6_ndp_ready' "$onedocker" || fail "container creation does not inspect the responder readiness marker"
manual_ipv6_rollback_call="\"\$manual_ipv6_helper\" --remove \"\$name\""
tunnel_ndp_check="[ \"\$ndp_required\" = \"false\" ]"
grep -Fq "$manual_ipv6_rollback_call" "$onedocker" || fail "failed attachment does not remove its address mapping"
grep -Fq "$tunnel_ndp_check" "$onedocker" || fail "tunnel/non-Ethernet IPv6 still requires an NDP responder"
if grep -Fq 'radvd' "$uninstaller" || grep -Fq '/etc/sysctl.d/99-custom.conf' "$uninstaller"; then
    fail "Docker uninstall must not remove host-owned IPv6 services or generic sysctl state"
fi
grep -Fq 'docker-ipv6-attach.service' "$uninstaller" || fail "Docker uninstall does not clean the installer-owned routed IPv6 service"
grep -Fq '99-oneclickvirt-docker-ipv6.conf' "$uninstaller" || fail "Docker uninstall does not clean the installer-owned sysctl file"
grep -Fq 'docker_ipv6_ndp_ready_required' "$uninstaller" || fail "Docker uninstall does not clean the readiness requirement state"

# A registry tag can be published for the wrong CPU. The resolver must build a
# local image, validate that image too, and leave container mutation to its
# caller so a failed fallback cannot remove a working responder.
_yellow() { :; }
NDPRESPONDER_TARGET_FILE_REQUIRED=false
mock_build_succeeds=true
mock_build_called=false
mock_remove_called=false
# shellcheck disable=SC2317,SC2329 # Invoked by the dynamically sourced resolver.
docker() {
    case "$1:$2" in
        pull:*)
            return 0
            ;;
        image:inspect)
            case "$*" in
                *localhost/oneclickvirt-ndpresponder:arm64*) printf '%s\n' arm64 ;;
                *) printf '%s\n' amd64 ;;
            esac
            return 0
            ;;
        build:--tag)
            mock_build_called=true
            "$mock_build_succeeds"
            return
            ;;
        rm:*)
            mock_remove_called=true
            return 0
            ;;
        *)
            printf 'unexpected docker invocation during resolver test: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
# shellcheck disable=SC2034 # Consumed by the dynamically sourced resolver.
NDPRESPONDER_SOURCE_URL=https://example.invalid/ndpresponder.git
if ! resolve_ndpresponder_image arm64 spiritlhl/ndpresponder_aarch64; then
    fail "Docker did not build a validated local responder after a bad registry architecture"
fi
[[ "$NDPRESPONDER_IMAGE" == 'localhost/oneclickvirt-ndpresponder:arm64' ]] || fail "Docker resolver selected $NDPRESPONDER_IMAGE instead of the validated local responder"
[[ "$mock_build_called" == true && "$mock_remove_called" == false ]] || fail "Docker resolver mutated a responder container before caller validation"

mock_build_succeeds=false
mock_build_called=false
mock_remove_called=false
if resolve_ndpresponder_image arm64 spiritlhl/ndpresponder_aarch64; then
    fail "Docker accepted a responder after both registry and source architectures failed"
fi
[[ "$mock_build_called" == true && "$mock_remove_called" == false ]] || fail "Docker resolver changed a responder container after a failed source build"

docker() {
    if [[ "$1" == run && "$2" == --rm && "$4" == --help ]]; then
        case "$3" in
            supports-target-file)
                printf '%s\n' '  --target-file value  reload static IPv6 targets'
                printf '%s\n' '  --target-file-reload-interval value  target refresh interval'
                printf '%s\n' '  --ready-file value  responder readiness marker'
                ;;
            *) printf '%s\n' 'Usage: ndpresponder -i IFACE' ;;
        esac
        return 0
    fi
    return 1
}
# shellcheck disable=SC2034 # Consumed by the dynamically sourced capability probe.
NDPRESPONDER_TARGET_FILE_REQUIRED=true
ndpresponder_supports_manual_routed_features supports-target-file || fail "new responder routed IPv6 capabilities were not detected"
if ndpresponder_supports_manual_routed_features legacy-image; then
    fail "legacy responder was incorrectly accepted for routed IPv6 mode"
fi
ndpresponder_image_supports_required_features supports-target-file || fail "routed IPv6-capable responder was rejected"
if ndpresponder_image_supports_required_features legacy-image; then
    fail "routed IPv6-incompatible responder was accepted"
fi

printf 'docker IPv6 network regression tests passed\n'

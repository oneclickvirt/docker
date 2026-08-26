#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/dockerinstall.sh"

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

# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function docker_ipv6_subnet_has_live_address)
# shellcheck disable=SC1090 # The test intentionally loads the host route overlap helper.
source <(extract_function docker_ipv6_subnet_overlaps_host)
# shellcheck disable=SC1090 # The test intentionally loads the ULA candidate helper.
source <(extract_function docker_ipv6_ula_candidate)
# shellcheck disable=SC1090 # The test intentionally loads ULA validation helpers.
source <(extract_function docker_ipv6_ula_is_safe)
# shellcheck disable=SC1090 # The test intentionally loads the idempotency guard.
source <(extract_function docker_ipv6_ula_state_matches_network)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function is_public_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads the CIDR selector.
source <(extract_function select_public_ipv6_cidr)
# shellcheck disable=SC1090 # The test intentionally loads the CIDR prefix parser.
source <(extract_function ipv6_cidr_prefix_length)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_image_matches_architecture)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function resolve_ndpresponder_image)

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/docker-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
cat > "$tmpdir/ip" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-6" ] && [ "${2:-}" = "route" ]; then
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
    *)
        printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::9/64 scope global'
        ;;
esac
EOF
chmod 700 "$tmpdir/ip"

old_path="$PATH"
export PATH="$tmpdir:$PATH"
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2a14:6781:000a:0000::9/64' ]]; then
    printf 'normal /64 selection returned %q\n' "$selected" >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=delegated
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2a14:7c0:1002:10f8::1/38' ]]; then
    printf 'delegated /38 was hidden by an uplink /128: %q\n' "$selected" >&2
    exit 1
fi
if [[ "$(ipv6_cidr_prefix_length "$selected")" != 38 ]]; then
    printf 'delegated IPv6 CIDR did not retain its /38 prefix length\n' >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=tunnel
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2001:470:1f14:9::2/64' ]]; then
    printf 'tunnel /64 selection returned %q\n' "$selected" >&2
    exit 1
fi
unset IPV6_TEST_SCENARIO
docker_ipv6_subnet_has_live_address "2a14:6781:000a:0000::/64"
if docker_ipv6_subnet_has_live_address "2a14:6781:000a:0000:1::/80"; then
    printf 'sibling subnet was incorrectly reported as containing a host address\n' >&2
    exit 1
fi
if ! docker_ipv6_subnet_overlaps_host "2a14:6781:a::1:0:0/96"; then
    printf 'connected host IPv6 route was not detected as a Docker overlap\n' >&2
    exit 1
fi
if docker_ipv6_subnet_overlaps_host "$(docker_ipv6_ula_candidate 0)"; then
    printf 'isolated Docker ULA unexpectedly overlaps the host route\n' >&2
    exit 1
fi
managed_ula=$(docker_ipv6_ula_candidate 0)
if ! docker_ipv6_ula_state_matches_network nat "$managed_ula" "$managed_ula"; then
    printf 'installer-managed Docker ULA was not accepted for reuse\n' >&2
    exit 1
fi
if docker_ipv6_ula_state_matches_network managed "$managed_ula" "$managed_ula" ||
   docker_ipv6_ula_state_matches_network nat "fd42:5339:296f:1d01::/64" "$managed_ula" ||
   docker_ipv6_ula_state_matches_network nat "2a14:6781:a::/64" "2a14:6781:a::/64"; then
    printf 'unmanaged or mismatched Docker IPv6 network was accepted for reuse\n' >&2
    exit 1
fi
if extract_function create_docker_ula_ipv6_network | grep -Fq "docker_ipv6_subnet_overlaps_host \"\$existing_ula\""; then
    printf 'Docker ULA reuse incorrectly checks its own connected bridge route\n' >&2
    exit 1
fi
export PATH="$old_path"

if ! is_public_ipv6 "2a14:6781:a::9"; then
    printf 'expected a global unicast IPv6 to be accepted\n' >&2
    exit 1
fi
for non_public in "fec0::1" "ff02::1" "64:ff9b::1" "2001:0000::1" "2001:0002::1" "2001:0010::1" "2001:0020::1" "2001:0db8::1" "2002::1" "3fff:000f::1"; do
    if is_public_ipv6 "$non_public"; then
        printf 'non-public IPv6 was accepted as a Docker source: %s\n' "$non_public" >&2
        exit 1
    fi
done

if extract_function check_ipv6 | grep -Eq 'API_NET|curl[[:space:]]'; then
    printf 'check_ipv6 must not use an external address as a Docker subnet source\n' >&2
    exit 1
fi
if ! extract_function adapt_ipv6 | grep -Fq "net.ipv6.conf.\${interface}.accept_ra=2"; then
    printf 'Docker IPv6 forwarding must preserve router advertisements on the uplink\n' >&2
    exit 1
fi
docker_build_ipv6_source=$(extract_function docker_build_ipv6)
if ! grep -Fq 'public_parent_prefix > 112' <<<"$docker_build_ipv6_source" || \
   ! grep -Fq "create_docker_ula_ipv6_network \"\$public_parent\"" <<<"$docker_build_ipv6_source"; then
    printf 'Docker must use ULA NAT66 instead of pretending a /113-/128 parent can create a public bridge subnet\n' >&2
    exit 1
fi
if ! ndpresponder_image_matches_architecture arm64 arm64 ||
   ! ndpresponder_image_matches_architecture arm arm ||
   ndpresponder_image_matches_architecture arm64 amd64 ||
   ndpresponder_image_matches_architecture arm amd64; then
    printf 'Docker responder image architecture validation is incorrect\n' >&2
    exit 1
fi
if ! grep -Fq 'registry_ndp_image="spiritlhl/ndpresponder_aarch64"' "$installer"; then
    printf 'Docker must select the published aarch64 responder tag on ARM64\n' >&2
    exit 1
fi
if extract_function docker_build_ipv6 | grep -Fq -- '--restart always'; then
    printf 'Docker ndpresponder must not retain an unconditional restart policy\n' >&2
    exit 1
fi
if ! extract_function docker_build_ipv6 | grep -Fq -- '--restart on-failure:3'; then
    printf 'Docker ndpresponder must use a bounded failure restart policy\n' >&2
    exit 1
fi
if ! extract_function docker_build_ipv6 | grep -Fq 'docker update --restart=no ndpresponder'; then
    printf 'Docker must stop a failed ndpresponder restart loop during health verification\n' >&2
    exit 1
fi

# A registry tag can be published for the wrong CPU. The resolver must build a
# local image, validate that image too, and leave container mutation to its
# caller so a failed fallback cannot remove a working responder.
_yellow() { :; }
mock_build_succeeds=true
mock_build_called=false
mock_remove_called=false
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
    printf 'Docker did not build a validated local responder after a bad registry architecture\n' >&2
    exit 1
fi
[[ "$NDPRESPONDER_IMAGE" == 'localhost/oneclickvirt-ndpresponder:arm64' ]] || {
    printf 'Docker resolver selected %q instead of the validated local responder\n' "$NDPRESPONDER_IMAGE" >&2
    exit 1
}
[[ "$mock_build_called" == true && "$mock_remove_called" == false ]] || {
    printf 'Docker resolver mutated a responder container before the caller could validate the fallback\n' >&2
    exit 1
}

mock_build_succeeds=false
mock_build_called=false
mock_remove_called=false
if resolve_ndpresponder_image arm64 spiritlhl/ndpresponder_aarch64; then
    printf 'Docker accepted a responder after both registry and source architectures failed\n' >&2
    exit 1
fi
[[ "$mock_build_called" == true && "$mock_remove_called" == false ]] || {
    printf 'Docker resolver changed a responder container after a failed source build\n' >&2
    exit 1
}

printf 'docker IPv6 network candidate tests passed\n'

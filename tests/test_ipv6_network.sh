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
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function is_public_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_image_matches_architecture)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function resolve_ndpresponder_image)

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/docker-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
cat > "$tmpdir/ip" <<'EOF'
#!/bin/sh
printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::9/64 scope global'
EOF
chmod 700 "$tmpdir/ip"

old_path="$PATH"
export PATH="$tmpdir:$PATH"
docker_ipv6_subnet_has_live_address "2a14:6781:000a:0000::/64"
if docker_ipv6_subnet_has_live_address "2a14:6781:000a:0000:1::/80"; then
    printf 'sibling subnet was incorrectly reported as containing a host address\n' >&2
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
if ! extract_function adapt_ipv6 | grep -Fq 'net.ipv6.conf.${interface}.accept_ra=2'; then
    printf 'Docker IPv6 forwarding must preserve router advertisements on the uplink\n' >&2
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

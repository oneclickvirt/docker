#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/dockerinstall.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/docker-host-ipv6.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

extract_function() {
    awk -v name="$1" '$0 == name "() {" {printing=1} printing {print} printing && /^}$/ {exit}' "$installer"
}
eval "$(extract_function valid_ipv6_in_parent)"
eval "$(extract_function host_ipv6_address_available)"
eval "$(extract_function find_container_iface)"

cat >"$test_dir/ip" <<'EOF'
#!/bin/sh
case "$*" in
    '-j -6 addr show')
        if [ "${IP_TEST_SCENARIO:-}" = malformed ]; then
            printf '\033[31mUngültige Adresse / Adresse non valide / IPv6 地址无效\033[0m\n'
        elif [ "${IP_TEST_SCENARIO:-}" = colored ]; then
            printf '\033[32m%s\033[0m\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::1","prefixlen":64}]}]'
        else
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::1","prefixlen":64}]}]'
        fi
        ;;
    '-j -6 route show table all')
        if [ "${IP_TEST_SCENARIO:-}" = colored ]; then
            printf '\033[36m%s\033[0m\n' '[{"dst":"default","gateway":"2a01:4f8:c014:1a63::2","dev":"eth0"},{"dst":"2a01:4f8:c014:1a63::4/128","dev":"eth0"},{"dst":"2a01:4f8:c014:1a63::6/128","dev":"br-test"}]'
        else
            printf '%s\n' '[{"dst":"default","gateway":"2a01:4f8:c014:1a63::2","dev":"eth0"},{"dst":"2a01:4f8:c014:1a63::4/128","dev":"eth0"},{"dst":"2a01:4f8:c014:1a63::6/128","dev":"br-test"}]'
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "$test_dir/ip"
cat >"$test_dir/runtime" <<'EOF'
#!/bin/sh
[ "${IP_TEST_SCENARIO:-}" = no_ula ] || printf '%s\n' 'fd42::2'
EOF
cat >"$test_dir/nsenter" <<'EOF'
#!/bin/sh
case "$*" in
    *'-j -6 addr show')
        [ "${IP_TEST_SCENARIO:-}" = malformed ] && { printf 'Adresse non valide / IPv6 地址无效\n'; exit 0; }
        printf '\033[32m%s\033[0m\n' '[{"ifname":"eth0@if7","addr_info":[{"family":"inet6","local":"fd42::2","prefixlen":64}]}]'
        ;;
    *'-j link show')
        printf '\033[36m%s\033[0m\n' '[{"ifname":"lo"},{"ifname":"eth0@if7"}]'
        ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "$test_dir/runtime" "$test_dir/nsenter"
export PATH="$test_dir:$PATH"
runtime="$test_dir/runtime"

reject() {
    if "$@"; then
        printf 'Unexpectedly accepted host IPv6 conflict: %s\n' "$*" >&2
        exit 1
    fi
}

valid_ipv6_in_parent '2a01:4f8:c014:1a63::5' '2a01:4f8:c014:1a63::/64'
valid_ipv6_in_parent '2a01:4f8:c014:1a63::5' '2a01:4f8:c014:1a00::/56'
valid_ipv6_in_parent '2a01:4f8:c014:1a63::5' '2a01:4f8:c014:1a63::/120'
reject valid_ipv6_in_parent '2a01:4f8:c014:1a63::' '2a01:4f8:c014:1a63::/64'
reject valid_ipv6_in_parent '2a01:4f8:c014:1a63::8' '2a01:4f8:c014:1a63::8/127'

reject host_ipv6_address_available '2a01:4f8:c014:1a63::1' br-test ''
reject host_ipv6_address_available '2a01:4f8:c014:1a63::2' br-test ''
reject host_ipv6_address_available '2a01:4f8:c014:1a63::4' br-test ''
reject host_ipv6_address_available '2a01:4f8:c014:1a63::6' br-test ''
host_ipv6_address_available '2a01:4f8:c014:1a63::6' br-test '2a01:4f8:c014:1a63::6'
host_ipv6_address_available '2a01:4f8:c014:1a63::5' br-test ''
IP_TEST_SCENARIO=colored host_ipv6_address_available '2a01:4f8:c014:1a63::5' br-test ''
IP_TEST_SCENARIO=colored reject host_ipv6_address_available '2a01:4f8:c014:1a63::1' br-test ''
IP_TEST_SCENARIO=malformed reject host_ipv6_address_available '2a01:4f8:c014:1a63::5' br-test ''
[ "$(find_container_iface guest1 123)" = eth0 ]
[ "$(IP_TEST_SCENARIO=no_ula find_container_iface guest1 123)" = eth0 ]
IP_TEST_SCENARIO=malformed reject find_container_iface guest1 123

printf 'Docker host IPv6 preservation tests passed\n'

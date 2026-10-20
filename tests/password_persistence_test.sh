#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
for entrypoint in entrypoint.sh entrypoint_alpine.sh; do
    (
        eval "$(awk '/^initialize_root_password\(\) \{/,/^}/ {print}' "$root/dockerfiles/$entrypoint")"
        chpasswd() {
            cat >/dev/null
            [[ "${password_failure:-false}" != true ]] || return 1
            printf 'changed\n' >>"$temporary/calls-$entrypoint"
        }
        ROOT_PASSWORD=initial-bootstrap
        state="$temporary/$entrypoint/state"
        initialize_root_password "$state"
        ROOT_PASSWORD=old-environment-must-not-reset-user-password
        initialize_root_password "$state"
        [[ $(wc -l <"$temporary/calls-$entrypoint") == 1 ]]
        password_failure=true
        if initialize_root_password "$temporary/$entrypoint/failed"; then
            echo 'Password failure was accepted' >&2; exit 1
        fi
        [[ ! -e "$temporary/$entrypoint/failed" ]]
        password_failure=false
        initialize_root_password "$temporary/$entrypoint/failed"
        [[ -f "$temporary/$entrypoint/failed" ]]
    )
done
echo 'Docker password initialization survives restart and propagates failures'

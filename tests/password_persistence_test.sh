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
        [[ $(wc -l <"$temporary/calls-$entrypoint") -eq 1 ]]
        password_failure=true
        if initialize_root_password "$temporary/$entrypoint/failed"; then
            echo 'Password failure was accepted' >&2; exit 1
        fi
        [[ ! -e "$temporary/$entrypoint/failed" ]]
        password_failure=false
        unset ROOT_PASSWORD
        ROOT_PASSWORD_FILE="$temporary/$entrypoint/password"
        printf 'mounted-secret\n' >"$ROOT_PASSWORD_FILE"
        initialize_root_password "$temporary/$entrypoint/from-file"
        [[ -f "$temporary/$entrypoint/from-file" ]]
        printf 'line-one\nline-two\n' >"$ROOT_PASSWORD_FILE"
        if initialize_root_password "$temporary/$entrypoint/multiline"; then
            echo 'A multiline password file was accepted' >&2; exit 1
        fi
        [[ ! -e "$temporary/$entrypoint/multiline" ]]
        ROOT_PASSWORD=conflicting-value
        if initialize_root_password "$temporary/$entrypoint/conflict"; then
            echo 'Conflicting password sources were accepted' >&2; exit 1
        fi
        unset ROOT_PASSWORD_FILE
        ROOT_PASSWORD=initial-bootstrap
        initialize_root_password "$temporary/$entrypoint/failed"
        [[ -f "$temporary/$entrypoint/failed" ]]
    )
done
echo 'Docker password initialization survives restart and propagates failures'

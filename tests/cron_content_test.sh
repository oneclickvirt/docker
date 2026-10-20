#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
eval "$(awk '/^same_file_contents\(\) \{/,/^}/ {print}' "$root/dockerfiles/entrypoint.sh")"
printf 'managed cron\n' >"$temporary/expected"
cp "$temporary/expected" "$temporary/existing"
printf 'managed cron' >"$temporary/different-newline"
printf 'custom cron\n' >"$temporary/custom"
for mode in normal no_cmp; do
    (
        if [[ "$mode" == no_cmp ]]; then
            mkdir "$temporary/minimal-bin"
            ln -s "$(command -v sha256sum)" "$temporary/minimal-bin/sha256sum"
            # shellcheck disable=SC2123 # Exercise a minimal image without cmp on its search path.
            PATH="$temporary/minimal-bin"
        fi
        same_file_contents "$temporary/expected" "$temporary/existing"
        if same_file_contents "$temporary/expected" "$temporary/custom"; then
            printf 'Custom cron was mistaken for managed content\n' >&2; exit 1
        fi
        if same_file_contents "$temporary/expected" "$temporary/different-newline"; then
            printf 'Comparison discarded a meaningful final newline\n' >&2; exit 1
        fi
        if same_file_contents "$temporary/missing" "$temporary/existing" 2>/dev/null; then
            printf 'An unreadable cron file was accepted\n' >&2; exit 1
        fi
    )
done
printf 'Managed cron comparison works without cmp and preserves custom content\n'

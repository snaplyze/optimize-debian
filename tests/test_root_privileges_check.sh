#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_script_non_root_guard() {
    local script_name="$1"
    local script_path="$ROOT_DIR/$script_name"
    local output status

    [ -f "$script_path" ] || fail "Script not found: $script_path"

    # Capture output and stderr
    set +e
    output="$(bash "$script_path" 2>&1)"
    status=$?
    set -e

    if [ "$status" -ne 1 ]; then
        fail "$script_name: expected exit code 1 when run as non-root, got $status (output: $output)"
    fi

    if grep -iq "permission denied" <<<"$output"; then
        fail "$script_name: Permission denied detected in output: $output"
    fi

    if ! grep -Eq "(must be run as root|Запустите от root|с правами root)" <<<"$output"; then
        fail "$script_name: expected root warning message not found in output: $output"
    fi
}

main() {
    if [ "$(id -u)" -eq 0 ]; then
        printf 'SKIPPED: test_root_privileges_check.sh (running as root)\n'
        exit 0
    fi

    test_script_non_root_guard "optimize_amnezia_host.sh"
    test_script_non_root_guard "optimize_vps.sh"
    test_script_non_root_guard "optimize_mini_pc.sh"
    test_script_non_root_guard "optimize_wsl2.sh"
    test_script_non_root_guard "upgrade-to-debian13.sh"

    printf 'tests/test_root_privileges_check.sh: OK\n'
}

main "$@"

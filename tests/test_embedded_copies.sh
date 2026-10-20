#!/usr/bin/env bash
# Users run optimize_*.sh as `bash <(curl ...)`: lib/ is not there and the embedded
# copies of lib/ functions run instead. Every copy must match lib/ exactly, so the
# tests of lib/ cover the copies too.
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(optimize_vps.sh optimize_amnezia_host.sh optimize_mini_pc.sh optimize_wsl2.sh)
LIBS=(lib/common.sh lib/tui.sh)

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR:-}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Writes `declare -f` of each function named in $2 that the sourced files define,
# one file per function in $1. A clean environment keeps the caller out of it; stdin is
# /dev/null because bash with a socket on stdin and no SHLVL reads ~/.bashrc.
dump_functions() {
    local out_dir="$1" names_file="$2"
    shift 2
    mkdir -p "$out_dir"
    env -i PATH="$PATH" HOME="$TEST_DIR" OPTIMIZE_SOURCE_ONLY=1 bash -c '
        out_dir="$1"
        names_file="$2"
        shift 2
        for f in "$@"; do
            # shellcheck disable=SC1090
            source "$f"
        done
        while IFS= read -r fn; do
            if declare -F "$fn" >/dev/null; then
                declare -f "$fn" > "$out_dir/$fn"
            fi
        done < "$names_file"
    ' _ "$out_dir" "$names_file" "$@" </dev/null >/dev/null
}

main() {
    local script fn copies total=0 lib
    local lib_paths=()

    for lib in "${LIBS[@]}"; do
        lib_paths+=("$ROOT_DIR/$lib")
    done
    for lib in "${lib_paths[@]}"; do
        env -i PATH="$PATH" bash -c 'source "$1"; compgen -A function' _ "$lib" </dev/null
    done | sort -u > "$TEST_DIR/function_names"
    [ -s "$TEST_DIR/function_names" ] || fail "no functions found in ${LIBS[*]}"

    dump_functions "$TEST_DIR/ref" "$TEST_DIR/function_names" "${lib_paths[@]}" || \
        fail "cannot source ${LIBS[*]}"

    for script in "${SCRIPTS[@]}"; do
        # A copy of the script in a directory without lib/ defines only its embedded copies.
        mkdir -p "$TEST_DIR/standalone/$script.d"
        cp "$ROOT_DIR/$script" "$TEST_DIR/standalone/$script.d/$script"
        dump_functions "$TEST_DIR/copy/$script" "$TEST_DIR/function_names" \
            "$TEST_DIR/standalone/$script.d/$script" || \
            fail "cannot source $script without lib/ (OPTIMIZE_SOURCE_ONLY=1)"

        copies=0
        while IFS= read -r fn; do
            [ -f "$TEST_DIR/copy/$script/$fn" ] || continue
            copies=$((copies + 1))
            if ! cmp -s "$TEST_DIR/ref/$fn" "$TEST_DIR/copy/$script/$fn"; then
                {
                    printf 'FAIL: embedded copy of %s in %s differs from lib/ (lib/ -> copy):\n' "$fn" "$script"
                    diff -u "$TEST_DIR/ref/$fn" "$TEST_DIR/copy/$script/$fn" | sed -e '1,2d' | head -n 30
                } >&2
                exit 1
            fi
        done < "$TEST_DIR/function_names"

        [ "$copies" -gt 0 ] || fail "$script defines no embedded copies of lib/ functions"
        total=$((total + copies))
    done

    printf 'tests/test_embedded_copies.sh: OK (%d copies in %d scripts)\n' "$total" "${#SCRIPTS[@]}"
}

main "$@"

#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_locale_generation() (
    local source_file="$1"
    # shellcheck disable=SC1090 # Exercise both the library and standalone scripts.
    OPTIMIZE_SOURCE_ONLY=1 source "$source_file"
    trap - ERR
    declare -F common_generate_utf8_locales >/dev/null || \
        fail "$source_file does not provide locale generation"

    local locale_file="$TEST_DIR/locale.gen"
    local generated_locales=$'C\nC.utf8\nen_US.utf8\nru_RU.utf8'
    local generation_status=0
    # shellcheck disable=SC2317,SC2329 # Invoked by the sourced production helper.
    locale-gen() {
        [ "$LC_ALL" = C ] || fail "generation needs a valid LC_ALL"
        [ "$LANG" = C ] || fail "generation needs a valid LANG"
        [ "$*" = --keep-existing ] || fail "existing compiled locales must be preserved"
        return "$generation_status"
    }
    # shellcheck disable=SC2317,SC2329 # Invoked by the sourced production helper.
    locale() {
        [ "$*" = -a ] || fail "unexpected locale command: $*"
        printf '%s\n' "$generated_locales"
    }

    cat > "$locale_file" <<'EOF'
# retained comment
de_DE.UTF-8 UTF-8
# en_US.UTF-8 UTF-8
 en_US.UTF-8   UTF-8
  # ru_RU.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8 # duplicate
EOF
    common_generate_utf8_locales "$locale_file"
    [ "$(grep -c '^en_US.UTF-8 UTF-8$' "$locale_file")" = 1 ] || fail "English must be enabled once"
    [ "$(grep -c '^ru_RU.UTF-8 UTF-8$' "$locale_file")" = 1 ] || fail "Russian must be enabled once"
    [ "$(grep -c 'ru_RU\|en_US' "$locale_file")" = 2 ] || fail "duplicate locale entries remain"
    grep -qx 'de_DE.UTF-8 UTF-8' "$locale_file" || fail "existing locale was removed"
    grep -qx '# retained comment' "$locale_file" || fail "unrelated comment was removed"
    cp "$locale_file" "$TEST_DIR/expected.gen"
    common_generate_utf8_locales "$locale_file"
    cmp "$locale_file" "$TEST_DIR/expected.gen" || fail "locale generation is not idempotent"

    rm "$locale_file"
    common_generate_utf8_locales "$locale_file"
    grep -qx 'ru_RU.UTF-8 UTF-8' "$locale_file" || fail "missing locale.gen was not created"

    generation_status=1
    if common_generate_utf8_locales "$locale_file"; then
        fail "locale-gen failure must propagate"
    fi
    generation_status=0
    generated_locales=$'C\nC.utf8\nen_US.utf8'
    if common_generate_utf8_locales "$locale_file" 2> "$TEST_DIR/error"; then
        fail "missing Russian locale must fail even when locale-gen succeeds"
    fi
    grep -q ru_RU "$TEST_DIR/error" || fail "generation failure must identify the missing locale"
)

test_profile_contracts() {
    local script
    for script in optimize_amnezia_host.sh optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh; do
        grep -Eq '^[[:space:]]*common_generate_utf8_locales /etc/locale.gen$' "$ROOT_DIR/$script" || \
            fail "$script must generate English and Russian locales"
        if grep -Eq '^(export )?LC_ALL=[$]DEFAULT_LOCALE$' "$ROOT_DIR/$script"; then
            fail "$script must not persist LC_ALL in login configuration"
        fi
    done
    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh; do
        grep -q 'update-locale --reset' "$ROOT_DIR/$script" || \
            fail "$script must use the distro locale configuration path"
    done
}

test_locale_generation "$ROOT_DIR/lib/common.sh"
for script in optimize_amnezia_host.sh optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh; do
    test_locale_generation "$ROOT_DIR/$script"
    cp "$ROOT_DIR/$script" "$TEST_DIR/$script"
    test_locale_generation "$TEST_DIR/$script"
done
test_profile_contracts
printf 'tests/test_locale_configuration.sh: OK\n'

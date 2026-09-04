#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/tui.sh
source "$ROOT_DIR/lib/tui.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_status() {
    local expected="$1"
    shift
    set +e
    "$@"
    local actual=$?
    set -e
    [ "$actual" -eq "$expected" ] || fail "expected status $expected, got $actual: $*"
}

test_forced_backend_selection() {
    local bash_bin tmp_bin

    [ "$(TUI_BACKEND=plain tui_detect_backend)" = "plain" ] || fail "plain backend should be force-selectable"
    [ "$(TUI_BACKEND=dialog tui_detect_backend)" = "dialog" ] || fail "dialog backend should be force-selectable"
    [ "$(TUI_BACKEND=whiptail tui_detect_backend)" = "whiptail" ] || fail "whiptail backend should be force-selectable"

    bash_bin="$(command -v bash)"
    tmp_bin="$(mktemp -d)"
    assert_status 1 env PATH="$tmp_bin" TUI_BACKEND=gum TUI_AUTO_INSTALL_GUM=false GUM=/nonexistent/gum "$bash_bin" -c 'source "$1"; tui_detect_backend >/dev/null' _ "$ROOT_DIR/lib/tui.sh"
    assert_status 1 env TUI_BACKEND=invalid bash -c 'source "$1"; tui_detect_backend >/dev/null' _ "$ROOT_DIR/lib/tui.sh"
    rm -rf "$tmp_bin"
}

test_auto_backend_prefers_gum_and_skips_ncurses() {
    local old_path tmp_bin

    old_path="$PATH"
    tmp_bin="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp_bin/gum"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp_bin/whiptail"
    chmod +x "$tmp_bin/gum" "$tmp_bin/whiptail"

    PATH="$tmp_bin"
    [ "$(GUM=/nonexistent/gum TUI_GUM_BIN='' TUI_AUTO_INSTALL_GUM=false tui_detect_backend)" = "gum" ] || \
        fail "auto backend should prefer gum when it is available"

    PATH="$old_path"
    rm -f "$tmp_bin/gum"
    PATH="$tmp_bin"
    [ "$(GUM=/nonexistent/gum TUI_GUM_BIN='' TUI_AUTO_INSTALL_GUM=false tui_detect_backend)" = "plain" ] || \
        fail "auto backend must not fall back to whiptail/dialog blue-screen UI"
    PATH="$old_path"
    rm -rf "$tmp_bin"
}

test_plain_prompt_defaults() {
    printf '\n' | TUI_BACKEND=plain tui_prompt_yn "Proceed?" true
    assert_status 1 env TUI_BACKEND=plain bash -c 'source "$1"; printf "\n" | tui_prompt_yn "Proceed?" false' _ "$ROOT_DIR/lib/tui.sh"
    assert_status 1 env TUI_BACKEND=plain bash -c 'source "$1"; printf "n\n" | tui_prompt_yn "Proceed?" true' _ "$ROOT_DIR/lib/tui.sh"
    printf 'y\n' | TUI_BACKEND=plain tui_prompt_yn "Proceed?" false
}

test_plain_radiolist_fallback_status() {
    assert_status 1 env TUI_BACKEND=plain bash -c 'source "$1"; tui_radiolist "Title" "Prompt" 10 40 3 "1" "One" on' _ "$ROOT_DIR/lib/tui.sh"
}

main() {
    test_forced_backend_selection
    test_auto_backend_prefers_gum_and_skips_ncurses
    test_plain_prompt_defaults
    test_plain_radiolist_fallback_status
    printf 'tests/test_tui_helpers.sh: OK\n'
}

main "$@"

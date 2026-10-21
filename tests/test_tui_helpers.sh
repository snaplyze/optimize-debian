#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every variable lib/tui.sh reads: the caller's environment must not change the result.
unset TUI_BACKEND GUM TUI_GUM_BIN TUI_GUM_VERSION TUI_AUTO_INSTALL_GUM \
    TUI_PROMPT_PREFIX TUI_RESOLVED_BACKEND OPTIMIZE_SOURCE_ONLY

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

# tui_install_gum downloads one archive and accepts it only with the SHA-256 pinned in
# tui_gum_sha256; checksums.txt from the same release is not consulted.
test_install_gum_checks_the_pinned_sum() {
    local dir serve status
    dir="$(mktemp -d)"
    serve="$dir/serve"
    mkdir -p "$dir/bin" "$serve" "$dir/build"
    cat > "$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry|--retry-delay|--retry-max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[ -f "$SERVE/${url##*/}" ] || exit 22
cat "$SERVE/${url##*/}" > "$out"
EOF
    chmod +x "$dir/bin/curl"
    printf '#!/bin/sh\necho gum\n' > "$dir/build/gum"
    chmod +x "$dir/build/gum"
    tar -czf "$serve/gum_0.17.0_Linux_x86_64.tar.gz" -C "$dir/build" gum

    run_install() {
        PATH="$dir/bin:$PATH" CURL_LOG="$dir/curl.log" SERVE="$serve" GUM="$dir/gum" TUI_GUM_VERSION="$1" bash -c '
            source "$1"
            test_sum="$3"
            tui_gum_asset_arch() { printf "x86_64\n"; }
            if [ "$2" != pinned ]; then
                tui_gum_sha256() { [ "$TUI_GUM_VERSION" = 0.17.0 ] && printf "%s\n" "$test_sum"; }
            fi
            tui_install_gum
        ' _ "$ROOT_DIR/lib/tui.sh" "$2" "${3:-}"
    }

    # The archive matches the sum: gum is installed, and only the archive is downloaded.
    : > "$dir/curl.log"
    run_install 0.17.0 test "$(sha256sum "$serve/gum_0.17.0_Linux_x86_64.tar.gz" | awk '{print $1}')" || fail "gum with the pinned sum must install"
    [ -x "$dir/gum" ] || fail "gum must be installed into GUM"
    [ "$(wc -l < "$dir/curl.log")" -eq 1 ] || fail "only the archive may be downloaded: $(cat "$dir/curl.log")"
    grep -qF -- "--proto =https" "$dir/curl.log" || fail "gum must be downloaded over HTTPS only"
    grep -qF -- "--max-time 300" "$dir/curl.log" || fail "the gum download must be bounded in time"
    grep -qF -- "--retry-max-time 300" "$dir/curl.log" || fail "gum retries must stay within the time limit"
    if grep -q checksums.txt "$dir/curl.log"; then
        fail "checksums.txt must not be consulted"
    fi

    # A substituted archive (the real pinned sum does not match the test archive) is refused.
    rm -f "$dir/gum"
    status=0
    run_install 0.17.0 pinned || status=$?
    [ "$status" -eq 1 ] || fail "an archive that misses the pinned sum must be refused, got $status"
    [ ! -e "$dir/gum" ] || fail "a refused archive must not be installed"

    # A version without a pinned sum is not downloaded at all.
    : > "$dir/curl.log"
    status=0
    run_install 0.18.0 pinned || status=$?
    [ "$status" -eq 1 ] || fail "an unpinned gum version must be refused, got $status"
    [ ! -s "$dir/curl.log" ] || fail "an unpinned gum version must not be downloaded"

    tui_gum_sha256 x86_64 | grep -Eqx '[0-9a-f]{64}' || fail "gum $TUI_GUM_VERSION must be pinned for x86_64"
    rm -rf "$dir"
}

main() {
    test_install_gum_checks_the_pinned_sum
    test_forced_backend_selection
    test_auto_backend_prefers_gum_and_skips_ncurses
    test_plain_prompt_defaults
    test_plain_radiolist_fallback_status
    printf 'tests/test_tui_helpers.sh: OK\n'
}

main "$@"

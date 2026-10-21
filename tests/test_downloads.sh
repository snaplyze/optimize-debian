#!/usr/bin/env bash
# Tests of the download helpers in lib/common.sh: pinned versions and SHA-256 sums, pinned APT
# key fingerprints, bounded downloads. curl is mocked and serves local files; gpg, tar and unzip
# are real. The embedded copies in optimize_*.sh are compared with lib/ by
# tests/test_embedded_copies.sh, so these tests cover the copies too.
# Some tests narrow PATH inside a command substitution on purpose (SC2030, SC2031).
# shellcheck disable=SC1091,SC2034,SC2030,SC2031
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

TEST_DIR="$(mktemp -d)"
GNUPG_TEST_HOME=""
cleanup() {
    if [ -n "$GNUPG_TEST_HOME" ]; then
        GNUPGHOME="$GNUPG_TEST_HOME" gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    fi
    rm -rf "${TEST_DIR:-}"
}
trap cleanup EXIT

MOCK_BIN="$TEST_DIR/bin"
SYS_BIN="$TEST_DIR/sysbin"
MOCK_STATE="$TEST_DIR/state"
SERVE="$TEST_DIR/serve"
CURL_LOG="$MOCK_STATE/curl.log"
MSGS="$MOCK_STATE/messages.log"
REAL_PATH="$PATH"
MOCK_ARCH=amd64
# A well-formed SHA-256 that no test file has.
WRONG_SUM="$(printf '%064d' 0)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Output helpers the scripts define; the lib functions call them.
log() { printf 'LOG: %s\n' "$1" >> "$MSGS"; }
warn() { printf 'WARN: %s\n' "$1" >> "$MSGS"; }
error() { printf 'ERROR: %s\n' "$1" >> "$MSGS"; }
info() { printf 'INFO: %s\n' "$1" >> "$MSGS"; }

make_mocks() {
    local tool

    mkdir -p "$MOCK_BIN" "$SYS_BIN"
    # curl logs its arguments and writes $SERVE/<last URL segment> to the -o file; a
    # <name>.fail file there makes that download fail.
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_STATE/curl.log"
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry|--retry-delay|--retry-max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
name="${url##*/}"
[ ! -e "$SERVE/$name.fail" ] && [ -f "$SERVE/$name" ] || exit 22
cat "$SERVE/$name" > "$out"
EOF
    cat > "$MOCK_BIN/dpkg" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --print-architecture ] && printf '%s\n' "$MOCK_ARCH"
EOF
    chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/dpkg"
    # A search path with the tools the helpers need and nothing else (no starship).
    for tool in awk bash cat chmod gzip install mkdir mktemp mv rm sha256sum tar unzip; do
        ln -s "$(command -v "$tool")" "$SYS_BIN/$tool"
    done
}

reset_state() {
    rm -rf "$MOCK_STATE" "$SERVE"
    mkdir -p "$MOCK_STATE" "$SERVE"
    : > "$CURL_LOG"
    : > "$MSGS"
    MOCK_ARCH=amd64
    unset COMMON_DOWNLOAD_CONNECT_TIMEOUT COMMON_DOWNLOAD_MAX_TIME COMMON_DOWNLOAD_RETRIES COMMON_STARSHIP_BIN
}

assert_msg() {
    grep -qF -- "$1" "$MSGS" || fail "expected message '$1', got: $(cat "$MSGS")"
}

sha() {
    sha256sum "$1" | awk '{print $1}'
}

run_status() {
    local status=0
    "$@" >/dev/null 2>&1 || status=$?
    printf '%s\n' "$status"
}

# Runs "$@" with common_pinned_download answering <url> <sha256> for every tool. The names are
# unlike the lib's locals: bash scoping is dynamic, and the mock runs inside the lib functions.
with_pin() {
    local with_pin_url="$1" with_pin_sum="$2"
    shift 2
    (
        # shellcheck disable=SC2329 # Invoked by the lib functions under test.
        common_pinned_download() { printf '%s %s\n' "$with_pin_url" "$with_pin_sum"; }
        "$@"
    )
}

test_download_is_bounded_and_https_only() {
    reset_state
    printf 'payload\n' > "$SERVE/file.txt"
    common_download https://example.test/file.txt "$TEST_DIR/out.txt" || fail "a served file must download"
    grep -qF -- "--proto =https --proto-redir =https" "$CURL_LOG" || fail "downloads must stay on HTTPS: $(cat "$CURL_LOG")"
    grep -qF -- "--connect-timeout 20 --max-time 900 --retry 3 --retry-delay 3 --retry-max-time 900" "$CURL_LOG" || \
        fail "downloads and their retries must be bounded: $(cat "$CURL_LOG")"

    : > "$CURL_LOG"
    COMMON_DOWNLOAD_CONNECT_TIMEOUT=1 COMMON_DOWNLOAD_MAX_TIME=2 COMMON_DOWNLOAD_RETRIES=0 \
        common_download https://example.test/file.txt "$TEST_DIR/out.txt"
    grep -qF -- "--connect-timeout 1 --max-time 2 --retry 0 --retry-delay 3 --retry-max-time 2" "$CURL_LOG" || \
        fail "the limits must be adjustable: $(cat "$CURL_LOG")"
}

# The real curl against a local port that accepts connections and never answers: the download
# fails within the time limit instead of hanging (PERF-3).
test_download_gives_up_on_a_silent_server() {
    local pid port started elapsed status

    command -v python3 >/dev/null 2>&1 || fail "python3 is required for the silent server test"
    python3 -I -c '
import socket, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
print(s.getsockname()[1], flush=True)
held = []
end = time.time() + 20
while time.time() < end:
    s.settimeout(max(0.1, end - time.time()))
    try:
        held.append(s.accept()[0])
    except OSError:
        pass
' > "$TEST_DIR/port" &
    pid=$!
    for _ in $(seq 1 50); do
        [ -s "$TEST_DIR/port" ] && break
        sleep 0.1
    done
    port="$(cat "$TEST_DIR/port")"
    [ -n "$port" ] || fail "the silent server did not start"

    # curl counts the TLS handshake into the connection time: the connection limit applies...
    started="$SECONDS"
    status="$(PATH="$REAL_PATH" COMMON_DOWNLOAD_CONNECT_TIMEOUT=1 COMMON_DOWNLOAD_MAX_TIME=60 COMMON_DOWNLOAD_RETRIES=0 \
        run_status common_download "https://127.0.0.1:$port/file" "$TEST_DIR/silent.out")"
    elapsed=$((SECONDS - started))
    [ "$status" = 28 ] || fail "a silent server must time out (curl status 28), got $status"
    [ "$elapsed" -le 4 ] || fail "the connection limit must stop the download, took ${elapsed}s"

    # ...and the total limit applies on its own.
    started="$SECONDS"
    status="$(PATH="$REAL_PATH" COMMON_DOWNLOAD_CONNECT_TIMEOUT=60 COMMON_DOWNLOAD_MAX_TIME=1 COMMON_DOWNLOAD_RETRIES=0 \
        run_status common_download "https://127.0.0.1:$port/file" "$TEST_DIR/silent.out")"
    elapsed=$((SECONDS - started))
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ "$status" = 28 ] || fail "a silent server must time out (curl status 28), got $status"
    [ "$elapsed" -le 4 ] || fail "the total limit must stop the download, took ${elapsed}s"
}

test_fetch_verified() {
    local good status

    reset_state
    printf 'release\n' > "$SERVE/tool.tar.gz"
    good="$(sha "$SERVE/tool.tar.gz")"
    common_fetch_verified https://example.test/tool.tar.gz "$good" "$TEST_DIR/tool.tar.gz" || fail "a matching download must be accepted"
    cmp -s "$SERVE/tool.tar.gz" "$TEST_DIR/tool.tar.gz" || fail "the accepted download must reach the target"

    # A substituted file never reaches the target.
    rm -f "$TEST_DIR/tool.tar.gz"
    printf 'substituted\n' > "$SERVE/tool.tar.gz"
    status="$(run_status common_fetch_verified https://example.test/tool.tar.gz "$good" "$TEST_DIR/tool.tar.gz")"
    [ "$status" = 1 ] || fail "a checksum mismatch must fail, got $status"
    [ ! -e "$TEST_DIR/tool.tar.gz" ] || fail "a substituted download must not reach the target"
    assert_msg "Checksum mismatch for https://example.test/tool.tar.gz"

    : > "$SERVE/tool.tar.gz.fail"
    status="$(run_status common_fetch_verified https://example.test/tool.tar.gz "$good" "$TEST_DIR/tool.tar.gz")"
    [ "$status" = 1 ] || fail "a failed download must fail, got $status"
    assert_msg "Download failed: https://example.test/tool.tar.gz"

    # A malformed sum is refused before any download.
    : > "$CURL_LOG"
    status="$(run_status common_fetch_verified https://example.test/tool.tar.gz "${good^^}" "$TEST_DIR/tool.tar.gz")"
    [ "$status" = 1 ] || fail "a malformed sum must fail, got $status"
    [ ! -s "$CURL_LOG" ] || fail "a malformed sum must not download"
}

test_pins() {
    local tool arch pin url sum

    for tool in starship fnm go; do
        for arch in amd64 arm64; do
            pin="$(common_pinned_download "$tool" "$arch")" || fail "$tool must be pinned for $arch"
            read -r url sum <<<"$pin"
            [[ "$url" == https://* ]] || fail "$tool $arch must be an HTTPS URL: $url"
            [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || fail "$tool $arch must have a SHA-256: $sum"
        done
    done
    for tool in cuda-keyring-debian12 cuda-keyring-debian13; do
        common_pinned_download "$tool" amd64 >/dev/null || fail "$tool must be pinned for amd64"
    done
    if common_pinned_download starship armhf >/dev/null; then
        fail "an unpinned architecture must return 1"
    fi
    for tool in docker nvidia-container-toolkit; do
        pin="$(common_apt_key_pin "$tool")" || fail "the $tool key must be pinned"
        read -r url sum <<<"$pin"
        [[ "$url" == https://* ]] || fail "the $tool key must come over HTTPS: $url"
        [[ "$sum" =~ ^[0-9A-F]{40}$ ]] || fail "the $tool key must have a full fingerprint: $sum"
    done
}

test_fetch_pinned_binary() {
    local status

    reset_state
    mkdir -p "$TEST_DIR/build" "$TEST_DIR/out1" "$TEST_DIR/out2" "$TEST_DIR/out3" "$TEST_DIR/out4"
    # A tar.gz with the binary at its top level, as starship publishes it.
    printf '#!/bin/sh\necho starship\n' > "$TEST_DIR/build/starship"
    tar -czf "$SERVE/starship.tar.gz" -C "$TEST_DIR/build" starship
    with_pin https://example.test/starship.tar.gz "$(sha "$SERVE/starship.tar.gz")" \
        common_fetch_pinned_binary starship "$TEST_DIR/out1" || fail "a pinned tar.gz must be extracted"
    [ -x "$TEST_DIR/out1/starship" ] || fail "the extracted binary must be executable"
    [ "$(ls -A "$TEST_DIR/out1")" = starship ] || fail "only the binary may stay: $(ls -A "$TEST_DIR/out1")"

    # A zip, as fnm publishes it.
    printf 'fnm binary\n' > "$TEST_DIR/build/fnm"
    (cd "$TEST_DIR/build" && python3 -I -c 'import zipfile; z = zipfile.ZipFile("../serve/fnm.zip", "w"); z.write("fnm"); z.close()')
    with_pin https://example.test/fnm.zip "$(sha "$SERVE/fnm.zip")" \
        common_fetch_pinned_binary fnm "$TEST_DIR/out2" || fail "a pinned zip must be extracted"
    [ "$(cat "$TEST_DIR/out2/fnm")" = "fnm binary" ] || fail "the zip binary must be extracted"
    [ -x "$TEST_DIR/out2/fnm" ] || fail "the zip binary must be executable"

    # A substituted archive is not extracted.
    status="$(with_pin https://example.test/fnm.zip "$WRONG_SUM" run_status common_fetch_pinned_binary fnm "$TEST_DIR/out3")"
    [ "$status" = 1 ] || fail "a substituted archive must fail, got $status"
    [ -z "$(ls -A "$TEST_DIR/out3")" ] || fail "a substituted archive must leave nothing: $(ls -A "$TEST_DIR/out3")"

    # No pin for the architecture: nothing is downloaded.
    MOCK_ARCH=armhf
    : > "$CURL_LOG"
    status="$(run_status common_fetch_pinned_binary starship "$TEST_DIR/out4")"
    [ "$status" = 1 ] || fail "an unpinned architecture must fail, got $status"
    assert_msg "No pinned starship release for architecture armhf"
    [ ! -s "$CURL_LOG" ] || fail "an unpinned architecture must not download"
}

test_install_starship() {
    local status

    reset_state
    mkdir -p "$TEST_DIR/build"
    printf '#!/bin/sh\necho starship\n' > "$TEST_DIR/build/starship"
    tar -czf "$SERVE/starship.tar.gz" -C "$TEST_DIR/build" starship
    COMMON_STARSHIP_BIN="$TEST_DIR/usr-local-bin-starship"

    # No Debian package: the pinned release binary is installed.
    status="$(
        PATH="$MOCK_BIN:$SYS_BIN"
        # shellcheck disable=SC2329 # Invoked by common_install_starship.
        common_package_available() { return 1; }
        with_pin https://example.test/starship.tar.gz "$(sha "$SERVE/starship.tar.gz")" run_status common_install_starship
    )"
    [ "$status" = 0 ] || fail "the pinned starship must install, got $status"
    [ -x "$COMMON_STARSHIP_BIN" ] || fail "starship must be installed into COMMON_STARSHIP_BIN"

    # The Debian package is preferred: no download.
    rm -f "$COMMON_STARSHIP_BIN"
    : > "$CURL_LOG"
    status="$(
        PATH="$MOCK_BIN:$SYS_BIN"
        # shellcheck disable=SC2329 # Invoked by common_install_starship.
        common_package_available() { [ "$1" = starship ]; }
        # shellcheck disable=SC2329 # Invoked by common_install_starship.
        common_safe_install() { printf '#!/bin/sh\n' > "$MOCK_BIN/starship"; chmod +x "$MOCK_BIN/starship"; }
        run_status common_install_starship
    )"
    rm -f "$MOCK_BIN/starship"
    [ "$status" = 0 ] || fail "the Debian package must be enough, got $status"
    [ ! -s "$CURL_LOG" ] || fail "the Debian package must not download the release: $(cat "$CURL_LOG")"
    [ ! -e "$COMMON_STARSHIP_BIN" ] || fail "the release binary must not be installed next to the package"

    # A substituted release is not installed.
    status="$(
        PATH="$MOCK_BIN:$SYS_BIN"
        # shellcheck disable=SC2329 # Invoked by common_install_starship.
        common_package_available() { return 1; }
        with_pin https://example.test/starship.tar.gz "$WRONG_SUM" run_status common_install_starship
    )"
    [ "$status" = 1 ] || fail "a substituted starship must fail, got $status"
    [ ! -e "$COMMON_STARSHIP_BIN" ] || fail "a substituted starship must not be installed"
}

test_install_go() {
    local prefix="$TEST_DIR/usr-local" status
    local had_tmpdir="${TMPDIR+set}" old_tmpdir="${TMPDIR:-}"

    reset_state
    # Downloading and unpacking happen inside the prefix, not in TMPDIR (noexec or RAM-backed):
    # a read-only TMPDIR must not matter (for a user; root writes anyway).
    mkdir -p "$TEST_DIR/tmpdir"
    chmod 555 "$TEST_DIR/tmpdir"
    export TMPDIR="$TEST_DIR/tmpdir"
    mkdir -p "$TEST_DIR/gobuild/go/bin" "$prefix/go"
    printf '#!/bin/sh\necho go1.0\n' > "$TEST_DIR/gobuild/go/bin/go"
    chmod +x "$TEST_DIR/gobuild/go/bin/go"
    tar -czf "$SERVE/go.tar.gz" -C "$TEST_DIR/gobuild" go
    printf 'old\n' > "$prefix/go/OLD"

    # A substituted archive leaves the installed Go as it was.
    status="$(with_pin https://example.test/go.tar.gz "$WRONG_SUM" run_status common_install_go "$prefix")"
    [ "$status" = 1 ] || fail "a substituted Go archive must fail, got $status"
    [ -f "$prefix/go/OLD" ] || fail "a failed installation must keep the installed Go"

    with_pin https://example.test/go.tar.gz "$(sha "$SERVE/go.tar.gz")" common_install_go "$prefix" || fail "the pinned Go must install"
    [ -x "$prefix/go/bin/go" ] || fail "go must be installed into <prefix>/go"
    [ ! -e "$prefix/go/OLD" ] || fail "the earlier Go must be replaced"
    [ -z "$(ls -A "$TEST_DIR/tmpdir")" ] || fail "Go must not be unpacked in TMPDIR: $(ls -A "$TEST_DIR/tmpdir")"
    [ "$(ls -A "$prefix")" = go ] || fail "no work directory may stay in the prefix: $(ls -A "$prefix")"

    # The new tree cannot be moved in: the installed Go is put back.
    printf 'kept\n' > "$prefix/go/KEPT"
    status="$(
        # shellcheck disable=SC2329 # Invoked by common_install_go.
        mv() {
            if [ "${2:-}" = "$prefix/go" ] && [ ! -e "$TEST_DIR/mv-failed" ]; then
                : > "$TEST_DIR/mv-failed"
                return 1
            fi
            command mv "$@"
        }
        with_pin https://example.test/go.tar.gz "$(sha "$SERVE/go.tar.gz")" run_status common_install_go "$prefix"
    )"
    [ "$status" = 1 ] || fail "a failed swap must fail, got $status"
    [ -f "$prefix/go/KEPT" ] || fail "a failed swap must put the installed Go back"
    [ "$(ls -A "$prefix")" = go ] || fail "a failed swap must leave no work directory: $(ls -A "$prefix")"
    rm -f "$prefix/go/KEPT"

    # An archive with a go directory but without go/bin/go is refused and the installed Go stays.
    mkdir -p "$TEST_DIR/brokenbuild/go"
    printf 'no binary\n' > "$TEST_DIR/brokenbuild/go/README"
    tar -czf "$SERVE/go.tar.gz" -C "$TEST_DIR/brokenbuild" go
    status="$(with_pin https://example.test/go.tar.gz "$(sha "$SERVE/go.tar.gz")" run_status common_install_go "$prefix")"
    [ "$status" = 1 ] || fail "an archive without go/bin/go must fail, got $status"
    [ -x "$prefix/go/bin/go" ] || fail "a refused archive must keep the installed Go"

    # Neither the new tree nor the old one can be moved to <prefix>/go: the old tree stays in the
    # work directory the message names, and the exit cleanup leaves it there.
    tar -czf "$SERVE/go.tar.gz" -C "$TEST_DIR/gobuild" go
    status="$(
        # shellcheck disable=SC2329 # Invoked by common_install_go.
        mv() {
            [ "${2:-}" != "$prefix/go" ] || return 1
            command mv "$@"
        }
        # In this shell, not in with_pin's subshell: the exit cleanup must see the registration.
        go_sum="$(sha "$SERVE/go.tar.gz")"
        # shellcheck disable=SC2329 # Invoked by common_install_go.
        common_pinned_download() { printf '%s %s\n' https://example.test/go.tar.gz "$go_sum"; }
        common_install_go "$prefix" >/dev/null 2>&1 || true
        common_remove_temp_dirs
        ls -d "$prefix"/.optimize.*/go.previous/bin/go
    )" || fail "the previous Go must survive a failed swap and the exit cleanup"
    [ -x "$status" ] || fail "the previous Go must stay where the message says: $status"
    assert_msg "Could not put the previous Go back; it is in $prefix/.optimize."
    rm -rf "$prefix"/.optimize.*

    chmod 755 "$TEST_DIR/tmpdir"
    if [ -n "$had_tmpdir" ]; then
        export TMPDIR="$old_tmpdir"
    else
        unset TMPDIR
    fi
}

# SEC-2: a temporary directory goes away when the script exits, also when it is killed.
test_temp_dirs_are_removed_on_exit() {
    local dir sig

    for sig in TERM INT; do
        # The subshell, which waits for bash -c because of `|| true`, keeps the shell's report of
        # the killed process out of the output.
        (
            bash -c '
                source "$1"
                common_temp_dir work "$2"
                printf "%s\n" "$work" > "$2/created"
                kill -s "$3" $$
                sleep 5
            ' _ "$ROOT_DIR/lib/common.sh" "$TEST_DIR" "$sig" </dev/null || true
        ) 2>/dev/null
        dir="$(cat "$TEST_DIR/created")"
        [ -n "$dir" ] && [ ! -e "$dir" ] || fail "a temporary directory must be removed when the script gets SIG$sig: $dir"
    done

    # A normal exit, and an EXIT trap of the caller that stays in place (the directory sits in
    # TEST_DIR, as the caller's trap does not remove it).
    bash -c '
        source "$1"
        trap "printf caller > \"$2/caller-trap\"" EXIT
        common_temp_dir work "$2"
        printf "%s\n" "$work" > "$2/created"
    ' _ "$ROOT_DIR/lib/common.sh" "$TEST_DIR" </dev/null
    [ "$(cat "$TEST_DIR/caller-trap")" = caller ] || fail "the caller's EXIT trap must stay"
    bash -c '
        source "$1"
        common_temp_dir work "$2"
        printf "%s\n" "$work" > "$2/created"
    ' _ "$ROOT_DIR/lib/common.sh" "$TEST_DIR" </dev/null
    dir="$(cat "$TEST_DIR/created")"
    [ ! -e "$dir" ] || fail "a temporary directory must be removed on exit: $dir"
}

# A real key made for the test: the helper must accept exactly the pinned primary key.
test_install_apt_key() {
    local fpr other status

    if ! command -v gpg >/dev/null 2>&1; then
        printf 'SKIP: APT key cases: gpg is not installed\n'
        return 0
    fi
    reset_state
    GNUPG_TEST_HOME="$TEST_DIR/gnupg"
    mkdir -m 700 "$GNUPG_TEST_HOME"
    for uid in "Pinned <pinned@example.invalid>" "Other <other@example.invalid>"; do
        GNUPGHOME="$GNUPG_TEST_HOME" gpg --batch --quiet --passphrase '' --quick-gen-key "$uid" ed25519 sign never 2>/dev/null
    done
    fpr="$(GNUPGHOME="$GNUPG_TEST_HOME" gpg --with-colons --list-keys pinned@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    other="$(GNUPGHOME="$GNUPG_TEST_HOME" gpg --with-colons --list-keys other@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    GNUPGHOME="$GNUPG_TEST_HOME" gpg --armor --export pinned@example.invalid > "$SERVE/pinned.asc"
    GNUPGHOME="$GNUPG_TEST_HOME" gpg --armor --export other@example.invalid > "$SERVE/other.asc"
    GNUPGHOME="$GNUPG_TEST_HOME" gpg --armor --export pinned@example.invalid other@example.invalid > "$SERVE/both.asc"

    # Names unlike the lib's locals, as in with_pin.
    run_key() {
        local run_key_url="$1" run_key_fpr="$2"
        shift 2
        (
            # shellcheck disable=SC2329 # Invoked by common_install_apt_key.
            common_apt_key_pin() { printf '%s %s\n' "$run_key_url" "$run_key_fpr"; }
            "$@"
        )
    }

    run_key https://example.test/pinned.asc "$fpr" common_install_apt_key test "$TEST_DIR/test.gpg" || fail "the pinned key must be accepted"
    [ "$(head -c 5 "$TEST_DIR/test.gpg")" != "-----" ] || fail "a .gpg keyring must hold the binary key"
    [ "$(stat -c %a "$TEST_DIR/test.gpg")" = 644 ] || fail "the keyring must be readable by apt"
    gpg --show-keys --with-colons "$TEST_DIR/test.gpg" 2>/dev/null | grep -q "^fpr:::::::::$fpr:" || fail "the keyring must hold the pinned key"

    run_key https://example.test/pinned.asc "$fpr" common_install_apt_key test "$TEST_DIR/test.asc" || fail "the pinned key must be accepted as .asc"
    cmp -s "$SERVE/pinned.asc" "$TEST_DIR/test.asc" || fail "a .asc keyring must hold the armored key as downloaded"

    # Another key, or the pinned key next to another one, is refused and nothing is written.
    status="$(run_key https://example.test/other.asc "$fpr" run_status common_install_apt_key test "$TEST_DIR/other.gpg")"
    [ "$status" = 1 ] || fail "another key must be refused, got $status"
    [ ! -e "$TEST_DIR/other.gpg" ] || fail "a refused key must not be written"
    assert_msg "has fingerprint $other, expected $fpr"
    status="$(run_key https://example.test/both.asc "$fpr" run_status common_install_apt_key test "$TEST_DIR/both.gpg")"
    [ "$status" = 1 ] || fail "a file with an extra key must be refused, got $status"
    [ ! -e "$TEST_DIR/both.gpg" ] || fail "a refused key file must not be written"

    : > "$SERVE/pinned.asc.fail"
    status="$(run_key https://example.test/pinned.asc "$fpr" run_status common_install_apt_key test "$TEST_DIR/fail.gpg")"
    [ "$status" = 1 ] || fail "a failed download must fail, got $status"
    status="$(run_status common_install_apt_key unknown-key "$TEST_DIR/unknown.gpg")"
    [ "$status" = 1 ] || fail "an unknown key name must fail, got $status"
}

main() {
    make_mocks
    PATH="$MOCK_BIN:$PATH"
    export MOCK_STATE SERVE MOCK_ARCH

    test_download_is_bounded_and_https_only
    test_download_gives_up_on_a_silent_server
    test_fetch_verified
    test_pins
    test_fetch_pinned_binary
    test_install_starship
    test_install_go
    test_temp_dirs_are_removed_on_exit
    test_install_apt_key
    printf 'tests/test_downloads.sh: OK\n'
}

main "$@"

#!/usr/bin/env bash
# Tests of the APT helpers in lib/common.sh with mocked apt-get and apt-cache.
# The embedded copies of these functions in optimize_*.sh are compared with lib/ by
# tests/test_embedded_copies.sh, so these tests cover the copies too.
# COMMON_APT_* variables set here are read by the sourced lib functions.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR:-}"' EXIT

MOCK_BIN="$TEST_DIR/bin"
MOCK_STATE="$TEST_DIR/state"
APT_LOG="$MOCK_STATE/apt-get.log"
CACHE_LOG="$MOCK_STATE/apt-cache.log"
MSGS="$MOCK_STATE/messages.log"
SILENT_LOG="$MOCK_STATE/silent.log"
SLEEP_LOG="$MOCK_STATE/sleep.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Output helpers the scripts define; the lib functions call them.
log() { printf 'LOG: %s\n' "$1" >> "$MSGS"; }
warn() { printf 'WARN: %s\n' "$1" >> "$MSGS"; }
error() { printf 'ERROR: %s\n' "$1" >> "$MSGS"; }
info() { printf 'INFO: %s\n' "$1" >> "$MSGS"; }
progress() { printf 'PROGRESS: %s\n' "$1" >> "$MSGS"; }
log_silent() { printf '%s\n' "$1" >> "$SILENT_LOG"; }
# No real waiting: the delay is recorded and counted as elapsed time.
sleep() {
    printf '%s\n' "$1" >> "$SLEEP_LOG"
    SECONDS=$((SECONDS + $1))
}

make_mocks() {
    mkdir -p "$MOCK_BIN" "$MOCK_STATE"

    # Behaviour is controlled by files in $MOCK_STATE:
    #   update_lock_busy  number of apt-get update calls that still fail on the lists lock
    #   update_fail       apt-get update fails with a repository error
    #   install_lock_busy apt-get install fails on the dpkg lock unless DPkg::Lock::Timeout is passed
    #   install_lock_stuck apt-get install fails on the dpkg lock even with DPkg::Lock::Timeout
    #   install_lock_after number of installations with packages before the dpkg lock gets stuck
    #   install_fail      packages (one per line) whose installation fails
    cat > "$MOCK_BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
state="${MOCK_STATE:?}"
printf '%s\n' "$*" >> "$state/apt-get.log"
printf '%s\n' "${DEBIAN_FRONTEND:-unset}" >> "$state/frontend.log"
args=" $* "
case "$args" in
    *" update "*)
        if [ -s "$state/update_lock_busy" ]; then
            left="$(cat "$state/update_lock_busy")"
            if [ "$left" -gt 0 ]; then
                printf '%s\n' $((left - 1)) > "$state/update_lock_busy"
                printf 'E: Could not get lock /var/lib/apt/lists/lock. It is held by process 42 (apt-get)\n'
                printf 'E: Unable to lock directory /var/lib/apt/lists/\n'
                exit 100
            fi
        fi
        if [ -e "$state/update_fail" ]; then
            printf 'Err:1 http://example.invalid/debian bookworm InRelease\n'
            printf 'E: The repository is not signed.\n'
            exit 100
        fi
        printf 'Hit:1 http://deb.debian.org/debian bookworm InRelease\n'
        ;;
    *" install "*)
        if [ -s "$state/install_lock_after" ] && [[ "$args" != *" install -y " ]]; then
            left="$(cat "$state/install_lock_after")"
            printf '%s\n' $((left - 1)) > "$state/install_lock_after"
            [ "$left" -le 0 ] && : > "$state/install_lock_stuck"
        fi
        if [ -e "$state/install_lock_stuck" ] || { [ -e "$state/install_lock_busy" ] && [[ "$args" != *"DPkg::Lock::Timeout="* ]]; }; then
            if [ "${LC_ALL:-}" != C ] && [[ "${LANG:-}" == ru* ]]; then
                printf 'E: Не удалось получить доступ к файлу блокировки /var/lib/dpkg/lock-frontend\n'
            else
                printf 'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 42 (aptitude)\n'
            fi
            exit 100
        fi
        if [ -s "$state/install_fail" ]; then
            while IFS= read -r pkg; do
                if [[ "$args" == *" $pkg "* ]]; then
                    printf 'E: Sub-process /usr/bin/dpkg returned an error code (1) for %s\n' "$pkg"
                    exit 100
                fi
            done < "$state/install_fail"
        fi
        printf 'Setting up packages\n'
        ;;
esac
EOF

    #   unavailable          packages without a candidate in any release
    #   unavailable_release  packages that bookworm-backports does not provide (bookworm does)
    #   installed            packages already installed (Installed: 1.0, Candidate: 2.0)
    #   dpkg_versions        "package version" lines: what dpkg-query reports as installed
    cat > "$MOCK_BIN/apt-cache" <<'EOF'
#!/usr/bin/env bash
state="${MOCK_STATE:?}"
printf '%s\n' "$*" >> "$state/apt-cache.log"
pkg="${2:-}"
listed() { [ -e "$state/$1" ] && grep -qxF "$pkg" "$state/$1"; }
case "${1:-}" in
    madison)
        listed unavailable && exit 0
        printf ' %s |        1.0 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' "$pkg"
        listed unavailable_release || \
            printf ' %s | 2.0~bpo12+1 | http://deb.debian.org/debian bookworm-backports/main amd64 Packages\n' "$pkg"
        exit 0
        ;;
    policy) ;;
    *) exit 2 ;;
esac
printf '%s:\n' "$pkg"
if listed unavailable; then
    printf '  Installed: (none)\n  Candidate: (none)\n  Version table:\n'
elif listed installed; then
    printf '  Installed: 1.0\n  Candidate: 2.0\n  Version table:\n'
else
    printf '  Installed: (none)\n  Candidate: 1.0\n  Version table:\n'
fi
EOF
    cat > "$MOCK_BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
state="${MOCK_STATE:?}"
pkg="${!#}"
[ -e "$state/dpkg_versions" ] || exit 1
version="$(awk -v p="$pkg" '$1 == p { print $2 }' "$state/dpkg_versions")"
[ -n "$version" ] || exit 1
printf '%s' "$version"
EOF
    chmod +x "$MOCK_BIN/apt-get" "$MOCK_BIN/apt-cache" "$MOCK_BIN/dpkg-query"
}

reset_state() {
    rm -rf "$MOCK_STATE"
    mkdir -p "$MOCK_STATE"
    : > "$APT_LOG"
    : > "$CACHE_LOG"
    : > "$MSGS"
    : > "$SILENT_LOG"
    : > "$SLEEP_LOG"
    unset COMMON_APT_INDEX_FRESH COMMON_APT_LOCK_TIMEOUT COMMON_APT_UPDATE_RETRY_DELAY \
        COMMON_APT_UPDATE_ATTEMPTS COMMON_APT_UPDATE_CHECK
    hash -r
}

count_apt() {
    # Number of apt-get calls whose command is $1; "install" counts installations of
    # packages, not the lock waits (install -y without packages).
    if [ "$1" = install ]; then
        grep -c -- " install -y ." "$APT_LOG" || true
    else
        grep -c -- " $1\( \|\$\)" "$APT_LOG" || true
    fi
}

assert_msg() {
    grep -qF -- "$1" "$MSGS" || fail "expected message '$1', got: $(cat "$MSGS")"
}

refute_msg() {
    if grep -qF -- "$1" "$MSGS"; then
        fail "unexpected message '$1': $(cat "$MSGS")"
    fi
}

run_status() {
    local status=0
    "$@" >/dev/null || status=$?
    printf '%s\n' "$status"
}

test_install_failure_returns_one() {
    local status

    reset_state
    printf 'bad\n' > "$MOCK_STATE/install_fail"
    status="$(run_status common_safe_install good bad)"
    [ "$status" = 1 ] || fail "a failed installation must return 1, got $status"
    refute_msg "Packages installed successfully"
    assert_msg "Failed to install: bad"
    assert_msg "Package installation incomplete: bad"
    # One call for both packages, then one per package.
    grep -qF -- "install -y good bad" "$APT_LOG" || fail "packages must be installed in one call first: $(cat "$APT_LOG")"
    grep -q -- "install -y good$" "$APT_LOG" || fail "the retry must install good alone: $(cat "$APT_LOG")"
    grep -q -- "install -y bad$" "$APT_LOG" || fail "the retry must install bad alone: $(cat "$APT_LOG")"
    grep -qF "Sub-process /usr/bin/dpkg" "$SILENT_LOG" || fail "apt output must go to the log"

    reset_state
    status="$(run_status common_safe_install good other)"
    [ "$status" = 0 ] || fail "a successful installation must return 0, got $status"
    assert_msg "Packages installed successfully"
    [ "$(count_apt install)" = 1 ] || fail "available packages must be installed in one call: $(cat "$APT_LOG")"
}

test_release_is_passed_to_apt() {
    local status

    reset_state
    status="$(run_status common_safe_install -t bookworm-backports linux-image-amd64 linux-headers-amd64)"
    [ "$status" = 0 ] || fail "installation from a release must succeed, got $status"
    grep -q -- "install -y -t bookworm-backports linux-image-amd64 linux-headers-amd64$" "$APT_LOG" || \
        fail "apt-get install must get -t and only the packages: $(cat "$APT_LOG")"
    grep -qx -- "madison linux-image-amd64" "$CACHE_LOG" || \
        fail "availability in the release must come from apt-cache madison: $(cat "$CACHE_LOG")"
    grep -qx -- "madison linux-headers-amd64" "$CACHE_LOG" || \
        fail "every package must be looked up in the release: $(cat "$CACHE_LOG")"
    refute_msg "Unavailable"
    assert_msg "Packages installed successfully from bookworm-backports"

    # An installed package is not skipped: apt upgrades it to the version of the release.
    reset_state
    printf 'linux-image-amd64\n' > "$MOCK_STATE/installed"
    common_safe_install -t bookworm-backports linux-image-amd64
    grep -q -- "install -y -t bookworm-backports linux-image-amd64$" "$APT_LOG" || \
        fail "an installed package must still be passed to apt-get install: $(cat "$APT_LOG")"

    # A package missing from the release is reported for that release and not installed, even
    # though the default release has it (apt-cache -t <release> policy would still show a candidate).
    reset_state
    printf 'linux-headers-amd64\n' > "$MOCK_STATE/unavailable_release"
    status="$(run_status common_safe_install -t bookworm-backports linux-image-amd64 linux-headers-amd64)"
    [ "$status" = 0 ] || fail "a package missing from the release is a warning, got status $status"
    assert_msg "Unavailable packages in bookworm-backports: linux-headers-amd64"
    grep -q -- "install -y -t bookworm-backports linux-image-amd64$" "$APT_LOG" || \
        fail "only the available package must be installed: $(cat "$APT_LOG")"

    # -t without a release is a usage error.
    reset_state
    status="$(run_status common_safe_install -t)"
    [ "$status" = 1 ] || fail "-t without a release must return 1, got $status"
    [ "$(count_apt install)" = 0 ] || fail "nothing may be installed without a release name"

    # An unknown release is not a package list: nothing is installed, the status stays 0.
    reset_state
    status="$(run_status common_safe_install -t nosuchrelease pkg)"
    [ "$status" = 0 ] || fail "an unknown release makes packages unavailable, got $status"
    assert_msg "Unavailable packages in nosuchrelease: pkg"
}

test_unavailable_packages_warn() {
    local status

    reset_state
    printf 'missing\n' > "$MOCK_STATE/unavailable"
    status="$(run_status common_safe_install ok missing)"
    [ "$status" = 0 ] || fail "an unavailable package is not an error, got $status"
    assert_msg "WARN: Unavailable packages: missing"
    grep -q -- "install -y ok$" "$APT_LOG" || fail "only the available package must be installed: $(cat "$APT_LOG")"
    if grep -q -- "missing" "$APT_LOG"; then
        fail "the unavailable package must not reach apt-get install"
    fi

    reset_state
    printf 'missing\n' > "$MOCK_STATE/unavailable"
    status="$(run_status common_safe_install missing)"
    [ "$status" = 0 ] || fail "only unavailable packages: status 0 expected, got $status"
    [ "$(count_apt install)" = 0 ] || fail "nothing is installed when nothing is available"
    refute_msg "Packages installed successfully"

    reset_state
    status="$(run_status common_safe_install)"
    [ "$status" = 0 ] || fail "no packages: status 0 expected, got $status"
    [ "$(count_apt update)" = 0 ] || fail "no packages must not refresh the index"
}

test_package_available() {
    reset_state
    common_package_available present || fail "a package with a candidate must be available"
    printf 'absent\n' > "$MOCK_STATE/unavailable"
    if common_package_available absent; then
        fail "a package with Candidate: (none) must not be available"
    fi
    if common_package_available ""; then
        fail "an empty package name must not be available"
    fi
    : > "$CACHE_LOG"
    common_package_available present
    [ "$(wc -l < "$CACHE_LOG")" = 1 ] || fail "one apt-cache call per package expected: $(cat "$CACHE_LOG")"
    grep -qx -- "policy present" "$CACHE_LOG" || fail "apt-cache policy expected: $(cat "$CACHE_LOG")"

    : > "$CACHE_LOG"
    printf 'only_main\n' > "$MOCK_STATE/unavailable_release"
    common_package_available present bookworm-backports || fail "a package must be available in the release"
    if common_package_available only_main bookworm-backports; then
        fail "a package without a candidate in the release must not be available there"
    fi
    common_package_available only_main || fail "the same package is available without a release"
    grep -qx -- "madison present" "$CACHE_LOG" || fail "the release must be checked with apt-cache madison: $(cat "$CACHE_LOG")"
}

test_index_refreshed_once() {
    local i

    reset_state
    for i in $(seq 1 13); do
        common_safe_install "pkg$i"
    done
    [ "$(count_apt update)" = 1 ] || fail "13 installations must refresh the index once: $(cat "$APT_LOG")"
    [ "$(count_apt install)" = 13 ] || fail "13 installations expected: $(cat "$APT_LOG")"

    common_apt_sources_changed
    common_safe_install after_change
    common_safe_install after_change_again
    [ "$(count_apt update)" = 2 ] || fail "the index must be refreshed again after common_apt_sources_changed: $(cat "$APT_LOG")"

    # Explicit refreshes are covered by the same mark.
    reset_state
    common_apt_update "first" || fail "first refresh failed"
    common_apt_update "second" || fail "second refresh failed"
    [ "$(count_apt update)" = 1 ] || fail "an explicit refresh must run once: $(cat "$APT_LOG")"
    common_apt_sources_changed
    common_apt_update "third" || fail "third refresh failed"
    [ "$(count_apt update)" = 2 ] || fail "a refresh after common_apt_sources_changed must run: $(cat "$APT_LOG")"

    # A failed refresh is not remembered.
    reset_state
    : > "$MOCK_STATE/update_fail"
    common_apt_update "failing" >/dev/null || true
    rm -f "$MOCK_STATE/update_fail"
    common_apt_update "retry" || fail "refresh after a failure must run"
    [ "$(count_apt update)" = 2 ] || fail "a failed refresh must be retried: $(cat "$APT_LOG")"
}

test_lock_timeout_option_and_no_fuser() {
    local pathbin tool status

    reset_state
    common_safe_install pkg
    while IFS= read -r line; do
        case "$line" in
            *"DPkg::Lock::Timeout=300"*) ;;
            *) fail "apt-get call without DPkg::Lock::Timeout=300: $line" ;;
        esac
    done < "$APT_LOG"
    grep -qx noninteractive "$MOCK_STATE/frontend.log" || fail "apt-get must run with DEBIAN_FRONTEND=noninteractive"
    if grep -vx noninteractive "$MOCK_STATE/frontend.log" | grep -q .; then
        fail "every apt-get call must run noninteractive: $(cat "$MOCK_STATE/frontend.log")"
    fi

    reset_state
    COMMON_APT_LOCK_TIMEOUT=17 common_safe_install pkg
    grep -q -- "DPkg::Lock::Timeout=17 " "$APT_LOG" || fail "COMMON_APT_LOCK_TIMEOUT must set the timeout: $(cat "$APT_LOG")"

    # A PATH with the mocks and basic tools but without fuser. The mock apt-get reports a
    # busy dpkg lock unless it was started with DPkg::Lock::Timeout, as apt would wait for it.
    reset_state
    pathbin="$TEST_DIR/pathbin"
    mkdir -p "$pathbin"
    for tool in bash sed grep head tail cat date dirname mkdir seq; do
        ln -sf "$(command -v "$tool")" "$pathbin/$tool"
    done
    cp "$MOCK_BIN/apt-get" "$MOCK_BIN/apt-cache" "$pathbin/"
    ln -sf "$(command -v env)" "$pathbin/env"
    if PATH="$pathbin" command -v fuser >/dev/null 2>&1; then
        fail "the test PATH must not provide fuser"
    fi
    : > "$MOCK_STATE/install_lock_busy"
    hash -r
    status=0
    PATH="$pathbin" common_safe_install pkg || status=$?
    hash -r
    [ "$status" = 0 ] || fail "installation without fuser and with a busy dpkg lock must succeed, got $status: $(cat "$MSGS")"
    assert_msg "Packages installed successfully"

    if grep -nE 'fuser|wait_for_dpkg_lock' "$ROOT_DIR/lib/common.sh" >/dev/null; then
        fail "lib/common.sh must not depend on fuser"
    fi
}

test_update_waits_for_dpkg_lock() {
    local status

    # Before apt-get update, an install of no packages waits for the dpkg lock: update does
    # not take that lock and would break the download of another running installation.
    reset_state
    common_apt_update "ordering" || fail "refresh failed"
    grep -n . "$APT_LOG" | sed -n '1p' | grep -q -- "DPkg::Lock::Timeout=300 .* install -y$" || \
        fail "the dpkg lock wait must come first: $(cat "$APT_LOG")"
    grep -n . "$APT_LOG" | sed -n '2p' | grep -q -- " update$" || \
        fail "apt-get update must follow the lock wait: $(cat "$APT_LOG")"
    [ "$(wc -l < "$APT_LOG")" = 2 ] || fail "wait and update expected: $(cat "$APT_LOG")"

    # A lock that is not released ends the refresh without running update.
    reset_state
    : > "$MOCK_STATE/install_lock_stuck"
    status="$(run_status common_apt_update "stuck lock")"
    [ "$status" = 75 ] || fail "a held dpkg lock must fail the refresh with 75, got $status"
    [ "$(count_apt update)" = 0 ] || fail "update must not run while the dpkg lock is held: $(cat "$APT_LOG")"
    assert_msg "apt-get update failed during: stuck lock"

    # apt ships translations: the lock is recognised under any locale.
    reset_state
    : > "$MOCK_STATE/install_lock_stuck"
    status="$(LANG=ru_RU.UTF-8 run_status common_apt_update "translated lock")"
    [ "$status" = 75 ] || fail "a held dpkg lock must be recognised under a translated locale, got $status"
    [ "$(count_apt update)" = 0 ] || fail "update must not run under a translated lock message: $(cat "$APT_LOG")"
}

test_held_dpkg_lock_does_not_multiply_waits() {
    local status

    # Before installing: the lock wait of the refresh fails, nothing is installed.
    reset_state
    : > "$MOCK_STATE/install_lock_stuck"
    status="$(run_status common_safe_install a b c)"
    [ "$status" = 1 ] || fail "a held dpkg lock must fail the installation, got $status"
    [ "$(count_apt install)" = 0 ] || fail "no installation may wait for a lock already found held: $(cat "$APT_LOG")"
    assert_msg "still holds the dpkg lock"
    refute_msg "Continuing with the existing APT package index"

    # The lock is taken after the refresh: one installation call, no retries one by one,
    # each of which would wait for the same lock again.
    reset_state
    COMMON_APT_INDEX_FRESH=1
    : > "$MOCK_STATE/install_lock_stuck"
    status="$(LANG=ru_RU.UTF-8 run_status common_safe_install a b c)"
    [ "$status" = 1 ] || fail "a held dpkg lock must fail the installation, got $status"
    [ "$(count_apt install)" = 1 ] || fail "one installation call expected while the lock is held: $(cat "$APT_LOG")"
    refute_msg "Packages installed successfully"

    # The lock is taken during the retries one by one: the remaining packages are not tried.
    reset_state
    COMMON_APT_INDEX_FRESH=1
    printf 'a\n' > "$MOCK_STATE/install_fail"
    printf '1\n' > "$MOCK_STATE/install_lock_after"
    status="$(run_status common_safe_install a b c)"
    [ "$status" = 1 ] || fail "a lock taken during the retries must fail the installation, got $status"
    [ "$(count_apt install)" = 2 ] || fail "the batch and one retry expected, then no more waits: $(cat "$APT_LOG")"
    assert_msg "Package installation incomplete: a b c"
}

test_install_from_release() {
    local status

    reset_state
    printf 'kernel 2.0~bpo12+1\nheaders 2.0~bpo12+1\n' > "$MOCK_STATE/dpkg_versions"
    common_install_from_release bookworm-backports kernel headers || fail "packages installed from the release must succeed"
    grep -q -- "install -y -t bookworm-backports kernel headers$" "$APT_LOG" || fail "the release must go to apt-get: $(cat "$APT_LOG")"

    # apt-get succeeded, but the installed version is not the release's one.
    reset_state
    printf 'kernel 1.0\nheaders 2.0~bpo12+1\n' > "$MOCK_STATE/dpkg_versions"
    status="$(run_status common_install_from_release bookworm-backports kernel headers)"
    [ "$status" = 1 ] || fail "a version from another release must fail, got $status"

    # The installation itself failed.
    reset_state
    printf 'kernel 2.0~bpo12+1\nheaders 2.0~bpo12+1\n' > "$MOCK_STATE/dpkg_versions"
    printf 'kernel\n' > "$MOCK_STATE/install_fail"
    status="$(run_status common_install_from_release bookworm-backports kernel headers)"
    [ "$status" = 1 ] || fail "a failed installation must fail, got $status"

    status="$(run_status common_install_from_release bookworm-backports)"
    [ "$status" = 1 ] || fail "packages are required, got $status"
}

test_package_installed_from() {
    reset_state
    printf 'kernel 2.0~bpo12+1\nheaders 2.0~bpo12+1\n' > "$MOCK_STATE/dpkg_versions"
    common_package_installed_from bookworm-backports kernel headers || \
        fail "packages installed in the release version must be reported as installed from it"

    printf 'kernel 1.0\nheaders 2.0~bpo12+1\n' > "$MOCK_STATE/dpkg_versions"
    if common_package_installed_from bookworm-backports kernel headers; then
        fail "a package installed from the default release must not count as installed from the release"
    fi

    printf 'headers 2.0~bpo12+1\n' > "$MOCK_STATE/dpkg_versions"
    if common_package_installed_from bookworm-backports kernel headers; then
        fail "a package that is not installed must not count as installed from the release"
    fi

    printf 'kernel 1.0\n' > "$MOCK_STATE/dpkg_versions"
    printf 'kernel\n' > "$MOCK_STATE/unavailable_release"
    if common_package_installed_from bookworm-backports kernel; then
        fail "a release without the package cannot be the source of the installed version"
    fi
    if common_package_installed_from "" kernel || common_package_installed_from bookworm-backports; then
        fail "a release and at least one package are required"
    fi
}

test_update_lock_retry() {
    local status

    # A busy lists lock is retried and the refresh succeeds.
    reset_state
    printf '3\n' > "$MOCK_STATE/update_lock_busy"
    COMMON_APT_UPDATE_RETRY_DELAY=7
    status="$(run_status common_apt_update "Docker repository refresh")"
    [ "$status" = 0 ] || fail "a refresh must wait for the lists lock, got status $status: $(cat "$MSGS")"
    [ "$(count_apt update)" = 4 ] || fail "three busy attempts and one success expected: $(cat "$APT_LOG")"
    [ "$(wc -l < "$SLEEP_LOG")" = 3 ] || fail "three waits expected: $(cat "$SLEEP_LOG")"
    grep -qx 7 "$SLEEP_LOG" || fail "COMMON_APT_UPDATE_RETRY_DELAY must set the wait: $(cat "$SLEEP_LOG")"
    refute_msg "apt-get update failed"

    # The state is kept in this shell, not in the status subshell above.
    reset_state
    printf '2\n' > "$MOCK_STATE/update_lock_busy"
    common_apt_update "mark" || fail "refresh with a busy lock failed"
    [ "${COMMON_APT_INDEX_FRESH:-0}" = 1 ] || fail "a refresh after retries must be remembered"

    # The attempt limit ends the wait with the context in the error.
    reset_state
    printf '100\n' > "$MOCK_STATE/update_lock_busy"
    COMMON_APT_UPDATE_ATTEMPTS=3
    status="$(run_status common_apt_update "Backports repository refresh")"
    [ "$status" = 100 ] || fail "a lock that stays busy must fail with the apt status, got $status"
    [ "$(count_apt update)" = 3 ] || fail "the attempt limit must stop the retries: $(cat "$APT_LOG")"
    assert_msg "ERROR: apt-get update failed during: Backports repository refresh"

    # The time limit ends the wait too, even with attempts left.
    reset_state
    printf '100\n' > "$MOCK_STATE/update_lock_busy"
    COMMON_APT_UPDATE_ATTEMPTS=1000
    COMMON_APT_LOCK_TIMEOUT=30
    COMMON_APT_UPDATE_RETRY_DELAY=10
    status="$(run_status common_apt_update "time limit")"
    [ "$status" = 100 ] || fail "the time limit must end the wait with the apt status, got $status"
    [ "$(count_apt update)" -le 4 ] || fail "the time limit must stop the retries: $(cat "$APT_LOG")"
    [ "$(count_apt update)" -ge 2 ] || fail "the lock must be retried before the limit: $(cat "$APT_LOG")"
    assert_msg "apt-get update failed during: time limit"

    # Other failures are not retried.
    reset_state
    : > "$MOCK_STATE/update_fail"
    status="$(run_status common_apt_update "broken repository")"
    [ "$status" = 100 ] || fail "a broken repository must fail with the apt status, got $status"
    [ "$(count_apt update)" = 1 ] || fail "only the lock is retried: $(cat "$APT_LOG")"
    unset COMMON_APT_UPDATE_ATTEMPTS COMMON_APT_LOCK_TIMEOUT COMMON_APT_UPDATE_RETRY_DELAY
}

test_update_failure_report() {
    local out status

    reset_state
    : > "$MOCK_STATE/update_fail"
    status=0
    out="$(common_apt_update "APT source enrichment")" || status=$?
    [ "$status" = 100 ] || fail "the apt-get update status must be returned, got $status"
    assert_msg "ERROR: apt-get update failed during: APT source enrichment"
    grep -qF "E: The repository is not signed." <<<"$out" || fail "the first lines of the apt output must be shown, got: $out"
    grep -qF "E: The repository is not signed." "$SILENT_LOG" || fail "the apt output must go to the log"

    # safe_install goes on with the old index and installs what it can.
    reset_state
    : > "$MOCK_STATE/update_fail"
    status="$(run_status common_safe_install pkg)"
    [ "$status" = 0 ] || fail "a failed refresh must not stop the installation, got $status"
    assert_msg "ERROR: apt-get update failed during: installing: pkg"
    assert_msg "WARN: Continuing with the existing APT package index"
    [ "$(count_apt install)" = 1 ] || fail "the installation must go on: $(cat "$APT_LOG")"
}

test_update_check_hook() {
    local status

    update_check_reject() {
        warn "rejected: $1"
        return 1
    }
    update_check_accept() {
        return 0
    }

    reset_state
    COMMON_APT_UPDATE_CHECK=update_check_reject
    status="$(run_status common_apt_update "hooked")"
    [ "$status" = 1 ] || fail "a rejecting check must fail the refresh, got $status"
    assert_msg "WARN: rejected: Hit:1 http://deb.debian.org/debian bookworm InRelease"
    assert_msg "apt-get update failed during: hooked"
    [ "${COMMON_APT_INDEX_FRESH:-0}" = 0 ] || fail "a rejected refresh must not be remembered"
    common_apt_update "hooked again" >/dev/null 2>&1 || true
    [ "$(count_apt update)" = 2 ] || fail "a rejected refresh must be retried: $(cat "$APT_LOG")"

    reset_state
    COMMON_APT_UPDATE_CHECK=update_check_accept
    common_apt_update "accepted" || fail "an accepting check must not fail the refresh"
    [ "${COMMON_APT_INDEX_FRESH:-0}" = 1 ] || fail "an accepted refresh must be remembered"
    unset COMMON_APT_UPDATE_CHECK
}

main() {
    make_mocks
    PATH="$MOCK_BIN:$PATH"
    export MOCK_STATE

    test_install_failure_returns_one
    test_release_is_passed_to_apt
    test_unavailable_packages_warn
    test_package_available
    test_index_refreshed_once
    test_lock_timeout_option_and_no_fuser
    test_update_waits_for_dpkg_lock
    test_held_dpkg_lock_does_not_multiply_waits
    test_package_installed_from
    test_install_from_release
    test_update_lock_retry
    test_update_failure_report
    test_update_check_hook
    printf 'tests/test_apt_helpers.sh: OK\n'
}

main "$@"

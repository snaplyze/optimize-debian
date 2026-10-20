#!/usr/bin/env bash
# Tests of the time-sync helpers in lib/common.sh with mocked systemctl, timedatectl and
# package installation. The embedded copies of these functions in optimize_*.sh are compared
# with lib/ by tests/test_embedded_copies.sh, so these tests cover the copies too.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR:-}"' EXIT

MSGS="$TEST_DIR/messages.log"
CALLS="$TEST_DIR/calls.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Output helpers the scripts define; the lib functions call them.
log() { printf 'LOG: %s\n' "$1" >> "$MSGS"; }
warn() { printf 'WARN: %s\n' "$1" >> "$MSGS"; }
info() { printf 'INFO: %s\n' "$1" >> "$MSGS"; }

# Mocked system state, set by reset_state and the tests.
SYSTEMD=1
UNITS=""
ACTIVE=""
ENABLE_OK=1
START_OK=1
TIMESYNCD_AVAILABLE=1
INSTALL_OK=1
NTP_SYNC=yes
SET_NTP_OK=1

common_systemd_running() { [ "$SYSTEMD" = 1 ]; }
common_apt_update() { printf 'apt_update %s\n' "$1" >> "$CALLS"; }
common_package_available() { [ "$TIMESYNCD_AVAILABLE" = 1 ] && [ "$1" = systemd-timesyncd ]; }
common_safe_install() {
    printf 'install %s\n' "$*" >> "$CALLS"
    [ "$INSTALL_OK" = 1 ]
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$CALLS"
    case "$1" in
        list-unit-files) [[ " $UNITS " == *" $2 "* ]] ;;
        is-active) [[ " $ACTIVE " == *" $2 "* ]] ;;
        enable) [ "$ENABLE_OK" = 1 ] ;;
        start) [ "$START_OK" = 1 ] ;;
        *) return 1 ;;
    esac
}
timedatectl() {
    printf 'timedatectl %s\n' "$*" >> "$CALLS"
    case "$*" in
        "show -p NTPSynchronized --value") printf '%s\n' "$NTP_SYNC" ;;
        "set-ntp true") [ "$SET_NTP_OK" = 1 ] ;;
        *) return 1 ;;
    esac
}

reset_state() {
    SYSTEMD=1
    UNITS=""
    ACTIVE=""
    ENABLE_OK=1
    START_OK=1
    TIMESYNCD_AVAILABLE=1
    INSTALL_OK=1
    NTP_SYNC=yes
    SET_NTP_OK=1
    COMMON_TIME_SYNC_SERVICE="previous"
    : > "$MSGS"
    : > "$CALLS"
}

assert_msg() {
    grep -qF -- "$1" "$MSGS" || fail "expected message '$1', got: $(cat "$MSGS")"
}

assert_call() {
    grep -qxF -- "$1" "$CALLS" || fail "expected call '$1', got: $(cat "$CALLS")"
}

refute_call() {
    if grep -qF -- "$1" "$CALLS"; then
        fail "unexpected call '$1': $(cat "$CALLS")"
    fi
}

test_clock_synchronized_reads_ntp_synchronized() {
    reset_state
    common_system_clock_synchronized || fail "NTPSynchronized=yes must count as synchronized"
    assert_call "timedatectl show -p NTPSynchronized --value"
    NTP_SYNC=no
    if common_system_clock_synchronized; then
        fail "NTPSynchronized=no must not count as synchronized"
    fi
    NTP_SYNC=""
    if common_system_clock_synchronized; then
        fail "an empty answer must not count as synchronized"
    fi
}

test_ensure_keeps_the_installed_service() {
    # An installed and active chrony is kept; nothing is installed or started.
    reset_state
    UNITS="chrony.service systemd-timesyncd.service"
    ACTIVE="chrony.service"
    common_ensure_time_sync_service || fail "an active installed service must be accepted"
    [ "$COMMON_TIME_SYNC_SERVICE" = chrony ] || fail "chrony expected, got '$COMMON_TIME_SYNC_SERVICE'"
    refute_call "install"
    refute_call "systemctl enable"
    refute_call "apt_update"
    assert_msg "Detected NTP service: chrony"

    # An installed but inactive chrony is started, and systemd-timesyncd is not installed
    # over it: in Debian the packages conflict and the installation would remove chrony.
    reset_state
    UNITS="chrony.service"
    common_ensure_time_sync_service || fail "an inactive installed service must be started"
    [ "$COMMON_TIME_SYNC_SERVICE" = chrony ] || fail "chrony expected, got '$COMMON_TIME_SYNC_SERVICE'"
    assert_call "systemctl enable --now chrony.service"
    refute_call "install"
    assert_msg "NTP service started: chrony"

    # The preferred order decides between installed services.
    reset_state
    UNITS="systemd-timesyncd.service ntpsec.service"
    ACTIVE="ntpsec.service systemd-timesyncd.service"
    common_ensure_time_sync_service
    [ "$COMMON_TIME_SYNC_SERVICE" = ntpsec ] || fail "ntpsec is preferred over systemd-timesyncd, got '$COMMON_TIME_SYNC_SERVICE'"

    # enable --now fails, start works.
    reset_state
    UNITS="ntp.service"
    ENABLE_OK=0
    common_ensure_time_sync_service || fail "a service that only starts must be accepted"
    assert_call "systemctl start ntp.service"
    [ "$COMMON_TIME_SYNC_SERVICE" = ntp ] || fail "ntp expected, got '$COMMON_TIME_SYNC_SERVICE'"
}

test_ensure_installs_timesyncd_when_none_is_installed() {
    reset_state
    common_ensure_time_sync_service || fail "systemd-timesyncd must be installed and started"
    # The index is refreshed first: the time-sync step can run before any other refresh.
    [ "$(head -n 1 "$CALLS" | grep -c '^systemctl list-unit-files')" = 1 ] || fail "installed units are looked up first"
    grep -n '' "$CALLS" | grep -q '^[0-9]*:apt_update time sync service lookup$' || fail "the index must be refreshed: $(cat "$CALLS")"
    [ "$(grep -n '^apt_update' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^install' "$CALLS" | cut -d: -f1)" ] || \
        fail "the index must be refreshed before the installation: $(cat "$CALLS")"
    assert_call "install systemd-timesyncd"
    assert_call "systemctl enable --now systemd-timesyncd.service"
    [ "$COMMON_TIME_SYNC_SERVICE" = systemd-timesyncd ] || fail "systemd-timesyncd expected, got '$COMMON_TIME_SYNC_SERVICE'"
}

test_ensure_failures() {
    local status

    # Without systemd nothing is touched.
    reset_state
    SYSTEMD=0
    status=0
    common_ensure_time_sync_service || status=$?
    [ "$status" = 1 ] || fail "no systemd must return 1, got $status"
    [ ! -s "$CALLS" ] || fail "no systemd must not call anything: $(cat "$CALLS")"
    [ -z "$COMMON_TIME_SYNC_SERVICE" ] || fail "no service must be reported without systemd"

    reset_state
    TIMESYNCD_AVAILABLE=0
    status=0
    common_ensure_time_sync_service || status=$?
    [ "$status" = 1 ] || fail "no service and no package must return 1, got $status"
    assert_msg "No supported NTP service detected and systemd-timesyncd is unavailable"
    [ -z "$COMMON_TIME_SYNC_SERVICE" ] || fail "no service must be reported"

    reset_state
    INSTALL_OK=0
    status=0
    common_ensure_time_sync_service || status=$?
    [ "$status" = 1 ] || fail "a failed installation must return 1, got $status"
    assert_msg "Failed to install systemd-timesyncd"
    refute_call "systemctl enable"

    reset_state
    UNITS="chrony.service"
    ENABLE_OK=0
    START_OK=0
    status=0
    common_ensure_time_sync_service || status=$?
    [ "$status" = 1 ] || fail "a service that does not start must return 1, got $status"
    assert_msg "Failed to enable or start NTP service: chrony"
    [ -z "$COMMON_TIME_SYNC_SERVICE" ] || fail "a service that does not run must not be reported"
}

test_enable_time_sync() {
    local status

    # set-ntp works.
    reset_state
    UNITS="chrony.service"
    ACTIVE="chrony.service"
    common_enable_time_sync || fail "time sync must be enabled"
    assert_call "timedatectl set-ntp true"
    assert_msg "NTP synchronization enabled via chrony"
    [ "$COMMON_TIME_SYNC_SERVICE" = chrony ] || fail "chrony expected, got '$COMMON_TIME_SYNC_SERVICE'"

    # set-ntp fails, but the service runs and the clock is synchronized.
    reset_state
    UNITS="ntpsec.service"
    ACTIVE="ntpsec.service"
    SET_NTP_OK=0
    common_enable_time_sync || fail "a running service must be enough"
    assert_msg "Time sync already operational via ntpsec"

    # set-ntp fails, the service runs, the clock is not synchronized yet.
    reset_state
    UNITS="ntpsec.service"
    ACTIVE="ntpsec.service"
    SET_NTP_OK=0
    NTP_SYNC=no
    common_enable_time_sync || fail "a running service must be enough"
    assert_msg "Time-sync daemon ntpsec is active even though timedatectl could not control it directly"

    # set-ntp fails and the started service does not stay active.
    reset_state
    UNITS="ntpsec.service"
    SET_NTP_OK=0
    status=0
    common_enable_time_sync || status=$?
    [ "$status" = 1 ] || fail "a service that is not active must return 1, got $status"
    assert_msg "Could not enable NTP via timedatectl after preparing ntpsec"

    # No usable service: set-ntp is not tried.
    reset_state
    UNITS="chrony.service"
    ENABLE_OK=0
    START_OK=0
    status=0
    common_enable_time_sync || status=$?
    [ "$status" = 1 ] || fail "a failed service must return 1, got $status"
    refute_call "timedatectl set-ntp"

    reset_state
    SYSTEMD=0
    status=0
    common_enable_time_sync || status=$?
    [ "$status" = 1 ] || fail "no systemd must return 1, got $status"
    assert_msg "systemd is unavailable"
    [ -z "$COMMON_TIME_SYNC_SERVICE" ] || fail "no service must be reported without systemd"

    # Without timedatectl nothing is touched.
    reset_state
    status="$(
        unset -f timedatectl
        # shellcheck disable=SC2123 # An empty search path hides the real timedatectl.
        PATH="$TEST_DIR/empty-path"
        common_enable_time_sync >/dev/null || printf '%s' "$?"
    )"
    [ "$status" = 1 ] || fail "no timedatectl must return 1, got '$status'"
    assert_msg "timedatectl is unavailable"
    [ ! -s "$CALLS" ] || fail "no timedatectl must not call anything: $(cat "$CALLS")"
}

main() {
    test_clock_synchronized_reads_ntp_synchronized
    test_ensure_keeps_the_installed_service
    test_ensure_installs_timesyncd_when_none_is_installed
    test_ensure_failures
    test_enable_time_sync
    printf 'tests/test_time_sync.sh: OK\n'
}

main "$@"

#!/usr/bin/env bash
# Behavioral tests for optimize_vps.sh: system limits, config backups, SSH hardening.
# SC2016: case bodies are single-quoted on purpose, they run in a separate bash.
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/optimize_vps.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Common prelude for every case: sources the script without running the steps,
# isolates the environment and provides event-log assertions. Each case runs in
# its own bash process and removes its temp directory on exit.
read -r -d '' CASE_HEADER <<'HEADER_EOF' || true
set -euo pipefail
OPTIMIZE_SOURCE_ONLY=1
source "$SCRIPT_ROOT/optimize_vps.sh"
LOG_FILE=""
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
EVENTS="$T/events"
: > "$EVENTS"

die() { printf "FAIL: %s\n" "$*" >&2; exit 1; }
event() { printf "%s\n" "$*" >> "$EVENTS"; }
run_status() { set +e; ( set -e; "$@" ) > "$T/out" 2>&1; RC=$?; set -e; }
assert_rc() { [ "$RC" -eq "$1" ] || die "$2 (rc=$RC, expected $1): $(cat "$T/out")"; }
assert_failed() { [ "$RC" -ne 0 ] || die "$1 (expected a non-zero exit): $(cat "$T/out")"; }
assert_out() { grep -Fq -- "$1" "$T/out" || die "$2: output lacks '$1': $(cat "$T/out")"; }
event_log() { tr "\n" "|" < "$EVENTS"; }
assert_event() { grep -Fxq -- "$1" "$EVENTS" || die "missing event '$1' in: $(event_log)"; }
assert_no_event() { ! grep -Fxq -- "$1" "$EVENTS" || die "unexpected event '$1' in: $(event_log)"; }
assert_no_temp_leftovers() { [ -z "$(ls -A "$TMPDIR")" ] || die "temp files left behind: $(ls -A "$TMPDIR")"; }
HEADER_EOF

run_case() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c "$CASE_HEADER"$'\n'"$1"
}

test_removed_dead_helpers() {
    local name
    for name in run_silent prompt_yn check_dialog; do
        ! grep -Eq "^${name}\(\)" "$SCRIPT" || fail "unused helper $name is defined again in optimize_vps.sh"
    done
}

test_system_limits_single_idempotent_place() {
    run_case '
        VPS_LIMITS_FILE="$T/limits.d/99-vps-limits.conf"
        mkdir -p "$T/limits.d"
        printf "# distro limits.conf\n" > "$T/limits.conf"
        cp "$T/limits.conf" "$T/limits.conf.orig"

        write_system_limits
        cp "$VPS_LIMITS_FILE" "$T/first"
        write_system_limits
        cmp -s "$T/first" "$VPS_LIMITS_FILE" || die "a second run must produce the same limits file"
        cmp -s "$T/limits.conf" "$T/limits.conf.orig" || die "limits.conf must not be touched"
        [ "$(ls "$T/limits.d" | wc -l)" = 1 ] || die "only one limits file expected: $(ls "$T/limits.d")"

        # Every limit of the script lives in this one file, nofile has a single value.
        for line in "* soft nofile 65535" "* hard nofile 65535" "root soft nofile 65535" "root hard nofile 65535" \
                    "* soft nproc 65535" "* hard nproc 65535" "root soft nproc 65535" "root hard nproc 65535" \
                    "* soft memlock unlimited" "* hard memlock unlimited"; do
            [ "$(grep -Fxc "$line" "$VPS_LIMITS_FILE")" = 1 ] || die "limits file must have exactly one: $line"
        done
        [ "$(awk "\$3 == \"nofile\" { print \$4 }" "$VPS_LIMITS_FILE" | sort -u)" = "$VPS_NOFILE_LIMIT" ] || \
            die "nofile in the file differs from VPS_NOFILE_LIMIT=$VPS_NOFILE_LIMIT"

        # The values come from the variables, not from literals in the template.
        VPS_NOFILE_LIMIT=4242
        write_system_limits
        grep -Fxq "* hard nofile 4242" "$VPS_LIMITS_FILE" || die "nofile must follow VPS_NOFILE_LIMIT"
    '
}

test_system_limits_summary_matches_file() {
    # The final message prints the variable the limits file is rendered from, and
    # nothing else appends limits to /etc/security/limits.conf.
    grep -Fq 'info "System limits increased (nofile $VPS_NOFILE_LIMIT)"' "$SCRIPT" || \
        fail "the summary must print VPS_NOFILE_LIMIT"
    ! grep -Eq 'nofile (262144|524288)' "$SCRIPT" || fail "stray nofile literal in optimize_vps.sh"
    ! grep -Eq '>>? */etc/security/limits\.conf' "$SCRIPT" || fail "optimize_vps.sh must not write /etc/security/limits.conf"
    [ "$(grep -c 'write_system_limits$' "$SCRIPT")" = 1 ] || fail "write_system_limits must run exactly once"
}

test_config_backup_only_on_change() {
    run_case '
        log() { :; }
        target="$T/etc/daemon.json"
        mkdir -p "$T/etc"

        # New file: nothing to back up.
        printf "one\n" | write_config_with_backup "$target"
        [ "$(cat "$target")" = one ] || die "new content must be written"
        [ "$(ls "$T/etc" | wc -l)" = 1 ] || die "no backup for a new file: $(ls "$T/etc")"

        # Same content again: file and backups untouched.
        printf "one\n" | write_config_with_backup "$target"
        printf "one\n" | write_config_with_backup "$target"
        [ "$(ls "$T/etc" | wc -l)" = 1 ] || die "identical content must not create copies: $(ls "$T/etc")"

        # Changed content: the old content is kept, the new one is written.
        printf "two\n" | write_config_with_backup "$target"
        [ "$(cat "$target")" = two ] || die "changed content must be written"
        [ "$(ls "$T/etc" | wc -l)" = 2 ] || die "one backup expected: $(ls "$T/etc")"
        [ "$(cat "$T"/etc/daemon.json.backup.*)" = one ] || die "backup must hold the previous content"

        # A second change the same day does not overwrite the first copy.
        printf "three\n" | write_config_with_backup "$target"
        [ "$(ls "$T/etc" | wc -l)" = 3 ] || die "second change needs its own backup: $(ls "$T/etc")"
        [ "$(cat "$target")" = three ] || die "latest content must be written"
        cat "$T"/etc/daemon.json.backup.* | sort | tr "\n" " " | grep -Fxq "one two " || \
            die "both previous versions must be kept"

        # Repeat of the latest content: still three files.
        printf "three\n" | write_config_with_backup "$target"
        [ "$(ls "$T/etc" | wc -l)" = 3 ] || die "repeat must not add copies: $(ls "$T/etc")"
        assert_no_temp_leftovers

        # Mode and multi-line content survive.
        chmod 640 "$target"
        printf "a\nb\n" | write_config_with_backup "$target"
        [ "$(cat "$target")" = "$(printf "a\nb")" ] || die "multi-line content must be written"
        [ "$(stat -c %a "$target")" = 640 ] || die "the mode of the written file must survive"
        [ "$(stat -c %a "$(ls -t "$T"/etc/daemon.json.backup.* | head -n 1)")" = 640 ] || die "the copy must keep the mode"
    '
}

test_config_backup_is_used_for_overwritten_files() {
    local file
    for file in /etc/docker/daemon.json /etc/fail2ban/jail.local; do
        grep -Fq "write_config_with_backup $file <<" "$SCRIPT" || fail "$file must be written through write_config_with_backup"
        ! grep -Eq "^cat > $file" "$SCRIPT" || fail "$file is overwritten without a copy"
    done
}

# Mocks for sshd and systemctl. Flag files choose what fails.
SSH_CASE_SETUP='
SSHD_CONFIG_FILE="$T/sshd_config"
SSH_HARDENING_FILE="$T/sshd_config.d/99-hardening.conf"
mkdir -p "$T/sshd_config.d"
printf "Include sshd_config.d/*.conf\n" > "$SSHD_CONFIG_FILE"
sshd() {
    event "sshd $*"
    if [ -e "$T/sshd_test_fails" ]; then
        echo "sshd: invalid configuration" >&2
        return 1
    fi
}
systemctl() {
    event "systemctl $*"
    local unit="${2:-}"
    if [ "$unit" = ssh.service ] && [ -e "$T/ssh_unit_fails" ]; then
        echo "Unit ssh.service not found" >&2
        return 5
    fi
    if [ "$unit" = sshd.service ] && [ -e "$T/sshd_unit_fails" ]; then
        echo "Unit sshd.service not found" >&2
        return 5
    fi
}
reset_ssh_case() {
    : > "$EVENTS"
    rm -f "$T/sshd_test_fails" "$T/ssh_unit_fails" "$T/sshd_unit_fails" "$SSH_HARDENING_FILE"
}
'

test_ssh_hardening_dropin_content() {
    run_case "$SSH_CASE_SETUP"'
        reset_ssh_case
        run_status configure_ssh_hardening ops
        assert_rc 0 "SSH hardening"
        for line in "PermitRootLogin no" "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PubkeyAuthentication yes" \
                    "PermitEmptyPasswords no" "AllowUsers ops"; do
            grep -Fxq "$line" "$SSH_HARDENING_FILE" || die "drop-in lacks: $line"
        done
        [ "$(grep -c "^AllowUsers" "$SSH_HARDENING_FILE")" = 1 ] || die "exactly one AllowUsers expected"
        assert_event "sshd -t"
        assert_event "systemctl restart ssh.service"
        assert_no_event "systemctl restart sshd.service"
        assert_out "SSH service restarted" "success message"
        [ -e "$T/sshd_config.backup.$(date +%F)" ] || die "sshd_config must be backed up"

        # Another user is rendered; the drop-in is rewritten, not appended.
        run_status configure_ssh_hardening operator
        assert_rc 0 "second run"
        grep -Fxq "AllowUsers operator" "$SSH_HARDENING_FILE" || die "new user missing"
        ! grep -Fxq "AllowUsers ops" "$SSH_HARDENING_FILE" || die "old user must be replaced"

        # ssh.service missing: fall back to sshd.service.
        reset_ssh_case
        : > "$T/ssh_unit_fails"
        run_status configure_ssh_hardening ops
        assert_rc 0 "fallback to sshd.service"
        assert_event "systemctl restart sshd.service"
    '
}

test_ssh_hardening_invalid_config_is_removed() {
    run_case "$SSH_CASE_SETUP"'
        # sshd -t fails, no earlier drop-in: nothing left, no restart.
        reset_ssh_case
        : > "$T/sshd_test_fails"
        run_status configure_ssh_hardening ops
        assert_failed "invalid configuration must fail the step"
        assert_out "SSH configuration test failed" "error message"
        assert_out "sshd: invalid configuration" "sshd output must be visible"
        [ ! -e "$SSH_HARDENING_FILE" ] || die "the rejected drop-in must be removed"
        assert_no_event "systemctl restart ssh.service"
        assert_no_event "systemctl restart sshd.service"

        # Earlier drop-in exists: it is put back, not deleted.
        reset_ssh_case
        printf "# earlier drop-in\nAllowUsers earlier\n" > "$SSH_HARDENING_FILE"
        : > "$T/sshd_test_fails"
        run_status configure_ssh_hardening ops
        assert_failed "invalid configuration must fail the step"
        [ "$(cat "$SSH_HARDENING_FILE")" = "$(printf "# earlier drop-in\nAllowUsers earlier")" ] || \
            die "the earlier drop-in must be restored"
        assert_no_event "systemctl restart ssh.service"
        assert_no_temp_leftovers

        # The drop-in cannot be written (no sshd_config.d): the step fails before sshd -t,
        # without a restart and without a success message.
        reset_ssh_case
        saved_file="$SSH_HARDENING_FILE"
        SSH_HARDENING_FILE="$T/missing-dir/99-hardening.conf"
        run_status configure_ssh_hardening ops
        assert_failed "an unwritable drop-in must fail the step"
        assert_out "Could not write" "write error message"
        assert_no_event "sshd -t"
        assert_no_event "systemctl restart ssh.service"
        ! grep -q "SSH service restarted" "$T/out" || die "no restart message after a write error"
        SSH_HARDENING_FILE="$saved_file"
    '
}

test_ssh_hardening_restart_failure_is_visible() {
    run_case "$SSH_CASE_SETUP"'
        reset_ssh_case
        : > "$T/ssh_unit_fails"
        : > "$T/sshd_unit_fails"
        run_status configure_ssh_hardening ops
        assert_failed "failed restart must fail the step"
        assert_out "Failed to restart the SSH service" "restart failure message"
        assert_out "Unit sshd.service not found" "the last attempt output must be visible"
        ! grep -Fq "SSH service restarted" "$T/out" || die "success must not be reported"
        assert_event "systemctl restart ssh.service"
        assert_event "systemctl restart sshd.service"
        assert_no_temp_leftovers
    '
}

test_ssh_hardening_step_stops_the_script() {
    # The step must abort the run when hardening fails: the caller exits.
    grep -Fxq 'configure_ssh_hardening "$NEW_USER" || exit 1' "$SCRIPT" || \
        fail "the SSH hardening step must stop the script on failure"
}

main() {
    test_removed_dead_helpers
    test_system_limits_single_idempotent_place
    test_system_limits_summary_matches_file
    test_config_backup_only_on_change
    test_config_backup_is_used_for_overwritten_files
    test_ssh_hardening_dropin_content
    test_ssh_hardening_invalid_config_is_removed
    test_ssh_hardening_restart_failure_is_visible
    test_ssh_hardening_step_stops_the_script
    printf 'PASS: %s\n' "$(basename "$0")"
}

main "$@"

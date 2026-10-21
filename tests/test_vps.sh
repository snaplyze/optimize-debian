#!/usr/bin/env bash
# Behavioral tests for optimize_vps.sh: system limits, config backups, SSH hardening, swap file.
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
assert_no_event_matches() { ! grep -Eq -- "$1" "$EVENTS" || die "unexpected event matches '$1' in: $(event_log)"; }
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
SSH_HARDENING_FILE="$T/sshd_config.d/00-optimize-hardening.conf"
SSH_LEGACY_HARDENING_FILE="$T/sshd_config.d/99-hardening.conf"
mkdir -p "$T/sshd_config.d"
printf "Include sshd_config.d/*.conf\n" > "$SSHD_CONFIG_FILE"
# sshd -T: the drop-ins in name order when sshd_config includes them, then sshd_config; the
# first value of a keyword wins, while allowusers and port add up, as in sshd. Only keywords set
# in the files are printed.
sshd_effective() {
    local file key value
    local -A seen=()
    local files=("$SSHD_CONFIG_FILE")
    ! grep -q "^Include" "$SSHD_CONFIG_FILE" || files=("$T"/sshd_config.d/*.conf "$SSHD_CONFIG_FILE")
    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        while read -r key value; do
            case "$key" in "" | "#"* | Include) continue ;; esac
            key="${key,,}"
            case "$key" in
                allowusers | port) ;;
                *) [ -z "${seen[$key]:-}" ] || continue; seen[$key]=1 ;;
            esac
            printf "%s %s\n" "$key" "$value"
        done < "$file"
    done
}
sshd() {
    event "sshd $*"
    if [ -e "$T/sshd_test_fails" ]; then
        echo "sshd: invalid configuration" >&2
        return 1
    fi
    if [ "${1:-}" = -T ]; then
        [ ! -e "$T/sshd_dump_fails" ] || return 255
        sshd_effective
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
    rm -f "$T/sshd_test_fails" "$T/sshd_dump_fails" "$T/ssh_unit_fails" "$T/sshd_unit_fails" "$T"/sshd_config.d/*.conf
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
        SSH_HARDENING_FILE="$T/missing-dir/00-optimize-hardening.conf"
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

test_ssh_hardening_paths() {
    # Debian reads the drop-ins in name order and sshd keeps the first value: ours sorts first.
    run_case '
        [ "$SSH_HARDENING_FILE" = /etc/ssh/sshd_config.d/00-optimize-hardening.conf ] || die "the hardening drop-in must sort before the other drop-ins"
        [ "$SSH_LEGACY_HARDENING_FILE" = /etc/ssh/sshd_config.d/99-hardening.conf ] || die "the drop-in of earlier versions moved"
    '
}

test_ssh_hardening_effective_values() {
    run_case "$SSH_CASE_SETUP"'
        # A drop-in read after ours, such as 50-cloud-init.conf, does not override it.
        reset_ssh_case
        printf "PasswordAuthentication yes\n" > "$T/sshd_config.d/50-cloud-init.conf"
        run_status configure_ssh_hardening ops
        assert_rc 0 "a later drop-in must not override the hardening"
        assert_event "sshd -T"
        assert_event "systemctl restart ssh.service"

        # Only the hardening comes first: the operator keeps other settings of a later drop-in.
        reset_ssh_case
        printf "AllowTcpForwarding no\nMaxSessions 4\nUsePAM yes\n" > "$T/sshd_config.d/10-local.conf"
        run_status configure_ssh_hardening ops
        assert_rc 0 "hardening next to an operator drop-in"
        sshd_effective | grep -Fxq "allowtcpforwarding no" || die "the operator AllowTcpForwarding must stay"
        sshd_effective | grep -Fxq "maxsessions 4" || die "the operator MaxSessions must stay"

        # A drop-in read first wins: the step fails, ours goes, sshd is not restarted.
        reset_ssh_case
        printf "PasswordAuthentication yes\n" > "$T/sshd_config.d/00-aaa.conf"
        run_status configure_ssh_hardening ops
        assert_failed "an overridden hardening value must fail the step"
        assert_out "passwordauthentication: expected no, effective yes" "the overridden value must be named"
        [ ! -e "$SSH_HARDENING_FILE" ] || die "the overridden drop-in must be removed"
        [ "$(cat "$T/sshd_config.d/00-aaa.conf")" = "PasswordAuthentication yes" ] || die "the other drop-in must stay"
        assert_no_event "systemctl restart ssh.service"
        assert_no_temp_leftovers

        # An sshd_config without the Include of the drop-ins (kept from an older release)
        # reads none of them: the same.
        reset_ssh_case
        printf "PasswordAuthentication yes\n" > "$SSHD_CONFIG_FILE"
        run_status configure_ssh_hardening ops
        printf "Include sshd_config.d/*.conf\n" > "$SSHD_CONFIG_FILE"
        assert_failed "a drop-in sshd does not read must fail the step"
        assert_out "allowusers: expected ops, effective none" "the missing values must be named"
        [ ! -e "$SSH_HARDENING_FILE" ] || die "an unread drop-in must be removed"
        assert_no_event "systemctl restart ssh.service"

        # sshd -T fails: the values cannot be confirmed, so the same.
        reset_ssh_case
        : > "$T/sshd_dump_fails"
        run_status configure_ssh_hardening ops
        assert_failed "a failed sshd -T must fail the step"
        assert_out "sshd -T failed" "the failed read-back must be named"
        [ ! -e "$SSH_HARDENING_FILE" ] || die "an unconfirmed drop-in must be removed"
        assert_no_event "systemctl restart ssh.service"
    '
}

test_ssh_hardening_replaces_the_legacy_dropin() {
    run_case "$SSH_CASE_SETUP"'
        # The drop-in of an earlier version goes: its AllowUsers would add to ours.
        reset_ssh_case
        printf "# SSH Hardening - VPS Optimization\nPermitRootLogin no\nAllowUsers old\n" > "$SSH_LEGACY_HARDENING_FILE"
        run_status configure_ssh_hardening ops
        assert_rc 0 "hardening over an earlier version"
        [ ! -e "$SSH_LEGACY_HARDENING_FILE" ] || die "the earlier drop-in must be removed"
        assert_out "Removed the drop-in of an earlier version" "the removal must be reported"
        [ "$(sshd_effective | grep "^allowusers")" = "allowusers ops" ] || die "only the new AllowUsers may stay"
        assert_no_temp_leftovers

        # A rejected config puts the earlier drop-in back.
        reset_ssh_case
        printf "# SSH Hardening - VPS Optimization\nAllowUsers old\n" > "$SSH_LEGACY_HARDENING_FILE"
        : > "$T/sshd_test_fails"
        run_status configure_ssh_hardening ops
        assert_failed "invalid configuration must fail the step"
        [ "$(cat "$SSH_LEGACY_HARDENING_FILE")" = "$(printf "# SSH Hardening - VPS Optimization\nAllowUsers old")" ] || \
            die "the earlier drop-in must be restored"
        [ ! -e "$SSH_HARDENING_FILE" ] || die "the rejected drop-in must be removed"
        assert_no_temp_leftovers

        # An operator file with that name is not ours and stays.
        reset_ssh_case
        printf "# my settings\nPort 2222\n" > "$SSH_LEGACY_HARDENING_FILE"
        run_status configure_ssh_hardening ops
        assert_rc 0 "hardening next to an operator file"
        [ "$(cat "$SSH_LEGACY_HARDENING_FILE")" = "$(printf "# my settings\nPort 2222")" ] || die "an operator file must stay"
    '
}

test_ssh_hardening_step_stops_the_script() {
    # The step must abort the run when hardening fails: the caller exits.
    grep -Fxq 'configure_ssh_hardening "$NEW_USER" || exit 1' "$SCRIPT" || \
        fail "the SSH hardening step must stop the script on failure"
}

# Mocks for the swap step: the swap file and fstab live in the temporary tree, and the swap
# binaries are scripts (SWAPON_BIN and the others are variables) over a registry of active swaps
# ($SWAPS, lines "name bytes"). SWAPOFF_FAIL / FALLOCATE_FAIL make them fail.
SWAP_MOCKS='
    SWAPFILE_PATH="$T/swapfile"
    FSTAB_FILE="$T/fstab"
    SWAPS="$T/swaps"
    : > "$SWAPS"
    printf "UUID=abc / ext4 defaults 0 1\n" > "$FSTAB_FILE"
    export EVENTS SWAPS
    SWAPON_BIN="$T/swapon"
    SWAPOFF_BIN="$T/swapoff"
    MKSWAP_BIN="$T/mkswap"
    FALLOCATE_BIN="$T/fallocate"
    cat > "$SWAPON_BIN" <<"MOCK"
#!/bin/sh
case "$*" in
    "--show=NAME --noheadings") awk "{ print \$1 }" "$SWAPS" ;;
    "--show --noheadings --bytes") awk "{ print \$1, \"file\", \$2, 0, -2 }" "$SWAPS" ;;
    /*) echo "swapon $1" >> "$EVENTS"; printf "%s %s\n" "$1" "$(stat -c %s "$1")" >> "$SWAPS" ;;
    *) exit 2 ;;
esac
MOCK
    cat > "$SWAPOFF_BIN" <<"MOCK"
#!/bin/sh
echo "swapoff $1" >> "$EVENTS"
[ -z "${SWAPOFF_FAIL:-}" ] || { echo "swapoff: $1: Cannot allocate memory" >&2; exit 1; }
awk -v p="$1" "\$1 != p" "$SWAPS" > "$SWAPS.new"
mv "$SWAPS.new" "$SWAPS"
MOCK
    cat > "$MKSWAP_BIN" <<"MOCK"
#!/bin/sh
echo "mkswap $1" >> "$EVENTS"
MOCK
    cat > "$FALLOCATE_BIN" <<"MOCK"
#!/bin/sh
echo "fallocate $*" >> "$EVENTS"
[ -z "${FALLOCATE_FAIL:-}" ] || exit 1
truncate -s "$2" "$3"
MOCK
    chmod +x "$SWAPON_BIN" "$SWAPOFF_BIN" "$MKSWAP_BIN" "$FALLOCATE_BIN"
    dd() {
        local arg count=0 out=""
        for arg in "$@"; do
            case "$arg" in of=*) out="${arg#of=}" ;; count=*) count="${arg#count=}" ;; esac
        done
        event "dd count=$count"
        truncate -s "${count}G" "$out"
    }
    # An active swap file of $1 (a size for truncate) with $2 lines in fstab.
    seed_swapfile() {
        local n
        truncate -s "$1" "$SWAPFILE_PATH"
        printf "%s %s\n" "$SWAPFILE_PATH" "$(stat -c %s "$SWAPFILE_PATH")" >> "$SWAPS"
        for ((n = 0; n < $2; n++)); do printf "%s none swap sw 0 0\n" "$SWAPFILE_PATH" >> "$FSTAB_FILE"; done
    }
    fstab_swap_lines() { grep -c "^$SWAPFILE_PATH " "$FSTAB_FILE" || true; }
    assert_one_fstab_line() {
        [ "$(fstab_swap_lines)" = 1 ] || die "fstab must have exactly one swap file line: $(cat "$FSTAB_FILE")"
        grep -Fxq "UUID=abc / ext4 defaults 0 1" "$FSTAB_FILE" || die "other fstab lines must stay: $(cat "$FSTAB_FILE")"
    }
'

test_swap_active_file_of_the_right_size_is_kept() {
    run_case "$SWAP_MOCKS"'
        seed_swapfile 2G 2
        inode="$(stat -c %i "$SWAPFILE_PATH")"
        run_status setup_swap_file 2
        assert_rc 0 "an active swap file of the right size"
        assert_out "keeping it" "the kept swap file must be said"
        assert_no_event_matches "^(swapoff|mkswap|swapon|fallocate|dd) "
        [ "$(stat -c %i "$SWAPFILE_PATH")" = "$inode" ] || die "the swap file must not be recreated"
        assert_one_fstab_line
    '
}

test_swap_active_file_of_another_size_is_recreated() {
    run_case "$SWAP_MOCKS"'
        seed_swapfile 1G 1
        run_status setup_swap_file 2
        assert_rc 0 "an active swap file of another size"
        [ "$(event_log)" = "swapoff $SWAPFILE_PATH|fallocate -l 2G $SWAPFILE_PATH|mkswap $SWAPFILE_PATH|swapon $SWAPFILE_PATH|" ] || \
            die "expected swapoff, new file, mkswap, swapon in this order: $(event_log)"
        [ "$(stat -c %s "$SWAPFILE_PATH")" = $((2 * 1024 * 1024 * 1024)) ] || die "the new swap file must have the new size"
        [ "$(stat -c %a "$SWAPFILE_PATH")" = 600 ] || die "the swap file must be 600"
        assert_one_fstab_line
    '
}

test_swap_failed_swapoff_keeps_the_active_file() {
    run_case "$SWAP_MOCKS"'
        seed_swapfile 1G 1
        export SWAPOFF_FAIL=1
        run_status setup_swap_file 2
        assert_rc 0 "a failed swapoff must not stop the script"
        assert_out "Could not turn off" "the failed swapoff must be warned about"
        assert_event "swapoff $SWAPFILE_PATH"
        assert_no_event_matches "^(mkswap|swapon|fallocate|dd) "
        [ "$(stat -c %s "$SWAPFILE_PATH")" = $((1024 * 1024 * 1024)) ] || die "the active swap file must stay as it was"
        grep -Fxq "$SWAPFILE_PATH 1073741824" "$SWAPS" || die "the swap must stay active"
        assert_one_fstab_line
    '
}

test_swap_created_once_and_kept_on_a_second_run() {
    run_case "$SWAP_MOCKS"'
        run_status setup_swap_file 2
        assert_rc 0 "no swap yet"
        [ "$(event_log)" = "fallocate -l 2G $SWAPFILE_PATH|mkswap $SWAPFILE_PATH|swapon $SWAPFILE_PATH|" ] || \
            die "expected a new file, mkswap, swapon: $(event_log)"
        assert_no_event_matches "^swapoff "
        assert_one_fstab_line
        # The second run changes nothing.
        : > "$EVENTS"
        run_status setup_swap_file 2
        assert_rc 0 "a second run"
        assert_no_event_matches "^(swapoff|mkswap|swapon|fallocate|dd) "
        assert_out "keeping it" "the second run must keep the swap file"
        assert_one_fstab_line
    '
}

test_swap_falls_back_to_dd() {
    run_case "$SWAP_MOCKS"'
        export FALLOCATE_FAIL=1
        run_status setup_swap_file 2
        assert_rc 0 "fallocate unavailable"
        assert_event "dd count=2"
        assert_event "mkswap $SWAPFILE_PATH"
        assert_event "swapon $SWAPFILE_PATH"
        assert_one_fstab_line
    '
}

test_swap_review_cases() {
    # A kept file gets mode 600: swapped-out memory must not be readable by others.
    run_case "$SWAP_MOCKS"'
        seed_swapfile 2G 1
        chmod 644 "$SWAPFILE_PATH"
        setup_swap_file 2 > "$T/out" 2>&1
        [ "$(stat -c %a "$SWAPFILE_PATH")" = 600 ] || die "a kept swap file must become 600"
        [ "$SWAP_FILE_STATE" = kept ] || die "the state must be kept, got $SWAP_FILE_STATE"
    '
    # The operator swap line with its own fields and options stays as it is.
    run_case "$SWAP_MOCKS"'
        seed_swapfile 2G 0
        printf "%s swap swap defaults,pri=5 0 0\n" "$SWAPFILE_PATH" >> "$FSTAB_FILE"
        run_status setup_swap_file 2
        assert_rc 0 "an operator fstab line"
        grep -Fxq "$SWAPFILE_PATH swap swap defaults,pri=5 0 0" "$FSTAB_FILE" || die "the operator fstab line must stay: $(cat "$FSTAB_FILE")"
        assert_one_fstab_line
    '
    # An fstab without a final newline gets ours on a line of its own.
    run_case "$SWAP_MOCKS"'
        printf "UUID=abc / ext4 defaults 0 1" > "$FSTAB_FILE"
        setup_swap_file 2 > "$T/out" 2>&1
        assert_one_fstab_line
        [ "$SWAP_FILE_STATE" = created ] || die "the state must be created, got $SWAP_FILE_STATE"
    '
    # A failed swapoff leaves the state unchanged for the messages of the caller.
    run_case "$SWAP_MOCKS"'
        seed_swapfile 1G 1
        export SWAPOFF_FAIL=1
        setup_swap_file 2 >/dev/null 2>&1
        [ "$SWAP_FILE_STATE" = unchanged ] || die "the state must be unchanged, got $SWAP_FILE_STATE"
    '
    # Something that is not a regular file is left alone.
    run_case "$SWAP_MOCKS"'
        mkdir "$SWAPFILE_PATH"
        run_status setup_swap_file 2
        assert_rc 0 "a directory at the swap file path"
        assert_out "not a regular file" "the skipped path must be named"
        assert_no_event_matches "^(swapoff|mkswap|swapon|fallocate|dd) "
        [ -d "$SWAPFILE_PATH" ] || die "the directory must stay"
    '
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
    test_ssh_hardening_effective_values
    test_ssh_hardening_replaces_the_legacy_dropin
    test_ssh_hardening_step_stops_the_script
    test_ssh_hardening_paths
    test_swap_active_file_of_the_right_size_is_kept
    test_swap_active_file_of_another_size_is_recreated
    test_swap_failed_swapoff_keeps_the_active_file
    test_swap_created_once_and_kept_on_a_second_run
    test_swap_falls_back_to_dd
    test_swap_review_cases
    printf 'PASS: %s\n' "$(basename "$0")"
}

main "$@"

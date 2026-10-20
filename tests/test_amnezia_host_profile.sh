#!/usr/bin/env bash
# SC2016: case bodies are single-quoted on purpose, they run in a separate bash.
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Common prelude for every behavioral case: sources the script without running
# main, isolates the environment, and provides event-log assertions. Each case
# runs in its own bash process and removes its temp directory on exit.
read -r -d '' CASE_HEADER <<'HEADER_EOF' || true
set -euo pipefail
OPTIMIZE_SOURCE_ONLY=1
source "$SCRIPT_ROOT/optimize_amnezia_host.sh"
LOG_FILE=""
unset SUDO_USER SSH_CONNECTION SSH_CLIENT || true
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
EVENTS="$T/events"
: > "$EVENTS"

die() { printf "FAIL: %s\n" "$*" >&2; exit 1; }
event() { printf "%s\n" "$*" >> "$EVENTS"; }
run_status() { set +e; ( set -e; "$@" ) > "$T/out" 2>&1; RC=$?; set -e; }
assert_rc() { [ "$RC" -eq "$1" ] || die "$2 (rc=$RC, expected $1): $(cat "$T/out")"; }
assert_failed() { [ "$RC" -ne 0 ] || die "$1 (expected a non-zero exit): $(cat "$T/out")"; }
assert_out() { grep -Fq -- "$1" "$T/out" || die "$2: output lacks '$1': $(cat "$T/out")"; }
assert_no_out() { ! grep -Fq -- "$1" "$T/out" || die "$2: output has '$1': $(cat "$T/out")"; }
event_index() { awk -v e="$1" '$0 == e { print NR; exit }' "$EVENTS"; }
event_log() { tr "\n" "|" < "$EVENTS"; }
assert_event() { [ -n "$(event_index "$1")" ] || die "missing event '$1' in: $(event_log)"; }
assert_no_event() { [ -z "$(event_index "$1")" ] || die "unexpected event '$1' in: $(event_log)"; }
assert_event_matches() { grep -Eq -- "$1" "$EVENTS" || die "no event matches '$1' in: $(event_log)"; }
assert_no_event_matches() { ! grep -Eq -- "$1" "$EVENTS" || die "unexpected event matches '$1' in: $(event_log)"; }
assert_before() {
    local first second
    first="$(event_index "$1")"
    second="$(event_index "$2")"
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || \
        die "expected '$1' before '$2' in: $(event_log)"
}
HEADER_EOF

run_case() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c "$CASE_HEADER"$'\n'"$1"
}

test_release_and_firewall_helpers() {
    run_case '
        validate_firewall_phase bootstrap
        validate_firewall_phase locked
        ! validate_firewall_phase something-else || die "invalid firewall phase must be rejected"

        [[ "$(firewall_udp_rule_for_phase bootstrap)" == "all-udp-temporary" ]]
        [[ "$(firewall_udp_rule_for_phase locked)" == "8443/udp" ]]

        validate_swap_size_gb 2
        validate_swap_size_gb 16
        ! validate_swap_size_gb 0 || die "zero swap size must be rejected"
        ! validate_swap_size_gb nope || die "non-numeric swap size must be rejected"

        validate_username snaplyze
        ! validate_username 1234 || die "numeric-only usernames must be rejected"

        validate_port 22
        validate_port 8443
        validate_port 65535
        ! validate_port 0 || die "port 0 must be rejected"
        ! validate_port 70000 || die "port > 65535 must be rejected"
        ! validate_port invalid || die "non-numeric port must be rejected"
    '
}

test_existing_user_requires_authorized_keys_before_hardening() {
    run_case '
        TARGET_USER=sample
        tmp_home="$T/home"
        mkdir -p "$tmp_home"

        user_home_for() {
            [ "$1" = "sample" ] || return 1
            printf "%s\n" "$tmp_home"
        }

        ! target_user_has_authorized_keys "$TARGET_USER" || die "user without authorized_keys must not pass SSH key preflight"

        mkdir -p "$tmp_home/.ssh"
        printf "%s\n" "# only a comment" > "$tmp_home/.ssh/authorized_keys"
        ! target_user_has_authorized_keys "$TARGET_USER" || die "authorized_keys without a key line must not pass SSH key preflight"

        printf "%s\n" "ssh-ed25519 AAAATEST sample@example" > "$tmp_home/.ssh/authorized_keys"
        target_user_has_authorized_keys "$TARGET_USER"
    '
}

# --- parse_args -----------------------------------------------------------

test_parse_args_target_user_resolution() {
    run_case '
        resolve() { parse_args "$@"; resolve_target_user; printf "%s\n" "$TARGET_USER" > "$T/user"; }

        # No --user, run through sudo by a regular user: SUDO_USER is the operator.
        SUDO_USER=admin
        run_status resolve --yes
        assert_rc 0 "sudo run without --user must succeed"
        [ "$(cat "$T/user")" = "admin" ] || die "SUDO_USER must become the target user, got $(cat "$T/user")"

        # An explicit --user wins over SUDO_USER.
        run_status resolve --user ops --yes
        assert_rc 0 "--user must succeed"
        [ "$(cat "$T/user")" = "ops" ] || die "--user must win over SUDO_USER, got $(cat "$T/user")"

        # --user after other options and without SUDO_USER.
        unset SUDO_USER
        run_status resolve --yes --user ops
        assert_rc 0 "--user without SUDO_USER must succeed"
        [ "$(cat "$T/user")" = "ops" ] || die "--user must set the target user, got $(cat "$T/user")"

        # Root without sudo and without --user: no implicit user.
        run_status resolve --yes
        assert_failed "run without --user and without SUDO_USER must fail"
        assert_out "--user" "the error must point at --user"

        # sudo from a root shell reports SUDO_USER=root: not an operator either.
        SUDO_USER=root
        run_status resolve --yes
        assert_failed "SUDO_USER=root must not become the target user"
        assert_out "--user" "the error must point at --user"

        # --user needs a non-empty value.
        run_status resolve --user
        assert_failed "--user without a value must fail"
        assert_out "--user requires a value" "missing --user value"
        SUDO_USER=admin
        run_status resolve --user ""
        assert_failed "--user with an empty value must fail even under sudo"
        assert_out "--user requires a value" "empty --user value"
    '
}

test_parse_args_rejects_invalid_input() {
    run_case '
        key_file="$T/keys.pub"
        printf "%s\n" "ssh-ed25519 AAAATEST ops@example" > "$key_file"

        run_status parse_args --user ops --frobnicate
        assert_failed "unknown option must fail"
        assert_out "Unknown option: --frobnicate" "unknown option message"
        assert_out "Usage:" "unknown option must print usage"

        for option in --user --ssh-public-key --ssh-public-key-file --ssh-port --xray-port --amneziawg-port --swap-size-gb --firewall-phase; do
            run_status parse_args --yes "$option"
            assert_failed "$option without a value must fail"
            assert_out "$option requires a value" "$option without a value"
        done

        run_status parse_args --user ops --firewall-phase something-else
        assert_failed "invalid firewall phase must fail"
        assert_out "Unsupported firewall phase" "invalid firewall phase message"

        run_status parse_args --user ops --ssh-public-key-file "$T/missing.pub"
        assert_failed "missing public key file must fail"
        assert_out "SSH public key file not found" "missing public key file message"

        run_status parse_args --user ops --ssh-public-key-file "$key_file"
        assert_rc 0 "existing public key file must be accepted"

        for option in --ssh-port --xray-port --amneziawg-port; do
            for port in 0 70000 invalid; do
                run_status parse_args --user ops "$option" "$port"
                assert_failed "$option $port must fail"
                assert_out "port" "$option $port message"
            done
            run_status parse_args --user ops "$option" 65535
            assert_rc 0 "$option 65535 must be accepted"
        done

        run_status parse_args --user root
        assert_failed "--user root must be rejected"
        assert_out "root cannot be the target user" "root target user message"

        run_status parse_args --user ops --ssh-port 443
        assert_failed "SSH port equal to the XRay port must be rejected"
        assert_out "must differ" "port clash message"
        run_status parse_args --user ops --ssh-port 8444 --xray-port 8444
        assert_failed "equal custom SSH and XRay ports must be rejected"
        run_status parse_args --user ops --ssh-port 8443
        assert_rc 0 "SSH port equal to the AmneziaWG (UDP) port is allowed"

        run_status parse_args --user ops --swap-size-gb 0
        assert_failed "zero swap size must fail"
        assert_out "Unsupported swap size" "swap size message"

        run_status parse_args --help
        assert_rc 0 "--help must succeed"
        assert_out "Usage:" "--help must print usage"
        assert_out "--user <name>" "usage must document --user"
        assert_no_out "snaplyze" "usage must not hard-code a personal default user"
    '
}

test_parse_args_applies_options() {
    run_case '
        parse_args --user ops
        [ "$SSH_PORT" = 22 ] && [ "$XRAY_PORT" = 443 ] && [ "$AMNEZIAWG_PORT" = 8443 ] || die "default ports changed"
        [ "$FIREWALL_PHASE" = bootstrap ] && [ "$SWAP_SIZE_GB" = 2 ] || die "default phase or swap size changed"
        $INSTALL_DOCKER && $INSTALL_FISH && ! $INSTALL_KERNEL_BACKPORTS && ! $CREATE_USER && ! $SKIP_SWAP && ! $ASSUME_YES || die "default flags changed"

        key_file="$T/keys.pub"
        : > "$key_file"
        parse_args --user ops --create-user --ssh-public-key "ssh-ed25519 AAAA k" --ssh-public-key-file "$key_file" \
            --ssh-port 2222 --xray-port 8444 --amneziawg-port 9443 --swap-size-gb 4 \
            --skip-swap --skip-docker --skip-fish --kernel-backports --firewall-phase locked --yes
        [ "$TARGET_USER" = ops ] || die "--user not applied"
        $CREATE_USER || die "--create-user not applied"
        [ "$SSH_PUBLIC_KEY" = "ssh-ed25519 AAAA k" ] || die "--ssh-public-key not applied"
        [ "$SSH_PUBLIC_KEY_FILE" = "$key_file" ] || die "--ssh-public-key-file not applied"
        [ "$SSH_PORT" = 2222 ] || die "--ssh-port not applied"
        [ "$XRAY_PORT" = 8444 ] || die "--xray-port not applied"
        [ "$AMNEZIAWG_PORT" = 9443 ] || die "--amneziawg-port not applied"
        [ "$SWAP_SIZE_GB" = 4 ] || die "--swap-size-gb not applied"
        $SKIP_SWAP || die "--skip-swap not applied"
        ! $INSTALL_DOCKER || die "--skip-docker not applied"
        ! $INSTALL_FISH || die "--skip-fish not applied"
        $INSTALL_KERNEL_BACKPORTS || die "--kernel-backports not applied"
        [ "$FIREWALL_PHASE" = locked ] || die "--firewall-phase not applied"
        $ASSUME_YES || die "--yes not applied"
    '
}

# --- SSH session check ----------------------------------------------------

test_login_user_warning() {
    run_case '
        TARGET_USER=ops
        login_check() { warn_if_login_user_not_target_user; printf "CONTINUED\n"; }
        unset SSH_CONNECTION SSH_CLIENT

        # The target user ran the script: no warning.
        SUDO_USER=ops
        ASSUME_YES=false
        run_status login_check </dev/null
        assert_rc 0 "target user"
        assert_no_out "logged in as" "target user must not warn"
        assert_out CONTINUED "target user must continue"

        # Another user with --yes, without SSH variables (sudo drops them): warning only.
        SUDO_USER=admin
        ASSUME_YES=true
        run_status login_check </dev/null
        assert_rc 0 "--yes must only warn"
        assert_out "logged in as admin" "warning must name the logged-in user"
        assert_out "AllowUsers" "warning must explain AllowUsers"
        assert_out CONTINUED "--yes must continue"

        # Interactive: confirmation required.
        ASSUME_YES=false
        run_status login_check <<< "y"
        assert_out "logged in as admin" "interactive warning"
        assert_out CONTINUED "answer y must continue"
        run_status login_check <<< "n"
        assert_rc 0 "answer n exits cleanly"
        assert_out "Aborted by user" "answer n must abort"
        assert_no_out CONTINUED "answer n must not continue"
        run_status login_check </dev/null
        assert_out "Aborted by user" "no answer must abort"
        assert_no_out CONTINUED "no answer must not continue"

        # Without sudo the logged-in user comes from logname (direct root login).
        unset SUDO_USER
        logname() { printf "root\n"; }
        run_status login_check <<< "n"
        assert_out "logged in as root" "root login must be reported"
        assert_no_out CONTINUED "root login with answer n must not continue"

        # Unknown logged-in user: warn, do not block.
        logname() { return 1; }
        run_status login_check </dev/null
        assert_rc 0 "unknown logged-in user"
        assert_out "Cannot determine the logged-in user" "unknown user warning"
        assert_out CONTINUED "unknown user must continue"
    '
}

# --- create_target_user_if_needed -----------------------------------------

USER_CASE_SETUP='
    TARGET_USER=ops
    ADDUSER_BIN=mock_adduser
    HOME_DIR="$T/home/ops"

    id() { [ -e "$T/user_exists" ]; }
    mock_adduser() { event "adduser $*"; mkdir -p "$HOME_DIR"; : > "$T/user_exists"; }
    user_home_for() {
        case "$1" in
            ops) printf "%s\n" "$HOME_DIR" ;;
            admin) printf "%s\n" "$T/home/admin" ;;
            *) return 1 ;;
        esac
    }
    install() { event "install $*"; mkdir -p "${@: -1}"; }
    chown() { event "chown $*"; }

    reset_user_case() {
        rm -rf "$T/home" "$T/user_exists"
        : > "$EVENTS"
        mkdir -p "$T/home"
        SSH_PUBLIC_KEY=""
        SSH_PUBLIC_KEY_FILE=""
        ASSUME_YES=true
        unset SUDO_USER || true
    }
    keys_file() { printf "%s\n" "$HOME_DIR/.ssh/authorized_keys"; }
    mode_of() { stat -c %a "$1"; }
'

test_create_user_existing_user_branches() {
    run_case "$USER_CASE_SETUP"'
        # Existing user, no keys anywhere: stop before SSH password login is disabled.
        reset_user_case
        : > "$T/user_exists"
        mkdir -p "$HOME_DIR"
        run_status create_target_user_if_needed
        assert_failed "existing user without keys must fail"
        assert_out "has no authorized_keys" "existing user without keys"
        assert_no_event_matches "^adduser"

        # Existing user that already has a key and no new source: succeeds, key untouched.
        mkdir -p "$HOME_DIR/.ssh"
        printf "%s\n" "ssh-ed25519 AAAAOLD old@example" > "$(keys_file)"
        run_status create_target_user_if_needed
        assert_rc 0 "existing user with keys"
        [ "$(cat "$(keys_file)")" = "ssh-ed25519 AAAAOLD old@example" ] || die "existing keys must stay untouched"
        assert_no_event_matches "^adduser"
        assert_out "Using existing user" "existing user message"

        # --ssh-public-key is merged without duplicates, run twice.
        reset_user_case
        : > "$T/user_exists"
        SSH_PUBLIC_KEY="ssh-ed25519 AAAANEW new@example"
        run_status create_target_user_if_needed
        assert_rc 0 "existing user with --ssh-public-key"
        run_status create_target_user_if_needed
        assert_rc 0 "existing user with --ssh-public-key, second run"
        [ "$(grep -Fxc "ssh-ed25519 AAAANEW new@example" "$(keys_file)")" = 1 ] || die "public key must be added exactly once"
        [ "$(mode_of "$(keys_file)")" = 600 ] || die "authorized_keys must be mode 600"
        assert_event "chown ops:ops $(keys_file)"
        assert_event_matches "^install -d -m 700 -o ops -g ops .*/home/ops/.ssh$"

        # --ssh-public-key-file is merged duplicate-safe into existing keys.
        reset_user_case
        : > "$T/user_exists"
        mkdir -p "$HOME_DIR/.ssh"
        printf "%s\n" "ssh-ed25519 AAAAONE one@example" > "$(keys_file)"
        SSH_PUBLIC_KEY_FILE="$T/source.pub"
        printf "%s\n%s\n\n" "ssh-ed25519 AAAAONE one@example" "ssh-ed25519 AAAATWO two@example" > "$SSH_PUBLIC_KEY_FILE"
        run_status create_target_user_if_needed
        assert_rc 0 "existing user with --ssh-public-key-file"
        [ "$(wc -l < "$(keys_file)")" = 2 ] || die "merge must add only the missing key: $(cat "$(keys_file)")"
        grep -Fxq "ssh-ed25519 AAAATWO two@example" "$(keys_file)" || die "missing key must be merged"
        [ -z "$(sort "$(keys_file)" | uniq -d)" ] || die "merge must not duplicate keys"
        [ "$(mode_of "$(keys_file)")" = 600 ] || die "merged authorized_keys must be mode 600"

        # Keys of the invoking sudo user are the fallback source.
        reset_user_case
        : > "$T/user_exists"
        mkdir -p "$T/home/admin/.ssh"
        printf "%s\n" "ssh-ed25519 AAAAADM admin@example" > "$T/home/admin/.ssh/authorized_keys"
        SUDO_USER=admin
        run_status create_target_user_if_needed
        assert_rc 0 "existing user with sudo user keys"
        grep -Fxq "ssh-ed25519 AAAAADM admin@example" "$(keys_file)" || die "sudo user keys must be merged"
    '
}

test_create_user_new_user_branches() {
    run_case "$USER_CASE_SETUP"'
        # New user with an explicit public key.
        reset_user_case
        SSH_PUBLIC_KEY="ssh-ed25519 AAAAKEY key@example"
        run_status create_target_user_if_needed
        assert_rc 0 "new user with --ssh-public-key"
        assert_event "adduser --gecos  --disabled-password ops"
        assert_before "adduser --gecos  --disabled-password ops" "chown ops:ops $(keys_file)"
        [ "$(cat "$(keys_file)")" = "ssh-ed25519 AAAAKEY key@example" ] || die "explicit key must be the only key"
        [ "$(mode_of "$(keys_file)")" = 600 ] || die "authorized_keys must be mode 600"

        # New user with a key file.
        reset_user_case
        SSH_PUBLIC_KEY_FILE="$T/source.pub"
        printf "%s\n%s\n" "ssh-ed25519 AAAAONE one@example" "ssh-ed25519 AAAATWO two@example" > "$SSH_PUBLIC_KEY_FILE"
        run_status create_target_user_if_needed
        assert_rc 0 "new user with --ssh-public-key-file"
        assert_event "adduser --gecos  --disabled-password ops"
        [ "$(wc -l < "$(keys_file)")" = 2 ] || die "key file must be merged: $(cat "$(keys_file)")"
        [ "$(mode_of "$(keys_file)")" = 600 ] || die "authorized_keys must be mode 600"

        # New user with the invoking sudo user keys.
        reset_user_case
        mkdir -p "$T/home/admin/.ssh"
        printf "%s\n" "ssh-ed25519 AAAAADM admin@example" > "$T/home/admin/.ssh/authorized_keys"
        SUDO_USER=admin
        run_status create_target_user_if_needed
        assert_rc 0 "new user with sudo user keys"
        grep -Fxq "ssh-ed25519 AAAAADM admin@example" "$(keys_file)" || die "sudo user keys must be copied"

        # Non-interactive without any key source: error.
        reset_user_case
        run_status create_target_user_if_needed
        assert_failed "new user without a key source must fail with --yes"
        assert_out "Pass --ssh-public-key or --ssh-public-key-file" "missing key source hint"
        [ ! -s "$(keys_file)" ] || die "no key may be written without a source"

        # Interactive without a key source: the pasted key is used, an empty answer fails.
        reset_user_case
        ASSUME_YES=false
        run_status create_target_user_if_needed <<< "ssh-ed25519 AAAAPASTE paste@example"
        assert_rc 0 "interactive pasted key"
        grep -Fxq "ssh-ed25519 AAAAPASTE paste@example" "$(keys_file)" || die "pasted key must be written"
        reset_user_case
        ASSUME_YES=false
        run_status create_target_user_if_needed <<< ""
        assert_failed "empty pasted key must fail"
        assert_out "cannot be empty" "empty pasted key message"

        # Invalid username: rejected before adduser runs.
        reset_user_case
        TARGET_USER="Bad_Name"
        SSH_PUBLIC_KEY="ssh-ed25519 AAAAKEY key@example"
        run_status create_target_user_if_needed
        assert_failed "invalid username must fail"
        assert_no_event_matches "^adduser"
    '
}

test_target_user_privileges() {
    run_case '
        TARGET_USER=ops
        usermod() { event "usermod $*"; }
        getent() { [ "$1" = group ] && [ "$2" = docker ] && [ -e "$T/docker_group" ]; }
        common_safe_write_sudoers() { event "sudoers $1|$2"; }

        ensure_target_user_privileges >/dev/null
        assert_event "usermod -aG sudo ops"
        assert_event "sudoers /etc/sudoers.d/ops|ops ALL=(ALL) NOPASSWD:ALL"
        assert_event "sudoers /etc/sudoers.d/root|root ALL=(ALL) NOPASSWD:ALL"
        assert_no_event "usermod -aG docker ops"

        : > "$T/docker_group"
        ensure_target_user_privileges >/dev/null
        assert_event "usermod -aG docker ops"
    '
}

test_base_packages_include_fail2ban_journal_backend() {
    run_case '
        common_apt_update() { event "apt-update $1"; }
        common_apt_get() { event "apt-get $*"; }
        common_safe_install() { event "safe_install $*"; }

        install_base_packages >/dev/null
        assert_event_matches "^safe_install .*(^| )python3-systemd( |$)"
        assert_event_matches "^safe_install .*(^| )fail2ban( |$)"
        assert_event_matches "^safe_install .*(^| )ufw( |$)"
        assert_before "apt-update initial package refresh" "apt-get upgrade -y"
    '
}

test_fail2ban_jail_is_backed_up_before_overwrite() {
    run_case '
        FAIL2BAN_JAIL_FILE="$T/fail2ban/jail.local"
        mkdir -p "$T/fail2ban"
        common_systemd_running() { return 1; }
        # A distinct stamp per call keeps two backups made within one second apart.
        date() { local n; n=$(( $(cat "$T/clock" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/clock"; echo "TS$n"; }
        backups() { find "$T/fail2ban" -name "jail.local.backup.*" | wc -l; }

        # first run: nothing to preserve
        SSH_PORT=2222
        run_status configure_fail2ban
        assert_rc 0 "first configure_fail2ban"
        grep -Fxq "port = 2222" "$FAIL2BAN_JAIL_FILE" || die "jail lacks the SSH port"
        grep -Fxq "backend = systemd" "$FAIL2BAN_JAIL_FILE" || die "jail lacks the systemd backend"
        [ "$(backups)" = 0 ] || die "a fresh install must not create a backup"

        # same content again: no copy, file not rewritten (the old mtime survives)
        touch -d "2001-01-01" "$FAIL2BAN_JAIL_FILE"
        run_status configure_fail2ban
        assert_rc 0 "repeat configure_fail2ban"
        [ "$(backups)" = 0 ] || die "a repeat run with the same content must not create a backup"
        [ "$(stat -c %Y "$FAIL2BAN_JAIL_FILE")" -lt 1000000000 ] || die "an up-to-date jail must not be rewritten"

        # operator edit: kept in a copy, then replaced
        printf "# operator edit\n" >> "$FAIL2BAN_JAIL_FILE"
        run_status configure_fail2ban
        assert_rc 0 "configure_fail2ban over an edited jail"
        [ "$(backups)" = 1 ] || die "an edited jail must be backed up once, got $(backups)"
        ! grep -Fq "# operator edit" "$FAIL2BAN_JAIL_FILE" || die "the edited jail was not replaced"
        grep -Fxq "# operator edit" "$T"/fail2ban/jail.local.backup.* || die "the backup lacks the operator edit"
        run_status configure_fail2ban
        [ "$(backups)" = 1 ] || die "re-running after the restore must not add backups"

        # another port: the previous generation is kept as well
        SSH_PORT=3333
        run_status configure_fail2ban
        assert_rc 0 "configure_fail2ban with another port"
        [ "$(backups)" = 2 ] || die "a changed port must add one backup, got $(backups)"
        grep -Fxq "port = 3333" "$FAIL2BAN_JAIL_FILE" || die "the new port was not written"
        grep -Flx "port = 2222" "$T"/fail2ban/jail.local.backup.* > /dev/null || die "the old port generation was not kept"
    '
}

# --- configure_firewall ---------------------------------------------------

test_firewall_without_ufw_is_skipped() {
    run_case '
        mkdir -p "$T/empty"
        PATH="$T/empty" run_status configure_firewall
        assert_rc 0 "missing UFW must not fail the script"
        assert_out "UFW is not installed" "missing UFW warning"
    '
}

test_firewall_bootstrap_phase() {
    run_case '
        UFW_DEFAULTS_FILE="$T/ufw-defaults"
        printf "%s\n" "IPV6=yes" "DEFAULT_FORWARD_POLICY=\"DROP\"" > "$UFW_DEFAULTS_FILE"
        ufw() { event "ufw $*"; }

        SSH_PORT=2222
        XRAY_PORT=8444
        FIREWALL_PHASE=bootstrap
        run_status configure_firewall
        assert_rc 0 "bootstrap phase"

        grep -Fxq "DEFAULT_FORWARD_POLICY=\"ACCEPT\"" "$UFW_DEFAULTS_FILE" || die "UFW forward policy must become ACCEPT"
        grep -Fxq "IPV6=yes" "$UFW_DEFAULTS_FILE" || die "other UFW defaults must stay untouched"

        assert_event "ufw default deny incoming"
        assert_event "ufw default allow outgoing"
        assert_event "ufw allow 2222/tcp"
        assert_event "ufw allow 8444/tcp"
        assert_event "ufw allow from any to any proto udp comment Temporary AmneziaWG bootstrap allowance"
        assert_event "ufw --force enable"
        assert_before "ufw default deny incoming" "ufw --force enable"
        assert_before "ufw allow 2222/tcp" "ufw --force enable"
        assert_before "ufw allow 8444/tcp" "ufw --force enable"
        assert_before "ufw allow from any to any proto udp comment Temporary AmneziaWG bootstrap allowance" "ufw --force enable"
        assert_no_event_matches "delete"
        assert_no_event_matches "/udp"
        assert_out "temporary all-UDP ingress" "bootstrap phase must warn about open UDP"
    '
}

test_firewall_locked_phase() {
    run_case '
        UFW_DEFAULTS_FILE="$T/missing-ufw-defaults"
        ufw() { event "ufw $*"; }

        AMNEZIAWG_PORT=9443
        FIREWALL_PHASE=locked
        run_status configure_firewall
        assert_rc 0 "locked phase"

        [ ! -e "$UFW_DEFAULTS_FILE" ] || die "a missing UFW defaults file must not be created"
        assert_event "ufw allow 22/tcp"
        assert_event "ufw allow 443/tcp"
        assert_event "ufw --force delete allow from any to any proto udp"
        assert_event "ufw allow 9443/udp"
        assert_before "ufw allow 22/tcp" "ufw --force enable"
        assert_before "ufw allow 443/tcp" "ufw --force enable"
        assert_before "ufw --force delete allow from any to any proto udp" "ufw allow 9443/udp"
        assert_before "ufw allow 9443/udp" "ufw --force enable"
        assert_no_event_matches "comment"
        assert_out "Removed temporary bootstrap UDP allowance" "locked phase message"

        : > "$EVENTS"
        AMNEZIAWG_PORT=8443
        run_status configure_firewall
        assert_event "ufw allow 8443/udp"
    '
}

# --- configure_ssh_hardening ----------------------------------------------

SSH_CASE_SETUP='
    TARGET_USER=ops
    SSH_PORT=2222
    SSH_HARDENING_DROPIN="$T/sshd_config.d/99-test.conf"

    sshd() {
        event "sshd $*"
        if [ "${1:-}" = -T ]; then
            printf "port %s\n" "${CURRENT_SSH_PORT:-22}"
            return 0
        fi
        [ ! -e "$T/sshd_test_fails" ]
    }
    common_systemd_running() { [ ! -e "$T/no_systemd" ]; }
    systemctl() {
        event "systemctl $*"
        if [ -e "$T/units_fail_on_new_port" ] && grep -q "^Port 2222" "$SSH_HARDENING_DROPIN" 2>/dev/null; then
            printf "Job for %s failed: address already in use\n" "$2" >&2
            return 1
        fi
        case "$2" in
            ssh.service)
                if [ -e "$T/ssh_unit_fails" ]; then printf "Unit ssh.service not found\n" >&2; return 1; fi ;;
            sshd.service)
                if [ -e "$T/sshd_unit_fails" ]; then printf "Unit sshd.service not found\n" >&2; return 1; fi ;;
        esac
    }
    ufw() {
        event "ufw $*"
        if [ "$1" = status ]; then
            if [ -e "$T/ufw_active" ]; then printf "Status: active\n"; else printf "Status: inactive\n"; fi
            if [ -e "$T/ufw_has_ssh_rule" ]; then printf "2222/tcp                   ALLOW       Anywhere\n"; fi
        elif [ "$1" = allow ] && [ -e "$T/ufw_allow_fails" ]; then
            return 1
        fi
    }
    reset_ssh_case() {
        rm -rf "$T"/sshd_config.d "$T"/sshd_test_fails "$T"/no_systemd "$T"/ssh_unit_fails \
            "$T"/sshd_unit_fails "$T"/ufw_active "$T"/ufw_allow_fails "$T"/units_fail_on_new_port \
            "$T"/ufw_has_ssh_rule
        SSH_PORT_RULE_ADDED=false
        CURRENT_SSH_PORT=22
        : > "$EVENTS"
    }
    write_previous_dropin() {
        mkdir -p "$(dirname "$SSH_HARDENING_DROPIN")"
        printf "%s\n" "# previous valid drop-in" > "$SSH_HARDENING_DROPIN"
    }
'

test_ssh_hardening_dropin_and_order() {
    run_case "$SSH_CASE_SETUP"'
        # Active UFW: validate first, then open the port, then restart.
        reset_ssh_case
        : > "$T/ufw_active"
        run_status configure_ssh_hardening
        assert_rc 0 "SSH hardening with active UFW"
        assert_before "sshd -t" "ufw allow 2222/tcp"
        assert_before "ufw allow 2222/tcp" "systemctl restart ssh.service"

        for line in "AllowUsers ops" "PermitRootLogin no" "PasswordAuthentication no" "PubkeyAuthentication yes" "KbdInteractiveAuthentication no" "Port 2222"; do
            grep -Fxq "$line" "$SSH_HARDENING_DROPIN" || die "drop-in lacks: $line"
        done
        [ "$(grep -c "^AllowUsers" "$SSH_HARDENING_DROPIN")" = 1 ] || die "drop-in must have exactly one AllowUsers"

        # Inactive UFW: nothing to open, the restart still happens.
        reset_ssh_case
        run_status configure_ssh_hardening
        assert_rc 0 "SSH hardening with inactive UFW"
        assert_no_event "ufw allow 2222/tcp"
        assert_event "systemctl restart ssh.service"

        # Another user and the default port are rendered into the drop-in.
        reset_ssh_case
        TARGET_USER=operator
        SSH_PORT=22
        run_status configure_ssh_hardening
        assert_rc 0 "SSH hardening with default port"
        grep -Fxq "AllowUsers operator" "$SSH_HARDENING_DROPIN" || die "AllowUsers must follow TARGET_USER"
        grep -Fxq "Port 22" "$SSH_HARDENING_DROPIN" || die "Port must follow SSH_PORT"
    '
}

test_ssh_hardening_failures_are_visible() {
    run_case "$SSH_CASE_SETUP"'
        # ssh.service fails, sshd.service works: still success.
        reset_ssh_case
        : > "$T/ssh_unit_fails"
        run_status configure_ssh_hardening
        assert_rc 0 "fallback to sshd.service"
        assert_before "systemctl restart ssh.service" "systemctl restart sshd.service"

        # Both units fail: the output of both attempts is shown, the drop-in is removed.
        reset_ssh_case
        : > "$T/ssh_unit_fails"
        : > "$T/sshd_unit_fails"
        run_status configure_ssh_hardening
        assert_failed "failed SSH restart must stop the script"
        assert_out "Failed to restart the SSH service" "failed SSH restart message"
        assert_out "Unit ssh.service not found" "first attempt output"
        assert_out "Unit sshd.service not found" "second attempt output"
        [ ! -e "$SSH_HARDENING_DROPIN" ] || die "the new drop-in must not stay after a failed restart"

        # sshd -t fails, no previous drop-in: no firewall change, no restart, no leftover drop-in.
        reset_ssh_case
        : > "$T/ufw_active"
        : > "$T/sshd_test_fails"
        run_status configure_ssh_hardening
        assert_failed "invalid SSH configuration must stop the script"
        assert_out "SSH configuration test failed" "sshd -t failure message"
        assert_no_event_matches "^systemctl"
        assert_no_event "ufw allow 2222/tcp"
        [ ! -e "$SSH_HARDENING_DROPIN" ] || die "invalid drop-in must be removed"

        # sshd -t fails with a previous drop-in: it is restored.
        reset_ssh_case
        : > "$T/sshd_test_fails"
        write_previous_dropin
        run_status configure_ssh_hardening
        assert_failed "invalid SSH configuration must stop the script"
        assert_no_event_matches "^systemctl"
        [ "$(cat "$SSH_HARDENING_DROPIN")" = "# previous valid drop-in" ] || die "previous drop-in must be restored"

        # UFW cannot open the port: the drop-in is reverted and sshd is not restarted.
        reset_ssh_case
        : > "$T/ufw_active"
        : > "$T/ufw_allow_fails"
        write_previous_dropin
        run_status configure_ssh_hardening
        assert_failed "UFW failure must stop the script before restarting sshd"
        assert_out "Could not allow 2222/tcp" "UFW failure message"
        assert_no_event_matches "^systemctl"
        [ "$(cat "$SSH_HARDENING_DROPIN")" = "# previous valid drop-in" ] || die "previous drop-in must be restored after a UFW failure"
    '
}

test_ssh_hardening_rolls_back_failed_restart() {
    run_case "$SSH_CASE_SETUP"'
        # The new port is busy: sshd cannot start with the new drop-in. The previous
        # drop-in is put back and the service is restarted again before the script fails.
        reset_ssh_case
        : > "$T/units_fail_on_new_port"
        write_previous_dropin
        run_status configure_ssh_hardening
        assert_failed "failed restart must stop the script"
        [ "$(cat "$SSH_HARDENING_DROPIN")" = "# previous valid drop-in" ] || die "previous drop-in must be restored"
        [ "$(grep -Fxc "systemctl restart ssh.service" "$EVENTS")" = 2 ] || die "the SSH service must be restarted again after the rollback: $(event_log)"
        assert_out "address already in use" "the restart error must be visible"
        assert_out "$SSH_HARDENING_DROPIN" "the message must name the drop-in path"
        assert_out "running again" "a successful rollback must be reported"

        # The rule this run added for the busy port is removed again; an existing rule stays.
        reset_ssh_case
        : > "$T/units_fail_on_new_port"
        : > "$T/ufw_active"
        run_status configure_ssh_hardening
        assert_failed "failed restart must stop the script"
        grep -Fxq "ufw allow 2222/tcp" "$EVENTS" || die "the new port must be allowed before the restart: $(event_log)"
        grep -Fxq "ufw delete allow 2222/tcp" "$EVENTS" || die "the rule added for the failed change must be removed: $(event_log)"
        reset_ssh_case
        : > "$T/units_fail_on_new_port"
        : > "$T/ufw_active"
        : > "$T/ufw_has_ssh_rule"
        run_status configure_ssh_hardening
        assert_failed "failed restart must stop the script"
        assert_no_event_matches "^ufw (allow|delete)"

        # No previous drop-in: ours is removed and sshd is restarted without it.
        reset_ssh_case
        : > "$T/units_fail_on_new_port"
        run_status configure_ssh_hardening
        assert_failed "failed restart must stop the script"
        [ ! -e "$SSH_HARDENING_DROPIN" ] || die "the new drop-in must be removed when there was none before"
        [ "$(grep -Fxc "systemctl restart ssh.service" "$EVENTS")" = 2 ] || die "the SSH service must be restarted again after the rollback"

        # sshd stays down even after the rollback: the operator gets the path and a console hint.
        reset_ssh_case
        : > "$T/ssh_unit_fails"
        : > "$T/sshd_unit_fails"
        write_previous_dropin
        run_status configure_ssh_hardening
        assert_failed "unrecoverable restart failure"
        assert_out "still does not start" "unrecoverable failure message"
        assert_out "$SSH_HARDENING_DROPIN" "the message must name the drop-in path"
    '
}

test_ssh_hardening_without_systemd() {
    run_case "$SSH_CASE_SETUP"'
        # Moving sshd to another port needs a restart: refuse before touching anything.
        reset_ssh_case
        : > "$T/no_systemd"
        : > "$T/ufw_active"
        write_previous_dropin
        run_status configure_ssh_hardening
        assert_failed "port change without systemd must stop the script"
        assert_out "cannot be restarted" "no systemd message"
        assert_no_event_matches "^(systemctl|ufw allow)"
        [ "$(cat "$SSH_HARDENING_DROPIN")" = "# previous valid drop-in" ] || die "the drop-in must stay untouched"

        # The port the daemon already listens on: drop-in written, restart left to the operator.
        reset_ssh_case
        : > "$T/no_systemd"
        CURRENT_SSH_PORT=2222
        run_status configure_ssh_hardening
        assert_rc 0 "unchanged port without systemd"
        assert_no_event_matches "^systemctl"
        grep -Fxq "Port 2222" "$SSH_HARDENING_DROPIN" || die "drop-in must be written"
        assert_out "restart the SSH service manually" "no systemd hint"
    '
}

test_product_paths_default_to_system_locations() {
    run_case '
        [ "$SSH_HARDENING_DROPIN" = "/etc/ssh/sshd_config.d/99-amnezia-host-hardening.conf" ] || die "SSH hardening must use the dedicated drop-in"
        [ "$UFW_DEFAULTS_FILE" = "/etc/default/ufw" ] || die "UFW defaults path changed"
        [ "$ADDUSER_BIN" = "/usr/sbin/adduser" ] || die "adduser path changed"
        [ "$SYSCTL_CONF_FILE" = "/etc/sysctl.d/99-amnezia-host.conf" ] || die "sysctl must use the dedicated file"
        [ "$MODULES_LOAD_FILE" = "/etc/modules-load.d/99-amnezia-host.conf" ] || die "modules-load path changed"
        [ "$LIMITS_CONF_FILE" = "/etc/security/limits.d/99-amnezia-limits.conf" ] || die "limits path changed"
        [ "$SWAPFILE_PATH" = "/swapfile" ] || die "the swapfile must be a dedicated /swapfile"
        [ "$FSTAB_FILE" = "/etc/fstab" ] || die "fstab path changed"
        [ "$FAIL2BAN_JAIL_FILE" = "/etc/fail2ban/jail.local" ] || die "fail2ban jail path changed"
        [ "$DOCKER_SOURCES_FILE" = "/etc/apt/sources.list.d/docker.sources" ] || die "Docker must use docker.sources"
        [ "$DOCKER_KEYRING" = "/etc/apt/keyrings/docker.gpg" ] || die "Docker keyring path changed"
        [ "$ROOT_HOME" = "/root" ] || die "root home path changed"
        [ -z "$TARGET_USER" ] || die "TARGET_USER must have no personal default"
    '
}

# --- sysctl, swap, Docker, Fish/Starship ----------------------------------

test_sysctl_baseline() {
    run_case '
        SYSCTL_CONF_FILE="$T/sysctl.d/99-test.conf"
        MODULES_LOAD_FILE="$T/modules-load.d/99-test.conf"
        LIMITS_CONF_FILE="$T/limits.d/99-test.conf"
        mkdir -p "$T/sysctl.d"
        modprobe() { event "modprobe $*"; }
        sysctl() { event "sysctl $*"; }

        run_status configure_sysctl
        assert_rc 0 "configure_sysctl"

        for line in "vm.swappiness = 10" "net.ipv4.tcp_congestion_control = bbr" "net.core.default_qdisc = fq" \
            "net.ipv4.ip_forward = 1" "net.ipv4.conf.all.rp_filter = 2" "net.ipv4.conf.default.rp_filter = 2"; do
            grep -Fxq "$line" "$SYSCTL_CONF_FILE" || die "sysctl file lacks: $line"
        done
        for module in tcp_bbr tun wireguard; do
            grep -Fxq "$module" "$MODULES_LOAD_FILE" || die "modules-load file lacks: $module"
            assert_event "modprobe $module"
        done
        grep -Fq "nofile 524288" "$LIMITS_CONF_FILE" || die "limits file lacks nofile"
        assert_event "sysctl -e -p $SYSCTL_CONF_FILE"
    '
}

test_sysctl_buffers_follow_memory() {
    run_case '
        SYSCTL_CONF_FILE="$T/sysctl.d/99-test.conf"
        MODULES_LOAD_FILE="$T/modules-load.d/99-test.conf"
        LIMITS_CONF_FILE="$T/limits.d/99-test.conf"
        mkdir -p "$T/sysctl.d"
        modprobe() { :; }
        sysctl() { :; }
        # configure_sysctl reads the memory size from /proc/meminfo with grep.
        grep() {
            if [ "${1:-}" = MemTotal ]; then printf "MemTotal:       %s kB\n" "$MEM_KB"; else command grep "$@"; fi
        }

        # 4 GB and 2 GB: the 10 Gbps buffer is 64 MB, and 32 MB on a small host.
        for case_ in "4194304 67108864" "2097152 33554432" "3145728 67108864" "3145727 33554432"; do
            MEM_KB="${case_% *}"
            run_status configure_sysctl
            assert_rc 0 "configure_sysctl with ${MEM_KB} kB"
            command grep -Fxq "net.core.rmem_max = ${case_#* }" "$SYSCTL_CONF_FILE" || die "rmem_max for ${MEM_KB} kB must be ${case_#* }"
            command grep -Fxq "net.core.wmem_max = ${case_#* }" "$SYSCTL_CONF_FILE" || die "wmem_max for ${MEM_KB} kB must be ${case_#* }"
        done
    '
}

test_swap_baseline() {
    run_case '
        SWAPFILE_PATH="$T/swapfile"
        FSTAB_FILE="$T/fstab"
        swapon() {
            event "swapon $*"
            if [ "$1" = --show ] && [ -e "$T/active_swap" ]; then printf "/dev/zram0\n"; fi
            return 0
        }
        mkswap() { event "mkswap $*"; }
        fallocate() { event "fallocate $*"; : > "$3"; }
        : > "$FSTAB_FILE"

        # --skip-swap
        SKIP_SWAP=true
        run_status configure_swap
        assert_rc 0 "skip swap"
        assert_no_event_matches "^(fallocate|mkswap|swapon)"
        SKIP_SWAP=false

        # Active swap is left alone.
        : > "$T/active_swap"
        run_status configure_swap
        assert_rc 0 "active swap"
        assert_no_event_matches "^(fallocate|mkswap)"
        rm -f "$T/active_swap"

        # An existing swapfile without active swap is not clobbered.
        printf "data\n" > "$SWAPFILE_PATH"
        run_status configure_swap
        assert_rc 0 "existing swapfile"
        assert_no_event_matches "^(fallocate|mkswap)"
        [ "$(cat "$SWAPFILE_PATH")" = data ] || die "existing swapfile must stay untouched"
        rm -f "$SWAPFILE_PATH"

        # Creation: size, mode, mkswap, swapon, one fstab entry (existing entry is not duplicated).
        : > "$EVENTS"
        SWAP_SIZE_GB=4
        printf "%s none swap sw 0 0\n" "$SWAPFILE_PATH" > "$FSTAB_FILE"
        run_status configure_swap
        assert_rc 0 "swapfile creation"
        assert_event "fallocate -l 4G $SWAPFILE_PATH"
        assert_before "fallocate -l 4G $SWAPFILE_PATH" "mkswap $SWAPFILE_PATH"
        assert_before "mkswap $SWAPFILE_PATH" "swapon $SWAPFILE_PATH"
        [ "$(stat -c %a "$SWAPFILE_PATH")" = 600 ] || die "swapfile must be mode 600"
        [ "$(grep -c "^$SWAPFILE_PATH none swap" "$FSTAB_FILE")" = 1 ] || die "fstab entry must not be duplicated"

        rm -f "$SWAPFILE_PATH"
        : > "$FSTAB_FILE"
        run_status configure_swap
        [ "$(cat "$FSTAB_FILE")" = "$SWAPFILE_PATH none swap sw 0 0" ] || die "fstab entry missing: $(cat "$FSTAB_FILE")"
    '
}

test_docker_repository_and_packages() {
    run_case '
        DOCKER_KEYRING="$T/keyrings/docker.gpg"
        DOCKER_SOURCES_FILE="$T/docker.sources"
        ID=debian
        VERSION_CODENAME=trixie
        TARGET_USER=ops
        curl() { event "curl $*"; printf "KEYDATA\n"; }
        gpg() { event "gpg $*"; cat > /dev/null; : > "$3"; }
        dpkg() { printf "amd64\n"; }
        common_apt_sources_changed() { event "apt-sources-changed"; }
        common_apt_update() { event "apt-update $1"; }
        common_safe_install() { event "safe_install $*"; }
        common_systemd_running() { return 1; }
        groupadd() { event "groupadd $*"; }
        ensure_target_user_privileges() { event ensure_target_user_privileges; }

        run_status install_docker_ce
        assert_rc 0 "install_docker_ce"
        assert_event "curl -fsSL https://download.docker.com/linux/debian/gpg"
        assert_event "gpg --dearmor -o $DOCKER_KEYRING"
        for line in "URIs: https://download.docker.com/linux/debian" "Suites: trixie" "Architectures: amd64" "Signed-By: $DOCKER_KEYRING"; do
            grep -Fxq "$line" "$DOCKER_SOURCES_FILE" || die "docker.sources lacks: $line"
        done
        assert_event "safe_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        assert_before "gpg --dearmor -o $DOCKER_KEYRING" "apt-sources-changed"
        assert_before "apt-sources-changed" "apt-update Docker repository refresh"
        assert_before "apt-update Docker repository refresh" "safe_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        assert_before "groupadd -f docker" ensure_target_user_privileges

        # An existing keyring is not downloaded again.
        : > "$EVENTS"
        run_status install_docker_ce
        assert_rc 0 "install_docker_ce, second run"
        assert_no_event_matches "^curl"
    '
}

test_backports_kernel_comes_from_backports() {
    run_case '
        INSTALL_KERNEL_BACKPORTS=true
        BACKPORTS_SOURCES_FILE="$T/debian-backports.sources"
        detect_debian_version() { printf "12\n"; }
        dpkg() {
            case "$1" in
                --print-architecture) printf "amd64\n" ;;
                -s) event "dpkg $*" ;;
            esac
        }
        common_apt_sources_changed() { event "apt-sources-changed"; }
        common_apt_update() { event "apt-update $1"; }
        common_safe_install() { event "safe_install $*"; }
        common_package_installed_from() { event "installed-from $*"; }

        run_status install_backports_kernel
        assert_rc 0 "install_backports_kernel"
        grep -Fxq "Suites: bookworm-backports" "$BACKPORTS_SOURCES_FILE" || die "backports source not written"
        assert_event "safe_install -t bookworm-backports linux-image-amd64 linux-headers-amd64"
        assert_before "apt-sources-changed" "apt-update Backports repository refresh"
        assert_before "apt-update Backports repository refresh" "safe_install -t bookworm-backports linux-image-amd64 linux-headers-amd64"
        assert_out "installed successfully" "success is reported when the install worked"
        assert_event "installed-from bookworm-backports linux-image-amd64 linux-headers-amd64"

        # Not installed, or installed but not in the Backports version: an error, not a success message.
        common_package_installed_from() { return 1; }
        run_status install_backports_kernel
        assert_failed "a kernel that did not come from Backports must fail the step"
        assert_no_out "installed successfully" "kernel from the default release"
        common_package_installed_from() { event "installed-from $*"; }

        # A failed installation is an error, not a success message.
        common_safe_install() { return 1; }
        run_status install_backports_kernel
        assert_failed "a failed Backports kernel installation must fail the step"
        assert_no_out "installed successfully" "failure"

    '
}

test_fish_and_starship_setup() {
    run_case '
        TARGET_USER=ops
        ROOT_HOME="$T/root"
        HOME_DIR="$T/home/ops"
        mkdir -p "$ROOT_HOME" "$HOME_DIR"
        user_home_for() { printf "%s\n" "$HOME_DIR"; }
        install() { event "install $*"; mkdir -p "${@: -1}"; }
        chown() { event "chown $*"; }
        common_safe_install() { event "safe_install $*"; }
        fish() { :; }
        starship() { event "starship $*"; if [ "$*" = "preset nerd-font-symbols" ]; then printf "# nerd-font-symbols preset\n"; fi; }

        # --skip-fish
        INSTALL_FISH=false
        run_status install_fish_and_starship
        assert_rc 0 "skip fish"
        assert_no_event_matches "^safe_install"
        [ ! -e "$HOME_DIR/.config" ] && [ ! -e "$ROOT_HOME/.config" ] || die "nothing may be written with --skip-fish"
        INSTALL_FISH=true

        run_status install_fish_and_starship
        assert_rc 0 "install_fish_and_starship"
        assert_event "safe_install fish"
        assert_event "starship preset nerd-font-symbols"
        run_status install_fish_and_starship
        assert_rc 0 "install_fish_and_starship, second run"

        for home in "$HOME_DIR" "$ROOT_HOME"; do
            grep -Fxq "# nerd-font-symbols preset" "$home/.config/starship.toml" || die "starship preset missing in $home"
            grep -Fq "starship init fish | source" "$home/.config/fish/config.fish" || die "fish config missing in $home"
            [ "$(grep -c "exec fish" "$home/.bashrc")" = 1 ] || die "exec fish must be added to $home/.bashrc exactly once"
        done
        assert_event "chown ops:ops $HOME_DIR/.bashrc"
    '
}

# --- main wiring ----------------------------------------------------------

test_main_step_order() {
    [ -r /etc/os-release ] || { printf 'SKIP: main step order needs /etc/os-release\n'; return 0; }
    run_case '
        for step in require_supported_debian_release validate_target_user confirm_execution \
            warn_if_login_user_not_target_user install_base_packages configure_locales \
            install_backports_kernel create_target_user_if_needed ensure_target_user_privileges \
            configure_time_sync configure_swap install_docker_ce install_fish_and_starship \
            configure_sysctl configure_fail2ban configure_ssh_hardening configure_firewall print_summary; do
            eval "$step() { event $step; }"
        done

        run_status main --user ops --yes
        assert_rc 0 "main with mocked steps"
        assert_before confirm_execution warn_if_login_user_not_target_user
        assert_before warn_if_login_user_not_target_user install_base_packages
        assert_before create_target_user_if_needed configure_ssh_hardening
        assert_before configure_ssh_hardening configure_firewall
        assert_event install_docker_ce

        # The target user comes from SUDO_USER, or main refuses to start.
        : > "$EVENTS"
        run_status main --yes
        assert_failed "main without --user and without SUDO_USER must fail"
        assert_out "--user" "main must point at --user"
        assert_no_event require_supported_debian_release
        SUDO_USER=admin
        run_status main --yes
        assert_rc 0 "main under sudo without --user"
        assert_event install_base_packages
        unset SUDO_USER

        : > "$EVENTS"
        run_status main --user ops --yes --skip-docker
        assert_rc 0 "main with --skip-docker"
        assert_no_event install_docker_ce
    '
}

# --- checks that cannot run as a non-root user ----------------------------

# Repository hygiene, not behavior: the profile must stay minimal. A negative
# invariant over the script text cannot be exercised by running the script.
test_script_stays_minimal() {
    if grep -Eq 'linux-xanmod|fnm env|install_fnm_for_user|/etc/docker/daemon.json|docker\.service\.d/override\.conf' \
        "$ROOT_DIR/optimize_amnezia_host.sh"; then
        fail 'optimize_amnezia_host.sh should stay minimal and avoid heavy VPS tuning features'
    fi
}

test_docs_are_wired() {
    grep -q 'optimize_amnezia_host.sh' "$ROOT_DIR/README.md" || \
        fail 'README.md should mention optimize_amnezia_host.sh'
    grep -q 'README_AMNEZIA_HOST.md' "$ROOT_DIR/README.md" || \
        fail 'README.md should link the Amnezia host documentation'
    grep -q 'bootstrap' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should describe the bootstrap firewall phase'
    grep -q 'locked' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should describe the locked firewall phase'
    grep -q 'Temporary AmneziaWG bootstrap allowance' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should describe removing the bootstrap UDP rule in locked mode'
    grep -q '8443/udp' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the AmneziaWG target port'
    grep -q '2G' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the default 2G swapfile'
    grep -q 'sudo group' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should mention sudo group compatibility'
    grep -q -- '--create-user' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the create-user mode'
    grep -q 'authorized_keys' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should explain how keys are copied for a created user'
    grep -q 'без дублей' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should mention duplicate-safe key merging'
    grep -q -- '--ssh-public-key' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document explicit SSH public key input'
    grep -q -- '--ssh-public-key-file' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document SSH public key file input'
    grep -q -- '--skip-swap' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the swap opt-out mode'
    grep -q -- '--skip-docker' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the Docker opt-out mode'
    grep -q -- '--skip-fish' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the Fish shell opt-out mode'
    grep -q -- '--ssh-port' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the SSH port option'
    grep -q -- '--xray-port' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the XRay port option'
    grep -q -- '--amneziawg-port' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the AmneziaWG port option'
    grep -q 'nerd-font-symbols' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the Starship nerd-font preset'
    grep -q '10 Гбит/с' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should document the 10 Gbps tuning'
    grep -q 'SUDO_USER' "$ROOT_DIR/docs/README_AMNEZIA_HOST.md" || \
        fail 'README_AMNEZIA_HOST.md should explain how the target user is chosen'
}

main() {
    test_release_and_firewall_helpers
    test_existing_user_requires_authorized_keys_before_hardening
    test_parse_args_target_user_resolution
    test_parse_args_rejects_invalid_input
    test_parse_args_applies_options
    test_login_user_warning
    test_create_user_existing_user_branches
    test_create_user_new_user_branches
    test_target_user_privileges
    test_base_packages_include_fail2ban_journal_backend
    test_fail2ban_jail_is_backed_up_before_overwrite
    test_firewall_without_ufw_is_skipped
    test_firewall_bootstrap_phase
    test_firewall_locked_phase
    test_ssh_hardening_dropin_and_order
    test_ssh_hardening_failures_are_visible
    test_ssh_hardening_rolls_back_failed_restart
    test_ssh_hardening_without_systemd
    test_product_paths_default_to_system_locations
    test_sysctl_baseline
    test_sysctl_buffers_follow_memory
    test_swap_baseline
    test_docker_repository_and_packages
    test_backports_kernel_comes_from_backports
    test_fish_and_starship_setup
    test_main_step_order
    test_script_stays_minimal
    test_docs_are_wired
    printf 'PASS: %s\n' "$(basename "$0")"
}

main "$@"

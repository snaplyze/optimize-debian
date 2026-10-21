#!/usr/bin/env bash
# Behavior of the optimize_mini_pc.sh steps that were pulled into functions: SSH
# hardening, the Samba firewall rule and share, jail.local. Each case runs in its own
# bash on a temporary tree; commands that change the system are mocked.
# SC2016: case bodies are single-quoted on purpose, they run in a separate bash.
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

read -r -d '' CASE_HEADER <<'HEADER_EOF' || true
set -euo pipefail
OPTIMIZE_SOURCE_ONLY=1
source "$SCRIPT_ROOT/optimize_mini_pc.sh"
trap - ERR
LOG_FILE=""
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
EVENTS="$T/events"
: > "$EVENTS"

die() { printf "FAIL: %s\n" "$*" >&2; exit 1; }
event() { printf "%s\n" "$*" >> "$EVENTS"; }
run_status() { set +e; ( set -e; "$@" ) > "$T/out" 2>&1; RC=$?; set -e; }
assert_rc() { [ "$RC" -eq "$1" ] || die "$2 (rc=$RC, expected $1): $(cat "$T/out")"; }
assert_out() { grep -Fq -- "$1" "$T/out" || die "$2: output lacks '$1': $(cat "$T/out")"; }
event_log() { tr "\n" "|" < "$EVENTS"; }
assert_event() { grep -Fxq -- "$1" "$EVENTS" || die "missing event '$1' in: $(event_log)"; }
assert_no_event() { ! grep -Fxq -- "$1" "$EVENTS" || die "unexpected event '$1' in: $(event_log)"; }
assert_no_event_matches() { ! grep -Eq -- "$1" "$EVENTS" || die "unexpected event matches '$1' in: $(event_log)"; }
# Lines of section [$2] of the smb.conf $1, header included (a commented header also ends a section).
section_of() { awk -v s="[$2]" "/^[[:space:]]*;?\\[/ { on = (\$0 == s) } on" "$1"; }
# Active (not commented, not blank) lines in the [homes] section of $1, whether or not its header is commented.
active_homes_lines() {
    awk "/^;?\\[homes\\]/ { on = 1; next } /^[[:space:]]*\\[/ { on = 0 } on && !/^[[:space:]]*([;#]|\$)/" "$1"
}
HEADER_EOF

run_case() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c "$CASE_HEADER"$'\n'"$1"
}

test_dead_helpers_removed() {
    local name
    for name in run_silent check_dialog; do
        ! grep -Eq "^${name}\(\)" "$ROOT_DIR/optimize_mini_pc.sh" || \
            fail "optimize_mini_pc.sh defines the unused function $name"
    done
}

# What cannot run without root: the top-level steps must call the helpers. Commented
# lines do not count.
test_steps_use_the_helpers() {
    local script="$ROOT_DIR/optimize_mini_pc.sh"
    local code call
    code="$(grep -Ev '^[[:space:]]*#' "$script")"
    for call in 'setup_ssh_access "$NEW_USER" "$USER_HOME"' '        configure_samba_firewall' \
        'ensure_samba_share "$SAMBA_CONF"' 'disable_samba_homes_section "$SAMBA_CONF"' '    write_fail2ban_jail_local'; do
        grep -Fq -- "$call" <<< "$code" || fail "step does not call: $call"
    done
    ! grep -Eq 'ufw allow Samba$|BIN"? allow Samba|chmod -R 755|99-hardening.conf <<' <<< "$code" || \
        fail "optimize_mini_pc.sh still has an inline Samba rule, recursive chmod or inline SSH drop-in"
}

test_ssh_public_key_validation() {
    run_case '
        # Accepts only what ssh-keygen -l -f reads from a file holding that one line.
        ssh-keygen() {
            [ "$1" = "-l" ] && [ "$2" = "-f" ] || return 2
            event "ssh-keygen -l -f"
            grep -Eq "^ssh-ed25519 [A-Za-z0-9+/]+( .*)?$" "$3"
        }
        is_valid_ssh_public_key "ssh-ed25519 AAAAC3Nza user@host" || die "valid key rejected"
        ! is_valid_ssh_public_key "host.example ssh-ed25519 AAAAC3Nza" || die "known_hosts style line accepted"
        ! is_valid_ssh_public_key "command=\"x\" ssh-ed25519 AAAAC3Nza" || die "line with options accepted"
        ! is_valid_ssh_public_key "not a key at all" || die "garbage accepted"
        ! is_valid_ssh_public_key "" || die "empty accepted"
        printf -v multi "ssh-ed25519 AAAAC3Nza\njunk"
        ! is_valid_ssh_public_key "$multi" || die "multi-line input accepted"
        assert_event "ssh-keygen -l -f"
    '
}

test_ssh_public_key_validation_with_real_ssh_keygen() {
    if ! command -v ssh-keygen > /dev/null; then
        printf 'SKIP: ssh-keygen is not installed\n'
        return 0
    fi
    run_case '
        unset -f ssh-keygen 2>/dev/null || true
        ssh-keygen -q -t ed25519 -N "" -C test@host -f "$T/id" > /dev/null
        pub="$(cat "$T/id.pub")"
        is_valid_ssh_public_key "$pub" || die "real public key rejected"
        ! is_valid_ssh_public_key "myhost.example $pub" || die "host-prefixed public key accepted"
        ! is_valid_ssh_public_key "$(head -n 1 "$T/id")" || die "private key line accepted"
        ! is_valid_ssh_public_key "ssh-ed25519 notbase64!" || die "broken key body accepted"
    '
}

# Common mocks for apply_ssh_hardening: events for sshd and systemctl.
SSH_MOCKS='
    SSHD_HARDENING_FILE="$T/sshd_config.d/00-optimize-hardening.conf"
    SSHD_LEGACY_HARDENING_FILE="$T/sshd_config.d/99-hardening.conf"
    SSHD_T_RC=0
    SSHD_DUMP_RC=0
    RESTART_RC=0
    # sshd -T: the drop-ins in name order; the first value of a keyword wins, while
    # allowusers and port add up, as in sshd. Only keywords set in the files are printed.
    sshd_effective() {
        local file key value
        local -A seen=()
        for file in "$T"/sshd_config.d/*.conf; do
            [ -f "$file" ] || continue
            while read -r key value; do
                case "$key" in "" | "#"*) continue ;; esac
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
        if [ "$1" = -T ]; then
            [ "$SSHD_DUMP_RC" -eq 0 ] || return "$SSHD_DUMP_RC"
            sshd_effective
            return 0
        fi
        return "$SSHD_T_RC"
    }
    systemctl() { event "systemctl $*"; return "$RESTART_RC"; }
'

test_ssh_hardening_applies_after_sshd_t() {
    run_case "$SSH_MOCKS"'
        apply_ssh_hardening alice
        grep -Fxq "AllowUsers alice" "$SSHD_HARDENING_FILE" || die "drop-in lacks AllowUsers"
        grep -Fxq "PasswordAuthentication no" "$SSHD_HARDENING_FILE" || die "drop-in lacks PasswordAuthentication no"
        assert_event "sshd -t"
        assert_event "systemctl restart ssh.service"
        # sshd -t must come before the restart
        [ "$(sed -n 1p "$EVENTS")" = "sshd -t" ] || die "sshd -t is not first: $(event_log)"
    '
}

test_ssh_hardening_sshd_t_failure_removes_dropin_and_skips_restart() {
    run_case "$SSH_MOCKS"'
        SSHD_T_RC=1
        run_status apply_ssh_hardening alice
        assert_rc 1 "failed sshd -t must fail the hardening"
        [ ! -e "$SSHD_HARDENING_FILE" ] || die "drop-in must be removed after a failed sshd -t"
        assert_event "sshd -t"
        assert_no_event_matches "^systemctl"
        assert_out "SSH configuration test failed" "error must be visible"
    '
    run_case "$SSH_MOCKS"'
        SSHD_T_RC=1
        mkdir -p "$(dirname "$SSHD_HARDENING_FILE")"
        printf "Port 2222\n" > "$SSHD_HARDENING_FILE"
        run_status apply_ssh_hardening alice
        assert_rc 1 "failed sshd -t must fail the hardening"
        [ "$(cat "$SSHD_HARDENING_FILE")" = "Port 2222" ] || die "previous drop-in must be restored"
        assert_no_event_matches "^systemctl"
    '
}

test_ssh_hardening_paths() {
    # Debian reads the drop-ins in name order and sshd keeps the first value: ours sorts first.
    run_case '
        [ "$SSHD_HARDENING_FILE" = /etc/ssh/sshd_config.d/00-optimize-hardening.conf ] || die "the hardening drop-in must sort before the other drop-ins"
        [ "$SSHD_LEGACY_HARDENING_FILE" = /etc/ssh/sshd_config.d/99-hardening.conf ] || die "the drop-in of earlier versions moved"
    '
}

test_ssh_hardening_effective_values() {
    # A drop-in read after ours, such as 50-cloud-init.conf, does not override it.
    run_case "$SSH_MOCKS"'
        mkdir -p "$T/sshd_config.d"
        printf "PasswordAuthentication yes\n" > "$T/sshd_config.d/50-cloud-init.conf"
        apply_ssh_hardening alice
        grep -Fxq "KbdInteractiveAuthentication no" "$SSHD_HARDENING_FILE" || die "drop-in lacks KbdInteractiveAuthentication no"
        assert_event "sshd -T"
        assert_event "systemctl restart ssh.service"
    '
    # A drop-in read first wins: the hardening fails, ours goes, SSH is not restarted.
    run_case "$SSH_MOCKS"'
        mkdir -p "$T/sshd_config.d"
        printf "PasswordAuthentication yes\n" > "$T/sshd_config.d/00-aaa.conf"
        run_status apply_ssh_hardening alice
        assert_rc 1 "an overridden hardening value must fail the hardening"
        assert_out "passwordauthentication: expected no, effective yes" "the overridden value must be named"
        [ ! -e "$SSHD_HARDENING_FILE" ] || die "the overridden drop-in must be removed"
        assert_no_event_matches "^systemctl"
    '
    # sshd -T fails: the values cannot be confirmed, so the same.
    run_case "$SSH_MOCKS"'
        SSHD_DUMP_RC=255
        run_status apply_ssh_hardening alice
        assert_rc 1 "a failed sshd -T must fail the hardening"
        assert_out "sshd -T failed" "the failed read-back must be named"
        [ ! -e "$SSHD_HARDENING_FILE" ] || die "an unconfirmed drop-in must be removed"
        assert_no_event_matches "^systemctl"
    '
}

test_ssh_hardening_replaces_the_legacy_dropin() {
    # The four lines an earlier version wrote go: their AllowUsers would add to ours.
    run_case "$SSH_MOCKS"'
        mkdir -p "$T/sshd_config.d"
        printf "PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers old\n" > "$SSHD_LEGACY_HARDENING_FILE"
        run_status apply_ssh_hardening alice
        assert_rc 0 "hardening over an earlier version"
        [ ! -e "$SSHD_LEGACY_HARDENING_FILE" ] || die "the earlier drop-in must be removed"
        assert_out "Removed the drop-in of an earlier version" "the removal must be reported"
        [ "$(sshd_effective | grep "^allowusers")" = "allowusers alice" ] || die "only the new AllowUsers may stay"
    '
    # A failed restart puts the earlier drop-in back.
    run_case "$SSH_MOCKS"'
        mkdir -p "$T/sshd_config.d"
        printf "PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers old\n" > "$SSHD_LEGACY_HARDENING_FILE"
        RESTART_RC=1
        run_status apply_ssh_hardening alice
        assert_rc 1 "failed restart must fail the hardening"
        [ "$(cat "$SSHD_LEGACY_HARDENING_FILE")" = "$(printf "PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers old")" ] || \
            die "the earlier drop-in must be restored"
        [ ! -e "$SSHD_HARDENING_FILE" ] || die "the new drop-in must be removed"
    '
    # The same name with other content is an operator file and stays.
    run_case "$SSH_MOCKS"'
        mkdir -p "$T/sshd_config.d"
        printf "PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers old\nPort 2222\n" > "$SSHD_LEGACY_HARDENING_FILE"
        apply_ssh_hardening alice
        grep -Fxq "Port 2222" "$SSHD_LEGACY_HARDENING_FILE" || die "an operator file must stay"
    '
}

test_ssh_hardening_restart_failure_is_reported_and_reverted() {
    run_case "$SSH_MOCKS"'
        RESTART_RC=1
        run_status apply_ssh_hardening alice
        assert_rc 1 "failed restart must fail the hardening"
        [ ! -e "$SSHD_HARDENING_FILE" ] || die "drop-in must be removed after a failed restart"
        assert_out "Failed to restart the SSH service" "restart failure must be visible"
        # ssh.service and sshd.service for the restart, then both again after the revert
        [ "$(grep -c "^systemctl restart" "$EVENTS")" -eq 4 ] || die "expected a second restart after the revert: $(event_log)"
    '
    # ssh.service fails, sshd.service works: success
    run_case "$SSH_MOCKS"'
        systemctl() { event "systemctl $*"; [ "$2" = "sshd.service" ]; }
        apply_ssh_hardening alice
        [ -e "$SSHD_HARDENING_FILE" ] || die "drop-in must stay when the restart works"
    '
}

test_ssh_hardening_write_errors_keep_the_previous_dropin() {
    # The drop-in directory is not writable: nothing is written, nothing restarts.
    run_case "$SSH_MOCKS"'
        [ "$(id -u)" -ne 0 ] || { echo "SKIP: running as root"; exit 0; }
        mkdir -p "$(dirname "$SSHD_HARDENING_FILE")"
        printf "Port 2222\n" > "$SSHD_HARDENING_FILE"
        chmod 555 "$(dirname "$SSHD_HARDENING_FILE")"
        run_status apply_ssh_hardening alice
        chmod 755 "$(dirname "$SSHD_HARDENING_FILE")"
        assert_rc 1 "a write error must fail the hardening"
        [ "$(cat "$SSHD_HARDENING_FILE")" = "Port 2222" ] || die "previous drop-in was overwritten"
        assert_out "Cannot write" "write error must be visible"
        assert_no_event_matches "^(sshd|systemctl)"
    '
    # The backup copy fails: the previous drop-in is not touched.
    run_case "$SSH_MOCKS"'
        mkdir -p "$(dirname "$SSHD_HARDENING_FILE")"
        printf "Port 2222\n" > "$SSHD_HARDENING_FILE"
        cp() { return 1; }
        run_status apply_ssh_hardening alice
        assert_rc 1 "a backup error must fail the hardening"
        [ "$(cat "$SSHD_HARDENING_FILE")" = "Port 2222" ] || die "previous drop-in was changed"
        assert_out "Cannot back up" "backup error must be visible"
        assert_no_event_matches "^(sshd|systemctl)"
    '
}

# setup_ssh_access: the input comes from stdin; the script then reads one more line to
# show how many lines the step consumed (the pause "Press Enter ..." takes one).
SSH_STEP_MOCKS='
    VALID_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@host"
    ssh-keygen() { grep -q "AAAA" "$3"; }
    chown() { event "chown $*"; }
    hostname() { echo 192.168.1.50; }
    CONFIGURE_SECURITY=true
    apply_ssh_hardening() { event "harden $1"; return "${HARDEN_RC:-0}"; }
    USER_HOME_T="$T/home"
    run_step() {
        printf "%b" "$1" > "$T/in"
        {
            run_status_in_place
            read -r NEXT_LINE || NEXT_LINE="<eof>"
        } < "$T/in"
    }
    run_status_in_place() { set +e; setup_ssh_access alice "$USER_HOME_T" > "$T/out" 2>&1; RC=$?; set -e; }
'

test_setup_ssh_access_flow() {
    # valid key: added, hardened, the pause consumes exactly one line
    run_case "$SSH_MOCKS$SSH_STEP_MOCKS"'
        run_step "$VALID_KEY\nPAUSE\nREST\n"
        assert_rc 0 "step failed"
        grep -Fxq "$VALID_KEY" "$USER_HOME_T/.ssh/authorized_keys" || die "key not added"
        assert_event "harden alice"
        [ "$NEXT_LINE" = "REST" ] || die "the pause did not wait for Enter (next line: $NEXT_LINE)"
        assert_out "SSH hardened" "success not reported"
        assert_out "test SSH login" "login check reminder missing"
    '
    # invalid key first, then a valid one
    run_case "$SSH_MOCKS$SSH_STEP_MOCKS"'
        run_step "garbage\n$VALID_KEY\nPAUSE\nREST\n"
        grep -Fxq "$VALID_KEY" "$USER_HOME_T/.ssh/authorized_keys" || die "key not added"
        ! grep -Fq garbage "$USER_HOME_T/.ssh/authorized_keys" || die "invalid key was added"
        assert_out "not a valid SSH public key" "invalid key not reported"
        [ "$NEXT_LINE" = "REST" ] || die "unexpected input consumption: $NEXT_LINE"
    '
    # failed hardening: reported, no pause, no success message
    run_case "$SSH_MOCKS$SSH_STEP_MOCKS"'
        HARDEN_RC=1
        run_step "$VALID_KEY\nPAUSE\n"
        assert_rc 0 "a failed hardening must not abort the script"
        assert_out "SSH hardening was NOT applied" "failure not reported"
        ! grep -Fq "SSH hardened" "$T/out" || die "success reported after a failed hardening"
        [ "$NEXT_LINE" = "PAUSE" ] || die "pause shown after a failed hardening (next line: $NEXT_LINE)"
    '
    # Enter: nothing is added, hardening is skipped and security steps are not requested
    run_case "$SSH_MOCKS$SSH_STEP_MOCKS"'
        run_step "\nREST\n"
        assert_no_event "harden alice"
        [ ! -s "$USER_HOME_T/.ssh/authorized_keys" ] || die "a key appeared without input"
        [ "$CONFIGURE_SECURITY" = false ] || die "CONFIGURE_SECURITY must be cleared without a key"
        [ "$NEXT_LINE" = "REST" ] || die "unexpected input consumption: $NEXT_LINE"
    '
    # no hardening requested: the key is added, SSH is not touched, no pause
    run_case "$SSH_MOCKS$SSH_STEP_MOCKS"'
        CONFIGURE_SECURITY=false
        run_step "$VALID_KEY\nREST\n"
        grep -Fxq "$VALID_KEY" "$USER_HOME_T/.ssh/authorized_keys" || die "key not added"
        assert_no_event "harden alice"
        [ "$NEXT_LINE" = "REST" ] || die "unexpected pause: $NEXT_LINE"
    '
}

test_ipv4_network_cidr_and_lan_detection() {
    run_case '
        [ "$(ipv4_network_cidr 192.168.1.50/24)" = "192.168.1.0/24" ] || die "/24"
        [ "$(ipv4_network_cidr 10.20.30.40/12)" = "10.16.0.0/12" ] || die "/12"
        [ "$(ipv4_network_cidr 172.16.5.9/20)" = "172.16.0.0/20" ] || die "/20"
        [ "$(ipv4_network_cidr 192.168.001.050/24)" = "192.168.1.0/24" ] || die "leading zeros"
        for bad in 192.168.1.0 192.168.1.0/0 192.168.1.0/33 256.1.1.1/24 a.b.c.d/24 "" 192.168.1/24; do
            ! ipv4_network_cidr "$bad" >/dev/null || die "accepted bad network $bad"
        done

        ROUTE="default via 192.168.1.1 dev enp3s0 proto dhcp src 192.168.1.50 metric 100"
        ADDR="2: enp3s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic enp3s0\       valid_lft 86000sec"
        ip() {
            event "ip $*"
            case "$*" in
                "-o -4 route show default") printf "%s\n" "$ROUTE" ;;
                "-o -4 addr show dev enp3s0") printf "%s\n" "$ADDR" ;;
            esac
        }
        [ "$(detect_lan_subnet)" = "192.168.1.0/24" ] || die "LAN subnet not detected"
        assert_event "ip -o -4 addr show dev enp3s0"

        ROUTE=""
        ! detect_lan_subnet >/dev/null || die "no default route must give no subnet"
        ROUTE="default via 203.0.113.1 dev eth0"
        ADDR="2: eth0    inet 203.0.113.7/24 brd 203.0.113.255 scope global eth0"
        ip() { case "$*" in "-o -4 route show default") printf "%s\n" "$ROUTE" ;; *) printf "%s\n" "$ADDR" ;; esac; }
        ! detect_lan_subnet >/dev/null || die "a public network is not a LAN"
        ROUTE="default via 10.0.0.1 dev wg0"
        ADDR="5: wg0    inet 10.0.0.2/32 scope global wg0"
        ! detect_lan_subnet >/dev/null || die "a /32 is not a LAN"
    '
}

# ufw mock: a script, UFW_BIN is an absolute path.
UFW_MOCK='
    UFW_BIN="$T/ufw"
    printf "#!/bin/sh\necho \"ufw \$*\" >> \"%s\"\n" "$EVENTS" > "$UFW_BIN"
    chmod +x "$UFW_BIN"
    LAN_ADDR="2: enp3s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global enp3s0"
    ip() {
        case "$*" in
            "-o -4 route show default") printf "default via 192.168.1.1 dev enp3s0\n" ;;
            "-o -4 addr show dev enp3s0") printf "%s\n" "$LAN_ADDR" ;;
        esac
    }
    is_interactive_session() { return 1; }
'

test_samba_firewall_rule_is_limited_to_the_lan() {
    run_case "$UFW_MOCK"'
        configure_samba_firewall > "$T/out" 2>&1
        assert_event "ufw allow from 192.168.1.0/24 to any app Samba"
        assert_no_event "ufw allow Samba"
        assert_event "ufw --force delete allow Samba"
    '
}

test_samba_firewall_without_subnet() {
    # No default route, non-interactive: SMB stays closed and the warning says how to open it.
    run_case "$UFW_MOCK"'
        ip() { :; }
        run_status configure_samba_firewall
        assert_rc 0 "an unknown subnet must not abort the script"
        assert_no_event_matches "^ufw allow"
        assert_out "NOT added" "operator must be told that SMB is closed"
        assert_out "ufw allow from <your-lan-subnet> to any app Samba" "manual command missing"
        assert_out "SMB is closed" "must say that SMB is closed"
        # the broad rule of an earlier version must go even without a subnet
        assert_event "ufw --force delete allow Samba"
    '
    # Interactive: an invalid answer is asked again, a valid one is normalized.
    run_case "$UFW_MOCK"'
        ip() { :; }
        is_interactive_session() { return 0; }
        configure_samba_firewall < <(printf "nonsense\n172.20.5.9/16\n") > "$T/out" 2>&1
        assert_event "ufw allow from 172.20.0.0/16 to any app Samba"
        assert_no_event "ufw allow Samba"
        assert_out "Invalid network" "invalid answer not reported"
    '
    # Interactive, Enter: nothing is opened.
    run_case "$UFW_MOCK"'
        ip() { :; }
        is_interactive_session() { return 0; }
        configure_samba_firewall < <(printf "\n") > "$T/out" 2>&1
        assert_no_event_matches "^ufw allow"
    '
    # A public address on the default route is not taken as a LAN either.
    run_case "$UFW_MOCK"'
        LAN_ADDR="2: enp3s0    inet 203.0.113.7/24 scope global enp3s0"
        configure_samba_firewall > "$T/out" 2>&1
        assert_no_event_matches "^ufw allow"
        assert_event "ufw --force delete allow Samba"
    '
    # A typed network outside RFC 1918 needs a confirmation: "n" asks again, "y" accepts.
    run_case "$UFW_MOCK"'
        ip() { :; }
        is_interactive_session() { return 0; }
        configure_samba_firewall < <(printf "8.8.8.8/24\nn\n172.20.5.9/16\n") > "$T/out" 2>&1
        assert_event "ufw allow from 172.20.0.0/16 to any app Samba"
        assert_no_event "ufw allow from 8.8.8.0/24 to any app Samba"
        assert_out "not a private" "public network not warned about"
    '
    run_case "$UFW_MOCK"'
        ip() { :; }
        is_interactive_session() { return 0; }
        configure_samba_firewall < <(printf "8.8.8.8/24\ny\n") > "$T/out" 2>&1
        assert_event "ufw allow from 8.8.8.0/24 to any app Samba"
    '
}

test_share_root_permissions_are_not_recursive_and_set_once() {
    run_case '
        SAMBA_CONF="$T/smb.conf"
        printf "[global]\n   workgroup = WORKGROUP\n" > "$SAMBA_CONF"
        share="$T/ssd"
        mkdir -p "$share/media/sub"
        printf "data" > "$share/secret.txt"
        printf "#!/bin/sh\n" > "$share/media/run.sh"
        chmod 600 "$share/secret.txt"
        chmod 700 "$share/media/sub"
        chmod 644 "$share/media/run.sh"
        chmod 700 "$share"
        chown() { event "chown $*"; }

        snapshot() { find "$share" -mindepth 1 -printf "%p %m\n" | sort; }
        before="$(snapshot)"

        ensure_samba_share "$SAMBA_CONF" SSD_Storage "$share" alice > "$T/out" 2>&1
        [ "$(stat -c %a "$share")" = "755" ] || die "share root mode not set on the first run"
        assert_event "chown alice:alice $share"
        assert_no_event_matches "chown -R"
        [ "$(snapshot)" = "$before" ] || die "content of the share changed on the first run"
        grep -Fxq "[SSD_Storage]" "$SAMBA_CONF" || die "share not added"
        grep -Fxq "   path = $share" "$SAMBA_CONF" || die "share path not added"

        # Second run: nothing is touched, not even the root.
        chmod 711 "$share"
        : > "$EVENTS"
        cp "$SAMBA_CONF" "$T/smb.before"
        ensure_samba_share "$SAMBA_CONF" SSD_Storage "$share" alice > "$T/out" 2>&1
        [ "$(stat -c %a "$share")" = "711" ] || die "second run changed the root mode"
        assert_no_event_matches "^chown"
        [ "$(snapshot)" = "$before" ] || die "content of the share changed on the second run"
        cmp -s "$SAMBA_CONF" "$T/smb.before" || die "second run changed smb.conf"
        [ "$(grep -c "^\[SSD_Storage\]" "$SAMBA_CONF")" -eq 1 ] || die "share duplicated"
    '
}

test_samba_homes_section_only() {
    run_case '
        conf="$T/smb.conf"
        cat > "$conf" <<SMB
[global]
   workgroup = WORKGROUP
   read only = yes
   create mask = 0700

[homes]
   comment = Home Directories
   browseable = no

# By default, the home directories are exported read-only.
   read only = yes
   create mask = 0700
   directory mask = 0700
   valid users = %S

[printers]
   comment = All Printers
   browseable = no
   read only = yes
   create mask = 0700
   directory mask = 0700
   valid users = %S

[Media]
   path = /mnt/ssd
   read only = yes
   valid users = alice
SMB
        for s in global printers Media; do section_of "$conf" "$s" > "$T/orig.$s"; done
        chmod 640 "$conf"

        disable_samba_homes_section "$conf"

        for s in global printers Media; do
            section_of "$conf" "$s" | cmp -s - "$T/orig.$s" || die "section [$s] changed"
        done
        [ "$(stat -c %a "$conf")" = "640" ] || die "smb.conf mode changed"
        ! grep -Eq "^\[homes\]" "$conf" || die "[homes] header still active"
        # no active parameter between the [homes] header and the next section
        active="$(active_homes_lines "$conf")"
        [ -z "$active" ] || die "[homes] parameters still active: $active"
        grep -Fxq ";   read only = yes" "$conf" || die "[homes] parameter not commented"
        grep -Fxq "# By default, the home directories are exported read-only." "$conf" || die "comment line changed"

        cp "$conf" "$T/once"
        disable_samba_homes_section "$conf"
        cmp -s "$conf" "$T/once" || die "second run is not idempotent"
    '
}

test_fail2ban_jail_local_is_saved_before_overwrite() {
    run_case '
        FAIL2BAN_JAIL_LOCAL="$T/jail.local"
        count_backups() { find "$T" -maxdepth 1 -name "jail.local.bak*" | wc -l; }

        write_fail2ban_jail_local > "$T/out" 2>&1
        grep -Fxq "maxretry = 3" "$FAIL2BAN_JAIL_LOCAL" || die "jail.local not written"
        [ "$(count_backups)" -eq 0 ] || die "a backup of a missing file"

        write_fail2ban_jail_local > "$T/out" 2>&1
        [ "$(count_backups)" -eq 0 ] || die "same content must not create a copy"

        printf "[sshd]\nmaxretry = 10\n" > "$FAIL2BAN_JAIL_LOCAL"
        write_fail2ban_jail_local > "$T/out" 2>&1
        [ "$(count_backups)" -eq 1 ] || die "manual jail.local not saved"
        grep -Fxq "maxretry = 10" "$FAIL2BAN_JAIL_LOCAL.bak" || die "copy lacks the manual content"
        grep -Fxq "maxretry = 3" "$FAIL2BAN_JAIL_LOCAL" || die "jail.local not rewritten"

        write_fail2ban_jail_local > "$T/out" 2>&1
        [ "$(count_backups)" -eq 1 ] || die "rerun with the same content created a copy"

        printf "[sshd]\nmaxretry = 20\n" > "$FAIL2BAN_JAIL_LOCAL"
        write_fail2ban_jail_local > "$T/out" 2>&1
        [ "$(count_backups)" -eq 2 ] || die "second manual change must keep the first copy"
        grep -Fxq "maxretry = 10" "$FAIL2BAN_JAIL_LOCAL.bak" || die "first copy overwritten"
        grep -Fxq "maxretry = 20" "$FAIL2BAN_JAIL_LOCAL.bak.1" || die "second copy missing"
    '
}

main() {
    test_dead_helpers_removed
    test_steps_use_the_helpers
    test_ssh_public_key_validation
    test_ssh_public_key_validation_with_real_ssh_keygen
    test_setup_ssh_access_flow
    test_ssh_hardening_write_errors_keep_the_previous_dropin
    test_ssh_hardening_applies_after_sshd_t
    test_ssh_hardening_sshd_t_failure_removes_dropin_and_skips_restart
    test_ssh_hardening_effective_values
    test_ssh_hardening_replaces_the_legacy_dropin
    test_ssh_hardening_restart_failure_is_reported_and_reverted
    test_ssh_hardening_paths
    test_ipv4_network_cidr_and_lan_detection
    test_samba_firewall_rule_is_limited_to_the_lan
    test_samba_firewall_without_subnet
    test_share_root_permissions_are_not_recursive_and_set_once
    test_samba_homes_section_only
    test_fail2ban_jail_local_is_saved_before_overwrite
    printf 'PASS: mini PC step tests\n'
}

main "$@"

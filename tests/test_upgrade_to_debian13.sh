#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_source_does_not_execute_main() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        [[ "$CURRENT_CODENAME" == "" ]]
        [[ "$AUTO_YES" == false ]]
    '
}

test_is_remote_session_detection() {
    (
        unset SSH_CLIENT
        SSH_CONNECTION='10.0.0.1 12345 10.0.0.2 22' SCRIPT_ROOT="$ROOT_DIR" bash -c '
            set -euo pipefail
            source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
            is_remote_session
        '
    )

    (
        unset SSH_CONNECTION SSH_CLIENT
        SCRIPT_ROOT="$ROOT_DIR" bash -c '
            set -euo pipefail
            source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
            if is_remote_session; then
                printf "FAIL: local shell should not be treated as remote\n" >&2
                exit 1
            fi
        '
    )
}

test_arg_parsing_keeps_two_hop_reboot_guard() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        parse_args --yes
        [[ "$AUTO_YES" == true ]]
        [[ "$ALLOW_TWO_HOP_NO_REBOOT" == false ]]
        parse_args --allow-two-hop-no-reboot
        [[ "$ALLOW_TWO_HOP_NO_REBOOT" == true ]]
    '
}

test_two_hop_no_reboot_requires_explicit_flag_in_auto_mode() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        AUTO_YES=true
        ALLOW_TWO_HOP_NO_REBOOT=false
        if can_continue_two_hop_no_reboot; then
            printf "FAIL: --yes alone must not continue Debian 11->12->13 without reboot\n" >&2
            exit 1
        fi
        ALLOW_TWO_HOP_NO_REBOOT=true
        can_continue_two_hop_no_reboot
    '
}

test_ssh_health_skips_inactive_local_ssh_service() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        HAD_OPENSSH_SERVER=true
        SSH_WAS_ENABLED=false
        SSH_WAS_ACTIVE=false
        is_remote_session() { return 1; }
        is_installed_package() { [ "$1" = "openssh-server" ]; }
        log() { :; }
        sshd() { return 0; }
        systemctl() {
            printf "FAIL: systemctl should not be required for inactive local ssh service\n" >&2
            return 1
        }
        ss() { return 1; }
        ensure_ssh_is_healthy
    '
}

test_disk_space_checks_separate_mountpoints() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        test_tmp="$(mktemp -d)"
        trap "rm -rf \"$test_tmp\"" EXIT
        log() { :; }
        die() { printf "DIE: %s\n" "$1"; exit "${2:-1}"; }
        findmnt() {
            case "$3" in
                /|/boot|/var/cache/apt/archives|/usr) printf "%s\n" "$3"; return 0 ;;
                *) return 1 ;;
            esac
        }
        df() {
            case "${*: -1}" in
                /) printf "Avail\n10485760\n" ;;
                /boot) printf "Avail\n102400\n" ;;
                /var/cache/apt/archives) printf "Avail\n6291456\n" ;;
                /usr) printf "Avail\n6291456\n" ;;
            esac
        }
        if ( check_disk_space >"$test_tmp/disk-low.txt" 2>&1 ); then
            printf "FAIL: low free space on a separate /boot mount must fail preflight\n" >&2
            exit 1
        fi
    '

    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        checked_file=$(mktemp)
        trap "rm -f \"$checked_file\"" EXIT
        log() { :; }
        die() { printf "DIE: %s\n" "$1"; exit "${2:-1}"; }
        findmnt() {
            case "$3" in
                /|/boot|/var/cache/apt/archives|/usr) printf "%s\n" "$3"; return 0 ;;
                *) return 1 ;;
            esac
        }
        df() {
            printf "%s\n" "${*: -1}" >> "$checked_file"
            printf "Avail\n10485760\n"
        }
        check_disk_space
        grep -qx "/" "$checked_file"
        grep -qx "/boot" "$checked_file"
        grep -qx "/var/cache/apt/archives" "$checked_file"
        grep -qx "/usr" "$checked_file"
    '
}

main() {
    test_source_does_not_execute_main
    test_is_remote_session_detection
    test_arg_parsing_keeps_two_hop_reboot_guard
    test_two_hop_no_reboot_requires_explicit_flag_in_auto_mode
    test_ssh_health_skips_inactive_local_ssh_service
    test_disk_space_checks_separate_mountpoints
    printf 'tests/test_upgrade_to_debian13.sh: OK\n'
}

main "$@"

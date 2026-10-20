#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_DIRS=()
TMP=""
OUT=""
trap 'rm -rf "${TMP_DIRS[@]}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

new_tmp() {
    TMP="$(mktemp -d)"
    TMP_DIRS+=("$TMP")
}

# Выполняет тело теста в отдельном bash с загруженным скриптом; пути APT, бэкапа и
# состояния dpkg указывают в каталог $1 (APT и dpkg переопределяются после source),
# поэтому система не затрагивается.
run_case() {
    local tmp="$1"
    local body="$2"

    BKP_DIR="$tmp/bkp" TEST_TMP="$tmp" SCRIPT_ROOT="$ROOT_DIR" \
        bash -c 'set -euo pipefail
source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
APT_ETC_DIR="$TEST_TMP/apt"
DPKG_STATUS_FILE="$TEST_TMP/dpkg-status"
APT_EXTENDED_STATES_FILE="$TEST_TMP/extended_states"
OS_RELEASE_FILE="$TEST_TMP/os-release"
'"$body" 2>&1
}

# expect_pass <tmp> <тело> <метка>: тело должно завершиться с кодом 0; вывод — в $OUT
expect_pass() {
    local rc=0
    OUT="$(run_case "$1" "$2")" || rc=$?
    [[ $rc -eq 0 ]] || fail "$3: код выхода $rc"$'\n'"$OUT"
}

# expect_die <tmp> <тело> <метка> <фрагмент>: тело должно завершиться ошибкой с фрагментом в выводе
expect_die() {
    local rc=0
    OUT="$(run_case "$1" "$2")" || rc=$?
    [[ $rc -ne 0 ]] || fail "$3: ожидалась остановка, код 0"$'\n'"$OUT"
    [[ "$OUT" == *"$4"* ]] || fail "$3: в выводе нет '$4'"$'\n'"$OUT"
}

assert_out_has() {
    [[ "$OUT" == *"$1"* ]] || fail "$2: в выводе нет '$1'"$'\n'"$OUT"
}

assert_out_lacks() {
    [[ "$OUT" != *"$1"* ]] || fail "$2: в выводе не должно быть '$1'"$'\n'"$OUT"
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

# ── DATA-3: ожидаемые SSH-порты ──────────────────────────────────────────────
SNAPSHOT_SETUP='
is_installed_package() { [[ "$1" == "openssh-server" ]]; }
cp() { :; }
systemctl() { return 0; }
'

test_snapshot_stops_when_sshd_t_fails_and_sshd_not_listening() {
    new_tmp
    expect_die "$TMP" "$SNAPSHOT_SETUP"'
        sshd() { return 1; }
        ss() { printf "LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\"nginx\",pid=1,fd=6))\n"; }
        snapshot_remote_access_state
        printf "REACHED ports=[%s]\n" "$SSH_EXPECTED_PORTS"
    ' "snapshot without ports" "Не удалось определить порты SSH"
    assert_out_lacks "REACHED" "snapshot without ports"
    assert_out_lacks "Ожидаемые SSH порты" "snapshot without ports"
}

test_snapshot_uses_listening_sshd_ports_when_sshd_t_fails() {
    new_tmp
    expect_pass "$TMP" "$SNAPSHOT_SETUP"'
        sshd() { return 1; }
        ss() {
            printf "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:((\"sshd\",pid=7,fd=3))\n"
            printf "LISTEN 0 128 [::]:2222 [::]:* users:((\"sshd\",pid=7,fd=4))\n"
            printf "LISTEN 0 128 0.0.0.0:2200 0.0.0.0:* users:((\"sshd\",pid=7,fd=5))\n"
            printf "LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\"nginx\",pid=1,fd=6))\n"
        }
        snapshot_remote_access_state
        [[ "$SSH_EXPECTED_PORTS" == "2200 2222" ]] || { printf "FAIL ports=[%s]\n" "$SSH_EXPECTED_PORTS"; exit 1; }
    ' "ports from ss"
}

test_snapshot_prefers_sshd_t_ports() {
    new_tmp
    expect_pass "$TMP" "$SNAPSHOT_SETUP"'
        sshd() { printf "port 2222\nport 22\nlisten 0.0.0.0\n"; }
        ss() { printf "ss must not be consulted when sshd -T works\n" >&2; return 1; }
        snapshot_remote_access_state
        [[ "$SSH_EXPECTED_PORTS" == "22 2222" ]] || { printf "FAIL ports=[%s]\n" "$SSH_EXPECTED_PORTS"; exit 1; }
        [[ -s "$SSH_BKP_DIR/sshd-T.before.txt" ]]
    ' "ports from sshd -T"
    assert_out_lacks "ss must not be consulted" "ports from sshd -T"
}

test_snapshot_combines_port_and_listenaddress_from_sshd_t() {
    new_tmp
    expect_pass "$TMP" "$SNAPSHOT_SETUP"'
        sshd() { printf "port 22\nlistenaddress 0.0.0.0:2222\nlistenaddress [::]:2222\n"; }
        ss() { return 1; }
        snapshot_remote_access_state
        [[ "$SSH_EXPECTED_PORTS" == "2222" ]] || { printf "FAIL ports=[%s]\n" "$SSH_EXPECTED_PORTS"; exit 1; }
    ' "listenaddress with port"

    expect_pass "$TMP" '
        f="$TEST_TMP/sshd-T"
        check() {
            printf "%b" "$2" > "$f"
            got="$(ssh_ports_from_sshd_t "$f")"
            [[ "$got" == "$1" ]] || { printf "FAIL: want=[%s] got=[%s] для: %s\n" "$1" "$got" "$2"; exit 1; }
        }
        check "22" "port 22\n"
        check "22 2222" "port 22\nport 2222\nlistenaddress 0.0.0.0\nlistenaddress ::\n"
        check "22 2200" "port 22\nlistenaddress 10.0.0.1:2200\nlistenaddress 0.0.0.0\n"
        check "2222" "port 22\nlistenaddress [2001:db8::1]:2222\n"
        check "2222" "port 2222\nlistenaddress 2001:db8::1\n"
    ' "ssh_ports_from_sshd_t"
}

test_snapshot_without_ports_stops_only_when_ssh_is_needed() {
    new_tmp
    # ssh выключен, неактивен, сессия не удалённая: предупреждение и продолжение
    expect_pass "$TMP" "$SNAPSHOT_SETUP"'
        systemctl() { return 1; }
        is_remote_session() { return 1; }
        sshd() { return 1; }
        ss() { return 0; }
        snapshot_remote_access_state
        [[ -z "$SSH_EXPECTED_PORTS" ]] || { printf "FAIL ports=[%s]\n" "$SSH_EXPECTED_PORTS"; exit 1; }
        printf "REACHED\n"
    ' "ssh not needed"
    assert_out_has "REACHED" "ssh not needed"
    assert_out_has "проверка портов после шагов будет пропущена" "ssh not needed"

    # удалённая сессия: ssh нужен для доступа
    expect_die "$TMP" "$SNAPSHOT_SETUP"'
        systemctl() { return 1; }
        is_remote_session() { return 0; }
        sshd() { return 1; }
        ss() { return 0; }
        snapshot_remote_access_state
    ' "remote session without ports" "Не удалось определить порты SSH"

    # ssh включён
    expect_die "$TMP" "$SNAPSHOT_SETUP"'
        systemctl() { [[ "$1" == "is-enabled" ]]; }
        is_remote_session() { return 1; }
        sshd() { return 1; }
        ss() { return 0; }
        snapshot_remote_access_state
    ' "enabled ssh without ports" "Не удалось определить порты SSH"
}

test_environment_does_not_override_apt_paths() {
    APT_ETC_DIR=/nonexistent/apt DPKG_STATUS_FILE=/nonexistent/status \
        APT_EXTENDED_STATES_FILE=/nonexistent/extended SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        source "$SCRIPT_ROOT/upgrade-to-debian13.sh"
        [[ "$APT_ETC_DIR" == /etc/apt ]]
        [[ "$DPKG_STATUS_FILE" == /var/lib/dpkg/status ]]
        [[ "$APT_EXTENDED_STATES_FILE" == /var/lib/apt/extended_states ]]
    '
}

# ── DATA-2: бэкап и восстановление ───────────────────────────────────────────
BACKUP_SETUP='
mkdir -p "$APT_ETC_DIR/sources.list.d" "$APT_ETC_DIR/preferences.d"
printf "deb http://deb.debian.org/debian bookworm main\n" > "$APT_ETC_DIR/sources.list"
printf "deb http://security.debian.org/debian-security bookworm-security main\n" > "$APT_ETC_DIR/sources.list.d/security.list"
printf "Package: *\n" > "$APT_ETC_DIR/preferences.d/pin"
printf "Package: bash\nStatus: install ok installed\n" > "$DPKG_STATUS_FILE"
printf "Auto-Installed: 1\n" > "$APT_EXTENDED_STATES_FILE"
dpkg() { printf "bash\tinstall\n"; }
apt-cache() { printf "policy\n"; }
ip() { return 0; }
systemctl() { return 0; }
'

test_backup_stops_before_changes_when_required_copy_fails() {
    new_tmp
    expect_die "$TMP" "$BACKUP_SETUP"'
        cp() {
            local arg
            for arg in "$@"; do
                [[ "$arg" == "$DPKG_STATUS_FILE" ]] && return 1
            done
            command cp "$@"
        }
        dpkg() { printf "dpkg-was-called\n"; }
        backup_state
    ' "backup with failing cp" "$TMP/dpkg-status"
    assert_out_lacks "Бэкап сохранён" "backup with failing cp"
    assert_out_lacks "dpkg-was-called" "backup with failing cp"
}

test_backup_copies_required_files_and_reports_success() {
    new_tmp
    expect_pass "$TMP" "$BACKUP_SETUP"'
        backup_state
        [[ -f "$BKP_DIR/sources.list" ]]
        [[ -f "$BKP_DIR/sources.list.d/security.list" ]]
        [[ -f "$BKP_DIR/preferences.d/pin" ]]
        cmp -s "$DPKG_STATUS_FILE" "$BKP_DIR/dpkg-status"
        [[ -f "$BKP_DIR/extended_states" ]]
        [[ -s "$BKP_DIR/dpkg-selections.txt" ]]
    ' "backup success"
    assert_out_has "Бэкап сохранён" "backup success"
}

test_failure_after_write_sources_prints_backup_path_and_working_restore_command() {
    new_tmp
    local rc=0
    OUT="$(run_case "$TMP" "$BACKUP_SETUP"'
        exec 3>&1 4>&2
        trap cleanup_logging EXIT
        printf "orig-debian-sources bookworm\n" > "$APT_ETC_DIR/sources.list.d/debian.sources"
        APT_MANIFEST_FILE="$BKP_DIR/manifest-bookworm-to-trixie.tsv"
        UPGRADE_PHASE=sources
        write_sources_deb822 trixie bookworm
        false
    ')" || rc=$?
    [[ $rc -ne 0 ]] || fail "failure after write_sources: ожидался ненулевой код"
    assert_out_has "$TMP/bkp" "failure after write_sources"
    assert_out_has "manifest-bookworm-to-trixie.tsv" "failure after write_sources"

    local restore_cmd
    restore_cmd="$(printf '%s\n' "$OUT" | grep -m1 '^  tac ')" || fail "в выводе нет команды восстановления"$'\n'"$OUT"
    # Источники уже перезаписаны: до восстановления в debian.sources целевой релиз
    grep -q trixie "$TMP/apt/sources.list.d/debian.sources" || fail "debian.sources не переписан"
    [[ ! -e "$TMP/apt/sources.list.d/security.list" ]] || fail "security.list должен быть перенесён"
    (cd "$TMP" && bash -c "$restore_cmd") >/dev/null
    grep -q bookworm "$TMP/apt/sources.list" || fail "sources.list не восстановлен"
    [[ -f "$TMP/apt/sources.list.d/security.list" ]] || fail "security.list не восстановлен"
    [[ "$(cat "$TMP/apt/sources.list.d/debian.sources")" == "orig-debian-sources bookworm" ]] \
        || fail "debian.sources не восстановлен"
}

test_recovery_hint_covers_only_current_step_manifest() {
    new_tmp
    mkdir -p "$TMP/bkp"
    printf 'moved\t/a\t/b\n' > "$TMP/bkp/manifest-preflight.tsv"
    printf 'moved\t/c\t/d\n' > "$TMP/bkp/manifest-bullseye-to-bookworm.tsv"
    printf 'moved\t/e\t/f\n' > "$TMP/bkp/manifest-bookworm-to-trixie.tsv"
    local body='
        exec 3>&1 4>&2
        trap cleanup_logging EXIT
        APT_MANIFEST_FILE="$BKP_DIR/manifest-bookworm-to-trixie.tsv"
        UPGRADE_PHASE=sources
        false
    '
    local rc=0
    OUT="$(run_case "$TMP" "$body")" || rc=$?
    [[ $rc -ne 0 ]] || fail "current manifest: ожидался ненулевой код"
    assert_out_has "manifest-bookworm-to-trixie.tsv" "current manifest"
    assert_out_lacks "manifest-bullseye-to-bookworm.tsv" "current manifest"
    assert_out_lacks "manifest-preflight.tsv" "current manifest"
    # копий sources.list в бэкапе нет — о них не пишем
    assert_out_lacks "Полные копии" "no copies in backup"

    mkdir -p "$TMP/bkp/sources.list.d"
    rc=0
    OUT="$(run_case "$TMP" "$body")" || rc=$?
    assert_out_has "Полные копии на момент запуска: $TMP/bkp/sources.list.d" "copies in backup"
    assert_out_lacks "$TMP/bkp/sources.list " "copies in backup"
}

test_recovery_hint_after_package_install_does_not_offer_source_rollback() {
    new_tmp
    mkdir -p "$TMP/bkp"
    printf 'moved\t/e\t/f\n' > "$TMP/bkp/manifest-bookworm-to-trixie.tsv"
    local rc=0
    OUT="$(run_case "$TMP" '
        exec 3>&1 4>&2
        trap cleanup_logging EXIT
        APT_MANIFEST_FILE="$BKP_DIR/manifest-bookworm-to-trixie.tsv"
        UPGRADE_PHASE=packages
        false
    ')" || rc=$?
    [[ $rc -ne 0 ]] || fail "packages phase: ожидался ненулевой код"
    assert_out_lacks "tac " "packages phase"
    assert_out_has "НЕ возвращайте" "packages phase"
    assert_out_has "apt-get -f install" "packages phase"
    assert_out_has "apt-get full-upgrade" "packages phase"

    rc=0
    OUT="$(run_case "$TMP" '
        exec 3>&1 4>&2
        trap cleanup_logging EXIT
        UPGRADE_PHASE=done
        false
    ')" || rc=$?
    assert_out_lacks "Скрипт завершился с ошибкой" "finished step"
}

test_upgrade_step_moves_through_phases() {
    new_tmp
    expect_pass "$TMP" '
        rec="$TEST_TMP/rec"
        record() { printf "%s phase=%s manifest=%s\n" "$1" "$UPGRADE_PHASE" "${APT_MANIFEST_FILE##*/}" >> "$rec"; }
        for fn in handle_held_packages check_apt_pinning disable_third_party_repos remove_backports \
            remove_proposed_updates upgrade_current_release ensure_remote_openssh_is_current \
            write_sources_deb822 refresh_apt_index_and_check_release minimal_upgrade full_upgrade \
            cleanup validate_firewall_state ensure_ssh_is_healthy; do
            eval "$fn() { record $fn; }"
        done
        log() { :; }
        UPGRADE_PHASE=done
        APT_MANIFEST_FILE="$BKP_DIR/manifest-preflight.tsv"
        printf "VERSION_CODENAME=trixie\n" > "$OS_RELEASE_FILE"
        do_upgrade_step bookworm trixie 13
        [[ "$UPGRADE_PHASE" == done ]] || { printf "FAIL: phase after step=%s\n" "$UPGRADE_PHASE"; exit 1; }
        m="manifest-bookworm-to-trixie.tsv"
        grep -qx "handle_held_packages phase=sources manifest=$m" "$rec"
        grep -qx "upgrade_current_release phase=sources manifest=$m" "$rec"
        grep -qx "write_sources_deb822 phase=sources manifest=$m" "$rec"
        grep -qx "refresh_apt_index_and_check_release phase=sources manifest=$m" "$rec"
        grep -qx "minimal_upgrade phase=packages manifest=$m" "$rec"
        grep -qx "full_upgrade phase=packages manifest=$m" "$rec"
        grep -qx "ensure_ssh_is_healthy phase=packages manifest=$m" "$rec"
    ' "phases of upgrade step"

    # шаг не завершился (кодовое имя не сменилось): фаза остаётся packages
    expect_die "$TMP" '
        for fn in handle_held_packages check_apt_pinning disable_third_party_repos remove_backports \
            remove_proposed_updates upgrade_current_release ensure_remote_openssh_is_current \
            write_sources_deb822 refresh_apt_index_and_check_release minimal_upgrade full_upgrade \
            cleanup validate_firewall_state ensure_ssh_is_healthy; do
            eval "$fn() { :; }"
        done
        log() { :; }
        die() { printf "PHASE-AT-DIE=%s\n" "$UPGRADE_PHASE"; exit 1; }
        printf "VERSION_CODENAME=bookworm\n" > "$OS_RELEASE_FILE"
        do_upgrade_step bookworm trixie 13
    ' "step not completed" "PHASE-AT-DIE=packages"
}

test_main_arms_recovery_hint_only_when_apt_sources_start_changing() {
    new_tmp
    expect_pass "$TMP" '
        rec="$TEST_TMP/rec"
        record() { printf "%s phase=[%s]\n" "$1" "$UPGRADE_PHASE" >> "$rec"; }
        for fn in parse_args require_root init_logging check_not_wsl check_architecture check_screen_tmux \
            check_disk_space check_dpkg_health setup_apt_env backup_state warn_if_legacy_ssh_keys_present \
            snapshot_remote_access_state protect_critical_remote_packages preflight_sanitize_apt_sources \
            install_prerequisites do_upgrade_step check_kernel_metapackage check_cryptsetup verify_upgrade \
            final_notes; do
            eval "$fn() { record $fn; }"
        done
        detect_current_version() { CURRENT_CODENAME=bookworm; record detect_current_version; }
        log() { :; }
        main
        grep -qx "backup_state phase=\[\]" "$rec"
        grep -qx "snapshot_remote_access_state phase=\[\]" "$rec"
        grep -qx "protect_critical_remote_packages phase=\[\]" "$rec"
        grep -qx "preflight_sanitize_apt_sources phase=\[sources\]" "$rec"
        grep -qx "install_prerequisites phase=\[sources\]" "$rec"
    ' "phase in main"
}

test_no_recovery_hint_before_apt_changes_start() {
    new_tmp
    local rc=0
    OUT="$(run_case "$TMP" '
        exec 3>&1 4>&2
        trap cleanup_logging EXIT
        false
    ')" || rc=$?
    [[ $rc -ne 0 ]] || fail "no hint: ожидался ненулевой код"
    assert_out_lacks "Скрипт завершился с ошибкой" "no hint before APT changes"
    assert_out_lacks "Вернуть файлы" "no hint before APT changes"
}

# ── DATA-1: источники старого релиза ─────────────────────────────────────────
test_write_sources_leaves_no_old_codename_in_active_files() {
    new_tmp
    expect_pass "$TMP" '
        sources_d="$APT_ETC_DIR/sources.list.d"
        mkdir -p "$sources_d"
        printf "deb http://deb.debian.org/debian bookworm main\n" > "$APT_ETC_DIR/sources.list"
        printf "deb http://security.debian.org/debian-security bookworm-security main\n" > "$sources_d/security.list"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm\nComponents: main\n" > "$sources_d/extra.sources"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm\nComponents: main\n" > "$sources_d/debian.sources"
        printf "deb http://deb.debian.org/debian trixie main\n" > "$sources_d/keep-trixie.list"
        printf "deb https://download.docker.com/linux/debian bookworm stable\n" > "$sources_d/docker.list"
        printf "deb http://security.debian.org/debian-security bookworm-security main\n" > "$sources_d/security.list.bak"

        disable_third_party_repos
        write_sources_deb822 trixie bookworm

        if hits="$(grep -ls bookworm "$APT_ETC_DIR/sources.list" "$sources_d"/*.list "$sources_d"/*.sources)"; then
            printf "FAIL: old codename in active files: %s\n" "$hits"
            exit 1
        fi
        grep -q "Suites: trixie trixie-updates" "$sources_d/debian.sources"
        grep -q "Suites: trixie-security" "$sources_d/debian.sources"
        [[ -f "$sources_d/keep-trixie.list" ]]
        # копия *.bak и перенесённые файлы сохранены вне активных источников
        [[ -f "$sources_d/security.list.bak" ]]
        [[ -f "$BKP_MOVED_DIR/security.list" ]]
        [[ -f "$BKP_MOVED_DIR/extra.sources" ]]
        [[ -f "$BKP_MOVED_DIR/debian.sources" ]]
        [[ -f "$BKP_MOVED_DIR/sources.list" ]]
        [[ -f "$APT_ETC_DIR/sources.list.d.disabled-${TS}/docker.list" ]]
        # манифест называет перенесённые файлы
        grep -q "^moved	$sources_d/security.list	$BKP_MOVED_DIR/security.list$" "$APT_MANIFEST_FILE"
        grep -q "^moved	$sources_d/extra.sources	" "$APT_MANIFEST_FILE"
        grep -q "^moved	$sources_d/docker.list	" "$APT_MANIFEST_FILE"
        grep -q "^created	$sources_d/debian.sources" "$APT_MANIFEST_FILE"
    ' "write_sources on temp tree"
}

test_write_sources_always_moves_previous_debian_sources() {
    new_tmp
    expect_pass "$TMP" '
        sources_d="$APT_ETC_DIR/sources.list.d"
        mkdir -p "$sources_d"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie\n" > "$sources_d/debian.sources"
        write_sources_deb822 trixie bookworm
        grep -q "Suites: trixie trixie-updates" "$sources_d/debian.sources"
        [[ -f "$BKP_MOVED_DIR/debian.sources" ]]
        grep -qx "Suites: trixie" "$BKP_MOVED_DIR/debian.sources"
    ' "previous debian.sources kept"
}

test_move_official_old_release_sources_leaves_other_files() {
    new_tmp
    expect_pass "$TMP" '
        sources_d="$APT_ETC_DIR/sources.list.d"
        mkdir -p "$sources_d"
        printf "deb http://security.debian.org/debian-security bookworm-security main\n" > "$sources_d/official-old.list"
        printf "deb http://deb.debian.org/debian trixie main\n" > "$sources_d/official-new.list"
        printf "deb https://download.docker.com/linux/debian bookworm stable\n" > "$sources_d/third-party.list"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm\n" > "$sources_d/official-old.sources"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie\n" > "$sources_d/official-new.sources"
        printf "Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: bookworm\n" > "$sources_d/third-party.sources"
        move_official_old_release_sources bookworm
        [[ "$(ls "$BKP_MOVED_DIR")" == "$(printf "official-old.list\nofficial-old.sources")" ]] || { printf "FAIL moved: %s\n" "$(ls "$BKP_MOVED_DIR")"; exit 1; }
        [[ "$(ls "$sources_d")" == "$(printf "official-new.list\nofficial-new.sources\nthird-party.list\nthird-party.sources")" ]] || { printf "FAIL left: %s\n" "$(ls "$sources_d")"; exit 1; }
    ' "move official old release"
}

test_remove_backports_cleans_list_and_deb822_files() {
    new_tmp
    expect_pass "$TMP" '
        sources_d="$APT_ETC_DIR/sources.list.d"
        mkdir -p "$sources_d"
        printf "deb http://deb.debian.org/debian bookworm main\ndeb http://deb.debian.org/debian bookworm-backports main\n" > "$APT_ETC_DIR/sources.list"
        printf "deb http://deb.debian.org/debian bookworm-backports main\n" > "$sources_d/extra.list"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm bookworm-backports\n" > "$sources_d/debian.sources"
        remove_backports
        ! grep -rq backports "$APT_ETC_DIR/sources.list" "$sources_d/extra.list" "$sources_d/debian.sources"
        grep -qx "Suites: bookworm" "$sources_d/debian.sources"
        grep -q "bookworm main" "$APT_ETC_DIR/sources.list"
    ' "remove_backports"
}

test_apt_policy_check_looks_only_at_source_descriptions() {
    new_tmp
    # источник с n=<старый релиз>
    expect_die "$TMP" '
        apt-get() { :; }
        apt-cache() { printf "Package files:\n 500 https://deb.debian.org/debian bookworm/main amd64 Packages\n     release v=12.5,o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\n"; }
        refresh_apt_index_and_check_release bookworm
    ' "release n=bookworm" "остался старый релиз bookworm"
    assert_out_has "grep -rlE 'bookworm|oldstable'" "release n=bookworm"
    # источник, найденный только по строке с адресом
    expect_die "$TMP" '
        apt-get() { :; }
        apt-cache() { printf "Package files:\n 500 http://security.debian.org/debian-security bookworm-security/main amd64 Packages\n"; }
        refresh_apt_index_and_check_release bookworm
    ' "uri bookworm-security" "остался старый релиз bookworm"
    # только release n=...
    expect_die "$TMP" '
        apt-get() { :; }
        apt-cache() { printf "Package files:\n     release o=Debian,n=bookworm\n"; }
        refresh_apt_index_and_check_release bookworm
    ' "release n=bookworm at line end" "остался старый релиз bookworm"
    # suite через алиас oldstable-security: в URI нет кодового имени, есть только n=bookworm-security
    expect_die "$TMP" '
        apt-get() { :; }
        apt-cache() { printf "Package files:\n 500 http://security.debian.org/debian-security oldstable-security/main amd64 Packages\n     release v=12,o=Debian,a=oldstable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64\n"; }
        refresh_apt_index_and_check_release bookworm
    ' "release n=bookworm-security" "остался старый релиз bookworm"
    # закреплённая версия пакета и похожие имена — не источник
    expect_pass "$TMP" '
        apt-get() { :; }
        apt-cache() {
            printf "Package files:\n"
            printf " 100 /var/lib/dpkg/status\n     release a=now\n"
            printf " 500 https://deb.debian.org/debian trixie/main amd64 Packages\n"
            printf "     release v=13,o=Debian,a=stable,n=trixie,l=Debian,c=main,b=amd64\n"
            printf " 500 https://example.org/repo bookworm2/main amd64 Packages\n"
            printf "     release o=Example,n=bookworm2,c=main\n"
            printf "Pinned packages:\n"
            printf "     docker-ce -> 5:27.3.1-1~debian.12~bookworm with priority 1001\n"
        }
        refresh_apt_index_and_check_release bookworm
    ' "pinned version and similar names"
}

# ── DATA-4 и TEST-1: sanitize_deb822_suites ──────────────────────────────────
test_sanitize_drops_stanza_with_only_matching_suite() {
    new_tmp
    expect_pass "$TMP" '
        f="$TEST_TMP/debian.sources"
        cat > "$f" <<EOF
# основной репозиторий
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm-backports
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        rc=0
        sanitize_deb822_suites "$f" backports || rc=$?
        [[ $rc -eq 0 ]] || { printf "FAIL: ожидалось изменение, rc=%s\n" "$rc"; exit 1; }
        expected="$(cat <<EOF
# основной репозиторий
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
)"
        [[ "$(cat "$f")" == "$expected" ]] || { printf "FAIL: содержимое:\n%s\n" "$(cat "$f")"; exit 1; }
    ' "sanitize single suite"
}

test_sanitize_removes_only_matching_suite_from_several() {
    new_tmp
    expect_pass "$TMP" '
        f="$TEST_TMP/debian.sources"
        cat > "$f" <<EOF
# комментарий сохраняется
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-backports bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# второй блок
Types: deb
URIs: https://deb.debian.org/debian-security
Suites: bookworm-security
Components: main
EOF
        sanitize_deb822_suites "$f" backports
        expected="$(cat <<EOF
# комментарий сохраняется
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# второй блок
Types: deb
URIs: https://deb.debian.org/debian-security
Suites: bookworm-security
Components: main
EOF
)"
        [[ "$(cat "$f")" == "$expected" ]] || { printf "FAIL: содержимое:\n%s\n" "$(cat "$f")"; exit 1; }

        # без совпадений файл не меняется, код 1
        cp "$f" "$f.copy"
        if sanitize_deb822_suites "$f" proposed-updates; then
            printf "FAIL: файл без совпадений не должен меняться\n"
            exit 1
        fi
        cmp -s "$f" "$f.copy"
    ' "sanitize several suites"
}

test_sanitize_keeps_file_mode_and_owner() {
    new_tmp
    expect_pass "$TMP" '
        dir="$TEST_TMP/sources.list.d"
        mkdir -p "$dir"
        f="$dir/third.sources"
        printf "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm bookworm-backports\n" > "$f"
        chmod 644 "$f"
        before="$(stat -c "%a %u %g" "$f")"
        mktemp() { printf "%s\n" "$*" >> "$TEST_TMP/mktemp.args"; command mktemp "$@"; }
        chown() { printf "%s\n" "$*" >> "$TEST_TMP/chown.args"; command chown "$@"; }
        sanitize_deb822_suites "$f" backports
        # временный файл создаётся рядом с исходным (не в /tmp) и с суффиксом, который APT пропускает
        mktemp_args="$(cat "$TEST_TMP/mktemp.args")"
        [[ "$mktemp_args" == "--suffix=.disabled "* ]] || { printf "FAIL: mktemp %s\n" "$mktemp_args"; exit 1; }
        [[ "$(dirname "${mktemp_args##* }")" == "$dir" ]] || { printf "FAIL: mktemp %s\n" "$mktemp_args"; exit 1; }
        # владелец берётся у исходного файла
        [[ "$(cat "$TEST_TMP/chown.args")" == "--reference=$f "* ]] || { printf "FAIL: chown %s\n" "$(cat "$TEST_TMP/chown.args")"; exit 1; }
        after="$(stat -c "%a %u %g" "$f")"
        [[ "$before" == "$after" ]] || { printf "FAIL: права/владелец: %s -> %s\n" "$before" "$after"; exit 1; }
        [[ "$after" == "644 "* ]]
        grep -qx "Suites: bookworm" "$f"
        # временных файлов рядом не осталось
        [[ "$(ls -A "$dir")" == "third.sources" ]] || { printf "FAIL: остались файлы: %s\n" "$(ls -A "$dir")"; exit 1; }
    ' "sanitize keeps mode"
}

# ── TEST-1: официальные источники Debian ─────────────────────────────────────
test_official_debian_list_file_classification() {
    new_tmp
    expect_pass "$TMP" '
        check() {
            local want="$1" got=0 f="$TEST_TMP/t.list"
            printf "%s\n" "$2" > "$f"
            is_official_debian_list_file "$f" || got=1
            [[ "$got" == "$want" ]] || { printf "FAIL: want=%s got=%s для: %s\n" "$want" "$got" "$2"; exit 1; }
        }
        check 0 "deb http://deb.debian.org/debian bookworm main"
        check 0 "deb-src https://deb.debian.org/debian bookworm main"
        check 0 "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian-security bookworm-security main"
        check 0 "deb http://security.debian.org/debian-security bookworm-security main"
        check 0 "deb https://cdn-fastly.deb.debian.org/debian bookworm main"
        check 0 "# комментарий
deb http://deb.debian.org/debian bookworm main

deb http://security.debian.org/debian-security bookworm-security main"
        check 1 "deb https://download.docker.com/linux/debian bookworm stable"
        check 1 "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable"
        check 1 "deb http://deb.debian.org.evil.example/debian bookworm main"
        check 1 "deb http://notdeb.debian.org/debian bookworm main"
        check 1 "deb http://example.com/deb.debian.org/ bookworm main"
        check 1 "deb xhttp://deb.debian.org/debian bookworm main"
        check 1 "deb http://deb.debian.org/debian bookworm main
deb https://download.docker.com/linux/debian bookworm stable"
    ' "official .list classification"
}

test_official_debian_sources_file_classification() {
    new_tmp
    expect_pass "$TMP" '
        check() {
            local want="$1" got=0 f="$TEST_TMP/t.sources"
            printf "%s\n" "$2" > "$f"
            is_official_debian_sources_file "$f" || got=1
            [[ "$got" == "$want" ]] || { printf "FAIL: want=%s got=%s для: %s\n" "$want" "$got" "$2"; exit 1; }
        }
        check 0 "Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
        check 0 "Types: deb
URIs: http://security.debian.org/debian-security
Suites: bookworm-security"
        check 0 "# комментарий
Types: deb
URIs: https://deb.debian.org/debian https://cdn-fastly.deb.debian.org/debian
Suites: bookworm"
        check 0 "Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm

Types: deb
URIs: https://deb.debian.org/debian-security
Suites: bookworm-security"
        check 1 "Types: deb
URIs: https://download.docker.com/linux/debian
Suites: bookworm
Signed-By: /etc/apt/keyrings/docker.asc"
        check 1 "Types: deb
URIs: https://deb.debian.org/debian https://download.docker.com/linux/debian
Suites: bookworm"
        check 1 "Types: deb
URIs: https://deb.debian.org.evil.example/debian
Suites: bookworm"
        check 1 "Types: deb
URIs: https://example.com/deb.debian.org/
Suites: bookworm"
        check 1 "Types: deb
URIs: xhttps://deb.debian.org/debian
Suites: bookworm"
        check 1 "Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm

Types: deb
URIs: https://example.com/debian
Suites: bookworm"
    ' "official .sources classification"
}

# ── TEST-1: активная ветка ensure_ssh_is_healthy ─────────────────────────────
SSH_HEALTH_SETUP='
HAD_OPENSSH_SERVER=true
SSH_WAS_ENABLED=true
SSH_WAS_ACTIVE=true
SSH_EXPECTED_PORTS="22 2222"
mkdir -p "$SSH_BKP_DIR"
calls="$TEST_TMP/calls"
: > "$calls"
SERVICE_ACTIVE=1
SSHD_T_OK=1
PORT_LISTENING=1
REMOTE=1
is_installed_package() { return 0; }
is_remote_session() { [[ "$REMOTE" == 1 ]]; }
sshd() { [[ "$SSHD_T_OK" == 1 ]]; }
systemctl() {
    printf "systemctl %s\n" "$*" >> "$calls"
    case "$1" in
        is-active) [[ "$SERVICE_ACTIVE" == 1 ]] ;;
        *) return 0 ;;
    esac
}
ss() {
    if [[ "$PORT_LISTENING" == 1 && "$*" == *":2222 )"* ]]; then
        printf "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n"
    fi
    return 0
}
'

test_ensure_ssh_is_healthy_dies_when_service_inactive() {
    new_tmp
    expect_die "$TMP" "$SSH_HEALTH_SETUP"'
        SERVICE_ACTIVE=0
        ensure_ssh_is_healthy
    ' "inactive ssh" "Сервис ssh не активен"
}

test_ensure_ssh_is_healthy_dies_when_port_not_listening() {
    new_tmp
    expect_die "$TMP" "$SSH_HEALTH_SETUP"'
        PORT_LISTENING=0
        ensure_ssh_is_healthy
    ' "no listening port" "не слушает ожидаемые порты: 22 2222"
}

test_ensure_ssh_is_healthy_dies_when_sshd_config_invalid() {
    new_tmp
    expect_die "$TMP" "$SSH_HEALTH_SETUP"'
        SSHD_T_OK=0
        ensure_ssh_is_healthy
    ' "invalid sshd config" "Конфигурация sshd не проходит проверку"
    [[ ! -s "$TMP/calls" ]] || fail "при ошибке sshd -t сервис не должен перезапускаться: $(cat "$TMP/calls")"
}

test_ensure_ssh_is_healthy_passes_when_everything_is_fine() {
    new_tmp
    expect_pass "$TMP" "$SSH_HEALTH_SETUP"'
        ensure_ssh_is_healthy
        grep -qx "systemctl restart ssh" "$calls"
        grep -qx "systemctl is-active --quiet ssh" "$calls"
    ' "healthy ssh"
    assert_out_has "SSH сервис и прослушивание портов проверены" "healthy ssh"
}

test_ensure_ssh_is_healthy_remote_session_requires_running_service() {
    new_tmp
    expect_die "$TMP" "$SSH_HEALTH_SETUP"'
        SSH_WAS_ENABLED=false
        SSH_WAS_ACTIVE=false
        SERVICE_ACTIVE=0
        ensure_ssh_is_healthy
    ' "remote session, inactive ssh" "Сервис ssh не активен"
    if grep -q restart "$TMP/calls"; then
        fail "сервис, который не был активен, не должен перезапускаться"
    fi
}

main() {
    test_source_does_not_execute_main
    test_is_remote_session_detection
    test_arg_parsing_keeps_two_hop_reboot_guard
    test_two_hop_no_reboot_requires_explicit_flag_in_auto_mode
    test_ssh_health_skips_inactive_local_ssh_service
    test_disk_space_checks_separate_mountpoints
    test_snapshot_stops_when_sshd_t_fails_and_sshd_not_listening
    test_snapshot_uses_listening_sshd_ports_when_sshd_t_fails
    test_snapshot_prefers_sshd_t_ports
    test_snapshot_combines_port_and_listenaddress_from_sshd_t
    test_snapshot_without_ports_stops_only_when_ssh_is_needed
    test_environment_does_not_override_apt_paths
    test_backup_stops_before_changes_when_required_copy_fails
    test_backup_copies_required_files_and_reports_success
    test_failure_after_write_sources_prints_backup_path_and_working_restore_command
    test_recovery_hint_covers_only_current_step_manifest
    test_recovery_hint_after_package_install_does_not_offer_source_rollback
    test_upgrade_step_moves_through_phases
    test_main_arms_recovery_hint_only_when_apt_sources_start_changing
    test_no_recovery_hint_before_apt_changes_start
    test_write_sources_leaves_no_old_codename_in_active_files
    test_write_sources_always_moves_previous_debian_sources
    test_move_official_old_release_sources_leaves_other_files
    test_remove_backports_cleans_list_and_deb822_files
    test_apt_policy_check_looks_only_at_source_descriptions
    test_sanitize_drops_stanza_with_only_matching_suite
    test_sanitize_removes_only_matching_suite_from_several
    test_sanitize_keeps_file_mode_and_owner
    test_official_debian_list_file_classification
    test_official_debian_sources_file_classification
    test_ensure_ssh_is_healthy_dies_when_service_inactive
    test_ensure_ssh_is_healthy_dies_when_port_not_listening
    test_ensure_ssh_is_healthy_dies_when_sshd_config_invalid
    test_ensure_ssh_is_healthy_passes_when_everything_is_fine
    test_ensure_ssh_is_healthy_remote_session_requires_running_service
    printf 'tests/test_upgrade_to_debian13.sh: OK\n'
}

main "$@"

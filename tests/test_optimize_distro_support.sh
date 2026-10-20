#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_vps_and_mini_supported_release_helpers() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_vps.sh"
        is_supported_debian_version 12
        is_supported_debian_version 13
        if is_supported_debian_version 11; then
            printf "FAIL: Debian 11 must be unsupported for optimize_vps.sh\n" >&2
            exit 1
        fi
    '

    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_mini_pc.sh"
        is_supported_debian_version 12
        is_supported_debian_version 13
        if is_supported_debian_version 24; then
            printf "FAIL: non-Debian major release must be unsupported for optimize_mini_pc.sh\n" >&2
            exit 1
        fi
    '
}

test_wsl_release_helpers() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        trap - ERR
        is_supported_debian_version 12
        is_supported_debian_version 13
        if is_supported_debian_version 11; then
            printf "FAIL: Debian 11 must be unsupported for optimize_wsl2.sh\n" >&2
            exit 1
        fi

        VERSION_ID=12
        [[ "$(resolve_fetch_packages)" == "neofetch" ]]
        [[ "$(resolve_cuda_distro 12)" == "debian12" ]]

        VERSION_ID=13
        [[ "$(resolve_fetch_packages)" == "fastfetch" ]]
        [[ "$(resolve_cuda_distro 13)" == "debian13" ]]

        if render_wsl_conf "" | grep -q "^default="; then
            printf "FAIL: empty WSL default user must not render default=\n" >&2
            exit 1
        fi
        render_wsl_conf snaplyze | grep -q "^default=snaplyze$"
    '
}

test_wsl_cuda_toolkit_package_resolver() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        apt-cache() {
            [ "$1" = "show" ] && [ "$2" = "cuda-toolkit" ]
        }
        [[ "$(resolve_cuda_toolkit_package)" == "cuda-toolkit" ]]
    '

    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        apt-cache() {
            [ "$1" = "show" ] && [ "$2" = "cuda-toolkit-13-2" ]
        }
        [[ "$(resolve_cuda_toolkit_package)" == "cuda-toolkit-13-2" ]]
    '
}

test_fnm_dependency_helpers() {
    grep -q 'ensure_fnm_install_dependencies()' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should preflight fnm dependencies'
    grep -Fq "safe_install \"\${missing_packages[@]}\"" "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should install missing fnm dependencies automatically'
    grep -q 'install_fnm_for_user root || warn "fnm installation for root failed"' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should not abort when fnm installation for root fails'

    grep -q 'ensure_fnm_install_dependencies()' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should preflight fnm dependencies'
    grep -Fq "safe_install \"\${missing_packages[@]}\"" "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should install missing fnm dependencies automatically'
    grep -q 'install_fnm_for_user root || warn "fnm installation for root failed"' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should not abort when fnm installation for root fails'

    grep -q 'ensure_fnm_install_dependencies()' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should preflight fnm dependencies'
    grep -Fq "safe_install \"\${missing_packages[@]}\"" "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should install missing fnm dependencies automatically'
}

test_script_text_contracts() {
    grep -q '/etc/apt/sources.list.d/docker.sources' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should use docker.sources'
    grep -q '/etc/apt/sources.list.d/docker.sources' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should use docker.sources'
    grep -q 'safe_install linux-cpupower' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should standardize on linux-cpupower'
    grep -q 'safe_install linux-cpupower' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should standardize on linux-cpupower'
    grep -q "if \\[ -e \"\\\$f\" \\]; then" "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should guard missing APT source globs explicitly'
    grep -q 'Node.js Installation (fnm + LTS)' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should use fnm section naming'
    grep -q 'Node.js (fnm + LTS)' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should use fnm section naming'
    grep -q 'install_fnm_for_user' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should install Node via fnm'
    grep -q 'append_authorized_key_unique()' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should merge SSH keys without overwriting authorized_keys'
    grep -Fq "grep -Fqx \"\$ssh_key\" \"\$target_file\"" "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should skip duplicate authorized_keys entries'
    grep -q 'install_fnm_for_user' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should install Node via fnm'
    grep -q 'append_authorized_key_unique()' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should merge SSH keys without overwriting authorized_keys'
    grep -Fq "grep -Fqx \"\$ssh_key\" \"\$target_file\"" "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should skip duplicate authorized_keys entries'
    grep -q 'fnm env --use-on-cd --shell fish' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should configure fnm in fish'
    grep -q 'fnm env --use-on-cd --shell bash' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should configure fnm in bash'
    grep -q 'fnm env --use-on-cd --shell fish' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should configure fnm in fish'
    grep -q 'fnm env --use-on-cd --shell bash' "$ROOT_DIR/optimize_mini_pc.sh" || \
        fail 'optimize_mini_pc.sh should configure fnm in bash'
    grep -q 'fnm env --use-on-cd --shell fish' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should configure fnm in fish'
    grep -q 'fnm env --use-on-cd --shell bash' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should configure fnm in bash'
    grep -q 'Node.js Installation (fnm + LTS)' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should keep fnm section naming'
    grep -q 'install_fnm_for_user' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should install Node via fnm'
    grep -q 'INSTALL_GO=true' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should expose an INSTALL_GO toggle'
    grep -q 'INSTALL_NODE=true' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should expose an INSTALL_NODE toggle'
    grep -Fq "if \$INSTALL_GO; then" "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should guard Go installation behind INSTALL_GO'
    grep -Fq "if \$INSTALL_NODE; then" "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should guard Node installation behind INSTALL_NODE'

    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        grep -q 'preset nerd-font-symbols' "$ROOT_DIR/$script" || \
            fail "$script should configure Starship with nerd-font-symbols preset"
        grep -q 'exec fish' "$ROOT_DIR/$script" || \
            fail "$script should configure interactive fish auto-switch in .bashrc"
    done

    for script in optimize_vps.sh optimize_mini_pc.sh optimize_amnezia_host.sh; do
        grep -q 'common_render_debian_backports_source' "$ROOT_DIR/$script" || \
            fail "$script should configure Debian backports sources through shared helper"
    done

    grep -q 'MAX_BUFFER=67108864' "$ROOT_DIR/optimize_vps.sh" || \
        fail "optimize_vps.sh should define 64MB max buffer for 10G throughput"
    grep -q 'max_buffer_bytes=67108864' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail "optimize_amnezia_host.sh should define 64MB max buffer for 10G throughput"

    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        if grep -Fq 'INSTALL_XANMOD' "$ROOT_DIR/$script"; then
            fail "$script should not have INSTALL_XANMOD flag"
        fi
        if grep -Fq 'INSTALL_ZSH' "$ROOT_DIR/$script"; then
            fail "$script should not have INSTALL_ZSH flag"
        fi
    done

    if grep -RE '^[[:space:]]*PROMPT=' "$ROOT_DIR"/optimize_*.sh; then
        fail 'optimize scripts must not assign PROMPT in zsh snippets; PROMPT is zsh PS1'
    fi

    if grep -Eq 'remove_legacy_nvm_for_user|\.nvm|nvm\.sh|nvm\(' "$ROOT_DIR/optimize_wsl2.sh"; then
        fail 'optimize_wsl2.sh should not keep legacy NVM cleanup or runtime logic'
    fi
    if grep -Eq '(^|[^[:alnum:]_])NVM([^[:alnum:]_]|$)|\.nvm|nvm\.sh|nvm\(' \
        "$ROOT_DIR/optimize_vps.sh" "$ROOT_DIR/optimize_mini_pc.sh" "$ROOT_DIR/optimize_wsl2.sh"; then
        fail 'optimize scripts should no longer contain active NVM implementation references'
    fi
}

test_generated_fish_config_templates_parse() {
    command -v fish >/dev/null 2>&1 || return 0

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        awk '
            /config\.fish.*<<.*FISH/ { inside=1; next }
            inside && /^FISH.*EOF$/ { inside=0; exit }
            inside { print }
        ' "$ROOT_DIR/$script" > "$tmp_dir/$script.fish"

        [ -s "$tmp_dir/$script.fish" ] || \
            fail "$script should contain a generated config.fish template"
        fish -n "$tmp_dir/$script.fish" || \
            fail "$script generated config.fish template should parse as fish"
    done

    rm -rf "$tmp_dir"
    trap - RETURN
}

test_repository_text_contracts() {
    if grep -R "ESMApps\\|ESM:" "$ROOT_DIR"/optimize_*.sh; then
        fail 'Debian optimize scripts must not write Ubuntu ESM unattended-upgrades origins'
    fi

    for script in optimize_wsl2.sh optimize_vps.sh optimize_mini_pc.sh optimize_amnezia_host.sh; do
        grep -q 'common_render_docker_debian_source' "$ROOT_DIR/$script" || \
            fail "$script should render Docker deb822 sources through the shared helper"
    done
    grep -q 'Architectures:' "$ROOT_DIR/lib/common.sh" || \
        fail 'shared Docker deb822 helper should pin sources to dpkg architecture'

    grep -q 'gpu_status_wsl || true' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should not abort NVIDIA setup when GPU preflight warns'
    if grep -Eq 'safe_install[[:space:]]+cuda([[:space:]]|$)' "$ROOT_DIR/optimize_wsl2.sh"; then
        fail 'optimize_wsl2.sh must not install the broad cuda metapackage in WSL'
    fi
    if grep -Fq 'apt-cache search cuda | grep -q' "$ROOT_DIR/optimize_wsl2.sh"; then
        fail 'optimize_wsl2.sh must not probe CUDA packages with grep -q under pipefail'
    fi
    grep -q 'resolve_cuda_toolkit_package' "$ROOT_DIR/optimize_wsl2.sh" || \
        fail 'optimize_wsl2.sh should resolve CUDA toolkit package through apt-cache show'

    grep -q 'systemctl restart ssh.service' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should restart Debian ssh.service'
    grep -q 'systemctl restart sshd.service' "$ROOT_DIR/optimize_vps.sh" || \
        fail 'optimize_vps.sh should keep sshd.service fallback'

    # Security & Stability Audit Contracts
    if grep -RE 'tmpfs[[:space:]]+/tmp[[:space:]]+tmpfs.*noexec' "$ROOT_DIR"/optimize_*.sh; then
        fail 'optimize scripts must not mount /tmp with noexec (breaks apt, dpkg, go build, npm)'
    fi

    for script in optimize_vps.sh optimize_mini_pc.sh; do
        grep -q 'backend = systemd' "$ROOT_DIR/$script" || \
            fail "$script fail2ban jail must use backend = systemd on Debian 12/13"
        if grep -q 'logpath = /var/log/auth.log' "$ROOT_DIR/$script"; then
            fail "$script fail2ban must not require /var/log/auth.log on systemd-journal Debian"
        fi
    done

    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        grep -q 'net\.ipv4\.conf\.all\.rp_filter = 2' "$ROOT_DIR/$script" || \
            fail "$script should configure Loose rp_filter (2) for VPN/Docker routing"
        grep -q 'net\.ipv4\.conf\.default\.rp_filter = 2' "$ROOT_DIR/$script" || \
            fail "$script should configure default Loose rp_filter (2) for VPN/Docker routing"
        if grep -q 'rp_filter = 1' "$ROOT_DIR/$script"; then
            fail "$script must not configure Strict rp_filter (1)"
        fi
        grep -q 'common_safe_write_sudoers' "$ROOT_DIR/$script" || \
            fail "$script should use common_safe_write_sudoers for atomic visudo validation"
    done

    if grep -RE 'ntlm[[:space:]]+auth' "$ROOT_DIR"/optimize_*.sh; then
        fail 'optimize scripts must not re-enable obsolete and insecure ntlm auth'
    fi

    for script in optimize_vps.sh optimize_amnezia_host.sh; do
        grep -q 'KbdInteractiveAuthentication no' "$ROOT_DIR/$script" || \
            fail "$script should configure modern OpenSSH KbdInteractiveAuthentication no"
    done

    if grep -RE 'eval echo "~' "$ROOT_DIR"/*.sh "$ROOT_DIR"/lib/*.sh; then
        fail 'scripts must not use eval echo "~" for home expansion; use common_user_home'
    fi
}

test_vps_safe_install_reports_install_failures() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_vps.sh"
        wait_for_dpkg_lock() { return 0; }
        package_available() { return 0; }
        progress() { :; }
        log() { :; }
        warn() { :; }
        apt-get() {
            case "$1" in
                update) return 0 ;;
                install) return 1 ;;
                *) return 0 ;;
            esac
        }
        if safe_install synthetic-package; then
            printf "FAIL: safe_install must fail when package installation fails\n" >&2
            exit 1
        fi
    '
}

test_vps_ntp_and_apt_helpers() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_vps.sh"
        test_tmp="$(mktemp -d)"
        trap "rm -rf \"$test_tmp\"" EXIT
        log() { :; }
        warn() { :; }
        info() { :; }
        log_silent() { :; }

        service_unit_exists() { [ "$1" = "chronyd.service" ]; }
        [[ "$(detect_time_sync_service)" == "chronyd.service" ]]

        systemd_system_available() { return 0; }
        service_unit_exists() { return 1; }
        package_available() { [ "$1" = "systemd-timesyncd" ]; }
        safe_install() { printf "%s\n" "$*" > "$test_tmp/ntp-install.txt"; }
        service_unit_active() { return 1; }
        service_unit_enable_now() { return 0; }
        service_unit_start() { return 0; }
        TIME_SYNC_SERVICE_NAME="Not configured"
        ensure_time_sync_service
        [[ "$TIME_SYNC_SERVICE_NAME" == "systemd-timesyncd" ]]
        [[ "$(cat "$test_tmp/ntp-install.txt")" == "systemd-timesyncd" ]]

        timedatectl_available() { return 0; }
        ensure_time_sync_service() { TIME_SYNC_SERVICE_NAME="chronyd"; return 0; }
        detect_time_sync_service() { printf "%s\n" "chronyd.service"; }
        timedatectl() { return 0; }
        TIME_SYNC_SERVICE_NAME="Not configured"
        enable_ntp_sync
        [[ "$TIME_SYNC_SERVICE_NAME" == "chronyd" ]]

        ensure_time_sync_service() { TIME_SYNC_SERVICE_NAME="ntpsec"; return 0; }
        service_unit_active() { [ "$1" = "ntpsec.service" ]; }
        system_clock_synchronized() { return 0; }
        info() { :; }
        timedatectl() { return 1; }
        TIME_SYNC_SERVICE_NAME="Not configured"
        enable_ntp_sync
        [[ "$TIME_SYNC_SERVICE_NAME" == "ntpsec" ]]

        tmp_file=$(mktemp)
        printf "%s\n" "deb http://mirror.example/debian bookworm main non-free-firmware" > "$tmp_file"
        enrich_apt_components "$tmp_file"
        grep -q "main non-free-firmware contrib non-free" "$tmp_file"
        rm -f "$tmp_file"
    '
}

test_vps_apt_update_failure_diagnostics() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_vps.sh"
        test_tmp="$(mktemp -d)"
        trap "rm -rf \"$test_tmp\"" EXIT
        log_silent() { :; }
        error() { printf "ERROR: %s\n" "$1"; }
        apt-get() {
            printf "%s\n" "E: synthetic apt failure"
            return 1
        }

        if run_apt_update_with_diagnostics "test refresh" > "$test_tmp/apt-diag.txt" 2>&1; then
            printf "FAIL: expected apt update helper to fail\n" >&2
            exit 1
        fi

        grep -q "apt-get update failed during: test refresh" "$test_tmp/apt-diag.txt"
        grep -q "synthetic apt failure" "$test_tmp/apt-diag.txt"
    '
}

test_vps_enrichment_rewrite_failure_is_diagnostic() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_vps.sh"
        test_tmp="$(mktemp -d)"
        trap "rm -rf \"$test_tmp\"" EXIT
        progress() { :; }
        error() { printf "ERROR: %s\n" "$1"; }
        mktemp() { return 1; }

        tmp_file="$test_tmp/vps-source-test"
        printf "%s\n" "deb http://mirror.example/debian bookworm main" > "$tmp_file"

        if enrich_apt_components "$tmp_file" > "$test_tmp/enrich-diag.txt" 2>&1; then
            printf "FAIL: expected enrich_apt_components to fail when mktemp fails\n" >&2
            exit 1
        fi

        grep -q "Failed to allocate temporary file while updating" "$test_tmp/enrich-diag.txt"
    '
}

test_mini_ntp_helper() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_mini_pc.sh"
        log() { :; }
        warn() { :; }
        info() { :; }
        log_silent() { :; }

        systemd_system_available() { return 0; }
        package_available() { [ "$1" = "systemd-timesyncd" ]; }
        service_unit_exists() { return 1; }
        service_unit_active() { return 1; }
        service_unit_enable_now() { return 0; }
        service_unit_start() { return 0; }
        safe_install() { :; }
        TIME_SYNC_SERVICE_NAME="Not configured"
        ensure_time_sync_service
        [[ "$TIME_SYNC_SERVICE_NAME" == "systemd-timesyncd" ]]
    '
}

main() {
    test_vps_and_mini_supported_release_helpers
    test_wsl_release_helpers
    test_wsl_cuda_toolkit_package_resolver
    test_fnm_dependency_helpers
    test_script_text_contracts
    test_generated_fish_config_templates_parse
    test_repository_text_contracts
    test_vps_safe_install_reports_install_failures
    test_vps_ntp_and_apt_helpers
    test_vps_apt_update_failure_diagnostics
    test_vps_enrichment_rewrite_failure_is_diagnostic
    test_mini_ntp_helper
    printf 'tests/test_optimize_distro_support.sh: OK\n'
}

main "$@"

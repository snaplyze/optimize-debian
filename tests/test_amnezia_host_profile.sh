#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_release_and_firewall_helpers() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_amnezia_host.sh"

        is_supported_debian_version 12
        is_supported_debian_version 13
        if is_supported_debian_version 11; then
            printf "FAIL: Debian 11 must be unsupported for optimize_amnezia_host.sh\n" >&2
            exit 1
        fi

        validate_firewall_phase bootstrap
        validate_firewall_phase locked
        if validate_firewall_phase something-else; then
            printf "FAIL: invalid firewall phase must be rejected\n" >&2
            exit 1
        fi

        [[ "$(firewall_udp_rule_for_phase bootstrap)" == "all-udp-temporary" ]]
        [[ "$(firewall_udp_rule_for_phase locked)" == "8443/udp" ]]

        validate_swap_size_gb 2
        validate_swap_size_gb 16
        if validate_swap_size_gb 0; then
            printf "FAIL: zero swap size must be rejected\n" >&2
            exit 1
        fi
        if validate_swap_size_gb nope; then
            printf "FAIL: non-numeric swap size must be rejected\n" >&2
            exit 1
        fi

        validate_username snaplyze
        if validate_username 1234; then
            printf "FAIL: numeric-only usernames must be rejected\n" >&2
            exit 1
        fi

        validate_port 22
        validate_port 8443
        validate_port 65535
        if validate_port 0; then
            printf "FAIL: port 0 must be rejected\n" >&2
            exit 1
        fi
        if validate_port 70000; then
            printf "FAIL: port > 65535 must be rejected\n" >&2
            exit 1
        fi
        if validate_port invalid; then
            printf "FAIL: non-numeric port must be rejected\n" >&2
            exit 1
        fi
    '
}

test_package_available_helper() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_amnezia_host.sh"

        apt-cache() {
            cat <<APT_EOF
sample:
  Installed: (none)
  Candidate: 1.2.3
APT_EOF
        }

        package_available sample

        apt-cache() {
            cat <<APT_EOF
missing:
  Installed: (none)
  Candidate: (none)
APT_EOF
        }

        if package_available missing; then
            printf "FAIL: package_available must reject Candidate: (none)\n" >&2
            exit 1
        fi
    '
}

test_existing_user_requires_authorized_keys_before_hardening() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_amnezia_host.sh"

        tmp_home=$(mktemp -d)
        TARGET_USER=sample

        user_home_for() {
            [ "$1" = "sample" ] || return 1
            printf "%s\n" "$tmp_home"
        }

        if target_user_has_authorized_keys "$TARGET_USER"; then
            printf "FAIL: user without authorized_keys must not pass SSH key preflight\n" >&2
            exit 1
        fi

        mkdir -p "$tmp_home/.ssh"
        printf "%s\n" "ssh-ed25519 AAAATEST sample@example" > "$tmp_home/.ssh/authorized_keys"
        target_user_has_authorized_keys "$TARGET_USER"
    '
}

test_script_text_contracts() {
    grep -q 'docker-ce' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should offer Docker CE installation'
    grep -q '/etc/apt/sources.list.d/docker.sources' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should use docker.sources'
    grep -q '99-amnezia-host-hardening.conf' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should configure SSH hardening via a drop-in'
    grep -q '99-amnezia-host.conf' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should write a dedicated sysctl file'
    grep -q 'Temporary AmneziaWG bootstrap allowance' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should document the temporary bootstrap UDP rule'
    grep -q 'delete allow from any to any proto udp' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should remove the bootstrap UDP rule in locked mode'
    grep -Fq "AllowUsers \${TARGET_USER}" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should lock SSH access to the selected user'
    grep -q -- '--create-user' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose a create-user flag'
    grep -q -- '--ssh-public-key' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose an explicit SSH public key flag'
    grep -q -- '--ssh-public-key-file' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose an SSH public key file flag'
    grep -Fq "adduser --gecos \"\" --disabled-password \"\$TARGET_USER\"" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should create the target user without forcing a password'
    grep -q 'append_authorized_keys_unique()' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should centralize duplicate-safe authorized_keys merging'
    grep -q 'append_authorized_key_line_unique()' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should support direct public key line insertion'
    grep -Fq "grep -Fqx \"\$source_line\" \"\$target_keys\"" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should skip duplicate authorized_keys entries'
    grep -Fq "append_authorized_keys_unique \"\$source_keys\" \"\$user_home/.ssh/authorized_keys\"" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should merge authorized_keys into the created user account'
    grep -Fq "append_authorized_key_line_unique \"\$SSH_PUBLIC_KEY\" \"\$user_home/.ssh/authorized_keys\"" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should support explicit SSH public key injection for new users'
    grep -q 'Pass --ssh-public-key or --ssh-public-key-file' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should explain noninteractive create-user key requirements'
    grep -Fq "usermod -aG sudo \"\$TARGET_USER\"" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should add the target user to the sudo group'
    grep -q 'ensure_target_user_privileges' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should centralize target-user privilege setup'
    grep -Fq "common_safe_write_sudoers \"/etc/sudoers.d/\${TARGET_USER}\"" "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should configure passwordless sudo for the target user'
    grep -q 'common_safe_write_sudoers "/etc/sudoers.d/root"' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should configure passwordless sudo for root'
    grep -q '/swapfile' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should manage a dedicated /swapfile'
    grep -q -- '--swap-size-gb' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose a swap size flag'
    grep -q -- '--skip-swap' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose a swap opt-out flag'
    grep -q 'vm.swappiness = 10' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should set a conservative swappiness value'
    grep -q -- '--skip-docker' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose a Docker opt-out flag'

    grep -q -- '--skip-fish' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose a skip-fish flag'
    grep -q -- '--ssh-port' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose an ssh-port flag'
    grep -q -- '--xray-port' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose an xray-port flag'
    grep -q -- '--amneziawg-port' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should expose an amneziawg-port flag'
    grep -q 'nerd-font-symbols' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should configure the nerd-font-symbols starship preset'
    grep -q 'python3-systemd' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should install python3-systemd for fail2ban'
    grep -q 'DEFAULT_FORWARD_POLICY="ACCEPT"' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should ensure UFW allows packet forwarding'
    grep -q 'tcp_bbr' "$ROOT_DIR/optimize_amnezia_host.sh" || \
        fail 'optimize_amnezia_host.sh should load tcp_bbr kernel module'

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
}

main() {
    test_release_and_firewall_helpers
    test_package_available_helper
    test_existing_user_requires_authorized_keys_before_hardening
    test_script_text_contracts
    test_docs_are_wired
    printf 'PASS: %s\n' "$(basename "$0")"
}

main "$@"

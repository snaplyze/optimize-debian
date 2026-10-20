#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_status() {
    local expected="$1"
    shift
    set +e
    "$@"
    local actual=$?
    set -e
    [ "$actual" -eq "$expected" ] || fail "expected status $expected, got $actual: $*"
}

test_supported_debian_versions() {
    common_is_supported_debian_version 12
    common_is_supported_debian_version 13
    common_is_supported_debian_version 12.5
    assert_status 1 common_is_supported_debian_version 11
    assert_status 1 common_is_supported_debian_version 24
    assert_status 1 common_is_supported_debian_version ""
}

test_username_validation() {
    common_validate_username snaplyze
    common_validate_username snap_user-1
    assert_status 1 common_validate_username ""
    assert_status 2 common_validate_username 123
    assert_status 3 common_validate_username 1snap
    assert_status 3 common_validate_username -snap
    assert_status 4 common_validate_username Snap
    assert_status 5 common_validate_username aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}

test_wsl_conf_rendering() {
    common_render_wsl_conf "" | grep -q '^systemd=true$' || fail "WSL config should enable systemd"
    if common_render_wsl_conf "" | grep -q '^default='; then
        fail "empty WSL default user must not render default="
    fi
    common_render_wsl_conf snaplyze | grep -q '^default=snaplyze$' || \
        fail "WSL config should render a non-empty default user"
}

test_docker_source_rendering() {
    local rendered
    rendered="$(common_render_docker_debian_source debian trixie amd64 /etc/apt/keyrings/docker.gpg)"
    grep -q '^Types: deb$' <<<"$rendered" || fail "Docker source should render Types"
    grep -q '^URIs: https://download.docker.com/linux/debian$' <<<"$rendered" || fail "Docker source should render Debian URI"
    grep -q '^Suites: trixie$' <<<"$rendered" || fail "Docker source should render suite"
    grep -q '^Architectures: amd64$' <<<"$rendered" || fail "Docker source should render architecture"
    grep -q '^Signed-By: /etc/apt/keyrings/docker.gpg$' <<<"$rendered" || fail "Docker source should render Signed-By"
}

test_unattended_upgrades_rendering() {
    local rendered
    rendered="$(common_render_debian_unattended_upgrades_conf)"
    grep -q "\${distro_id}:\${distro_codename}-security" <<<"$rendered" || \
        fail "unattended-upgrades should include Debian security origin"
    if grep -Eq 'ESMApps|ESM:' <<<"$rendered"; then
        fail "unattended-upgrades must not include Ubuntu ESM origins"
    fi

    rendered="$(common_render_apt_periodic_auto_upgrades_conf)"
    grep -q '^APT::Periodic::Unattended-Upgrade "1";$' <<<"$rendered" || \
        fail "APT periodic config should enable unattended-upgrades"
}

test_debian_backports_source_rendering() {
    local rendered
    rendered="$(common_render_debian_backports_source bookworm)"
    grep -q '^Types: deb$' <<<"$rendered" || fail "Backports source should render Types"
    grep -q '^URIs: http://deb.debian.org/debian$' <<<"$rendered" || fail "Backports source should render Debian URI"
    grep -q '^Suites: bookworm-backports$' <<<"$rendered" || fail "Backports source should render suite"
    grep -q '^Components: main contrib non-free non-free-firmware$' <<<"$rendered" || fail "Backports source should render components"
    grep -q '^Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg$' <<<"$rendered" || fail "Backports source should render default Signed-By"

    assert_status 1 common_render_debian_backports_source ""
}

test_user_home() {
    local home
    home="$(common_user_home "root")"
    [ "$home" = "/root" ] || fail "common_user_home root should be /root, got: $home"
    assert_status 1 common_user_home "definitely_non_existing_user_12345"
}

test_safe_write_sudoers() {
    local temp_file
    temp_file="$(mktemp)"
    rm -f "$temp_file"

    # Valid syntax should succeed
    common_safe_write_sudoers "$temp_file" "root ALL=(ALL) NOPASSWD:ALL"
    [ -f "$temp_file" ] || fail "common_safe_write_sudoers did not create target file"
    grep -q "root ALL=(ALL) NOPASSWD:ALL" "$temp_file" || fail "content mismatch"
    rm -f "$temp_file"

    # Invalid syntax must fail and remove the target file
    if command -v visudo >/dev/null 2>&1 || [ -x /usr/sbin/visudo ]; then
        assert_status 2 common_safe_write_sudoers "$temp_file" "invalid sudoers syntax ??? !!!"
        [ ! -f "$temp_file" ] || fail "invalid sudoers file should not exist after failure"
        rm -f "$temp_file"
    else
        printf 'SKIP: invalid sudoers syntax case of common_safe_write_sudoers: visudo is not installed\n'
    fi
}

main() {
    test_supported_debian_versions
    test_username_validation
    test_wsl_conf_rendering
    test_docker_source_rendering
    test_unattended_upgrades_rendering
    test_debian_backports_source_rendering
    test_user_home
    test_safe_write_sudoers
    printf 'tests/test_common_helpers.sh: OK\n'
}

main "$@"


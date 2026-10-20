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
    local dir target

    if ! command -v visudo >/dev/null 2>&1 && [ ! -x /usr/sbin/visudo ]; then
        printf 'SKIP: common_safe_write_sudoers cases: visudo is not installed\n'
        return 0
    fi

    dir="$(mktemp -d)"
    SUDOERS_TEST_DIR="$dir"
    trap 'chmod -R u+w "${SUDOERS_TEST_DIR:-}" 2>/dev/null || true; rm -rf "${SUDOERS_TEST_DIR:-}"' EXIT
    target="$dir/sudoers.d/ops"

    assert_status 1 common_safe_write_sudoers "" "root ALL=(ALL) NOPASSWD:ALL"
    assert_status 1 common_safe_write_sudoers "$target" ""

    # Valid content: written as the target with the sudoers mode.
    common_safe_write_sudoers "$target" "ops ALL=(ALL) NOPASSWD:ALL" || fail "valid sudoers content must be written"
    [ "$(cat "$target")" = "ops ALL=(ALL) NOPASSWD:ALL" ] || fail "sudoers content mismatch"
    [ "$(stat -c %a "$target")" = 440 ] || fail "sudoers file must have mode 440"

    # Invalid content over a valid file: the old file stays as it was, no temporary file is left.
    assert_status 2 common_safe_write_sudoers "$target" "invalid sudoers syntax ??? !!!"
    [ "$(cat "$target")" = "ops ALL=(ALL) NOPASSWD:ALL" ] || fail "invalid content must not replace the valid sudoers file"
    [ "$(ls -A "$dir/sudoers.d")" = ops ] || fail "no temporary file may stay next to the sudoers file: $(ls -A "$dir/sudoers.d")"

    # A write that cannot happen is a failure, and the old file stays.
    if [ "$(id -u)" -ne 0 ]; then
        chmod 555 "$dir/sudoers.d"
        if common_safe_write_sudoers "$target" "root ALL=(ALL) NOPASSWD:ALL" 2>/dev/null; then
            chmod 755 "$dir/sudoers.d"
            fail "a failed write must not report success"
        fi
        chmod 755 "$dir/sudoers.d"
        [ "$(cat "$target")" = "ops ALL=(ALL) NOPASSWD:ALL" ] || fail "a failed write must keep the old sudoers file"
    else
        printf 'SKIP: unwritable sudoers directory case: running as root\n'
    fi

    # A directory in place of the target is an error, not a file moved inside it.
    mkdir "$dir/sudoers.d/dirtarget"
    if common_safe_write_sudoers "$dir/sudoers.d/dirtarget" "ops ALL=(ALL) NOPASSWD:ALL" 2>/dev/null; then
        fail "a directory in place of the sudoers file must not report success"
    fi

    # The unchecked copy is named with a dot: sudo skips such files in #includedir.
    mkdir "$dir/bin"
    # shellcheck disable=SC2016 # $2 belongs to the stub script, not to this shell.
    printf '#!/bin/sh\nprintf "%%s\\n" "$2" >> "%s/visudo.log"\n' "$dir" > "$dir/bin/visudo"
    chmod +x "$dir/bin/visudo"
    PATH="$dir/bin:$PATH" common_safe_write_sudoers "$dir/sudoers.d/dotted" "ops ALL=(ALL) NOPASSWD:ALL" || \
        fail "write with the stub visudo must succeed"
    case "$(basename "$(head -n 1 "$dir/visudo.log")")" in
        .dotted.*) ;;
        *) fail "visudo must check a temporary file whose name starts with a dot: $(cat "$dir/visudo.log")" ;;
    esac

    rm -rf "$dir"
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


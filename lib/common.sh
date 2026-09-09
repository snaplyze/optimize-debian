#!/usr/bin/env bash

common_generate_utf8_locales() {
    local locale_file="${1:-/etc/locale.gen}"
    local locale_name available_locales

    touch "$locale_file" || return
    for locale_name in en_US ru_RU; do
        sed -i -E "/^[[:space:]#]*${locale_name}\\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)/d" "$locale_file" || return
        printf '%s.UTF-8 UTF-8\n' "$locale_name" >> "$locale_file" || return
    done

    # Keep locales compiled outside locale.gen, including those supplied by the image.
    LC_ALL=C LANG=C locale-gen --keep-existing || return
    available_locales="$(LC_ALL=C LANG=C locale -a)" || return
    for locale_name in en_US ru_RU; do
        # locale-gen can succeed even when an individual localedef invocation fails.
        if ! grep -Eiq "^${locale_name}\\.(utf8|utf-8)$" <<< "$available_locales"; then
            printf 'Locale generation failed: %s.UTF-8 is unavailable\n' "$locale_name" >&2
            return 1
        fi
    done
}

common_is_supported_debian_version() {
    case "${1%%.*}" in
        12|13) return 0 ;;
        *) return 1 ;;
    esac
}

common_validate_username() {
    local username="${1:-}"

    [[ -z "$username" ]] && return 1
    [[ "$username" =~ ^[0-9]+$ ]] && return 2
    [[ "$username" =~ ^[-0-9] ]] && return 3
    [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && return 4
    [[ ${#username} -gt 32 ]] && return 5

    return 0
}

common_render_wsl_conf() {
    local default_user="${1:-}"

    cat <<'EOF'
[boot]
# Enable systemd for better service management
# systemd allows Docker to auto-start via service configuration
systemd=true

[automount]
# Enable metadata for proper file permissions
enabled=true
# Mount Windows drives to /mnt (standard WSL behavior)
# C: will be /mnt/c, D: will be /mnt/d, etc.
root=/mnt
# Combined options: metadata for permissions, case sensitivity, umask for directories
# Note: fmask removed to allow Windows executables (like VSCode scripts) to work
options="metadata,case=dir,umask=022"

[network]
# Generate hosts file for local development
generateHosts=true
# Custom hostname
hostname=debian-wsl

[interop]
# Enable Windows process integration
enabled=true
# Append Windows PATH for better tool access
appendWindowsPath=true
EOF

    if [ -n "$default_user" ]; then
        cat <<EOF

[user]
# Default user - login with this user instead of root
default=${default_user}
EOF
    fi
}

common_render_docker_debian_source() {
    local os_id="${1:-}"
    local suite="${2:-}"
    local architecture="${3:-}"
    local signed_by="${4:-}"

    if [ -z "$os_id" ] || [ -z "$suite" ] || [ -z "$architecture" ] || [ -z "$signed_by" ]; then
        return 1
    fi

    cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/${os_id}
Suites: ${suite}
Components: stable
Architectures: ${architecture}
Signed-By: ${signed_by}
EOF
}

common_render_debian_unattended_upgrades_conf() {
    cat <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
}

common_render_apt_periodic_auto_upgrades_conf() {
    cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

common_render_debian_backports_source() {
    local suite="${1:-}"
    local signed_by="${2:-/usr/share/keyrings/debian-archive-keyring.gpg}"

    if [ -z "$suite" ]; then
        return 1
    fi

    cat <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${suite}-backports
Components: main contrib non-free non-free-firmware
Signed-By: ${signed_by}
EOF
}

common_user_home() {
    local username="${1:-}"
    [ -n "$username" ] || return 1
    local entry home
    entry="$(getent passwd "$username" 2>/dev/null || true)"
    [ -n "$entry" ] || return 1
    home="$(cut -d: -f6 <<<"$entry")"
    [ -n "$home" ] || return 1
    printf '%s\n' "$home"
}

common_safe_write_sudoers() {
    local target_file="${1:-}"
    local content="${2:-}"

    [ -n "$target_file" ] && [ -n "$content" ] || return 1

    mkdir -p "$(dirname "$target_file")"
    printf '%s\n' "$content" > "$target_file"
    chmod 440 "$target_file"

    local visudo_bin
    visudo_bin="$(command -v visudo 2>/dev/null || true)"
    [ -n "$visudo_bin" ] || [ ! -x /usr/sbin/visudo ] || visudo_bin="/usr/sbin/visudo"

    if [ -n "$visudo_bin" ] && [ -x "$visudo_bin" ]; then
        if ! "$visudo_bin" -cf "$target_file" >/dev/null 2>&1; then
            rm -f "$target_file"
            return 2
        fi
    fi

    return 0
}


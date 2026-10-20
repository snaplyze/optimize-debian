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
    [ -n "$os_id" ] && [ -n "$suite" ] && [ -n "$architecture" ] && [ -n "$signed_by" ] || return 1
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
    [ -n "$suite" ] || return 1
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
    local target_dir tmp_file visudo_bin

    [ -n "$target_file" ] && [ -n "$content" ] || return 1

    visudo_bin="$(command -v visudo 2>/dev/null || true)"
    [ -n "$visudo_bin" ] || [ ! -x /usr/sbin/visudo ] || visudo_bin="/usr/sbin/visudo"
    [ -n "$visudo_bin" ] && [ -x "$visudo_bin" ] || return 1

    target_dir="$(dirname "$target_file")"
    mkdir -p "$target_dir" || return 1
    # sudo skips files whose names contain a dot, so the unchecked copy is never read as a rule.
    tmp_file="$(mktemp "$target_dir/.$(basename "$target_file").XXXXXX" 2>/dev/null)" || return 1

    if ! printf '%s\n' "$content" > "$tmp_file" || ! chmod 440 "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    if ! "$visudo_bin" -cf "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 2
    fi
    if ! mv -fT "$tmp_file" "$target_file"; then
        rm -f "$tmp_file"
        return 1
    fi
}


# apt-get without prompts. DPkg::Lock::Timeout makes apt wait for the dpkg lock held by
# another package manager instead of failing; apt does the waiting itself and covers the dpkg locks
# only (apt-get update takes the lists lock, see common_apt_update).
common_apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o "DPkg::Lock::Timeout=${COMMON_APT_LOCK_TIMEOUT:-300}" \
        -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 "$@"
}

# Refreshes the APT index once per run: later calls return 0 until common_apt_sources_changed.
# First waits for the dpkg lock with an install of no packages: apt-get update does not take
# that lock and would break the download of an installation running in another process.
# Returns 75 when that lock is still held after COMMON_APT_LOCK_TIMEOUT seconds.
# Retries while another process holds the lists lock, within COMMON_APT_UPDATE_ATTEMPTS
# attempts and COMMON_APT_LOCK_TIMEOUT seconds. COMMON_APT_UPDATE_CHECK may name a function
# that receives the apt output and returns non-zero to reject an update apt itself accepted.
common_apt_update() {
    local context="${1:-package index refresh}"
    local timeout="${COMMON_APT_LOCK_TIMEOUT:-300}"
    local delay="${COMMON_APT_UPDATE_RETRY_DELAY:-10}"
    local max_attempts="${COMMON_APT_UPDATE_ATTEMPTS:-30}"
    local started="$SECONDS"
    local attempt=1
    local output status

    if [ "${COMMON_APT_INDEX_FRESH:-0}" = 1 ]; then
        return 0
    fi

    progress "Refreshing APT package index..."
    status=0
    output="$(LC_ALL=C common_apt_get install -y 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        log_silent "$output"
        if grep -q 'Could not get lock' <<<"$output"; then
            error "apt-get update failed during: $context (dpkg lock is still held)"
            printf '%s\n' "$output" | head -n 10 | sed 's/^/    /' || true
            return 75
        fi
    fi
    while :; do
        status=0
        output="$(LC_ALL=C common_apt_get update 2>&1)" || status=$?
        log_silent "$output"
        if [ "$status" -eq 0 ] && [ -n "${COMMON_APT_UPDATE_CHECK:-}" ]; then
            "$COMMON_APT_UPDATE_CHECK" "$output" || status=$?
        fi
        if [ "$status" -eq 0 ]; then
            COMMON_APT_INDEX_FRESH=1
            return 0
        fi

        if grep -Eq 'Could not get lock [^ ]*/lists/lock|Unable to lock directory [^ ]*/lists/' <<<"$output" \
            && [ "$attempt" -lt "$max_attempts" ] \
            && [ $((SECONDS - started + delay)) -le "$timeout" ]; then
            if [ "$attempt" -eq 1 ]; then
                info "APT package lists are locked by another process, waiting for it..."
            fi
            sleep "$delay"
            attempt=$((attempt + 1))
            continue
        fi

        error "apt-get update failed during: $context"
        printf '%s\n' "$output" | head -n 10 | sed 's/^/    /' || true
        return "$status"
    done
}

# Call after every change to APT sources or keys so the next common_apt_update refreshes the index.
common_apt_sources_changed() {
    COMMON_APT_INDEX_FRESH=0
}

# common_package_available <package> [release]: the package has an install candidate or,
# when a release is named, a version in that release. `apt-cache -t <release> policy` is not
# enough: it only raises the release's priority and still shows the default candidate.
common_package_available() {
    local package="${1:-}"
    local release="${2:-}"
    local policy candidate

    [ -n "$package" ] || return 1
    if [ -n "$release" ]; then
        LC_ALL=C apt-cache madison "$package" 2>/dev/null | \
            awk -F'|' -v suite=" ${release}/" 'index($3, suite) { found = 1 } END { exit !found }'
        return
    fi
    policy="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null)" || return 1
    candidate="$(sed -n '/^[[:space:]]*Candidate:/{s/^[^:]*:[[:space:]]*//;p;q;}' <<<"$policy")"
    [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

# common_package_installed_from <release> <package>...: every package is installed in a
# version that the release provides.
common_package_installed_from() {
    local release="${1:-}"
    local package version
    shift || true

    [ -n "$release" ] && [ $# -gt 0 ] || return 1
    for package in "$@"; do
        version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null)" || return 1
        [ -n "$version" ] || return 1
        LC_ALL=C apt-cache madison "$package" 2>/dev/null | \
            awk -F'|' -v suite=" ${release}/" -v version="$version" \
                'index($3, suite) { gsub(/[[:space:]]/, "", $2); if ($2 == version) found = 1 } END { exit !found }' || return 1
    done
}

# common_safe_install [-t release] <package>...: installs the available packages in one
# apt-get call, retrying one by one when it fails. Unavailable packages only produce a
# warning; returns 1 when an available package could not be installed. With -t the
# packages come from that release and an installed package is upgraded to its version.
common_safe_install() {
    local release=""
    local packages=()
    local available_packages=()
    local unavailable_packages=()
    local failed_packages=()
    local install_args=(install -y)
    local pkg output status

    if [ "${1:-}" = "-t" ]; then
        if [ -z "${2:-}" ]; then
            error "common_safe_install: -t needs a release name"
            return 1
        fi
        release="$2"
        install_args+=(-t "$release")
        shift 2
    fi
    packages=("$@")
    [ ${#packages[@]} -gt 0 ] || return 0

    status=0
    common_apt_update "installing: ${packages[*]}" || status=$?
    if [ "$status" -eq 75 ]; then
        error "Not installing ${packages[*]}: another package manager still holds the dpkg lock"
        return 1
    elif [ "$status" -ne 0 ]; then
        warn "Continuing with the existing APT package index"
    fi

    for pkg in "${packages[@]}"; do
        if common_package_available "$pkg" "$release"; then
            available_packages+=("$pkg")
        else
            unavailable_packages+=("$pkg")
        fi
    done

    if [ ${#available_packages[@]} -gt 0 ]; then
        progress "Installing ${#available_packages[@]} packages..."
        status=0
        output="$(LC_ALL=C common_apt_get "${install_args[@]}" "${available_packages[@]}" 2>&1)" || status=$?
        log_silent "$output"
        if [ "$status" -ne 0 ] && grep -q 'Could not get lock' <<<"$output"; then
            # Retrying one by one would wait for the same lock once per package.
            error "Not installing ${available_packages[*]}: another package manager still holds the dpkg lock"
            failed_packages=("${available_packages[@]}")
        elif [ "$status" -ne 0 ]; then
            for pkg in "${available_packages[@]}"; do
                if [ ${#failed_packages[@]} -gt 0 ] && grep -q 'Could not get lock' <<<"$output"; then
                    # The lock was taken meanwhile: the remaining packages would wait for it in turn.
                    failed_packages+=("$pkg")
                    continue
                fi
                status=0
                output="$(LC_ALL=C common_apt_get "${install_args[@]}" "$pkg" 2>&1)" || status=$?
                log_silent "$output"
                if [ "$status" -ne 0 ]; then
                    failed_packages+=("$pkg")
                    warn "Failed to install: $pkg"
                    printf '%s\n' "$output" | tail -n 5 | sed 's/^/    /' || true
                fi
            done
        fi
    fi

    if [ ${#unavailable_packages[@]} -gt 0 ]; then
        warn "Unavailable packages${release:+ in $release}: ${unavailable_packages[*]}"
    fi
    if [ ${#failed_packages[@]} -gt 0 ]; then
        warn "Package installation incomplete: ${failed_packages[*]}"
        return 1
    fi
    if [ ${#available_packages[@]} -gt 0 ]; then
        log "Packages installed successfully${release:+ from $release}"
    fi
}

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

# common_install_from_release <release> <package>...: installs the packages from the release and
# succeeds only when every one of them is installed in a version that release provides.
common_install_from_release() {
    local release="${1:-}"
    shift || true

    [ -n "$release" ] && [ $# -gt 0 ] || return 1
    common_safe_install -t "$release" "$@" && common_package_installed_from "$release" "$@"
}

# common_enrich_apt_components <file>: adds contrib, non-free and non-free-firmware to every
# source in <file> that has the main component: the deb and deb-src lines of a one-line file,
# the Components fields of a deb822 .sources file. The file is rewritten only when a component
# is added: through a temporary file in its directory that gets its mode and owner and then
# replaces it, so a failed write leaves the source as it was; the next common_apt_update
# refreshes the index. Returns 1 when the file cannot be read or rewritten.
common_enrich_apt_components() {
    local f="${1:-}"
    local format=list
    local tmp_file line body comment words added changed=0 read_status=0

    [ -f "$f" ] || return 0
    [[ "$f" == *.sources ]] && format=deb822

    if ! tmp_file="$(mktemp "$(dirname "$f")/.$(basename "$f").XXXXXX")"; then
        error "Failed to allocate temporary file while updating $f"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        body="$line"
        comment=""
        if [ "$format" = list ] && [[ "$line" == *"#"* ]]; then
            body="${line%%#*}"
            comment="#${line#*#}"
        fi
        if { [ "$format" = list ] && [[ "$body" =~ ^[[:space:]]*deb(-src)?[[:space:]] ]]; } ||
            { [ "$format" = deb822 ] && [[ "$body" =~ ^[[:space:]]*[Cc]omponents: ]]; }; then
            words=" ${body//[[:space:]:]/ } "
            added=""
            if [[ "$words" == *" main "* ]]; then
                [[ "$words" == *" contrib "* ]] || added+=" contrib"
                [[ "$words" == *" non-free "* ]] || added+=" non-free"
                [[ "$words" == *" non-free-firmware "* ]] || added+=" non-free-firmware"
            fi
            if [ -n "$added" ]; then
                body="${body%"${body##*[![:space:]]}"}"
                line="${body}${added}${comment:+ $comment}"
                changed=1
            fi
        fi
        printf '%s\n' "$line"
    done < "$f" > "$tmp_file" || read_status=1
    if [ "$read_status" -ne 0 ]; then
        rm -f "$tmp_file"
        error "Failed to read APT source file: $f"
        return 1
    fi

    if [ "$changed" -eq 0 ]; then
        rm -f "$tmp_file"
        return 0
    fi

    progress "Updating APT source file: $f"
    if ! chmod --reference="$f" "$tmp_file" || ! chown --reference="$f" "$tmp_file" || ! mv -f "$tmp_file" "$f"; then
        rm -f "$tmp_file"
        error "Failed to write updated APT source file: $f"
        return 1
    fi
    common_apt_sources_changed
}

# common_enrich_apt_sources [apt_dir]: common_enrich_apt_components for sources.list and every
# .list and .sources file in sources.list.d of <apt_dir> (/etc/apt). Returns 1 when a file could
# not be rewritten; the other files are still processed.
common_enrich_apt_sources() {
    local apt_dir="${1:-/etc/apt}"
    local f status=0

    for f in "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list "$apt_dir"/sources.list.d/*.sources; do
        common_enrich_apt_components "$f" || status=1
    done
    return "$status"
}

# systemd runs as the init system (not in WSL without systemd or in most containers).
common_systemd_running() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# The kernel reports the clock as synchronized. timedatectl names this NTPSynchronized;
# it has no SystemClockSynchronized property (Debian 12 and 13).
common_system_clock_synchronized() {
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]
}

# common_ensure_time_sync_service: keeps the first installed time-sync service of chrony,
# ntpsec, ntp, openntpd and systemd-timesyncd, starting it when it is inactive, and installs
# systemd-timesyncd only when none is installed: in Debian these packages conflict, so
# installing another one would remove the operator's. Sets COMMON_TIME_SYNC_SERVICE to the
# running service without .service. Returns 1 without systemd or when no service runs.
common_ensure_time_sync_service() {
    local unit service=""

    COMMON_TIME_SYNC_SERVICE=""
    common_systemd_running || return 1

    for unit in chronyd.service chrony.service ntpsec.service ntp.service openntpd.service systemd-timesyncd.service; do
        if systemctl list-unit-files "$unit" --no-legend >/dev/null 2>&1; then
            service="$unit"
            break
        fi
    done

    if [ -z "$service" ]; then
        # The index may not be refreshed yet in this run (an image with empty package lists).
        common_apt_update "time sync service lookup" || true
        if ! common_package_available systemd-timesyncd; then
            warn "No supported NTP service detected and systemd-timesyncd is unavailable"
            return 1
        fi
        log "No NTP service detected. Installing systemd-timesyncd..."
        if ! common_safe_install systemd-timesyncd; then
            warn "Failed to install systemd-timesyncd"
            return 1
        fi
        service="systemd-timesyncd.service"
    else
        log "Detected NTP service: ${service%.service}"
    fi

    if ! systemctl is-active "$service" >/dev/null 2>&1; then
        if ! systemctl enable --now "$service" >/dev/null 2>&1 && ! systemctl start "$service" >/dev/null 2>&1; then
            warn "Failed to enable or start NTP service: ${service%.service}"
            return 1
        fi
        log "NTP service started: ${service%.service}"
    fi
    COMMON_TIME_SYNC_SERVICE="${service%.service}"
}

# common_enable_time_sync: common_ensure_time_sync_service, then `timedatectl set-ntp true`.
# Returns 1 without timedatectl or systemd, or when time sync could not be enabled.
common_enable_time_sync() {
    COMMON_TIME_SYNC_SERVICE=""
    if ! command -v timedatectl >/dev/null 2>&1; then
        info "timedatectl is unavailable. Install and start chrony, ntpsec, or systemd-timesyncd manually if time sync is required."
        return 1
    fi
    if ! common_systemd_running; then
        info "systemd is unavailable. Install and start an NTP daemon manually before enabling time synchronization."
        return 1
    fi

    common_ensure_time_sync_service || return 1

    if timedatectl set-ntp true 2>/dev/null; then
        log "NTP synchronization enabled via $COMMON_TIME_SYNC_SERVICE"
        return 0
    fi

    if systemctl is-active "$COMMON_TIME_SYNC_SERVICE.service" >/dev/null 2>&1; then
        if common_system_clock_synchronized; then
            log "Time sync already operational via $COMMON_TIME_SYNC_SERVICE"
        else
            info "Time-sync daemon $COMMON_TIME_SYNC_SERVICE is active even though timedatectl could not control it directly"
        fi
        return 0
    fi

    warn "Could not enable NTP via timedatectl after preparing $COMMON_TIME_SYNC_SERVICE"
    return 1
}

# common_temp_dir <variable> [parent]: a fresh directory from mktemp -d (inside <parent> when
# given) stored in <variable>. It is removed when the script exits, also on an error or a
# signal, unless the caller removed it first. The removal is an EXIT trap set here: an EXIT trap
# the caller set before stays and skips it, so the scripts set none of their own (hygiene test).
common_temp_dir() {
    local __common_var="${1:-}" __common_parent="${2:-}" __common_dir

    if [ -n "$__common_parent" ]; then
        __common_dir="$(mktemp -d "$__common_parent/.optimize.XXXXXX")" || return 1
    else
        __common_dir="$(mktemp -d)" || return 1
    fi
    COMMON_TEMP_DIRS+=("$__common_dir")
    if [ -z "$(trap -p EXIT)" ]; then
        trap common_remove_temp_dirs EXIT
    fi
    printf -v "$__common_var" '%s' "$__common_dir"
}

# Removes the directories of common_temp_dir that are still there.
common_remove_temp_dirs() {
    local dir

    for dir in ${COMMON_TEMP_DIRS[@]+"${COMMON_TEMP_DIRS[@]}"}; do
        [ ! -d "$dir" ] || rm -rf -- "$dir"
    done
    COMMON_TEMP_DIRS=()
}

# common_keep_temp_dir <dir>: <dir> of common_temp_dir is no longer removed on exit (it holds
# something the operator has to recover).
common_keep_temp_dir() {
    local dir kept=()

    for dir in ${COMMON_TEMP_DIRS[@]+"${COMMON_TEMP_DIRS[@]}"}; do
        [ "$dir" = "${1:-}" ] || kept+=("$dir")
    done
    COMMON_TEMP_DIRS=(${kept[@]+"${kept[@]}"})
}

# common_download <url> <file>: HTTPS only, redirects included; every attempt is bounded in
# connection and total time, a few retries on transient errors start only within that total
# time, so a bad network fails within about twice COMMON_DOWNLOAD_MAX_TIME instead of hanging.
common_download() {
    curl -fsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout "${COMMON_DOWNLOAD_CONNECT_TIMEOUT:-20}" \
        --max-time "${COMMON_DOWNLOAD_MAX_TIME:-900}" \
        --retry "${COMMON_DOWNLOAD_RETRIES:-3}" --retry-delay 3 \
        --retry-max-time "${COMMON_DOWNLOAD_MAX_TIME:-900}" \
        -o "$2" "$1"
}

# Third-party downloads pinned in the repository: "<url> <sha256>" of <tool> for a Debian
# architecture (dpkg --print-architecture). The sums come from the projects' published
# checksums (fnm publishes none: computed from the release asset); a new version needs new
# sums. Returns 1 when <tool> has no pin for the architecture.
common_pinned_download() {
    case "${1:-}:${2:-}" in
        starship:amd64) printf '%s %s\n' https://github.com/starship/starship/releases/download/v1.27.0/starship-x86_64-unknown-linux-gnu.tar.gz 3b94758850901717eb36aa1b53f8492c1322506ec6d41273bc6151e79ed8e4a1 ;;
        starship:arm64) printf '%s %s\n' https://github.com/starship/starship/releases/download/v1.27.0/starship-aarch64-unknown-linux-musl.tar.gz 341f5cbf24699fa0b27ec88965ad25f862ea09e15d35a543fd6ffdff1d2aa00d ;;
        fnm:amd64) printf '%s %s\n' https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-linux.zip 7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224 ;;
        fnm:arm64) printf '%s %s\n' https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-arm64.zip 4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599 ;;
        go:amd64) printf '%s %s\n' https://dl.google.com/go/go1.27.3.linux-amd64.tar.gz 65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ;;
        go:arm64) printf '%s %s\n' https://dl.google.com/go/go1.27.3.linux-arm64.tar.gz a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49 ;;
        cuda-keyring-debian12:amd64) printf '%s %s\n' https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb e7f219eab6fe4819cdb5c15b98233dc3420302d9c00883219cd3d896857cf48d ;;
        cuda-keyring-debian13:amd64) printf '%s %s\n' https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb d0d4ef986a44400f9db33c600ef33a985175e7cc63d805a10e1839c7a1e78f5f ;;
        *) return 1 ;;
    esac
}

# common_fetch_verified <url> <sha256> <file>: downloads <url> into a fresh directory next to
# <file> and moves it there only when its SHA-256 is <sha256>: a partial or substituted download
# never reaches <file>, and a large download does not fill a RAM-backed /tmp.
common_fetch_verified() {
    local url="${1:-}" expected="${2:-}" dest="${3:-}"
    local tmp_dir actual

    if [ -z "$url" ] || [ -z "$dest" ] || ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        error "A download needs a URL, a SHA-256 and a target file"
        return 1
    fi
    common_temp_dir tmp_dir "$(dirname "$dest")" || return 1
    if ! common_download "$url" "$tmp_dir/download"; then
        rm -rf "$tmp_dir"
        warn "Download failed: $url"
        return 1
    fi
    actual="$(sha256sum "$tmp_dir/download" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        rm -rf "$tmp_dir"
        error "Checksum mismatch for $url: expected $expected, got ${actual:-nothing}"
        return 1
    fi
    if ! mv -f "$tmp_dir/download" "$dest"; then
        rm -rf "$tmp_dir"
        error "Could not move the download of $url to $dest"
        return 1
    fi
    rm -rf "$tmp_dir"
}

# common_fetch_pinned <tool> <file>: common_fetch_verified with the pin of <tool> for this
# machine's architecture.
common_fetch_pinned() {
    local tool="${1:-}" dest="${2:-}"
    local arch pin url sum

    arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
    if ! pin="$(common_pinned_download "$tool" "$arch")"; then
        warn "No pinned $tool release for architecture ${arch:-unknown}"
        return 1
    fi
    read -r url sum <<<"$pin"
    common_fetch_verified "$url" "$sum" "$dest"
}

# common_fetch_pinned_binary <tool> <dir>: the <tool> binary from its pinned release archive
# (.tar.gz or .zip), checked and extracted to <dir>/<tool> with mode 755.
common_fetch_pinned_binary() {
    local tool="${1:-}" dir="${2:-}"
    local archive="$2/$1.download"
    local status=0

    common_fetch_pinned "$tool" "$archive" || return 1
    case "$(common_pinned_download "$tool" "$(dpkg --print-architecture 2>/dev/null)")" in
        *.zip\ *) unzip -q -o "$archive" "$tool" -d "$dir" || status=1 ;;
        *.tar.gz\ *) tar -xzf "$archive" -C "$dir" "$tool" || status=1 ;;
        *) status=1 ;;
    esac
    rm -f "$archive"
    if [ "$status" -ne 0 ] || ! chmod 755 "$dir/$tool"; then
        error "Could not extract $tool from its release archive"
        return 1
    fi
}

# common_install_starship: the Debian package when the release has one (Debian 13), otherwise
# the pinned release binary in /usr/local/bin. Returns 1 when starship could not be installed.
common_install_starship() {
    local tmp_dir status=0

    command -v starship >/dev/null 2>&1 && return 0
    if common_package_available starship && common_safe_install starship && command -v starship >/dev/null 2>&1; then
        return 0
    fi

    common_temp_dir tmp_dir || return 1
    if ! common_fetch_pinned_binary starship "$tmp_dir" ||
        ! install -m 755 "$tmp_dir/starship" "${COMMON_STARSHIP_BIN:-/usr/local/bin/starship}"; then
        status=1
    fi
    rm -rf "$tmp_dir"
    return "$status"
}

# Signing keys of third-party APT repositories pinned in the repository: "<url> <fingerprint>"
# of the primary key, as the vendors publish it. Returns 1 for an unknown name.
common_apt_key_pin() {
    case "${1:-}" in
        docker) printf '%s %s\n' https://download.docker.com/linux/debian/gpg 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ;;
        nvidia-container-toolkit) printf '%s %s\n' https://nvidia.github.io/libnvidia-container/gpgkey C95B321B61E88C1809C4F759DDCAE044F796ECB0 ;;
        *) return 1 ;;
    esac
}

# common_install_apt_key <name> <keyring>: the signing key <name> of common_apt_key_pin,
# accepted only when the downloaded file holds exactly that primary key. A keyring ending in
# .asc keeps the armored key; any other name gets the binary form.
common_install_apt_key() {
    local key_name="${1:-}" keyring="${2:-}"
    local pin url fingerprint tmp_dir actual status=0

    if ! pin="$(common_apt_key_pin "$key_name")" || [ -z "$keyring" ]; then
        error "No pinned APT key named '$key_name'"
        return 1
    fi
    read -r url fingerprint <<<"$pin"

    common_temp_dir tmp_dir || return 1
    if ! common_download "$url" "$tmp_dir/key"; then
        rm -rf "$tmp_dir"
        warn "Download failed: $url"
        return 1
    fi
    mkdir -m 700 "$tmp_dir/gnupg"
    actual="$(GNUPGHOME="$tmp_dir/gnupg" gpg --batch --show-keys --with-colons "$tmp_dir/key" 2>/dev/null |
        awk -F: '$1 == "pub" { primary = 1 } $1 == "fpr" && primary { print $10; primary = 0 }')"
    if [ "$actual" != "$fingerprint" ]; then
        rm -rf "$tmp_dir"
        error "The key at $url has fingerprint ${actual:-none}, expected $fingerprint"
        return 1
    fi
    case "$keyring" in
        *.asc) cp "$tmp_dir/key" "$tmp_dir/keyring" || status=1 ;;
        *) GNUPGHOME="$tmp_dir/gnupg" gpg --batch --yes --dearmor -o "$tmp_dir/keyring" "$tmp_dir/key" || status=1 ;;
    esac
    if [ "$status" -ne 0 ] || ! install -m 644 "$tmp_dir/keyring" "$keyring"; then
        rm -rf "$tmp_dir"
        error "Could not write the APT key $keyring"
        return 1
    fi
    rm -rf "$tmp_dir"
}

# common_install_go [prefix]: the pinned Go release in <prefix>/go (/usr/local/go). It is
# downloaded and unpacked in a directory inside <prefix>, so a noexec or RAM-backed /tmp does not
# matter, and swapped in by rename only after the check; a failed swap puts the old tree back.
common_install_go() {
    local prefix="${1:-/usr/local}"
    local work_dir

    common_temp_dir work_dir "$prefix" || return 1
    if ! common_fetch_pinned go "$work_dir/go.tar.gz" || ! tar -xzf "$work_dir/go.tar.gz" -C "$work_dir" ||
        [ ! -f "$work_dir/go/bin/go" ]; then
        rm -rf "$work_dir"
        error "Could not download and unpack the pinned Go release"
        return 1
    fi
    if [ -e "$prefix/go" ] && ! mv "$prefix/go" "$work_dir/go.previous"; then
        rm -rf "$work_dir"
        error "Could not move the installed Go in $prefix/go aside"
        return 1
    fi
    if ! mv "$work_dir/go" "$prefix/go"; then
        if [ -e "$work_dir/go.previous" ] && ! mv "$work_dir/go.previous" "$prefix/go"; then
            common_keep_temp_dir "$work_dir"
            error "Could not put the previous Go back; it is in $work_dir/go.previous"
            return 1
        fi
        rm -rf "$work_dir"
        error "Could not install Go into $prefix/go"
        return 1
    fi
    rm -rf "$work_dir"
}

# common_render_fish_config <vps|mini|wsl2>: ~/.config/fish/config.fish of a profile.
common_render_fish_config() {
    local profile="${1:-}"

    case "$profile" in
        vps) printf '%s\n' '# ~/.config/fish/config.fish' ;;
        mini) printf '%s\n' '# ~/.config/fish/config.fish - Mini PC Media/Home Server' ;;
        wsl2) printf '%s\n' '# ~/.config/fish/config.fish - WSL2 Optimized Configuration' ;;
        *) return 1 ;;
    esac
    cat <<'FISH_EOF'
set -g fish_greeting ""
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'

# WSL2 Environment Variables
set -gx EDITOR code
set -gx VISUAL code
set -gx BROWSER "/mnt/c/Windows/System32/cmd.exe /c start"
set -gx DISPLAY ":0"
FISH_EOF
    fi
    cat <<'FISH_EOF'

# Environment & Paths
if test -d /usr/local/go/bin
    fish_add_path /usr/local/go/bin
end
if test -d $HOME/go/bin
    fish_add_path $HOME/go/bin
end
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
if test -d /usr/local/cuda
    set -gx CUDA_HOME /usr/local/cuda
    fish_add_path /usr/local/cuda/bin
    if test -d /usr/local/cuda/lib64
        set -gx LD_LIBRARY_PATH /usr/local/cuda/lib64 $LD_LIBRARY_PATH
    end
end
FISH_EOF
    fi
    cat <<'FISH_EOF'
if test -d /usr/sbin
    fish_add_path /usr/sbin
end
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
if test -d /mnt/c/Windows/System32
    fish_add_path /mnt/c/Windows/System32
end
FISH_EOF
    fi
    cat <<'FISH_EOF'

# Fast Node Manager (fnm) hook
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
if test -d "$HOME/.local/share/fnm"
    set -gx FNM_PATH "$HOME/.local/share/fnm"
    fish_add_path -g "$FNM_PATH"
end
FISH_EOF
    fi
    cat <<'FISH_EOF'
if command -v fnm >/dev/null 2>&1
    fnm env --use-on-cd --shell fish | source
end

# System Aliases
alias ll="ls -alFh"
alias la="ls -A"
alias l="ls -CF"
alias cls="clear"
alias c="clear"
alias h="history"
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

# System Monitoring Aliases
alias meminfo="free -h"
alias cpuinfo="lscpu"
alias diskinfo="df -h"
alias ports="ss -tulpn"
alias psa="ps aux"
FISH_EOF
    if [ "$profile" = mini ]; then
        cat <<'FISH_EOF'

# Hardware Monitoring (GPU & Sensors)
alias gpuinfo="vainfo 2>/dev/null || intel_gpu_top"
alias temp="sensors"
FISH_EOF
    fi
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
alias psg="ps aux | grep"
FISH_EOF
    fi
    cat <<'FISH_EOF'

# Package Management Aliases
alias update="sudo apt update && sudo apt upgrade -y"
alias install="sudo apt install"
alias remove="sudo apt remove"
alias search="apt search"
alias autoremove="sudo apt autoremove -y"

# Docker Aliases
alias d="docker"
alias dc="docker compose"
alias dps="docker ps"
alias dpsa="docker ps -a"
alias di="docker images"
alias dcu="docker compose up -d"
alias dcd="docker compose down"
alias dcl="docker compose logs -f"
alias dex="docker exec -it"
alias drm="docker rm"
alias drmi="docker rmi"
alias dprune="docker system prune -af"

# Git Aliases
alias g="git"
alias gs="git status"
alias gst="git status"
alias ga="git add"
alias gaa="git add --all"
alias gc="git commit"
alias gcm="git commit -m"
alias gca="git commit -a"
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
alias gcam="git commit -am"
FISH_EOF
    fi
    cat <<'FISH_EOF'
alias gp="git pull"
alias gP="git push"
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
alias gpo="git push origin"
FISH_EOF
    fi
    cat <<'FISH_EOF'
alias gl="git log --oneline --graph --decorate"
alias gd="git diff"
FISH_EOF
    if [ "$profile" = wsl2 ]; then
        cat <<'FISH_EOF'
alias gb="git branch"
alias gco="git checkout"
alias gcb="git checkout -b"

# WSL2 Helper Functions
function explorer
    if test (count $argv) -gt 0
        explorer.exe (wslpath -w "$argv[1]")
    else
        explorer.exe (wslpath -w ".")
    end
end

function cmd
    cmd.exe /c "$argv"
end

function powershell
    powershell.exe -Command "$argv"
end

function wslperf
    echo "=== WSL Performance ==="
    echo "Memory: "(free -h | grep '^Mem:' | awk '{print $3"/"$2}')
    echo "CPU: "(top -bn1 | grep 'Cpu(s):' | awk '{print $2}' | cut -d'%' -f1)"%"
    echo "Disk: "(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')
end

function mkcd
    mkdir -p "$argv[1]"; and cd "$argv[1]"
end
FISH_EOF
    fi
    cat <<'FISH_EOF'

# Interactive starship prompt
if status is-interactive
    if command -v starship >/dev/null 2>&1
        starship init fish | source
    end
end
FISH_EOF
}

# common_render_bashrc <vps|mini|wsl2>: ~/.bashrc of a profile. It starts the interactive Fish
# session, so the Fish step does not write ~/.bashrc itself.
common_render_bashrc() {
    local profile="${1:-}"

    case "$profile" in
        vps) printf '%s\n' '# VPS Optimized Bash Configuration' ;;
        mini) printf '%s\n' '# Mini PC Optimized Bash Configuration' ;;
        wsl2) printf '%s\n' '# WSL2 Optimized Bash Configuration' ;;
        *) return 1 ;;
    esac
    cat <<'BASHRC'

# Auto-switch to Fish for interactive sessions only
# Non-interactive SSH commands, cron, scp/rsync stay in standard Bash
if [[ $- == *i* ]] && [ -z "${SSH_ORIGINAL_COMMAND:-}" ] && command -v fish >/dev/null 2>&1; then
    exec fish
fi

# ============================================
# Shell Options
# ============================================

# History configuration
HISTSIZE=50000
HISTFILESIZE=100000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT="%F %T "
shopt -s histappend

# Navigation and behavior
shopt -s autocd           # cd to directory just by typing its name
shopt -s cdspell          # autocorrect typos in path names when using cd
shopt -s dirspell         # autocorrect typos in directory names during completion
shopt -s globstar         # ** recursive glob
shopt -s checkwinsize     # update LINES and COLUMNS after each command
shopt -s nocaseglob       # case-insensitive globbing

# Completion options
shopt -s no_empty_cmd_completion

# ============================================
# Bash Completion
# ============================================

if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# ============================================
# Environment Variables
# ============================================

BASHRC
    if [ "$profile" = wsl2 ]; then
        cat <<'BASHRC'
# WSL2-specific environment variables
export EDITOR='code'
export VISUAL='code'
export BROWSER="/mnt/c/Windows/System32/cmd.exe /c start"
export DISPLAY=":0"
BASHRC
    fi
    if [ "$profile" = vps ] || [ "$profile" = mini ]; then
        cat <<'BASHRC'
export EDITOR='vim'
export VISUAL='vim'
export PAGER='less'
BASHRC
    fi
    cat <<'BASHRC'

BASHRC
    if [ "$profile" = wsl2 ]; then
        cat <<'BASHRC'
# Path optimization for WSL
export PATH="/usr/local/bin:/usr/bin:$PATH"
BASHRC
    fi
    if [ "$profile" = vps ] || [ "$profile" = mini ]; then
        cat <<'BASHRC'
# Path optimization
export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/sbin:$PATH"
BASHRC
    fi
    cat <<'BASHRC'

# ============================================
# Prompt Configuration
# ============================================

# Colors for prompt
if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
    # We have color support
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\u@\h:\w\$ '
fi

# If Starship is installed, use it
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi

# ============================================
# Docker Aliases
# ============================================

alias d='docker'
alias dc='docker compose'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias dex='docker exec -it'
alias drm='docker rm'
alias drmi='docker rmi'
alias dprune='docker system prune -af'

# ============================================
# Git Aliases
# ============================================

alias g='git'
alias gs='git status'
alias gst='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit -a'
alias gcam='git commit -am'
alias gp='git pull'
alias gP='git push'
alias gpo='git push origin'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gb='git branch'
alias gco='git checkout'
alias gcb='git checkout -b'

# ============================================
# System Aliases
# ============================================

alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias c='clear'
alias h='history'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

# System monitoring
alias meminfo='free -h'
alias cpuinfo='lscpu'
alias diskinfo='df -h'
alias ports='ss -tulpn'
alias psa='ps aux'
alias psg='ps aux | grep'

# Package management
alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install'
alias remove='sudo apt remove'
alias search='apt search'
alias autoremove='sudo apt autoremove -y'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias mkdir='mkdir -pv'

# ============================================
BASHRC
    if [ "$profile" = wsl2 ]; then
        cat <<'BASHRC'
# WSL2-specific Functions
# ============================================

explorer() {
    if [ -z "$1" ]; then
        explorer.exe .
    else
        explorer.exe "$(wslpath -w "$1")"
    fi
}

cmd() {
    cmd.exe /c "$*"
}

powershell() {
    powershell.exe -Command "$*"
}

wslperf() {
    echo "=== WSL Performance ==="
    echo "Memory: $(free -h | grep '^Mem:' | awk '{print $3"/"$2}')"
    echo "CPU: $(top -bn1 | grep 'Cpu(s):' | awk '{print $2}' | cut -d'%' -f1)%"
    echo "Disk: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
}

# ============================================
BASHRC
    fi
    cat <<'BASHRC'
# Useful Functions
# ============================================

mkcd() {
    mkdir -p "$1" && cd "$1"
}

extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    tar xzf "$1"     ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.rar)       unrar e "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.tbz2)      tar xjf "$1"     ;;
            *.tgz)       tar xzf "$1"     ;;
            *.zip)       unzip "$1"       ;;
            *.Z)         uncompress "$1"  ;;
            *.7z)        7z x "$1"        ;;
            *)           echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# ============================================
# fnm (Fast Node Manager)
# ============================================

export FNM_PATH="$HOME/.local/share/fnm"
export PATH="$FNM_PATH:$PATH"
export XDG_RUNTIME_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fnm-runtime"
mkdir -p "$XDG_RUNTIME_DIR"
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi

# ============================================
BASHRC
    if [ "$profile" = vps ] || [ "$profile" = mini ]; then
        cat <<'BASHRC'
# Go Configuration
# ============================================

export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

# ============================================
BASHRC
    fi
    cat <<'BASHRC'
# Additional Settings
# ============================================

# Enable color support for ls and grep
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# Improved less
export LESS='-R -F -X'
export LESSOPEN='| /usr/bin/lesspipe %s 2>&-'
BASHRC
    if [ "$profile" = wsl2 ]; then
        cat <<'BASHRC'

# ============================================
# Welcome Message (optional)
# ============================================

# Uncomment to show system info on login
# if [ -t 0 ]; then
#     echo "Welcome to WSL2 - $(lsb_release -d | cut -f2)"
#     echo "$(uname -r)"
# fi
BASHRC
    fi
}

# common_setup_fish <user> <home> <profile>: Starship's nerd-font-symbols preset and the
# profile's config.fish in <home>/.config, owned by <user>. ~/.bashrc, which starts Fish for
# interactive sessions, is written by common_setup_bashrc. Returns 1 without touching anything
# when <home> is missing: root does not create a user's home here.
common_setup_fish() {
    local user="${1:-}" home="${2:-}" profile="${3:-}"
    local config

    if [ -z "$home" ] || [ ! -d "$home" ]; then
        warn "Home directory ${home:-(none)} of $user is missing; its Fish configuration is skipped"
        return 1
    fi
    config="$(common_render_fish_config "$profile")" || return 1
    install -d -m 0755 "$home/.config/fish" || return 1
    if command -v starship >/dev/null 2>&1; then
        starship preset nerd-font-symbols > "$home/.config/starship.toml" 2>/dev/null || true
        chmod 644 "$home/.config/starship.toml" 2>/dev/null || true
    fi
    printf '%s\n' "$config" > "$home/.config/fish/config.fish" || return 1
    chmod 644 "$home/.config/fish/config.fish"
    chown -R "$user:" "$home/.config" 2>/dev/null || true
}

# common_setup_bashrc <user> <home> <profile>: the profile's ~/.bashrc, owned by <user>. A .bashrc
# that none of the profiles wrote is copied first, with its owner and mode, to a new file
# .bashrc.backup.<time>.<suffix> (mktemp: a name prepared in the user's home is not followed), so
# a repeated run makes no new copy. Returns 1 without touching anything when <home> is missing.
common_setup_bashrc() {
    local user="${1:-}" home="${2:-}" profile="${3:-}"
    local bashrc="${2:-}/.bashrc"
    local config backup

    if [ -z "$home" ] || [ ! -d "$home" ]; then
        warn "Home directory ${home:-(none)} of $user is missing; its Bash configuration is skipped"
        return 1
    fi
    config="$(common_render_bashrc "$profile")" || return 1
    if [ -f "$bashrc" ] && ! head -n 1 "$bashrc" | grep -qE '^# (VPS|Mini PC|WSL2) Optimized Bash Configuration$'; then
        # Without a copy the user's own .bashrc is not replaced.
        if ! backup="$(mktemp "$bashrc.backup.$(date +%Y%m%d_%H%M%S).XXXXXX")" || ! cat "$bashrc" > "$backup"; then
            warn "Could not back up the existing .bashrc of $user; it is left as it is"
            return 1
        fi
        chown --reference="$bashrc" "$backup" 2>/dev/null || true
        chmod --reference="$bashrc" "$backup" 2>/dev/null || true
        log "Backed up existing .bashrc for $user to $backup"
    fi
    printf '%s\n' "$config" > "$bashrc" || return 1
    if [ "$user" != root ]; then
        chown "$user:" "$bashrc" 2>/dev/null || true
    fi
}

# SSH hardening drop-ins. For most keywords sshd keeps the first value it reads, and Debian's
# sshd_config includes /etc/ssh/sshd_config.d/*.conf in name order before its own lines, so a
# drop-in that sorts first (for example cloud-init's 50-cloud-init.conf before 99-*.conf) wins.
# The hardening drop-ins are named 00-*.conf, and the values sshd takes are read back with sshd -T.

# common_sshd_effective_mismatches <"keyword value">...: prints "keyword: expected <value>,
# effective <values>" for each pair that `sshd -T` does not show. Keywords are lower case, as
# sshd -T prints them; a keyword that takes several values (allowusers, port) matches when one of
# them is the expected one. Match blocks are not applied. Returns 0 when every pair matches, 1 on
# a mismatch and 2 when sshd -T fails.
common_sshd_effective_mismatches() {
    local effective pair keyword actual rc=0

    effective="$(sshd -T 2>/dev/null)" || return 2
    for pair in "$@"; do
        grep -qxF -- "$pair" <<<"$effective" && continue
        keyword="${pair%% *}"
        actual="$(awk -v k="$keyword" '$1 == k { sub(/^[^ ]+ /, ""); v = v (v == "" ? "" : ", ") $0 } END { print v }' <<<"$effective")"
        printf '%s: expected %s, effective %s\n' "$keyword" "${pair#* }" "${actual:-none}"
        rc=1
    done
    return "$rc"
}

# common_sshd_legacy_dropin_is_ours <file>: <file> is a hardening drop-in that an earlier version
# of these scripts wrote under a 99-*.conf name: it starts with the VPS or Amnezia header, or it is
# exactly the four lines of the mini-PC. An operator's file with the same name is not ours.
common_sshd_legacy_dropin_is_ours() {
    local file="${1:-}"
    local lines=()

    [ -f "$file" ] && mapfile -t lines < "$file" 2>/dev/null || return 1
    case "${lines[0]:-}" in
        "# SSH Hardening - VPS Optimization" | "# Minimal Amnezia host SSH baseline") return 0 ;;
    esac
    [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = "PermitRootLogin no" ] &&
        [ "${lines[1]}" = "PasswordAuthentication no" ] && [ "${lines[2]}" = "PubkeyAuthentication yes" ] &&
        [[ "${lines[3]}" =~ ^AllowUsers\ [^[:space:]]+$ ]]
}

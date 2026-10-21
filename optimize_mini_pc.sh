#!/bin/bash

# Force C locale for script execution to avoid locale-related issues
export LC_ALL=C
export LANG=C

################################################################################
# Mini PC Optimization Script (Intel N5095/Jasper Lake Focus)
# Purpose: Complete optimization for Home Server / Media Server on Debian 12/13
# Hardware Focus: Intel Celeron N5095 (Jasper Lake), Debian Backports kernel, Fish + Starship, SSD/NVMe, Intel UHD GPU
# Version: 1.0.0 (Hybrid VPS+WSL2 features)
################################################################################

set -e
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_PATH="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
if [ -d "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)" || SCRIPT_DIR=""
else
    SCRIPT_DIR=""
fi
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR="$(pwd -P)"

if [ -r "$SCRIPT_DIR/lib/common.sh" ]; then
    # shellcheck source=lib/common.sh
    source "$SCRIPT_DIR/lib/common.sh"
fi
if [ -r "$SCRIPT_DIR/lib/tui.sh" ]; then
    # shellcheck source=lib/tui.sh
    source "$SCRIPT_DIR/lib/tui.sh"
fi

if ! declare -F common_generate_utf8_locales >/dev/null; then
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
fi

if ! declare -F common_is_supported_debian_version >/dev/null; then
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
fi

if ! declare -F common_apt_get >/dev/null; then
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
fi

if ! declare -F common_enrich_apt_components >/dev/null; then
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
fi

if ! declare -F common_systemd_running >/dev/null; then
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
fi

if ! declare -F common_temp_dir >/dev/null; then
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
fi

if ! declare -F common_render_fish_config >/dev/null; then
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
fi

if ! declare -F tui_detect_backend >/dev/null; then
    : "${GUM:=/usr/local/bin/gum}"
    : "${TUI_GUM_VERSION:=0.17.0}"
    : "${TUI_AUTO_INSTALL_GUM:=true}"

    tui_gum_path() {
        if [ -n "${TUI_GUM_BIN:-}" ] && [ -x "$TUI_GUM_BIN" ]; then
            printf '%s\n' "$TUI_GUM_BIN"
            return 0
        fi
        if [ -n "${GUM:-}" ] && [ -x "$GUM" ]; then
            printf '%s\n' "$GUM"
            return 0
        fi
        command -v gum 2>/dev/null || return 1
    }

    tui_gum_asset_arch() {
        case "$(uname -m)" in
            x86_64|amd64) printf '%s\n' "x86_64" ;;
            aarch64|arm64) printf '%s\n' "arm64" ;;
            armv7l) printf '%s\n' "armv7" ;;
            *) uname -m ;;
        esac
    }

    # SHA-256 of the gum release archive for TUI_GUM_VERSION and an asset architecture, pinned in
    # the repository from the release's checksums.txt; another version has no pin and is not installed.
    tui_gum_sha256() {
        case "${TUI_GUM_VERSION}:${1:-}" in
            0.17.0:x86_64) printf '%s\n' 69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb ;;
            0.17.0:arm64) printf '%s\n' b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c ;;
            0.17.0:armv7) printf '%s\n' 25711c2fbc6887cde79ed586972834121a04955968808dd688c688381ac50ab2 ;;
            *) return 1 ;;
        esac
    }

    tui_install_gum() {
        local gum_dir tmp_dir arch dl_url gum_checksum gum_path

        command -v curl >/dev/null 2>&1 || return 1
        command -v tar >/dev/null 2>&1 || return 1
        command -v sha256sum >/dev/null 2>&1 || return 1

        arch="$(tui_gum_asset_arch)"
        gum_checksum="$(tui_gum_sha256 "$arch")" || return 1
        [ "$(uname -s)" = Linux ] || return 1

        gum_dir="$(dirname "$GUM")"
        mkdir -p "$gum_dir" 2>/dev/null || return 1
        [ -w "$gum_dir" ] || return 1

        tmp_dir="$(mktemp -d)" || return 1
        dl_url="https://github.com/charmbracelet/gum/releases/download/v${TUI_GUM_VERSION}/gum_${TUI_GUM_VERSION}_Linux_${arch}.tar.gz"

        # HTTPS only and bounded in time, like common_download (lib/tui.sh does not need lib/common.sh).
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 \
            --retry 3 --retry-delay 3 --retry-max-time 300 -o "${tmp_dir}/gum.tar.gz" "$dl_url"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        if [ "$(sha256sum "${tmp_dir}/gum.tar.gz" | awk '{print $1}')" != "$gum_checksum" ]; then
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! tar -xf "${tmp_dir}/gum.tar.gz" --directory "$tmp_dir"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        gum_path="$(find "$tmp_dir" -type f -executable -name "gum" -print -quit)"
        if [ -z "$gum_path" ] || ! mv "$gum_path" "$GUM"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        chmod +x "$GUM" || {
            rm -rf "$tmp_dir"
            return 1
        }

        TUI_GUM_BIN="$GUM"
        rm -rf "$tmp_dir"
    }

    tui_init() {
        local backend="${TUI_BACKEND:-auto}"
        case "$backend" in
            gum)
                if ! tui_gum_path >/dev/null 2>&1 && [ "$TUI_AUTO_INSTALL_GUM" != "false" ]; then tui_install_gum || return 1; fi
                TUI_RESOLVED_BACKEND="gum"
                ;;
            auto|"")
                if tui_gum_path >/dev/null 2>&1; then
                    TUI_RESOLVED_BACKEND="gum"
                elif [ "$TUI_AUTO_INSTALL_GUM" != "false" ] && [ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" ] && [ -t 1 ]; then
                    if tui_install_gum; then TUI_RESOLVED_BACKEND="gum"; else TUI_RESOLVED_BACKEND="plain"; fi
                else
                    TUI_RESOLVED_BACKEND="plain"
                fi
                ;;
            plain|dialog|whiptail) TUI_RESOLVED_BACKEND="$backend" ;;
            *) return 1 ;;
        esac
    }

    tui_detect_backend() {
        if [ -n "${TUI_RESOLVED_BACKEND:-}" ]; then
            printf '%s\n' "$TUI_RESOLVED_BACKEND"
            return 0
        fi

        case "${TUI_BACKEND:-auto}" in
            gum)
                tui_gum_path >/dev/null 2>&1 || return 1
                printf '%s\n' "gum"
                return 0
                ;;
            dialog|whiptail|plain) printf '%s\n' "$TUI_BACKEND"; return 0 ;;
            auto|"") ;;
            *) return 1 ;;
        esac

        if tui_gum_path >/dev/null 2>&1; then
            printf '%s\n' "gum"
            return 0
        fi

        printf '%s\n' "plain"
    }

    tui_has_visual_backend() {
        local backend
        backend="$(tui_detect_backend)" || return 1
        case "$backend" in
            gum) tui_gum_path >/dev/null 2>&1 ;;
            dialog|whiptail) command -v "$backend" >/dev/null 2>&1 ;;
            *) return 1 ;;
        esac
    }

    tui_gum() {
        local gum_bin
        gum_bin="$(tui_gum_path)" || return 1
        "$gum_bin" "$@"
    }

    tui_prompt_yn() {
        local prompt="$1"
        local default_yes="$2"
        local backend answer prompt_suffix
        backend="$(tui_detect_backend)" || backend="plain"
        if [ "$backend" = "gum" ] && tui_gum_path >/dev/null 2>&1; then
            if $default_yes; then
                tui_gum confirm --prompt.foreground 12 --selected.background 12 --selected.foreground 15 --unselected.foreground 12 "$prompt"
            else
                tui_gum confirm --default=false --prompt.foreground 12 --selected.background 12 --selected.foreground 15 --unselected.foreground 12 "$prompt"
            fi
            return $?
        fi
        if { [ "$backend" = "dialog" ] || [ "$backend" = "whiptail" ]; } && command -v "$backend" >/dev/null 2>&1; then
            if $default_yes; then
                "$backend" --yesno "$prompt" 8 70 3>&1 1>&2 2>&3
            else
                "$backend" --defaultno --yesno "$prompt" 8 70 3>&1 1>&2 2>&3
            fi
            return $?
        fi
        if $default_yes; then prompt_suffix="[Y/n]"; else prompt_suffix="[y/N]"; fi
        read -r -p "${TUI_PROMPT_PREFIX:-}${prompt} ${prompt_suffix}: " answer || answer=""
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
            "") $default_yes; return $? ;;
            *) printf 'Invalid response. Please answer yes or no.\n' >&2; tui_prompt_yn "$prompt" "$default_yes" ;;
        esac
    }

    tui_radiolist() {
        local title="$1" prompt="$2" height="$3" width="$4" list_height="$5" backend
        local tag label status choice
        local options=()
        shift 5
        backend="$(tui_detect_backend)" || return 1
        case "$backend" in
            gum)
                tui_gum_path >/dev/null 2>&1 || return 1
                while [ "$#" -gt 0 ]; do
                    tag="$1"
                    label="${2:-}"
                    status="${3:-off}"
                    if [ "$status" = "on" ]; then
                        options=("${tag} - ${label}" "${options[@]}")
                    else
                        options+=("${tag} - ${label}")
                    fi
                    shift 3
                done
                choice="$(tui_gum choose --cursor "> " --header.foreground 12 --cursor.foreground 12 --header "+ ${title}: ${prompt}" "${options[@]}")" || return 1
                printf '%s\n' "${choice%% *}"
                ;;
            dialog|whiptail)
                command -v "$backend" >/dev/null 2>&1 || return 1
                "$backend" --title "$title" --radiolist "$prompt" "$height" "$width" "$list_height" "$@" 3>&1 1>&2 2>&3
                ;;
            plain) return 1 ;;
        esac
    }
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Symbols for modern output
SYMBOL_GEAR="⚙"
SYMBOL_PACKAGE="📦"
SYMBOL_ROCKET="🚀"
SYMBOL_WARN="⚠"
SYMBOL_INFO="ℹ"

# Logging
LOG_FILE="/var/log/minipc_optimization.log"

# Silent logging (to file only)
# APT helper settings are fixed here: a root shell's environment must not change them.
COMMON_APT_LOCK_TIMEOUT=300
COMMON_APT_UPDATE_RETRY_DELAY=10
COMMON_APT_UPDATE_ATTEMPTS=30
COMMON_APT_UPDATE_CHECK=""
COMMON_APT_INDEX_FRESH=0

log_silent() {
    [ -n "${LOG_FILE:-}" ] || return 0
    local log_dir
    log_dir="$(dirname "$LOG_FILE" 2>/dev/null || echo "")"
    if [ -w "$LOG_FILE" ] || { [ ! -e "$LOG_FILE" ] && [ -n "$log_dir" ] && [ -w "$log_dir" ]; }; then
        mkdir -p "$log_dir" 2>/dev/null || return 0
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

ui_backend() {
    local backend

    if declare -F tui_detect_backend >/dev/null; then
        backend="$(tui_detect_backend 2>/dev/null || true)"
    fi
    printf '%s\n' "${backend:-plain}"
}

ui_has_gum() {
    declare -F tui_gum_path >/dev/null && [ "$(ui_backend)" = "gum" ] && tui_gum_path >/dev/null 2>&1
}

ui_style() {
    ui_has_gum && tui_gum style "$@"
}

ui_clean_heading() {
    local text="$*"
    local marker

    for marker in \
        "${SYMBOL_GEAR:-}" \
        "${SYMBOL_PACKAGE:-}" \
        "${SYMBOL_ROCKET:-}" \
        "${SYMBOL_WARN:-}" \
        "${SYMBOL_INFO:-}"; do
        [ -n "$marker" ] && text="${text//$marker/}"
    done

    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s\n' "$text"
}

ui_title() {
    local text

    text="$(ui_clean_heading "$*")"
    if ! ui_style --foreground 12 --bold "+ ${text}"; then
        echo -e "${BLUE}${BOLD}+ ${text}${NC}"
    fi
}

ui_message() {
    local color="$1"
    local label="$2"
    local message="$3"

    printf '  %b%-7s%b %s\n' "$color" "[$label]" "$NC" "$message"
}

ui_hint() {
    local text="$1"

    if ! ui_style --foreground 8 "  ${text}"; then
        echo -e "  ${DIM}${text}${NC}"
    fi
}

ui_success_title() {
    local text="$1"

    if ! ui_style --foreground 10 --bold "${text}"; then
        echo -e "${GREEN}${BOLD}${text}${NC}"
    fi
}

ui_option_state() {
    local label="$1"
    local enabled="$2"
    local status color

    if $enabled; then
        status="enabled"
        color=10
    else
        status="skipped"
        color=8
    fi

    if ui_has_gum; then
        tui_gum join \
            "$(tui_gum style --foreground "$color" --bold "  -")" \
            "$(tui_gum style --foreground 15 "$(printf ' %-42s' "$label")")" \
            "$(tui_gum style --foreground "$color" --bold "$status")"
    else
        echo -e "  ${GREEN}-${NC} $(printf '%-42s' "$label") ${DIM}${status}${NC}"
    fi
}

log() {
    ui_message "$GREEN" "ok" "$1"
    log_silent "[OK] $1"
}

warn() {
    ui_message "$YELLOW" "warn" "$1"
    log_silent "[WARN] $1"
}

error() {
    ui_message "$RED" "error" "$1"
    log_silent "[ERROR] $1"
}

info() {
    ui_message "$BLUE" "info" "$1"
    log_silent "[INFO] $1"
}

progress() {
    ui_message "$CYAN" ".." "$1"
    log_silent "[...] $1"
}

section() {
    local title

    title="$(ui_clean_heading "$*")"
    echo ""
    ui_title "$title"
    log_silent "========== $title =========="
}

# Subsection header
subsection() {
    local title

    title="$(ui_clean_heading "$*")"
    echo ""
    if ! ui_style --foreground 13 --bold "  - ${title}"; then
        echo -e "  ${CYAN}-${NC} ${BOLD}${title}${NC}"
    fi
    log_silent "--- $title ---"
}

append_authorized_key_unique() {
    local ssh_key="$1"
    local target_file="$2"

    touch "$target_file"
    chmod 600 "$target_file"

    if ! grep -Fqx "$ssh_key" "$target_file"; then
        printf '%s\n' "$ssh_key" >> "$target_file"
    fi
}

# Check if running as root
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" && $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

is_supported_debian_version() {
    common_is_supported_debian_version "${1:-}"
}

require_supported_debian_release() {
    if [[ "$ID" != "debian" ]]; then
        error "This script requires Debian. Detected: ${ID:-unknown}"
        exit 1
    fi

    if ! is_supported_debian_version "${VERSION_ID:-}"; then
        error "This script supports Debian 12 (Bookworm) and Debian 13 (Trixie). Detected: Debian ${VERSION_ID:-unknown}"
        exit 1
    fi
}

resolve_intel_media_packages() {
    local packages=(
        "intel-media-va-driver-non-free"
        "intel-gpu-tools"
        "vainfo"
        "mesa-utils"
    )

    if common_package_available "libmfx-gen1.2"; then
        packages+=("libmfx-gen1.2")
    elif common_package_available "libmfx1"; then
        packages+=("libmfx1")
    fi

    printf '%s\n' "${packages[@]}"
}

# Paths of the system files the steps below write. Constants, so that tests
# can point them at a temporary tree after sourcing the script.
SSHD_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
SAMBA_CONF="/etc/samba/smb.conf"
SAMBA_SHARE_PATH="/mnt/ssd"
UFW_BIN="/usr/sbin/ufw"

# Succeeds when $1 is one authorized_keys line that starts with a key type and that
# ssh-keygen can read. ssh-keygen -l alone also takes "host ssh-ed25519 AAAA..."
# (known_hosts format), which sshd does not accept in authorized_keys.
is_valid_ssh_public_key() {
    local key="${1:-}"
    local key_file
    local rc=0

    case "$key" in
        *$'\n'* | *$'\r'*) return 1 ;;
        ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-nistp256\ * | ecdsa-sha2-nistp384\ * | ecdsa-sha2-nistp521\ * | \
            sk-ssh-ed25519@openssh.com\ * | sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
        *) return 1 ;;
    esac

    key_file="$(mktemp)" || return 1
    printf '%s\n' "$key" > "$key_file"
    ssh-keygen -l -f "$key_file" >/dev/null 2>&1 < /dev/null || rc=1
    rm -f "$key_file"
    return "$rc"
}

# Restart the SSH unit; errors of both attempts stay visible.
restart_ssh_service() {
    systemctl restart ssh.service || systemctl restart sshd.service
}

# Put the previous drop-in back (or remove ours when there was none).
revert_ssh_hardening_dropin() {
    local backup="${1:-}"

    if [ -n "$backup" ]; then
        cp -p "$backup" "$SSHD_HARDENING_FILE"
    else
        rm -f "$SSHD_HARDENING_FILE"
    fi
}

# Key-only login for $1. The drop-in stays only when `sshd -t` accepts it and
# SSH restarts with it; otherwise the previous state is restored and 1 returned.
# The new drop-in is written to a temporary file and moved into place, so a write
# error never leaves an empty or partial file over the previous one.
apply_ssh_hardening() {
    local user="$1"
    local dropin_dir
    local backup=""
    local new_file=""

    dropin_dir="$(dirname "$SSHD_HARDENING_FILE")"
    if ! mkdir -p "$dropin_dir"; then
        error "Cannot create $dropin_dir; SSH hardening is not applied"
        return 1
    fi

    if [ -e "$SSHD_HARDENING_FILE" ]; then
        if ! backup="$(mktemp)" || ! cp -p "$SSHD_HARDENING_FILE" "$backup"; then
            error "Cannot back up the existing $SSHD_HARDENING_FILE; SSH hardening is not applied"
            [ -z "$backup" ] || rm -f "$backup"
            return 1
        fi
    fi

    if ! new_file="$(mktemp "$dropin_dir/.99-hardening.XXXXXX")" ||
        ! printf '%s\n' \
            "PermitRootLogin no" \
            "PasswordAuthentication no" \
            "PubkeyAuthentication yes" \
            "AllowUsers $user" > "$new_file" ||
        ! chmod 644 "$new_file" ||
        ! mv -f "$new_file" "$SSHD_HARDENING_FILE"; then
        error "Cannot write $SSHD_HARDENING_FILE; SSH hardening is not applied, the previous file is unchanged"
        [ -z "$new_file" ] || rm -f "$new_file"
        [ -z "$backup" ] || rm -f "$backup"
        return 1
    fi

    if ! sshd -t; then
        error "SSH configuration test failed; reverting $SSHD_HARDENING_FILE, SSH is not restarted"
        revert_ssh_hardening_dropin "$backup"
        [ -z "$backup" ] || rm -f "$backup"
        return 1
    fi

    if ! restart_ssh_service; then
        error "Failed to restart the SSH service with the hardened configuration; reverting $SSHD_HARDENING_FILE"
        revert_ssh_hardening_dropin "$backup"
        if ! restart_ssh_service; then
            error "SSH still does not restart after the revert; check 'systemctl status ssh' on the console"
        fi
        [ -z "$backup" ] || rm -f "$backup"
        return 1
    fi

    [ -z "$backup" ] || rm -f "$backup"
    return 0
}

# Asks for an SSH public key on stdin, adds it to $2/.ssh/authorized_keys for user $1
# and, with CONFIGURE_SECURITY, hardens SSH and waits for the operator to confirm a
# login with the key. Without a key SSH is left alone and CONFIGURE_SECURITY is cleared.
setup_ssh_access() {
    local user="$1"
    local user_home="$2"
    local ssh_key=""

    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"

    echo ""
    info "Please paste your SSH public key (the content of your id_rsa.pub or id_ed25519.pub):"
    info "If you don't have one, generate it on your local machine with: ssh-keygen -t ed25519"
    info "Press Enter to skip SSH key setup (you can add it later)"
    echo ""
    while true; do
        read -r -p "SSH Public Key: " ssh_key || ssh_key=""
        if [ -z "$ssh_key" ] || is_valid_ssh_public_key "$ssh_key"; then
            break
        fi
        warn "That is not a valid SSH public key (one line starting with ssh-ed25519, ssh-rsa, ecdsa-sha2-... or sk-...). Try again or press Enter to skip."
    done

    if [ -z "$ssh_key" ]; then
        warn "SSH key setup skipped. You can add a key later to ~/.ssh/authorized_keys"
        if $CONFIGURE_SECURITY; then
            warn "SSH hardening skipped (no SSH key provided)"
            CONFIGURE_SECURITY=false
        fi
        return 0
    fi

    append_authorized_key_unique "$ssh_key" "$user_home/.ssh/authorized_keys"
    chown -R "$user:$user" "$user_home/.ssh"
    log "SSH public key added for $user"

    $CONFIGURE_SECURITY || return 0

    log "Hardening SSH configuration..."
    if apply_ssh_hardening "$user"; then
        log "SSH hardened: only $user can login with SSH keys"
        echo ""
        warn "IMPORTANT: Please test SSH login with the new key in another terminal before continuing!"
        warn "Command: ssh $user@$(hostname -I | awk '{print $1}')"
        echo ""
        read -r -p "Press Enter once you've verified SSH access works..." || true
    else
        warn "SSH hardening was NOT applied; password and root login are unchanged. Fix the SSH configuration and re-run the script"
    fi
}

# Network of an IPv4 address with prefix ("192.168.1.50/24" -> "192.168.1.0/24"). Prefix 1-32.
ipv4_network_cidr() {
    local cidr="${1:-}"
    local a b c d len ip mask net

    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]}))
    d=$((10#${BASH_REMATCH[4]}))
    len=$((10#${BASH_REMATCH[5]}))
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ] || return 1
    [ "$len" -ge 1 ] && [ "$len" -le 32 ] || return 1

    ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    net=$(( ip & mask ))
    printf '%d.%d.%d.%d/%d\n' \
        $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) $(( (net >> 8) & 255 )) $(( net & 255 )) "$len"
}

# Succeeds for an RFC 1918 network (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 ranges).
is_private_ipv4_network() {
    local net="${1:-}"
    local a b

    [[ "$net" =~ ^([0-9]+)\.([0-9]+)\. ]] || return 1
    a="${BASH_REMATCH[1]}"
    b="${BASH_REMATCH[2]}"
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    return 1
}

# Prints the private IPv4 network of the default-route interface (e.g. 192.168.1.0/24).
detect_lan_subnet() {
    local iface addr net

    iface="$(ip -o -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    [ -n "$iface" ] || return 1
    addr="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "inet") { print $(i + 1); exit }}')"
    [ -n "$addr" ] || return 1
    # A /31 or /32 is a point-to-point link, not a LAN.
    [ "${addr#*/}" -le 30 ] 2>/dev/null || return 1
    net="$(ipv4_network_cidr "$addr")" || return 1
    is_private_ipv4_network "$net" || return 1
    printf '%s\n' "$net"
}

is_interactive_session() {
    [ -t 0 ]
}

# Sets SAMBA_SUBNET: detected from the default route, else asked for. Fails without one.
# A typed network outside the private ranges needs a confirmation.
resolve_samba_subnet() {
    local detected input net answer

    SAMBA_SUBNET=""
    if detected="$(detect_lan_subnet)"; then
        SAMBA_SUBNET="$detected"
        return 0
    fi

    is_interactive_session || return 1
    warn "Could not determine the local network automatically"
    while true; do
        read -r -p "  Local network allowed to use Samba (CIDR, e.g. 192.168.1.0/24; Enter to skip): " input || return 1
        [ -n "$input" ] || return 1
        if ! net="$(ipv4_network_cidr "$input")"; then
            warn "Invalid network '$input'. Use IPv4 CIDR notation, e.g. 192.168.1.0/24"
            continue
        fi
        if ! is_private_ipv4_network "$net"; then
            warn "$net is not a private (RFC 1918) network: SMB would be open to everything in it"
            read -r -p "  Use it anyway? (y/N): " answer || answer=""
            [[ "$answer" =~ ^[Yy]$ ]] || continue
        fi
        SAMBA_SUBNET="$net"
        return 0
    done
}

# Samba (SMB) is opened only for the local network (IPv4), never for any source. The
# rule for any source that earlier versions of this script added is always removed.
configure_samba_firewall() {
    command -v "$UFW_BIN" &> /dev/null || return 0

    if resolve_samba_subnet; then
        "$UFW_BIN" allow from "$SAMBA_SUBNET" to any app Samba
        log "Firewall rule added: Samba only from $SAMBA_SUBNET"
    else
        warn "Samba firewall rule NOT added: the local network is unknown, so SMB is closed in UFW"
        warn "To open it for your LAN: ufw allow from <your-lan-subnet> to any app Samba   (e.g. 192.168.1.0/24)"
    fi

    if ! "$UFW_BIN" --force delete allow Samba > /dev/null; then
        warn "Could not remove the rule 'ufw allow Samba' (any source); check 'ufw status' and delete it if present"
    fi
}

# Owner and mode of the share root only: never recursive, the disk content is the owner's.
prepare_share_root() {
    local dir="$1"
    local user="$2"

    chown "$user:$user" "$dir"
    chmod 755 "$dir"
}

# Succeeds when smb.conf $1 defines share [$2].
samba_share_defined() {
    grep -q "^\[$2\]" "$1"
}

# Adds share [$2] (directory $3, user $4) to smb.conf $1 on the first run only. The
# share root gets its owner and mode then; the content of the disk is never touched,
# and a share that already exists is left as it is.
ensure_samba_share() {
    local conf="$1" share_name="$2" path="$3" user="$4"

    if samba_share_defined "$conf" "$share_name"; then
        warn "Share [$share_name] already exists in smb.conf; its definition and $path permissions are left unchanged"
        return 0
    fi

    log "Setting owner of $path to $user (the share root only)..."
    prepare_share_root "$path" "$user"
    cat >> "$conf" <<SMB_EOF

[$share_name]
   path = $path
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0644
   directory mask = 0755
   valid users = $user
SMB_EOF
}

# Comments out the [homes] section of smb.conf $1 (header and parameters, up to the
# next section header). Other sections keep identical lines.
disable_samba_homes_section() {
    local conf="$1"
    local tmp

    tmp="$(mktemp)"
    if ! awk '
        /^[[:space:]]*\[/ { in_homes = ($0 ~ /^[[:space:]]*\[homes\][[:space:]]*$/) }
        in_homes && $0 !~ /^[[:space:]]*([;#]|$)/ { print ";" $0; next }
        { print }
    ' "$conf" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    # cat keeps the owner and mode of the original file.
    cat "$tmp" > "$conf"
    rm -f "$tmp"
}

# Writes the Fail2Ban jail.local; a different existing file is copied to jail.local.bak[.N] first.
write_fail2ban_jail_local() {
    local backup="${FAIL2BAN_JAIL_LOCAL}.bak"
    local n=0
    local tmp

    tmp="$(mktemp)"
    cat > "$tmp" <<JAIL_EOF
[DEFAULT]
backend = systemd

[sshd]
enabled = true
port = 22
maxretry = 3
bantime = 3600
JAIL_EOF

    if [ -e "$FAIL2BAN_JAIL_LOCAL" ] && ! cmp -s "$tmp" "$FAIL2BAN_JAIL_LOCAL"; then
        while [ -e "$backup" ]; do
            n=$((n + 1))
            backup="${FAIL2BAN_JAIL_LOCAL}.bak.${n}"
        done
        cp -p "$FAIL2BAN_JAIL_LOCAL" "$backup"
        log "Existing $FAIL2BAN_JAIL_LOCAL saved to $backup"
    fi
    cat "$tmp" > "$FAIL2BAN_JAIL_LOCAL"
    rm -f "$tmp"
}

# shellcheck disable=SC2317
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Prompt Yes/No
prompt_yn() {
    local prompt="$1" default_yes="$2"
    TUI_PROMPT_PREFIX=" - " tui_prompt_yn "$prompt" "$default_yes"
}

################################################################################
# 0. Detect OS Version & Validation
################################################################################
section "${SYMBOL_GEAR} Pre-flight Checks"

# Detect OS
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME=$NAME
    OS_VERSION=$VERSION_ID
    OS_CODENAME=$VERSION_CODENAME
    log "Detected OS: $OS_NAME $OS_VERSION ($OS_CODENAME)"
else
    error "Cannot detect OS version. /etc/os-release not found."
    exit 1
fi

require_supported_debian_release
log "✓ Debian ${VERSION_ID} (${VERSION_CODENAME}) confirmed"

################################################################################
# Configuration Menu
################################################################################

# Default configuration flags
UPDATE_SYSTEM=true
INSTALL_BASE_UTILS=true
CONFIGURE_LOCALES=true
CREATE_USER=true
INSTALL_KERNEL=true
INSTALL_INTEL_GPU=true
OPTIMIZE_SSD=true
INSTALL_DOCKER=true
INSTALL_FISH=true
INSTALL_GO=true
INSTALL_NODE=true
CONFIGURE_SECURITY=true
DISABLE_SERVICES=true
INSTALL_SAMBA=false
PERFORMANCE_TUNING=true

show_selected_options() {
    subsection "Selected profile"
    ui_option_state "System update and base utilities" "$UPDATE_SYSTEM"
    ui_option_state "Locales and timezone" "$CONFIGURE_LOCALES"
    ui_option_state "User and SSH hardening" "$CREATE_USER"
    ui_option_state "Linux kernel (Backports on Debian 12)" "$INSTALL_KERNEL"
    ui_option_state "Intel GPU drivers" "$INSTALL_INTEL_GPU"
    ui_option_state "SSD optimization" "$OPTIMIZE_SSD"
    ui_option_state "Performance tuning" "$PERFORMANCE_TUNING"
    ui_option_state "Docker CE" "$INSTALL_DOCKER"
    ui_option_state "Fish + Starship (nerd-font-symbols)" "$INSTALL_FISH"
    ui_option_state "Go toolchain" "$INSTALL_GO"
    ui_option_state "Node.js LTS via fnm" "$INSTALL_NODE"
    ui_option_state "Samba file sharing" "$INSTALL_SAMBA"
}

show_menu() {
    echo ""
    section "Mini PC Optimization"
    ui_hint "Intel N5095/Jasper Lake profile for Debian 12/13."

    # System Basics
    subsection "System"
    if prompt_yn "Update system & Install base utils" true; then
        UPDATE_SYSTEM=true
        INSTALL_BASE_UTILS=true
    else
        UPDATE_SYSTEM=false
        INSTALL_BASE_UTILS=false
    fi
    prompt_yn "Configure Locales (en_US + ru_RU) & Timezone" true && CONFIGURE_LOCALES=true || CONFIGURE_LOCALES=false
    if prompt_yn "Create new sudo user & Harden SSH" true; then
        CREATE_USER=true
        CONFIGURE_SECURITY=true
    else
        CREATE_USER=false
        CONFIGURE_SECURITY=false
    fi

    # Hardware Specifics
    subsection "Hardware"
    prompt_yn "Install latest Linux kernel via Backports (optimized for N5095/JasperLake)" true && INSTALL_KERNEL=true || INSTALL_KERNEL=false
    prompt_yn "Install Intel GPU Drivers (QuickSync/Transcoding)" true && INSTALL_INTEL_GPU=true || INSTALL_INTEL_GPU=false
    prompt_yn "Optimize SSDs (TRIM, I/O scheduler)" true && OPTIMIZE_SSD=true || OPTIMIZE_SSD=false
    if prompt_yn "Apply Performance Tuning (Sysctl, Limits, Swap, Tmpfs)" true; then
        PERFORMANCE_TUNING=true
        DISABLE_SERVICES=true
    else
        PERFORMANCE_TUNING=false
        DISABLE_SERVICES=false
    fi

    # Software Stack
    subsection "Software"
    prompt_yn "Install Docker CE & Docker Compose" true && INSTALL_DOCKER=true || INSTALL_DOCKER=false
    prompt_yn "Install Fish + Starship Shell (nerd-font-symbols preset)" true && INSTALL_FISH=true || INSTALL_FISH=false
    prompt_yn "Install Go (Latest)" true && INSTALL_GO=true || INSTALL_GO=false
    prompt_yn "Install Node.js (LTS via fnm)" true && INSTALL_NODE=true || INSTALL_NODE=false

    
    subsection "File Sharing"
    SAMBA_SHARE_NAME="SSD_Storage"
    prompt_yn "Install Samba File Sharing" false && INSTALL_SAMBA=true || INSTALL_SAMBA=false
    if $INSTALL_SAMBA; then
        while true; do
            echo -ne "  ${YELLOW}Enter Samba Share Name (folder name) [SSD_Storage]: ${NC}"
            read -r input_name
            input_name=${input_name:-SSD_Storage}
            if [[ "$input_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                SAMBA_SHARE_NAME="$input_name"
                break
            else
                echo -e "  ${RED}Invalid name. Use only A-Z, a-z, 0-9, underscores, and hyphens.${NC}"
            fi
        done
        info "Samba Share Name set to: $SAMBA_SHARE_NAME"
    fi

    echo ""
    show_selected_options
    echo ""
    ui_success_title "Starting installation with selected options..."
    sleep 1
}

# Show menu
tui_init || true
show_menu

log "=== Starting Mini PC Optimization ==="

################################################################################
# 1. System Update & Base Utils
################################################################################
if $UPDATE_SYSTEM; then
    section "${SYMBOL_PACKAGE} System Update"
    # Enrich sources for non-free drivers (needed for Intel GPU)
    log "Enabling contrib non-free non-free-firmware repositories..."
    if ! common_enrich_apt_sources; then
        error "Failed while rewriting APT source files"
        exit 1
    fi

    common_apt_update "system update"
    common_apt_get upgrade -y
    
    if $INSTALL_BASE_UTILS; then
        log "Installing essential packages..."
        # Combined list from VPS + specific needs
        common_safe_install wget curl git htop iotop sysstat net-tools \
            iptables ufw fail2ban python3-systemd unattended-upgrades apt-listchanges \
            zip unzip gnupg ca-certificates lsb-release \
            lm-sensors linux-cpupower speedtest-cli irqbalance \
            fzf ripgrep fd-find bat bc needrestart ncdu tree vim nano tmux \
            make gcc g++ cmake xz-utils xdg-user-dirs || \
            warn "Some essential packages were not installed, continuing"
            
        # Aliases for bat and fd
        if [ -f /usr/bin/batcat ] && [ ! -f /usr/bin/bat ]; then
            ln -sf /usr/bin/batcat /usr/bin/bat 2>/dev/null || true
        fi
        if [ -f /usr/bin/fdfind ] && [ ! -f /usr/bin/fd ]; then
            ln -sf /usr/bin/fdfind /usr/bin/fd 2>/dev/null || true
        fi
        
        # Configure iptables-legacy for Docker compatibility
        # Switch ALL iptables utilities to legacy mode (critical for UFW)
        # Set master alternatives first
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || update-alternatives --install /usr/sbin/iptables iptables /usr/sbin/iptables-legacy 100
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || update-alternatives --install /usr/sbin/ip6tables ip6tables /usr/sbin/ip6tables-legacy 100
        # Set slave alternatives (iptables-restore and iptables-save are automatically managed)
        update-alternatives --set iptables-save /usr/sbin/iptables-legacy-save 2>/dev/null || true
        update-alternatives --set ip6tables-save /usr/sbin/ip6tables-legacy-save 2>/dev/null || true
    fi
fi

################################################################################
# 2. Locale & Timezone
################################################################################
if $CONFIGURE_LOCALES; then
    section "${SYMBOL_GEAR} Locales & Timezone"

    # Locale selection
    echo "Select default system locale (English and Russian UTF-8 are always generated):"
    echo "1) en_US.UTF-8 (English)"
    echo "2) ru_RU.UTF-8 (Russian)"
    echo "3) Both (en_US.UTF-8 as default)"
    
    if ! LOCALE_CHOICE=$(tui_radiolist "Default Locale" "Select default language (both UTF-8 locales will be generated):" 15 60 3 "1" "English (en_US.UTF-8)" on "2" "Russian (ru_RU.UTF-8)" off "3" "Both (English as default)" off); then
        read -r -p "Enter choice [1-3]: " LOCALE_CHOICE
    fi

    case $LOCALE_CHOICE in
        1)
            DEFAULT_LOCALE="en_US.UTF-8"
            log "Selected locale: English (en_US.UTF-8)"
            ;;
        2)
            DEFAULT_LOCALE="ru_RU.UTF-8"
            log "Selected locale: Russian (ru_RU.UTF-8)"
            ;;
        3)
            DEFAULT_LOCALE="en_US.UTF-8"
            log "Selected locales: English + Russian"
            ;;
        *)
            warn "Invalid choice. Using English (en_US.UTF-8) as default"
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
    esac

    # Support both SSH client locales regardless of the selected default language.
    common_safe_install locales || warn "locales package was not installed, locale generation may fail"
    common_generate_utf8_locales /etc/locale.gen
    # Debian 12 uses /etc/default/locale; Debian 13 uses /etc/locale.conf.
    update-locale --reset "LANG=$DEFAULT_LOCALE" "LANGUAGE=${DEFAULT_LOCALE%%.*}"

    # Write to profile for all users (will be applied on next login)
    cat > /etc/profile.d/locale.sh <<EOF
export LANG=$DEFAULT_LOCALE
export LANGUAGE=${DEFAULT_LOCALE%%.*}
EOF


    chmod +x /etc/profile.d/locale.sh

    log "Default locale set to: $DEFAULT_LOCALE"
    log "Locale will be fully applied after reboot or re-login"


    # Timezone
    echo ""
    read -r -p "Enter timezone (e.g., Europe/Moscow) [Press Enter to keep current]: " NEW_TIMEZONE
    if [ -n "$NEW_TIMEZONE" ]; then
        if [ -f "/usr/share/zoneinfo/$NEW_TIMEZONE" ]; then
            timedatectl set-timezone "$NEW_TIMEZONE" 2>/dev/null || {
                ln -sf "/usr/share/zoneinfo/$NEW_TIMEZONE" /etc/localtime
                echo "$NEW_TIMEZONE" > /etc/timezone
            }
            log "Timezone set to $NEW_TIMEZONE"
        else
            warn "Invalid timezone. Skipping."
        fi
    fi

    common_enable_time_sync || true

    info "Localization configured:"
    info "  Locale: $DEFAULT_LOCALE"
    info "  Timezone: ${NEW_TIMEZONE:-unchanged}"
    info "  Time sync: ${COMMON_TIME_SYNC_SERVICE:-Not configured}"
fi

################################################################################
# 3. User Creation
################################################################################
if $CREATE_USER; then
    section "${SYMBOL_GEAR} User Creation"
    
    # Username validation function
    validate_username() {
        common_validate_username "${1:-}"
    }
    
    echo ""
    info "We need to create a new sudo user for secure access."
    if $CONFIGURE_SECURITY; then
        info "Root login will be disabled after setup."
    fi
    echo ""
    
    # Username input with validation and retry
    while true; do
        read -r -p "Enter new username: " NEW_USER
        
        validate_username "$NEW_USER"
        validation_result=$?
        
        if [ $validation_result -eq 0 ]; then
            break
        else
            case $validation_result in
                1) warn "Username cannot be empty" ;;
                2) warn "Username cannot be only numbers (causes UID confusion)" ;;
                3) warn "Username cannot start with a number or dash" ;;
                4) warn "Username can only contain: lowercase letters, numbers, underscore, dash" ;;
                5) warn "Username is too long (max 32 characters)" ;;
            esac
            info "Please try again..."
            echo ""
        fi
    done
    
    # Check if user already exists
    if id "$NEW_USER" &>/dev/null; then
        warn "User $NEW_USER already exists. Skipping user creation..."

        # Ensure existing user has sudo group membership
        if ! id -nG "$NEW_USER" | grep -qw sudo; then
            /usr/sbin/usermod -aG sudo "$NEW_USER"
            log "Added existing user $NEW_USER to sudo group"
        fi
        
        # Offer to change password for existing user
        echo ""
        read -p "Do you want to change password for existing user $NEW_USER? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Loop until password is successfully set
            while true; do
                if passwd "$NEW_USER"; then
                    log "Password changed for $NEW_USER"
                    break
                else
                    warn "Failed to change password. Please try again."
                    read -p "Retry? (Y/n): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Nn]$ ]]; then
                        warn "Skipping password change."
                        break
                    fi
                fi
            done
        fi
    else
        # Create user with disabled password initially (will be set below)
        /usr/sbin/adduser --gecos "" --disabled-password "$NEW_USER" || {
            error "Failed to create user $NEW_USER"
            exit 1
        }
        
        # Add to sudo group
        /usr/sbin/usermod -aG sudo "$NEW_USER"
        log "User $NEW_USER created and added to sudo group"
        
        # Set password for new user
        log "Setting password for new user $NEW_USER..."
        # Set password for new user
        log "Setting password for new user $NEW_USER..."
        while true; do
            if passwd "$NEW_USER"; then
                 break
            else
                 warn "Failed to set password. Please try again."
                 read -p "Retry? (Y/n): " -n 1 -r
                 echo
                 if [[ $REPLY =~ ^[Nn]$ ]]; then
                     warn "Skipping password setup (user might be locked)."
                     break
                 fi
            fi
        done
    fi
    
    # Store user for later use (adding to docker group, video/render groups)
    # Configure passwordless sudo for the new user
    if common_safe_write_sudoers "/etc/sudoers.d/$NEW_USER" "$NEW_USER ALL=(ALL) NOPASSWD:ALL"; then
        log "Passwordless sudo configured for $NEW_USER"
    else
        warn "Failed to configure passwordless sudo for $NEW_USER (sudoers write or visudo check failed, is sudo installed?; the previous file, if any, is unchanged)"
    fi
    
    # Configure passwordless sudo for root
    if ! grep -q "^root.*NOPASSWD:ALL" /etc/sudoers.d/root 2>/dev/null; then
        if common_safe_write_sudoers "/etc/sudoers.d/root" "root ALL=(ALL) NOPASSWD:ALL"; then
            log "Passwordless sudo configured for root"
        else
            warn "Failed to configure passwordless sudo for root (sudoers write or visudo check failed, is sudo installed?; the previous file, if any, is unchanged)"
        fi
    fi
    
    # Setup SSH keys
    USER_HOME=$(common_user_home "$NEW_USER" || echo "/home/$NEW_USER")
    setup_ssh_access "$NEW_USER" "$USER_HOME"
else
    NEW_USER=$(logname 2>/dev/null || echo "$SUDO_USER")
    [ -z "$NEW_USER" ] && NEW_USER="root"
    log "Using existing user: $NEW_USER"
fi

################################################################################
# 4. Hardware Optimization (Kernel & CPU & GPU)
################################################################################
if $INSTALL_KERNEL; then
    section "${SYMBOL_GEAR} Kernel & Hardware"
    
    # N5095 Check
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2)
    log "Detected CPU: $CPU_MODEL"
    
    # Remove legacy XanMod sources and keys if present
    if [ -e /etc/apt/sources.list.d/xanmod-release.list ]; then
        rm -f /etc/apt/sources.list.d/xanmod-release.list
        common_apt_sources_changed
    fi
    rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || true

    distro_version="${VERSION_ID%%.*}"
    ARCH="$(dpkg --print-architecture)"
    KERNEL_PKG="linux-image-${ARCH}"
    HEADERS_PKG="linux-headers-${ARCH}"

    if [ "$distro_version" = "12" ]; then
        info "Configuring Debian bookworm-backports for latest LTS kernel..."
        common_render_debian_backports_source "bookworm" > /etc/apt/sources.list.d/debian-backports.sources
        chmod 644 /etc/apt/sources.list.d/debian-backports.sources
        common_apt_sources_changed

        log "Installing official Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG)..."
        if common_apt_update "Backports repository refresh" \
            && common_install_from_release bookworm-backports "$KERNEL_PKG" "$HEADERS_PKG"; then
            log "Official Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG) installed successfully"
            BACKPORTS_KERNEL_INSTALLED=true
        else
            warn "Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG) was not installed, the current kernel stays in use"
            BACKPORTS_KERNEL_INSTALLED=false
        fi
    else
        info "Debian $distro_version includes modern kernel by default ($KERNEL_VERSION)"
        if common_safe_install "$KERNEL_PKG" "$HEADERS_PKG"; then
            log "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) updated successfully"
        else
            warn "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) was not updated"
        fi
        BACKPORTS_KERNEL_INSTALLED=false
    fi
    
    # CPU Governor (schedutil is best for N5095)
    # linux-cpupower is available on Debian 12 and Debian 13
    common_safe_install linux-cpupower || warn "linux-cpupower was not installed, CPU governor tuning may be skipped"

    # Detect best available governor
    AVAILABLE_GOVERNORS=$(cpupower frequency-info -g 2>/dev/null | grep "available cpufreq governors:" | cut -d: -f2 || true)
    
    if [[ "$AVAILABLE_GOVERNORS" == *"schedutil"* ]]; then
        GOVERNOR="schedutil"
    elif [[ "$AVAILABLE_GOVERNORS" == *"powersave"* ]]; then
        GOVERNOR="powersave"
        log "Note: Using 'powersave' governor (standard for intel_pstate driver)"
    elif [[ "$AVAILABLE_GOVERNORS" == *"ondemand"* ]]; then
        GOVERNOR="ondemand"
    else
        GOVERNOR="performance"
    fi
    
    log "Selected CPU Governor: $GOVERNOR"

    # Apply immediately
    cpupower frequency-set -g $GOVERNOR 2>/dev/null || true

    # Create persistent service for cpupower
    cat > /etc/systemd/system/cpupower-config.service <<EOF
[Unit]
Description=Apply CPU performance settings
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g $GOVERNOR

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable cpupower-config.service
    systemctl start cpupower-config.service
fi

if $INSTALL_INTEL_GPU; then
    log "Installing Intel GPU Drivers..."
    mapfile -t intel_gpu_packages < <(resolve_intel_media_packages)
    common_safe_install "${intel_gpu_packages[@]}" || warn "Intel GPU drivers were not fully installed"
    
    /usr/sbin/groupadd -f render
    /usr/sbin/groupadd -f video
    if [ -n "$NEW_USER" ] && [ "$NEW_USER" != "root" ]; then
        /usr/sbin/usermod -aG video,render "$NEW_USER"
        log "Added $NEW_USER to video/render groups."
    fi
fi

################################################################################
# 5. SSD & Storage
################################################################################
if $OPTIMIZE_SSD; then
    section "${SYMBOL_GEAR} Storage Optimization"
    
    systemctl enable fstrim.timer
    systemctl start fstrim.timer
    
    log "Setting I/O schedulers (optimized for media server)..."
    cat > /etc/udev/rules.d/60-ioschedulers.conf <<'EOF'
# I/O Scheduler optimization for Media Server

# NVMe drives - use 'none' scheduler (best for NVMe)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="512"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rq_affinity}="2"

# SSD drives - use 'mq-deadline' scheduler (best for SATA SSD with media files)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="512"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="512"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"

ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="1024"
EOF
    udevadm control --reload
    udevadm trigger
fi

################################################################################
# 6. Fish Shell and Starship Installation
################################################################################
if $INSTALL_FISH; then
        section "${SYMBOL_ROCKET} Fish & Starship"
        common_safe_install fish curl git || warn "Fish shell prerequisites were not fully installed"

        # The Debian package (Debian 13) or the pinned release checked by its SHA-256
        common_install_starship || warn "Starship could not be installed"

        setup_fish_for_user() {
            local username=$1
            local user_home
            user_home=$(common_user_home "$username" || echo "/home/$username")

            log "Setting up Fish + Starship for user: $username"
            if common_setup_fish "$username" "$user_home" mini; then
                log "Fish + Starship (nerd-font-symbols) configured for $username"
            else
                warn "Fish configuration failed for $username"
            fi
        }

        # Ensure fish is available before setup
        if ! command -v fish &> /dev/null; then
            error "Fish installation failed - fish binary not found!"
            exit 1
        fi

        setup_fish_for_user root
        [ -n "$NEW_USER" ] && [ "$NEW_USER" != "root" ] && setup_fish_for_user "$NEW_USER"
    fi

################################################################################
# 6.5. Bash Modernization (Minimal Configuration)
################################################################################
section "${SYMBOL_GEAR} Bash Modernization"

progress "Configuring modern Bash setup..."

# Ensure bash-completion is installed
common_safe_install bash-completion || warn "bash-completion was not installed"

setup_bash_for_user() {
    local username=$1
    local user_home
    user_home=$(common_user_home "$username" || echo "/home/$username")

    log "Setting up Bash configuration for $username"
    if common_setup_bashrc "$username" "$user_home" mini; then
    log "Bash configuration written for $username"
else
    warn "Bash configuration failed for $username"
fi
}

# Setup Bash for root
setup_bash_for_user root

# Setup Bash for new user if created
if [ -n "$NEW_USER" ]; then
    setup_bash_for_user "$NEW_USER"
fi

log "Bash modernization completed"
log "Features: Starship prompt, history (50k), aliases, fnm auto-switching"

################################################################################
# 7. Go & Node.js
################################################################################
if $INSTALL_GO; then
    section "${SYMBOL_PACKAGE} Go Installation"
    
    log "Installing Go programming language..."
    
    # The pinned Go release, checked against its SHA-256 and swapped in only after unpacking
    if ! common_install_go; then
        error "Go installation failed"
        exit 1
    fi
    GO_VERSION="$(head -n 1 /usr/local/go/VERSION)"
    GO_VERSION="${GO_VERSION#go}"
    
    # Create profile.d entry
    cat > /etc/profile.d/golang.sh <<'GOEOF'
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
GOEOF
    chmod +x /etc/profile.d/golang.sh
    
    # Add to .bashrc for root
    if [ -f /root/.bashrc ] && ! grep -q "GOROOT" /root/.bashrc; then
        cat >> /root/.bashrc <<'GORC'

# Go configuration
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
GORC
    fi
    
    # Add to .bashrc for new user
    USER_HOME=$(common_user_home "$NEW_USER" || echo "/home/$NEW_USER")
    if [ -f "$USER_HOME/.bashrc" ] && ! grep -q "GOROOT" "$USER_HOME/.bashrc"; then
         cat >> "$USER_HOME/.bashrc" <<'GORC'

# Go configuration
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
GORC
        chown "$NEW_USER:$NEW_USER" "$USER_HOME/.bashrc"
    fi
    
    log "Go ${GO_VERSION} installed successfully"
fi

if $INSTALL_NODE; then
    section "${SYMBOL_PACKAGE} Node.js (fnm + LTS)"
    # Clean-OS target: this flow provisions fnm directly and does not migrate old Node-manager setups.

    ensure_fnm_install_dependencies() {
        local required_packages=(curl unzip)
        local missing_packages=()
        local unresolved_packages=()
        local pkg

        for pkg in "${required_packages[@]}"; do
            command -v "$pkg" >/dev/null 2>&1 || missing_packages+=("$pkg")
        done

        if [ ${#missing_packages[@]} -eq 0 ]; then
            return 0
        fi

        warn "Missing fnm prerequisites: ${missing_packages[*]}. Attempting to install them..."
        common_safe_install "${missing_packages[@]}" || true

        for pkg in "${missing_packages[@]}"; do
            command -v "$pkg" >/dev/null 2>&1 || unresolved_packages+=("$pkg")
        done

        if [ ${#unresolved_packages[@]} -eq 0 ]; then
            log "fnm prerequisites installed successfully"
            return 0
        fi

        warn "Skipping fnm/Node.js installation because required packages are still missing: ${unresolved_packages[*]}"
        return 1
    }
    
    install_fnm_for_user() {
        local username=$1
        local user_home
        user_home=$(common_user_home "$username" || echo "/home/$username")
        log "Installing fnm for user: $username"
        
        local fnm_dir fnm_install_script
        # The binary comes from the pinned fnm release; it and the setup script sit in a fresh
        # directory in /tmp (not root's TMPDIR, which the user may not reach) that only root can
        # write and the user can read.
        if ! common_temp_dir fnm_dir /tmp || ! chmod 755 "$fnm_dir" || ! common_fetch_pinned_binary fnm "$fnm_dir"; then
            [ -z "${fnm_dir:-}" ] || rm -rf "$fnm_dir"
            warn "Could not fetch the pinned fnm release; skipping fnm for $username"
            return 1
        fi
        fnm_install_script="$fnm_dir/fnm-setup.sh"
        
        cat > "$fnm_install_script" <<'FNMINSTALL'
#!/bin/bash
set -e
export HOME="$1"
export USER="$2"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_RUNTIME_DIR="$XDG_STATE_HOME/fnm-runtime"

# The fnm binary that the calling script checked against its pinned SHA-256
install -D -m 755 "$3" "$XDG_DATA_HOME/fnm/fnm"

export PATH="$XDG_DATA_HOME/fnm:$PATH"
mkdir -p "$XDG_RUNTIME_DIR"

if ! command -v fnm >/dev/null 2>&1; then
    echo "fnm binary not found in PATH after install"
    exit 1
fi

eval "$(fnm env --shell bash)"
fnm install --lts --use
CURRENT_NODE="$(fnm current)"
fnm default "$CURRENT_NODE"

if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
fi

node --version
npm --version
FNMINSTALL

        chmod +x "$fnm_install_script"

        if [ "$username" = "root" ]; then
            bash "$fnm_install_script" "$user_home" "$username" "$fnm_dir/fnm"
        else
            su - "$username" -c "bash '$fnm_install_script' '$user_home' '$username' '$fnm_dir/fnm'"
        fi
        rm -rf "$fnm_dir"
        
        if [ -f "$user_home/.bashrc" ] && ! grep -q "FNM_PATH" "$user_home/.bashrc"; then
             cat >> "$user_home/.bashrc" <<'FNMRC'

# fnm (Fast Node Manager) - Native binary, no lazy-loading needed
export FNM_PATH="$HOME/.local/share/fnm"
export PATH="$FNM_PATH:$PATH"
export XDG_RUNTIME_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fnm-runtime"
mkdir -p "$XDG_RUNTIME_DIR"
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi
FNMRC
             chown "$username:$username" "$user_home/.bashrc"
        fi

        local fnm_bin="$user_home/.local/share/fnm/fnm"
        if [ -x "$fnm_bin" ]; then
            log "fnm installed successfully for $username"
        else
            warn "fnm installation may have failed for $username"
        fi

        chown -R "$username:$username" "$user_home/.local/share/fnm" 2>/dev/null || true
        chown -R "$username:$username" "$user_home/.local/state/fnm-runtime" 2>/dev/null || true
        chown -R "$username:$username" "$user_home/.npm" 2>/dev/null || true
        chown "$username:$username" "$user_home/.bashrc" 2>/dev/null || true

        rm -f "$fnm_install_script"
        log "fnm setup completed for $username"
    }
    
    if ensure_fnm_install_dependencies; then
        install_fnm_for_user root || warn "fnm installation for root failed"
        if [ -n "${NEW_USER:-}" ] && [ "$NEW_USER" != "root" ]; then
            install_fnm_for_user "$NEW_USER" || warn "fnm installation for $NEW_USER failed"
        fi
    fi
fi

################################################################################
# 8. Docker
################################################################################
if $INSTALL_DOCKER; then
    section "Step 8: Docker"
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        common_apt_get remove -y "$pkg" 2>/dev/null || true
    done
    
    install -m 0755 -d /etc/apt/keyrings
    # Docker's GPG key, accepted only with its pinned fingerprint
    if ! common_install_apt_key docker /etc/apt/keyrings/docker.gpg; then
        error "The Docker APT key could not be installed"
        exit 1
    fi
    DOCKER_ARCH="$(dpkg --print-architecture)"
    
    common_render_docker_debian_source "$ID" "$VERSION_CODENAME" "$DOCKER_ARCH" "/etc/apt/keyrings/docker.gpg" > /etc/apt/sources.list.d/docker.sources
    common_apt_sources_changed

    common_apt_update "Docker repository refresh"
    common_safe_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || \
        warn "Some Docker packages were not installed"

    # Check if Docker was actually installed
    if ! command -v docker &>/dev/null; then
        error "Docker installation failed - docker binary not found!"
        exit 1
    fi

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  }
}
EOF
    # Override socket for proper startup
    mkdir -p /etc/systemd/system/docker.service.d
    echo -e "[Service]\nExecStart=\nExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock" > /etc/systemd/system/docker.service.d/override.conf
    
    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker
    
    [ -n "$NEW_USER" ] && /usr/sbin/usermod -aG docker "$NEW_USER"
fi

################################################################################
# 9. Performance Tuning (Sysctl, Swap, Limits)
################################################################################
if $PERFORMANCE_TUNING; then
    section "Step 9: Performance Tuning"
    
    # RAM Detection
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    # Use awk for accurate calculation with rounding
    TOTAL_RAM_GB=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_KB/1024/1024}")

    # Swap calculation (optimized for 16GB RAM)
    # For systems with 12GB+, use 4GB swap (no need for large swap with plenty RAM)
    if (( $(echo "$TOTAL_RAM_GB >= 12" | bc -l) )); then
        SWAP_SIZE=4
        log "Detected ${TOTAL_RAM_GB}GB RAM - using optimized 4GB swap"
    else
        # For smaller systems, use 50% rule
        SWAP_SIZE=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", ($TOTAL_RAM_GB / 2) + 0.5}")
        if [ "$SWAP_SIZE" -lt 1 ]; then
            SWAP_SIZE=2
        fi
    fi
    
    # Validated swap check and recreate logic (ported from optimize_vps.sh)
    if /usr/sbin/swapon --show | grep -q "/swapfile"; then
        log "Removing existing swap (to ensure correct size)..."
        /usr/sbin/swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
    fi

    # Check if remaining swap (from partitions or other sources) is sufficient
    # We use awk to sum up total existing swap bytes
    EXISTING_SWAP_BYTES=$(/usr/sbin/swapon --show --noheadings --bytes 2>/dev/null | awk '{sum+=$3} END {print sum}')
    # Default to 0 if command fails or empty
    EXISTING_SWAP_BYTES=${EXISTING_SWAP_BYTES:-0}
    
    # Calculate desired size in bytes (SWAP_SIZE is in GB)
    REQUIRED_BYTES=$((SWAP_SIZE * 1024 * 1024 * 1024))
    
    if [ "$EXISTING_SWAP_BYTES" -ge "$REQUIRED_BYTES" ]; then
        EXISTING_GB=$(LC_NUMERIC=C awk "BEGIN {printf \"%.1f\", $EXISTING_SWAP_BYTES/1024/1024/1024}")
        log "Sufficient existing swap detected (${EXISTING_GB}GB >= ${SWAP_SIZE}GB). Skipping /swapfile creation."
    else
        log "Creating ${SWAP_SIZE}GB Swap..."
        if ! /usr/bin/fallocate -l "${SWAP_SIZE}G" /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1G count="$SWAP_SIZE" status=progress
        fi
        
        chmod 600 /swapfile
        /usr/sbin/mkswap /swapfile
        /usr/sbin/swapon /swapfile
        
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    fi

    # Ensure /etc/sysctl.conf exists
    if [ ! -f /etc/sysctl.conf ]; then
        log "Creating /etc/sysctl.conf (was missing)..."
        cat > /etc/sysctl.conf <<'SYSCTLCONF'
#
# /etc/sysctl.conf - Configuration file for setting system variables
# See /etc/sysctl.d/ for additional system variables.
#

# Additional settings are in /etc/sysctl.d/
SYSCTLCONF
    fi

    # Sysctl (Media Server optimized for 16GB RAM + Intel N5095)
    cat > /etc/sysctl.d/99-minipc.conf <<EOF
# Mini PC Optimization - Media Server (16GB RAM, Intel N5095)
# Optimized for Plex/Jellyfin with QuickSync transcoding

# ============================================================================
# Network Performance - Enhanced for streaming
# ============================================================================

# TCP/UDP Buffer Sizes (optimized for 16GB RAM, media streaming)
net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

# Network Queues (for multiple concurrent streams)
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 16384

# TCP Performance
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535

# TCP Fast Open (reduces streaming connection latency)
net.ipv4.tcp_fastopen = 3

# TCP Window Scaling & SACK (better for high-latency clients)
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# MTU Probing
net.ipv4.tcp_mtu_probing = 1

# TCP Orphan & TIME_WAIT limits
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_max_tw_buckets = 131072

# ============================================================================
# Virtual Memory - Optimized for 16GB RAM
# ============================================================================
vm.swappiness = 5
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes = 131072
vm.overcommit_memory = 1
vm.zone_reclaim_mode = 0

# ============================================================================
# File System Performance (for large media files)
# ============================================================================
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024

# ============================================================================
# Connection Tracking (for multiple streaming sessions)
# ============================================================================
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600



# ============================================================================
# Security
# ============================================================================
# Reverse Path Filtering (Loose mode 2 for multi-homed and container routing, RFC 3704)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

EOF

    
    # Fix IRQ Storm on JasperLake/N5095 (High CPU usage on one core)
    log "Applying blacklist for problematic drivers (IRQ Storm Fix)..."
    cat > /etc/modprobe.d/blacklist-minipc.conf <<EOF
# Fix for high single-core CPU usage (IRQ Storm) on Intel N5095/JasperLake
# Disables HDMI Audio and Low-Power DMA which cause excessive interrupts
blacklist snd_hda_intel
blacklist snd_hda_codec_hdmi
blacklist idma64
blacklist i2c_designware_core
blacklist i2c_designware_platform
EOF
    log "Driver blacklist applied. Will take effect after reboot."

    # Apply sysctl settings
    # Apply sysctl settings with error tolerance for missing parameters
    /usr/sbin/sysctl -e -p /etc/sysctl.d/99-minipc.conf 2>&1 | grep -v "cannot stat" | grep -v "No such file or directory" | grep -v "unknown key" || true
    log "Kernel parameters applied (some may be skipped if not supported by hardware)"

    # Limits (optimized for media server)
    cat > /etc/security/limits.d/99-minipc.conf <<EOF
# Mini PC System Limits - Media Server (16GB RAM)

# Open file limits (for media libraries and concurrent streams)
* soft nofile 262144
* hard nofile 262144
root soft nofile 262144
root hard nofile 262144

# Process limits
* soft nproc 32768
* hard nproc 32768

# Memory lock (for QuickSync transcoding)
* soft memlock unlimited
* hard memlock unlimited

EOF

    # Journald limit
    mkdir -p /etc/systemd/journald.conf.d/
    echo -e "[Journal]\nSystemMaxUse=500M" > /etc/systemd/journald.conf.d/00-size.conf
    systemctl restart systemd-journald
    
    # Tmpfs optimization
    if ! grep -q "tmpfs /tmp" /etc/fstab; then
        log "Optimizing tmpfs..."
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=1G 0 0" >> /etc/fstab
        echo "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=512M 0 0" >> /etc/fstab
    fi
fi

################################################################################
# 10. Disable Unnecessary Services
################################################################################
if $DISABLE_SERVICES; then
    section "Step 10: Disable Unused Services"
    SERVICES_TO_DISABLE=("bluetooth.service" "cups.service" "avahi-daemon.service")
    for service in "${SERVICES_TO_DISABLE[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            systemctl disable "$service" &>/dev/null || true
            systemctl stop "$service" &>/dev/null || true
            log "Disabled $service"
        fi
    done
fi

################################################################################
# 11. Security (UFW, Auto-Updates)
################################################################################
if $CONFIGURE_SECURITY; then
    section "Step 11: Security"
    
    /usr/sbin/ufw default deny incoming
    /usr/sbin/ufw default allow outgoing
    /usr/sbin/ufw allow 22/tcp
    /usr/sbin/ufw allow 80/tcp
    /usr/sbin/ufw allow 443/tcp
    /usr/sbin/ufw --force enable
    
    # Fail2Ban
    write_fail2ban_jail_local
    systemctl restart fail2ban
    
    # Auto Updates
    common_render_apt_periodic_auto_upgrades_conf > /etc/apt/apt.conf.d/20auto-upgrades
fi

################################################################################
# 12. Services (Samba)
################################################################################
if $INSTALL_SAMBA; then
    section "Step 12: Samba"
    
    # Check if the share directory exists
    if [ ! -d "$SAMBA_SHARE_PATH" ]; then
        warn "Directory $SAMBA_SHARE_PATH does not exist! Skipping Samba configuration."
        warn "Please mount your drive to $SAMBA_SHARE_PATH and configure Samba manually later."
    else
        common_safe_install samba || {
            error "Samba installation failed"
            exit 1
        }
        
        # Backup config
        [ ! -f "$SAMBA_CONF.bak" ] && cp "$SAMBA_CONF" "$SAMBA_CONF.bak"
        
        # Configure global settings (Enable SMB2+ for modern clients)
        if ! grep -q "server min protocol" "$SAMBA_CONF"; then
            sed -i '/\[global\]/a \   server min protocol = SMB2' "$SAMBA_CONF"
        fi
        
        # Disable the default [homes] share (only that section, other sections keep their lines)
        disable_samba_homes_section "$SAMBA_CONF"
        
        ensure_samba_share "$SAMBA_CONF" "$SAMBA_SHARE_NAME" "$SAMBA_SHARE_PATH" "$NEW_USER"
        
        log "Samba configured. Please set SMB password for user: $NEW_USER"
        log "Note: This password can be different from system password."
        
        # Retry loop for password
        while ! smbpasswd -a "$NEW_USER"; do
            warn "Password setting failed (mismatch?). Please try again."
            echo ""
        done
        
        systemctl restart smbd
        log "Samba service restarted."
        
        # Firewall rule for Samba (now that package is installed and profile exists)
        configure_samba_firewall
    fi
fi

################################################################################
# 13. Monitoring & Maintenance Scripts
################################################################################
section "Step 13: Utility Scripts"

# 13.1 Monitor Script
cat > /usr/local/bin/minipc-monitor.sh <<'EOF'
#!/bin/bash
echo "=== Mini PC Monitor (N5095) ==="
echo ""
echo "--- System ---"
echo "CPU Temp: $(sensors | grep 'Package id 0:' | awk '{print $4}')"
echo "Kernel:   $(uname -r)"
echo "Uptime:   $(uptime -p)"
echo "Load:     $(uptime | awk -F'load average:' '{print $2}')"
echo ""
echo "--- Memory ---"
free -h | grep Mem | awk '{print "Total: "$2 " | Used: "$3 " | Free: "$4}'
echo ""
echo "--- Storage ---"
df -h / /mnt/ssd 2>/dev/null | grep -v Filesystem
echo ""
echo "--- Docker ---"
if command -v docker >/dev/null; then
    docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
else
    echo "Docker not installed"
fi
echo ""
echo "--- GPU ---"
echo "Run 'sudo intel_gpu_top' for realtime stats."
EOF
chmod +x /usr/local/bin/minipc-monitor.sh

# 13.2 Cleanup Script
cat > /usr/local/bin/minipc-cleanup.sh <<'EOF'
#!/bin/bash
echo "Starting Mini PC cleanup..."
# Clean package cache
apt-get clean
apt-get autoclean
apt-get -o DPkg::Lock::Timeout=300 autoremove -y
# Clean journals > 7 days
journalctl --vacuum-time=7d
# Clean docker
if command -v docker >/dev/null; then
    docker system prune -f
fi
# Clean temp
find /tmp -type f -atime +7 -delete
echo "Cleanup completed!"
EOF
chmod +x /usr/local/bin/minipc-cleanup.sh

# Weekly cleanup cron
echo '#!/bin/bash' > /etc/cron.weekly/minipc-cleanup
echo '/usr/local/bin/minipc-cleanup.sh >> /var/log/minipc-cleanup.log 2>&1' >> /etc/cron.weekly/minipc-cleanup
chmod +x /etc/cron.weekly/minipc-cleanup

# 13.3 Info Script
cat > /usr/local/bin/minipc-info.sh <<'EOF'
#!/bin/bash
echo "=== System Information ==="
hostnamectl
echo ""
echo "=== CPU Info ==="
lscpu | grep -E 'Model name|Architecture|Thread|Core'
echo ""
echo "=== Network ==="
ip -br a
echo ""
echo "=== Public IP ==="
curl -s --max-time 5 ifconfig.me || echo "Unavailable"
echo ""
EOF
chmod +x /usr/local/bin/minipc-info.sh

# 13.4 Network Test Script
cat > /usr/local/bin/network-test.sh <<'EOF'
#!/bin/bash
echo "=== Network Performance Test ==="
if ! command -v speedtest-cli &> /dev/null; then
    apt-get install -y -o DPkg::Lock::Timeout=300 speedtest-cli
fi
speedtest-cli
echo ""
echo "=== Network Stats ==="
netstat -s | head -20
EOF
chmod +x /usr/local/bin/network-test.sh

section "Mini PC Optimization Complete"
ui_success_title "Mini PC optimization completed"
warn "Please REBOOT to apply kernel, group changes, and sysctl settings."
if [ "${BACKPORTS_KERNEL_INSTALLED:-false}" = true ]; then
    info "Kernel: Official Debian Backports (${KERNEL_PKG:-linux-image-amd64})"
fi
subsection "New utilities"
info "minipc-monitor.sh"
info "minipc-cleanup.sh"
info "minipc-info.sh"
info "network-test.sh"

echo ""
if prompt_yn "Do you want to reboot now?" true; then
    log "Rebooting..."
    /usr/sbin/reboot
else
    warn "Please remember to reboot manually!"
fi

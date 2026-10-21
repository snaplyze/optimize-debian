#!/bin/bash

# Force C locale for script execution to avoid locale-related issues
export LC_ALL=C
export LANG=C

################################################################################
# VPS Optimization Script for Debian 12/13 (Bookworm/Trixie)
# Purpose: Complete VPS optimization with Debian Backports kernel, Fish + Starship, 10G networking
# Features: Auto RAM detection, Backports kernel, 10G sysctl, Fish + Starship, Docker, SSH hardening
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Symbols for modern output
SYMBOL_GEAR="⚙"
SYMBOL_PACKAGE="📦"
SYMBOL_ROCKET="🚀"
SYMBOL_WARN="⚠"
SYMBOL_INFO="ℹ"

# Logging
LOG_FILE="/var/log/vps_optimization.log"
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

if ! declare -F common_sshd_effective_mismatches >/dev/null; then
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

ui_success_title() {
    local text="$1"

    if ! ui_style --foreground 10 --bold "${text}"; then
        echo -e "${GREEN}${BOLD}${text}${NC}"
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

prevent_duplicate_cloud_init_networking() {
    local cloud_network_file="/etc/network/interfaces.d/50-cloud-init"
    local disable_file="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
    local backup_suffix
    local managed_ifaces=""

    [ -f "$cloud_network_file" ] || return 0

    if ! dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "install ok installed"; then
        return 0
    fi

    managed_ifaces=$(awk '$1 == "iface" && $2 != "lo" { print $2 }' /etc/network/interfaces 2>/dev/null | sort -u | tr '\n' ' ')
    [ -n "$managed_ifaces" ] || return 0

    warn "Detected duplicate network ownership: cloud-init and ifupdown both manage ${managed_ifaces}"

    cat > "$disable_file" <<'EOF'
network: {config: disabled}
EOF

    backup_suffix=".disabled-by-optimize.$(date +%F-%H%M%S)"
    mv "$cloud_network_file" "${cloud_network_file}${backup_suffix}"

    log "Disabled cloud-init network rendering and moved ${cloud_network_file} to avoid duplicate DHCP clients on reboot"
}

# System limits: one drop-in holds every limit the script sets, so a repeated
# run rewrites the same file and the summary reports the same value.
VPS_LIMITS_FILE="/etc/security/limits.d/99-vps-limits.conf"
VPS_NOFILE_LIMIT=65535
VPS_NPROC_LIMIT=65535
VPS_MEMLOCK_LIMIT="unlimited"

write_system_limits() {
    cat > "$VPS_LIMITS_FILE" <<EOF
# VPS Limits Optimization (VPN server, 1-4GB RAM)
* soft nofile $VPS_NOFILE_LIMIT
* hard nofile $VPS_NOFILE_LIMIT
* soft nproc $VPS_NPROC_LIMIT
* hard nproc $VPS_NPROC_LIMIT
* soft memlock $VPS_MEMLOCK_LIMIT
* hard memlock $VPS_MEMLOCK_LIMIT
root soft nofile $VPS_NOFILE_LIMIT
root hard nofile $VPS_NOFILE_LIMIT
root soft nproc $VPS_NPROC_LIMIT
root hard nproc $VPS_NPROC_LIMIT
EOF
}

# Write stdin to a config file; if the file exists with different content,
# keep a copy first (<file>.backup.<date>, numbered if that name is taken).
# Identical content leaves the file and the backups untouched.
write_config_with_backup() {
    local target="$1"
    local new_file backup n=0

    new_file="$(mktemp)" || return 1
    cat > "$new_file"

    if [ -e "$target" ] && ! cmp -s "$new_file" "$target"; then
        backup="$target.backup.$(date +%F)"
        while [ -e "$backup" ]; do
            n=$((n + 1))
            backup="$target.backup.$(date +%F).$n"
        done
        cp -p "$target" "$backup" || { rm -f "$new_file"; return 1; }
        log "Backed up $target to $backup"
    fi

    if ! cat "$new_file" > "$target"; then
        rm -f "$new_file"
        return 1
    fi
    rm -f "$new_file"
}

# SSH hardening drop-in. Its name sorts before the other drop-ins, so its values win, and sshd -T
# must show them. A config that fails `sshd -t` or that check is removed and sshd is not
# restarted; a restart failure is reported and fails the step.
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/00-optimize-hardening.conf"
# Earlier versions wrote the drop-in here, where a drop-in sorting first could override it.
SSH_LEGACY_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"

# Puts back the drop-in saved in $1 (ours) or removes ours when there was none, then the earlier
# version's drop-in saved in $2. A temporary copy is removed once it is back; one that cannot be
# put back stays, and its path is printed.
restore_ssh_hardening_dropin() {
    local previous_dropin="${1:-}"
    local legacy_dropin="${2:-}"
    local rc=0

    if [ -n "$previous_dropin" ]; then
        if cat "$previous_dropin" > "$SSH_HARDENING_FILE"; then
            rm -f "$previous_dropin"
        else
            error "Could not restore $SSH_HARDENING_FILE; its previous content is in $previous_dropin"
            rc=1
        fi
    else
        rm -f "$SSH_HARDENING_FILE"
    fi
    if [ -n "$legacy_dropin" ]; then
        if cp -p "$legacy_dropin" "$SSH_LEGACY_HARDENING_FILE"; then
            rm -f "$legacy_dropin"
        else
            error "Could not restore $SSH_LEGACY_HARDENING_FILE; its previous content is in $legacy_dropin"
            rc=1
        fi
    fi
    return "$rc"
}

configure_ssh_hardening() {
    local allowed_user="$1"
    local previous_dropin=""
    local legacy_dropin=""
    local mismatches line

    cp "$SSHD_CONFIG_FILE" "$SSHD_CONFIG_FILE.backup.$(date +%F)" 2>/dev/null || true

    # Keep the drop-in of an earlier run so a rejected config does not take it away.
    if [ -e "$SSH_HARDENING_FILE" ]; then
        previous_dropin="$(mktemp)" || return 1
        cp -p "$SSH_HARDENING_FILE" "$previous_dropin" || { rm -f "$previous_dropin"; return 1; }
    fi
    # The earlier version's drop-in goes once the new one is in place; an operator's file stays.
    if common_sshd_legacy_dropin_is_ours "$SSH_LEGACY_HARDENING_FILE"; then
        if ! legacy_dropin="$(mktemp)" || ! cp -p "$SSH_LEGACY_HARDENING_FILE" "$legacy_dropin"; then
            rm -f "$previous_dropin" "$legacy_dropin"
            return 1
        fi
    fi

    if ! cat > "$SSH_HARDENING_FILE" <<EOF
# SSH Hardening - VPS Optimization
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3

# Only allow specific user
AllowUsers $allowed_user
EOF
    then
        error "Could not write $SSH_HARDENING_FILE; the SSH configuration is unchanged"
        rm -f "$legacy_dropin"
        restore_ssh_hardening_dropin "$previous_dropin"
        return 1
    fi
    [ -z "$legacy_dropin" ] || rm -f "$SSH_LEGACY_HARDENING_FILE"

    if ! sshd -t; then
        error "SSH configuration test failed! Reverting changes..."
        restore_ssh_hardening_dropin "$previous_dropin" "$legacy_dropin"
        return 1
    fi
    if ! mismatches="$(common_sshd_effective_mismatches "permitrootlogin no" "passwordauthentication no" \
        "pubkeyauthentication yes" "permitemptypasswords no" "kbdinteractiveauthentication no" \
        "allowusers $allowed_user")"; then
        error "sshd does not take the hardening values (sshd -T); reverting changes, SSH is not restarted"
        while IFS= read -r line; do
            error "  $line"
        done <<<"${mismatches:-sshd -T failed}"
        error "A drop-in in $(dirname "$SSH_HARDENING_FILE") that sorts first, or a line above the Include in $SSHD_CONFIG_FILE, sets them"
        restore_ssh_hardening_dropin "$previous_dropin" "$legacy_dropin"
        return 1
    fi
    rm -f "$previous_dropin"
    if [ -n "$legacy_dropin" ]; then
        rm -f "$legacy_dropin"
        log "Removed the drop-in of an earlier version: $SSH_LEGACY_HARDENING_FILE"
    fi

    log "SSH configuration is valid"
    if ! systemctl restart ssh.service >/dev/null 2>&1 && ! systemctl restart sshd.service; then
        error "Failed to restart the SSH service; the hardening config is in place but not active"
        return 1
    fi
    log "SSH service restarted with new configuration"
}

print_usage() {
    cat <<'USAGE'
Usage: sudo bash optimize_vps.sh
       bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_vps.sh)

VPS optimization for Debian 12 and 13: Debian Backports kernel on Debian 12, sysctl for 10G VPN
traffic, Fish + Starship, Go, Node.js (fnm), Docker, SSH hardening, Fail2Ban and UFW.
It asks for the user, the SSH key and the options interactively.
Run it as root on the target machine: it changes the system (packages, kernel, users, sudoers,
SSH, firewall, sysctl). Guide: https://github.com/snaplyze/optimize-debian/blob/main/docs/README_VPS.md

Options:
  -h, --help    Show this help and exit without changing anything
USAGE
}

# Every step runs from optimize_main, called on the last line: bash reads a whole function before
# running it, so a download cut short (bash <(curl ...)) stops with a syntax error before any
# change. The body keeps the column it had at the top level, so the heredocs it writes stay as
# they are.
optimize_main() {
case "${1:-}" in
    -h|--help)
        print_usage
        exit 0
        ;;
    "")
        ;;
    *)
        printf 'Unknown argument: %s\n\n' "$1" >&2
        print_usage >&2
        exit 2
        ;;
esac


# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

tui_init || true
log "=== Starting VPS Optimization ==="

################################################################################
# 1. Detect OS Version
################################################################################
section "${SYMBOL_GEAR} Detecting Operating System"

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
prevent_duplicate_cloud_init_networking

################################################################################
# 2. User Creation and SSH Key Setup
################################################################################
section "${SYMBOL_GEAR} User Account Setup"

# Username validation function
validate_username() {
    common_validate_username "${1:-}"
}

echo ""
info "We need to create a new sudo user for secure access."
info "Root login will be disabled after setup."
echo ""

# Username input with validation and retry
USER_WAS_CREATED=false
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
    log "Using existing user: $NEW_USER"

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
    USER_WAS_CREATED=true

    # Add to sudo group
    /usr/sbin/usermod -aG sudo "$NEW_USER"
    log "User $NEW_USER created and added to sudo group"

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

# Store user for later use (adding to docker group)
DOCKER_USER=$NEW_USER

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
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

echo ""
info "Please paste your SSH public key (the content of your id_rsa.pub or id_ed25519.pub):"
info "If you don't have one, generate it on your local machine with: ssh-keygen -t ed25519"
echo ""
read -r -p "SSH Public Key: " SSH_PUBLIC_KEY

if [ -z "$SSH_PUBLIC_KEY" ]; then
    error "SSH public key cannot be empty!"
    exit 1
fi

# Add SSH key to authorized_keys
append_authorized_key_unique "$SSH_PUBLIC_KEY" "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
log "SSH key configured for $NEW_USER"

echo ""
if $USER_WAS_CREATED; then
    warn "IMPORTANT: Please test SSH login with the new user in another terminal!"
else
    warn "IMPORTANT: Please test SSH login with the configured user in another terminal!"
fi
warn "Command: ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
echo ""
read -r -p "Press Enter once you've verified SSH access works..."

################################################################################
# 3. System Localization Settings
################################################################################
section "${SYMBOL_GEAR} System Localization"

echo ""
info "Setting up system locale, hostname, and timezone..."
echo ""

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
common_safe_install locales
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

# Hostname configuration
echo ""
read -r -p "Enter new hostname (press Enter to keep current: $(hostname)): " NEW_HOSTNAME

if [ -n "$NEW_HOSTNAME" ]; then
    # Validate hostname
    if [[ $(LC_ALL=C; echo "$NEW_HOSTNAME") =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        OLD_HOSTNAME=$(hostname)

        # Set new hostname
        hostnamectl set-hostname "$NEW_HOSTNAME"

        # Update /etc/hosts
        sed -i "s/127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts

        # Add entry if not exists
        if ! grep -q "127.0.1.1" /etc/hosts; then
            echo "127.0.1.1	${NEW_HOSTNAME}" >> /etc/hosts
        fi

        log "Hostname changed: $OLD_HOSTNAME -> $NEW_HOSTNAME"
    else
        warn "Invalid hostname format. Keeping current hostname: $(hostname)"
    fi
else
    log "Keeping current hostname: $(hostname)"
fi

# Timezone configuration
echo ""
# Get current timezone
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
elif [ -L /etc/localtime ]; then
    CURRENT_TZ=$(readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||')
else
    CURRENT_TZ="Unknown"
fi

info "Current timezone: $CURRENT_TZ"
info "Examples: Europe/Moscow, America/New_York, Asia/Tokyo, UTC"
echo ""
read -r -p "Enter timezone (press Enter to keep current): " NEW_TIMEZONE

if [ -n "$NEW_TIMEZONE" ]; then
    # Validate timezone
    if [ -f "/usr/share/zoneinfo/$NEW_TIMEZONE" ]; then
        if command -v timedatectl >/dev/null 2>&1; then
            # Use timedatectl if available
            if timedatectl set-timezone "$NEW_TIMEZONE" 2>/dev/null; then
                log "Timezone set to: $NEW_TIMEZONE"
            else
                # Fallback to manual method
                ln -sf "/usr/share/zoneinfo/$NEW_TIMEZONE" /etc/localtime
                echo "$NEW_TIMEZONE" > /etc/timezone
                log "Timezone set to: $NEW_TIMEZONE (manual method)"
            fi
        else
            # Manual timezone configuration
            ln -sf "/usr/share/zoneinfo/$NEW_TIMEZONE" /etc/localtime
            echo "$NEW_TIMEZONE" > /etc/timezone
            log "Timezone set to: $NEW_TIMEZONE"
        fi
    else
        warn "Invalid timezone '$NEW_TIMEZONE'. Timezone file not found."
        warn "Keeping current timezone."
    fi
else
    log "Keeping current timezone: $CURRENT_TZ"
fi

common_enable_time_sync || true

echo ""
info "Localization configured:"
info "  Locale: $DEFAULT_LOCALE"
info "  Hostname: $(hostname)"
# Get timezone again for display
if command -v timedatectl >/dev/null 2>&1; then
    DISPLAY_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
elif [ -L /etc/localtime ]; then
    DISPLAY_TZ=$(readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||')
else
    DISPLAY_TZ="Unknown"
fi
info "  Timezone: $DISPLAY_TZ"
info "  Time sync: ${COMMON_TIME_SYNC_SERVICE:-Not configured}"
echo ""

#################################################################################
# 4. Fish Shell and Starship Installation
################################################################################
section "${SYMBOL_ROCKET} Fish + Starship Installation"

echo ""
info "Installing Fish shell and Starship prompt (nerd-font-symbols preset)..."
echo ""

# Install Fish and dependencies with availability check
common_safe_install fish git curl

# Starship: the Debian package (Debian 13) or the pinned release checked by its SHA-256
common_install_starship || warn "Starship could not be installed"

if command -v starship >/dev/null 2>&1; then
    log "Starship prompt installed"
else
    warn "Starship installation encountered an issue"
fi

setup_fish_for_user() {
    local username=$1
    local user_home
    user_home=$(common_user_home "$username" || echo "/home/$username")

    log "Setting up Fish + Starship for user: $username"
    if common_setup_fish "$username" "$user_home" vps; then
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

# Setup Fish for root
setup_fish_for_user root

# Setup Fish for new user
setup_fish_for_user "$NEW_USER"

echo ""
info "Fish + Starship configured successfully!"
log "Features: Starship prompt (nerd-font-symbols), autosuggestions, syntax highlighting, Git & Docker integration"
echo ""

################################################################################
# 4.5. Bash Modernization (Minimal Configuration)
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
    if common_setup_bashrc "$username" "$user_home" vps; then
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
# 5. Go Installation
################################################################################
section "${SYMBOL_PACKAGE} Go Installation"

log "Installing Go programming language..."

# The pinned Go release, checked against its SHA-256 and swapped in only after unpacking
if ! common_install_go; then
    error "Go installation failed"
    exit 1
fi
GO_VERSION="$(head -n 1 /usr/local/go/VERSION)"
GO_VERSION="${GO_VERSION#go}"

# Create profile.d entry for Go PATH
cat > /etc/profile.d/golang.sh <<'GOEOF'
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
GOEOF

chmod +x /etc/profile.d/golang.sh

# Add Go to .bashrc for root
if [ -f /root/.bashrc ]; then
    if ! grep -q "GOROOT" /root/.bashrc; then
        cat >> /root/.bashrc <<'GORC'

# Go configuration
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
GORC
    fi
fi

# Add Go to .bashrc for new user
USER_HOME=$(common_user_home "$NEW_USER" || echo "/home/$NEW_USER")
if [ -f "$USER_HOME/.bashrc" ]; then
    if ! grep -q "GOROOT" "$USER_HOME/.bashrc"; then
        cat >> "$USER_HOME/.bashrc" <<'GORC'

# Go configuration
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
GORC
        chown "$NEW_USER:$NEW_USER" "$USER_HOME/.bashrc"
    fi
fi

# Source the profile for current session
# shellcheck disable=SC1091
. /etc/profile.d/golang.sh

log "Go ${GO_VERSION} installed successfully"
log "Go path: /usr/local/go/bin/go"

################################################################################
# 6. Node.js and fnm Installation
################################################################################
section "${SYMBOL_PACKAGE} Node.js Installation (fnm + LTS)"

log "Installing fnm and Node.js LTS..."
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

# Function to install fnm for a user
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

    local fnm_bin="$user_home/.local/share/fnm/fnm"
    if [ -x "$fnm_bin" ]; then
        log "fnm installed successfully for $username"
    else
        warn "fnm installation may have failed for $username"
    fi

    if [ -f "$user_home/.bashrc" ]; then
        if ! grep -q "FNM_PATH" "$user_home/.bashrc"; then
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
        fi
    fi

    chown -R "$username:$username" "$user_home/.local/share/fnm" 2>/dev/null || true
    chown -R "$username:$username" "$user_home/.local/state/fnm-runtime" 2>/dev/null || true
    chown -R "$username:$username" "$user_home/.npm" 2>/dev/null || true
    chown "$username:$username" "$user_home/.bashrc" 2>/dev/null || true

    rm -f "$fnm_install_script"

    log "fnm setup completed for $username"
}

if ensure_fnm_install_dependencies; then
    # Install fnm for root
    install_fnm_for_user root || warn "fnm installation for root failed"

    # Install fnm for new user
    if [ -n "${NEW_USER:-}" ] && [ "$NEW_USER" != "root" ]; then
        install_fnm_for_user "$NEW_USER" || warn "fnm installation for $NEW_USER failed"
    fi

    log "Node.js and fnm installation complete"
fi

################################################################################
# 7. Detect CPU Architecture and RAM
################################################################################
log "Step 7: Detecting system specifications..."

# Install bc with availability check (needed for calculations)
common_safe_install bc

# Detect CPU architecture
CPU_ARCH=$(uname -m)
log "CPU Architecture: $CPU_ARCH"

# Get total RAM in GB (force English locale for decimal point)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_KB/1024/1024}")
# Replace comma with dot for calculations
TOTAL_RAM_GB=$(echo "$TOTAL_RAM_GB" | tr ',' '.')
log "Total RAM: ${TOTAL_RAM_GB}GB"

# Calculate swap size based on RAM (force English locale for bc)
if (( $(LC_NUMERIC=C echo "$TOTAL_RAM_GB < 3" | bc -l) )); then
    # Less than 3GB: swap = 2 * RAM
    SWAP_SIZE=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB * 2 + 0.5}")
    SWAPPINESS=60
    log "RAM < 3GB: Creating ${SWAP_SIZE}GB swap (2x RAM)"
else
    # 3GB or more: swap = RAM / 2 (rounded up for better performance)
    SWAP_SIZE=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", ($TOTAL_RAM_GB / 2) + 0.5}")
    SWAPPINESS=10
    log "RAM >= 3GB: Creating ${SWAP_SIZE}GB swap (0.5x RAM)"
fi

################################################################################
# 6. System Update and Essential Packages
################################################################################
log "Step 8: Updating system and installing essential packages..."

common_apt_update "initial package refresh"
common_apt_get upgrade -y

# Enrich APT sources with non-free packages
log "Enriching APT sources with contrib and non-free components..."
if ! common_enrich_apt_sources; then
    error "Failed while rewriting APT source files"
    exit 1
fi
if ! common_apt_update "APT source enrichment"; then
    error "APT source enrichment left the package index in a broken state"
    exit 1
fi
log "APT sources enriched with contrib and non-free components"

# Install essential packages with availability check
essential_packages=(
    "wget"
    "curl"
    "git"
    "htop"
    "iotop"
    "sysstat"
    "net-tools"
    "iptables"
    "net-tools"
    "iptables"
    "ufw"
    "irqbalance"
    "fail2ban"
    "python3-systemd"
    "unattended-upgrades"
    "apt-listchanges"
    "needrestart"
    "ncdu"
    "tree"
    "vim"
    "nano"
    "tmux"
    "zip"
    "unzip"
    "gnupg"
    "ca-certificates"
    "lsb-release"
    "cmake"
    "make"
    "gcc"
    "g++"
    "python3-venv"
    "fzf"
    "ripgrep"
    "fd-find"
    "bat"
    "xz-utils"
    "xdg-user-dirs"
)

common_safe_install "${essential_packages[@]}"

# Configure iptables-legacy for Debian (nftables compatibility issue with UFW/Docker)
# Must be done BEFORE installing UFW to ensure proper initialization
log "Configuring iptables-legacy for UFW and Docker compatibility..."

# Switch ALL iptables utilities to legacy mode (critical for UFW)
# Set master alternatives first
update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || update-alternatives --install /usr/sbin/iptables iptables /usr/sbin/iptables-legacy 100
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || update-alternatives --install /usr/sbin/ip6tables ip6tables /usr/sbin/ip6tables-legacy 100
# Set slave alternatives (iptables-restore and iptables-save are automatically managed)
update-alternatives --set iptables-save /usr/sbin/iptables-legacy-save 2>/dev/null || true
update-alternatives --set ip6tables-save /usr/sbin/ip6tables-legacy-save 2>/dev/null || true

log "iptables switched to legacy mode (all utilities) for compatibility"

log "Essential packages installed"

# Create Debian package aliases (Debian uses different names for some packages)
log "Creating package aliases..."
if [ -f /usr/bin/batcat ] && [ ! -f /usr/bin/bat ]; then
    ln -sf /usr/bin/batcat /usr/bin/bat 2>/dev/null || true
fi
if [ -f /usr/bin/fdfind ] && [ ! -f /usr/bin/fd ]; then
    ln -sf /usr/bin/fdfind /usr/bin/fd 2>/dev/null || true
fi
log "Package aliases created"

################################################################################
# 8. Debian Kernel Installation (Official Backports on Debian 12)
################################################################################
log "Step 9: Configuring official Linux kernel..."

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

    progress "Installing latest kernel from Debian Backports ($KERNEL_PKG, $HEADERS_PKG)..."
    if common_apt_update "Backports repository refresh" \
        && common_install_from_release bookworm-backports "$KERNEL_PKG" "$HEADERS_PKG"; then
        log "Official Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG) installed successfully"
    else
        error "Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG) was not installed"
        exit 1
    fi
    BACKPORTS_KERNEL_INSTALLED=true
else
    info "Debian $distro_version includes modern kernel by default ($KERNEL_VERSION)"
    progress "Ensuring latest official Debian kernel ($KERNEL_PKG, $HEADERS_PKG)..."
    if ! common_safe_install "$KERNEL_PKG" "$HEADERS_PKG"; then
        error "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) was not installed"
        exit 1
    fi
    log "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) updated successfully"
    BACKPORTS_KERNEL_INSTALLED=false
fi


################################################################################
# 8. Docker and Docker Compose Installation
################################################################################
log "Step 10: Installing Docker and Docker Compose..."

# Remove old Docker versions if present
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    common_apt_get remove -y "$pkg" 2>/dev/null || true
done

# Note: iptables-legacy was already configured above for UFW and Docker compatibility
log "Using iptables-legacy for Docker compatibility (already configured)"

# Install prerequisites (ca-certificates, curl, gnupg, lsb-release already installed)
install -m 0755 -d /etc/apt/keyrings

# Add Docker's official GPG key, accepted only with its pinned fingerprint
if ! common_install_apt_key docker /etc/apt/keyrings/docker.gpg; then
    error "The Docker APT key could not be installed"
    exit 1
fi
DOCKER_ARCH="$(dpkg --print-architecture)"

# Set up Docker repository
common_render_docker_debian_source "$ID" "$VERSION_CODENAME" "$DOCKER_ARCH" "/etc/apt/keyrings/docker.gpg" > /etc/apt/sources.list.d/docker.sources
common_apt_sources_changed

# Install Docker Engine, CLI, containerd, and Docker Compose plugin with availability check
docker_packages=(
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
    "docker-buildx-plugin"
    "docker-compose-plugin"
)

common_safe_install "${docker_packages[@]}" || {
    error "Docker packages installation failed"
    exit 1
}

# Check if Docker was actually installed
if ! command -v docker &>/dev/null; then
    error "Docker installation failed - docker binary not found!"
    exit 1
fi

# Configure Docker daemon for better performance BEFORE starting service
mkdir -p /etc/docker
write_config_with_backup /etc/docker/daemon.json <<EOF
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

# Create systemd drop-in directory for Docker service customization
mkdir -p /etc/systemd/system/docker.service.d

# Create systemd service override to fix socket activation issues
cat > /etc/systemd/system/docker.service.d/override.conf <<'SYSTEMD_EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock
SYSTEMD_EOF

# Enable and start Docker service with stale process cleanup
systemctl daemon-reload

# Clean up any stale Docker processes and PID file before starting
if [ -f /var/run/docker.pid ]; then
    old_pid=$(cat /var/run/docker.pid 2>/dev/null || echo "")
    if [ -n "$old_pid" ]; then
        kill -9 "$old_pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f /var/run/docker.pid
fi

# Also try to kill any lingering dockerd processes
pkill -9 dockerd 2>/dev/null || true
sleep 1

systemctl enable docker
systemctl enable docker.socket
systemctl start docker.socket
systemctl start docker

# Ensure docker group exists
/usr/sbin/groupadd -f docker

# Fix docker.sock permissions
sleep 1
if [ -S /var/run/docker.sock ]; then
    chown root:docker /var/run/docker.sock
    chmod 660 /var/run/docker.sock
    log "Docker socket permissions fixed"
fi

# Add user to docker group
/usr/sbin/usermod -aG docker "$DOCKER_USER"
log "User $DOCKER_USER added to docker group"

# Verify Docker installation
DOCKER_VERSION=$(docker --version)
COMPOSE_VERSION=$(docker compose version)
log "Docker installed: $DOCKER_VERSION"
log "Docker Compose installed: $COMPOSE_VERSION"

log "Docker and Docker Compose installation complete"

################################################################################
# 9. Kernel Parameters Optimization (sysctl)
################################################################################
log "Step 11: Optimizing kernel parameters..."

# Ensure /etc/sysctl.conf exists (some minimal Debian installations don't have it)
if [ ! -f /etc/sysctl.conf ]; then
    log "Creating /etc/sysctl.conf (was missing)..."
    cat > /etc/sysctl.conf <<'SYSCTLCONF'
#
# /etc/sysctl.conf - Configuration file for setting system variables
# See /etc/sysctl.d/ for additional system variables.
# See sysctl.conf (5) for information.
#

# Additional settings are in /etc/sysctl.d/
SYSCTLCONF
fi

# Backup original sysctl.conf
cp /etc/sysctl.conf "/etc/sysctl.conf.backup.$(date +%F)" 2>/dev/null || true

# Calculate adaptive buffer sizes based on RAM (optimized for channels up to 10 Gbps)
TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "2048")
MAX_BUFFER=67108864
DEF_BUFFER=2097152
if [ "$TOTAL_RAM_MB" -lt 3000 ]; then
    MAX_BUFFER=33554432
    DEF_BUFFER=1048576
fi

# Ensure persistent kernel modules loading for BBR, TUN, and WireGuard
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/99-vps-modules.conf <<'MODULES_EOF'
tcp_bbr
tun
wireguard
MODULES_EOF
modprobe tcp_bbr 2>/dev/null || true
modprobe tun 2>/dev/null || true
modprobe wireguard 2>/dev/null || true

cat > /etc/sysctl.d/99-vps-optimization.conf <<EOF
# VPS Optimization - Optimized for high-throughput VPN servers (up to 10 Gbps)
# Focus: Low latency, BDP scaling, efficient memory usage, WireGuard/OpenVPN routing

# ============================================================================
# Network Performance - Optimized for VPN (TCP + UDP) & 10 Gbps Links
# ============================================================================

# TCP/UDP Buffer Sizes (adaptive up to 64MB for 10G links)
net.core.rmem_default = $DEF_BUFFER
net.core.wmem_default = $DEF_BUFFER
net.core.rmem_max = $MAX_BUFFER
net.core.wmem_max = $MAX_BUFFER
net.ipv4.tcp_rmem = 4096 1048576 $MAX_BUFFER
net.ipv4.tcp_wmem = 4096 1048576 $MAX_BUFFER

# UDP Buffer Sizes (critical for high-speed VPN protocols like WireGuard, AmneziaWG)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Network Queues (scaled for high throughput)
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384

# TCP Performance Tuning
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535

# TCP Fast Open (reduces VPN connection latency by 15-40%)
net.ipv4.tcp_fastopen = 3

# TCP Keep-Alive (faster dead connection detection for VPN)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# TCP Window Scaling & SACK (better for high-latency VPN connections)
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# TCP Orphan & TIME_WAIT limits (prevent memory exhaustion)
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_max_tw_buckets = 131072

# MTU Probing (helps with VPN encapsulation overhead)
net.ipv4.tcp_mtu_probing = 1

# ============================================================================
# TCP Congestion Control - BBR for better VPN throughput
# ============================================================================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ============================================================================
# Connection Tracking - Optimized for high connection counts & VPN tunnels
# ============================================================================
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# Generic timeout (for VPN protocols)
net.netfilter.nf_conntrack_generic_timeout = 120

# ============================================================================
# File System Performance
# ============================================================================
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# ============================================================================
# Virtual Memory - Optimized for 1-4GB RAM
# ============================================================================
vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = 60
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# Memory management
vm.min_free_kbytes = 65536
vm.overcommit_memory = 1
vm.overcommit_ratio = 50
vm.zone_reclaim_mode = 0

# ============================================================================
# Security (VPN server hardening)
# ============================================================================

# IP Forwarding (required for VPN)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Reverse Path Filtering (Loose mode 2 for VPN tunnels and multi-homed routing, RFC 3704)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# ICMP & Broadcast protection
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Source routing (disable for security)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Redirect protection
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# ============================================================================
# Kernel Performance
# ============================================================================
kernel.panic = 10
kernel.panic_on_oops = 1

# Process limits (moderate for low RAM)
kernel.pid_max = 65536
kernel.threads-max = 65536



EOF

# Apply sysctl settings with error tolerance for missing parameters
# Some parameters may not exist in virtualized environments (WSL2, containers, etc.)
# Apply sysctl settings with error tolerance for missing parameters
/usr/sbin/sysctl -e -p /etc/sysctl.d/99-vps-optimization.conf 2>&1 | grep -v "cannot stat" | grep -v "No such file or directory" || true
log "Kernel parameters applied (some may be skipped in virtualized environments)"

################################################################################
# 10. Swap Optimization
################################################################################
log "Step 12: Setting up swap file..."

# Remove existing swap if present
if /usr/sbin/swapon --show | grep -q "/swapfile"; then
    log "Removing existing swap..."
    /usr/sbin/swapoff /swapfile
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
fi

# Create new swap with calculated size
log "Creating ${SWAP_SIZE}GB swap file..."
if ! /usr/bin/fallocate -l "${SWAP_SIZE}G" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1G count="$SWAP_SIZE" status=progress
fi
chmod 600 /swapfile
/usr/sbin/mkswap /swapfile
/usr/sbin/swapon /swapfile

# Add to fstab
if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Swap file created and enabled (${SWAP_SIZE}GB, swappiness=$SWAPPINESS)"

################################################################################
# 11. Firewall Configuration (UFW)
################################################################################
# Configure Firewall (UFW)
log "Configuring firewall (UFW)..."
/usr/sbin/ufw --force enable >/dev/null 2>&1 || warn "Could not enable UFW"
# Default: Deny Incoming, Allow Outgoing, Allow Forwarding (critical for VPN routing)
# We use 'ufw default' commands which are robust
/usr/sbin/ufw default deny incoming 2>/dev/null
/usr/sbin/ufw default allow outgoing 2>/dev/null
if [ -f /etc/default/ufw ]; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
fi
/usr/sbin/ufw default allow forward 2>/dev/null || true

# Allow SSH (Port 22)
/usr/sbin/ufw allow 22/tcp 2>/dev/null || warn "Could not allow SSH port"

# Allow HTTP/HTTPS
/usr/sbin/ufw allow 80/tcp 2>/dev/null
/usr/sbin/ufw allow 443/tcp 2>/dev/null

log "UFW firewall enabled with SSH access allowed"
log "Firewall rules: SSH (22/tcp), HTTP (80/tcp), HTTPS (443/tcp) allowed"

################################################################################
# 12. Fail2Ban Configuration
################################################################################
log "Step 14: Configuring Fail2Ban..."

systemctl enable fail2ban
systemctl start fail2ban

write_config_with_backup /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
backend = systemd

[sshd]
enabled = true
port = 22
maxretry = 3
bantime = 7200
EOF

systemctl restart fail2ban

################################################################################
# 25. System Limits Optimization
################################################################################
log "Step 15: Optimizing system limits..."

write_system_limits

################################################################################
# 14. Automatic Security Updates
################################################################################
log "Step 16: Configuring automatic security updates..."

common_render_debian_unattended_upgrades_conf > /etc/apt/apt.conf.d/50unattended-upgrades
common_render_apt_periodic_auto_upgrades_conf > /etc/apt/apt.conf.d/20auto-upgrades

################################################################################
# 15. Journal Log Size Limit
################################################################################
log "Step 17: Limiting systemd journal size..."

mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/00-journal-size.conf <<EOF
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=100M
RuntimeMaxUse=100M
EOF

systemctl restart systemd-journald

################################################################################
# 24. SSH Hardening
################################################################################
log "Step 18: Hardening SSH configuration..."

configure_ssh_hardening "$NEW_USER" || exit 1

################################################################################
# 25. Optimize tmpfs
################################################################################
log "Step 19: Optimizing tmpfs..."

# Check if entries already exist to avoid duplicates
if ! grep -q "tmpfs /tmp" /etc/fstab; then
    cat >> /etc/fstab <<EOF
tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=1G 0 0
tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=512M 0 0
EOF
fi

################################################################################
# 24. Disable Unnecessary Services
################################################################################
log "Step 20: Disabling unnecessary services..."

SERVICES_TO_DISABLE=(
    "bluetooth.service"
    "cups.service"
    "avahi-daemon.service"
)

for service in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$service" &>/dev/null; then
        systemctl disable "$service" &>/dev/null || true
        systemctl stop "$service" &>/dev/null || true
        log "Disabled $service"
    fi
done

################################################################################
# 25. I/O Scheduler Optimization
################################################################################
log "Step 21: Optimizing I/O scheduler..."

cat > /etc/udev/rules.d/60-ioschedulers.conf <<'EOF'
# I/O Scheduler optimization for VPS environments

# NVMe drives - use 'none' scheduler (best for NVMe)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rq_affinity}="2"

# SSD drives - use 'mq-deadline' scheduler (best for SATA SSD)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="512"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="128"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"

# HDD drives - use 'bfq' scheduler (best for rotational drives)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="256"
EOF

# Reload udev rules
udevadm control --reload-rules
udevadm trigger

log "I/O scheduler optimized"

################################################################################
# 26. CPU Governor Optimization
################################################################################
log "Step 22: Optimizing CPU governor..."

# Install linux-cpupower for CPU frequency management on Debian 12/13
common_safe_install linux-cpupower || warn "linux-cpupower was not installed, CPU governor tuning may be skipped"

# Set CPU governor to 'schedutil' (balance between performance and power efficiency)
# For VPN servers, 'schedutil' provides good balance - responsive when needed, efficient when idle
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    # Detect best available governor
    AVAILABLE_GOVERNORS=$(cpupower frequency-info -g 2>/dev/null | grep "available cpufreq governors:" | cut -d: -f2)
    
    if [[ "$AVAILABLE_GOVERNORS" == *"schedutil"* ]]; then
        GOVERNOR="schedutil"
    elif [[ "$AVAILABLE_GOVERNORS" == *"powersave"* ]]; then
        GOVERNOR="powersave"
        log "Note: Using 'powersave' governor (std for intel_pstate or fallback)"
    elif [[ "$AVAILABLE_GOVERNORS" == *"ondemand"* ]]; then
        GOVERNOR="ondemand"
    else
        GOVERNOR="performance"
    fi

    log "Selected CPU Governor: $GOVERNOR"

    # Create systemd service to set governor on boot
    cat > /etc/systemd/system/cpu-governor.service <<EOF
[Unit]
Description=Set CPU Governor to $GOVERNOR
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/cpupower frequency-set -g $GOVERNOR

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start the service
    systemctl daemon-reload
    systemctl enable cpu-governor.service
    systemctl start cpu-governor.service

    # Also set it now
    cpupower frequency-set -g $GOVERNOR 2>/dev/null || true

    log "CPU governor set to '$GOVERNOR'"
else
    warn "CPU frequency scaling not available (virtual CPU or governor not supported)"
fi

################################################################################
# 24. Create Monitoring Script
################################################################################
log "Step 22: Creating monitoring script..."

cat > /usr/local/bin/vps-monitor.sh <<'SCRIPT'
#!/bin/bash

echo "=== VPS System Monitor ==="
echo ""

echo "=== System Info ==="
echo "Hostname: $(hostname)"
echo "Uptime: $(uptime -p)"
echo "Kernel: $(uname -r)"
echo ""

echo "=== CPU Usage ==="
top -bn1 | head -n 5
echo ""

# Show CPU governor if available
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    echo "CPU Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
    echo "CPU Frequency: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.2f GHz", $1/1000000}' || echo 'N/A')"
fi

echo ""
echo "=== Memory Usage ==="
free -h

echo ""
echo "=== Disk Usage ==="
df -h | grep -v tmpfs

echo ""
echo "=== I/O Scheduler & Disk Info ==="
for disk in /sys/block/sd? /sys/block/nvme?n?; do
    if [ -e "$disk" ]; then
        device=$(basename $disk)
        scheduler=$(cat $disk/queue/scheduler 2>/dev/null | grep -oP '\[\K[^\]]+' || echo 'N/A')
        rotational=$(cat $disk/queue/rotational 2>/dev/null)
        if [ "$rotational" = "0" ]; then
            disk_type="SSD/NVMe"
        else
            disk_type="HDD"
        fi
        echo "$device: $disk_type, Scheduler: $scheduler"
    fi
done

echo ""
echo "=== Network Performance ==="
echo "TCP Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
echo "Default Qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'N/A')"
echo "IP Forwarding (VPN): $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 'N/A')"

echo ""
echo "=== Network Connections ==="
ss -s

echo ""
echo "=== Memory Parameters ==="
echo "Swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo 'N/A')"
echo "VFS Cache Pressure: $(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo 'N/A')"

echo ""
echo "=== Load Average ==="
uptime

echo ""
echo "=== Top 5 Processes by Memory ==="
ps aux --sort=-%mem | head -6

echo ""
echo "=== Top 5 Processes by CPU ==="
ps aux --sort=-%cpu | head -6

echo ""
echo "=== Swap Usage ==="
swapon --show

echo ""
echo "=== Active VPN Connections (if any) ==="
# Check for common VPN interfaces
if ip link show | grep -qE 'tun|wg|ppp'; then
    ip -s link show | grep -A 2 -E 'tun|wg|ppp'
else
    echo "No VPN interfaces detected"
fi

SCRIPT

chmod +x /usr/local/bin/vps-monitor.sh

################################################################################
# 21. Create Cleanup Script
################################################################################
log "Step 23: Creating cleanup script..."

cat > /usr/local/bin/vps-cleanup.sh <<'SCRIPT'
#!/bin/bash

echo "Starting VPS cleanup..."

# Clean package cache
apt-get clean
apt-get autoclean
apt-get -o DPkg::Lock::Timeout=300 autoremove -y

# Clean journal logs older than 7 days
journalctl --vacuum-time=7d

# Clean old kernels (keep current + 1)
dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | head -n -1 | xargs apt-get -o DPkg::Lock::Timeout=300 -y purge 2>/dev/null || true

# Clean temp files older than 7 days
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

# Clean thumbnail cache if exists
rm -rf ~/.cache/thumbnails/* 2>/dev/null || true

echo "Cleanup completed!"
SCRIPT

chmod +x /usr/local/bin/vps-cleanup.sh

# Create weekly cron job for cleanup
cat > /etc/cron.weekly/vps-cleanup <<'EOF'
#!/bin/bash
/usr/local/bin/vps-cleanup.sh >> /var/log/vps-cleanup.log 2>&1
EOF

chmod +x /etc/cron.weekly/vps-cleanup

################################################################################
# 24. Network Performance Test Script
################################################################################
log "Step 24: Creating network performance test script..."

cat > /usr/local/bin/network-test.sh <<'SCRIPT'
#!/bin/bash

echo "=== Network Performance Test ==="
echo ""
echo "Testing network speed with speedtest-cli..."

if ! command -v speedtest-cli &> /dev/null; then
    echo "Installing speedtest-cli..."
    apt-get install -y -o DPkg::Lock::Timeout=300 speedtest-cli
fi

speedtest-cli

echo ""
echo "=== Network Statistics ==="
netstat -s | head -20
SCRIPT

chmod +x /usr/local/bin/network-test.sh

################################################################################
# 23. System Information Script
################################################################################
log "Step 25: Creating system information script..."

cat > /usr/local/bin/vps-info.sh <<'SCRIPT'
#!/bin/bash

echo "=== VPS System Information ==="
echo ""
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""

# CPU Detection with fallback
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)
if [ -z "$CPU_MODEL" ]; then
    # Fallback for systems without "model name" (ARM, some VPS)
    CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2 | xargs)
fi
if [ -z "$CPU_MODEL" ]; then
    # Final fallback - show CPU architecture
    CPU_MODEL=$(lscpu | grep "Architecture" | cut -d':' -f2 | xargs)
fi

echo "CPU: ${CPU_MODEL:-Unknown}"
echo "CPU Cores: $(nproc)"
echo "Architecture: $(uname -m)"
echo ""
echo "Total RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "Used RAM: $(free -h | awk '/^Mem:/ {print $3}')"
echo "Free RAM: $(free -h | awk '/^Mem:/ {print $4}')"
echo ""
echo "Swap Total: $(free -h | awk '/^Swap:/ {print $2}')"
echo "Swap Used: $(free -h | awk '/^Swap:/ {print $3}')"
echo ""
echo "Disk Usage:"
df -h / | tail -1
echo ""
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "Unable to detect")
echo "Public IP: $PUBLIC_IP"
echo ""
echo "Active Firewall Rules:"
ufw status numbered
echo ""
echo "TCP Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "Swappiness: $(sysctl -n vm.swappiness)"
echo ""
if command -v docker &> /dev/null; then
    echo "Docker Version: $(docker --version 2>/dev/null || echo 'Not available')"
    echo "Docker Compose: $(docker compose version 2>/dev/null || echo 'Not available')"
    echo "Docker Status: $(systemctl is-active docker 2>/dev/null || echo 'Not running')"
fi
SCRIPT

chmod +x /usr/local/bin/vps-info.sh

################################################################################
# Final Summary
################################################################################
section "VPS Optimization Complete"
ui_success_title "VPS optimization completed"

subsection "Summary of optimizations"
info "OS detected: $OS_NAME $OS_VERSION ($OS_CODENAME)"
info "Locale: $DEFAULT_LOCALE (will apply after reboot)"
info "Hostname: $(hostname)"
# Get timezone for display with fallback
if command -v timedatectl >/dev/null 2>&1; then
    SUMMARY_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
elif [ -L /etc/localtime ]; then
    SUMMARY_TZ=$(readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||')
else
    SUMMARY_TZ="Unknown"
fi
info "Timezone: $SUMMARY_TZ"
info "Fish + Starship (nerd-font-symbols) configured for root and $NEW_USER"
info "Starship prompt with Nerd Font symbols preset"
info "Autosuggestions and syntax highlighting built-in via Fish"
if $USER_WAS_CREATED; then
    info "New user created: $NEW_USER (with sudo + docker access, passwordless)"
else
    info "Existing user configured: $NEW_USER (with sudo + docker access, passwordless)"
fi
info "SSH keys configured for $NEW_USER"
info "System updated and essential packages installed"
info "Docker & Docker Compose installed (latest version)"
info "User $NEW_USER added to docker group (no sudo needed for docker)"
info "10G networking parameters optimized (BBR, FQ, adaptive buffers up to 64MB)"
if [ "${BACKPORTS_KERNEL_INSTALLED:-false}" = true ]; then
    info "Official Debian Backports kernel installed ($KERNEL_PKG, $HEADERS_PKG)"
else
    info "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) verified"
fi
info "Swap configured (${SWAP_SIZE}GB, swappiness=$SWAPPINESS)"
info "Firewall (UFW) enabled with forward policy ACCEPT, SSH, HTTP, HTTPS"
info "Fail2Ban configured with python3-systemd for SSH protection"
info "System limits increased (nofile $VPS_NOFILE_LIMIT)"
info "Automatic security updates enabled"
info "Journal logs limited to 500MB"
info "SSH hardened (root login disabled, only key auth)"
info "tmpfs optimized"
info "I/O scheduler optimized"
info "Unnecessary services disabled"

subsection "Created utility scripts"
info "vps-monitor.sh   - System monitoring"
info "vps-cleanup.sh   - System cleanup (runs weekly)"
info "vps-info.sh      - System information"
info "network-test.sh  - Network performance test"

subsection "Security configuration"
info "Root login: DISABLED"
info "Password authentication: DISABLED"
info "SSH key authentication: ENABLED (for $NEW_USER only)"
info "Passwordless sudo: ENABLED (for $NEW_USER and root)"
info "SSH port: 22"

subsection "Critical SSH verification"
warn "CRITICAL: Before disconnecting, verify SSH access:"
warn "  1. Open a new terminal (don't close this one!)"
warn "  2. Test login: ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
warn "  3. Test sudo: sudo -l (should work without password)"
warn "  4. Only disconnect current session after successful test!"
echo ""
subsection "System information"
/usr/local/bin/vps-info.sh
echo ""
subsection "Required reboot"
warn "A system reboot is REQUIRED to activate all changes:"
warn "  - Locale settings ($DEFAULT_LOCALE)"
warn "  - Latest Linux kernel ($KERNEL_PKG)"
warn "  - Docker group membership for $NEW_USER"
warn "  - Fish shell with Starship"
echo ""
read -p "Do you want to reboot now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Rebooting system in 5 seconds... Press Ctrl+C to cancel"
    sleep 5
    /usr/sbin/reboot
else
    log "Reboot skipped. Please reboot manually when ready with: sudo reboot"
    echo ""
    warn "After reboot:"
    warn "  - Check kernel version: uname -r"
    warn "  - Verify locale: locale"
    warn "  - Test Fish: fish"
    warn "  - Test Docker: docker ps (should work without sudo)"
fi
}

# shellcheck disable=SC2317
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
optimize_main "$@"

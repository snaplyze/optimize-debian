#!/bin/bash
# shellcheck disable=SC1091

# Force C locale for script execution to avoid locale-related issues
export LC_ALL=C
export LANG=C

################################################################################
# WSL2 Optimization Script for Debian 12/13 (Bookworm/Trixie) - v4
# Purpose: Complete WSL2 optimization with modern Fish + Starship setup
# Features: WSL2-specific configs, systemd, Docker, NVIDIA/CUDA support, performance tuning
################################################################################

set -Eeuo pipefail

SCRIPT_VERSION="4.1.0"
export DEBIAN_FRONTEND=noninteractive
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

        # A directory of common_temp_dir (lib/common.sh) is also removed when the script is
        # interrupted; lib/tui.sh alone falls back to mktemp.
        if declare -F common_temp_dir >/dev/null; then
            common_temp_dir tmp_dir || return 1
        else
            tmp_dir="$(mktemp -d)" || return 1
        fi
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

# Installation order (dependency-aware):
#  1) Validate Debian 12/13 + WSL2
#  2) Write /etc/wsl.conf early (takes effect only after full `wsl --shutdown`)
#  3) Refresh/upgrade base system and install prerequisite packages
#  4) Create/select the target user before writing user dotfiles
#  5) Configure locales
#  6) Configure shells, then install user-scoped toolchains (Go, fnm/Node)
#  7) Install Docker from the official Docker Debian repository
#  8) Layer NVIDIA Container Toolkit on top of Docker, then optional CUDA
#  9) Apply performance/autoupdate/journald settings and create helper scripts
# 10) Summarize any actions that require a post-install `wsl --shutdown`

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    error "Script failed at line ${line_no} with exit code ${exit_code}. Check ${LOG_FILE} for details."
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ══════════════════════════════════════════════════════════════════════════════
# VISUAL THEME - Modern, Clean, Professional
# ══════════════════════════════════════════════════════════════════════════════

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Symbols
SYMBOL_DOT="•"
SYMBOL_GEAR="⚙"
SYMBOL_PACKAGE="📦"
SYMBOL_ROCKET="🚀"
SYMBOL_CHECK="✔"
SYMBOL_WARN="⚠"
SYMBOL_INFO="ℹ"

# Logging
LOG_FILE="/var/log/wsl2_optimization.log"

# ══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS - Clean TUI Output
# ══════════════════════════════════════════════════════════════════════════════

# Log to file only (silent)
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
    backend="$(tui_detect_backend 2>/dev/null || true)"
    printf '%s\n' "${backend:-plain}"
}

ui_has_gum() {
    [ "$(ui_backend)" = "gum" ] && tui_gum_path >/dev/null 2>&1
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
        "${SYMBOL_CHECK:-}" \
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

print_header() {
    local line
    local gum_active=false

    ui_has_gum && gum_active=true
    clear
    echo ""

    while IFS= read -r line; do
        if $gum_active; then
            tui_gum style --foreground 12 --bold "$line"
        else
            echo -e "${BLUE}${line}${NC}"
        fi
    done <<'EOF'
 __        ______  _     ____
 \ \      / / ___|| |   |___ \
  \ \ /\ / /\___ \| |     __) |
   \ V  V /  ___) | |___ / __/
    \_/\_/  |____/|_____|_____|
EOF

    if $gum_active; then
        tui_gum style --foreground 15 --bold --margin "1 0" "WSL2 Optimization for Debian 12/13  v${SCRIPT_VERSION}"
        tui_gum style --foreground 8 "Systemd, Docker, CUDA, Fish, Node.js, Go and WSL tuning"
    else
        echo ""
        echo -e "${BOLD}${WHITE}WSL2 Optimization for Debian 12/13  v${SCRIPT_VERSION}${NC}"
        echo -e "${DIM}Systemd, Docker, CUDA, Fish, Node.js, Go and WSL tuning${NC}"
    fi
    echo ""
}

ui_message() {
    local color="$1"
    local label="$2"
    local message="$3"

    printf '  %b%-7s%b %s\n' "$color" "[$label]" "$NC" "$message"
}

# Success message
log() {
    ui_message "$GREEN" "ok" "$1"
    log_silent "[OK] $1"
}

# Warning message
warn() {
    ui_message "$YELLOW" "warn" "$1"
    log_silent "[WARN] $1"
}

# Error message
error() {
    ui_message "$RED" "error" "$1"
    log_silent "[ERROR] $1"
}

# Info message
info() {
    ui_message "$BLUE" "info" "$1"
    log_silent "[INFO] $1"
}

# Progress message (what is being done now)
progress() {
    ui_message "$CYAN" ".." "$1"
    log_silent "[PROGRESS] $1"
}

# Section header
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
        echo -e "  ${MAGENTA}-${NC} ${BOLD}${title}${NC}"
    fi
    log_silent "--- $title ---"
}

restore_linux_home_path_ownership() {
    local target_path="$1"
    local desired_user="${2:-}"
    local current_owner
    local home_user

    [ -e "$target_path" ] || return 0

    if [ -z "$desired_user" ]; then
        home_user=$(printf '%s\n' "$target_path" | sed -n 's#^/home/\([^/]\+\)/.*#\1#p')
        if [ -n "$home_user" ] && id "$home_user" >/dev/null 2>&1; then
            desired_user="$home_user"
        fi
    fi

    [ -n "$desired_user" ] || return 0

    current_owner=$(stat -c '%U' "$target_path" 2>/dev/null || true)
    if [ "$current_owner" != "$desired_user" ]; then
        chown "$desired_user:$desired_user" "$target_path" 2>/dev/null || true
        chmod u+rw "$target_path" 2>/dev/null || true
    fi
}

# WSL-specific review of the apt-get update output, run by common_apt_update through
# COMMON_APT_UPDATE_CHECK: repository verification errors reject the refresh, and a WSL
# clock that is out of sync gets a hint.
wsl_apt_update_check() {
    local apt_output="$1"

    if printf '%s\n' "$apt_output" | grep -Eqi '(^W: Failed to fetch|An error occurred during the signature verification|OpenPGP signature verification failed|EXPKEYSIG|NO_PUBKEY|not live until)'; then
        warn "APT package index refresh completed with repository verification errors"
        if printf '%s\n' "$apt_output" | grep -Eqi 'not live until'; then
            warn "WSL clock appears out of sync. Run 'wsl --shutdown' in Windows, reopen WSL, verify the current time, then rerun the script."
        fi
        return 1
    fi
}
COMMON_APT_UPDATE_CHECK=wsl_apt_update_check

is_supported_debian_version() {
    common_is_supported_debian_version "${1:-}"
}

require_supported_debian_release() {
    if [[ "$ID" != "debian" ]]; then
        error "This script requires Debian. Detected: ${ID:-unknown}"
        exit 1
    fi

    if ! is_supported_debian_version "${VERSION_ID:-}"; then
        error "This script supports Debian 12 (Bookworm) and Debian 13 (Trixie) on WSL2."
        error "Detected: ${ID:-unknown} ${VERSION_ID:-unknown}"
        exit 1
    fi
}

resolve_fetch_packages() {
    if common_package_available fastfetch; then
        printf '%s\n' "fastfetch"
    elif common_package_available neofetch; then
        printf '%s\n' "neofetch"
    fi
}

resolve_fetch_command() {
    if command -v fastfetch >/dev/null 2>&1; then
        printf '%s\n' "fastfetch"
    elif command -v neofetch >/dev/null 2>&1; then
        printf '%s\n' "neofetch"
    fi
}

resolve_cuda_distro() {
    if is_supported_debian_version "$1"; then
        printf 'debian%s\n' "${1%%.*}"
        return 0
    fi

    return 1
}

cuda_package_available() {
    local package="$1"
    apt-cache show "$package" >/dev/null 2>&1
}

resolve_cuda_toolkit_package() {
    local package
    local preferred_packages=(
        cuda-toolkit
        cuda-toolkit-13
        cuda-toolkit-13-2
        cuda-toolkit-13-1
        cuda-toolkit-13-0
        cuda-toolkit-12-9
        cuda-toolkit-12-8
        cuda-toolkit-12-6
        cuda-toolkit-12-5
        cuda-toolkit-12-4
        cuda-toolkit-12-3
    )

    for package in "${preferred_packages[@]}"; do
        if cuda_package_available "$package"; then
            printf '%s\n' "$package"
            return 0
        fi
    done

    return 1
}

render_wsl_conf() {
    common_render_wsl_conf "${1:-}"
}

print_usage() {
    cat <<'USAGE'
Usage: sudo bash optimize_wsl2.sh
       bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/optimize-debian/main/optimize_wsl2.sh)

WSL2 setup for Debian 12 and 13: systemd, Fish + Starship, Docker, NVIDIA Container Toolkit,
CUDA, Go and Node.js (fnm). It asks for the components and the user interactively.
Run it as root in the WSL2 distribution: it changes the system (packages, users, sudoers,
/etc/wsl.conf, sysctl). Guide: https://github.com/snaplyze/optimize-debian/blob/main/docs/README_WSL2.md

Options:
  -h, --help    Show this help and exit without changing anything
USAGE
    printf '\nVersion: %s\n' "$SCRIPT_VERSION"
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


# WSL2 detection functions
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

is_wsl2() {
    grep -qiE '(wsl2|microsoft-standard-WSL2)' /proc/sys/kernel/osrelease 2>/dev/null ||     grep -qiE '(wsl2|microsoft-standard-WSL2)' /proc/version 2>/dev/null
}

service_actions_available() {
    has_systemd && [ "${WSL_RESTART_REQUIRED:-false}" != "true" ]
}

note_post_restart() {
    local message="$1"
    POST_RESTART_NOTES+=("$message")
}

has_user_systemd() {
    systemctl --user show-environment >/dev/null 2>&1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

POST_RESTART_NOTES=()

# Verify WSL2 environment
if ! is_wsl; then
    error "This script must be run inside WSL."
    exit 1
fi

if ! grep -qiE 'wsl2|microsoft-standard-WSL2' /proc/sys/kernel/osrelease 2>/dev/null; then
    error "WSL was detected, but this script requires WSL2 specifically."
    error "Current kernel: $(cat /proc/sys/kernel/osrelease 2>/dev/null || echo unknown)"
    exit 1
fi
log "WSL2 kernel confirmed"

# ══════════════════════════════════════════════════════════════════════════════
# START BANNER
# ══════════════════════════════════════════════════════════════════════════════
tui_init || true
print_header
log_silent "=== Starting WSL2 Optimization for Debian 12/13 v${SCRIPT_VERSION} ==="

################################################################################
# 1. Detect OS Version
################################################################################
section "${SYMBOL_GEAR} System Detection"

# Detect OS
if [ -f /etc/os-release ]; then
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
if ! is_wsl; then
    error "This script must be run inside WSL."
    exit 1
fi
if ! is_wsl2; then
    error "WSL detected, but this script requires WSL2."
    exit 1
fi
log "Debian ${VERSION_ID} (${VERSION_CODENAME}) on WSL2 confirmed"

################################################################################
# 2. Interactive Configuration Menu
################################################################################

# Default configuration flags
CONFIGURE_WSL_CONF=true
UPDATE_SYSTEM=true
INSTALL_BASE_UTILS=true
CREATE_USER=false
USER_WAS_CREATED=false
CONFIGURE_LOCALES=true
INSTALL_FISH=true
INSTALL_DOCKER=true
INSTALL_NVIDIA=false
INSTALL_CUDA=false
CONFIGURE_SSH_AGENT=true
INSTALL_GO=true
INSTALL_NODE=true
ENABLE_AUTO_UPDATES=true
PERFORMANCE_TUNING=true
CONFIGURE_JOURNALD=true
WSL_RESTART_REQUIRED=false

show_selected_options() {
    subsection "Selected profile"
    ui_option_state "WSL2 systemd configuration" "$CONFIGURE_WSL_CONF"
    ui_option_state "System package update" "$UPDATE_SYSTEM"
    ui_option_state "Base utilities" "$INSTALL_BASE_UTILS"
    ui_option_state "User provisioning" "$CREATE_USER"
    ui_option_state "Locales" "$CONFIGURE_LOCALES"
    ui_option_state "Fish + Starship" "$INSTALL_FISH"
    ui_option_state "SSH agent" "$CONFIGURE_SSH_AGENT"
    ui_option_state "Go toolchain" "$INSTALL_GO"
    ui_option_state "Node.js LTS via fnm" "$INSTALL_NODE"
    ui_option_state "Docker CE" "$INSTALL_DOCKER"
    ui_option_state "NVIDIA container toolkit" "$INSTALL_NVIDIA"
    ui_option_state "CUDA toolkit" "$INSTALL_CUDA"
    ui_option_state "Security auto-updates" "$ENABLE_AUTO_UPDATES"
    ui_option_state "Performance tuning" "$PERFORMANCE_TUNING"
    ui_option_state "systemd-journald limits" "$CONFIGURE_JOURNALD"
}

# Interactive menu
show_menu() {
    echo ""
    section "Before You Start"
    warn "Run these checks from Windows PowerShell before provisioning:"
    info "wsl --update"
    info "wsl --set-default-version 2"
    info "Review %USERPROFILE%\\.wslconfig for RAM/CPU limits"

    prompt_yn() {
        local prompt="$1" default_yes="$2"
        TUI_PROMPT_PREFIX="  ${SYMBOL_DOT} " tui_prompt_yn "$prompt" "$default_yes"
    }

    section "Configuration"
    ui_hint "Press Enter to accept the highlighted default."

    # System configuration
    subsection "System"
    prompt_yn "Configure WSL2 (wsl.conf with systemd)" true && CONFIGURE_WSL_CONF=true || CONFIGURE_WSL_CONF=false
    prompt_yn "Update system packages" true && UPDATE_SYSTEM=true || UPDATE_SYSTEM=false
    prompt_yn "Install base utilities (git, neovim, tmux, etc.)" true && INSTALL_BASE_UTILS=true || INSTALL_BASE_UTILS=false
    prompt_yn "Create new user with sudo rights" false && CREATE_USER=true || CREATE_USER=false
    prompt_yn "Configure locales (ru_RU, en_US)" true && CONFIGURE_LOCALES=true || CONFIGURE_LOCALES=false

    # Shell and development
    subsection "Shell and Development"
    prompt_yn "Install Fish + Starship" true && INSTALL_FISH=true || INSTALL_FISH=false
    prompt_yn "Configure ssh-agent" true && CONFIGURE_SSH_AGENT=true || CONFIGURE_SSH_AGENT=false
    prompt_yn "Install Go (latest stable)" true && INSTALL_GO=true || INSTALL_GO=false
    prompt_yn "Install Node.js (LTS via fnm)" true && INSTALL_NODE=true || INSTALL_NODE=false

    # Containerization
    subsection "Containers and GPU"
    prompt_yn "Install Docker CE" true && INSTALL_DOCKER=true || INSTALL_DOCKER=false
    if prompt_yn "Install NVIDIA Container Toolkit + CUDA support" false; then
        INSTALL_NVIDIA=true
        if prompt_yn "  → Install full CUDA Toolkit" true; then
            INSTALL_CUDA=true
        else
            INSTALL_CUDA=false
        fi
    else
        INSTALL_NVIDIA=false
        INSTALL_CUDA=false
    fi

    # System optimization
    subsection "Maintenance"
    prompt_yn "Enable automatic security updates" true && ENABLE_AUTO_UPDATES=true || ENABLE_AUTO_UPDATES=false
    prompt_yn "Apply performance tuning" true && PERFORMANCE_TUNING=true || PERFORMANCE_TUNING=false
    prompt_yn "Configure systemd-journald limits (100MB disk + 50MB RAM)" true && CONFIGURE_JOURNALD=true || CONFIGURE_JOURNALD=false

    echo ""
    show_selected_options
    echo ""
    ui_success_title "${SYMBOL_ROCKET} Starting installation with selected options..."
    echo ""
    sleep 1
}

# Show menu
show_menu

################################################################################
# 3. WSL2 Configuration
################################################################################
section "${SYMBOL_GEAR} WSL2 Configuration"

if $CONFIGURE_WSL_CONF; then
    progress "Creating optimized /etc/wsl.conf..."

    # Backup existing wsl.conf
    if [ -f /etc/wsl.conf ]; then
        cp /etc/wsl.conf "/etc/wsl.conf.backup.$(date +%F)" || true
    fi

    # Create optimized wsl.conf. Do not write an empty [user] default because
    # WSL expects this key to contain a real Linux user name.
    render_wsl_conf "" > /etc/wsl.conf

    WSL_RESTART_REQUIRED=true
    note_post_restart "Run 'wsl --shutdown' in Windows PowerShell so the new /etc/wsl.conf (including systemd) is applied."
    log "WSL2 configuration updated"
    info "After script completion, run 'wsl --shutdown' in Windows to apply changes"
else
    log "Skipping WSL2 configuration"
fi

################################################################################
# 4. System Update and Base Packages
################################################################################
section "${SYMBOL_PACKAGE} System Update & Packages"

if $UPDATE_SYSTEM; then
    progress "Updating system packages..."

    # Enrich APT components
    if ! common_enrich_apt_sources; then
        error "Failed while rewriting APT source files"
        exit 1
    fi

    # Update package lists once, then upgrade
    common_apt_update "system update"
    common_apt_get upgrade -y >/dev/null 2>&1

    log "System updated successfully"
else
    info "Skipping system update"
fi

if $INSTALL_BASE_UTILS; then
    subsection "Base Development Utilities"

    # Optimized package list based on recommendations:
    # - Removed: wget (duplicates curl), make/gcc/g++ (in build-essential)
    # - Removed: iotop, sysstat, net-tools, xdg-user-dirs (not needed in WSL2)
    # - Added: neovim, tmux, ncdu (recommended for development)
    # - System info uses fastfetch -> neofetch -> skip fallback across Debian 12/13
    base_packages=(
        # Network & Downloads
        "curl"                    # HTTP client (kept)

        # Version Control
        "git"                     # Essential

        # Monitoring
        "htop"                    # Process monitor

        # Build Tools
        "build-essential"         # Includes: gcc, g++, make
        "cmake"                   # Build system

        # Python
        "python3"                 # Python interpreter
        "python3-pip"             # Package manager
        "python3-venv"            # Virtual environments

        # Modern Search Tools
        "fzf"                     # Fuzzy finder
        "ripgrep"                 # Fast grep (rg)
        "fd-find"                 # Fast find (fd)

        # File Utilities
        "tree"                    # Directory tree view
        "jq"                      # JSON processor
        "file"                    # File type detection
        "ncdu"                    # Disk usage analyzer (NEW)

        # Archives
        "unzip"                   # ZIP extraction
        "zip"                     # ZIP creation
        "xz-utils"                # XZ compression

        # Security
        "gnupg"                   # GPG encryption
        "ca-certificates"         # SSL certificates

        # System Info
        "lsb-release"             # Distro info
        "bc"                      # Calculator

        # Editors & Terminal (NEW)
        "neovim"                  # Modern text editor
        "tmux"                    # Terminal multiplexer (critical for WSL2!)
    )

    # resolve_fetch_packages runs in a subshell: refresh the index here so the mark survives.
    common_apt_update "base package selection" || true
    while IFS= read -r fetch_pkg; do
        [ -n "$fetch_pkg" ] && base_packages+=("$fetch_pkg")
    done < <(resolve_fetch_packages)

    progress "Installing ${#base_packages[@]} base packages..."
    common_safe_install "${base_packages[@]}" || warn "Some base packages were not installed, continuing"

    # Create symlinks for Debian naming conventions
    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
        ln -sf "$(command -v batcat)" /usr/local/bin/bat 2>/dev/null || true
    fi

    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        ln -sf "$(command -v fdfind)" /usr/local/bin/fd 2>/dev/null || true
    fi

    log "Base utilities configured"
else
    info "Skipping base utilities installation"
fi

################################################################################
# 5. User Creation
################################################################################
section "${SYMBOL_GEAR} User Management"

# Username validation function
validate_username() {
    local username="$1"

    # Empty username
    [[ -z "$username" ]] && return 1

    # Only digits (not allowed by Linux)
    [[ "$username" =~ ^[0-9]+$ ]] && return 2

    # Starts with digit or dash
    [[ "$username" =~ ^[-0-9] ]] && return 3

    # Contains invalid characters (only lowercase, digits, underscore, dash allowed)
    [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && return 4

    # Too long (max 32)
    [[ ${#username} -gt 32 ]] && return 5

    return 0
}

NEW_USER=""
if $CREATE_USER; then
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

    if id "$NEW_USER" &>/dev/null; then
        warn "User $NEW_USER already exists. Skipping creation but will configure..."
        # Offer to change password for existing user
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

        # Ensure user is in sudo group
        if ! groups "$NEW_USER" | grep -q sudo; then
            /usr/sbin/usermod -aG sudo "$NEW_USER"
            log "Added $NEW_USER to sudo group"
        fi
    else
        # Create user
        /usr/sbin/adduser --gecos "" --disabled-password "$NEW_USER" || {
            error "Failed to create user $NEW_USER"
            CREATE_USER=false
        }
        if [ $CREATE_USER = true ]; then
            USER_WAS_CREATED=true
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
    fi

        # Only configure if user was created/configured successfully
        if [ $CREATE_USER = true ]; then
            # Configure passwordless sudo
            if common_safe_write_sudoers "/etc/sudoers.d/$NEW_USER" "$NEW_USER ALL=(ALL) NOPASSWD:ALL"; then
                log "Passwordless sudo configured for $NEW_USER"
            else
                warn "Failed to configure passwordless sudo for $NEW_USER (sudoers write or visudo check failed, is sudo installed?; the previous file, if any, is unchanged)"
            fi

            # Verify user home directory exists
            USER_HOME=$(common_user_home "$NEW_USER" || echo "/home/$NEW_USER")
            if [ ! -d "$USER_HOME" ]; then
                warn "User home directory $USER_HOME does not exist, creating..."
                mkdir -p "$USER_HOME"
                chown -R "$NEW_USER:$NEW_USER" "$USER_HOME"
                chmod 700 "$USER_HOME"
            fi

            # Update wsl.conf with default user
            if $CONFIGURE_WSL_CONF; then
                render_wsl_conf "$NEW_USER" > /etc/wsl.conf
                log "Set $NEW_USER as default user in wsl.conf"
                info "Default user will apply after WSL restart (wsl --shutdown)"
            fi

            # Store for later use
            DOCKER_USER=$NEW_USER
        fi
else
    # On a clean WSL distro, prefer the invoking sudo user. Otherwise fall back to
    # the first regular human account (UID >= 1000). If none exists yet, keep root.
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        DOCKER_USER="$SUDO_USER"
    else
        DOCKER_USER="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd)"
        DOCKER_USER="${DOCKER_USER:-root}"
    fi
    log "Using existing user: $DOCKER_USER"
fi

# If the script lives in /home/<user>/..., return ownership to that Linux user.
# This prevents the script from remaining owned by root/nobody after sudo execution.
restore_linux_home_path_ownership "$SCRIPT_PATH"

################################################################################
# 6. Locale Configuration
################################################################################
section "${SYMBOL_GEAR} System Localization"

if $CONFIGURE_LOCALES; then
    log "Configuring system locales..."

    # Install locales package with availability check
    common_safe_install locales || warn "locales package was not installed, locale generation may fail"

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
            ;;
        2)
            DEFAULT_LOCALE="ru_RU.UTF-8"
            ;;
        3)
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
        *)
            warn "Invalid choice. Using English (en_US.UTF-8) as default"
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
    esac

    # Support both SSH client locales regardless of the selected default language.
    common_generate_utf8_locales /etc/locale.gen
    # Debian 12 uses /etc/default/locale; Debian 13 uses /etc/locale.conf.
    update-locale --reset "LANG=$DEFAULT_LOCALE" "LANGUAGE=${DEFAULT_LOCALE%%.*}"

    # Write to profile for all users (will be sourced on login)
    cat > /etc/profile.d/locale.sh <<EOF
export LANG=$DEFAULT_LOCALE
export LANGUAGE=${DEFAULT_LOCALE%%.*}
EOF

    chmod +x /etc/profile.d/locale.sh

    # Keep C for provisioning; the login profile applies the selected default.
    log "Locale configured: $DEFAULT_LOCALE"
    info "Locale will be fully applied after WSL restart"
else
    log "Skipping locale configuration"
fi

################################################################################
# 7. Fish and Starship Installation
################################################################################
section "${SYMBOL_ROCKET} Fish + Starship Installation"

if $INSTALL_FISH; then
    log "Installing Fish shell and Starship prompt..."

    # Install Fish with availability check
    common_safe_install fish curl || warn "Fish shell prerequisites were not fully installed"

    # Starship: the Debian package (Debian 13) or the pinned release checked by its SHA-256
    if common_install_starship; then
        log "Starship prompt installed"
    else
        warn "Starship could not be installed"
    fi

    setup_fish_for_user() {
        local username=$1
        local user_home
        user_home=$(common_user_home "$username" || echo "/home/$username")

        log "Setting up Fish + Starship for user: $username"
        if common_setup_fish "$username" "$user_home" wsl2; then
            log "Fish + Starship (nerd-font-symbols) configured for $username"
        else
            warn "Fish configuration failed for $username"
        fi
    }

    # Ensure fish is available before setup
    if ! command -v fish >/dev/null 2>&1; then
        error "Fish installation failed - fish binary not found!"
        exit 1
    fi

    # Setup Fish for root
    setup_fish_for_user root

    # Setup Fish for new user if created
    if [ -n "$NEW_USER" ]; then
        setup_fish_for_user "$NEW_USER"
    fi

    # Setup Fish for docker user
    if [ -n "$DOCKER_USER" ] && [ "$DOCKER_USER" != "root" ] && [ "$DOCKER_USER" != "$NEW_USER" ]; then
        setup_fish_for_user "$DOCKER_USER"
    fi

    log "Fish + Starship configuration completed"
else
    log "Skipping Fish installation"
fi

################################################################################
# 7.5. Bash Modernization (Minimal Configuration)
################################################################################
section "${SYMBOL_GEAR} Bash Modernization"

log "Configuring modern Bash setup..."

# Ensure bash-completion is installed
common_safe_install bash-completion || warn "bash-completion was not installed"

setup_bash_for_user() {
    local username=$1
    local user_home
    user_home=$(common_user_home "$username" || echo "/home/$username")

    log "Setting up Bash configuration for $username"
    if common_setup_bashrc "$username" "$user_home" wsl2; then
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

# Setup Bash for docker user if different
if [ -n "$DOCKER_USER" ] && [ "$DOCKER_USER" != "root" ] && [ "$DOCKER_USER" != "$NEW_USER" ]; then
    setup_bash_for_user "$DOCKER_USER"
fi

log "✓ Bash modernization completed"
log "  Features: history (50k lines), smart navigation, bash-completion"
log "  Aliases: Docker, Git, System"
log "  Functions: WSL2 integration, utilities, fnm auto-switching"
if command -v starship >/dev/null 2>&1; then
    log "  Prompt: Starship (same as Fish)"
fi

################################################################################
# 8. Go Installation (pinned release)
################################################################################
if $INSTALL_GO; then
section "${SYMBOL_PACKAGE} Go Installation"

log "Installing Go (pinned release)..."

install_go() {
    local go_version

    # The pinned Go release, checked against its SHA-256 and swapped in only after unpacking
    if ! common_install_go; then
        warn "Go installation failed"
        return 1
    fi
    go_version="$(head -n 1 /usr/local/go/VERSION)"
    go_version="${go_version#go}"

    # Add Go to PATH for all users via profile.d
    cat > /etc/profile.d/golang.sh <<'GOEOF'
export PATH=/usr/local/go/bin:$PATH
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH
GOEOF
    chmod +x /etc/profile.d/golang.sh

    # Also add to Bash configs if they exist
    add_go_to_bashrc() {
        local bashrc_path=$1
        if [ -f "$bashrc_path" ]; then
            if ! grep -q "golang" "$bashrc_path"; then
                cat >> "$bashrc_path" <<'BASHEOF'

# Go environment (install-go-latest)
export PATH=/usr/local/go/bin:$PATH
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH
BASHEOF
                log "Added Go configuration to $bashrc_path"
            fi
        fi
    }

    # Add to root's .bashrc
    add_go_to_bashrc "/root/.bashrc"

    # Add to regular user's .bashrc if exists
    if [ -n "$NEW_USER" ] && $CREATE_USER; then
        user_home=$(common_user_home "$NEW_USER" || echo "/home/$NEW_USER")
        add_go_to_bashrc "$user_home/.bashrc"
    fi

    # Source it for current session
    export PATH=/usr/local/go/bin:$PATH
    export GOPATH=$HOME/go
    export PATH=$GOPATH/bin:$PATH

    log "Go ${go_version} installed successfully"
    /usr/local/go/bin/go version
}

install_go || warn "Go installation failed, continuing..."
else
    log "Skipping Go installation"
fi

################################################################################
# 9. Node.js Installation with fnm
################################################################################
if $INSTALL_NODE; then
section "${SYMBOL_PACKAGE} Node.js Installation (fnm + LTS)"

log "Installing fnm and Node.js LTS..."
# Clean-OS target: do not carry legacy Node manager migration/removal logic here.

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

# Make fnm available in this non-interactive shell
export PATH="$XDG_DATA_HOME/fnm:$PATH"
mkdir -p "$XDG_RUNTIME_DIR"

if ! command -v fnm >/dev/null 2>&1; then
    echo "fnm binary not found in PATH after install"
    exit 1
fi

# Load fnm environment in the current shell
# Use bash here because this installer itself runs via bash

eval "$(fnm env --shell bash)"

# Install latest LTS, activate it, and make it default
fnm install --lts --use
CURRENT_NODE="$(fnm current)"
fnm default "$CURRENT_NODE"

# Enable Corepack for pnpm/yarn where available
if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
fi

# Output versions for verification
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

    chown -R "$username:$username" "$user_home/.local/share/fnm" 2>/dev/null || true
    chown -R "$username:$username" "$user_home/.local/state/fnm-runtime" 2>/dev/null || true
    chown -R "$username:$username" "$user_home/.npm" 2>/dev/null || true
    chown "$username:$username" "$user_home/.bashrc" 2>/dev/null || true

    rm -f "$fnm_install_script"

    log "fnm setup completed for $username"
}

if ensure_fnm_install_dependencies; then
    # Install fnm for root
    install_fnm_for_user "root" || warn "fnm installation for root failed"

    # Install fnm for regular user if created
    if [ -n "${NEW_USER:-}" ] && $CREATE_USER; then
        install_fnm_for_user "$NEW_USER" || warn "fnm installation for $NEW_USER failed"
    fi

    # Install fnm for the active non-root user when different from the users above
    if [ -n "${DOCKER_USER:-}" ] && [ "$DOCKER_USER" != "root" ] && [ "$DOCKER_USER" != "${NEW_USER:-}" ]; then
        install_fnm_for_user "$DOCKER_USER" || warn "fnm installation for $DOCKER_USER failed"
    fi

    log "Node.js and fnm installation completed"
fi
else
    log "Skipping Node.js/fnm installation"
fi

################################################################################
# 10. SSH Agent Configuration
################################################################################
section "${SYMBOL_GEAR} SSH Agent Configuration"

if $CONFIGURE_SSH_AGENT; then
    log "Configuring SSH agent for WSL2..."

    # Install openssh-client with availability check
    common_safe_install openssh-client || warn "openssh-client was not installed"

    if has_user_systemd; then
        log "Enabling ssh-agent.socket via systemd..."
        systemctl --user enable --now ssh-agent.socket || warn "Failed to enable ssh-agent.socket"
    else
        log "Configuring ssh-agent via profile..."

        # write literal $USER for runtime expansion in user shell
        # shellcheck disable=SC2016
        PROFILE_SNIPPET='# WSL2: автозапуск ssh-agent (без systemd)
if ! pgrep -u "$USER" ssh-agent >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" >/dev/null
fi
'

        for f in "/home/$DOCKER_USER/.bash_profile" "/home/$DOCKER_USER/.profile" "/home/$DOCKER_USER/.zprofile"; do
            [ -f "$f" ] || touch "$f"
            if ! grep -F "WSL2: автозапуск ssh-agent" "$f" >/dev/null 2>&1; then
                printf "%b\n" "$PROFILE_SNIPPET" >>"$f"
                log "Added ssh-agent autostart to ${f##*/}"
            fi
        done
    fi

    log "SSH agent configuration completed"
else
    log "Skipping SSH agent configuration"
fi

################################################################################
# 11. Docker Installation
################################################################################
section "${SYMBOL_PACKAGE} Docker Installation"

if $INSTALL_DOCKER; then
    log "Installing Docker Engine from the official Docker APT repository..."

    # Remove old/conflicting Docker packages per official docs
    common_apt_get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

    common_safe_install ca-certificates curl gnupg || warn "Docker repository prerequisites were not fully installed"

    install -m 0755 -d /etc/apt/keyrings
    # Docker's GPG key, accepted only with its pinned fingerprint
    if ! common_install_apt_key docker /etc/apt/keyrings/docker.asc; then
        error "The Docker APT key could not be installed"
        exit 1
    fi
    DOCKER_ARCH="$(dpkg --print-architecture)"

    common_render_docker_debian_source "$ID" "$VERSION_CODENAME" "$DOCKER_ARCH" "/etc/apt/keyrings/docker.asc" > /etc/apt/sources.list.d/docker.sources

    common_apt_sources_changed
    common_apt_update "Docker repository refresh"

    docker_packages=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-buildx-plugin"
        "docker-compose-plugin"
    )
    common_safe_install "${docker_packages[@]}" || warn "Some Docker packages were not installed"

    if ! command -v docker >/dev/null 2>&1; then
        error "Docker installation failed - docker binary not found"
        exit 1
    fi

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "features": {
    "buildkit": true
  }
}
EOF

    if service_actions_available; then
        systemctl enable --now docker || {
            error "Failed to enable/start docker.service"
            exit 1
        }
        log "Docker service enabled and started"
    else
        note_post_restart "After restarting WSL, start Docker with 'sudo systemctl enable --now docker' if it is not already running."
        warn "systemd is not active in the current session yet. Docker will be started after WSL restarts with systemd enabled."
    fi

    groupadd -f docker
    if [ -n "$DOCKER_USER" ] && [ "$DOCKER_USER" != "root" ]; then
        usermod -aG docker "$DOCKER_USER"
        log "User $DOCKER_USER added to docker group"
    fi

    DOCKER_VERSION=$(docker --version 2>/dev/null || echo "Not available")
    COMPOSE_VERSION=$(docker compose version 2>/dev/null || echo "Not available")
    log "Docker installed: $DOCKER_VERSION"
    log "Docker Compose: $COMPOSE_VERSION"
else
    log "Skipping Docker installation"
fi

################################################################################
# 12. NVIDIA Container Toolkit and CUDA
################################################################################
section "${SYMBOL_GEAR} NVIDIA Support Installation"

if $INSTALL_NVIDIA; then
    log "Installing NVIDIA Container Toolkit..."

    # Check GPU status
    gpu_status_wsl() {
        local ok_flag=0
        echo "Checking GPU/WSL status:"
        if [ -e /dev/dxg ]; then
            echo " - /dev/dxg: OK (WSL GPU available)"
        else
            echo " - /dev/dxg: Missing (GPU not available in WSL)"
            ok_flag=1
        fi
        if command -v nvidia-smi >/dev/null 2>&1; then
            echo " - nvidia-smi: found"
            nvidia-smi -L || true
        else
            echo " - nvidia-smi: not found in Linux environment"
            ok_flag=1
        fi

        if [ $ok_flag -ne 0 ]; then
            warn "GPU may not be available. Installation will continue but may not work properly."
            warn "Tips:"
            warn " - Install latest NVIDIA driver with WSL support"
            warn " - Enable GPU support for your WSL distribution"
            warn " - Run 'wsl --shutdown' after driver update"
        fi
        return $ok_flag
    }

    gpu_status_wsl || true

    # Install NVIDIA Container Toolkit
    install -m 0755 -d /usr/share/keyrings
    # The repository is added only with its key accepted by the pinned fingerprint; otherwise
    # the toolkit package stays unavailable and its installation is skipped below.
    if common_install_apt_key nvidia-container-toolkit /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
        ARCH="$(dpkg --print-architecture)"
        echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/${ARCH}/ /" | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    else
        warn "The NVIDIA Container Toolkit key could not be installed; its repository is not added"
    fi

    common_apt_sources_changed
    if common_apt_update "NVIDIA Container Toolkit repository refresh"; then
        common_safe_install nvidia-container-toolkit || warn "NVIDIA Container Toolkit was not installed"
    else
        warn "Failed to refresh APT after adding the NVIDIA Container Toolkit repository"
        warn "Skipping NVIDIA Container Toolkit package installation until APT is healthy"
    fi

    # Configure NVIDIA runtime - only if Docker is installed
    if command -v nvidia-ctk >/dev/null 2>&1; then
        if command -v docker >/dev/null 2>&1; then
            # Ensure Docker directory exists
            mkdir -p /etc/docker

            # Stop Docker before configuration if running
            if service_actions_available; then
                systemctl stop docker 2>/dev/null || true
                sleep 2
            fi

            # Ensure Docker daemon.json is valid JSON (nvidia-ctk needs valid JSON to modify)
            if [ ! -f /etc/docker/daemon.json ]; then
                log "Creating empty Docker daemon.json..."
                echo '{}' > /etc/docker/daemon.json
            fi

            # Validate daemon.json before modifying
            if ! grep -q '{' /etc/docker/daemon.json 2>/dev/null; then
                log "Repairing invalid daemon.json..."
                echo '{}' > /etc/docker/daemon.json
            fi

            # Configure NVIDIA runtime using nvidia-ctk (idempotent, safe to run multiple times)
            log "Configuring NVIDIA Container Runtime..."
            nvidia-ctk runtime configure --runtime=docker 2>&1 | tee -a "$LOG_FILE" | grep -v "^INFO" || {
                warn "nvidia-ctk configuration completed with status: $?"
            }

            # Reload and restart Docker
            if service_actions_available; then
                log "Reloading systemd daemon..."
                systemctl daemon-reload 2>/dev/null || true
                sleep 1

                log "Starting Docker service..."
                systemctl start docker 2>/dev/null || true
                sleep 2

                # Check Docker status with retries
                retry_count=0
                max_retries=3
                while [ $retry_count -lt $max_retries ]; do
                    if systemctl is-active docker >/dev/null 2>&1; then
                        log "NVIDIA Container Toolkit configured successfully"
                        break
                    fi
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        warn "Docker not ready yet, waiting... ($retry_count/$max_retries)"
                        sleep 2
                    fi
                done

                if [ $retry_count -eq $max_retries ]; then
                    warn "Docker service may not be running - this is not critical for NVIDIA toolkit"
                    info "You can manually restart Docker with: sudo systemctl restart docker"
                fi
            else
                note_post_restart "If you enabled NVIDIA Container Toolkit, restart WSL first, then run 'sudo systemctl restart docker' before testing GPU containers."
                warn "systemd not available in the current session - Docker restart deferred until after WSL restart"
            fi
        else
            warn "Docker not installed - skipping NVIDIA runtime configuration"
            warn "Install Docker first, then run: sudo nvidia-ctk runtime configure --runtime=docker"
        fi
    else
        warn "nvidia-ctk not found - installation may have failed"
    fi

    # Install CUDA Toolkit if requested
    if $INSTALL_CUDA; then
        log "Installing CUDA Toolkit..."

        # Add CUDA repository (Official NVIDIA method for Debian 12/13)
        log "Configuring CUDA repository for Debian ${VERSION_ID} (${VERSION_CODENAME})..."

        CUDA_DISTRO=$(resolve_cuda_distro "$VERSION_ID") || {
            error "Unsupported CUDA Debian release: ${VERSION_ID:-unknown}"
            exit 1
        }
        CUDA_ARCH="x86_64"  # NVIDIA uses x86_64 in repository paths, not amd64!
        CUDA_REPO_PATH="${CUDA_DISTRO}/x86_64"

        log "CUDA repository: $CUDA_DISTRO/$CUDA_ARCH"

        # Enable contrib repository (required for Debian)
        log "Enabling contrib repository (required for Debian)..."
        if ! grep -qE "^deb .* contrib|^\s*Components:.*\bcontrib\b" /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
            if command -v add-apt-repository >/dev/null 2>&1; then
                add-apt-repository contrib -y 2>&1 | tee -a "$LOG_FILE" || {
                    warn "add-apt-repository failed, trying alternative method..."
                    sed -i 's/ main$/ main contrib/' /etc/apt/sources.list 2>/dev/null || true
                    sed -i 's/ main / main contrib /' /etc/apt/sources.list 2>/dev/null || true
                    for f in /etc/apt/sources.list.d/*.sources; do
                        [ -e "$f" ] && sed -i -E '/^\s*Components:\s*/ { /contrib/! s/$/ contrib/ }' "$f"
                    done
                }
            else
                sed -i 's/ main$/ main contrib/' /etc/apt/sources.list 2>/dev/null || true
                sed -i 's/ main / main contrib /' /etc/apt/sources.list 2>/dev/null || true
                for f in /etc/apt/sources.list.d/*.sources; do
                    [ -e "$f" ] && sed -i -E '/^\s*Components:\s*/ { /contrib/! s/$/ contrib/ }' "$f"
                done
            fi
            common_apt_sources_changed
            log "✓ contrib repository enabled"
        else
            log "✓ contrib repository already enabled"
        fi

        # The cuda-keyring package pinned by its SHA-256 for this Debian release
        download_success=false
        CUDA_KEYRING_DIR=""
        if common_temp_dir CUDA_KEYRING_DIR; then
            CUDA_KEYRING_PATH="$CUDA_KEYRING_DIR/cuda-keyring.deb"
            log "Downloading the pinned CUDA keyring package for ${CUDA_DISTRO}..."
            if common_fetch_pinned "cuda-keyring-${CUDA_DISTRO}" "$CUDA_KEYRING_PATH"; then
                download_success=true
            fi
        fi

        if [[ "$download_success" == "true" ]]; then
            log "Installing CUDA keyring package..."
            if dpkg -i "$CUDA_KEYRING_PATH" 2>&1 | tee -a "$LOG_FILE"; then
                log "✓ CUDA keyring installed successfully"
                rm -rf "$CUDA_KEYRING_DIR"

                log "Updating APT repository cache..."
                common_apt_sources_changed
                if common_apt_update "CUDA repository refresh"; then
                    log "✓ APT cache updated successfully"
                else
                    warn "Failed to update package list after adding CUDA repository"
                    INSTALL_CUDA=false
                fi
            else
                error "Failed to install CUDA keyring package (dpkg returned $?)"
                rm -rf "$CUDA_KEYRING_DIR"
                warn "CUDA installation will be skipped"
                INSTALL_CUDA=false
            fi
        else
            [ -z "$CUDA_KEYRING_DIR" ] || rm -rf "$CUDA_KEYRING_DIR"
            error "Could not get the pinned CUDA keyring package for ${CUDA_DISTRO} (see the message above)"
            warn "If it was a download error, please check:"
            warn "  1. Internet connection"
            warn "  2. Repository availability"
            warn "  3. DNS resolution"
            warn "CUDA installation will be skipped"
            INSTALL_CUDA=false
        fi

        # Install CUDA packages (only if keyring installation succeeded)
        if $INSTALL_CUDA; then
            # In WSL, install a toolkit-only metapackage. The broad "cuda"
            # metapackage can pull Linux driver packages that are not wanted in WSL.
            if CUDA_TOOLKIT_PACKAGE=$(resolve_cuda_toolkit_package); then
                log "Found CUDA toolkit metapackage: $CUDA_TOOLKIT_PACKAGE"
                if common_safe_install "$CUDA_TOOLKIT_PACKAGE"; then
                    log "CUDA toolkit package installed: $CUDA_TOOLKIT_PACKAGE"
                else
                    warn "CUDA toolkit installation failed: $CUDA_TOOLKIT_PACKAGE"
                    INSTALL_CUDA=false
                fi
            else
                warn "No CUDA toolkit metapackage available in APT cache"
                log "Repository: https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO_PATH}/"
                log "Try running: apt-cache policy cuda-toolkit cuda-toolkit-13 cuda-toolkit-13-2"
                INSTALL_CUDA=false
            fi
        fi  # End of: if $INSTALL_CUDA (package installation check)
    fi  # End of: if $INSTALL_CUDA

    # Configure CUDA environment variables (MOVED OUTSIDE if $INSTALL_CUDA)
    # This runs regardless of whether we just installed CUDA or it was already installed
    if [ -d "/usr/local/cuda" ]; then
        log "Configuring CUDA environment variables..."

        # Create system-wide CUDA environment file
        cat > /etc/profile.d/cuda.sh <<'CUDAEOF'
# CUDA Toolkit Environment
# Automatically configured by WSL2 optimization script
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
export CUDA_HOME=/usr/local/cuda
CUDAEOF
        chmod +x /etc/profile.d/cuda.sh
        log "✓ Created /etc/profile.d/cuda.sh"

        # Function to add CUDA to user's .bashrc
        add_cuda_to_bashrc() {
            local bashrc_path=$1
            if [ -f "$bashrc_path" ]; then
                if ! grep -q "cuda/bin" "$bashrc_path"; then
                    cat >> "$bashrc_path" <<'BASHCUDA'

# CUDA Toolkit environment
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
export CUDA_HOME=/usr/local/cuda
BASHCUDA
                    log "✓ Added CUDA configuration to $bashrc_path"
                fi
            fi
        }

        # Add to root's .bashrc
        add_cuda_to_bashrc "/root/.bashrc"

        # Add to regular user's .bashrc if exists
        if [ -n "$NEW_USER" ] && [ "$NEW_USER" != "root" ]; then
            user_home=$(common_user_home "$NEW_USER" || echo "/home/$NEW_USER")
            add_cuda_to_bashrc "$user_home/.bashrc"
        fi

        # Add to docker user's .bashrc if different
        if [ -n "$DOCKER_USER" ] && [ "$DOCKER_USER" != "root" ] && [ "$DOCKER_USER" != "$NEW_USER" ]; then
            user_home=$(common_user_home "$DOCKER_USER" || echo "/home/$DOCKER_USER")
            add_cuda_to_bashrc "$user_home/.bashrc"
        fi

        # Verify CUDA installation
        if [ -f "/usr/local/cuda/bin/nvcc" ]; then
            CUDA_VERSION=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | grep "release" | awk '{print $5}' | sed 's/,//')
            log "✓ CUDA Compiler (nvcc) installed: version $CUDA_VERSION"
            log "✓ CUDA installation successful!"
            info "Run 'source /etc/profile.d/cuda.sh' or start a new terminal to use CUDA"
        else
            warn "CUDA compiler (nvcc) not found in /usr/local/cuda/bin"
            info "CUDA may not be fully installed. Check with: apt list --installed | grep cuda"
        fi
    else
        if $INSTALL_CUDA; then
            warn "/usr/local/cuda directory not found after installation"
            warn "CUDA packages may have been installed but symlink not created"
            info "Check available CUDA versions: ls -la /usr/local/ | grep cuda"
        fi
    fi

else
    log "Skipping NVIDIA installation"
fi

################################################################################
# 13. Performance Tuning
################################################################################
section "${SYMBOL_ROCKET} Performance Tuning"

if $PERFORMANCE_TUNING; then
    log "Applying performance optimizations..."

    # System limits (optimized for 32GB RAM and ML/AI)
    cat > /etc/security/limits.d/99-wsl2-limits.conf <<EOF
# WSL2 Performance Limits - High Performance (32GB RAM)

# Open file limits (for large projects and datasets)
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288

# Process limits (for parallel ML/AI training)
* soft nproc 131072
* hard nproc 131072
root soft nproc 131072
root hard nproc 131072

# Memory lock (for CUDA and GPU memory pinning)
* soft memlock unlimited
* hard memlock unlimited

# Core dump size (for debugging)
* soft core unlimited
* hard core unlimited

EOF

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

    # Kernel parameters for WSL2 (High Performance: 32GB RAM, i7-13700K, RTX 4090)
    cat > /etc/sysctl.d/99-wsl2-optimization.conf <<EOF
# WSL2 Optimization - High Performance (32GB RAM, i7-13700K, RTX 4090)
# Optimized for ML/AI workloads, development, and GPU computing

# ============================================================================
# Network Performance - Maximum buffers for 32GB RAM
# ============================================================================

# TCP/UDP Buffer Sizes (aggressive for 32GB RAM)
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 524288 67108864
net.ipv4.tcp_wmem = 4096 524288 67108864

# Network Queues (high throughput)
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 32768

# TCP Performance
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# TCP Window Scaling & SACK
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# MTU Probing
net.ipv4.tcp_mtu_probing = 1

# TCP Orphan & TIME_WAIT limits
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_max_tw_buckets = 262144

# ============================================================================
# Virtual Memory - Aggressive caching for 32GB RAM
# ============================================================================
vm.swappiness = 1
vm.vfs_cache_pressure = 40
vm.dirty_ratio = 30
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 6000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes = 262144
vm.overcommit_memory = 1
vm.overcommit_ratio = 80
vm.zone_reclaim_mode = 0

# Memory mapping (for large datasets and ML models)
vm.max_map_count = 262144

# ============================================================================
# File System Performance (for large datasets)
# ============================================================================
fs.file-max = 4194304
fs.inotify.max_user_watches = 2097152
fs.inotify.max_user_instances = 2048

# ============================================================================
# Shared Memory (for CUDA and multi-process ML/AI)
# ============================================================================
kernel.shmmax = 68719476736
kernel.shmall = 16777216

# ============================================================================
# Kernel Performance (ML/AI workloads)
# ============================================================================
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.pid_max = 131072
kernel.threads-max = 131072

# Entropy (for cryptography)
kernel.random.write_wakeup_threshold = 1024

# ============================================================================
# Security
# ============================================================================
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
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF

    # Enable Transparent Huge Pages for ML/AI (if available)
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        log "Enabling Transparent Huge Pages for ML/AI workloads..."
        echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo defer > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    fi

    # Apply sysctl settings with error tolerance for missing parameters
    # Some parameters may not exist in WSL2 environment
    sysctl -e -p /etc/sysctl.d/99-wsl2-optimization.conf 2>&1 | grep -v "cannot stat" | grep -v "No such file or directory" || true
    log "Kernel parameters applied (some may be skipped in WSL2 environment)"

    # I/O scheduler optimization (for high-performance NVMe)
    cat > /etc/udev/rules.d/60-ioschedulers.conf <<'EOF'
# I/O Scheduler Optimization for WSL2 (High Performance)

# NVMe drives - use 'none' scheduler (best for high-end NVMe)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/nr_requests}="2048"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rq_affinity}="2"

# SSD drives - use 'mq-deadline' scheduler
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"
EOF

    log "Performance tuning applied"
else
    log "Skipping performance tuning"
fi

################################################################################
# 14. Automatic Security Updates
################################################################################
section "${SYMBOL_GEAR} Automatic Security Updates"

if $ENABLE_AUTO_UPDATES; then
    log "Configuring automatic security updates..."

    # Install unattended-upgrades with availability check
    common_safe_install unattended-upgrades apt-listchanges || warn "Automatic update packages were not installed"

    common_render_debian_unattended_upgrades_conf > /etc/apt/apt.conf.d/50unattended-upgrades
    common_render_apt_periodic_auto_upgrades_conf > /etc/apt/apt.conf.d/20auto-upgrades

    log "Automatic security updates configured"
else
    log "Skipping automatic security updates"
fi

################################################################################
# 15. Create Utility Scripts
################################################################################
section "${SYMBOL_GEAR} Creating Utility Scripts"

# WSL2 Performance Monitor
cat > /usr/local/bin/wsl2-monitor.sh <<'SCRIPT'
#!/bin/bash

echo "=== WSL2 System Monitor ==="
echo ""
echo "=== System Information ==="
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""

echo "=== CPU Usage ==="
top -bn1 | head -n 5

echo ""
echo "=== Memory Usage ==="
free -h

echo ""
echo "=== Disk Usage ==="
df -h | grep -v tmpfs

echo ""
echo "=== WSL2 Specific ==="
# Try to get WSL version from wsl.exe (available from Windows side)
WSL_VERSION=$(wsl.exe --version 2>/dev/null | grep -o "WSL: [0-9.]*" | cut -d: -f2 | xargs)

# If wsl.exe not available, try to get WSL kernel version from /proc/version
if [ -z "$WSL_VERSION" ]; then
    KERNEL_VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/version 2>/dev/null | head -1)
    if [ -n "$KERNEL_VERSION" ]; then
        echo "WSL Version: $KERNEL_VERSION (kernel)"
    else
        echo "WSL Version: Unknown (run from Windows PowerShell: wsl --version)"
    fi
else
    echo "WSL Version: $WSL_VERSION"
fi
echo "GPU Support: $([ -e /dev/dxg ] && echo 'Available' || echo 'Not Available')"
if command -v nvidia-smi >/dev/null 2>&1; then
    NVIDIA_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$NVIDIA_VERSION" ]; then
        echo "NVIDIA Driver: $NVIDIA_VERSION"
    fi
fi

echo ""
echo "=== Top 5 Processes by Memory ==="
ps aux --sort=-%mem | head -6

echo ""
echo "=== Top 5 Processes by CPU ==="
ps aux --sort=-%cpu | head -6
SCRIPT

chmod +x /usr/local/bin/wsl2-monitor.sh

# WSL2 Cleanup Script
cat > /usr/local/bin/wsl2-cleanup.sh <<'SCRIPT'
#!/bin/bash

echo "Starting WSL2 cleanup..."

# Clean package cache
apt-get clean
apt-get autoclean
apt-get -o DPkg::Lock::Timeout=300 autoremove -y

# Clean journal logs
journalctl --vacuum-time=7d

# Clean temp files
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

# Clean Docker if installed
if command -v docker >/dev/null 2>&1; then
    docker system prune -f
fi

# Clear package lists to save space
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

echo "WSL2 cleanup completed!"
SCRIPT

chmod +x /usr/local/bin/wsl2-cleanup.sh

# WSL2 Backup Script
cat > /usr/local/bin/wsl2-backup.sh <<'SCRIPT'
#!/bin/bash

BACKUP_DIR="/mnt/c/WSL-Backups/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

echo "Creating WSL2 backup to $BACKUP_DIR"

# Backup configuration files
cp /etc/wsl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/docker/daemon.json "$BACKUP_DIR/" 2>/dev/null || true

# Backup user configurations
if [ -n "$1" ]; then
    USER_HOME="/home/$1"
    if [ -d "$USER_HOME" ]; then
        tar -czf "$BACKUP_DIR/home-$1-$(date +%H%M%S).tar.gz" -C "$(dirname "$USER_HOME")" "$(basename "$USER_HOME")"
    fi
fi

echo "Backup completed: $BACKUP_DIR"
SCRIPT

chmod +x /usr/local/bin/wsl2-backup.sh

# Create weekly cron job for cleanup
cat > /etc/cron.weekly/wsl2-cleanup <<'EOF'
#!/bin/bash
/usr/local/bin/wsl2-cleanup.sh >> /var/log/wsl2-cleanup.log 2>&1
EOF

chmod +x /etc/cron.weekly/wsl2-cleanup

log "Utility scripts created"


################################################################################
# 16. Configure systemd-journald
################################################################################

section "${SYMBOL_GEAR} systemd-journald Configuration"

if $CONFIGURE_JOURNALD; then
    if has_systemd; then
        log "Configuring systemd-journald for WSL2..."

        mkdir -p /etc/systemd/journald.conf.d

        cat > /etc/systemd/journald.conf.d/00-wsl2.conf <<'JOURNALD_EOF'
[Journal]
SystemMaxUse=100M
SystemKeepFree=500M
SystemMaxFileSize=10M
SystemMaxFiles=10
RuntimeMaxUse=50M
RuntimeKeepFree=100M
RuntimeMaxFileSize=10M
RuntimeMaxFiles=5
MaxRetentionSec=1week
MaxFileSec=1day
Compress=yes
ForwardToSyslog=no
ForwardToWall=no
SyncIntervalSec=5m
JOURNALD_EOF

        if service_actions_available; then
            systemctl restart systemd-journald 2>&1 | tee -a "$LOG_FILE" || warn "Failed to restart journald"
        else
            note_post_restart "systemd-journald limits were written; they will be applied after the next WSL restart."
        fi
        journalctl --vacuum-size=100M --vacuum-time=1week 2>&1 | tee -a "$LOG_FILE" || true

        journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP 'Archived and active journals take up \K[^.]+' || echo "unknown")
        log "✓ systemd-journald configured"
        info "  Max: 100MB disk + 50MB RAM, Current: $journal_size"
    else
        warn "systemd not available"
    fi
else
    log "Skipping systemd-journald configuration"
fi

################################################################################
# 17. Final Cleanup
################################################################################
section "${SYMBOL_GEAR} Final Cleanup"

progress "Performing final cleanup..."

# Clean package cache silently
apt-get clean >/dev/null 2>&1
apt-get autoclean >/dev/null 2>&1
common_apt_get autoremove -y >/dev/null 2>&1

# Clear journal logs silently
journalctl --vacuum-time=3d >/dev/null 2>&1

log "Cleanup completed"

################################################################################
# 17. Final Summary and Instructions
################################################################################
section "${SYMBOL_CHECK} Installation Complete"

echo ""
ui_success_title "${SYMBOL_CHECK} WSL2 optimization complete"
subsection "Summary of optimizations"
log "OS detected: $OS_NAME $OS_VERSION ($OS_CODENAME)"

if $CONFIGURE_WSL_CONF; then
    log "WSL2 configuration (wsl.conf) with systemd"
fi

if $UPDATE_SYSTEM; then
    log "System packages updated"
fi

if $INSTALL_BASE_UTILS; then
    log "Base utilities installed (neovim, tmux, ncdu, etc.)"
fi

if [ -n "$NEW_USER" ]; then
    if $USER_WAS_CREATED; then
        log "New user created: $NEW_USER (with sudo access)"
    elif $CREATE_USER; then
        log "Existing user configured: $NEW_USER (with sudo access)"
    fi
fi

if $CONFIGURE_LOCALES; then
    log "Locale configured: ${DEFAULT_LOCALE:-en_US.UTF-8}"
fi

if $INSTALL_FISH; then
    log "Fish + Starship installed with WSL2 optimizations"
fi

log "Bash modernized with optimizations"

if $INSTALL_DOCKER; then
    log "Docker CE + Docker Compose installed"
fi

if $INSTALL_NVIDIA; then
    log "NVIDIA Container Toolkit installed"
    if $INSTALL_CUDA; then
        log "CUDA Toolkit installed"
    fi
fi

if $PERFORMANCE_TUNING; then
    log "Performance tuning applied"
fi

if $ENABLE_AUTO_UPDATES; then
    log "Automatic security updates enabled"
fi

echo ""
subsection "Created utility scripts"
info "wsl2-monitor.sh   - WSL2 system monitoring"
info "wsl2-cleanup.sh   - System cleanup (runs weekly)"
info "wsl2-backup.sh    - Backup configuration"

echo ""
subsection "Important next steps"

if [ -n "$NEW_USER" ] && $CREATE_USER; then
    warn "Run 'wsl --shutdown' in Windows PowerShell to apply default user"
    info "After restart: you will login as $NEW_USER"
    echo ""
fi

if $CONFIGURE_WSL_CONF; then
    warn "Run 'wsl --shutdown' in Windows PowerShell to apply WSL2 configuration"
fi

if $INSTALL_FISH; then
    echo ""
    info "New interactive shell sessions will start with Fish + Starship"
    info "WSL2 functions: explorer(), cmd(), powershell(), wslperf()"
fi

if $INSTALL_DOCKER && [ -n "$DOCKER_USER" ]; then
    echo ""
    info "Docker group: relogin or run 'newgrp docker'"
fi

if [ ${#POST_RESTART_NOTES[@]} -gt 0 ]; then
    echo ""
    subsection "After-restart checklist"
    for note in "${POST_RESTART_NOTES[@]}"; do
        info "$note"
    done
fi

echo ""
subsection "WSL2 performance tips"
info "Create %USERPROFILE%\\.wslconfig in Windows:"
echo -e "    ${DIM}[wsl2]${NC}"
echo -e "    ${DIM}memory=8GB${NC}"
echo -e "    ${DIM}processors=4${NC}"
echo -e "    ${DIM}autoMemoryReclaim=dropCache${NC}"
echo -e "    ${DIM}sparseVhd=true${NC}"
echo ""
info "Run 'wsl2-monitor.sh' for system performance monitoring"
info "Run 'wsl2-cleanup.sh' for periodic maintenance"
echo ""

ui_success_title "${SYMBOL_ROCKET} WSL2 optimization successfully completed"
echo ""

# Show system information if available
FETCH_CMD=$(resolve_fetch_command || true)
if [ -n "$FETCH_CMD" ]; then
    "$FETCH_CMD"
else
    info "System info tool not installed (fastfetch/neofetch unavailable for this release)"
fi
}

if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" == "1" ]]; then
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    fi
    exit 0
fi
optimize_main "$@"

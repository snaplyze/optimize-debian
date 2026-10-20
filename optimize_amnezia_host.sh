#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_VERSION="0.3.0"
LOG_FILE="/var/log/amnezia_host_optimization.log"
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
TARGET_USER=""
ADDUSER_BIN="/usr/sbin/adduser"
SSH_HARDENING_DROPIN="/etc/ssh/sshd_config.d/99-amnezia-host-hardening.conf"
UFW_DEFAULTS_FILE="/etc/default/ufw"
SYSCTL_CONF_FILE="/etc/sysctl.d/99-amnezia-host.conf"
MODULES_LOAD_FILE="/etc/modules-load.d/99-amnezia-host.conf"
LIMITS_CONF_FILE="/etc/security/limits.d/99-amnezia-limits.conf"
SWAPFILE_PATH="/swapfile"
FSTAB_FILE="/etc/fstab"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCES_FILE="/etc/apt/sources.list.d/docker.sources"
BACKPORTS_SOURCES_FILE="/etc/apt/sources.list.d/debian-backports.sources"
ROOT_HOME="/root"
SSH_PORT_RULE_ADDED=false
INSTALL_DOCKER=true
INSTALL_FISH=true
INSTALL_KERNEL_BACKPORTS=false
FIREWALL_PHASE="bootstrap"
ASSUME_YES=false

CREATE_USER=false
SKIP_SWAP=false
SWAP_SIZE_GB=2
SSH_PUBLIC_KEY=""
SSH_PUBLIC_KEY_FILE=""
SSH_PORT=22
XRAY_PORT=443
AMNEZIAWG_PORT=8443

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SYMBOL_WARN="⚠"
SYMBOL_INFO="ℹ"

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
        printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

ui_clean_heading() {
    local text="$*"
    local marker

    for marker in \
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
    printf '\n%b+ %s%b\n' "$BLUE$BOLD" "$text" "$NC"
}

ui_message() {
    local color="$1"
    local label="$2"
    local message="$3"

    printf '  %b%-7s%b %s\n' "$color" "[$label]" "$NC" "$message"
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
    ui_message "$RED" "error" "$1" >&2
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
    ui_title "$title"
    log_silent "========== $title =========="
}

usage() {
    cat <<USAGE
Usage: sudo ./optimize_amnezia_host.sh [options]

Version: ${SCRIPT_VERSION}

Minimal Debian 12/13 host baseline for AmneziaVPN self-hosted deployment via the Amnezia app.
The script prepares the host only; it does not install AmneziaWG, XRay, or any other protocol containers.

Options:
  --user <name>               Existing sudo-capable user to keep as the operator
                              (default: the invoking sudo user, SUDO_USER; required when run as root without sudo)
  --create-user               Create the target user when it does not already exist
  --ssh-public-key <key>      Public key to add when creating a user without an invoking sudo-user key source
  --ssh-public-key-file <p>   File with one or more public keys to merge into the created user's authorized_keys
  --ssh-port <port>           SSH service port to configure and allow in firewall (default: 22)
  --xray-port <port>          XRay target port to allow in firewall (default: 443)
  --amneziawg-port <port>     AmneziaWG target port to allow in firewall (default: 8443)
  --swap-size-gb <size>       Create and enable a /swapfile of the given size in GiB (default: 2)
  --skip-swap                 Do not create a swapfile automatically
  --skip-docker               Do not install Docker CE; leave Docker installation to the Amnezia app
  --skip-fish                 Do not install Fish shell and Starship prompt
  --kernel-backports          Install latest Linux kernel & headers from Debian Backports (Debian 12)
  --firewall-phase <phase>    Firewall profile to apply: bootstrap | locked (default: bootstrap)
  --yes                       Run non-interactively with the selected options
  --help                      Show this help and exit

Firewall phases:
  bootstrap  Open SSH, 443/tcp, and temporary all-UDP ingress to avoid blocking first-time
             AmneziaWG installation before the app pins a final port.
  locked     Open SSH, 443/tcp, and 8443/udp only after AmneziaWG has been pinned to 8443/udp.

SSH access:
  SSH hardening restricts login to the target user (AllowUsers) and disables root login.
  Make sure the target user is the account you log in with, or has working SSH keys.

User creation notes:
  When --create-user is used, the script prefers authorized_keys from the invoking sudo user
  (SUDO_USER). If that source is unavailable, pass --ssh-public-key or --ssh-public-key-file.
USAGE
}

is_supported_debian_version() {
    common_is_supported_debian_version "${1:-}"
}

require_supported_debian_release() {
    if [ "${ID:-}" != "debian" ]; then
        error "This script supports Debian only"
        exit 1
    fi

    if ! is_supported_debian_version "$VERSION_ID"; then
        error "Unsupported Debian version: ${VERSION_ID}. Only Debian 12 and 13 are supported."
        exit 1
    fi
}

systemd_system_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

timedatectl_available() {
    command -v timedatectl >/dev/null 2>&1
}

system_clock_synchronized() {
    timedatectl_available && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi '^yes$'
}

service_unit_exists() {
    systemctl list-unit-files "$1" >/dev/null 2>&1
}

service_unit_active() {
    systemctl is-active "$1" >/dev/null 2>&1
}

service_unit_enable_now() {
    systemctl enable --now "$1" >/dev/null 2>&1
}

service_unit_start() {
    systemctl start "$1" >/dev/null 2>&1
}

detect_time_sync_service() {
    local unit

    for unit in ntpsec.service ntp.service chrony.service chronyd.service systemd-timesyncd.service; do
        if service_unit_exists "$unit" && service_unit_active "$unit"; then
            printf '%s\n' "$unit"
            return 0
        fi
    done

    return 1
}

ensure_time_sync_service() {
    local detected_service=""

    if ! systemd_system_available; then
        warn "systemd is not available; skipping time sync service checks"
        return 0
    fi

    if detected_service=$(detect_time_sync_service); then
        TIME_SYNC_SERVICE_NAME="$detected_service"
        log "Keeping existing time sync service: ${TIME_SYNC_SERVICE_NAME}"
        return 0
    fi

    warn "No active time sync service detected"

    if common_package_available systemd-timesyncd; then
        common_safe_install systemd-timesyncd || warn "Failed to install systemd-timesyncd"
        if service_unit_enable_now systemd-timesyncd.service; then
            TIME_SYNC_SERVICE_NAME="systemd-timesyncd.service"
            log "Enabled fallback time sync service: ${TIME_SYNC_SERVICE_NAME}"
            return 0
        fi
    fi

    warn "Could not enable a fallback time sync service automatically"
    return 1
}

validate_firewall_phase() {
    case "$1" in
        bootstrap|locked)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

firewall_udp_rule_for_phase() {
    case "$1" in
        bootstrap)
            printf '%s\n' 'all-udp-temporary'
            ;;
        locked)
            printf '%s/udp\n' "$AMNEZIAWG_PORT"
            ;;
    esac
}

validate_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_swap_size_gb() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_username() {
    common_validate_username "${1:-}"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { error "--user requires a value"; exit 1; }
                TARGET_USER="$2"
                shift 2
                ;;
            --create-user)
                CREATE_USER=true
                shift
                ;;
            --ssh-public-key)
                [ "$#" -ge 2 ] || { error "--ssh-public-key requires a value"; exit 1; }
                SSH_PUBLIC_KEY="$2"
                shift 2
                ;;
            --ssh-public-key-file)
                [ "$#" -ge 2 ] || { error "--ssh-public-key-file requires a value"; exit 1; }
                SSH_PUBLIC_KEY_FILE="$2"
                shift 2
                ;;
            --ssh-port)
                [ "$#" -ge 2 ] || { error "--ssh-port requires a value"; exit 1; }
                SSH_PORT="$2"
                shift 2
                ;;
            --xray-port)
                [ "$#" -ge 2 ] || { error "--xray-port requires a value"; exit 1; }
                XRAY_PORT="$2"
                shift 2
                ;;
            --amneziawg-port)
                [ "$#" -ge 2 ] || { error "--amneziawg-port requires a value"; exit 1; }
                AMNEZIAWG_PORT="$2"
                shift 2
                ;;
            --swap-size-gb)
                [ "$#" -ge 2 ] || { error "--swap-size-gb requires a value"; exit 1; }
                SWAP_SIZE_GB="$2"
                shift 2
                ;;
            --skip-swap)
                SKIP_SWAP=true
                shift
                ;;
            --skip-docker)
                INSTALL_DOCKER=false
                shift
                ;;
            --skip-fish)
                INSTALL_FISH=false
                shift
                ;;
            --kernel-backports)
                INSTALL_KERNEL_BACKPORTS=true
                shift
                ;;
            --firewall-phase)
                [ "$#" -ge 2 ] || { error "--firewall-phase requires a value"; exit 1; }
                FIREWALL_PHASE="$2"
                shift 2
                ;;
            --yes)
                ASSUME_YES=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [ "$TARGET_USER" = "root" ]; then
        error "root cannot be the target user: SSH hardening disables root login (PermitRootLogin no) and would lock you out. Pass a regular user with --user"
        exit 1
    fi

    if ! validate_firewall_phase "$FIREWALL_PHASE"; then
        error "Unsupported firewall phase: ${FIREWALL_PHASE}. Use bootstrap or locked."
        exit 1
    fi

    if ! validate_swap_size_gb "$SWAP_SIZE_GB"; then
        error "Unsupported swap size: ${SWAP_SIZE_GB}. Use a positive integer number of GiB."
        exit 1
    fi

    if ! validate_port "$SSH_PORT"; then
        error "Invalid SSH port: ${SSH_PORT}. Port must be between 1 and 65535."
        exit 1
    fi

    if ! validate_port "$XRAY_PORT"; then
        error "Invalid XRay port: ${XRAY_PORT}. Port must be between 1 and 65535."
        exit 1
    fi

    if ! validate_port "$AMNEZIAWG_PORT"; then
        error "Invalid AmneziaWG port: ${AMNEZIAWG_PORT}. Port must be between 1 and 65535."
        exit 1
    fi

    if [ "$SSH_PORT" = "$XRAY_PORT" ]; then
        error "SSH port and XRay port must differ (both are TCP): ${SSH_PORT}"
        exit 1
    fi

    if [ -n "$SSH_PUBLIC_KEY_FILE" ] && [ ! -f "$SSH_PUBLIC_KEY_FILE" ]; then
        error "SSH public key file not found: ${SSH_PUBLIC_KEY_FILE}"
        exit 1
    fi
}

# Without --user the operator is the regular user who invoked sudo. Kept apart
# from parse_args so that the root check in main reports a missing root first.
resolve_target_user() {
    if [ -n "$TARGET_USER" ]; then
        return 0
    fi

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
        return 0
    fi

    error "Target user is not set: run through sudo as a regular user or pass --user <name>"
    exit 1
}

confirm_execution() {
    local auto_create_swap=true

    if $ASSUME_YES; then
        return 0
    fi

    if $SKIP_SWAP; then
        auto_create_swap=false
    fi

    printf '\nTarget user: %s\n' "$TARGET_USER"
    printf 'Swap size (GiB): %s\n' "$SWAP_SIZE_GB"
    printf 'Auto-create swap: %s\n' "$auto_create_swap"
    printf 'Install Docker CE: %s\n' "$INSTALL_DOCKER"
    printf 'Install Fish + Starship: %s\n' "$INSTALL_FISH"
    printf 'Install Backports Kernel: %s\n' "$INSTALL_KERNEL_BACKPORTS"
    printf 'SSH port: %s/tcp\n' "$SSH_PORT"
    printf 'XRay port: %s/tcp\n' "$XRAY_PORT"
    printf 'AmneziaWG port: %s/udp\n' "$AMNEZIAWG_PORT"
    printf 'Firewall phase: %s (%s)\n' "$FIREWALL_PHASE" "$(firewall_udp_rule_for_phase "$FIREWALL_PHASE")"
    printf 'Proceed? [y/N]: '

    local reply
    read -r reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        warn "Aborted by user"
        exit 0
    fi
}

current_login_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi

    logname 2>/dev/null
}

warn_if_login_user_not_target_user() {
    local login_user
    local reply

    # AllowUsers locks every other account out of SSH, whether or not this run
    # itself came in over SSH (sudo usually drops SSH_CONNECTION anyway).
    login_user="$(current_login_user || true)"
    if [ -z "$login_user" ]; then
        warn "Cannot determine the logged-in user; make sure ${TARGET_USER} can log in over SSH with a key"
        return 0
    fi

    if [ "$login_user" = "$TARGET_USER" ]; then
        return 0
    fi

    warn "You are logged in as ${login_user}, but SSH hardening allows only ${TARGET_USER} (AllowUsers) and disables root login"
    warn "After the SSH service restarts, ${login_user} will not be able to log in over SSH"

    if $ASSUME_YES; then
        return 0
    fi

    printf 'Continue anyway? [y/N]: '
    read -r reply || reply=""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        warn "Aborted by user"
        exit 0
    fi
}

validate_target_user() {
    if id "$TARGET_USER" >/dev/null 2>&1; then
        return 0
    fi

    if ! $CREATE_USER; then
        error "User ${TARGET_USER} does not exist. Re-run with --create-user to provision it."
        exit 1
    fi

    return 0
}

user_home_for() {
    local username="$1"
    getent passwd "$username" | cut -d: -f6
}

target_user_has_authorized_keys() {
    local username="$1"
    local user_home
    local keys_file

    user_home="$(user_home_for "$username")"
    [ -n "$user_home" ] || return 1

    keys_file="$user_home/.ssh/authorized_keys"
    [ -s "$keys_file" ] || return 1
    grep -Eq '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$keys_file"
}

resolve_authorized_keys_source() {
    local candidate_user="${SUDO_USER:-}"
    local candidate_path=""

    if [ -n "$SSH_PUBLIC_KEY_FILE" ] && [ -f "$SSH_PUBLIC_KEY_FILE" ]; then
        printf '%s\n' "$SSH_PUBLIC_KEY_FILE"
        return 0
    fi

    if [ -n "$candidate_user" ] && [ "$candidate_user" != "root" ]; then
        candidate_path="$(user_home_for "${candidate_user}")/.ssh/authorized_keys"
        if [ -f "$candidate_path" ]; then
            printf '%s\n' "$candidate_path"
            return 0
        fi
    fi

    return 1
}

append_authorized_keys_unique() {
    local source_keys="$1"
    local target_keys="$2"
    local source_line=""

    touch "$target_keys"
    chmod 600 "$target_keys"

    while IFS= read -r source_line || [ -n "$source_line" ]; do
        [ -n "$source_line" ] || continue
        if ! grep -Fqx "$source_line" "$target_keys"; then
            printf '%s\n' "$source_line" >> "$target_keys"
        fi
    done < "$source_keys"
}

append_authorized_key_line_unique() {
    local source_key="$1"
    local target_keys="$2"

    touch "$target_keys"
    chmod 600 "$target_keys"

    if ! grep -Fqx "$source_key" "$target_keys"; then
        printf '%s\n' "$source_key" >> "$target_keys"
    fi
}

create_target_user_if_needed() {
    local validation_result
    local user_home
    local source_keys

    if id "$TARGET_USER" >/dev/null 2>&1; then
        log "Using existing user: ${TARGET_USER}"
        user_home="$(user_home_for "$TARGET_USER")"
        install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.ssh"
        if [ -n "$SSH_PUBLIC_KEY" ]; then
            append_authorized_key_line_unique "$SSH_PUBLIC_KEY" "$user_home/.ssh/authorized_keys"
            chown "$TARGET_USER:$TARGET_USER" "$user_home/.ssh/authorized_keys"
        elif source_keys="$(resolve_authorized_keys_source)"; then
            append_authorized_keys_unique "$source_keys" "$user_home/.ssh/authorized_keys"
            chown "$TARGET_USER:$TARGET_USER" "$user_home/.ssh/authorized_keys"
        elif ! target_user_has_authorized_keys "$TARGET_USER"; then
            error "Existing user ${TARGET_USER} has no authorized_keys, but SSH password login will be disabled"
            error "Pass --ssh-public-key or --ssh-public-key-file, or add ${user_home}/.ssh/authorized_keys before hardening"
            exit 1
        fi
        return 0
    fi

    section "Target user creation"

    if validate_username "$TARGET_USER"; then
        validation_result=0
    else
        validation_result=$?
        case "$validation_result" in
            1) error "Username cannot be empty" ;;
            2) error "Username cannot be only numbers" ;;
            3) error "Username cannot start with a number or dash" ;;
            4) error "Username can only contain lowercase letters, numbers, underscore, and dash" ;;
            5) error "Username is too long (max 32 characters)" ;;
        esac
        exit 1
    fi

    "$ADDUSER_BIN" --gecos "" --disabled-password "$TARGET_USER"
    user_home="$(user_home_for "$TARGET_USER")"
    install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.ssh"
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        append_authorized_key_line_unique "$SSH_PUBLIC_KEY" "$user_home/.ssh/authorized_keys"
    elif source_keys="$(resolve_authorized_keys_source)"; then
        append_authorized_keys_unique "$source_keys" "$user_home/.ssh/authorized_keys"
    elif ! $ASSUME_YES; then
        echo ""
        info "No authorized_keys source detected for the invoking sudo user."
        info "Paste a public key for ${TARGET_USER} so SSH access works after hardening."
        read -r -p "SSH Public Key: " SSH_PUBLIC_KEY
        if [ -z "$SSH_PUBLIC_KEY" ]; then
            error "SSH public key cannot be empty when creating a new user without a key source"
            exit 1
        fi
        append_authorized_key_line_unique "$SSH_PUBLIC_KEY" "$user_home/.ssh/authorized_keys"
    else
        error "Cannot create ${TARGET_USER} safely: no authorized_keys source found for the invoking sudo user"
        error "Pass --ssh-public-key or --ssh-public-key-file when using --create-user non-interactively"
        exit 1
    fi
    chown "$TARGET_USER:$TARGET_USER" "$user_home/.ssh/authorized_keys"

    log "Created user ${TARGET_USER}"
    log "SSH authorized_keys prepared for ${TARGET_USER}"
}

ensure_passwordless_sudo() {
    if ! common_safe_write_sudoers "/etc/sudoers.d/${TARGET_USER}" "$TARGET_USER ALL=(ALL) NOPASSWD:ALL"; then
        error "Failed to configure passwordless sudo for ${TARGET_USER} (sudoers write or visudo check failed, is sudo installed?; the previous file, if any, is unchanged)"
        exit 1
    fi
    log "Passwordless sudo configured for ${TARGET_USER}"

    if ! common_safe_write_sudoers "/etc/sudoers.d/root" "root ALL=(ALL) NOPASSWD:ALL"; then
        error "Failed to configure passwordless sudo for root (sudoers write or visudo check failed, is sudo installed?; the previous file, if any, is unchanged)"
        exit 1
    fi
    log "Passwordless sudo configured for root"
}

ensure_target_user_privileges() {
    section "Target user privileges"

    usermod -aG sudo "$TARGET_USER"
    log "${TARGET_USER} added to the sudo group"
    ensure_passwordless_sudo

    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker "$TARGET_USER"
        log "${TARGET_USER} added to the docker group"
    fi
}

install_base_packages() {
    section "System update and minimal package baseline"
    common_apt_update "initial package refresh"
    common_apt_get upgrade -y
    common_safe_install ca-certificates curl sudo gnupg lsb-release nftables iptables ufw fail2ban python3-systemd
}

configure_locales() {
    section "UTF-8 locales for SSH sessions"
    common_safe_install locales || warn "locales package was not installed, locale generation may fail"
    common_generate_utf8_locales /etc/locale.gen
    log "English and Russian UTF-8 locales are available; system language preserved"
}

configure_time_sync() {
    section "Time synchronization"
    TIME_SYNC_SERVICE_NAME="Not configured"
    ensure_time_sync_service || true

    if system_clock_synchronized; then
        log "System clock is synchronized"
    else
        warn "System clock is not yet reported as synchronized"
    fi
}

configure_swap() {
    local swap_size_mib=$((SWAP_SIZE_GB * 1024))

    section "Swap baseline"

    if $SKIP_SWAP; then
        info "Skipping swap creation by request"
        return 0
    fi

    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        log "Active swap already detected; leaving existing swap in place"
        return 0
    fi

    if [ -e "$SWAPFILE_PATH" ]; then
        warn "${SWAPFILE_PATH} already exists but no active swap was detected; leaving it unchanged to avoid clobbering data"
        warn "Review ${SWAPFILE_PATH} manually if you still want a ${SWAP_SIZE_GB}G swapfile"
        return 0
    fi

    progress "Creating ${SWAP_SIZE_GB}G swapfile at ${SWAPFILE_PATH}"
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE_PATH"
    else
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="${swap_size_mib}" status=progress
    fi

    chmod 600 "$SWAPFILE_PATH"
    mkswap "$SWAPFILE_PATH" >/dev/null
    swapon "$SWAPFILE_PATH"

    if ! grep -qE "^[[:space:]]*${SWAPFILE_PATH}[[:space:]]+none[[:space:]]+swap[[:space:]]" "$FSTAB_FILE"; then
        printf '%s none swap sw 0 0\n' "$SWAPFILE_PATH" >> "$FSTAB_FILE"
    fi

    log "Swapfile enabled (${SWAP_SIZE_GB}G)"
}

install_docker_ce() {
    section "Docker CE (vanilla host baseline)"

    install -m 0755 -d "$(dirname "$DOCKER_KEYRING")"

    if [ ! -f "$DOCKER_KEYRING" ]; then
        progress "Installing Docker APT key"
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o "$DOCKER_KEYRING"
        chmod a+r "$DOCKER_KEYRING"
    fi
    DOCKER_ARCH="$(dpkg --print-architecture)"

    common_render_docker_debian_source "$ID" "$VERSION_CODENAME" "$DOCKER_ARCH" "$DOCKER_KEYRING" > "$DOCKER_SOURCES_FILE"
    common_apt_sources_changed

    common_apt_update "Docker repository refresh"
    common_safe_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if systemd_system_available; then
        service_unit_enable_now docker.service || service_unit_start docker.service || true
        service_unit_enable_now docker.socket || service_unit_start docker.socket || true
    fi

    groupadd -f docker
    ensure_target_user_privileges
    log "Docker installed and group access refreshed for ${TARGET_USER}"
}

install_backports_kernel() {
    if ! $INSTALL_KERNEL_BACKPORTS; then
        return 0
    fi

    section "Debian Backports Kernel Installation"
    local distro_version
    distro_version="$(detect_debian_version)"
    if [ "$distro_version" != "12" ]; then
        info "Debian $distro_version already includes a modern kernel; skipping backports kernel"
        return 0
    fi

    progress "Configuring bookworm-backports repository"
    common_render_debian_backports_source "bookworm" > "$BACKPORTS_SOURCES_FILE"
    chmod 644 "$BACKPORTS_SOURCES_FILE"
    common_apt_sources_changed

    local arch
    arch="$(dpkg --print-architecture)"
    progress "Installing latest kernel from backports (linux-image-$arch, linux-headers-$arch)"
    if common_apt_update "Backports repository refresh" \
        && common_install_from_release bookworm-backports "linux-image-$arch" "linux-headers-$arch"; then
        log "Debian Backports kernel and headers installed successfully"
    else
        error "Debian Backports kernel (linux-image-$arch, linux-headers-$arch) was not installed"
        return 1
    fi
    warn "A REBOOT IS REQUIRED to boot into the new Backports kernel before configuring AmneziaVPN"
}

install_fish_and_starship() {
    section "Fish shell and Starship prompt setup"

    if ! $INSTALL_FISH; then
        info "Skipping Fish shell and Starship installation by request"
        return 0
    fi

    progress "Installing Fish shell"
    common_safe_install fish || warn "Fish installation failed"

    if ! command -v fish >/dev/null 2>&1; then
        warn "Fish installation failed or binary not found; skipping shell customization"
        return 0
    fi

    if ! command -v starship >/dev/null 2>&1; then
        progress "Installing Starship prompt"
        if common_package_available starship; then
            common_safe_install starship || warn "Starship package installation failed, trying the official installer"
        fi
        if ! command -v starship >/dev/null 2>&1; then
            if curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null 2>&1; then
                log "Starship binary installed successfully via official installer"
            else
                warn "Could not install Starship automatically"
            fi
        fi
    else
        log "Starship is already installed"
    fi

    local user_home
    user_home="$(user_home_for "$TARGET_USER")"

    if [ -n "$user_home" ] && [ -d "$user_home" ]; then
        install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.config/fish"

        # Generate starship preset nerd-font-symbols
        if command -v starship >/dev/null 2>&1; then
            starship preset nerd-font-symbols > "$user_home/.config/starship.toml" 2>/dev/null || true
            chmod 644 "$user_home/.config/starship.toml" 2>/dev/null || true
            chown "$TARGET_USER:$TARGET_USER" "$user_home/.config/starship.toml" 2>/dev/null || true
        fi

        # Write ~/.config/fish/config.fish
        cat > "$user_home/.config/fish/config.fish" <<'FISH_EOF'
# ~/.config/fish/config.fish
set -g fish_greeting ""

if status is-interactive
    if command -v starship >/dev/null 2>&1
        starship init fish | source
    end
end
FISH_EOF
        chmod 644 "$user_home/.config/fish/config.fish"
        chown -R "$TARGET_USER:$TARGET_USER" "$user_home/.config"

        # Configure safe interactive-only auto-exec in ~/.bashrc
        # Keeps login shell as /bin/bash so Amnezia client non-interactive SSH commands run without syntax errors
        local bashrc="$user_home/.bashrc"
        touch "$bashrc"
        if ! grep -q "exec fish" "$bashrc"; then
            cat >> "$bashrc" <<'BASH_FISH_EOF'

# Auto-switch to Fish for interactive sessions only
# Non-interactive SSH commands (e.g. AmneziaVPN installer) stay in standard Bash
if [[ $- == *i* ]] && [ -z "${SSH_ORIGINAL_COMMAND:-}" ] && command -v fish >/dev/null 2>&1; then
    exec fish
fi
BASH_FISH_EOF
            chown "$TARGET_USER:$TARGET_USER" "$bashrc"
        fi

        log "Fish + Starship (nerd-font-symbols) configured for ${TARGET_USER}"
    fi

    # Also configure for root if its home exists
    if [ -d "$ROOT_HOME" ]; then
        install -d -m 0755 "$ROOT_HOME/.config/fish"
        if command -v starship >/dev/null 2>&1; then
            starship preset nerd-font-symbols > "$ROOT_HOME/.config/starship.toml" 2>/dev/null || true
            chmod 644 "$ROOT_HOME/.config/starship.toml" 2>/dev/null || true
        fi
        cat > "$ROOT_HOME/.config/fish/config.fish" <<'FISH_ROOT_EOF'
set -g fish_greeting ""

if status is-interactive
    if command -v starship >/dev/null 2>&1
        starship init fish | source
    end
end
FISH_ROOT_EOF
        chmod 644 "$ROOT_HOME/.config/fish/config.fish"
        if ! grep -q "exec fish" "$ROOT_HOME/.bashrc" 2>/dev/null; then
            cat >> "$ROOT_HOME/.bashrc" <<'BASH_FISH_ROOT_EOF'

# Auto-switch to Fish for interactive sessions only
if [[ $- == *i* ]] && [ -z "${SSH_ORIGINAL_COMMAND:-}" ] && command -v fish >/dev/null 2>&1; then
    exec fish
fi
BASH_FISH_ROOT_EOF
        fi
    fi
}

configure_sysctl() {
    section "Kernel modules and 10 Gbps sysctl baseline"

    # Persist and load required kernel modules for VPN and BBR
    install -d -m 0755 "$(dirname "$MODULES_LOAD_FILE")"
    cat > "$MODULES_LOAD_FILE" <<'MODULES_EOF'
tcp_bbr
tun
wireguard
MODULES_EOF

    local mod
    for mod in tcp_bbr tun wireguard; do
        modprobe "$mod" >/dev/null 2>&1 || true
    done

    # Calculate 10G BDP TCP buffer limits based on available RAM
    local total_ram_kb
    local max_buffer_bytes=67108864 # 64MB default for 10 Gbps pipes

    total_ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    if [ "$total_ram_kb" -gt 0 ] && [ "$total_ram_kb" -lt 3145728 ]; then
        # On VPS with < 3GB RAM, use 32MB max buffer to preserve memory while driving high speeds
        max_buffer_bytes=33554432
    fi

    cat > "$SYSCTL_CONF_FILE" <<SYSCTL_EOF
# 10 Gbps host tuning for AmneziaVPN app-managed deployments
# Network Congestion Control (BBR + FQ pacing)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# IP Forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# 10 Gbps BDP Buffer Tuning (dynamic TCP/IP window scaling)
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = ${max_buffer_bytes}
net.core.wmem_max = ${max_buffer_bytes}
net.core.optmem_max = 2097152
net.ipv4.tcp_rmem = 4096 1048576 ${max_buffer_bytes}
net.ipv4.tcp_wmem = 4096 1048576 ${max_buffer_bytes}

# UDP Buffer Tuning (WireGuard / AmneziaWG packet throughput)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Network Queues for 10G packet burst absorption
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384

# TCP Performance & Latency Tuning
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# Connection Tracking for high-concurrency VPN sessions
net.netfilter.nf_conntrack_max = 262144

# System Hardening & Memory (Loose rp_filter for VPN/Docker routing)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
vm.swappiness = 10
SYSCTL_EOF

    install -d -m 0755 "$(dirname "$LIMITS_CONF_FILE")"
    cat > "$LIMITS_CONF_FILE" <<'LIMITS_EOF'
# File descriptor and process limits for 10G VPN concurrency
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
* soft memlock unlimited
* hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited
LIMITS_EOF

    sysctl -e -p "$SYSCTL_CONF_FILE" >/dev/null 2>&1 || true
    log "10 Gbps sysctl and system limits baseline applied"
}

configure_firewall() {
    section "Firewall baseline"

    if ! command -v ufw >/dev/null 2>&1; then
        warn "UFW is not installed; skipping firewall setup"
        return 0
    fi

    # Ensure UFW forwards traffic between VPN and physical interfaces
    if [ -f "$UFW_DEFAULTS_FILE" ]; then
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$UFW_DEFAULTS_FILE"
    fi

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "${SSH_PORT}/tcp" >/dev/null
    ufw allow "${XRAY_PORT}/tcp" >/dev/null

    if [ "$FIREWALL_PHASE" = "bootstrap" ]; then
        ufw allow from any to any proto udp comment 'Temporary AmneziaWG bootstrap allowance' >/dev/null
        warn "Bootstrap firewall phase enabled: temporary all-UDP ingress remains open until AmneziaWG is pinned to ${AMNEZIAWG_PORT}/udp"
    else
        ufw --force delete allow from any to any proto udp >/dev/null 2>&1 || true
        ufw allow "${AMNEZIAWG_PORT}/udp" >/dev/null
        log "Removed temporary bootstrap UDP allowance"
        log "Locked firewall phase enabled: ${AMNEZIAWG_PORT}/udp opened for AmneziaWG"
    fi

    ufw --force enable >/dev/null
    warn "Review Docker-published ports after Amnezia deployment; Docker networking can bypass simplistic host-firewall expectations."
    log "Firewall baseline applied"
}

configure_fail2ban() {
    section "Fail2Ban for SSH"

    cat > /etc/fail2ban/jail.local <<FAIL2BAN_EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 3
bantime = 7200
FAIL2BAN_EOF

    if systemd_system_available; then
        service_unit_enable_now fail2ban.service || service_unit_start fail2ban.service || true
        systemctl restart fail2ban.service >/dev/null 2>&1 || true
    fi

    log "Fail2Ban configured for SSH (port ${SSH_PORT})"
}

render_ssh_hardening_dropin() {
    cat <<SSH_EOF
# Minimal Amnezia host SSH baseline
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
AllowUsers ${TARGET_USER}
Port ${SSH_PORT}
SSH_EOF
}

ufw_is_active() {
    local status

    command -v ufw >/dev/null 2>&1 || return 1
    status="$(ufw status 2>/dev/null || true)"
    grep -q '^Status: active' <<< "$status"
}

# Open the new SSH port in an active UFW before sshd moves to it: sshd restarts
# before configure_firewall runs, and a closed port would cut off new sessions.
allow_ssh_port_in_active_firewall() {
    ufw_is_active || return 0

    # A rule that already exists is the operator's: it is neither added nor removed here.
    if ufw status 2>/dev/null | grep -Eq "^${SSH_PORT}/tcp[[:space:]]+ALLOW"; then
        return 0
    fi

    if ! ufw allow "${SSH_PORT}/tcp" >/dev/null; then
        error "Could not allow ${SSH_PORT}/tcp in UFW; not restarting the SSH service to avoid blocking SSH access"
        return 1
    fi
    SSH_PORT_RULE_ADDED=true
    log "SSH port ${SSH_PORT}/tcp allowed in the active firewall before the SSH service restart"
}

remove_added_ssh_port_rule() {
    $SSH_PORT_RULE_ADDED || return 0

    # The port may belong to another service (the reason the restart failed): do not leave it open.
    if ufw delete allow "${SSH_PORT}/tcp" >/dev/null; then
        log "Removed the UFW rule for ${SSH_PORT}/tcp added for the failed SSH change"
    else
        warn "Could not remove the UFW rule for ${SSH_PORT}/tcp; remove it with: ufw delete allow ${SSH_PORT}/tcp"
    fi
    SSH_PORT_RULE_ADDED=false
}

# Restart the SSH unit; on failure print the output of both attempts.
restart_ssh_service() {
    local ssh_output
    local sshd_output

    if ssh_output="$(systemctl restart ssh.service 2>&1)"; then
        return 0
    fi
    if sshd_output="$(systemctl restart sshd.service 2>&1)"; then
        return 0
    fi

    printf 'systemctl restart ssh.service: %s\n' "$ssh_output" >&2
    printf 'systemctl restart sshd.service: %s\n' "$sshd_output" >&2
    return 1
}

# Port sshd listens on now (22 when it cannot be read).
current_ssh_port() {
    local port

    port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    printf '%s\n' "${port:-22}"
}

# Put the previous drop-in back (or remove ours when there was none).
revert_ssh_hardening_dropin() {
    local backup="${1:-}"

    if [ -n "$backup" ]; then
        cp -p "$backup" "$SSH_HARDENING_DROPIN"
    else
        rm -f "$SSH_HARDENING_DROPIN"
    fi
}

configure_ssh_hardening() {
    local backup=""

    section "SSH hardening"

    # Without systemd sshd is not restarted, so it keeps its old port while
    # configure_firewall opens only the new one.
    if ! systemd_system_available && [ "$SSH_PORT" != "$(current_ssh_port)" ]; then
        error "systemd is not available, so the SSH service cannot be restarted to move it to port ${SSH_PORT}"
        error "Keep the current SSH port, or restart the SSH service yourself and re-run the script"
        exit 1
    fi

    install -d -m 0755 "$(dirname "$SSH_HARDENING_DROPIN")"

    if [ -e "$SSH_HARDENING_DROPIN" ]; then
        backup="$(mktemp)"
        cp -p "$SSH_HARDENING_DROPIN" "$backup"
    fi

    render_ssh_hardening_dropin > "$SSH_HARDENING_DROPIN"

    if ! sshd -t; then
        error "SSH configuration test failed; reverting the SSH hardening drop-in ${SSH_HARDENING_DROPIN}"
        revert_ssh_hardening_dropin "$backup"
        rm -f "$backup"
        exit 1
    fi

    if ! allow_ssh_port_in_active_firewall; then
        revert_ssh_hardening_dropin "$backup"
        rm -f "$backup"
        exit 1
    fi

    if ! systemd_system_available; then
        rm -f "$backup"
        warn "systemd is not available; restart the SSH service manually to apply the drop-in"
        log "SSH hardening drop-in written (port ${SSH_PORT})"
        return 0
    fi

    if ! restart_ssh_service; then
        error "Failed to restart the SSH service with the new configuration (port ${SSH_PORT}); the port may be in use"
        revert_ssh_hardening_dropin "$backup"
        remove_added_ssh_port_rule
        if restart_ssh_service; then
            error "Previous SSH drop-in restored (${SSH_HARDENING_DROPIN}) and the SSH service is running again; the new settings are not applied"
        else
            error "The SSH service still does not start after restoring ${SSH_HARDENING_DROPIN}; check 'systemctl status ssh' and 'journalctl -u ssh' on the console"
        fi
        rm -f "$backup"
        exit 1
    fi

    rm -f "$backup"
    log "SSH hardening drop-in applied (port ${SSH_PORT})"
}

print_summary() {
    section "Summary"
    log "Minimal Amnezia host baseline completed"
    log "Target user: ${TARGET_USER}"
    log "Swap target: ${SWAP_SIZE_GB}G"
    log "Docker installed: ${INSTALL_DOCKER}"
    log "Fish + Starship: ${INSTALL_FISH}"
    log "10G networking: BBR + FQ + scaled buffers"
    log "Firewall phase: ${FIREWALL_PHASE}"
    log "SSH port: ${SSH_PORT}/tcp"
    log "XRay target port: ${XRAY_PORT}/tcp"
    if [ "$FIREWALL_PHASE" = "locked" ]; then
        log "AmneziaWG target port: ${AMNEZIAWG_PORT}/udp"
    else
        warn "AmneziaWG is still in bootstrap firewall mode; restrict UDP after pinning ${AMNEZIAWG_PORT}/udp in the Amnezia app"
    fi
    if $INSTALL_DOCKER; then
        warn "Log out and back in before using Docker as ${TARGET_USER}"
    fi
}

main() {
    parse_args "$@"

    if [ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi

    resolve_target_user

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        error "/etc/os-release is missing"
        exit 1
    fi

    require_supported_debian_release
    validate_target_user
    confirm_execution
    warn_if_login_user_not_target_user

    install_base_packages
    configure_locales
    install_backports_kernel
    create_target_user_if_needed
    ensure_target_user_privileges
    configure_time_sync
    configure_swap
    if $INSTALL_DOCKER; then
        install_docker_ce
    else
        info "Skipping Docker installation; leave Docker provisioning to the Amnezia app"
    fi
    install_fish_and_starship
    configure_sysctl
    configure_fail2ban
    configure_ssh_hardening
    configure_firewall
    print_summary
}

# shellcheck disable=SC2317
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" = "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"

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

    tui_install_gum() {
        local gum_dir tmp_dir os_name arch dl_url checksum_url gum_checksum gum_path
        command -v curl >/dev/null 2>&1 || return 1
        command -v tar >/dev/null 2>&1 || return 1
        command -v sha256sum >/dev/null 2>&1 || return 1
        gum_dir="$(dirname "$GUM")"
        mkdir -p "$gum_dir" 2>/dev/null || return 1
        [ -w "$gum_dir" ] || return 1
        tmp_dir="$(mktemp -d)"
        os_name="$(uname -s)"
        arch="$(tui_gum_asset_arch)"
        dl_url="https://github.com/charmbracelet/gum/releases/download/v${TUI_GUM_VERSION}/gum_${TUI_GUM_VERSION}_${os_name}_${arch}.tar.gz"
        checksum_url="https://github.com/charmbracelet/gum/releases/download/v${TUI_GUM_VERSION}/checksums.txt"
        if ! curl -Lsf "$dl_url" >"${tmp_dir}/gum.tar.gz"; then rm -rf "$tmp_dir"; return 1; fi
        if ! curl -Lsf "$checksum_url" >"${tmp_dir}/checksums.txt"; then rm -rf "$tmp_dir"; return 1; fi
        gum_checksum="$(awk -v f="$(basename "$dl_url")" '$2==f{print $1}' "${tmp_dir}/checksums.txt")"
        if [ -z "$gum_checksum" ] || ! echo "$gum_checksum  ${tmp_dir}/gum.tar.gz" | sha256sum -c - >/dev/null 2>&1; then rm -rf "$tmp_dir"; return 1; fi
        if ! tar -xf "${tmp_dir}/gum.tar.gz" --directory "$tmp_dir"; then rm -rf "$tmp_dir"; return 1; fi
        gum_path="$(find "$tmp_dir" -type f -executable -name "gum" -print -quit)"
        if [ -z "$gum_path" ] || ! mv "$gum_path" "$GUM"; then rm -rf "$tmp_dir"; return 1; fi
        chmod +x "$GUM" || { rm -rf "$tmp_dir"; return 1; }
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

# Run command silently, show only on error
run_silent() {
    local cmd="$1"
    local desc="${2:-Running command}"
    
    if ! eval "$cmd" >/dev/null 2>&1; then
        error "$desc failed"
        return 1
    fi
    return 0
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

# Wait for dpkg/apt lock to be released
wait_for_dpkg_lock() {
    local max_wait=300  # 5 minutes maximum wait
    local wait_time=0
    local check_interval=2

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

        if [ $wait_time -ge $max_wait ]; then
            error "Timeout waiting for dpkg lock after ${max_wait}s"
            return 1
        fi

        if [ $wait_time -eq 0 ]; then
            info "Waiting for other package managers to finish..."
        fi

        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done

    # Additional small delay to ensure lock is fully released
    [ $wait_time -gt 0 ] && sleep 1
    return 0
}

# Check if package is available in repositories
package_available() {
    LC_ALL=C apt-cache policy "$1" 2>/dev/null | grep -q "Candidate:" && \
    ! LC_ALL=C apt-cache policy "$1" 2>/dev/null | grep -q "Candidate: (none)"
}

# Safe package installation with availability check (silent mode)
safe_install() {
    local packages=("$@")
    local available_packages=()
    local unavailable_packages=()
    local failed_packages=()

    # Wait for any running package managers to finish
    wait_for_dpkg_lock || return 1

    # Update package list silently
    apt-get update >/dev/null 2>&1 || true
    
    for pkg in "${packages[@]}"; do
        if package_available "$pkg"; then
            available_packages+=("$pkg")
        else
            unavailable_packages+=("$pkg")
        fi
    done
    
    if [ ${#available_packages[@]} -gt 0 ]; then
        progress "Installing ${#available_packages[@]} packages..."
        if ! apt-get install -y "${available_packages[@]}" >/dev/null 2>&1; then
            # Retry with individual packages on failure
            for pkg in "${available_packages[@]}"; do
                if ! apt-get install -y "$pkg" >/dev/null 2>&1; then
                    failed_packages+=("$pkg")
                    warn "Failed to install: $pkg"
                fi
            done
        fi
        if [ ${#failed_packages[@]} -eq 0 ]; then
            log "Packages installed successfully"
        else
            warn "Package installation incomplete: ${failed_packages[*]}"
            return 1
        fi
    fi
    
    if [ ${#unavailable_packages[@]} -gt 0 ]; then
        warn "Unavailable packages: ${unavailable_packages[*]}"
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

enrich_apt_components() {
    local f="$1"
    local tmp_file
    local line
    [ -f "$f" ] || return 0

    progress "Updating APT source file: $f"

    if ! tmp_file=$(mktemp); then
        error "Failed to allocate temporary file while updating $f"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            (deb\ *|deb-src\ *|[[:space:]]deb\ *|[[:space:]]deb-src\ *)
                if [[ " $line " == *" main "* ]]; then
                    [[ " $line " == *" contrib "* ]] || line="${line} contrib"
                    [[ " $line " == *" non-free "* ]] || line="${line} non-free"
                    [[ " $line " == *" non-free-firmware "* ]] || line="${line} non-free-firmware"
                fi
                ;;
        esac
        printf '%s\n' "$line" >>"$tmp_file"
    done < "$f"

    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        error "Refusing to replace $f with an empty temporary file"
        return 1
    fi

    if ! cat "$tmp_file" > "$f"; then
        rm -f "$tmp_file"
        error "Failed to write updated APT source file: $f"
        return 1
    fi

    rm -f "$tmp_file"
    return 0
}

enrich_deb822_components() {
    local f="$1"
    [ -f "$f" ] || return 0

    progress "Updating deb822 APT source file: $f"

    if ! sed -i -E '/^\s*Components:\s*/ {
        /contrib/! s/$/ contrib/
        /non-free([[:space:]]|$)/! s/$/ non-free/
        /non-free-firmware/! s/$/ non-free-firmware/
    }' "$f"; then
        error "Failed to update deb822 APT source file: $f"
        return 1
    fi

    return 0
}

enrich_all_apt_sources() {
    local status=0

    enrich_apt_components "/etc/apt/sources.list" || status=$?

    local f
    for f in /etc/apt/sources.list.d/*.list; do
        if [ -e "$f" ]; then
            enrich_apt_components "$f" || status=$?
        fi
    done

    for f in /etc/apt/sources.list.d/*.sources; do
        if [ -e "$f" ]; then
            enrich_deb822_components "$f" || status=$?
        fi
    done

    return $status
}

run_apt_update_with_diagnostics() {
    local context="$1"
    local output
    local status

    output=$(apt-get update 2>&1) && status=0 || status=$?
    log_silent "$output"

    if [ $status -ne 0 ]; then
        error "apt-get update failed during: $context"
        printf '%s\n' "$output" | head -10 | sed 's/^/    /'
        return $status
    fi

    return 0
}

systemd_system_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

timedatectl_available() {
    command -v timedatectl >/dev/null 2>&1
}

system_clock_synchronized() {
    [ "$(timedatectl show --property=SystemClockSynchronized --value 2>/dev/null)" = "yes" ]
}

time_sync_candidate_units() {
    printf '%s\n' \
        chronyd.service \
        chrony.service \
        ntpsec.service \
        ntp.service \
        openntpd.service \
        systemd-timesyncd.service
}

service_unit_exists() {
    systemctl list-unit-files "$1" --no-legend >/dev/null 2>&1
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
    for unit in $(time_sync_candidate_units); do
        if service_unit_exists "$unit"; then
            printf '%s\n' "$unit"
            return 0
        fi
    done

    return 1
}

ensure_time_sync_service() {
    local service

    if ! systemd_system_available; then
        return 1
    fi

    service=$(detect_time_sync_service || true)
    if [ -z "$service" ]; then
        if ! package_available systemd-timesyncd; then
            warn "No supported NTP service detected and systemd-timesyncd is unavailable"
            return 1
        fi

        log "No NTP service detected. Installing systemd-timesyncd..."
        safe_install systemd-timesyncd
        service="systemd-timesyncd.service"
    else
        log "Detected NTP service: ${service%.service}"
    fi

    if service_unit_active "$service"; then
        TIME_SYNC_SERVICE_NAME="${service%.service}"
        return 0
    fi

    if service_unit_enable_now "$service" || service_unit_start "$service"; then
        log "NTP service started: ${service%.service}"
        TIME_SYNC_SERVICE_NAME="${service%.service}"
        return 0
    fi

    warn "Failed to enable or start NTP service: ${service%.service}"
    return 1
}

enable_ntp_sync() {
    local service

    if ! timedatectl_available; then
        info "timedatectl is unavailable. Install and start chrony, ntpsec, or systemd-timesyncd manually if time sync is required."
        return 1
    fi

    if ! systemd_system_available; then
        info "systemd is unavailable. Install and start an NTP daemon manually before enabling time synchronization."
        return 1
    fi

    TIME_SYNC_SERVICE_NAME="Not configured"
    ensure_time_sync_service || return 1
    service="${TIME_SYNC_SERVICE_NAME}.service"

    if timedatectl set-ntp true 2>/dev/null; then
        log "NTP synchronization enabled via $TIME_SYNC_SERVICE_NAME"
        return 0
    fi

    if service_unit_active "$service"; then
        if system_clock_synchronized; then
            log "Time sync already operational via $TIME_SYNC_SERVICE_NAME"
        else
            info "Time-sync daemon $TIME_SYNC_SERVICE_NAME is active even though timedatectl could not control it directly"
        fi
        return 0
    fi

    warn "Could not enable NTP via timedatectl after preparing $TIME_SYNC_SERVICE_NAME"
    return 1
}

# shellcheck disable=SC2317
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Yes/No prompt with default value
prompt_yn() {
    local prompt="$1"
    local default="$2"
    local default_yes=false

    [ "$default" = "yes" ] && default_yes=true
    TUI_PROMPT_PREFIX="" tui_prompt_yn "$prompt" "$default_yes"
}

# Check if running as root
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" && $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

# Check if dialog is available, fallback to read if not
check_dialog() {
    tui_has_visual_backend
}

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
    warn "Failed to configure passwordless sudo for $NEW_USER (visudo syntax check failed)"
fi

# Configure passwordless sudo for root
if ! grep -q "^root.*NOPASSWD:ALL" /etc/sudoers.d/root 2>/dev/null; then
    if common_safe_write_sudoers "/etc/sudoers.d/root" "root ALL=(ALL) NOPASSWD:ALL"; then
        log "Passwordless sudo configured for root"
    else
        warn "Failed to configure passwordless sudo for root (visudo syntax check failed)"
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
    echo "Select system locale:"
    echo "1) en_US.UTF-8 (English)"
    echo "2) ru_RU.UTF-8 (Russian)"
    echo "3) Both (en_US.UTF-8 + ru_RU.UTF-8)"
    
    if ! LOCALE_CHOICE=$(tui_radiolist "Locale Selection" "Select locale:" 15 60 3 "1" "English (en_US.UTF-8)" on "2" "Russian (ru_RU.UTF-8)" off "3" "Both (en_US.UTF-8 + ru_RU.UTF-8)" off); then
        read -r -p "Enter choice [1-3]: " LOCALE_CHOICE
    fi

case $LOCALE_CHOICE in
    1)
        LOCALE_TO_GENERATE="en_US.UTF-8"
        DEFAULT_LOCALE="en_US.UTF-8"
        log "Selected locale: English (en_US.UTF-8)"
        ;;
    2)
        LOCALE_TO_GENERATE="ru_RU.UTF-8"
        DEFAULT_LOCALE="ru_RU.UTF-8"
        log "Selected locale: Russian (ru_RU.UTF-8)"
        ;;
    3)
        LOCALE_TO_GENERATE="en_US.UTF-8 ru_RU.UTF-8"
        DEFAULT_LOCALE="en_US.UTF-8"
        log "Selected locales: English + Russian"
        ;;
    *)
        warn "Invalid choice. Using English (en_US.UTF-8) as default"
        LOCALE_TO_GENERATE="en_US.UTF-8"
        DEFAULT_LOCALE="en_US.UTF-8"
        ;;
esac

# Install locales package with availability check
if package_available locales; then
    safe_install locales
else
    warn "locales package not available"
fi

# Generate locales
log "Generating locales..."
for locale in $LOCALE_TO_GENERATE; do
    log "Processing locale: $locale"
    
    # Remove all existing entries for this locale (both commented and uncommented)
    # to avoid duplicates from previous runs
    sed -i "/^#* *${locale} UTF-8/d" /etc/locale.gen
    
    # Add a single uncommented entry
    echo "${locale} UTF-8" >> /etc/locale.gen
    log "Added ${locale} to /etc/locale.gen"
done

# Generate locales without LC_ALL set
LC_ALL=C.UTF-8 /usr/sbin/locale-gen

# Update locale configuration file
cat > /etc/default/locale <<EOF
LANG=$DEFAULT_LOCALE
LANGUAGE=${DEFAULT_LOCALE%%.*}
LC_ALL=$DEFAULT_LOCALE
EOF

# Export for current session using safe C.UTF-8 to avoid warnings
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=en

# Write to profile for all users (will be applied on next login)
cat > /etc/profile.d/locale.sh <<EOF
export LANG=$DEFAULT_LOCALE
export LC_ALL=$DEFAULT_LOCALE
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

TIME_SYNC_SERVICE_NAME="Not configured"
enable_ntp_sync || true

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
info "  Time sync: $TIME_SYNC_SERVICE_NAME"
echo ""

#################################################################################
# 4. Fish Shell and Starship Installation
################################################################################
section "${SYMBOL_ROCKET} Fish + Starship Installation"

echo ""
info "Installing Fish shell and Starship prompt (nerd-font-symbols preset)..."
echo ""

# Install Fish and dependencies with availability check
safe_install fish git curl

# Install Starship prompt (universal, works everywhere)
if ! command -v starship >/dev/null 2>&1; then
    if package_available starship; then
        safe_install starship
    fi
    if ! command -v starship >/dev/null 2>&1; then
        curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null 2>&1 || true
    fi
fi

if command -v starship >/dev/null 2>&1; then
    log "Starship prompt installed"
else
    warn "Starship installation encountered an issue"
fi

# Function to setup Fish + Starship for a user
setup_fish_for_user() {
    local username=$1
    local user_home
    user_home=$(common_user_home "$username" || echo "/home/$username")

    [ -d "$user_home" ] || return 0
    log "Setting up Fish + Starship for user: $username"

    install -d -m 0755 "$user_home/.config/fish"

    # Generate starship preset nerd-font-symbols
    if command -v starship >/dev/null 2>&1; then
        starship preset nerd-font-symbols > "$user_home/.config/starship.toml" 2>/dev/null || true
        chmod 644 "$user_home/.config/starship.toml" 2>/dev/null || true
    fi

    # Write ~/.config/fish/config.fish
    cat > "$user_home/.config/fish/config.fish" <<'FISH_EOF'
# ~/.config/fish/config.fish
set -g fish_greeting ""

# Environment & Paths
if test -d /usr/local/go/bin
    fish_add_path /usr/local/go/bin
end
if test -d $HOME/go/bin
    fish_add_path $HOME/go/bin
end
if test -d /usr/sbin
    fish_add_path /usr/sbin
end

# Fast Node Manager (fnm) hook
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
alias gp="git pull"
alias gP="git push"
alias gl="git log --oneline --graph --decorate"
alias gd="git diff"

# Interactive starship prompt
if status is-interactive
    if command -v starship >/dev/null 2>&1
        starship init fish | source
    end
end
FISH_EOF
    chmod 644 "$user_home/.config/fish/config.fish"

    # Configure hybrid auto-switch in ~/.bashrc
    # Keeps login shell as /bin/bash so non-interactive scripts/automation stay 100% POSIX
    local bashrc="$user_home/.bashrc"
    touch "$bashrc"
    if ! grep -q "exec fish" "$bashrc"; then
        cat >> "$bashrc" <<'BASH_FISH_EOF'

# Auto-switch to Fish for interactive sessions only
# Non-interactive SSH commands, cron, scp/rsync stay in standard Bash
if [[ $- == *i* ]] && [ -z "${SSH_ORIGINAL_COMMAND:-}" ] && command -v fish >/dev/null 2>&1; then
    exec fish
fi
BASH_FISH_EOF
    fi

    # Set correct ownership
    chown -R "$username:$username" "$user_home/.config" "$bashrc" 2>/dev/null || true
    log "Fish + Starship (nerd-font-symbols) configured for $username"
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
safe_install bash-completion

# Function to setup modern Bash for a user
setup_bash_for_user() {
    local username=$1
    local user_home
    user_home=$(common_user_home "$username" || echo "/home/$username")
    
    log "Setting up Bash configuration for $username"
    
    # Backup existing .bashrc if it exists and is not our version
    if [ -f "$user_home/.bashrc" ] && ! grep -q "VPS Optimized Bash Configuration" "$user_home/.bashrc"; then
        cp "$user_home/.bashrc" "$user_home/.bashrc.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # Create modern .bashrc
    cat > "$user_home/.bashrc" <<'BASHRC'
# VPS Optimized Bash Configuration

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

export EDITOR='vim'
export VISUAL='vim'
export PAGER='less'

# Path optimization
export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/sbin:$PATH"

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
alias ports='netstat -tulanp'
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
# Go Configuration
# ============================================

export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

# ============================================
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

    # Set proper ownership
    if [ "$username" != "root" ]; then
        chown "$username":"$username" "$user_home/.bashrc" 2>/dev/null || true
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

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    *) GO_ARCH="$ARCH"; warn "Unknown architecture, attempting with: $ARCH" ;;
esac

# Fetch latest Go version
GO_VERSION=$(curl -s https://go.dev/VERSION?m=text 2>/dev/null | head -1 | sed 's/go//')
if [ -z "$GO_VERSION" ]; then
    GO_VERSION="1.25.4"  # fallback version
    warn "Could not detect latest Go version, using fallback: $GO_VERSION"
fi

GO_DOWNLOAD_URL="https://dl.google.com/go/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
GO_CHECKSUM_URL="https://dl.google.com/go/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz.sha256"

log "Go version: $GO_VERSION ($GO_ARCH)"
log "Downloading Go from: $GO_DOWNLOAD_URL"

# Download Go binary
cd /tmp

# Download checksum (Google provides just the hash, sometimes with filename)
CHECKSUM=$(curl -fsSL "$GO_CHECKSUM_URL" 2>/dev/null | head -1 | awk '{print $1}')
if [ -z "$CHECKSUM" ]; then
    error "Could not download Go checksum from $GO_CHECKSUM_URL"
    exit 1
fi

log "Expected checksum: $CHECKSUM"

# Download Go binary
curl -fsSL "$GO_DOWNLOAD_URL" -o "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

# Verify checksum
ACTUAL_CHECKSUM=$(sha256sum "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" | awk '{print $1}')
if [ "$CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
    error "Go checksum verification failed!"
    error "Expected: $CHECKSUM"
    error "Actual:   $ACTUAL_CHECKSUM"
    exit 1
fi
log "Go checksum verified successfully"

# Remove old Go installation if exists
rm -rf /usr/local/go
mkdir -p /usr/local/go

# Extract and install
tar -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -C /usr/local/
rm -f "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

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

# Cleanup
rm -f /tmp/go"${GO_VERSION}".linux-"${GO_ARCH}".tar.gz

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
    safe_install "${missing_packages[@]}"

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

    local fnm_install_script="/tmp/fnm_install_${username}.sh"

    cat > "$fnm_install_script" <<'FNMINSTALL'
#!/bin/bash
set -e

export HOME="$1"
export USER="$2"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_RUNTIME_DIR="$XDG_STATE_HOME/fnm-runtime"

command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required"; exit 1; }

curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell

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
        bash "$fnm_install_script" "$user_home" "$username"
    else
        su - "$username" -c "bash '$fnm_install_script' '$user_home' '$username'"
    fi

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
safe_install bc

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

run_apt_update_with_diagnostics "initial package refresh"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Enrich APT sources with non-free packages
log "Enriching APT sources with contrib and non-free components..."
if ! enrich_all_apt_sources; then
    error "Failed while rewriting APT source files"
    exit 1
fi
if ! run_apt_update_with_diagnostics "APT source enrichment"; then
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

safe_install "${essential_packages[@]}"

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
rm -f /etc/apt/sources.list.d/xanmod-release.list /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || true

distro_version="${VERSION_ID%%.*}"
ARCH="$(dpkg --print-architecture)"
KERNEL_PKG="linux-image-${ARCH}"
HEADERS_PKG="linux-headers-${ARCH}"

if [ "$distro_version" = "12" ]; then
    info "Configuring Debian bookworm-backports for latest LTS kernel..."
    common_render_debian_backports_source "bookworm" > /etc/apt/sources.list.d/debian-backports.sources
    chmod 644 /etc/apt/sources.list.d/debian-backports.sources

    run_apt_update_with_diagnostics "Backports repository refresh"
    progress "Installing latest kernel from Debian Backports ($KERNEL_PKG, $HEADERS_PKG)..."
    safe_install -t bookworm-backports "$KERNEL_PKG" "$HEADERS_PKG"
    log "Official Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG) installed successfully"
    BACKPORTS_KERNEL_INSTALLED=true
else
    info "Debian $distro_version includes modern kernel by default ($KERNEL_VERSION)"
    progress "Ensuring latest official Debian kernel ($KERNEL_PKG, $HEADERS_PKG)..."
    safe_install "$KERNEL_PKG" "$HEADERS_PKG"
    log "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) updated successfully"
    BACKPORTS_KERNEL_INSTALLED=false
fi


################################################################################
# 8. Docker and Docker Compose Installation
################################################################################
log "Step 10: Installing Docker and Docker Compose..."

# Remove old Docker versions if present
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done

# Note: iptables-legacy was already configured above for UFW and Docker compatibility
log "Using iptables-legacy for Docker compatibility (already configured)"

# Install prerequisites (ca-certificates, curl, gnupg, lsb-release already installed)
install -m 0755 -d /etc/apt/keyrings

# Add Docker's official GPG key
curl -fsSL "https://download.docker.com/linux/$ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
DOCKER_ARCH="$(dpkg --print-architecture)"

# Set up Docker repository
common_render_docker_debian_source "$ID" "$VERSION_CODENAME" "$DOCKER_ARCH" "/etc/apt/keyrings/docker.gpg" > /etc/apt/sources.list.d/docker.sources

# Install Docker Engine, CLI, containerd, and Docker Compose plugin with availability check
docker_packages=(
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
    "docker-buildx-plugin"
    "docker-compose-plugin"
)

safe_install "${docker_packages[@]}"

# Check if Docker was actually installed
if ! command -v docker &>/dev/null; then
    error "Docker installation failed - docker binary not found!"
    exit 1
fi

# Configure Docker daemon for better performance BEFORE starting service
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

cat > /etc/fail2ban/jail.local <<EOF
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

cat > /etc/security/limits.d/99-vps-limits.conf <<EOF
# VPS Limits Optimization
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
root soft nproc 65535
root hard nproc 65535
EOF

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

cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%F)" 2>/dev/null || true

# Create hardening config
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# SSH Hardening - VPS Optimization
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10
AllowTcpForwarding yes

# Only allow specific user
AllowUsers $NEW_USER
EOF

# Test SSH configuration
if sshd -t; then
    log "SSH configuration is valid"
    systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart sshd.service
    log "SSH service restarted with new configuration"
else
    error "SSH configuration test failed! Reverting changes..."
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
fi

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
safe_install linux-cpupower

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
# 27. System Limits Optimization
################################################################################
log "Step 23: Optimizing system limits..."

# Backup existing limits.conf
cp /etc/security/limits.conf "/etc/security/limits.conf.backup.$(date +%F)" 2>/dev/null || true

# Add optimized limits for VPN server
cat >> /etc/security/limits.conf <<'LIMITS'

# ============================================================================
# VPS Optimization - System Limits for VPN Server (1-4GB RAM)
# ============================================================================

# Open file limits (moderate for low RAM VPS)
*               soft    nofile          262144
*               hard    nofile          262144
root            soft    nofile          262144
root            hard    nofile          262144

# Process limits
*               soft    nproc           16384
*               hard    nproc           16384

# Memory lock (for VPN encryption)
*               soft    memlock         unlimited
*               hard    memlock         unlimited

LIMITS

log "System limits optimized"

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
apt-get autoremove -y

# Clean journal logs older than 7 days
journalctl --vacuum-time=7d

# Clean old kernels (keep current + 1)
dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | head -n -1 | xargs apt-get -y purge 2>/dev/null || true

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
    safe_install speedtest-cli
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
info "System limits increased (nofile 524288)"
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

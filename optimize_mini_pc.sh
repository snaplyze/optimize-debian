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

# Check if running as root
if [[ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" && $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

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

# Safe package installation with availability check (silent mode)
safe_install() {
    local packages=("$@")
    local available_packages=()
    local unavailable_packages=()

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
                apt-get install -y "$pkg" >/dev/null 2>&1 || warn "Failed to install: $pkg"
            done
        fi
        log "Packages installed successfully"
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

enrich_apt_components() {
    local f="$1"
    local tmp_file
    local line
    [ -f "$f" ] || return 0

    tmp_file=$(mktemp)
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

    cat "$tmp_file" > "$f"
    rm -f "$tmp_file"
}

enrich_deb822_components() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -i -E '/^\s*Components:\s*/ {
        /contrib/! s/$/ contrib/
        /non-free([[:space:]]|$)/! s/$/ non-free/
        /non-free-firmware/! s/$/ non-free-firmware/
    }' "$f"
}

enrich_all_apt_sources() {
    enrich_apt_components "/etc/apt/sources.list"

    local f
    for f in /etc/apt/sources.list.d/*.list; do
        if [ -e "$f" ]; then
            enrich_apt_components "$f"
        fi
    done

    for f in /etc/apt/sources.list.d/*.sources; do
        if [ -e "$f" ]; then
            enrich_deb822_components "$f"
        fi
    done
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

resolve_intel_media_packages() {
    local packages=(
        "intel-media-va-driver-non-free"
        "intel-gpu-tools"
        "vainfo"
        "mesa-utils"
    )

    if package_available "libmfx-gen1.2"; then
        packages+=("libmfx-gen1.2")
    elif package_available "libmfx1"; then
        packages+=("libmfx1")
    fi

    printf '%s\n' "${packages[@]}"
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

# Check if dialog is available
check_dialog() {
    tui_has_visual_backend
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
    enrich_all_apt_sources
    
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    
    if $INSTALL_BASE_UTILS; then
        log "Installing essential packages..."
        # Combined list from VPS + specific needs
        safe_install wget curl git htop iotop sysstat net-tools \
            iptables ufw fail2ban python3-systemd unattended-upgrades apt-listchanges \
            zip unzip gnupg ca-certificates lsb-release \
            lm-sensors linux-cpupower speedtest-cli irqbalance \
            fzf ripgrep fd-find bat bc needrestart ncdu tree vim nano tmux \
            make gcc g++ cmake xz-utils xdg-user-dirs
            
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
    safe_install locales
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

    TIME_SYNC_SERVICE_NAME="Not configured"
    enable_ntp_sync || true

    info "Localization configured:"
    info "  Locale: $DEFAULT_LOCALE"
    info "  Timezone: ${NEW_TIMEZONE:-unchanged}"
    info "  Time sync: $TIME_SYNC_SERVICE_NAME"
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
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    
    echo ""
    info "Please paste your SSH public key (the content of your id_rsa.pub or id_ed25519.pub):"
    info "If you don't have one, generate it on your local machine with: ssh-keygen -t ed25519"
    info "Press Enter to skip SSH key setup (you can add it later)"
    echo ""
    read -r -p "SSH Public Key: " SSH_PUBLIC_KEY
    
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        append_authorized_key_unique "$SSH_PUBLIC_KEY" "$USER_HOME/.ssh/authorized_keys"
        chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
        log "SSH public key added for $NEW_USER"
        
        if $CONFIGURE_SECURITY; then
            log "Hardening SSH configuration..."
            cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers $NEW_USER
EOF
            systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true
            log "SSH hardened: only $NEW_USER can login with SSH keys"
        fi
    else
        warn "SSH key setup skipped. You can add a key later to ~/.ssh/authorized_keys"
        if $CONFIGURE_SECURITY; then
            warn "SSH hardening skipped (no SSH key provided)"
            CONFIGURE_SECURITY=false
        fi
    fi
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
        log "Installing official Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG)..."
        safe_install -t bookworm-backports "$KERNEL_PKG" "$HEADERS_PKG"
        log "Official Debian Backports kernel ($KERNEL_PKG, $HEADERS_PKG) installed successfully"
        BACKPORTS_KERNEL_INSTALLED=true
    else
        info "Debian $distro_version includes modern kernel by default ($KERNEL_VERSION)"
        safe_install "$KERNEL_PKG" "$HEADERS_PKG"
        log "Official Debian kernel ($KERNEL_PKG, $HEADERS_PKG) updated successfully"
        BACKPORTS_KERNEL_INSTALLED=false
    fi
    
    # CPU Governor (schedutil is best for N5095)
    # linux-cpupower is available on Debian 12 and Debian 13
    safe_install linux-cpupower

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
    apt-get update >/dev/null 2>&1 || true
    mapfile -t intel_gpu_packages < <(resolve_intel_media_packages)
    safe_install "${intel_gpu_packages[@]}"
    
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
        safe_install fish curl git

        if ! command -v starship >/dev/null 2>&1; then
            if package_available starship; then
                safe_install starship
            fi
            if ! command -v starship >/dev/null 2>&1; then
                curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null 2>&1 || true
            fi
        fi

        setup_fish_for_user() {
            local username=$1
            local user_home
            user_home=$(common_user_home "$username" || echo "/home/$username")
            [ -d "$user_home" ] || return 0
            log "Configuring Fish + Starship for $username..."

            install -d -m 0755 "$user_home/.config/fish"

            # Generate starship preset nerd-font-symbols
            if command -v starship >/dev/null 2>&1; then
                starship preset nerd-font-symbols > "$user_home/.config/starship.toml" 2>/dev/null || true
                chmod 644 "$user_home/.config/starship.toml" 2>/dev/null || true
            fi

            # Write ~/.config/fish/config.fish
            cat > "$user_home/.config/fish/config.fish" <<'FISH_EOF'
# ~/.config/fish/config.fish - Mini PC Media/Home Server
set -g fish_greeting ""

# Paths
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

# System Monitoring
alias meminfo="free -h"
alias cpuinfo="lscpu"
alias diskinfo="df -h"
alias ports="ss -tulpn"
alias psa="ps aux"

# Hardware Monitoring (GPU & Sensors)
alias gpuinfo="vainfo 2>/dev/null || intel_gpu_top"
alias temp="sensors"

# Package Management
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

            chown -R "$username:$username" "$user_home/.config" "$bashrc" 2>/dev/null || true
            log "Fish + Starship (nerd-font-symbols) configured for $username"
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
safe_install bash-completion

# Function to setup modern Bash for a user
setup_bash_for_user() {
    local username=$1
    local user_home
    user_home=$(common_user_home "$username" || echo "/home/$username")
    
    log "Setting up Bash configuration for $username"
    
    # Backup existing .bashrc if it exists and is not our version
    if [ -f "$user_home/.bashrc" ] && ! grep -q "Mini PC Optimized Bash Configuration" "$user_home/.bashrc"; then
        cp "$user_home/.bashrc" "$user_home/.bashrc.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # Create modern .bashrc
    cat > "$user_home/.bashrc" <<'BASHRC'
# Mini PC Optimized Bash Configuration

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

if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

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
# 7. Go & Node.js
################################################################################
if $INSTALL_GO; then
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
    
    # Download checksum
    CHECKSUM=$(curl -fsSL "$GO_CHECKSUM_URL" 2>/dev/null | head -1 | awk '{print $1}')
    if [ -z "$CHECKSUM" ]; then
        error "Could not download Go checksum from $GO_CHECKSUM_URL"
        exit 1
    fi
    
    # Download binary
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
    
    # Extract
    tar -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -C /usr/local/
    
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
    
    # Cleanup
    rm -f "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
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
        apt-get remove -y $pkg 2>/dev/null || true
    done
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    DOCKER_ARCH="$(dpkg --print-architecture)"
    
    common_render_docker_debian_source "$ID" "$VERSION_CODENAME" "$DOCKER_ARCH" "/etc/apt/keyrings/docker.gpg" > /etc/apt/sources.list.d/docker.sources
      
    apt-get update
    safe_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = systemd

[sshd]
enabled = true
port = 22
maxretry = 3
bantime = 3600
EOF
    systemctl restart fail2ban
    
    # Auto Updates
    common_render_apt_periodic_auto_upgrades_conf > /etc/apt/apt.conf.d/20auto-upgrades
fi

################################################################################
# 12. Services (Samba)
################################################################################
if $INSTALL_SAMBA; then
    section "Step 12: Samba"
    
    # Check if /mnt/ssd exists
    if [ ! -d "/mnt/ssd" ]; then
        warn "Directory /mnt/ssd does not exist! Skipping Samba configuration."
        warn "Please mount your drive to /mnt/ssd and configure Samba manually later."
    else
        # Fix permissions for the share directory
        log "Setting permissions for /mnt/ssd to user $NEW_USER..."
        chown -R "$NEW_USER:$NEW_USER" /mnt/ssd
        chmod -R 755 /mnt/ssd
        
        safe_install samba
        
        # Backup config
        [ ! -f /etc/samba/smb.conf.bak ] && cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
        
        # Configure global settings (Enable SMB2+ for modern clients)
        if ! grep -q "server min protocol" /etc/samba/smb.conf; then
            sed -i '/\[global\]/a \   server min protocol = SMB2' /etc/samba/smb.conf
        fi
        
        # Disable default [homes] share PROPERLY (comment out all lines to prevent global leakage)
        # We use a loop to comment out the [homes] section and its commonly associated parameters
        # This is safer than simple sed replacement which might miss indented lines
        sed -i 's/^\[homes\]/;\[homes\]/g' /etc/samba/smb.conf
        sed -i 's/^   comment = Home Directories/;   comment = Home Directories/g' /etc/samba/smb.conf
        sed -i 's/^   browseable = no/;   browseable = no/g' /etc/samba/smb.conf
        sed -i 's/^   read only = yes/;   read only = yes/g' /etc/samba/smb.conf
        sed -i 's/^   create mask = 0700/;   create mask = 0700/g' /etc/samba/smb.conf
        sed -i 's/^   directory mask = 0700/;   directory mask = 0700/g' /etc/samba/smb.conf
        sed -i 's/^   valid users = %S/;   valid users = %S/g' /etc/samba/smb.conf
        
        # Add share if not exists (simple check)
        if ! grep -q "\[$SAMBA_SHARE_NAME\]" /etc/samba/smb.conf; then
            cat >> /etc/samba/smb.conf <<EOF

[$SAMBA_SHARE_NAME]
   path = /mnt/ssd
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0644
   directory mask = 0755
   valid users = $NEW_USER
EOF
        else
            warn "Share [$SAMBA_SHARE_NAME] might already exist in smb.conf"
        fi
        
        log "Samba configured. Please set SMB password for user: $NEW_USER"
        log "Note: This password can be different from system password."
        
        # Retry loop for password
        while ! smbpasswd -a "$NEW_USER"; do
            warn "Password setting failed (mismatch?). Please try again."
            echo ""
        done
        
        systemctl restart smbd
        log "Samba service restarted."
        
        # Enable firewall rule for Samba (now that package is installed and profile exists)
        if command -v /usr/sbin/ufw &> /dev/null; then
            /usr/sbin/ufw allow Samba
            log "Firewall rules updated for Samba."
        fi
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
apt-get autoremove -y
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
curl -s ifconfig.me || echo "Unavailable"
echo ""
EOF
chmod +x /usr/local/bin/minipc-info.sh

# 13.4 Network Test Script
cat > /usr/local/bin/network-test.sh <<'EOF'
#!/bin/bash
echo "=== Network Performance Test ==="
if ! command -v speedtest-cli &> /dev/null; then
    apt-get install -y speedtest-cli
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

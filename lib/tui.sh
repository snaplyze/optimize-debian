#!/usr/bin/env bash

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
            if ! tui_gum_path >/dev/null 2>&1 && [ "$TUI_AUTO_INSTALL_GUM" != "false" ]; then
                tui_install_gum || return 1
            fi
            TUI_RESOLVED_BACKEND="gum"
            ;;
        auto|"")
            if tui_gum_path >/dev/null 2>&1; then
                TUI_RESOLVED_BACKEND="gum"
            elif [ "$TUI_AUTO_INSTALL_GUM" != "false" ] && [ "${OPTIMIZE_SOURCE_ONLY:-0}" != "1" ] && [ -t 1 ]; then
                if tui_install_gum; then
                    TUI_RESOLVED_BACKEND="gum"
                else
                    TUI_RESOLVED_BACKEND="plain"
                fi
            else
                TUI_RESOLVED_BACKEND="plain"
            fi
            ;;
        plain|dialog|whiptail)
            TUI_RESOLVED_BACKEND="$backend"
            ;;
        *)
            return 1
            ;;
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
        dialog|whiptail|plain)
            printf '%s\n' "$TUI_BACKEND"
            return 0
            ;;
        auto|"")
            ;;
        *)
            return 1
            ;;
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

#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh)

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# One table of Debian versions for the library and for every script. FN names the function
# under test and LABEL the thing it belongs to; the case body runs after the script is sourced.
read -r -d '' VERSION_CASES <<'CASES_EOF' || true
for version in 12 13 13.1 12.5; do
    "$FN" "$version" || { printf 'FAIL: %s: Debian %s must be supported\n' "$LABEL" "$version" >&2; exit 1; }
done
for version in 11 24 120 1 ""; do
    if "$FN" "$version"; then
        printf 'FAIL: %s: "%s" must be unsupported\n' "$LABEL" "$version" >&2
        exit 1
    fi
done
CASES_EOF

# lib/common.sh is the single implementation; each script embeds a copy for the one-file
# run (`bash <(curl ...)`) and wraps it as is_supported_debian_version. Every script runs
# both ways: next to lib/ (the repository checkout) and alone in an empty directory.
test_supported_debian_versions() {
    local script mode script_dir

    SRC="$ROOT_DIR/lib/common.sh" FN=common_is_supported_debian_version LABEL=lib/common.sh \
        bash -c 'set -euo pipefail; source "$SRC"; '"$VERSION_CASES"

    for script in "${SCRIPTS[@]}"; do
        for mode in with-lib embedded; do
            script_dir="$ROOT_DIR"
            if [ "$mode" = embedded ]; then
                script_dir="$TEST_TMP/$script.d"
                mkdir -p "$script_dir"
                cp "$ROOT_DIR/$script" "$script_dir/$script"
            fi
            SRC="$script_dir/$script" FN=is_supported_debian_version LABEL="$script ($mode)" \
                bash -c 'set -euo pipefail; OPTIMIZE_SOURCE_ONLY=1; source "$SRC"; trap - ERR; '"$VERSION_CASES"
        done
    done
}

test_wsl_release_helpers() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        trap - ERR
        [[ "$(resolve_cuda_distro 12)" == "debian12" ]]
        [[ "$(resolve_cuda_distro 13)" == "debian13" ]]
        [[ "$(resolve_cuda_distro 13.1)" == "debian13" ]]
        if resolve_cuda_distro 11 >/dev/null; then
            printf "FAIL: Debian 11 has no CUDA repository target\n" >&2
            exit 1
        fi

        if render_wsl_conf "" | grep -q "^default="; then
            printf "FAIL: empty WSL default user must not render default=\n" >&2
            exit 1
        fi
        render_wsl_conf snaplyze | grep -q "^default=snaplyze$"
    '
}

# resolve_fetch_packages asks the package index: fastfetch when it is available, neofetch
# as the fallback, nothing when neither is. VERSION_ID must not matter.
test_wsl_fetch_package_resolver() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        trap - ERR
        # Only names the product asks about may be answered.
        common_package_available() {
            case "$1" in
                fastfetch|neofetch) [[ " $AVAILABLE " == *" $1 "* ]] ;;
                *) printf "FAIL: unexpected package query: %s\n" "$*" >&2; exit 1 ;;
            esac
        }
        common_apt_update() { printf "FAIL: resolve_fetch_packages must leave the index refresh to its caller\n" >&2; exit 1; }
        check() {
            local expected="$1" actual
            actual="$(resolve_fetch_packages)"
            [ "$actual" = "$expected" ] || {
                printf "FAIL: available=[%s] VERSION_ID=%s: expected [%s], got [%s]\n" "$AVAILABLE" "$VERSION_ID" "$expected" "$actual" >&2
                exit 1
            }
        }

        for VERSION_ID in 12 13; do
            AVAILABLE="fastfetch neofetch"; check fastfetch
            AVAILABLE="fastfetch";          check fastfetch
            AVAILABLE="neofetch";           check neofetch
            AVAILABLE="";                   check ""
        done
    '
}

test_wsl_cuda_toolkit_package_resolver() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        apt-cache() {
            [ "$1" = "show" ] && [ "$2" = "cuda-toolkit" ]
        }
        [[ "$(resolve_cuda_toolkit_package)" == "cuda-toolkit" ]]
    '

    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        apt-cache() {
            [ "$1" = "show" ] && [ "$2" = "cuda-toolkit-13-2" ]
        }
        [[ "$(resolve_cuda_toolkit_package)" == "cuda-toolkit-13-2" ]]
    '
}

# optimize_vps.sh and optimize_mini_pc.sh share this helper: a key already in the file is
# not added again, other keys stay, and the file is private.
test_authorized_keys_merge() {
    local script

    for script in optimize_vps.sh optimize_mini_pc.sh; do
        SCRIPT_ROOT="$ROOT_DIR" SCRIPT_NAME="$script" TEST_TMP="$TEST_TMP" bash -c '
            set -euo pipefail
            OPTIMIZE_SOURCE_ONLY=1
            source "$SCRIPT_ROOT/$SCRIPT_NAME"
            trap - ERR
            keys="$TEST_TMP/$SCRIPT_NAME.authorized_keys"
            printf "%s\n" "ssh-ed25519 AAAA-existing old" > "$keys"
            chmod 644 "$keys"

            append_authorized_key_unique "ssh-ed25519 AAAA-new new" "$keys"
            append_authorized_key_unique "ssh-ed25519 AAAA-new new" "$keys"
            append_authorized_key_unique "ssh-ed25519 AAAA-existing old" "$keys"

            [ "$(wc -l < "$keys")" = 2 ] || { printf "FAIL: %s: authorized_keys has duplicates or lost keys\n" "$SCRIPT_NAME" >&2; exit 1; }
            grep -Fxq "ssh-ed25519 AAAA-existing old" "$keys"
            grep -Fxq "ssh-ed25519 AAAA-new new" "$keys"
            [ "$(stat -c %a "$keys")" = 600 ] || { printf "FAIL: %s: authorized_keys must be mode 600\n" "$SCRIPT_NAME" >&2; exit 1; }

            append_authorized_key_unique "ssh-ed25519 AAAA-first first" "$TEST_TMP/$SCRIPT_NAME.fresh"
            [ "$(cat "$TEST_TMP/$SCRIPT_NAME.fresh")" = "ssh-ed25519 AAAA-first first" ]
        '
    done
}

# Text checks (hygiene): names, flags and patterns that must not come back anywhere in the
# product. The positive requirements are covered by behavioral tests of the functions.
test_project_conventions_contract() {
    local script
    # A text check (hygiene) of conventions from AGENTS.md "Key Patterns" that the scripts
    # apply in flat top-level steps, which tests cannot call without root.
    for script in "${SCRIPTS[@]}"; do
        grep -q 'net\.ipv4\.conf\.all\.rp_filter = 2' "$ROOT_DIR/$script" || fail "$script must keep net.ipv4.conf.all.rp_filter = 2"
        grep -q 'net\.ipv4\.conf\.default\.rp_filter = 2' "$ROOT_DIR/$script" || fail "$script must keep net.ipv4.conf.default.rp_filter = 2"
        grep -q 'exec fish' "$ROOT_DIR/$script" || fail "$script must switch interactive bash sessions to fish"
        grep -q 'preset nerd-font-symbols' "$ROOT_DIR/$script" || fail "$script must use the Starship nerd-font-symbols preset"
        grep -q 'common_render_docker_debian_source ' "$ROOT_DIR/$script" || fail "$script must render docker.sources with the shared helper"
        if grep -nE '(>|tee|install|cp|mv)[^|#]*sudoers\.d/' "$ROOT_DIR/$script" | grep -v 'mktemp'; then
            fail "$script must write /etc/sudoers.d only through common_safe_write_sudoers"
        fi
        grep -q 'common_safe_write_sudoers "' "$ROOT_DIR/$script" || fail "$script must configure sudo through common_safe_write_sudoers"
    done
    for script in optimize_vps.sh optimize_mini_pc.sh optimize_amnezia_host.sh; do
        grep -q 'backend = systemd' "$ROOT_DIR/$script" || fail "$script must read fail2ban logs from journald (backend = systemd)"
        grep -q 'common_render_debian_backports_source ' "$ROOT_DIR/$script" || fail "$script must render the Backports source with the shared helper"
    done
}

test_flat_step_regression_contracts() {
    local entry script pattern
    # A text check (hygiene) of fixes that live in flat top-level steps of vps, mini-PC and WSL2:
    # they run only as root after the OPTIMIZE_SOURCE_ONLY guard, so tests cannot call them.
    # Each line guards a regression: an optional step that must not stop the run, a tuning
    # value, a glob guard, a package name or a shell hook.
    # shellcheck disable=SC2016 # The contracts are literal script text, not expansions.
    local contracts=(
        'optimize_vps.sh|install_fnm_for_user root || warn'
        'optimize_mini_pc.sh|install_fnm_for_user root || warn'
        'optimize_wsl2.sh|gpu_status_wsl || true'
        'optimize_vps.sh|MAX_BUFFER=67108864'
        'optimize_vps.sh|common_safe_install linux-cpupower'
        'optimize_mini_pc.sh|common_safe_install linux-cpupower'
        'optimize_mini_pc.sh|if $INSTALL_GO; then'
        'optimize_mini_pc.sh|if $INSTALL_NODE; then'
        'optimize_wsl2.sh|if $INSTALL_GO; then'
        'optimize_wsl2.sh|if $INSTALL_NODE; then'
        'optimize_vps.sh|if ensure_fnm_install_dependencies; then'
        'optimize_mini_pc.sh|if ensure_fnm_install_dependencies; then'
        'optimize_wsl2.sh|if ensure_fnm_install_dependencies; then'
        'optimize_vps.sh|fnm env --use-on-cd --shell fish'
        'optimize_vps.sh|fnm env --use-on-cd --shell bash'
        'optimize_mini_pc.sh|fnm env --use-on-cd --shell fish'
        'optimize_mini_pc.sh|fnm env --use-on-cd --shell bash'
        'optimize_wsl2.sh|fnm env --use-on-cd --shell fish'
        'optimize_wsl2.sh|fnm env --use-on-cd --shell bash'
        'optimize_vps.sh|/etc/apt/sources.list.d/docker.sources'
        'optimize_mini_pc.sh|/etc/apt/sources.list.d/docker.sources'
        'optimize_wsl2.sh|/etc/apt/sources.list.d/docker.sources'
    )
    for entry in "${contracts[@]}"; do
        script="${entry%%|*}"
        pattern="${entry#*|}"
        awk -v p="$pattern" '!/^[[:space:]]*#/ && index($0, p) { found = 1 } END { exit !found }' "$ROOT_DIR/$script" || \
            fail "$script lost a guarded line: $pattern"
    done
}

test_forbidden_patterns_hygiene() {
    local script

    for script in "${SCRIPTS[@]}"; do
        if grep -Fq 'INSTALL_XANMOD' "$ROOT_DIR/$script"; then
            fail "$script should not have INSTALL_XANMOD flag"
        fi
        if grep -Fq 'INSTALL_ZSH' "$ROOT_DIR/$script"; then
            fail "$script should not have INSTALL_ZSH flag"
        fi
        if grep -Eq '^[[:space:]]*PROMPT=' "$ROOT_DIR/$script"; then
            fail "$script must not assign PROMPT in zsh snippets; PROMPT is zsh PS1"
        fi
        if grep -Eq 'ESMApps|ESM:' "$ROOT_DIR/$script"; then
            fail "$script must not write Ubuntu ESM unattended-upgrades origins"
        fi
        if grep -Eq 'tmpfs[[:space:]]+/tmp[[:space:]]+tmpfs.*noexec' "$ROOT_DIR/$script"; then
            fail "$script must not mount /tmp with noexec (breaks apt, dpkg, go build, npm)"
        fi
        if grep -Eq 'rp_filter = 1' "$ROOT_DIR/$script"; then
            fail "$script must not configure Strict rp_filter (1)"
        fi
        if grep -Eq 'ntlm[[:space:]]+auth' "$ROOT_DIR/$script"; then
            fail "$script must not re-enable obsolete and insecure ntlm auth"
        fi
        if grep -Eq 'logpath = /var/log/auth.log' "$ROOT_DIR/$script"; then
            fail "$script fail2ban must not require /var/log/auth.log on systemd-journal Debian"
        fi
        if grep -Eq '(^|[^[:alnum:]_])NVM([^[:alnum:]_]|$)|remove_legacy_nvm_for_user|\.nvm|nvm\.sh|nvm\(' "$ROOT_DIR/$script"; then
            fail "$script should no longer contain NVM references"
        fi
    done

    if grep -Eq 'safe_install[[:space:]]+cuda([[:space:]]|$)' "$ROOT_DIR/optimize_wsl2.sh"; then
        fail 'optimize_wsl2.sh must not install the broad cuda metapackage in WSL'
    fi
    if grep -Fq 'apt-cache search cuda | grep -q' "$ROOT_DIR/optimize_wsl2.sh"; then
        fail 'optimize_wsl2.sh must not probe CUDA packages with grep -q under pipefail'
    fi
    # Downloads go through common_download / common_fetch_verified (tests/test_downloads.sh):
    # nothing from the network is piped into a shell, wget is not used, temporary files come from
    # mktemp rather than fixed /tmp paths, and every curl call is bounded in time.
    for script in "${SCRIPTS[@]}" lib/common.sh lib/tui.sh; do
        if grep -nE '(curl|wget)[^#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh([[:space:]]|$)' "$ROOT_DIR/$script"; then
            fail "$script must not pipe a download into a shell"
        fi
        if grep -nE '(^|[[:space:];|&(])wget[[:space:]]' "$ROOT_DIR/$script" | grep -vE 'common_safe_install|^[0-9]+:[[:space:]]*#'; then
            fail "$script must download with curl through the shared helpers, not wget"
        fi
        # common_temp_dir removes its directories from an EXIT trap that a trap of the script
        # itself would replace or skip.
        if grep -nE '(^|[[:space:];])trap[[:space:]].*[[:space:]]EXIT([[:space:]]|$)' "$ROOT_DIR/$script" | grep -vE 'trap common_remove_temp_dirs EXIT|^[0-9]+:[[:space:]]*#'; then
            fail "$script must not set an EXIT trap: common_temp_dir cleans up through its own"
        fi
        if grep -nE '/tmp/' "$ROOT_DIR/$script" | grep -vE '^[0-9]+:[[:space:]]*#'; then
            fail "$script must create temporary files with mktemp, not fixed /tmp paths"
        fi
        if awk '
            # Joins continued lines, then checks every curl command for --max-time.
            /\\$/ { buf = buf substr($0, 1, length($0) - 1) " "; next }
            { line = buf $0; buf = "" }
            line ~ /^[[:space:]]*#/ { next }
            line ~ /(^|[[:space:];|&(])curl[[:space:]]+-/ && line !~ /--max-time/ { print FILENAME ":" FNR ": " line; bad = 1 }
            END { exit !bad }
        ' "$ROOT_DIR/$script"; then
            fail "$script has a curl call without --max-time"
        fi
    done
    # ARCH-5: the shell configs of the vps, mini and wsl2 profiles come from lib/common.sh only.
    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh; do
        # (Go and fnm still append their own blocks to .bashrc with cat >>.)
        if grep -nE '(cat > |tee )"[^"]*(\.bashrc|config\.fish)"' "$ROOT_DIR/$script"; then
            fail "$script must write .bashrc and config.fish through common_setup_bashrc / common_setup_fish"
        fi
    done
    if grep -RE 'eval echo "~' "$ROOT_DIR"/*.sh "$ROOT_DIR"/lib/*.sh; then
        fail 'scripts must not use eval echo "~" for home expansion; use common_user_home'
    fi
}

# The templates are cut out of the script text and parsed by fish.
test_generated_fish_config_templates_parse() {
    if ! command -v fish >/dev/null 2>&1; then
        printf 'SKIP: generated config.fish templates are not parsed: fish is not installed\n'
        return 0
    fi

    local tmp_dir script=optimize_amnezia_host.sh
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    # The vps, mini and wsl2 configs come from common_render_fish_config (tests/test_shell_config.sh);
    # Amnezia keeps its own template.
    awk '
        /config\.fish.*<<.*FISH/ { inside=1; next }
        inside && /^FISH.*EOF$/ { inside=0; exit }
        inside { print }
    ' "$ROOT_DIR/$script" > "$tmp_dir/$script.fish"

    [ -s "$tmp_dir/$script.fish" ] || \
        fail "$script should contain a generated config.fish template"
    fish -n "$tmp_dir/$script.fish" || \
        fail "$script generated config.fish template should parse as fish"

    rm -rf "$tmp_dir"
    trap - RETURN
}

test_apt_settings_ignore_environment() {
    local script
    # The scripts run as root through `bash <(curl ...)`, which keeps the caller's environment:
    # COMMON_APT_UPDATE_CHECK names a command to run, so none of these may come from it.
    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        SCRIPT_ROOT="$ROOT_DIR" SCRIPT_NAME="$script" COMMON_APT_UPDATE_CHECK=/bin/false \
            COMMON_APT_LOCK_TIMEOUT=1 COMMON_APT_UPDATE_ATTEMPTS=1 COMMON_APT_UPDATE_RETRY_DELAY=0 \
            COMMON_APT_INDEX_FRESH=1 bash -c '
            set -euo pipefail
            OPTIMIZE_SOURCE_ONLY=1
            source "$SCRIPT_ROOT/$SCRIPT_NAME"
            [ "$COMMON_APT_LOCK_TIMEOUT" = 300 ] && [ "$COMMON_APT_UPDATE_ATTEMPTS" = 30 ] \
                && [ "$COMMON_APT_UPDATE_RETRY_DELAY" = 10 ] && [ "$COMMON_APT_INDEX_FRESH" = 0 ] || {
                printf "FAIL: %s takes APT settings from the environment\n" "$SCRIPT_NAME" >&2
                exit 1
            }
            case "$SCRIPT_NAME:$COMMON_APT_UPDATE_CHECK" in
                optimize_wsl2.sh:wsl_apt_update_check|optimize_vps.sh:|optimize_mini_pc.sh:|optimize_amnezia_host.sh:) ;;
                *) printf "FAIL: %s: COMMON_APT_UPDATE_CHECK=%s\n" "$SCRIPT_NAME" "$COMMON_APT_UPDATE_CHECK" >&2; exit 1 ;;
            esac
        '
    done
}

# Text check (hygiene): the removed APT helper names must not come back.
test_apt_helpers_replace_old_implementations() {
    local script
    # The APT, APT sources and time-sync helpers live in lib/common.sh (tests/test_apt_helpers.sh,
    # tests/test_time_sync.sh) and are embedded in the scripts (tests/test_embedded_copies.sh);
    # no script keeps its own variant.
    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        if grep -nE 'fuser|wait_for_dpkg_lock|run_apt_update_with_diagnostics|apt_update_once|(^|[^_a-z])(safe_install|package_available)\b' "$ROOT_DIR/$script"; then
            fail "$script must use the common_apt_* / common_safe_install helpers only"
        fi
        if grep -nE '(^|[^_a-z])(enrich_all_apt_sources|enrich_apt_components|enrich_deb822_components|enable_ntp_sync|ensure_time_sync_service|detect_time_sync_service|time_sync_candidate_units|timedatectl_available|system_clock_synchronized|systemd_system_available)\b' "$ROOT_DIR/$script"; then
            fail "$script must use common_enrich_apt_sources and the common time-sync helpers only"
        fi
    done
}

# Text check (hygiene): see the comment inside.
test_apt_source_changes_reset_the_index_mark() {
    local script bad
    # common_apt_update refreshes the index once per run, so after the
    # script changes APT sources or keys, common_apt_sources_changed must come before the next
    # refresh or installation, or the new repository stays invisible.
    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh optimize_amnezia_host.sh; do
        bad="$(awk '
            /^[[:space:]]*#/ { next }
            /common_apt_sources_changed/ { pending = 0; next }
            /(>|tee) .*(docker\.sources|debian-backports\.sources|nvidia-container-toolkit\.list|\$DOCKER_SOURCES_FILE|\$BACKPORTS_SOURCES_FILE)/ ||
            /sed -i.*(sources\.list|Components:)/ ||
            /add-apt-repository / ||
            tolower($0) ~ /dpkg -i .*keyring/ ||
            /rm -f[^#]*\/etc\/apt\/sources\.list\.d\// { if (!pending) pending = NR; next }
            pending && /(common_safe_install|common_apt_update|common_apt_get (install|upgrade|dist-upgrade|full-upgrade))[[:space:]]/ {
                print pending; pending = 0
            }
            END { if (pending) print pending }
        ' "$ROOT_DIR/$script")"
        [ -z "$bad" ] || fail "$script: APT sources change at line(s) $(tr '\n' ' ' <<<"$bad")not followed by common_apt_sources_changed before the next refresh or install"
    done
}

test_wsl_apt_update_check() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c '
        set -euo pipefail
        OPTIMIZE_SOURCE_ONLY=1
        source "$SCRIPT_ROOT/optimize_wsl2.sh"
        test_tmp="$(mktemp -d)"
        trap "rm -rf \"$test_tmp\"" EXIT
        warn() { printf "WARN: %s\n" "$1" >> "$test_tmp/warn.txt"; }

        [[ "${COMMON_APT_UPDATE_CHECK:-}" == "wsl_apt_update_check" ]] || {
            printf "FAIL: WSL2 must register wsl_apt_update_check for common_apt_update\n" >&2
            exit 1
        }
        wsl_apt_update_check "Hit:1 http://deb.debian.org/debian bookworm InRelease"
        [ ! -s "$test_tmp/warn.txt" ]

        if wsl_apt_update_check "W: Failed to fetch http://example.invalid/Release"; then
            printf "FAIL: a fetch failure must reject the APT refresh\n" >&2
            exit 1
        fi
        grep -q "repository verification errors" "$test_tmp/warn.txt"
        ! grep -q "WSL clock" "$test_tmp/warn.txt"

        : > "$test_tmp/warn.txt"
        if wsl_apt_update_check "W: GPG error: Signature made in the future, not live until Mon"; then
            printf "FAIL: a signature date error must reject the APT refresh\n" >&2
            exit 1
        fi
        grep -q "WSL clock appears out of sync" "$test_tmp/warn.txt"
    '
}

main() {
    test_supported_debian_versions
    test_wsl_release_helpers
    test_wsl_fetch_package_resolver
    test_wsl_cuda_toolkit_package_resolver
    test_authorized_keys_merge
    test_project_conventions_contract
    test_flat_step_regression_contracts
    test_forbidden_patterns_hygiene
    test_generated_fish_config_templates_parse
    test_apt_settings_ignore_environment
    test_apt_helpers_replace_old_implementations
    test_apt_source_changes_reset_the_index_mark
    test_wsl_apt_update_check
    printf 'tests/test_optimize_distro_support.sh: OK\n'
}

main "$@"

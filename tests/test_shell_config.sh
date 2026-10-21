#!/usr/bin/env bash
# Tests of the shell configuration helpers in lib/common.sh: the Fish and Bash configs of the
# vps, mini and wsl2 profiles and their setup in a user's home. The embedded copies in
# optimize_*.sh are compared with lib/ by tests/test_embedded_copies.sh.
# The expected lines are literal config text (SC2016).
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR:-}"' EXIT
MSGS="$TEST_DIR/messages.log"
: > "$MSGS"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

log() { printf 'LOG: %s\n' "$1" >> "$MSGS"; }
warn() { printf 'WARN: %s\n' "$1" >> "$MSGS"; }

has_line() {
    grep -qxF -- "$2" <<<"$1"
}

test_profiles_render() {
    local profile fish bashrc

    for profile in vps mini wsl2; do
        fish="$(common_render_fish_config "$profile")" || fail "$profile: no Fish config"
        bashrc="$(common_render_bashrc "$profile")" || fail "$profile: no Bash config"

        bash -n <<<"$bashrc" || fail "$profile: the Bash config must parse"
        if command -v fish >/dev/null 2>&1; then
            fish -n <<<"$fish" || fail "$profile: the Fish config must parse"
        fi

        # Shared parts: Starship in both shells, fnm hooks, and Fish for interactive Bash.
        grep -qF "starship init fish | source" <<<"$fish" || fail "$profile: Fish must start Starship"
        has_line "$fish" "    fnm env --use-on-cd --shell fish | source" || fail "$profile: Fish must load fnm"
        has_line "$fish" 'alias ports="ss -tulpn"' || fail "$profile: Fish ports alias must use ss"
        has_line "$bashrc" "    exec fish" || fail "$profile: interactive Bash must switch to Fish"
        [ "$(grep -c 'exec fish' <<<"$bashrc")" = 1 ] || fail "$profile: Bash must switch to Fish once"
        has_line "$bashrc" '    eval "$(starship init bash)"' || fail "$profile: Bash must start Starship"
        has_line "$bashrc" "alias ports='ss -tulpn'" || fail "$profile: Bash ports alias must use ss (net-tools is not installed everywhere)"
        if grep -q netstat <<<"$bashrc$fish"; then
            fail "$profile: configs must not need netstat"
        fi
    done

    # Profile parts.
    has_line "$(common_render_fish_config mini)" 'alias temp="sensors"' || fail "mini: Fish must have the hardware aliases"
    if grep -q 'alias temp=' <<<"$(common_render_fish_config vps)"; then
        fail "vps: Fish must not have the mini-PC hardware aliases"
    fi
    has_line "$(common_render_fish_config wsl2)" "function explorer" || fail "wsl2: Fish must have the Windows helpers"
    has_line "$(common_render_bashrc wsl2)" "export EDITOR='code'" || fail "wsl2: Bash must use the Windows editor"
    has_line "$(common_render_bashrc vps)" "export EDITOR='vim'" || fail "vps: Bash must use vim"
    has_line "$(common_render_bashrc mini)" "export GOROOT=/usr/local/go" || fail "mini: Bash must set up Go"
    if grep -q 'explorer.exe' <<<"$(common_render_bashrc vps)$(common_render_fish_config mini)"; then
        fail "vps and mini must not have the WSL2 helpers"
    fi
    head -n 1 <<<"$(common_render_bashrc mini)" | grep -qxF "# Mini PC Optimized Bash Configuration" || fail "mini: Bash header changed"

    if common_render_fish_config other >/dev/null 2>&1 || common_render_bashrc other >/dev/null 2>&1; then
        fail "an unknown profile must fail"
    fi
}

test_setup_writes_once() {
    local user group home="$TEST_DIR/home"

    user="$(id -un)"
    group="$(id -gn)"
    mkdir -p "$home"
    printf '# the distribution .bashrc\n' > "$home/.bashrc"
    chmod 644 "$home/.bashrc"

    common_setup_fish "$user" "$home" vps || fail "the Fish setup must succeed"
    [ "$(cat "$home/.config/fish/config.fish")" = "$(common_render_fish_config vps)" ] || fail "config.fish must hold the vps config"
    [ "$(cat "$home/.bashrc")" = "# the distribution .bashrc" ] || fail "the Fish setup must not write .bashrc"

    # A tight umask shows that the copy keeps the mode of the original rather than getting a new one.
    (umask 077 && common_setup_bashrc "$user" "$home" vps) || fail "the Bash setup must succeed"
    [ "$(cat "$home/.bashrc")" = "$(common_render_bashrc vps)" ] || fail ".bashrc must hold the vps config"
    [ "$(find "$home" -maxdepth 1 -name '.bashrc.backup.*' | wc -l)" = 1 ] || fail "a foreign .bashrc must be copied once"
    [ "$(cat "$home"/.bashrc.backup.*)" = "# the distribution .bashrc" ] || fail "the copy must hold the original .bashrc"
    [ "$(stat -c %a "$home"/.bashrc.backup.*)" = 644 ] || fail "the copy must keep the mode of the original"
    [ "$(stat -c %U:%G "$home/.bashrc")" = "$user:$group" ] || fail ".bashrc must belong to the user"

    # A repeated run rewrites its own files and makes no new copy.
    common_setup_fish "$user" "$home" vps
    common_setup_bashrc "$user" "$home" vps
    [ "$(find "$home" -maxdepth 1 -name '.bashrc.backup.*' | wc -l)" = 1 ] || fail "a repeated run must not copy .bashrc again"

    # Another profile's file is ours too: switching profiles needs no copy either.
    common_setup_bashrc "$user" "$home" wsl2
    common_setup_bashrc "$user" "$home" mini
    common_setup_bashrc "$user" "$home" vps
    [ "$(find "$home" -maxdepth 1 -name '.bashrc.backup.*' | wc -l)" = 1 ] || fail "a .bashrc of another profile is ours and needs no copy"
    # Copies made within one second share a name: the content shows that none was made again.
    [ "$(cat "$home"/.bashrc.backup.*)" = "# the distribution .bashrc" ] || fail "the copy must still hold the original .bashrc"

    [ -f "$(find "$home" -maxdepth 1 -name '.bashrc.backup.*')" ] && [ ! -L "$(find "$home" -maxdepth 1 -name '.bashrc.backup.*')" ] || \
        fail "the copy must be a new regular file"

    # A missing home is reported and left alone: root does not create it here.
    : > "$MSGS"
    if common_setup_fish "$user" "$TEST_DIR/missing" vps || common_setup_bashrc "$user" "$TEST_DIR/missing" vps; then
        fail "a missing home must fail the setup"
    fi
    [ ! -e "$TEST_DIR/missing" ] || fail "a missing home must not be created"
    grep -q "Home directory $TEST_DIR/missing of $user is missing; its Fish configuration is skipped" "$MSGS" || fail "Fish must report the missing home"
    grep -q "Home directory $TEST_DIR/missing of $user is missing; its Bash configuration is skipped" "$MSGS" || fail "Bash must report the missing home"

    # No copy can be made: the user's own .bashrc stays as it is.
    printf '# another distribution .bashrc\n' > "$home/.bashrc"
    if (
        # shellcheck disable=SC2329 # Invoked by common_setup_bashrc.
        mktemp() { return 1; }
        common_setup_bashrc "$user" "$home" vps
    ) >/dev/null 2>&1; then
        fail "a failed copy must fail the setup"
    fi
    [ "$(cat "$home/.bashrc")" = "# another distribution .bashrc" ] || fail "without a copy the .bashrc must stay as it is"
}

# Prints the number of the first uncommented line that ends with the call $2 (fixed text).
first_call_line() {
    awk -v call="$2" '
        /^[[:space:]]*#/ { next }
        length($0) >= length(call) && substr($0, length($0) - length(call) + 1) == call { print NR; exit }
    ' "$1"
}

# The Fish step no longer writes ~/.bashrc: the Bash step, which writes it with the switch to Fish,
# must follow it in every script and for every user the Fish step configures.
test_bash_step_follows_fish_step() {
    local script user fish_line bash_line

    for script in optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh; do
        while IFS= read -r user; do
            fish_line="$(first_call_line "$ROOT_DIR/$script" "setup_fish_for_user $user")"
            bash_line="$(first_call_line "$ROOT_DIR/$script" "setup_bash_for_user $user")"
            [ -n "$bash_line" ] || fail "$script configures Fish for $user but not Bash"
            [ "$bash_line" -gt "$fish_line" ] || fail "$script must run the Bash step for $user after the Fish step"
        done < <(grep -oE 'setup_fish_for_user ("\$[A-Z_]+"|root)$' "$ROOT_DIR/$script" | sed 's/^setup_fish_for_user //' | sort -u)
    done
}

main() {
    test_profiles_render
    test_setup_writes_once
    test_bash_step_follows_fish_step
    printf 'tests/test_shell_config.sh: OK\n'
}

main "$@"

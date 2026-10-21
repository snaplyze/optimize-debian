#!/usr/bin/env bash
# Behavioral tests for optimize_wsl2.sh: the ssh-agent autostart (BUG-5) and the copy of
# /etc/wsl.conf (DATA-8). Every case sources the script with OPTIMIZE_SOURCE_ONLY=1 and points
# the path variables at a temporary tree; nothing outside it is touched, except the /tmp
# fallback case, which creates and removes /tmp/ssh-agent-<uid> of the test user.
# SC2016: case bodies are single-quoted on purpose, they run in a separate bash.
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/optimize_wsl2.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Common prelude for every case: sources the script without running the steps and isolates
# the environment. Each case runs in its own bash process and removes its temp directory on exit.
read -r -d '' CASE_HEADER <<'HEADER_EOF' || true
set -euo pipefail
OPTIMIZE_SOURCE_ONLY=1
source "$SCRIPT_ROOT/optimize_wsl2.sh"
LOG_FILE=""
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/etc/profile.d" "$T/bin"
SSH_AGENT_PROFILE_FILE="$T/etc/profile.d/wsl2-ssh-agent.sh"
WSL_CONF_FILE="$T/etc/wsl.conf"
DOCKER_USER="tester"
common_user_home() { [ "$1" = tester ] && printf "%s\n" "$T/home"; }

die() { printf "FAIL: %s\n" "$*" >&2; exit 1; }
log() { printf "[OK] %s\n" "$1" >> "$T/log"; }
warn() { printf "[WARN] %s\n" "$1" >> "$T/log"; }

# The block earlier versions appended, with the empty line printf "%b\n" left after it.
LEGACY_BLOCK='# WSL2: автозапуск ssh-agent (без systemd)
if ! pgrep -u "$USER" ssh-agent >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" >/dev/null
fi

'
LEGACY_BLOCK_NO_EMPTY_LINE="${LEGACY_BLOCK%$'\n'}"
HEADER_EOF

run_case() {
    SCRIPT_ROOT="$ROOT_DIR" bash -c "$CASE_HEADER"$'\n'"$1"
}

test_legacy_branches_removed() {
    ! grep -q '^has_user_systemd()' "$SCRIPT" || fail "has_user_systemd is defined again in optimize_wsl2.sh"
    ! grep -Fq 'systemctl --user enable --now ssh-agent.socket' "$SCRIPT" || \
        fail "the ssh-agent step must not enable the agent of root through systemctl --user"
    ! grep -Fq '/home/$DOCKER_USER/.bash_profile' "$SCRIPT" || \
        fail "the home of DOCKER_USER must come from passwd, not /home/\$DOCKER_USER"
    grep -Fq 'backup_wsl_conf' "$SCRIPT" || fail "the wsl.conf step must call backup_wsl_conf"
    ! grep -Fq '/etc/wsl.conf.backup.$(date +%F)"' "$SCRIPT" || fail "the wsl.conf copy must carry the time"
    [ "$(grep -c '^    configure_ssh_agent_autostart$' "$SCRIPT")" = 1 ] || \
        fail "configure_ssh_agent_autostart must run exactly once from the ssh-agent step"
}

test_profile_file_is_posix_and_readable() {
    command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is required to check the profile.d snippet (CI installs it)"
    run_case '
        configure_ssh_agent_autostart
        [ -f "$SSH_AGENT_PROFILE_FILE" ] || die "profile.d file must be created"
        [ "$(stat -c %a "$SSH_AGENT_PROFILE_FILE")" = 644 ] || die "profile.d file must be mode 644"
        head -n 1 "$SSH_AGENT_PROFILE_FILE" | grep -Fq "optimize_wsl2.sh" || die "the first line must name the writer"
        sh -n "$SSH_AGENT_PROFILE_FILE" || die "profile.d file must parse as sh"
        if command -v dash >/dev/null 2>&1; then
            dash -n "$SSH_AGENT_PROFILE_FILE" || die "profile.d file must parse in dash"
        fi
        shellcheck -s sh "$SSH_AGENT_PROFILE_FILE" || die "profile.d file must pass shellcheck -s sh"
        ! grep -Fq "\$HOME/.ssh" "$SSH_AGENT_PROFILE_FILE" || die "the socket must not live in ~/.ssh (often a DrvFS link on WSL)"
        [ -z "$(ls -A "$T/etc/profile.d" | grep -v "^wsl2-ssh-agent.sh$")" ] || \
            die "temporary files left in profile.d: $(ls -A "$T/etc/profile.d")"
        grep -Fq "ssh-agent autostart written to $SSH_AGENT_PROFILE_FILE" "$T/log" || die "the write must be logged"

        # A second run rewrites nothing.
        cp -p "$SSH_AGENT_PROFILE_FILE" "$T/first"
        : > "$T/log"
        configure_ssh_agent_autostart
        cmp -s "$T/first" "$SSH_AGENT_PROFILE_FILE" || die "a second run must leave the same profile.d file"
        ! grep -Fq "written to" "$T/log" || die "a second run must not report a write"
        [ "$(ls -A "$T/etc/profile.d" | wc -l)" = 1 ] || die "a second run must not leave files: $(ls -A "$T/etc/profile.d")"
    '
}

# Runs the profile.d snippet under $SNIPPET_SH with set -e, mocked ssh-add (exit code $1) and
# ssh-agent (exit code MOCK_SSH_AGENT_RC) that log their calls to $T/calls, and prints three
# lines: SSH_AUTH_SOCK (or "unset"), the number of leaked _wsl2_agent variables, REACHED.
read -r -d '' SNIPPET_SANDBOX <<'SANDBOX_EOF' || true
write_ssh_agent_profile || true
cat > "$T/bin/ssh-add" <<EOF
#!/usr/bin/env bash
printf "ssh-add %s\n" "\$*" >> "$T/calls"
exit \${MOCK_SSH_ADD_RC:-2}
EOF
cat > "$T/bin/ssh-agent" <<EOF
#!/usr/bin/env bash
printf "ssh-agent %s\n" "\$*" >> "$T/calls"
if [ "\${MOCK_SSH_AGENT_RC:-0}" != 0 ]; then
    echo "unix_listener: cannot bind to path: Operation not permitted" >&2
    exit "\$MOCK_SSH_AGENT_RC"
fi
printf "SSH_AGENT_PID=4242; export SSH_AGENT_PID;\necho Agent pid 4242;\n"
EOF
chmod 755 "$T/bin/ssh-add" "$T/bin/ssh-agent"
mkdir -m 700 "$T/run"
# The /tmp fallback of the snippet is a fixed path of the test user: it is removed on exit
# unless it existed before, in which case the cases that need it are skipped.
TMP_AGENT_DIR="/tmp/ssh-agent-$(id -u)"
TMP_AGENT_DIR_FREE=1
if [ -e "$TMP_AGENT_DIR" ]; then
    TMP_AGENT_DIR_FREE=0
else
    trap 'rm -rf "$T" "$TMP_AGENT_DIR"' EXIT
fi
run_snippet() {
    : > "$T/calls"
    env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$T/run" MOCK_SSH_ADD_RC="$1" "${@:2}" \
        "$SNIPPET_SH" -c "set -e; . \"$SSH_AGENT_PROFILE_FILE\"; printf \"%s\\n\" \"\${SSH_AUTH_SOCK:-unset}\"; \
set | grep -c \"^_wsl2_agent\" || true; echo REACHED" > "$T/out" 2> "$T/stderr" || true
    [ "$(sed -n 3p "$T/out")" = REACHED ] || die "[$SNIPPET_SH] the shell with set -e must survive the snippet: $(cat "$T/out" "$T/stderr")"
    [ "$(sed -n 2p "$T/out")" = 0 ] || die "[$SNIPPET_SH] the snippet must unset its variables: $(cat "$T/out")"
    [ ! -s "$T/stderr" ] || die "[$SNIPPET_SH] the snippet must print nothing to stderr: $(cat "$T/stderr")"
    sed -n 1p "$T/out"
}
SNIPPET_SHELLS="sh"
if command -v dash >/dev/null 2>&1; then
    SNIPPET_SHELLS="sh dash"
else
    printf "SKIP: dash not installed, the snippet runs under sh only\n" >&2
fi
SANDBOX_EOF

test_snippet_starts_agent_only_without_one() {
    run_case "$SNIPPET_SANDBOX"'
        for SNIPPET_SH in $SNIPPET_SHELLS; do
            # No agent answers (2): the socket is set, a stale socket file is removed, the agent starts.
            : > "$T/run/ssh-agent.sock"
            sock="$(run_snippet 2)"
            [ "$sock" = "$T/run/ssh-agent.sock" ] || die "[$SNIPPET_SH] SSH_AUTH_SOCK must point at XDG_RUNTIME_DIR/ssh-agent.sock, got: $sock"
            grep -Fxq "ssh-add -l" "$T/calls" || die "ssh-add -l must probe the socket: $(cat "$T/calls")"
            grep -Fxq "ssh-agent -a $T/run/ssh-agent.sock" "$T/calls" || die "ssh-agent -a must start on the socket: $(cat "$T/calls")"
            [ ! -e "$T/run/ssh-agent.sock" ] || die "the stale socket file must be removed before the agent starts"

            # A live agent without keys (1) and with keys (0): nothing is started.
            for rc in 1 0; do
                sock="$(run_snippet "$rc")"
                [ "$sock" = "$T/run/ssh-agent.sock" ] || die "[$SNIPPET_SH] SSH_AUTH_SOCK must be set for rc=$rc, got: $sock"
                ! grep -q "^ssh-agent" "$T/calls" || die "a live agent (rc=$rc) must not be replaced: $(cat "$T/calls")"
            done

            # The agent cannot bind: silent, and SSH_AUTH_SOCK does not point at a dead socket.
            sock="$(run_snippet 2 MOCK_SSH_AGENT_RC=1)"
            [ "$sock" = unset ] || die "[$SNIPPET_SH] a failed bind must leave SSH_AUTH_SOCK unset, got: $sock"
            grep -q "^ssh-agent" "$T/calls" || die "the agent must have been tried: $(cat "$T/calls")"

            # An agent set by the caller (WSL agent relay, ssh -A) is kept and nothing is called.
            sock="$(run_snippet 2 SSH_AUTH_SOCK=/run/user/1000/relay.sock)"
            [ "$sock" = /run/user/1000/relay.sock ] || die "[$SNIPPET_SH] a set SSH_AUTH_SOCK must stay, got: $sock"
            [ ! -s "$T/calls" ] || die "nothing may run when SSH_AUTH_SOCK is set: $(cat "$T/calls")"
        done
    '
}

test_snippet_checks_the_socket_directory() {
    run_case "$SNIPPET_SANDBOX"'
        mkdir -m 755 "$T/run755"
        ln -s "$T/run" "$T/runlink"
        for SNIPPET_SH in $SNIPPET_SHELLS; do
            # XDG_RUNTIME_DIR is used as it is (systemd gives it mode 700 itself).
            sock="$(run_snippet 2 XDG_RUNTIME_DIR="$T/run755")"
            [ "$sock" = "$T/run755/ssh-agent.sock" ] || die "[$SNIPPET_SH] XDG_RUNTIME_DIR must be used when set, got: $sock"
            grep -q "^ssh-agent -a $T/run755/" "$T/calls" || die "the agent must start in XDG_RUNTIME_DIR: $(cat "$T/calls")"

            # A link or a directory of another user: nothing is started, nothing is exported.
            sock="$(run_snippet 2 XDG_RUNTIME_DIR="$T/runlink")"
            [ "$sock" = unset ] || die "[$SNIPPET_SH] a linked directory must not be used, got: $sock"
            [ ! -s "$T/calls" ] || die "nothing may run for a linked directory: $(cat "$T/calls")"
            printf "#!/usr/bin/env bash\n[ \"\$1\" = -c ] && [ \"\$2\" = %%u ] && { echo 0; exit 0; }\nexec /usr/bin/stat \"\$@\"\n" > "$T/bin/stat"
            chmod 755 "$T/bin/stat"
            sock="$(run_snippet 2)"
            rm -f "$T/bin/stat"
            [ "$sock" = unset ] || die "[$SNIPPET_SH] a directory of another user must not be used, got: $sock"
            [ ! -s "$T/calls" ] || die "nothing may run for a directory of another user: $(cat "$T/calls")"

            # Without XDG_RUNTIME_DIR: /tmp/ssh-agent-<uid>, created with mode 700 and used only with it.
            if [ "$TMP_AGENT_DIR_FREE" != 1 ]; then
                printf "SKIP: %s exists, the /tmp fallback is not checked\n" "$TMP_AGENT_DIR" >&2
                continue
            fi
            sock="$(run_snippet 2 XDG_RUNTIME_DIR=)"
            [ "$sock" = "$TMP_AGENT_DIR/ssh-agent.sock" ] || die "[$SNIPPET_SH] the /tmp fallback must be used without XDG_RUNTIME_DIR, got: $sock"
            [ "$(stat -c %a "$TMP_AGENT_DIR")" = 700 ] || die "the /tmp fallback must be created with mode 700"
            grep -q "^ssh-agent -a $TMP_AGENT_DIR/" "$T/calls" || die "the agent must start in the /tmp fallback: $(cat "$T/calls")"
            chmod 755 "$TMP_AGENT_DIR"
            sock="$(run_snippet 2 XDG_RUNTIME_DIR=)"
            [ "$sock" = unset ] || die "[$SNIPPET_SH] a /tmp fallback without mode 700 must not be used, got: $sock"
            [ ! -s "$T/calls" ] || die "nothing may run for a /tmp fallback without mode 700: $(cat "$T/calls")"
            rm -rf "$TMP_AGENT_DIR"
        done
    '
}

test_legacy_block_cleanup() {
    run_case '
        # The test does not run as root: stat reports .profile as owned by root and the rest
        # by the user, chown only records its call.
        stat() {
            if [ "$1" = -c ] && [ "$2" = %u ]; then
                case "$3" in
                    "$T/home/.profile") echo 0 ;;
                    *) echo 1000 ;;
                esac
            else
                command stat "$@"
            fi
        }
        chown() { printf "chown %s\n" "$*" >> "$T/chown"; }
        : > "$T/chown"

        debian_profile="# ~/.profile: executed by the command interpreter for login shells.
if [ -n \"\$BASH_VERSION\" ]; then
    if [ -f \"\$HOME/.bashrc\" ]; then
        . \"\$HOME/.bashrc\"
    fi
fi
"
        # .bash_profile of the block alone, .profile of Debian plus the block, .zprofile with
        # other lines around the block, .bashrc without a block.
        printf "%s" "$LEGACY_BLOCK" > "$T/home/.bash_profile"
        printf "%s%s" "$debian_profile" "$LEGACY_BLOCK" > "$T/home/.profile"
        chmod 600 "$T/home/.profile"
        printf "export EDITOR=vim\n%sautoload -Uz compinit\n" "$LEGACY_BLOCK" > "$T/home/.zprofile"
        printf "alias ll=\"ls -l\"\n" > "$T/home/.bashrc"
        cp -p "$T/home/.bashrc" "$T/bashrc.orig"

        configure_ssh_agent_autostart

        [ ! -e "$T/home/.bash_profile" ] || die ".bash_profile that held only the block must be removed"
        [ -f "$T/home/.profile" ] || die ".profile must stay"
        printf "%s" "$debian_profile" | cmp -s - "$T/home/.profile" || die ".profile content differs from the original: $(cat -A "$T/home/.profile")"
        [ "$(stat -c %a "$T/home/.profile")" = 600 ] || die ".profile must keep its mode"
        [ -f "$T/home/.zprofile" ] || die ".zprofile with other lines must stay"
        [ "$(cat "$T/home/.zprofile")" = "$(printf "export EDITOR=vim\nautoload -Uz compinit")" ] || \
            die ".zprofile must keep the other lines: $(cat -A "$T/home/.zprofile")"
        cmp -s "$T/bashrc.orig" "$T/home/.bashrc" || die "a file without the block must not change"
        ! grep -rF "WSL2: автозапуск ssh-agent" "$T/home" || die "the block must be gone from every login file"
        [ "$(grep -c "Removed the ssh-agent block" "$T/log")" = 3 ] || die "every cleanup must be logged: $(cat "$T/log")"
        grep -Fq "Removed $T/home/.bash_profile" "$T/log" || die "the removal of .bash_profile must be logged"
        [ "$(cat "$T/chown")" = "chown --reference=$T/home $T/home/.profile" ] || \
            die ".profile owned by root must get the owner of the home, and nothing else: $(cat "$T/chown")"
        grep -Fq "Gave $T/home/.profile the owner of $T/home" "$T/log" || die "the chown must be logged: $(cat "$T/log")"

        # A second run changes nothing.
        cp -p "$T/home/.profile" "$T/profile.first"
        cp -p "$T/home/.zprofile" "$T/zprofile.first"
        : > "$T/log"
        : > "$T/chown"
        configure_ssh_agent_autostart
        cmp -s "$T/profile.first" "$T/home/.profile" || die "a second run must not change .profile"
        cmp -s "$T/zprofile.first" "$T/home/.zprofile" || die "a second run must not change .zprofile"
        [ ! -e "$T/home/.bash_profile" ] || die "a second run must not create .bash_profile"
        ! grep -q "Removed" "$T/log" || die "a second run must not report removals: $(cat "$T/log")"
        [ ! -s "$T/chown" ] || die "a second run must not chown: $(cat "$T/chown")"
    '
}

test_legacy_block_cleanup_edge_cases() {
    run_case '
        # .profile that earlier versions created from the block alone stays as an empty file.
        printf "%s" "$LEGACY_BLOCK" > "$T/home/.profile"
        # A block without the trailing empty line, followed by a line, and a line that merely
        # mentions the marker: only the exact block goes.
        printf "%s# WSL2: автозапуск ssh-agent (без systemd) was here\n" "$LEGACY_BLOCK_NO_EMPTY_LINE" > "$T/home/.zprofile"
        # A link is not written through, even when its target holds the block.
        printf "%s" "$LEGACY_BLOCK" > "$T/target"
        cp -p "$T/target" "$T/target.orig"
        ln -s "$T/target" "$T/home/.bash_profile"
        configure_ssh_agent_autostart
        [ -f "$T/home/.profile" ] || die ".profile is never removed"
        [ ! -s "$T/home/.profile" ] || die ".profile must be empty after the block is removed: $(cat -A "$T/home/.profile")"
        [ "$(cat "$T/home/.zprofile")" = "# WSL2: автозапуск ssh-agent (без systemd) was here" ] || \
            die "only the exact block may be removed: $(cat -A "$T/home/.zprofile")"
        [ -L "$T/home/.bash_profile" ] || die "a linked login file must stay a link"
        cmp -s "$T/target.orig" "$T/target" || die "the target of a linked login file must not change"
        grep -Fq "[WARN] $T/home/.bash_profile is a symbolic link" "$T/log" || die "a linked login file must be warned about: $(cat "$T/log")"

        # No home in passwd: the profile.d file is written, the cleanup is skipped with a warning.
        rm -f "$SSH_AGENT_PROFILE_FILE" "$T/home/.bash_profile"
        printf "%s" "$LEGACY_BLOCK" > "$T/home/.bash_profile"
        DOCKER_USER="nobody-here"
        : > "$T/log"
        configure_ssh_agent_autostart
        [ -f "$SSH_AGENT_PROFILE_FILE" ] || die "profile.d file must be written even without a home"
        [ -f "$T/home/.bash_profile" ] || die "without a home nothing may be removed"
        grep -Fq "[WARN] Home directory of nobody-here not found" "$T/log" || die "a missing home must be warned about: $(cat "$T/log")"
    '
}

test_wsl_conf_backup_keeps_every_copy() {
    run_case '
        FAKE_DATE="2026-10-21-101010"
        date() { [ "$*" = "+%F-%H%M%S" ] || die "the copy name needs date +%F-%H%M%S, got: date $*"; printf "%s\n" "$FAKE_DATE"; }

        backup_wsl_conf
        [ "$(ls "$T/etc" | grep -c "^wsl.conf.backup.")" = 0 ] || die "no copy without a wsl.conf: $(ls -A "$T/etc")"

        printf "[boot]\nsystemd=false\n" > "$WSL_CONF_FILE"
        chmod 640 "$WSL_CONF_FILE"
        touch -d "2025-01-02 03:04:05" "$WSL_CONF_FILE"
        cp -p "$WSL_CONF_FILE" "$T/wsl.conf.orig"
        backup_wsl_conf
        [ -f "$WSL_CONF_FILE.backup.2026-10-21-101010" ] || die "the copy must carry the date and time: $(ls -A "$T/etc")"
        [ "$(stat -c %a "$WSL_CONF_FILE.backup.2026-10-21-101010")" = 640 ] || die "the copy must keep the mode"
        [ "$(stat -c %Y "$WSL_CONF_FILE.backup.2026-10-21-101010")" = "$(stat -c %Y "$WSL_CONF_FILE")" ] || \
            die "the copy must keep the time of the original (cp -p)"
        grep -Fq "Backed up $WSL_CONF_FILE to $WSL_CONF_FILE.backup.2026-10-21-101010" "$T/log" || die "the copy must be logged"

        # The script writes its own wsl.conf, then a second run the same day copies again.
        render_wsl_conf "" > "$WSL_CONF_FILE"
        FAKE_DATE="2026-10-21-181818"
        backup_wsl_conf
        [ "$(ls "$T/etc" | grep -c "^wsl.conf.backup.")" = 2 ] || die "two runs must leave two copies: $(ls -A "$T/etc")"
        cmp -s "$T/wsl.conf.orig" "$WSL_CONF_FILE.backup.2026-10-21-101010" || die "the first copy must still hold the original"
        cmp -s "$WSL_CONF_FILE" "$WSL_CONF_FILE.backup.2026-10-21-181818" || die "the second copy must hold the current file"

        # A failed copy warns and does not stop the step.
        cp() { return 1; }
        FAKE_DATE="2026-10-21-191919"
        backup_wsl_conf || die "a failed copy must not fail the step"
        grep -Fq "[WARN] Could not back up $WSL_CONF_FILE" "$T/log" || die "a failed copy must be warned about: $(cat "$T/log")"
    '
}

main() {
    test_legacy_branches_removed
    test_profile_file_is_posix_and_readable
    test_snippet_starts_agent_only_without_one
    test_snippet_checks_the_socket_directory
    test_legacy_block_cleanup
    test_legacy_block_cleanup_edge_cases
    test_wsl_conf_backup_keeps_every_copy
    printf 'test_wsl2.sh: OK\n'
}

main "$@"

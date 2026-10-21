#!/usr/bin/env bash
# DEL-1: `bash <(curl ...)` runs the script as it arrives. A download cut short must change
# nothing: every step runs from optimize_main, called on the last line, and bash reads a whole
# function before running it. --help must answer without root and without changes.
# shellcheck disable=SC2016 # sed and grep patterns hold literal script text.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(optimize_vps.sh optimize_mini_pc.sh optimize_wsl2.sh)

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR:-}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Commands that change a system: each records its call instead.
make_mocks() {
    local cmd

    mkdir -p "$TEST_DIR/bin"
    for cmd in apt apt-get dpkg useradd adduser usermod groupadd chpasswd passwd visudo systemctl \
        service sysctl ufw sed cp mv rm chmod chown install tee mkdir touch ln reboot shutdown curl \
        wget timedatectl hostnamectl locale-gen update-locale modprobe swapon swapoff mkswap fallocate \
        dd sshd update-grub gpg tar unzip mount umount fish starship docker; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\n' "$cmd" "$TEST_DIR/calls.log" > "$TEST_DIR/bin/$cmd"
        chmod +x "$TEST_DIR/bin/$cmd"
    done
}

# Runs the text $1 with bash and the mocks; prints "reached" when the first step ran.
run_text() {
    : > "$TEST_DIR/calls.log"
    : > "$TEST_DIR/reached"
    PATH="$TEST_DIR/bin:$PATH" REACHED_LOG="$TEST_DIR/reached" bash "$1" </dev/null >/dev/null 2>&1 || true
    cat "$TEST_DIR/reached"
}

test_truncated_script_changes_nothing() {
    local script="$1"
    local size cut percent

    tail -n 1 "$ROOT_DIR/$script" | grep -qxF 'optimize_main "$@"' || fail "$script must end with the optimize_main call"

    # The first step of every script is the root check. In the copy it records that the steps
    # started and stops there, so the test never runs a step and does not depend on the host OS.
    sed -E 's/^if \[\[ \$EUID -ne 0 \]\]; then$/if printf "reached\\n" >> "$REACHED_LOG"; exit 0; then/' \
        "$ROOT_DIR/$script" > "$TEST_DIR/full.sh"
    [ "$(grep -c 'REACHED_LOG' "$TEST_DIR/full.sh")" = 1 ] || fail "$script: exactly one root check expected"
    size="$(wc -c < "$TEST_DIR/full.sh")"

    # Control: the whole script reaches its first step.
    [ "$(run_text "$TEST_DIR/full.sh")" = reached ] || fail "$script: the complete script must reach its first step"

    for percent in 5 20 35 50 60 70 80 90 95 99; do
        cut=$((size * percent / 100))
        head -c "$cut" "$TEST_DIR/full.sh" > "$TEST_DIR/cut.sh"
        [ -z "$(run_text "$TEST_DIR/cut.sh")" ] || fail "$script cut at $percent% ran its steps"
        [ ! -s "$TEST_DIR/calls.log" ] || fail "$script cut at $percent% ran: $(head -n 3 "$TEST_DIR/calls.log")"
    done

    # Everything but the call: main is defined and never runs.
    head -n -1 "$TEST_DIR/full.sh" > "$TEST_DIR/cut.sh"
    [ -z "$(run_text "$TEST_DIR/cut.sh")" ] || fail "$script without its last line ran its steps"
    [ ! -s "$TEST_DIR/calls.log" ] || fail "$script without its last line ran: $(head -n 3 "$TEST_DIR/calls.log")"
}

test_help_without_root() {
    local script="$1"
    local output status arg version

    version="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$ROOT_DIR/$script")"
    [ -n "$version" ] || fail "$script must set SCRIPT_VERSION"
    for arg in --help -h; do
        : > "$TEST_DIR/calls.log"
        status=0
        output="$(PATH="$TEST_DIR/bin:$PATH" bash "$ROOT_DIR/$script" "$arg" </dev/null 2>&1)" || status=$?
        [ "$status" -eq 0 ] || fail "$script $arg must exit 0, got $status: $output"
        grep -q '^Usage: sudo bash '"$script"'$' <<<"$output" || fail "$script $arg must print the usage: $output"
        grep -Fqx "Version: $version" <<<"$output" || fail "$script $arg must print version $version: $output"
        [ ! -s "$TEST_DIR/calls.log" ] || fail "$script $arg must change nothing: $(head -n 3 "$TEST_DIR/calls.log")"
    done

    : > "$TEST_DIR/calls.log"
    status=0
    output="$(PATH="$TEST_DIR/bin:$PATH" bash "$ROOT_DIR/$script" --bogus </dev/null 2>&1)" || status=$?
    [ "$status" -eq 2 ] || fail "$script with an unknown argument must exit 2, got $status"
    grep -q 'Unknown argument: --bogus' <<<"$output" || fail "$script must name the unknown argument: $output"
    [ ! -s "$TEST_DIR/calls.log" ] || fail "$script with an unknown argument must change nothing"
}

main() {
    local script

    make_mocks
    for script in "${SCRIPTS[@]}"; do
        test_truncated_script_changes_nothing "$script"
        test_help_without_root "$script"
    done
    printf 'tests/test_truncated_download.sh: OK\n'
}

main "$@"

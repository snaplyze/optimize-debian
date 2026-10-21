#!/usr/bin/env bash
# Tests of the SSH hardening helpers in lib/common.sh: the read-back of the values sshd takes
# (sshd -T) and the recognition of the drop-ins earlier versions wrote. The embedded copies in
# optimize_*.sh are compared with lib/ by tests/test_embedded_copies.sh.
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR:-}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# sshd -T prints SSHD_T_OUTPUT, or fails when SSHD_T_RC is not 0.
SSHD_T_OUTPUT=""
SSHD_T_RC=0
sshd() {
    [ "$1" = -T ] || fail "only sshd -T is expected, got: sshd $*"
    [ "$SSHD_T_RC" -eq 0 ] || return "$SSHD_T_RC"
    printf '%s\n' "$SSHD_T_OUTPUT"
}

test_effective_mismatches() {
    local out rc

    SSHD_T_OUTPUT="$(printf '%s\n' "port 2222" "port 22" "permitrootlogin no" "passwordauthentication no" \
        "allowusers ops" "allowusers backup")"

    out="$(common_sshd_effective_mismatches "permitrootlogin no" "passwordauthentication no" "allowusers ops" "port 2222")" ||
        fail "matching values must pass: $out"
    [ -z "$out" ] || fail "matching values must print nothing: $out"

    # Several values of a keyword that adds up: one of them is enough.
    common_sshd_effective_mismatches "allowusers backup" "port 22" >/dev/null || fail "any value of allowusers and port must match"

    rc=0
    out="$(common_sshd_effective_mismatches "passwordauthentication yes" "allowusers alice" "kbdinteractiveauthentication no")" || rc=$?
    [ "$rc" -eq 1 ] || fail "a mismatch must return 1, got $rc"
    [ "$out" = "$(printf '%s\n' "passwordauthentication: expected yes, effective no" \
        "allowusers: expected alice, effective ops, backup" \
        "kbdinteractiveauthentication: expected no, effective none")" ] || fail "unexpected mismatch report: $out"

    # A keyword is matched whole: "port 222" is not "port 2222".
    rc=0
    common_sshd_effective_mismatches "port 222" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "a value must match the whole line"

    rc=0
    SSHD_T_RC=255
    out="$(common_sshd_effective_mismatches "permitrootlogin no")" || rc=$?
    SSHD_T_RC=0
    [ "$rc" -eq 2 ] || fail "a failed sshd -T must return 2, got $rc"
    [ -z "$out" ] || fail "a failed sshd -T must print nothing: $out"
}

test_legacy_dropin_is_ours() {
    local file="$TEST_DIR/99-hardening.conf"

    printf '%s\n' "# SSH Hardening - VPS Optimization" "PermitRootLogin no" "AllowUsers ops" > "$file"
    common_sshd_legacy_dropin_is_ours "$file" || fail "the VPS drop-in must be ours"

    printf '%s\n' "# Minimal Amnezia host SSH baseline" "Port 2222" > "$file"
    common_sshd_legacy_dropin_is_ours "$file" || fail "the Amnezia drop-in must be ours"

    printf '%s\n' "PermitRootLogin no" "PasswordAuthentication no" "PubkeyAuthentication yes" "AllowUsers ops" > "$file"
    common_sshd_legacy_dropin_is_ours "$file" || fail "the four mini-PC lines must be ours"

    printf '%s\n' "PermitRootLogin no" "PasswordAuthentication no" "PubkeyAuthentication yes" "AllowUsers ops" "Port 2222" > "$file"
    ! common_sshd_legacy_dropin_is_ours "$file" || fail "a fifth line makes the file an operator file"

    printf '%s\n' "PermitRootLogin no" "PasswordAuthentication no" "PubkeyAuthentication yes" "AllowUsers ops backup" > "$file"
    ! common_sshd_legacy_dropin_is_ours "$file" || fail "two users in AllowUsers make the file an operator file"

    printf '%s\n' "# my hardening" "PasswordAuthentication no" > "$file"
    ! common_sshd_legacy_dropin_is_ours "$file" || fail "an operator file must not be ours"

    ! common_sshd_legacy_dropin_is_ours "$TEST_DIR/missing.conf" || fail "a missing file must not be ours"
    ! common_sshd_legacy_dropin_is_ours "$TEST_DIR" || fail "a directory must not be ours"
}

main() {
    test_effective_mismatches
    test_legacy_dropin_is_ours
    printf 'tests/test_ssh_helpers.sh: OK\n'
}

main "$@"
